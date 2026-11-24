#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// 应用锁 —— 多任务（App 切换器）点击卡片时的二次验证
// 流程：点被锁卡片 → 拦住这次点选 → SpringBoard 里做面容验证 → 通过后按包名把 App 拉起来。
// 1.8.3：验证通过后不再“重放点选动作”（切换器已退出点选状态，重放无效），改成直接启动 App。

static NSString *const APLLockedBundleIdentifier = @"com.adb.aimaTravel";

static BOOL APLInvokeBoolReturn(id object, SEL selector, id argument) {
    if (object == nil) return NO;
    if (![object respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil) return NO;
    const char *returnType = [signature methodReturnType];
    if (returnType == NULL || returnType[0] == 'v') return NO;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:object];
    [invocation setSelector:selector];
    id argumentToPass = argument;
    [invocation setArgument:&argumentToPass atIndex:2];
    [invocation invoke];

    if (returnType[0] == 'B' || returnType[0] == 'c') {
        BOOL value = NO;
        [invocation getReturnValue:&value];
        return value;
    }
    if (returnType[0] == 'q' || returnType[0] == 'Q' || returnType[0] == 'i' || returnType[0] == 'I' ||
        returnType[0] == 'l' || returnType[0] == 'L' || returnType[0] == 's' || returnType[0] == 'S') {
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
}

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
        if (returnType[0] == 'q' || returnType[0] == 'Q' || returnType[0] == 'i' || returnType[0] == 'I' ||
            returnType[0] == 'l' || returnType[0] == 'L' || returnType[0] == 's' || returnType[0] == 'S') {
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

// 启动 App：先用 LSApplicationWorkspace，失败再用 SBSLaunchApplicationWithIdentifier
static BOOL APLLaunchBundle(NSString *bundleID) {
    if (bundleID == nil) return NO;
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass != nil) {
            SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
            if ([workspaceClass respondsToSelector:defaultSelector]) {
                id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id workspace = sendObject((id)workspaceClass, defaultSelector);
                if (workspace != nil && APLInvokeBoolReturn(workspace, NSSelectorFromString(@"openApplicationWithBundleID:"), bundleID)) {
                    return YES;
                }
            }
        }
    } @catch (NSException *exception) {
    }

    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (handle != NULL) {
        typedef int (*LaunchFunction)(CFStringRef, BOOL);
        LaunchFunction launch = (LaunchFunction)dlsym(handle, "SBSLaunchApplicationWithIdentifier");
        if (launch != NULL) {
            int result = launch((__bridge CFStringRef)bundleID, NO);
            return result == 0;
        }
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

    APLAuthenticateThen(^{
        APLLaunchBundle(APLLockedBundleIdentifier);
    });
}

%end
