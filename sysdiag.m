//
//  libsysdiag.m — 编译为 libsysdiag.dylib(临时诊断探针, 1.3.108)
//
//  用途: 注入目标 App(云闪付 com.unionpay.chsp), hook 内存级检测 API,
//  经 os_log 输出调用记录(SSH 端 log stream 抓取), 评估 App 风控行为:
//    1. dyld 镜像枚举(_dyld_get_image_name / _dyld_get_image_header /
//       objc_copyImageNames / dladdr) —— 是否数进程内注入的 dylib
//    2. 类名探测(objc_getClass / objc_lookUpClass) —— 是否查 tweak 类名
//    3. 进程探测(sysctl kern.proc*) / shell 逃逸(popen/system/posix_spawn)
//    4. 通知监听/发布(notify_register_dispatch / notify_post)
//    5. dlopen 动态库探测
//  输出格式: "[PRB] ..." 前缀, predicate 过滤。诊断完成后整体移除。
//
//  中性化: 文件名/lib 名/subsystem 全部系统风格; 敏感词仅内存匹配不落盘。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>
#import <sys/sysctl.h>
#import <notify.h>
#import <spawn.h>

extern void MSHookFunction(void *symbol, void *replacement, void **result);

static os_log_t SDLog = NULL;

// 敏感词表(镜像路径/类名/通知名命中即记录; 全小写 strstr 匹配)
static const char *kSens[] = {
    "vcam", "uigest", "substrate", "substitute", "libhooker", "ellekit",
    "cynject", "cycript", "frida", "injector", "tweakinject", "jailbreak",
    "jbroot", "/var/jb", "cydia", "sileo", "zebra", "trollstore",
    "systemhook", "roothide", "libuigest", "sysdiag", NULL
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
        os_log(SDLog, "[PRB] dyld_get_image_name(%u) -> %{public}s [SENS]", idx, nm);
    return nm;
}

static const struct mach_header *(*orig_dgh)(uint32_t);
static const struct mach_header *hk_dgh(uint32_t idx) {
    const struct mach_header *h = orig_dgh(idx);
    if (h) {
        const char *nm = orig_dgni ? orig_dgni(idx) : NULL;
        if (sd_sens(nm))
            os_log(SDLog, "[PRB] dyld_get_image_header(%u) %{public}s [SENS]", idx, nm);
    }
    return h;
}

static unsigned (*orig_ocin)(const char **);
static unsigned hk_ocin(const char **outNames) {
    unsigned n = orig_ocin(outNames);
    os_log(SDLog, "[PRB] objc_copyImageNames n=%u", n);
    for (unsigned i = 0; outNames && i < n; i++)
        if (sd_sens(outNames[i]))
            os_log(SDLog, "[PRB] copyImageNames[%u]=%{public}s [SENS]", i, outNames[i]);
    return n;
}

// dladdr(查地址所属镜像 —— 风控用它定位可疑函数)
static int (*orig_dladdr)(const void *, Dl_info *);
static int hk_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr(addr, info);
    if (r && info && sd_sens(info->dli_fname))
        os_log(SDLog, "[PRB] dladdr(%p) -> %{public}s [SENS]", addr, info->dli_fname);
    return r;
}

// ===== 2. 类名探测 =====
static Class (*orig_ogc)(const char *);
static Class hk_ogc(const char *name) {
    if (sd_sens(name))
        os_log(SDLog, "[PRB] objc_getClass(%{public}s) [SENS]", name);
    return orig_ogc(name);
}

static Class (*orig_oluc)(const char *);
static Class hk_oluc(const char *name) {
    if (sd_sens(name))
        os_log(SDLog, "[PRB] objc_lookUpClass(%{public}s) [SENS]", name);
    return orig_oluc(name);
}

// ===== 3. sysctl 进程探测 + shell 逃逸 =====
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int hk_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                     void *newp, size_t newlen) {
    if (namelen >= 2 && name && name[0] == CTL_KERN
        && (name[1] == KERN_PROC || name[1] == KERN_PROC_ALL
            || name[1] == KERN_PROC_PID || name[1] == KERN_PROCARGS))
        os_log(SDLog, "[PRB] sysctl kern.proc(%d,%d) len=%u", name[0], name[1], namelen);
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static FILE *(*orig_popen)(const char *, const char *);
static FILE *hk_popen(const char *cmd, const char *mode) {
    os_log(SDLog, "[PRB] popen(%{public}s, %{public}s)", cmd ? cmd : "(null)",
           mode ? mode : "");
    return orig_popen(cmd, mode);
}

static int (*orig_system)(const char *);
static int hk_system(const char *cmd) {
    os_log(SDLog, "[PRB] system(%{public}s)", cmd ? cmd : "(null)");
    return orig_system(cmd);
}

static int (*orig_ps)(const char *path, pid_t *pid, const char **argv,
                      const char **envp, posix_spawn_file_actions_t,
                      const posix_spawnattr_t *);
static int hk_ps(const char *path, pid_t *pid, const char **argv,
                 const char **envp, posix_spawn_file_actions_t fa,
                 const posix_spawnattr_t *sa) {
    if (path)
        os_log(SDLog, "[PRB] posix_spawn(%{public}s)", path);
    return orig_ps(path, pid, argv, envp, fa, sa);
}

// ===== 4. 通知监听/发布 =====
static uint32_t (*orig_nrd)(const char *, int *, dispatch_queue_t, void (*)(int));
static uint32_t hk_nrd(const char *name, int *tok, dispatch_queue_t q, void (*h)(int)) {
    os_log(SDLog, "[PRB] notify_register_dispatch(%{public}s)",
           name ? name : "(null)");
    return orig_nrd(name, tok, q, h);
}

static uint32_t (*orig_np)(const char *);
static uint32_t hk_np(const char *name) {
    if (name && sd_sens(name))
        os_log(SDLog, "[PRB] notify_post(%{public}s) [SENS]", name);
    return orig_np(name);
}

// ===== 5. dlopen =====
static void *(*orig_dlopen)(const char *, int);
static void *hk_dlopen(const char *path, int mode) {
    if (path)
        os_log(SDLog, "[PRB] dlopen(%{public}s)", path);
    return orig_dlopen(path, mode);
}

__attribute__((constructor))
static void sdInit(void) {
    SDLog = os_log_create("com.apple.systemdiagnostics", "probe");
    os_log(SDLog, "[PRB] probe loaded pid=%d", getpid());

    struct hk { void **sym; void *repl; void **orig; } hks[] = {
        { (void **)&orig_dgni, (void *)hk_dgni, NULL },
        { (void **)&orig_dgh,  (void *)hk_dgh,  NULL },
        { (void **)&orig_ocin, (void *)hk_ocin, NULL },
        { (void **)&orig_dladdr, (void *)hk_dladdr, NULL },
        { (void **)&orig_ogc,  (void *)hk_ogc,  NULL },
        { (void **)&orig_oluc, (void *)hk_oluc, NULL },
        { (void **)&orig_sysctl, (void *)hk_sysctl, NULL },
        { (void **)&orig_popen, (void *)hk_popen, NULL },
        { (void **)&orig_system, (void *)hk_system, NULL },
        { (void **)&orig_ps,   (void *)hk_ps,   NULL },
        { (void **)&orig_nrd,  (void *)hk_nrd,  NULL },
        { (void **)&orig_np,   (void *)hk_np,   NULL },
        { (void **)&orig_dlopen, (void *)hk_dlopen, NULL },
    };
    const char *names[] = {
        "_dyld_get_image_name", "_dyld_get_image_header",
        "_objc_copyImageNames", "dladdr",
        "objc_getClass", "objc_lookUpClass",
        "sysctl", "popen", "system", "posix_spawn",
        "notify_register_dispatch", "notify_post", "dlopen",
    };
    int n = sizeof(hks) / sizeof(hks[0]);
    for (int i = 0; i < n; i++) {
        void *sym = dlsym(RTLD_DEFAULT, names[i]);
        if (!sym) {
            os_log(SDLog, "[PRB] dlsym miss %{public}s", names[i]);
            continue;
        }
        void **orig = hks[i].orig ? hks[i].orig : (void **)hks[i].sym;
        MSHookFunction(sym, hks[i].repl, orig);
    }
    os_log(SDLog, "[PRB] hooks armed (%d)", n);
}
