//
//  GPUImageProcessor.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 GPUImageProcessor 实现
//

#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// 手动声明 VideoToolbox 类型和函数（不依赖 SDK 头文件，避免类型冲突）
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
OSStatus VTSessionSetProperty(CFTypeRef session, CFStringRef propertyKey, CFTypeRef propertyValue);

// VTPixelRotationSession 私有 API 函数指针类型
typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

// 日志总开关(2026-08-16, diskwrites 崩溃循环止血): 默认静默, vc.plist "logEnabled=YES" 打开
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

static void vcam_gpu_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_gpu_log.txt";
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

@interface GPUImageProcessor ()
// 会话（VT session 非线程安全且内部缓存 pipeline 状态, 必须按用途隔离）
// 对齐千面 render 逆向(0xb0f8-0xb154): 按目标格式三套 session
//   BGRA 目标 -> 专用 session(千面 _0xe8) / 420v/420f 目标 -> 专用 session(千面 _0xf0)
//   其他私有格式(|8v0/-8f0/p420 等) -> base session(千面 _0x30), 千面对所有格式无白名单全 transfer
@property (nonatomic, assign) VTPixelTransferSessionRef bgraTransferSession;       // render 线程: BGRA 目标专用
@property (nonatomic, assign) VTPixelTransferSessionRef yuvTransferSession;        // render 线程: 420v/420f 目标专用
@property (nonatomic, assign) VTPixelTransferSessionRef privateTransferSession;    // render 线程: 私有格式目标专用(base, 隔离状态)
@property (nonatomic, assign) VTPixelTransferSessionRef prerenderTransferSession;  // 预渲染线程专用
// 私有格式两步法中转: 已迁移到下方 per-key 池(2026-08-15), 旧单例字段移除
// 两步法按流池化(2026-08-15): 相机多条流(预览/照片/录像)目标尺寸各异,
// 共用一个 session/staging 交替不同尺寸 → VT 内部 pipeline 状态污染 → 偶发
// -12905 → writeFrame NO → 替换画面中断(黑屏/闪回相机)。
// session/staging/token 按 "dstW_dstH_fmt" 独立, 各流互不干扰
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepSessionPool;    // key -> session 指针
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepStagingPool;    // key -> CVPixelBufferRef 指针(池持有引用)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepTokenPool;     // key -> staging 内容帧代数
// 2step 失败熔断(2026-08-15, App 相机黑屏根因): App 摄像头带 328x184 '18f0' 微型分析流,
// VT 不支持该组合(-12905), 高频流上"失败→重建 session→再失败"每秒 8 次 → mediaserverd
// wakeups 资源超限被杀 → 死循环重启(6s/次) → 所有相机黑屏。
// 同 key 连续失败 ≥2 次即熔断: 永久跳过该流两步法(保留相机原帧, 分析流无视觉影响),
// 不再创建/销毁 session
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepFailCountPool; // key -> 连续失败计数
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepDisabledPool;  // key -> 熔断标记

// 按流并行体系(2026-08-16 自研优化: VT 会话+锁全部 per-stream):
// 旧版一步 transfer 按格式 3 把锁 —— 同格式的多条流(如 QQ 两条 420f 流)共用
// 一个 session 串行执行, 多流场景 render 排队延迟大。现改为 per-(w,h,fmt) 池化:
// 每条流独立 session + 独立锁, 全部流完全并行 VT transfer。
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *oneStepSessionPool;   // key -> session
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *oneStepKeyLockPool;   // key -> lock
@property (nonatomic, strong) NSLock *rotationRenderLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *twoStepKeyLockPool;
@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;
// render 路径专用旋转 session（非线程安全: 预渲染线程与 render 线程并发用同一 session 会崩溃）
@property (nonatomic, assign) VTPixelRotationSessionRef renderRotationSession;
// 自适应旋转 buffer 缓存（按 尺寸+格式 复用, 避免拍照流每帧创建 ~3MB buffer; 仅 renderLock 内访问）
@property (nonatomic, assign) CVPixelBufferRef adaptiveRotateCache;
@property (nonatomic, assign) size_t adaptiveRotateCacheW;
@property (nonatomic, assign) size_t adaptiveRotateCacheH;
@property (nonatomic, assign) OSType adaptiveRotateCacheFmt;
// 旋转结果帧代数: 同一帧(token)多流渲染时只 rotate 一次, 后续流直接复用
@property (nonatomic, assign) uint64_t adaptiveRotatedGen;
// 流 key LRU 顺序(2026-08-16 黑屏修复): per-key 池(session+staging 12MB 级 buffer)
// 无上限增长 —— App 切前后摄/分辨率/多流组合变化时 key 只增不减, 内存缓慢累积 →
// mediaserverd 内存超限被杀 → 相机黑屏(重进恢复=重启清零, 再累积再黑, 周期循环)。
// 超 kVcamMaxStreamKeys 淘汰最久未用 key(释放 session+staging), 熔断标记保留
@property (nonatomic, strong) NSMutableArray<NSString *> *streamKeyOrder;

// 私有 API 函数指针
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
// 千面逆向确认(0xb094/0xe598): 属性是 kVTPixelRotationPropertyKey_Rotation,
// 值是 CFString 常量 kVTRotation_CCW90/CW90/180 (不是 RotationInDegrees + 数字!)
@property (nonatomic, assign) CFStringRef rotationPropertyKey;
@property (nonatomic, assign) CFStringRef rotationCCW90Value;
@property (nonatomic, assign) CFStringRef rotationCW90Value;
@property (nonatomic, assign) CFStringRef rotation180Value;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

// 预渲染旋转输出 3 槽轮转 buffer(仅预渲染线程访问):
// 旋转若每帧 CVPixelBufferCreate ~3MB(1080p 420f) = 30fps 下 90MB/s 分配释放,
// malloc 压力 + 内存碎片 → 卡顿/不稳。live 缓存 + render fallback + in-flight
// transfer 最多同时持有 2 帧旧输出, 3 槽轮转保证写入槽不被任何读者持有
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool0;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool1;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool2;
@property (nonatomic, assign) int prerenderRotateSlot;
// 镜像专用 buffer(mirror-only 场景: 无旋转时需先复制到自有 buffer 再原地行反转,
// 解码器输出的 buffer 不可写)。预渲染线程独占, 按尺寸+格式缓存
@property (nonatomic, assign) CVPixelBufferRef prerenderMirrorBuffer;
@property (nonatomic, assign) size_t prerenderMirrorW;
@property (nonatomic, assign) size_t prerenderMirrorH;
@property (nonatomic, assign) OSType prerenderMirrorFmt;

// CIContext（软件渲染，mediaserverd 没有 GPU 上下文）
// 两个独立 CIContext: 预渲染线程用 preprocessContext, render 线程回退用 renderContext（CIContext 非线程安全）
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) CIContext *renderContext;

// 缓冲池字典（key="w_h", value=CVPixelBufferPoolRef）—— 每个尺寸独立池，避免频繁重建
@property (nonatomic, strong) NSMutableDictionary *bgraBufferPoolMap;

// 内部方法（前向声明，让 ARC 正确处理 CF_RETURNS_RETAINED）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;
@end

@implementation GPUImageProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rotationAngle = 0;
        _mirrored = NO;
        _rotationApiAvailable = NO;
        _bgraTransferSession = NULL;
        _yuvTransferSession = NULL;
        _privateTransferSession = NULL;
        _prerenderTransferSession = NULL;
        _pixelRotationSession = NULL;
        _bgraBufferPoolMap = [[NSMutableDictionary alloc] init];
        _twoStepSessionPool = [[NSMutableDictionary alloc] init];
        _twoStepStagingPool = [[NSMutableDictionary alloc] init];
        _twoStepTokenPool = [[NSMutableDictionary alloc] init];
        _twoStepFailCountPool = [[NSMutableDictionary alloc] init];
        _twoStepDisabledPool = [[NSMutableDictionary alloc] init];
        _oneStepSessionPool = [[NSMutableDictionary alloc] init];
        _oneStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _rotationRenderLock = [[NSLock alloc] init];
        _twoStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _adaptiveRotatedGen = 0;
        _streamKeyOrder = [NSMutableArray array];

        // 软件渲染 CIContext（mediaserverd 没有 GPU 上下文）
        @try {
            _preprocessContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
            _renderContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _preprocessContext = nil;
            _renderContext = nil;
        }

        [self setupBGRATransferSession];
        [self setupYUVTransferSession];
        [self setupPrerenderTransferSession];
        [self setupPixelRotationSession];
        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized");
    }
    return self;
}

- (void)dealloc {
    typedef void (*InvalidateFunc)(VTPixelTransferSessionRef);
    if (_bgraTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_bgraTransferSession);
    }
    if (_yuvTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_yuvTransferSession);
    }
    if (_prerenderTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_prerenderTransferSession);
    }
    if (_privateTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_privateTransferSession);
    }
    // 释放两步法池(per-key session + staging buffer)
    {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        for (NSValue *v in _twoStepSessionPool.allValues) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
            if (s && invalidate) invalidate(s);
        }
        for (NSValue *v in _twoStepStagingPool.allValues) {
            CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        [_twoStepSessionPool removeAllObjects];
        [_twoStepStagingPool removeAllObjects];
        [_twoStepTokenPool removeAllObjects];
        // 一步 transfer per-stream session 池
        for (NSValue *v in _oneStepSessionPool.allValues) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
            if (s && invalidate) invalidate(s);
        }
        [_oneStepSessionPool removeAllObjects];
    }
    // 释放旋转 session 与自适应旋转缓存
    {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionInvalidate");
        if (invalidate) {
            if (_pixelRotationSession) invalidate((VTPixelTransferSessionRef)_pixelRotationSession);
            if (_renderRotationSession) invalidate((VTPixelTransferSessionRef)_renderRotationSession);
        }
    }
    if (_adaptiveRotateCache) {
        CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = NULL;
    }
    // 释放预渲染旋转 3 槽池 + 镜像 buffer
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setPrerenderRotateBuffer:NULL atSlot:i];
    }
    if (_prerenderMirrorBuffer) {
        CVPixelBufferRelease(_prerenderMirrorBuffer);
        _prerenderMirrorBuffer = NULL;
    }
    // 释放所有缓冲池
    for (id key in _bgraBufferPoolMap) {
        CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key];
        CVPixelBufferPoolRelease(pool);
    }
    [_bgraBufferPoolMap removeAllObjects];
    vcam_gpu_log(@"[vcam] GPUImageProcessor deallocated");
}

#pragma mark - Session 初始化

- (void)setupBGRATransferSession {
    if (_bgraTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_bgraTransferSession);
    if (status == noErr) {
        // 对齐千面 init 反汇编(0xa494-0xa518): 三个 session 仅设 ScalingMode=Trim, 无 RealTime
        // 千面导入 kVTScalingMode_Trim: 保宽高比填充目标 + 裁剪超出部分(crop fill)
        VTSessionSetProperty(_bgraTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] BGRA VTPixelTransferSession created (Trim only)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create BGRA session: %d", (int)status]);
    }
}

- (void)setupYUVTransferSession {
    if (_yuvTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_yuvTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_yuvTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] YUV VTPixelTransferSession created (Trim only)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create YUV session: %d", (int)status]);
    }
}

- (void)setupPrerenderTransferSession {
    if (_prerenderTransferSession) return;
    // 预渲染线程专用 session（与 render 的 session 分离, 避免并发调用崩溃）
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_prerenderTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_prerenderTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Prerender VTPixelTransferSession created (Trim)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create prerender session: %d", (int)status]);
    }
}

- (void)setupPrivateTransferSession {
    if (_privateTransferSession) return;
    // 私有格式目标(|xv0/|8v0/-8f0/p420 等)专用 session:
    // 与标准格式 session 隔离 —— 私有格式的 pipeline 会改写 session 内部状态,
    // 混用会污染标准流(之前照片模式上下反复拉伸的教训)
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_privateTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_privateTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Private-format VTPixelTransferSession created (Trim)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create private session: %d", (int)status]);
    }
}

// 两步法 per-key session 存取(renderLock 内调用, 无并发)
- (VTPixelTransferSessionRef)twoStepSessionForKey:(NSString *)key {
    NSValue *v = _twoStepSessionPool[key];
    if (v) return (VTPixelTransferSessionRef)[v pointerValue];
    VTPixelTransferSessionRef s = NULL;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        _twoStepSessionPool[key] = [NSValue valueWithPointer:s];
        return s;
    }
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] failed to create 2step session for %@", key]);
    return NULL;
}

- (void)invalidateTwoStepSessionForKey:(NSString *)key {
    NSValue *v = _twoStepSessionPool[key];
    if (!v) return;
    VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
    if (s) {
        void (*invalidate)(VTPixelTransferSessionRef) =
            (void (*)(VTPixelTransferSessionRef))dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(s);
    }
    [_twoStepSessionPool removeObjectForKey:key];
    // session 重建后 staging 内容仍有效(纯格式转换), token 保留以继续复用缩放
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    // dlsym(RTLD_DEFAULT) 在 mediaserverd 中找不到 VideoToolbox 私有符号
    // (rotation session 因此从未创建, 自适应旋转从未执行)。
    // 改为显式 dlopen VideoToolbox 后在其镜像内查找。
    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY | RTLD_GLOBAL);
    void *base = vt ? vt : RTLD_DEFAULT;

    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(base, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(base, "VTPixelRotationSessionRotateImage");

    // 注意: kVTPixelRotationPropertyKey_* / kVTRotation_* 是 CFStringRef 全局变量,
    // dlsym 返回的是变量地址, 需解引用拿到 CFString 对象; 解引用失败回退已知字符串值。
    // 千面逆向(0xb094/0xe598)确认: 属性 kVTPixelRotationPropertyKey_Rotation,
    // 值为 kVTRotation_CCW90 / kVTRotation_CW90 / kVTRotation_180 CFString 常量
    void *rotSym = dlsym(base, "kVTPixelRotationPropertyKey_Rotation");
    _rotationPropertyKey = rotSym ? *(CFStringRef *)rotSym : CFSTR("Rotation");
    void *ccwSym = dlsym(base, "kVTRotation_CCW90");
    _rotationCCW90Value = ccwSym ? *(CFStringRef *)ccwSym : CFSTR("CCW90");
    void *cwSym = dlsym(base, "kVTRotation_CW90");
    _rotationCW90Value = cwSym ? *(CFStringRef *)cwSym : CFSTR("CW90");
    void *r180Sym = dlsym(base, "kVTRotation_180");
    _rotation180Value = r180Sym ? *(CFStringRef *)r180Sym : CFSTR("180");
    void *flipSym = dlsym(base, "kVTPixelRotationPropertyKey_FlipHorizontalOrientation");
    _flipHorizontalKey = flipSym ? *(CFStringRef *)flipSym : CFSTR("FlipHorizontalOrientation");

    vcam_gpu_log([NSString stringWithFormat:@"[vcam] rotation api probe: handle=%d create=%d rotate=%d rotKey=%d ccw=%d cw=%d r180=%d flipKey=%d",
                  vt != NULL, _createRotationSession != NULL, _transferRotationImage != NULL,
                  rotSym != NULL, ccwSym != NULL, cwSym != NULL, r180Sym != NULL, flipSym != NULL]);

    if (!_createRotationSession || !_transferRotationImage) {
        _rotationApiAvailable = NO;
        vcam_gpu_log(@"[vcam] VTPixelRotationSession API unavailable (adaptive rotation disabled)");
        return;
    }

    OSStatus status = _createRotationSession(kCFAllocatorDefault, &_pixelRotationSession);
    if (status == noErr) {
        _rotationApiAvailable = YES;
        // render 路径专用第二个 session（预渲染与 render 并发旋转同一 session 会崩溃）
        OSStatus st2 = _createRotationSession(kCFAllocatorDefault, &_renderRotationSession);
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession created (render session: %d)", (int)st2]);
    } else {
        _rotationApiAvailable = NO;
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create VTPixelRotationSession: %d", (int)status]);
    }
}

#pragma mark - 缓冲池（多池字典，每个尺寸独立池，避免频繁重建）

- (CVPixelBufferPoolRef)getOrCreatePoolForWidth:(size_t)width height:(size_t)height format:(OSType)format {
    if (width == 0 || height == 0) return NULL;

    // 池字典非线程安全: render 线程与预渲染线程(convertFormat 回退)都会访问
    @synchronized(self) {
        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", width, height, (unsigned)format];
        id existing = _bgraBufferPoolMap[key];
        if (existing) {
            return (__bridge CVPixelBufferPoolRef)existing;
        }
        // 新建池纳入流 key LRU(与 session/staging 同一上限管理, 防尺寸种类累积)
        [self touchStreamKeyLRU:key];

        // 创建新池（关键约束：不能用 kCVPixelBufferIOSurfacePropertiesKey）
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
        };
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferWidthKey:  @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        };

        CVPixelBufferPoolRef pool = NULL;
        OSStatus status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            (__bridge CFDictionaryRef)poolAttributes,
            (__bridge CFDictionaryRef)pixelBufferAttributes,
            &pool
        );

        if (status != noErr) {
            // 回退：NULL pool attributes
            status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                NULL,
                (__bridge CFDictionaryRef)pixelBufferAttributes,
                &pool
            );
        }

        if (status == noErr && pool) {
            _bgraBufferPoolMap[key] = (__bridge id)pool;
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Created buffer pool: %zux%zu fmt=%u (key=%@)", width, height, (unsigned)format, key]);
            return pool;
        }

        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create buffer pool: %d, %zux%zu", (int)status, width, height]);
        return NULL;
    }
}

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    @synchronized(self) {
        CVPixelBufferPoolRef pool = [self getOrCreatePoolForWidth:width height:height format:kCVPixelFormatType_32BGRA];

        CVPixelBufferRef buffer = NULL;
        if (pool) {
            OSStatus status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
            if (status == noErr && buffer) {
                return buffer;
            }
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to get buffer from pool: %d", (int)status]);
        }

        // 回退：直接创建（不带 IOSurface 属性）
        OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &buffer);
        if (status != noErr) {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, %zux%zu BGRA", (int)status, width, height]);
            return NULL;
        }
        return buffer;
    }
}

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format {
    [self getOrCreatePoolForWidth:width height:height format:format];
    NSString *fmtStr = [self stringForFormat:format];
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] GPUImageProcessor configured: %zux%zu format: %@", width, height, fmtStr]);
}

#pragma mark - 核心处理

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;

    @try {
        size_t inW = CVPixelBufferGetWidth(input);
        size_t inH = CVPixelBufferGetHeight(input);

        int total = (_sourceRotation + _rotationAngle) % 360;
        if (total < 0) total += 360;

        // 旋转后的尺寸
        size_t rotW = inW, rotH = inH;
        if (total == 90 || total == 270) {
            rotW = inH;
            rotH = inW;
        }

        // 1. 旋转/镜像（如果需要）→ BGRA
        CVPixelBufferRef processedBuffer = NULL;
        if ((total != 0 || _mirrored) && _rotationApiAvailable && _pixelRotationSession) {
            processedBuffer = [self rotateAndMirror:input width:rotW height:rotH angle:total];
        }
        // 如果旋转失败或不需要旋转，直接用输入
        if (!processedBuffer) {
            processedBuffer = input;
            CVPixelBufferRetain(processedBuffer);
        }

        // 2. 缩放到目标尺寸的 BGRA（CoreImage 擅长 BGRA→BGRA 缩放）
        //    VTPixelTransferSession 不支持缩放，必须先缩放到目标尺寸再做格式转换
        size_t curW = CVPixelBufferGetWidth(processedBuffer);
        size_t curH = CVPixelBufferGetHeight(processedBuffer);
        if (curW != width || curH != height) {
            CVPixelBufferRef scaledBGRA = [self scaleToBGRA:processedBuffer width:width height:height];
            CVPixelBufferRelease(processedBuffer);
            processedBuffer = scaledBGRA;  // scaledBGRA 已 retain (CF_RETURNS_RETAINED)
            if (!processedBuffer) {
                return NULL;
            }
        }

        // 3. 格式转换（BGRA → 目标格式，同尺寸）
        CVPixelBufferRef outputBuffer = NULL;
        if (format == kCVPixelFormatType_32BGRA) {
            // 目标格式是 BGRA，直接返回缩放后的缓冲区
            outputBuffer = processedBuffer;
        } else {
            // 用 VTPixelTransferSession 转换格式（同尺寸 BGRA→YUV）
            outputBuffer = [self createBufferWithWidth:width height:height format:format];
            if (outputBuffer) {
                OSStatus status = VTPixelTransferSessionTransferImage(_yuvTransferSession, processedBuffer, outputBuffer);
                if (status != noErr) {
                    NSString *fmtStr = [self stringForFormat:format];
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelTransferSession failed: %d, format: %@", (int)status, fmtStr]);
                    // 回退到 CoreImage（同尺寸 BGRA→YUV）
                    CVPixelBufferRelease(outputBuffer);
                    outputBuffer = [self convertWithCoreImage:processedBuffer toFormat:format width:width height:height];
                }
            }
            CVPixelBufferRelease(processedBuffer);
        }

        return outputBuffer;
    } @catch (NSException *e) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Exception in processPixelBuffer: %@", e]);
        return NULL;
    }
}

// crop fill: 保持宽高比, 填充整个目标, 裁剪超出部分（无黑边, 居中）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    if (inW == 0 || inH == 0 || width == 0 || height == 0) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef output = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!output) return NULL;

    // crop fill: 取较大缩放比填充整个目标, 超出部分裁剪（无黑边）
    CGFloat scale = MAX((CGFloat)width / (CGFloat)inW, (CGFloat)height / (CGFloat)inH);
    CGFloat scaledW = (CGFloat)inW * scale;
    CGFloat scaledH = (CGFloat)inH * scale;
    // 居中偏移（负值 = 图像超出目标边界, 被 bounds 裁剪）
    CGFloat offsetX = ((CGFloat)width - scaledW) / 2.0;
    CGFloat offsetY = ((CGFloat)height - scaledH) / 2.0;

    // 变换: 缩放后平移到居中位置
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    // 千面用 DeviceRGB 渲染(逆向: CGColorSpaceCreateDeviceRGB + render:colorSpace:),
    // sRGB 会导致照片流(-8f0 full-range)高光过爆
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:scaled toCVPixelBuffer:output
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    
    return output;
}

- (CVPixelBufferRef)rotateAndMirror:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height angle:(int)angle CF_RETURNS_RETAINED {
    if (!input || !_pixelRotationSession) return NULL;

    // 目标缓冲保持源格式（对齐千面 rotateBuffer: 0xe514-0xe578:
    // GetPixelFormatType(src) → CVPixelBufferCreate(同格式) —— 420f 源旋转后仍是 420f,
    // range/矩阵 attachments 语义保持, 不做 BGRA 中转）
    OSType srcFormat = CVPixelBufferGetPixelFormatType(input);
    CVPixelBufferRef dst = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, srcFormat, NULL, &dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create rotation buffer: %d", (int)status]);
        return NULL;
    }

    // 设置旋转角度（千面 prerender rotateBuffer 用 kVTRotation_* 常量值, 90=CW90 与其一致）
    // angle==0 也显式设置: 不设置会残留上一次的角度, 只镜像场景会多转 90/270
    if (angle == 90) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotationCW90Value);
    } else if (angle == 180) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotation180Value);
    } else if (angle == 270) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    } else {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, kCFBooleanFalse);  // 显式归零防残留
    }
    // 设置镜像
    VTSessionSetProperty(_pixelRotationSession, _flipHorizontalKey, _mirrored ? kCFBooleanTrue : kCFBooleanFalse);

    status = _transferRotationImage(_pixelRotationSession, input, dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession failed: %d", (int)status]);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    return dst;
}

// 3 槽存取 helper(仅预渲染线程 + dealloc 调用)
- (CVPixelBufferRef)prerenderRotateBufferAtSlot:(int)slot {
    if (slot == 0) return _prerenderRotatePool0;
    if (slot == 1) return _prerenderRotatePool1;
    return _prerenderRotatePool2;
}

- (void)setPrerenderRotateBuffer:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _prerenderRotatePool0 = buf;
    else if (slot == 1) _prerenderRotatePool1 = buf;
    else _prerenderRotatePool2 = buf;
}

// CPU 水平镜像(原地行反转): 420f/420v Y 平面按 1 字节粒度、UV 平面按 2 字节粒度
// (CbCr 对不能拆开), BGRA 按 4 字节粒度。~3MB 帧约 1ms(预渲染线程可承受)。
// 千面二进制无任何 Flip 属性字符串 —— VTPixelRotationSession 的 flip 在 420f 上
// 不支持(-12914), 镜像必须自己实现(对齐千面: VT 只做纯旋转)
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb) {
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, 0);
    int planes = (int)CVPixelBufferGetPlaneCount(pb);
    if (planes <= 0) {
        // 单平面 BGRA: 4 字节/像素
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t w = CVPixelBufferGetWidth(pb) * 4;
        size_t h = CVPixelBufferGetHeight(pb);
        for (size_t y = 0; y < h && base; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t l = 0, r = w - 4; l < r; l += 4, r -= 4) {
                uint32_t t = *(uint32_t *)(row + l);
                *(uint32_t *)(row + l) = *(uint32_t *)(row + r);
                *(uint32_t *)(row + r) = t;
            }
        }
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, p);
            size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(pb, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(pb, p);
            size_t px = (p == 0) ? 1 : 2;  // Y=1字节/px, UV=2字节/px(CbCr 对)
            size_t rowBytes = pw * px;
            for (size_t y = 0; y < ph && base; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t l = 0, r = rowBytes - px; l < r; l += px, r -= px) {
                    for (size_t b = 0; b < px; b++) {
                        uint8_t t = row[l + b];
                        row[l + b] = row[r + b];
                        row[r + b] = t;
                    }
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// 逐平面复制(格式/尺寸需一致, bytesPerRow 允许不同 → 逐行 min 拷贝)
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;
    int planes = (int)CVPixelBufferGetPlaneCount(src);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    if (planes <= 0) {
        uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddress(src);
        uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        size_t sbpr = CVPixelBufferGetBytesPerRow(src), dbpr = CVPixelBufferGetBytesPerRow(dst);
        size_t w = CVPixelBufferGetWidth(src) * 4, h = CVPixelBufferGetHeight(src);
        for (size_t y = 0; y < h && s && d; y++)
            memcpy(d + y * dbpr, s + y * sbpr, w);
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t px = (p == 0) ? 1 : 2;
            size_t w = CVPixelBufferGetWidthOfPlane(src, p) * px;
            size_t h = CVPixelBufferGetHeightOfPlane(src, p);
            for (size_t y = 0; y < h && s && d; y++)
                memcpy(d + y * dbpr, s + y * sbpr, w);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

// 预渲染用: 旋转(VT 纯旋转, 永不设 flip 属性 —— 420f 上 VT flip 报 -12914,
// 千面二进制亦无任何 Flip 字符串) + 镜像(CPU 行反转)。保持源格式。
// 总旋转 = 视频自带(sourceRotation) + 用户手动(rotationAngle)
- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    int total = (_sourceRotation + _rotationAngle) % 360;
    if (total < 0) total += 360;
    BOOL needRotate = (total != 0);
    BOOL needMirror = _mirrored;
    if (!needRotate && !needMirror) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    OSType fmt = CVPixelBufferGetPixelFormatType(input);

    // 阶段1: 纯旋转(VT) → 产出可写池 buffer; 失败/不需要时用原帧
    CVPixelBufferRef work = NULL;
    BOOL workIsWritable = NO;
    if (needRotate && _rotationApiAvailable && _pixelRotationSession && _transferRotationImage) {
        size_t rotW = (total == 90 || total == 270) ? inH : inW;
        size_t rotH = (total == 90 || total == 270) ? inW : inH;
        int slot = _prerenderRotateSlot;
        _prerenderRotateSlot = (slot + 1) % 3;
        CVPixelBufferRef dst = [self prerenderRotateBufferAtSlot:slot];
        if (!dst || CVPixelBufferGetWidth(dst) != rotW || CVPixelBufferGetHeight(dst) != rotH ||
            CVPixelBufferGetPixelFormatType(dst) != fmt) {
            if (dst) CVPixelBufferRelease(dst);
            dst = NULL;
            OSStatus cst = CVPixelBufferCreate(kCFAllocatorDefault, rotW, rotH, fmt, NULL, &dst);
            if (cst != noErr || !dst) {
                [self setPrerenderRotateBuffer:NULL atSlot:slot];
            } else {
                [self setPrerenderRotateBuffer:CVPixelBufferRetain(dst) atSlot:slot];
            }
        }
        if (dst) {
            CFTypeRef rotValue;
            if (total == 90)       rotValue = _rotationCW90Value;
            else if (total == 270) rotValue = _rotationCCW90Value;
            else                   rotValue = _rotation180Value;
            VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, rotValue);
            OSStatus st = _transferRotationImage(_pixelRotationSession, input, dst);
            if (st == noErr) {
                work = CVPixelBufferRetain(dst);  // 池 buffer 可写, 后续可原地镜像
                workIsWritable = YES;
            } else {
                static int rotFailLogged = 0;
                if (rotFailLogged++ < 2) {
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] prerender rotate failed: %d (keep unrotated)", (int)st]);
                }
            }
        }
    }
    if (!work) {
        work = (CVPixelBufferRef)CVPixelBufferRetain(input);  // 解码器 buffer, 不可写
    }

    // 阶段2: 镜像(CPU 行反转)
    if (!needMirror) return work;  // CF_RETURNS_RETAINED
    if (workIsWritable) {
        vcamMirrorRowsInPlace(work);
        return work;
    }
    // mirror-only: 复制到自有 buffer 再反转(不动解码器 buffer)
    if (!_prerenderMirrorBuffer || _prerenderMirrorW != inW || _prerenderMirrorH != inH ||
        _prerenderMirrorFmt != fmt) {
        if (_prerenderMirrorBuffer) CVPixelBufferRelease(_prerenderMirrorBuffer);
        _prerenderMirrorBuffer = NULL;
        CVPixelBufferRef mb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, fmt, NULL, &mb) == noErr && mb) {
            _prerenderMirrorBuffer = mb;  // 池持有
            _prerenderMirrorW = inW;
            _prerenderMirrorH = inH;
            _prerenderMirrorFmt = fmt;
        }
    }
    if (_prerenderMirrorBuffer &&
        vcamCopyPlanes(work, _prerenderMirrorBuffer)) {
        vcamMirrorRowsInPlace(_prerenderMirrorBuffer);
        CVPixelBufferRelease(work);
        return CVPixelBufferRetain(_prerenderMirrorBuffer);
    }
    // 复制失败(罕见): 返回未镜像帧, 不崩溃
    return work;
}

// 预渲染用: 同尺寸格式转换(如 BGRA -> 420f), VT 主路径 + CoreImage 回退
// 注意: 用预渲染专用 session（避免与 render 线程的 session 并发调用崩溃）
- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;
    if (CVPixelBufferGetPixelFormatType(input) == format) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    // VT transfer 同尺寸格式转换（预渲染专用 session）
    CVPixelBufferRef out = [self createBufferWithWidth:w height:h format:format];
    if (out) {
        if (!_prerenderTransferSession) {
            [self setupPrerenderTransferSession];
        }
        if (_prerenderTransferSession &&
            VTPixelTransferSessionTransferImage(_prerenderTransferSession, input, out) == noErr) {
            return out;
        }
        CVPixelBufferRelease(out);
    }

    // CoreImage 回退
    return [self convertWithCoreImage:input toFormat:format width:w height:h];
}

// writeFrame 回退路径: crop fill 渲染到任意格式目标 buffer（保持宽高比填满, 居中裁剪）
// 注意: 用 render 线程专用 CIContext（避免与预渲染线程的 context 并发崩溃）
- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst {
    if (!input || !dst || !_renderContext) return NO;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (inW == 0 || inH == 0 || w == 0 || h == 0) return NO;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NO;

    CGFloat scale = MAX((CGFloat)w / (CGFloat)inW, (CGFloat)h / (CGFloat)inH);
    CGFloat offsetX = ((CGFloat)w - (CGFloat)inW * scale) / 2.0;
    CGFloat offsetY = ((CGFloat)h - (CGFloat)inH * scale) / 2.0;
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    // renderContext 非线程安全, 内部自锁(多流并发回退时串行)
    [_rotationRenderLock lock];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_renderContext render:scaled toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:colorSpace];
    [_rotationRenderLock unlock];

    return YES;
}

// render 路径用: 自适应正交旋转 —— 源/目标宽高比正交(一横一竖)时 CCW90 旋转
// (宽高互换, 保持源格式), 预览流(竖向)与拍照/录像流(横向)各自正确方向。
// token = 帧代数: 同一帧被相机多条流渲染时只 CCW90 一次, 后续流直接复用缓存
// (每流省一次 VT rotate ~2-4ms, 多流场景 CPU 大降)。传 0 = 不缓存。
- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED {
    if (!src) return NULL;
    if (_rotationAngle != 0 || !_rotationApiAvailable || !_renderRotationSession) {
        // 用户已手动旋转(预渲染已应用)或 API 不可用
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    if (!srcW || !srcH || !targetW || !targetH) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    // 源/目标宽高比正交(一横一竖) -> CCW90
    double srcRatio = (double)srcW / (double)srcH;
    double dstRatio = (double)targetW / (double)targetH;
    BOOL orthogonal = (srcRatio > 1.0 && dstRatio < 1.0) || (srcRatio < 1.0 && dstRatio > 1.0);
    if (!orthogonal) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    // rotation session + 缓存串行锁(内部自锁, 调用方无需再包全局锁)
    [_rotationRenderLock lock];

    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    // 同帧复用(2026-08-16): 同一帧(token)已旋转过且缓存尺寸/格式匹配 → 直接返回,
    // 多流共享一次旋转结果
    if (token != 0 && _adaptiveRotatedGen == token && _adaptiveRotateCache &&
        _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW &&
        _adaptiveRotateCacheFmt == fmt) {
        CVPixelBufferRef hit = CVPixelBufferRetain(_adaptiveRotateCache);
        [_rotationRenderLock unlock];
        return hit;
    }

    // CCW90: 宽高互换, 保持源格式(YUV 源旋转后仍是 YUV, 后续 YUV->私有格式转换 range 不变)
    CVPixelBufferRef rotated = NULL;
    if (_adaptiveRotateCache && _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW && _adaptiveRotateCacheFmt == fmt) {
        rotated = CVPixelBufferRetain(_adaptiveRotateCache);  // 复用缓存(RotateImage 全覆盖写, 无需清空)
    } else {
        rotated = [self createBufferWithWidth:srcH height:srcW format:fmt];
        if (!rotated) {
            [_rotationRenderLock unlock];
            return (CVPixelBufferRef)CVPixelBufferRetain(src);
        }
        if (_adaptiveRotateCache) CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = CVPixelBufferRetain(rotated);
        _adaptiveRotateCacheW = srcH;
        _adaptiveRotateCacheH = srcW;
        _adaptiveRotateCacheFmt = fmt;
    }

    VTSessionSetProperty(_renderRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    OSStatus st = _transferRotationImage(_renderRotationSession, src, rotated);
    if (st == noErr && token != 0) {
        _adaptiveRotatedGen = token;  // 旋转成功才登记代数(失败结果不可缓存)
    }
    [_rotationRenderLock unlock];
    if (st != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] adaptive CCW90 failed: %d fmt=%@ (keep unrotated)",
                      (int)st, [self stringForFormat:fmt]]);
        CVPixelBufferRelease(rotated);
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }
    return rotated;  // CF_RETURNS_RETAINED
}

// CoreImage 回退: CI 只渲染到 BGRA(软件渲染器对 planar YUV 支持不可靠, 渲染失败会留下未初始化 buffer → 黑屏/绿屏)
// 目标是 YUV 时再用 VT transfer 转换, VT 失败返回 NULL(绝不返回未初始化的 YUV buffer)
- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    // 1. CI 渲染到 BGRA（bounds + sRGB, 软件渲染器对 BGRA 支持可靠）
    CVPixelBufferRef bgra = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!bgra) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:image toCVPixelBuffer:bgra
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    

    // 2. 目标就是 BGRA: 直接返回
    if (format == kCVPixelFormatType_32BGRA) {
        return bgra;
    }

    // 3. BGRA -> YUV 用 VT 转换（预渲染专用 session）; 失败返回 NULL
    CVPixelBufferRef output = [self createBufferWithWidth:width height:height format:format];
    if (!output) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    if (!_prerenderTransferSession) {
        [self setupPrerenderTransferSession];
    }
    if (!_prerenderTransferSession ||
        VTPixelTransferSessionTransferImage(_prerenderTransferSession, bgra, output) != noErr) {
        CVPixelBufferRelease(output);
        CVPixelBufferRelease(bgra);
        vcam_gpu_log(@"[vcam] convertWithCoreImage: VT BGRA->YUV failed, return NULL (no uninitialized buffer)");
        return NULL;
    }
    CVPixelBufferRelease(bgra);
    return output;
}

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width height:(size_t)height format:(OSType)format CF_RETURNS_RETAINED {
    CVPixelBufferRef buffer = NULL;
    // 不带 IOSurface 属性（mediaserverd 安全）
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, NULL, &buffer);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, size: %zux%zu, format: %@",
                      (int)status, width, height, [self stringForFormat:format]]);
        return NULL;
    }
    return buffer;
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    return [self transferPixelBuffer:src toPixelBuffer:dst token:0];
}

// per-key 锁获取(池字典自身用 @synchronized 保护)
- (NSLock *)twoStepLockForKey:(NSString *)key {
    @synchronized(self) {
        NSLock *l = _twoStepKeyLockPool[key];
        if (!l) {
            l = [[NSLock alloc] init];
            _twoStepKeyLockPool[key] = l;
        }
        return l;
    }
}

// 一步 transfer per-stream session/lock 获取(2026-08-16: 每流独立 session,
// 同格式多条流不再共用 session 串行 —— 多流完全并行, render 排队延迟大降)
- (VTPixelTransferSessionRef)oneStepSessionForKey:(NSString *)key {
    @synchronized(self) {
        NSValue *v = _oneStepSessionPool[key];
        if (v) return (VTPixelTransferSessionRef)[v pointerValue];
        VTPixelTransferSessionRef s = NULL;
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
            VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
            _oneStepSessionPool[key] = [NSValue valueWithPointer:s];
            return s;
        }
        return NULL;
    }
}

- (NSLock *)oneStepLockForKey:(NSString *)key {
    @synchronized(self) {
        NSLock *l = _oneStepKeyLockPool[key];
        if (!l) {
            l = [[NSLock alloc] init];
            _oneStepKeyLockPool[key] = l;
        }
        return l;
    }
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;

    OSType dstFormat = CVPixelBufferGetPixelFormatType(dst);
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);

    NSString *poolKey = [NSString stringWithFormat:@"%zu_%zu_%u", dstW, dstH, (unsigned)dstFormat];
    [self touchStreamKeyLRU:poolKey];

    BOOL isPrivate = !(dstFormat == kCVPixelFormatType_32BGRA ||
                       (dstFormat & 0xffffffef) == '420f');
    BOOL sameSize = (srcW == dstW && srcH == dstH);

    if (isPrivate && !sameSize) {
        // 两步法 per-key: 每条流一把锁 —— 拍照流/预览流/录像流完全并行
        NSLock *keyLock = [self twoStepLockForKey:poolKey];
        [keyLock lock];
        BOOL ok = [self twoStepTransferLocked:src toPixelBuffer:dst key:poolKey token:token];
        [keyLock unlock];
        return ok;
    }

    // 一步 transfer per-stream: 每条流独立 session+锁, 全流并行
    NSLock *lock = [self oneStepLockForKey:poolKey];
    VTPixelTransferSessionRef session = [self oneStepSessionForKey:poolKey];
    if (!session || !lock) return NO;

    [lock lock];
    OSStatus status = VTPixelTransferSessionTransferImage(session, src, dst);
    [lock unlock];
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VT transfer failed: %d, %@ -> %@",
                      (int)status,
                      [self stringForFormat:CVPixelBufferGetPixelFormatType(src)],
                      [self stringForFormat:dstFormat]]);
        return NO;
    }
    return YES;
}

// 流 key LRU(2026-08-16 黑屏修复): 每次流访问把 key 移到 MRU 尾部,
// 超 kVcamMaxStreamKeys 淘汰最旧 key 的全部池资源(session/staging/token/锁)。
// 防切前后摄/换分辨率场景 key 无限累积 → mediaserverd 内存超限被杀(黑屏循环)。
// 熔断标记(twoStepDisabledPool)保留: 熔断语义是永久的, 淘汰后重试已确认
// 不支持的组合会复发 wakeups 风暴。持锁中的 NSLock 淘汰安全: 持有线程栈上
// 有强引用, unlock 释放后才可能 dealloc
static const NSUInteger kVcamMaxStreamKeys = 6;

- (void)touchStreamKeyLRU:(NSString *)key {
    if (!key) return;
    @synchronized(self) {
        NSUInteger idx = [_streamKeyOrder indexOfObject:key];
        if (idx != NSNotFound) {
            [_streamKeyOrder removeObjectAtIndex:idx];
        }
        [_streamKeyOrder addObject:key];

        while (_streamKeyOrder.count > kVcamMaxStreamKeys) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;

            void (*invalidateSession)(VTPixelTransferSessionRef) =
                (void (*)(VTPixelTransferSessionRef))dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");

            // one-step session + 锁
            NSValue *osv = _oneStepSessionPool[old];
            if (osv) {
                VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[osv pointerValue];
                if (s && invalidateSession) invalidateSession(s);
                [_oneStepSessionPool removeObjectForKey:old];
            }
            [_oneStepKeyLockPool removeObjectForKey:old];

            // two-step session(大头是 staging: 12MP 流级 BGRA ~12-48MB/条)
            NSValue *tsv = _twoStepSessionPool[old];
            if (tsv) {
                VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[tsv pointerValue];
                if (s && invalidateSession) invalidateSession(s);
                [_twoStepSessionPool removeObjectForKey:old];
            }
            NSValue *stv = _twoStepStagingPool[old];
            if (stv) {
                CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
                if (b) CVPixelBufferRelease(b);
                [_twoStepStagingPool removeObjectForKey:old];
            }
            [_twoStepTokenPool removeObjectForKey:old];
            [_twoStepFailCountPool removeObjectForKey:old];
            [_twoStepKeyLockPool removeObjectForKey:old];
            // BGRA 分配池(__bridge 存储, 手动 release; 池内 idle buffer 随之释放)
            id poolObj = _bgraBufferPoolMap[old];
            if (poolObj) {
                CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)poolObj);
                [_bgraBufferPoolMap removeObjectForKey:old];
            }
            // twoStepDisabledPool 故意不清(熔断永久)

            vcam_gpu_log([NSString stringWithFormat:@"[vcam] LRU evict stream key %@ (pool now %lu)", old, (unsigned long)_streamKeyOrder.count]);
        }
    }
}

// 资源探针用: 当前 LRU 活跃 key 数
- (NSUInteger)activeStreamKeyCount {
    @synchronized(self) {
        return _streamKeyOrder.count;
    }
}

// 两步法主体(调用方已持 per-key 锁)
- (BOOL)twoStepTransferLocked:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst
                          key:(NSString *)poolKey token:(uint64_t)token {
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);

    // 失败熔断: 该流组合 VT 不支持(如 328x184 '18f0' 分析流) → 直接放弃替换。
    // 高频流上反复尝试+重建 session 会造成 wakeups 风暴 → mediaserverd 被杀
    if ([_twoStepDisabledPool[poolKey] boolValue]) {
        return NO;
    }

    // staging: 目标尺寸 BGRA 中转(每流独立, 池持有引用)
    CVPixelBufferRef staging = NULL;
    NSValue *sv = _twoStepStagingPool[poolKey];
    if (sv) staging = (CVPixelBufferRef)[sv pointerValue];
    if (!staging) {
        staging = [self createBufferWithWidth:dstW height:dstH format:kCVPixelFormatType_32BGRA];
        if (!staging) return NO;
        _twoStepStagingPool[poolKey] = [NSValue valueWithPointer:staging];  // 所有权归池
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step staging created for stream %@", poolKey]);
    }

    // 缩放复用: 同一源帧(token 未变)同流已缩放 → 跳过步骤1
    NSNumber *cachedTok = _twoStepTokenPool[poolKey];
    BOOL stagingFresh = (token != 0 && cachedTok && [cachedTok unsignedLongLongValue] == token);
    if (!stagingFresh) {
        // 步骤1: 缩放到目标尺寸 BGRA(per-key session, Trim crop fill)
        VTPixelTransferSessionRef s1 = [self twoStepSessionForKey:poolKey];
        if (!s1) return NO;
        OSStatus st1 = VTPixelTransferSessionTransferImage(s1, src, staging);
        if (st1 != noErr) {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step stage1 failed: %d key=%@", (int)st1, poolKey]);
            return NO;
        }
        _twoStepTokenPool[poolKey] = @(token);
    }

    // 步骤2: 同尺寸 BGRA → 私有格式(per-key session)。
    // 失败处理: 计数 + 熔断(不做高频 session 重建 —— 328x184 '18f0' 分析流场景
    // 曾每秒 rebuild 8 次 → wakeups 风暴 → mediaserverd 被杀死循环)
    VTPixelTransferSessionRef s2 = [self twoStepSessionForKey:poolKey];
    OSStatus st2 = s2 ? VTPixelTransferSessionTransferImage(s2, staging, dst) : -1;
    if (st2 != noErr) {
        NSInteger fails = [_twoStepFailCountPool[poolKey] integerValue] + 1;
        _twoStepFailCountPool[poolKey] = @(fails);
        if (fails >= 2) {
            // 熔断: 该流组合确认不支持, 释放该流 session/staging, 之后永久跳过
            _twoStepDisabledPool[poolKey] = @YES;
            [self invalidateTwoStepSessionForKey:poolKey];
            NSValue *stv = _twoStepStagingPool[poolKey];
            if (stv) {
                CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
                if (b) CVPixelBufferRelease(b);
                [_twoStepStagingPool removeObjectForKey:poolKey];
            }
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step CIRCUIT-BROKEN for stream %@ (unsupported combo, keep camera frame)", poolKey]);
        } else {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] 2step stage2 failed: %d key=%@ (fail %ld)", (int)st2, poolKey, (long)fails]);
        }
        return NO;
    }
    _twoStepFailCountPool[poolKey] = @0;
    return YES;
}

#pragma mark - 工具

- (NSString *)stringForFormat:(OSType)format {
    char fstr[5] = {0};
    fstr[0] = (char)(format >> 24);
    fstr[1] = (char)(format >> 16);
    fstr[2] = (char)(format >> 8);
    fstr[3] = (char)format;
    return [NSString stringWithUTF8String:fstr];
}

@end
