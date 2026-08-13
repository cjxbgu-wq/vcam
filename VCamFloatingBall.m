#import "VCamFloatingBall.h"
#import "VCamCore.h"

@interface VCamFloatingBall ()
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIButton *replaceBtn;
@property (nonatomic, strong) UIButton *rotateBtn;
@property (nonatomic, strong) UIButton *mirrorBtn;
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
    self = [super initWithFrame:CGRectMake(0, 0, 50, 50)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        self.layer.cornerRadius = 25;
        self.layer.masksToBounds = YES;
        self.clipsToBounds = YES;
        [self setupGestures];
    }
    return self;
}

- (void)setupGestures {
    // 点击：切换替换
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    [self addGestureRecognizer:tap];

    // 拖动：移动位置
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self addGestureRecognizer:pan];
}

#pragma mark - 显示/隐藏

- (void)showAsOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.overlayWindow && !self.overlayWindow.hidden) return;

        // 创建独立 UIWindow（确保在所有 app 上层）
        if (!self.overlayWindow) {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
            if (scene) {
                self.overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
            } else {
                self.overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
            self.overlayWindow.windowLevel = UIWindowLevelAlert + 1000;
            self.overlayWindow.rootViewController = [[UIViewController alloc] init];
            self.overlayWindow.backgroundColor = [UIColor clearColor];
            self.overlayWindow.userInteractionEnabled = YES;
        }

        // 定位到右侧中间
        CGFloat x = [UIScreen mainScreen].bounds.size.width - 60;
        CGFloat y = [UIScreen mainScreen].bounds.size.height / 2 - 25;
        self.frame = CGRectMake(x, y, 50, 50);

        [self.overlayWindow addSubview:self];
        self.overlayWindow.hidden = NO;
        NSLog(@"[vcam] Floating ball shown as overlay");
    });
}

- (void)hideFloatingBall {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow.hidden = YES;
    });
}

#pragma mark - 手势处理

- (void)onTap {
    // 切换替换开关
    VCamCore *core = [VCamCore sharedInstance];
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"] ?: @{}];
    config[@"enabled"] = @(!core.enabled);
    [config writeToFile:@"/var/mobile/Media/DCIM/vc.plist" atomically:YES];
    NSLog(@"[vcam] toggleReplacementTapped, enabled=%d", !core.enabled);
}

- (void)onPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.superview];
}

@end
