using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Shuangji.Common;

namespace Shuangji.Common
{
    /// <summary>
    /// 按账号隔离的数据池：上号收集 / 修改替换 / 重置。
    /// </summary>
    public sealed class AccountPoolEngine
    {
        public sealed class PoolItem
        {
            public DateTime Time { get; set; }
            public string Host { get; set; }
            public bool Downlink { get; set; }
            public byte[] Data { get; set; }
            public string Info1Hex { get; set; }
            public string Info2Hex { get; set; }
            public string ContentHex { get; set; }
            public int Length { get; set; }
        }

        private sealed class AccountState
        {
            public WorkMode Mode = WorkMode.Idle;
            public int Version = 1;
            public readonly List<PoolItem> Pool = new List<PoolItem>();
            public readonly HashSet<string> Keys = new HashSet<string>(StringComparer.Ordinal);
            public long CollectCount;
            public long ModifyCount;
            public DateTime? LastCollectAt;
            public DateTime? LastModifyAt;
            public bool Online;
            /// <summary>开启加速（局内开/局外关）：拦截 3366 大包 + 用 65010 池替换。</summary>
            public bool BoostEnabled;
            public long BoostInterceptCount;
            public long BoostReplaceCount;
            /// <summary>65010 端口专用数据池（读取模式收集，修改模式局内替换）。</summary>
            public readonly List<PoolItem> Pool65010 = new List<PoolItem>();
            public readonly HashSet<string> Keys65010 = new HashSet<string>(StringComparer.Ordinal);
            /// <summary>
            /// 绿色冻结：第一次读取并离开读取模式后锁定，禁止再次读取污染样本。
            /// 单设备模拟「干净机抓绿 → 搞事机顶号」：绿数据只抓一轮。
            /// </summary>
            public bool GreenFrozen;
            /// <summary>读取期从 01 0A 00 23 +18 抓到的绿 UIN（20B）。</summary>
            public byte[] GreenUin;
            public readonly object Lock = new object();
        }

        private readonly object _mapLock = new object();
        private readonly Dictionary<string, AccountState> _map =
            new Dictionary<string, AccountState>(StringComparer.OrdinalIgnoreCase);

        private static readonly byte[] MarkerContent = { 0x01, 0x0A, 0x00, 0x09 };
        private const int MaxPool = 1500;
        private const int MaxStore = 512;
        private const int MaxPool65010 = 800;
        private const int MaxStore65010 = 8192;
        /// <summary>每种长度最多保留的「上号绿色」下行条数，避免后期脏包挤掉早期绿色样本。</summary>
        private const int MaxGreenPerLength = 2;

        private AccountState Get(string user)
        {
            if (string.IsNullOrWhiteSpace(user)) user = "_anon_";
            lock (_mapLock)
            {
                if (!_map.TryGetValue(user, out var st))
                {
                    st = new AccountState();
                    _map[user] = st;
                    TryLoad(user, st);
                }
                return st;
            }
        }

        public void SetOnline(string user, bool online)
        {
            var st = Get(user);
            lock (st.Lock) st.Online = online;
        }

        public WorkMode GetMode(string user)
        {
            var st = Get(user);
            lock (st.Lock) return st.Mode;
        }

        public void SetMode(string user, WorkMode mode)
        {
            var st = Get(user);
            lock (st.Lock)
            {
                SaveLocked(user, st);
                // 再次点「读取」：解冻以便重收绿
                if (mode == WorkMode.Collect)
                {
                    st.GreenFrozen = false;
                }
                // 离开读取模式且已有下行样本 → 冻结绿色
                else if (st.Mode == WorkMode.Collect && mode != WorkMode.Collect)
                {
                    if (st.Pool.Any(p => p.Downlink) || st.Pool65010.Count > 0)
                        st.GreenFrozen = true;
                }
                st.Mode = mode;
                WorkModeHub.Set(user, mode);
                SaveLocked(user, st);
            }
        }

        /// <summary>退出软件前把所有账号池落盘，保留读取模式抓到的下行数据。</summary>
        public void SaveAll()
        {
            lock (_mapLock)
            {
                foreach (var kv in _map)
                {
                    lock (kv.Value.Lock)
                        SaveLocked(kv.Key, kv.Value);
                }
            }
        }

        public int GetDownlinkPoolCount(string user)
        {
            var st = Get(user);
            lock (st.Lock)
            {
                // NJ 下行池 + 65010 下行样本都算「有绿」，避免只收到 65010 却一直 Ready=false
                int nj = st.Pool.Count(p => p.Downlink);
                int p65 = st.Pool65010.Count(p => p.Downlink);
                return nj + p65;
            }
        }

        public void SetBoost(string user, bool enabled)
        {
            var st = Get(user);
            lock (st.Lock) st.BoostEnabled = enabled;
        }

        public bool GetBoost(string user)
        {
            var st = Get(user);
            lock (st.Lock) return st.BoostEnabled;
        }

        public void Reset(string user)
        {
            var st = Get(user);
            lock (st.Lock)
            {
                st.Pool.Clear();
                st.Keys.Clear();
                st.Pool65010.Clear();
                st.Keys65010.Clear();
                st.GreenUin = null;
                st.GreenFrozen = false;
                st.Version++;
                st.CollectCount = 0;
                st.ModifyCount = 0;
                st.BoostInterceptCount = 0;
                st.BoostReplaceCount = 0;
                st.LastCollectAt = null;
                st.LastModifyAt = null;
                st.Mode = WorkMode.Idle;
                WorkModeHub.Set(user, WorkMode.Idle);
                SaveLocked(user, st);
            }
        }

        public AccountStatusDto Status(string user)
        {
            var st = Get(user);
            lock (st.Lock)
            {
                int njDown = st.Pool.Count(p => p.Downlink);
                int p65Down = st.Pool65010.Count(p => p.Downlink);
                int downCnt = njDown + p65Down;
                bool ready = downCnt > 0 || (st.GreenUin != null && st.GreenUin.Length > 0);
                string readyText;
                if (ready)
                    readyText = "绿就绪 NJ=" + njDown + " 65010=" + p65Down
                                + (st.GreenFrozen ? " (已冻结)" : "");
                else if (st.GreenFrozen)
                    readyText = "绿已冻结但池空，请点重置后再读取";
                else if (st.Mode == WorkMode.Collect)
                    readyText = "读取中…走一遍上号等下行（SOCKS 须经节点）";
                else
                    readyText = "尚未读到绿：点读取→上号→绿>0 再进大厅/修改";
                return new AccountStatusDto
                {
                    UserName = user,
                    Mode = st.Mode,
                    PoolCount = downCnt,
                    PoolVersion = st.Version,
                    CollectCount = st.CollectCount,
                    ModifyCount = st.ModifyCount,
                    LastCollectAt = st.LastCollectAt,
                    LastModifyAt = st.LastModifyAt,
                    Online = st.Online,
                    BoostEnabled = st.BoostEnabled,
                    BoostInterceptCount = st.BoostInterceptCount,
                    Pool65010Count = st.Pool65010.Count,
                    GreenFrozen = st.GreenFrozen,
                    ReadyLobby = ready,
                    ReadyModify = ready,
                    ReadyText = readyText
                };
            }
        }

        /// <summary>切换大厅/修改前检查是否已读到绿数据。</summary>
        public bool CanEnterMode(string user, WorkMode mode, out string reason)
        {
            reason = "";
            if (mode != WorkMode.Lobby && mode != WorkMode.Modify)
                return true;
            if (GetDownlinkPoolCount(user) > 0) return true;
            var st = Get(user);
            lock (st.Lock)
            {
                if (st.GreenUin != null && st.GreenUin.Length > 0) return true;
                if (st.GreenFrozen)
                {
                    reason = "绿已冻结且池空，请先点重置再读取上号";
                    return false;
                }
            }
            reason = "尚未读到绿数据：请先点「读取」，用同一账号走 SOCKS 上号，等绿>0 再进大厅/修改";
            return false;
        }

        public List<PoolItem> Snapshot(string user)
        {
            var st = Get(user);
            lock (st.Lock)
                return st.Pool.Select(p => new PoolItem
                {
                    Time = p.Time,
                    Host = p.Host,
                    Downlink = p.Downlink,
                    Data = p.Data,
                    Info1Hex = p.Info1Hex,
                    Info2Hex = p.Info2Hex,
                    ContentHex = p.ContentHex,
                    Length = p.Length
                }).ToList();
        }

        private const int BoostMinLen = 10000;

        /// <summary>
        /// 举报/异常上报通道（WPE ACE_Filter Send + ACE_Sanitizer 出站）：
        /// 33 66 00 0B 00 0C 40 13。客户端→服务器，不是下行检测，不是解密目标 0E。
        /// </summary>
        private static bool Has4013Header(byte[] data)
        {
            if (data == null || data.Length < 8) return false;
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

        private static bool Has4013TlvType(byte[] data, byte type)
        {
            if (data == null || data.Length < 24) return false;
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 24; i++)
            {
                if (data[i] != 0x33 || data[i + 1] != 0x66) continue;
                if (data[i + 6] != 0x40 || data[i + 7] != 0x13) continue;
                if (data[i + 16] == 0x19 && data[i + 17] == 0x00 && data[i + 18] == 0x00
                    && data[i + 19] == type)
                    return true;
            }
            return false;
        }

        /// <summary>下行检测文件 TLV（dump 对照：小包 00..04 放行，其余文件块拦截）。</summary>
        private static bool Has4013DetectionFile(byte[] data)
        {
            return Port65010DownlinkFilter.HasDetectionFileFrame(data, 0, data?.Length ?? 0);
        }

        /// <summary>加速：65010 下行 33 66 且长度 ≥ 10000。</summary>
        private static bool IsBoostTarget(PacketJob job)
        {
            if (job == null || job.Data == null || job.Port != 65010 || !job.IsServerToClient) return false;
            var data = job.Data;
            if (data.Length < BoostMinLen) return false;
            return data[0] == 0x33 && data[1] == 0x66;
        }

        /// <summary>
        /// 65010（仅局内）：上行 4013 全拦（WPE ACE_Filter）；下行检测文件 TLV + ≥10000 大包拦。
        /// 读取/大厅绝不能调这里——会断上号。
        /// </summary>
        private bool TryIntercept65010(AccountState st, PacketJob job, PacketResult result, string tag)
        {
            if (job.Port != 65010) return false;

            // 上行：33 66 00 0B 00 0C 40 13 整帧丢（恢复为能抗住部分举报的全拦）
            if (!job.IsServerToClient && Port65010UplinkFilter.Contains4013Header(job.Data))
            {
                Interlocked.Increment(ref st.BoostInterceptCount);
                result.Modified = true;
                result.Data = new byte[0];
                result.Action = "intercept";
                result.Message = tag + " 拦截举报/异常上报(上行4013)";
                Interlocked.Increment(ref st.ModifyCount);
                st.LastModifyAt = DateTime.Now;
                return true;
            }

            if (job.IsServerToClient
                && (Has4013DetectionFile(job.Data) || IsBoostTarget(job)))
            {
                Interlocked.Increment(ref st.BoostInterceptCount);
                result.Modified = true;
                result.Data = new byte[0];
                result.Action = "intercept";
                result.Message = IsBoostTarget(job)
                    ? tag + " 拦截下行大包 len=" + job.Data.Length
                    : tag + " 拦截下行检测文件TLV";
                Interlocked.Increment(ref st.ModifyCount);
                st.LastModifyAt = DateTime.Now;
                return true;
            }
            return false;
        }

        /// <summary>
        /// NJ 上行举报体（解密目标.txt）：01 00 00 0E … 0A 92。
        /// 只拦上行；下行 nj 任务走 PatchNjClean，勿与此混淆。
        /// </summary>
        private bool TryInterceptNjReport0E(AccountState st, PacketJob job, PacketResult result, string tag)
        {
            if (job.IsServerToClient || job.Data == null) return false;
            if (!IsNjHost(job.Host) && job.Port != 10012 && job.Port != 443 && job.Port != 80)
                return false;
            if (!HasNjReport0E(job.Data)) return false;

            Interlocked.Increment(ref st.BoostInterceptCount);
            result.Modified = true;
            result.Data = new byte[0];
            result.Action = "intercept";
            result.Message = tag + " 拦截NJ上行举报0E";
            Interlocked.Increment(ref st.ModifyCount);
            st.LastModifyAt = DateTime.Now;
            return true;
        }

        private static bool HasNjReport0E(byte[] data)
        {
            if (data == null || data.Length < 20) return false;
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 4; i++)
            {
                if (data[i] != 0x01 || data[i + 1] != 0x00
                    || data[i + 2] != 0x00 || data[i + 3] != 0x0E)
                    continue;
                // 解密目标特征：其后不久出现 0A 92 密文体
                int lim = Math.Min(i + 64, n - 1);
                for (int j = i + 4; j < lim; j++)
                {
                    if (data[j] == 0x0A && data[j + 1] == 0x92)
                        return true;
                }
            }
            return false;
        }

        /// <summary>网关回调：加速拦截/替换 / 按模式收集或修改。</summary>
        public PacketResult Process(PacketJob job)
        {
            var result = new PacketResult { Modified = false, Data = job?.Data, Action = "passthrough" };
            if (job == null || job.Data == null || job.Data.Length < 2) return result;

            var st = Get(job.UserName ?? "");
            WorkMode mode;
            lock (st.Lock) mode = st.Mode;

            try
            {
                if (job.Data.Length < 10 && !(mode == WorkMode.Modify && job.Port == 65010))
                    return result;

                // 大厅：65010 完全透传（上号/大厅握手需要）；只洗 NJ
                if (mode == WorkMode.Lobby)
                {
                    if (job.Port == 65010)
                    {
                        result.Action = "passthrough";
                        return result;
                    }

                    var lobbyRep = PatchNjClean(st, job);
                    if (lobbyRep != null)
                    {
                        result.Modified = true;
                        result.Data = lobbyRep;
                        result.Action = "replace";
                        Interlocked.Increment(ref st.ModifyCount);
                        st.LastModifyAt = DateTime.Now;
                    }
                    else result.Action = "passthrough";
                    return result;
                }

                if (mode == WorkMode.Collect)
                {
                    // 读取期：65010 必须透传，否则上不了号；仅收集（检测文件不入库）
                    bool frozen;
                    lock (st.Lock) frozen = st.GreenFrozen;
                    if (frozen)
                    {
                        // 绿色已冻结：再点读取也不入库；要刷新去点「大厅」
                        result.Action = "collect";
                        result.Message = "frozen skip";
                        return result;
                    }
                    int added = Collect(st, job);
                    int addedUin = CollectGreenUin(st, job);
                    int added65010 = Collect65010(st, job);
                    result.Action = "collect";
                    result.Message = "added=" + added + " uin=" + addedUin + " p65010=" + added65010
                                    + " downPool=" + GetDownlinkPoolCount(job.UserName);
                    return result;
                }

                // 修改模式(局内)
                if (mode == WorkMode.Modify)
                {
                    if (TryIntercept65010(st, job, result, "局内")) return result;
                    if (job.Port == 65010)
                    {
                        result.Action = "passthrough";
                        return result;
                    }

                    // NJ 上行举报体（解密目标 01 00 00 0E … 0A 92）
                    if (TryInterceptNjReport0E(st, job, result, "局内")) return result;

                    // NJ：洗检测任务（绿校验/UIN → 清载荷 → 作废标记）
                    var replaced = PatchNjClean(st, job);
                    if (replaced != null)
                    {
                        result.Modified = true;
                        result.Data = replaced;
                        result.Action = "replace";
                        Interlocked.Increment(ref st.ModifyCount);
                        st.LastModifyAt = DateTime.Now;
                    }
                    else
                    {
                        result.Action = "passthrough";
                        result.Message = "NJ无命中透传";
                    }
                    return result;
                }
            }
            catch
            {
                // 任何异常：原样放行，绝不让处理逻辑弄崩客户端
                result.Modified = false;
                result.Data = job.Data;
                result.Action = "passthrough";
                result.Message = "异常兜底透传";
            }
            return result;
        }

        private static bool HasDownlinkGreen(AccountState st)
        {
            lock (st.Lock)
            {
                if (st.Pool.Any(p => p.Downlink && p.Data != null && p.Data.Length > 0)) return true;
                if (st.Pool65010.Any(p => p.Downlink && p.Data != null && p.Data.Length > 0)) return true;
                return st.GreenUin != null && st.GreenUin.Length > 0;
            }
        }

        /// <summary>读取模式：记录 65010 下行 33 66 小包到专用池（上号期未必带 40 13）。</summary>
        private int Collect65010(AccountState st, PacketJob job)
        {
            if (job.Port != 65010 || job.Data == null) return 0;
            // 绿样本只收下发
            if (!job.IsServerToClient) return 0;
            var data = job.Data;
            if (data.Length < 8 || data.Length >= BoostMinLen) return 0;
            if (data[0] != 0x33 || data[1] != 0x66) return 0;
            // 检测文件块不当绿样本
            if (Has4013DetectionFile(data)) return 0;

            int storeLen = Math.Min(data.Length, MaxStore65010);
            string key = data.Length + "|" + HttpUtil.BytesToHex(data, Math.Min(32, storeLen))
                         + "|" + (job.IsServerToClient ? "D" : "U");

            lock (st.Lock)
            {
                if (st.Keys65010.Contains(key) || st.Pool65010.Count >= MaxPool65010) return 0;
                st.Keys65010.Add(key);
                var frame = new byte[storeLen];
                Buffer.BlockCopy(data, 0, frame, 0, storeLen);
                st.Pool65010.Add(new PoolItem
                {
                    Time = DateTime.Now,
                    Host = job.Host ?? "",
                    Downlink = job.IsServerToClient,
                    Data = frame,
                    Length = data.Length,
                    Info1Hex = "",
                    Info2Hex = "",
                    ContentHex = HttpUtil.BytesToHex(frame, Math.Min(48, storeLen))
                });
                st.CollectCount++;
                st.LastCollectAt = DateTime.Now;
                SaveLocked(job.UserName, st);
                return 1;
            }
        }

        /// <summary>33 66 帧头长度：前 0x14 字节含序号，必须保留实时值。</summary>
        private const int Frame65010HeaderLen = 0x14;

        private static bool Has4013Variant(byte[] data)
        {
            int n = Math.Min(data.Length, 8192);
            for (int i = 0; i <= n - 8; i++)
            {
                if (data[i] == 0x33 && data[i + 1] == 0x66
                    && data[i + 6] == 0x40 && data[i + 7] == 0x13)
                    return true;
            }
            return false;
        }

        private static bool IsNjHost(string host)
        {
            return AceCdnRules.IsWatchHost(host);
        }

        /// <summary>
        /// 读取模式 = 冻结「上号绿色期」下发：
        /// 刚上号、还没做事时服务器下发的包是绿色/可通过校验的；此时开读取把它们存住。
        /// 每种长度只留最早几条，防止后来做事时的脏包混进来。
        /// </summary>
        private int Collect(AccountState st, PacketJob job)
        {
            int added = 0;
            var data = job.Data;
            if (data == null) return 0;

            // 只收下行（下发）= 绿色数据包来源
            if (!job.IsServerToClient) return 0;

            bool nj = IsNjHost(job.Host) || job.Port == 10012 || job.Port == 10011 || job.Port == 10013;
            // 非 NJ/关注端口且无特征：不收，避免把无关 HTTPS 塞进绿池
            if (!nj && job.Port != 443 && job.Port != 80 && !HasSig(data)) return 0;
            if (!HasSig(data) && !nj) return 0;

            int frameCap = nj ? 16384 : 8192;

            int limit = Math.Min(data.Length, 65536) - 10;
            for (int i = 0; i <= limit; i++)
            {
                if (data[i] != 0x00 || data[i + 1] != 0x01) continue;
                if (data[i + 6] != 0x01 || data[i + 7] != 0x00 || data[i + 8] != 0x09) continue;

                byte[] info1 = { data[i + 2], data[i + 3], data[i + 4], data[i + 5] };
                byte info2 = data[i + 9];
                int cpos = IndexOf(data, MarkerContent, i + 10);
                byte[] content;
                int clen;
                if (cpos >= 0 && cpos - i < 2500)
                {
                    clen = Math.Min(Math.Max(64, data.Length - cpos), Math.Max(MaxStore, 2048));
                    if (cpos + clen > data.Length) clen = data.Length - cpos;
                    content = new byte[clen];
                    Buffer.BlockCopy(data, cpos, content, 0, clen);
                }
                else
                {
                    clen = Math.Min(data.Length, Math.Max(MaxStore, 2048));
                    content = new byte[clen];
                    Buffer.BlockCopy(data, 0, content, 0, clen);
                }

                string info1Hex = HttpUtil.BytesToHex(info1, 4);
                string info2Hex = info2.ToString("X2");
                string key = "D|" + (nj ? "NJ|" : "") + info1Hex + "|" + info2Hex + "|" + data.Length + "|"
                             + HttpUtil.BytesToHex(content, 24);

                if (TryAddPoolFrame(st, job, data, frameCap, key, info1Hex, info2Hex,
                        HttpUtil.BytesToHex(content, 48)))
                    added++;
            }

            // 无经典 00 01…01 00 09 时：靠 01 0A 00 23/09 仍入库
            if (added == 0 && nj)
            {
                int t = IndexOfNjTag(data, 0x23);
                if (t < 3) t = IndexOfNjTag(data, 0x09);
                if (t >= 3)
                {
                    string info1Hex = t >= 3
                        ? HttpUtil.BytesToHex(new[] { data[t - 3], data[t - 2], data[t - 1] }, 3)
                        : "000000";
                    string info2Hex = data[t + 3].ToString("X2");
                    string key = "D|NJ|TAG3|" + info1Hex + "|" + info2Hex + "|" + data.Length;
                    if (TryAddPoolFrame(st, job, data, frameCap, key, info1Hex, info2Hex,
                            HttpUtil.BytesToHex(data, Math.Min(48, data.Length))))
                        added++;
                }
            }

            // 仍无命中：NJ/10012 下行大包兜底入库（否则绿一直为 0）
            if (added == 0 && nj && data.Length >= 64 && data.Length < 65536)
            {
                string key = "D|NJ|RAW|" + data.Length + "|" + HttpUtil.BytesToHex(data, 32);
                if (TryAddPoolFrame(st, job, data, frameCap, key, "", "",
                        HttpUtil.BytesToHex(data, Math.Min(48, data.Length))))
                    added++;
            }

            if (added > 0)
                lock (st.Lock) SaveLocked(job.UserName, st);
            return added;
        }

        private bool TryAddPoolFrame(AccountState st, PacketJob job, byte[] data, int frameCap,
            string key, string info1Hex, string info2Hex, string contentHex)
        {
            lock (st.Lock)
            {
                if (st.Keys.Contains(key) || st.Pool.Count >= MaxPool) return false;
                int sameLen = st.Pool.Count(p => p.Downlink && p.Length == data.Length);
                if (sameLen >= MaxGreenPerLength) return false;

                st.Keys.Add(key);
                int frameLen = Math.Min(data.Length, frameCap);
                var frame = new byte[frameLen];
                Buffer.BlockCopy(data, 0, frame, 0, frameLen);
                st.Pool.Add(new PoolItem
                {
                    Time = DateTime.Now,
                    Host = job.Host ?? "",
                    Downlink = true,
                    Data = frame,
                    Info1Hex = info1Hex,
                    Info2Hex = info2Hex,
                    ContentHex = contentHex,
                    Length = data.Length
                });
                st.CollectCount++;
                st.LastCollectAt = DateTime.Now;
                return true;
            }
        }

        private static int IndexOfNjTag(byte[] data, byte tag)
        {
            int n = Math.Min(data?.Length ?? 0, 65536);
            for (int i = 0; i <= n - 4; i++)
            {
                if (data[i] == 0x01 && data[i + 1] == 0x0A && data[i + 2] == 0x00 && data[i + 3] == tag)
                    return i;
            }
            return -1;
        }

        private static readonly object _rngLock = new object();
        private static readonly Random _rng = new Random();

        /// <summary>
        /// NJ 干净改法（对齐 WPE ACE_Filter + ACE_Sanitizer，禁止整帧替换）：
        /// 1) 有绿：只贴 23/09 前 3 字节校验 + UIN（不瞎合成、不硬贴 0A 92 前会话字段）
        /// 2) 按原标记清检测区（到下一 01 0A 边界为止，避免误伤邻块）
        /// 3) 作废标记 23/09/08/F1/01 00/B8 34 → 00
        /// </summary>
        private byte[] PatchNjClean(AccountState st, PacketJob job)
        {
            var data = job.Data;
            if (data == null || data.Length < 10) return null;
            if (!HasNjDetectionMarker(data)) return null;

            byte[] green = null;
            byte[] greenUin = null;
            lock (st.Lock)
            {
                var downs = st.Pool
                    .Where(p => p.Downlink && p.Data != null && p.Data.Length > 0)
                    .OrderBy(p => p.Time)
                    .ToList();
                var pick = downs.FirstOrDefault(p => IsNjHost(p.Host)) ?? (downs.Count > 0 ? downs[0] : null);
                if (pick != null) green = pick.Data;
                greenUin = st.GreenUin;
            }

            var result = (byte[])data.Clone();
            bool any = false;

            // 1) 绿样本校验位（仅 tag3，不碰会话常量/序号）
            if (green != null)
            {
                if (ApplyNjTag3FromPick(result, green, 0x23)) any = true;
                if (ApplyNjTag3FromPick(result, green, 0x09)) any = true;
            }
            // 2) UIN 必须在标记仍是 23 时写入（+18）
            if (ApplyGreenUin(result, greenUin)) any = true;
            // 3) 按原始标记清检测区
            if (SanitizeNjDetectionInPlace(result)) any = true;
            // 4) 最后作废全部检测标记
            if (NeuterNjMarkers(result)) any = true;

            return any ? result : null;
        }

        private static bool HasNjDetectionMarker(byte[] data)
        {
            if (data == null || data.Length < 4) return false;
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 4; i++)
            {
                if (data[i] != 0x01 || data[i + 1] != 0x0A) continue;
                // 01 0A 00 23/09/08/F1
                if (data[i + 2] == 0x00 && (data[i + 3] == 0x23 || data[i + 3] == 0x09
                    || data[i + 3] == 0x08 || data[i + 3] == 0xF1))
                    return true;
                // 01 0A 01 00 / 01 0A B8 34
                if (data[i + 2] == 0x01 && data[i + 3] == 0x00) return true;
                if (data[i + 2] == 0xB8 && data[i + 3] == 0x34) return true;
            }
            return false;
        }

        private int CollectGreenUin(AccountState st, PacketJob job)
        {
            if (job.Data == null || !job.IsServerToClient) return 0;
            int t = IndexOfNjTag(job.Data, 0x23);
            if (t < 0 || t + 18 + 20 > job.Data.Length) return 0;
            // +14..+17 = 00 00 00 14；+18 起 19 位数字 + NUL
            if (job.Data[t + 14] != 0 || job.Data[t + 15] != 0 || job.Data[t + 16] != 0 || job.Data[t + 17] != 0x14)
                return 0;
            for (int k = 0; k < 19; k++)
            {
                byte b = job.Data[t + 18 + k];
                if (b < 0x30 || b > 0x39) return 0;
            }
            if (job.Data[t + 18 + 19] != 0) return 0;

            lock (st.Lock)
            {
                if (st.GreenUin != null) return 0;
                st.GreenUin = new byte[20];
                Buffer.BlockCopy(job.Data, t + 18, st.GreenUin, 0, 20);
                st.CollectCount++;
                st.LastCollectAt = DateTime.Now;
                SaveLocked(job.UserName, st);
                return 1;
            }
        }

        private static bool ApplyGreenUin(byte[] data, byte[] greenUin)
        {
            if (data == null || greenUin == null || greenUin.Length != 20) return false;
            bool any = false;
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 38; i++)
            {
                if (data[i] != 0x01 || data[i + 1] != 0x0A || data[i + 2] != 0x00 || data[i + 3] != 0x23)
                    continue;
                if (data[i + 14] != 0 || data[i + 15] != 0 || data[i + 16] != 0 || data[i + 17] != 0x14)
                    continue;
                for (int k = 0; k < 20; k++)
                {
                    if (data[i + 18 + k] != greenUin[k])
                    {
                        data[i + 18 + k] = greenUin[k];
                        any = true;
                    }
                }
            }
            return any;
        }

        /// <summary>
        /// ACE_Filter 扩展：作废全部已知检测标记。
        /// 01 0A 00 23/09/08/F1 → 01 0A 00 00；01 0A 01 00 / B8 34 → 01 0A 00 00。
        /// </summary>
        private static bool NeuterNjMarkers(byte[] data)
        {
            if (data == null || data.Length < 4) return false;
            bool any = false;
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 4; i++)
            {
                if (data[i] != 0x01 || data[i + 1] != 0x0A) continue;
                if (data[i + 2] == 0x00
                    && (data[i + 3] == 0x23 || data[i + 3] == 0x09
                        || data[i + 3] == 0x08 || data[i + 3] == 0xF1))
                {
                    data[i + 3] = 0x00;
                    any = true;
                }
                else if ((data[i + 2] == 0x01 && data[i + 3] == 0x00)
                         || (data[i + 2] == 0xB8 && data[i + 3] == 0x34))
                {
                    data[i + 2] = 0x00;
                    data[i + 3] = 0x00;
                    any = true;
                }
            }
            return any;
        }

        /// <summary>
        /// ACE_Sanitizer：按原始标记清检测区。
        /// 01 0A 00 23 → +42；01 0A 00 09/08/F1、01 0A 01 00 → +14。
        /// 对照 nj.txt：23 块 +18 起 UIN(20B)，+38 后接 09 块；09 块 +14 起才是载荷。
        /// </summary>
        private static bool SanitizeNjDetectionInPlace(byte[] data)
        {
            if (data == null || data.Length < 20) return false;
            bool changed = false;

            // 与 WPE ACE_Sanitizer.NJ_RULES 对齐（含稀有 B8 34）
            var rules = new[]
            {
                new[] { 0x01, 0x0A, 0x00, 0x23, 42 },
                new[] { 0x01, 0x0A, 0x00, 0x09, 14 },
                new[] { 0x01, 0x0A, 0x00, 0x08, 14 },
                new[] { 0x01, 0x0A, 0x01, 0x00, 14 },
                new[] { 0x01, 0x0A, 0x00, 0xF1, 14 },
                new[] { 0x01, 0x0A, 0xB8, 0x34, 14 },
            };

            int n = Math.Min(data.Length, 65536);
            foreach (var rule in rules)
            {
                int off = rule[4];
                for (int i = 0; i <= n - 4; i++)
                {
                    if (data[i] != rule[0] || data[i + 1] != rule[1]
                        || data[i + 2] != rule[2] || data[i + 3] != rule[3])
                        continue;
                    int start = i + off;
                    // 清到下一 01 0A 标记或 +512，避免把邻块外壳一起抹掉
                    int end = Math.Min(start + 512, data.Length);
                    for (int j = start; j <= end - 4; j++)
                    {
                        if (data[j] == 0x01 && data[j + 1] == 0x0A)
                        {
                            end = j;
                            break;
                        }
                    }
                    for (int j = start; j < end; j++)
                    {
                        if (data[j] != 0) { data[j] = 0; changed = true; }
                    }
                }
            }
            return changed;
        }

        private static byte[] ApplyInfoFromPick(byte[] data, PoolItem pick)
        {
            byte[] info1;
            byte info2;
            if (pick != null && !string.IsNullOrEmpty(pick.Info1Hex))
            {
                info1 = HexTo4(pick.Info1Hex);
                if (!byte.TryParse(pick.Info2Hex, System.Globalization.NumberStyles.HexNumber, null, out info2))
                    info2 = 0x93;
            }
            else
            {
                Synthesize(data, out info1, out info2);
            }

            byte[] result = (byte[])data.Clone();
            bool any = false;
            int limit = data.Length - 10;
            for (int i = 0; i <= limit; i++)
            {
                if (data[i] != 0x00 || data[i + 1] != 0x01) continue;
                if (data[i + 6] != 0x01 || data[i + 7] != 0x00 || data[i + 8] != 0x09) continue;

                result[i + 2] = info1[0];
                result[i + 3] = info1[1];
                result[i + 4] = info1[2];
                result[i + 5] = info1[3];
                result[i + 9] = info2;
                any = true;
            }

            // NJ：01 0A 00 23 / 01 0A 00 09 前 3 字节校验（如 01 00 A6）
            // 注意：0A 92 前的 08 XX 是序号、FE 69 0E 83 是会话常量——都不要拿绿样本硬贴
            if (pick?.Data != null)
            {
                if (ApplyNjTag3FromPick(result, pick.Data, 0x23)) any = true;
                if (ApplyNjTag3FromPick(result, pick.Data, 0x09)) any = true;
            }

            return any ? result : null;
        }

        private static void Synthesize(byte[] data, out byte[] info1, out byte info2)
        {
            uint h = 0x811C9DC5;
            int n = Math.Min(data?.Length ?? 0, 64);
            for (int i = 0; i < n; i++) { h ^= data[i]; h *= 0x01000193; }
            h ^= (uint)(Environment.TickCount & 0xFFFF);
            info1 = new[] { (byte)h, (byte)(h >> 8), (byte)(h >> 16), (byte)(h >> 24) };
            info2 = (byte)((h >> 16) ^ h ^ 0x93);
            if (info1[0] == 0 && info1[1] == 0 && info1[2] == 0 && info1[3] == 0)
                info1[0] = 0xA5;
        }

        private static byte[] HexTo4(string hex)
        {
            var parts = (hex ?? "").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            var b = new byte[4];
            for (int i = 0; i < 4 && i < parts.Length; i++)
                byte.TryParse(parts[i], System.Globalization.NumberStyles.HexNumber, null, out b[i]);
            return b;
        }

        private static bool HasSig(byte[] data)
        {
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 3; i++)
            {
                if (data[i] == 0x01 && data[i + 1] == 0x00 && data[i + 2] == 0x09) return true;
                // NJ 标记：01 0A 00 23 / 01 0A 00 09（其前 3 字节 01 XX YY 为校验位）
                if (i <= n - 4 && data[i] == 0x01 && data[i + 1] == 0x0A && data[i + 2] == 0x00
                    && (data[i + 3] == 0x23 || data[i + 3] == 0x09))
                    return true;
            }
            return false;
        }

        /// <summary>
        /// NJ：01 0A 00 23/09 前 3 字节（如 01 00 A6）为包变校验，用绿样本同位置覆盖。
        /// </summary>
        private static bool ApplyNjTag3FromPick(byte[] result, byte[] green, byte tag)
        {
            if (result == null || green == null) return false;
            byte[] g3 = null;
            int gn = Math.Min(green.Length, 65536);
            for (int i = 3; i <= gn - 4; i++)
            {
                if (green[i] == 0x01 && green[i + 1] == 0x0A && green[i + 2] == 0x00 && green[i + 3] == tag)
                {
                    g3 = new[] { green[i - 3], green[i - 2], green[i - 1] };
                    break;
                }
            }
            if (g3 == null) return false;

            bool any = false;
            int rn = Math.Min(result.Length, 65536);
            for (int i = 3; i <= rn - 4; i++)
            {
                if (result[i] != 0x01 || result[i + 1] != 0x0A || result[i + 2] != 0x00 || result[i + 3] != tag)
                    continue;
                if (result[i - 3] != g3[0] || result[i - 2] != g3[1] || result[i - 1] != g3[2])
                {
                    result[i - 3] = g3[0];
                    result[i - 2] = g3[1];
                    result[i - 1] = g3[2];
                    any = true;
                }
            }
            return any;
        }


        private static int IndexOf(byte[] src, byte[] pat, int start)
        {
            int limit = src.Length - pat.Length;
            for (int i = Math.Max(0, start); i <= limit; i++)
            {
                bool ok = true;
                for (int j = 0; j < pat.Length; j++)
                    if (src[i + j] != pat[j]) { ok = false; break; }
                if (ok) return i;
            }
            return -1;
        }

        private void SaveLocked(string user, AccountState st)
        {
            try
            {
                string path = Path.Combine(AppPaths.PoolsDir, SafeName(user) + ".json");
                var obj = new
                {
                    user,
                    version = st.Version,
                    mode = (int)st.Mode,
                    collect = st.CollectCount,
                    modify = st.ModifyCount,
                    greenFrozen = st.GreenFrozen,
                    greenUin = HttpUtil.ToBase64(st.GreenUin),
                    items = st.Pool.Select(p => new
                    {
                        time = p.Time.ToString("o"),
                        host = p.Host,
                        down = p.Downlink,
                        len = p.Length,
                        info1 = p.Info1Hex,
                        info2 = p.Info2Hex,
                        content = p.ContentHex,
                        data = HttpUtil.ToBase64(p.Data)
                    }).ToList(),
                    items65010 = st.Pool65010.Select(p => new
                    {
                        time = p.Time.ToString("o"),
                        host = p.Host,
                        down = p.Downlink,
                        len = p.Length,
                        content = p.ContentHex,
                        data = HttpUtil.ToBase64(p.Data)
                    }).ToList()
                };
                File.WriteAllText(path, SimpleJson.Serialize(obj), Encoding.UTF8);
            }
            catch { }
        }

        private void TryLoad(string user, AccountState st)
        {
            try
            {
                string path = Path.Combine(AppPaths.PoolsDir, SafeName(user) + ".json");
                if (!File.Exists(path)) return;
                var root = SimpleJson.DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
                st.Version = SimpleJson.GetInt(root, "version", 1);
                st.CollectCount = SimpleJson.GetInt(root, "collect", 0);
                st.ModifyCount = SimpleJson.GetInt(root, "modify", 0);
                st.GreenFrozen = SimpleJson.GetBool(root, "greenFrozen", false);
                var gu = HttpUtil.FromBase64(SimpleJson.GetString(root, "greenUin"));
                if (gu != null && gu.Length == 20) st.GreenUin = gu;
                if (root.ContainsKey("items") && root["items"] is System.Collections.ArrayList arr)
                {
                    foreach (var o in arr)
                    {
                        var d = o as Dictionary<string, object>;
                        if (d == null) continue;
                        var item = new PoolItem
                        {
                            Host = SimpleJson.GetString(d, "host"),
                            Downlink = SimpleJson.GetBool(d, "down"),
                            Length = SimpleJson.GetInt(d, "len"),
                            Info1Hex = SimpleJson.GetString(d, "info1"),
                            Info2Hex = SimpleJson.GetString(d, "info2"),
                            ContentHex = SimpleJson.GetString(d, "content"),
                            Data = HttpUtil.FromBase64(SimpleJson.GetString(d, "data"))
                        };
                        DateTime.TryParse(SimpleJson.GetString(d, "time"), out var t);
                        item.Time = t == default ? DateTime.Now : t;
                        string key = item.Info1Hex + "|" + item.Info2Hex + "|" + item.Length;
                        if (st.Keys.Add(key)) st.Pool.Add(item);
                    }
                }
                if (root.ContainsKey("items65010") && root["items65010"] is System.Collections.ArrayList arr65010)
                {
                    foreach (var o in arr65010)
                    {
                        var d = o as Dictionary<string, object>;
                        if (d == null) continue;
                        var item = new PoolItem
                        {
                            Host = SimpleJson.GetString(d, "host"),
                            Downlink = SimpleJson.GetBool(d, "down"),
                            Length = SimpleJson.GetInt(d, "len"),
                            ContentHex = SimpleJson.GetString(d, "content"),
                            Data = HttpUtil.FromBase64(SimpleJson.GetString(d, "data")),
                            Info1Hex = "",
                            Info2Hex = ""
                        };
                        DateTime.TryParse(SimpleJson.GetString(d, "time"), out var t);
                        item.Time = t == default ? DateTime.Now : t;
                        if (item.Data == null || item.Data.Length < 2) continue;
                        string key = item.Length + "|" + HttpUtil.BytesToHex(item.Data, Math.Min(32, item.Data.Length))
                                     + "|" + (item.Downlink ? "D" : "U");
                        if (st.Keys65010.Add(key)) st.Pool65010.Add(item);
                    }
                }
                // 已有样本但旧文件无冻结标记：视为已抓过绿，直接冻结
                if (!st.GreenFrozen && (st.Pool.Count > 0 || st.Pool65010.Count > 0))
                    st.GreenFrozen = true;
            }
            catch { }
        }

        private static string SafeName(string user)
        {
            foreach (var c in Path.GetInvalidFileNameChars())
                user = (user ?? "x").Replace(c, '_');
            return user;
        }
    }
}
