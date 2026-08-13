//
//  VCamFloatingBall.h
//  VCamPlus
//
//  悬浮球 UI（对标 vcameracrack.dylib 的 VCamFloatingBall 类）
//
//  逆向特征：
//    - "[vcam] Floating window created" / "[vcam] Floating ball created"
//    - "[vcam][btn] switchVideoTapped, BGIntegrityOK=%d (diagnostic bypass)"
//    - "[vcam][btn] rotateLeftTapped fired" / "[vcam][btn] rotateRightTapped fired"
//    - "[vcam][btn] rotation: %d -> %d (deg=%d)"
//    - "[vcam][btn] toggleReplacementTapped, BGIntegrityOK=%d (diagnostic bypass)"
//    - "[vcam][btn] multiPickerTapped, BGIntegrityOK=%d (diagnostic bypass)"
//    - "[vcam][panel] showSettingsPanel triggered, BGIntegrityOK=%d (diagnostic bypass active)"
//    - "[vcam][ball] tap received, BGIntegrityOK=%d (diagnostic bypass active)"
//    - "[vcam] Double click volume UP detected!"
//    - "floatingBallEnabled"
//
//  用户需求：
//    - 6 键设计：播/循/转/翻/替/换
//    - 悬浮球始终可见，面板显示在右侧
//    - 桌面和 app 内都有悬浮窗，前后台切换显示
//

#import <Foundation/Foundation.h>

@interface VCamFloatingBall : NSObject

+ (instancetype)sharedInstance;

- (void)showFloatingBall;
- (void)hideFloatingBall;

// 6 键回调
- (void)restartVideoTapped;       // 播 - 重新播放
- (void)toggleLoopTapped;         // 循 - 循环播放
- (void)rotateRightTapped;        // 转 - 顺时针旋转 90°
- (void)toggleMirrorTapped;       // 翻 - 左右镜像
- (void)toggleReplacementTapped;  // 替 - 替换/恢复
- (void)switchVideoTapped;        // 换 - 切换视频槽位

@end
