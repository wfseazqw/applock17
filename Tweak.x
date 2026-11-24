#import "Tweak.h"
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

static PasswordManager *passwordManager;

//bundle IDs of switches enabled to lock apps
NSArray* updateEnabledBundleIDs() {
   NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_IS_ENABLED];
   NSArray *enabledBundleIDs = bundleDefaults[BUNDLE_DEFAULTS_IS_ENABLED_KEY];
   NSLog(@"the enabled bundle ids: %@", enabledBundleIDs);
   return enabledBundleIDs;
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


// 设置页点“注销”后发来的通知：先把名单再同步一次，再让 SpringBoard 重启（等同注销）
static void APLRespringNotificationCallback(CFNotificationCenterRef center,
                                            void *observer,
                                            CFNotificationName name,
                                            const void *object,
                                            CFDictionaryRef userInfo) {
   dispatch_async(dispatch_get_main_queue(), ^{
      kill(getpid(), SIGKILL);
   });
}

 %ctor {
   appLockSetup();

   // 2.0.0：不再改写注入名单（RootHide 下无写权限），改为全 App 注入 + 运行时按勾选名单判断。
   // 这里只负责“注销”按钮的通知处理。
   NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
   if ([bundleID isEqualToString:@"com.apple.springboard"]) {
      CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                      NULL,
                                      APLRespringNotificationCallback,
                                      CFSTR("com.wfseazqw.applock17.respring"),
                                      NULL,
                                      CFNotificationSuspensionBehaviorDeliverImmediately);
   }
 }



