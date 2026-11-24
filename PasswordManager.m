#import "PasswordManager.h" 

// 验证结果的回调可能在后台线程，触碰 UI / 打开 App 必须回到主线程
static void APLRunOnMainThread(void(^block)(void)) {
    if([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@implementation PasswordManager

+ (id)sharedInstance {
    static PasswordManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

-(void)authenticate:(void(^)(BOOL isAuthenticated, NSError *authenticationError))completion {
    NSDictionary *bundleDefaults = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN];
	NSLog(@"current bundleDefaults: %@", bundleDefaults);

    NSDictionary *bundleDefaultsPasscode = [[NSUserDefaults standardUserDefaults] persistentDomainForName:USER_DEFAULTS_DOMAIN_PASSCODE];
	NSLog(@"current passcode: %@", bundleDefaultsPasscode);

    NSString *appLockPasscode = bundleDefaultsPasscode[BUNDLE_DEFAULTS_PASSCODE_KEY];


    BOOL isBiometricsEnabled = [bundleDefaults[BIOMETRICS_SPECIFIER_KEY] boolValue];
    BOOL isPasscodeEnabled = [bundleDefaults[PASSCODE_SPECIFIER_KEY] boolValue];

    if (isBiometricsEnabled == true) {
        [self checkBiometrics:^(BOOL isBiometricsCorrect, NSError *checkError) {
            if (isBiometricsCorrect == true) {
                APLRunOnMainThread(^{
                    completion(isBiometricsCorrect, checkError);
                });
            }
        }];
    }

    if (isPasscodeEnabled == true) {
        [self checkForPassword:appLockPasscode withCompletion:^(BOOL isPasswordCorrect) {
            if (isPasswordCorrect == true) {
                APLRunOnMainThread(^{
                    completion(isPasswordCorrect, nil);
                });
            }
        }];
    }

}

-(void)checkBiometrics:(void(^)(BOOL isBiometricsCorrect, NSError *checkError))completion {
    LAContext *laContext = [[LAContext alloc]init];
    NSError *evaluatePolicyError;

    BOOL isBiometricsAvailable = [laContext canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&evaluatePolicyError];
    if (isBiometricsAvailable == true) {
        [laContext evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics 
                localizedReason:@"验证身份以打开应用" 
                reply:^(BOOL success, NSError *error) {
                completion(success, error);
        }];
    } else {
        NSString *alertTitle = @"错误";
        NSString *alertMessage = @"未检测到生物识别，请先在 设置 中启用面容 ID 或触控 ID";
        APLRunOnMainThread(^{
            UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            [UIAlertController showAlertControllerWithVC:rootVC withMessage:alertMessage withTitle:alertTitle];
        });
        //don't run completion biometrics is not availalbe
        // completion(isBiometricsCorrect, nil); 
    }
}


-(void)checkForPassword:(NSString *)password withCompletion:(void(^)(BOOL isPasswordCorrect))completion {
    APLRunOnMainThread(^{
        UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;

        [self showAlertControllerPasswordCheckerWithVC:rootVC withCompletion:^(UIAlertController *alertController) {
            UITextField *textField = alertController.textFields[0];
            NSString *passwordInput = textField.text;
            if ([passwordInput isEqual:password]) {
                completion(true);
            } else {
                completion(false);
            }
        }];
    });
}


-(void)showAlertControllerPasswordCheckerWithVC:(UIViewController *)VC withCompletion:(void(^)(UIAlertController *alertController))completion {
   UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"应用已锁定"
                               message:@"请输入密码"
                               preferredStyle:UIAlertControllerStyleAlert];
   
   UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
      handler:^(UIAlertAction * action) 
      {
        //  UITextField *alertViewTextField = alert.textFields[0];
         completion(alert);
      }];
   
   
   [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.secureTextEntry = true;
    }];

   [alert addAction:defaultAction];
   [VC presentViewController:alert animated:YES completion:nil];
}

@end