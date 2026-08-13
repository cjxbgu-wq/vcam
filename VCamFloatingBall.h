#import <UIKit/UIKit.h>

// 悬浮球 UI
// 对标 vcameracrack 的 VCamFloatingBall
// 桌面(SpringBoard)和 app 内都显示，每个进程位置独立
@interface VCamFloatingBall : UIView

+ (instancetype)sharedInstance;

// 显示悬浮球（覆盖在所有 app 上层）
- (void)showAsOverlay;

// 隐藏悬浮球
- (void)hideFloatingBall;

@end
