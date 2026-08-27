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
static void *vcamSecImg(void) {
    static void *img = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        img = dlopen("/System/Library/Frameworks/Security.framework/Security",
                     RTLD_LAZY | RTLD_LOCAL);
        if (!img) vcam_notify_log(@"[vcam][lic] sec img load fail");
    });
    return img;
}

// Security 符号专用解析: 句柄内优先(精确到该镜像), 兜底全局域, 均过信任校验
static void *vcamSecSym(const char *name) {
    void *img = vcamSecImg();
    void *p = img ? dlsym(img, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return vcamSymTrusted(p);
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
// 消息 = 本机设备码原文(16 hex 大写); 签名 = base64(DER) blob(~88 字符);
// 公钥 = X9.63 未压缩 65 字节(hex 嵌入, 混淆字符串层加密)。
// 私钥仅存在于开发机 license_priv.pem, 永不上设备 —— 逆向再彻底也无法
// 伪造密钥(数学保证, 非混淆保证)
+ (BOOL)vcamLicenseVerifyBlob:(NSString *)blob {
    if (![blob isKindOfClass:[NSString class]]) return NO;
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:blob
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    // X963 P-256 签名 = r||s 各 32 字节, 定长 64(1.3.56 收紧, fail-closed)
    if (!sig || sig.length != 64) return NO;
    NSData *msg = [[self vcamDeviceCode] dataUsingEncoding:NSUTF8StringEncoding];
    if (msg.length != 16) return NO;

    typedef CFTypeRef (*SecKeyCreateWithDataFn)(CFDataRef, CFDictionaryRef, void **);
    typedef BOOL (*SecKeyVerifySignatureFn)(CFTypeRef, CFStringRef, CFDataRef, CFDataRef, void **);
    static SecKeyCreateWithDataFn createKey = NULL;
    static SecKeyVerifySignatureFn verifySig = NULL;
    static CFStringRef attrType = NULL, attrClass = NULL, attrSize = NULL;
    static CFStringRef keyTypeEC = NULL, keyClassPub = NULL, sigAlg = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createKey  = (SecKeyCreateWithDataFn)vcamSecSym("SecKeyCreateWithData");
        verifySig  = (SecKeyVerifySignatureFn)vcamSecSym("SecKeyVerifySignature");
        // kSecAttr*/kSecSignature* 是 const CFStringRef 指针常量: dlsym 返回的是
        // "存放该指针的变量"的地址, 须再解一层引用(*slot)取真正的 CFStringRef 值。
        // (1.3.55 激活失败设备端根因: 直接把符号地址当 CFStringRef 用 → 属性
        //  字典键全错 → SecKeyCreateWithData 建钥失败 → 验签永远 NO)
        CFStringRef *slot = NULL;
        slot      = (CFStringRef *)vcamSecSym("kSecAttrKeyType");
        attrType  = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSym("kSecAttrKeyClass");
        attrClass = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSym("kSecAttrKeySizeInBits");
        attrSize  = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSym("kSecAttrKeyTypeECSECPrime256");
        keyTypeEC = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSym("kSecAttrKeyClassPublic");
        keyClassPub = slot ? *slot : NULL;
        slot      = (CFStringRef *)vcamSecSym("kSecSignatureAlgorithmECDSASignatureMessageX963SHA256");
        sigAlg    = slot ? *slot : NULL;
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
    if (pubKeyData.length != 65) return NO;

    int bits = 256;
    CFNumberRef sizeNum = CFNumberCreate(NULL, kCFNumberIntType, &bits);
    const void *dk[3] = { attrType, attrClass, attrSize };
    const void *dv[3] = { keyTypeEC, keyClassPub, sizeNum };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, dk, dv, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef key = attrs ? createKey((__bridge CFDataRef)pubKeyData, attrs, NULL) : NULL;
    if (attrs) CFRelease(attrs);
    if (sizeNum) CFRelease(sizeNum);
    if (!key) return NO;
    BOOL ok = verifySig(key, sigAlg,
                        (__bridge CFDataRef)msg, (__bridge CFDataRef)sig, NULL);
    CFRelease(key);
    return ok;
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

@end
