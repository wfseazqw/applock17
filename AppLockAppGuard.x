#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>

// 应用锁 —— App 自身进程内的保护
// 逻辑：被注入到这个 App，就说明它被用户勾选为“加锁”。
//   1. App 退到后台/失去活跃（包括打开多任务界面）时，立刻在 App 自己的界面上盖一层毛玻璃，
//      系统给多任务卡片拍照时拍到的就是这层糊图，卡片上看不到内容。
//   2. App 回到前台时，先弹面容/密码；验证通过才撤掉毛玻璃，验证不通过就一直糊着，并提供“点一下重新验证”。

static UIVisualEffectView *gAPLOverlay = nil;
static BOOL gAPLAuthRunning = NO;
static BOOL gAPLNeedLock = NO;

static void APLRequestAuth(void);

static UIWindow *APLTopWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

static void APLRemoveOverlay(void) {
    if (gAPLOverlay == nil) return;
    UIVisualEffectView *overlay = gAPLOverlay;
    gAPLOverlay = nil;
    [UIView animateWithDuration:0.15 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

static void APLShowOverlay(void) {
    UIWindow *window = APLTopWindow();
    if (window == nil) return;
    if (gAPLOverlay != nil) {
        // 已在糊着，跟着窗口尺寸走就行
        gAPLOverlay.frame = window.bounds;
        return;
    }

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    blur.frame = window.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = YES;

    UIView *dim = [[UIView alloc] initWithFrame:blur.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [blur.contentView addSubview:dim];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"AppLock 已锁定";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:26];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [blur.contentView addSubview:title];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectZero];
    tip.text = @"需要面容或密码验证";
    tip.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    tip.font = [UIFont systemFontOfSize:15];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    [blur.contentView addSubview:tip];

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"验证" forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [retry setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    retry.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    retry.layer.cornerRadius = 22;
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [retry addAction:[UIAction actionWithHandler:^(UIAction *action) {
        APLRequestAuth();
    }] forControlEvents:UIControlEventTouchUpInside];
    [blur.contentView addSubview:retry];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor constant:-30],
        [tip.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
        [tip.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [retry.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
        [retry.topAnchor constraintEqualToAnchor:tip.bottomAnchor constant:24],
        [retry.widthAnchor constraintEqualToConstant:132],
        [retry.heightAnchor constraintEqualToConstant:44],
    ]];

    blur.alpha = 1.0;
    [window addSubview:blur];
    gAPLOverlay = blur;
}

static void APLRequestAuth(void) {
    if (gAPLAuthRunning) return;
    gAPLAuthRunning = YES;

    LAContext *context = [[LAContext alloc] init];
    context.localizedFallbackTitle = @"输入密码";
    NSError *error = nil;
    BOOL canUse = [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error];

    if (!canUse) {
        gAPLAuthRunning = NO;
        return;
    }

    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"解锁 AppLock"
                      reply:^(BOOL success, NSError *authError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gAPLAuthRunning = NO;
            if (success) {
                gAPLNeedLock = NO;
                APLRemoveOverlay();
            }
            // 失败就保持糊着，用户可点“验证”重试
        });
    }];
}

static void APLHandleResignActive(void) {
    gAPLNeedLock = YES;
    APLShowOverlay();
}

static void APLHandleBecomeActive(void) {
    if (!gAPLNeedLock) return;
    APLShowOverlay();
    APLRequestAuth();
}

__attribute__((constructor)) static void APLAppGuardInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleID == nil) return;
        if ([bundleID isEqualToString:@"com.apple.springboard"]) return;
        if ([bundleID isEqualToString:@"com.apple.Preferences"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                             object:nil
                                                              queue:[NSOperationQueue mainQueue]
                                                         usingBlock:^(NSNotification *note) {
                APLHandleResignActive();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                             object:nil
                                                              queue:[NSOperationQueue mainQueue]
                                                         usingBlock:^(NSNotification *note) {
                APLHandleBecomeActive();
            }];
        });
    }
}
