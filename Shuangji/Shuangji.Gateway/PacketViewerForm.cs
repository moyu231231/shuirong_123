using System;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using Shuangji.Common;

namespace Shuangji.Gateway
{
    /// <summary>花瓶/Charles 风格抓包查看：列表 + 十六进制/ASCII。</summary>
    public class PacketViewerForm : Form
    {
        private ListBox _list;
        private TextBox _hex;
        private Label _info;
        private CheckBox _chkAuto;
        private TextBox _filter;
        private CapturedPacket[] _snap = new CapturedPacket[0];

        public PacketViewerForm()
        {
            Text = "抓包查看（花瓶风格）";
            Width = 980;
            Height = 640;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);

            var top = new Panel { Dock = DockStyle.Top, Height = 36 };
            var btnRefresh = new Button { Left = 8, Top = 6, Width = 70, Text = "刷新" };
            var btnClear = new Button { Left = 84, Top = 6, Width = 70, Text = "清空" };
            var btnExport = new Button { Left = 160, Top = 6, Width = 90, Text = "导出选中" };
            _chkAuto = new CheckBox { Left = 260, Top = 8, AutoSize = true, Checked = true, Text = "自动刷新" };
            _filter = new TextBox { Left = 360, Top = 6, Width = 200 };
            top.Controls.Add(new Label { Left = 570, Top = 10, AutoSize = true, Text = "过滤(端口/标签)" });
            top.Controls.AddRange(new Control[] { btnRefresh, btnClear, btnExport, _chkAuto, _filter });

            _info = new Label { Dock = DockStyle.Bottom, Height = 22, Text = "提示：右侧乱码区是密文的 ASCII 预览，不是文本文件" };

            var split = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Vertical,
                SplitterDistance = 380
            };
            _list = new ListBox
            {
                Dock = DockStyle.Fill,
                IntegralHeight = false,
                HorizontalScrollbar = true,
                Font = new Font("Consolas", 9F)
            };
            _hex = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                ReadOnly = true,
                Font = new Font("Consolas", 9.5F),
                BackColor = Color.FromArgb(30, 30, 30),
                ForeColor = Color.FromArgb(220, 220, 220)
            };
            split.Panel1.Controls.Add(_list);
            split.Panel2.Controls.Add(_hex);

            Controls.Add(split);
            Controls.Add(_info);
            Controls.Add(top);

            btnRefresh.Click += (s, e) => Reload();
            btnClear.Click += (s, e) => { PacketCaptureStore.Clear(); Reload(); };
            btnExport.Click += (s, e) => ExportSelected();
            _list.SelectedIndexChanged += (s, e) => ShowSelected();
            _filter.TextChanged += (s, e) => Reload();

            var t = new Timer { Interval = 800 };
            t.Tick += (s, e) => { if (_chkAuto.Checked) Reload(keepSel: true); };
            t.Start();
            FormClosed += (s, e) => t.Stop();

            PacketCaptureStore.Changed += () =>
            {
                if (IsDisposed) return;
                BeginInvoke(new Action(() => { if (_chkAuto.Checked) Reload(keepSel: true); }));
            };

            Reload();
        }

        private void Reload(bool keepSel = false)
        {
            int old = _list.SelectedIndex;
            string f = (_filter.Text ?? "").Trim().ToLowerInvariant();
            _snap = PacketCaptureStore.Snapshot()
                .Where(p =>
                {
                    if (string.IsNullOrEmpty(f)) return true;
                    return (p.Port + "").Contains(f)
                           || (p.Tags ?? "").ToLowerInvariant().Contains(f)
                           || (p.Host ?? "").ToLowerInvariant().Contains(f)
                           || (p.DirText ?? "").Contains(f);
                })
                .ToArray();

            _list.BeginUpdate();
            _list.Items.Clear();
            foreach (var p in _snap) _list.Items.Add(p.Summary);
            _list.EndUpdate();
            _info.Text = string.Format("共 {0} 条 | 乱码=密文ASCII预览 | 标记NJ检测23/密文/文件体=疑似下发或上报载荷", _snap.Length);

            if (keepSel && old >= 0 && old < _list.Items.Count)
                _list.SelectedIndex = old;
        }

        private void ShowSelected()
        {
            int i = _list.SelectedIndex;
            if (i < 0 || i >= _snap.Length) { _hex.Text = ""; return; }
            var p = _snap[i];
            var header = string.Format(
                "时间: {0:yyyy-MM-dd HH:mm:ss.fff}\r\n方向: {1}\r\n目标: {2}:{3}\r\n用户: {4}\r\n长度: {5}\r\n标签: {6}\r\n动作: {7}\r\n\r\n",
                p.Time, p.DirText, p.Host, p.Port, p.User, p.Length, p.Tags, p.Action);
            _hex.Text = header + PacketCaptureStore.FormatHexDump(p.Data, 8192);
        }

        private void ExportSelected()
        {
            int i = _list.SelectedIndex;
            if (i < 0 || i >= _snap.Length) return;
            var p = _snap[i];
            using (var sfd = new SaveFileDialog
            {
                Filter = "文本|*.txt|二进制|*.bin",
                FileName = string.Format("pkt_{0:HHmmss}_{1}_{2}.txt", p.Time, p.DirText, p.Port)
            })
            {
                if (sfd.ShowDialog(this) != DialogResult.OK) return;
                if (sfd.FileName.EndsWith(".bin", StringComparison.OrdinalIgnoreCase))
                    System.IO.File.WriteAllBytes(sfd.FileName, p.Data ?? new byte[0]);
                else
                    System.IO.File.WriteAllText(sfd.FileName,
                        p.DirText + "\r\n" + PacketCaptureStore.FormatHexDump(p.Data, 65536),
                        System.Text.Encoding.UTF8);
            }
        }
    }
}
