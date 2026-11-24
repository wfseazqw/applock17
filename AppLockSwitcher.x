#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Common.h"
#import "PasswordManager.h"

// 多任务（App 切换器）保护：
// 1) 被锁 App 的卡片盖上模糊层，看不见内容
// 2) 从多任务点开被锁 App 时再次验证
// 全部在 SpringBoard 进程内完成，不依赖 App 内注入。

#define APL_BLUR_TAG 0x4150424C

static BOOL APLSwEnabled(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
    return [bundleDefaults[TWEAK_SPECIFIER_KEY] boolValue];
}

static NSArray *APLSwLockedIDs(void) {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *list = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

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

// 按「卡片容器」反查它对应的 appLayout：遍历切换器当前的画面布局，逐个比对容器
static id APLLayoutForContainer(id switcher, id container) {
    if (container == nil || switcher == nil) return nil;
    SEL selLayouts = NSSelectorFromString(@"appLayouts");
    SEL selContainer = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
    if (![switcher respondsToSelector:selLayouts] || ![switcher respondsToSelector:selContainer]) return nil;

    id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*msgID_ID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    NSArray *layouts = msgID(switcher, selLayouts);
    if (![layouts isKindOfClass:[NSArray class]]) return nil;
    for (id layout in layouts) {
        id c = msgID_ID(switcher, selContainer, layout);
        if (c == container) return layout;
    }
    return nil;
}

static void APLBlurContainer(id container) {
    if (![container isKindOfClass:[UIView class]]) return;
    UIView *card = (UIView *)container;
    if ([card viewWithTag:APL_BLUR_TAG] != nil) return;

    UIView *cover = [[UIView alloc] initWithFrame:card.bounds];
    cover.tag = APL_BLUR_TAG;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.userInteractionEnabled = NO;
    cover.clipsToBounds = YES;
    cover.layer.cornerRadius = card.layer.cornerRadius > 0 ? card.layer.cornerRadius : 20.0;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = cover.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cover addSubview:blur];

    UIView *dim = [[UIView alloc] initWithFrame:cover.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [cover addSubview:dim];

    [card addSubview:cover];
}

// 把当前所有被锁 App 的卡片都盖上模糊层
static void APLBlurAllLockedCards(id switcher) {
    if (!APLSwEnabled()) return;
    SEL selLayouts = NSSelectorFromString(@"appLayouts");
    SEL selContainer = NSSelectorFromString(@"_itemContainerForAppLayoutIfExists:");
    if (![switcher respondsToSelector:selLayouts] || ![switcher respondsToSelector:selContainer]) return;

    id (*msgID)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*msgID_ID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    NSArray *layouts = msgID(switcher, selLayouts);
    if (![layouts isKindOfClass:[NSArray class]]) return;
    for (id layout in layouts) {
        if (!APLAppLayoutLocked(layout)) continue;
        id c = msgID_ID(switcher, selContainer, layout);
        if (c != nil) APLBlurContainer(c);
    }
}

%hook SBFluidSwitcherViewController

// 可见布局更新时补盖模糊（卡片新建、复用、滑动都会走到这里）
- (void)_updateVisibleAdjustedAppLayouts {
    %orig;
    APLBlurAllLockedCards(self);
}

// 进入切换器时也补一次
- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidBeginWithTransitionContext:(id)context {
    %orig;
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        if (strongSelf) APLBlurAllLockedCards(strongSelf);
    });
}

// 点击卡片打开 App 的入口
- (void)didSelectContainer:(id)container modifierFlags:(long long)modifierFlags {
    if (!APLSwEnabled()) {
        %orig;
        return;
    }

    id appLayout = APLLayoutForContainer(self, container);
    if (!APLAppLayoutLocked(appLayout)) {
        %orig;
        return;
    }

    APLBlurContainer(container);

    [[PasswordManager sharedInstance] authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
        if (isAuthenticated) {
            %orig;
        } else {
            APLBlurAllLockedCards(self);
        }
    }];
}

%end
