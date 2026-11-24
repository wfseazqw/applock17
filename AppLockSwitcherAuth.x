#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 应用锁 —— 多任务（App 切换器）点击卡片时的二次验证
// 说明：验证放在 SpringBoard 里做。SpringBoard 是系统进程，面容识别可用；
// 在第三方 App 自己进程里发验证请求，这台机器上会退化到“输入密码”，所以不放在 App 里。
// App 那边只负责退后台糊屏（AppLockAppGuard.x）。用户验证通过后，卡片点击照常放行。

static NSString *const APLLockedBundleIdentifier = @"com.adb.aimaTravel";

static id APLLayoutForContainer(id switcher, id container) {
    if (container == nil) return nil;
    @try {
        id layouts = [switcher valueForKey:@"appLayouts"];
        if (layouts == nil) return nil;
        for (id layout in layouts) {
            SEL selector = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
            if (![switcher respondsToSelector:selector]) return nil;
            id (*sendId)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id candidate = sendId(switcher, selector, layout);
            if (candidate == container) {
                return layout;
            }
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

static BOOL APLLayoutIsLocked(id layout) {
    if (layout == nil) return NO;
    @try {
        SEL selector = NSSelectorFromString(@"containsItemWithBundleIdentifier:");
        if (![layout respondsToSelector:selector]) return NO;
        id (*sendId)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id result = sendId(layout, selector, APLLockedBundleIdentifier);
        if (result != nil) {
            return [result boolValue];
        }
    } @catch (NSException *exception) {
    }
    return NO;
}

static void APLAuthenticateThen(void (^onSuccess)(void)) {
    LAContext *context = [[LAContext alloc] init];
    context.localizedFallbackTitle = @"输入密码";

    NSError *error = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        return;
    }

    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:@"解锁 AppLock"
                      reply:^(BOOL success, NSError *authError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success && onSuccess) {
                onSuccess();
            }
        });
    }];
}

%hook SBFluidSwitcherViewController

- (void)didSelectContainer:(id)container modifierFlags:(long long)flags {
    id layout = APLLayoutForContainer(self, container);
    if (!APLLayoutIsLocked(layout)) {
        %orig;
        return;
    }

    id target = (id)self;
    SEL selector = _cmd;
    IMP implementation = [target methodForSelector:selector];

    APLAuthenticateThen(^{
        if (implementation != NULL && target != nil) {
            ((void (*)(id, SEL, id, long long))implementation)(target, selector, container, flags);
        }
    });
}

%end
