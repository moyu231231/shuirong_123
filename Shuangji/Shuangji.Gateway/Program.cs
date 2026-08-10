using System;
using System.Collections.Concurrent;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Shuangji.Common;

namespace Shuangji.Gateway
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    public class MainForm : Form
    {
        private TcpListener _listener;
        private volatile bool _running;
        private Label _lbl;
        private ListBox _log;
        private CheckBox _chkMitm;
        private TextBox _txtAccount, _txtEngine;
        private X509Certificate2 _ca;
        private string _accountBase = "http://127.0.0.1:" + Ports.Account;
        private string _engineBase = "http://127.0.0.1:" + Ports.Engine;
        private readonly ConcurrentDictionary<string, int> _connCount =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        /// <summary>引擎回报的账号模式缓存；仅修改模式(2)才本地硬拦 65010。</summary>
        private readonly ConcurrentDictionary<string, int> _modeCache =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        public MainForm()
        {
            Text = "双机 · 流量网关 (Gateway)";
            Width = 820;
            Height = 560;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);

            var top = new Panel { Dock = DockStyle.Top, Height = 120 };
            _txtAccount = new TextBox { Left = 100, Top = 12, Width = 260, Text = _accountBase };
            _txtEngine = new TextBox { Left = 100, Top = 42, Width = 260, Text = _engineBase };
            _chkMitm = new CheckBox { Left = 380, Top = 42, AutoSize = true, Checked = true, Text = "TLS才MITM；10012/80等TCP明文直接送引擎" };
            var btnStart = new Button { Left = 12, Top = 78, Width = 100, Text = "启动网关" };
            var btnStop = new Button { Left = 120, Top = 78, Width = 80, Text = "停止" };
            var btnCert = new Button { Left = 210, Top = 78, Width = 160, Text = "导出根证书给手机" };
            var btnClearLog = new Button { Left = 380, Top = 78, Width = 100, Text = "清理日志" };
            var btnViewer = new Button { Left = 490, Top = 78, Width = 120, Text = "抓包查看(花瓶)" };
            _lbl = new Label { Left = 620, Top = 82, AutoSize = true, Text = "未启动" };
            top.Controls.Add(new Label { Left = 12, Top = 15, Text = "账号中枢", AutoSize = true });
            top.Controls.Add(new Label { Left = 12, Top = 45, Text = "引擎地址", AutoSize = true });
            top.Controls.AddRange(new Control[] { _txtAccount, _txtEngine, _chkMitm, btnStart, btnStop, btnCert, btnClearLog, btnViewer, _lbl });

            _log = new ListBox { Dock = DockStyle.Fill };
            Controls.Add(_log);
            Controls.Add(top);

            btnStart.Click += (s, e) => Start();
            btnStop.Click += (s, e) => Stop();
            btnClearLog.Click += (s, e) =>
            {
                _log.Items.Clear();
                Log("日志已清理");
            };
            btnViewer.Click += (s, e) =>
            {
                var f = new PacketViewerForm();
                if (MdiParent != null) { f.MdiParent = MdiParent; f.Show(); }
                else f.Show(this);
            };
            btnCert.Click += (s, e) => ExportCa();
            FormClosing += (s, e) =>
            {
                if (MdiParent != null && e.CloseReason == CloseReason.UserClosing)
                {
                    e.Cancel = true;
                    WindowState = FormWindowState.Minimized;
                    return;
                }
                Stop();
            };
            Load += (s, e) =>
            {
                EnsureCa();
                Start();
            };
        }

        private void Log(string s)
        {
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + s;
            if (InvokeRequired) BeginInvoke(new Action(() => AppendLog(line)));
            else AppendLog(line);
        }

        private void AppendLog(string line)
        {
            if (_log.Items.Count >= 1000) _log.Items.Clear();
            _log.Items.Insert(0, line);
        }

        private void Start()
        {
            if (_running) return;
            try
            {
                _accountBase = _txtAccount.Text.Trim().TrimEnd('/');
                _engineBase = _txtEngine.Text.Trim().TrimEnd('/');
                EnsureCa();
                _listener = new TcpListener(IPAddress.Any, Ports.Socks);
                _listener.Start(200);
                _running = true;
                new Thread(AcceptLoop) { IsBackground = true }.Start();
                _lbl.Text = $"SOCKS5 已监听 :{Ports.Socks}  （用户 Shadowrocket 填：云机公网IP:{Ports.Socks} + 账号密码）";
                _lbl.ForeColor = Color.DarkGreen;
                Log("Gateway 启动 SOCKS5 :" + Ports.Socks);
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败:\n" + ex.Message);
            }
        }

        private void Stop()
        {
            _running = false;
            try { _listener?.Stop(); } catch { }
            _lbl.Text = "已停止";
            _lbl.ForeColor = Color.DarkRed;
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                try
                {
                    var c = _listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(_ => HandleClient(c));
                }
                catch { if (!_running) break; }
            }
        }

        private void HandleClient(TcpClient client)
        {
            string user = null;
            string connId = null;
            bool acquired = false;
            try
            {
                client.NoDelay = true;
                string remoteIp = "";
                try { remoteIp = ((IPEndPoint)client.Client.RemoteEndPoint).Address.ToString(); } catch { }
                var stream = client.GetStream();
                stream.ReadTimeout = 30000;
                stream.WriteTimeout = 30000;

                // greeting
                int ver = stream.ReadByte();
                int nmethods = stream.ReadByte();
                if (ver != 5 || nmethods < 0) { client.Close(); return; }
                var methods = new byte[nmethods];
                ReadExact(stream, methods, 0, nmethods);
                // 要求用户名密码 0x02
                stream.Write(new byte[] { 0x05, 0x02 }, 0, 2);

                // auth
                int authVer = stream.ReadByte();
                int ulen = stream.ReadByte();
                if (authVer != 1 || ulen < 0) { client.Close(); return; }
                var ub = new byte[ulen];
                ReadExact(stream, ub, 0, ulen);
                int plen = stream.ReadByte();
                var pb = new byte[Math.Max(0, plen)];
                if (plen > 0) ReadExact(stream, pb, 0, plen);
                user = Encoding.UTF8.GetString(ub);
                string pass = Encoding.UTF8.GetString(pb);

                if (!Auth(user, pass, out var msg, out int maxConn))
                {
                    stream.Write(new byte[] { 0x01, 0x01 }, 0, 2);
                    Log("认证失败 " + user + " " + msg);
                    client.Close();
                    return;
                }

                if (!TryAcquire(user, maxConn, out int cur))
                {
                    stream.Write(new byte[] { 0x01, 0x01 }, 0, 2);
                    Log($"连接超限拒绝 {user} 当前={cur} 上限={(maxConn <= 0 ? "不限" : maxConn.ToString())}");
                    client.Close();
                    return;
                }
                acquired = true;
                connId = Guid.NewGuid().ToString("N");
                ReportSession("open", user, connId, remoteIp);

                stream.Write(new byte[] { 0x01, 0x00 }, 0, 2);
                Log($"用户上线: {user} 连接={cur}/{(maxConn <= 0 ? "不限" : maxConn.ToString())} ip={remoteIp}");

                // request
                var hdr = new byte[4];
                ReadExact(stream, hdr, 0, 4);
                if (hdr[0] != 5) { client.Close(); return; }
                byte cmd = hdr[1];
                byte atyp = hdr[3];
                string host;
                int port;
                if (atyp == 1)
                {
                    var ip = new byte[4];
                    ReadExact(stream, ip, 0, 4);
                    host = new IPAddress(ip).ToString();
                }
                else if (atyp == 3)
                {
                    int l = stream.ReadByte();
                    var hb = new byte[l];
                    ReadExact(stream, hb, 0, l);
                    host = Encoding.ASCII.GetString(hb);
                }
                else if (atyp == 4)
                {
                    var ip = new byte[16];
                    ReadExact(stream, ip, 0, 16);
                    host = new IPAddress(ip).ToString();
                }
                else { client.Close(); return; }
                var pb2 = new byte[2];
                ReadExact(stream, pb2, 0, 2);
                port = (pb2[0] << 8) | pb2[1];

                if (cmd != 1) // CONNECT only
                {
                    ReplySocks(stream, 0x07);
                    client.Close();
                    return;
                }

                TcpClient remote = new TcpClient();
                try
                {
                    remote.NoDelay = true;
                    remote.Connect(host, port);
                }
                catch
                {
                    ReplySocks(stream, 0x05);
                    client.Close();
                    return;
                }
                ReplySocks(stream, 0x00);
                Log($"{user} CONNECT {host}:{port}");

                // 目标端口：80/443/10012/65010 等均为 TCP，不限 443
                bool watch = IsWatchTarget(host, port);
                Guid dropReg = Guid.Empty;
                if (port == 65010)
                {
                    dropReg = Port65010Control.Register(user, () =>
                    {
                        try { remote.Close(); } catch { }
                        try { client.Close(); } catch { }
                        Log($"断开65010(进修改重拉UID包) {user} {host}:{port}");
                    });
                }
                try
                {

                // 窥探客户端首包，判断是 TLS 还是明文/自定义十六进制协议
                bool isTls = false;
                try
                {
                    if (client.Client.Poll(800000, SelectMode.SelectRead) || client.Available > 0)
                    {
                        var peek = new byte[5];
                        int n = client.Client.Receive(peek, 0, peek.Length, SocketFlags.Peek);
                        isTls = n >= 3 && peek[0] == 0x16 && (peek[1] == 0x03 || peek[1] == 0x02);
                    }
                }
                catch { }

                if (isTls)
                    Log($"{user} {host}:{port} 判定=TLS");
                else
                    Log($"{user} {host}:{port} 判定=TCP明文/二进制 (送引擎处理={(watch ? "是" : "否")})");

                if (_chkMitm.Checked && isTls)
                {
                    try { RelayMitm(user, host, port, stream, remote); }
                    catch (Exception ex)
                    {
                        Log("MITM 失败，改走 TCP 透传+引擎: " + host + ":" + port + " " + ex.Message);
                        try { RelayPlain(user, host, port, stream, remote.GetStream(), forceEngine: watch); } catch { }
                    }
                }
                else
                {
                    // 10012/80/65010 等：直接当 TCP 十六进制流，按字节送引擎
                    RelayPlain(user, host, port, stream, remote.GetStream(), forceEngine: watch);
                }
                }
                finally
                {
                    if (port == 65010 && dropReg != Guid.Empty)
                        Port65010Control.Unregister(user, dropReg);
                }
            }
            catch (Exception ex)
            {
                Log("会话结束 " + (user ?? "") + " " + ex.Message);
            }
            finally
            {
                if (acquired && !string.IsNullOrEmpty(user))
                {
                    int left = Release(user);
                    ReportSession("close", user, connId, null);
                    Log($"用户下线: {user} 剩余连接={left}");
                }
                try { client.Close(); } catch { }
            }
        }

        private bool TryAcquire(string user, int maxConn, out int current)
        {
            current = 0;
            if (string.IsNullOrEmpty(user)) return false;
            while (true)
            {
                int cur = _connCount.GetOrAdd(user, 0);
                if (maxConn > 0 && cur >= maxConn)
                {
                    current = cur;
                    return false;
                }
                if (_connCount.TryUpdate(user, cur + 1, cur))
                {
                    current = cur + 1;
                    return true;
                }
            }
        }

        private int Release(string user)
        {
            if (string.IsNullOrEmpty(user)) return 0;
            while (true)
            {
                if (!_connCount.TryGetValue(user, out int cur)) return 0;
                int next = Math.Max(0, cur - 1);
                if (!_connCount.TryUpdate(user, next, cur)) continue;
                if (next == 0) _connCount.TryRemove(user, out _);
                return next;
            }
        }

        private void ReportSession(string ev, string user, string connId, string remoteIp)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    string path = ev == "open" ? "/api/session/open" : "/api/session/close";
                    string json = SimpleJson.Serialize(new
                    {
                        UserName = user,
                        ConnId = connId ?? "",
                        RemoteIp = remoteIp ?? ""
                    });
                    HttpUtil.PostJson(_accountBase + path, json, 2000);
                }
                catch { }
            });
        }

        private void RelayPlain(string user, string host, int port, NetworkStream client, NetworkStream remote, bool forceEngine = false)
        {
            var t1 = new Thread(() => Pump(user, host, port, client, remote, false, forceEngine)) { IsBackground = true };
            var t2 = new Thread(() => Pump(user, host, port, remote, client, true, forceEngine)) { IsBackground = true };
            t1.Start(); t2.Start();
            t1.Join(); t2.Join();
        }

        private void RelayMitm(string user, string host, int port, NetworkStream clientNet, TcpClient remoteTcp)
        {
            // 对客户端伪造证书，对服务器真实 TLS（任意端口，不限 443）
            var serverSsl = new SslStream(remoteTcp.GetStream(), false, (s, c, ch, e) => true);
            serverSsl.AuthenticateAsClient(host);

            var cert = IssueHostCert(host);
            var clientSsl = new SslStream(clientNet, false);
            clientSsl.AuthenticateAsServer(cert, false,
                System.Security.Authentication.SslProtocols.Tls | System.Security.Authentication.SslProtocols.Tls11 | System.Security.Authentication.SslProtocols.Tls12,
                false);

            var t1 = new Thread(() => Pump(user, host, port, clientSsl, serverSsl, false, true)) { IsBackground = true };
            var t2 = new Thread(() => Pump(user, host, port, serverSsl, clientSsl, true, true)) { IsBackground = true };
            t1.Start(); t2.Start();
            t1.Join(); t2.Join();
            try { clientSsl.Close(); } catch { }
            try { serverSsl.Close(); } catch { }
            try { remoteTcp.Close(); } catch { }
        }

        private bool IsModifyMode(string user)
        {
            // 优先进程内总线（点修改立刻生效）；HTTP 缓存作备用
            if (WorkModeHub.IsModify(user)) return true;
            int m;
            return !string.IsNullOrEmpty(user)
                   && _modeCache.TryGetValue(user, out m)
                   && m == (int)WorkMode.Modify;
        }

        private void Pump(string user, string host, int port, Stream from, Stream to, bool serverToClient, bool forceEngine)
        {
            var buf = new byte[65536];
            // 过滤器常驻保粘包状态；真正丢包仅在「修改/局内」模式
            Port65010UplinkFilter upFilter = (!serverToClient && port == 65010)
                ? new Port65010UplinkFilter() : null;
            Port65010DownlinkFilter downFilter = (serverToClient && port == 65010)
                ? new Port65010DownlinkFilter() : null;
            try
            {
                while (true)
                {
                    byte[] chunk = ReadChunk(from, buf, port, serverToClient);
                    if (chunk == null) break;

                    // 读取/大厅/待机：65010 全放行；局内才拦上报/检测文件
                    bool block65010 = IsModifyMode(user);
                    string capAction = "capture";
                    if (block65010 && upFilter != null)
                    {
                        int dropped;
                        chunk = upFilter.Filter(chunk, out dropped);
                        if (dropped > 0)
                        {
                            capAction = "intercept-report";
                            Log($"本地拦截举报/异常上报(上行4013) {user} {host}:{port} drop={dropped}B keep={chunk?.Length ?? 0}B");
                        }
                        if (chunk == null || chunk.Length == 0) continue;
                    }
                    if (block65010 && downFilter != null)
                    {
                        int dropped;
                        var before = chunk;
                        chunk = downFilter.Filter(chunk, out dropped);
                        if (dropped > 0)
                        {
                            capAction = "intercept-detectfile";
                            Log($"本地拦截65010下行检测文件 {user} {host}:{port} drop={dropped}B keep={chunk?.Length ?? 0}B");
                            PacketCaptureStore.Add(user, host, port, serverToClient, before, capAction);
                        }
                        if (chunk == null || chunk.Length == 0) continue;
                    }

                    // 抓包入库（花瓶查看）——在引擎处理前留原始样貌
                    if (port == 65010 || port == 10012 || port == 10011 || port == 10013
                        || PacketCaptureStore.IsInteresting(host, port, chunk))
                        PacketCaptureStore.Add(user, host, port, serverToClient, chunk, capAction);

                    chunk = MaybeProcess(user, host, port, chunk, serverToClient, forceEngine) ?? chunk;
                    // intercept 返回空数组：丢弃，不转发
                    if (chunk != null && chunk.Length > 0)
                        to.Write(chunk, 0, chunk.Length);
                }
            }
            catch { }
            try { to.Close(); } catch { }
            try { from.Close(); } catch { }
        }

        /// <summary>
        /// 65010 下行若包头 3366 且当前不足 10000，短时拼包，便于加速拦截。
        /// </summary>
        private static byte[] ReadChunk(Stream from, byte[] buf, int port, bool serverToClient)
        {
            int n = from.Read(buf, 0, buf.Length);
            if (n <= 0) return null;

            if (port == 65010 && serverToClient && n >= 2 && n < 10000 &&
                buf[0] == 0x33 && buf[1] == 0x66)
            {
                using (var ms = new MemoryStream(12000))
                {
                    ms.Write(buf, 0, n);
                    int oldTimeout = 30000;
                    try
                    {
                        if (from is NetworkStream ns) { try { oldTimeout = ns.ReadTimeout; ns.ReadTimeout = 200; } catch { } }
                        while (ms.Length < 10000 && ms.Length < buf.Length)
                        {
                            bool more = false;
                            try
                            {
                                if (from is NetworkStream nss) more = nss.DataAvailable;
                                else more = true;
                            }
                            catch { more = true; }
                            if (!more && ms.Length >= 2) break;
                            int m = from.Read(buf, 0, (int)Math.Min(buf.Length, 10000 - ms.Length + 2048));
                            if (m <= 0) break;
                            ms.Write(buf, 0, m);
                        }
                    }
                    catch { }
                    finally
                    {
                        try { if (from is NetworkStream ns2) ns2.ReadTimeout = oldTimeout; } catch { }
                    }
                    return ms.ToArray();
                }
            }

            var chunk = new byte[n];
            Buffer.BlockCopy(buf, 0, chunk, 0, n);
            return chunk;
        }

        private byte[] MaybeProcess(string user, string host, int port, byte[] data, bool down, bool forceEngine)
        {
            bool modify = IsModifyMode(user);
            bool uplink4013 = modify && port == 65010 && !down
                              && Port65010UplinkFilter.Contains4013Header(data);
            bool downFile = modify && port == 65010 && down
                            && Port65010DownlinkFilter.HasDetectionFileFrame(data, 0, data?.Length ?? 0);
            // 局内：NJ 上行 01 00 00 0E…0A 92 本地硬拦（引擎超时也不放行）
            if (modify && !down && LooksLikeNjReport0E(data))
            {
                Log($"本地拦截NJ上行举报0E {user} {host}:{port} {data.Length}B");
                PacketCaptureStore.Add(user, host, port, down, data, "intercept-nj0e");
                return new byte[0];
            }
            try
            {
                if (!forceEngine && !LooksInteresting(data) && !IsWatchTarget(host, port))
                    return data;

                string json = SimpleJson.Serialize(new
                {
                    UserName = user,
                    Host = host,
                    Port = port,
                    IsServerToClient = down,
                    Data = HttpUtil.ToBase64(data)
                });
                string resp = HttpUtil.PostJson(_engineBase + "/api/packet", json, 4000);
                var d = SimpleJson.DeserializeObject(resp);
                // 同步模式缓存：进局内后才开始本地硬拦 65010
                int mode = SimpleJson.GetInt(d, "Mode", -1);
                if (mode >= 0 && !string.IsNullOrEmpty(user))
                    _modeCache[user] = mode;

                string action = SimpleJson.GetString(d, "Action");
                if (action == "intercept")
                {
                    Log($"引擎拦截 {user} {host}:{port} {(down ? "下行" : "上行")} {data.Length}B {SimpleJson.GetString(d, "Message")}");
                    return new byte[0];
                }
                if (SimpleJson.GetBool(d, "Modified"))
                {
                    var mod = HttpUtil.FromBase64(SimpleJson.GetString(d, "Data"));
                    if (mod != null && mod.Length > 0) return mod;
                    if (mod != null && mod.Length == 0) return new byte[0];
                }
                if (action == "collect" || action == "replace")
                    Log($"引擎 {action} {user} {host}:{port} {(down ? "下行" : "上行")} {data.Length}B");
            }
            catch
            {
                // 仅局内模式才 fail-closed；读取/大厅绝不能因引擎异常丢 65010
                if (uplink4013 || downFile)
                {
                    Log($"引擎异常，fail-closed 丢弃65010{(uplink4013 ? "上行4013" : "下行检测文件")} {user} {host}:{port} {data.Length}B");
                    return new byte[0];
                }
            }
            return data;
        }

        private static bool IsWatchTarget(string host, int port)
        {
            // 业务相关端口：明文 TCP / HTTP / HTTPS / ACE 通道
            if (port == 80 || port == 443 || port == 8080 || port == 8443 ||
                port == 10012 || port == 65010 || port == 10013 || port == 10011)
                return true;
            return LooksInterestingHost(host);
        }

        private static bool LooksInterestingHost(string host)
        {
            if (string.IsNullOrEmpty(host)) return false;
            host = host.ToLowerInvariant();
            return host.Contains("anticheatexpert") || host.Contains("cschannel") ||
                   host.Contains("nj.") || host.Contains("acesdk") || host.Contains("tencent");
        }

        /// <summary>解密目标：01 00 00 0E … 0A 92（NJ 上行举报体）。</summary>
        private static bool LooksLikeNjReport0E(byte[] data)
        {
            if (data == null || data.Length < 20) return false;
            int n = Math.Min(data.Length, 65536);
            for (int i = 0; i <= n - 4; i++)
            {
                if (data[i] != 0x01 || data[i + 1] != 0x00
                    || data[i + 2] != 0x00 || data[i + 3] != 0x0E)
                    continue;
                int lim = Math.Min(i + 64, n - 1);
                for (int j = i + 4; j < lim; j++)
                {
                    if (data[j] == 0x0A && data[j + 1] == 0x92)
                        return true;
                }
            }
            return false;
        }

        private static bool LooksInteresting(byte[] data)
        {
            if (data == null || data.Length < 4) return false;
            int n = Math.Min(data.Length, 8192);
            for (int i = 0; i <= n - 2; i++)
            {
                if (data[i] == 0x33 && data[i + 1] == 0x66) return true;
                if (i <= n - 3 && data[i] == 0x01 && data[i + 1] == 0x00 && data[i + 2] == 0x09) return true;
                if (i <= n - 4 && data[i] == 0x01 && data[i + 1] == 0x0A && data[i + 2] == 0 && data[i + 3] == 0x09) return true;
                if (i <= n - 4 && data[i] == 0x01 && data[i + 1] == 0x00 && data[i + 2] == 0x00 && data[i + 3] == 0x0E) return true;
            }
            if (data[0] == (byte)'H' || data[0] == (byte)'G' || data[0] == (byte)'P') return true;
            return false;
        }

        private bool Auth(string user, string pass, out string msg, out int maxConn)
        {
            msg = "";
            maxConn = 0;
            try
            {
                string json = HttpUtil.PostJson(_accountBase + "/api/auth",
                    SimpleJson.Serialize(new { UserName = user, Password = pass }));
                var r = SimpleJson.Deserialize<AuthResponse>(json);
                msg = r?.Message ?? "";
                maxConn = r?.MaxConnections ?? 0;
                return r != null && r.Ok;
            }
            catch (Exception ex)
            {
                msg = ex.Message;
                return false;
            }
        }

        private static void ReplySocks(Stream s, byte rep)
        {
            // VER REP RSV ATYP BND.ADDR BND.PORT
            s.Write(new byte[] { 0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, 0, 10);
        }

        private static void ReadExact(Stream s, byte[] buf, int off, int len)
        {
            int read = 0;
            while (read < len)
            {
                int n = s.Read(buf, off + read, len - read);
                if (n <= 0) throw new EndOfStreamException();
                read += n;
            }
        }

        #region CA / MITM certs

        private void EnsureCa()
        {
            if (_ca != null) return;
            string pfx = Path.Combine(AppPaths.CertDir, "shuangji-ca.pfx");
            string cer = Path.Combine(AppPaths.CertDir, "shuangji-ca.cer");
            if (File.Exists(pfx))
            {
                _ca = new X509Certificate2(pfx, "shuangji", X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet | X509KeyStorageFlags.PersistKeySet);
            }
            else
            {
                _ca = CreateCa();
                File.WriteAllBytes(pfx, _ca.Export(X509ContentType.Pfx, "shuangji"));
                File.WriteAllBytes(cer, _ca.Export(X509ContentType.Cert));
            }
            if (!File.Exists(cer))
                File.WriteAllBytes(cer, _ca.Export(X509ContentType.Cert));
        }

        private void ExportCa()
        {
            EnsureCa();
            string cer = Path.Combine(AppPaths.CertDir, "shuangji-ca.cer");
            string desktop = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "shuangji-ca.cer");
            File.Copy(cer, desktop, true);
            MessageBox.Show("根证书已导出到桌面:\n" + desktop + "\n\n请发到 iPhone，安装并在「证书信任设置」中启用完全信任。", "导出成功");
        }

        private static X509Certificate2 CreateCa()
        {
            using (var rsa = RSA.Create(2048))
            {
                var req = new CertificateRequest("CN=Shuangji Root CA", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                req.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
                req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
                req.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(req.PublicKey, false));
                var ca = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
                return new X509Certificate2(ca.Export(X509ContentType.Pfx, "shuangji"), "shuangji",
                    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet | X509KeyStorageFlags.PersistKeySet);
            }
        }

        private X509Certificate2 IssueHostCert(string host)
        {
            EnsureCa();
            using (var rsa = RSA.Create(2048))
            {
                var req = new CertificateRequest("CN=" + host, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                var san = new SubjectAlternativeNameBuilder();
                try { san.AddDnsName(host); } catch { }
                req.CertificateExtensions.Add(san.Build());
                req.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
                req.CertificateExtensions.Add(new X509KeyUsageExtension(
                    X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
                req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
                    new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));

                byte[] serial = Guid.NewGuid().ToByteArray();
                serial[0] &= 0x7F;
                using (var signed = req.Create(_ca, DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(365), serial))
                {
                    // .NET Framework: 通过临时 PFX 合并私钥
                    return MergePrivateKey(signed, rsa);
                }
            }
        }

        private static X509Certificate2 MergePrivateKey(X509Certificate2 cert, RSA rsa)
        {
            try
            {
                // .NET Core / 新 API
                var m = typeof(X509Certificate2).GetMethod("CopyWithPrivateKey", new[] { typeof(RSA) });
                if (m != null)
                {
                    var withKey = (X509Certificate2)m.Invoke(cert, new object[] { rsa });
                    return new X509Certificate2(withKey.Export(X509ContentType.Pfx, "x"), "x",
                        X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);
                }
            }
            catch { }

            // 回退：自签（部分客户端需关闭证书校验；真机请优先装 CA 并用上面路径）
            using (var selfRsa = RSA.Create(2048))
            {
                var req = new CertificateRequest(cert.Subject, selfRsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                var self = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(365));
                return new X509Certificate2(self.Export(X509ContentType.Pfx, "x"), "x",
                    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);
            }
        }

        #endregion
    }
}
