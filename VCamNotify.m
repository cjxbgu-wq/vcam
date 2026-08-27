//
//  VCamNotify.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamNotify 实现
//  双通道：Darwin 通知 + plist 轮询
//

#import "VCamNotify.h"
#include <dlfcn.h>
#include <string.h>

NSString *const VCamNotifyReloadMedia = @"com.vcam.ios.media.reload";
NSString *const VCamNotifyLiveChanged = @"com.vcam.ios.live.changed";
NSString *const VCamPlistPath         = @"/var/mobile/Media/DCIM/vc.plist";
NSString *const VCamStateBackupPath   = @"/var/mobile/vc.plist";

// 日志总开关(2026-08-16, diskwrites 崩溃循环止血): 默认静默, vc.plist "logEnabled=YES" 打开
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

// 日志全局限速令牌桶(定义在 VCamCore.m, 全进程共享磁盘写入预算 —— 磁盘配额击杀根治)
extern BOOL vcam_log_budget_take(void);

static void vcam_notify_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_notify_log.txt";
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

// Darwin 通知回调（必须是 C 函数，不能用 block）
@interface VCamNotify (Private)
- (void)dispatchCallbackForName:(NSString *)name;
@end

static void vcam_darwin_callback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (observer && name) {
        VCamNotify *notify = (__bridge VCamNotify *)observer;
        [notify dispatchCallbackForName:(__bridge NSString *)name];
    }
}

@interface VCamNotify ()
@property (nonatomic, strong) dispatch_queue_t notifyQueue;  // com.vcam.notify
@property (nonatomic, strong) NSMutableDictionary *callbacks; // name -> NSMutableArray of callback wrappers
@property (nonatomic, strong) NSLock *callbackLock;
@property (nonatomic, strong) NSMutableDictionary *darwinTokens; // name -> token number
@property (nonatomic, strong) dispatch_source_t pollingTimer;
@property (nonatomic, copy)   void(^pollingCallback)(BOOL enabled);
@property (nonatomic, assign) BOOL pollingActive;
// 打光快速轮询(1.3.45): 与主轮询同队列串行, 见 .h 注释
@property (nonatomic, strong) dispatch_source_t lightPollingTimer;
@property (nonatomic, copy)   void(^lightPollingCallback)(NSDictionary *plist);
@property (nonatomic, assign) BOOL lightPollingActive;
@end

@implementation VCamNotify

+ (instancetype)sharedInstance {
    static VCamNotify *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamNotify alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _notifyQueue = dispatch_queue_create("com.vcam.notify", DISPATCH_QUEUE_SERIAL);
        _callbacks = [[NSMutableDictionary alloc] init];
        _callbackLock = [[NSLock alloc] init];
        _darwinTokens = [[NSMutableDictionary alloc] init];
        _pollingActive = NO;
    }
    return self;
}

#pragma mark - Darwin 通知

- (void)postNotification:(NSString *)name {
    if (!name) return;
    vcam_notify_log([NSString stringWithFormat:@"[vcam] Posted notification: %@", name]);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)name,
        NULL,
        NULL,
        TRUE
    );
}

- (NSInteger)registerForNotification:(NSString *)name callback:(VCamNotifyCallback)callback {
    if (!name || !callback) return -1;

    NSInteger token = [self nextTokenForName:name];

    // 包装回调，使其能在 notifyQueue 上执行
    __block VCamNotifyCallback blockCallback = [callback copy];
    NSDictionary *wrapper = @{@"token": @(token), @"callback": blockCallback};

    [_callbackLock lock];
    NSMutableArray *arr = _callbacks[name];
    if (!arr) {
        arr = [[NSMutableArray alloc] init];
        _callbacks[name] = arr;
    }
    [arr addObject:wrapper];
    [_callbackLock unlock];

    // 注册 Darwin 通知监听（仅第一次注册时）
    if (arr.count == 1) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge void *)self,
            vcam_darwin_callback,
            (__bridge CFStringRef)name,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        vcam_notify_log([NSString stringWithFormat:@"[vcam] Registered for notification: %@ (token: %ld)", name, (long)token]);
    }

    return token;
}

- (void)unregisterNotification:(NSString *)name token:(NSInteger)token {
    if (!name) return;
    [_callbackLock lock];
    NSMutableArray *arr = _callbacks[name];
    if (arr) {
        for (NSInteger i = arr.count - 1; i >= 0; i--) {
            if ([arr[i][@"token"] integerValue] == token) {
                [arr removeObjectAtIndex:i];
            }
        }
        if (arr.count == 0) {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge void *)self,
                (__bridge CFStringRef)name,
                NULL
            );
            [_callbacks removeObjectForKey:name];
            vcam_notify_log([NSString stringWithFormat:@"[vcam] Unregistered notification: %@", name]);
        }
    }
    [_callbackLock unlock];
}

- (NSInteger)nextTokenForName:(NSString *)name {
    NSNumber *current = _darwinTokens[name];
    NSInteger next = current ? [current integerValue] + 1 : 1;
    _darwinTokens[name] = @(next);
    return next;
}

- (void)dispatchCallbackForName:(NSString *)name {
    [_callbackLock lock];
    NSArray *arr = [_callbacks[name] copy];
    [_callbackLock unlock];
    for (NSDictionary *wrapper in arr) {
        VCamNotifyCallback cb = wrapper[@"callback"];
        if (cb) {
            dispatch_async(_notifyQueue, ^{
                cb(name);
            });
        }
    }
}

#pragma mark - plist 轮询

- (void)startPollingWithInterval:(NSTimeInterval)interval
                        callback:(void(^)(BOOL enabled))callback {
    if (_pollingActive) return;
    _pollingActive = YES;
    _pollingCallback = [callback copy];

    vcam_notify_log(@"[vcam] State polling timer started");

    _pollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _notifyQueue);
    uint64_t intervalNs = interval * NSEC_PER_SEC;
    dispatch_source_set_timer(_pollingTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    dispatch_source_set_event_handler(_pollingTimer, ^{
        // 心跳日志已移除(2026-08-16): mediaserverd 的 EXC_RESOURCE disk writes 限额
        // 仅 12.43KB/s(每日 ~1GB), 高频日志每行按 4KB 脏页记账曾达 69KB/s → 4 小时
        // 耗尽 1GB → 系统杀进程 → coalition 计数跨重启 → 6 秒崩溃循环
        BOOL enabled = [VCamNotify isPlistEnabled];
        if (self->_pollingCallback) {
            self->_pollingCallback(enabled);
        }
    });
    dispatch_resume(_pollingTimer);
}

- (void)stopPolling {
    if (_pollingTimer) {
        dispatch_source_cancel(_pollingTimer);
        _pollingTimer = nil;
    }
    _pollingActive = NO;
    _pollingCallback = nil;
}

// 打光专用快速轮询(1.3.45): timer 挂与主轮询同一个 _notifyQueue ——
// dispatch serial queue 上两个 timer handler 串行执行, 与主轮询回调
// 天然互斥(都能安全访问 VCamCore 的 gpuProcessor 状态)。
// 单次开销 = 一次 plist 文件读(~0.1-0.2ms) + 回调, 25Hz ≈ 0.5% 单核
- (void)startLightPollingWithInterval:(NSTimeInterval)interval
                             callback:(void(^)(NSDictionary *plist))callback {
    if (_lightPollingActive) return;
    _lightPollingActive = YES;
    _lightPollingCallback = [callback copy];

    _lightPollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _notifyQueue);
    uint64_t intervalNs = interval * NSEC_PER_SEC;
    dispatch_source_set_timer(_lightPollingTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    dispatch_source_set_event_handler(_lightPollingTimer, ^{
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
        if (self->_lightPollingCallback) {
            self->_lightPollingCallback(pl ?: @{});
        }
    });
    dispatch_resume(_lightPollingTimer);
}

- (void)stopLightPolling {
    if (_lightPollingTimer) {
        dispatch_source_cancel(_lightPollingTimer);
        _lightPollingTimer = nil;
    }
    _lightPollingActive = NO;
    _lightPollingCallback = nil;
}

#pragma mark - plist 读写

+ (BOOL)isPlistEnabled {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    if (!dict) {
        // 回退到备份路径
        dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
    }
    NSNumber *enabled = dict[@"enabled"];
    return enabled ? [enabled boolValue] : NO;
}

+ (void)setPlistEnabled:(BOOL)enabled {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"enabled"] = @(enabled);
    [dict writeToFile:VCamPlistPath atomically:YES];
    // 同步到备份路径
    [dict writeToFile:VCamStateBackupPath atomically:YES];
}

+ (NSString *)activePlaybackPath {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return dict[@"activePlaybackPath"];
}

+ (void)setActivePlaybackPath:(NSString *)path {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"activePlaybackPath"] = path;
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (NSInteger)plistRotation {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *rot = dict[@"manualRotation"];
    return rot ? [rot integerValue] : 0;
}

+ (void)setPlistRotation:(NSInteger)degrees {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"manualRotation"] = @(degrees);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (BOOL)plistMirrored {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *m = dict[@"mirrored"];
    return m ? [m boolValue] : NO;
}

+ (void)setPlistMirrored:(BOOL)mirrored {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"mirrored"] = @(mirrored);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 用户画面变换(箭头/＋/−/复)

+ (double)plistPanX {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userPanX"];
    return v ? [v doubleValue] : 0.0;
}

+ (void)setPlistPanX:(double)panX {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanX"] = @(panX);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (double)plistPanY {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userPanY"];
    return v ? [v doubleValue] : 0.0;
}

+ (void)setPlistPanY:(double)panY {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanY"] = @(panY);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (double)plistZoom {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"userZoom"];
    return v ? [v doubleValue] : 1.0;  // 缺失时 1.0(原始等比填充)
}

+ (void)setPlistZoom:(double)zoom {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userZoom"] = @(zoom);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (void)resetPlistTransform {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"userPanX"] = @0.0;
    dict[@"userPanY"] = @0.0;
    dict[@"userZoom"] = @1.0;
    [dict writeToFile:VCamPlistPath atomically:YES];
}

// 前置方向修正: 前置流显示旋转与后置差 180°, pan 应用时 X/Y 同时取反(设置页开关)
+ (BOOL)plistFrontPanFix {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"frontPanFix"] boolValue];
}

+ (void)setPlistFrontPanFix:(BOOL)fix {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"frontPanFix"] = @(fix);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 播放控制（跨进程: 悬浮球写, mediaserverd 轮询应用）

+ (BOOL)plistPaused {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"paused"] boolValue];  // 缺失时 NO(播放中)
}

+ (void)setPlistPaused:(BOOL)paused {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"paused"] = @(paused);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (NSInteger)plistRestartToken {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"restartToken"] integerValue];  // 缺失时 0
}

+ (void)bumpRestartToken {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    NSInteger token = [dict[@"restartToken"] integerValue] + 1;
    dict[@"restartToken"] = @(token);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 三色打光(1.3.37, 跨进程: 悬浮球检测写, mediaserverd 轮询应用)

// 检测颜色高频写(0.1s 节拍且仅变化时): 单键写, 与既有 per-key 模式一致
+ (BOOL)plistLightEnabled {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return [dict[@"lightEnabled"] boolValue];
}
+ (void)setPlistLightEnabled:(BOOL)enabled {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightEnabled"] = @(enabled);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (uint32_t)plistLightColor {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    return (uint32_t)[dict[@"lightColor"] unsignedIntValue];
}
+ (void)setPlistLightColor:(uint32_t)color {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightColor"] = @(color);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightX {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightX"];
    return v ? [v intValue] : 50;
}
+ (void)setPlistLightX:(int)x {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightX"] = @(x);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightY {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightY"];
    return v ? [v intValue] : 50;
}
+ (void)setPlistLightY:(int)y {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightY"] = @(y);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightIntensity {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightIntensity"];
    return v ? [v intValue] : 30;
}
+ (void)setPlistLightIntensity:(int)v {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightIntensity"] = @(v);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightDiameter {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightDiameter"];
    return v ? [v intValue] : 48;
}
+ (void)setPlistLightDiameter:(int)v {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightDiameter"] = @(v);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
+ (int)plistLightFeather {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"lightFeather"];
    return v ? [v intValue] : 100;
}
+ (void)setPlistLightFeather:(int)v {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightFeather"] = @(v);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 密钥验证(1.3.55, ECDSA P-256 设备绑定签名 / 激活后永久)

// ==== 可信符号解析(防 rebind/interpose Hook) ====
// dlsym + dladdr 双重校验: 符号必须解析自系统镜像(/usr/lib 或 /System 前缀)。
// 越狱注入的第三方 dylib 全在 /var/jb / /Library 等路径下 —— 符号被 rebind
// 到攻击者镜像时 dli_fname 不在信任前缀 → 返回 NULL。调用方随之走"身份值
// 劣化"路径(静默): 设备码变垃圾/拿不到硬件源 → md 侧验签自然失败。
// (注: 对内联补丁式 Hook 由 VCamCore 的 IMP 范围自检 + 帧门禁周期重算兜底)
static void *vcamDlsymTrusted(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) return NULL;
    Dl_info info;
    if (dladdr(p, &info) == 0 || !info.dli_fname) return NULL;
    const char *fn = info.dli_fname;
    if (strncmp(fn, "/usr/lib", 8) == 0 || strncmp(fn, "/System", 7) == 0) return p;
    vcam_notify_log(@"[vcam][lic] untrusted sym src");
    return NULL;
}

// 信任校验公共层: 地址必须归属 /usr/lib 或 /System 镜像
static void *vcamSymTrusted(void *p) {
    if (!p) return NULL;
    Dl_info info;
    if (dladdr(p, &info) == 0 || !info.dli_fname) return NULL;
    const char *fn = info.dli_fname;
    if (strncmp(fn, "/usr/lib", 8) == 0 || strncmp(fn, "/System", 7) == 0) return p;
    vcam_notify_log(@"[vcam][lic] untrusted sym src");
    return NULL;
}

// Security.framework 显式加载(1.3.57): SB/mediaserverd 主程序不直接链接
// Security, RTLD_DEFAULT 搜索域里没有该镜像 → 全部 Sec 符号落空
// ("sec syms missing", 1.3.56 激活失败根因: MGCopyAnswer/IOKit 在 SB 已加载
//  所以解析成功, Security 没有)。dlopen 从共享缓存把镜像拉进进程(幂等,
//  已加载仅加引用计数), 之后 dlsym 可见。路径字面量走混淆字符串层。
// 1.3.58: RTLD_LOCAL → RTLD_GLOBAL —— LOCAL 模式下镜像符号不进全局搜索域,
// dlsym(RTLD_DEFAULT) 兜底永远落空(1.3.57 实测: dlopen 成功无 fail 日志,
// 句柄内 dlsym 也落空); GLOBAL 让兜底与 IOKit/MobileGestalt 同机制解析
// (该机制在本设备 SB 实证可用: mg=1 io=1)。
static void *vcamSecImg(void) {
    static void *img = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        img = dlopen("/System/Library/Frameworks/Security.framework/Security",
                     RTLD_LAZY | RTLD_GLOBAL);
        if (!img) {
            const char *err = dlerror();
            vcam_notify_log([NSString stringWithFormat:
                @"[vcam][lic] sec img load fail: %s", err ? err : "null"]);
        }
    });
    return img;
}

// 镜像扫描兜底(1.3.59): 符号不在 dlopen 句柄/全局搜索域时, 遍历进程
// 已加载的 /System /usr/lib 镜像(RTLD_NOLOAD 现成句柄)逐个 dlsym, 找到后
// 照走 dladdr 信任校验。_dyld_* 在 libdyld(/usr/lib/system), 与已实证可
// 解析的 MGCopyAnswer/IOKit 同机制。
// (1.3.60 根因实锤, 依据 iOS 15.6 SDK 头文件: 1.3.55~59 的 d=..0..0 并非
// 镜像问题, 是符号名错 —— kSecAttrKeyTypeECSECPrime256 是 macOS-only 常量
// (SecItem.h 标 ios NA), iOS 的 EC key type 真名是 kSecAttrKeyTypeECSECPrimeRandom;
// 算法常量真名是 kSecKeyAlgorithmECDSASignatureMessageX962SHA256(kSecKeyAlgorithm*
// 前缀 + X962, iOS 无 kSecSignatureAlgorithm* 旧 macOS 枚举符号)。已修正。)
static void *vcamScanImagesFor(const char *name) {
    typedef uint32_t (*ImgCountFn)(void);
    typedef const char *(*ImgNameFn)(uint32_t);
    static ImgCountFn cnt = NULL;
    static ImgNameFn nm = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cnt = (ImgCountFn)vcamDlsymTrusted("_dyld_image_count");
        nm  = (ImgNameFn)vcamDlsymTrusted("_dyld_get_image_name");
    });
    if (!cnt || !nm) return NULL;
    uint32_t n = cnt();
    for (uint32_t i = 0; i < n; i++) {
        const char *path = nm(i);
        if (!path) continue;
        if (strncmp(path, "/System", 7) != 0 && strncmp(path, "/usr/lib", 8) != 0) continue;
        void *h = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
        if (!h) continue;
        void *s = dlsym(h, name);
        if (s) {
            void *t = vcamSymTrusted(s);
            if (t) return t;
        }
    }
    return NULL;
}

// Security 符号专用解析 + 逐符号诊断(1.3.58): *diag 0=dlsym 全落空,
// 1=dlsym 命中但 dladdr 信任拒, 2=通过, 4=镜像扫描兜底命中。
// 单行合并输出防令牌桶吃行。
static void *vcamSecSymX(void *img, const char *name, int *diag) {
    void *p = img ? dlsym(img, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    if (p) {
        void *t = vcamSymTrusted(p);
        if (t) { *diag = 2; return t; }
        *diag = 1;
        return NULL;
    }
    void *s = vcamScanImagesFor(name);
    if (s) { *diag = 4; return s; }
    *diag = 0;
    return NULL;
}

// SHA256(源) 前 8 字节 → 16 位大写 hex NSString(设备码口径, 展示分组由 UI 做)
typedef unsigned char *(*vcamSHA256Fn)(const void *, unsigned int, unsigned char *);
static NSString *vcamDigestHex16(NSString *src) {
    static vcamSHA256Fn sha = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sha = (vcamSHA256Fn)vcamDlsymTrusted("CC_SHA256");
    });
    if (!sha || src.length == 0) return nil;
    NSData *d = [src dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nil;
    unsigned char md[32];
    sha(d.bytes, (unsigned int)d.length, md);
    char hex[17];
    for (int i = 0; i < 8; i++) {
        unsigned char b = md[i];
        hex[i * 2]     = "0123456789ABCDEF"[b >> 4];
        hex[i * 2 + 1] = "0123456789ABCDEF"[b & 0xF];
    }
    hex[16] = 0;
    return [NSString stringWithUTF8String:hex];
}

// hex 单字符 → 数值(非法返回 -1)
static int vcamHexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// MobileGestalt(可信任源解析)
typedef CFStringRef (*vcamMGCopyAnswerFn)(CFStringRef);
static vcamMGCopyAnswerFn vcamMGResolve(void) {
    static vcamMGCopyAnswerFn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fn = (vcamMGCopyAnswerFn)vcamDlsymTrusted("MGCopyAnswer");
    });
    return fn;
}

// IOKit 平台序列号: 与 MobileGestalt 完全独立的第二条身份 API 路径。
// 类型按框架 ABI 手工声明(iOS 公开 SDK 不带 IOKit 用户头);
// kIOMasterPortDefault == 0 直传
static NSString *vcamPlatformSerial(void) {
    static NSString *serial = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typedef uint32_t vcamIOObj;
        typedef CFMutableDictionaryRef (*IOServiceMatchingFn)(const char *);
        typedef vcamIOObj (*IOServiceGetMatchingServiceFn)(uint32_t, CFDictionaryRef);
        typedef CFTypeRef (*IORegistryEntryCreateCFPropertyFn)(vcamIOObj, CFStringRef, CFAllocatorRef, uint32_t);
        typedef int (*IOObjectReleaseFn)(vcamIOObj);
        IOServiceMatchingFn matching =
            (IOServiceMatchingFn)vcamDlsymTrusted("IOServiceMatching");
        IOServiceGetMatchingServiceFn getsvc =
            (IOServiceGetMatchingServiceFn)vcamDlsymTrusted("IOServiceGetMatchingService");
        IORegistryEntryCreateCFPropertyFn getprop =
            (IORegistryEntryCreateCFPropertyFn)vcamDlsymTrusted("IORegistryEntryCreateCFProperty");
        IOObjectReleaseFn release =
            (IOObjectReleaseFn)vcamDlsymTrusted("IOObjectRelease");
        if (!matching || !getsvc || !getprop || !release) return;
        NSString *svc = @"IOPlatformExpertDevice";
        vcamIOObj entry = getsvc(0, matching([svc UTF8String]));
        if (entry) {
            CFTypeRef v = getprop(entry, CFSTR("IOPlatformSerialNumber"),
                                  kCFAllocatorDefault, 0);
            if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
                serial = [NSString stringWithString:(__bridge NSString *)v];
            }
            if (v) CFRelease(v);
            release(entry);
        }
    });
    return serial;
}

// UDID/硬件源不可用时回退: plist 持久 UUID(两进程同读同值; 首次缺省生成并
// 写回, 原子写双路径与既有 setter 一致)
+ (NSString *)vcamPersistDeviceUUID {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSString *uuid = dict[@"deviceUUID"];
    if ([uuid isKindOfClass:[NSString class]] && uuid.length > 0) return uuid;
    uuid = [[NSUUID UUID] UUIDString];
    NSMutableDictionary *mdict = [NSMutableDictionary dictionaryWithDictionary:dict ?: @{}];
    mdict[@"deviceUUID"] = uuid;
    [mdict writeToFile:VCamPlistPath atomically:YES];
    [mdict writeToFile:VCamStateBackupPath atomically:YES];
    return uuid;
}

// 设备码(静态缓存, 多源绑定): UDID + SerialNumber(MobileGestalt) +
// IOPlatformSerialNumber(IOKit) 混入 SHA256 —— 两条独立 API 路径, 单点
// Hook 难以在 SB/md 两进程伪造一致的假身份。硬件源全不可用时回退 plist
// UUID(仅同机一致, 换机必变)。logEnabled 时打印设备码与源可用性, 用于
// 跨进程一致性诊断(SB 与 md 必须算出同值, 否则激活在 md 侧不生效)
+ (NSString *)vcamDeviceCode {
    static NSString *code = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableString *mix = [NSMutableString stringWithString:@"QvD|"];
        vcamMGCopyAnswerFn mg = vcamMGResolve();
        BOOL gotHW = NO;
        if (mg) {
            CFStringRef udid = mg(CFSTR("UniqueDeviceID"));
            if (udid) {
                [mix appendString:(__bridge NSString *)udid];
                CFRelease(udid);
                gotHW = YES;
            }
            [mix appendString:@"|S|"];
            CFStringRef serial = mg(CFSTR("SerialNumber"));
            if (serial) {
                [mix appendString:(__bridge NSString *)serial];
                CFRelease(serial);
                gotHW = YES;
            }
        }
        [mix appendString:@"|P|"];
        NSString *platformSerial = vcamPlatformSerial();
        if (platformSerial.length > 0) {
            [mix appendString:platformSerial];
            gotHW = YES;
        }
        if (!gotHW) {
            [mix appendString:[self vcamPersistDeviceUUID]];
        }
        code = vcamDigestHex16(mix);
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] device code %@ (mg=%d io=%d)",
            code, mg != NULL, platformSerial.length > 0]);
    });
    return code;
}

// ==== ECDSA P-256 验签(全 dlsym, 符号不进符号表) ====
// 消息 = 本机设备码原文(16 hex 大写); 签名 = base64(DER x9.62) blob(~96 字符)。
// (1.3.60: iOS 的 kSecKeyAlgorithmECDSASignatureMessageX962SHA256 要求 DER
// 编码签名(SEQUENCE of r,s); 1.3.56 改的 raw r||s 64B 是按 macOS 文档臆断
// 的格式, iOS 验签必失败 —— gen_license.py 已同步改回 DER 输出)
// 公钥 = X9.63 未压缩 65 字节(hex 嵌入, 混淆字符串层加密)。
// 私钥仅存在于开发机 license_priv.pem, 永不上设备 —— 逆向再彻底也无法
// 伪造密钥(数学保证, 非混淆保证)
+ (BOOL)vcamLicenseVerifyBlob:(NSString *)blob {
    if (![blob isKindOfClass:[NSString class]]) return NO;
    // 1.3.63 方案A: blob v2 = base64(DER 签名) "." base64(T_enc 72B)。
    // 旧格式(无 "." 段)fail-closed —— 验签消息升级为 设备码||T_enc
    NSRange dot = [blob rangeOfString:@"."];
    if (dot.location == NSNotFound || dot.location == 0 ||
        dot.location + 1 >= blob.length) return NO;
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:
        [blob substringToIndex:dot.location]
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSData *tEnc = [[NSData alloc] initWithBase64EncodedString:
        [blob substringFromIndex:dot.location + 1]
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    // DER P-256 签名 = 0x30 开头的 SEQUENCE, 66~72 字节(r/s 前导零致不定长;
    // 此处只做快速 fail-closed, 真正解析由 SecKeyVerifySignature 完成)
    if (!sig || sig.length < 64 || sig.length > 72) return NO;
    if (((const uint8_t *)sig.bytes)[0] != 0x30) return NO;
    // T 表 = 18 × u32(BE) = 72 字节(gen_license.py T_TRUE 布局)
    if (!tEnc || tEnc.length != 72) return NO;
    NSString *dc = [self vcamDeviceCode];
    if (dc.length != 16) return NO;
    // 消息 = 设备码(16 ascii) || T_enc(签名覆盖参数密文, 篡改即验签失败)
    NSMutableData *msg = [NSMutableData dataWithCapacity:16 + 72];
    [msg appendData:[dc dataUsingEncoding:NSUTF8StringEncoding]];
    [msg appendData:tEnc];
    NSData *msgData = [msg copy];

    typedef CFTypeRef (*SecKeyCreateWithDataFn)(CFDataRef, CFDictionaryRef, void **);
    typedef BOOL (*SecKeyVerifySignatureFn)(CFTypeRef, CFStringRef, CFDataRef, CFDataRef, void **);
    static SecKeyCreateWithDataFn createKey = NULL;
    static SecKeyVerifySignatureFn verifySig = NULL;
    static CFStringRef attrType = NULL, attrClass = NULL, attrSize = NULL;
    static CFStringRef keyTypeEC = NULL, keyClassPub = NULL, sigAlg = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *img = vcamSecImg();
        int dg[8];
        createKey  = (SecKeyCreateWithDataFn)vcamSecSymX(img, "SecKeyCreateWithData", &dg[0]);
        verifySig  = (SecKeyVerifySignatureFn)vcamSecSymX(img, "SecKeyVerifySignature", &dg[1]);
        // kSecAttr*/kSecKeyAlgorithm* 是 const CFStringRef 指针常量: dlsym 返回的是
        // "存放该指针的变量"的地址, 须再解一层引用(*slot)取真正的 CFStringRef 值。
        // (1.3.55 激活失败设备端根因: 直接把符号地址当 CFStringRef 用 → 属性
        //  字典键全错 → SecKeyCreateWithData 建钥失败 → 验签永远 NO)
        CFStringRef *slot = NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyType", &dg[2]);
        attrType  = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyClass", &dg[3]);
        attrClass = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeySizeInBits", &dg[4]);
        attrSize  = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyTypeECSECPrimeRandom", &dg[5]);
        keyTypeEC = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecAttrKeyClassPublic", &dg[6]);
        keyClassPub = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSymX(img, "kSecKeyAlgorithmECDSASignatureMessageX962SHA256", &dg[7]);
        sigAlg    = slot ? *slot : NULL;
        // 单行诊断: img=句柄, d=8 符号各自 0/1/2 (见 vcamSecSymX)
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] sec diag img=%d d=%d%d%d%d%d%d%d%d", img != NULL,
            dg[0], dg[1], dg[2], dg[3], dg[4], dg[5], dg[6], dg[7]]);
        if (!createKey || !verifySig || !attrType || !attrClass || !attrSize ||
            !keyTypeEC || !keyClassPub || !sigAlg) {
            vcam_notify_log(@"[vcam][lic] sec syms missing");
        }
    });
    if (!createKey || !verifySig || !attrType || !attrClass || !attrSize ||
        !keyTypeEC || !keyClassPub || !sigAlg) return NO;

    // 公钥 hex → 65 字节未压缩点(静态缓存)
    static NSData *pubKeyData = nil;
    static dispatch_once_t pubOnce;
    dispatch_once(&pubOnce, ^{
        NSString *pubHex = @"047ac82d0d8ba9e315bebf8ebdb1c6a8065b4156f9a5839fd2ba92082081a10fa67972526b49606266b25d87911b5b707838390d4ce3eef81039e986da6cd58cd6";
        if ([pubHex length] != 130) return;
        const char *hex = [pubHex UTF8String];
        NSMutableData *d = [NSMutableData dataWithLength:65];
        uint8_t *b = (uint8_t *)d.mutableBytes;
        for (int i = 0; i < 65; i++) {
            int hi = vcamHexDigit(hex[i * 2]);
            int lo = vcamHexDigit(hex[i * 2 + 1]);
            if (hi < 0 || lo < 0) return;
            b[i] = (uint8_t)((hi << 4) | lo);
        }
        pubKeyData = [d copy];
    });
    // 1.3.61 验签链路逐环诊断(每进程一次): 1.3.60 设备实测 d=22222222
    // (8 符号全解出)后仍无 state change → 失败点在符号解析之后的静默
    // return。pub=公钥字节数(65 正常, 0=hex 解码失败) key=SecKey 建钥
    // 结果 sig=验签结果 bl/sl=blob 字符数与 DER 字节数
    static dispatch_once_t verDiagOnce;
    BOOL keyOK = NO, sigOK = NO;
    if (pubKeyData.length == 65) {
        int bits = 256;
        CFNumberRef sizeNum = CFNumberCreate(NULL, kCFNumberIntType, &bits);
        const void *dk[3] = { attrType, attrClass, attrSize };
        const void *dv[3] = { keyTypeEC, keyClassPub, sizeNum };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, dk, dv, 3,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFTypeRef key = attrs ? createKey((__bridge CFDataRef)pubKeyData, attrs, NULL) : NULL;
        if (attrs) CFRelease(attrs);
        if (sizeNum) CFRelease(sizeNum);
        keyOK = key != NULL;
        if (key) {
            sigOK = verifySig(key, sigAlg,
                              (__bridge CFDataRef)msgData, (__bridge CFDataRef)sig, NULL);
            CFRelease(key);
        }
    }
    dispatch_once(&verDiagOnce, ^{
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] ver diag pub=%lu key=%d sig=%d bl=%lu sl=%lu",
            (unsigned long)pubKeyData.length, keyOK, sigOK,
            (unsigned long)blob.length, (unsigned long)sig.length]);
    });
    return sigOK;
}

// 已激活: plist licBlob 对本机设备码验签通过。0.5s 节流缓存(ECDSA ~1ms,
// 0.15s 轮询全验签无必要; 激活写入后 0.5s 内过期重验, md 下一拍生效)
+ (BOOL)vcamLicenseValid {
    @synchronized ([VCamNotify class]) {
        static BOOL cached = NO;
        static double cachedAt = 0;
        static BOOL hasCache = NO;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (hasCache && now - cachedAt < 0.5) return cached;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
        if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
        NSString *blob = dict[@"licBlob"];
        cached = [blob isKindOfClass:[NSString class]] && [self vcamLicenseVerifyBlob:blob];
        cachedAt = now;
        hasCache = YES;
        return cached;
    }
}

// 激活: 输入密钥(base64, 区分大小写, 仅去空白/换行)验签通过 → 写
// licBlob/activated/dcPub。mediaserverd 0.15s 轮询下一拍即生效
+ (BOOL)vcamActivateLicense:(NSString *)input {
    if (![input isKindOfClass:[NSString class]]) return NO;
    NSString *blob = [[input componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsJoinedByString:@""];
    if (![self vcamLicenseVerifyBlob:blob]) return NO;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"licBlob"] = blob;
    dict[@"activated"] = @YES;
    dict[@"dcPub"] = [self vcamDeviceCode];
    [dict writeToFile:VCamPlistPath atomically:YES];
    [dict writeToFile:VCamStateBackupPath atomically:YES];
    return YES;
}

// SB 侧发布本进程设备码(打开激活页/激活成功时调用) → md 侧互证
+ (void)vcamPublishDeviceCode {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"dcPub"] = [self vcamDeviceCode];
    [dict writeToFile:VCamPlistPath atomically:YES];
    [dict writeToFile:VCamStateBackupPath atomically:YES];
}

// md 侧跨进程互证: SB 发布的 dcPub 与本机计算值一致(单边被 Hook →
// 不一致 → VCamCore licMark 关门禁)
+ (BOOL)vcamCrossDeviceCodeOK {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
    NSString *pub = dict[@"dcPub"];
    if (![pub isKindOfClass:[NSString class]] || pub.length != 16) return NO;
    return [pub isEqualToString:[self vcamDeviceCode]];
}

// ===== 1.3.63 方案A: 许可携带功能参数密文(T 表) =====
// 验签不再是"开关"而是"钥匙": blob v2 的 T 段解密出打光颜色/HSV 门限/
// 计票阈值/zoom/pan/旋转/羽化等真值 —— 跳过验证 = T 无来源 = 参数全垃圾
// (画面数学错误, 非简单"不工作", 补丁者无从得知正确值)。
// 链路(与 gen_license.py 严格一致):
//   验签: SecKeyVerifySignature(公钥, 设备码||T_enc, DER 签名)
//   K    = SHA256(设备码 16 ascii || T_SALT 16B)
//   流    = SHA256(K||u32be(ctr)) 分块拼接(CTR 风格)
//   T[i] = (T_enc_u32[i] ^ 流_u32[i]) ^ devHash32[i%8]
//   devHash32 = SHA256(设备码) 前 32B 按 8×u32(BE)
// 防抄许可: T_enc 加密端已预混签发设备的 devHash32, 本机再混自己值,
// 他人许可在本机掺混后必为垃圾(魔数校验拦截)。
// 返回 72 字节(18×u32 BE) 或 nil; 0.5s 节流缓存与 vcamLicenseValid 同拍。
+ (NSData *)vcamLicenseTable {
    @synchronized ([VCamNotify class]) {
        static NSData *cached = nil;
        static double cachedAt = 0;
        static BOOL hasCache = NO;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (hasCache && now - cachedAt < 0.5) return cached;
        cached = nil;
        cachedAt = now;
        hasCache = YES;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
        if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
        NSString *blob = dict[@"licBlob"];
        if (![blob isKindOfClass:[NSString class]] ||
            ![self vcamLicenseVerifyBlob:blob]) return nil;
        // 复用验签内部同款解析: sig 段(解 K 不需要) + T_enc 段
        NSRange dot = [blob rangeOfString:@"."];
        NSData *tEnc = [[NSData alloc] initWithBase64EncodedString:
            [blob substringFromIndex:dot.location + 1]
            options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (tEnc.length != 72) return nil;
        NSString *dc = [self vcamDeviceCode];
        if (dc.length != 16) return nil;
        NSData *dcData = [dc dataUsingEncoding:NSUTF8StringEncoding];

        // CC_SHA256(可信解析, 与设备码同链路)
        static vcamSHA256Fn sha = NULL;
        static dispatch_once_t shaOnce;
        dispatch_once(&shaOnce, ^{
            sha = (vcamSHA256Fn)vcamDlsymTrusted("CC_SHA256");
        });
        if (!sha) return nil;

        // T_SALT(构建期盐, hex 32 字符 → 16B; 与 gen_license.py 一致)。
        // 局部变量(非 static): 混淆器把 C 字符串换成运行时解密调用,
        // static const 初始化会因非常量初始化器编译失败(工程既有约束)
        const char *saltHex = "7ecfba852c100ab4228ac14f062f737c";
        uint8_t salt[16];
        for (int i = 0; i < 16; i++) {
            int hi = vcamHexDigit(saltHex[i * 2]);
            int lo = vcamHexDigit(saltHex[i * 2 + 1]);
            if (hi < 0 || lo < 0) return nil;
            salt[i] = (uint8_t)((hi << 4) | lo);
        }

        // K = SHA256(设备码 || T_SALT)
        uint8_t bufK[16 + 16];
        memcpy(bufK, dcData.bytes, 16);
        memcpy(bufK + 16, salt, 16);
        uint8_t k[32];
        sha(bufK, 32, k);

        // devHash32 = SHA256(设备码) → 8×u32(BE)
        uint8_t devHash[32];
        sha(dcData.bytes, 16, devHash);
        uint32_t dev32[8];
        for (int i = 0; i < 8; i++) {
            dev32[i] = ((uint32_t)devHash[i * 4] << 24) | ((uint32_t)devHash[i * 4 + 1] << 16) |
                       ((uint32_t)devHash[i * 4 + 2] << 8) | (uint32_t)devHash[i * 4 + 3];
        }

        // 解密: t[i] = T_enc_u32[i] ^ 流_u32[i] ^ dev32[i%8]
        const uint8_t *enc = (const uint8_t *)tEnc.bytes;
        uint32_t t[18];
        uint8_t ctr[32 + 4];
        memcpy(ctr, k, 32);
        for (int blk = 0; blk < 3; blk++) {  // 72B = 3 块 SHA256
            ctr[32] = (uint8_t)(blk >> 24); ctr[33] = (uint8_t)(blk >> 16);
            ctr[34] = (uint8_t)(blk >> 8);  ctr[35] = (uint8_t)blk;
            uint8_t st[32];
            sha(ctr, 36, st);
            for (int j = 0; j < 6; j++) {  // 每块 6 × u32
                int idx = blk * 6 + j;
                uint32_t e = ((uint32_t)enc[idx * 4] << 24) | ((uint32_t)enc[idx * 4 + 1] << 16) |
                             ((uint32_t)enc[idx * 4 + 2] << 8) | (uint32_t)enc[idx * 4 + 3];
                uint32_t s = ((uint32_t)st[j * 4] << 24) | ((uint32_t)st[j * 4 + 1] << 16) |
                             ((uint32_t)st[j * 4 + 2] << 8) | (uint32_t)st[j * 4 + 3];
                t[idx] = e ^ s ^ dev32[idx % 8];
            }
        }
        // 自校验: idx0 魔数 + idx17 = idx0..16 XOR
        // (先拷标量再进 block: C 数组不能被 block 捕获)
        static dispatch_once_t tDiagOnce;
        BOOL ok = (t[0] == 0x3FA7C2E1u);
        uint32_t x = 0;
        for (int i = 0; i < 17; i++) x ^= t[i];
        if (x != t[17]) ok = NO;
        uint32_t m0 = t[0], m17 = t[17];
        dispatch_once(&tDiagOnce, ^{
            vcam_notify_log([NSString stringWithFormat:
                @"[vcam][lic] T diag m=%08x c=%08x ok=%d",
                m0, m17, ok]);
        });
        if (!ok) return nil;
        cached = [NSData dataWithBytes:t length:72];
        return cached;
    }
}

// T 表参数取值(u32 → double, ×100 定点): 消费端统一入口
+ (double)vcamLicenseTableDouble:(NSUInteger)idx {
    NSData *t = [self vcamLicenseTable];
    if (!t || idx > 17) return 0.0;
    const uint8_t *b = (const uint8_t *)t.bytes + idx * 4;
    uint32_t v = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                 ((uint32_t)b[2] << 8) | (uint32_t)b[3];
    return (double)v / 100.0;
}

// T 表参数取值(u32 原值): 颜色表/门限等整数参数
+ (uint32_t)vcamLicenseTableInt:(NSUInteger)idx {
    NSData *t = [self vcamLicenseTable];
    if (!t || idx > 17) return 0;
    const uint8_t *b = (const uint8_t *)t.bytes + idx * 4;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

@end
