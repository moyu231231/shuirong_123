# ShuiyongMem.dylib（TrollFools 注入）

## 依赖源码（请从 GitHub 拉取进本目录）

```bash
# fishhook（必须）
curl -L -o fishhook.c https://raw.githubusercontent.com/facebook/fishhook/main/fishhook.c
curl -L -o fishhook.h https://raw.githubusercontent.com/facebook/fishhook/main/fishhook.h
```

（仓库里的 `fishhook.h` 只是占位 API，**务必覆盖为官方文件**。）

可选（完整越狱设备）：把 [ElleKit](https://github.com/tealbathingsuit/ellekit) 链进 dylib，对内部函数做 `MSHookFunction`。

## 编译（Mac + Theos 或 Xcode）

Xcode：新建 Framework/Dynamic Library target，产出 `ShuiyongMem.dylib`。  
Theos：`LIBRARY_NAME = ShuiyongMem`，装到任意路径后拷到手机。

## 安装到游戏

1. TrollStore 安装 [TrollFools](https://github.com/Lessica/TrollFools)  
2. 选中游戏 → Inject → 选 `ShuiyongMem.dylib`  
3. 杀进程重开游戏，看 Console 是否有 `[水溶C-Mem] loaded`  
4. 同时开「水溶C」隧道 + Shuangji 第2层

## 符号对不上时

在 Mac 上对 `tersafe`：

```bash
nm -gU tersafe.framework/tersafe | rg -i 'report|tss_|TssSDK'
```

把 `TersafeHooks.m` 里的名字改成实际导出。
