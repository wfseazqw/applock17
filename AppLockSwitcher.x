#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Common.h"
#import "PasswordManager.h"

// 多任务（App 切换器）相关保护：都在 SpringBoard 进程内完成，不依赖 App 内注入。
// 1) 被锁 App 的卡片画面模糊（看不见内容）
// 2) 从多任务点开被锁 App 时再次验证

static BOOL APLSwEnabled(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    return [bundleDefaults[TWEAK_SPECIFIER_KEY] boolValue];
}

static NSArray *APLSwLockedIDs(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *list = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

// appLayout 是否包含任一被锁的包名
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

%hook SBFluidSwitcherViewController

// 卡片画面是否按「模糊」处理
- (BOOL)_isAppLayoutBlurred:(id)appLayout {
    if (APLSwEnabled() && APLAppLayoutLocked(appLayout)) {
        return YES;
    }
    return %orig;
}

// 点击卡片打开 App 的入口
- (void)didSelectContainer:(id)container modifierFlags:(long long)modifierFlags {
    if (!APLSwEnabled()) {
        %orig;
        return;
    }

    id appLayout = APLAppLayoutOfContainer(container);
    if (!APLAppLayoutLocked(appLayout)) {
        %orig;
        return;
    }

    [[PasswordManager sharedInstance] authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
        if (isAuthenticated) {
            %orig;
        }
    }];
}

%end
