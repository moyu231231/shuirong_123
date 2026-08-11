# 水溶C（TrollStore × 内置 Dopamine）

双机链路 + 外部内存补丁。官方 Dopamine tipa 打进包内，部署页 **一键越狱并部署**。

## 打包

| 环境 | 做法 |
|------|------|
| **没有 Mac（新手）** | 打开 **[新手无Mac手把手.txt](新手无Mac手把手.txt)**，或双击 `package.cmd` |
| 有 Mac | `./package.sh` → `dist/水溶C.tipa` |

`package.sh` 默认下载并内置 `Dopamine.tipa`（约 +55MB）。若只要小包：`BUNDLE_DOPAMINE=0 ./package.sh`（运行时再下载）。

## 一键越狱并部署

1. TrollStore 安装 `水溶C.tipa`；在 TrollStore **设置里打开 URL Scheme**，并 Rebuild Icon Cache。
2. 打开水溶C → **部署** → **一键越狱并部署**：
   - 未装 Dopamine：本地分发内置 tipa → 唤起 TrollStore 安装
   - 自动打开 Dopamine → **你点一次 Jailbreak**（内核利用必须在 Dopamine 里跑）
   - 出现 `/var/jb` 后自动部署 `sy_kpatch` / `sy_watch`
3. 打开三角洲；**内存**页看 `flag=1 spoof≥1 jb=1`。
4. **链路**连双机。

说明：无法把 kfd 完整「嵌进同一进程当普通函数」——越狱要独立引导链。水溶C 做的是 **内置官方引擎 + 全自动编排**；补丁仍走外部内存，默认不注入游戏 dylib。

可选：打开「三角洲机型 tweak」增强 hook（镜像痕迹更大）。

## 目录

- `App/Deploy/` 一键越狱编排、部署、本地 tipa HTTP
- `App/Inject/` 手动补丁 / 清理设备标识
- `Tools/sy_kpatch` · `sy_watch` · `sy_mempatch` · `syinject`
- `package.sh` 编工具并拉取 Dopamine.tipa
