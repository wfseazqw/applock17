// 最小声明，仅供编译期解析；运行时由系统的 MobileCoreServices 提供实现
#import <Foundation/Foundation.h>
#import "LSApplicationProxy.h"

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (void)enumerateApplicationsOfType:(NSUInteger)type
                              block:(void (^)(LSApplicationProxy *proxy))block;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end
