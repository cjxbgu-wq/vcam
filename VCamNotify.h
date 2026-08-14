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

@end
