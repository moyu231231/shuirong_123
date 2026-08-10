using System;
using System.IO;

namespace Shuangji.Common
{
    /// <summary>
    /// 65010 下行「检测文件」拦截。
    /// 帧：33 66 00 0B 00 0C 40 13 | … | 19 00 00 TT | …
    /// dump 中 TT∈{06,07,09,0A,0F,11,12,16,17,18,1B,1D,44,66} 为文件块；
    /// TT∈{00..04} 小包/保活放行。网关本地执行，防引擎超时放行。
    /// </summary>
    public sealed class Port65010DownlinkFilter
    {
        private byte[] _leftover;
        private bool _dropping;

        public static bool IsDetectionFileTlv(byte tt)
        {
            switch (tt)
            {
                case 0x06: case 0x07: case 0x09: case 0x0A:
                case 0x0F: case 0x11: case 0x12:
                case 0x16: case 0x17: case 0x18:
                case 0x1B: case 0x1D:
                case 0x44: case 0x66:
                    return true;
                default:
                    return false;
            }
        }

        public static bool HasDetectionFileFrame(byte[] data, int start, int length)
        {
            if (data == null || length < 20) return false;
            int end = start + length;
            for (int i = start; i <= end - 20; i++)
            {
                if (!Port65010UplinkFilter.Is4013At(data, i)) continue;
                if (data[i + 16] == 0x19 && data[i + 17] == 0x00 && data[i + 18] == 0x00
                    && IsDetectionFileTlv(data[i + 19]))
                    return true;
            }
            return false;
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
            if (_dropping)
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
                _dropping = false;
            }

            using (var ms = new MemoryStream(data.Length))
            {
                while (i < data.Length)
                {
                    if (i + 8 > data.Length)
                    {
                        KeepFrom(data, i);
                        break;
                    }

                    if (!Port65010UplinkFilter.IsFrameAt(data, i))
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

                    // 半包：4013 头已见但不够读 TT
                    if (Port65010UplinkFilter.Is4013At(data, i) && next < 0 && data.Length - i < 20)
                    {
                        KeepFrom(data, i);
                        break;
                    }

                    bool drop = false;
                    if (Port65010UplinkFilter.Is4013At(data, i) && i + 20 <= data.Length
                        && data[i + 16] == 0x19 && data[i + 17] == 0x00 && data[i + 18] == 0x00
                        && IsDetectionFileTlv(data[i + 19]))
                        drop = true;
                    // 无完整 TT 但已是超大 4013 段：当检测文件丢
                    else if (Port65010UplinkFilter.Is4013At(data, i) && frameEnd - i >= 1500)
                        drop = true;

                    if (drop)
                    {
                        droppedBytes += frameEnd - i;
                        if (next < 0)
                        {
                            _dropping = true;
                            KeepTail(data, data.Length);
                            break;
                        }
                        i = frameEnd;
                        continue;
                    }

                    ms.Write(data, i, frameEnd - i);
                    i = frameEnd;
                }
                return ms.ToArray();
            }
        }

        private void KeepFrom(byte[] data, int i)
        {
            int keep = data.Length - i;
            if (keep <= 0) { _leftover = null; return; }
            _leftover = new byte[keep];
            Buffer.BlockCopy(data, i, _leftover, 0, keep);
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
                if (Port65010UplinkFilter.IsFrameAt(data, i)) return i;
            }
            return -1;
        }
    }
}
