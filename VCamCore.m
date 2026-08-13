#import "VCamCore.h"
#import "GPUImageProcessor.h"
#import "LocalVideoPlayer.h"
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreGraphics/CoreGraphics.h>

// 对标 vcameracrack 的 VCamCore
// 关键改进（基于逆向分析）：
// 1. 文件路径用 /var/mobile/Media/DCIM/（不是 /tmp/）
// 2. 格式白名单：只处理 BGRA/420v/420f
// 3. 双格式预渲染：同时维护 BGRA 和 YUV 缓冲区
// 4. 缓冲池减少分配开销
// 5. plist 轮询 + Darwin 通知双通道状态控制

static NSString *const kVideoPath  = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kPlistPath  = @"/var/mobile/Media/DCIM/vc.plist";
static NSString *const kNotifyReload = @"com.vcam.ios.media.reload";

// 文件日志（mediaserverd 中 NSLog 不可见）
static volatile int32_t vcamLogCount = 0;
static void vcam_core_log(NSString *msg) {
    int32_t n = __sync_add_and_fetch(&vcamLogCount, 1);
    if (n > 200) return;
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
@property (nonatomic, strong) dispatch_queue_t prerenderQueue;
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) NSLock *processLock;

// 双格式预渲染缓冲区
@property (nonatomic, assign) CVPixelBufferRef liveBGRAPixelBuffer;
@property (nonatomic, assign) CVPixelBufferRef liveYUVPixelBuffer;

// 预分配缓冲区（减少运行时分配）
@property (nonatomic, assign) CVPixelBufferRef preallocBGRABuffer;
@property (nonatomic, assign) CVPixelBufferRef preallocYUV420fBuffer;
@property (nonatomic, assign) CVPixelBufferRef preallocYUV420vBuffer;

// CIContext（软件渲染）
@property (nonatomic, strong) CIContext *ciContext;

// 帧计数（诊断用）
@property (nonatomic, assign) int32_t frameCount;
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
        _prerenderQueue = dispatch_queue_create("com.vcam.prerender", DISPATCH_QUEUE_SERIAL);
        _processingQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        _processLock = [[NSLock alloc] init];
        _isPixelBufferMode = YES;
        _liveBGRAPixelBuffer = NULL;
        _liveYUVPixelBuffer = NULL;
        _preallocBGRABuffer = NULL;
        _preallocYUV420fBuffer = NULL;
        _preallocYUV420vBuffer = NULL;

        // GPU/CIContext 初始化
        @try {
            _gpuProcessor = [[GPUImageProcessor alloc] init];
        } @catch (NSException *e) {
            _gpuProcessor = nil;
        }
        @try {
            _ciContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _ciContext = nil;
        }

        _enabled = NO;
        vcam_core_log(@"[VCamCore] initialized with multi-format buffer pools (vcamplus style)");

        [self loadState];

        // 启动状态轮询（plist 轮询，不用 Darwin 通知避免崩溃）
        [self startConfigPolling];

        // 启动预渲染线程
        [self startPrerenderThread];
    }
    return self;
}

#pragma mark - 格式白名单

- (BOOL)isSupportedVideoFormat:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return NO;
    OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
    // 只支持 BGRA, 420v, 420f（对标 vcameracrack）
    return (fmt == kCVPixelFormatType_32BGRA ||
            fmt == kCVPixelFormatType_420YpCbCr8VideoRange ||
            fmt == kCVPixelFormatType_420YpCbCr8FullRange);
}

#pragma mark - 状态轮询（plist 轮询，每秒检查 enabled 变化）

- (void)startConfigPolling {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        while (YES) {
            @autoreleasepool {
                @try {
                    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
                    if (config) {
                        BOOL newEnabled = [config[@"enabled"] boolValue];
                        if (newEnabled != strongSelf.enabled) {
                            vcam_core_log([NSString stringWithFormat:@"[Poll] Live state changed to: %@", newEnabled ? @"YES" : @"NO"]);
                            [strongSelf loadState];
                        }
                    }
                } @catch (NSException *e) {}
            }
            [NSThread sleepForTimeInterval:1.0];
        }
    });
}

#pragma mark - 状态加载

- (void)loadState {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
    if (!config) {
        _enabled = NO;
        return;
    }

    BOOL oldEnabled = _enabled;
    BOOL newEnabled = [config[@"enabled"] boolValue];
    NSString *videoPath = config[@"videoPath"];
    if (videoPath.length > 0) {
        _currentVideoPath = videoPath;
    } else {
        _currentVideoPath = kVideoPath;
    }

    // 旋转/镜像
    NSInteger newRotation = [config[@"rotationAngle"] integerValue];
    BOOL newMirrored = [config[@"mirrored"] boolValue];
    if (_gpuProcessor) {
        _gpuProcessor.rotationAngle = newRotation;
        _gpuProcessor.mirrored = newMirrored;
    }

    if (newEnabled && !oldEnabled) {
        // 禁用→启用：加载视频
        if (![fm fileExistsAtPath:_currentVideoPath]) {
            vcam_core_log([NSString stringWithFormat:@"[VCamCore] Video file not found: %@", _currentVideoPath]);
            _enabled = NO;
            return;
        }
        _enabled = YES;
        @try {
            LocalVideoPlayer *player = [LocalVideoPlayer sharedInstance];
            BOOL ok = [player loadVideoAtPath:_currentVideoPath];
            if (ok) {
                [player prefillFrameQueue];
                [player startDecodingThread];
                self.isConnected = YES;
                vcam_core_log(@"[VCamCore] Video loaded and decoding started");
            }
        } @catch (NSException *e) {
            vcam_core_log([NSString stringWithFormat:@"[VCamCore] Load exception: %@", e]);
        }
    } else if (newEnabled && oldEnabled) {
        // 已启用→仍启用：不重载
        _enabled = YES;
    } else if (!newEnabled && oldEnabled) {
        // 启用→禁用：停止解码，恢复原相机
        _enabled = NO;
        [self clearReplacementFrame];
        _isConnected = NO;
        _targetSizeKnown = NO;
        @try {
            [[LocalVideoPlayer sharedInstance] stopDecodingThread];
        } @catch (NSException *e) {}
        vcam_core_log(@"[VCamCore] Replacement frame cleared, real camera restored");
    } else {
        _enabled = NO;
    }
}

- (void)reloadMediaFromConfig {
    [self loadState];
}

#pragma mark - 预渲染线程

- (void)startPrerenderThread {
    __weak typeof(self) weakSelf = self;
    dispatch_async(_prerenderQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        while (YES) {
            @autoreleasepool {
                @try {
                    if (!strongSelf.enabled) {
                        // 清理预渲染缓冲
                        CVPixelBufferRef oldBGRA = strongSelf.liveBGRAPixelBuffer;
                        strongSelf.liveBGRAPixelBuffer = NULL;
                        if (oldBGRA) CVPixelBufferRelease(oldBGRA);
                        CVPixelBufferRef oldYUV = strongSelf.liveYUVPixelBuffer;
                        strongSelf.liveYUVPixelBuffer = NULL;
                        if (oldYUV) CVPixelBufferRelease(oldYUV);
                        [NSThread sleepForTimeInterval:0.5];
                        continue;
                    }

                    if (!strongSelf.targetSizeKnown) {
                        [NSThread sleepForTimeInterval:0.05];
                        continue;
                    }

                    // 从解码器获取 BGRA 帧
                    CVPixelBufferRef decoderFrame = [[LocalVideoPlayer sharedInstance] copyCurrentFrame];
                    if (!decoderFrame) {
                        [NSThread sleepForTimeInterval:0.016];
                        continue;
                    }

                    size_t w = strongSelf.targetWidth;
                    size_t h = strongSelf.targetHeight;

                    // 处理到 BGRA 缓冲区（旋转/镜像/缩放）
                    if (!strongSelf.preallocBGRABuffer ||
                        CVPixelBufferGetWidth(strongSelf.preallocBGRABuffer) != w ||
                        CVPixelBufferGetHeight(strongSelf.preallocBGRABuffer) != h) {
                        if (strongSelf.preallocBGRABuffer) {
                            CVPixelBufferRelease(strongSelf.preallocBGRABuffer);
                        }
                        // CRITICAL: 不使用 IOSurface 属性
                        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, NULL, &strongSelf.preallocBGRABuffer);
                    }

                    if (strongSelf.preallocBGRABuffer && strongSelf.gpuProcessor) {
                        [strongSelf.gpuProcessor processPixelBuffer:decoderFrame
                                                             toBuffer:strongSelf.preallocBGRABuffer
                                                               toWidth:w
                                                              toHeight:h
                                                                format:kCVPixelFormatType_32BGRA];

                        // 原子发布 BGRA 帧
                        CVPixelBufferRef oldBGRA = strongSelf.liveBGRAPixelBuffer;
                        CVPixelBufferRetain(strongSelf.preallocBGRABuffer);
                        strongSelf.liveBGRAPixelBuffer = strongSelf.preallocBGRABuffer;
                        if (oldBGRA) CVPixelBufferRelease(oldBGRA);

                        // 如果目标格式是 YUV，同时预渲染 YUV 帧
                        if (strongSelf.targetFormat == kCVPixelFormatType_420YpCbCr8VideoRange ||
                            strongSelf.targetFormat == kCVPixelFormatType_420YpCbCr8FullRange) {

                            if (!strongSelf.preallocYUV420fBuffer ||
                                CVPixelBufferGetWidth(strongSelf.preallocYUV420fBuffer) != w ||
                                CVPixelBufferGetHeight(strongSelf.preallocYUV420fBuffer) != h) {
                                if (strongSelf.preallocYUV420fBuffer) {
                                    CVPixelBufferRelease(strongSelf.preallocYUV420fBuffer);
                                }
                                CVPixelBufferCreate(kCFAllocatorDefault, w, h, strongSelf.targetFormat, NULL, &strongSelf.preallocYUV420fBuffer);
                            }

                            if (strongSelf.preallocYUV420fBuffer && strongSelf.gpuProcessor.pixelTransferSession) {
                                OSStatus xferStatus = VTPixelTransferSessionTransferImage(
                                    strongSelf.gpuProcessor.pixelTransferSession,
                                    strongSelf.preallocBGRABuffer,
                                    strongSelf.preallocYUV420fBuffer);
                                if (xferStatus == noErr) {
                                    CVPixelBufferRef oldYUV = strongSelf.liveYUVPixelBuffer;
                                    CVPixelBufferRetain(strongSelf.preallocYUV420fBuffer);
                                    strongSelf.liveYUVPixelBuffer = strongSelf.preallocYUV420fBuffer;
                                    if (oldYUV) CVPixelBufferRelease(oldYUV);
                                }
                            }
                        }

                        int32_t fc = __sync_add_and_fetch(&strongSelf.frameCount, 1);
                        if (fc <= 3) {
                            vcam_core_log(@"[VCamCore] Prerendered frame OK");
                        }
                    }
                    CVPixelBufferRelease(decoderFrame);
                } @catch (NSException *e) {
                    vcam_core_log([NSString stringWithFormat:@"[VCamCore] Prerender exception: %@", e]);
                }
            }
            [NSThread sleepForTimeInterval:0.033]; // ~30fps
        }
    });
}

#pragma mark - 核心替换方法（hook 函数调用）

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)origPixelBuffer {
    if (!_enabled || !_isPixelBufferMode || !origPixelBuffer) return;

    // 格式白名单检查
    if (![self isSupportedVideoFormat:origPixelBuffer]) return;

    size_t origWidth = CVPixelBufferGetWidth(origPixelBuffer);
    size_t origHeight = CVPixelBufferGetHeight(origPixelBuffer);
    OSType origFormat = CVPixelBufferGetPixelFormatType(origPixelBuffer);

    // 锁定目标尺寸/格式（只处理第一个支持的格式）
    if (!_targetSizeKnown) {
        _targetWidth = origWidth;
        _targetHeight = origHeight;
        _targetFormat = origFormat;
        _targetSizeKnown = YES;
        char fstr[5] = {0};
        fstr[0] = (char)(origFormat >> 24);
        fstr[1] = (char)(origFormat >> 16);
        fstr[2] = (char)(origFormat >> 8);
        fstr[3] = (char)origFormat;
        vcam_core_log([NSString stringWithFormat:@"[VCamCore] Target locked: %zux%zu fmt=0x%x (%s)",
                      origWidth, origHeight, origFormat, fstr]);

        // 配置 GPU 处理器的预处理目标
        if (_gpuProcessor) {
            [_gpuProcessor setPreprocessTargetWidth:origWidth height:origHeight];
        }
    }

    // 跳过与锁定格式不同的帧
    if (origWidth != _targetWidth || origHeight != _targetHeight || origFormat != _targetFormat) {
        return;
    }

    // 根据目标格式选择预渲染缓冲区
    CVPixelBufferRef prerendered = NULL;
    if (origFormat == kCVPixelFormatType_32BGRA) {
        prerendered = _liveBGRAPixelBuffer;
    } else {
        // YUV 格式优先用 YUV 预渲染帧，回退到 BGRA
        prerendered = _liveYUVPixelBuffer;
        if (!prerendered) prerendered = _liveBGRAPixelBuffer;
    }

    if (!prerendered) return;
    CVPixelBufferRetain(prerendered);

    size_t repWidth = CVPixelBufferGetWidth(prerendered);
    size_t repHeight = CVPixelBufferGetHeight(prerendered);
    OSType repFormat = CVPixelBufferGetPixelFormatType(prerendered);

    // 路径 1：尺寸和格式都匹配 → 直接 memcpy（快速路径）
    if (repWidth == origWidth && repHeight == origHeight && repFormat == origFormat) {
        @try {
            CVPixelBufferLockBaseAddress(origPixelBuffer, 0);
            CVPixelBufferLockBaseAddress(prerendered, kCVPixelBufferLock_ReadOnly);

            BOOL origPlanar = CVPixelBufferIsPlanar(origPixelBuffer);
            BOOL repPlanar = CVPixelBufferIsPlanar(prerendered);

            if (origPlanar && repPlanar) {
                size_t planeCount = CVPixelBufferGetPlaneCount(origPixelBuffer);
                for (size_t p = 0; p < planeCount; p++) {
                    void *srcBase = CVPixelBufferGetBaseAddressOfPlane(prerendered, p);
                    void *dstBase = CVPixelBufferGetBaseAddressOfPlane(origPixelBuffer, p);
                    size_t srcBPR = CVPixelBufferGetBytesPerRowOfPlane(prerendered, p);
                    size_t dstBPR = CVPixelBufferGetBytesPerRowOfPlane(origPixelBuffer, p);
                    size_t srcH = CVPixelBufferGetHeightOfPlane(prerendered, p);
                    size_t dstH = CVPixelBufferGetHeightOfPlane(origPixelBuffer, p);
                    size_t minH = MIN(srcH, dstH);
                    size_t minBPR = MIN(srcBPR, dstBPR);
                    if (srcBase && dstBase) {
                        for (size_t y = 0; y < minH; y++) {
                            memcpy((uint8_t *)dstBase + y * dstBPR,
                                   (uint8_t *)srcBase + y * srcBPR, minBPR);
                        }
                    }
                }
            } else {
                void *srcBase = CVPixelBufferGetBaseAddress(prerendered);
                void *dstBase = CVPixelBufferGetBaseAddress(origPixelBuffer);
                if (srcBase && dstBase) {
                    size_t srcBPR = CVPixelBufferGetBytesPerRow(prerendered);
                    size_t dstBPR = CVPixelBufferGetBytesPerRow(origPixelBuffer);
                    size_t minHeight = MIN(repHeight, origHeight);
                    size_t minBPR = MIN(srcBPR, dstBPR);
                    for (size_t y = 0; y < minHeight; y++) {
                        memcpy((uint8_t *)dstBase + y * dstBPR,
                               (uint8_t *)srcBase + y * srcBPR, minBPR);
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(prerendered, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(origPixelBuffer, 0);
        } @catch (NSException *e) {}
        CVPixelBufferRelease(prerendered);
        return;
    }

    // 路径 2：格式不匹配 → VTPixelTransferSession 转换（BGRA→YUV）
    if (repFormat == kCVPixelFormatType_32BGRA && _gpuProcessor.pixelTransferSession) {
        OSStatus xferStatus = VTPixelTransferSessionTransferImage(
            _gpuProcessor.pixelTransferSession, prerendered, origPixelBuffer);
        if (xferStatus == noErr) {
            CVPixelBufferRelease(prerendered);
            return;
        }
    }

    // 路径 3：CoreImage 渲染（缩放/转换）
    if (_ciContext) {
        @try {
            CIImage *image = [CIImage imageWithCVPixelBuffer:prerendered];
            if (image) {
                if (repWidth != origWidth || repHeight != origHeight) {
                    CGFloat scaleX = (CGFloat)origWidth / (CGFloat)repWidth;
                    CGFloat scaleY = (CGFloat)origHeight / (CGFloat)repHeight;
                    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];
                }
                CVPixelBufferLockBaseAddress(origPixelBuffer, 0);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                [_ciContext render:image
                     toCVPixelBuffer:origPixelBuffer
                             bounds:CGRectMake(0, 0, origWidth, origHeight)
                         colorSpace:cs];
                CGColorSpaceRelease(cs);
                CVPixelBufferUnlockBaseAddress(origPixelBuffer, 0);
                CVPixelBufferRelease(prerendered);
                return;
            }
        } @catch (NSException *e) {}
    }

    // 路径 4：回退 memcpy（部分替换）
    @try {
        CVPixelBufferLockBaseAddress(origPixelBuffer, 0);
        CVPixelBufferLockBaseAddress(prerendered, kCVPixelBufferLock_ReadOnly);
        void *srcBase = CVPixelBufferGetBaseAddress(prerendered);
        void *dstBase = CVPixelBufferGetBaseAddress(origPixelBuffer);
        if (srcBase && dstBase) {
            size_t srcBPR = CVPixelBufferGetBytesPerRow(prerendered);
            size_t dstBPR = CVPixelBufferGetBytesPerRow(origPixelBuffer);
            size_t minHeight = MIN(repHeight, origHeight);
            size_t minBPR = MIN(srcBPR, dstBPR);
            for (size_t y = 0; y < minHeight; y++) {
                memcpy((uint8_t *)dstBase + y * dstBPR,
                       (uint8_t *)srcBase + y * srcBPR, minBPR);
            }
        }
        CVPixelBufferUnlockBaseAddress(prerendered, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(origPixelBuffer, 0);
    } @catch (NSException *e) {}

    CVPixelBufferRelease(prerendered);
}

#pragma mark - 辅助方法

- (BOOL)hasReplacementFrame {
    return (_liveBGRAPixelBuffer != NULL || _liveYUVPixelBuffer != NULL);
}

- (void)clearReplacementFrame {
    // 清理预渲染缓冲
    CVPixelBufferRef oldBGRA = _liveBGRAPixelBuffer;
    _liveBGRAPixelBuffer = NULL;
    if (oldBGRA) CVPixelBufferRelease(oldBGRA);

    CVPixelBufferRef oldYUV = _liveYUVPixelBuffer;
    _liveYUVPixelBuffer = NULL;
    if (oldYUV) CVPixelBufferRelease(oldYUV);

    // 重置目标尺寸
    _targetSizeKnown = NO;

    // 清理预分配缓冲区
    if (_preallocBGRABuffer) {
        CVPixelBufferRelease(_preallocBGRABuffer);
        _preallocBGRABuffer = NULL;
    }
    if (_preallocYUV420fBuffer) {
        CVPixelBufferRelease(_preallocYUV420fBuffer);
        _preallocYUV420fBuffer = NULL;
    }
    if (_preallocYUV420vBuffer) {
        CVPixelBufferRelease(_preallocYUV420vBuffer);
        _preallocYUV420vBuffer = NULL;
    }
}

- (void)dealloc {
    [self clearReplacementFrame];
}

@end
