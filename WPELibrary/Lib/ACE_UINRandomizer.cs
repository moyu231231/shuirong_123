using System;
using System.Threading;

namespace WPELibrary.Lib
{
    public static class ACE_UINRandomizer
    {
        // ── 开关 & 计数 ──────────────────────────────────────────
        public static bool EnableUIN = true;
        public static long UINCount = 0;

        private static readonly Random rng = new Random();

        // NJ inbound marker: 01 0A 00 23
        private static readonly byte[] Marker = { 0x01, 0x0A, 0x00, 0x23 };

        // Offset from marker start to UIN's first digit byte
        private const int UinOffset = 18;

        // 19 ASCII digits (index 18 is last digit; index 19 is the null terminator, never touched)
        private const int UinDigitLength = 19;

        /// <summary>
        /// 扫描 data 中的 01 0A 00 23 标记，将 UIN 的 1-2 位随机改为 '0'-'9'。
        /// 返回修改后的副本；无匹配或开关关闭时返回 null。
        /// </summary>
        public static byte[] Randomize(byte[] data)
        {
            if (!EnableUIN) return null;
            if (data == null || data.Length < Marker.Length + UinOffset + 20)
                return null;

            int markerPos = IndexOf(data, Marker);
            if (markerPos < 0) return null;

            int uinStart = markerPos + UinOffset;
            if (uinStart + 20 > data.Length) return null;

            byte[] result = (byte[])data.Clone();

            // 随机改 1 或 2 个不重复位置
            int count = rng.Next(1, 3);
            int[] positions = PickDistinctPositions(count, UinDigitLength);
            foreach (int pos in positions)
                result[uinStart + pos] = (byte)(0x30 + rng.Next(0, 10));

            Interlocked.Increment(ref UINCount);
            return result;
        }

        private static int IndexOf(byte[] source, byte[] pattern)
        {
            int limit = source.Length - pattern.Length;
            for (int i = 0; i <= limit; i++)
            {
                bool match = true;
                for (int j = 0; j < pattern.Length; j++)
                {
                    if (source[i + j] != pattern[j]) { match = false; break; }
                }
                if (match) return i;
            }
            return -1;
        }

        private static int[] PickDistinctPositions(int count, int range)
        {
            if (count == 1) return new[] { rng.Next(0, range) };
            int a = rng.Next(0, range);
            int b;
            do { b = rng.Next(0, range); } while (b == a);
            return new[] { a, b };
        }
    }
}
