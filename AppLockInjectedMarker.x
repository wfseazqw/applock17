#import <UIKit/UIKit.h>
#import "Common.h"

// 注入验证：只在第三方 App 进程里显示一条小横幅，确认插件代码到底有没有进这个 App。
// 不改变 App 的任何行为，几秒后自动消失。

__attribute__((constructor)) static void APLInjectedMarker(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleID == nil) return;
        if ([bundleID isEqualToString:@"com.apple.springboard"]) return;
        if ([bundleID isEqualToString:@"com.apple.Preferences"]) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *window = [UIApplication sharedApplication].keyWindow;
            if (window == nil) return;

            UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, window.bounds.size.width, 44)];
            badge.backgroundColor = [UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:0.95];
            badge.textColor = [UIColor whiteColor];
            badge.font = [UIFont boldSystemFontOfSize:14];
            badge.textAlignment = NSTextAlignmentCenter;
            badge.numberOfLines = 2;
            badge.text = [NSString stringWithFormat:@"AppLock 已注入\n%@", bundleID];
            badge.userInteractionEnabled = NO;

            CGFloat top = window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top : 44;
            badge.frame = CGRectMake(0, top, window.bounds.size.width, 48);
            [window addSubview:badge];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [badge removeFromSuperview];
            });
        });
    }
}
