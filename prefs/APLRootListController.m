//
//  APLRootListController.m
//  Prefs
//
//  重写版：不再依赖 AltList 框架，由面板自己枚举已安装的 App 生成列表。
//  勾选结果仍写入 com.applock.prefs 的 switchIsEnabled 数组，与插件本体的读取方式保持一致。
//

#import <Foundation/Foundation.h>
#import "APLRootListController.h"
#import <Preferences/Preferences.h>
#import <dlfcn.h>

// 只用运行时访问，不依赖私有框架头，避免 SDK 头与私有声明冲突
static id APLSafePerform(id target, NSString *selectorName) {
    if(!target) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if(![target respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [target performSelector:sel];
#pragma clang diagnostic pop
}

static NSString *APLString(id target, NSString *selectorName) {
    id value = APLSafePerform(target, selectorName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray *APLAllApplications(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    });
    id workspace = APLSafePerform((id)NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    id all = APLSafePerform(workspace, @"allInstalledApplications");
    return [all isKindOfClass:[NSArray class]] ? all : @[];
}

static PSSpecifier *tweakEnabledSpecifier;
static PSSpecifier *biometricsSpecifier;
static PSSpecifier *passcodeSpecifier;

UISwitch *isEnabledSwitchControl;
UISwitch *biometricsSwitchControl;
UISwitch *passcodeSwitchControl;

UITableView *myTableView;

@implementation APLRootListController

-(instancetype)init {
    self = [super init];
    if(self) {
        [self createCustomSpecifiers];
    }
    return self;
}

-(void)createCustomSpecifiers {
    tweakEnabledSpecifier = [PSSpecifier preferenceSpecifierNamed:@"启用"
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:Nil
                                                            cell:PSSwitchCell
                                                            edit:Nil];
    [tweakEnabledSpecifier setProperty:USER_DEFAULTS_DOMAIN forKey:@"defaults"];
    [tweakEnabledSpecifier setProperty:TWEAK_SPECIFIER_KEY forKey:@"key"];

    biometricsSpecifier = [PSSpecifier preferenceSpecifierNamed:@"生物识别"
                                                       target:self
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil
                                                         cell:PSSwitchCell
                                                         edit:Nil];
    [biometricsSpecifier setProperty:USER_DEFAULTS_DOMAIN forKey:@"defaults"];
    [biometricsSpecifier setProperty:BIOMETRICS_SPECIFIER_KEY forKey:@"key"];
    [biometricsSpecifier setProperty:@YES forKey:@"default"];

    passcodeSpecifier = [PSSpecifier preferenceSpecifierNamed:@"密码"
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:Nil
                                                       cell:PSSwitchCell
                                                       edit:Nil];
    [passcodeSpecifier setProperty:USER_DEFAULTS_DOMAIN forKey:@"defaults"];
    [passcodeSpecifier setProperty:PASSCODE_SPECIFIER_KEY forKey:@"key"];
    [passcodeSpecifier setProperty:@NO forKey:@"default"];
}

//MARK: 应用列表

-(NSArray *)sortedApplications:(BOOL)systemApps {
    NSMutableArray *result = [NSMutableArray array];

    for(id proxy in APLAllApplications()) {
        NSString *identifier = APLString(proxy, @"bundleIdentifier");
        if(!identifier.length) continue;
        if([identifier hasPrefix:@"com.apple.WebKit"]) continue;

        NSString *type = APLString(proxy, @"applicationType");
        BOOL isSystem = [type isEqualToString:@"System"];
        if(isSystem != systemApps) continue;

        if(!APLString(proxy, @"localizedName").length) continue;

        id tags = APLSafePerform(proxy, @"appTags");
        if([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) continue;

        [result addObject:proxy];
    }

    [result sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSString *nameA = APLString(a, @"localizedName");
        NSString *nameB = APLString(b, @"localizedName");
        if(!nameA.length) nameA = APLString(a, @"bundleIdentifier");
        if(!nameB.length) nameB = APLString(b, @"bundleIdentifier");
        return [(nameA ?: @"") localizedCaseInsensitiveCompare:(nameB ?: @"")];
    }];

    return result;
}

-(NSMutableArray *)appGroupWithTitle:(NSString *)title footer:(NSString *)footer systemApps:(BOOL)systemApps {
    NSMutableArray *group = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:title
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:Nil
                                                          cell:PSGroupCell
                                                          edit:Nil];
    if(footer) [header setProperty:footer forKey:@"footerText"];
    [group addObject:header];

    for(id proxy in [self sortedApplications:systemApps]) {
        NSString *display = APLString(proxy, @"localizedName");
        NSString *identifier = APLString(proxy, @"bundleIdentifier");
        if(!display.length) display = identifier;
        if(!display.length) continue;
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:display
                                                          target:self
                                                             set:@selector(setAppLocked:specifier:)
                                                             get:@selector(isAppLocked:)
                                                          detail:Nil
                                                            cell:PSSwitchCell
                                                            edit:Nil];
        [spec setProperty:identifier forKey:@"bundleID"];
        [spec setProperty:@NO forKey:@"default"];
        [group addObject:spec];
    }

    return group;
}

//MARK: 勾选状态读写

-(NSArray *)lockedBundleIDs {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    NSArray *locked = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
    return [locked isKindOfClass:[NSArray class]] ? locked : @[];
}

-(void)saveLockedBundleIDs:(NSArray *)locked {
    NSMutableDictionary *bundleDefaults = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED] mutableCopy];
    if(!bundleDefaults) bundleDefaults = [NSMutableDictionary dictionary];
    bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY] = locked;
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:bundleDefaults forName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

-(id)isAppLocked:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"bundleID"];
    if(!bundleID) return @NO;
    return @([[self lockedBundleIDs] containsObject:bundleID]);
}

-(void)setAppLocked:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"bundleID"];
    if(!bundleID) return;

    NSMutableArray *locked = [[self lockedBundleIDs] mutableCopy];
    if([value boolValue]) {
        if(![locked containsObject:bundleID]) [locked addObject:bundleID];
    } else {
        [locked removeObject:bundleID];
    }
    [self saveLockedBundleIDs:locked];
}

//MARK: specifiers

- (NSMutableArray *)specifiers {
    if(!_specifiers) {
        NSMutableArray *all = [NSMutableArray array];
        [all addObject:tweakEnabledSpecifier];
        [all addObject:biometricsSpecifier];
        [all addObject:passcodeSpecifier];

        [all addObjectsFromArray:[self appGroupWithTitle:@"用户应用"
                                                 footer:@"勾选后，打开该 App 需要先验证身份"
                                             systemApps:NO]];
        [all addObjectsFromArray:[self appGroupWithTitle:@"系统应用"
                                                 footer:nil
                                             systemApps:YES]];

        _specifiers = all;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    myTableView = [self table];
}

//MARK: UIAdaptivePresentationControllerDelegate

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self userDismissedPasscodeVC];
}

//MARK: helper methods

-(void)userDismissedPasscodeVC {
    [passcodeSwitchControl setOn:false animated:true];
    [self passcodeSwitchChanged:nil];
}

-(void)presentPasswordViewController {
    PasswordViewController *passwordVC = [[PasswordViewController alloc] init];
    passwordVC.presentationController.delegate = self;
    [self presentViewController:passwordVC animated:true completion:nil];
}

-(void)isEnabledSwitchChanged:(id)sender {
    UISwitch *isEnabledSwitch = (UISwitch *)sender;

    PSSwitchTableCell *biometricsSwitchCell = (PSSwitchTableCell *)[myTableView cellForRowAtIndexPath:BIOMETRIC_CELL_INDEXPATH];
    UISwitch *biometricsSwitchControl = (UISwitch *)[biometricsSwitchCell control];

    PSSwitchTableCell *passcodeSwitchCell = (PSSwitchTableCell *)[myTableView cellForRowAtIndexPath:PASSCODE_CELL_INDEXPATH];
    UISwitch *passcodeSwitchControl = (UISwitch *)[passcodeSwitchCell control];

    if(isEnabledSwitch.on == true) {
        [[NSUserDefaults standardUserDefaults] setPersistentDomain:@{TWEAK_SPECIFIER_KEY:@1,
                                                                    BIOMETRICS_SPECIFIER_KEY:@1,
                                                                    PASSCODE_SPECIFIER_KEY:@0}
                                                          forName:USER_DEFAULTS_DOMAIN];
        [biometricsSwitchControl setOn:true animated:true];
        [passcodeSwitchControl setOn:false animated:true];
    } else {
        [[NSUserDefaults standardUserDefaults] setPersistentDomain:@{TWEAK_SPECIFIER_KEY:@0,
                                                                    BIOMETRICS_SPECIFIER_KEY:@0,
                                                                    PASSCODE_SPECIFIER_KEY:@0}
                                                          forName:USER_DEFAULTS_DOMAIN];
        [passcodeSwitchControl setOn:false animated:true];
        [biometricsSwitchControl setOn:false animated:true];
    }
}

-(void)biometricsSwitchChanged:(id)sender {
    UISwitch *biometricsSwitch = (UISwitch *)sender;

    PSSwitchTableCell *passcodeSwitchCell = (PSSwitchTableCell *)[myTableView cellForRowAtIndexPath:PASSCODE_CELL_INDEXPATH];
    UISwitch *passcodeSwitchControl = (UISwitch *)[passcodeSwitchCell control];

    if(biometricsSwitch.on == true) {
        [[NSUserDefaults standardUserDefaults] setPersistentDomain:@{TWEAK_SPECIFIER_KEY:@1,
                                                                    BIOMETRICS_SPECIFIER_KEY:@1,
                                                                    PASSCODE_SPECIFIER_KEY:@0}
                                                          forName:USER_DEFAULTS_DOMAIN];
        [passcodeSwitchControl setOn:false animated:true];
    } else {
        [[NSUserDefaults standardUserDefaults] setPersistentDomain:@{TWEAK_SPECIFIER_KEY:@1,
                                                                    BIOMETRICS_SPECIFIER_KEY:@0,
                                                                    PASSCODE_SPECIFIER_KEY:@1}
                                                          forName:USER_DEFAULTS_DOMAIN];
        [passcodeSwitchControl setOn:true animated:true];
        [self presentPasswordViewController];
    }

    PSSwitchTableCell *isEnabledSwitchCell = (PSSwitchTableCell *)[myTableView cellForRowAtIndexPath:IS_ENABLED_CELL_INDEXPATH];
    UISwitch *isEnabledSwitchControl = (UISwitch *)[isEnabledSwitchCell control];
    [isEnabledSwitchControl setOn:true animated:true];
}

-(void)passcodeSwitchChanged:(id)sender {
    UISwitch *passcodeSwitch = (UISwitch *)sender;

    PSSwitchTableCell *biometricsSwitchCell = (PSSwitchTableCell *)[myTableView cellForRowAtIndexPath:BIOMETRIC_CELL_INDEXPATH];
    UISwitch *biometricsSwitchControl = (UISwitch *)[biometricsSwitchCell control];

    if(passcodeSwitch.on == true) {
        [[NSUserDefaults standardUserDefaults] setPersistentDomain:@{TWEAK_SPECIFIER_KEY:@1,
                                                                    BIOMETRICS_SPECIFIER_KEY:@0,
                                                                    PASSCODE_SPECIFIER_KEY:@1}
                                                          forName:USER_DEFAULTS_DOMAIN];
        [biometricsSwitchControl setOn:false animated:true];
        [self presentPasswordViewController];
    } else {
        [[NSUserDefaults standardUserDefaults] setPersistentDomain:@{TWEAK_SPECIFIER_KEY:@1,
                                                                    BIOMETRICS_SPECIFIER_KEY:@1,
                                                                    PASSCODE_SPECIFIER_KEY:@0}
                                                          forName:USER_DEFAULTS_DOMAIN];
        [biometricsSwitchControl setOn:true animated:true];
    }

    PSSwitchTableCell *isEnabledSwitchCell = (PSSwitchTableCell *)[myTableView cellForRowAtIndexPath:IS_ENABLED_CELL_INDEXPATH];
    UISwitch *isEnabledSwitchControl = (UISwitch *)[isEnabledSwitchCell control];
    [isEnabledSwitchControl setOn:true animated:true];
}

//MARK: tableView delegate

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {

    if([indexPath compare:IS_ENABLED_CELL_INDEXPATH] == NSOrderedSame) {
        PSSwitchTableCell *isEnabledSwitchCell = (PSSwitchTableCell *)cell;
        isEnabledSwitchControl = (UISwitch *)[isEnabledSwitchCell control];
        [isEnabledSwitchControl addTarget:self
                                   action:@selector(isEnabledSwitchChanged:)
                         forControlEvents:UIControlEventValueChanged];
    }

    if([indexPath compare:BIOMETRIC_CELL_INDEXPATH] == NSOrderedSame) {
        PSSwitchTableCell *biometricsSwitchCell = (PSSwitchTableCell *)cell;
        biometricsSwitchControl = (UISwitch *)[biometricsSwitchCell control];
        [biometricsSwitchControl addTarget:self
                                    action:@selector(biometricsSwitchChanged:)
                          forControlEvents:UIControlEventValueChanged];
    }

    if([indexPath compare:PASSCODE_CELL_INDEXPATH] == NSOrderedSame) {
        PSSwitchTableCell *passcodeSwitchCell = (PSSwitchTableCell *)cell;
        passcodeSwitchControl = (UISwitch *)[passcodeSwitchCell control];
        [passcodeSwitchControl addTarget:self
                                  action:@selector(passcodeSwitchChanged:)
                        forControlEvents:UIControlEventValueChanged];
    }
}

@end
