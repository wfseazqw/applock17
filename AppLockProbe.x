#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Common.h"

// 只读探测 3：确认关键方法的参数类型，并取卡片内容视图的入口名字。
// 不改变任何行为。

static UIWindow *gProbeWindow = nil;

static BOOL APLHasAny(NSString *s, NSArray *keys) {
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *APLTypeOf(NSString *clsName, NSString *sel) {
    Class c = NSClassFromString(clsName);
    if (!c) return [NSString stringWithFormat:@"%@ 类不存在", clsName];
    Method m = class_getInstanceMethod(c, NSSelectorFromString(sel));
    if (!m) return [NSString stringWithFormat:@"%@ 无 %@", clsName, sel];
    return [NSString stringWithFormat:@"%@ 类型=%s", sel, method_getTypeEncoding(m)];
}

static NSString *APLMethodNames(NSString *clsName, NSArray *keys) {
    Class c = NSClassFromString(clsName);
    if (!c) return @"类不存在";
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *s = NSStringFromSelector(method_getName(ms[i]));
        if (keys == nil || APLHasAny(s, keys)) [out addObject:s];
    }
    free(ms);
    return [NSString stringWithFormat:@"(共%u) %@", n, out.count ? [out componentsJoinedByString:@", "] : @"无匹配"];
}

static NSString *APLBuildReport(void) {
    NSMutableString *t = [NSMutableString string];

    [t appendString:@"【1 关键方法类型】\n"];
    for (NSString *sel in @[@"didSelectContainer:modifierFlags:",
                            @"_isAppLayoutBlurred:",
                            @"_applyRootContentViewBlurRadiusWithCompletion:",
                            @"handleTapToBringItemContainerForward:",
                            @"canSelectContainer:numberOfTaps:",
                            @"_handleDismissTapGesture:"]) {
        [t appendFormat:@"%@\n", APLTypeOf(@"SBFluidSwitcherViewController", sel)];
    }

    [t appendString:@"\n【2 卡片内容视图提供者】\n"];
    [t appendFormat:@"%@\n", APLMethodNames(@"SBFluidSwitcherPageContentViewProvider", nil)];

    [t appendString:@"\n【3 卡片容器】\n"];
    [t appendFormat:@"%@\n", APLMethodNames(@"SBFluidSwitcherItemContainer", @[@"appLayout", @"displayItem", @"content", @"snapshot", @"image"])];

    [t appendString:@"\n【4 AppLayout 取包名】\n"];
    [t appendFormat:@"%@\n", APLMethodNames(@"SBAppLayout", @[@"bundle", @"displayItem"])];

    return t;
}

static void APLShowProbe(void) {
    if (gProbeWindow) { gProbeWindow.hidden = NO; return; }

    NSString *text = APLBuildReport();
    [UIPasteboard generalPasteboard].string = text;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor whiteColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    tv.text = text;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:tv];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        gProbeWindow.hidden = YES;
    }] forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:close];

    [NSLayoutConstraint activateConstraints:@[
        [close.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [close.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:6],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:8],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-8],
        [tv.topAnchor constraintEqualToAnchor:close.bottomAnchor constant:6],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor]
    ]];

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }

    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 1000;
    w.rootViewController = vc;

    gProbeWindow = w;
    w.hidden = NO;
}

static void APLProbeTryShow(int left) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gProbeWindow) return;
        if ([UIApplication sharedApplication].connectedScenes.count == 0 && left > 0) {
            APLProbeTryShow(left - 1);
            return;
        }
        APLShowProbe();
    });
}

__attribute__((constructor)) static void APLProbeInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        APLProbeTryShow(8);
    }
}
