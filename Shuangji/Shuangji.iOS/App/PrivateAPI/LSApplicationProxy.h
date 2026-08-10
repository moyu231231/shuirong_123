#ifndef LSApplicationProxy_h
#define LSApplicationProxy_h

#import <Foundation/Foundation.h>

@interface LSApplicationProxy : NSObject
+ (LSApplicationProxy *)applicationProxyForIdentifier:(NSString *)bundleIdentifier;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)shortVersionString;
- (NSString *)applicationType;
- (NSString *)teamID;
- (NSURL *)bundleURL;
- (NSURL *)dataContainerURL;
- (BOOL)installed;
@end

#endif
