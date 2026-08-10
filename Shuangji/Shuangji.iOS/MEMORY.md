# 内存层：TrollStore 可行路线 + GitHub 优秀例子

目标：在「不完全越狱、用 TrollStore 装软件」的前提下，尽可能操作目标进程内存 / Hook `tersafe`。

## 结论先说

| 能力 | TrollStore  alone | TrollStore + TrollFools 注入 | 完整越狱 (Dopamine) |
|------|-------------------|------------------------------|---------------------|
| 本机 VPN 拦包（已有双层） | ✅ | ✅ | ✅ |
| 外部搜内存 / 改数据段 | ⚠️ 看 task_port | ⚠️ | ✅ |
| 注入 dylib 进游戏 | ❌ | ✅ **主力** | ✅ |
| Hook `tersafe` 导出符号 | ❌ | ✅ fishhook / 自写 | ✅ |
| 改 `__TEXT` 指令 / RVA | ❌ 易杀进程 | ❌ 易杀 | ✅ ElleKit |

**推荐组合（给 TrollStore 用户）：**

```text
水溶C App（控制台 + 隧道双层）
    +
TrollFools 把「水溶C-Mem.dylib」注入游戏
    → 进程内 Hook tersafe 导出 / get_report_data
    → 从源头掐 send_cs / send_gs 报告队列
```

---

## GitHub 优秀例子（建议收藏）

### 1. 注入载体（必看）

| 项目 | 地址 | 用途 |
|------|------|------|
| **TrollFools** | https://github.com/Lessica/TrollFools | TrollStore 设备上对 App **原地注入 dylib/framework**（insert_dylib + ChOma） |
| TrollFools_AI | https://github.com/CrackerCat/TrollFools_AI | 更高系统版本 / AI 机型变体（≤17.5.1 一类） |
| **ChOma** | https://github.com/opa334/ChOma | CoreTrust / 伪签，TrollStore 生态基础 |
| **TrollStore** | https://github.com/opa334/TrollStore | 任意 entitlement 永久安装 |

用法：用 TrollFools 选中游戏 → 注入我们编好的 `ShuiyongMem.dylib`。

### 2. 外部内存编辑（参考实现）

| 项目 | 地址 | 用途 |
|------|------|------|
| **VansonMod** | https://github.com/SoulRune/VansonMod | TrollStore 内存搜索/Hex/指针链；外部调试范本 |
| VansonLoader | https://github.com/vaenshine/vansonloader | 其配套 **注入版 dylib** |
| TaskPortHaxxApp | https://github.com/khanhduytran0/TaskPortHaxxApp | 仅靠 CoreTrust 玩 task_port 的实验 |

说明：外部改 `__TEXT` 在无越狱上常被 AMFI 打崩；改数据/队列指针相对现实。业务上我们更偏向 **注入 Hook**，而不是做通用修改器 UI。

### 3. 进程内 Hook（注入后用）

| 项目 | 地址 | 用途 |
|------|------|------|
| **fishhook** | https://github.com/facebook/fishhook | 重绑 Mach-O 导入符号；适合 Hook 游戏对 `tersafe` **导出** 的调用、以及 `send`/`connect` |
| **ElleKit** | https://github.com/tealbathingsuit/ellekit | Substrate 兼容；`MSHookFunction` / `MSHookMemory`；**完整越狱更稳** |
| insert_dylib | https://github.com/tyilo/insert_dylib | 装载命令写入（TrollFools 内部已用） |
| MachOKit | https://github.com/p-x9/MachOKit | Swift 解析 Mach-O（做特征/找符号时有用） |

`tersafe` 可见导出（IDA/字符串已确认一类）：

- `_tss_get_report_data` / `_TssSDKGetReportData*`
- `_tss_del_report_data*`
- `_tss_sdk_encryptpacket` / `_tss_sdk_decryptpacket`
- `send_cs` / `send_gs` 计数串（内部，未必导出）

注入 dylib 后优先：

1. `dlsym` + fishhook 重绑游戏侧对 `TssSDKGetReportData` / `tss_get_report_data` 的导入 → 直接返回空/长度 0  
2. 或 Hook 后立刻 `tss_del_report_data`  
3. 对 `send`/`sendto` 做载荷特征丢弃作兜底（与线缆层规则一致）

---

## 三层总览（网络双层 + 内存）

```text
【内存层 · 游戏进程内】ShuiyongMem.dylib（TrollFools 注入）
   Hook get_report_data / 相关导出 → 报告出不去（含 GS）
        │
【第1层 · 手机隧道】水溶C PacketTunnel
   拦 65010 上行 4013、NJ 上行 0E、轻洗 23/09
        │
【第2层 · PC/云】Shuangji Gateway+Engine
   绿样本、大厅/局内精洗、下行检测文件
```

内存层专门补 tersafe 的 **send_gs（走游戏服）**——纯网络层最容易漏的那条。

---

## 目录

- `MemDylib/` — 可给 TrollFools 注入的 dylib 源码骨架  
- `Shared/AceSignatures.swift` — 与网络层同一套字节特征（C 侧有对应头文件）

## 合规与风险

仅用于你们自有环境的协议研究与配套工具开发。改内存/注入可能导致闪退、封号；`__TEXT` 补丁在无越狱上极易被杀。
