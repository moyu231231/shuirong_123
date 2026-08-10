using System;
using System.Collections.Concurrent;

namespace Shuangji.Common
{
    /// <summary>
    /// 进修改模式时请求断开该账号当前全部 65010 连接，
    /// 让带 UID 特征位的包重新下发一次，便于只改那个位置。
    /// Host 同进程内 Gateway 订阅即可生效。
    /// </summary>
    public static class Port65010Control
    {
        private static readonly ConcurrentDictionary<string, byte> Pending =
            new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);

        private static readonly ConcurrentDictionary<string, ConcurrentDictionary<Guid, Action>> Active =
            new ConcurrentDictionary<string, ConcurrentDictionary<Guid, Action>>(StringComparer.OrdinalIgnoreCase);

        public static void RequestDrop(string user)
        {
            if (string.IsNullOrWhiteSpace(user)) return;
            Pending[user] = 1;
            if (Active.TryGetValue(user, out var map))
            {
                foreach (var kv in map)
                {
                    try { kv.Value?.Invoke(); } catch { }
                }
            }
        }

        public static bool ConsumePending(string user)
        {
            if (string.IsNullOrWhiteSpace(user)) return false;
            return Pending.TryRemove(user, out _);
        }

        public static Guid Register(string user, Action close)
        {
            var id = Guid.NewGuid();
            if (string.IsNullOrWhiteSpace(user) || close == null) return id;
            var map = Active.GetOrAdd(user, _ => new ConcurrentDictionary<Guid, Action>());
            map[id] = close;
            if (Pending.ContainsKey(user))
            {
                try { close(); } catch { }
            }
            return id;
        }

        public static void Unregister(string user, Guid id)
        {
            if (string.IsNullOrWhiteSpace(user)) return;
            if (Active.TryGetValue(user, out var map))
            {
                map.TryRemove(id, out _);
                if (map.IsEmpty) Active.TryRemove(user, out _);
            }
        }
    }
}
