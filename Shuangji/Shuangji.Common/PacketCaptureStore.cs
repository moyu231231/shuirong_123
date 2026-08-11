using System;
using System.Collections.Generic;
using System.Text;

namespace Shuangji.Common
{
    /// <summary>抓包条目（花瓶/Charles 风格展示用）。</summary>
    public sealed class CapturedPacket
    {
        public DateTime Time { get; set; }
        public string User { get; set; }
        public string Host { get; set; }
        public int Port { get; set; }
        public bool Downlink { get; set; } // true=接收/下行
        public int Length { get; set; }
        public string Tags { get; set; }
        public string Action { get; set; }
        public byte[] Data { get; set; }

        public string DirText { get { return Downlink ? "接收" : "上行"; } }
        public string Summary
        {
            get
            {
                return string.Format("{0:HH:mm:ss.fff}  {1}  {2}:{3}  {4}B  {5}  {6}",
                    Time, DirText, Host, Port, Length, Tags, Action);
            }
        }
    }

    /// <summary>网关进程内抓包环形缓冲 + 十六进制格式化。</summary>
    public static class PacketCaptureStore
    {
        private static readonly object Lock = new object();
        private static readonly List<CapturedPacket> Items = new List<CapturedPacket>();
        public const int MaxItems = 500;
        public const int MaxStoreBytes = 8192;

        public static event Action Changed;

        public static void Add(string user, string host, int port, bool down, byte[] data, string action)
        {
            if (data == null || data.Length == 0) return;
            // 只收业务通道，避免刷屏
            if (!IsInteresting(host, port, data)) return;

            int n = Math.Min(data.Length, MaxStoreBytes);
            var copy = new byte[n];
            Buffer.BlockCopy(data, 0, copy, 0, n);

            var item = new CapturedPacket
            {
                Time = DateTime.Now,
                User = user ?? "",
                Host = host ?? "",
                Port = port,
                Downlink = down,
                Length = data.Length,
                Tags = DetectTags(copy),
                Action = action ?? "",
                Data = copy
            };

            lock (Lock)
            {
                Items.Insert(0, item);
                while (Items.Count > MaxItems) Items.RemoveAt(Items.Count - 1);
            }
            try { Changed?.Invoke(); } catch { }
        }

        public static List<CapturedPacket> Snapshot()
        {
            lock (Lock) return new List<CapturedPacket>(Items);
        }

        public static void Clear()
        {
            lock (Lock) Items.Clear();
            try { Changed?.Invoke(); } catch { }
        }

        public static bool IsInteresting(string host, int port, byte[] data)
        {
            if (port == 65010 || port == 10012 || port == 10011 || port == 10013)
                return true;
            if (AceCdnRules.IsWatchHost(host))
                return true;
            return data != null && (HasNjMarker(data) || Has4013(data));
        }

        public static string DetectTags(byte[] data)
        {
            if (data == null) return "";
            var tags = new List<string>();
            if (Has4013(data)) tags.Add("4013");
            if (Contains(data, 0x01, 0x0A, 0x00, 0x23)) tags.Add("NJ检测23");
            if (Contains(data, 0x01, 0x0A, 0x00, 0x09)) tags.Add("NJ-09");
            if (Contains(data, 0x00, 0x00, 0x0A, 0x92) || Contains(data, 0x0A, 0x92))
                tags.Add("0A92会话");
            if (data.Length >= 4 && data[0] == 0x01 && data[1] == 0x00 && data[2] == 0x00)
                tags.Add(string.Format("帧TT={0:X2}", data[3]));
            // 密文/压缩体：无可打印比例高
            if (data.Length > 64 && PrintableRatio(data) < 0.15)
                tags.Add("密文/文件体");
            return string.Join(",", tags);
        }

        /// <summary>花瓶风格：地址 | HEX | ASCII</summary>
        public static string FormatHexDump(byte[] data, int maxBytes = 4096)
        {
            if (data == null || data.Length == 0) return "(空)";
            int n = Math.Min(data.Length, maxBytes);
            var sb = new StringBuilder(n * 4);
            for (int i = 0; i < n; i += 16)
            {
                sb.AppendFormat("{0:X8}  ", i);
                var ascii = new char[16];
                for (int j = 0; j < 16; j++)
                {
                    if (i + j < n)
                    {
                        byte b = data[i + j];
                        sb.AppendFormat("{0:X2} ", b);
                        ascii[j] = (b >= 32 && b <= 126) ? (char)b : '.';
                    }
                    else
                    {
                        sb.Append("   ");
                        ascii[j] = ' ';
                    }
                    if (j == 7) sb.Append(' ');
                }
                sb.Append(" |");
                sb.Append(ascii);
                sb.Append("|\r\n");
            }
            if (data.Length > maxBytes)
                sb.AppendFormat("... 共 {0} 字节，仅显示前 {1}\r\n", data.Length, maxBytes);
            return sb.ToString();
        }

        private static bool Has4013(byte[] data)
        {
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 8; i++)
            {
                if (data[i] == 0x33 && data[i + 1] == 0x66
                    && data[i + 2] == 0x00 && data[i + 3] == 0x0B
                    && data[i + 4] == 0x00 && data[i + 5] == 0x0C
                    && data[i + 6] == 0x40 && data[i + 7] == 0x13)
                    return true;
            }
            return false;
        }

        private static bool HasNjMarker(byte[] data)
        {
            return Contains(data, 0x01, 0x0A, 0x00, 0x23)
                   || Contains(data, 0x01, 0x0A, 0x00, 0x09)
                   || (data.Length >= 4 && data[0] == 0x01 && data[1] == 0x00 && data[2] == 0x00);
        }

        private static bool Contains(byte[] data, params byte[] pat)
        {
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - pat.Length; i++)
            {
                bool ok = true;
                for (int j = 0; j < pat.Length; j++)
                    if (data[i + j] != pat[j]) { ok = false; break; }
                if (ok) return true;
            }
            return false;
        }

        private static double PrintableRatio(byte[] data)
        {
            int lim = Math.Min(data.Length, 512);
            int p = 0;
            for (int i = 0; i < lim; i++)
                if (data[i] >= 32 && data[i] <= 126) p++;
            return (double)p / lim;
        }
    }
}
