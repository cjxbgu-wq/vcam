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

    // 1. 格式白名单检查
    if (![self isSupportedVideoFormat:pixelBuffer]) return;

    // 2. 格式锁定：只处理第一个遇到的格式
    if (!_targetSizeKnown) {
        char fstr[5] = {0};
        fstr[0] = (char)(origFormat >> 24);
        fstr[1] = (char)(origFormat >> 16);
        fstr[2] = (char)(origFormat >> 8);
        fstr[3] = (char)origFormat;
        vcam_core_log([NSString stringWithFormat:@"[vcam] Initial Live state: %@",
                       [NSString stringWithFormat:@"target locked %zux%zu fmt=0x%x (%s)",
                        origWidth, origHeight, origFormat, fstr]]);
        _targetWidth = origWidth;
        _targetHeight = origHeight;
        _targetFormat = origFormat;
        _targetSizeKnown = YES;
    }

    // 跳过与锁定格式+尺寸不同的帧（防止相机多流交替导致 buffer mismatch 崩溃）
    if (origWidth != _targetWidth || origHeight != _targetHeight || origFormat != _targetFormat) {
        return;
    }

    // 3. 获取替换帧
    CVPixelBufferRef replacementFrame = [_videoPlayer copyCurrentFrame];
    if (!replacementFrame) {
        // 没有可用帧，使用缓存的帧
        if (origFormat == kCVPixelFormatType_32BGRA && _liveBGRAPixelBuffer) {
            [self writeFrame:_liveBGRAPixelBuffer toPixelBuffer:pixelBuffer];
            return;
        }
        if (_liveYUVPixelBuffer) {
            [self writeFrame:_liveYUVPixelBuffer toPixelBuffer:pixelBuffer];
            return;
        }
        return;  // 没有缓存帧，保持原始相机
    }

    // 4. 处理帧（旋转/镜像/缩放/格式转换）
    CVPixelBufferRef processedFrame = [_gpuProcessor processPixelBuffer:replacementFrame
                                                                toWidth:origWidth
                                                                height:origHeight
                                                                format:origFormat];
    CVPixelBufferRelease(replacementFrame);

    if (!processedFrame) {
        // 处理失败，使用缓存帧或保持原始相机
        return;
    }

    // 5. 写入目标 pixelBuffer
    [self writeFrame:processedFrame toPixelBuffer:pixelBuffer];

    // 6. 缓存最后渲染的帧
    [self cacheLastRenderedFrame:processedFrame width:origWidth height:origHeight];
    CVPixelBufferRelease(processedFrame);

    _frameCount++;
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
    _targetSizeKnown = NO;
    _targetWidth = 0;
    _targetHeight = 0;
    _targetFormat = 0;
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
    // 格式白名单（逆向确认）：BGRA, 420v, 420f
    // Theos SDK 缺少 kCVPixelFormatType_420YpCbCr8VideoRange/FullRange 声明，用 FourCC 码代替
    return format == kCVPixelFormatType_32BGRA  // BGRA
        || format == '420v'                      // 420v (VideoRange)
        || format == '420f';                     // 420f (FullRange)
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
