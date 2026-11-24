#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Common.h"

// 只读探测：不改变任何行为，只在 SpringBoard 里弹一次文本框，
// 把「多任务切换器 / 快照 / 应用退出」相关的内部类名与方法名列出来。

static BOOL gProbeShown = NO;

static BOOL APLHasAny(NSString *s, NSArray *keys) {
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSArray *APLClassNames(NSString *kw, NSUInteger limit) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    objc_getClassList(classes, count);
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (name && [name containsString:kw]) {
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

static NSString *APLBuildReport(void) {
    NSMutableString *t = [NSMutableString string];

    [t appendString:@"【1 切换器类】\n"];
    [t appendFormat:@"%@\n\n", [APLClassNames(@"Switcher", 14) componentsJoinedByString:@", "]];

    [t appendString:@"【2 快照类】\n"];
    [t appendFormat:@"%@\n\n", [APLClassNames(@"Snapshot", 10) componentsJoinedByString:@", "]];

    [t appendString:@"【3 SBApplication 关键法】\n"];
    [t appendFormat:@"%@\n\n", APLMethodNames(@"SBApplication", @[@"kill", @"terminate", @"suspend", @"background", @"foreground", @"activate", @"processState"])];

    [t appendString:@"【4 SBUIController 关键法】\n"];
    [t appendFormat:@"%@\n", APLMethodNames(@"SBUIController", @[@"kill", @"terminate", @"activate", @"switch", @"suspend"])];

    return t;
}

static void APLShowProbe(void) {
    if (gProbeShown) return;
    UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (root == nil) return;
    gProbeShown = YES;

    NSString *text = APLBuildReport();

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
        [vc dismissViewControllerAnimated:YES completion:nil];
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

    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [root presentViewController:vc animated:YES completion:nil];
}

static void APLProbeTryShow(int left) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gProbeShown) return;
        if ([UIApplication sharedApplication].keyWindow.rootViewController == nil && left > 0) {
            APLProbeTryShow(left - 1);
            return;
        }
        APLShowProbe();
    });
}

__attribute__((constructor)) static void APLProbeInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        APLProbeTryShow(6);
    }
}
