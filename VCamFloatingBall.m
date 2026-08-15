//
//  VCamFloatingBall.m
//  VCamPlus
//
//  悬浮球 + 双页签面板(控制/设置), 灰色主题
//  只在 SpringBoard 中使用（需要 UIKit）
//
//  控制页: 选择视频 | 3x3 宫格(播 替/原 1 / ▶ 关 2 / 转 镜 3)
//  设置页: 预设视频2 / 预设视频3 / 岐盛相机(频道链接) / @QuGenttx 水印
//
//  跨进程控制(球在 SpringBoard, 播放器在 mediaserverd): 全部经 vc.plist
//    enabled(替/原) / activePlaybackPath(1/2/3) / paused(▶) /
//    restartToken(播) / manualRotation(转) / mirrored(镜)
//  mediaserverd 每秒轮询应用(VCamCore startStatePolling)
//

#import "VCamFloatingBall.h"
#import "VCamCore.h"
#import "VCamNotify.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

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

#pragma mark - 悬浮球视图(灰色)

@interface VCamBallView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation VCamBallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithRed:0.75 green:0.76 blue:0.78 alpha:1.0].CGColor;

        _label = [[UILabel alloc] initWithFrame:self.bounds];
        _label.text = @"VC";
        _label.textColor = [UIColor whiteColor];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.font = [UIFont boldSystemFontOfSize:14];
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_label];
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
@property (nonatomic, strong) UIButton *tabSettingsBtn;
@property (nonatomic, strong) UIView *controlPageView;
@property (nonatomic, strong) UIView *settingsPageView;
// 需要动态改标题的按钮
@property (nonatomic, strong) VCamPanelButton *replaceBtn;    // 替 ↔ 原
@property (nonatomic, strong) VCamPanelButton *playPauseBtn;  // ▶ ↔ ⏸
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isFloating;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) NSInteger pickerSlot;      // 0=选择视频(vcam.mp4) 2/3=预设槽位
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.overlayWindow removeFromSuperview];
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        self.ballView = nil;
        self.panelView = nil;
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
    return btn;
}

#pragma mark - 面板创建（双页签 + 灰色主题, 紧凑尺寸）

- (void)createPanel {
    CGFloat panelW = 198;
    CGFloat pad = 10;
    CGFloat contentW = panelW - pad * 2;                 // 178
    CGFloat tabH = 30;
    CGFloat pageTop = pad + tabH + 6;                    // 页面内容起始 y
    CGFloat rowH = 38;                                   // 整宽按钮高度
    CGFloat gap = 8;

    // 控制页内容高度: 选择视频(38) + 8 + 3 行宫格(40*3 + 7*2)
    CGFloat controlH = rowH + gap + 40 * 3 + 7 * 2;      // 174
    // 设置页内容高度: 3 个整宽按钮(38*3 + 8*2) + 10 + 水印(16)
    CGFloat settingsH = rowH * 3 + gap * 2 + 10 + 16;    // 154
    CGFloat panelH = pageTop + MAX(controlH, settingsH) + pad;

    _panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
    _panelView.backgroundColor = [self vcPanelBgColor];
    _panelView.layer.cornerRadius = 12;
    _panelView.layer.masksToBounds = YES;
    _panelView.alpha = 0;
    _panelView.hidden = YES;

    // ===== 页签行: 控制 | 设置 =====
    CGFloat tabW = 76;
    CGFloat tabGap = 8;
    CGFloat tabX0 = (panelW - (tabW * 2 + tabGap)) / 2;
    _tabControlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabControlBtn.frame = CGRectMake(tabX0, pad, tabW, tabH);
    [_tabControlBtn setTitle:@"控制" forState:UIControlStateNormal];  // 之前漏 setTitle 导致文字不显示
    _tabControlBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabControlBtn.layer.cornerRadius = 7;
    [_tabControlBtn addTarget:self action:@selector(controlTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabControlBtn];

    _tabSettingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabSettingsBtn.frame = CGRectMake(tabX0 + tabW + tabGap, pad, tabW, tabH);
    [_tabSettingsBtn setTitle:@"设置" forState:UIControlStateNormal];
    _tabSettingsBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabSettingsBtn.layer.cornerRadius = 7;
    [_tabSettingsBtn addTarget:self action:@selector(settingsTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabSettingsBtn];

    // ===== 控制页 =====
    _controlPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, controlH)];
    _controlPageView.backgroundColor = [UIColor clearColor];
    [_panelView addSubview:_controlPageView];

    // 选择视频(整宽)
    VCamPanelButton *selectBtn = [self makeButton:@"选择视频"
                                            frame:CGRectMake(pad, 0, contentW, rowH)
                                          selector:@selector(selectVideoTapped)];
    selectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_controlPageView addSubview:selectBtn];

    // 3x3 宫格
    CGFloat cellW = (contentW - gap * 2) / 3;            // 54
    CGFloat cellH = 40;
    CGFloat gridY0 = rowH + gap;
    NSString *gridTitles[3][3] = {
        { @"播", @"替", @"1" },
        { @"▶", @"关", @"2" },
        { @"转", @"镜", @"3" },
    };
    SEL gridSels[3][3] = {
        { @selector(restartVideoTapped), @selector(toggleReplacementTapped), @selector(slot1Tapped) },
        { @selector(playPauseTapped),     @selector(closePanelTapped),       @selector(slot2Tapped) },
        { @selector(rotateRightTapped),   @selector(mirrorTapped),           @selector(slot3Tapped) },
    };
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            CGRect f = CGRectMake(pad + c * (cellW + gap), gridY0 + r * (cellH + 7), cellW, cellH);
            VCamPanelButton *btn = [self makeButton:gridTitles[r][c] frame:f selector:gridSels[r][c]];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            [_controlPageView addSubview:btn];
            if (r == 0 && c == 1) _replaceBtn = btn;    // 替 ↔ 原
            if (r == 1 && c == 0) _playPauseBtn = btn;  // ▶ ↔ ⏸
        }
    }

    // ===== 设置页 =====
    _settingsPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, settingsH)];
    _settingsPageView.backgroundColor = [UIColor clearColor];
    [_panelView addSubview:_settingsPageView];

    VCamPanelButton *preset2 = [self makeButton:@"预设视频2"
                                          frame:CGRectMake(pad, 0, contentW, rowH)
                                        selector:@selector(preset2Tapped)];
    preset2.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset2];

    VCamPanelButton *preset3 = [self makeButton:@"预设视频3"
                                          frame:CGRectMake(pad, rowH + gap, contentW, rowH)
                                        selector:@selector(preset3Tapped)];
    preset3.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset3];

    // 岐盛相机: 隐藏频道链接按钮(跳转 Telegram)
    VCamPanelButton *channel = [self makeButton:@"岐盛相机"
                                          frame:CGRectMake(pad, (rowH + gap) * 2, contentW, rowH)
                                        selector:@selector(channelLinkTapped)];
    channel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:channel];

    // 水印
    UILabel *mark = [[UILabel alloc] initWithFrame:CGRectMake(pad, (rowH + gap) * 2 + rowH + 10, contentW, 16)];
    mark.text = @"@QuGenttx";
    mark.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    mark.textAlignment = NSTextAlignmentCenter;
    mark.font = [UIFont systemFontOfSize:11];
    [_settingsPageView addSubview:mark];

    // 初始页签 = 控制, 替/原标题按当前 enabled 状态
    _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self updateReplaceButtonTitle];

    // 面板先加, 悬浮球后加 → 球永远在面板上层, 即使重叠也能拖动/点击
    [_overlayWindow addSubview:_panelView];
}

- (void)refreshTabStyles {
    BOOL controlActive = !_settingsPageView.hidden;
    _tabControlBtn.backgroundColor = controlActive ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    _tabSettingsBtn.backgroundColor = controlActive ? [self vcTabInactiveColor] : [self vcTabActiveColor];
    [_tabControlBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_tabSettingsBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
}

#pragma mark - 页签切换

- (void)controlTabTapped {
    vcam_ball_log(@"[vcam][tab] control");
    _controlPageView.hidden = NO;
    _settingsPageView.hidden = YES;
    [self refreshTabStyles];
}

- (void)settingsTabTapped {
    vcam_ball_log(@"[vcam][tab] settings");
    _controlPageView.hidden = YES;
    _settingsPageView.hidden = NO;
    [self refreshTabStyles];
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

// ▶/⏸: 暂停/继续
- (void)playPauseTapped {
    _isPaused = !_isPaused;
    [VCamNotify setPlistPaused:_isPaused];
    [self.playPauseBtn setTitle:_isPaused ? @"⏸" : @"▶" forState:UIControlStateNormal];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] playPause -> %@", _isPaused ? @"paused" : @"playing"]);
}

// 替/原: 替换摄像头 ↔ 还原摄像头
- (void)toggleReplacementTapped {
    BOOL newEnabled = ![VCamNotify isPlistEnabled];
    [VCamNotify setPlistEnabled:newEnabled];
    [[VCamCore sharedInstance] setEnabled:newEnabled];
    [self updateReplaceButtonTitle];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] replace toggle -> %@", newEnabled ? @"replaced" : @"restored"]);
}

- (void)updateReplaceButtonTitle {
    BOOL en = [VCamNotify isPlistEnabled];
    [self.replaceBtn setTitle:en ? @"原" : @"替" forState:UIControlStateNormal];
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
    if (![VCamNotify isPlistEnabled]) {
        [VCamNotify setPlistEnabled:YES];
        [[VCamCore sharedInstance] setEnabled:YES];
        [self updateReplaceButtonTitle];
    }
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] play slot %ld: %@", (long)slot, path]);
}

// 转: 顺时针旋转 90°
- (void)rotateRightTapped {
    int oldAngle = [VCamCore sharedInstance].gpuProcessor.rotationAngle;
    int newAngle = (oldAngle + 90) % 360;
    [VCamCore sharedInstance].gpuProcessor.rotationAngle = newAngle;
    // 持久化到 vc.plist: mediaserverd(真正渲染替换画面的进程)轮询读取
    [VCamNotify setPlistRotation:newAngle];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] rotation: %d -> %d (synced)", oldAngle, newAngle]);
}

// 镜: 镜像翻转
- (void)mirrorTapped {
    BOOL oldMirrored = [VCamCore sharedInstance].gpuProcessor.mirrored;
    [VCamCore sharedInstance].gpuProcessor.mirrored = !oldMirrored;
    [VCamNotify setPlistMirrored:!oldMirrored];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] mirror toggled: %d -> %d (synced)", oldMirrored, !oldMirrored]);
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

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        vcam_ball_log(@"[vcam] picked item is not a video");
        return;
    }

    NSInteger slot = _pickerSlot;
    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                completionHandler:^(NSURL *url, NSError *error) {
        VCamFloatingBall *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!url) {
            vcam_ball_log([NSString stringWithFormat:@"[vcam] load video representation failed: %@", error]);
            return;
        }
        // 目标路径: 0=vcam.mp4(当前选择) 2/3=6/N.mp4(预设槽位)
        // (SpringBoard 进程内写入, pathhook 重定向到 mediaserverd 实读的 /rootfs 路径)
        NSString *dest = (slot == 0) ? @"/var/mobile/Media/DCIM/vcam.mp4"
                       : [NSString stringWithFormat:@"/var/mobile/Media/DCIM/6/%ld.mp4", (long)slot];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent
       withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:dest error:nil];
        NSError *copyErr = nil;
        BOOL ok = [fm copyItemAtPath:url.path toPath:dest error:&copyErr];
        vcam_ball_log([NSString stringWithFormat:@"[vcam] picker copy slot=%ld %@ -> %@ (%@)",
                       (long)slot, url.path, dest, ok ? @"OK" : [copyErr localizedDescription]]);

        // 选择视频(槽位 0): 切为当前源立即播放(路径变化由 mediaserverd 轮询检测重载)
        if (ok && slot == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [VCamNotify setActivePlaybackPath:dest];
                if (![VCamNotify isPlistEnabled]) {
                    [VCamNotify setPlistEnabled:YES];
                    [[VCamCore sharedInstance] setEnabled:YES];
                    [strongSelf updateReplaceButtonTitle];
                }
                vcam_ball_log([NSString stringWithFormat:@"[vcam] active source switched: %@", dest]);
            });
        }
        // 预设槽位(2/3): 只存储, 由控制页 2/3 键播放
    }];
}

#pragma mark - 频道链接

// 岐盛相机: 隐藏频道链接按钮
- (void)channelLinkTapped {
    vcam_ball_log(@"[vcam][btn] channel link tapped");
    NSURL *url = [NSURL URLWithString:@"https://t.me/XFrealtime2"];
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
