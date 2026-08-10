using System;
using System.IO;

namespace Shuangji.Common
{
    /// <summary>
    /// 65010 上行「举报/异常上报」拦截（对齐 WPE ACE_Filter Send）：
    /// 精确头 33 66 00 0B 00 0C 40 13 → 整帧丢弃。
    /// 仅在局内(Modify)启用；读取/大厅必须放行，否则上不了号。
    /// </summary>
    public sealed class Port65010UplinkFilter
    {
        private byte[] _leftover;
        private bool _dropping4013;

        public static bool Contains4013Header(byte[] data)
        {
            return Contains4013Header(data, 0, data?.Length ?? 0);
        }

        public static bool Contains4013Header(byte[] data, int start, int length)
        {
            if (data == null || length < 8) return false;
            int end = start + length - 7;
            for (int i = start; i < end; i++)
            {
                if (Is4013At(data, i)) return true;
            }
            return false;
        }

        public static bool Is4013At(byte[] data, int i)
        {
            return i >= 0 && i + 8 <= data.Length
                   && data[i] == 0x33 && data[i + 1] == 0x66
                   && data[i + 2] == 0x00 && data[i + 3] == 0x0B
                   && data[i + 4] == 0x00 && data[i + 5] == 0x0C
                   && data[i + 6] == 0x40 && data[i + 7] == 0x13;
        }

        public static bool IsFrameAt(byte[] data, int i)
        {
            return i >= 0 && i + 8 <= data.Length
                   && data[i] == 0x33 && data[i + 1] == 0x66
                   && data[i + 2] == 0x00 && data[i + 3] == 0x0B
                   && data[i + 4] == 0x00 && data[i + 5] == 0x0C;
        }

        public byte[] Filter(byte[] chunk, out int droppedBytes)
        {
            droppedBytes = 0;
            if (chunk == null || chunk.Length == 0)
                return chunk ?? new byte[0];

            byte[] data;
            if (_leftover != null && _leftover.Length > 0)
            {
                data = new byte[_leftover.Length + chunk.Length];
                Buffer.BlockCopy(_leftover, 0, data, 0, _leftover.Length);
                Buffer.BlockCopy(chunk, 0, data, _leftover.Length, chunk.Length);
                _leftover = null;
            }
            else data = chunk;

            int i = 0;
            if (_dropping4013)
            {
                int next = IndexOfFrame(data, 0);
                if (next < 0)
                {
                    droppedBytes = data.Length;
                    KeepTail(data, data.Length);
                    return new byte[0];
                }
                droppedBytes += next;
                i = next;
                _dropping4013 = false;
            }

            using (var ms = new MemoryStream(data.Length))
            {
                while (i < data.Length)
                {
                    if (i + 8 > data.Length)
                    {
                        int keep = data.Length - i;
                        _leftover = new byte[keep];
                        Buffer.BlockCopy(data, i, _leftover, 0, keep);
                        break;
                    }

                    if (!IsFrameAt(data, i))
                    {
                        if (data[i] == 0x33 && i + 1 == data.Length)
                        {
                            _leftover = new[] { data[i] };
                            break;
                        }
                        ms.WriteByte(data[i]);
                        i++;
                        continue;
                    }

                    int next = IndexOfFrame(data, i + 8);
                    int frameEnd = next >= 0 ? next : data.Length;
                    if (next < 0 && data.Length - i < 16)
                    {
                        int keep = data.Length - i;
                        _leftover = new byte[keep];
                        Buffer.BlockCopy(data, i, _leftover, 0, keep);
                        break;
                    }

                    int flen = frameEnd - i;
                    // WPE：凡 40 13 上报帧一律丢（局内）
                    if (Is4013At(data, i))
                    {
                        droppedBytes += flen;
                        if (next < 0)
                        {
                            _dropping4013 = true;
                            KeepTail(data, data.Length);
                            break;
                        }
                        i = frameEnd;
                        continue;
                    }

                    ms.Write(data, i, flen);
                    i = frameEnd;
                }

                return ms.ToArray();
            }
        }

        private void KeepTail(byte[] data, int end)
        {
            int keep = Math.Min(7, end);
            if (keep <= 0) { _leftover = null; return; }
            _leftover = new byte[keep];
            Buffer.BlockCopy(data, end - keep, _leftover, 0, keep);
        }

        private static int IndexOfFrame(byte[] data, int start)
        {
            for (int i = start; i <= data.Length - 8; i++)
            {
                if (IsFrameAt(data, i)) return i;
            }
            return -1;
        }
    }
}
