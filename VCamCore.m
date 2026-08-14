//
//  VCamCore.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamCore 实现
//  核心职责：
//    1. 从 LocalVideoPlayer 获取当前帧
//    2. 用 GPUImageProcessor 处理（旋转/镜像/格式转换）
//    3. 写入目标 pixelBuffer（hook 函数传入的相机帧）
//    4. 缓存最后渲染的帧（双格式：BGRA + YUV）
//    5. 状态控制（loadState 转换）
//    6. plist 轮询（mediaserverd 安全通道）
//

#import "VCamCore.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

static void vcam_core_log(NSString *msg) {
    @try {
        NSString *logPath = @"/tmp/vcam_core_log.txt";
        NSString *ts = [NSDate date].description;
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

@interface VCamCore ()
@property (nonatomic, strong) dispatch_source_t pollingTimer;
@property (nonatomic, assign) BOOL pollingActive;
@property (nonatomic, assign) BOOL lastEnabledState;
// 帧缓存: 避免每次 render 都调用 processPixelBuffer（24fps 视频 vs 60fps 相机）
@property (nonatomic, assign) CVPixelBufferRef cachedProcessedFrame;
@property (nonatomic, assign) uint64_t lastProcessedFrameCount;
@property (nonatomic, assign) size_t lastProcessedWidth;
@property (nonatomic, assign) size_t lastProcessedHeight;
@property (nonatomic, assign) OSType lastProcessedFormat;
@end

@implementation VCamCore

+ (instancetype)sharedInstance {
    static VCamCore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamCore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _prerenderQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        _processingQueue = dispatch_queue_create("com.vcam.processing.bg", DISPATCH_QUEUE_SERIAL);
        _processLock = [[NSLock alloc] init];
        _isPixelBufferMode = YES;
        _preprocessEnabled = YES;
        _enabled = NO;
        _targetSizeKnown = NO;
        _targetWidth = 0;
        _targetHeight = 0;
        _targetFormat = 0;
        _liveBGRAPixelBuffer = NULL;
        _liveYUVPixelBuffer = NULL;
        _lastRenderedWidth = 0;
        _lastRenderedHeight = 0;
        _frameCount = 0;
        _pollingActive = NO;
        _lastEnabledState = NO;
        _formatLockMap = [[NSMutableDictionary alloc] init];
        _cachedProcessedFrame = NULL;
        _lastProcessedFrameCount = 0;
        _lastProcessedWidth = 0;
        _lastProcessedHeight = 0;
        _lastProcessedFormat = 0;

        // 初始化组件
        _gpuProcessor = [[GPUImageProcessor alloc] init];
        _videoPlayer = [[LocalVideoPlayer alloc] initWithCapacity:10];
        _videoPlayer.gpuProcessor = _gpuProcessor;
        _frameQueue = _videoPlayer.frameQueue;

        // CIContext（软件渲染）
        @try {
            _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        } @catch (NSException *e) {
            _ciContext = nil;
        }

        vcam_core_log(@"[vcam] VCamCore initialized with multi-format buffer pools (vcamplus style)");
    }
    return self;
}

- (void)dealloc {
    [self stopStatePolling];
    [self clearReplacementFrame];
    vcam_core_log(@"[vcam] VCamCore deallocated");
}

#pragma mark - 初始化

- (void)initializeInMediaserverd {
    vcam_core_log(@"[vcam] Initializing in mediaserverd...");
    // mediaserverd 中用 plist 轮询（Darwin 通知不安全）
    [self startStatePolling];
    vcam_core_log(@"[vcam] MediaServerd hooks initialized");
}

- (void)initializeInSpringBoard {
    vcam_core_log(@"[vcam] SpringBoard hooks initialized");
    // SpringBoard 中也用 plist 轮询
    [self startStatePolling];
}

#pragma mark - 核心方法

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || !_enabled) return;

    size_t origWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t origHeight = CVPixelBufferGetHeight(pixelBuffer);
    OSType origFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

    // 诊断: 每 60 帧记录 render 入口
    static int vcamRenderCount = 0;
    vcamRenderCount++;
    BOOL diagThisFrame = (vcamRenderCount % 60 == 1);

    // 1. 格式白名单检查
    if (![self isSupportedVideoFormat:pixelBuffer]) {
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d SKIP whitelist fmt=0x%x", vcamRenderCount, (unsigned)origFormat]);
        return;
    }

    // 2. 多格式锁定: 每种格式独立锁尺寸(允许 420f/|xv0/p420 等多格式同时处理)
    NSNumber *fmtKey = @(origFormat);
    NSString *lockedSize = _formatLockMap[fmtKey];
    if (!lockedSize) {
        // 该格式首次遇到, 锁定其尺寸
        char fstr[5] = {0};
        fstr[0] = (char)(origFormat >> 24);
        fstr[1] = (char)(origFormat >> 16);
        fstr[2] = (char)(origFormat >> 8);
        fstr[3] = (char)origFormat;
        vcam_core_log([NSString stringWithFormat:@"[vcam] Format locked: %zux%zu fmt=0x%x (%s)",
                       origWidth, origHeight, (unsigned)origFormat, fstr]);
        // 用 NSString 存 "w,h" 简单可靠(NSValue 包装 size_t 在 ARC 下不安全)
        _formatLockMap[fmtKey] = [NSString stringWithFormat:@"%zu,%zu", origWidth, origHeight];
        // 兼容旧字段
        _targetWidth = origWidth;
        _targetHeight = origHeight;
        _targetFormat = origFormat;
        _targetSizeKnown = YES;
    } else {
        // 该格式已锁定, 检查尺寸是否匹配(同格式不同尺寸仍跳过, 防 mismatch 崩溃)
        NSArray *parts = [lockedSize componentsSeparatedByString:@","];
        if (parts.count == 2) {
            size_t lw = (size_t)[parts[0] integerValue];
            size_t lh = (size_t)[parts[1] integerValue];
            if (origWidth != lw || origHeight != lh) {
                if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d SKIP size mismatch %zux%zu fmt=0x%x (locked %zux%zu)", vcamRenderCount, origWidth, origHeight, (unsigned)origFormat, lw, lh]);
                return;
            }
        }
    }

    // 3. 帧缓存: 只在视频帧变化或目标格式/尺寸变化时重新处理 processPixelBuffer
    //    (视频 24fps vs 相机 60fps, 缓存避免 60% 的重复处理, 大幅减少卡顿)
    uint64_t currentFrameCount = _videoPlayer.frameCount;
    BOOL needReprocess = (currentFrameCount != _lastProcessedFrameCount ||
                          origWidth != _lastProcessedWidth ||
                          origHeight != _lastProcessedHeight ||
                          origFormat != _lastProcessedFormat ||
                          _cachedProcessedFrame == NULL);

    if (needReprocess) {
        CVPixelBufferRef replacementFrame = [_videoPlayer copyCurrentFrame];
        if (replacementFrame) {
            CVPixelBufferRef processedFrame = [_gpuProcessor processPixelBuffer:replacementFrame
                                                                        toWidth:origWidth
                                                                        height:origHeight
                                                                        format:origFormat];
            CVPixelBufferRelease(replacementFrame);

            if (processedFrame) {
                if (_cachedProcessedFrame) {
                    CVPixelBufferRelease(_cachedProcessedFrame);
                }
                _cachedProcessedFrame = processedFrame;  // CF_RETURNS_RETAINED, 已 retain
                _lastProcessedFrameCount = currentFrameCount;
                _lastProcessedWidth = origWidth;
                _lastProcessedHeight = origHeight;
                _lastProcessedFormat = origFormat;
                if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d REPROCESS fc=%llu %zux%zu fmt=0x%x", vcamRenderCount, (unsigned long long)currentFrameCount, origWidth, origHeight, (unsigned)origFormat]);
            } else {
                if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d processPixelBuffer FAILED", vcamRenderCount]);
            }
        }
    }

    // 4. 用缓存的 processedFrame 写入相机帧（快路径: writeFrame 只 memcpy）
    if (_cachedProcessedFrame) {
        [self writeFrame:_cachedProcessedFrame toPixelBuffer:pixelBuffer];
        [self cacheLastRenderedFrame:_cachedProcessedFrame width:origWidth height:origHeight];
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d OK wrote frame %zux%zu (cached)", vcamRenderCount, origWidth, origHeight]);
        _frameCount++;
        return;
    }

    // 5. 没有缓存帧，用 liveBGRAPixelBuffer/liveYUVPixelBuffer 回退
    if (origFormat == kCVPixelFormatType_32BGRA && _liveBGRAPixelBuffer) {
        [self writeFrame:_liveBGRAPixelBuffer toPixelBuffer:pixelBuffer];
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d cache BGRA", vcamRenderCount]);
        return;
    }
    if (_liveYUVPixelBuffer) {
        [self writeFrame:_liveYUVPixelBuffer toPixelBuffer:pixelBuffer];
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d cache YUV", vcamRenderCount]);
        return;
    }
    if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d NO frame no cache", vcamRenderCount]);
}

- (BOOL)hasReplacementFrame {
    if (!_enabled) return NO;
    CVPixelBufferRef frame = [_videoPlayer getCurrentFrame];
    return frame != NULL;
}

- (void)clearReplacementFrame {
    [_processLock lock];
    if (_liveBGRAPixelBuffer) {
        CVPixelBufferRelease(_liveBGRAPixelBuffer);
        _liveBGRAPixelBuffer = NULL;
    }
    if (_liveYUVPixelBuffer) {
        CVPixelBufferRelease(_liveYUVPixelBuffer);
        _liveYUVPixelBuffer = NULL;
    }
    if (_cachedProcessedFrame) {
        CVPixelBufferRelease(_cachedProcessedFrame);
        _cachedProcessedFrame = NULL;
    }
    _lastProcessedFrameCount = 0;
    _lastProcessedWidth = 0;
    _lastProcessedHeight = 0;
    _lastProcessedFormat = 0;
    _targetSizeKnown = NO;
    _targetWidth = 0;
    _targetHeight = 0;
    _targetFormat = 0;
    [_formatLockMap removeAllObjects];
    [_processLock unlock];
    vcam_core_log(@"[vcam] Replacement frame cleared, real camera restored");
}

- (void)cacheLastRenderedFrame:(CVPixelBufferRef)buffer width:(size_t)width height:(size_t)height {
    if (!buffer) return;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);

    [_processLock lock];
    if (format == kCVPixelFormatType_32BGRA) {
        if (_liveBGRAPixelBuffer) {
            CVPixelBufferRelease(_liveBGRAPixelBuffer);
        }
        _liveBGRAPixelBuffer = buffer;
        CVPixelBufferRetain(_liveBGRAPixelBuffer);
    } else {
        if (_liveYUVPixelBuffer) {
            CVPixelBufferRelease(_liveYUVPixelBuffer);
        }
        _liveYUVPixelBuffer = buffer;
        CVPixelBufferRetain(_liveYUVPixelBuffer);
    }
    _lastRenderedWidth = width;
    _lastRenderedHeight = height;
    [_processLock unlock];
}

- (BOOL)isSupportedVideoFormat:(CVPixelBufferRef)buffer {
    if (!buffer) return NO;
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    // 格式白名单: BGRA, 420v, 420f, |xv0(视频录制预览), p420(视频录制预览)
    // Theos SDK 缺少 kCVPixelFormatType_420YpCbCr8VideoRange/FullRange 声明，用 FourCC 码代替
    // |xv0 = 0x7c787630 planar YUV 双平面(视频模式预览流), p420 = 0x70343230 3-plane YUV
    return format == kCVPixelFormatType_32BGRA  // BGRA
        || format == '420v'                      // 420v (VideoRange)
        || format == '420f'                      // 420f (FullRange)
        || format == '|xv0'                      // |xv0 (视频录制预览流, planar YUV)
        || format == 'p420';                     // p420 (视频录制预览流, 3-plane YUV)
}

#pragma mark - 帧写入

- (void)writeFrame:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    if (!src || !dst) return;

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    OSType srcFormat = CVPixelBufferGetPixelFormatType(src);
    OSType dstFormat = CVPixelBufferGetPixelFormatType(dst);

    // 路径1：格式和尺寸都匹配 → 直接 memcpy（最快）
    if (srcFormat == dstFormat && srcW == dstW && srcH == dstH) {
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dst, 0);

        void *srcBase = CVPixelBufferGetBaseAddress(src);
        void *dstBase = CVPixelBufferGetBaseAddress(dst);
        size_t srcSize = CVPixelBufferGetDataSize(src);
        size_t dstSize = CVPixelBufferGetDataSize(dst);

        if (srcBase && dstBase) {
            size_t copySize = MIN(srcSize, dstSize);
            memcpy(dstBase, srcBase, copySize);
        }

        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return;
    }

    // 路径2：VTPixelTransferSession 转换
    if ([_gpuProcessor transferPixelBuffer:src toPixelBuffer:dst]) {
        return;
    }

    // 路径3：CoreImage 渲染（回退）
    @try {
        CIImage *image = [CIImage imageWithCVPixelBuffer:src];
        if (image && _ciContext) {
            [_ciContext render:image toCVPixelBuffer:dst];
            return;
        }
    } @catch (NSException *e) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] CoreImage render failed: %@", e]);
    }

    // 路径4：所有方法都失败 → 保持原始相机帧（不显示黑屏）
    // 不做任何操作，让原始相机帧通过
}

#pragma mark - 状态控制

- (void)setEnabled:(BOOL)enabled {
    [_processLock lock];
    if (_enabled == enabled) {
        // enable→enable (no reload) / disable→disable (no action)
        [_processLock unlock];
        return;
    }
    [_processLock unlock];

    if (enabled) {
        // disable→enable: 加载视频
        NSString *path = [VCamNotify activePlaybackPath];
        if (!path || path.length == 0) {
            path = @"/var/mobile/Media/DCIM/vcam.mp4";
        }
        vcam_core_log([NSString stringWithFormat:@"[vcam] readActivePlaybackPath -> %@", path]);

        __weak typeof(self) weakSelf = self;
        [_videoPlayer loadVideoAtPath:path completion:^(BOOL success, NSError *error) {
            if (success) {
                vcam_core_log(@"[vcam] Live state set to: enabled");
                [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
            } else {
                vcam_core_log([NSString stringWithFormat:@"[vcam] Failed to load video: %@", error]);
            }
        }];
        [_videoPlayer startWatchingFile:path];

        [_processLock lock];
        _enabled = YES;
        [_processLock unlock];
        vcam_core_log(@"[vcam] Live state changed to: enabled");
    } else {
        // enable→disable: 停止解码
        [_videoPlayer stopDecodingThread];
        [_videoPlayer stopWatchingFile];
        [self clearReplacementFrame];

        [_processLock lock];
        _enabled = NO;
        [_processLock unlock];
        vcam_core_log(@"[vcam] Live state changed to: disabled");
        [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
    }
}

#pragma mark - plist 轮询

- (void)startStatePolling {
    if (_pollingActive) return;
    _pollingActive = YES;
    vcam_core_log(@"[vcam] State polling timer started");

    __weak typeof(self) weakSelf = self;
    [[VCamNotify sharedInstance] startPollingWithInterval:1.0 callback:^(BOOL enabled) {
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        static int vcamCorePollCount = 0;
        vcamCorePollCount++;
        if (vcamCorePollCount % 5 == 1) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] core poll#%d enabled=%d lastEnabled=%d", vcamCorePollCount, enabled, strongSelf.lastEnabledState]);
        }
        if (enabled != strongSelf.lastEnabledState) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] state change: %d -> %d, calling setEnabled", strongSelf.lastEnabledState, enabled]);
            strongSelf.lastEnabledState = enabled;
            [strongSelf setEnabled:enabled];
        }
    }];
}

- (void)stopStatePolling {
    [[VCamNotify sharedInstance] stopPolling];
    _pollingActive = NO;
}

@end
