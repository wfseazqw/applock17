#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 应用锁 —— 多任务（App 切换器）点击卡片时的二次验证
// 验证放在 SpringBoard 做（系统进程的面容可用）；App 自己只负责退后台糊屏。
// 1.8.2：取“卡片是否属于被锁 App”改成按方法真实返回类型调用（NSInvocation），避免 SpringBoard 崩溃。

static NSString *const APLLockedBundleIdentifier = @"com.adb.aimaTravel";

static id APLLayoutForContainer(id switcher, id container) {
    if (container == nil) return nil;
    @try {
        id layouts = [switcher valueForKey:@"appLayouts"];
        if (layouts == nil) return nil;
        SEL selector = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
        if (![switcher respondsToSelector:selector]) return nil;
        id (*sendObject)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        for (id layout in layouts) {
            id candidate = sendObject(switcher, selector, layout);
            if (candidate == container) {
                return layout;
            }
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

// 按真实返回类型调用 containsItemWithBundleIdentifier:，只把结果当“是/否”用
static BOOL APLLayoutIsLocked(id layout) {
    if (layout == nil) return NO;
    @try {
        SEL selector = NSSelectorFromString(@"containsItemWithBundleIdentifier:");
        if (![layout respondsToSelector:selector]) return NO;
        NSMethodSignature *signature = [layout methodSignatureForSelector:selector];
        if (signature == nil) return NO;
        const char *returnType = [signature methodReturnType];
        if (returnType == NULL) return NO;

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:layout];
        [invocation setSelector:selector];
        id argumentToPass = APLLockedBundleIdentifier;
        [invocation setArgument:&argumentToPass atIndex:2];
        [invocation invoke];

        if (returnType[0] == 'B' || returnType[0] == 'c') {
            BOOL value = NO;
            [invocation getReturnValue:&value];
            return value;
        }
        if (returnType[0] == 'q' || returnType[0] == 'Q' || returnType[0] == 'i' ||
            returnType[0] == 'I' || returnType[0] == 'l' || returnType[0] == 'L' ||
            returnType[0] == 's' || returnType[0] == 'S') {
            long long value = 0;
            [invocation getReturnValue:&value];
            return value != 0;
        }
        if (returnType[0] == '@' || returnType[0] == '#') {
            __unsafe_unretained id value = nil;
            [invocation getReturnValue:&value];
            return [value boolValue];
        }
        return NO;
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
    BOOL isLocked = NO;
    @try {
        id layout = APLLayoutForContainer(self, container);
        isLocked = APLLayoutIsLocked(layout);
    } @catch (NSException *exception) {
        isLocked = NO;
    }

    if (!isLocked) {
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
