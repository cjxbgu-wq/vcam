//
//  Tweak.m
//  VCamPlus
//
//  Hook 入口（对标 vcameracrack.dylib 的 hook 安装逻辑）
//
//  逆向特征（3 个 hook，不是 4 个）：
//    1. BWNodeOutput emitSampleBuffer:        —— 主预览流（所有 app 的相机预览）
//    2. BWStillImageScalerNode renderSampleBuffer:forInput: —— 照片缩放（拍照）
//    3. BWPhotoEncoderNode renderSampleBuffer:forInput:      —— 照片编码（保存的照片）
//
//  注意：
//    - 不 hook BWVideoCompressorNode（原版没有，更简单更稳定）
//    - MSHookMessageEx 自包含实现（method_setImplementation，不依赖 Substrate/ElleKit）
//    - mediaserverd 中初始化 VCamCore + 安装 hook
//    - SpringBoard 中初始化 VCamFloatingBall
//
//  关键约束（记忆）：
//    - mediaserverd 中 NSLog 不可见，用文件日志
//    - mediaserverd 中不能重启，避免重复 stopDecoding+cleanup+reload
//    - Darwin 通知在 mediaserverd 中不安全，用 plist 轮询
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "VCamCore.h"
#import "VCamFloatingBall.h"
#import "VCamNotify.h"

// MSHookMessageEx 自包含实现（不依赖 CydiaSubstrate/ElleKit）
// 原因：Dopamine 无 ElleKit/Substrate/libinjector，systemhook 未注入 mediaserverd
// (proxy 跳过)，opainject 单独注入 VCamPlus 时 _MSHookMessageEx 符号缺失导致
// dlopen 失败。MSHookMessageEx 本质是 method_setImplementation 的封装。
static void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        if (origPtr) *origPtr = NULL;
        return;
    }
    if (origPtr) *origPtr = method_getImplementation(method);
    method_setImplementation(method, newImp);
}

// 文件日志（mediaserverd 中 NSLog 不可见）
static volatile int32_t vcamTweakLogCount = 0;
static void vcam_tweak_log(NSString *msg) {
    int32_t n = __sync_add_and_fetch(&vcamTweakLogCount, 1);
    if (n > 500) return;  // 限制日志量
    @try {
        NSString *logPath = @"/tmp/vcam_tweak_log.txt";
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

#pragma mark - Hook 函数原始指针

// BWNodeOutput emitSampleBuffer: 的原始实现
static void (*orig_BWNodeOutput_emitSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer);

// BWStillImageScalerNode renderSampleBuffer:forInput: 的原始实现
static void (*orig_BWStillImageScalerNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);

// BWPhotoEncoderNode renderSampleBuffer:forInput: 的原始实现
static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input);

#pragma mark - Hook 函数实现

// Hook 1: BWNodeOutput emitSampleBuffer:
// 主预览流 —— 所有 app 的相机预览/录像都经过这里(逆向: 就地改写原 buffer 后调原 IMP,
// 假帧顺原生管线流向所有下游消费者: 预览/录像编码器/拍照编码器)
static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    // 诊断: 记录预览流触发 + 格式(每 60 帧一次)
    static int vcamEmitCount = 0;
    vcamEmitCount++;
    if (vcamEmitCount % 60 == 1) {
        CVPixelBufferRef pb = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
        OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
        vcam_tweak_log([NSString stringWithFormat:@"[vcam] emit#%d fmt=0x%x cls=%@", vcamEmitCount, (unsigned)fmt, NSStringFromClass([self class])]);
    }
    // 逆向逻辑: 只替换 mediaType=='vide' 的帧, 过滤音频/元数据(避免无效处理 + 录像流被漏掉)
    if (sampleBuffer) {
        // CMSampleBuffer 本身无 mediaType, 但 [self mediaType] 在 BWNodeOutput 上返回当前流类型
        // 用 CFString 'vide' (kCMMediaType_Video = 'vide') 比较未导出符号, 用 FourCC 直接比较
        // 逆向: w8 = 0x76696465 = 'vide'; 若 [self mediaType] != 'vide' 直通原 IMP
        @try {
            // [self mediaType] 返回 CMMediaType (FourCC uint32)
            // 用 objc_msgSend 调用避免 Theos SDK 声明问题
            SEL mediaTypeSel = sel_registerName("mediaType");
            if ([self respondsToSelector:mediaTypeSel]) {
                uint32_t mt = ((uint32_t(*)(id, SEL))objc_msgSend)(self, mediaTypeSel);
                if (mt != 'vide') {
                    // 非视频帧(音频/元数据), 直通原 IMP
                    if (orig_BWNodeOutput_emitSampleBuffer) {
                        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
                    }
                    return;
                }
            }
        } @catch (NSException *e) {}
        // 就地改写原 sample buffer 的 CVPixelBuffer, 然后调原 IMP 发射(假帧流向所有下游)
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            @try {
                [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer];
            } @catch (NSException *e) {
                vcam_tweak_log([NSString stringWithFormat:@"[vcam] emitSampleBuffer hook exception: %@", e]);
            }
        }
    }
    // 调用原始方法(发射已掉包的 sample buffer)
    if (orig_BWNodeOutput_emitSampleBuffer) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
    }
}

// Hook 2: BWStillImageScalerNode renderSampleBuffer:forInput:
// 照片缩放 —— 拍照时的照片缩放处理
static void hook_BWStillImageScalerNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            @try {
                [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer];
            } @catch (NSException *e) {
                vcam_tweak_log([NSString stringWithFormat:@"[vcam] ScalerNode hook exception: %@", e]);
            }
        }
    }
    if (orig_BWStillImageScalerNode_renderSampleBuffer) {
        orig_BWStillImageScalerNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
    }
}

// Hook 3: BWPhotoEncoderNode renderSampleBuffer:forInput:
// 照片编码 —— 保存的照片经过这里
static void hook_BWPhotoEncoderNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            @try {
                [[VCamCore sharedInstance] renderReplacementToPixelBuffer:pixelBuffer];
            } @catch (NSException *e) {
                vcam_tweak_log([NSString stringWithFormat:@"[vcam] PhotoEncoder hook exception: %@", e]);
            }
        }
    }
    if (orig_BWPhotoEncoderNode_renderSampleBuffer) {
        orig_BWPhotoEncoderNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
    }
}

#pragma mark - Hook 安装

static void installMediaserverdHooks(void) {
    // Hook 1: BWNodeOutput emitSampleBuffer:
    Class bwNodeOutput = objc_getClass("BWNodeOutput");
    if (bwNodeOutput) {
        MSHookMessageEx(bwNodeOutput,
                        @selector(emitSampleBuffer:),
                        (IMP)hook_BWNodeOutput_emitSampleBuffer,
                        (IMP *)&orig_BWNodeOutput_emitSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWNodeOutput emitSampleBuffer:");
    } else {
        vcam_tweak_log(@"[vcam] BWNodeOutput class not found");
    }

    // Hook 2: BWStillImageScalerNode renderSampleBuffer:forInput:
    Class bwStillImageScaler = objc_getClass("BWStillImageScalerNode");
    if (bwStillImageScaler) {
        MSHookMessageEx(bwStillImageScaler,
                        @selector(renderSampleBuffer:forInput:),
                        (IMP)hook_BWStillImageScalerNode_renderSampleBuffer,
                        (IMP *)&orig_BWStillImageScalerNode_renderSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWStillImageScalerNode renderSampleBuffer:forInput:");
    } else {
        vcam_tweak_log(@"[vcam] BWStillImageScalerNode class not found");
    }

    // Hook 3: BWPhotoEncoderNode renderSampleBuffer:forInput:
    Class bwPhotoEncoder = objc_getClass("BWPhotoEncoderNode");
    if (bwPhotoEncoder) {
        MSHookMessageEx(bwPhotoEncoder,
                        @selector(renderSampleBuffer:forInput:),
                        (IMP)hook_BWPhotoEncoderNode_renderSampleBuffer,
                        (IMP *)&orig_BWPhotoEncoderNode_renderSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWPhotoEncoderNode renderSampleBuffer:forInput:");
    } else {
        vcam_tweak_log(@"[vcam] BWPhotoEncoderNode class not found");
    }
}

#pragma mark - 进程初始化

static void initializeInMediaserverd(void) {
    vcam_tweak_log(@"[vcam] Initializing in mediaserverd...");

    // 初始化 VCamCore（会启动 plist 轮询）
    [[VCamCore sharedInstance] initializeInMediaserverd];

    // 安装 3 个 hook
    installMediaserverdHooks();

    vcam_tweak_log(@"[vcam] MediaServerd hooks initialized");
}

static void initializeInSpringBoard(void) {
    vcam_tweak_log(@"[vcam] SpringBoard hooks initialized");

    // 初始化 VCamCore（状态轮询）
    [[VCamCore sharedInstance] initializeInSpringBoard];

    // 显示悬浮球
    [[VCamFloatingBall sharedInstance] showFloatingBall];
}

#pragma mark - 入口

__attribute__((constructor))
static void vcamInit(void) {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        vcam_tweak_log([NSString stringWithFormat:@"[vcam] Loading in process: %@", processName]);

        if ([processName isEqualToString:@"mediaserverd"]) {
            initializeInMediaserverd();
        } else if ([processName isEqualToString:@"SpringBoard"]) {
            initializeInSpringBoard();
        } else {
            // lskdd 等其他进程也加载（plist 中配置了）
            vcam_tweak_log([NSString stringWithFormat:@"[vcam] Loaded in other process: %@", processName]);
            [[VCamCore sharedInstance] initializeInMediaserverd];
        }
    }
}

// destructor（卸载时清理）
__attribute__((destructor))
static void vcamDeinit(void) {
    vcam_tweak_log(@"[vcam] Unloading...");
    [[VCamCore sharedInstance] stopStatePolling];
}
