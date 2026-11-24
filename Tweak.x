#import "Tweak.h"
#import <dlfcn.h>

static PasswordManager *passwordManager;

//bundle IDs of switches enabled to lock apps
NSArray* updateEnabledBundleIDs() {
   NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
   NSArray *enabledBundleIDs = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
   NSLog(@"the enabled bundle ids: %@", enabledBundleIDs);
   return enabledBundleIDs;
}

// 插件自身注入配置（和 dylib 同目录的 AppLock.plist）
BOOL isAppLockEnabled(void);

static NSString *APLInjectionFilterPlistPath(void) {
   Dl_info info;
   if (dladdr((const void *)&updateEnabledBundleIDs, &info) == 0 || info.dli_fname == NULL) {
      return nil;
   }
   NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
   if (!dylibPath.length) return nil;
   return [[dylibPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"AppLock.plist"];
}

// 按“已勾选加锁的 App”重写注入名单：SpringBoard / Spotlight 固定保留，其余只放被勾选的第三方 App
static void APLSyncInjectedBundles(void) {
   NSString *plistPath = APLInjectionFilterPlistPath();
   if (!plistPath.length) return;

   NSArray *lockedBundleIDs = updateEnabledBundleIDs();
   NSMutableArray *bundles = [NSMutableArray arrayWithObjects:@"com.apple.springboard", @"com.apple.Spotlight", nil];
   BOOL masterOn = isAppLockEnabled();
   for (id item in lockedBundleIDs) {
      if (!masterOn) break;   // 总开关关掉时，第三方 App 一律不注入（也就不糊屏、不加锁）
      if (![item isKindOfClass:[NSString class]]) continue;
      NSString *bundleID = (NSString *)item;
      if (!bundleID.length) continue;
      if ([bundleID hasPrefix:@"com.apple."]) continue;   // 系统 App 不注入
      if ([bundles containsObject:bundleID]) continue;
      [bundles addObject:bundleID];
   }

   NSDictionary *filterDictionary = @{ @"Filter" : @{ @"Bundles" : bundles } };
   NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:filterDictionary
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:NULL];
   if (plistData == nil) return;
   BOOL written = [plistData writeToFile:plistPath atomically:YES];
   NSLog(@"[AppLock] injected bundles updated (%d): %@ -> %@", written, bundles, plistPath);
}

BOOL isAppLockEnabled() {
   NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
   NSNumber *isEnabled = bundleDefaults[TWEAK_SPECIFIER_KEY];
   return [isEnabled boolValue];
}

static void appLockSetup() {
   passwordManager = [PasswordManager sharedInstance];
}

//widgets AppPredictionsUIWidget.framework
%hook APUIAppIconGridView

//ios 14 - 15
   -(void)iconTapped:(SBIconView *)iconView {
      //check if AppLock tweak is enabled, if not run original method and exit hooked method
      if (isAppLockEnabled() == false) { %orig; return; } 
      
      
      NSString *bundleID = iconView.applicationBundleIdentifierForShortcuts;
      NSLog(@"the bundleID: %@", bundleID);
      NSArray *lockedBundleIDs = updateEnabledBundleIDs();
      BOOL isApplicationLocked = [lockedBundleIDs containsObject:bundleID];

      // //check if app has been locked, if not run original method and exit hooked method
      if (isApplicationLocked == false) { %orig; return; }

      [passwordManager authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
         if (isAuthenticated == true) {
            NSLog(@"passwordManager authenticate works");
            %orig;
         } else {
            //do nothing, don't open the app
         }
      }];
   }

%end

//spotlight searchUI.framework
%hook SearchUIHomeScreenAppIconView

//ios 14 - 17
- (void)icon:(SBHApplicationIcon*)applicationIcon launchFromLocation:(id)arg2 context:(id)arg3 {
   //check if AppLock tweak is enabled, if not run original method and exit hooked method
   if (isAppLockEnabled() == false) { %orig; return; } 
   
   
   NSString *bundleID = applicationIcon.applicationBundleID;
   NSLog(@"the bundleID: %@", bundleID);
   NSArray *lockedBundleIDs = updateEnabledBundleIDs();
   BOOL isApplicationLocked = [lockedBundleIDs containsObject:bundleID];

   // //check if app has been locked, if not run original method and exit hooked method
   if (isApplicationLocked == false) { %orig; return; }

   [passwordManager authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
      if (isAuthenticated == true) {
         NSLog(@"passwordManager authenticate works");
         %orig;
      } else {
         //do nothing, don't open the app
      }
   }];
}

%end

//Springboard 
%hook SBUIController

//ios 11 - 17
-(void)activateApplication:(SBApplication *)application fromIcon:(id)arg2 location:(long long)arg3 activationSettings:(id)arg4 actions:(id)arg5 {
   
   //check if AppLock tweak is enabled, if not run original method and exit hooked method
   if (isAppLockEnabled() == false) { %orig; return; } 
   
   
   NSString *bundleID = application.bundleIdentifier;
   NSLog(@"the bundleID: %@", bundleID);
   NSArray *lockedBundleIDs = updateEnabledBundleIDs();
   BOOL isApplicationLocked = [lockedBundleIDs containsObject:bundleID];

   //check if app has been locked, if not run original method and exit hooked method
   if (isApplicationLocked == false) { %orig; return; }

   [passwordManager authenticate:^(BOOL isAuthenticated, NSError *authenticationError) {
      if (isAuthenticated == true) {
         NSLog(@"passwordManager authenticate works");
         %orig;
      } else {
         //do nothing, don't open the app
      }
   }];
   
}

%end


 %ctor {
   appLockSetup();

   // SpringBoard 每次启动时（含注销/重启）按当前勾选名单重写注入名单，
   // 这样新勾选的 App 下次启动就会被注入，未勾选的不会再被注入。
   NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
   if ([bundleID isEqualToString:@"com.apple.springboard"]) {
      APLSyncInjectedBundles();
   }
 }



