using System;
using System.Drawing;
using System.Windows.Forms;

namespace Shuangji.Host
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ShellForm());
        }
    }

    public class ShellForm : Form
    {
        private Form _account;
        private Form _gateway;
        private Form _engine;

        public ShellForm()
        {
            Text = "水溶C端口 · 控制台";
            Width = 1280;
            Height = 800;
            StartPosition = FormStartPosition.CenterScreen;
            IsMdiContainer = true;
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Color.FromArgb(40, 44, 52);

            var menu = new MenuStrip();
            var win = new ToolStripMenuItem("窗口");
            win.DropDownItems.Add("账号中枢", null, (s, e) => ShowChild(ref _account, () => new AccountServer.MainForm(), "账号中枢"));
            win.DropDownItems.Add("流量网关", null, (s, e) => ShowChild(ref _gateway, () => new Gateway.MainForm(), "流量网关"));
            win.DropDownItems.Add("数据处理引擎", null, (s, e) => ShowChild(ref _engine, () => new Engine.MainForm(), "数据处理引擎"));
            win.DropDownItems.Add(new ToolStripSeparator());
            win.DropDownItems.Add("平铺窗口", null, (s, e) => LayoutMdi(MdiLayout.TileHorizontal));
            win.DropDownItems.Add("层叠窗口", null, (s, e) => LayoutMdi(MdiLayout.Cascade));
            var help = new ToolStripMenuItem("帮助");
            help.DropDownItems.Add("关于", null, (s, e) =>
                MessageBox.Show(this, "水溶C端口 一体化控制台\n账号中枢 / 流量网关 / 数据处理引擎", "关于"));
            menu.Items.Add(win);
            menu.Items.Add(help);
            MainMenuStrip = menu;
            Controls.Add(menu);

            var bar = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Dock = DockStyle.Top };
            bar.Items.Add(new ToolStripButton("账号中枢", null, (s, e) => ShowChild(ref _account, () => new AccountServer.MainForm(), "账号中枢")));
            bar.Items.Add(new ToolStripButton("流量网关", null, (s, e) => ShowChild(ref _gateway, () => new Gateway.MainForm(), "流量网关")));
            bar.Items.Add(new ToolStripButton("数据处理引擎", null, (s, e) => ShowChild(ref _engine, () => new Engine.MainForm(), "数据处理引擎")));
            bar.Items.Add(new ToolStripSeparator());
            bar.Items.Add(new ToolStripButton("平铺", null, (s, e) => LayoutMdi(MdiLayout.TileHorizontal)));
            Controls.Add(bar);

            Load += (s, e) =>
            {
                ShowChild(ref _account, () => new AccountServer.MainForm(), "账号中枢");
                ShowChild(ref _engine, () => new Engine.MainForm(), "数据处理引擎");
                ShowChild(ref _gateway, () => new Gateway.MainForm(), "流量网关");
                BeginInvoke(new Action(() => LayoutMdi(MdiLayout.TileHorizontal)));
            };

            FormClosing += (s, e) =>
            {
                CloseChild(_account);
                CloseChild(_gateway);
                CloseChild(_engine);
            };
        }

        private void ShowChild(ref Form field, Func<Form> create, string title)
        {
            if (field == null || field.IsDisposed)
            {
                field = create();
                field.Text = title;
                field.MdiParent = this;
                field.Show();
            }
            else
            {
                if (!field.Visible) field.Show();
                field.WindowState = FormWindowState.Normal;
                field.BringToFront();
                field.Activate();
            }
        }

        private static void CloseChild(Form f)
        {
            if (f == null || f.IsDisposed) return;
            try
            {
                f.Close();
            }
            catch { }
        }
    }
}
