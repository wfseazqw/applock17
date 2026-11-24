#import "Tweak.h"
#import <objc/message.h>
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

#pragma mark - 把“锁/不锁”写进每个 App 自己的容器

// App 侧读的是自己容器里的这个文件（沙盒内一定能读）；SpringBoard 负责写。
static NSString *const kAPLStateFileName = @"com.applock.state.plist";

static void APLSyncAppStateFiles(void) {
   // 让 cfprefsd 拿到设置页刚写的最新值
   CFPreferencesAppSynchronize(CFSTR("com.applock.prefs"));
   CFPreferencesAppSynchronize(CFSTR("com.applock.prefs.isTweakOn"));

   BOOL masterOn = isAppLockEnabled();
   NSArray *lockedBundleIDs = updateEnabledBundleIDs();
   if (![lockedBundleIDs isKindOfClass:[NSArray class]]) lockedBundleIDs = @[];

   id workspace = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("LSApplicationWorkspace"), @selector(defaultWorkspace));
   if (workspace == nil) {
      NSLog(@"[AppLock] 拿不到 LSApplicationWorkspace");
      return;
   }
   NSArray *apps = ((NSArray *(*)(id, SEL))objc_msgSend)(workspace, @selector(allInstalledApplications));
   if (apps == nil) {
      NSLog(@"[AppLock] 拿不到已装 App 列表");
      return;
   }

   NSFileManager *fileManager = [NSFileManager defaultManager];
   NSInteger changed = 0;
   NSInteger failed = 0;
   NSMutableDictionary *globalApps = [NSMutableDictionary dictionary];
   for (id proxy in apps) {
      @try {
         NSString *bundleID = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier));
         if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) continue;
         if ([bundleID hasPrefix:@"com.apple."]) continue;

         BOOL wanted = (masterOn && [lockedBundleIDs containsObject:bundleID]);
         globalApps[bundleID] = @(wanted);

         NSURL *containerURL = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, @selector(dataContainerURL));
         if (containerURL == nil) continue;

         NSString *prefsDir = [[containerURL path] stringByAppendingPathComponent:@"Library/Preferences"];
         if (![fileManager fileExistsAtPath:prefsDir]) {
            NSError *dirError = nil;
            if (![fileManager createDirectoryAtPath:prefsDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
               failed++;
               continue;
            }
         }

         NSString *statePath = [prefsDir stringByAppendingPathComponent:kAPLStateFileName];

         NSDictionary *oldState = [NSDictionary dictionaryWithContentsOfFile:statePath];
         if (oldState != nil && [oldState[@"locked"] boolValue] == wanted) continue;

         NSDictionary *state = @{ @"locked" : @(wanted),
                                  @"bundleID" : bundleID,
                                  @"updated" : [NSDate date] };
         NSError *error = nil;
         if ([state writeToFile:statePath atomically:YES]) {
            changed++;
         } else {
            failed++;
            NSLog(@"[AppLock] 写状态失败 %@: %@", bundleID, error);
         }
      } @catch (__unused NSException *exception) {
         failed++;
      }
   }
   NSLog(@"[AppLock] 状态文件同步完成：改动 %ld 个，失败 %ld 个，勾选 %lu 个",
         (long)changed, (long)failed, (unsigned long)lockedBundleIDs.count);

   // 另外再写两份全局状态：万一容器写不进去，App 还有别的地方可读
   NSDictionary *globalState = @{ @"master" : @(masterOn),
                                  @"apps" : globalApps,
                                  @"updated" : [NSDate date] };
   BOOL wrotePrefsDir = [globalState writeToFile:@"/var/mobile/Library/Preferences/com.applock.state.plist" atomically:YES];
   BOOL wroteTmpDir = [globalState writeToFile:@"/private/var/tmp/com.applock.state.plist" atomically:YES];
   NSLog(@"[AppLock] 全局状态文件：偏好目录 %d，tmp 目录 %d", wrotePrefsDir, wroteTmpDir);
}

//widgets AppPredictionsUIWidget.framework
%hook APUIAppIconGridView

//ios 14 - 15
   -(void)iconTapped:(SBIconView *)iconView {
      NSString *bundleID = iconView.applicationBundleIdentifierForShortcuts;
      

      //check if AppLock tweak is enabled, if not run original method and exit hooked method
      if (isAppLockEnabled() == false) { %orig; return; } 
      
      
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
   NSString *bundleID = applicationIcon.applicationBundleID;
   

   //check if AppLock tweak is enabled, if not run original method and exit hooked method
   if (isAppLockEnabled() == false) { %orig; return; } 
   
   
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
   
   NSString *bundleID = application.bundleIdentifier;
   

   //check if AppLock tweak is enabled, if not run original method and exit hooked method
   if (isAppLockEnabled() == false) { %orig; return; } 
   
   
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


// 设置页点“注销”后发来的通知：直接让 SpringBoard 重启（等同注销）
static void APLRespringNotificationCallback(CFNotificationCenterRef center,
                                            void *observer,
                                            CFNotificationName name,
                                            const void *object,
                                            CFDictionaryRef userInfo) {
   dispatch_async(dispatch_get_main_queue(), ^{
      kill(getpid(), SIGKILL);
   });
}

 // 勾选变化后发来的通知：把“锁/不锁”写进每个 App 自己的容器里，App 自己读得到
 static void APLListChangedCallback(CFNotificationCenterRef center,
                                   void *observer,
                                   CFNotificationName name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
   dispatch_async(dispatch_get_main_queue(), ^{
      APLSyncAppStateFiles();
   });
}

 %ctor {
   appLockSetup();

   // 2.0.0：不再改写注入名单（RootHide 下无写权限），改为全 App 注入 + 运行时读状态判断。
   // 2.0.2：App 进程读不到 com.applock.prefs（沙盒拒绝跨域读取），
   //        改由 SpringBoard 把每个 App 的“锁/不锁”写进它自己的容器，App 只读自己的文件。
   NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
   if ([bundleID isEqualToString:@"com.apple.springboard"]) {
      CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                      NULL,
                                      APLRespringNotificationCallback,
                                      CFSTR("com.wfseazqw.applock17.respring"),
                                      NULL,
                                      CFNotificationSuspensionBehaviorDeliverImmediately);
      CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                      NULL,
                                      APLListChangedCallback,
                                      CFSTR("com.wfseazqw.applock17.listchanged"),
                                      NULL,
                                      CFNotificationSuspensionBehaviorDeliverImmediately);

      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
         @try {
            APLSyncAppStateFiles();
         } @catch (NSException *exception) {
            NSLog(@"[AppLock] 启动同步出错：%@", exception);
         }
      });

      // 每 60 秒补一次：新装的 App 不用注销、不用重打包也会自动出现在状态里
      // （只在 SpringBoard 自己的定时器里跑，绝不挂在 App 启动流程上）
      NSTimer *syncTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
         @try {
            APLSyncAppStateFiles();
         } @catch (NSException *exception) {
            NSLog(@"[AppLock] 定时同步出错：%@", exception);
         }
      }];
      (void)syncTimer;
   }
 }



