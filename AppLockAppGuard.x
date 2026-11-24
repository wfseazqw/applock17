#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Common.h"

// 应用锁 —— App 自身进程内的“糊屏”
// 只负责一件事：这个 App 被勾选为加锁时，退到后台（含打开多任务界面）就在它自己的窗口上盖一层毛玻璃，
// 系统给多任务卡片拍照时拍到的就是这层糊图；回到前台就撤掉（验证已在 SpringBoard 先做过）。
// 2.0.1：全 App 注入后，App 进程内到底读不读得到勾选名单，用一个自检小面板直接显示出来，不再靠猜。

static UIVisualEffectView *gAPLOverlay = nil;
static UILabel *gAPLDiagLabel = nil;

#pragma mark - 三种读法

static NSString *const kAPLMasterDomain = @"com.applock.prefs.isTweakOn";
static NSString *const kAPLListDomain = @"com.applock.prefs";

static NSArray *APLListViaNSUserDefaults(void) {
    id value = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kAPLListDomain][BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSNumber *APLMasterViaNSUserDefaults(void) {
    id value = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kAPLMasterDomain][TWEAK_SPECIFIER_KEY];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSArray *APLListViaCFPreferences(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("switchIsEnabled"), (__bridge CFStringRef)kAPLListDomain);
    NSArray *result = nil;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFArrayGetTypeID()) {
            result = [(__bridge NSArray *)value copy];
        }
        CFRelease(value);
    }
    return result;
}

static NSNumber *APLMasterViaCFPreferences(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("isTweakEnabled"), (__bridge CFStringRef)kAPLMasterDomain);
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

// 直接读文件：给自检面板用，同时作为最后的兜底读法
static NSString *gAPLReadPath = nil;

static NSDictionary *APLReadPlistFile(NSString *domain) {
    NSArray *dirs = @[ @"/var/mobile/Library/Preferences",
                       @"/var/jb/var/mobile/Library/Preferences" ];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:[domain stringByAppendingString:@".plist"]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict == nil) continue;
        if (gAPLReadPath == nil) gAPLReadPath = path;
        return dict;
    }
    return nil;
}

static NSArray *APLListViaFile(void) {
    id value = APLReadPlistFile(kAPLListDomain)[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSNumber *APLMasterViaFile(void) {
    id value = APLReadPlistFile(kAPLMasterDomain)[TWEAK_SPECIFIER_KEY];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

#pragma mark - 判定

// 总开关 + 当前 App 是否在勾选名单里（三种读法任意一种读出来就算数，越靠前越可信）
static BOOL APLShouldProtectSelf(void) {
    NSArray *locked = APLListViaCFPreferences();
    if (locked == nil) locked = APLListViaNSUserDefaults();
    if (locked == nil) locked = APLListViaFile();

    NSNumber *master = APLMasterViaCFPreferences();
    if (master == nil) master = APLMasterViaNSUserDefaults();
    if (master == nil) master = APLMasterViaFile();
    if (master != nil && ![master boolValue]) return NO;

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID.length) return NO;
    if (![locked isKindOfClass:[NSArray class]]) return NO;
    return [locked containsObject:bundleID];
}

#pragma mark - 自检面板

static NSString *APLYesNo(BOOL value) {
    return value ? @"读到了" : @"没读到";
}

static NSString *APLDiagText(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(无)";

    NSArray *cfList = APLListViaCFPreferences();
    NSArray *udList = APLListViaNSUserDefaults();
    NSArray *fileList = APLListViaFile();

    NSNumber *cfMaster = APLMasterViaCFPreferences();
    NSNumber *udMaster = APLMasterViaNSUserDefaults();

    NSArray *effective = cfList ?: udList ?: fileList;
    BOOL hit = [effective isKindOfClass:[NSArray class]] && [effective containsObject:bundleID];

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"AppLock 2.0.1 自检\n本App：%@\n", bundleID];
    [text appendFormat:@"总开关 CF:%@ NS:%@\n", cfMaster ? (cfMaster.boolValue ? @"1" : @"0") : @"—",
                                            udMaster ? (udMaster.boolValue ? @"1" : @"0") : @"—"];
    [text appendFormat:@"名单 CF:%@(%lu) NS:%@(%lu) 文件:%@(%lu)\n",
        APLYesNo(cfList != nil), (unsigned long)cfList.count,
        APLYesNo(udList != nil), (unsigned long)udList.count,
        APLYesNo(fileList != nil), (unsigned long)fileList.count];
    if ([effective isKindOfClass:[NSArray class]] && effective.count) {
        [text appendFormat:@"内容：%@\n", [effective componentsJoinedByString:@", "]];
    }
    [text appendFormat:@"文件路径：%@\n本App在名单：%@ → 糊屏%@", gAPLReadPath ?: @"(无)",
        hit ? @"是" : @"否", hit ? @"开" : @"关"];
    return text;
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

static void APLUpdateDiagPanel(void) {
    UIWindow *window = APLTopWindow();
    if (window == nil) return;

    if (gAPLDiagLabel == nil) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 52, window.bounds.size.width - 16, 0)];
        label.numberOfLines = 0;
        label.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
        label.layer.cornerRadius = 6;
        label.layer.masksToBounds = YES;
        label.userInteractionEnabled = NO;
        gAPLDiagLabel = label;
    }
    gAPLDiagLabel.text = APLDiagText();
    [gAPLDiagLabel sizeToFit];
    CGRect frame = gAPLDiagLabel.frame;
    frame.origin = CGPointMake(8, 52);
    frame.size.width = window.bounds.size.width - 16;
    gAPLDiagLabel.frame = frame;

    if (gAPLDiagLabel.superview != window) {
        [window addSubview:gAPLDiagLabel];
    }
    [window bringSubviewToFront:gAPLDiagLabel];
}

#pragma mark - 糊屏

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
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    APLUpdateDiagPanel();
                });
            }];
        });
    }
}
