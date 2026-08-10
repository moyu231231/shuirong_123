// ============================================================
// ACE_Sanitizer.cs — ACE反作弊网络数据清洗 (WPE集成模块)
// 移植自: ace_bypass_proxy/server/src/main.rs (Rust v41)
// ============================================================
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Net;
using System.Net.Sockets;

namespace WPELibrary.Lib
{
    public static class ACE_Sanitizer
    {
        // ============================================================
        // ACE 拦截开关 (全局)
        // ============================================================
        public static bool EnableACE { get; set; } = true;
        public static long ACECount = 0;

        // ============================================================
        // CRC32 — 标准实现, 匹配 tersafe sub_D3DEC
        // ============================================================
        private static readonly uint[] CRC32_TABLE = GenerateCRC32Table();

        private static uint[] GenerateCRC32Table()
        {
            var table = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint crc = i;
                for (int j = 0; j < 8; j++)
                {
                    if ((crc & 1) != 0)
                        crc = 0xEDB88320 ^ (crc >> 1);
                    else
                        crc >>= 1;
                }
                table[i] = crc;
            }
            return table;
        }

        public static uint CRC32(byte[] data, int offset, int length)
        {
            uint crc = 0xFFFFFFFF;
            for (int i = offset; i < offset + length; i++)
            {
                crc = CRC32_TABLE[((byte)crc ^ data[i])] ^ (crc >> 8);
            }
            return ~crc;
        }

        public static uint CRC32(byte[] data) { return CRC32(data, 0, data.Length); }

        // ============================================================
        // NJ 域名检测
        // ============================================================
        public static bool IsNJData(byte[] data)
        {
            // NJ ACE帧: 01 00 00 00 魔数
            return data.Length >= 4 
                && data[0] == 0x01 
                && data[1] == 0x00 
                && data[2] == 0x00 
                && data[3] == 0x00;
        }

        // ============================================================
        // 65010 帧检测
        // ============================================================
        public static bool Is65010Data(byte[] data)
        {
            return data.Length >= 2 
                && data[0] == 0x33 
                && data[1] == 0x66;
        }

        // ============================================================
        // 获取socket远程端口
        // ============================================================
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int getpeername(
            IntPtr s, 
            ref sockaddr_in name, 
            ref int namelen);

        [StructLayout(LayoutKind.Sequential)]
        private struct sockaddr_in
        {
            public short sin_family;
            public ushort sin_port;
            public uint sin_addr;
            public ulong sin_zero;
        }

        public static int GetRemotePort(IntPtr socketHandle)
        {
            try
            {
                var addr = new sockaddr_in();
                int len = Marshal.SizeOf(addr);
                int result = getpeername(socketHandle, ref addr, ref len);
                if (result == 0)
                {
                    // sin_port is network byte order
                    return IPAddress.NetworkToHostOrder((short)addr.sin_port);
                }
            }
            catch { }
            return 0;
        }

        // ============================================================
        // NJ 入站清洗 (v41: UIN替换 + 6标记payload清零)
        // ============================================================
        private static readonly byte[] TARGET_UIN = System.Text.Encoding.ASCII.GetBytes("8641756217741712662\0");

        // 6种 01 0A 标记: (u32 LE pattern, payload偏移)
        private struct NJRule { public uint Pattern; public int PayloadOffset; }
        private static readonly NJRule[] NJ_RULES = new NJRule[]
        {
            new NJRule { Pattern = 0x23000A01, PayloadOffset = 42 },  // 01 0A 00 23 → payload @ +42
            new NJRule { Pattern = 0x09000A01, PayloadOffset = 14 },  // 01 0A 00 09 → payload @ +14
            new NJRule { Pattern = 0x08000A01, PayloadOffset = 14 },  // 01 0A 00 08 → payload @ +14
            new NJRule { Pattern = 0x00010A01, PayloadOffset = 14 },  // 01 0A 01 00 → payload @ +14
            new NJRule { Pattern = 0xF1000A01, PayloadOffset = 14 },  // 01 0A 00 F1 → payload @ +14 (稀有)
            new NJRule { Pattern = 0x34B80A01, PayloadOffset = 14 },  // 01 0A B8 34 → payload @ +14 (稀有)
        };

        public static byte[] SanitizeNJInbound(byte[] data)
        {
            var result = (byte[])data.Clone();
            bool changed = false;

            // UIN替换: 01 0A 00 23 标记 +18 处替换20B
            byte[] marker23 = BitConverter.GetBytes(0x23000A01u);
            for (int i = 0; i <= result.Length - 38; i++)
            {
                if (result[i] == marker23[0] && result[i + 1] == marker23[1] 
                    && result[i + 2] == marker23[2] && result[i + 3] == marker23[3])
                {
                    int uinPos = i + 18;
                    if (uinPos + 20 <= result.Length)
                    {
                        Array.Copy(TARGET_UIN, 0, result, uinPos, 20);
                        changed = true;
                    }
                }
            }

            // payload清零: 6种标记
            foreach (var rule in NJ_RULES)
            {
                byte[] marker = BitConverter.GetBytes(rule.Pattern);
                for (int i = 0; i <= result.Length - 4; i++)
                {
                    if (result[i] == marker[0] && result[i + 1] == marker[1]
                        && result[i + 2] == marker[2] && result[i + 3] == marker[3])
                    {
                        int start = i + rule.PayloadOffset;
                        int end = Math.Min(start + 512, result.Length);
                        for (int j = start; j < end; j++)
                        {
                            if (result[j] != 0)
                            {
                                result[j] = 0;
                                changed = true;
                            }
                        }
                    }
                }
            }

            return changed ? result : null;
        }

        // ============================================================
        // 65010 出站清洗: 40_13>22B → 零化 +0x14~帧尾
        // ============================================================
        public static byte[] Sanitize65010Outbound(byte[] data)
        {
            var result = (byte[])data.Clone();
            bool changed = false;

            // 找所有 33 66 标记
            var markers = new List<int>();
            for (int i = 0; i <= result.Length - 2; i++)
            {
                if (result[i] == 0x33 && result[i + 1] == 0x66)
                {
                    markers.Add(i);
                    i++;
                }
            }

            if (markers.Count == 0) return null;

            for (int i = 0; i < markers.Count; i++)
            {
                int frameStart = markers[i];
                int frameEnd = (i + 1 < markers.Count) ? markers[i + 1] : result.Length;

                if (frameStart + 8 < frameEnd)
                {
                    // 读取 variant (LE uint16)
                    ushort variant = BitConverter.ToUInt16(result, frameStart + 6);
                    
                    // 40_13帧, 超过22B → 零化 +0x14~帧尾
                    if (variant == 0x1340 && frameEnd - frameStart > 22)
                    {
                        for (int j = frameStart + 0x14; j < frameEnd; j++)
                        {
                            if (result[j] != 0)
                            {
                                result[j] = 0;
                                changed = true;
                            }
                        }
                    }
                }
            }

            return changed ? result : null;
        }

        // ============================================================
        // 综合入口: 根据端口自动选择清洗策略
        // ============================================================
        public static byte[] SanitizeOutbound(IntPtr socket, byte[] data)
        {
            if (!EnableACE) return null;
            int port = GetRemotePort(socket);
            if (port == 65010 && Is65010Data(data))
            {
                var result = Sanitize65010Outbound(data);
                if (result != null) System.Threading.Interlocked.Increment(ref ACECount);
                return result;
            }
            return null;
        }

        public static byte[] SanitizeInbound(IntPtr socket, byte[] data, int dataLen)
        {
            if (!EnableACE) return null;
            if (IsNJData(data))
            {
                var result = SanitizeNJInbound(data);
                if (result != null) System.Threading.Interlocked.Increment(ref ACECount);
                return result;
            }
            return null;
        }
    }
}
