# 水溶C（TrollStore）

注入内置库封上报 + 链路连双机。

## 打包

| 环境 | 做法 |
|------|------|
| **没有 Mac（新手）** | 打开 **[新手无Mac手把手.txt](新手无Mac手把手.txt)**，或双击 `package.cmd` |
| 有 Mac | `./package.sh` → `dist/水溶C.tipa` |

摘要也在 [打包.txt](打包.txt)。

## 使用

1. **注入**：选游戏 → 注入（内置库，无文件选择）
2. **链路**：填双机 IP/账号 → 连接 → 读取/大厅/局内
3. 重开游戏

## 目录

- `App/` 界面（注入 / 链路 / 内存）
- `MemDylib/` 内置上报封堵库
- `Tools/syinject.c` 注入助手（打包时编进 App）
- `package.sh` 一键 tipa
