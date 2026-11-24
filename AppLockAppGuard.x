#import <UIKit/UIKit.h>
#import "Common.h"

// 应用锁 —— App 自身进程内的“糊屏”
// 只负责一件事：这个 App 被勾选为加锁时，退到后台（含打开多任务界面）就在它自己的窗口上盖一层毛玻璃，
// 系统给多任务卡片拍照时拍到的就是这层糊图；回到前台就撤掉（验证已在 SpringBoard 先做过）。
// 2.0.0：改为“全 App 注入 + 运行时读名单判断”，不再依赖改写注入名单（RootHide 下无写权限）。

static UIVisualEffectView *gAPLOverlay = nil;

// 总开关 + 当前 App 是否在勾选名单里
static BOOL APLShouldProtectSelf(void) {
    NSDictionary *masterDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    if (![masterDefaults[TWEAK_SPECIFIER_KEY] boolValue]) return NO;

    NSDictionary *listDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *locked = listDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    if (![locked isKindOfClass:[NSArray class]]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID.length) return NO;
    return [locked containsObject:bundleID];
}

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
    [UIView animateWithDuration:0.12 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

static void APLShowOverlay(void) {
    if (!APLShouldProtectSelf()) return;

    UIWindow *window = APLTopWindow();
    if (window == nil) return;
    if (gAPLOverlay != nil) {
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

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor constant:-14],
        [tip.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor],
        [tip.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
    ]];

    blur.alpha = 1.0;
    [window addSubview:blur];
    gAPLOverlay = blur;
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
                APLShowOverlay();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                             object:nil
                                                              queue:[NSOperationQueue mainQueue]
                                                         usingBlock:^(NSNotification *note) {
                APLShowOverlay();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                             object:nil
                                                              queue:[NSOperationQueue mainQueue]
                                                         usingBlock:^(NSNotification *note) {
                APLRemoveOverlay();
            }];
        });
    }
}
