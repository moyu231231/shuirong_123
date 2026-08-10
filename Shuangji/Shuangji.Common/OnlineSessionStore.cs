using System;
using System.Collections.Generic;
using System.Linq;

namespace Shuangji.Common
{
    /// <summary>账号中枢侧在线会话汇总（由 Gateway 上报）。</summary>
    public sealed class OnlineSessionStore
    {
        private sealed class Conn
        {
            public string Id;
            public string User;
            public string RemoteIp;
            public DateTime OpenedAt;
            public DateTime LastSeen;
        }

        private readonly object _lock = new object();
        private readonly Dictionary<string, Conn> _conns = new Dictionary<string, Conn>(StringComparer.OrdinalIgnoreCase);

        public void Open(string user, string connId, string remoteIp)
        {
            if (string.IsNullOrWhiteSpace(user) || string.IsNullOrWhiteSpace(connId)) return;
            lock (_lock)
            {
                var now = DateTime.Now;
                _conns[connId] = new Conn
                {
                    Id = connId,
                    User = user.Trim(),
                    RemoteIp = remoteIp ?? "",
                    OpenedAt = now,
                    LastSeen = now
                };
            }
        }

        public void Touch(string connId)
        {
            if (string.IsNullOrWhiteSpace(connId)) return;
            lock (_lock)
            {
                if (_conns.TryGetValue(connId, out var c))
                    c.LastSeen = DateTime.Now;
            }
        }

        public void Close(string connId)
        {
            if (string.IsNullOrWhiteSpace(connId)) return;
            lock (_lock) _conns.Remove(connId);
        }

        public void CloseUser(string user)
        {
            if (string.IsNullOrWhiteSpace(user)) return;
            lock (_lock)
            {
                var keys = _conns.Where(kv =>
                        string.Equals(kv.Value.User, user, StringComparison.OrdinalIgnoreCase))
                    .Select(kv => kv.Key).ToList();
                foreach (var k in keys) _conns.Remove(k);
            }
        }

        /// <summary>清理超过指定分钟无活动的僵尸会话。</summary>
        public int PurgeStale(int minutes = 30)
        {
            var cut = DateTime.Now.AddMinutes(-Math.Max(1, minutes));
            lock (_lock)
            {
                var keys = _conns.Where(kv => kv.Value.LastSeen < cut).Select(kv => kv.Key).ToList();
                foreach (var k in keys) _conns.Remove(k);
                return keys.Count;
            }
        }

        public List<OnlineUserDto> Snapshot(Func<string, int> maxConnOf)
        {
            lock (_lock)
            {
                return _conns.Values
                    .GroupBy(c => c.User, StringComparer.OrdinalIgnoreCase)
                    .Select(g =>
                    {
                        var ips = g.Select(x => x.RemoteIp).Where(x => !string.IsNullOrEmpty(x)).Distinct().ToList();
                        return new OnlineUserDto
                        {
                            UserName = g.Key,
                            Connections = g.Count(),
                            MaxConnections = maxConnOf != null ? maxConnOf(g.Key) : 0,
                            RemoteIps = string.Join(", ", ips),
                            FirstSeen = g.Min(x => x.OpenedAt),
                            LastSeen = g.Max(x => x.LastSeen)
                        };
                    })
                    .OrderByDescending(x => x.LastSeen)
                    .ToList();
            }
        }

        public int TotalConnections()
        {
            lock (_lock) return _conns.Count;
        }
    }
}
