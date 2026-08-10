using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading;
using System.Windows.Forms;
using Shuangji.Common;

namespace Shuangji.Engine
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
        private readonly AccountPoolEngine _engine = new AccountPoolEngine();
        private HttpListener _api;
        private HttpListener _web;
        private volatile bool _running;
        private Label _lbl;
        private TextBox _txtPublicUrl;
        private ListBox _log;
        private string _accountBase = "http://127.0.0.1:" + Ports.Account;
        private bool _boundAllInterfaces;

        public MainForm()
        {
            Text = "双机 · 数据处理引擎 (Engine)";
            Width = 820;
            Height = 580;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);

            var top = new Panel { Dock = DockStyle.Top, Height = 150 };
            _lbl = new Label
            {
                Left = 12,
                Top = 8,
                Width = 780,
                Height = 88,
                Text = "引擎未启动"
            };
            top.Controls.Add(new Label
            {
                Left = 12,
                Top = 100,
                AutoSize = true,
                Text = "云服务器公网访问地址(填公网IP或域名):"
            });
            _txtPublicUrl = new TextBox
            {
                Left = 270,
                Top = 96,
                Width = 380,
                Text = "http://你的云机公网IP:" + Ports.EngineWeb + "/"
            };
            var btnCopy = new Button { Left = 660, Top = 94, Width = 90, Text = "复制地址" };
            btnCopy.Click += (s, e) =>
            {
                try
                {
                    Clipboard.SetText(_txtPublicUrl.Text.Trim());
                    Log("已复制: " + _txtPublicUrl.Text.Trim());
                }
                catch { }
            };
            top.Controls.Add(_txtPublicUrl);
            top.Controls.Add(btnCopy);
            top.Controls.Add(_lbl);

            _log = new ListBox { Dock = DockStyle.Fill };
            var bottom = new Panel { Dock = DockStyle.Bottom, Height = 48 };
            var btnStart = new Button { Left = 12, Top = 10, Width = 100, Text = "启动服务" };
            var btnStop = new Button { Left = 120, Top = 10, Width = 80, Text = "停止" };
            var btnOpen = new Button { Left = 210, Top = 10, Width = 120, Text = "打开本机网页" };
            var btnLan = new Button { Left = 340, Top = 10, Width = 160, Text = "云机访问说明" };
            var btnClearLog = new Button { Left = 520, Top = 10, Width = 100, Text = "清理日志" };
            bottom.Controls.AddRange(new Control[] { btnStart, btnStop, btnOpen, btnLan, btnClearLog });
            Controls.Add(_log);
            Controls.Add(bottom);
            Controls.Add(top);

            btnStart.Click += (s, e) => Start();
            btnStop.Click += (s, e) => Stop();
            btnClearLog.Click += (s, e) =>
            {
                _log.Items.Clear();
                Log("日志已清理");
            };
            btnOpen.Click += (s, e) =>
            {
                try { System.Diagnostics.Process.Start($"http://127.0.0.1:{Ports.EngineWeb}/"); } catch { }
            };
            btnLan.Click += (s, e) =>
            {
                string pub = _txtPublicUrl.Text.Trim();
                string tips =
                    "部署模式：软件跑在云服务器上，用户用公网访问（不需要内网穿透）。\n\n" +
                    "1) 网页控制台（用户浏览器打开）\n" +
                    "   " + pub + "\n" +
                    "   或 http://云机公网IP:" + Ports.EngineWeb + "/\n\n" +
                    "2) Shadowrocket 代理（用户手机）\n" +
                    "   SOCKS5  云机公网IP:" + Ports.Socks + "\n" +
                    "   用户名/密码 = 账号中枢里开的账号\n\n" +
                    "3) 云厂商安全组/防火墙必须放行入站：\n" +
                    "   " + Ports.EngineWeb + " (网页)\n" +
                    "   " + Ports.Socks + " (代理)\n" +
                    "   " + Ports.Account + " / " + Ports.Engine + " 一般仅服务器本机用，可不对公网开放\n\n" +
                    "三个软件都装在同一台云机，用管理员运行 START_ALL.bat 即可。";
                MessageBox.Show(this, tips, "云服务器访问方式");
            };
            FormClosing += (s, e) =>
            {
                if (MdiParent != null && e.CloseReason == CloseReason.UserClosing)
                {
                    e.Cancel = true;
                    WindowState = FormWindowState.Minimized;
                    return;
                }
                try { _engine.SaveAll(); Log("退出前已保存全部账号数据池"); } catch { }
                Stop();
            };
            Load += (s, e) => Start();
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
                // 先尝试注册 URLACL，让非本机也能访问 + 端口
                NetUtil.TryAddUrlAcl(Ports.Engine);
                NetUtil.TryAddUrlAcl(Ports.EngineWeb);

                _api = CreateListener(Ports.Engine);
                _web = CreateListener(Ports.EngineWeb);
                _running = true;
                new Thread(() => Loop(_api, HandleApi)) { IsBackground = true }.Start();
                new Thread(() => Loop(_web, HandleWeb)) { IsBackground = true }.Start();

                string lan = NetUtil.PrimaryLanIP();
                string scope = _boundAllInterfaces ? "已监听所有网卡(云机公网可达)" : "仅本机(请管理员重开)";
                _lbl.Text =
                    $"引擎已启动（{scope}）\n" +
                    $"本机: http://127.0.0.1:{Ports.EngineWeb}/\n" +
                    $"用户请用云机公网IP访问: http://公网IP:{Ports.EngineWeb}/  （安全组放行 {Ports.EngineWeb},{Ports.Socks}）";
                _lbl.ForeColor = Color.DarkGreen;
                if (_txtPublicUrl.Text.Contains("你的云机") || string.IsNullOrWhiteSpace(_txtPublicUrl.Text))
                    _txtPublicUrl.Text = $"http://公网IP:{Ports.EngineWeb}/";
                Log("Engine 启动成功 - 云机部署：用户浏览器打开 http://云机公网IP:" + Ports.EngineWeb + "/");
                Log("Shadowrocket: SOCKS5 云机公网IP:" + Ports.Socks + " + 账号密码");
                foreach (var ip in NetUtil.GetLanIPv4())
                    Log("本机网卡IP(供对照): " + ip);
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败（建议管理员运行）:\n" + ex.Message);
            }
        }

        private HttpListener CreateListener(int port)
        {
            var l = new HttpListener();
            // 优先绑定所有网卡，供手机/其他电脑访问
            l.Prefixes.Add($"http://+:{port}/");
            try
            {
                l.Start();
                _boundAllInterfaces = true;
                return l;
            }
            catch
            {
                try { l.Close(); } catch { }
                l = new HttpListener();
                l.Prefixes.Add($"http://127.0.0.1:{port}/");
                l.Start();
                _boundAllInterfaces = false;
                Log("警告: 端口 " + port + " 只能本机访问。请用管理员运行，或执行 netsh http add urlacl");
                return l;
            }
        }

        private void Stop()
        {
            try { _engine.SaveAll(); } catch { }
            _running = false;
            try { _api?.Stop(); } catch { }
            try { _web?.Stop(); } catch { }
            _lbl.Text = "引擎已停止";
            _lbl.ForeColor = Color.DarkRed;
        }

        private void Loop(HttpListener listener, Action<HttpListenerContext> handler)
        {
            while (_running)
            {
                try
                {
                    var ctx = listener.GetContext();
                    ThreadPool.QueueUserWorkItem(_ =>
                    {
                        try { handler(ctx); }
                        catch (Exception ex)
                        {
                            try { HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = ex.Message }), 500).Wait(); } catch { }
                        }
                    });
                }
                catch { if (!_running) break; }
            }
        }

        private bool AuthUser(string user, string pass, out string msg)
        {
            msg = "";
            try
            {
                string json = HttpUtil.PostJson(_accountBase + "/api/auth",
                    SimpleJson.Serialize(new { UserName = user, Password = pass }));
                var r = SimpleJson.Deserialize<AuthResponse>(json);
                msg = r?.Message ?? "";
                return r != null && r.Ok;
            }
            catch (Exception ex)
            {
                msg = "账号中枢不可用: " + ex.Message;
                return false;
            }
        }

        private void HandleApi(HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath.TrimEnd('/').ToLowerInvariant();
            string body = HttpUtil.ReadBody(ctx.Request);

            if (path == "/api/ping")
            {
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = true, name = "Engine" })).Wait();
                return;
            }

            if (path == "/api/login" && ctx.Request.HttpMethod == "POST")
            {
                var d = SimpleJson.DeserializeObject(body);
                string u = SimpleJson.GetString(d, "UserName");
                string p = SimpleJson.GetString(d, "Password");
                bool ok = AuthUser(u, p, out var msg);
                if (ok) _engine.SetOnline(u, true);
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok, Ok = ok, message = msg, Message = msg })).Wait();
                Log((ok ? "网页登录成功: " : "网页登录失败: ") + u);
                return;
            }

            if (path == "/api/mode" && ctx.Request.HttpMethod == "POST")
            {
                var d = SimpleJson.DeserializeObject(body);
                string u = SimpleJson.GetString(d, "UserName");
                string p = SimpleJson.GetString(d, "Password");
                int m = SimpleJson.GetInt(d, "Mode");
                if (!AuthUser(u, p, out var msg))
                {
                    HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = msg })).Wait();
                    return;
                }
                var want = (WorkMode)m;
                if (!_engine.CanEnterMode(u, want, out var deny))
                {
                    HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, Ok = false, message = deny, Message = deny })).Wait();
                    Log(u + " 切换失败: " + deny);
                    return;
                }
                _engine.SetMode(u, want);
                string modeCn = ModeToCn(want);
                int down = _engine.GetDownlinkPoolCount(u);
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = true, message = "模式已切换: " + modeCn, downlinkPool = down })).Wait();
                Log(u + " 模式 => " + modeCn + " 下行池=" + down);
                return;
            }

            if (path == "/api/reset" && ctx.Request.HttpMethod == "POST")
            {
                var d = SimpleJson.DeserializeObject(body);
                string u = SimpleJson.GetString(d, "UserName");
                string p = SimpleJson.GetString(d, "Password");
                if (!AuthUser(u, p, out var msg))
                {
                    HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = msg })).Wait();
                    return;
                }
                _engine.Reset(u);
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = true, message = "数据池已重置" })).Wait();
                Log(u + " 重置数据池");
                return;
            }

            if (path == "/api/status")
            {
                string u = HttpUtil.Query(ctx.Request, "user");
                string p = HttpUtil.Query(ctx.Request, "pass");
                if (!AuthUser(u, p, out var msg))
                {
                    HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = msg })).Wait();
                    return;
                }
                var st = _engine.Status(u);
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = true, Ok = true, data = st })).Wait();
                return;
            }

            if (path == "/api/pool")
            {
                string u = HttpUtil.Query(ctx.Request, "user");
                string p = HttpUtil.Query(ctx.Request, "pass");
                if (!AuthUser(u, p, out var msg))
                {
                    HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = msg })).Wait();
                    return;
                }
                var items = _engine.Snapshot(u).Select(x => new
                {
                    Time = x.Time.ToString("HH:mm:ss"),
                    x.Host,
                    x.Downlink,
                    x.Length,
                    x.Info1Hex,
                    x.Info2Hex,
                    x.ContentHex
                }).ToList();
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = true, items })).Wait();
                return;
            }

            // Gateway 调用：处理数据包
            if (path == "/api/packet" && ctx.Request.HttpMethod == "POST")
            {
                var d = SimpleJson.DeserializeObject(body);
                string user = SimpleJson.GetString(d, "UserName");
                var job = new PacketJob
                {
                    UserName = user,
                    Host = SimpleJson.GetString(d, "Host"),
                    Port = SimpleJson.GetInt(d, "Port"),
                    IsServerToClient = SimpleJson.GetBool(d, "IsServerToClient"),
                    Data = HttpUtil.FromBase64(SimpleJson.GetString(d, "Data"))
                };
                var r = _engine.Process(job);
                HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new
                {
                    ok = true,
                    Modified = r.Modified,
                    Action = r.Action,
                    Message = r.Message,
                    Mode = (int)_engine.GetMode(user),
                    Data = r.Modified ? HttpUtil.ToBase64(r.Data) : null
                })).Wait();
                if (r.Action == "collect" || r.Action == "replace" || r.Action == "intercept")
                    Log($"{user} {r.Action} host={job.Host}:{job.Port} len={job.Data?.Length} {r.Message}");
                return;
            }

            HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = "not found" }), 404).Wait();
        }

        private void HandleWeb(HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath;
            if (path == "/" || path == "/index.html")
            {
                string file = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Web", "index.html");
                if (!File.Exists(file))
                {
                    // 兼容开发路径
                    file = Path.Combine(Application.StartupPath, "Web", "index.html");
                }
                if (File.Exists(file))
                {
                    string html = File.ReadAllText(file);
                    HttpUtil.WriteTextAsync(ctx.Response, html, 200, "text/html; charset=utf-8").Wait();
                    return;
                }
                HttpUtil.WriteTextAsync(ctx.Response, "<h1>index.html missing</h1>", 404, "text/html").Wait();
                return;
            }

            // 网页同源 API 代理到本进程 API 端口逻辑：直接复用 HandleApi 路径风格
            if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
            {
                HandleApi(ctx);
                return;
            }

            HttpUtil.WriteTextAsync(ctx.Response, "Not Found", 404, "text/plain").Wait();
        }

        private static string ModeToCn(WorkMode m)
        {
            switch (m)
            {
                case WorkMode.Collect: return "读取模式";
                case WorkMode.Modify: return "修改模式";
                case WorkMode.Lobby: return "大厅";
                default: return "待机";
            }
        }
    }
}
