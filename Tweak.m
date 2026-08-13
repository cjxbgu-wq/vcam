#import "VCamCore.h"
#import "VCamFloatingBall.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>

// ============================================================================
// 对标 vcameracrack 的 Tweak.m
// 只 hook 3 个相机节点（不 hook 视频编码器，更稳定）
// ============================================================================

// MSHookMessageEx 动态查找（RootHide/ElleKit 可能不提供 CydiaSubstrate）
typedef void (*MSHookMessageEx_t)(Class cls, SEL sel, IMP newImp, IMP *origPtr);
static MSHookMessageEx_t _MSHookMessageEx = NULL;

static BOOL installHook(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    if (!cls) return NO;
    if (_MSHookMessageEx) {
        _MSHookMessageEx(cls, sel, newImp, origPtr);
        return YES;
    }
    // 降级：ObjC runtime
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (origPtr) *origPtr = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

// 原 IMP 指针
static IMP orig_BWNodeOutput_emitSampleBuffer = NULL;
static IMP orig_BWStillImageScaler_renderSampleBuffer = NULL;
static IMP orig_BWPhotoEncoder_renderSampleBuffer = NULL;

// IMP 调用宏
#define CALL_IMP_3(imp, self, _cmd, arg) \
    ((void(*)(id, SEL, CMSampleBufferRef))(imp))((self), (_cmd), (arg))
#define CALL_IMP_4(imp, self, _cmd, arg1, arg2) \
    ((void(*)(id, SEL, CMSampleBufferRef, id))(imp))((self), (_cmd), (arg1), (arg2))

// VCamCore 就绪标志
static volatile BOOL vcamReady = NO;
static volatile BOOL vcamInitStarted = NO;

// 全局悬浮球
static VCamFloatingBall *sFloatingBall = nil;

// 诊断日志
__attribute__((visibility("default"))) void vcam_diag_log(NSString *msg) {
    static volatile int32_t diagLogCount = 0;
    int32_t n = __sync_add_and_fetch(&diagLogCount, 1);
    if (n > 200) return;
    @try {
        NSString *logPath = @"/tmp/vcam_diag.txt";
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

// ============================================================================
// Hook 1: BWNodeOutput emitSampleBuffer: — 主预览流
// ============================================================================

static void vcam_BWNodeOutput_emitSampleBuffer_Hook(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    if (!vcamReady) {
        if (orig_BWNodeOutput_emitSampleBuffer) {
            CALL_IMP_3(orig_BWNodeOutput_emitSampleBuffer, self, _cmd, sampleBuffer);
        }
        return;
    }

    VCamCore *core = [VCamCore sharedInstance];
    if (core.enabled && core.isPixelBufferMode) {
        CVPixelBufferRef origPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (origPixelBuffer) {
            @try {
                [core renderReplacementToPixelBuffer:origPixelBuffer];
            } @catch (NSException *e) {}
        }
    }

    if (orig_BWNodeOutput_emitSampleBuffer) {
        CALL_IMP_3(orig_BWNodeOutput_emitSampleBuffer, self, _cmd, sampleBuffer);
    }
}

// ============================================================================
// Hook 2: BWStillImageScalerNode renderSampleBuffer:forInput: — 静态图片缩放
// ============================================================================

static void vcam_BWStillImageScaler_renderSampleBuffer_Hook(id self, SEL _cmd,
                                                               CMSampleBufferRef sampleBuffer,
                                                               id input) {
    if (!vcamReady) {
        if (orig_BWStillImageScaler_renderSampleBuffer) {
            CALL_IMP_4(orig_BWStillImageScaler_renderSampleBuffer, self, _cmd, sampleBuffer, input);
        }
        return;
    }
    VCamCore *core = [VCamCore sharedInstance];
    if (core.enabled && core.isPixelBufferMode) {
        CVPixelBufferRef origPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (origPixelBuffer) {
            @try {
                [core renderReplacementToPixelBuffer:origPixelBuffer];
            } @catch (NSException *e) {}
        }
    }
    if (orig_BWStillImageScaler_renderSampleBuffer) {
        CALL_IMP_4(orig_BWStillImageScaler_renderSampleBuffer, self, _cmd, sampleBuffer, input);
    }
}

// ============================================================================
// Hook 3: BWPhotoEncoderNode renderSampleBuffer:forInput: — 照片编码
// ============================================================================

static void vcam_BWPhotoEncoder_renderSampleBuffer_Hook(id self, SEL _cmd,
                                                          CMSampleBufferRef sampleBuffer,
                                                          id input) {
    if (!vcamReady) {
        if (orig_BWPhotoEncoder_renderSampleBuffer) {
            CALL_IMP_4(orig_BWPhotoEncoder_renderSampleBuffer, self, _cmd, sampleBuffer, input);
        }
        return;
    }
    VCamCore *core = [VCamCore sharedInstance];
    if (core.enabled && core.isPixelBufferMode) {
        CVPixelBufferRef origPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (origPixelBuffer) {
            @try {
                [core renderReplacementToPixelBuffer:origPixelBuffer];
            } @catch (NSException *e) {}
        }
    }
    if (orig_BWPhotoEncoder_renderSampleBuffer) {
        CALL_IMP_4(orig_BWPhotoEncoder_renderSampleBuffer, self, _cmd, sampleBuffer, input);
    }
}

// ============================================================================
// 悬浮球显示
// ============================================================================

static void vcam_showFloatingBall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            sFloatingBall = [VCamFloatingBall sharedInstance];
            [sFloatingBall showAsOverlay];
            NSLog(@"[vcam] Floating ball shown as overlay");
        } @catch (NSException *e) {
            NSLog(@"[vcam] Failed to show floating ball: %@", e);
        }
    });
}

// ============================================================================
// Tweak 入口（constructor）
// ============================================================================

__attribute__((constructor))
static void vcam_initializer(void) {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        NSLog(@"[vcam] Loading in process: %@", processName);

        // 创建标记文件
        NSString *markerPath = [NSString stringWithFormat:@"/tmp/vcam_loaded_%@.txt", processName];
        [@("loaded") writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        vcam_diag_log([NSString stringWithFormat:@"[%@] constructor started", processName]);

        // 动态查找 MSHookMessageEx
        _MSHookMessageEx = (MSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");

        BOOL isMediaserverd = [processName isEqualToString:@"mediaserverd"];
        BOOL isSpringBoard  = [processName isEqualToString:@"SpringBoard"];

        if (isMediaserverd) {
            // === mediaserverd: 安装 3 个相机节点 hook ===
            vcam_diag_log(@"[mediaserverd] Initializing in mediaserverd...");

            // Hook 1: BWNodeOutput - 主预览流
            Class bwNodeOutputClass = objc_getClass("BWNodeOutput");
            if (bwNodeOutputClass) {
                SEL sel1 = NSSelectorFromString(@"emitSampleBuffer:");
                if ([bwNodeOutputClass instancesRespondToSelector:sel1]) {
                    if (installHook(bwNodeOutputClass, sel1,
                                    (IMP)vcam_BWNodeOutput_emitSampleBuffer_Hook,
                                    &orig_BWNodeOutput_emitSampleBuffer)) {
                        vcam_diag_log(@"[mediaserverd] HOOKED BWNodeOutput emitSampleBuffer: SUCCESS");
                    }
                }
            }

            // Hook 2: BWStillImageScalerNode - 静态图片缩放
            Class bwScalerClass = objc_getClass("BWStillImageScalerNode");
            if (bwScalerClass) {
                SEL sel2 = NSSelectorFromString(@"renderSampleBuffer:forInput:");
                if ([bwScalerClass instancesRespondToSelector:sel2]) {
                    if (installHook(bwScalerClass, sel2,
                                    (IMP)vcam_BWStillImageScaler_renderSampleBuffer_Hook,
                                    &orig_BWStillImageScaler_renderSampleBuffer)) {
                        vcam_diag_log(@"[mediaserverd] HOOKED BWStillImageScalerNode SUCCESS");
                    }
                }
            }

            // Hook 3: BWPhotoEncoderNode - 照片编码
            Class bwPhotoEncoderClass = objc_getClass("BWPhotoEncoderNode");
            if (bwPhotoEncoderClass) {
                SEL sel3 = NSSelectorFromString(@"renderSampleBuffer:forInput:");
                if ([bwPhotoEncoderClass instancesRespondToSelector:sel3]) {
                    if (installHook(bwPhotoEncoderClass, sel3,
                                    (IMP)vcam_BWPhotoEncoder_renderSampleBuffer_Hook,
                                    &orig_BWPhotoEncoder_renderSampleBuffer)) {
                        vcam_diag_log(@"[mediaserverd] HOOKED BWPhotoEncoderNode SUCCESS");
                    }
                }
            }

            vcam_diag_log(@"[mediaserverd] MediaServerd hooks initialized");

            // VCamCore 延迟初始化到后台队列（避免阻塞 constructor 导致 watchdog）
            if (!vcamInitStarted) {
                vcamInitStarted = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                    @try {
                        vcam_diag_log(@"[mediaserverd] VCamCore init starting");
                        [VCamCore sharedInstance];
                        vcamReady = YES;
                        vcam_diag_log(@"[mediaserverd] VCamCore READY (vcamReady=YES)");
                    } @catch (NSException *e) {
                        vcam_diag_log([NSString stringWithFormat:@"[mediaserverd] VCamCore init FAILED: %@", e]);
                    }
                });
            }
        }

        // === 悬浮球：SpringBoard 和所有 UIKit 进程都显示 ===
        if (isSpringBoard) {
            vcam_diag_log(@"[SpringBoard] SpringBoard hooks initialized");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                vcam_showFloatingBall();
            });
        } else if (!isMediaserverd) {
            // 其他 UIKit 进程：监听 UIApplication 就绪后显示
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                  object:nil
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(NSNotification * _Nonnull n) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        vcam_showFloatingBall();
                    });
                }];
                if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        vcam_showFloatingBall();
                    });
                }
            });
        }

        vcam_diag_log([NSString stringWithFormat:@"[%@] constructor returned", processName]);
    }
}
