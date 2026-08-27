//
//  VCamNotify.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamNotify 实现
//  双通道：Darwin 通知 + plist 轮询
//

#import "VCamNotify.h"
#include <dlfcn.h>

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

#pragma mark - 密钥验证(1.3.54, 绑定设备 / 激活后永久)

// CommonCrypto SHA256 运行时解析(符号在 libSystem): dlsym 直取, 符号不进
// 二进制符号表 —— 与 MobileGestalt 同策略, 防逆向按符号定位算法入口
typedef unsigned char *(*vcamSHA256Fn)(const void *, unsigned int, unsigned char *);
static vcamSHA256Fn vcamSHA256Resolve(void) {
    static vcamSHA256Fn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fn = (vcamSHA256Fn)dlsym(RTLD_DEFAULT, "CC_SHA256");
    });
    return fn;
}

// SHA256(源) 前 8 字节 → 16 位大写 hex NSString(raw, 无横线; 展示分组由 UI 做)
static NSString *vcamDigestHex16(NSString *src) {
    vcamSHA256Fn sha = vcamSHA256Resolve();
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

// 密钥输入规范化: 去横线/空格, 大写(接受 4-4-4-4 分组或连写输入)
static NSString *vcamLicenseNormalize(NSString *input) {
    if (![input isKindOfClass:[NSString class]]) return @"";
    NSMutableString *s = [input mutableCopy];
    [s replaceOccurrencesOfString:@"-" withString:@"" options:NSLiteralSearch
                            range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@" " withString:@"" options:NSLiteralSearch
                            range:NSMakeRange(0, s.length)];
    return [s uppercaseString];
}

// UDID 不可用时回退: plist 持久 UUID(两进程同读同值; 首次缺省生成并写回,
// 原子写双路径与既有 setter 一致 —— SFTP/plist 并发教训)
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

// 设备码(静态缓存): MobileGestalt UDID 优先(真实硬件唯一标识, 换设备必变),
// 回退 plist UUID。logEnabled 时打印设备码与来源类型便于跨进程一致性诊断
// (SB 与 mediaserverd 算出的设备码必须一致, 否则激活在 md 侧不生效)
+ (NSString *)vcamDeviceCode {
    static NSString *code = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *deviceID = nil;
        BOOL fromUDID = NO;
        typedef CFStringRef (*MGCopyAnswerFn)(CFStringRef);
        MGCopyAnswerFn mg = (MGCopyAnswerFn)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
        if (mg) {
            CFStringRef udid = mg(CFSTR("UniqueDeviceID"));
            if (udid) {
                deviceID = [NSString stringWithString:(__bridge NSString *)udid];
                CFRelease(udid);
                fromUDID = YES;
            }
        }
        if (deviceID.length == 0) {
            deviceID = [self vcamPersistDeviceUUID];
        }
        code = vcamDigestHex16([@"QvD|" stringByAppendingString:deviceID]);
        vcam_notify_log([NSString stringWithFormat:
            @"[vcam][lic] device code %@ (src=%@)",
            code, fromUDID ? @"udid" : @"uuid"]);
    });
    return code;
}

// 期望密钥(静态缓存, 静态值仅本进程内存 —— 比对口径与设备码一致 raw 16 hex)
+ (NSString *)vcamLicenseExpected {
    static NSString *key = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        key = vcamDigestHex16([@"QvL|" stringByAppendingString:[self vcamDeviceCode]]);
    });
    return key;
}

// 已激活: plist licenseKey 存储值 == 本机重算期望(每次重算, 伪造 plist 无效)
+ (BOOL)vcamLicenseValid {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    if (!dict) dict = [NSDictionary dictionaryWithContentsOfFile:VCamStateBackupPath];
    NSString *stored = dict[@"licenseKey"];
    if (![stored isKindOfClass:[NSString class]] || stored.length != 16) return NO;
    return [stored isEqualToString:[self vcamLicenseExpected]];
}

// 激活: 规范化输入比对期望, 通过写 licenseKey(规范化 16 hex)+activated。
// mediaserverd 0.15s 轮询下一拍即生效(licGate→effEnabled), 无需额外通知
+ (BOOL)vcamActivateLicense:(NSString *)input {
    NSString *norm = vcamLicenseNormalize(input);
    if (norm.length != 16) return NO;
    if (![norm isEqualToString:[self vcamLicenseExpected]]) return NO;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"licenseKey"] = norm;
    dict[@"activated"] = @YES;
    [dict writeToFile:VCamPlistPath atomically:YES];
    [dict writeToFile:VCamStateBackupPath atomically:YES];
    return YES;
}

@end
