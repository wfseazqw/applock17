#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Common.h"

// 应用锁 —— App 自身进程内的“糊屏”
// 只负责一件事：这个 App 被勾选为加锁时，退到后台（含打开多任务界面）就在它自己的窗口上盖一层毛玻璃，
// 系统给多任务卡片拍照时拍到的就是这层糊图；回到前台就撤掉（验证已在 SpringBoard 先做过）。
// 2.0.3 正式版：
//   App 进程被沙盒限制，读不到设置页那份名单（com.applock.prefs 三种读法实测都拿不到），
//   所以改由 SpringBoard 把“锁/不锁”写进每个 App 自己的容器，App 只读自己的文件。

static UIVisualEffectView *gAPLOverlay = nil;

#pragma mark - 读状态

static NSString *const kAPLStateFileName = @"com.applock.state.plist";
static NSString *const kAPLGlobalPrefsPath = @"/var/mobile/Library/Preferences/com.applock.state.plist";
static NSString *const kAPLGlobalTmpPath = @"/private/var/tmp/com.applock.state.plist";

// 自己容器里的状态（SpringBoard 写的，沙盒内一定读得到）
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

#pragma mark - 名单兜底（正常用不到，容器状态读不到时才走）

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

static NSArray *APLListViaNSUserDefaults(void) {
    id value = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED][BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [value isKindOfClass:[NSArray class]] ? value : nil;
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

static NSNumber *APLMasterViaCFPreferences(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("isTweakEnabled"), CFSTR("com.applock.prefs.isTweakOn"));
    NSNumber *result = nil;
    if (value != NULL) {
        CFTypeID type = CFGetTypeID(value);
        if (type == CFBooleanGetTypeID()) {
            result = @(CFBooleanGetValue((CFBooleanRef)value));
        } else if (type == CFNumberGetTypeID()) {
            int number = 0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
            result = @(number != 0);
        }
        CFRelease(value);
    }
    return result;
}

#pragma mark - 判定

// 这个 App 现在要不要糊屏
// 1) 自己容器里的状态文件（SpringBoard 写的，最可靠的通道）
// 2) tmp / 偏好目录里的全局状态
// 3) 都读不到才退回原来的跨域读法
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
    if (locked == nil) locked = APLListViaNSUserDefaults();
    if (locked == nil) locked = APLListViaFile();
    if (![locked isKindOfClass:[NSArray class]]) return NO;

    NSNumber *master = APLMasterViaCFPreferences();
    if (master != nil && ![master boolValue]) return NO;
    if (!bundleID.length) return NO;
    return [locked containsObject:bundleID];
}

#pragma mark - 糊屏

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
