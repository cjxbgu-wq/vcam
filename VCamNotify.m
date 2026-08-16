//
//  VCamNotify.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamNotify 实现
//  双通道：Darwin 通知 + plist 轮询
//

#import "VCamNotify.h"

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
            cached = (d && d[@"logEnabled"]) ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) { cached = 0; }
    }
    return cached == 1;
}

static void vcam_notify_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
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

@end
