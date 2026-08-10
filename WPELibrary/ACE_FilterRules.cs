using System;
using System.Linq;
using WPELibrary.Lib;

namespace WPELibrary
{
    /// <summary>
    /// 内置拦截规则集合。
    /// 每次 StartHook 前由 Socket_Form 调用 Register()，规则已存在时自动跳过。
    /// </summary>
    public static class ACE_FilterRules
    {
        // 该规则的唯一名称，用于去重检测
        public const string RuleName_LargePacket3366 = "[内置] 3366大包拦截(≥10000字节)";

        /// <summary>
        /// 注册所有内置规则。幂等：重复调用不会产生重复条目。
        /// </summary>
        public static void Register()
        {
            Register_LargePacket3366();
        }

        /// <summary>
        /// 拦截发送方向中包头为 0x33 0x66、数据长度 ≥ 10000 字节的数据包。
        /// </summary>
        private static void Register_LargePacket3366()
        {
            try
            {
                var list = Socket_Cache.FilterList.lstFilter;

                // 已存在则跳过，避免重复添加
                if (list.Any(f => f.FName == RuleName_LargePacket3366))
                    return;

                Guid fid = Guid.NewGuid();

                // 仅作用于发送方向（Send / SendTo / WSASend / WSASendTo）
                // FilterFunction(bSend, bSendTo, bRecv, bRecvFrom, bWSASend, bWSASendTo, bWSARecv, bWSARecvFrom)
                var func = new Socket_Cache.Filter.FilterFunction(
                    bSend:       true,
                    bSendTo:     true,
                    bRecv:       false,
                    bRecvFrom:   false,
                    bWSASend:    true,
                    bWSASendTo:  true,
                    bWSARecv:    false,
                    bWSARecvFrom:false
                );

                Socket_Cache.Filter.AddFilter(
                    IsEnable:              true,
                    FID:                   fid,
                    FName:                 RuleName_LargePacket3366,
                    bAppointHeader:        true,
                    HeaderContent:         "3366",        // 包头前两字节 = 0x33 0x66
                    bAppointSocket:        false,
                    SocketContent:         0,
                    bAppointLength:        true,
                    LengthContent:         ">=10000",     // 数据长度 ≥ 1万字节
                    bAppointPort:          false,
                    PortContent:           0,
                    FilterMode:            Socket_Cache.Filter.FilterMode.Normal,
                    FilterAction:          Socket_Cache.Filter.FilterAction.Intercept,
                    IsExecute:             false,
                    FEType:                Socket_Cache.Filter.FilterExecuteType.Send,
                    SID:                   Guid.Empty,
                    RID:                   Guid.Empty,
                    FilterFunction:        func,
                    FilterStartFrom:       Socket_Cache.Filter.FilterStartFrom.Head,
                    IsProgressionDone:     false,
                    IsProgressionContinuous: false,
                    ProgressionStep:       1,
                    IsProgressionCarry:    false,
                    ProgressionCarryNumber: 1,
                    ProgressionPosition:   string.Empty,
                    ProgressionCount:      0,
                    FSearch:               string.Empty,
                    FModify:               string.Empty
                );
            }
            catch (Exception ex)
            {
                Socket_Operation.DoLog(nameof(Register_LargePacket3366), ex.Message);
            }
        }
    }
}
