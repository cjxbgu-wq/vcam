//
//  VCamNotify.h
//  VCamPlus
//
//  通知管理（对标 vcameracrack.dylib 的 VCamNotify 类）
//
//  逆向特征：
//    - dispatch_queue: com.vcam.notify
//    - Darwin 通知名: com.vcam.ios.media.reload / com.vcam.ios.live.changed
//    - "Registered VCamNotify listener for reload-media"
//    - "State polling timer started" —— plist 轮询
//    - 状态备份路径: /var/mobile/vc.plist
//
//  注意（记忆约束）：
//    - mediaserverd 中 Darwin 通知可能触发崩溃，所以 mediaserverd 主要用 plist 轮询
//    - SpringBoard 中可以用 Darwin 通知
//

#import <Foundation/Foundation.h>

// Darwin 通知名（与原版保持一致）
extern NSString *const VCamNotifyReloadMedia;   // com.vcam.ios.media.reload
extern NSString *const VCamNotifyLiveChanged;   // com.vcam.ios.live.changed

// plist 路径（逆向确认）
extern NSString *const VCamPlistPath;            // /var/mobile/Media/DCIM/vc.plist
extern NSString *const VCamStateBackupPath;      // /var/mobile/vc.plist

typedef void(^VCamNotifyCallback)(NSString *name);

@interface VCamNotify : NSObject

+ (instancetype)sharedInstance;

#pragma mark - Darwin 通知
- (void)postNotification:(NSString *)name;
- (NSInteger)registerForNotification:(NSString *)name callback:(VCamNotifyCallback)callback;
- (void)unregisterNotification:(NSString *)name token:(NSInteger)token;

#pragma mark - plist 轮询（mediaserverd 安全通道）
// 逆向特征: "State polling timer started" —— 每秒检查 vc.plist 的 enabled 字段
- (void)startPollingWithInterval:(NSTimeInterval)interval
                        callback:(void(^)(BOOL enabled))callback;
- (void)stopPolling;

#pragma mark - plist 读写
+ (BOOL)isPlistEnabled;
+ (void)setPlistEnabled:(BOOL)enabled;
+ (NSString *)activePlaybackPath;
+ (void)setActivePlaybackPath:(NSString *)path;
// 旋转/镜像状态（跨进程同步: 悬浮球在 SpringBoard 写, mediaserverd 轮询读;
// 字段名对齐千面逆向 vc.plist 的 manualRotation）
+ (NSInteger)plistRotation;
+ (void)setPlistRotation:(NSInteger)degrees;
+ (BOOL)plistMirrored;
+ (void)setPlistMirrored:(BOOL)mirrored;

// 用户画面变换(悬浮球 箭头/＋/−/复): pan 归一化 -1..1(自由平移),
// zoom 0.5..4.0(1=原始); mediaserverd 轮询读 → 黑底画布合成
+ (double)plistPanX;
+ (void)setPlistPanX:(double)panX;
+ (double)plistPanY;
+ (void)setPlistPanY:(double)panY;
+ (double)plistZoom;
+ (void)setPlistZoom:(double)zoom;
+ (void)resetPlistTransform;
// 前置方向修正(2026-08-23): 前置摄像头流的显示旋转与后置差 180°(实测 pan 双反),
// mediaserverd 无法自动判别前后置 —— 设置页手动开关, 开启时 pan 应用时 X/Y 同时取反
+ (BOOL)plistFrontPanFix;
+ (void)setPlistFrontPanFix:(BOOL)fix;

// 播放控制（跨进程: 悬浮球写, mediaserverd 轮询应用）
// paused: 暂停/继续视频解码(暂停时预渲染冻结在最后一帧)
+ (BOOL)plistPaused;
+ (void)setPlistPaused:(BOOL)paused;
// restartToken: 自增令牌, mediaserverd 检测到变化后从头重播当前视频
+ (NSInteger)plistRestartToken;
+ (void)bumpRestartToken;

// 三色打光(1.3.37, 跨进程: 悬浮球屏幕取色检测写, mediaserverd 轮询应用):
// lightEnabled=取色总开关; lightColor=0x00RRGGBB(0=熄灭, 颜色跟随屏幕闪烁);
// lightX/lightY=光斑中心 %(默认 50/50); lightIntensity 强度%(默认 30);
// lightDiameter 直径%(默认 48); lightFeather 羽化%(默认 100)
+ (BOOL)plistLightEnabled;
+ (void)setPlistLightEnabled:(BOOL)enabled;
+ (uint32_t)plistLightColor;
+ (void)setPlistLightColor:(uint32_t)color;
+ (int)plistLightX;
+ (void)setPlistLightX:(int)x;
+ (int)plistLightY;
+ (void)setPlistLightY:(int)y;
+ (int)plistLightIntensity;
+ (void)setPlistLightIntensity:(int)v;
+ (int)plistLightDiameter;
+ (void)setPlistLightDiameter:(int)v;
+ (int)plistLightFeather;
+ (void)setPlistLightFeather:(int)v;

@end
