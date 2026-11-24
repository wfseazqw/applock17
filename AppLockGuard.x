#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "Common.h"

// 这套逻辑跑在「被锁的那个 App 自己」的进程里：
// 1) App 退到后台前，先把画面盖成模糊，系统截的那张多任务卡片就是模糊的；
// 2) App 再从后台回到前台、或冷启动时，必须验证身份才把模糊层撤掉。

static BOOL APLPrefBool(NSString *domain, NSString *key) {
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:domain];
    return [defaults[key] boolValue];
}

static BOOL APLIsLockedBundle(NSString *bundleID) {
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *lockedBundleIDs = defaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [lockedBundleIDs isKindOfClass:[NSArray class]] && [lockedBundleIDs containsObject:bundleID];
}

// 只有「普通 App 进程 + 总开关开着 + 自己被勾选锁定」这一种情况才动手
static BOOL APLShouldGuard(void) {
    if (NSClassFromString(@"UIApplication") == nil) return NO;
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *packageType = mainBundle.infoDictionary[@"CFBundlePackageType"];
    if (![packageType isEqualToString:@"APPL"]) return NO;
    NSString *bundleID = mainBundle.bundleIdentifier;
    if (!bundleID.length) return NO;

    // 总开关所在的域在部分 App 沙盒里可能读不到，读不到就按「开启」算，避免整个功能静默失效
    NSDictionary *tweakDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    NSNumber *tweakEnabled = tweakDefaults[TWEAK_SPECIFIER_KEY];
    BOOL isTweakOn = (tweakEnabled == nil) ? YES : [tweakEnabled boolValue];

    return isTweakOn && APLIsLockedBundle(bundleID);
}

#pragma mark - 临时自检

static BOOL gDiagShown = NO;

static NSString *APLDiagText(void) {
    NSMutableString *text = [NSMutableString string];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    [text appendFormat:@"注入: OK\nApp: %@\n", bundleID ?: @"?"];
    [text appendFormat:@"进程类型: %@\n", [[NSBundle mainBundle] infoDictionary][@"CFBundlePackageType"] ?: @"?"];

    NSDictionary *tweakDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    id tweakValue = tweakDefaults[TWEAK_SPECIFIER_KEY];
    [text appendFormat:@"总开关域: %@ (%@)\n",
        tweakDefaults ? @"读到" : @"读不到",
        tweakValue ? [tweakValue stringValue] : @"-"];

    NSDictionary *lockDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *list = lockDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    if ([list isKindOfClass:[NSArray class]]) {
        NSArray *preview = list.count > 4 ? [list subarrayWithRange:NSMakeRange(0, 4)] : list;
        [text appendFormat:@"锁定名单: %lu 个\n%@%@\n",
            (unsigned long)list.count,
            [preview componentsJoinedByString:@"\n"],
            list.count > 4 ? @"\n..." : @""];
        [text appendFormat:@"本 App 在名单里: %@\n", [list containsObject:bundleID] ? @"是" : @"否"];
    } else {
        [text appendString:@"锁定名单: 读不到\n"];
    }

    [text appendFormat:@"最终判断: %@", APLShouldGuard() ? @"加锁" : @"不加锁"];
    return text;
}

#pragma mark - 遮挡画面

@interface APLCoverViewController : UIViewController
@property (nonatomic, copy) void (^onRetry)(void);
@end

@implementation APLCoverViewController {
    UIVisualEffectView *_blurView;
    UIView *_cardView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIButton *_retryButton;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _blurView.frame = self.view.bounds;
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_blurView];

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_cardView];

    UIImageView *lockView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
    lockView.tintColor = [UIColor whiteColor];
    lockView.contentMode = UIViewContentModeScaleAspectFit;
    lockView.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardView addSubview:lockView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"已锁定";
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:24];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardView addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _subtitleLabel.text = @"验证身份后继续使用";
    _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    _subtitleLabel.font = [UIFont systemFontOfSize:15];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardView addSubview:_subtitleLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_retryButton setTitle:@"验证身份" forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_retryButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    _retryButton.backgroundColor = [UIColor whiteColor];
    _retryButton.layer.cornerRadius = 14;
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_retryButton addTarget:self action:@selector(handleRetry) forControlEvents:UIControlEventTouchUpInside];
    [_cardView addSubview:_retryButton];

    [NSLayoutConstraint activateConstraints:@[
        [_cardView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_cardView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_cardView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],

        [lockView.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:4],
        [lockView.centerXAnchor constraintEqualToAnchor:_cardView.centerXAnchor],
        [lockView.widthAnchor constraintEqualToConstant:44],
        [lockView.heightAnchor constraintEqualToConstant:44],

        [_titleLabel.topAnchor constraintEqualToAnchor:lockView.bottomAnchor constant:14],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor],

        [_retryButton.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:22],
        [_retryButton.centerXAnchor constraintEqualToAnchor:_cardView.centerXAnchor],
        [_retryButton.widthAnchor constraintEqualToConstant:132],
        [_retryButton.heightAnchor constraintEqualToConstant:44],
        [_retryButton.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-4]
    ]];
}

-(void)handleRetry {
    if (self.onRetry) self.onRetry();
}

@end

#pragma mark - 守卫

@interface APLGuard : NSObject
@property (nonatomic, assign) BOOL needAuth;
@property (nonatomic, assign) BOOL authenticating;
@property (nonatomic, strong) UIWindow *coverWindow;
+ (instancetype)shared;
-(void)attachToScene:(UIWindowScene *)scene;
-(void)raiseCover;
-(void)dropCover;
-(void)beginAuthentication;
@end

@implementation APLGuard

+ (instancetype)shared {
    static APLGuard *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[APLGuard alloc] init];
        instance.needAuth = YES;
    });
    return instance;
}

-(UIWindowScene *)currentScene {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState != UISceneActivationStateUnattached) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.windowScene) return window.windowScene;
    }
    return nil;
}

-(void)attachToScene:(UIWindowScene *)scene {
    if (!scene) return;
    if (!self.coverWindow) {
        APLCoverViewController *coverVC = [[APLCoverViewController alloc] init];
        __weak typeof(self) weakSelf = self;
        coverVC.onRetry = ^{
            [weakSelf beginAuthentication];
        };
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.windowLevel = UIWindowLevelAlert - 1;
        window.rootViewController = coverVC;
        self.coverWindow = window;
    }
    self.coverWindow.frame = scene.coordinateSpace.bounds;
    self.coverWindow.hidden = NO;
}

-(void)raiseCover {
    if (!self.coverWindow) {
        [self attachToScene:[self currentScene]];
        if (!self.coverWindow) return;
    }
    self.coverWindow.hidden = NO;
}

-(void)dropCover {
    self.coverWindow.hidden = YES;
}

-(void)beginAuthentication {
    if (self.authenticating) return;

    BOOL isBiometricsEnabled = APLPrefBool(USER_DEFAULTS_DOMAIN, BIOMETRICS_SPECIFIER_KEY);
    BOOL isPasscodeEnabled = APLPrefBool(USER_DEFAULTS_DOMAIN, PASSCODE_SPECIFIER_KEY);

    // 两种验证都没开：宁可放行，也不能把 App 锁死
    if (!isBiometricsEnabled && !isPasscodeEnabled) {
        self.needAuth = NO;
        [self dropCover];
        return;
    }

    self.authenticating = YES;
    __weak typeof(self) weakSelf = self;

    if (isBiometricsEnabled) {
        LAContext *context = [[LAContext alloc] init];
        NSError *policyError = nil;
        if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&policyError]) {
            [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                      localizedReason:@"验证身份以打开应用"
                                reply:^(BOOL success, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.authenticating = NO;
                    if (success) {
                        weakSelf.needAuth = NO;
                        [weakSelf dropCover];
                    } else if (isPasscodeEnabled) {
                        [weakSelf promptPasscode:YES];
                    }
                });
            }];
            return;
        }
    }

    self.authenticating = NO;
    [self promptPasscode:NO];
}

-(void)promptPasscode:(BOOL)isRetry {
    NSString *storedPasscode = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_PASSCODE] objectForKey:BUNDLE_DEFAULTS_PASSCODE_KEY];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用已锁定"
                                                                  message:isRetry ? @"密码不正确，请重新输入" : @"请输入密码"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.secureTextEntry = YES;
        textField.placeholder = @"密码";
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *input = alert.textFields.firstObject.text;
        if (storedPasscode && [input isEqualToString:storedPasscode]) {
            weakSelf.needAuth = NO;
            [weakSelf dropCover];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf promptPasscode:YES];
            });
        }
    }]];

    UIViewController *presenter = self.coverWindow.rootViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Hooks

static BOOL gGuardEnabled = NO;

static void APLShowDiagIfNeeded(void) {
    if (gDiagShown) return;
    gDiagShown = YES;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用锁 自检（临时）"
                                                                  message:APLDiagText()
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];

    UIViewController *presenter = nil;
    APLGuard *guard = [APLGuard shared];
    if (guard.coverWindow && !guard.coverWindow.hidden) {
        presenter = guard.coverWindow.rootViewController;
    } else {
        presenter = [UIApplication sharedApplication].keyWindow.rootViewController;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void APLInstallNotifications(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (gGuardEnabled) [[APLGuard shared] raiseCover];
    }];

    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (!gGuardEnabled) return;
        APLGuard *guard = [APLGuard shared];
        guard.needAuth = YES;
        [guard raiseCover];
    }];

    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        APLShowDiagIfNeeded();
        if (!gGuardEnabled) return;
        APLGuard *guard = [APLGuard shared];
        if (guard.needAuth) {
            [guard beginAuthentication];
        } else {
            [guard dropCover];
        }
    }];
}

%group APLGuardGroup

%hook UIWindow

-(void)makeKeyAndVisible {
    %orig;
    if (gGuardEnabled && self.windowLevel == UIWindowLevelNormal) {
        [[APLGuard shared] attachToScene:self.windowScene];
    }
}

%end

%hook NSBundle

// 被锁的第三方 App 通常没写面容 ID 的用途说明，补一条进去，否则系统拒绝弹验证
-(id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSFaceIDUsageDescription"]) {
        return @"验证身份以打开应用";
    }
    return %orig;
}

%end

%end

%ctor {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleID = mainBundle.bundleIdentifier;
    BOOL isAppProcess = [mainBundle.infoDictionary[@"CFBundlePackageType"] isEqualToString:@"APPL"]
        && bundleID.length
        && ![bundleID hasPrefix:@"com.apple."];

    if (isAppProcess) {
        gGuardEnabled = APLShouldGuard();
        APLInstallNotifications();
        if (gGuardEnabled) {
            %init(APLGuardGroup);
        }
    }
}
