#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Common.h"
#import "PasswordManager.h"

// 现场观测版：屏幕顶部浮一条实时日志，只记录与「被锁 App / 多任务」相关的内部调用，
// 用来确认点击卡片到底走了哪个方法。除日志外不改变行为。

static UIWindow *gLogWindow = nil;
static UITextView *gLogView = nil;
static NSMutableArray<NSString *> *gLines = nil;

static BOOL APLSwEnabled(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    return [bundleDefaults[TWEAK_SPECIFIER_KEY] boolValue];
}

static NSArray *APLSwLockedIDs(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *list = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

static BOOL APLIsLockedBundle(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]]) return NO;
    NSArray *locked = APLSwLockedIDs();
    return [locked containsObject:bundleID];
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

static id APLAppLayoutOfContainer(id container) {
    if (container == nil) return nil;
    SEL sel = NSSelectorFromString(@"applayout");
    if (![container respondsToSelector:sel]) return nil;
    id (*msgSendID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return msgSendID(container, sel);
}

static void APLLogRefresh(void) {
    if (gLogView == nil) return;
    gLogView.text = [gLines componentsJoinedByString:@"\n"];
    if (gLogView.contentSize.height > gLogView.bounds.size.height) {
        [gLogView setContentOffset:CGPointMake(0, gLogView.contentSize.height - gLogView.bounds.size.height) animated:NO];
    }
}

static void APLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLines == nil) gLines = [NSMutableArray array];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        [gLines addObject:[NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], line]];
        while (gLines.count > 60) [gLines removeObjectAtIndex:0];
        APLLogRefresh();
    });
}

static void APLLogSetup(void) {
    if (gLogWindow) { gLogWindow.hidden = NO; return; }

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:4],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-4],
        [tv.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:4],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor constant:-4]
    ]];

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 1000;
    w.rootViewController = vc;

    gLogWindow = w;
    gLogView = tv;
    gLines = [NSMutableArray array];
    [gLines addObject:@"点一下多任务里爱玛卡片看看"];
    APLLogRefresh();

    w.frame = CGRectMake(0, 60, [UIScreen mainScreen].bounds.size.width, 130);
    w.hidden = NO;
}

static void APLLogTrySetup(int left) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gLogWindow) return;
        if ([UIApplication sharedApplication].connectedScenes.count == 0 && left > 0) {
            APLLogTrySetup(left - 1);
            return;
        }
        APLLogSetup();
    });
}

%hook SBFluidSwitcherViewController

- (BOOL)_isAppLayoutBlurred:(id)appLayout {
    BOOL origValue = %orig;
    if (APLAppLayoutLocked(appLayout)) {
        APLLog(@"_isAppLayoutBlurred 锁定=%d 系统原值=%d", APLAppLayoutLocked(appLayout), origValue);
        return YES;
    }
    return origValue;
}

- (void)didSelectContainer:(id)container modifierFlags:(long long)modifierFlags {
    id appLayout = APLAppLayoutOfContainer(container);
    APLLog(@"didSelectContainer(%@) layout=%@ 锁定=%d",
           NSStringFromClass([container class]),
           appLayout ? NSStringFromClass([appLayout class]) : @"nil",
           APLAppLayoutLocked(appLayout));

    if (APLSwEnabled() && APLAppLayoutLocked(appLayout)) {
        [[PasswordManager sharedInstance] authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
            if (isAuthenticated) { %orig; }
        }];
        return;
    }
    %orig;
}

- (void)handleTapToBringItemContainerForward:(id)container {
    APLLog(@"handleTapToBringItemContainerForward(%@)", NSStringFromClass([container class]));
    %orig;
}

- (BOOL)canSelectContainer:(id)container numberOfTaps:(long long)taps {
    BOOL origValue = %orig;
    APLLog(@"canSelectContainer 次数=%lld 返回=%d", taps, origValue);
    return origValue;
}

%end

%hook SBApplication

- (void)saveSuspendSnapshot:(id)snapshot forSceneHandle:(id)sceneHandle {
    NSString *bundleID = [(id)self bundleIdentifier];
    if (APLIsLockedBundle(bundleID)) {
        APLLog(@"saveSuspendSnapshot %@", bundleID);
    }
    %orig;
}

- (void)_setInternalProcessState:(long long)state {
    NSString *bundleID = [(id)self bundleIdentifier];
    if (APLIsLockedBundle(bundleID)) {
        APLLog(@"_setInternalProcessState %@ -> %lld", bundleID, state);
    }
    %orig;
}

%end

%hook SBUIController

- (void)activateApplication:(id)application fromIcon:(id)icon location:(long long)location activationSettings:(id)settings actions:(id)actions {
    NSString *bundleID = [(id)application bundleIdentifier];
    if (APLIsLockedBundle(bundleID)) {
        APLLog(@"SBUIController 激活 %@", bundleID);
    }
    %orig;
}

%end

__attribute__((constructor)) static void APLLogInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        APLLogTrySetup(8);
    }
}
