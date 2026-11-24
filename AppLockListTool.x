#import <UIKit/UIKit.h>
#import "Common.h"

// 临时工具：只在「设置」里运行，把当前锁定名单的包名显示出来，方便加进注入名单
static BOOL gListShown = NO;

static NSArray *APLReadLockedList(void) {
    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *list = defaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

static void APLShowLockList(void) {
    if (gListShown) return;
    gListShown = YES;

    NSArray *list = APLReadLockedList();
    NSString *message;
    if (list.count) {
        message = [NSString stringWithFormat:@"锁定名单 %lu 个：\n\n%@", (unsigned long)list.count, [list componentsJoinedByString:@"\n"]];
    } else {
        message = @"锁定名单读不到，或者一个都没勾选。";
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"锁定名单（临时）"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];

    if (list.count) {
        [alert addAction:[UIAlertAction actionWithTitle:@"拷贝名单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = [list componentsJoinedByString:@"\n"];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];

    [ [UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

__attribute__((constructor)) static void APLListToolInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) {
            return;
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                APLShowLockList();
            });
        }];
    }
}
