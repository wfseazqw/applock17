#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Common.h"

// 只读探测 2（显示方式修正）：定位「切换器点开卡片」的入口，以及「卡片快照」的处理点。
// 不改变任何行为。用一个独立的高层级窗口显示，避免被 SpringBoard 启动时的界面重建清理掉。

static UIWindow *gProbeWindow = nil;

static BOOL APLHasAny(NSString *s, NSArray *keys) {
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSArray *APLClassNamesPrefix(NSString *prefix, NSString *kw, NSUInteger limit) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    objc_getClassList(classes, count);
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (name && [name hasPrefix:prefix] && [name containsString:kw]) {
            if (![out containsObject:name]) [out addObject:name];
            if (out.count >= limit) break;
        }
    }
    free(classes);
    return out;
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

static NSString *APLSelectorOf(NSString *clsName, NSString *sel) {
    Class c = NSClassFromString(clsName);
    if (!c) return [NSString stringWithFormat:@"%@ 类不存在", clsName];
    SEL s = NSSelectorFromString(sel);
    if ([c instancesRespondToSelector:s]) return [NSString stringWithFormat:@"%@ 有实例方法 %@", clsName, sel];
    if ([c respondsToSelector:s]) return [NSString stringWithFormat:@"%@ 只有类方法有 %@", clsName, sel];
    return [NSString stringWithFormat:@"%@ 没有 %@", clsName, sel];
}

static NSString *APLBuildReport(void) {
    NSMutableString *t = [NSMutableString string];

    [t appendString:@"【1 FluidSwitcher 类】\n"];
    [t appendFormat:@"%@\n\n", [APLClassNamesPrefix(@"SB", @"FluidSwitcher", 16) componentsJoinedByString:@", "]];

    [t appendString:@"【2 快照保存相关】\n"];
    [t appendFormat:@"%@\n", APLSelectorOf(@"SBApplication", @"saveSuspendSnapshot:forSceneHandle:")];
    [t appendFormat:@"%@\n", APLSelectorOf(@"SBApplication", @"suspendSnapshotForSceneHandle:")];
    [t appendFormat:@"%@\n\n", APLMethodNames(@"SBAppSwitcherSnapshotViewState", nil)];

    [t appendString:@"【3 SBWorkspace 激活法】\n"];
    [t appendFormat:@"%@\n\n", APLMethodNames(@"SBWorkspace", @[@"activat", @"entity", @"scene", @"transition"])];

    [t appendString:@"【4 MainWorkspace 激活法】\n"];
    [t appendFormat:@"%@\n\n", APLMethodNames(@"SBMainWorkspace", @[@"activat", @"entity", @"scene", @"transition"])];

    [t appendString:@"【5 FluidSwitcher 点按相关】\n"];
    [t appendFormat:@"%@\n\n", APLMethodNames(@"SBFluidSwitcherViewController", @[@"tap", @"select", @"activat", @"press", @"handle", @"begin", @"app"])];

    [t appendString:@"【6 AppController 相关】\n"];
    [t appendFormat:@"%@\n", APLMethodNames(@"SBApplicationController", @[@"activat", @"foreground", @"front", @"switcher"])];

    return t;
}

static void APLShowProbe(void) {
    if (gProbeWindow) {
        gProbeWindow.hidden = NO;
        return;
    }

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

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"拷贝" forState:UIControlStateNormal];
    [copy addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        [UIPasteboard generalPasteboard].string = text;
    }] forControlEvents:UIControlEventTouchUpInside];
    copy.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:copy];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        gProbeWindow.hidden = YES;
    }] forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:close];

    [NSLayoutConstraint activateConstraints:@[
        [copy.leadingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [copy.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:6],
        [close.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [close.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:6],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:8],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-8],
        [tv.topAnchor constraintEqualToAnchor:copy.bottomAnchor constant:6],
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
