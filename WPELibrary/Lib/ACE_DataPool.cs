using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json;

namespace WPELibrary.Lib
{
    /// <summary>
    /// 智能滤镜数据池条目：保存 NJ 心跳块的校验值与特征。
    /// </summary>
    public class ACE_PoolEntry
    {
        public string Region { get; set; } = "ios";
        public string Server { get; set; } = "QQ";
        public string CollectedHex { get; set; }
        public string Info1Hex { get; set; }
        public string Info2Hex { get; set; }
        public int BlockSize { get; set; }
        public int PayloadSize { get; set; }
        public string SignatureHex { get; set; }
        public DateTime CollectedAt { get; set; } = DateTime.Now;
        public int UseCount { get; set; }

        [JsonIgnore]
        public byte[] Info1Bytes => HexToBytes(Info1Hex);

        [JsonIgnore]
        public byte[] Info2Bytes => HexToBytes(Info2Hex);

        [JsonIgnore]
        public byte[] SignatureBytes => HexToBytes(SignatureHex);

        private static byte[] HexToBytes(string hex)
        {
            if (string.IsNullOrWhiteSpace(hex))
                return Array.Empty<byte>();

            hex = hex.Replace(" ", string.Empty);
            if (hex.Length % 2 != 0)
                return Array.Empty<byte>();

            var bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return bytes;
        }
    }

    /// <summary>
    /// 数据池持久化与相似度匹配。
    /// </summary>
    public static class ACE_DataPool
    {
        private static readonly object SyncRoot = new object();
        private static readonly List<ACE_PoolEntry> Entries = new List<ACE_PoolEntry>();
        private static readonly Dictionary<int, int> LastUsedBucket = new Dictionary<int, int>();

        public static IReadOnlyList<ACE_PoolEntry> AllEntries
        {
            get { lock (SyncRoot) { return Entries.ToList(); } }
        }

        public static int Count
        {
            get { lock (SyncRoot) { return Entries.Count; } }
        }

        public static string PoolFilePath =>
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "nj_smartfilter_pool.json");

        public static void Add(ACE_PoolEntry entry)
        {
            if (entry == null)
                return;

            lock (SyncRoot)
            {
                // 去重：相同 info1+info2+块大小视为重复
                if (Entries.Any(e =>
                    e.Info1Hex == entry.Info1Hex
                    && e.Info2Hex == entry.Info2Hex
                    && e.BlockSize == entry.BlockSize))
                    return;

                Entries.Add(entry);
            }
        }

        public static void RemoveAt(int index)
        {
            lock (SyncRoot)
            {
                if (index >= 0 && index < Entries.Count)
                    Entries.RemoveAt(index);
            }
        }

        public static void Clear()
        {
            lock (SyncRoot)
            {
                Entries.Clear();
                LastUsedBucket.Clear();
            }
        }

        public static void Save()
        {
            try
            {
                List<ACE_PoolEntry> snapshot;
                lock (SyncRoot) { snapshot = Entries.ToList(); }

                var json = JsonConvert.SerializeObject(snapshot, Formatting.Indented);
                File.WriteAllText(PoolFilePath, json, Encoding.UTF8);
            }
            catch (Exception ex)
            {
                Socket_Operation.DoLog(nameof(Save), ex.Message);
            }
        }

        public static void Load()
        {
            try
            {
                if (!File.Exists(PoolFilePath))
                    return;

                var json = File.ReadAllText(PoolFilePath, Encoding.UTF8);
                var list = JsonConvert.DeserializeObject<List<ACE_PoolEntry>>(json);
                if (list == null)
                    return;

                lock (SyncRoot)
                {
                    Entries.Clear();
                    Entries.AddRange(list);
                }
            }
            catch (Exception ex)
            {
                Socket_Operation.DoLog(nameof(Load), ex.Message);
            }
        }

        /// <summary>
        /// 根据块大小、前缀特征和负载相似度，从数据池挑选最佳校验值。
        /// </summary>
        public static ACE_PoolEntry FindBestMatch(int blockSize, byte[] signature, int payloadSize)
        {
            List<ACE_PoolEntry> snapshot;
            lock (SyncRoot) { snapshot = Entries.ToList(); }

            if (snapshot.Count == 0)
                return null;

            int bestScore = int.MinValue;
            var candidates = new List<(ACE_PoolEntry entry, int score)>();

            foreach (var entry in snapshot)
            {
                int score = ComputeSimilarityScore(entry, blockSize, signature, payloadSize);
                if (score > bestScore)
                {
                    bestScore = score;
                    candidates.Clear();
                    candidates.Add((entry, score));
                }
                else if (score == bestScore)
                {
                    candidates.Add((entry, score));
                }
            }

            if (candidates.Count == 0)
                return null;

            // 同分候选中轮换使用，避免总用同一条
            int bucket = blockSize / 512;
            int pickIndex = 0;
            lock (SyncRoot)
            {
                if (!LastUsedBucket.TryGetValue(bucket, out pickIndex))
                    pickIndex = 0;
                pickIndex = pickIndex % candidates.Count;
                LastUsedBucket[bucket] = pickIndex + 1;
            }

            var chosen = candidates[pickIndex].entry;
            lock (SyncRoot) { chosen.UseCount++; }
            return chosen;
        }

        private static int ComputeSimilarityScore(ACE_PoolEntry entry, int blockSize, byte[] signature, int payloadSize)
        {
            int score = 0;

            // 块大小接近度 (0~40)
            int sizeDiff = Math.Abs(entry.BlockSize - blockSize);
            score += Math.Max(0, 40 - sizeDiff / 128);

            // 负载大小接近度 (0~20)
            int payloadDiff = Math.Abs(entry.PayloadSize - payloadSize);
            score += Math.Max(0, 20 - payloadDiff / 64);

            // 前缀特征相似度 (0~40)
            var sigA = entry.SignatureBytes;
            if (signature != null && sigA != null && signature.Length > 0 && sigA.Length > 0)
            {
                int compareLen = Math.Min(Math.Min(signature.Length, sigA.Length), 48);
                int match = 0;
                for (int i = 0; i < compareLen; i++)
                {
                    if (signature[i] == sigA[i])
                        match++;
                }
                score += (int)((double)match / compareLen * 40);
            }

            return score;
        }
    }
}
