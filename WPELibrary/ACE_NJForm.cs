using System;
using System.Drawing;
using System.Windows.Forms;
using WPELibrary.Lib;

namespace WPELibrary
{
    /// <summary>
    /// NJ 智能滤镜控制面板（数据处理 / 收集数据）。
    /// </summary>
    public class ACE_NJForm : Form
    {
        private RadioButton rbProcess;
        private RadioButton rbCollect;
        private CheckBox cbCancelBound;
        private CheckBox cbEnableProcess;
        private CheckBox cbRepairSend;
        private Button btnManage;
        private Button btnClose;
        private Label lblCount;
        private CheckBox cbOnly04;
        private CheckBox cbIgnore00;
        private CheckBox cbIgnore01;
        private CheckBox cbIgnore02;
        private CheckBox cbIgnore03;
        private CheckBox cbIgnore04;
        private Timer refreshTimer;

        public ACE_NJForm()
        {
            BuildUi();
            LoadFromEngine();
            refreshTimer = new Timer { Interval = 500 };
            refreshTimer.Tick += (s, e) =>
            {
                lblCount.Text = "nj数据量:" + ACE_SmartFilter.PoolCount;
            };
            refreshTimer.Start();
            FormClosed += (s, e) =>
            {
                refreshTimer.Stop();
                SaveToEngine();
                ACE_SmartFilter.SavePool();
            };
        }

        private void BuildUi()
        {
            Text = "NJ";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(360, 220);
            Font = new Font("Microsoft YaHei UI", 9F);

            rbProcess = new RadioButton { Text = "数据处理", Location = new Point(16, 16), AutoSize = true };
            rbCollect = new RadioButton { Text = "收集数据", Location = new Point(110, 16), AutoSize = true };
            cbCancelBound = new CheckBox { Text = "取消数据越界", Location = new Point(210, 16), AutoSize = true };

            cbEnableProcess = new CheckBox { Text = "处理开关", Location = new Point(16, 52), AutoSize = true };
            cbRepairSend = new CheckBox { Text = "校验数据修复(发送)", Location = new Point(110, 52), AutoSize = true };

            btnManage = new Button
            {
                Text = "管理数据",
                Location = new Point(130, 85),
                Size = new Size(100, 32)
            };
            btnManage.Click += (s, e) =>
            {
                // 非模态：避免收集时阻塞 NJ 面板；管理器用定时快照刷新，不会卡死
                var f = new ACE_DataManagerForm();
                f.Show(this);
            };

            lblCount = new Label
            {
                Text = "nj数据量:0",
                Location = new Point(16, 95),
                AutoSize = true,
                ForeColor = Color.DarkBlue
            };

            cbOnly04 = new CheckBox { Text = "仅04(Cheat)", Location = new Point(240, 130), AutoSize = true };
            cbIgnore00 = new CheckBox { Text = "忽视00", Location = new Point(16, 160), AutoSize = true };
            cbIgnore01 = new CheckBox { Text = "忽视01", Location = new Point(80, 160), AutoSize = true };
            cbIgnore02 = new CheckBox { Text = "忽视02", Location = new Point(144, 160), AutoSize = true };
            cbIgnore03 = new CheckBox { Text = "忽视03", Location = new Point(208, 160), AutoSize = true };
            cbIgnore04 = new CheckBox { Text = "忽视04", Location = new Point(272, 160), AutoSize = true };

            btnClose = new Button
            {
                Text = "关闭",
                Location = new Point(270, 12),
                Size = new Size(70, 26),
                Anchor = AnchorStyles.Top | AnchorStyles.Right
            };
            // 放到右上角标题区旁
            btnClose.Location = new Point(ClientSize.Width - 80, 8);
            btnClose.Click += (s, e) => Close();

            // 模式变更即时生效
            EventHandler modeChanged = (s, e) => SaveToEngine();
            rbProcess.CheckedChanged += modeChanged;
            rbCollect.CheckedChanged += modeChanged;
            cbCancelBound.CheckedChanged += modeChanged;
            cbEnableProcess.CheckedChanged += modeChanged;
            cbRepairSend.CheckedChanged += modeChanged;
            cbOnly04.CheckedChanged += modeChanged;
            cbIgnore00.CheckedChanged += modeChanged;
            cbIgnore01.CheckedChanged += modeChanged;
            cbIgnore02.CheckedChanged += modeChanged;
            cbIgnore03.CheckedChanged += modeChanged;
            cbIgnore04.CheckedChanged += modeChanged;

            Controls.AddRange(new Control[]
            {
                rbProcess, rbCollect, cbCancelBound,
                cbEnableProcess, cbRepairSend,
                btnManage, lblCount,
                cbOnly04, cbIgnore00, cbIgnore01, cbIgnore02, cbIgnore03, cbIgnore04,
                btnClose
            });
        }

        private void LoadFromEngine()
        {
            rbProcess.Checked = ACE_SmartFilter.Mode == ACE_SmartFilter.WorkMode.Process;
            rbCollect.Checked = ACE_SmartFilter.Mode == ACE_SmartFilter.WorkMode.Collect;
            if (!rbProcess.Checked && !rbCollect.Checked)
                rbProcess.Checked = false;

            cbCancelBound.Checked = ACE_SmartFilter.CancelOutOfBound;
            cbEnableProcess.Checked = ACE_SmartFilter.EnableProcess;
            cbRepairSend.Checked = ACE_SmartFilter.EnableChecksumRepairSend;
            cbOnly04.Checked = ACE_SmartFilter.Only04Cheat;
            cbIgnore00.Checked = ACE_SmartFilter.Ignore00;
            cbIgnore01.Checked = ACE_SmartFilter.Ignore01;
            cbIgnore02.Checked = ACE_SmartFilter.Ignore02;
            cbIgnore03.Checked = ACE_SmartFilter.Ignore03;
            cbIgnore04.Checked = ACE_SmartFilter.Ignore04;
            lblCount.Text = "nj数据量:" + ACE_SmartFilter.PoolCount;
        }

        private void SaveToEngine()
        {
            if (rbCollect.Checked)
                ACE_SmartFilter.Mode = ACE_SmartFilter.WorkMode.Collect;
            else if (rbProcess.Checked)
                ACE_SmartFilter.Mode = ACE_SmartFilter.WorkMode.Process;
            else
                ACE_SmartFilter.Mode = ACE_SmartFilter.WorkMode.None;

            ACE_SmartFilter.CancelOutOfBound = cbCancelBound.Checked;
            ACE_SmartFilter.EnableProcess = cbEnableProcess.Checked;
            ACE_SmartFilter.EnableChecksumRepairSend = cbRepairSend.Checked;
            ACE_SmartFilter.Only04Cheat = cbOnly04.Checked;
            ACE_SmartFilter.Ignore00 = cbIgnore00.Checked;
            ACE_SmartFilter.Ignore01 = cbIgnore01.Checked;
            ACE_SmartFilter.Ignore02 = cbIgnore02.Checked;
            ACE_SmartFilter.Ignore03 = cbIgnore03.Checked;
            ACE_SmartFilter.Ignore04 = cbIgnore04.Checked;
        }
    }
}
