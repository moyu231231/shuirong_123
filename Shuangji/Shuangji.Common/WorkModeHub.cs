using System;
using System.Collections.Concurrent;

namespace Shuangji.Common
{
    /// <summary>
    /// 进程内模式总线（Host 同进程加载 Engine+Gateway）。
    /// 网页切到「修改」后立即可见，避免网关 HTTP 缓存滞后导致上报漏拦一拍。
    /// </summary>
    public static class WorkModeHub
    {
        private static readonly ConcurrentDictionary<string, int> Modes =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        public static void Set(string user, WorkMode mode)
        {
            if (string.IsNullOrEmpty(user)) return;
            Modes[user] = (int)mode;
        }

        public static WorkMode Get(string user, WorkMode def = WorkMode.Idle)
        {
            int m;
            if (!string.IsNullOrEmpty(user) && Modes.TryGetValue(user, out m))
                return (WorkMode)m;
            return def;
        }

        public static bool IsModify(string user)
        {
            return Get(user) == WorkMode.Modify;
        }
    }
}
