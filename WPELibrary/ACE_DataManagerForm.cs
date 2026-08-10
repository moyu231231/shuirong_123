using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;
using WPELibrary.Lib;

namespace WPELibrary
{
    /// <summary>
    /// 数据管理器：用快照+定时刷新，避免 Hook 线程改绑定列表导致崩溃/卡死。
    /// </summary>
    public class ACE_DataManagerForm : Form
    {
        private DataGridView dgv;
        private Button btnClear;
        private Button btnDelete;
        private Button btnSave;
        private Button btnClose;
        private Label lblInfo;
        private TabControl tabs;
        private Timer refreshTimer;
        private int lastVersion = -1;
        private BindingSource bindingSource;
        private List<ACE_SmartFilter.PoolEntry> viewList;

        public ACE_DataManagerForm()
        {
            Text = "数据管理器";
            FormBorderStyle = FormBorderStyle.Sizable;
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(780, 420);
            MinimumSize = new Size(640, 320);
            Font = new Font("Microsoft YaHei UI", 9F);

            tabs = new TabControl { Dock = DockStyle.Fill };
            var page = new TabPage("当前收集数据");

            dgv = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                RowHeadersVisible = false,
                BackgroundColor = Color.White,
                VirtualMode = false
            };
            // 关闭即时重绘抖动
            typeof(DataGridView).InvokeMember("DoubleBuffered",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.SetProperty,
                null, dgv, new object[] { true });

            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "cRegion", HeaderText = "区", DataPropertyName = "Region", FillWeight = 40 });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "cServer", HeaderText = "服", DataPropertyName = "Server", FillWeight = 40 });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "cContent", HeaderText = "收集内容", DataPropertyName = "ContentHex", FillWeight = 220 });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "cInfo1", HeaderText = "Info", DataPropertyName = "Info1Hex", FillWeight = 80 });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "cInfo2", HeaderText = "Info2", DataPropertyName = "Info2Hex", FillWeight = 40 });
            dgv.AutoGenerateColumns = false;

            viewList = new List<ACE_SmartFilter.PoolEntry>();
            bindingSource = new BindingSource { DataSource = viewList };
            dgv.DataSource = bindingSource;

            page.Controls.Add(dgv);
            tabs.TabPages.Add(page);

            var bottom = new Panel { Dock = DockStyle.Bottom, Height = 40 };
            btnDelete = new Button { Text = "删除选中", Location = new Point(8, 8), Size = new Size(80, 26) };
            btnClear = new Button { Text = "清空全部", Location = new Point(96, 8), Size = new Size(80, 26) };
            btnSave = new Button { Text = "保存数据池", Location = new Point(184, 8), Size = new Size(90, 26) };
            btnClose = new Button { Text = "关闭", Location = new Point(280, 8), Size = new Size(70, 26) };
            lblInfo = new Label { Location = new Point(370, 12), AutoSize = true, Text = "" };

            btnDelete.Click += (s, e) =>
            {
                try
                {
                    if (dgv.SelectedRows.Count == 0) return;
                    var keys = new List<string>();
                    foreach (DataGridViewRow row in dgv.SelectedRows)
                    {
                        if (row.DataBoundItem is ACE_SmartFilter.PoolEntry pe && pe.Info1Hex != null)
                            keys.Add(pe.Info1Hex);
                    }
                    ACE_SmartFilter.RemoveByKeys(keys);
                    ForceRefresh();
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, ex.Message, "删除失败");
                }
            };
            btnClear.Click += (s, e) =>
            {
                if (MessageBox.Show(this, "确定清空全部数据池？", "确认", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    ACE_SmartFilter.ClearPool();
                    ForceRefresh();
                }
            };
            btnSave.Click += (s, e) =>
            {
                ACE_SmartFilter.SavePool();
                MessageBox.Show(this, "已保存到:\n" + ACE_SmartFilter.GetPoolFilePath(), "保存成功");
            };
            btnClose.Click += (s, e) => Close();

            bottom.Controls.AddRange(new Control[] { btnDelete, btnClear, btnSave, btnClose, lblInfo });
            Controls.Add(tabs);
            Controls.Add(bottom);

            // 定时刷新：仅 UI 线程重绑快照，绝不让 Hook 线程碰 DataGridView
            refreshTimer = new Timer { Interval = 800 };
            refreshTimer.Tick += (s, e) =>
            {
                try
                {
                    if (IsDisposed || !IsHandleCreated) return;
                    int ver = ACE_SmartFilter.Version;
                    if (ver == lastVersion && !ACE_SmartFilter.ConsumeDirty()) return;
                    RefreshView(ver);
                }
                catch { }
            };
            refreshTimer.Start();

            FormClosed += (s, e) =>
            {
                try
                {
                    refreshTimer.Stop();
                    refreshTimer.Dispose();
                }
                catch { }
            };

            ForceRefresh();
        }

        private void ForceRefresh()
        {
            RefreshView(ACE_SmartFilter.Version);
            ACE_SmartFilter.ConsumeDirty();
        }

        private void RefreshView(int ver)
        {
            if (IsDisposed) return;
            try
            {
                var snap = ACE_SmartFilter.GetSnapshot();
                int first = dgv.FirstDisplayedScrollingRowIndex;
                int sel = dgv.CurrentCell != null ? dgv.CurrentCell.RowIndex : -1;

                viewList = snap;
                bindingSource.DataSource = viewList;
                bindingSource.ResetBindings(false);

                lblInfo.Text = "共 " + snap.Count + " 条";
                lastVersion = ver;

                if (first >= 0 && first < dgv.Rows.Count)
                {
                    try { dgv.FirstDisplayedScrollingRowIndex = first; } catch { }
                }
                if (sel >= 0 && sel < dgv.Rows.Count)
                {
                    try { dgv.Rows[sel].Selected = true; } catch { }
                }
            }
            catch (Exception ex)
            {
                try { lblInfo.Text = "刷新异常: " + ex.Message; } catch { }
            }
        }
    }
}
