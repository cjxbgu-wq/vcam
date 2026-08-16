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
#import <mach/mach.h>

// ===== 资源自监控(2026-08-16 黑屏取证 v2: +CPU% +按流渲染统计) =====
// mediaserverd 周期性被杀(相机替换活跃 ~150s)但无 .ips 落盘, 系统侧无法判死因。
// v2 探针每 30s 记一行: 内存(已证平稳)/进程 CPU%(所有线程 user+system 累计差分)/
// 按流(w_h_fmt)渲染计数+像素量 —— 被杀前最后一行即可定位烧 CPU 配额的具体流
static NSString *vcam_process_cpu_seconds(void) {
    thread_array_t threads;
    mach_msg_type_number_t tcount = 0;
    double total = 0;
    if (task_threads(mach_task_self(), &threads, &tcount) == KERN_SUCCESS) {
        for (mach_msg_type_number_t i = 0; i < tcount; i++) {
            thread_basic_info_data_t bi;
            mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc) == KERN_SUCCESS) {
                total += bi.user_time.seconds + bi.user_time.microseconds / 1e6;
                total += bi.system_time.seconds + bi.system_time.microseconds / 1e6;
            }
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, tcount * sizeof(thread_t));
    }
    return [NSString stringWithFormat:@"%.1f", total];
}

static void vcam_telemetry_sample(uint64_t renderedFrames, NSString *streamStats) {
    static CFAbsoluteTime lastTel = 0;
    static double lastCpu = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastTel > 0 && (now - lastTel) < 30.0) return;

    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0, resident = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        footprint = vmInfo.phys_footprint;
        resident = vmInfo.resident_size;
    }

    double cpuSec = [vcam_process_cpu_seconds() doubleValue];
    double cpuPct = (lastTel > 0 && now > lastTel) ? ((cpuSec - lastCpu) / (now - lastTel) * 100.0) : 0;
    lastTel = now;
    lastCpu = cpuSec;

    @try {
        NSString *line = [NSString stringWithFormat:
            @"%.0f fp=%lluMB res=%lluMB cpu=%.0f%% renders=%llu | %@\n",
            now, footprint >> 20, resident >> 20, cpuPct, renderedFrames,
            streamStats.length ? streamStats : @"-"];
        NSString *path = @"/tmp/vcam_telemetry.txt";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// 日志总开关(2026-08-16, diskwrites 崩溃循环止血): mediaserverd 的 EXC_RESOURCE
// disk writes 配额极低(12.43KB/s 记账/每日 ~1GB, 每行日志按 4KB 脏页记账)。
// 默认全部静默; 诊断时 SSH 写 vc.plist "logEnabled=YES" + respring 打开
static BOOL vcam_log_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            cached = (d && d[@"logEnabled"]) ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) { cached = 0; }
    }
    return cached == 1;
}

static void vcam_core_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
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
// 第一次已改写, 后续直接跳过(不 retain, 仅指针比较)
@property (nonatomic, assign) CVPixelBufferRef dedupLastBuffer;

// ===== 性能优化(2026-08-15) =====
// 进程标记: 只有 mediaserverd 真正解码/预渲染; SpringBoard 的 VCamCore 只做状态记录,
// 否则 SB 进程白白解码整个视频(30fps 解码+转换) → 桌面卡顿/按钮迟钝
@property (nonatomic, assign) BOOL isMediaserverdProcess;
// 源帧代数(单调递增): 每存入新帧 +1。render 设置到 gpuProcessor.frameToken,
// 供私有格式两步法的 staging 缩放复用(同帧多流渲染时缩放只做一次, CPU 减半)
@property (nonatomic, assign) uint64_t liveFrameGen;
// 预渲染重复源跳过: 无新帧入队(解码计数未变)且旋转/镜像未变时, 跳过重复的旋转+格式转换
@property (nonatomic, assign) uint64_t lastPrerenderSrcGen;
@property (nonatomic, assign) int lastPrerenderRot;
@property (nonatomic, assign) BOOL lastPrerenderMirror;

// ===== 相机空闲门控(2026-08-16 发热优化) =====
// 根因: 替换开启期间解码+预渲染按视频帧率 30fps 常转, 而相机流只在 App 打开相机时
// 才到达 hook —— "开着替换但没用相机"的绝大部分时间(桌面/后台/非相机 App)全是空转,
// 这是常驻发热的主源。门控: render 心跳 >2s 无相机流 → 暂停解码(常驻线程空转睡眠,
// CPU≈0)+预渲染睡眠; 相机流恢复(render 被调)同步即时唤醒(先吃缓存帧, 解码 ~100ms 内跟上)
@property (nonatomic, assign) CFAbsoluteTime lastRenderActivity;
@property (nonatomic, assign) BOOL pipelineIdle;
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
        // 预渲染 Default 优先级(2026-08-16 卡顿修复): Utility 下预渲染被饿死 → 旋转转换
        // 跟不上解码 → _liveYUV 长时间不更新 → render 反复写旧帧 → 卡顿观感。
        // (8-15 降 Utility 时 render 是全局锁串行大负载; 现在 per-stream 并行 + 微型流
        //  跳过 + 相机空闲门控后我们负载已大降, Default 与服务同级竞争安全)
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

        // 初始化组件 —— SpringBoard 轻量化(2026-08-15):
        // SB 只记录状态(悬浮球按钮全走 vc.plist, 替换渲染在 mediaserverd),
        // 不创建解码/渲染组件(LocalVideoPlayer+GPUImageProcessor+CIContext+VT sessions)。
        // 降 SB 常驻内存/句柄 → 整机 CPU 余量增大(前台 App 相机 watchdog 是 CPU 超时触发)。
        // 轮询回调对 nil 的访问全部是 nil-messaging no-op, 安全
        if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            _gpuProcessor = nil;
            _videoPlayer = nil;
            _frameQueue = nil;
            vcam_core_log(@"[vcam] VCamCore initialized lean in SpringBoard (no decoder/renderer)");
        } else {
            _gpuProcessor = [[GPUImageProcessor alloc] init];
            _videoPlayer = [[LocalVideoPlayer alloc] initWithCapacity:10];
            _videoPlayer.gpuProcessor = _gpuProcessor;
            _frameQueue = _videoPlayer.frameQueue;
        }

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
    // 仅真 mediaserverd 解码/预渲染: Tweak 构造器对 lskdd 等其他进程也调本方法,
    // 那些进程没有相机 hook, 全功能解码纯属浪费(多进程 AVFoundation 队列压力)
    _isMediaserverdProcess = [[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"];
    // mediaserverd 中用 plist 轮询（Darwin 通知不安全）
    [self startStatePolling];
    vcam_core_log([NSString stringWithFormat:@"[vcam] MediaServerd hooks initialized (decoder=%d)", _isMediaserverdProcess]);
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

    // 微型流跳过(2026-08-15, mediaserverd 存活关键): App 相机带人脸/场景分析小流
    // (如 328x184 '18f0'), 替换它无视觉意义但每帧 VT 转换挤占 mediaserverd →
    // AURemoteIO RPC 超时 → mediaserverd 被杀死循环。可见预览流(≥720p)不受影响
    if (targetW * targetH < 640 * 480) {
        return;
    }

    // 相机活跃心跳 + 空闲即时唤醒(2026-08-16 发热优化): 走到这里 = 有真实可见相机流,
    // 刷新心跳; 若管线处于空闲暂停态(相机关闭过)则同步恢复解码(常驻线程只翻标志, 零延迟),
    // 本帧先吃 _liveYUVPixelBuffer 缓存帧, 解码 ~100ms 内跟上 —— 用户无感知
    self->_lastRenderActivity = CFAbsoluteTimeGetCurrent();
    if (self->_pipelineIdle) {
        self->_pipelineIdle = NO;                 // 预渲染线程 ≤0.1s 内自行恢复
        [self->_videoPlayer startDecodingThread]; // 空转线程恢复解码标志
    }

    // 少数派方向流降频(2026-08-16 云闪付扫码 CPU 配额被杀修复):
    // 扫码场景 3 流 90 renders/s CPU 67% → ~110s 被杀(telemetry v2 实证)。
    // 其中两条横流(1280x720 -8f0/BGRA)是扫码头分析流(用户不可见), 全速替换纯烧配额。
    // 方向少数派 = 辅助流: 实时按横竖渲染占比判定, 少数派流降到 ~15fps。
    // 预览(多数派)不受影响; 视频通话录像流若为少数派 → 15fps 画面(远好于黑屏)。
    // 计数每 150 帧重置(窗口化防长期倾斜)
    {
        static int64_t landscapeCnt = 0, portraitCnt = 0;
        static CFAbsoluteTime lastLandscapeTick = 0, lastPortraitTick = 0;
        BOOL isLandscape = (targetW > targetH);
        if (isLandscape) landscapeCnt++; else portraitCnt++;
        if ((landscapeCnt + portraitCnt) >= 150) { landscapeCnt >>= 2; portraitCnt >>= 2; }

        BOOL minority = isLandscape ? (landscapeCnt < portraitCnt)
                                    : (portraitCnt < landscapeCnt);
        if (minority) {
            CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime last = isLandscape ? lastLandscapeTick : lastPortraitTick;
            if (last > 0 && (nowT - last) < 0.066) {
                return;  // 15fps 上限: 该方向本窗口内已写过, 跳过(保留相机帧)
            }
            if (isLandscape) lastLandscapeTick = nowT; else lastPortraitTick = nowT;
        }
    }

    // 诊断: 降频至每 600 帧(30fps 相机流 ~20s 一条, disk writes 限额保护)
    static int vcamRenderCount = 0;
    vcamRenderCount++;
    BOOL diagThisFrame = (vcamRenderCount % 600 == 1);

    // 1. 取预渲染缓存(YUV 主源, 等价千面 [player copyCurrentFrame])
    [_processLock lock];
    CVPixelBufferRef yuv = _liveYUVPixelBuffer;
    if (yuv) CVPixelBufferRetain(yuv);
    uint64_t gen = _liveFrameGen;
    [_processLock unlock];
    // 帧代数经 writeFrame:toPixelBuffer:token: 参数传递(不写 gpuProcessor 全局属性,
    // 多 hook 线程并发 render 时全局赋值会互相覆盖导致 staging 误用别帧内容)
    CVPixelBufferRef bgra = NULL;

    // 注: 曾尝试渲染缓存(gen 相同则 memcpy 上次输出, 省 VT 转换) —— 已移除:
    // 相机帧是 IOSurface-backed(GPU/ISP 并发持有), VT 内部有同步而裸 memcpy 没有,
    // 周期性撞数据竞争窗口导致 mediaserverd 崩溃(相机闪退)。写入相机帧一律走 VT。
    // 注2: 预渲染不再预产 BGRA(懒加载, 产能优化), BGRA 回退时现场转换。

    if (!yuv) {
        // 无帧回退(对齐千面 0xb018-0xb05c): 用上一帧缓存填充, 视频解码间隙不闪回相机画面。
        // 不再要求尺寸匹配 —— VT transfer 本身支持任意尺寸 crop fill,
        // 尺寸不匹配时跳过会导致间隙闪现真实相机画面(不稳定感)
        if (diagThisFrame) vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d NO frame, fallback", vcamRenderCount]);
        [_renderLock lock];
        CVPixelBufferRef fb = _fallbackFrame;
        if (fb) CVPixelBufferRetain(fb);
        [_renderLock unlock];
        if (fb) {
            [_gpuProcessor transferPixelBuffer:fb toPixelBuffer:pixelBuffer];  // 内部自带格式锁
            CVPixelBufferRelease(fb);
        }
        return;
    }

    // 2. 选源(对齐千面架构: 解码原生 420f 单一源 —— readNextFrame 0xe0e4 直接把
    //    AVAssetReader 解码帧给 setReplacementPixelBuffer, 无 BGRA 中转)。
    //    YUV(420f) 源携带原生 range/矩阵 attachments: YUV→私有格式(-8f0/p420/|xv0)
    //    range 保持正确; BGRA 源转私有格式 VT 缺 range 信息 → 照片过曝(高光洗白)。
    //    420f→某私有格式若 VT 不支持(-12905), 下方自动回退 BGRA 源重试
    CVPixelBufferRef base = yuv;

    // 3. 自适应旋转(对齐千面 render_disas 0xaf7c-0xafe4): 源/目标宽高比正交(一横一竖)时
    // CCW90 旋转(宽高互换), 预览流(竖向 buffer)与拍照/录像流(横向 buffer)各自正确方向,
    // 否则拍照保存画面横躺(翻转根因)。方法内部自带 rotationRenderLock。
    // token=gen: 同一帧被相机多条流渲染时 CCW90 只做一次, 后续流直接复用缓存(每流省 ~2-4ms)
    CVPixelBufferRef src = [_gpuProcessor adaptiveRotateIfNeeded:base targetWidth:targetW targetHeight:targetH token:gen];

    // 4. 写入相机帧: VT transfer(Trim 保比例 crop fill)主路径。
    //    全格式处理无白名单(对齐千面 0xb0f8-0xb154: 私有格式 |8v0/-8f0/p420 也 transfer,
    //    这正是千面能替换视频模式预览和拍照保存的原因), 失败保留原相机帧
    BOOL usedFallbackSource = NO;
    BOOL ok = [self writeFrame:src toPixelBuffer:pixelBuffer token:gen];
    if (!ok && base == yuv) {
        // YUV 源失败(该 420f→目标组合 VT 不支持): 懒转 BGRA 回退(预渲染已不预产 BGRA,
        // 罕见路径现场转换一次, 正常帧不付这个代价)
        if (src) CVPixelBufferRelease(src);
        src = NULL;
        [_renderLock lock];
        CVPixelBufferRef lazyBGRA = [_gpuProcessor convertFormat:yuv toFormat:kCVPixelFormatType_32BGRA];
        if (lazyBGRA) {
            src = [_gpuProcessor adaptiveRotateIfNeeded:lazyBGRA targetWidth:targetW targetHeight:targetH token:0];
            CVPixelBufferRelease(lazyBGRA);
        }
        [_renderLock unlock];
        ok = [self writeFrame:src toPixelBuffer:pixelBuffer token:0];  // 0 = 不复用 staging
        usedFallbackSource = ok;
        if (ok && diagThisFrame) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d YUV->0x%x failed, retry via lazy BGRA OK", vcamRenderCount, (unsigned)origFormat]);
        }
    }
    if (ok) {
        _frameCount++;
        if (diagThisFrame) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] render#%d OK %zux%zu fmt=0x%x via %@%@",
                           vcamRenderCount, targetW, targetH, (unsigned)origFormat,
                           usedFallbackSource ? @"BGRA(fb)" : @"YUV",
                           (src != base && !usedFallbackSource) ? @" +CCW90" : @""]);
        }
        // 缓存回退帧(千面缓存旋转后的实际 transfer 源 x24, 0xb15c-0xb19c) + 同帧去重
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

    if (src) CVPixelBufferRelease(src);
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

// 像素级诊断: dump buffer 的颜色 attachments + 亮度采样(量化单次转换的提亮效应)
// 采样中心十字 5 点: Y 平面(YUV) 或 G 通道(BGRA), 附 attachments 全字典
- (void)dumpBufferDiagnostics:(CVPixelBufferRef)buf label:(NSString *)label {
    if (!buf) return;
    OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    size_t w = CVPixelBufferGetWidth(buf);
    size_t h = CVPixelBufferGetHeight(buf);

    CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    NSMutableArray *samples = [NSMutableArray array];
    if (CVPixelBufferGetPlaneCount(buf) >= 1) {
        // YUV: 采样 plane0(Y) 中心十字
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(buf, 0);
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
        if (base) {
            size_t cx = w / 2, cy = h / 2;
            size_t xs[] = {cx, cx / 2, cx + cx / 2, cx, cx};
            size_t ys[] = {cy, cy, cy, cy / 2, cy + cy / 2};
            for (int i = 0; i < 5; i++) {
                if (xs[i] < w && ys[i] < h) {
                    [samples addObject:@(base[ys[i] * bpr + xs[i]])];
                }
            }
        }
    } else {
        // BGRA: 采样 G 通道(Offset+1)
        uint8_t *base = CVPixelBufferGetBaseAddress(buf);
        size_t bpr = CVPixelBufferGetBytesPerRow(buf);
        if (base) {
            size_t cx = w / 2, cy = h / 2;
            size_t xs[] = {cx, cx / 2, cx + cx / 2, cx, cx};
            size_t ys[] = {cy, cy, cy, cy / 2, cy + cy / 2};
            for (int i = 0; i < 5; i++) {
                if (xs[i] < w && ys[i] < h) {
                    [samples addObject:@(base[ys[i] * bpr + xs[i] * 4 + 1])];
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);

    NSDictionary *atts = CFBridgingRelease(CVBufferCopyAttachments(buf, kCVAttachmentMode_ShouldPropagate));
    vcam_core_log([NSString stringWithFormat:@"[vcam][pix] %@ %zux%zu fmt=0x%x Y/G=%@ atts=%@",
                   label, w, h, (unsigned)fmt, samples, atts ?: @"(nil)"]);
}

#pragma mark - 帧写入

// 对齐逆向: VT transfer(Trim 保比例 crop fill 缩放+格式转换) 主路径
// 失败回退 CoreImage crop fill(仅标准格式), 再失败保留原相机帧(绝不输出未初始化 buffer 防绿屏)
// token: 该 src 帧的代数(私有格式两步法 staging 复用判断用)。传 0 = 永不复用(安全)。
// 在 renderLock 内设置到 GPU —— 多 hook 线程并发 render 时各自携带自己的 token,
// 避免 lock 外全局赋值被其他线程覆盖导致 staging 误用别帧内容
- (BOOL)writeFrame:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;

    static int vcamWriteCount = 0;
    vcamWriteCount++;
    BOOL diag = (vcamWriteCount % 900 == 1);
    if (diag) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT begin %zux%zu(0x%x) -> %zux%zu(0x%x)",
                       vcamWriteCount,
                       CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), (unsigned)CVPixelBufferGetPixelFormatType(src),
                       CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst), (unsigned)CVPixelBufferGetPixelFormatType(dst)]);
    }

    // 并行锁体系(2026-08-15): 不再用全局 renderLock —— 拍照流(4032x3024 大帧 ~100ms)
    // 持全局锁会阻塞所有预览流(拍照瞬间预览冻结/黑屏)。锁下沉到 GPU 内部:
    //   一步 transfer 按目标格式 3 把锁(异格式流并行), 两步法 per-key 锁(异尺寸流并行),
    //   rotation/CI 回退内部自锁。token 经参数传递(线程安全, 不写全局属性)
    BOOL done = NO;

    // 路径1: VTPixelTransferSession（任意尺寸+格式组合, CropSourceToCleanAperture 自动 crop fill）
    // 对齐千面(0xb0f8-0xb158): VT 是唯一路径, 失败直接保留相机帧 —— 千面无 CI 回退。
    // (CI 软件渲染 12MP 照片帧需数秒且持 rotationRenderLock, 会饿死全部预览流的
    //  自适应旋转 → 相机管线线程卡死 → mediaserverd watchdog 60s kill, 拍照黑屏根因)
    @try {
        if ([_gpuProcessor transferPixelBuffer:src toPixelBuffer:dst token:token]) {
            if (diag) {
                vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT ok", vcamWriteCount]);
            }
            done = YES;
        }
    } @catch (NSException *e) {
        vcam_core_log([NSString stringWithFormat:@"[vcam] write#%d VT exception: %@", vcamWriteCount, e]);
    }

    return done ? YES : NO;
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
                // 空闲门控(2026-08-16 发热优化): 相机无流(render 心跳 >2s 无刷新) →
                // 整条预渲染睡眠等待, 不取帧不转换; render 被调时清 pipelineIdle 自动恢复
                if (strongSelf.pipelineIdle) {
                    [NSThread sleepForTimeInterval:0.1];
                    nextTick = CFAbsoluteTimeGetCurrent();
                    continue;
                }

                // effectiveFps = PTS 实测帧率(校准 nominalFrameRate 低估导致的节拍慢放)
                double fps = strongSelf.videoPlayer.effectiveFps;
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

                // 重复源跳过: 无新帧入队(frameCount 未变, 如解码间隙/暂停回退当前帧)且
                // 总旋转(视频自带+用户手动)/镜像未变时, 下一拍已产出相同内容 → 跳过旋转+VT 转换
                // (用解码器单调递增的 frameCount 判断, 不用指针: 解码器会回收复用 buffer 指针)
                strongSelf.gpuProcessor.sourceRotation = strongSelf.videoPlayer.preferredRotation;
                int curRot = (strongSelf.gpuProcessor.sourceRotation + strongSelf.gpuProcessor.rotationAngle) % 360;
                BOOL curMirror = strongSelf.gpuProcessor.mirrored;
                uint64_t curCount = strongSelf.videoPlayer.frameCount;
                if (curCount == strongSelf->_lastPrerenderSrcGen &&
                    curRot == strongSelf->_lastPrerenderRot &&
                    curMirror == strongSelf->_lastPrerenderMirror) {
                    CVPixelBufferRelease(frame);
                    continue;
                }
                strongSelf->_lastPrerenderSrcGen = curCount;
                strongSelf->_lastPrerenderRot = curRot;
                strongSelf->_lastPrerenderMirror = curMirror;

                // 1. 旋转/镜像（如需要, 视频原尺寸; 解码帧为 420f, 旋转保持 420f）
                CVPixelBufferRef rotated = [strongSelf.gpuProcessor rotateAndMirrorIfNeeded:frame];
                CVPixelBufferRelease(frame);
                if (!rotated) continue;

                // 2. 懒 BGRA(产能优化): 不再每帧预转 BGRA —— 旋转+转换两个 VT 调用
                //    每帧 ~68ms > 41.6ms(24fps 帧间隔), 预渲染只跑出 14.6fps → 卡顿。
                //    YUV 是 render 主源(千面解码原生单源架构); BGRA 回退需求罕见
                //    (仅 420f→某私有格式 VT 不支持时), 由 render 现场懒转。
                //    只做旋转一个 VT → 预渲染恢复源视频帧率

                // 3. 完整产出后才替换缓存（避免半成品被 render 读到）
                [strongSelf.processLock lock];
                if (strongSelf->_liveYUVPixelBuffer) {
                    CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                }
                strongSelf->_liveYUVPixelBuffer = rotated;  // 所有权转移
                strongSelf->_liveFrameGen++;  // render 端 staging 复用的帧代数
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
    // SpringBoard 进程守卫: SB 不解码视频(替换渲染在 mediaserverd), 只记录状态。
    // 否则 SB 会启动解码线程+预渲染线程白白解码整个视频 → 桌面卡顿/悬浮窗按钮迟钝
    if (!_isMediaserverdProcess) {
        _enabled = enabled;
        return;
    }

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

        // 异步加载: loadVideoFile 含同步轨道解析 + 预解码 5 帧(50-150ms+),
        // 在 0.15s 节拍的轮询线程上同步执行会积压队列 → XPC watchdog 超时 →
        // mediaserverd 被杀(相机黑屏/闪退)。串行 processingQueue 天然合并连点请求
        __weak typeof(self) weakSelf = self;
        dispatch_async(_processingQueue, ^{
            VCamCore *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_videoPlayer loadVideoAtPath:path completion:^(BOOL success, NSError *error) {
                if (success) {
                    vcam_core_log(@"[vcam] Video loaded OK (async)");
                    [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
                } else {
                    vcam_core_log([NSString stringWithFormat:@"[vcam] Failed to load video: %@", error]);
                }
            }];
            [strongSelf->_videoPlayer startWatchingFile:path];
        });

        [_processLock lock];
        _enabled = YES;
        [_processLock unlock];

        // 空闲门控基线(2026-08-16 发热优化): enable 后给 2s 心跳宽限, 期间预渲染正常跑
        // (相机若已开着, render 心跳会持续刷新, 永不进入空闲)
        _pipelineIdle = NO;
        _lastRenderActivity = CFAbsoluteTimeGetCurrent();

        // 必须在 _enabled=YES 之后启动（否则预渲染 while(enabled) 读到 NO 立即退出, 之后永远不替换）
        [self startPrerenderThread];
        vcam_core_log(@"[vcam] Live state changed to: enabled");
    } else {
        // enable→disable: 停止解码/预渲染, 但保留帧缓存(_liveYUV/_fallback)。
        // _enabled=NO 时 render 直接 return → 相机真实画面自然恢复, 语义不变;
        // 而下次 enable 时异步加载视频需要 0.5~4s(轨道解析+预解码), 期间
        // render NO frame → 若缓存被清则黑屏。保留缓存 → 冻结上一帧画面平滑过渡
        [self stopPrerenderThread];
        [_videoPlayer stopDecodingThread];
        [_videoPlayer stopWatchingFile];

        [_processLock lock];
        _enabled = NO;
        [_processLock unlock];
        _pipelineIdle = NO;  // 门控状态复位, 下次 enable 从正常态启动
        vcam_core_log(@"[vcam] Live state changed to: disabled (frame cache kept)");
        [[VCamNotify sharedInstance] postNotification:VCamNotifyLiveChanged];
    }
}

#pragma mark - plist 轮询

- (void)startStatePolling {
    if (_pollingActive) return;
    _pollingActive = YES;
    vcam_core_log(@"[vcam] State polling timer started");

    __weak typeof(self) weakSelf = self;
    // 0.15s 轮询: 悬浮球按钮(转/镜/播/切源)生效延迟降到最长 0.15s(平均 75ms),
    // 单次 plist 读取 ~0.1ms 开销可忽略, 读取在后台 notify 队列不占主线程
    [[VCamNotify sharedInstance] startPollingWithInterval:0.15 callback:^(BOOL enabled) {
        VCamCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        // poll 心跳日志已移除(2026-08-16): mediaserverd disk writes 限额 12.43KB/s,
        // 高频日志按 4KB 脏页/行记账 → EXC_RESOURCE 杀进程(崩溃循环根因)
        if (enabled != strongSelf.lastEnabledState) {
            vcam_core_log([NSString stringWithFormat:@"[vcam] state change: %d -> %d, calling setEnabled", strongSelf.lastEnabledState, enabled]);
            strongSelf.lastEnabledState = enabled;
            [strongSelf setEnabled:enabled];
        }

        // 空闲看门狗(2026-08-16 发热优化): 替换开着但相机流心跳 >2s 未刷新
        // (相机关闭/切后台/非相机 App) → 暂停解码+预渲染, CPU 归零;
        // 相机重新打开时 render 同步清 pipelineIdle 即时恢复
        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && !strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 2.0) {
            strongSelf->_pipelineIdle = YES;
            [strongSelf->_videoPlayer stopDecodingThread];
            vcam_core_log(@"[vcam] camera idle >2s, pipeline paused (decode+prerender)");
        }

        // 资源探针(2026-08-16 黑屏取证 v2): 每 30s 一行内存/CPU%/按流渲染统计
        if (strongSelf.isMediaserverdProcess) {
            vcam_telemetry_sample(strongSelf->_frameCount,
                                  [strongSelf->_gpuProcessor takeStreamStats]);
        }

        // 旋转/镜像跨进程同步: 悬浮球(SpringBoard)写 vc.plist, mediaserverd 轮询应用
        // (对齐千面 vc.plist manualRotation 字段; rotationAngle!=0 时 render 不做自适应旋转)
        // 性能: 一次读 plist 提取全部控制字段(原来 5 个字段各读一次文件 = 5x IO)
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};
        static NSInteger lastSyncedRotation = -1;
        static BOOL lastSyncedMirrored = NO;
        NSInteger plistRotation = [pl[@"manualRotation"] integerValue];
        BOOL plistMirrored = [pl[@"mirrored"] boolValue];
        if (plistRotation != lastSyncedRotation) {
            strongSelf.gpuProcessor.rotationAngle = (int)plistRotation;
            lastSyncedRotation = plistRotation;
            vcam_core_log([NSString stringWithFormat:@"[vcam] rotation synced: %ld", (long)plistRotation]);
        }
        if (plistMirrored != lastSyncedMirrored) {
            strongSelf.gpuProcessor.mirrored = plistMirrored;
            lastSyncedMirrored = plistMirrored;
            vcam_core_log([NSString stringWithFormat:@"[vcam] mirror synced: %d", plistMirrored]);
        }

        // 视频源切换(悬浮球 1/2/3 键): activePlaybackPath 变化 → 自动重载新视频
        // (无需 toggle enabled, 轮询 0.15s 内生效; 路径写入由悬浮球完成)
        static NSString *lastSyncedPath = nil;
        static BOOL pathSyncInit = NO;
        NSString *activePath = pl[@"activePlaybackPath"];
        if (activePath.length > 0 && ![activePath isEqualToString:lastSyncedPath]) {
            if (pathSyncInit && strongSelf.enabled) {
                vcam_core_log([NSString stringWithFormat:
                    @"[vcam] activePlaybackPath changed: %@ -> %@, reloading", lastSyncedPath, activePath]);
                // 切视频重置手动旋转/镜像: 残留的手动角度会与新视频自带的 preferredRotation
                // 叠加, 产生意外的 180° 等翻转(换视频后画面倒立的根因)。
                // 新视频按其自身元数据从干净起点显示
                strongSelf.gpuProcessor.rotationAngle = 0;
                strongSelf.gpuProcessor.mirrored = NO;
                [VCamNotify setPlistRotation:0];
                [VCamNotify setPlistMirrored:NO];
                lastSyncedRotation = 0;
                lastSyncedMirrored = NO;
                // 异步重载(同步加载阻塞轮询线程 → watchdog 崩溃)
                __weak typeof(strongSelf) wSelf = strongSelf;
                dispatch_async(strongSelf.processingQueue, ^{
                    VCamCore *sSelf = wSelf;
                    if (!sSelf) return;
                    [sSelf.videoPlayer loadVideoAtPath:activePath completion:nil];
                    [sSelf.videoPlayer startWatchingFile:activePath];
                });
            }
            lastSyncedPath = [activePath copy];
            pathSyncInit = YES;
        }

        // 暂停/继续(悬浮球 ▶ 键): paused → 解码线程停止取帧, 预渲染冻结最后一帧
        static BOOL lastSyncedPaused = NO;
        BOOL plistPaused = [pl[@"paused"] boolValue];
        if (plistPaused != lastSyncedPaused) {
            strongSelf.videoPlayer.paused = plistPaused;
            vcam_core_log([NSString stringWithFormat:@"[vcam] paused synced: %d", plistPaused]);
            lastSyncedPaused = plistPaused;
        }

        // 从头重播(悬浮球 播 键): restartToken 自增 → 重载当前视频回到开头
        static NSInteger lastRestartToken = -1;
        NSInteger restartToken = [pl[@"restartToken"] integerValue];
        if (restartToken != lastRestartToken) {
            if (lastRestartToken >= 0 && strongSelf.enabled && strongSelf.videoPlayer.currentVideoPath.length > 0) {
                vcam_core_log(@"[vcam] restart token bumped, replay from beginning");
                // 异步重载(同步加载阻塞轮询线程 → watchdog 崩溃)
                NSString *replayPath = [strongSelf.videoPlayer.currentVideoPath copy];
                __weak typeof(strongSelf) wSelf = strongSelf;
                dispatch_async(strongSelf.processingQueue, ^{
                    VCamCore *sSelf = wSelf;
                    if (!sSelf) return;
                    [sSelf.videoPlayer loadVideoAtPath:replayPath completion:nil];
                });
            }
            lastRestartToken = restartToken;
        }
    }];
}

- (void)stopStatePolling {
    [[VCamNotify sharedInstance] stopPolling];
    _pollingActive = NO;
}

@end
