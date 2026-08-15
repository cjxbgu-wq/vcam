//
//  VCamFloatingBall.h
//  VCamPlus
//
//  悬浮球 UI（双页签面板: 控制/设置, 灰色主题）
//
//  控制页: 选择视频 | 3x3 宫格(播 替/原 1 / ▶ 关 2 / 转 镜 3)
//  设置页: 预设视频2 / 预设视频3 / 岐盛相机(频道链接) / @QuGenttx 水印
//
//  跨进程控制: 全部经 vc.plist, mediaserverd 每秒轮询应用
//

#import <Foundation/Foundation.h>

@interface VCamFloatingBall : NSObject

+ (instancetype)sharedInstance;

- (void)showFloatingBall;
- (void)hideFloatingBall;

@end
