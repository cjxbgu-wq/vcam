//
//  VCamFloatingBall.m
//  VCamPlus
//
//  悬浮球 + 三页签面板(控制/打光/设置), 灰色主题
//  只在 SpringBoard 中使用（需要 UIKit）
//
//  控制页 4x4 宫格:
//   播(图标)  ↑(占位)  复(图标)  1(占位)
//   ←(占位)   ↓(占位)  →(占位)   2(占位)
//   −(占位)   ▶        ＋(占位)  3(占位)
//   ↷(旋转)   镜(图标)  替(图标)  4(占位)
//  打光页: 占位(功能后续版本接入)
//  设置页: 选择视频 / 预设视频2 / 预设视频3 / 岐盛相机(频道链接) / @QuGenttx 水印
//
//  跨进程控制(球在 SpringBoard, 播放器在 mediaserverd): 全部经 vc.plist
//    enabled(替/原) / activePlaybackPath(1/2/3) / paused(▶) /
//    restartToken(播) / manualRotation(↷) / mirrored(镜)
//  mediaserverd 每秒轮询应用(VCamCore startStatePolling)
//

#import "VCamFloatingBall.h"
#import "VCamCore.h"
#import "VCamNotify.h"
#import "ball_icon.h"
#import "btn_icons.h"
#import "VCamStr.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

// 按钮图标解码(与悬浮球品牌图标同机制): btn_icons.h 内 XOR 8字节 rolling key
// 加密 PNG 字节, 此处运行时解密后 imageWithData —— 二进制内无 PNG 魔数, 防提取
static UIImage *vcamDecodeBtnIcon(const unsigned char *enc, NSUInteger len,
                                  const unsigned char key[8]) {
    NSMutableData *d = [NSMutableData dataWithLength:len];
    unsigned char *dst = (unsigned char *)d.mutableBytes;
    for (NSUInteger i = 0; i < len; i++) dst[i] = enc[i] ^ key[i & 7];
    return [UIImage imageWithData:d];
}

static void vcam_ball_log(NSString *msg) {
    @try {
        NSString *logPath = @"/tmp/vcam_ball_log.txt";
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

#pragma mark - 触摸穿透 window
// 全屏 UIWindow 会拦截所有触摸导致桌面无法滑动(App 图标拖不动)。
// 覆写 hitTest: 只有悬浮球/面板区域接收触摸, 空白区域返回 nil 穿透到下层 window。
@interface VCamOverlayWindow : UIWindow
@end

@implementation VCamOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中 window 自身或 rootViewController.view(全屏空白容器) = 空白区域 → 穿透
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}

@end

#pragma mark - 屏幕取色点视图(1.3.37, 空心准星)
// 中心完全透明(直径 ~28pt 区域): 检测采样取截屏中心 21px(~7pt), 准星本体
// 绝不落入采样区 —— 截屏(CGWindowListCreateImage OnScreenOnly 含本窗口)
// 不会把准星自己画进采样导致自污染。四条外刻度线 + 外圆环标记位置。
@interface VCamPickDotView : UIView
@end

@implementation VCamPickDotView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGPoint c = CGPointMake(rect.size.width / 2, rect.size.height / 2);
    CGFloat r = 14;  // 外圆环半径(内缘 12.75, 中心 ~25pt 直径全透明)

    // 双色描边圆环: 白环 + 黑外描, 任何背景(亮/暗)都清晰可见
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.85].CGColor);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r + 0.5, c.y - r + 0.5, r * 2 - 1, r * 2 - 1));

    // 四条外刻度线(上/右/下/左, 从半径 17 到 21): 标记圆心方位, 不进中心
    CGContextSetLineWidth(ctx, 2);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.85].CGColor);
    for (int i = 0; i < 4; i++) {
        double ang = i * M_PI / 2;
        CGPoint p1 = CGPointMake(c.x + (CGFloat)cos(ang) * 17, c.y + (CGFloat)sin(ang) * 17);
        CGPoint p2 = CGPointMake(c.x + (CGFloat)cos(ang) * 21, c.y + (CGFloat)sin(ang) * 21);
        CGContextMoveToPoint(ctx, p1.x, p1.y);
        CGContextAddLineToPoint(ctx, p2.x, p2.y);
    }
    CGContextStrokePath(ctx);
}

@end

#pragma mark - 悬浮球视图(岐盛相机图标)

@interface VCamBallView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@end

@implementation VCamBallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 图标球(2026-08-17): 岐盛相机品牌图标替代灰底"VC"文字。
        // 图标 PNG 以 C 数组嵌入 dylib(ball_icon.h), 无需 deb 布局资源文件,
        // 运行时 UIImage imageWithData 解码。
        // 2026-08-18 加密: PNG 字节 XOR 8字节 rolling key 存储, 二进制内无
        // PNG 魔数/binwalk 特征, 防提取替换品牌图标; 此处运行时解码
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithRed:0.75 green:0.76 blue:0.78 alpha:1.0].CGColor;

        static const unsigned char vcsIconKey[8] = {
            VCS_ICON_KEY0, VCS_ICON_KEY1, VCS_ICON_KEY2, VCS_ICON_KEY3,
            VCS_ICON_KEY4, VCS_ICON_KEY5, VCS_ICON_KEY6, VCS_ICON_KEY7,
        };
        NSMutableData *imgData = [NSMutableData dataWithLength:vcam_ball_icon_png_len];
        const unsigned char *src = vcam_ball_icon_enc;
        unsigned char *dst = (unsigned char *)imgData.mutableBytes;
        for (NSUInteger i = 0; i < vcam_ball_icon_png_len; i++) {
            dst[i] = src[i] ^ vcsIconKey[i & 7];
        }
        UIImage *icon = [UIImage imageWithData:imgData];
        _iconView = [[UIImageView alloc] initWithImage:icon];
        _iconView.frame = CGRectMake(3, 3, frame.size.width - 6, frame.size.height - 6);
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_iconView];
    }
    return self;
}

@end

#pragma mark - 面板按钮视图

@interface VCamPanelButton : UIButton
@property (nonatomic, copy) NSString *buttonKey;
@end

@implementation VCamPanelButton
@end

#pragma mark - VCamFloatingBall

@interface VCamFloatingBall () <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) VCamBallView *ballView;
@property (nonatomic, strong) UIView *panelView;
// 页签
@property (nonatomic, strong) UIButton *tabControlBtn;
@property (nonatomic, strong) UIButton *tabLightBtn;
@property (nonatomic, strong) UIButton *tabSettingsBtn;
@property (nonatomic, strong) UIView *controlPageView;
@property (nonatomic, strong) UIView *lightPageView;
@property (nonatomic, strong) UIView *settingsPageView;
// 需要动态状态视觉的按钮(图标按钮, 用边框高亮表达开/关)
@property (nonatomic, strong) VCamPanelButton *replaceBtn;    // 替(图标, 边框=替换开启)
@property (nonatomic, strong) VCamPanelButton *mirrorBtn;     // 镜(图标, 边框=镜像开启)
@property (nonatomic, strong) VCamPanelButton *frontFixBtn;   // 设置页: 前置方向修正开关
@property (nonatomic, strong) VCamPanelButton *playPauseBtn;  // ▶ ↔ ⏸
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isFloating;
@property (nonatomic, assign) BOOL isPaused;
// 面板动态高度(2026-08-23): 高度跟随当前激活页签, 消除短页下方的空白
@property (nonatomic, assign) CGFloat panelPageTop;    // 页签行下方内容起始 y
@property (nonatomic, assign) CGFloat panelPad;        // 面板内边距
@property (nonatomic, assign) CGFloat controlPageH;    // 控制页内容高度
@property (nonatomic, assign) CGFloat settingsPageH;   // 设置页内容高度
@property (nonatomic, assign) CGFloat lightPageH;      // 打光页内容高度
@property (nonatomic, assign) NSInteger pickerSlot;      // 0=选择视频(vcam.mp4) 2/3=预设槽位

// ===== 三色打光(1.3.37, 复刻 Android ControllerFragment 屏幕取色 + vcplax 注入) =====
@property (nonatomic, strong) VCamPanelButton *pickColorBtn;  // 屏幕取色总开关
@property (nonatomic, strong) UIView *lightColorSwatch;       // 检测颜色预览色块
@property (nonatomic, strong) UILabel *lightColorLabel;       // 检测颜色名称/RGB
@property (nonatomic, strong) UISlider *lightIntensitySlider; // 打光强度 0-100 (默认 30)
@property (nonatomic, strong) UISlider *lightDiameterSlider;  // 打光直径 0-100 (默认 48)
@property (nonatomic, strong) UISlider *lightXSlider;         // 横坐标 0-100 (默认 50)
@property (nonatomic, strong) UISlider *lightYSlider;         // 纵坐标 0-100 (默认 50)
@property (nonatomic, strong) UISlider *lightFeatherSlider;   // 边缘羽化 0-100 (默认 100)
@property (nonatomic, strong) UILabel *lightIntensityValue;
@property (nonatomic, strong) UILabel *lightDiameterValue;
@property (nonatomic, strong) UILabel *lightXValue;
@property (nonatomic, strong) UILabel *lightYValue;
@property (nonatomic, strong) UILabel *lightFeatherValue;
@property (nonatomic, strong) UIView *pickDotView;            // 屏幕取色点(空心准星, 可拖)
@property (nonatomic, strong) dispatch_queue_t colorPickQueue;
@property (nonatomic, strong) dispatch_source_t colorPickTimer;
@property (nonatomic, assign) BOOL pickSuspended;             // 拖动取色点中暂停检测
@property (nonatomic, assign) int pickSkipCount;              // 开启/拖动后跳拍数(残留帧防护)
@property (nonatomic, assign) uint32_t lastDetectedColor;     // 上次检测色(变化才写 plist)
@property (nonatomic, assign) BOOL lightFlushScheduled;       // 滑块节流写标记
@property (nonatomic, assign) BOOL lightParamsDirty;          // 滑块待写标记
@end

@implementation VCamFloatingBall

+ (instancetype)sharedInstance {
    static VCamFloatingBall *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamFloatingBall alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _panelVisible = NO;
        _isFloating = NO;
        _isPaused = NO;
    }
    return self;
}

- (void)showFloatingBall {
    if (_isFloating) return;
    _isFloating = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self createOverlayWindow];
        vcam_ball_log(@"[vcam] Floating window created (tabs UI, gray theme)");
    });

    // 监听前后台切换(关 隐藏后的恢复通道: 锁屏解锁/回到桌面时 SpringBoard 重新 active)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
}

- (void)hideFloatingBall {
    if (!_isFloating) return;
    _isFloating = NO;
    [self stopColorPickup];  // 检测线程随 window 一起停(1.3.37)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.overlayWindow removeFromSuperview];
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        self.ballView = nil;
        self.panelView = nil;
        self.pickDotView = nil;  // 旧 view 随 window 失效, 重建时新建
    });
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI 创建

- (void)createOverlayWindow {
    CGRect screenBounds = [UIScreen mainScreen].bounds;

    // iOS 13+: UIWindow 必须关联 UIWindowScene 才会渲染（SpringBoard 也是 scene 体系,
    // 不关联 scene 的 window 创建成功但永远不可见——悬浮球一直不显示的根因）
    UIWindowScene *windowScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    // 回退: 任意 UIWindowScene（启动早期可能还没 active 的）
    if (!windowScene) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
    }

    if (windowScene) {
        _overlayWindow = [[VCamOverlayWindow alloc] initWithWindowScene:windowScene];
        vcam_ball_log([NSString stringWithFormat:@"[vcam] overlay window attached to scene: %@", windowScene]);
    } else {
        _overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screenBounds];
        vcam_ball_log(@"[vcam] overlay window: no scene found, fallback initWithFrame");
    }
    _overlayWindow.frame = screenBounds;
    _overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    _overlayWindow.backgroundColor = [UIColor clearColor];
    _overlayWindow.rootViewController = [[UIViewController alloc] init];
    _overlayWindow.hidden = NO;
    _overlayWindow.userInteractionEnabled = YES;

    // 悬浮球（初始位置在右侧中间）
    CGFloat ballSize = 50;
    CGFloat ballX = screenBounds.size.width - ballSize - 20;
    CGFloat ballY = screenBounds.size.height / 2 - ballSize / 2;
    _ballView = [[VCamBallView alloc] initWithFrame:CGRectMake(ballX, ballY, ballSize, ballSize)];

    // 点击手势
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTapped:)];
    [_ballView addGestureRecognizer:tapGesture];

    // 拖动手势
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballDragged:)];
    [_ballView addGestureRecognizer:panGesture];

    // 创建面板（初始隐藏, 先加入 window）
    [self createPanel];

    // 球最后加入 → 永远在面板上层, 位置重叠时球仍可拖动/点击
    [_overlayWindow addSubview:_ballView];
}

#pragma mark - 灰色主题辅助

- (UIColor *)vcPanelBgColor {
    return [UIColor colorWithRed:0.24 green:0.25 blue:0.27 alpha:0.94];
}
- (UIColor *)vcButtonBgColor {
    return [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0];
}
- (UIColor *)vcTabActiveColor {
    return [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0];
}
- (UIColor *)vcTabInactiveColor {
    return [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0];
}

- (VCamPanelButton *)makeButton:(NSString *)title frame:(CGRect)frame selector:(SEL)sel {
    VCamPanelButton *btn = [VCamPanelButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [self vcButtonBgColor];
    btn.layer.cornerRadius = 9;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    // 即时按压反馈: 按下高亮, 抬起/取消立即恢复 —— 按钮零延迟"有反应"的手感
    [btn addTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
    [btn addTarget:self action:@selector(buttonTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return btn;
}

- (void)buttonTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.05 animations:^{
        sender.backgroundColor = [UIColor colorWithRed:0.62 green:0.63 blue:0.66 alpha:1.0];
    }];
}

- (void)buttonTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.12 animations:^{
        sender.backgroundColor = [self vcButtonBgColor];
    }];
}

#pragma mark - 面板创建（三页签 + 灰色主题, 4x4 宫格控制页）

- (void)createPanel {
    CGFloat panelW = 241;
    CGFloat pad = 10;
    CGFloat contentW = panelW - pad * 2;                 // 221
    CGFloat tabH = 30;
    CGFloat pageTop = pad + tabH + 6;                    // 页面内容起始 y
    CGFloat rowH = 38;                                   // 整宽按钮高度
    CGFloat gap = 8;

    // 控制页内容高度: 4x4 宫格(44*4 + 7*3)
    CGFloat cellW = 50;
    CGFloat cellH = 44;
    CGFloat gridGap = 7;
    CGFloat controlH = cellH * 4 + gridGap * 3;          // 197
    // 设置页内容高度: 选择视频 + 预设2 + 预设3 + 前置修正 + 岐盛相机 5 整宽(38*5 + 8*4) + 10 + 水印(16)
    CGFloat settingsH = rowH * 5 + gap * 4 + 10 + 16;    // 248
    // 打光页内容高度(1.3.37): 取色按钮 38 + 6 + 颜色行 22 + 8 + 5 滑块行(30×5 + 6×4) + 4
    CGFloat lightH = 38 + 6 + 22 + 8 + (30 * 5 + 6 * 4) + 4;  // 252
    // 面板高度跟随激活页签(2026-08-23): 初始=控制页(默认页), 切页动态动画调整,
    // 消除"设置页加高后控制页下方多出空白一行"
    CGFloat panelH = pageTop + controlH + pad;
    _panelPageTop = pageTop;
    _panelPad = pad;
    _controlPageH = controlH;
    _settingsPageH = settingsH;
    _lightPageH = lightH;

    _panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
    _panelView.backgroundColor = [self vcPanelBgColor];
    _panelView.layer.cornerRadius = 12;
    _panelView.layer.masksToBounds = YES;
    _panelView.alpha = 0;
    _panelView.hidden = YES;

    // ===== 页签行: 控制 | 打光 | 设置 =====
    CGFloat tabW = 64;
    CGFloat tabGap = 8;
    CGFloat tabX0 = (panelW - (tabW * 3 + tabGap * 2)) / 2;
    _tabControlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabControlBtn.frame = CGRectMake(tabX0, pad, tabW, tabH);
    [_tabControlBtn setTitle:@"控制" forState:UIControlStateNormal];
    _tabControlBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabControlBtn.layer.cornerRadius = 7;
    [_tabControlBtn addTarget:self action:@selector(controlTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabControlBtn];

    _tabLightBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabLightBtn.frame = CGRectMake(tabX0 + tabW + tabGap, pad, tabW, tabH);
    [_tabLightBtn setTitle:@"打光" forState:UIControlStateNormal];
    _tabLightBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabLightBtn.layer.cornerRadius = 7;
    [_tabLightBtn addTarget:self action:@selector(lightTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabLightBtn];

    _tabSettingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabSettingsBtn.frame = CGRectMake(tabX0 + (tabW + tabGap) * 2, pad, tabW, tabH);
    [_tabSettingsBtn setTitle:@"设置" forState:UIControlStateNormal];
    _tabSettingsBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabSettingsBtn.layer.cornerRadius = 7;
    [_tabSettingsBtn addTarget:self action:@selector(settingsTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabSettingsBtn];

    // ===== 控制页: 4x4 宫格 =====
    // 图标按钮(播/复/镜/替) = btn_icons.h 加密 PNG;
    // ↷=旋转(顺时针90°) ▶=播放/暂停;
    // ↑←↓→ − ＋ 1/2/3/4 = 占位(功能后续版本定义)
    _controlPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, controlH)];
    _controlPageView.backgroundColor = [UIColor clearColor];
    [_panelView addSubview:_controlPageView];

    static const unsigned char kPlayKey[8] = {
        VCS_BTN_VCAM_BTN_PLAY_KEY0, VCS_BTN_VCAM_BTN_PLAY_KEY1,
        VCS_BTN_VCAM_BTN_PLAY_KEY2, VCS_BTN_VCAM_BTN_PLAY_KEY3,
        VCS_BTN_VCAM_BTN_PLAY_KEY4, VCS_BTN_VCAM_BTN_PLAY_KEY5,
        VCS_BTN_VCAM_BTN_PLAY_KEY6, VCS_BTN_VCAM_BTN_PLAY_KEY7,
    };
    static const unsigned char kMirrorKey[8] = {
        VCS_BTN_VCAM_BTN_MIRROR_KEY0, VCS_BTN_VCAM_BTN_MIRROR_KEY1,
        VCS_BTN_VCAM_BTN_MIRROR_KEY2, VCS_BTN_VCAM_BTN_MIRROR_KEY3,
        VCS_BTN_VCAM_BTN_MIRROR_KEY4, VCS_BTN_VCAM_BTN_MIRROR_KEY5,
        VCS_BTN_VCAM_BTN_MIRROR_KEY6, VCS_BTN_VCAM_BTN_MIRROR_KEY7,
    };
    static const unsigned char kReplaceKey[8] = {
        VCS_BTN_VCAM_BTN_REPLACE_KEY0, VCS_BTN_VCAM_BTN_REPLACE_KEY1,
        VCS_BTN_VCAM_BTN_REPLACE_KEY2, VCS_BTN_VCAM_BTN_REPLACE_KEY3,
        VCS_BTN_VCAM_BTN_REPLACE_KEY4, VCS_BTN_VCAM_BTN_REPLACE_KEY5,
        VCS_BTN_VCAM_BTN_REPLACE_KEY6, VCS_BTN_VCAM_BTN_REPLACE_KEY7,
    };
    static const unsigned char kRestoreKey[8] = {
        VCS_BTN_VCAM_BTN_RESTORE_KEY0, VCS_BTN_VCAM_BTN_RESTORE_KEY1,
        VCS_BTN_VCAM_BTN_RESTORE_KEY2, VCS_BTN_VCAM_BTN_RESTORE_KEY3,
        VCS_BTN_VCAM_BTN_RESTORE_KEY4, VCS_BTN_VCAM_BTN_RESTORE_KEY5,
        VCS_BTN_VCAM_BTN_RESTORE_KEY6, VCS_BTN_VCAM_BTN_RESTORE_KEY7,
    };
    static const unsigned char kRotateKey[8] = {
        VCS_BTN_VCAM_BTN_ROTATE_KEY0, VCS_BTN_VCAM_BTN_ROTATE_KEY1,
        VCS_BTN_VCAM_BTN_ROTATE_KEY2, VCS_BTN_VCAM_BTN_ROTATE_KEY3,
        VCS_BTN_VCAM_BTN_ROTATE_KEY4, VCS_BTN_VCAM_BTN_ROTATE_KEY5,
        VCS_BTN_VCAM_BTN_ROTATE_KEY6, VCS_BTN_VCAM_BTN_ROTATE_KEY7,
    };

    // 宫格布局: 文字 / SF Symbol / 自定义图标 三类按钮
    // 播图标 → 从头重播; 复图标 → 占位; 镜图标 → 镜像; 替图标 → 替换开关;
    // 转图标 → 旋转(1.3.26 起用自定义图标替代 arrow.clockwise)
    // 箭头/加减/播放暂停 = SF Symbol。1/2/3/4 = 文字占位
    typedef NS_ENUM(int, GridCellType) {
        CellText,    // 文字按钮
        CellIcon,    // 自定义加密 PNG 图标(btn_icons.h)
        CellSymbol,  // SF Symbol 按钮
    };
    struct GridCell {
        GridCellType type;
        NSString *repr;      // CellText=标题 / CellSymbol=SF Symbol 名
        UIImage *icon;       // CellIcon 图像
        UIEdgeInsets insets; // CellIcon 内边距(控制图标大小)
        SEL action;
    };
    UIImage *iconPlay    = vcamDecodeBtnIcon(vcam_btn_play_enc, vcam_btn_play_len, kPlayKey);
    UIImage *iconMirror  = vcamDecodeBtnIcon(vcam_btn_mirror_enc, vcam_btn_mirror_len, kMirrorKey);
    UIImage *iconReplace = vcamDecodeBtnIcon(vcam_btn_replace_enc, vcam_btn_replace_len, kReplaceKey);
    UIImage *iconRestore = vcamDecodeBtnIcon(vcam_btn_restore_enc, vcam_btn_restore_len, kRestoreKey);
    UIImage *iconRotate  = vcamDecodeBtnIcon(vcam_btn_rotate_enc, vcam_btn_rotate_len, kRotateKey);
    // AlwaysOriginal: UIButtonTypeSystem 会把 image tint 染成系统蓝
    // (1.3.24 实测图标全蓝的根因), 固定原始灰白像素免染色
    iconPlay    = [iconPlay    imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconMirror  = [iconMirror  imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconReplace = [iconReplace imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconRestore = [iconRestore imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconRotate  = [iconRotate  imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];

    // 1.3.26 修复: 播图标此前漏绑(icon=nil → 空白按钮), "左上角图标没显示"的根因
    // 1.3.28 图标按需调大小: 播放大(insets 2), 复缩小(insets 8), 其余中等(insets 4)
    struct GridCell cells[4][4] = {
        { {CellIcon, nil, iconPlay, {2, 2, 2, 2}, @selector(restartVideoTapped)},
          {CellSymbol, @"arrow.up", nil, {0, 0, 0, 0}, @selector(panUpTapped)},
          {CellIcon, nil, iconRestore, {8, 8, 8, 8}, @selector(resetTransformTapped)},
          {CellText, @"1", nil, {0, 0, 0, 0}, @selector(placeholderTapped)} },
        { {CellSymbol, @"arrow.left", nil, {0, 0, 0, 0}, @selector(panLeftTapped)},
          {CellSymbol, @"arrow.down", nil, {0, 0, 0, 0}, @selector(panDownTapped)},
          {CellSymbol, @"arrow.right", nil, {0, 0, 0, 0}, @selector(panRightTapped)},
          {CellText, @"2", nil, {0, 0, 0, 0}, @selector(placeholderTapped)} },
        { {CellSymbol, @"minus", nil, {0, 0, 0, 0}, @selector(zoomOutTapped)},
          {CellSymbol, @"play.fill", nil, {0, 0, 0, 0}, @selector(playPauseTapped)},
          {CellSymbol, @"plus", nil, {0, 0, 0, 0}, @selector(zoomInTapped)},
          {CellText, @"3", nil, {0, 0, 0, 0}, @selector(placeholderTapped)} },
        { {CellIcon, nil, iconRotate, {7, 7, 7, 7}, @selector(rotateRightTapped)},
          {CellIcon, nil, iconMirror, {7, 7, 7, 7}, @selector(mirrorTapped)},
          {CellIcon, nil, iconReplace, {4, 4, 4, 4}, @selector(toggleReplacementTapped)},
          {CellText, @"4", nil, {0, 0, 0, 0}, @selector(placeholderTapped)} },
    };
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            struct GridCell cell = cells[r][c];
            CGRect f = CGRectMake(pad + c * (cellW + gridGap), r * (cellH + gridGap), cellW, cellH);
            VCamPanelButton *btn;
            if (cell.type == CellIcon) {
                // 自定义图标按钮: 灰白 PNG 居中(AlwaysOriginal 免 tint 染色)
                // (1.3.28 内边距按图标单独配置: 播 2 大 / 复 8 小 / 其余 4 中)
                btn = [self makeButton:@"" frame:f selector:cell.action];
                [btn setImage:cell.icon forState:UIControlStateNormal];
                btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
                btn.imageEdgeInsets = cell.insets;
            } else if (cell.type == CellSymbol) {
                // SF Symbol 按钮: template 矢量图, tintColor 染白贴合灰色主题
                // (1.3.27: 17pt Regular → 14pt Semibold, 箭头/加减缩小且加粗,
                // 与放大的自定义图标形成主次层级)
                btn = [self makeButton:@"" frame:f selector:cell.action];
                UIImageSymbolConfiguration *cfg =
                    [UIImageSymbolConfiguration configurationWithPointSize:14
                                                                   weight:UIImageSymbolWeightSemibold];
                UIImage *sym = [UIImage systemImageNamed:cell.repr withConfiguration:cfg];
                if (sym) {
                    [btn setImage:sym forState:UIControlStateNormal];
                    btn.tintColor = [UIColor whiteColor];
                    btn.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
                } else {
                    // 兜底: 极老系统无 SF Symbol 时显示文字
                    btn = [self makeButton:@"·" frame:f selector:cell.action];
                    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
                }
            } else {
                btn = [self makeButton:cell.repr frame:f selector:cell.action];
                btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            }
            [_controlPageView addSubview:btn];
            if (r == 2 && c == 1) _playPauseBtn = btn;         // ▶ ↔ ⏸ (play.fill/pause.fill)
            if (r == 3 && c == 1) _mirrorBtn = btn;             // 镜(图标)
            if (r == 3 && c == 2) _replaceBtn = btn;            // 替(图标)
        }
    }

    // ===== 打光页(1.3.37, 复刻 Android 三色打光): 屏幕取色 + 颜色预览 + 5 参数滑块 =====
    // 数据流: 取色点(可拖) → 检测线程 0.1s 截屏采样多数表决 → vc.plist lightColor
    //         → mediaserverd 轮询 → 预渲染圆形渐变光斑注入(公式同 Android vcplax)
    _lightPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, lightH)];
    _lightPageView.backgroundColor = [UIColor clearColor];
    [_panelView addSubview:_lightPageView];

    // 屏幕取色总开关: 开 = 取色点显示 + 检测启动 + 打光启用(颜色跟屏幕闪烁)
    _pickColorBtn = [self makeButton:@"屏幕取色: 关"
                               frame:CGRectMake(pad, 0, contentW, rowH)
                             selector:@selector(pickColorTapped)];
    _pickColorBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_lightPageView addSubview:_pickColorBtn];

    // 检测颜色预览行: 色块 + 名称/RGB
    CGFloat colorRowY = rowH + 6;
    _lightColorSwatch = [[UIView alloc] initWithFrame:CGRectMake(pad, colorRowY + 3, 16, 16)];
    _lightColorSwatch.layer.cornerRadius = 3;
    _lightColorSwatch.layer.borderWidth = 1;
    _lightColorSwatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    _lightColorSwatch.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [_lightPageView addSubview:_lightColorSwatch];
    _lightColorLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad + 24, colorRowY, contentW - 24, 22)];
    _lightColorLabel.text = @"颜色: 未检测";
    _lightColorLabel.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    _lightColorLabel.font = [UIFont systemFontOfSize:12];
    [_lightPageView addSubview:_lightColorLabel];

    // 5 参数滑块行: 标题(56) + 滑块 + 值(42), 默认 强度30/直径48/X50/Y50/羽化100
    // plist 已有值优先(跨进程持久化), 否则用默认值(getter 内置默认)
    CGFloat sliderX = pad + 56;
    CGFloat sliderW = contentW - 56 - 42;
    CGFloat sy = colorRowY + 22 + 8;
    CGFloat rowStep = 30 + 6;
    NSString *rowTitles[5] = {@"打光强度", @"打光直径", @"横坐标", @"纵坐标", @"边缘羽化"};
    SEL rowActions[5] = {@selector(lightIntensityChanged:), @selector(lightDiameterChanged:),
                         @selector(lightXChanged:), @selector(lightYChanged:),
                         @selector(lightFeatherChanged:)};
    int initVals[5] = {
        [VCamNotify plistLightIntensity], [VCamNotify plistLightDiameter],
        [VCamNotify plistLightX], [VCamNotify plistLightY],
        [VCamNotify plistLightFeather]
    };
    for (int i = 0; i < 5; i++) {
        CGFloat ry = sy + rowStep * i;
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, ry + 5, 56, 20)];
        title.text = rowTitles[i];
        title.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
        title.font = [UIFont systemFontOfSize:12];
        [_lightPageView addSubview:title];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(sliderX, ry + 1, sliderW, 28)];
        slider.minimumValue = 0;
        slider.maximumValue = 100;
        int v = initVals[i];
        if (v < 0) v = 0;
        if (v > 100) v = 100;
        slider.value = (float)v;
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.55 green:0.56 blue:0.58 alpha:1.0];
        [slider addTarget:self action:rowActions[i] forControlEvents:UIControlEventValueChanged];
        [_lightPageView addSubview:slider];

        UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(pad + contentW - 42, ry + 5, 42, 20)];
        val.text = [NSString stringWithFormat:@"%d%%", v];
        val.textColor = [UIColor whiteColor];
        val.font = [UIFont systemFontOfSize:12];
        val.textAlignment = NSTextAlignmentRight;
        [_lightPageView addSubview:val];

        // ARC 下不能把 __strong ivar 地址塞进数组 —— switch 直接赋值
        switch (i) {
            case 0: _lightIntensitySlider = slider; _lightIntensityValue = val; break;
            case 1: _lightDiameterSlider = slider; _lightDiameterValue = val; break;
            case 2: _lightXSlider = slider; _lightXValue = val; break;
            case 3: _lightYSlider = slider; _lightYValue = val; break;
            case 4: _lightFeatherSlider = slider; _lightFeatherValue = val; break;
        }
    }

    // ===== 设置页 =====
    _settingsPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, settingsH)];
    _settingsPageView.backgroundColor = [UIColor clearColor];
    [_panelView addSubview:_settingsPageView];

    // 选择视频(整宽, 原 3x3 布局时期在控制页, 4x4 宫格化后移到设置页)
    VCamPanelButton *selectBtn = [self makeButton:@"选择视频"
                                            frame:CGRectMake(pad, 0, contentW, rowH)
                                          selector:@selector(selectVideoTapped)];
    selectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:selectBtn];

    VCamPanelButton *preset2 = [self makeButton:@"预设视频2"
                                          frame:CGRectMake(pad, rowH + gap, contentW, rowH)
                                        selector:@selector(preset2Tapped)];
    preset2.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset2];

    VCamPanelButton *preset3 = [self makeButton:@"预设视频3"
                                          frame:CGRectMake(pad, (rowH + gap) * 2, contentW, rowH)
                                        selector:@selector(preset3Tapped)];
    preset3.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset3];

    // 前置方向修正(2026-08-23): 前置摄像头流显示旋转与后置差 180°(箭头方向双反),
    // mediaserverd 无法自动判别前后置 —— 手动开关: 用前置时开, 用后置时关。
    // 开启时 pan 应用 X/Y 同时取反
    _frontFixBtn = [self makeButton:@"前置方向修正: 关"
                              frame:CGRectMake(pad, (rowH + gap) * 3, contentW, rowH)
                            selector:@selector(frontPanFixTapped)];
    _frontFixBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:_frontFixBtn];
    [self refreshFrontFixButton];

    // 岐盛相机: 隐藏频道链接按钮(跳转 Telegram)。
    // 2026-08-18: 品牌/签名/频道字符串混淆存储(VCamStr.h), 二进制无明文
    VCamPanelButton *channel = [self makeButton:VCS(qisheng)
                                          frame:CGRectMake(pad, (rowH + gap) * 4, contentW, rowH)
                                        selector:@selector(channelLinkTapped)];
    channel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:channel];

    // 水印
    UILabel *mark = [[UILabel alloc] initWithFrame:CGRectMake(pad, (rowH + gap) * 4 + rowH + 10, contentW, 16)];
    mark.text = VCS(mark);
    mark.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    mark.textAlignment = NSTextAlignmentCenter;
    mark.font = [UIFont systemFontOfSize:11];
    [_settingsPageView addSubview:mark];

    // 初始页签 = 控制, 替/镜边框按当前 enabled/mirrored 状态
    _lightPageView.hidden = YES;
    _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self updateReplaceButtonVisual];
    [self updateMirrorButtonVisual];

    // 面板先加, 悬浮球后加 → 球永远在面板上层, 即使重叠也能拖动/点击
    [_overlayWindow addSubview:_panelView];

    // 打光状态恢复(1.3.37): respring 前取色模式开着 → 恢复取色点 + 检测。
    // 必须在面板 addSubview 之后 → 取色点最后添加位于面板/球之上
    if ([VCamNotify plistLightEnabled]) {
        _lastDetectedColor = [VCamNotify plistLightColor];
        _pickSkipCount = 3;
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        [self updateColorPreview:_lastDetectedColor];
        vcam_ball_log(@"[vcam][light] pickup state restored from plist");
    }
}

- (void)refreshTabStyles {
    BOOL controlActive = !_controlPageView.hidden;
    BOOL lightActive = !_lightPageView.hidden;
    _tabControlBtn.backgroundColor = controlActive ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    _tabLightBtn.backgroundColor = lightActive ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    _tabSettingsBtn.backgroundColor = (!controlActive && !lightActive) ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    [_tabControlBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_tabLightBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_tabSettingsBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
}

#pragma mark - 页签切换

// 面板高度跟随激活页签(2026-08-23): 高度动画到 pageTop+内容高+pad,
// 垂直位置随新高度重新以球为中心(updatePanelPosition 读新尺寸)
- (void)applyPanelContentHeight:(CGFloat)contentH {
    CGFloat targetH = _panelPageTop + contentH + _panelPad;
    if (fabs(_panelView.frame.size.height - targetH) < 0.5) return;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = self.panelView.frame;
        f.size.height = targetH;
        self.panelView.frame = f;
        [self updatePanelPosition];
    }];
}

- (void)controlTabTapped {
    vcam_ball_log(@"[vcam][tab] control");
    _controlPageView.hidden = NO;
    _lightPageView.hidden = YES;
    _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self applyPanelContentHeight:_controlPageH];
}

- (void)lightTabTapped {
    vcam_ball_log(@"[vcam][tab] light");
    _controlPageView.hidden = YES;
    _lightPageView.hidden = NO;
    _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self applyPanelContentHeight:_lightPageH];
}

#pragma mark - 三色打光(1.3.37, 复刻 Android 屏幕取色 → vc.plist → mediaserverd 注入)

// 近似颜色名(检测预览显示用)
static NSString *vcamLightColorName(uint32_t c) {
    int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
    if (r > 200 && g < 80 && b < 80) return @"红";
    if (r < 80 && g > 200 && b < 80) return @"绿";
    if (r < 80 && g < 80 && b > 200) return @"蓝";
    if (r > 200 && g > 200 && b < 80) return @"黄";
    if (r < 80 && g > 200 && b > 200) return @"青";
    if (r > 200 && g < 80 && b > 200) return @"紫";
    if (r > 220 && g > 220 && b > 220) return @"白";
    return @"自定义";
}

// 屏幕取色总开关: 开 = 取色点显示 + 检测启动 + 打光启用(光斑颜色跟屏幕闪烁);
// 关 = 全链路熄灭(lightColor=0, mediaserverd 注入直通零开销)
- (void)pickColorTapped {
    BOOL on = ![VCamNotify plistLightEnabled];
    [VCamNotify setPlistLightEnabled:on];
    if (on) {
        [VCamNotify setPlistLightColor:0];  // 复位, 检测到颜色再写(避免残留旧色)
        _lastDetectedColor = 0;
        _pickSkipCount = 3;  // 跳前 3 拍(Android FRAME_SKIP_ON_START: 避免残留状态误检)
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        vcam_ball_log(@"[vcam][light] screen color pickup ON");
    } else {
        [self stopColorPickup];
        [self hidePickDot];
        [VCamNotify setPlistLightColor:0];
        _lastDetectedColor = 0;
        [self updateColorPreview:0];
        [_pickColorBtn setTitle:@"屏幕取色: 关" forState:UIControlStateNormal];
        vcam_ball_log(@"[vcam][light] screen color pickup OFF");
    }
}

// 取色点(空心准星): 中心透明设计 → 截屏采样不受自身污染
- (void)showPickDot {
    if (!_overlayWindow) return;
    if (_pickDotView) {
        _pickDotView.hidden = NO;
        return;
    }
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};
    CGFloat px = [pl[@"lightPickX"] doubleValue];
    CGFloat py = [pl[@"lightPickY"] doubleValue];
    CGRect sb = _overlayWindow.bounds;
    if (px <= 0 || py <= 0) { px = sb.size.width / 2; py = sb.size.height / 2; }
    px = MAX(22, MIN(sb.size.width - 22, px));
    py = MAX(22, MIN(sb.size.height - 22, py));
    _pickDotView = [[VCamPickDotView alloc] initWithFrame:CGRectMake(px - 22, py - 22, 44, 44)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(pickDotDragged:)];
    [_pickDotView addGestureRecognizer:pan];
    [_overlayWindow addSubview:_pickDotView];  // 最后添加 → 位于面板/球之上
}

- (void)hidePickDot {
    _pickDotView.hidden = YES;
}

// 拖动取色点: 拖动中暂停检测(手指物理遮挡采样区, 采样无意义);
// 松手写位置到 vc.plist(持久化 + 检测线程按最新位置采样)并跳 3 拍
- (void)pickDotDragged:(UIPanGestureRecognizer *)g {
    if (!_pickDotView) return;
    CGPoint t = [g translationInView:_overlayWindow];
    CGPoint c = CGPointMake(_pickDotView.center.x + t.x, _pickDotView.center.y + t.y);
    c.x = MAX(22, MIN(_overlayWindow.bounds.size.width - 22, c.x));
    c.y = MAX(22, MIN(_overlayWindow.bounds.size.height - 22, c.y));
    _pickDotView.center = c;
    [g setTranslation:CGPointZero inView:_overlayWindow];
    if (g.state == UIGestureRecognizerStateBegan) {
        _pickSuspended = YES;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _pickSuspended = NO;
        _pickSkipCount = 3;
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
            [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
        dict[@"lightPickX"] = @(c.x);
        dict[@"lightPickY"] = @(c.y);
        [dict writeToFile:VCamPlistPath atomically:YES];
        vcam_ball_log([NSString stringWithFormat:@"[vcam][light] pick dot moved to (%.0f,%.0f)", c.x, c.y]);
    }
}

// 检测线程: 0.1s 节拍 serial queue(独立于主线程, 截屏+采样不卡 UI)
- (void)startColorPickup {
    if (_colorPickTimer) return;
    if (!_colorPickQueue) {
        _colorPickQueue = dispatch_queue_create("vcam.colorpick", DISPATCH_QUEUE_SERIAL);
    }
    _colorPickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _colorPickQueue);
    dispatch_source_set_timer(_colorPickTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                              (uint64_t)(0.1 * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_colorPickTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf colorPickTick];
    });
    dispatch_resume(_colorPickTimer);
    vcam_ball_log(@"[vcam][light] color pickup timer started (0.1s)");
}

- (void)stopColorPickup {
    if (_colorPickTimer) {
        dispatch_source_cancel(_colorPickTimer);
        _colorPickTimer = nil;
        vcam_ball_log(@"[vcam][light] color pickup timer stopped");
    }
}

// 检测一拍(复刻 Android onImageAvailable 采样算法):
// 截取色点周围 44x44pt → 中心 21x21px 采样 → 饱和度过滤(max>180 且 max-min>60)
// → RGB 量化 >>5 到 512 桶 → 多数表决(bestCount>=30) → 颜色变化写 vc.plist
// 检测不到鲜艳色 → lightColor=0 = 打光熄灭(颜色跟随屏幕闪烁熄/亮)
- (void)colorPickTick {
    if (_pickSuspended) return;
    if (_pickSkipCount > 0) { _pickSkipCount--; return; }

    // 取色点位置(pt): 松手时写入; 未初始化用屏幕中心
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};
    CGFloat px = [pl[@"lightPickX"] doubleValue];
    CGFloat py = [pl[@"lightPickY"] doubleValue];
    CGRect sb = [UIScreen mainScreen].bounds;
    if (px <= 0 || py <= 0) { px = sb.size.width / 2; py = sb.size.height / 2; }

    // 截屏(小区域): SpringBoard 系统进程内 CGWindowListCreateImage 可用,
    // 只合成取色点周围 44x44pt(GPU 小区域读回, 开销极低)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGImageRef img = CGWindowListCreateImage(
        CGRectMake(px - 22, py - 22, 44, 44),
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowImageDefault);
#pragma clang diagnostic pop
    if (!img) return;  // 截屏失败(罕见): 本拍跳过, 不熄灯(避免误闪)

    const int S = 21;  // 采样边长(像素, ~7pt): 准星中心透明区内
    size_t iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
    if (iw >= (size_t)S && ih >= (size_t)S) {
        CGImageRef crop = CGImageCreateWithImageInRect(img,
            CGRectMake((CGFloat)(iw - S) / 2.0, (CGFloat)(ih - S) / 2.0, S, S));
        if (crop) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef bctx = CGBitmapContextCreate(NULL, S, S, 8, S * 4, cs,
                                                      kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
            if (bctx) {
                CGContextDrawImage(bctx, CGRectMake(0, 0, S, S), crop);
                const uint8_t *rgba = (const uint8_t *)CGBitmapContextGetData(bctx);

                // 量化多数表决(Android 同款: 8x8x8=512 桶, 每通道 >>5)
                int counts[512] = {0};
                int sumR[512] = {0}, sumG[512] = {0}, sumB[512] = {0};
                for (int y = 0; y < S; y++) {
                    for (int x = 0; x < S; x++) {
                        const uint8_t *p = rgba + (y * S + x) * 4;
                        int r = p[0], g = p[1], b = p[2];
                        int maxc = MAX(MAX(r, g), b), minc = MIN(MIN(r, g), b);
                        if (maxc < 180 || maxc - minc < 60) continue;  // 饱和度过滤
                        int idx = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
                        counts[idx]++; sumR[idx] += r; sumG[idx] += g; sumB[idx] += b;
                    }
                }
                int bestIdx = 0, bestCount = 0;
                for (int i = 0; i < 512; i++) {
                    if (counts[i] > bestCount) { bestCount = counts[i]; bestIdx = i; }
                }
                uint32_t detected = 0;
                if (bestCount >= 30) {  // 441 像素的 ~7%(对齐 Android 10/121)
                    int r = sumR[bestIdx] / bestCount;
                    int g = sumG[bestIdx] / bestCount;
                    int b = sumB[bestIdx] / bestCount;
                    detected = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
                }

                if (detected != _lastDetectedColor) {
                    _lastDetectedColor = detected;
                    [VCamNotify setPlistLightColor:detected];  // 0=熄灭
                    uint32_t d = detected;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateColorPreview:d];
                    });
                    vcam_ball_log([NSString stringWithFormat:
                        @"[vcam][light] color detected: 0x%06x %@", d, vcamLightColorName(d)]);
                }
                CGContextRelease(bctx);
            }
            CGColorSpaceRelease(cs);
            CFRelease(crop);
        }
    }
    CFRelease(img);
}

// 主线程更新颜色预览
- (void)updateColorPreview:(uint32_t)color {
    if (color == 0) {
        _lightColorSwatch.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        _lightColorLabel.text = @"颜色: 未检测";
    } else {
        _lightColorSwatch.backgroundColor = [UIColor colorWithRed:((color >> 16) & 0xFF) / 255.0
                                                             green:((color >> 8) & 0xFF) / 255.0
                                                              blue:(color & 0xFF) / 255.0 alpha:1];
        _lightColorLabel.text = [NSString stringWithFormat:@"颜色: %@ (%d,%d,%d)",
                                 vcamLightColorName(color),
                                 (int)((color >> 16) & 0xFF),
                                 (int)((color >> 8) & 0xFF),
                                 (int)(color & 0xFF)];
    }
}

// ===== 打光参数滑块(节流写: 拖动中 0.12s 合并落盘一次, Android 同款思路) =====
- (void)lightIntensityChanged:(UISlider *)s {
    _lightIntensityValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)];
    [self scheduleLightParamsFlush];
}
- (void)lightDiameterChanged:(UISlider *)s {
    _lightDiameterValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)];
    [self scheduleLightParamsFlush];
}
- (void)lightXChanged:(UISlider *)s {
    _lightXValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)];
    [self scheduleLightParamsFlush];
}
- (void)lightYChanged:(UISlider *)s {
    _lightYValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)];
    [self scheduleLightParamsFlush];
}
- (void)lightFeatherChanged:(UISlider *)s {
    _lightFeatherValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)];
    [self scheduleLightParamsFlush];
}

- (void)scheduleLightParamsFlush {
    _lightParamsDirty = YES;
    if (_lightFlushScheduled) return;
    _lightFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _lightFlushScheduled = NO;
        if (_lightParamsDirty) {
            _lightParamsDirty = NO;
            [self flushLightParams];
        }
    });
}

// 5 参数一次读改写批量落盘(0.12s 节流上限, 拖动全程打光实时跟随)
- (void)flushLightParams {
    if (!_lightIntensitySlider) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightIntensity"] = @((int)lroundf(_lightIntensitySlider.value));
    dict[@"lightDiameter"] = @((int)lroundf(_lightDiameterSlider.value));
    dict[@"lightX"] = @((int)lroundf(_lightXSlider.value));
    dict[@"lightY"] = @((int)lroundf(_lightYSlider.value));
    dict[@"lightFeather"] = @((int)lroundf(_lightFeatherSlider.value));
    [dict writeToFile:VCamPlistPath atomically:YES];
}

- (void)settingsTabTapped {
    vcam_ball_log(@"[vcam][tab] settings");
    _controlPageView.hidden = YES;
    _lightPageView.hidden = YES;
    _settingsPageView.hidden = NO;
    [self refreshTabStyles];
    [self applyPanelContentHeight:_settingsPageH];
}

#pragma mark - 交互

- (void)ballTapped:(UITapGestureRecognizer *)gesture {
    vcam_ball_log(@"[vcam][ball] tap received");
    [self togglePanel];
}

- (void)ballDragged:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:_overlayWindow];
    CGPoint newCenter = CGPointMake(_ballView.center.x + translation.x, _ballView.center.y + translation.y);

    // 限制在屏幕内
    CGFloat halfW = _ballView.frame.size.width / 2;
    CGFloat halfH = _ballView.frame.size.height / 2;
    newCenter.x = MAX(halfW, MIN(_overlayWindow.frame.size.width - halfW, newCenter.x));
    newCenter.y = MAX(halfH, MIN(_overlayWindow.frame.size.height - halfH, newCenter.y));

    _ballView.center = newCenter;
    [gesture setTranslation:CGPointZero inView:_overlayWindow];

    // 同步面板位置（面板在悬浮球左侧）
    [self updatePanelPosition];
}

- (void)togglePanel {
    _panelVisible = !_panelVisible;
    if (_panelVisible) {
        _panelView.hidden = NO;
        [self updatePanelPosition];
        [UIView animateWithDuration:0.2 animations:^{
            self.panelView.alpha = 1.0;
        }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{
            self.panelView.alpha = 0;
        } completion:^(BOOL finished) {
            self.panelView.hidden = YES;
        }];
    }
}

- (void)updatePanelPosition {
    CGFloat panelW = _panelView.frame.size.width;
    CGFloat panelH = _panelView.frame.size.height;
    CGFloat screenW = _overlayWindow.frame.size.width;
    CGFloat screenH = _overlayWindow.frame.size.height;
    CGFloat gap = 8;

    // 面板默认在悬浮球右侧; 右侧空间不足(球靠右缘)时翻到左侧
    CGFloat rightX = CGRectGetMaxX(_ballView.frame) + gap;
    CGFloat leftX = _ballView.frame.origin.x - panelW - gap;
    CGFloat panelX = (rightX + panelW <= screenW - 5) ? rightX : leftX;
    panelX = MAX(5, panelX);

    // 垂直以球为中心, 限制在屏幕内
    CGFloat panelY = _ballView.center.y - panelH / 2;
    panelY = MAX(5, MIN(screenH - panelH - 5, panelY));

    _panelView.frame = CGRectMake(panelX, panelY, panelW, panelH);
}

#pragma mark - 控制页回调

// 播: 从头重播当前视频(restartToken 自增, mediaserverd 轮询触发重载)
- (void)restartVideoTapped {
    vcam_ball_log(@"[vcam][btn] restart(replay from beginning)");
    [VCamNotify bumpRestartToken];
}

// ▶/⏸: 暂停/继续(SF Symbol play.fill ↔ pause.fill)
- (void)playPauseTapped {
    _isPaused = !_isPaused;
    [VCamNotify setPlistPaused:_isPaused];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14
                                                       weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage systemImageNamed:(_isPaused ? @"pause.fill" : @"play.fill")
                            withConfiguration:cfg];
    [self.playPauseBtn setImage:sym forState:UIControlStateNormal];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] playPause -> %@", _isPaused ? @"paused" : @"playing"]);
}

// 替/原: 替换摄像头 ↔ 还原摄像头(图标按钮, 白色边框=替换开启)
- (void)toggleReplacementTapped {
    BOOL newEnabled = ![VCamNotify isPlistEnabled];
    [VCamNotify setPlistEnabled:newEnabled];
    [[VCamCore sharedInstance] setEnabled:newEnabled];
    [self updateReplaceButtonVisual];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] replace toggle -> %@", newEnabled ? @"replaced" : @"restored"]);
}

- (void)updateReplaceButtonVisual {
    // 语义(1.3.29 用户要求反转): 默认(替换中)无边框 = 干净状态;
    // 点击还原(未替换)显示白边 = 提醒当前是真实摄像头画面
    BOOL en = [VCamNotify isPlistEnabled];
    self.replaceBtn.layer.borderWidth = 2;
    self.replaceBtn.layer.borderColor = en ? [UIColor clearColor].CGColor
                                           : [UIColor whiteColor].CGColor;
}

// 镜: 镜像翻转(图标按钮, 白色边框=镜像开启)
- (void)updateMirrorButtonVisual {
    BOOL mi = [VCamNotify plistMirrored];
    self.mirrorBtn.layer.borderWidth = 2;
    self.mirrorBtn.layer.borderColor = mi ? [UIColor whiteColor].CGColor
                                          : [UIColor clearColor].CGColor;
}

// 前置方向修正开关视觉: 标题文案 + 白边高亮(开)
- (void)refreshFrontFixButton {
    BOOL on = [VCamNotify plistFrontPanFix];
    [self.frontFixBtn setTitle:(on ? @"前置方向修正: 开" : @"前置方向修正: 关")
                      forState:UIControlStateNormal];
    self.frontFixBtn.layer.borderWidth = 2;
    self.frontFixBtn.layer.borderColor = on ? [UIColor whiteColor].CGColor
                                            : [UIColor clearColor].CGColor;
}

// 前置方向修正: 前置流 pan 双反 180°, 开启后 mediaserverd 应用 pan 时 X/Y 取反
- (void)frontPanFixTapped {
    BOOL nv = ![VCamNotify plistFrontPanFix];
    [VCamNotify setPlistFrontPanFix:nv];
    [self refreshFrontFixButton];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] front pan fix -> %d (synced)", nv]);
}

// 占位按钮(↑←↓→ − ＋ 复 1/2/3/4): 功能待后续版本定义, 仅记录点击
- (void)placeholderTapped {
    vcam_ball_log(@"[vcam][btn] placeholder tapped (function TBD)");
}

// 关: 只收起面板(悬浮球保持显示), 再点悬浮球即可重新打开
- (void)closePanelTapped {
    vcam_ball_log(@"[vcam][btn] close panel (ball stays)");
    if (_panelVisible) {
        _panelVisible = NO;
        [UIView animateWithDuration:0.15 animations:^{
            self.panelView.alpha = 0;
        } completion:^(BOOL finished) {
            self.panelView.hidden = YES;
        }];
    }
}

// 1/2/3: 播放当前选择视频 / 预设视频2 / 预设视频3
- (void)slot1Tapped { [self playSlot:1]; }
- (void)slot2Tapped { [self playSlot:2]; }
- (void)slot3Tapped { [self playSlot:3]; }

- (void)playSlot:(NSInteger)slot {
    NSString *path = (slot == 1) ? @"/var/mobile/Media/DCIM/vcam.mp4"
                                 : [NSString stringWithFormat:@"/var/mobile/Media/DCIM/6/%ld.mp4", (long)slot];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] slot %ld source missing: %@ (set it in 设置 first)", (long)slot, path]);
        return;
    }
    // 路径变化 → mediaserverd 轮询自动重载; 若替换未开则同时开启
    [VCamNotify setActivePlaybackPath:path];
    [self resetOrientationState];  // 换源重置旋转/镜像(防残留角度与新视频元数据叠加翻转)
    [self updateMirrorButtonVisual];  // 镜像重置后同步边框状态
    if (![VCamNotify isPlistEnabled]) {
        [VCamNotify setPlistEnabled:YES];
        [[VCamCore sharedInstance] setEnabled:YES];
        [self updateReplaceButtonVisual];
    }
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] play slot %ld: %@", (long)slot, path]);
}

// 转: 顺时针旋转 90°
// 从 plist 读当前角度(单一事实源): SB 进程内存的 gpuProcessor 状态与
// mediaserverd(真正渲染的进程)可能不同步, 基于 SB 内存累加会导致角度跳变
- (void)rotateRightTapped {
    int oldAngle = (int)[VCamNotify plistRotation];
    int newAngle = (oldAngle + 90) % 360;
    [VCamNotify setPlistRotation:newAngle];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] rotation: %d -> %d (synced)", oldAngle, newAngle]);
}

#pragma mark - 用户画面变换(箭头/＋/−/复, 1.3.30)
// 语义: 箭头移动替换后的画面 —— 不需要先放大, 未放大也可自由移动,
// 画面移出的区域显示黑色; ＋放大/−缩小(0.5..4.0, 每次固定 10%, 缩小时四周露黑边);
// 复还原为未移动未缩放的原始画面。
// 通道: vc.plist userPanX/userPanY/userZoom → mediaserverd 轮询同步到 GPU 管线
// (预渲染黑底画布合成, 方向为屏幕语义: panX 正=画面右移, panY 正=画面下移)
static const double kVcamPanStep   = 0.05;   // 每次点击移动 5% 源宽(对齐安卓统一基数)
static const double kVcamZoomFactor = 1.10;  // 每次点击相对缩放 10%(1.3.34 用户要求
                                             // 步进 x2: 原 5% 太小; 仍用乘法步进保持
                                             // 高倍率时感知等幅)
static const double kVcamZoomMin  = 0.5;     // 最小缩小到一半(四周黑边)
static const double kVcamZoomMax  = 4.0;

static double vcamClamp(double v, double lo, double hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// dx/dy 归一化增量(屏幕语义): dx 正=画面右移, dy 正=画面下移
- (void)panByX:(double)dx Y:(double)dy {
    double nx = vcamClamp([VCamNotify plistPanX] + dx, -1.0, 1.0);
    double ny = vcamClamp([VCamNotify plistPanY] + dy, -1.0, 1.0);
    [VCamNotify setPlistPanX:nx];
    [VCamNotify setPlistPanY:ny];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] pan -> (%.2f, %.2f) (synced)", nx, ny]);
}

- (void)panLeftTapped  { [self panByX:-kVcamPanStep Y:0]; }  // 画面左移
- (void)panRightTapped { [self panByX: kVcamPanStep Y:0]; }  // 画面右移
- (void)panUpTapped    { [self panByX:0 Y:-kVcamPanStep]; }  // 画面上移
- (void)panDownTapped  { [self panByX:0 Y: kVcamPanStep]; }  // 画面下移

- (void)zoomInTapped {
    double nz = vcamClamp([VCamNotify plistZoom] * kVcamZoomFactor, kVcamZoomMin, kVcamZoomMax);
    [VCamNotify setPlistZoom:nz];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] zoom in -> %.2f (synced)", nz]);
}

- (void)zoomOutTapped {
    double nz = vcamClamp([VCamNotify plistZoom] / kVcamZoomFactor, kVcamZoomMin, kVcamZoomMax);
    [VCamNotify setPlistZoom:nz];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] zoom out -> %.2f (synced)", nz]);
}

// 复: 还原为最原始画面(未移动未缩放; 不动旋转/镜像 —— 那两个由"转/镜"管理)
- (void)resetTransformTapped {
    [VCamNotify resetPlistTransform];
    vcam_ball_log(@"[vcam][btn] transform reset (pan=0, zoom=1) (synced)");
}

// 镜: 镜像翻转(同样以 plist 为单一事实源)
- (void)mirrorTapped {
    BOOL newMirrored = ![VCamNotify plistMirrored];
    [VCamNotify setPlistMirrored:newMirrored];
    [self updateMirrorButtonVisual];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] mirror toggled -> %d (synced)", newMirrored]);
}

// 切视频时重置手动旋转/镜像: 残留的手动角度会与新视频自带的 preferredRotation
// 叠加, 产生意外的 180° 等翻转(换视频后画面倒立的根因)。新视频从元数据干净起点显示
// 1.3.30: 同步重置画面变换(pan/zoom), 新视频从原始全幅位置显示
- (void)resetOrientationState {
    [VCamNotify setPlistRotation:0];
    [VCamNotify setPlistMirrored:NO];
    [VCamNotify resetPlistTransform];
    [self updateMirrorButtonVisual];
    vcam_ball_log(@"[vcam][btn] orientation state reset (rotation=0, mirror=off, pan=0, zoom=1)");
}

#pragma mark - 视频选择(PHPicker 相册选择器)

- (void)selectVideoTapped { [self openPickerForSlot:0]; }
- (void)preset2Tapped     { [self openPickerForSlot:2]; }
- (void)preset3Tapped     { [self openPickerForSlot:3]; }

- (void)openPickerForSlot:(NSInteger)slot {
    _pickerSlot = slot;
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] open picker for slot %ld", (long)slot]);

    if (!NSClassFromString(@"PHPickerViewController")) {
        vcam_ball_log(@"[vcam] PHPickerViewController unavailable");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        // 不设 filter(SDK 15.6 无 +[PHPickerFilter videos] 便捷方法),
        // 选择完成后用 public.movie 类型校验, 非视频拒绝
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        // 从悬浮窗 rootViewController present, 保证显示在最顶层
        [self.overlayWindow.rootViewController presentViewController:picker
                                                            animated:YES
                                                          completion:nil];
    });
}

// 宽视频类型判定(1.3.25 修复"picked item is not a video"误拒):
// (1)public.movie / public.audiovisual-content(视频父类型) conforms 判定;
// (2)registeredTypeIdentifiers 里含 movie/video/mpeg-4/quicktime 的容器类型。
// PHPicker 的 itemProvider 拿到瞬间类型可能尚未异步注册完(hasItemConforming 返回 NO),
// 配合 caller 的延迟重查兜底
- (BOOL)providerLooksLikeVideo:(NSItemProvider *)provider {
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) return YES;
    if ([provider hasItemConformingToTypeIdentifier:@"public.audiovisual-content"]) return YES;
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([tid containsString:@"movie"] || [tid containsString:@"video"] ||
            [tid containsString:@"mpeg-4"] || [tid containsString:@"quicktime"]) {
            return YES;
        }
    }
    return NO;
}

// 按候选类型顺序加载 provider 文件表示: 前一类型失败(返回 nil url)自动尝试下一个
- (void)loadVideoFromProvider:(NSItemProvider *)provider candidates:(NSArray<NSString *> *)cands slot:(NSInteger)slot {
    __weak typeof(self) weakSelf = self;
    NSString *tid = cands.firstObject;
    [provider loadFileRepresentationForTypeIdentifier:tid
                                completionHandler:^(NSURL *url, NSError *error) {
        VCamFloatingBall *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!url) {
            vcam_ball_log([NSString stringWithFormat:@"[vcam] load type %@ failed: %@ (cands left %lu)",
                           tid, error, (unsigned long)(cands.count - 1)]);
            if (cands.count > 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf loadVideoFromProvider:provider
                                           candidates:[cands subarrayWithRange:NSMakeRange(1, cands.count - 1)]
                                                   slot:slot];
                });
            }
            return;
        }
        [strongSelf savePickedVideoAt:url toSlot:slot];
    }];
}

// copy 选中视频到目标槽位 + 槽位 0 时切为当前源
- (void)savePickedVideoAt:(NSURL *)srcUrl toSlot:(NSInteger)slot {
    // 目标路径: 0=vcam.mp4(当前选择) 2/3=6/N.mp4(预设槽位)
    // (SpringBoard 进程内写入, pathhook 重定向到 mediaserverd 实读的 /rootfs 路径)
    NSString *dest = (slot == 0) ? @"/var/mobile/Media/DCIM/vcam.mp4"
                   : [NSString stringWithFormat:@"/var/mobile/Media/DCIM/6/%ld.mp4", (long)slot];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent
   withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dest error:nil];
    NSError *copyErr = nil;
    BOOL ok = [fm copyItemAtPath:srcUrl.path toPath:dest error:&copyErr];
    vcam_ball_log([NSString stringWithFormat:@"[vcam] picker copy slot=%ld %@ -> %@ (%@)",
                   (long)slot, srcUrl.path, dest, ok ? @"OK" : [copyErr localizedDescription]]);

    // 选择视频(槽位 0): 切为当前源立即播放(路径变化由 mediaserverd 轮询检测重载)
    if (ok && slot == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamNotify setActivePlaybackPath:dest];
            [self resetOrientationState];  // 换源重置旋转/镜像(防残留角度叠加翻转)
            if (![VCamNotify isPlistEnabled]) {
                [VCamNotify setPlistEnabled:YES];
                [[VCamCore sharedInstance] setEnabled:YES];
                [self updateReplaceButtonVisual];
            }
            vcam_ball_log([NSString stringWithFormat:@"[vcam] active source switched: %@", dest]);
        });
    }
    // 预设槽位(2/3): 只存储, 由设置页预设按钮/控制页槽位键播放
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    NSItemProvider *provider = results.firstObject.itemProvider;
    NSInteger slot = _pickerSlot;

    if (![self providerLooksLikeVideo:provider]) {
        // 类型注册竞态兜底: provider 拿到瞬间类型标识可能未注册完,
        // 0.6s 后重查一次(1.3.25 前直接拒绝导致选视频"没反应")
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VCamFloatingBall *strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([strongSelf providerLooksLikeVideo:provider]) {
                vcam_ball_log(@"[vcam] video type appeared after retry (async registration race)");
                [strongSelf startVideoLoadFromProvider:provider slot:slot];
            } else {
                vcam_ball_log([NSString stringWithFormat:@"[vcam] picked item is not a video (types: %@)",
                               provider.registeredTypeIdentifiers]);
            }
        });
        return;
    }
    [self startVideoLoadFromProvider:provider slot:slot];
}

// 构造候选类型列表并开始加载(标准 movie 优先, 其余已注册 av 类型逐个兜底)
- (void)startVideoLoadFromProvider:(NSItemProvider *)provider slot:(NSInteger)slot {
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [cands addObject:@"public.movie"];
    }
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([cands containsObject:tid]) continue;
        if ([tid containsString:@"movie"] || [tid containsString:@"video"] ||
            [tid containsString:@"mpeg-4"] || [tid containsString:@"quicktime"]) {
            [cands addObject:tid];
        }
    }
    if (cands.count == 0) [cands addObject:@"public.movie"];
    [self loadVideoFromProvider:provider candidates:cands slot:slot];
}

#pragma mark - 频道链接

// 岐盛相机: 隐藏频道链接按钮
- (void)channelLinkTapped {
    vcam_ball_log(@"[vcam][btn] channel link tapped");
    NSURL *url = [NSURL URLWithString:VCS(tglink)];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

#pragma mark - 前后台切换

- (void)appDidBecomeActive:(NSNotification *)notification {
    vcam_ball_log(@"[vcam] App became active");

    dispatch_async(dispatch_get_main_queue(), ^{
        // 启动早期 scene 未连接时 window 未关联 scene（不可见），此时补建
        if (self->_isFloating && self.overlayWindow && self.overlayWindow.windowScene == nil) {
            vcam_ball_log(@"[vcam] window has no scene, recreating on didBecomeActive");
            [self.overlayWindow removeFromSuperview];
            self.overlayWindow = nil;
            [self createOverlayWindow];
        }
    });
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    vcam_ball_log(@"[vcam] App entered background");
}

@end
