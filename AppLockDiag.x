#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 临时诊断：只为了确认「能否在普通 App 里注入」和「App 里能否读到锁定名单」
static NSString *APLDiagReport(void) {
    NSMutableString *out = [NSMutableString string];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    [out appendFormat:@"注入: OK (%@)\n", bundleID ?: @"?"];

    NSDictionary *domainA = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.applock.prefs"];
    id listA = domainA[@"switchIsEnabled"];
    [out appendFormat:@"A域(NSUserDefaults): %@ / 锁定数量 %@\n",
        domainA ? [NSString stringWithFormat:@"%lu键", (unsigned long)domainA.count] : @"读不到",
        [listA isKindOfClass:[NSArray class]] ? [NSString stringWithFormat:@"%lu", (unsigned long)[listA count]] : @"-"];

    NSString *plistPath = @"/var/mobile/Library/Preferences/com.applock.prefs.plist";
    BOOL existsPlain = [[NSFileManager defaultManager] fileExistsAtPath:plistPath];
    [out appendFormat:@"B文件(/var/mobile/...): %@\n", existsPlain ? @"可读" : @"读不到"];

    id listC = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("switchIsEnabled"), CFSTR("com.applock.prefs"));
    [out appendFormat:@"C域(CFPreferences): %@\n",
        [listC isKindOfClass:[NSArray class]] ? [NSString stringWithFormat:@"%lu", (unsigned long)[listC count]] : (listC ? @"有值" : @"读不到")];

    return out;
}

__attribute__((constructor)) static void APLDiagInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) {
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AppLock 探测结果"
                                                                          message:APLDiagReport()
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
            [root presentViewController:alert animated:YES completion:nil];
        });
    }
}
