# 水溶C（TrollStore × RootHide / Dopamine）

默认适配 **RootHide Dopamine**（无 `/var/jb`，扫描 `.jbroot-*`）。也可选官方 Dopamine。

## 一键越狱并部署

1. TrollStore 开启 URL Scheme。
2. 部署页选 **RootHide Dopamine（推荐）** → **一键越狱并部署**。
3. Dopamine 内点 Jailbreak；成功后自动部署到 `/var/mobile/Library/shuiyong`。
4. **RootHide Manager**：打三角洲时不要把游戏拉进「隐藏越狱」黑名单（否则 tweak 无效；外部 mempatch 仍可用）。
5. 内存页看 **`flag=1`**（主效果）；`spoof` 只是改缓存机型串，不是万能。

## 补丁到底有没有用

| 项 | 作用 |
|----|------|
| flag / GOT | 挡上报门闩与 OnRecv，这是主价值 |
| spoof 改串 | 只改内存里已有的 `iPhone*,*`；现场读 sysctl 无效，需开机型 tweak |
| RootHide | 藏越狱痕迹；和「改机型」是两件事，别指望越狱本身改机型 |

## 打包

| 环境 | 做法 |
|------|------|
| 无 Mac | [新手无Mac手把手.txt](新手无Mac手把手.txt) / `package.cmd` |
| 有 Mac | `./package.sh` → `dist/水溶C.tipa` |

`JB_FLAVOR=roothide`（默认）或 `stock`；`BUNDLE_DOPAMINE=0` 不内置 tipa。
