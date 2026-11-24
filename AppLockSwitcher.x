#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "Common.h"
#import "PasswordManager.h"

// 多任务（App 切换器）保护：
// 1) 被锁 App 的卡片在切换器里盖上模糊层（遮罩挂在切换器窗口内，离开切换器自动撤掉，且不拦截触摸）
// 2) 从多任务点开被锁 App 时再次验证，通过后用系统接口启动该 App

#define APL_COVER_TAG 0x41504356

static NSMutableDictionary<NSValue *, UIView *> *gCovers = nil;
static __weak UIWindow *gHostWindow = nil;
static __weak id gSwitcher = nil;
static CADisplayLink *gLink = nil;

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

static UIView *APLMakeCover(CGRect frame, CGFloat cornerRadius) {
    UIView *cover = [[UIView alloc] initWithFrame:frame];
    cover.clipsToBounds = YES;
    cover.userInteractionEnabled = NO;
    cover.tag = APL_COVER_TAG;
    cover.layer.cornerRadius = cornerRadius;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = cover.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [cover addSubview:blur];

    UIView *dim = [[UIView alloc] initWithFrame:cover.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    dim.userInteractionEnabled = NO;
    [cover addSubview:dim];

    return cover;
}

static void APLClearCovers(void) {
    for (UIView *cover in gCovers.allValues) [cover removeFromSuperview];
    [gCovers removeAllObjects];
}

static void APLSyncCovers(id switcher) {
    if (switcher == nil) return;
    if (!APLSwEnabled()) { APLClearCovers(); return; }
    if (gCovers == nil) gCovers = [NSMutableDictionary dictionary];

    id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*msgID_ID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    SEL selLayouts = NSSelectorFromString(@"appLayouts");
    SEL selContainer = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
    if (![switcher respondsToSelector:selLayouts] || ![switcher respondsToSelector:selContainer]) return;

    UIView *switcherView = msgID(switcher, NSSelectorFromString(@"view"));
    if (![switcherView isKindOfClass:[UIView class]]) { APLClearCovers(); return; }

    UIWindow *host = switcherView.window;
    if (host == nil) { APLClearCovers(); gHostWindow = nil; return; }

    // 宿主窗口换了，旧遮罩全部清掉
    if (gHostWindow != host) { APLClearCovers(); gHostWindow = host; }

    NSArray *layouts = msgID(switcher, selLayouts);
    if (![layouts isKindOfClass:[NSArray class]]) { APLClearCovers(); return; }

    CGRect screen = host.bounds;
    NSMutableSet<NSValue *> *liveKeys = [NSMutableSet set];

    for (id layout in layouts) {
        if (!APLAppLayoutLocked(layout)) continue;

        id container = msgID_ID(switcher, selContainer, layout);
        if (![container isKindOfClass:[UIView class]]) continue;

        UIView *card = (UIView *)container;
        if (card.window == nil) continue;

        CGRect frame = [card convertRect:card.bounds toView:host];

        // 卡片不在屏幕里（多任务已退出 / App 已打开 / 回到桌面）就不盖
        CGRect visible = CGRectIntersection(frame, screen);
        if (CGRectIsNull(visible) || visible.size.width < 60 || visible.size.height < 60) continue;

        CGFloat radius = card.layer.cornerRadius > 0 ? card.layer.cornerRadius : 26.0;
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)card];
        UIView *cover = gCovers[key];
        if (cover == nil) {
            cover = APLMakeCover(frame, radius);
            [host addSubview:cover];
            gCovers[key] = cover;
        } else if (cover.superview != host) {
            [cover removeFromSuperview];
            [host addSubview:cover];
        }
        cover.frame = frame;
        cover.layer.cornerRadius = radius;
        cover.hidden = NO;
        [host bringSubviewToFront:cover];
        [liveKeys addObject:key];
    }

    for (NSValue *key in gCovers.allKeys) {
        if (![liveKeys containsObject:key]) {
            [gCovers[key] removeFromSuperview];
            [gCovers removeObjectForKey:key];
        }
    }
}

static void APLSetCoversHidden(BOOL hidden) {
    for (UIView *cover in gCovers.allValues) cover.hidden = hidden;
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
    gHostWindow = nil;
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

- (void)_updateVisibleAdjustedAppLayouts {
    %orig;
    APLStartSync(self);
    APLSyncCovers(self);
}

- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidBeginWithTransitionContext:(id)context {
    %orig;
    APLStartSync(self);
    APLSyncCovers(self);
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

    id switcher = (id)self;
    id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*msgID_ID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    SEL selLayouts = NSSelectorFromString(@"appLayouts");
    SEL selForLayout = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
    id appLayout = nil;
    if ([switcher respondsToSelector:selLayouts] && [switcher respondsToSelector:selForLayout]) {
        NSArray *layouts = msgID(switcher, selLayouts);
        for (id layout in layouts) {
            if (msgID_ID(switcher, selForLayout, layout) == container) { appLayout = layout; break; }
        }
    }

    NSString *bundleID = APLLockedBundleIDForLayout(appLayout);
    if (bundleID == nil) {
        %orig;
        return;
    }

    // 验证期间先收遮罩，避免挡住面容面板
    APLSetCoversHidden(YES);

    [[PasswordManager sharedInstance] authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
        if (isAuthenticated) {
            APLClearCovers();
            APLOpenApplication(bundleID);
        } else {
            APLSetCoversHidden(NO);
            APLSyncCovers(switcher);
        }
    }];
}

%end
