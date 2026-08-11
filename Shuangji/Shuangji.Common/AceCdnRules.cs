using System;
using System.Net;

namespace Shuangji.Common
{
    /// <summary>
    /// ACE / MRPCS 检测 CDN 黑洞（对齐花海「饿死动态下发」）。
    /// Gateway CONNECT 与隧道侧共用同一套域名关键字 + IP 表。
    /// </summary>
    public static class AceCdnRules
    {
        /// <summary>域名/主机子串（小写匹配）。</summary>
        public static readonly string[] HostNeedles = new[]
        {
            "anticheatexpert",
            "cschannel",
            "acesdk",
            "mrpcs",
            "tsssdk",
            "tss.",
            "ano.",
            "anogs",
            "iescdn",
            "qcloud",
            "cdn-tencent",
            "tencentcdn",
            "nj.",
            "gcloudsdk",
            "tdm.",
            "tp2.",
        };

        /// <summary>已知威严/检测 CDN IP（可继续追加）。</summary>
        public static readonly string[] IpBlackhole = new[]
        {
            "183.2.172.46",
        };

        public static bool LooksAceOrCdnHost(string host)
        {
            if (string.IsNullOrEmpty(host)) return false;
            string h = host.Trim().ToLowerInvariant();
            if (h.Length == 0) return false;

            if (IsBlackholeIp(h)) return true;

            for (int i = 0; i < HostNeedles.Length; i++)
            {
                if (h.IndexOf(HostNeedles[i], StringComparison.Ordinal) >= 0)
                    return true;
            }
            // 宽一点：tencent 子域但排除明显业务无关时仍可能误伤；
            // 仅作「关注目标」时用 ContainsTencentLoose，黑洞用 ShouldDropConnect。
            return false;
        }

        public static bool ContainsTencentLoose(string host)
        {
            if (string.IsNullOrEmpty(host)) return false;
            return host.IndexOf("tencent", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        public static bool IsBlackholeIp(string hostOrIp)
        {
            if (string.IsNullOrEmpty(hostOrIp)) return false;
            string s = hostOrIp.Trim();
            // 去掉 IPv6 括号
            if (s.StartsWith("[") && s.EndsWith("]"))
                s = s.Substring(1, s.Length - 2);
            for (int i = 0; i < IpBlackhole.Length; i++)
            {
                if (string.Equals(s, IpBlackhole[i], StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            IPAddress ip;
            if (IPAddress.TryParse(s, out ip))
            {
                string canon = ip.ToString();
                for (int i = 0; i < IpBlackhole.Length; i++)
                {
                    if (string.Equals(canon, IpBlackhole[i], StringComparison.OrdinalIgnoreCase))
                        return true;
                }
            }
            return false;
        }

        /// <summary>
        /// 局内修改模式：应拒绝 CONNECT 的检测 CDN。
        /// 关键字命中或 IP 黑洞；tencent 裸域太宽，不单独黑洞。
        /// </summary>
        public static bool ShouldDropConnect(string host)
        {
            if (string.IsNullOrEmpty(host)) return false;
            if (IsBlackholeIp(host)) return true;
            return LooksAceOrCdnHost(host);
        }

        /// <summary>是否值得送引擎/隧道观察（比黑洞略宽，含 tencent）。</summary>
        public static bool IsWatchHost(string host)
        {
            if (LooksAceOrCdnHost(host)) return true;
            return ContainsTencentLoose(host);
        }
    }
}
