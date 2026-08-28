using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal sealed class ReleaseSelectionForm : Form
{
    private readonly ListView _candidateList = new()
    {
        Dock = DockStyle.Fill,
        View = View.Details,
        FullRowSelect = true,
        MultiSelect = false,
        HideSelection = false,
        GridLines = true,
        ShowItemToolTips = true,
    };
    private readonly Button _confirmButton = new()
    {
        Text = "使用所选版本",
        AutoSize = true,
        Enabled = false,
        Padding = new Padding(12, 4, 12, 4),
    };
    private readonly TextBox _candidateDetails = new()
    {
        Dock = DockStyle.Fill,
        ReadOnly = true,
        BorderStyle = BorderStyle.FixedSingle,
        BackColor = SystemColors.Window,
        AccessibleName = "所选发行版本详细信息",
        TabStop = true,
    };

    public ReleaseCandidate? SelectedCandidate { get; private set; }

    public ReleaseSelectionForm(IReadOnlyList<ReleaseCandidate> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        if (candidates.Count < 2)
        {
            throw new ArgumentException("At least two release candidates are required.", nameof(candidates));
        }

        Text = "选择匹配的专辑版本";
        Font = new Font("Microsoft YaHei UI", 9F);
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;
        ShowInTaskbar = false;
        MinimumSize = new Size(720, 390);
        ClientSize = new Size(900, 500);

        _candidateList.Columns.Add("序号", 58, HorizontalAlignment.Center);
        _candidateList.Columns.Add("艺术家", 190);
        _candidateList.Columns.Add("专辑", 300);
        _candidateList.Columns.Add("发行日期", 112);
        _candidateList.Columns.Add("地区", 72, HorizontalAlignment.Center);
        _candidateList.Columns.Add("碟号", 64, HorizontalAlignment.Center);
        foreach (var candidate in candidates)
        {
            var item = new ListViewItem(candidate.Index.ToString(System.Globalization.CultureInfo.InvariantCulture))
            {
                Tag = candidate,
                ToolTipText = CreateToolTip(candidate),
            };
            item.SubItems.Add(candidate.Artist);
            item.SubItems.Add(candidate.Title);
            item.SubItems.Add(DefaultIfBlank(candidate.Date));
            item.SubItems.Add(DefaultIfBlank(candidate.Country));
            item.SubItems.Add(DefaultIfBlank(candidate.Disc));
            _candidateList.Items.Add(item);
        }

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 1,
            Padding = new Padding(14, 12, 14, 8),
        };
        header.Controls.Add(new Label
        {
            Text = "MusicBrainz 找到多个与这张光盘匹配的发行版本",
            AutoSize = true,
            Font = new Font(Font.FontFamily, 11F, FontStyle.Bold),
            ForeColor = Color.FromArgb(31, 41, 55),
        });
        header.Controls.Add(new Label
        {
            Text = "请选择光盘实际对应的版本。确认后转换会从当前位置继续，不会重新读取音频。",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(3, 5, 3, 0),
        });

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.RightToLeft,
            Padding = new Padding(10, 6, 10, 10),
        };
        var cancelButton = new Button
        {
            Text = "取消转换",
            DialogResult = DialogResult.Cancel,
            AutoSize = true,
            Padding = new Padding(12, 4, 12, 4),
        };
        _confirmButton.Click += (_, _) => ConfirmSelection();
        buttons.Controls.Add(_confirmButton);
        buttons.Controls.Add(cancelButton);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.Controls.Add(header, 0, 0);
        root.Controls.Add(_candidateList, 0, 1);
        var detailsPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 2,
            Padding = new Padding(10, 6, 10, 0),
        };
        detailsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        detailsPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        detailsPanel.Controls.Add(new Label
        {
            Text = "版本标识",
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(3, 6, 8, 3),
        }, 0, 0);
        detailsPanel.Controls.Add(_candidateDetails, 1, 0);
        root.Controls.Add(detailsPanel, 0, 2);
        root.Controls.Add(buttons, 0, 3);
        Controls.Add(root);

        AcceptButton = _confirmButton;
        CancelButton = cancelButton;
        _candidateList.SelectedIndexChanged += (_, _) =>
        {
            _confirmButton.Enabled = _candidateList.SelectedItems.Count == 1;
            UpdateCandidateDetails();
        };
        _candidateList.DoubleClick += (_, _) => ConfirmSelection();
        Resize += (_, _) => ApplyCandidateColumnWidths();
        DpiChanged += (_, _) => ApplyCandidateColumnWidths();
        Shown += (_, _) =>
        {
            ApplyCandidateColumnWidths();
            _candidateList.Items[0].Selected = true;
            _candidateList.Items[0].Focused = true;
            _candidateList.Focus();
        };
    }

    private void ConfirmSelection()
    {
        if (_candidateList.SelectedItems.Count != 1
            || _candidateList.SelectedItems[0].Tag is not ReleaseCandidate candidate)
        {
            return;
        }

        SelectedCandidate = candidate;
        DialogResult = DialogResult.OK;
        Close();
    }

    private void UpdateCandidateDetails()
    {
        if (_candidateList.SelectedItems.Count != 1
            || _candidateList.SelectedItems[0].Tag is not ReleaseCandidate candidate)
        {
            _candidateDetails.Clear();
            return;
        }

        var releaseId = candidate.ReleaseId.Length == 0 ? "—" : candidate.ReleaseId;
        var barcode = candidate.Barcode.Length == 0 ? "—" : candidate.Barcode;
        _candidateDetails.Text = $"MusicBrainz ID: {releaseId}    条码: {barcode}";
    }

    private void ApplyCandidateColumnWidths()
    {
        if (_candidateList.Columns.Count != 6 || _candidateList.ClientSize.Width <= 0)
        {
            return;
        }

        var scale = DeviceDpi / 96F;
        int Scale(int logicalPixels) => Math.Max(1, (int)Math.Round(logicalPixels * scale));

        var sequenceWidth = Scale(58);
        var dateWidth = Scale(112);
        var countryWidth = Scale(72);
        var discWidth = Scale(64);
        var fixedWidth = sequenceWidth + dateWidth + countryWidth + discWidth;
        var availableWidth = Math.Max(
            Scale(450),
            _candidateList.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - Scale(4));
        var flexibleWidth = Math.Max(Scale(360), availableWidth - fixedWidth);
        var artistWidth = Math.Max(Scale(150), (int)Math.Round(flexibleWidth * 0.38));
        var albumWidth = Math.Max(Scale(210), flexibleWidth - artistWidth);

        _candidateList.Columns[0].Width = sequenceWidth;
        _candidateList.Columns[1].Width = artistWidth;
        _candidateList.Columns[2].Width = albumWidth;
        _candidateList.Columns[3].Width = dateWidth;
        _candidateList.Columns[4].Width = countryWidth;
        _candidateList.Columns[5].Width = discWidth;
    }

    private static string DefaultIfBlank(string value) => value.Length == 0 ? "—" : value;

    private static string CreateToolTip(ReleaseCandidate candidate)
    {
        var details = new List<string>();
        if (candidate.ReleaseId.Length > 0)
        {
            details.Add("MusicBrainz ID: " + candidate.ReleaseId);
        }
        if (candidate.Barcode.Length > 0)
        {
            details.Add("条码: " + candidate.Barcode);
        }
        return string.Join(Environment.NewLine, details);
    }
}
