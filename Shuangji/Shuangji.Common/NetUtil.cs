using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace Shuangji.Common
{
    public static class NetUtil
    {
        /// <summary>本机可用于外部访问的 IPv4 列表（排除回环）。</summary>
        public static List<string> GetLanIPv4()
        {
            var list = new List<string>();
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string ip = ua.Address.ToString();
                        if (ip.StartsWith("127.")) continue;
                        if (!list.Contains(ip)) list.Add(ip);
                    }
                }
            }
            catch { }

            if (list.Count == 0)
            {
                try
                {
                    foreach (var a in Dns.GetHostAddresses(Dns.GetHostName()))
                    {
                        if (a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
                        {
                            string ip = a.ToString();
                            if (!list.Contains(ip)) list.Add(ip);
                        }
                    }
                }
                catch { }
            }
            return list;
        }

        public static string PrimaryLanIP()
        {
            var all = GetLanIPv4();
            // 优先常见内网段
            var pref = all.FirstOrDefault(ip =>
                ip.StartsWith("192.168.") || ip.StartsWith("10.") || ip.StartsWith("172."));
            return pref ?? all.FirstOrDefault() ?? "127.0.0.1";
        }

        /// <summary>尝试为 HttpListener 注册 URLACL（需管理员，失败忽略）。</summary>
        public static void TryAddUrlAcl(int port)
        {
            try
            {
                string args = $"http add urlacl url=http://+:{port}/ user=Everyone";
                var psi = new ProcessStartInfo("netsh", args)
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var p = Process.Start(psi))
                {
                    p?.WaitForExit(3000);
                }
            }
            catch { }
        }

        public static string BuildAccessTips(int webPort, int apiPort, int socksPort)
        {
            var ips = GetLanIPv4();
            var sb = new StringBuilder();
            sb.AppendLine("本机访问:  http://127.0.0.1:" + webPort + "/");
            if (ips.Count == 0)
            {
                sb.AppendLine("未检测到局域网 IP。请检查网卡。");
            }
            else
            {
                sb.AppendLine("手机/其他电脑（同一 WiFi/局域网）请用：");
                foreach (var ip in ips.Take(4))
                {
                    sb.AppendLine("  网页: http://" + ip + ":" + webPort + "/");
                    sb.AppendLine("  代理: SOCKS5 " + ip + ":" + socksPort);
                }
            }
            sb.AppendLine("外网用户需要：公网IP/域名 + 路由器端口映射(" + webPort + "," + socksPort + ") 或内网穿透。");
            return sb.ToString().TrimEnd();
        }
    }
}
