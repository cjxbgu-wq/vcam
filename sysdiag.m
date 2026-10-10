//
//  sysdiag.m — 编译为 libsysdiag.dylib(临时诊断探针, 1.3.108b)
//
//  用途: 注入目标 App(云闪付 com.unionpay.chsp), hook 内存级检测 API,
//  记录到 App 容器 tmp/sd.log(SSH root 直读; 设备无 log 命令, os_log 弃用):
//    1. dyld 镜像枚举(_dyld_get_image_name / _dyld_get_image_header /
//       objc_copyImageNames / dladdr) —— 是否数进程内注入的 dylib
//    2. 类名探测(objc_getClass / objc_lookUpClass) —— 是否查 tweak 类名
//    3. 进程探测(sysctl kern.proc*) / shell 逃逸(popen/system/posix_spawn)
//    4. 通知监听/发布(notify_register_dispatch / notify_post)
//    5. dlopen 动态库探测
//  诊断完成后整体移除(不参与混淆/leak gate —— 必须含敏感词表)。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <notify.h>
#import <spawn.h>
#import <pthread.h>
#import <sys/time.h>
#import <stdarg.h>
#import <stdio.h>

extern void MSHookFunction(void *symbol, void *replacement, void **result);

static FILE *gLog = NULL;
static pthread_mutex_t gMtx = PTHREAD_MUTEX_INITIALIZER;

static void sdlog(const char *fmt, ...) {
    if (!gLog) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    localtime_r(&tv.tv_sec, &tmv);
    va_list ap;
    va_start(ap, fmt);
    pthread_mutex_lock(&gMtx);
    fprintf(gLog, "%02d:%02d:%02d.%03d ",
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec, tv.tv_usec / 1000);
    vfprintf(gLog, fmt, ap);
    fputc('\n', gLog);
    fflush(gLog);
    pthread_mutex_unlock(&gMtx);
    va_end(ap);
}

// 敏感词表(镜像路径/类名/通知名命中即记录; strstr 大小写敏感按原样)
static const char *kSens[] = {
    "vcam", "VCam", "uigest", "substrate", "Substrate", "substitute",
    "libhooker", "ellekit", "ElleKit", "cynject", "cycript", "frida",
    "Frida", "injector", "Injector", "tweakinject", "TweakInject",
    "jailbreak", "jbroot", "/var/jb", "cydia", "Cydia", "sileo", "Sileo",
    "zebra", "trollstore", "TrollStore", "systemhook", "roothide",
    "RootHide", "libsysdiag", "sysdiag", NULL
};
static int sd_sens(const char *s) {
    if (!s) return 0;
    for (int i = 0; kSens[i]; i++)
        if (strstr(s, kSens[i])) return 1;
    return 0;
}

// ===== 1. dyld 镜像枚举 =====
static const char *(*orig_dgni)(uint32_t);
static const char *hk_dgni(uint32_t idx) {
    const char *nm = orig_dgni(idx);
    if (sd_sens(nm))
        sdlog("[PRB] dyld_get_image_name(%u) -> %s [SENS]", idx, nm);
    return nm;
}

static const struct mach_header *(*orig_dgh)(uint32_t);
static const struct mach_header *hk_dgh(uint32_t idx) {
    const struct mach_header *h = orig_dgh(idx);
    if (h && sd_sens(orig_dgni ? orig_dgni(idx) : NULL))
        sdlog("[PRB] dyld_get_image_header(%u) [SENS]", idx);
    return h;
}

static unsigned (*orig_ocin)(const char **);
static unsigned hk_ocin(const char **outNames) {
    unsigned n = orig_ocin(outNames);
    sdlog("[PRB] objc_copyImageNames n=%u", n);
    for (unsigned i = 0; outNames && i < n; i++)
        if (sd_sens(outNames[i]))
            sdlog("[PRB] copyImageNames[%u]=%s [SENS]", i, outNames[i]);
    return n;
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int hk_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr(addr, info);
    if (r && info && sd_sens(info->dli_fname))
        sdlog("[PRB] dladdr(%p) -> %s [SENS]", addr, info->dli_fname);
    return r;
}

// ===== 2. 类名探测 =====
static Class (*orig_ogc)(const char *);
static Class hk_ogc(const char *name) {
    if (sd_sens(name))
        sdlog("[PRB] objc_getClass(%s) [SENS]", name);
    return orig_ogc(name);
}

static Class (*orig_oluc)(const char *);
static Class hk_oluc(const char *name) {
    if (sd_sens(name))
        sdlog("[PRB] objc_lookUpClass(%s) [SENS]", name);
    return orig_oluc(name);
}

// ===== 3. sysctl 进程探测 + shell 逃逸 =====
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int hk_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                     void *newp, size_t newlen) {
    if (namelen >= 2 && name && name[0] == CTL_KERN
        && (name[1] == KERN_PROC || name[1] == KERN_PROC_ALL
            || name[1] == KERN_PROC_PID || name[1] == KERN_PROCARGS))
        sdlog("[PRB] sysctl kern.proc(%d,%d) len=%u", name[0], name[1], namelen);
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static FILE *(*orig_popen)(const char *, const char *);
static FILE *hk_popen(const char *cmd, const char *mode) {
    sdlog("[PRB] popen(%s, %s)", cmd ? cmd : "(null)", mode ? mode : "");
    return orig_popen(cmd, mode);
}

static int (*orig_system)(const char *);
static int hk_system(const char *cmd) {
    sdlog("[PRB] system(%s)", cmd ? cmd : "(null)");
    return orig_system(cmd);
}

static int (*orig_ps)(const char *path, pid_t *pid, const char **argv,
                      const char **envp, posix_spawn_file_actions_t,
                      const posix_spawnattr_t *);
static int hk_ps(const char *path, pid_t *pid, const char **argv,
                 const char **envp, posix_spawn_file_actions_t fa,
                 const posix_spawnattr_t *sa) {
    if (path)
        sdlog("[PRB] posix_spawn(%s)", path);
    return orig_ps(path, pid, argv, envp, fa, sa);
}

// ===== 4. 通知监听/发布 =====
static uint32_t (*orig_nrd)(const char *, int *, dispatch_queue_t, void (*)(int));
static uint32_t hk_nrd(const char *name, int *tok, dispatch_queue_t q, void (*h)(int)) {
    sdlog("[PRB] notify_register_dispatch(%s)", name ? name : "(null)");
    return orig_nrd(name, tok, q, h);
}

static uint32_t (*orig_np)(const char *);
static uint32_t hk_np(const char *name) {
    if (name && sd_sens(name))
        sdlog("[PRB] notify_post(%s) [SENS]", name);
    return orig_np(name);
}

// ===== 5. dlopen =====
static void *(*orig_dlopen)(const char *, int);
static void *hk_dlopen(const char *path, int mode) {
    if (path)
        sdlog("[PRB] dlopen(%s)", path);
    return orig_dlopen(path, mode);
}

__attribute__((constructor))
static void sdInit(void) {
    // ellekit 的 Bundles filter 只匹配已加载 framework 的 bundle id → plist
    // 用 com.apple.UIKit 保注入。目标自检用 getenv("HOME")(容器路径) ——
    // NSBundle mainBundle / NSHomeDirectory 在 constructor(main 之前)尚未
    // 初始化返回 nil, 环境变量在 exec 时已就绪(1.3.108 fix3)
    const char *home = getenv("HOME");
    if (!home || !strstr(home, "A1B6AB96-3969-4FB5-BDFA-9C51B9055FBE")) return;

    char path[512];
    snprintf(path, sizeof(path), "%s/tmp/sd.log", home);
    gLog = fopen(path, "a");
    if (!gLog) return;
    sdlog("[PRB] probe loaded pid=%d home=%s", getpid(), home);

    struct hk { void **orig; void *repl; } hks[] = {
        { (void **)&orig_dgni,   (void *)hk_dgni },
        { (void **)&orig_dgh,    (void *)hk_dgh },
        { (void **)&orig_ocin,   (void *)hk_ocin },
        { (void **)&orig_dladdr, (void *)hk_dladdr },
        { (void **)&orig_ogc,    (void *)hk_ogc },
        { (void **)&orig_oluc,   (void *)hk_oluc },
        { (void **)&orig_sysctl, (void *)hk_sysctl },
        { (void **)&orig_popen,  (void *)hk_popen },
        { (void **)&orig_system, (void *)hk_system },
        { (void **)&orig_ps,     (void *)hk_ps },
        { (void **)&orig_nrd,    (void *)hk_nrd },
        { (void **)&orig_np,     (void *)hk_np },
        { (void **)&orig_dlopen, (void *)hk_dlopen },
    };
    const char *names[] = {
        "_dyld_get_image_name", "_dyld_get_image_header",
        "_objc_copyImageNames", "dladdr",
        "objc_getClass", "objc_lookUpClass",
        "sysctl", "popen", "system", "posix_spawn",
        "notify_register_dispatch", "notify_post", "dlopen",
    };
    int n = sizeof(hks) / sizeof(hks[0]);
    int armed = 0;
    for (int i = 0; i < n; i++) {
        void *sym = dlsym(RTLD_DEFAULT, names[i]);
        if (!sym) {
            sdlog("[PRB] dlsym miss %s", names[i]);
            continue;
        }
        MSHookFunction(sym, hks[i].repl, hks[i].orig);
        armed++;
    }
    sdlog("[PRB] hooks armed (%d/%d)", armed, n);
}
