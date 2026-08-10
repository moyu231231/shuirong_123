#ifndef SpawnRoot_h
#define SpawnRoot_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 以 root persona 启动（需 com.apple.private.persona-mgmt），返回进程退出码；spawn 失败返回负值。
int SYSpawnRoot(NSString *path, NSArray<NSString *> *args, NSString * _Nullable * _Nullable stdOut, NSString * _Nullable * _Nullable stdErr);

NS_ASSUME_NONNULL_END

#endif
