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
@property (nonatomic, assign) BOOL prerenderActive;
// 多格式预渲染: 每种格式对应尺寸的 BGRA buffer（key=FourCC NSNumber, value=__bridge CVPixelBufferRef）
@property (nonatomic, strong) NSMutableDictionary *liveBGRAMap;
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
        _prerenderActive = NO;
        _liveBGRAMap = [[NSMutableDictionary alloc] init];

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

    // 2. 多格式锁定: key="format_w_h"（允许同格式不同尺寸，如 420f 1080x2340 和 420f 1440x1080）
    NSString *fmtKey = [NSString stringWithFormat:@"%u_%zu_%zu", (unsigned)origFormat, origWidth, origHeight];
    if (!_formatLockMap[fmtKey]) {
        char fstr[5] = {0};
        fstr[0] = (char)(origFormat >> 24);
        fstr[1] = (char)(origFormat >> 16);
        fstr[2] = (char)(origFormat >> 8);
        fstr[3] = (char)origFormat;
        vcam_core_log([NSString stringWithFormat:@"[vcam] Format locked: %zux%zu fmt=0x%x (%s)",
                       origWidth, origHeight, (unsigned)origFormat, fstr]);
        _formatLockMap[fmtKey] = @YES;
        _targetWidth = origWidth;
        _targetHeight = origHeight;
        _targetFormat = origFormat;
        _targetSizeKnown = YES;
    }
    // key 已包含尺寸，不需要检查 mismatch

    // 3. 用预渲染的 liveBGRAMap 取对应 format+w+h 的 420f buffer
    [_processLock lock];
    id bgraObj = _liveBGRAMap[fmtKey];
    if (!bgraObj) bgraObj = _liveBGRAMap[@(0)];  // 回退到原始尺寸
    if (bgraObj) CFRetain((__bridge CFTypeRef)bgraObj);
    [_processLock unlock];

    if (bgraObj) {
        CVPixelBufferRef liveBGRA = (__bridge CVPixelBufferRef)bgraObj;
        size_t liveW = CVPixelBufferGetWidth(liveBGRA);
        size_t liveH = CVPixelBufferGetHeight(liveBGRA);
        if (liveW == origWidth && liveH == origHeight) {
            // 尺寸匹配：writeFrame 处理格式转换（memcpy/VTPixelTransferSession/CoreImage）
            [self writeFrame:liveBGRA toPixelBuffer:pixelBuffer];
            [self cacheLastRenderedFrame:liveBGRA width:origWidth height:origHeight];
            if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d OK wrote frame %zux%zu (prerendered)", vcamRenderCount, origWidth, origHeight]);
            CFRelease((__bridge CFTypeRef)bgraObj);
            _frameCount++;
            return;
        } else {
            // 尺寸不匹配：实时缩放 + 格式转换
            CVPixelBufferRef processedFrame = [_gpuProcessor processPixelBuffer:liveBGRA toWidth:origWidth height:origHeight format:origFormat];
            if (processedFrame) {
                [self writeFrame:processedFrame toPixelBuffer:pixelBuffer];
                [self cacheLastRenderedFrame:processedFrame width:origWidth height:origHeight];
                CVPixelBufferRelease(processedFrame);
                if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d OK wrote frame %zux%zu (live resize)", vcamRenderCount, origWidth, origHeight]);
                CFRelease((__bridge CFTypeRef)bgraObj);
                _frameCount++;
                return;
            }
        }
        CFRelease((__bridge CFTypeRef)bgraObj);
    }

    // 4. 没有预渲染帧，用 _liveBGRAPixelBuffer/liveYUVPixelBuffer 回退
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
    [self stopPrerenderThread];
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
    [_liveBGRAMap removeAllObjects];
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
    // 逆向白名单: 只有 BGRA, 420v, 420f（不处理 |xv0/p420 等私有格式，让系统自行编码）
    return format == kCVPixelFormatType_32BGRA  // BGRA
        || format == '420v'                      // 420v (VideoRange)
        || format == '420f';                      // 420f (FullRange)
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

    // 路径1：格式和尺寸都匹配 且 非planar(BGRA) → 直接 memcpy（最快）
    // planar 格式(420f/420v)的预渲染buffer和相机帧 bpr 可能不同(padding/alignment), memcpy 会错位, 用 VTPixelTransferSession
    if (srcFormat == dstFormat && srcW == dstW && srcH == dstH && CVPixelBufferGetPlaneCount(src) == 0) {
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

#pragma mark - 预渲染线程

- (void)startPrerenderThread {
    if (_prerenderActive) return;
    _prerenderActive = YES;
    vcam_core_log(@"[vcam] Prerender thread started");
    __weak typeof(self) weakSelf = self;
    dispatch_async(_prerenderQueue, ^{
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        while (strongSelf.prerenderActive && strongSelf.enabled) {
            @autoreleasepool {
                CVPixelBufferRef frame = [strongSelf.videoPlayer copyCurrentFrame];
                if (!frame) {
                    [NSThread sleepForTimeInterval:0.005];
                    continue;
                }

                // 多格式预渲染：遍历 formatLockMap，为每种格式产出对应尺寸的 BGRA
                [strongSelf.processLock lock];
                NSDictionary *formatMap = [strongSelf.formatLockMap copy];
                [strongSelf.processLock unlock];

                if (formatMap.count == 0) {
                    // 还没遇到相机帧，用视频原始尺寸，产出 BGRA
                    size_t vw = CVPixelBufferGetWidth(frame);
                    size_t vh = CVPixelBufferGetHeight(frame);
                    CVPixelBufferRef processed = [strongSelf.gpuProcessor scaleToBGRA:frame width:vw height:vh];
                    if (processed) {
                        [strongSelf.processLock lock];
                        strongSelf.liveBGRAMap[@(0)] = (__bridge_transfer id)processed;
                        [strongSelf.processLock unlock];
                    }
                } else {
                    // formatLockMap key = "format_w_h"，统一产出 BGRA（最快, writeFrame 做 BGRA→目标格式）
                    for (NSString *key in formatMap) {
                        NSArray *parts = [key componentsSeparatedByString:@"_"];
                        if (parts.count != 3) continue;
                        size_t w = (size_t)[parts[1] integerValue];
                        size_t h = (size_t)[parts[2] integerValue];

                        CVPixelBufferRef processed = [strongSelf.gpuProcessor scaleToBGRA:frame width:w height:h];
                        if (processed) {
                            [strongSelf.processLock lock];
                            strongSelf.liveBGRAMap[key] = (__bridge_transfer id)processed;
                            [strongSelf.processLock unlock];
                        }
                    }
                }

                CVPixelBufferRelease(frame);

                // 按视频帧率等待
                double fps = strongSelf.videoPlayer.videoFps > 1.0 ? strongSelf.videoPlayer.videoFps : 30.0;
                [NSThread sleepForTimeInterval:1.0 / fps];
            }
        }
        vcam_core_log(@"[vcam] Prerender thread exited");
    });
}

- (void)stopPrerenderThread {
    _prerenderActive = NO;
    vcam_core_log(@"[vcam] Prerender thread stopped");
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
        [self startPrerenderThread];

        [_processLock lock];
        _enabled = YES;
        [_processLock unlock];
        vcam_core_log(@"[vcam] Live state changed to: enabled");
    } else {
        // enable→disable: 停止解码
        [self stopPrerenderThread];
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
