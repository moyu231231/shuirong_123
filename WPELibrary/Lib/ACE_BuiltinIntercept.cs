using System.Threading;

namespace WPELibrary.Lib
{
    /// <summary>
    /// 内置拦截：发送方向包头 0x33 0x66 且长度 ≥ 10000 字节时直接拦截。
    /// </summary>
    public static class ACE_BuiltinIntercept
    {
        public static bool Enabled { get; set; } = true;
        public static long InterceptCount;

        private const int MinLength = 10000;

        public static bool ShouldIntercept(byte[] data)
        {
            if (!Enabled || data == null)
                return false;

            return data.Length >= MinLength
                && data[0] == 0x33
                && data[1] == 0x66;
        }

        public static bool ShouldIntercept(Span<byte> data)
        {
            if (!Enabled || data.Length < 2)
                return false;

            return data.Length >= MinLength
                && data[0] == 0x33
                && data[1] == 0x66;
        }

        public static void RecordIntercept()
        {
            Interlocked.Increment(ref InterceptCount);
        }
    }
}
