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
// writeFrame 专用锁: VT session/CIContext 非线程安全, 多 hook 线程(预览/照片/视频节点)并发调用会输出黑帧/崩溃
@property (nonatomic, strong) NSLock *renderLock;
// 无帧回退缓存(对齐千面 _0x150/_0x158/_0x160): 视频解码间隙用上一帧填充, 避免闪回相机画面
@property (nonatomic, assign) CVPixelBufferRef fallbackFrame;
@property (nonatomic, assign) size_t fallbackWidth;
@property (nonatomic, assign) size_t fallbackHeight;
// 同帧去重(对齐千面 _0x78/_0x70): 管线同一物理 buffer 连续经过多个消费者,
// 第一次已就地改写, 后续直接跳过(不 retain, 仅指针比较)
@property (nonatomic, assign) CVPixelBufferRef dedupLastBuffer;
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
        _renderLock = [[NSLock alloc] init];
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
        _cachedProcessedFrame = NULL;
        _lastProcessedFrameCount = 0;
        _lastProcessedWidth = 0;
        _lastProcessedHeight = 0;
        _lastProcessedFormat = 0;
        _prerenderActive = NO;

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

    // 同帧去重(对齐千面 0xaed4-0xaee8): 管线同一物理 buffer 连续经过多个消费者时,
    // 第一次已就地改写, 后续消费者拿到的已是假帧数据, 直接跳过节省开销
    if (_dedupLastBuffer == pixelBuffer) return;

    OSType origFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t targetW = CVPixelBufferGetWidth(pixelBuffer);
    size_t targetH = CVPixelBufferGetHeight(pixelBuffer);

    // 诊断: 每 60 帧记录 render 入口
    static int vcamRenderCount = 0;
    vcamRenderCount++;
    BOOL diagThisFrame = (vcamRenderCount % 60 == 1);

    // 1. 取预渲染缓存(视频原尺寸双格式, 等价千面 [player copyCurrentFrame])
    [_processLock lock];
    CVPixelBufferRef bgra = _liveBGRAPixelBuffer;
    if (bgra) CVPixelBufferRetain(bgra);
    CVPixelBufferRef yuv = _liveYUVPixelBuffer;
    if (yuv) CVPixelBufferRetain(yuv);
    [_processLock unlock];

    if (!bgra && !yuv) {
        // 无帧回退(对齐千面 0xb018-0xb05c): 用上一帧缓存(目标尺寸匹配)填充,
        // 视频解码间隙不闪回相机画面
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d NO frame, fallback", vcamRenderCount]);
        [_renderLock lock];
        if (_fallbackFrame && _fallbackWidth == targetW && _fallbackHeight == targetH) {
            [_gpuProcessor transferPixelBuffer:_fallbackFrame toPixelBuffer:pixelBuffer];
        }
        [_renderLock unlock];
        return;
    }

    // 2. 按目标格式选源缓存（对齐千面双格式缓存）:
    //   BGRA 目标 → BGRA 缓存
    //   420v/420f 目标 → YUV(420f) 缓存优先(标准 YUV→YUV 转换最快), 回退 BGRA
    //   私有格式目标(|8v0/-8f0 等) → BGRA 缓存优先(实测 BGRA→私有格式 VT 成功率高)
    CVPixelBufferRef src = NULL;
    if (origFormat == kCVPixelFormatType_32BGRA) {
        src = bgra;
    } else if ([self isPrivateFormat:origFormat]) {
        src = bgra ? bgra : yuv;
    } else {
        src = yuv ? yuv : bgra;
    }

    // 3. 写入相机帧: VT transfer(Trim 保比例 crop fill)主路径。
    //    全格式处理无白名单(对齐千面 0xb0f8-0xb154: 私有格式 |8v0/-8f0/p420 也 transfer,
    //    这正是千面能替换视频模式预览和拍照保存的原因), 失败保留原相机帧
    BOOL ok = [self writeFrame:src toPixelBuffer:pixelBuffer];
    if (ok) {
        _frameCount++;
        if (diagThisFrame) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d OK %zux%zu fmt=0x%x via %@",
                           vcamRenderCount, targetW, targetH, (unsigned)origFormat,
                           (src == bgra) ? @"BGRA" : @"YUV"]);
        }
        // 缓存回退帧 + 同帧去重(对齐千面 0xb15c-0xb19c)
        [_renderLock lock];
        if (_fallbackFrame) CVPixelBufferRelease(_fallbackFrame);
        _fallbackFrame = src;
        CVPixelBufferRetain(_fallbackFrame);
        _fallbackWidth = targetW;
        _fallbackHeight = targetH;
        [_renderLock unlock];
        _dedupLastBuffer = pixelBuffer;
    } else if (diagThisFrame) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d FAILED write fmt=0x%x, keep camera", vcamRenderCount, (unsigned)origFormat]);
    }

    if (bgra) CVPixelBufferRelease(bgra);
    if (yuv) CVPixelBufferRelease(yuv);
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
    [_processLock unlock];
    // 清理回退缓存 + 去重指针
    [_renderLock lock];
    if (_fallbackFrame) {
        CVPixelBufferRelease(_fallbackFrame);
        _fallbackFrame = NULL;
    }
    _fallbackWidth = 0;
    _fallbackHeight = 0;
    _dedupLastBuffer = NULL;
    [_renderLock unlock];
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

// 私有格式判断(选转换源用): 私有目标优先用 BGRA 源(实测 BGRA->私有格式 VT 成功率高)
// 注意: 千面 render 无白名单, 所有格式都 transfer —— 此方法仅用于选源, 不过滤
- (BOOL)isPrivateFormat:(OSType)format {
    return !(format == kCVPixelFormatType_32BGRA || format == '420v' || format == '420f');
}

#pragma mark - 帧写入

// 对齐逆向: VT transfer(Trim 保比例 crop fill 缩放+格式转换) 主路径
// 失败回退 CoreImage crop fill(仅标准格式), 再失败保留原相机帧(绝不输出未初始化 buffer 防绿屏)
- (BOOL)writeFrame:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    if (!src || !dst) return NO;

    static int vcamWriteCount = 0;
    vcamWriteCount++;
    BOOL diag = (vcamWriteCount % 300 == 1);
    if (diag) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT begin %zux%zu(0x%x) -> %zux%zu(0x%x)",
                       vcamWriteCount,
                       CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), (unsigned)CVPixelBufferGetPixelFormatType(src),
                       CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst), (unsigned)CVPixelBufferGetPixelFormatType(dst)]);
    }

    // 路径1+2 加锁: pixelTransferSession/renderContext 非线程安全,
    // BWNodeOutput/照片/视频多个 hook 节点在不同线程并发调用 writeFrame 会输出黑帧/崩溃
    [_renderLock lock];
    BOOL done = NO;

    // 路径1: VTPixelTransferSession（任意尺寸+格式组合, CropSourceToCleanAperture 自动 crop fill）
    @try {
        if ([_gpuProcessor transferPixelBuffer:src toPixelBuffer:dst]) {
            if (diag) vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT ok", vcamWriteCount]);
            done = YES;
        }
    } @catch (NSException *e) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT exception: %@", vcamWriteCount, e]);
    }

    // 路径2: CoreImage crop fill 渲染（回退, 仅标准格式 —— CI 软件渲染器对私有 planar
    // 格式不可靠, 可能留下未初始化数据导致绿屏）
    if (!done && ![self isPrivateFormat:CVPixelBufferGetPixelFormatType(dst)]) {
        @try {
            if ([_gpuProcessor renderCropFill:src toPixelBuffer:dst]) {
                if (diag) vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d CI ok (fallback)", vcamWriteCount]);
                done = YES;
            }
        } @catch (NSException *e) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d renderCropFill exception: %@", vcamWriteCount, e]);
        }
    }

    [_renderLock unlock];
    if (done) return YES;

    // 路径3: 同格式同尺寸非 planar memcpy（最后手段）
    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    if (CVPixelBufferGetPixelFormatType(src) == CVPixelBufferGetPixelFormatType(dst) &&
        srcW == dstW && srcH == dstH && CVPixelBufferGetPlaneCount(src) == 0) {
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dst, 0);
        void *srcBase = CVPixelBufferGetBaseAddress(src);
        void *dstBase = CVPixelBufferGetBaseAddress(dst);
        if (srcBase && dstBase) {
            memcpy(dstBase, srcBase, MIN(CVPixelBufferGetDataSize(src), CVPixelBufferGetDataSize(dst)));
            CVPixelBufferUnlockBaseAddress(dst, 0);
            CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            return YES;
        }
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    }

    // 全部失败: 保留原始相机帧（不显示黑屏/绿屏）
    return NO;
}

#pragma mark - 预渲染线程

// 对齐逆向: 只产出视频原尺寸(旋转后互换)的 BGRA + 420f 双格式缓存
// render 时由 VTPixelTransferSession(CropSourceToCleanAperture) 一步完成 crop fill 缩放+格式转换
// (不再按相机帧格式做多尺寸缩放 —— 那会导致比例失真/性能差/未初始化 buffer 绿闪)
- (void)startPrerenderThread {
    if (_prerenderActive) return;
    _prerenderActive = YES;
    vcam_core_log(@"[vcam] Prerender thread started (native-size dual-format)");
    __weak typeof(self) weakSelf = self;
    dispatch_async(_prerenderQueue, ^{
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;

        // 绝对时间节拍器: 累计节拍(nextTick += interval), 消除 sleep 精度导致的累计漂移(卡顿/跳帧)
        CFAbsoluteTime nextTick = CFAbsoluteTimeGetCurrent();
        uint64_t renderedFrames = 0;
        static uint64_t prerenderLogSeq = 0;

        while (strongSelf.prerenderActive && strongSelf.enabled) {
            @autoreleasepool {
                double fps = strongSelf.videoPlayer.videoFps > 1.0 ? strongSelf.videoPlayer.videoFps : 30.0;
                nextTick += 1.0 / fps;
                double wait = nextTick - CFAbsoluteTimeGetCurrent();
                if (wait > 0.0005) {
                    [NSThread sleepForTimeInterval:wait];
                } else {
                    nextTick = CFAbsoluteTimeGetCurrent();  // 已落后(转换耗时超帧间隔), 重置基线
                }

                // 消费式取帧: 跟随解码节拍, 无积压; 队列空(解码间隙/图片模式)回退当前帧
                CVPixelBufferRef frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                if (!frame) {
                    frame = [strongSelf.videoPlayer copyCurrentFrame];
                }
                if (!frame) {
                    continue;
                }

                // 1. 旋转/镜像（如需要, 视频原尺寸）
                CVPixelBufferRef rotated = [strongSelf.gpuProcessor rotateAndMirrorIfNeeded:frame];
                CVPixelBufferRelease(frame);
                if (!rotated) continue;

                // 2. YUV 版本（同尺寸 420f, VT 转换）
                CVPixelBufferRef yuv = [strongSelf.gpuProcessor convertFormat:rotated toFormat:'420f'];

                // 3. 完整产出后才替换缓存（避免半成品被 render 读到）
                [strongSelf.processLock lock];
                if (strongSelf->_liveBGRAPixelBuffer) {
                    CVPixelBufferRelease(strongSelf->_liveBGRAPixelBuffer);
                }
                strongSelf->_liveBGRAPixelBuffer = rotated;  // 所有权转移
                if (yuv) {
                    if (strongSelf->_liveYUVPixelBuffer) {
                        CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                    }
                    strongSelf->_liveYUVPixelBuffer = yuv;  // 所有权转移; 失败时保留旧 YUV
                }
                [strongSelf.processLock unlock];

                renderedFrames++;
                if (renderedFrames % 600 == 1) {
                    prerenderLogSeq++;
                    vcam_core_log([NSString stringWithFormat:@"[vcam] prerender #%llu frames ok fps=%.1f", (unsigned long long)renderedFrames, fps]);
                }
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

        [_processLock lock];
        _enabled = YES;
        [_processLock unlock];

        // 必须在 _enabled=YES 之后启动（否则预渲染 while(enabled) 读到 NO 立即退出, 之后永远不替换）
        [self startPrerenderThread];
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
