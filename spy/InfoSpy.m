//
//  InfoSpy.m
//  设备信息采集诊断 tweak(仅注入支付宝 com.eg.AlipayiPhone)
//
//  目的: 实机抓取支付宝到底采集了哪些设备信息(改机参数表依据)。
//  两层 hook:
//    ObjC 层: UIDevice/IDFA/剪贴板/WiFi/运营商/定位/URL探测/NSUserDefaults
//    native 层: sysctl/uname/keychain/文件访问(越狱特征过滤)/dyld枚举/fork/getenv/dlopen
//  日志: 去重记录(相同 API+参数只记首次, 重复按 x10/x100 摘要), 防刷屏。
//  路径: 依次尝试 /var/mobile/Media/DCIM/spy_log.txt → /var/mobile/Media/spy_log.txt
//        → App 容器 tmp/spy_log.txt(沙盒拒绝前者时兜底, SSH find 定位)
//
//  约束: 只记录不篡改返回值(诊断态, 不改变 App 行为, 不触发额外风控信号)。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <time.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <mach-o/dyld.h>
#import <Security/Security.h>
#import <CoreTelephony/CoreTelephony.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CoreLocation/CoreLocation.h>

static NSString *const kTargetBundle = @"com.eg.AlipayiPhone";

// ===== 自包含 method swizzle(与 VCamPlus 同款, 不依赖 Substrate 符号) =====
static void SpyHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) { if (origPtr) *origPtr = NULL; return; }
    if (origPtr) *origPtr = method_getImplementation(method);
    method_setImplementation(method, newImp);
}
static void SpyHookClassMethodEx(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method method = class_getClassMethod(cls, sel);
    if (!method) { if (origPtr) *origPtr = NULL; return; }
    if (origPtr) *origPtr = method_getImplementation(method);
    method_setImplementation(method, newImp);
}

// ===== 日志核心: 去重 + 限流 =====
static pthread_mutex_t gSpyLock = PTHREAD_MUTEX_INITIALIZER;
static FILE *gSpyLog = NULL;
static NSString *gSpyLogPath = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gSpySeen = nil;

static void spy_ts(char *buf, size_t n) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    struct tm tm;
    localtime_r(&t.tv_sec, &tm);
    snprintf(buf, n, "%02d:%02d:%02d.%03ld",
             tm.tm_hour, tm.tm_min, tm.tm_sec, t.tv_nsec / 1000000);
}

static NSString *spy_trunc(NSString *s) {
    if (!s) return @"(nil)";
    if (s.length > 200) return [[s substringToIndex:200] stringByAppendingString:@"..."];
    return s;
}

static void spy_log(NSString *cat, NSString *detail) {
    if (!gSpyLog) return;
    if (detail.length > 200) detail = spy_trunc(detail);
    // 防换行打乱日志
    detail = [detail stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    pthread_mutex_lock(&gSpyLock);
    @try {
        if (!gSpySeen) gSpySeen = [NSMutableDictionary new];
        NSString *key = [cat stringByAppendingFormat:@"|%@", detail];
        NSInteger c = [gSpySeen[key] integerValue] + 1;
        gSpySeen[key] = @(c);
        char ts[32];
        spy_ts(ts, sizeof(ts));
        if (c == 1) {
            fprintf(gSpyLog, "[%s] %s | %s\n", ts, cat.UTF8String, detail.UTF8String ?: "");
        } else if (c == 10 || c == 100 || c == 1000 || c == 10000 || c == 100000) {
            fprintf(gSpyLog, "[%s] %s | %s ...(x%ld)\n", ts, cat.UTF8String,
                    detail.UTF8String ?: "", (long)c);
        }
        fflush(gSpyLog);
    } @finally {
        pthread_mutex_unlock(&gSpyLock);
    }
}

// ===== 越狱特征路径过滤(文件类 API 只记特征路径, 其余静默) =====
static NSArray<NSString *> *gJbKeywords = nil;
static BOOL spy_path_interesting(const char *p) {
    if (!p) return NO;
    NSString *s = @(p);
    // App 自身容器/Bundle 资源访问(海量, 无诊断价值)
    if ([s containsString:@"Containers"] || [s containsString:@".app/"]) return NO;
    if (!gJbKeywords) {
        gJbKeywords = @[@"cydia", @"substrate", @"sileo", @"zebra", @"inject",
                        @"tweak", @"jailbreak", @"jbroot", @"roothide", @"dopamine",
                        @"ellekit", @"substitute", @"stash", @"apt", @"bash", @"sshd",
                        @"/var/jb", @"/rootfs", @"MobileSubstrate", @"/bin/",
                        @"/sbin/", @"/usr/lib/", @"/usr/sbin/", @"/etc/apt",
                        @"uicache", @"preferenceloader", @"filza", @"newterm",
                        @"/private/var/db", @"/Applications/", @"/var/mobile/Library",
                        @"/Library/MobileSubstrate", @"/var/tmp", @"/etc/"];
    }
    NSString *low = s.lowercaseString;
    for (NSString *kw in gJbKeywords) {
        if ([low containsString:kw]) return YES;
    }
    return NO;
}

// ===== ObjC 层 hooks =====
#define SPY_OBJ_PROP(clsName, selName, fname, logName) \
static id (*spy_orig_##fname)(id, SEL); \
static id spy_hook_##fname(id self, SEL _cmd) { \
    id r = spy_orig_##fname(self, _cmd); \
    spy_log(@logName, r ? [NSString stringWithFormat:@"%@", r] : @"(nil)"); \
    return r; \
}

// UIDevice
SPY_OBJ_PROP(UIDevice, name, ud_name, "UIDevice.name")
SPY_OBJ_PROP(UIDevice, systemName, ud_sysName, "UIDevice.systemName")
SPY_OBJ_PROP(UIDevice, systemVersion, ud_sysVer, "UIDevice.systemVersion")
SPY_OBJ_PROP(UIDevice, model, ud_model, "UIDevice.model")
SPY_OBJ_PROP(UIDevice, localizedModel, ud_locModel, "UIDevice.localizedModel")
SPY_OBJ_PROP(UIDevice, identifierForVendor, ud_idfv, "UIDevice.identifierForVendor")

static float (*spy_orig_ud_batt)(id, SEL);
static float spy_hook_ud_batt(id self, SEL _cmd) {
    float r = spy_orig_ud_batt(self, _cmd);
    spy_log(@"UIDevice.batteryLevel", [NSString stringWithFormat:@"%.2f", r]);
    return r;
}

// IDFA
static NSUUID *(*spy_orig_idfa)(id, SEL);
static NSUUID *spy_hook_idfa(id self, SEL _cmd) {
    NSUUID *r = spy_orig_idfa(self, _cmd);
    spy_log(@"ASIdentifierManager.advertisingIdentifier", r ? [r UUIDString] : @"(nil)");
    return r;
}

// 剪贴板(读)
SPY_OBJ_PROP(UIPasteboard, string, pb_string, "UIPasteboard.string")
SPY_OBJ_PROP(UIPasteboard, strings, pb_strings, "UIPasteboard.strings")

static id (*spy_orig_pb_value)(id, SEL, NSString *);
static id spy_hook_pb_value(id self, SEL _cmd, NSString *type) {
    id r = spy_orig_pb_value(self, _cmd, type);
    spy_log(@"UIPasteboard.valueForPasteboardType",
            [NSString stringWithFormat:@"%@ = %@", type, spy_trunc([NSString stringWithFormat:@"%@", r ?: @"(nil)"])]);
    return r;
}

static UIPasteboard *(*spy_orig_pb_gen)(Class, SEL);
static UIPasteboard *spy_hook_pb_gen(Class self, SEL _cmd) {
    spy_log(@"UIPasteboard.generalPasteboard", @"(获取剪贴板对象)");
    return spy_orig_pb_gen(self, _cmd);
}

// 运营商
SPY_OBJ_PROP(CTCarrier, carrierName, ctc_name, "CTCarrier.carrierName")
SPY_OBJ_PROP(CTCarrier, mobileCountryCode, ctc_mcc, "CTCarrier.mobileCountryCode")
SPY_OBJ_PROP(CTCarrier, mobileNetworkCode, ctc_mnc, "CTCarrier.mobileNetworkCode")
SPY_OBJ_PROP(CTCarrier, isoCountryCode, ctc_iso, "CTCarrier.isoCountryCode")
SPY_OBJ_PROP(CTTelephonyNetworkInfo, serviceSubscriberCellularProviders, ctni_providers,
             "CTTelephonyNetworkInfo.serviceSubscriberCellularProviders")
SPY_OBJ_PROP(CTTelephonyNetworkInfo, serviceCurrentRadioAccessTechnology, ctni_rat,
             "CTTelephonyNetworkInfo.radioAccessTechnology")

// 屏幕比例(改机分辨率伪装点)
static CGRect (*spy_orig_scr_bounds)(id, SEL);
static CGRect spy_hook_scr_bounds(id self, SEL _cmd) {
    CGRect r = spy_orig_scr_bounds(self, _cmd);
    spy_log(@"UIScreen.bounds", NSStringFromCGRect(r));
    return r;
}
static CGRect (*spy_orig_scr_nativeBounds)(id, SEL);
static CGRect spy_hook_scr_nativeBounds(id self, SEL _cmd) {
    CGRect r = spy_orig_scr_nativeBounds(self, _cmd);
    spy_log(@"UIScreen.nativeBounds", NSStringFromCGRect(r));
    return r;
}
static CGFloat (*spy_orig_scr_scale)(id, SEL);
static CGFloat spy_hook_scr_scale(id self, SEL _cmd) {
    CGFloat r = spy_orig_scr_scale(self, _cmd);
    spy_log(@"UIScreen.scale", [NSString stringWithFormat:@"%.2f", r]);
    return r;
}
static CGFloat (*spy_orig_scr_nativeScale)(id, SEL);
static CGFloat spy_hook_scr_nativeScale(id self, SEL _cmd) {
    CGFloat r = spy_orig_scr_nativeScale(self, _cmd);
    spy_log(@"UIScreen.nativeScale", [NSString stringWithFormat:@"%.2f", r]);
    return r;
}

// 进程信息
SPY_OBJ_PROP(NSProcessInfo, operatingSystemVersionString, pi_osVer, "NSProcessInfo.operatingSystemVersionString")
SPY_OBJ_PROP(NSProcessInfo, hostName, pi_host, "NSProcessInfo.hostName")
static unsigned long long (*spy_orig_pi_mem)(id, SEL);
static unsigned long long spy_hook_pi_mem(id self, SEL _cmd) {
    unsigned long long r = spy_orig_pi_mem(self, _cmd);
    spy_log(@"NSProcessInfo.physicalMemory", [NSString stringWithFormat:@"%llu", r]);
    return r;
}

// Locale
static NSLocale *(*spy_orig_locale)(Class, SEL);
static NSLocale *spy_hook_locale(Class self, SEL _cmd) {
    NSLocale *l = spy_orig_locale(self, _cmd);
    spy_log(@"NSLocale.currentLocale", l.localeIdentifier ?: @"(nil)");
    return l;
}

// URL 探测(检测安装了哪些 App)
static BOOL (*spy_orig_canOpenURL)(id, SEL, NSURL *);
static BOOL spy_hook_canOpenURL(id self, SEL _cmd, NSURL *url) {
    BOOL r = spy_orig_canOpenURL(self, _cmd, url);
    spy_log(@"UIApplication.canOpenURL",
            [NSString stringWithFormat:@"%@ -> %d", url.absoluteString ?: @"(nil)", r]);
    return r;
}

// NSUserDefaults(特征 key 过滤)
static NSArray<NSString *> *gUdKeywords = nil;
static BOOL spy_ud_key_interesting(NSString *key) {
    if (!key) return NO;
    if (!gUdKeywords) {
        gUdKeywords = @[@"device", @"uuid", @"idfa", @"jail", @"apdid", @"umid",
                        @"finger", @"fp", @"token", @"utdid", @"imid", @"sdk"];
    }
    NSString *low = key.lowercaseString;
    for (NSString *kw in gUdKeywords) {
        if ([low containsString:kw]) return YES;
    }
    return NO;
}
static id (*spy_orig_ud_get)(id, SEL, NSString *);
static id spy_hook_ud_get(id self, SEL _cmd, NSString *key) {
    id r = spy_orig_ud_get(self, _cmd, key);
    if (spy_ud_key_interesting(key)) {
        spy_log(@"NSUserDefaults.objectForKey",
                [NSString stringWithFormat:@"%@ = %@", key, spy_trunc([NSString stringWithFormat:@"%@", r ?: @"(nil)"])]);
    }
    return r;
}

// 定点(定位权限/启动)
static void (*spy_orig_cl_start)(id, SEL);
static void spy_hook_cl_start(id self, SEL _cmd) {
    spy_log(@"CLLocationManager.startUpdatingLocation", @"(开始定位)");
    return spy_orig_cl_start(self, _cmd);
}
static void (*spy_orig_cl_reqWhen)(id, SEL);
static void spy_hook_cl_reqWhen(id self, SEL _cmd) {
    spy_log(@"CLLocationManager.requestWhenInUseAuthorization", @"(请求定位权限)");
    return spy_orig_cl_reqWhen(self, _cmd);
}
static long (*spy_orig_cl_auth)(Class, SEL);
static long spy_hook_cl_auth(Class self, SEL _cmd) {
    long r = spy_orig_cl_auth(self, _cmd);
    spy_log(@"CLLocationManager.authorizationStatus", [NSString stringWithFormat:@"%ld", r]);
    return r;
}

static int gObjcHookCount = 0;
static void installObjCHooks(void) {
    #define INSTALL_PROP(clsName, selName, fname) do { \
        SpyHookMessageEx(objc_getClass(clsName), sel_registerName(selName), \
                         (IMP)spy_hook_##fname, (IMP *)&spy_orig_##fname); \
        if (spy_orig_##fname) gObjcHookCount++; \
    } while (0)
    #define INSTALL_CLS_PROP(clsName, selName, fname) do { \
        SpyHookClassMethodEx(objc_getClass(clsName), sel_registerName(selName), \
                             (IMP)spy_hook_##fname, (IMP *)&spy_orig_##fname); \
        if (spy_orig_##fname) gObjcHookCount++; \
    } while (0)

    INSTALL_PROP("UIDevice", "name", ud_name);
    INSTALL_PROP("UIDevice", "systemName", ud_sysName);
    INSTALL_PROP("UIDevice", "systemVersion", ud_sysVer);
    INSTALL_PROP("UIDevice", "model", ud_model);
    INSTALL_PROP("UIDevice", "localizedModel", ud_locModel);
    INSTALL_PROP("UIDevice", "identifierForVendor", ud_idfv);
    INSTALL_PROP("UIDevice", "batteryLevel", ud_batt);

    Class asidMgr = objc_getClass("ASIdentifierManager");
    if (asidMgr) {
        SpyHookMessageEx(asidMgr, sel_registerName("advertisingIdentifier"),
                         (IMP)spy_hook_idfa, (IMP *)&spy_orig_idfa);
        if (spy_orig_idfa) gObjcHookCount++;
    }

    INSTALL_PROP("UIPasteboard", "string", pb_string);
    INSTALL_PROP("UIPasteboard", "strings", pb_strings);
    INSTALL_PROP("UIPasteboard", "valueForPasteboardType:", pb_value);
    INSTALL_CLS_PROP("UIPasteboard", "generalPasteboard", pb_gen);

    INSTALL_PROP("CTCarrier", "carrierName", ctc_name);
    INSTALL_PROP("CTCarrier", "mobileCountryCode", ctc_mcc);
    INSTALL_PROP("CTCarrier", "mobileNetworkCode", ctc_mnc);
    INSTALL_PROP("CTCarrier", "isoCountryCode", ctc_iso);
    INSTALL_PROP("CTTelephonyNetworkInfo", "serviceSubscriberCellularProviders", ctni_providers);
    INSTALL_PROP("CTTelephonyNetworkInfo", "serviceCurrentRadioAccessTechnology", ctni_rat);

    INSTALL_PROP("UIScreen", "bounds", scr_bounds);
    INSTALL_PROP("UIScreen", "nativeBounds", scr_nativeBounds);
    INSTALL_PROP("UIScreen", "scale", scr_scale);
    INSTALL_PROP("UIScreen", "nativeScale", scr_nativeScale);

    INSTALL_PROP("NSProcessInfo", "operatingSystemVersionString", pi_osVer);
    INSTALL_PROP("NSProcessInfo", "hostName", pi_host);
    INSTALL_PROP("NSProcessInfo", "physicalMemory", pi_mem);

    INSTALL_CLS_PROP("NSLocale", "currentLocale", locale);
    INSTALL_PROP("UIApplication", "canOpenURL:", canOpenURL);
    INSTALL_PROP("NSUserDefaults", "objectForKey:", ud_get);

    INSTALL_PROP("CLLocationManager", "startUpdatingLocation", cl_start);
    INSTALL_PROP("CLLocationManager", "requestWhenInUseAuthorization", cl_reqWhen);
    INSTALL_CLS_PROP("CLLocationManager", "authorizationStatus", cl_auth);
}

// ===== native 层 hooks(MSHookFunction 经 dlsym 动态获取) =====
typedef void *(*MSHookFunction_t)(void *, void *, void **);
static MSHookFunction_t gMSHookFunction = NULL;
static int gNativeHookCount = 0;

typedef int (*sysctlbyname_t)(const char *, void *, size_t *, void *, size_t);
static sysctlbyname_t spy_orig_sysctlbyname;
static int spy_hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = spy_orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (oldp && name) spy_log(@"sysctlbyname", @(name));
    return r;
}

typedef int (*sysctl_t)(int *, u_int, void *, size_t *, void *, size_t);
static sysctl_t spy_orig_sysctl;
static int spy_hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = spy_orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (oldp && namelen >= 1) {
        spy_log(@"sysctl", [NSString stringWithFormat:@"mib=%d,%d len=%u",
                            name[0], namelen > 1 ? name[1] : 0, namelen]);
    }
    return r;
}

typedef int (*uname_t)(struct utsname *);
static uname_t spy_orig_uname;
static int spy_hook_uname(struct utsname *n) {
    int r = spy_orig_uname(n);
    if (r == 0 && n) {
        spy_log(@"uname", [NSString stringWithFormat:@"machine=%s release=%s sysname=%s",
                           n->machine, n->release, n->sysname]);
    }
    return r;
}

typedef char *(*getenv_t)(const char *);
static getenv_t spy_orig_getenv;
static char *spy_hook_getenv(const char *name) {
    char *r = spy_orig_getenv(name);
    if (name) spy_log(@"getenv", [NSString stringWithFormat:@"%s = %s", name, r ? r : "(null)"]);
    return r;
}

typedef pid_t (*fork_t)(void);
static fork_t spy_orig_fork;
static pid_t spy_hook_fork(void) {
    pid_t r = spy_orig_fork();
    spy_log(@"fork", [NSString stringWithFormat:@"ret=%d", r]);
    return r;
}

typedef FILE *(*fopen_t)(const char *, const char *);
static fopen_t spy_orig_fopen;
static FILE *spy_hook_fopen(const char *path, const char *mode) {
    if (spy_path_interesting(path)) spy_log(@"fopen", @(path));
    return spy_orig_fopen(path, mode);
}

typedef int (*stat_t)(const char *, struct stat *);
static stat_t spy_orig_stat;
static int spy_hook_stat(const char *path, struct stat *buf) {
    int r = spy_orig_stat(path, buf);
    if (spy_path_interesting(path)) {
        spy_log(@"stat", [NSString stringWithFormat:@"%@ -> %d", @(path), r]);
    }
    return r;
}

typedef int (*lstat_t)(const char *, struct stat *);
static lstat_t spy_orig_lstat;
static int spy_hook_lstat(const char *path, struct stat *buf) {
    int r = spy_orig_lstat(path, buf);
    if (spy_path_interesting(path)) {
        spy_log(@"lstat", [NSString stringWithFormat:@"%@ -> %d", @(path), r]);
    }
    return r;
}

typedef int (*access_t)(const char *, int);
static access_t spy_orig_access;
static int spy_hook_access(const char *path, int mode) {
    int r = spy_orig_access(path, mode);
    if (spy_path_interesting(path)) {
        spy_log(@"access", [NSString stringWithFormat:@"%@ mode=%d -> %d", @(path), mode, r]);
    }
    return r;
}

typedef char *(*realpath_t)(const char *, char *);
static realpath_t spy_orig_realpath;
static char *spy_hook_realpath(const char *path, char *resolved) {
    char *r = spy_orig_realpath(path, resolved);
    if (spy_path_interesting(path)) {
        spy_log(@"realpath", [NSString stringWithFormat:@"%@ -> %s", @(path), r ? r : "(null)"]);
    }
    return r;
}

typedef void *(*dlopen_t)(const char *, int);
static dlopen_t spy_orig_dlopen;
static void *spy_hook_dlopen(const char *path, int mode) {
    if (path) spy_log(@"dlopen", @(path));
    return spy_orig_dlopen(path, mode);
}

typedef OSStatus (*SecItemCopyMatching_t)(CFDictionaryRef, CFTypeRef *);
static SecItemCopyMatching_t spy_orig_SecItemCopyMatching;
static OSStatus spy_hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (query) {
        NSDictionary *q = (__bridge NSDictionary *)query;
        spy_log(@"SecItemCopyMatching", [NSString stringWithFormat:@"class=%@ service=%@ account=%@ label=%@",
                q[(__bridge NSString *)kSecClass] ?: @"-",
                q[(__bridge NSString *)kSecAttrService] ?: @"-",
                q[(__bridge NSString *)kSecAttrAccount] ?: @"-",
                q[(__bridge NSString *)kSecAttrLabel] ?: @"-"]);
    }
    return spy_orig_SecItemCopyMatching(query, result);
}

typedef const char *(*dyld_name_t)(uint32_t);
static dyld_name_t spy_orig_dyld_get_image_name;
static const char *spy_hook_dyld_get_image_name(uint32_t idx) {
    const char *r = spy_orig_dyld_get_image_name(idx);
    spy_log(@"dyld_image_name", [NSString stringWithFormat:@"[%u] %s", idx, r ? r : "?"]);
    return r;
}

typedef uint32_t (*dyld_count_t)(void);
static dyld_count_t spy_orig_dyld_image_count;
static uint32_t spy_hook_dyld_image_count(void) {
    uint32_t r = spy_orig_dyld_image_count();
    spy_log(@"dyld_image_count", [NSString stringWithFormat:@"%u", r]);
    return r;
}

typedef CFDictionaryRef (*CNCopyCurrentNetworkInfo_t)(CFStringRef);
static CNCopyCurrentNetworkInfo_t spy_orig_CNCopyCurrentNetworkInfo;
static CFDictionaryRef spy_hook_CNCopyCurrentNetworkInfo(CFStringRef iface) {
    CFDictionaryRef r = spy_orig_CNCopyCurrentNetworkInfo(iface);
    // __bridge 只读不转移所有权(调用方仍持有返回值, ARC 不得释放)
    NSDictionary *d = r ? (__bridge NSDictionary *)r : nil;
    spy_log(@"CNCopyCurrentNetworkInfo",
            [NSString stringWithFormat:@"%@ = %@", (__bridge NSString *)iface,
                     d ? [NSString stringWithFormat:@"SSID=%@ BSSID=%@", d[@"SSID"], d[@"BSSID"]] : @"(nil)"]);
    return r;
}

static void installNativeHooks(void) {
    gMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!gMSHookFunction) {
        spy_log(@"InfoSpy", @"MSHookFunction 不可用, native 层未 hook");
        return;
    }
    #define NH(fn) do { \
        gMSHookFunction((void *)fn, (void *)spy_hook_##fn, (void **)&spy_orig_##fn); \
        if (spy_orig_##fn) gNativeHookCount++; \
    } while (0)

    NH(sysctlbyname);
    NH(sysctl);
    NH(uname);
    NH(getenv);
    NH(fork);
    NH(fopen);
    NH(stat);
    NH(lstat);
    NH(access);
    NH(realpath);
    NH(dlopen);
    NH(SecItemCopyMatching);
    NH(CNCopyCurrentNetworkInfo);
    // dyld 符号带前导下划线, 宏拼接会双下划线不匹配, 显式安装
    gMSHookFunction((void *)_dyld_get_image_name,
                    (void *)spy_hook_dyld_get_image_name,
                    (void **)&spy_orig_dyld_get_image_name);
    if (spy_orig_dyld_get_image_name) gNativeHookCount++;
    gMSHookFunction((void *)_dyld_image_count,
                    (void *)spy_hook_dyld_image_count,
                    (void **)&spy_orig_dyld_image_count);
    if (spy_orig_dyld_image_count) gNativeHookCount++;
}

// ===== 入口 =====
static void spy_pick_log_path(void) {
    NSArray *cands = @[
        @"/var/mobile/Media/DCIM/spy_log.txt",
        @"/var/mobile/Media/spy_log.txt",
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"spy_log.txt"],
    ];
    for (NSString *p in cands) {
        FILE *f = fopen(p.UTF8String, "a");
        if (f) {
            gSpyLog = f;
            gSpyLogPath = p;
            return;
        }
    }
}

__attribute__((constructor))
static void InfoSpyInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        // 双保险: plist Filter 已限定支付宝, 此处再校验(防 Filter 失效注入所有进程)
        if (![bid isEqualToString:kTargetBundle]) return;

        spy_pick_log_path();
        if (!gSpyLog) {
            NSLog(@"[InfoSpy] no writable log path!");
            return;
        }
        // banner
        char ts[32];
        spy_ts(ts, sizeof(ts));
        fprintf(gSpyLog, "\n==== InfoSpy start [%s] pid=%d bundle=%@ ====\n",
                ts, getpid(), bid);
        fprintf(gSpyLog, "log path: %@\n", gSpyLogPath);
        fflush(gSpyLog);
        NSLog(@"[InfoSpy] log -> %@", gSpyLogPath);

        installObjCHooks();
        installNativeHooks();

        fprintf(gSpyLog, "hooks installed: objc=%d native=%d\n", gObjcHookCount, gNativeHookCount);
        fflush(gSpyLog);

        // 首次 dump: 当前进程全部 dylib(检测者视角的镜像列表)
        uint32_t n = _dyld_image_count();
        fprintf(gSpyLog, "-- dyld images (%u) --\n", n);
        for (uint32_t i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            fprintf(gSpyLog, "  [%u] %s\n", i, nm ? nm : "?");
        }
        fflush(gSpyLog);
    }
}
