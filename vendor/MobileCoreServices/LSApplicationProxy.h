// 最小声明，仅供编译期解析；运行时由系统的 MobileCoreServices 提供实现
#import <Foundation/Foundation.h>

@interface LSApplicationProxy : NSObject
@property(nonatomic, readonly) NSString *applicationIdentifier;
@property(nonatomic, readonly) NSString *bundleIdentifier;
@property(nonatomic, readonly) NSString *localizedName;
@property(nonatomic, readonly) NSString *applicationType;
@property(nonatomic, readonly) NSArray *appTags;
@property(nonatomic, readonly, getter=isLaunchProhibited) BOOL launchProhibited;
@property(nonatomic, readonly) NSURL *bundleURL;
@property(nonatomic, readonly) NSString *shortVersionString;
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@end
