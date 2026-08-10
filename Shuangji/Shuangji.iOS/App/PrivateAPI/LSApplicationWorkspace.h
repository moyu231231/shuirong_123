#ifndef LSApplicationWorkspace_h
#define LSApplicationWorkspace_h

#import <Foundation/Foundation.h>

@class LSApplicationProxy;

@interface LSApplicationWorkspace : NSObject
+ (LSApplicationWorkspace *)defaultWorkspace NS_SWIFT_NAME(defaultWorkspace());
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
- (void)enumerateApplicationsOfType:(NSInteger)type block:(void (^)(id))block;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
@end

#endif
