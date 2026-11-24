#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "Common.h"
#import "PasswordManager.h"

// 多任务（App 切换器）保护：
// 1) 被锁 App 的卡片用独立置顶窗口盖住（能盖住实时画面层），看不见内容
// 2) 从多任务点开被锁 App 时再次验证，验证通过用系统接口启动该 App
// 全部在 SpringBoard 进程内完成，不依赖 App 内注入。

static UIWindow *gCoverWindow = nil;
static UIView *gCoverRoot = nil;
static NSMutableDictionary<NSValue *, UIView *> *gCovers = nil;
static CADisplayLink *gLink = nil;
static __weak id gSwitcher = nil;

@interface APLSyncDriver : NSObject
@end

static BOOL APLSwEnabled(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    return [bundleDefaults[TWEAK_SPECIFIER_KEY] boolValue];
}

static NSArray *APLSwLockedIDs(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *list = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

static BOOL APLAppLayoutLocked(id appLayout) {
    if (appLayout == nil) return NO;
    NSArray *locked = APLSwLockedIDs();
    if (locked.count == 0) return NO;
    SEL sel = NSSelectorFromString(@"containsItemWithBundleIdentifier:");
    if (![appLayout respondsToSelector:sel]) return NO;
    BOOL (*msgSendBool)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    for (NSString *bundleID in locked) {
        if (msgSendBool(appLayout, sel, bundleID)) return YES;
    }
    return NO;
}

// 从 appLayout 里取出被锁的那个包名
static NSString *APLLockedBundleIDForLayout(id appLayout) {
    if (appLayout == nil) return nil;
    NSArray *locked = APLSwLockedIDs();
    SEL sel = NSSelectorFromString(@"containsItemWithBundleIdentifier:");
    if (![appLayout respondsToSelector:sel]) return nil;
    BOOL (*msgSendBool)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    for (NSString *bundleID in locked) {
        if (msgSendBool(appLayout, sel, bundleID)) return bundleID;
    }
    return nil;
}

// 用系统接口启动 App（比复用点击方法可靠）
static void APLOpenApplication(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return;

    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    Class svcClass = NSClassFromString(@"FBSSystemService");
    if (svcClass != Nil) {
        id service = ((id (*)(id, SEL))objc_msgSend)(svcClass, NSSelectorFromString(@"sharedService"));
        SEL openSel = NSSelectorFromString(@"openApplication:options:withResult:");
        if (service && [service respondsToSelector:openSel]) {
            void (^result)(NSError *) = ^(NSError *error) {};
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, openSel, bundleID, @{}, result);
            return;
        }
    }

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (wsClass == Nil) {
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        wsClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (wsClass != Nil) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, NSSelectorFromString(@"defaultWorkspace"));
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (workspace && [workspace respondsToSelector:openSel]) {
            ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID);
        }
    }
}

static void APLCoverWindowSetup(void) {
    if (gCoverWindow) return;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    gCoverRoot = vc.view;

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = 100000;
    w.rootViewController = vc;
    w.userInteractionEnabled = NO;
    w.hidden = NO;

    gCoverWindow = w;
    gCovers = [NSMutableDictionary dictionary];
}

static UIView *APLMakeCover(CGRect frame, CGFloat cornerRadius) {
    UIView *cover = [[UIView alloc] initWithFrame:frame];
    cover.clipsToBounds = YES;
    cover.userInteractionEnabled = NO;
    cover.layer.cornerRadius = cornerRadius;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = cover.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cover addSubview:blur];

    UIView *dim = [[UIView alloc] initWithFrame:cover.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [cover addSubview:dim];

    return cover;
}

static void APLClearCovers(void) {
    for (UIView *cover in gCovers.allValues) [cover removeFromSuperview];
    [gCovers removeAllObjects];
}

static void APLSyncCovers(id switcher) {
    if (!APLSwEnabled()) { APLClearCovers(); return; }
    if (switcher == nil) return;

    SEL selLayouts = NSSelectorFromString(@"appLayouts");
    SEL selContainer = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
    if (![switcher respondsToSelector:selLayouts] || ![switcher respondsToSelector:selContainer]) return;

    APLCoverWindowSetup();
    if (gCoverWindow.hidden) return;

    id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*msgID_ID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    NSArray *layouts = msgID(switcher, selLayouts);
    if (![layouts isKindOfClass:[NSArray class]]) { APLClearCovers(); return; }

    NSMutableSet<NSValue *> *liveKeys = [NSMutableSet set];
    for (id layout in layouts) {
        if (!APLAppLayoutLocked(layout)) continue;
        id container = msgID_ID(switcher, selContainer, layout);
        if (![container isKindOfClass:[UIView class]]) continue;
        UIView *card = (UIView *)container;
        if (card.window == nil) continue;

        CGRect frame = [card convertRect:card.bounds toView:nil];
        if (frame.size.width < 40 || frame.size.height < 40) continue;

        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)card];
        UIView *cover = gCovers[key];
        if (cover == nil) {
            CGFloat radius = card.layer.cornerRadius > 0 ? card.layer.cornerRadius : 26.0;
            cover = APLMakeCover(frame, radius);
            [gCoverRoot addSubview:cover];
            gCovers[key] = cover;
        }
        cover.frame = frame;
        cover.layer.cornerRadius = card.layer.cornerRadius > 0 ? card.layer.cornerRadius : 26.0;
        [liveKeys addObject:key];
    }

    for (NSValue *key in gCovers.allKeys) {
        if (![liveKeys containsObject:key]) {
            [gCovers[key] removeFromSuperview];
            [gCovers removeObjectForKey:key];
        }
    }
}

static void APLStartSync(id switcher) {
    gSwitcher = switcher;
    if (gLink) return;
    APLSyncDriver *driver = [[APLSyncDriver alloc] init];
    gLink = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick:)];
    [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void APLStopSync(void) {
    [gLink invalidate];
    gLink = nil;
    APLClearCovers();
}

@implementation APLSyncDriver

- (void)tick:(CADisplayLink *)link {
    id switcher = gSwitcher;
    if (switcher == nil) { APLStopSync(); return; }

    id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    UIView *view = msgID(switcher, NSSelectorFromString(@"view"));
    if (![view isKindOfClass:[UIView class]] || view.window == nil) {
        APLStopSync();
        return;
    }
    APLSyncCovers(switcher);
}

@end

%hook SBFluidSwitcherViewController

// 卡片位置变化时同步遮罩
- (void)_updateVisibleAdjustedAppLayouts {
    %orig;
    APLStartSync(self);
    APLSyncCovers(self);
}

- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidBeginWithTransitionContext:(id)context {
    %orig;
    APLStartSync(self);
}

- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidEndWithTransitionContext:(id)context {
    %orig;
    APLSyncCovers(self);
}

// 点击卡片打开 App 的入口
- (void)didSelectContainer:(id)container modifierFlags:(long long)modifierFlags {
    if (!APLSwEnabled()) {
        %orig;
        return;
    }

    SEL selLayouts = NSSelectorFromString(@"appLayouts");
    SEL selForLayout = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
    id appLayout = nil;
    if ([self respondsToSelector:selLayouts] && [self respondsToSelector:selForLayout]) {
        id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id (*msgID_ID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        NSArray *layouts = msgID(self, selLayouts);
        for (id layout in layouts) {
            if (msgID_ID(self, selForLayout, layout) == container) { appLayout = layout; break; }
        }
    }

    NSString *bundleID = APLLockedBundleIDForLayout(appLayout);
    if (bundleID == nil) {
        %orig;
        return;
    }

    // 验证期间先收起遮罩，避免挡住面容识别面板
    if (gCoverWindow) gCoverWindow.hidden = YES;

    [[PasswordManager sharedInstance] authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
        if (isAuthenticated) {
            APLClearCovers();
            APLOpenApplication(bundleID);
        } else {
            if (gCoverWindow) gCoverWindow.hidden = NO;
            APLSyncCovers(self);
        }
    }];
}

%end
