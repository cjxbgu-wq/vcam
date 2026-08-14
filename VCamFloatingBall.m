//
//  VCamFloatingBall.m
//  VCamPlus
//
//  对标 vcameracrack.dylib 的 VCamFloatingBall 实现
//  只在 SpringBoard 中使用（需要 UIKit）
//

#import "VCamFloatingBall.h"
#import "VCamCore.h"
#import "VCamNotify.h"
#import <UIKit/UIKit.h>

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

#pragma mark - 悬浮球视图

@interface VCamBallView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation VCamBallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.85];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor whiteColor].CGColor;

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

@interface VCamFloatingBall ()
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) VCamBallView *ballView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) NSMutableArray<VCamPanelButton *> *panelButtons;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isFloating;
@property (nonatomic, assign) NSInteger videoSlot;  // 当前视频槽位 (1/2/3)
@property (nonatomic, assign) BOOL loopEnabled;
@property (nonatomic, assign) CGPoint lastBallPosition;
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
        _videoSlot = 1;
        _loopEnabled = YES;
        _panelButtons = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)showFloatingBall {
    if (_isFloating) return;
    _isFloating = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self createOverlayWindow];
        vcam_ball_log(@"[vcam] Floating window created");
        vcam_ball_log(@"[vcam] Floating ball created");
    });

    // 监听前后台切换
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
        _overlayWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
        vcam_ball_log([NSString stringWithFormat:@"[vcam] overlay window attached to scene: %@", windowScene]);
    } else {
        _overlayWindow = [[UIWindow alloc] initWithFrame:screenBounds];
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
    _lastBallPosition = _ballView.center;

    // 点击手势
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTapped:)];
    [_ballView addGestureRecognizer:tapGesture];

    // 拖动手势
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballDragged:)];
    [_ballView addGestureRecognizer:panGesture];

    [_overlayWindow addSubview:_ballView];

    // 创建面板（初始隐藏）
    [self createPanel];
}

- (void)createPanel {
    CGFloat panelWidth = 60;
    CGFloat panelHeight = 50 * 6 + 10;  // 6 个按钮
    CGFloat panelX = _ballView.frame.origin.x - panelWidth - 10;
    CGFloat panelY = _ballView.frame.origin.y - (panelHeight - _ballView.frame.size.height) / 2;

    _panelView = [[UIView alloc] initWithFrame:CGRectMake(panelX, panelY, panelWidth, panelHeight)];
    _panelView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    _panelView.layer.cornerRadius = 12;
    _panelView.layer.masksToBounds = YES;
    _panelView.alpha = 0;
    _panelView.hidden = YES;

    // 6 个按钮（从上到下）
    NSArray *titles = @[@"播", @"循", @"转", @"翻", @"替", @"换"];
    NSArray *keys = @[@"restart", @"loop", @"rotate", @"mirror", @"replace", @"switch"];
    SEL selectors[] = {
        @selector(restartVideoTapped),
        @selector(toggleLoopTapped),
        @selector(rotateRightTapped),
        @selector(toggleMirrorTapped),
        @selector(toggleReplacementTapped),
        @selector(switchVideoTapped)
    };

    for (int i = 0; i < 6; i++) {
        VCamPanelButton *btn = [VCamPanelButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(5, 5 + i * 50, panelWidth - 10, 45);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        btn.titleLabel.textColor = [UIColor whiteColor];
        btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:0.7];
        btn.layer.cornerRadius = 10;
        btn.buttonKey = keys[i];
        btn.tag = i;
        [btn addTarget:self action:selectors[i] forControlEvents:UIControlEventTouchUpInside];
        [_panelView addSubview:btn];
        [_panelButtons addObject:btn];
    }

    [_overlayWindow addSubview:_panelView];
}

#pragma mark - 交互

- (void)ballTapped:(UITapGestureRecognizer *)gesture {
    vcam_ball_log(@"[vcam][ball] tap received, BGIntegrityOK=1 (diagnostic bypass active)");
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
    _lastBallPosition = newCenter;
    [gesture setTranslation:CGPointZero inView:_overlayWindow];

    // 同步面板位置（面板在悬浮球左侧）
    [self updatePanelPosition];
}

- (void)togglePanel {
    _panelVisible = !_panelVisible;
    if (_panelVisible) {
        _panelView.hidden = NO;
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
    CGFloat panelWidth = _panelView.frame.size.width;
    CGFloat panelHeight = _panelView.frame.size.height;
    CGFloat panelX = _ballView.frame.origin.x - panelWidth - 10;
    CGFloat panelY = _ballView.center.y - panelHeight / 2;

    // 限制在屏幕内
    panelX = MAX(5, panelX);
    panelY = MAX(5, MIN(_overlayWindow.frame.size.height - panelHeight - 5, panelY));

    _panelView.frame = CGRectMake(panelX, panelY, panelWidth, panelHeight);
}

#pragma mark - 6 键回调

- (void)restartVideoTapped {
    vcam_ball_log(@"[vcam][btn] restartVideoTapped fired");
    // 重新播放视频
    LocalVideoPlayer *player = [VCamCore sharedInstance].videoPlayer;
    if (player.currentVideoPath) {
        [player loadVideoAtPath:player.currentVideoPath completion:nil];
    }
}

- (void)toggleLoopTapped {
    vcam_ball_log(@"[vcam][btn] toggleLoopTapped fired");
    _loopEnabled = !_loopEnabled;
    // 通知 VCamCore 循环状态变化
    // 目前视频默认循环播放，这个按钮可以用于关闭循环
}

- (void)rotateRightTapped {
    int oldAngle = [VCamCore sharedInstance].gpuProcessor.rotationAngle;
    int newAngle = (oldAngle + 90) % 360;
    [VCamCore sharedInstance].gpuProcessor.rotationAngle = newAngle;
    // 持久化到 vc.plist: mediaserverd(真正渲染替换画面的进程)轮询读取,
    // 只改本进程(SpringBoard)的 rotationAngle 对相机替换无效
    [VCamNotify setPlistRotation:newAngle];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] rotation: %d -> %d (deg=%d, synced)", oldAngle, newAngle, newAngle]);
    vcam_ball_log(@"[vcam][btn] rotateRightTapped fired");
}

- (void)toggleMirrorTapped {
    BOOL oldMirrored = [VCamCore sharedInstance].gpuProcessor.mirrored;
    [VCamCore sharedInstance].gpuProcessor.mirrored = !oldMirrored;
    // 持久化到 vc.plist 供 mediaserverd 轮询(同 rotateRightTapped)
    [VCamNotify setPlistMirrored:!oldMirrored];
    vcam_ball_log([NSString stringWithFormat:@"[vcam][btn] mirror toggled: %d -> %d (synced)", oldMirrored, !oldMirrored]);
}

- (void)toggleReplacementTapped {
    vcam_ball_log(@"[vcam][btn] toggleReplacementTapped, BGIntegrityOK=1 (diagnostic bypass)");
    VCamCore *core = [VCamCore sharedInstance];
    BOOL newEnabled = !core.enabled;
    [VCamNotify setPlistEnabled:newEnabled];
    [core setEnabled:newEnabled];
}

- (void)switchVideoTapped {
    vcam_ball_log(@"[vcam][btn] switchVideoTapped, BGIntegrityOK=1 (diagnostic bypass)");
    // 切换视频槽位: 1 -> 2 -> 3 -> 1
    _videoSlot = (_videoSlot % 3) + 1;

    NSString *videoPath;
    if (_videoSlot == 1) {
        videoPath = @"/var/mobile/Media/DCIM/vcam.mp4";
    } else {
        videoPath = [NSString stringWithFormat:@"/var/mobile/Media/DCIM/6/%ld.mp4", (long)_videoSlot];
    }

    [VCamNotify setActivePlaybackPath:videoPath];
    [[VCamNotify sharedInstance] postNotification:VCamNotifyReloadMedia];
    vcam_ball_log([NSString stringWithFormat:@"[vcam] Switching active source to: %@", videoPath]);
}

#pragma mark - 前后台切换

- (void)appDidBecomeActive:(NSNotification *)notification {
    // app 前台显示时，桌面悬浮窗隐藏
    // 但 app 内悬浮窗保持显示
    vcam_ball_log(@"[vcam] App became active");

    // 启动早期 scene 未连接时 window 未关联 scene（不可见），此时补建
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_isFloating && self.overlayWindow && self.overlayWindow.windowScene == nil) {
            vcam_ball_log(@"[vcam] window has no scene, recreating on didBecomeActive");
            [self.overlayWindow removeFromSuperview];
            self.overlayWindow = nil;
            [self createOverlayWindow];
        }
    });
}

- (void)appDidEnterBackground:(NSNotification *)notification {
    // app 后台时，桌面悬浮窗显示
    vcam_ball_log(@"[vcam] App entered background");
}

@end
