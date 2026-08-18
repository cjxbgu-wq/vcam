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

// 日志令牌桶(定义见下方 vcam_log_budget_take, 全进程共享磁盘写入预算)
BOOL vcam_log_budget_take(void);

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
        if (!vcam_log_budget_take()) return;  // 磁盘配额保护: 遥测也走令牌桶
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
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) cached = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return cached == 1;
}

// 日志全局限速令牌桶(2026-08-19 磁盘配额击杀循环根治): 设备实证 1.2.6 时代
// logEnabled=true 时, 每次开相机突发 40+ 行日志(emit#/write#/render#/init...)
// —— 每行按 4KB 脏页记账, 瞬时速率 >> 12.43KB/s 配额 → EXC_RESOURCE 击杀
// mediaserverd → 重启又写突发 → 再杀 = 自馈崩溃循环(runs 49→57/30s,
// launchctl "immediate reason = inefficient", 设备实证)。
// 令牌桶: 容量 24(短突发可过), 持续 3 行/s(=12KB/s, 恰在配额内)。
// 超限行直接丢弃 —— 诊断日志本就采样降频(%600), 丢行不影响取证大局。
// 全进程所有 vcam_*_log / telemetry 共用同一预算(定义于本文件, 其余编译单元 extern)。
BOOL vcam_log_budget_take(void) {
    static NSLock *lk = nil;
    static double tokens = 24.0;
    static double lastRefill = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lk = [[NSLock alloc] init];
        lastRefill = CFAbsoluteTimeGetCurrent();
    });
    [lk lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastRefill < now) {
        double refilled = tokens + (now - lastRefill) * 3.0;
        tokens = refilled > 24.0 ? 24.0 : refilled;
        lastRefill = now;
    }
    BOOL ok = NO;
    if (tokens >= 1.0) { tokens -= 1.0; ok = YES; }
    [lk unlock];
    return ok;
}

static void vcam_core_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
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
// 时间窗(2026-08-17 闪烁根治): 相机管线 IOSurface 池只有 3~6 个 buffer 循环
// 轮转, 帧 N 用 buffer A 替换后帧 N+2 又轮到同一地址 → 裸指针比较误判"已替换"
// 跳过 → 真实相机画面上屏 → 与替换帧稳定交替 = 用户看到的"替换/原画面闪烁"。
// 千面 0xaed4 判定的是"同一帧时间窗内多消费者"(间隔 <1ms), 不是跨帧轮转
// (≥16ms)。加 5ms 窗口区分两者。
@property (nonatomic, assign) CVPixelBufferRef dedupLastBuffer;
@property (nonatomic, assign) CFAbsoluteTime dedupLastTime;
// 去重 v2(2026-08-19 IOFence 死锁根治): 最近一次渲染的相机帧 PTS(与指针联合判定)
@property (nonatomic, assign) double dedupLastPts;
// 快照最近一次推进时的相机帧 PTS(2026-08-17 卡顿修复): 相机帧边界判定
@property (nonatomic, assign) double lastAdvancePts;

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
// 空闲卸载标记(2026-08-18 云闪付崩溃循环): pipelineIdle 暂停时已卸载媒体管线,
// render 心跳恢复时按 _idleResumePath 异步重载(期间渲染冻结快照帧不黑屏)
@property (nonatomic, assign) BOOL idleUnloaded;
@property (nonatomic, copy) NSString *idleResumePath;
// 恢复保持(2026-08-19 卡顿修复): 恢复重载后 5s 内不许再次 idle 卸载 ——
// 扫码页帧间歇突发(2-3s 一拨)曾造成 4s 内 4 轮卸载/重载抖动, 每轮重建
// reader+预填都是 CPU 尖峰且画面反复冻在旧帧
@property (nonatomic, assign) CFAbsoluteTime lastIdleResumeTime;
// CPU 闭环降载(2026-08-16): 进程 CPU 接近 daemon 50% 红线时置 YES ——
// 解码/预渲染节拍降为 1/3(替换内容 ~10fps 更新, 连续无感), 冻结帧走 staging 复用
@property (nonatomic, assign) BOOL lowPowerDecode;
// 多流显示同步(2026-08-16 照片模式叠影修复): 照片模式预览流+照片缩放流同时活跃,
// 各流 render 时刻不同且缓存 key 不同(尺寸/格式各异), 仅量化代数不够 —— 窗口内
// 不同流仍会从 live buffer 取到不同时间的帧, App 融合两流 → 两个画面叠影。
// 快照方案: 每 1/视频fps 窗口推进时 retain 锁定当前 _liveYUVPixelBuffer 为
// syncDisplayFrame, 窗口内所有流统一渲染该快照 + 同一 gen → 内容强制一致。
// 快照生命周期 ≤1 帧 < 预渲染 3-slot 旋转池复用周期(3 帧), 不会被覆写
@property (nonatomic, assign) CVPixelBufferRef syncDisplayFrame;
@property (nonatomic, assign) uint64_t syncDisplayGen;
@property (nonatomic, assign) CFAbsoluteTime lastGenAdvanceTime;
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
    [self renderReplacementToPixelBuffer:pixelBuffer pts:0];
}

- (void)renderReplacementToPixelBuffer:(CVPixelBufferRef)pixelBuffer pts:(double)pts {
    if (!pixelBuffer || !_enabled) return;

    // 同帧去重 v2(2026-08-19 IOFence GPU 死锁根治): 指针 + PTS 双重判定, 检查与
    // 登记同锁原子完成。旧"指针+5ms 窗"两个缺陷(设备实证 00:00:13 gpuEvent
    // "blocked by IOFence": 3 个同调用栈 GPU 等待者挤在同一 surface 上):
    //   1) 无锁竞态: emit/scaler/encoder 三个 hook 在不同 Apple 队列线程并发消费
    //      同一物理相机帧, 双双通过旧检查 → 同一相机 IOSurface 上并发排入多个
    //      VT GPU 写 + 下游节点同时持 fence → fence 互等死锁 → GPU 固件重启 →
    //      画面冻结后黑屏(msd 不死, 替/原无效, 只有重开相机/重启恢复)。
    //   2) 5ms 窗误放行: 慢消费者(>5ms 后到)对已被相机池回收的 surface 补写旧帧,
    //      与新帧的 ISP/GPU 处理撞车。
    // PTS 判定: 同一物理帧跨节点(emit/scaler/encoder)PTS 恒等 → 同指针+同 PTS =
    // 重复消费, 跳过; 池轮转回同指针但 PTS 已新 = 新帧, 渲染; 多流各自 buffer
    // 同 PTS = 各自渲染(指针不同, 不受影响)。PTS 不可用(=0 旧调用方)回退旧
    // 指针+5ms 窗。入口即占位登记: 并发第二个消费者必然看到 dup 跳过 ——
    // 同一 surface 任一时刻至多一个在飞的 VT GPU 写(fence 单向, 无环)。
    {
        static NSLock *dedupLock;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{ dedupLock = [[NSLock alloc] init]; });
        [dedupLock lock];
        CFAbsoluteTime nowDedup = CFAbsoluteTimeGetCurrent();
        BOOL samePtr = (self->_dedupLastBuffer == pixelBuffer);
        // 同指针 + (同 PTS 或 5ms 内) = 重复消费: PTS 抓慢消费者(同帧跨节点 PTS
        // 恒等, 无时间上限), 5ms 窗兜底同帧异 PTS 的节点实现; 池轮转新帧 PTS
        // 必新且距上次 ≥16ms → 两信号都放行, 必渲染
        BOOL dup = samePtr && ((pts > 0 && self->_dedupLastPts == pts) ||
                               (nowDedup - self->_dedupLastTime < 0.005));
        if (pts > 0) self->_dedupLastPts = pts;
        self->_dedupLastBuffer = pixelBuffer;  // 占位: 并发后来者必 dup
        self->_dedupLastTime = nowDedup;
        [dedupLock unlock];
        if (dup) return;
    }

    OSType origFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t targetW = CVPixelBufferGetWidth(pixelBuffer);
    size_t targetH = CVPixelBufferGetHeight(pixelBuffer);

    // 微型流也替换(2026-08-17 闪烁根治): 撤掉旧 <640x480 硬跳过 —— 扫码/网页/
    // 社交 App 常用低分辨率档(如 480x360 Medium)做**可见**预览, 被跳过的流永远
    // 显示真实相机; App 在高流(替换)与低流(跳过)间切换显示 = "替换/原画面闪烁",
    // 且扫码页整个不被替换(用户实证反馈)。
    // 旧担忧('18f0' 328x184 分析流 wakeups 风暴)已被两级熔断根治: stage1 失败
    // 回退 BGRA 重试一次, stage1/stage2 连续失败 2 次永久熔断该流(不再有
    // "失败→重建 session→再失败"循环)。微型流像素量小(≤0.2MP), 替换成本可忽略;
    // CPU 兜底由 80/60 紧急档闭环降载负责。

    // 相机活跃心跳 + 空闲即时唤醒(2026-08-16 发热优化): 走到这里 = 有真实可见相机流,
    // 刷新心跳; 若管线处于空闲暂停态(相机关闭过)则同步恢复解码(常驻线程只翻标志, 零延迟),
    // 本帧先吃 _liveYUVPixelBuffer 缓存帧, 解码 ~100ms 内跟上 —— 用户无感知
    self->_lastRenderActivity = CFAbsoluteTimeGetCurrent();
    if (self->_pipelineIdle) {
        self->_pipelineIdle = NO;                 // 预渲染线程 ≤0.1s 内自行恢复
        [self->_videoPlayer startDecodingThread]; // 空转线程恢复解码标志
        // 空闲卸载过媒体管线(2026-08-18): 异步重载 —— 期间本帧与后续帧渲染
        // _syncDisplayFrame 冻结快照(画面静止不黑), 加载完成后预渲染无缝跟上。
        // 必须后台队列(2026-08-18 watchdog 修复): loadVideoFile 内
        // tracksWithMediaType 是同步磁盘解析, 直接在 render(相机管线 hook 线程)
        // 执行会阻塞相机管线 0.5-2s → mediaserverd watchdog 杀进程(设备实证:
        // 恢复重载后 6s 被杀)。冻结帧机制保证加载期间画面连续
        if (self->_idleUnloaded) {
                self->_idleUnloaded = NO;
                self->_lastIdleResumeTime = CFAbsoluteTimeGetCurrent();  // 恢复保持窗口起算(2026-08-19)
                NSString *resumePath = self->_idleResumePath;
            if (resumePath.length > 0) {
                VCamCore *core = self;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    [core->_videoPlayer loadVideoAtPath:resumePath completion:nil];
                });
                vcam_core_log([NSString stringWithFormat:@"[vcam] camera resume after idle unload, reloading(async): %@", resumePath.lastPathComponent]);
            }
        }
    }

    // 1. 显示快照 + 帧代数(2026-08-16 照片模式叠影修复):
    // 每 1/视频fps 窗口推进一次, 推进时 retain 锁定当前 live 帧为快照;
    // 窗口内所有流(预览/照片缩放/录像)统一渲染同一快照 buffer + 同一 gen →
    // 内容强制一致, App 融合多流显示不再出现两个时间点的画面叠影。
    // 快照由本属性 retain, 预渲染替换 live 不影响内容(旋转 slot 池 3 帧复用周期 > 快照 1 帧寿命)
    [_processLock lock];
    {
        uint64_t liveGen = _liveFrameGen;
        CFAbsoluteTime nowQ = CFAbsoluteTimeGetCurrent();
        double vfps = MAX(_videoPlayer.effectiveFps, 1.0);
        // 相机帧边界驱动(2026-08-17 卡顿修复): 旧 1/vfps 时间窗在 30fps 相机流上
        // 被相机帧粒度采样 —— 33.3ms < 41.7ms 不推进, 66.7ms 才推进, 每次跨 2 个
        // 视频帧 → 内容实际 15fps 且隔帧跳 = "停-停-跳"节奏(肉眼可见卡顿)。
        // 改用相机帧 PTS 判定边界: 同一相机帧(emit/scaler/encoder 同帧共享 PTS)
        // 只有首个消费者可推进一次, 同帧其余消费者必然共享同一快照 —— 多流
        // 内容一致性(照片叠影防护)与旧整窗等价; 新相机帧到来即取最新 live:
        // 24fps 内容在 30/60fps 流上呈标准 pulldown 节奏(每帧 1~2 槽位),
        // 不丢帧不冻结。live 更新本身 ≤ 视频帧率, 天然限速无需时间窗。
        // PTS 不可用(0, 旧调用方)回退旧时间窗
        BOOL boundary;
        if (pts > 0) {
            boundary = (pts != self->_lastAdvancePts);
        } else {
            boundary = (nowQ - self->_lastGenAdvanceTime) >= (1.0 / vfps);
        }
        if (_liveYUVPixelBuffer &&
            (liveGen != self->_syncDisplayGen) && (liveGen < self->_syncDisplayGen || boundary)) {
            if (self->_syncDisplayFrame) CVPixelBufferRelease(self->_syncDisplayFrame);
            self->_syncDisplayFrame = CVPixelBufferRetain(_liveYUVPixelBuffer);
            self->_syncDisplayGen = liveGen;
            self->_lastGenAdvanceTime = nowQ;
            self->_lastAdvancePts = pts;
        }
    }
    CVPixelBufferRef yuv = self->_syncDisplayFrame;
    if (yuv) CVPixelBufferRetain(yuv);
    uint64_t gen = self->_syncDisplayGen;
    [_processLock unlock];
    // 帧代数经 writeFrame:toPixelBuffer:token: 参数传递(不写 gpuProcessor 全局属性,
    // 多 hook 线程并发 render 时全局赋值会互相覆盖导致 staging 误用别帧内容)
    CVPixelBufferRef bgra = NULL;

    // CPU 闭环降载(2026-08-16 扫码 CPU 配额被杀最终修复 v3, 取代所有"猜流"启发式):
    // 教训链: 方向判定误伤录像流(跳动)/照片流跳帧闪预览/低分辨率照片流判定误伤
    // 抖音美颜链(比例跳动)+漏掉扫码页可见流 —— 任何"猜哪条流不可见"都不可靠。
    // 物理约束: iOS daemon CPU 限 50% over 180s, 3 流全速替换 67% 必被杀。
    // 唯一两全: 全流全帧替换(永不闪) + CPU 接近红线时冻结内容源 ——
    // 两步法 staging(token) 机制天然支持: 传旧 token → 跳过昂贵缩放(stage1 ~4ms),
    // 只做格式转换(stage2 ~2ms) → 单帧成本降 ~60%, 画面=低帧率视频(连续无感)。
    // 解码/预渲染同步 15fps(降载期), CCW90 随冻结 token 自动复用。
    //
    // 采样修正(2026-08-16 振荡修复): task_threads 是瞬时快照, 线程退出/加入会让
    // 累计时间差分出现负值(实测 -5%~-50%) → 冻结误判 OFF → 又冲高误判 ON →
    // 12s 内 3 次横跳 = 用户观感"非常卡顿"的直接来源。修: 负差分丢弃(不更新基线,
    // 本次不判退); EMA 平滑抗单次毛刺。
    // 滞回时间窗: 进入后 ≥5s 不许退出, 退出后 ≥8s 不许再进 —— 防高频振荡
        // 紧急档重构(2026-08-17 横跳根治): 旧 46/48 阈值在正常运行区(实测 45-58%)
        // 内部横跳 → 内容 24↔20fps 反复切换 = 卡顿本身。教训: 系统配额是
        // 180s 均值 50%, 短时 45-58% 峰值完全安全(telemetry 实测无 kill,
        // renders 持续累积)。降载只在真失控(>80%, 如多流突发+解码堆积)时介入,
        // <60% 退出 —— 正常使用永不触发, 内容恒定 24fps。
        {
            static CFAbsoluteTime lastCpuCheck = 0;
            static CFAbsoluteTime lastCpuSample = 0;
            static double lastCpuSec = 0;
            static double emaPct = 0;              // EMA 平滑后 CPU%
            static BOOL emaInit = NO;
            static BOOL lowPower = NO;
            static CFAbsoluteTime lastModeSwitch = 0;  // 上次 ON/OFF 切换时刻
            // 启动冷却(2026-08-18 6秒三连崩根因): mediaserverd 启动/重启后首帧,
            // 相机管线初始化 + 视频加载 + 帧队列预填全速叠加 → CPU 冲 195%
            // (telemetry 实证) → runningboardd 杀(EXC_RESOURCE CPU, 无 .ips) →
            // 重启又冲 → 6 秒三连崩循环。首帧起 10s 强制 lowPower(解码/预渲染
            // 20fps 上限), 系统稳住后转 CPU 闭环接管。static 生命周期 = 进程级,
            // mediaserverd 重启归零重新生效, 相机开关(App 切换)不误触发
            static CFAbsoluteTime bootGraceUntil = 0;
            static BOOL bootGraceDone = NO;
            CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
            if (!bootGraceDone) {
                if (bootGraceUntil == 0) {
                    bootGraceUntil = nowT + 10.0;
                    lowPower = YES;
                    vcam_core_log(@"[vcam] boot grace: forced throttle 10s (startup storm guard)");
                } else if (nowT >= bootGraceUntil) {
                    bootGraceDone = YES;
                    lastModeSwitch = nowT;  // 退出判定从冷却结束起算
                    vcam_core_log(@"[vcam] boot grace ended, CPU loop takes over");
                }
            }
            BOOL graceOn = !bootGraceDone;  // 冷却期内强制低功率
            if (nowT - lastCpuCheck > 0.8) {  // 2s→0.8s(2026-08-18): 响应提速, 旧 2s+EMA 滞后 4-6s 挡不住启动风暴
                double cpuSec = [vcam_process_cpu_seconds() doubleValue];
                double delta = cpuSec - lastCpuSec;
                if (lastCpuSec > 0 && nowT > lastCpuSample && delta >= 0) {
                    double pct = delta / (nowT - lastCpuSample) * 100.0;
                    emaPct = emaInit ? (emaPct * 0.5 + pct * 0.5) : pct;  // 0.6/0.4→0.5/0.5 更灵敏
                    emaInit = YES;
                    // 进入快(2s)/退出慢(10s): 2026-08-18 重构 —— 旧 8s 进入 hold
                    // 在启动风暴里形同虚设(6 秒内死 3 次); 退出放慢防振荡
                    BOOL minHoldOk = (nowT - lastModeSwitch) > (lowPower ? 10.0 : 2.0);
                    // 硬闸: EMA>110% = 逼近 2 核, 无视 hold 立即压(秒级尖峰也杀进程)
                    BOOL hardTrip = (emaPct > 110.0);
                    // 阈值(2026-08-18): 72% 提前介入给 runningboardd 留余量;
                    if ((emaPct > 72.0 || hardTrip) && !lowPower && (minHoldOk || hardTrip)) {
                        lowPower = YES;
                        lastModeSwitch = nowT;
                        vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% (ema) >72%%, EMERGENCY throttle ON", emaPct]);
                    } else if (emaPct < 55.0 && lowPower && minHoldOk && !graceOn) {
                        lowPower = NO;
                        lastModeSwitch = nowT;
                        vcam_core_log([NSString stringWithFormat:@"[vcam] CPU %.0f%% (ema) <55%%, throttle OFF", emaPct]);
                    }
                }
            // 负差分(线程快照抖动): 只推进时间基线, 不更新 CPU 基线(下轮重算), 不判退
            lastCpuSample = nowT;
            if (delta >= 0 || lastCpuSec == 0) lastCpuSec = cpuSec;
            lastCpuCheck = nowT;
            self.lowPowerDecode = lowPower;  // 解码/预渲染同步降速
        }
        // 按流尺寸的内容更新节流(2026-08-16 吞吐量治理 v2):
        // 物理约束: 多流全速替换像素吞吐 22GB/30s >> daemon CPU 配额(实测 CPU 51-157%,
        // mediaserverd 照片场景 30s 被杀 3 次 = 拍照黑屏崩溃)。
        // v1 教训: 把照片取景器(2304x1650=3.8MP)节流到 12fps → 用户盯着看的主画面
        // 内容只有 12fps = 肉眼明显卡顿。取景器就是可见流, 不能低于视频内容率!
        // 0.042 可见流强制复用窗撤除(2026-08-17 卡顿修复): 与旧快照整窗同源的
        // 帧粒度采样 bug —— 30fps 流 33.3ms < 42ms 被强制喂旧 token(旧内容),
        // 66.7ms 才放行 → 私有格式两步法流内容实际 15fps。且它本质冗余:
        // 同 gen 重复渲染时 staging token 比较已自动跳过 stage1, CCW90 缓存按
        // gen 自动复用 —— 新内容到达即渲染, 旧内容自动跳过, 无需时间窗。
        // 保留: 仅不可见的拍照编码流(≥10MP, 产物是静态照片, 12MP VT 转换昂贵)
        // 放宽到 1fps; lowPower 紧急档 20fps
        {
            // 卡顿优化(2026-08-19): window==0(普通流: 非 ≥10MP 照片流且非降载档)
            // 时整块跳过 —— 旧实现每帧每流无条件 NSString 分配 + @synchronized
            // 字典读写, 8 流 × 30fps = 每秒数百次分配, 纯诊断路径白付。
            uint64_t px = (uint64_t)targetW * targetH;
            double window = px > 10000000ull ? 1.0
                          : (lowPower ? 0.05 : 0.0);
            if (window > 0.0) {
            static NSMutableDictionary<NSString *, NSDictionary *> *freezeState = nil;
            if (!freezeState) freezeState = [NSMutableDictionary dictionary];
            NSString *fk = [NSString stringWithFormat:@"%zu_%zu_%u", targetW, targetH, (unsigned)origFormat];
            @synchronized(freezeState) {
                NSDictionary *st = freezeState[fk];
                CFAbsoluteTime lastFull = st ? [st[@"t"] doubleValue] : 0;
                uint64_t lastTok = st ? [st[@"tok"] unsignedLongLongValue] : 0;
                if (lastFull > 0 && (nowT - lastFull) < window && lastTok != 0) {
                    gen = lastTok;  // 窗口内: 跳过 stage1 缩放, CCW90 复用缓存
                    // 抑制帧也推进节拍基准: 否则 60fps 流"隔帧全禁"(全渲染→长抑制→
                    // 又全渲染), 内容率掉一半; 每帧推进 → 内容精确稳定在 1/window
                    freezeState[fk] = @{@"t": @(nowT), @"tok": @(lastTok)};
                } else {
                    freezeState[fk] = @{@"t": @(nowT), @"tok": @(gen)};
                }
            }
            }  // window > 0.0
        }
    }

    // 诊断: 降频至每 600 帧(30fps 相机流 ~20s 一条, disk writes 限额保护)
    static int vcamRenderCount = 0;
    vcamRenderCount++;
    BOOL diagThisFrame = (vcamRenderCount % 600 == 1);

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
        _dedupLastTime = CFAbsoluteTimeGetCurrent();
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
    // 显示同步快照清理(2026-08-16 叠影修复配套)
    if (_syncDisplayFrame) {
        CVPixelBufferRelease(_syncDisplayFrame);
        _syncDisplayFrame = NULL;
    }
    _syncDisplayGen = 0;
    _lastGenAdvanceTime = 0;
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
    _dedupLastTime = 0;
    _dedupLastPts = 0;
    _lastAdvancePts = 0;
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

                // effectiveFps = PTS 实测帧率(校准 nominalFrameRate 低估导致的节拍慢放);
                // CPU 降载期上限 20fps(接近流畅下限; 15fps 肉眼可见卡顿)
                double fps = MIN(strongSelf.videoPlayer.effectiveFps,
                                 strongSelf.lowPowerDecode ? 20.0 : 240.0);
                nextTick += 1.0 / fps;
                double wait = nextTick - CFAbsoluteTimeGetCurrent();
                if (wait > 0.0005) {
                    [NSThread sleepForTimeInterval:wait];
                } else {
                    nextTick = CFAbsoluteTimeGetCurrent();  // 已落后(转换耗时超帧间隔), 重置基线
                }

                // 消费式取帧 + 短等待(2026-08-17 卡顿修复: 双时钟拍频):
                // 解码/预渲染是两个独立 24Hz 时钟, 相位漂移使预渲染拍点周期性
                // 落在解码入队之前 → dequeue 空 → 回退当前帧 = 同一帧重复产出两拍,
                // 下一拍取到积压帧 = 周期性"重复-紧接"节奏(拍频微卡顿)。
                // 修: 队列空时短等(≤1/3 帧间隔)让解码先产出; 再 drain-to-latest
                // 取最新(解码抖动积压 2+ 帧时防止显示滞后累积)。图片模式/暂停
                // (解码不再产出)等待自然超时走当前帧回退, 行为不变
                CVPixelBufferRef frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                if (!frame) {
                    CFAbsoluteTime waitStart = CFAbsoluteTimeGetCurrent();
                    double waitBudget = (1.0 / fps) / 3.0;
                    while (!frame && CFAbsoluteTimeGetCurrent() - waitStart < waitBudget) {
                        [NSThread sleepForTimeInterval:0.002];
                        frame = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                    }
                }
                if (frame) {
                    CVPixelBufferRef newer = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                    while (newer) {
                        CVPixelBufferRelease(frame);
                        frame = newer;
                        newer = [strongSelf.videoPlayer.frameQueue dequeuePixelBuffer];
                    }
                }
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
        // 相机重新打开时 render 同步清 pipelineIdle 即时恢复。
        // 2026-08-18 云闪付崩溃循环根因修复: 只停 CPU 不够 —— 部分扫码 App 的
        // 相机流不经过 hook 节点, mediaserverd 被系统判 inactive, 而 dylib 已初始化
        // 的 footprint 124MB > inactive jetsam 硬限 75MB → 5-6s 击杀 → 崩溃循环
        // (renders=0 即被杀, CPU 仅 1%, 无 .ips, telemetry fp=124MB 实证)。
        // 暂停时同步卸载媒体管线(reader/asset/帧队列/预渲染缓冲), 把 footprint
        // 压回线下; 恢复时冻结快照帧顶住 + 异步重载(~几百 ms)无缝跟上
        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && !strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 2.0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastIdleResumeTime) > 5.0) {  // 恢复保持(2026-08-19): 恢复重载后 5s 内不重复卸载
            strongSelf->_pipelineIdle = YES;
            [strongSelf->_videoPlayer stopDecodingThread];
            strongSelf->_idleResumePath = [strongSelf->_videoPlayer currentVideoPath];
            [strongSelf->_videoPlayer unloadForIdle];
            [strongSelf->_gpuProcessor releaseHeavyBuffersForIdle];
            // live 帧链也释放(2026-08-18 砍常驻内存): 预渲染线程已因 pipelineIdle
            // 睡眠不再产出, _syncDisplayFrame 快照独立 retain 旧内容, 恢复期间
            // render 冻结显示快照(L353 的 _liveYUV 为 NO 不推进), 重载完成后无缝跟上。
            // 持 _processLock 与 render 线程互斥(该字段 render 侧同锁访问)
            [strongSelf->_processLock lock];
            if (strongSelf->_liveYUVPixelBuffer) {
                CVPixelBufferRelease(strongSelf->_liveYUVPixelBuffer);
                strongSelf->_liveYUVPixelBuffer = NULL;
            }
            if (strongSelf->_liveBGRAPixelBuffer) {
                CVPixelBufferRelease(strongSelf->_liveBGRAPixelBuffer);
                strongSelf->_liveBGRAPixelBuffer = NULL;
            }
            if (strongSelf->_cachedProcessedFrame) {
                CVPixelBufferRelease(strongSelf->_cachedProcessedFrame);
                strongSelf->_cachedProcessedFrame = NULL;
            }
            [strongSelf->_processLock unlock];
            strongSelf->_idleUnloaded = YES;
            vcam_core_log(@"[vcam] camera idle >2s, pipeline paused + media unloaded (jetsam guard)");
        }

        // 深度空闲内存释放(2026-08-17 偶发全黑优化): 空闲暂停后再等 58s(排除
        // 快速开关相机场景, 避免重建开销), 释放 GPU 池全部流资源(组 staging
        // ~45MB+ per-key session/staging/cache)。mediaserverd inactive jetsam
        // 硬限 75MB, 空闲 footprint 120MB+ 会被杀 → 下次开相机黑屏 2-3s。
        // 恢复渲染时惰性重建(首帧一次性 ~10-20ms)。
        // 12s→60s(2026-08-18 云闪付扫码黑屏): 扫码页相机流周期性静默/唤醒, 12s 窗口
        // 造成"释放→重建→释放"循环, 每轮重建 session/staging 是 CPU 尖峰, 叠加扫码
        // 多流稳态负载推高 CPU → runningboardd 杀进程。60s 只在真长期空闲(锁屏/退
        // 出相机)才释放, 扫码场景不再循环。
        if (strongSelf.isMediaserverdProcess && strongSelf.enabled && strongSelf.pipelineIdle &&
            strongSelf->_lastRenderActivity > 0 &&
            (CFAbsoluteTimeGetCurrent() - strongSelf->_lastRenderActivity) > 60.0) {
            static CFAbsoluteTime lastIdleRelease = 0;
            CFAbsoluteTime nowIdle = CFAbsoluteTimeGetCurrent();
            // 释放一次后不再重复(资源已空); render 心跳恢复后再空闲才会重新进入
            if (nowIdle - lastIdleRelease > 30.0) {
                lastIdleRelease = nowIdle;
                [strongSelf->_gpuProcessor releaseIdleMemory];
                vcam_core_log(@"[vcam] camera idle >60s, GPU stream pools released (jetsam guard)");
            }
        }

        // 资源探针(2026-08-16 黑屏取证 v2): 每 30s 一行内存/CPU%/按流渲染统计
        // 修复(2026-08-16): takeStreamStats 是"取出并清零"语义, 之前每 0.15s 轮询调用
        // → 统计被高频清零, telemetry 里只剩最后 0.15s 的数据(9 vs 实际 1376)。
        // 节流到 30s 窗口到点才取, 统计恢复真实
        if (strongSelf.isMediaserverdProcess) {
            static CFAbsoluteTime lastStatsTake = 0;
            CFAbsoluteTime nowStats = CFAbsoluteTimeGetCurrent();
            if (nowStats - lastStatsTake >= 30.0) {
                lastStatsTake = nowStats;
                vcam_telemetry_sample(strongSelf->_frameCount,
                                      [strongSelf->_gpuProcessor takeStreamStats]);
            }
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
                [strongSelf.videoPlayer resetPlaybackPosition];  // 清续播位置, 真从头播(2026-08-19)
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
