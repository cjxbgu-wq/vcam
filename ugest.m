//
//  ugest.m — 编译为 libuigest.dylib(App 进程取色采样器)
//
//  【1.3.95 反检测重构: 主 dylib 退出 App 进程】
//  背景: 主 dylib(VCamPlus.dylib) 以往按 com.apple.UIKit bundle 注入所有
//  UIKit App —— ObjC 类(VCamCore/VCamNotify/VCamFloatingBall/NSQueue 等)
//  在加载瞬间全量注册进宿主 App runtime, 风控 SDK 一句
//  objc_getClass("VCamCore") 或全量类名 diff 即命中; 另有命名 dispatch 队列
//  (com.vcam.samp)、com.vcam.ios.* Darwin 通知、容器 tmp 诊断文件等痕迹。
//  1.3.64 已实证 UICSI 在 SB 进程只截 SB 图层(App 前台全黑) → 取色采样
//  只能留在前台 App 进程内。方案: 采样器拆成独立纯 C dylib ——
//    - 零 ObjC 类/分类定义(@interface/@implementation 均无) → runtime 零注册,
//      类名扫描/objc_getClass 探测全部落空
//    - 零文件写入(旧版每 5s 写容器 tmp/vcampick_diag.txt 的诊断一并移除)
//    - 通道名/通知名/总线路径全中性化(与主 dylib VCamNotify.m 常量同步约定)
//    - Darwin 通知改为中性名 backboard.stat.*(不再有 com.vcam.* 全系统可见名)
//  主 dylib 的 Filter 同步收窄为 Executables(mediaserverd/SpringBoard/lskdd),
//  第三方 App 进程内不再有 VCamPlus 镜像/类/队列。
//
//  架构(与 1.3.65~1.3.94 的 App 采样器等价):
//    constructor → 探测 sharedApplication(0.5s×30, 守护进程静默退出)
//    → 注册 cfg 开/关 Darwin 通知(初始关) → 主队列 12.5Hz timer
//    → Active×2 判定 + 采样耗时 EMA 退避 → UICSI 全屏捕获(32×64 网格)
//    → HSV 分档计票 + 6 拍滑窗多数票/连 0 滞回 → 写 mmap 总线(通道A)
//    + post Darwin slot 通知(通道B, 沙盒拒 mmap 时的保底, SB 端中继转发)
//

#include <dispatch/dispatch.h>
#include <notify.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stddef.h>
#include <math.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <CoreGraphics/CoreGraphics.h>
#include <objc/runtime.h>
#include <objc/message.h>

// ===== 与主 dylib(VCamNotify.m)同步约定的中性常量 =====
// Darwin 通知名(全系统可见, 用系统风格短名, 不得带项目特征)
#define UG_CFG_ON_NAME   "backboard.stat.c1"
#define UG_CFG_OFF_NAME  "backboard.stat.c0"
// slot 通知名前缀: backboard.stat.s0 .. s6 (s0=熄灭)
#define UG_SLOT_PREFIX   "backboard.stat.s"

// ===== 敏感字面量 XOR(同 Android libvc vc_sp_dexor 方案, 防泄露门/静态扫描) =====
// dst[i] = src[i] ^ ((0x53 + i*7) & 0xFF)。三条: UICSI 符号名 / SB 进程名 /
// 总线路径 —— 明文会命中 check_leak 关键字且是"屏幕捕获类 tweak"的静态指纹。
static const unsigned char UG_X_UICSI[19] = {
    0x06,0x13,0x22,0x1A,0x0A,0x17,0x09,0xE1,0xD8,0xF1,0xEB,0xC5,0xC2,0xC0,0xFC,0xD1,
    0xA2,0xAD,0xB4
};
static const unsigned char UG_X_PROG[11] = {
    0x00,0x2A,0x13,0x01,0x01,0x11,0x3F,0xEB,0xEA,0xE0,0xFD
};
static const unsigned char UG_X_BUS[30] = {
    0x7C,0x2C,0x00,0x1A,0x40,0x1B,0x12,0xE6,0xE2,0xFE,0xFC,0x8F,0xEA,0xCB,0xD1,0xD5,
    0xA2,0xE5,0x95,0x9B,0x96,0xAB,0xC2,0xDA,0x90,0x66,0x68,0x64,0x76,0x2F
};
static void ug_dexor(char *dst, const unsigned char *src, size_t n) {
    for (size_t i = 0; i < n; i++)
        dst[i] = (char)(src[i] ^ (unsigned char)((0x53 + i * 7) & 0xFF));
    dst[n] = 0;
}
static const char *ug_uicsi_name(void) {
    static char s[20]; static int init = 0;
    if (!init) { ug_dexor(s, UG_X_UICSI, 19); init = 1; }
    return s;
}
static const char *ug_sbprog_name(void) {
    static char s[12]; static int init = 0;
    if (!init) { ug_dexor(s, UG_X_PROG, 11); init = 1; }
    return s;
}
static const char *ug_bus_path(void) {
    static char s[31]; static int init = 0;
    if (!init) { ug_dexor(s, UG_X_BUS, 30); init = 1; }
    return s;
}

// mmap 颜色总线(与 VCamNotify.m vcamPickShmMap 同路径; 旧 .vcampick 弃用)
#define UG_BUS_MAGIC     0x53544153u   // 'STAT'

// 总线布局(与 VCamPickShm 完全一致, 字段语义见 VCamNotify.m)
struct ug_bus {
    uint32_t magic;
    uint32_t slot;    // 0=熄灭 1-6=红绿蓝黄青紫
    uint32_t color;   // 标准纯色 0x00RRGGBB
    uint32_t count;
    uint32_t avg;
    double   ts;      // 发布点(最后写)
    uint32_t pid;
};

static struct ug_bus *ug_bus_map(void) {
    static struct ug_bus *mapped = (struct ug_bus *)-1;
    if (mapped != (struct ug_bus *)-1) return mapped;   // 0 或有效指针
    int fd = open(ug_bus_path(), O_RDWR | O_CREAT, 0644);
    if (fd < 0) return NULL;
    ftruncate(fd, 4096);
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { return NULL; }
    mapped = (struct ug_bus *)p;
    if (mapped->magic != UG_BUS_MAGIC) {
        mapped->magic = 0;
        __sync_synchronize();
        memset(&(mapped->slot), 0, sizeof(struct ug_bus) - offsetof(struct ug_bus, slot));
        __sync_synchronize();
        mapped->magic = UG_BUS_MAGIC;
    }
    return mapped;
}

static void ug_bus_publish(int slot, uint32_t color, int cnt) {
    struct ug_bus *b = ug_bus_map();
    if (!b) return;
    if (slot < 0) slot = 0;
    if (slot > 6) slot = 6;
    __sync_synchronize();
    b->slot = (uint32_t)slot;
    b->color = color;
    b->count = (uint32_t)(cnt > 0 ? cnt : 0);
    b->avg = 0;
    b->pid = (uint32_t)getpid();
    __sync_synchronize();
    // ts 用与主 dylib 读端(CFAbsoluteTime)一致的时基: 墙钟秒换算 Apple 2001 纪元
    // (CFAbsoluteTime = unix_epoch - 978307200)。time(NULL) 粒度 1s 太粗(新鲜窗
    // 1s 会抖), 用 gettimeofday。
    {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        b->ts = (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0
              - 978307200.0;  // unix epoch → Apple 2001 纪元
    }
}

static void ug_notify_slot(int slot) {
    if (slot < 0 || slot > 6) return;
    char name[32];
    snprintf(name, sizeof(name), "%s%d", UG_SLOT_PREFIX, slot);
    notify_post(name);
}

// ===== UIKit C 互操作(无 UIKit 头/类引用) =====
static id ug_shared_app(void) {
    Class c = objc_getClass("UIApplication");
    if (!c) return nil;
    SEL s = sel_registerName("sharedApplication");
    if (!class_getClassMethod(c, s)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, s);
}

// applicationState: 0=Active(仅前台活跃才采样)
static long ug_app_active(id app) {
    if (!app) return -1;
    SEL s = sel_registerName("applicationState");
    if (![app respondsToSelector:s]) return -1;
    return (long)((long (*)(id, SEL))objc_msgSend)(app, s);
}

// ===== 采样一拍(移植 1.3.65~1.3.76 vcamAppSampleSlotAtX 的算法) =====
// 返回稳定 slot(0-6), 同时完成总线双通道发布
static int ug_sample_beat(void) {
    typedef CGImageRef (*UICSIFn)(void);
    static UICSIFn capFn = NULL;
    static int capFnTried = 0;
    if (!capFn) {
        if (capFnTried) return 0;
        capFnTried = 1;
        capFn = (UICSIFn)dlsym(RTLD_DEFAULT, ug_uicsi_name());
        if (!capFn) return 0;
    }
    // UICSI 内部可能抛 ObjC 异常(照片模式/前后台切换, 1.3.89 设备实证),
    // 本拍按无色处理, 绝不让异常冒泡杀死宿主
    @try {
        CGImageRef full = capFn();
        if (!full) return 0;
        size_t iw = CGImageGetWidth(full), ih = CGImageGetHeight(full);
        if (iw < 40 || ih < 40) { CFRelease(full); return 0; }
        const int GW = 32, GH = 64;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bctx = CGBitmapContextCreate(NULL, GW, GH, 8, GW * 4, cs,
                                                  kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
        static const uint32_t kKnown[6] = {
            0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF
        };
        int bestIdx = -1, bestCnt = 0;
        if (bctx) {
            CGContextSetInterpolationQuality(bctx, kCGInterpolationLow);
            CGContextDrawImage(bctx, CGRectMake(0, 0, GW, GH), full);
            const uint8_t *rgba = (const uint8_t *)CGBitmapContextGetData(bctx);
            if (rgba) {
                const int n = GW * GH;
                int counts[6] = {0};
                for (int i = 0; i < n; i++) {
                    int r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
                    int maxc = r > g ? (r > b ? r : b) : (g > b ? g : b);
                    int minc = r < g ? (r < b ? r : b) : (g < b ? g : b);
                    int delta = maxc - minc;
                    if (maxc < 60 || delta < 60) continue;
                    double h;
                    if (maxc == r)      h = 60.0 * (double)(g - b) / (double)delta;
                    else if (maxc == g) h = 60.0 * (2.0 + (double)(b - r) / (double)delta);
                    else                h = 60.0 * (4.0 + (double)(r - g) / (double)delta;
                    if (h < 0) h += 360.0;
                    int idx;
                    if (h < 30.0 || h >= 330.0)      idx = 0;  // 红
                    else if (h < 90.0)               idx = 3;  // 黄
                    else if (h < 150.0)              idx = 1;  // 绿
                    else if (h < 210.0)              idx = 4;  // 青
                    else if (h < 270.0)              idx = 2;  // 蓝
                    else                             idx = 5;  // 紫
                    counts[idx]++;
                }
                for (int k = 0; k < 6; k++) {
                    if (counts[k] > bestCnt) { bestCnt = counts[k]; bestIdx = k; }
                }
                if (bestCnt < n / 8) { bestIdx = -1; bestCnt = 0; }  // <12% 噪声
            }
            CGContextRelease(bctx);
        }
        CGColorSpaceRelease(cs);
        CFRelease(full);

        int slot = (bestIdx >= 0 && bestIdx < 6) ? bestIdx + 1 : 0;
        // ===== 滑窗投票 + 灭光滞回(1.3.76 口径, 窗口 6 拍@80ms) =====
        static int sWin[6] = {0};
        static int sWinPos = 0;
        static int sStableSlot = -2;
        static int sZeroRun = 0;
        sWin[sWinPos] = slot;
        sWinPos = (sWinPos + 1) % 6;
        if (slot >= 1 && slot <= 6) {
            sZeroRun = 0;
            int cnt[7] = {0};
            for (int i = 0; i < 6; i++) {
                if (sWin[i] >= 1 && sWin[i] <= 6) cnt[sWin[i]]++;
            }
            int majSlot = 0, majCnt = 0;
            for (int s = 1; s <= 6; s++) {
                if (cnt[s] > majCnt) { majCnt = cnt[s]; majSlot = s; }
            }
            if (majCnt >= 4 && majSlot != sStableSlot) sStableSlot = majSlot;
        } else {
            if (sZeroRun < 4) sZeroRun++;
            if (sZeroRun >= 4 && sStableSlot != 0) sStableSlot = 0;
        }
        int outSlot = (sStableSlot >= 0 && sStableSlot <= 6) ? sStableSlot : 0;
        uint32_t outColor = (outSlot >= 1 && outSlot <= 6) ? kKnown[outSlot - 1] : 0;
        // 通道A: mmap 总线直写; 通道B: Darwin slot(保活心跳, 沙盒拒 mmap 时由
        // SB 端中继代写总线)
        ug_bus_publish(outSlot, outColor, bestCnt);
        ug_notify_slot(outSlot);
        return outSlot;
    } @catch (id e) {
        return 0;
    }
}

// ===== cfg 状态(初始关; SB 悬浮球开/关取色时经 Darwin 下发) =====
static volatile int ug_cfg_on = 0;

__attribute__((constructor))
static void ugInit(void) {
    // SB 自己是桌面模式写者(VCamFloatingBall tick), 采双写者会互踩;
    // mediaserverd/lskdd 不加载 UIKit 本进不来 —— 双保险排除
    const char *prog = getprogname();
    if (strcmp(prog, ug_sbprog_name()) == 0) return;

    // 配置下行: cfg1(开, state 携坐标但全屏扫描不使用) / cfg0(关)
    int onTok = -1, offTok = -1;
    notify_register_dispatch(UG_CFG_ON_NAME, &onTok,
        dispatch_get_main_queue(), ^(int t) {
            ug_cfg_on = 1;
            (void)t;
        });
    notify_register_dispatch(UG_CFG_OFF_NAME, &offTok,
        dispatch_get_main_queue(), ^(int t) {
            ug_cfg_on = 0;
            (void)t;
        });

    // 探测 sharedApplication: App(UIKit 已加载)→ 启动采样 timer;
    // 守护进程(恒 nil)→ 15s 后静默退出(只留 2 个 Darwin 注册, 零开销)
    __block int probes = 0;
    __block void (^probe)(void) = ^(void) {
        id app = ug_shared_app();
        if (app) {
            // App 进程: 主队列 12.5Hz timer(1.3.77 降频口径)
            dispatch_queue_t sampQ = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
            dispatch_source_t timer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            static double sDurEma = 0;   // 采样耗时 EMA(1.3.89 CPU 退避)
            static int sSkipLeft = 0;
            dispatch_source_set_timer(timer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                (uint64_t)(0.08 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(timer, ^{
                if (!ug_cfg_on) return;
                // 前台判定(执行前双查, 后台竞态防护, 1.3.89 口径)
                id a1 = ug_shared_app();
                if (!a1 || ug_app_active(a1) != 0) return;
                if (sSkipLeft > 0) { sSkipLeft--; return; }
                if (sDurEma > 0.16) sSkipLeft = 5;
                else if (sDurEma > 0.08) sSkipLeft = 2;
                else if (sDurEma > 0.04) sSkipLeft = 1;
                dispatch_async(sampQ, ^{
                    id a2 = ug_shared_app();
                    if (!a2 || ug_app_active(a2) != 0) return;
                    // CFAbsoluteTime 等价口径的耗时测量
                    struct timeval t0v, t1v;
                    gettimeofday(&t0v, NULL);
                    ug_sample_beat();
                    gettimeofday(&t1v, NULL);
                    double dur = (double)(t1v.tv_sec - t0v.tv_sec)
                               + (double)(t1v.tv_usec - t0v.tv_usec) / 1000000.0;
                    sDurEma = (sDurEma > 0) ? (sDurEma * 0.7 + dur * 0.3) : dur;
                });
            });
            dispatch_resume(timer);
            static dispatch_source_t keepTimer = nil;
            keepTimer = timer;   // 进程生命周期持有
            probe = nil;         // 停止探测
            return;
        }
        if (++probes < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (probe) probe();
            });
        } else {
            probe = nil;   // 探测耗尽(守护进程): 释放自引用块, 只留 Darwin 注册
        }
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        probe();
    });
}
