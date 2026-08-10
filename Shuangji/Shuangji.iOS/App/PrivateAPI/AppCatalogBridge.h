#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 返回已装应用字典数组：bundleID / name / version / bundlePath / appType
NSArray<NSDictionary *> *SYFetchInstalledApplications(void);

/// 运行时打开 App（NSClassFromString，避免硬链私有类导致链接失败）
BOOL SYOpenApplicationWithBundleID(NSString *bundleID);

NS_ASSUME_NONNULL_END
