#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Common.h"

// 应用锁 —— App 自身进程内的“遮屏”
// 只负责一件事：这个 App 被勾选为加锁时，退到后台（含打开多任务界面）就在它自己的窗口上盖一张不透明的灰卡，
// 系统给多任务卡片拍照时拍到的就是这张灰卡；回到前台就撤掉（验证已在 SpringBoard 先做过）。
// 1.1 起：App 进程读不到设置页那份名单（沙盒限制），状态由 SpringBoard 写进本 App 自己的容器。
// 1.4：按用户要求改成整张不透明灰卡——边缘不再露出任何内容，也不再隐约能看见字。

static UIView *gAPLOverlay = nil;

#pragma mark - 读状态

static NSString *const kAPLStateFileName = @"com.applock.state.plist";
static NSString *const kAPLGlobalPrefsPath = @"/var/mobile/Library/Preferences/com.applock.state.plist";
static NSString *const kAPLGlobalTmpPath = @"/private/var/tmp/com.applock.state.plist";

static NSDictionary *APLOwnState(void) {
    NSString *library = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSString *path = [[library stringByAppendingPathComponent:@"Preferences"] stringByAppendingPathComponent:kAPLStateFileName];
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:path];
    return [state isKindOfClass:[NSDictionary class]] ? state : nil;
}

static NSDictionary *APLGlobalState(NSString *path) {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:path];
    return [state isKindOfClass:[NSDictionary class]] ? state : nil;
}

static NSArray *APLListViaCFPreferences(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("switchIsEnabled"), CFSTR("com.applock.prefs"));
    NSArray *result = nil;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFArrayGetTypeID()) {
            result = [(__bridge NSArray *)value copy];
        }
        CFRelease(value);
    }
    return result;
}

static NSArray *APLListViaFile(void) {
    NSArray *dirs = @[ @"/var/mobile/Library/Preferences", @"/var/jb/var/mobile/Library/Preferences" ];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:@"com.applock.prefs.plist"];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        id value = dict[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
        if ([value isKindOfClass:[NSArray class]]) return value;
    }
    return nil;
}

static BOOL APLShouldProtectSelf(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

    NSDictionary *ownState = APLOwnState();
    if (ownState != nil) {
        return [ownState[@"locked"] boolValue];
    }

    for (NSString *path in @[ kAPLGlobalTmpPath, kAPLGlobalPrefsPath ]) {
        NSDictionary *global = APLGlobalState(path);
        if (global == nil) continue;
        NSDictionary *apps = global[@"apps"];
        if (![apps isKindOfClass:[NSDictionary class]]) continue;
        id value = bundleID ? apps[bundleID] : nil;
        if ([value isKindOfClass:[NSNumber class]]) {
            return [value boolValue];
        }
    }

    NSArray *locked = APLListViaCFPreferences();
    if (locked == nil) locked = APLListViaFile();
    if (![locked isKindOfClass:[NSArray class]]) return NO;
    if (!bundleID.length) return NO;
    return [locked containsObject:bundleID];
}

#pragma mark - 盖/撤

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
    UIView *overlay = gAPLOverlay;
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

    UIView *cover = [[UIView alloc] initWithFrame:window.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.userInteractionEnabled = YES;
    // 整张不透明灰卡：不透明就代表底下任何内容都不会透出来，包括四角边缘的字
    cover.backgroundColor = [UIColor colorWithRed:0.42 green:0.42 blue:0.44 alpha:1.0];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"AppLock 已锁定";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:26];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:title];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectZero];
    tip.text = @"需要面容或密码验证";
    tip.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    tip.font = [UIFont systemFontOfSize:15];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:tip];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor constant:-14],
        [tip.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [tip.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
    ]];

    [window addSubview:cover];
    gAPLOverlay = cover;
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
