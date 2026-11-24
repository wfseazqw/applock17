#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreImage/CoreImage.h>
#import "Common.h"

// 应用锁 —— App 自身进程内的“糊屏”
// 只负责一件事：这个 App 被勾选为加锁时，退到后台（含打开多任务界面）就在它自己的窗口上盖一层糊图，
// 系统给多任务卡片拍照时拍到的就是这层糊图；回到前台就撤掉（验证已在 SpringBoard 先做过）。
// 1.1 起：App 进程读不到设置页那份名单（沙盒限制），状态由 SpringBoard 写进本 App 自己的容器。
// 1.2：改成“先截自己窗口一张图、缩小再高斯模糊、再铺满”，
//      因为 UIVisualEffectView 的实时模糊在系统快照里渲染不出来，卡片上只会看到一块深色板子，不像糊。

static UIView *gAPLOverlay = nil;
static CIContext *gAPLBlurContext = nil;

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

#pragma mark - 截图 + 模糊

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

// 把自己窗口截小图 → 高斯模糊 → 铺满用。
// 1.3：底图从 1/8 提到 1/4、半径调小，让卡片上还能看出 App 的轮廓和颜色，不再是一片发白的糊。
static UIImage *APLFrostedImage(UIWindow *window) {
    if (window == nil) return nil;
    CGRect bounds = window.bounds;
    if (bounds.size.width < 8 || bounds.size.height < 8) return nil;

    CGSize small = CGSizeMake(floor(bounds.size.width * 0.25), floor(bounds.size.height * 0.25));
    if (small.width < 8) small.width = 8;
    if (small.height < 8) small.height = 8;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:small format:format];

    UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        @try {
            [window drawViewHierarchyInRect:CGRectMake(0, 0, small.width, small.height) afterScreenUpdates:NO];
        } @catch (NSException *exception) {
        }
    }];
    if (snapshot == nil || snapshot.CGImage == NULL) return nil;

    CIImage *input = [CIImage imageWithCGImage:snapshot.CGImage];
    if (input == nil) return snapshot;

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (blur == nil) return snapshot;

    [blur setValue:input forKey:kCIInputImageKey];
    [blur setValue:@(9.0) forKey:kCIInputRadiusKey];
    CIImage *output = [[blur outputImage] imageByCroppingToRect:input.extent];
    if (output == nil) return snapshot;

    if (gAPLBlurContext == nil) {
        gAPLBlurContext = [CIContext contextWithOptions:nil];
    }
    CGImageRef image = [gAPLBlurContext createCGImage:output fromRect:input.extent];
    if (image == NULL) return snapshot;

    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result ?: snapshot;
}

#pragma mark - 盖/撤

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

    UIImage *frosted = APLFrostedImage(window);
    if (frosted != nil) {
        UIImageView *imageView = [[UIImageView alloc] initWithImage:frosted];
        imageView.frame = cover.bounds;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.contentMode = UIViewContentModeScaleToFill;
        imageView.layer.magnificationFilter = kCAFilterLinear;
        [cover addSubview:imageView];
    }

    UIView *dim = [[UIView alloc] initWithFrame:cover.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:frosted ? 0.42 : 0.8];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cover addSubview:dim];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"AppLock 已锁定";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:26];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cover addSubview:title];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectZero];
    tip.text = @"需要面容或密码验证";
    tip.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
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

    cover.alpha = 1.0;
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
