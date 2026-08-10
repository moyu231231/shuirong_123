using System;
using System.Drawing;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Shuangji.Common;

namespace Shuangji.AccountServer
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
        private readonly AccountStore _store = new AccountStore();
        private readonly OnlineSessionStore _online = new OnlineSessionStore();
        private HttpListener _listener;
        private Thread _thread;
        private volatile bool _running;
        private DataGridView _dgv, _dgvOnline;
        private TextBox _txtUser, _txtPass, _txtRemark;
        private NumericUpDown _numMaxConn;
        private CheckBox _chkEnable;
        private Label _lblStatus, _lblOnline;
        private ListBox _log;
        private System.Windows.Forms.Timer _timer;

        public MainForm()
        {
            Text = "双机 · 账号中枢 (AccountServer)";
            Width = 1000;
            Height = 680;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);

            var top = new Panel { Dock = DockStyle.Top, Height = 110 };
            _txtUser = new TextBox { Left = 70, Top = 12, Width = 120 };
            _txtPass = new TextBox { Left = 260, Top = 12, Width = 120 };
            _txtRemark = new TextBox { Left = 450, Top = 12, Width = 160 };
            _numMaxConn = new NumericUpDown
            {
                Left = 230, Top = 42, Width = 70,
                Minimum = 0, Maximum = 9999, Value = 10
            };
            _chkEnable = new CheckBox { Left = 70, Top = 45, Text = "启用", Checked = true, AutoSize = true };
            var btnAdd = new Button { Left = 400, Top = 42, Width = 90, Text = "添加/更新" };
            var btnDel = new Button { Left = 500, Top = 42, Width = 80, Text = "删除" };
            var btnRefresh = new Button { Left = 590, Top = 42, Width = 80, Text = "刷新" };
            var btnStart = new Button { Left = 680, Top = 42, Width = 100, Text = "启动API服务" };
            var btnStop = new Button { Left = 790, Top = 42, Width = 80, Text = "停止" };
            _lblStatus = new Label { Left = 70, Top = 78, AutoSize = true, Text = "服务未启动  默认端口 " + Ports.Account };

            top.Controls.Add(new Label { Left = 12, Top = 15, Text = "账号", AutoSize = true });
            top.Controls.Add(new Label { Left = 210, Top = 15, Text = "密码", AutoSize = true });
            top.Controls.Add(new Label { Left = 400, Top = 15, Text = "备注", AutoSize = true });
            top.Controls.Add(new Label { Left = 150, Top = 46, Text = "连接上限", AutoSize = true });
            top.Controls.Add(new Label { Left = 310, Top = 46, Text = "(0=不限)", AutoSize = true, ForeColor = Color.Gray });
            top.Controls.AddRange(new Control[] { _txtUser, _txtPass, _txtRemark, _numMaxConn, _chkEnable, btnAdd, btnDel, btnRefresh, btnStart, btnStop, _lblStatus });

            var tabs = new TabControl { Dock = DockStyle.Fill };
            var tabAcc = new TabPage("账号列表");
            var tabOnline = new TabPage("在线用户");

            _dgv = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                RowHeadersVisible = false
            };
            _dgv.Columns.Add("u", "账号");
            _dgv.Columns.Add("p", "密码");
            _dgv.Columns.Add("e", "启用");
            _dgv.Columns.Add("m", "连接上限");
            _dgv.Columns.Add("r", "备注");
            _dgv.Columns.Add("c", "创建时间");
            tabAcc.Controls.Add(_dgv);

            var onlineTop = new Panel { Dock = DockStyle.Top, Height = 36 };
            _lblOnline = new Label { Left = 12, Top = 10, AutoSize = true, Text = "在线：0 用户 / 0 连接" };
            var btnKick = new Button { Left = 280, Top = 5, Width = 120, Text = "踢掉选中用户" };
            var btnPurge = new Button { Left = 410, Top = 5, Width = 120, Text = "清理僵尸会话" };
            onlineTop.Controls.AddRange(new Control[] { _lblOnline, btnKick, btnPurge });

            _dgvOnline = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                RowHeadersVisible = false
            };
            _dgvOnline.Columns.Add("u", "账号");
            _dgvOnline.Columns.Add("n", "当前连接");
            _dgvOnline.Columns.Add("m", "上限");
            _dgvOnline.Columns.Add("ip", "客户端IP");
            _dgvOnline.Columns.Add("f", "首次上线");
            _dgvOnline.Columns.Add("l", "最近活动");
            tabOnline.Controls.Add(_dgvOnline);
            tabOnline.Controls.Add(onlineTop);

            tabs.TabPages.Add(tabAcc);
            tabs.TabPages.Add(tabOnline);

            var logPanel = new Panel { Dock = DockStyle.Bottom, Height = 160 };
            var logBar = new Panel { Dock = DockStyle.Top, Height = 32 };
            var btnClearLog = new Button { Left = 8, Top = 3, Width = 90, Text = "清理日志" };
            logBar.Controls.Add(btnClearLog);
            _log = new ListBox { Dock = DockStyle.Fill };
            logPanel.Controls.Add(_log);
            logPanel.Controls.Add(logBar);

            Controls.Add(tabs);
            Controls.Add(logPanel);
            Controls.Add(top);

            btnClearLog.Click += (s, e) =>
            {
                _log.Items.Clear();
                Log("日志已清理");
            };

            btnAdd.Click += (s, e) =>
            {
                var dto = new AccountDto
                {
                    UserName = _txtUser.Text.Trim(),
                    Password = _txtPass.Text,
                    Enabled = _chkEnable.Checked,
                    Remark = _txtRemark.Text,
                    MaxConnections = (int)_numMaxConn.Value
                };
                if (_store.Upsert(dto, out var msg))
                {
                    Log("保存账号: " + dto.UserName + " 连接上限=" + (dto.MaxConnections <= 0 ? "不限" : dto.MaxConnections.ToString()));
                    RefreshGrid();
                }
                else MessageBox.Show(msg);
            };
            btnDel.Click += (s, e) =>
            {
                if (_dgv.CurrentRow == null) return;
                string u = Convert.ToString(_dgv.CurrentRow.Cells[0].Value);
                if (MessageBox.Show("删除账号 " + u + " ?", "确认", MessageBoxButtons.YesNo) == DialogResult.Yes)
                {
                    _store.Delete(u);
                    _online.CloseUser(u);
                    RefreshGrid();
                    RefreshOnline();
                    Log("删除: " + u);
                }
            };
            btnRefresh.Click += (s, e) => { RefreshGrid(); RefreshOnline(); };
            btnStart.Click += (s, e) => StartApi();
            btnStop.Click += (s, e) => StopApi();
            btnKick.Click += (s, e) =>
            {
                if (_dgvOnline.CurrentRow == null) return;
                string u = Convert.ToString(_dgvOnline.CurrentRow.Cells[0].Value);
                _online.CloseUser(u);
                RefreshOnline();
                Log("已从在线面板清除: " + u + "（已建立的代理连接需断线后才会真正释放）");
            };
            btnPurge.Click += (s, e) =>
            {
                int n = _online.PurgeStale(30);
                RefreshOnline();
                Log("清理僵尸会话: " + n);
            };
            _dgv.CellClick += (s, e) =>
            {
                if (e.RowIndex < 0) return;
                _txtUser.Text = Convert.ToString(_dgv.Rows[e.RowIndex].Cells[0].Value);
                _txtPass.Text = Convert.ToString(_dgv.Rows[e.RowIndex].Cells[1].Value);
                string maxText = Convert.ToString(_dgv.Rows[e.RowIndex].Cells[3].Value);
                if (maxText == "不限") _numMaxConn.Value = 0;
                else if (int.TryParse(maxText, out int m))
                    _numMaxConn.Value = Math.Max(0, Math.Min(9999, m));
                _txtRemark.Text = Convert.ToString(_dgv.Rows[e.RowIndex].Cells[4].Value);
            };

            _timer = new System.Windows.Forms.Timer { Interval = 2000 };
            _timer.Tick += (s, e) => RefreshOnline();

            FormClosing += (s, e) =>
            {
                if (MdiParent != null && e.CloseReason == CloseReason.UserClosing)
                {
                    e.Cancel = true;
                    WindowState = FormWindowState.Minimized;
                    return;
                }
                _timer.Stop();
                StopApi();
            };
            Load += (s, e) =>
            {
                RefreshGrid();
                RefreshOnline();
                StartApi();
                _timer.Start();
            };
        }

        private void RefreshGrid()
        {
            _dgv.Rows.Clear();
            foreach (var a in _store.GetAll())
            {
                string max = a.MaxConnections <= 0 ? "不限" : a.MaxConnections.ToString();
                _dgv.Rows.Add(a.UserName, a.Password, a.Enabled ? "是" : "否", max, a.Remark, a.CreatedAt.ToString("yyyy-MM-dd HH:mm"));
            }
        }

        private void RefreshOnline()
        {
            if (InvokeRequired) { BeginInvoke(new Action(RefreshOnline)); return; }
            var list = _online.Snapshot(u =>
            {
                var a = _store.Find(u);
                return a == null ? 0 : a.MaxConnections;
            });
            _dgvOnline.Rows.Clear();
            int totalConn = 0;
            foreach (var o in list)
            {
                totalConn += o.Connections;
                string max = o.MaxConnections <= 0 ? "不限" : o.MaxConnections.ToString();
                _dgvOnline.Rows.Add(
                    o.UserName,
                    o.Connections,
                    max,
                    o.RemoteIps,
                    o.FirstSeen.ToString("HH:mm:ss"),
                    o.LastSeen.ToString("HH:mm:ss"));
            }
            _lblOnline.Text = $"在线：{list.Count} 用户 / {totalConn} 连接";
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

        private void StartApi()
        {
            if (_running) return;
            try
            {
                _listener = new HttpListener();
                _listener.Prefixes.Add($"http://+:{Ports.Account}/");
                try { _listener.Start(); }
                catch
                {
                    _listener.Prefixes.Clear();
                    _listener.Prefixes.Add($"http://127.0.0.1:{Ports.Account}/");
                    _listener.Start();
                }
                _running = true;
                _thread = new Thread(ListenLoop) { IsBackground = true };
                _thread.Start();
                _lblStatus.Text = $"API 已启动  http://127.0.0.1:{Ports.Account}/  （Gateway/Engine/网页鉴权都连这里）";
                _lblStatus.ForeColor = Color.DarkGreen;
                Log("API 启动成功");
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败（可用管理员运行）:\n" + ex.Message);
            }
        }

        private void StopApi()
        {
            _running = false;
            try { _listener?.Stop(); } catch { }
            _lblStatus.Text = "服务已停止";
            _lblStatus.ForeColor = Color.DarkRed;
        }

        private void ListenLoop()
        {
            while (_running)
            {
                try
                {
                    var ctx = _listener.GetContext();
                    ThreadPool.QueueUserWorkItem(_ => HandleRequest(ctx));
                }
                catch { if (!_running) break; }
            }
        }

        private void HandleRequest(HttpListenerContext ctx)
        {
            try
            {
                string path = ctx.Request.Url.AbsolutePath.TrimEnd('/').ToLowerInvariant();
                string body = HttpUtil.ReadBody(ctx.Request);
                string resp;

                if (path == "/api/ping")
                {
                    resp = SimpleJson.Serialize(new { ok = true, name = "AccountServer", time = DateTime.Now });
                }
                else if (path == "/api/auth" && ctx.Request.HttpMethod == "POST")
                {
                    var d = SimpleJson.DeserializeObject(body);
                    string u = SimpleJson.GetString(d, "UserName");
                    string p = SimpleJson.GetString(d, "Password");
                    bool ok = _store.Auth(u, p, out var msg);
                    var acc = ok ? _store.Find(u) : null;
                    resp = SimpleJson.Serialize(new AuthResponse
                    {
                        Ok = ok,
                        Message = msg,
                        UserName = u,
                        Token = ok ? AccountStore.MakeToken(u) : null,
                        MaxConnections = acc?.MaxConnections ?? 0
                    });
                    Log((ok ? "鉴权成功: " : "鉴权失败: ") + u + " " + msg);
                }
                else if (path == "/api/accounts" && ctx.Request.HttpMethod == "GET")
                {
                    resp = SimpleJson.Serialize(_store.GetAll());
                }
                else if (path == "/api/account/upsert" && ctx.Request.HttpMethod == "POST")
                {
                    var dto = SimpleJson.Deserialize<AccountDto>(body);
                    bool ok = _store.Upsert(dto, out var msg);
                    if (ok) BeginInvoke(new Action(RefreshGrid));
                    resp = SimpleJson.Serialize(new { ok, message = msg });
                }
                else if (path == "/api/account/delete" && ctx.Request.HttpMethod == "POST")
                {
                    var d = SimpleJson.DeserializeObject(body);
                    string u = SimpleJson.GetString(d, "UserName");
                    bool ok = _store.Delete(u);
                    if (ok)
                    {
                        _online.CloseUser(u);
                        BeginInvoke(new Action(() => { RefreshGrid(); RefreshOnline(); }));
                    }
                    resp = SimpleJson.Serialize(new { ok });
                }
                else if (path == "/api/session/open" && ctx.Request.HttpMethod == "POST")
                {
                    var d = SimpleJson.DeserializeObject(body);
                    string u = SimpleJson.GetString(d, "UserName");
                    string id = SimpleJson.GetString(d, "ConnId");
                    string ip = SimpleJson.GetString(d, "RemoteIp");
                    _online.Open(u, id, ip);
                    BeginInvoke(new Action(RefreshOnline));
                    resp = SimpleJson.Serialize(new { ok = true });
                }
                else if (path == "/api/session/close" && ctx.Request.HttpMethod == "POST")
                {
                    var d = SimpleJson.DeserializeObject(body);
                    string id = SimpleJson.GetString(d, "ConnId");
                    _online.Close(id);
                    BeginInvoke(new Action(RefreshOnline));
                    resp = SimpleJson.Serialize(new { ok = true });
                }
                else if (path == "/api/session/touch" && ctx.Request.HttpMethod == "POST")
                {
                    var d = SimpleJson.DeserializeObject(body);
                    _online.Touch(SimpleJson.GetString(d, "ConnId"));
                    resp = SimpleJson.Serialize(new { ok = true });
                }
                else if (path == "/api/online" && ctx.Request.HttpMethod == "GET")
                {
                    var list = _online.Snapshot(u =>
                    {
                        var a = _store.Find(u);
                        return a == null ? 0 : a.MaxConnections;
                    });
                    resp = SimpleJson.Serialize(new { ok = true, data = list, total = _online.TotalConnections() });
                }
                else
                {
                    resp = SimpleJson.Serialize(new { ok = false, message = "not found", path });
                    Task.Run(() => HttpUtil.WriteTextAsync(ctx.Response, resp, 404)).Wait();
                    return;
                }

                HttpUtil.WriteTextAsync(ctx.Response, resp).Wait();
            }
            catch (Exception ex)
            {
                try { HttpUtil.WriteTextAsync(ctx.Response, SimpleJson.Serialize(new { ok = false, message = ex.Message }), 500).Wait(); } catch { }
            }
        }
    }
}
