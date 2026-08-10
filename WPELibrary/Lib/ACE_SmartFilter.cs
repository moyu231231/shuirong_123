using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Xml.Linq;

namespace WPELibrary.Lib
{
    /// <summary>
    /// 智能滤镜：收集 NJ 校验值(Info1/Info2) + 数据处理时按相似度替换（伪心跳）。
    /// 校验头格式: 00 01 [Info1:4B] 01 00 09 [Info2:1B]
    /// 内容块标记: 01 0A 00 09
    /// 线程安全：Hook 线程只写内部 List，UI 通过 Snapshot/定时刷新读取。
    /// </summary>
    public static class ACE_SmartFilter
    {
        public enum WorkMode
        {
            None = 0,
            Collect = 1,
            Process = 2
        }

        public sealed class PoolEntry
        {
            public string Region { get; set; }
            public string Server { get; set; }
            public byte[] Content { get; set; }
            public byte[] Info1 { get; set; }
            public byte Info2 { get; set; }
            public int ContentLength { get; set; }
            public byte ContentType { get; set; }
            public DateTime CollectedAt { get; set; }
            public string ContentHex { get; set; }
            public string Info1Hex { get; set; }
            public string Info2Hex { get; set; }
        }

        public const int MaxPoolSize = 2000;
        public const int MaxContentStore = 512;

        // ── 开关与模式（原子读写，Hook 线程可读）────────────────
        private static int _mode = (int)WorkMode.None;
        public static WorkMode Mode
        {
            get { return (WorkMode)Volatile.Read(ref _mode); }
            set { Volatile.Write(ref _mode, (int)value); }
        }

        public static volatile bool EnableProcess = true;
        public static volatile bool EnableChecksumRepairSend = true;
        public static volatile bool CancelOutOfBound = true;
        public static volatile bool Only04Cheat = false;
        public static volatile bool Ignore00 = false;
        public static volatile bool Ignore01 = false;
        public static volatile bool Ignore02 = false;
        public static volatile bool Ignore03 = false;
        public static volatile bool Ignore04 = false;
        public static string DefaultRegion = "ios";
        public static string DefaultServer = "QQ";

        // ── 计数 ───────────────────────────────────────────────
        public static long Intercept3366Count = 0;
        public static long FakeHeartbeatReplaceCount = 0;

        private static readonly object _lock = new object();
        private static readonly List<PoolEntry> _pool = new List<PoolEntry>(256);
        private static readonly HashSet<string> _poolKeys = new HashSet<string>(StringComparer.Ordinal);

        // UI 刷新合并：Hook 线程只置位，不回调 UI
        private static int _dirty = 0;
        private static int _version = 0;

        private static readonly byte[] MarkerContent = { 0x01, 0x0A, 0x00, 0x09 };

        public static int PoolCount
        {
            get { lock (_lock) return _pool.Count; }
        }

        public static int Version
        {
            get { return Volatile.Read(ref _version); }
        }

        /// <summary>UI 轮询：是否有新数据需要刷新。</summary>
        public static bool ConsumeDirty()
        {
            return Interlocked.Exchange(ref _dirty, 0) != 0;
        }

        public static void MarkDirty()
        {
            Interlocked.Exchange(ref _dirty, 1);
            Interlocked.Increment(ref _version);
        }

        /// <summary>供 UI 绑定的只读快照（必须在 UI 线程调用）。</summary>
        public static List<PoolEntry> GetSnapshot()
        {
            lock (_lock)
            {
                return new List<PoolEntry>(_pool);
            }
        }

        #region 3366 拦截计数

        public static void Note3366Intercept()
        {
            Interlocked.Increment(ref Intercept3366Count);
        }

        public static long Get3366InterceptCountFromFilter()
        {
            try
            {
                var f = Socket_Cache.FilterList.lstFilter
                    .FirstOrDefault(x => x.FName == "[内置] 3366大包拦截(≥10000字节)");
                if (f != null) return Math.Max(f.ExecutionCount, Intercept3366Count);
            }
            catch { }
            return Intercept3366Count;
        }

        #endregion

        #region 主入口

        public static byte[] ProcessBuffer(byte[] data, bool isSend)
        {
            if (data == null || data.Length < 20) return null;

            try
            {
                var mode = Mode;
                if (mode == WorkMode.Collect)
                {
                    // 快速预检：没有目标特征直接跳过，避免每个包全扫描卡死
                    if (!HasCollectSignature(data)) return null;
                    CollectFromPacket(data);
                    return null;
                }

                if (mode == WorkMode.Process && EnableProcess)
                {
                    if (isSend && !EnableChecksumRepairSend) return null;
                    if (!HasCollectSignature(data)) return null;
                    return ReplaceChecksums(data);
                }
            }
            catch (Exception ex)
            {
                try { Socket_Operation.DoLog(nameof(ProcessBuffer), ex.Message); } catch { }
            }
            return null;
        }

        /// <summary>快速判断包内是否可能含校验头或内容标记。大包只扫前 64KB。</summary>
        private static bool HasCollectSignature(byte[] data)
        {
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 4; i++)
            {
                byte b0 = data[i];
                if (b0 != 0x01) continue;
                // 01 0A 00 09
                if (data[i + 1] == 0x0A && data[i + 2] == 0x00 && data[i + 3] == 0x09)
                    return true;
                // 01 00 09 （校验尾）
                if (data[i + 1] == 0x00 && data[i + 2] == 0x09)
                    return true;
            }
            return false;
        }

        #endregion

        #region 收集

        public static int CollectFromPacket(byte[] data)
        {
            if (data == null || data.Length < 24) return 0;
            int added = 0;

            try
            {
                // 大包限制扫描范围，防止 Hook 线程长时间占用
                int scanLen = Math.Min(data.Length, 65536);
                int limit = scanLen - 10;
                for (int i = 0; i <= limit; i++)
                {
                    if (data[i] != 0x00 || data[i + 1] != 0x01) continue;
                    if (data[i + 6] != 0x01 || data[i + 7] != 0x00 || data[i + 8] != 0x09) continue;

                    byte[] info1 = new byte[] { data[i + 2], data[i + 3], data[i + 4], data[i + 5] };
                    byte info2 = data[i + 9];

                    int contentPos = IndexOf(data, MarkerContent, i + 10);
                    if (contentPos < 0 || contentPos - i > 2500) continue;

                    int contentLen = GuessContentLength(data, contentPos);
                    if (contentLen < 14)
                    {
                        if (!CancelOutOfBound) continue;
                        contentLen = Math.Min(Math.Max(64, data.Length - contentPos), MaxContentStore);
                    }

                    if (contentPos + contentLen > data.Length)
                    {
                        if (!CancelOutOfBound) continue;
                        contentLen = data.Length - contentPos;
                    }
                    if (contentLen < 14) continue;

                    // 存储截断，避免大包拖垮内存/UI
                    int storeLen = Math.Min(contentLen, MaxContentStore);
                    byte[] content = new byte[storeLen];
                    Buffer.BlockCopy(data, contentPos, content, 0, storeLen);
                    byte ctype = storeLen > 14 ? content[14] : (byte)0;

                    if (!PassTypeFilters(ctype)) continue;

                    if (TryAddEntry(new PoolEntry
                    {
                        Region = DefaultRegion ?? "ios",
                        Server = DefaultServer ?? "QQ",
                        Content = content,
                        Info1 = info1,
                        Info2 = info2,
                        ContentLength = contentLen,
                        ContentType = ctype,
                        CollectedAt = DateTime.Now,
                        ContentHex = BytesToHex(content, 48),
                        Info1Hex = BytesToHex(info1, 4),
                        Info2Hex = info2.ToString("X2")
                    }))
                    {
                        added++;
                    }

                    // 跳过已匹配区域，减少重复扫描
                    i = Math.Max(i, contentPos);
                }
            }
            catch (Exception ex)
            {
                try { Socket_Operation.DoLog(nameof(CollectFromPacket), ex.Message); } catch { }
            }

            return added;
        }

        private static bool TryAddEntry(PoolEntry entry)
        {
            if (entry == null || entry.Info1 == null || entry.Info1.Length != 4) return false;
            if (entry.Content == null) entry.Content = Array.Empty<byte>();

            string key = (entry.Info1Hex ?? "") + "|" + (entry.Info2Hex ?? "") + "|" +
                         entry.ContentLength + "|" +
                         BytesToHex(entry.Content, Math.Min(32, entry.Content.Length));

            bool added = false;
            lock (_lock)
            {
                if (_poolKeys.Contains(key)) return false;
                if (_pool.Count >= MaxPoolSize) return false;

                _poolKeys.Add(key);
                _pool.Add(entry);
                added = true;
            }

            if (added) MarkDirty();
            return added;
        }

        #endregion

        #region 替换（伪心跳）

        private static int _fallbackCursor = 0;

        /// <summary>
        /// 伪心跳：凡命中校验头 00 01 II II II II 01 00 09 YY 的「01包」必须改写，
        /// 相似度不够或池为空也不能原样放行。
        /// </summary>
        private static byte[] ReplaceChecksums(byte[] data)
        {
            PoolEntry[] snapshot;
            lock (_lock)
            {
                snapshot = _pool.Count > 0 ? _pool.ToArray() : Array.Empty<PoolEntry>();
            }

            byte[] result = null;
            bool changed = false;
            int limit = data.Length - 10;

            for (int i = 0; i <= limit; i++)
            {
                if (data[i] != 0x00 || data[i + 1] != 0x01) continue;
                if (data[i + 6] != 0x01 || data[i + 7] != 0x00 || data[i + 8] != 0x09) continue;

                // 处理模式：命中即必须替换，不再因忽视过滤/缺内容块而放行
                int contentPos = IndexOf(data, MarkerContent, i + 10);
                int contentLen = 0;
                byte ctype = 0;
                byte[] liveContent = Array.Empty<byte>();

                if (contentPos >= 0 && contentPos - i <= 2500)
                {
                    contentLen = GuessContentLength(data, contentPos);
                    if (contentLen < 14)
                        contentLen = Math.Min(Math.Max(64, data.Length - contentPos), MaxContentStore);
                    if (contentPos + contentLen > data.Length)
                        contentLen = data.Length - contentPos;
                    if (contentLen < 14)
                        contentLen = Math.Min(Math.Max(0, data.Length - contentPos), MaxContentStore);

                    if (contentLen >= 14)
                    {
                        ctype = (contentPos + 14 < data.Length) ? data[contentPos + 14] : (byte)0;
                        int cmpLen = Math.Min(contentLen, MaxContentStore);
                        liveContent = new byte[cmpLen];
                        Buffer.BlockCopy(data, contentPos, liveContent, 0, cmpLen);
                    }
                }

                byte[] newInfo1;
                byte newInfo2;
                PickReplacement(liveContent, contentLen, ctype, snapshot, out newInfo1, out newInfo2);

                if (data[i + 2] == newInfo1[0] && data[i + 3] == newInfo1[1] &&
                    data[i + 4] == newInfo1[2] && data[i + 5] == newInfo1[3] &&
                    data[i + 9] == newInfo2)
                {
                    continue;
                }

                if (result == null) result = (byte[])data.Clone();
                result[i + 2] = newInfo1[0];
                result[i + 3] = newInfo1[1];
                result[i + 4] = newInfo1[2];
                result[i + 5] = newInfo1[3];
                result[i + 9] = newInfo2;
                changed = true;
                Interlocked.Increment(ref FakeHeartbeatReplaceCount);
            }

            return changed ? result : null;
        }

        /// <summary>
        /// 必出一组 Info1/Info2：
        /// 1) 池非空：永远取相似度最高者（无分数门槛）
        /// 2) 仍失败：轮询池中任意有效条目
        /// 3) 池为空：内容哈希合成伪校验，绝不原样放行
        /// </summary>
        private static void PickReplacement(
            byte[] liveContent, int liveLen, byte ctype, PoolEntry[] pool,
            out byte[] info1, out byte info2)
        {
            PoolEntry best = FindBestMatchForced(liveContent, liveLen, ctype, pool);
            if (best != null && best.Info1 != null && best.Info1.Length == 4)
            {
                info1 = best.Info1;
                info2 = best.Info2;
                return;
            }

            if (pool != null && pool.Length > 0)
            {
                int idx = Math.Abs(Interlocked.Increment(ref _fallbackCursor)) % pool.Length;
                for (int k = 0; k < pool.Length; k++)
                {
                    var e = pool[(idx + k) % pool.Length];
                    if (e?.Info1 != null && e.Info1.Length == 4)
                    {
                        info1 = e.Info1;
                        info2 = e.Info2;
                        return;
                    }
                }
            }

            SynthesizeChecksum(liveContent, liveLen, ctype, out info1, out info2);
        }

        private static PoolEntry FindBestMatchForced(byte[] liveContent, int liveLen, byte ctype, PoolEntry[] pool)
        {
            if (pool == null || pool.Length == 0) return null;

            PoolEntry best = null;
            double bestScore = double.MinValue;
            PoolEntry bestAny = null;

            foreach (var e in pool)
            {
                if (e == null || e.Info1 == null || e.Info1.Length != 4) continue;
                if (bestAny == null) bestAny = e;

                double score = 0;
                if (e.ContentType == ctype) score += 50;

                int lenDiff = Math.Abs(e.ContentLength - liveLen);
                score += Math.Max(0, 40 - lenDiff / 8.0);

                if (liveContent != null && liveContent.Length > 0 && e.Content != null)
                    score += PrefixSimilarity(liveContent, e.Content) * 40.0;
                else
                    score += 1;

                if (score > bestScore)
                {
                    bestScore = score;
                    best = e;
                }
            }

            return best ?? bestAny;
        }

        private static void SynthesizeChecksum(byte[] liveContent, int liveLen, byte ctype, out byte[] info1, out byte info2)
        {
            uint h = 0x811C9DC5;
            h ^= (uint)liveLen;
            h *= 0x01000193;
            h ^= ctype;
            h *= 0x01000193;

            if (liveContent != null)
            {
                int n = Math.Min(liveContent.Length, 64);
                for (int i = 0; i < n; i++)
                {
                    h ^= liveContent[i];
                    h *= 0x01000193;
                }
            }

            h ^= (uint)(Environment.TickCount & 0xFFFF);

            info1 = new byte[]
            {
                (byte)(h),
                (byte)(h >> 8),
                (byte)(h >> 16),
                (byte)(h >> 24)
            };
            info2 = (byte)((h >> 16) ^ h ^ 0x93);
            if (info1[0] == 0 && info1[1] == 0 && info1[2] == 0 && info1[3] == 0)
                info1[0] = 0xA5;
        }

        private static double PrefixSimilarity(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length == 0 || b.Length == 0) return 0;
            int start = 14;
            int n = Math.Min(Math.Min(a.Length, b.Length) - start, 64);
            if (n <= 0)
            {
                n = Math.Min(Math.Min(a.Length, b.Length), 16);
                start = 0;
            }
            if (n <= 0) return 0;

            int same = 0;
            for (int i = 0; i < n; i++)
            {
                if (a[start + i] == b[start + i]) same++;
            }
            return (double)same / n;
        }

        #endregion

        #region 过滤辅助

        private static bool PassTypeFilters(byte ctype)
        {
            if (Only04Cheat) return ctype == 0x04;
            if (Ignore00 && ctype == 0x00) return false;
            if (Ignore01 && ctype == 0x01) return false;
            if (Ignore02 && ctype == 0x02) return false;
            if (Ignore03 && ctype == 0x03) return false;
            if (Ignore04 && ctype == 0x04) return false;
            return true;
        }

        private static int GuessContentLength(byte[] data, int contentPos)
        {
            try
            {
                if (contentPos >= 8 &&
                    data[contentPos - 6] == 0x00 && data[contentPos - 5] == 0x00 &&
                    data[contentPos - 4] == 0x00 && data[contentPos - 3] == 0x01 &&
                    data[contentPos - 2] == data[contentPos - 8] &&
                    data[contentPos - 1] == data[contentPos - 7])
                {
                    int be = (data[contentPos - 8] << 8) | data[contentPos - 7];
                    if (be >= 14 && be <= 65535 && contentPos + be <= data.Length) return be;
                }

                int next = IndexOf(data, MarkerContent, contentPos + 4);
                if (next > contentPos) return next - contentPos;
                return Math.Min(data.Length - contentPos, 1024);
            }
            catch
            {
                return Math.Min(Math.Max(0, data.Length - contentPos), 256);
            }
        }

        private static int IndexOf(byte[] source, byte[] pattern, int start)
        {
            if (source == null || pattern == null) return -1;
            int limit = source.Length - pattern.Length;
            if (limit < 0) return -1;
            for (int i = Math.Max(0, start); i <= limit; i++)
            {
                bool ok = true;
                for (int j = 0; j < pattern.Length; j++)
                {
                    if (source[i + j] != pattern[j]) { ok = false; break; }
                }
                if (ok) return i;
            }
            return -1;
        }

        #endregion

        #region 数据池管理 / 持久化

        public static void ClearPool()
        {
            lock (_lock)
            {
                _pool.Clear();
                _poolKeys.Clear();
            }
            MarkDirty();
        }

        public static void RemoveAt(int index)
        {
            lock (_lock)
            {
                if (index < 0 || index >= _pool.Count) return;
                var e = _pool[index];
                string key = (e.Info1Hex ?? "") + "|" + (e.Info2Hex ?? "") + "|" + e.ContentLength + "|" +
                             BytesToHex(e.Content, Math.Min(32, e.Content?.Length ?? 0));
                _poolKeys.Remove(key);
                _pool.RemoveAt(index);
            }
            MarkDirty();
        }

        public static void RemoveByKeys(IEnumerable<string> info1HexList)
        {
            if (info1HexList == null) return;
            var set = new HashSet<string>(info1HexList, StringComparer.OrdinalIgnoreCase);
            lock (_lock)
            {
                for (int i = _pool.Count - 1; i >= 0; i--)
                {
                    if (set.Contains(_pool[i].Info1Hex ?? ""))
                    {
                        var e = _pool[i];
                        string key = (e.Info1Hex ?? "") + "|" + (e.Info2Hex ?? "") + "|" + e.ContentLength + "|" +
                                     BytesToHex(e.Content, Math.Min(32, e.Content?.Length ?? 0));
                        _poolKeys.Remove(key);
                        _pool.RemoveAt(i);
                    }
                }
            }
            MarkDirty();
        }

        public static string GetPoolFilePath()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "WPE_NJ");
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            return Path.Combine(dir, "nj_datapool.xml");
        }

        public static void SavePool()
        {
            try
            {
                PoolEntry[] snapshot;
                lock (_lock) snapshot = _pool.ToArray();

                var root = new XElement("NJDataPool",
                    new XAttribute("count", snapshot.Length),
                    snapshot.Select(e => new XElement("Entry",
                        new XAttribute("region", e.Region ?? ""),
                        new XAttribute("server", e.Server ?? ""),
                        new XAttribute("len", e.ContentLength),
                        new XAttribute("ctype", e.ContentType),
                        new XAttribute("info1", e.Info1Hex ?? ""),
                        new XAttribute("info2", e.Info2Hex ?? ""),
                        new XAttribute("content", BytesToHex(e.Content, e.Content?.Length ?? 0)),
                        new XAttribute("time", e.CollectedAt.ToString("o"))
                    )));
                root.Save(GetPoolFilePath());
            }
            catch (Exception ex)
            {
                try { Socket_Operation.DoLog(nameof(SavePool), ex.Message); } catch { }
            }
        }

        public static void LoadPool()
        {
            try
            {
                string path = GetPoolFilePath();
                if (!File.Exists(path)) return;
                var doc = XDocument.Load(path);
                lock (_lock)
                {
                    _pool.Clear();
                    _poolKeys.Clear();
                    foreach (var el in doc.Root?.Elements("Entry") ?? Enumerable.Empty<XElement>())
                    {
                        var info1 = HexToBytes((string)el.Attribute("info1"));
                        var content = HexToBytes((string)el.Attribute("content"));
                        if (info1.Length != 4) continue;

                        var entry = new PoolEntry
                        {
                            Region = (string)el.Attribute("region") ?? "ios",
                            Server = (string)el.Attribute("server") ?? "QQ",
                            ContentLength = (int?)el.Attribute("len") ?? content.Length,
                            ContentType = (byte)((int?)el.Attribute("ctype") ?? 0),
                            Info1 = info1,
                            Info2 = HexToBytes((string)el.Attribute("info2")).FirstOrDefault(),
                            Content = content ?? Array.Empty<byte>(),
                            CollectedAt = DateTime.TryParse((string)el.Attribute("time"), out var t) ? t : DateTime.Now
                        };
                        entry.ContentHex = BytesToHex(entry.Content, 48);
                        entry.Info1Hex = BytesToHex(entry.Info1, 4);
                        entry.Info2Hex = entry.Info2.ToString("X2");

                        string key = entry.Info1Hex + "|" + entry.Info2Hex + "|" + entry.ContentLength + "|" +
                                     BytesToHex(entry.Content, Math.Min(32, entry.Content.Length));
                        if (_poolKeys.Add(key)) _pool.Add(entry);
                        if (_pool.Count >= MaxPoolSize) break;
                    }
                }
                MarkDirty();
            }
            catch (Exception ex)
            {
                try { Socket_Operation.DoLog(nameof(LoadPool), ex.Message); } catch { }
            }
        }

        #endregion

        #region Hex 工具

        public static string BytesToHex(byte[] data, int max)
        {
            if (data == null || data.Length == 0 || max <= 0) return string.Empty;
            int n = Math.Min(data.Length, max);
            var sb = new StringBuilder(n * 3);
            for (int i = 0; i < n; i++)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(data[i].ToString("X2"));
            }
            if (data.Length > max) sb.Append(" ...");
            return sb.ToString();
        }

        public static byte[] HexToBytes(string hex)
        {
            if (string.IsNullOrWhiteSpace(hex)) return Array.Empty<byte>();
            var parts = hex.Split(new[] { ' ', '-', ',' }, StringSplitOptions.RemoveEmptyEntries);
            var list = new List<byte>(parts.Length);
            foreach (var p in parts)
            {
                if (byte.TryParse(p, System.Globalization.NumberStyles.HexNumber, null, out byte b))
                    list.Add(b);
            }
            return list.ToArray();
        }

        #endregion
    }
}
