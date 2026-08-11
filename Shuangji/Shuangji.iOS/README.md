# 水溶C（TrollStore × RootHide / Dopamine）

默认适配 **RootHide Dopamine**（无 `/var/jb`，扫描 `.jbroot-*`）。也可选官方 Dopamine。

## 一键越狱并部署

1. TrollStore 开启 URL Scheme。
2. 部署页选 **RootHide Dopamine（推荐）** → **一键越狱并部署**。
3. Dopamine 内点 Jailbreak；成功后自动部署到 `/var/mobile/Library/shuiyong`。
4. **RootHide Manager**：打三角洲时不要把游戏拉进「隐藏越狱」黑名单（否则 tweak 无效；外部 mempatch 仍可用）。
5. 内存页看 **`flag=1`**（门闩）；`report≥1` / tweak `report=empty`（挡 send_gs）；Gateway 局内应出现 `ACE CDN drop`。
6. **花海级效果靠叠层**，不是只开机型：小火箭→Gateway（CDN 黑洞+4013）+ mempatch + 可选 tweak。

## 补丁到底有没有用

| 项 | 作用 |
|----|------|
| flag / GOT OnRecv | 挡 COREREPORT 门闩与检测下发 |
| GetReport 空缓冲 | 挡 send_gs（禁止返回 NULL） |
| Gateway ACE CDN | 局内黑洞检测 CDN，对齐花海饿死 MRPCS |
| spoof 改串 / tweak | 机型画像；现场读 sysctl 需 tweak |
| 状态 VPN | **不拦包**；必须小火箭走 Gateway |

## 打包

| 环境 | 做法 |
|------|------|
| 无 Mac | [新手无Mac手把手.txt](新手无Mac手把手.txt) / `package.cmd` |
| 有 Mac | `./package.sh` → `dist/水溶C.tipa` |

`JB_FLAVOR=roothide`（默认）或 `stock`；`BUNDLE_DOPAMINE=0` 不内置 tipa。
