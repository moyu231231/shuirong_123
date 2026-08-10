#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 返回已装应用字典数组：bundleID / name / version / bundlePath / appType
NSArray<NSDictionary *> *SYFetchInstalledApplications(void);

NS_ASSUME_NONNULL_END
