using System;

namespace Shuangji.Common
{
    public static class Ports
    {
        public const int Account = 9100;
        public const int Engine = 9200;
        public const int EngineWeb = 8088;
        public const int Socks = 1080;
    }

    public enum WorkMode
    {
        Idle = 0,
        Collect = 1,  // 读取模式（上号绿色期）
        Modify = 2,   // 修改模式（局内，含 65010）
        Lobby = 3     // 大厅：只改 NJ，不动 65010
    }

    public sealed class AccountDto
    {
        public string UserName { get; set; }
        public string Password { get; set; }
        public bool Enabled { get; set; } = true;
        public string Remark { get; set; }
        public DateTime CreatedAt { get; set; } = DateTime.Now;
        public DateTime? ExpireAt { get; set; }
        /// <summary>单账号最大并发 SOCKS 连接数；0=不限制。</summary>
        public int MaxConnections { get; set; } = 10;
    }

    public sealed class OnlineUserDto
    {
        public string UserName { get; set; }
        public int Connections { get; set; }
        public int MaxConnections { get; set; }
        public string RemoteIps { get; set; }
        public DateTime FirstSeen { get; set; }
        public DateTime LastSeen { get; set; }
    }

    public sealed class AuthRequest
    {
        public string UserName { get; set; }
        public string Password { get; set; }
    }

    public sealed class AuthResponse
    {
        public bool Ok { get; set; }
        public string Message { get; set; }
        public string UserName { get; set; }
        public string Token { get; set; }
        public int MaxConnections { get; set; }
    }

    public sealed class ModeRequest
    {
        public string UserName { get; set; }
        public string Password { get; set; }
        public WorkMode Mode { get; set; }
    }

    public sealed class AccountStatusDto
    {
        public string UserName { get; set; }
        public WorkMode Mode { get; set; }
        public int PoolCount { get; set; }
        public int PoolVersion { get; set; }
        public long CollectCount { get; set; }
        public long ModifyCount { get; set; }
        public DateTime? LastCollectAt { get; set; }
        public DateTime? LastModifyAt { get; set; }
        public bool Online { get; set; }
        /// <summary>开启加速：拦截 65010 下行 3366 大包 + 池替换。</summary>
        public bool BoostEnabled { get; set; }
        public long BoostInterceptCount { get; set; }
        public int Pool65010Count { get; set; }
        /// <summary>绿色样本已冻结（等同双机干净机抓完后锁定，重置才可再读）。</summary>
        public bool GreenFrozen { get; set; }
        /// <summary>大厅就绪：至少有 NJ/下行绿样本。</summary>
        public bool ReadyLobby { get; set; }
        /// <summary>局内就绪：有 NJ 下行绿即可（65010 走上行清洗，不依赖绿池）。</summary>
        public bool ReadyModify { get; set; }
        /// <summary>给人看的就绪文案（未读取/读取中/已就绪）。</summary>
        public string ReadyText { get; set; }
    }

    public sealed class PacketJob
    {
        public string UserName { get; set; }
        public string Host { get; set; }
        public int Port { get; set; }
        public bool IsServerToClient { get; set; } // true=服务器下发
        public byte[] Data { get; set; }
        public string HexPreview { get; set; }
    }

    public sealed class PacketResult
    {
        public bool Modified { get; set; }
        public byte[] Data { get; set; }
        public string Action { get; set; } // none/collect/replace/passthrough
        public string Message { get; set; }
    }

    public static class Json
    {
        // 轻量 JSON，避免依赖 Newtonsoft（用简单手写/ DataContract）
        public static string Escape(string s)
        {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }
    }
}
