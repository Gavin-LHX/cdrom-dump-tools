using System.Diagnostics;
using System.Collections.Concurrent;
using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal sealed class MainForm : Form
{
    private static readonly Color AccentColor = Color.FromArgb(34, 122, 214);
    private static readonly Color SurfaceColor = Color.White;
    private static readonly Color AppBackgroundColor = Color.FromArgb(246, 248, 251);

    private sealed record ChoiceItem(string Value, string DisplayText)
    {
        public override string ToString() => DisplayText;
    }

    private sealed record LogEntry(string Text, bool IsError);

    private readonly AppSettings _settings;
    private readonly ToolTip _toolTip = new();
    private readonly TextBox _binTextBox = NewPathTextBox("把 .bin 文件拖到窗口，或点击浏览");
    private readonly TextBox _tocTextBox = NewPathTextBox("可选；留空时脚本查找同名 .toc");
    private readonly TextBox _outputTextBox = NewPathTextBox("留空时按识别出的专辑自动命名");
    private readonly TextBox _ffmpegTextBox = NewPathTextBox("可选；留空时自动查找 ffmpeg.exe");
    private readonly TextBox _envTextBox = NewPathTextBox("可选；高级用户可继续使用 EXE 同目录的 .env");
    private readonly TextBox _userAgentTextBox = new() { Dock = DockStyle.Fill, PlaceholderText = ConversionOptions.DefaultMusicBrainzUserAgent };
    private readonly ComboBox _formatComboBox = NewChoiceCombo(
        new("flac", "FLAC（无损压缩，推荐）"),
        new("wav", "WAV（未压缩）"));
    private readonly ComboBox _domesticPriorityComboBox = NewChoiceCombo(
        new("NetEaseFirst", "网易云音乐优先"),
        new("QQMusicFirst", "QQ 音乐优先"));
    private readonly ComboBox _lyricsFallbackComboBox = NewChoiceCombo(
        new("Auto", "自动：AI → Google → Microsoft → 免 Key（推荐）"),
        new("None", "关闭机器翻译"),
        new("AIThenGoogle", "AI → Google/Microsoft → 免 Key"),
        new("GoogleThenAI", "Google/Microsoft → AI → 免 Key"),
        new("AI", "仅 AI"),
        new("Google", "Google/Microsoft → 免 Key"));
    private readonly ComboBox _aiProviderComboBox = NewChoiceCombo(
        new("Auto", "自动：OpenAI → Anthropic"),
        new("OpenAI", "OpenAI 兼容接口"),
        new("Anthropic", "Anthropic 兼容接口"));
    private readonly Button _aiSettingsButton = new() { Text = "配置模型与 API Key…", AutoSize = true, Padding = new Padding(8, 2, 8, 2) };
    private readonly NumericUpDown _releaseIndexInput = new() { Minimum = 0, Maximum = 1000, Dock = DockStyle.Fill };
    private readonly CheckBox _metadataCheckBox = NewCheckBox("获取并写入在线元数据", isChecked: true);
    private readonly CheckBox _coverCheckBox = NewCheckBox("下载并嵌入专辑封面", isChecked: true);
    private readonly CheckBox _lyricsCheckBox = NewCheckBox("获取歌词并生成字幕", isChecked: true);
    private readonly CheckBox _netEaseCheckBox = NewCheckBox("使用网易云音乐", isChecked: true);
    private readonly CheckBox _qqMusicCheckBox = NewCheckBox("使用 QQ 音乐", isChecked: true);
    private readonly CheckBox _openOnSuccessCheckBox = NewCheckBox("成功后打开目录");
    private readonly Label _aiStatusLabel = new()
    {
        AutoSize = true,
        ForeColor = SystemColors.GrayText,
        Margin = new Padding(4, 8, 8, 4),
    };
    private readonly Label _phaseLabel = new()
    {
        AutoSize = true,
        Text = "等待开始",
        Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold),
        Margin = new Padding(0, 2, 8, 4),
    };
    private readonly Label _elapsedLabel = new()
    {
        AutoSize = true,
        Text = "00:00",
        ForeColor = SystemColors.GrayText,
        TextAlign = ContentAlignment.MiddleRight,
        Margin = new Padding(8, 2, 0, 4),
    };
    private readonly ProgressBar _progressBar = new()
    {
        Dock = DockStyle.Fill,
        Height = 8,
        Style = ProgressBarStyle.Blocks,
        Minimum = 0,
        Maximum = 100,
    };
    private readonly RichTextBox _logTextBox = new()
    {
        Dock = DockStyle.Fill,
        ReadOnly = true,
        DetectUrls = true,
        BackColor = Color.FromArgb(24, 26, 29),
        ForeColor = Color.Gainsboro,
        Font = new Font("Cascadia Mono", 9F),
        BorderStyle = BorderStyle.FixedSingle,
    };
    private readonly TextBox _previewTextBox = new()
    {
        Dock = DockStyle.Fill,
        ReadOnly = true,
        Multiline = true,
        ScrollBars = ScrollBars.Vertical,
        WordWrap = true,
        MinimumSize = new Size(0, 64),
        BackColor = SystemColors.ControlLightLight,
        Font = new Font("Cascadia Mono", 9F),
    };
    private readonly Button _runButton = new() { Text = "开始转换", AutoSize = true, Padding = new Padding(14, 5, 14, 5) };
    private readonly Button _cancelButton = new() { Text = "停止转换", AutoSize = true, Padding = new Padding(12, 5, 12, 5), Enabled = false };
    private readonly Button _openOutputButton = new() { Text = "打开输出目录", AutoSize = true, Padding = new Padding(12, 5, 12, 5), Enabled = false };
    private readonly ToolStripStatusLabel _statusLabel = new() { Text = "就绪", Spring = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly GroupBox _inputGroup = new();
    private readonly TabControl _settingsTabs = new();
    private readonly ConcurrentQueue<LogEntry> _pendingLogEntries = new();
    private readonly ConcurrentQueue<ConversionProgressEvent> _pendingProgressEvents = new();
    private readonly System.Windows.Forms.Timer _uiTimer = new() { Interval = 100 };
    private readonly System.Windows.Forms.Timer _previewTimer = new() { Interval = 220 };
    private readonly Stopwatch _elapsedWatch = new();

    private Process? _process;
    private bool _running;
    private bool _cancellationRequested;
    private bool _closeWhenStopped;
    private bool _allowClose;
    private string? _reportedOutputDirectory;
    private string? _lastOutputDirectory;
    private AiTranslationConfiguration _aiConfiguration;
    private StoredAiSettings _storedAiSettings;
    private bool _rememberAiKeys;
    private readonly bool _hadUnreadableSavedSecret;

    public MainForm()
    {
        _settings = AppSettingsStore.Load();
        _storedAiSettings = (_settings.AiSettings ?? new StoredAiSettings()).Clone();
        _rememberAiKeys = _storedAiSettings.RememberApiKeys;
        _aiConfiguration = AiSettingsPersistence.Load(_storedAiSettings, out _hadUnreadableSavedSecret);

        Text = "CD-ROM Dump Tools";
        Font = new Font("Microsoft YaHei UI", 9F);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = AppBackgroundColor;
        MinimumSize = new Size(760, 600);
        ClientSize = new Size(1080, 760);
        AllowDrop = true;
        KeyPreview = true;

        BuildInterface();
        LoadSettingsIntoControls();
        WireEvents();
        AcceptButton = _runButton;
        UpdateAiStatus();
        UpdateCommandPreview();
        _uiTimer.Start();
        if (_hadUnreadableSavedSecret)
        {
            AppendLog("警告：至少一个已保存的 API Key 无法由当前 Windows 用户解密，已将该 Key 留空。", isError: true);
        }
    }

    private void BuildInterface()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(14, 10, 14, 8),
            BackColor = AppBackgroundColor,
        };
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var scrollHost = new Panel
        {
            Dock = DockStyle.Fill,
            AutoScroll = true,
            Margin = Padding.Empty,
        };
        var content = new TableLayoutPanel
        {
            Anchor = AnchorStyles.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 1,
            RowCount = 4,
            Margin = Padding.Empty,
            BackColor = AppBackgroundColor,
        };
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        scrollHost.Controls.Add(content);
        scrollHost.ClientSizeChanged += (_, _) =>
        {
            var availableWidth = Math.Max(0, scrollHost.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 2);
            var width = Math.Min(1240, availableWidth);
            content.MinimumSize = new Size(width, Math.Max(0, scrollHost.ClientSize.Height));
            content.MaximumSize = new Size(width, 0);
            content.Left = Math.Max(0, (availableWidth - width) / 2);
            content.Top = 0;
        };

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 1,
            RowCount = 2,
            Margin = new Padding(4, 0, 4, 8),
        };
        header.Controls.Add(new Label
        {
            Text = "CD 光盘镜像转换",
            AutoSize = true,
            Font = new Font(Font.FontFamily, 16F, FontStyle.Bold),
            ForeColor = Color.FromArgb(31, 41, 55),
            Margin = Padding.Empty,
        }, 0, 0);
        header.Controls.Add(new Label
        {
            Text = "选择 BIN/TOC 后即可开始；专辑信息、封面、歌词和中文翻译会按已配置的多源策略自动处理。",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(1, 4, 0, 0),
        }, 0, 1);

        _inputGroup.Text = "输入与输出";
        _inputGroup.Dock = DockStyle.Top;
        _inputGroup.AutoSize = true;
        _inputGroup.Padding = new Padding(10, 8, 10, 10);
        _inputGroup.BackColor = SurfaceColor;
        var paths = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 4,
            RowCount = 3,
        };
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        AddPathRow(paths, 0, "BIN 镜像（必选）", _binTextBox, BrowseBin);
        AddPathRow(paths, 1, "TOC 文件", _tocTextBox, BrowseToc, () => _tocTextBox.Clear());
        AddPathRow(paths, 2, "自定义输出目录", _outputTextBox, BrowseOutputParent, () => _outputTextBox.Clear(), "留空时按识别出的艺术家、专辑和年份自动命名；选择父目录时会生成一个尚不存在的目录。");
        _inputGroup.Controls.Add(paths);

        _settingsTabs.Dock = DockStyle.Top;
        _settingsTabs.Height = 215;
        _settingsTabs.MinimumSize = new Size(0, 195);
        _settingsTabs.Margin = new Padding(0, 10, 0, 8);

        var conversionPage = NewTabPage("转换与标签");
        var conversionOptions = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 4,
            RowCount = 3,
            Padding = new Padding(10, 8, 10, 6),
        };
        conversionOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        conversionOptions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        conversionOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        conversionOptions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        AddLabeledControl(conversionOptions, 0, 0, "输出格式", _formatComboBox);
        AddLabeledControl(conversionOptions, 0, 2, "标签数据优先级", _domesticPriorityComboBox);
        var conversionSwitches = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            WrapContents = true,
            Margin = new Padding(0, 12, 0, 4),
        };
        conversionSwitches.Controls.AddRange(new Control[]
        {
            _metadataCheckBox,
            _coverCheckBox,
            _openOnSuccessCheckBox,
        });
        conversionOptions.Controls.Add(conversionSwitches, 0, 1);
        conversionOptions.SetColumnSpan(conversionSwitches, 4);
        var conversionHint = NewHintLabel("光盘身份优先使用 MusicBrainz；写入标签时优先使用网易云/QQ，缺失字段再由其他来源补齐。");
        conversionOptions.Controls.Add(conversionHint, 0, 2);
        conversionOptions.SetColumnSpan(conversionHint, 4);
        conversionPage.Controls.Add(conversionOptions);

        var lyricsPage = NewTabPage("歌词与 AI 翻译");
        var lyricsOptions = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 4,
            RowCount = 4,
            Padding = new Padding(10, 8, 10, 6),
        };
        lyricsOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        lyricsOptions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        lyricsOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        lyricsOptions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        AddLabeledControl(lyricsOptions, 0, 0, "翻译回退", _lyricsFallbackComboBox);
        AddLabeledControl(lyricsOptions, 0, 2, "AI 接口格式", _aiProviderComboBox);
        var lyricsSwitches = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            WrapContents = true,
            Margin = new Padding(0, 10, 0, 2),
        };
        lyricsSwitches.Controls.AddRange(new Control[] { _lyricsCheckBox, _netEaseCheckBox, _qqMusicCheckBox });
        lyricsOptions.Controls.Add(lyricsSwitches, 0, 1);
        lyricsOptions.SetColumnSpan(lyricsSwitches, 4);
        var aiStatusPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 2,
            Margin = new Padding(0, 3, 0, 0),
        };
        aiStatusPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        aiStatusPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        aiStatusPanel.Controls.Add(_aiStatusLabel, 0, 0);
        aiStatusPanel.Controls.Add(_aiSettingsButton, 1, 0);
        lyricsOptions.Controls.Add(aiStatusPanel, 0, 2);
        lyricsOptions.SetColumnSpan(aiStatusPanel, 4);
        var lyricsHint = NewHintLabel("歌词源：网易云 → QQ 音乐 → LRCLIB。\n默认正式 API：OpenAI → Anthropic → Google Cloud → Microsoft Azure。\n免 Key 尽力回退：Google GTX → Bing（可能限流或变更）。");
        lyricsOptions.Controls.Add(lyricsHint, 0, 3);
        lyricsOptions.SetColumnSpan(lyricsHint, 4);
        lyricsPage.Controls.Add(lyricsOptions);

        var advancedPage = NewTabPage("高级设置");
        var advancedOptions = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 4,
            RowCount = 4,
            Padding = new Padding(10, 8, 10, 6),
        };
        advancedOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        advancedOptions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        advancedOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        advancedOptions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        AddPathRow(advancedOptions, 0, "FFmpeg", _ffmpegTextBox, BrowseFfmpeg, () => _ffmpegTextBox.Clear());
        AddPathRow(advancedOptions, 1, ".env 文件", _envTextBox, BrowseEnvironmentFile, () => _envTextBox.Clear(), "高级兼容入口；日常使用可直接在 GUI 中配置模型和 API Key。");
        var advancedValues = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 4,
            Margin = new Padding(0, 4, 0, 0),
        };
        advancedValues.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        advancedValues.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 36F));
        advancedValues.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        advancedValues.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 64F));
        AddLabeledControl(advancedValues, 0, 0, "候选专辑序号", _releaseIndexInput);
        AddLabeledControl(advancedValues, 0, 2, "MusicBrainz User-Agent", _userAgentTextBox);
        advancedOptions.Controls.Add(advancedValues, 0, 2);
        advancedOptions.SetColumnSpan(advancedValues, 4);
        var advancedHint = NewHintLabel("候选序号为 0 时非交互地使用第 1 个候选；FFmpeg 和 .env 留空时按默认位置自动查找。");
        advancedOptions.Controls.Add(advancedHint, 0, 3);
        advancedOptions.SetColumnSpan(advancedHint, 4);
        advancedPage.Controls.Add(advancedOptions);

        _settingsTabs.TabPages.AddRange(new[] { conversionPage, lyricsPage, advancedPage });

        var activityGroup = new GroupBox
        {
            Text = "转换进度与详情",
            Dock = DockStyle.Fill,
            Padding = new Padding(10, 8, 10, 10),
            Margin = new Padding(0, 2, 0, 0),
            MinimumSize = new Size(0, 225),
            BackColor = SurfaceColor,
        };
        var activity = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Margin = Padding.Empty,
        };
        activity.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        activity.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        var progressPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 2,
            RowCount = 2,
            Margin = new Padding(0, 0, 0, 6),
        };
        progressPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        progressPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        progressPanel.Controls.Add(_phaseLabel, 0, 0);
        progressPanel.Controls.Add(_elapsedLabel, 1, 0);
        progressPanel.Controls.Add(_progressBar, 0, 1);
        progressPanel.SetColumnSpan(_progressBar, 2);

        var activityTabs = new TabControl { Dock = DockStyle.Fill };
        var logPage = NewTabPage("运行日志");
        var logLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Padding = new Padding(6) };
        logLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        logLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        var logToolbar = NewToolbar();
        var copyLogButton = NewToolbarButton("复制日志");
        var clearLogButton = NewToolbarButton("清空日志");
        copyLogButton.Click += (_, _) =>
        {
            FlushPendingLogEntries();
            CopyTextToClipboard(_logTextBox.Text, "日志");
        };
        clearLogButton.Click += (_, _) => ClearLogView();
        logToolbar.Controls.AddRange(new Control[] { copyLogButton, clearLogButton });
        logLayout.Controls.Add(logToolbar, 0, 0);
        logLayout.Controls.Add(_logTextBox, 0, 1);
        logPage.Controls.Add(logLayout);

        var previewPage = NewTabPage("命令预览");
        var previewLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Padding = new Padding(6) };
        previewLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        previewLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        var previewHeader = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 2,
            Margin = Padding.Empty,
        };
        previewHeader.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        previewHeader.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        previewHeader.Controls.Add(NewHintLabel("预览不会读取或显示 GUI/.env 中的 API Key；长命令会自动换行。"), 0, 0);
        var previewToolbar = NewToolbar();
        var copyPreviewButton = NewToolbarButton("复制命令");
        copyPreviewButton.Click += (_, _) => CopyTextToClipboard(_previewTextBox.Text, "命令");
        previewToolbar.Controls.Add(copyPreviewButton);
        previewHeader.Controls.Add(previewToolbar, 1, 0);
        previewLayout.Controls.Add(previewHeader, 0, 0);
        previewLayout.Controls.Add(_previewTextBox, 0, 1);
        previewPage.Controls.Add(previewLayout);
        activityTabs.TabPages.AddRange(new[] { logPage, previewPage });
        activity.Controls.Add(progressPanel, 0, 0);
        activity.Controls.Add(activityTabs, 0, 1);
        activityGroup.Controls.Add(activity);

        var actionPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(0, 8, 0, 0),
            BackColor = AppBackgroundColor,
        };
        _runButton.BackColor = AccentColor;
        _runButton.ForeColor = Color.White;
        _runButton.FlatStyle = FlatStyle.Flat;
        _runButton.FlatAppearance.BorderSize = 0;
        actionPanel.Controls.AddRange(new Control[] { _runButton, _cancelButton, _openOutputButton });
        actionPanel.SizeChanged += (_, _) =>
        {
            var cappedWidth = Math.Min(1240, actionPanel.ClientSize.Width);
            var leftInset = Math.Max(0, (actionPanel.ClientSize.Width - cappedWidth) / 2);
            actionPanel.Padding = new Padding(leftInset, 8, 0, 0);
        };

        content.Controls.Add(header, 0, 0);
        content.Controls.Add(_inputGroup, 0, 1);
        content.Controls.Add(_settingsTabs, 0, 2);
        content.Controls.Add(activityGroup, 0, 3);
        root.Controls.Add(scrollHost, 0, 0);
        root.Controls.Add(actionPanel, 0, 1);

        var statusStrip = new StatusStrip { SizingGrip = true };
        statusStrip.Items.Add(_statusLabel);
        Controls.Add(root);
        Controls.Add(statusStrip);
    }

    private void WireEvents()
    {
        DragEnter += HandleDragEnter;
        DragDrop += HandleDragDrop;
        FormClosing += HandleFormClosing;
        _runButton.Click += async (_, _) => await RunConversionAsync();
        _cancelButton.Click += (_, _) => CancelConversion();
        _openOutputButton.Click += (_, _) => OpenDirectorySafely(_lastOutputDirectory);
        _aiSettingsButton.Click += (_, _) => OpenAiSettings();
        _uiTimer.Tick += (_, _) => FlushUiUpdates();
        _previewTimer.Tick += (_, _) =>
        {
            _previewTimer.Stop();
            UpdateCommandPreview();
        };
        FormClosed += (_, _) =>
        {
            _uiTimer.Stop();
            _previewTimer.Stop();
            _uiTimer.Dispose();
            _previewTimer.Dispose();
        };

        foreach (var textBox in new[] { _binTextBox, _tocTextBox, _outputTextBox, _ffmpegTextBox, _envTextBox, _userAgentTextBox })
        {
            textBox.TextChanged += (_, _) => QueueCommandPreview();
        }
        foreach (var comboBox in new[] { _formatComboBox, _domesticPriorityComboBox, _lyricsFallbackComboBox, _aiProviderComboBox })
        {
            comboBox.SelectedIndexChanged += (_, _) => QueueCommandPreview();
        }
        _releaseIndexInput.ValueChanged += (_, _) => QueueCommandPreview();
        foreach (var checkBox in new[]
                 {
                     _metadataCheckBox, _coverCheckBox, _lyricsCheckBox, _netEaseCheckBox,
                     _qqMusicCheckBox,
                 })
        {
            checkBox.CheckedChanged += (_, _) => QueueCommandPreview();
        }
        _lyricsCheckBox.CheckedChanged += (_, _) => UpdateAiStatus();
        _lyricsFallbackComboBox.SelectedIndexChanged += (_, _) => UpdateAiStatus();
        _aiProviderComboBox.SelectedIndexChanged += (_, _) => UpdateAiStatus();

        _toolTip.SetToolTip(_releaseIndexInput, "0 表示非交互地使用第 1 个候选；1..1000 指定候选序号。");
        _toolTip.SetToolTip(_envTextBox, "高级兼容入口：GUI 只保存路径；日常使用请直接点击“配置模型与 API Key…”。");
        _toolTip.SetToolTip(_aiSettingsButton, "配置 OpenAI、Anthropic、Google Cloud 与 Microsoft Azure 的正式/兼容端点和 API Key；免 Key 回退无需配置。");
    }

    private void LoadSettingsIntoControls()
    {
        _binTextBox.Text = _settings.BinPath;
        _tocTextBox.Text = _settings.TocPath;
        // A final output directory is single-use: after a successful conversion it exists
        // and cannot be passed to the converter again, so never restore a stale value.
        _outputTextBox.Clear();
        _ffmpegTextBox.Text = _settings.FfmpegPath;
        _envTextBox.Text = _settings.EnvPath;
        SelectOrDefault(_formatComboBox, _settings.Format, "flac");
        SelectOrDefault(_domesticPriorityComboBox, _settings.DomesticSourcePriority, "NetEaseFirst");
        SelectOrDefault(_lyricsFallbackComboBox, _settings.LyricsTranslationFallback, "Auto");
        SelectOrDefault(_aiProviderComboBox, _settings.AiTranslationProvider, "Auto");
        _releaseIndexInput.Value = Math.Clamp(_settings.ReleaseIndex, 0, 1000);
        _metadataCheckBox.Checked = !_settings.NoMetadata;
        _coverCheckBox.Checked = !_settings.NoCover;
        _lyricsCheckBox.Checked = !_settings.NoLyrics;
        _netEaseCheckBox.Checked = !_settings.NoNetEase;
        _qqMusicCheckBox.Checked = !_settings.NoQQMusic;
        _openOnSuccessCheckBox.Checked = _settings.OpenOutputOnSuccess;
        _userAgentTextBox.Text = string.IsNullOrWhiteSpace(_settings.MusicBrainzUserAgent)
            ? ConversionOptions.DefaultMusicBrainzUserAgent
            : _settings.MusicBrainzUserAgent;
    }

    private AppSettings CaptureSettings() => new()
    {
        BinPath = _binTextBox.Text.Trim(),
        TocPath = _tocTextBox.Text.Trim(),
        OutputDirectory = string.Empty,
        FfmpegPath = _ffmpegTextBox.Text.Trim(),
        EnvPath = _envTextBox.Text.Trim(),
        Format = SelectedValue(_formatComboBox, "flac"),
        NoMetadata = !_metadataCheckBox.Checked,
        NoCover = !_coverCheckBox.Checked,
        NoLyrics = !_lyricsCheckBox.Checked,
        NoNetEase = !_netEaseCheckBox.Checked,
        NoQQMusic = !_qqMusicCheckBox.Checked,
        NoPause = true,
        LyricsTranslationFallback = SelectedValue(_lyricsFallbackComboBox, "Auto"),
        AiTranslationProvider = SelectedValue(_aiProviderComboBox, "Auto"),
        DomesticSourcePriority = SelectedValue(_domesticPriorityComboBox, "NetEaseFirst"),
        ReleaseIndex = Decimal.ToInt32(_releaseIndexInput.Value),
        MusicBrainzUserAgent = _userAgentTextBox.Text.Trim(),
        OpenOutputOnSuccess = _openOnSuccessCheckBox.Checked,
        AiSettings = _storedAiSettings.Clone(),
    };

    private ConversionOptions CaptureConversionOptions()
    {
        var settings = CaptureSettings();
        return new ConversionOptions
        {
            BinPath = settings.BinPath,
            TocPath = EmptyToNull(settings.TocPath),
            // The explicit output path is deliberately not persisted because it is a
            // one-shot destination. Read the current control value for this run.
            OutputDirectory = EmptyToNull(_outputTextBox.Text.Trim()),
            FfmpegPath = EmptyToNull(settings.FfmpegPath),
            EnvPath = EnvironmentFileResolver.Resolve(EmptyToNull(settings.EnvPath), AppContext.BaseDirectory),
            Format = settings.Format,
            NoMetadata = settings.NoMetadata,
            NoCover = settings.NoCover,
            NoLyrics = settings.NoLyrics,
            NoNetEase = settings.NoNetEase,
            NoQQMusic = settings.NoQQMusic,
            NoPause = settings.NoPause,
            LyricsTranslationFallback = settings.LyricsTranslationFallback,
            AiTranslationProvider = settings.AiTranslationProvider,
            DomesticSourcePriority = settings.DomesticSourcePriority,
            ReleaseIndex = settings.ReleaseIndex,
            MusicBrainzUserAgent = settings.MusicBrainzUserAgent,
        };
    }

    private async Task RunConversionAsync()
    {
        if (_running)
        {
            return;
        }

        EmbeddedConverterScript.VerifiedExecutionLease scriptLease;
        try
        {
            scriptLease = EmbeddedConverterScript.AcquireVerifiedExecutionLease();
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                this,
                "无法安全展开或校验内置转换脚本：\n" + exception.Message,
                "无法开始转换",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }
        using var verifiedScriptLease = scriptLease;
        var scriptPath = verifiedScriptLease.ScriptPath;
        var powerShellPath = PowerShellLocator.FindExecutable();
        var options = CaptureConversionOptions();
        var openOutputOnSuccessForRun = _openOnSuccessCheckBox.Checked;
        var useMachineTranslationConfiguration = AiTranslationEnvironment.ShouldApply(options);
        try
        {
            if (useMachineTranslationConfiguration)
            {
                AiTranslationEnvironment.Validate(_aiConfiguration);
            }
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
        {
            MessageBox.Show(this, exception.Message, "AI 设置无效", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (!ValidateInputs(scriptPath, powerShellPath, options, out var validationError))
        {
            MessageBox.Show(this, validationError, "无法开始转换", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        ClearLogView();
        try
        {
            AppSettingsStore.Save(CaptureSettings());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            AppendLog($"警告：无法保存最近设置：{exception.Message}", isError: true);
        }

        _reportedOutputDirectory = null;
        _cancellationRequested = false;
        _lastOutputDirectory = null;
        _openOutputButton.Enabled = false;
        SetRunningState(true, "正在转换…");

        Process? process = null;
        try
        {
            var startInfo = ConverterCommand.CreateStartInfo(
                powerShellPath!,
                scriptPath!,
                options,
                useMachineTranslationConfiguration ? _aiConfiguration : null);
            AppendLog("PowerShell: " + powerShellPath);
            AppendLog("命令: " + ConverterCommand.CreateSafePreview(powerShellPath!, startInfo.ArgumentList.ToArray()));
            AppendLog("AI 配置: " + (useMachineTranslationConfiguration
                ? CreateTranslationConfigurationSummary(options)
                : "本次转换未启用机器翻译"));
            AppendLog(string.Empty);

            process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            _process = process;
            process.OutputDataReceived += (_, eventArgs) => HandleProcessLine(eventArgs.Data, isError: false);
            process.ErrorDataReceived += (_, eventArgs) => HandleProcessLine(eventArgs.Data, isError: true);

            if (!process.Start())
            {
                throw new InvalidOperationException("PowerShell 进程未能启动。");
            }

            process.StandardInput.Close();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            await process.WaitForExitAsync();
            process.WaitForExit();
            FlushUiUpdates();

            if (_cancellationRequested)
            {
                SetRunningState(false, "已取消");
                AppendLog("转换已取消。", isError: true);
            }
            else if (process.ExitCode == 0 && _reportedOutputDirectory is not null)
            {
                _lastOutputDirectory = Path.GetFullPath(_reportedOutputDirectory);
                SetRunningState(false, "转换完成");
                AppendLog(string.Empty);
                AppendLog("转换完成。", isError: false);

                if (_lastOutputDirectory is not null && Directory.Exists(_lastOutputDirectory))
                {
                    _openOutputButton.Enabled = true;
                    if (openOutputOnSuccessForRun)
                    {
                        OpenDirectorySafely(_lastOutputDirectory);
                    }
                }
                if (!string.IsNullOrWhiteSpace(options.OutputDirectory))
                {
                    _outputTextBox.Clear();
                }
            }
            else if (process.ExitCode == 0)
            {
                SetRunningState(false, "转换结果未确认");
                AppendLog("错误：进程退出码为 0，但未收到脚本的精确完成标记，结果不判定为成功。", isError: true);
            }
            else
            {
                SetRunningState(false, $"转换失败（退出码 {process.ExitCode}）");
                AppendLog($"转换失败，PowerShell 退出码：{process.ExitCode}", isError: true);
            }
        }
        catch (Exception exception)
        {
            SetRunningState(false, "启动或运行失败");
            AppendLog("错误：" + exception.Message, isError: true);
            if (!IsDisposed && !Disposing)
            {
                MessageBox.Show(this, exception.Message, "转换失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
        finally
        {
            if (_running)
            {
                SetRunningState(false, "已停止");
            }
            if (ReferenceEquals(_process, process))
            {
                _process = null;
            }
            process?.Dispose();

            if (_closeWhenStopped && !IsDisposed)
            {
                _allowClose = true;
                BeginInvoke(new Action(Close));
            }
        }
    }

    private void CancelConversion()
    {
        var process = _process;
        if (process is null)
        {
            return;
        }

        try
        {
            if (process.HasExited)
            {
                return;
            }

            _statusLabel.Text = "正在取消…";
            _phaseLabel.Text = "正在停止转换…";
            _cancelButton.Enabled = false;
            // ffmpeg and helper processes must not survive cancellation.
            process.Kill(entireProcessTree: true);
            _cancellationRequested = true;
            AppendLog("已请求取消，并终止整个转换进程树。", isError: true);
        }
        catch (InvalidOperationException)
        {
            // The process exited between HasExited and Kill.
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or NotSupportedException)
        {
            AppendLog("取消失败：" + exception.Message, isError: true);
            _statusLabel.Text = "取消失败，转换仍在进行";
            _phaseLabel.Text = "转换仍在进行";
            _cancelButton.Enabled = true;
        }
    }

    private void HandleProcessLine(string? line, bool isError)
    {
        if (line is null)
        {
            return;
        }

        if (OutputPathResolver.TryParseFromLogLine(line, out var parsed) && parsed is not null)
        {
            _reportedOutputDirectory = parsed;
        }
        if (ConversionProgressParser.TryParse(line, out var progressEvent) && progressEvent is not null)
        {
            _pendingProgressEvents.Enqueue(progressEvent);
        }
        AppendLog(line, isError);
    }

    private void AppendLog(string text, bool isError = false)
    {
        if (IsDisposed || Disposing)
        {
            return;
        }
        _pendingLogEntries.Enqueue(new LogEntry(text, isError));
        if (!InvokeRequired)
        {
            FlushPendingLogEntries();
        }
    }

    private void FlushUiUpdates()
    {
        if (IsDisposed || Disposing)
        {
            return;
        }
        while (_pendingProgressEvents.TryDequeue(out var progressEvent))
        {
            ApplyProgressEvent(progressEvent);
        }
        FlushPendingLogEntries();
        if (_elapsedWatch.IsRunning)
        {
            _elapsedLabel.Text = FormatElapsed(_elapsedWatch.Elapsed);
        }
    }

    private void FlushPendingLogEntries()
    {
        while (_pendingLogEntries.TryDequeue(out var entry))
        {
            var start = _logTextBox.TextLength;
            _logTextBox.AppendText(entry.Text + Environment.NewLine);
            if (entry.IsError && entry.Text.Length > 0)
            {
                _logTextBox.Select(start, entry.Text.Length);
                _logTextBox.SelectionColor = Color.Gold;
                _logTextBox.Select(_logTextBox.TextLength, 0);
                _logTextBox.SelectionColor = _logTextBox.ForeColor;
            }
        }
        _logTextBox.ScrollToCaret();
    }

    private void ClearLogView()
    {
        while (_pendingProgressEvents.TryDequeue(out _))
        {
        }
        while (_pendingLogEntries.TryDequeue(out _))
        {
        }
        _logTextBox.Clear();
    }

    private void OpenDirectorySafely(string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory))
        {
            return;
        }

        try
        {
            var fullPath = Path.GetFullPath(directory);
            if (!Directory.Exists(fullPath))
            {
                MessageBox.Show(this, "输出目录不存在：\n" + fullPath, "无法打开", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"),
                UseShellExecute = false,
            };
            startInfo.ArgumentList.Add(fullPath);
            Process.Start(startInfo)?.Dispose();
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException)
        {
            MessageBox.Show(this, exception.Message, "无法打开输出目录", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void BrowseBin()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "选择 BIN 光盘镜像",
            Filter = "BIN 光盘镜像 (*.bin)|*.bin|所有文件 (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        };
        SetInitialDirectory(dialog, _binTextBox.Text);
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            ApplyDroppedOrSelectedFile(dialog.FileName);
        }
    }

    private void BrowseToc()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "选择 TOC 文件",
            Filter = "cdrdao TOC 文件 (*.toc)|*.toc|所有文件 (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        };
        SetInitialDirectory(dialog, _tocTextBox.Text);
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            _tocTextBox.Text = dialog.FileName;
        }
    }

    private void BrowseFfmpeg()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "选择 ffmpeg.exe",
            Filter = "FFmpeg (ffmpeg.exe)|ffmpeg.exe|可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        };
        SetInitialDirectory(dialog, _ffmpegTextBox.Text);
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            _ffmpegTextBox.Text = dialog.FileName;
        }
    }

    private void BrowseEnvironmentFile()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "选择 .env 文件",
            Filter = ".env 文件 (.env;*.env)|.env;*.env|环境配置 (*.env;*.txt)|*.env;*.txt|所有文件 (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        };
        SetInitialDirectory(dialog, _envTextBox.Text);
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            _envTextBox.Text = dialog.FileName;
        }
    }

    private void OpenAiSettings()
    {
        using var dialog = new AiSettingsForm(_aiConfiguration, _rememberAiKeys);
        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            return;
        }

        try
        {
            var updatedConfiguration = dialog.Configuration.Clone();
            var updatedStoredSettings = AiSettingsPersistence.Save(updatedConfiguration, dialog.RememberApiKeys);
            _aiConfiguration = updatedConfiguration;
            _rememberAiKeys = dialog.RememberApiKeys;
            _storedAiSettings = updatedStoredSettings;
            AppSettingsStore.Save(CaptureSettings());
            _statusLabel.Text = "AI 设置已保存";
            UpdateAiStatus();
            QueueCommandPreview();
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException
                                          or System.Security.Cryptography.CryptographicException
                                          or System.ComponentModel.Win32Exception)
        {
            MessageBox.Show(this, exception.Message, "无法保存 AI 设置", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void BrowseOutputParent()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "选择用于存放最终专辑目录的父目录",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
        };
        var current = _outputTextBox.Text.Trim();
        if (current.Length > 0)
        {
            try
            {
                var parent = Path.GetDirectoryName(Path.GetFullPath(current));
                if (!string.IsNullOrWhiteSpace(parent) && Directory.Exists(parent))
                {
                    dialog.InitialDirectory = parent;
                }
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
            {
                // The user can still choose a parent directory when the typed path is invalid.
            }
        }
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            var binForName = string.IsNullOrWhiteSpace(_binTextBox.Text)
                ? Path.Combine(dialog.SelectedPath, "cdrom.bin")
                : _binTextBox.Text.Trim();
            _outputTextBox.Text = OutputPathResolver.SuggestUnusedDirectory(
                dialog.SelectedPath,
                binForName,
                SelectedValue(_formatComboBox, "flac"));
        }
    }

    private void HandleDragEnter(object? sender, DragEventArgs eventArgs)
    {
        eventArgs.Effect = !_running && eventArgs.Data?.GetDataPresent(DataFormats.FileDrop) == true
            ? DragDropEffects.Copy
            : DragDropEffects.None;
    }

    private void HandleDragDrop(object? sender, DragEventArgs eventArgs)
    {
        if (_running || eventArgs.Data?.GetData(DataFormats.FileDrop) is not string[] paths)
        {
            return;
        }

        foreach (var path in paths.Where(File.Exists))
        {
            ApplyDroppedOrSelectedFile(path);
        }
    }

    private void ApplyDroppedOrSelectedFile(string path)
    {
        var extension = Path.GetExtension(path);
        if (extension.Equals(".bin", StringComparison.OrdinalIgnoreCase))
        {
            _binTextBox.Text = Path.GetFullPath(path);
            var siblingToc = Path.ChangeExtension(path, ".toc");
            if (File.Exists(siblingToc))
            {
                _tocTextBox.Text = Path.GetFullPath(siblingToc);
            }
        }
        else if (extension.Equals(".toc", StringComparison.OrdinalIgnoreCase))
        {
            _tocTextBox.Text = Path.GetFullPath(path);
            var siblingBin = Path.ChangeExtension(path, ".bin");
            if (File.Exists(siblingBin) && string.IsNullOrWhiteSpace(_binTextBox.Text))
            {
                _binTextBox.Text = Path.GetFullPath(siblingBin);
            }
        }
    }

    private void UpdateCommandPreview()
    {
        try
        {
            var scriptPath = EmbeddedConverterScript.EnsureExtracted();
            var locatedPowerShellPath = PowerShellLocator.FindExecutable();
            var powerShellPath = locatedPowerShellPath ?? "powershell.exe";
            var options = CaptureConversionOptions();
            if (string.IsNullOrWhiteSpace(options.BinPath))
            {
                options.BinPath = Path.Combine(Environment.CurrentDirectory, "请选择-BIN.bin");
            }
            var arguments = locatedPowerShellPath is not null
                ? ConverterCommand.CreateStartInfo(locatedPowerShellPath, scriptPath, options).ArgumentList.ToArray()
                : ConverterCommand.BuildArguments(scriptPath, options);
            _previewTextBox.Text = ConverterCommand.CreateSafePreview(powerShellPath, arguments);
        }
        catch (Exception exception)
        {
            _previewTextBox.Text = "命令预览暂不可用：" + exception.Message;
        }
    }

    private void QueueCommandPreview()
    {
        if (_running || IsDisposed || Disposing)
        {
            return;
        }
        _previewTimer.Stop();
        _previewTimer.Start();
    }

    private void UpdateAiStatus()
    {
        var fallback = SelectedValue(_lyricsFallbackComboBox, "Auto");
        var aiProvider = SelectedValue(_aiProviderComboBox, "Auto");
        var translationEnabled = _lyricsCheckBox.Checked
            && !string.Equals(fallback, "None", StringComparison.Ordinal);
        var usesAi = fallback is "Auto" or "AI" or "AIThenGoogle" or "GoogleThenAI";
        var usesGoogle = fallback is "Auto" or "Google" or "AIThenGoogle" or "GoogleThenAI";
        _aiProviderComboBox.Enabled = translationEnabled && usesAi && !_running;
        if (!translationEnabled)
        {
            _aiStatusLabel.Text = "本次不使用机器翻译；平台原歌词仍会按启用的来源查询。";
            _aiStatusLabel.ForeColor = SystemColors.GrayText;
            return;
        }

        var aiServices = new List<string>();
        if (usesAi && (aiProvider is "Auto" or "OpenAI")
            && !string.IsNullOrWhiteSpace(_aiConfiguration.OpenAiApiKey)
            && !string.IsNullOrWhiteSpace(_aiConfiguration.OpenAiModel))
        {
            aiServices.Add($"OpenAI ({_aiConfiguration.OpenAiModel.Trim()})");
        }
        if (usesAi && (aiProvider is "Auto" or "Anthropic")
            && !string.IsNullOrWhiteSpace(_aiConfiguration.AnthropicApiKey)
            && !string.IsNullOrWhiteSpace(_aiConfiguration.AnthropicModel))
        {
            aiServices.Add($"Anthropic ({_aiConfiguration.AnthropicModel.Trim()})");
        }
        var googleService = usesGoogle && !string.IsNullOrWhiteSpace(_aiConfiguration.GoogleApiKey)
            ? "Google Cloud Translation"
            : null;
        var microsoftService = usesGoogle && !string.IsNullOrWhiteSpace(_aiConfiguration.MicrosoftApiKey)
            ? "Microsoft Translator (Azure)"
            : null;
        var cloudServices = new[] { googleService, microsoftService }
            .Where(service => service is not null)
            .Cast<string>()
            .ToList();
        var relevantServices = new List<string>();
        if (string.Equals(fallback, "GoogleThenAI", StringComparison.Ordinal))
        {
            relevantServices.AddRange(cloudServices);
        }
        relevantServices.AddRange(aiServices);
        if (!string.Equals(fallback, "GoogleThenAI", StringComparison.Ordinal))
        {
            relevantServices.AddRange(cloudServices);
        }

        if (relevantServices.Count == 0)
        {
            _aiStatusLabel.Text = usesGoogle
                ? "正式 API 未配置；将用免 Key 回退：Google GTX → Bing（尽力而为，也会读取 .env）。"
                : "本轮仅使用 AI，但 GUI 中未配置完整服务；如有 .env，将继续尝试其中的配置。";
            _aiStatusLabel.ForeColor = Color.FromArgb(154, 93, 0);
            return;
        }

        _aiStatusLabel.Text = "正式 API：" + string.Join(" → ", relevantServices)
            + (usesGoogle ? "\n免 Key 回退：Google GTX → Bing（尽力而为）。" : string.Empty);
        _aiStatusLabel.ForeColor = Color.FromArgb(22, 120, 72);
    }

    private string CreateTranslationConfigurationSummary(ConversionOptions options)
    {
        var summary = AiTranslationEnvironment.CreateSafeSummary(_aiConfiguration);
        var usesNoKeyFallbacks = options.LyricsTranslationFallback is "Auto" or "Google" or "AIThenGoogle" or "GoogleThenAI";
        return usesNoKeyFallbacks
            ? summary + "；免 Key 尽力回退：Google GTX → Bing"
            : summary;
    }

    private void ApplyProgressEvent(ConversionProgressEvent progressEvent)
    {
        if (!_running || _cancellationRequested)
        {
            return;
        }

        switch (progressEvent.Kind)
        {
            case ConversionProgressKind.Metadata:
                SetIndeterminateProgress("正在识别光盘与匹配专辑…");
                break;
            case ConversionProgressKind.Lyrics:
                SetIndeterminateProgress($"正在处理第 {progressEvent.Current} 轨歌词…");
                break;
            case ConversionProgressKind.Cover:
                SetIndeterminateProgress("正在获取封面：" + progressEvent.Detail);
                break;
            case ConversionProgressKind.TrackCount:
                SetIndeterminateProgress($"准备转换 {progressEvent.Total} 轨音频…");
                break;
            case ConversionProgressKind.TrackStarted:
                var total = progressEvent.Total ?? 1;
                var current = Math.Clamp(progressEvent.Current ?? 1, 1, total);
                _progressBar.Style = ProgressBarStyle.Blocks;
                _progressBar.MarqueeAnimationSpeed = 0;
                _progressBar.Maximum = total;
                // This event is emitted immediately before FFmpeg starts the current
                // track, so count only the tracks that have already completed.
                _progressBar.Value = current - 1;
                _phaseLabel.Text = $"正在转换第 {current}/{total} 轨 · {progressEvent.Detail}";
                _statusLabel.Text = $"正在转换第 {current}/{total} 轨";
                break;
        }
    }

    private void SetIndeterminateProgress(string text)
    {
        _progressBar.Value = 0;
        _progressBar.Style = ProgressBarStyle.Marquee;
        _progressBar.MarqueeAnimationSpeed = 28;
        _phaseLabel.Text = text;
        _statusLabel.Text = text;
    }

    private static bool ValidateInputs(
        string? scriptPath,
        string? powerShellPath,
        ConversionOptions options,
        out string error)
    {
        if (scriptPath is null || !File.Exists(scriptPath))
        {
            error = "内置 bin_to_audio_windows.ps1 未能安全展开或通过完整性校验。";
            return false;
        }
        if (powerShellPath is null || !File.Exists(powerShellPath))
        {
            error = "找不到 PowerShell 7 或 Windows PowerShell。";
            return false;
        }
        if (string.IsNullOrWhiteSpace(options.BinPath) || !File.Exists(options.BinPath))
        {
            error = "请选择一个存在的 BIN 光盘镜像。";
            return false;
        }
        if (!Path.GetExtension(options.BinPath).Equals(".bin", StringComparison.OrdinalIgnoreCase))
        {
            error = "BIN 镜像应使用 .bin 扩展名。";
            return false;
        }
        if (!ValidateOptionalFile(options.TocPath, "TOC", out error)
            || !ValidateOptionalFile(options.FfmpegPath, "FFmpeg", out error)
            || !ValidateOptionalFile(options.EnvPath, ".env", out error))
        {
            return false;
        }
        if (!string.IsNullOrWhiteSpace(options.OutputDirectory))
        {
            if (!OutputPathResolver.TryValidateExplicitDirectory(options.OutputDirectory, out _, out var outputError))
            {
                error = outputError ?? "最终输出目录无效。";
                return false;
            }
        }

        error = string.Empty;
        return true;
    }

    private static bool ValidateOptionalFile(string? path, string label, out string error)
    {
        if (!string.IsNullOrWhiteSpace(path) && !File.Exists(path))
        {
            error = $"{label} 文件不存在：\n{path}";
            return false;
        }
        error = string.Empty;
        return true;
    }

    private void SetRunningState(bool running, string status)
    {
        _running = running;
        if (IsDisposed || Disposing)
        {
            return;
        }
        _runButton.Enabled = !running;
        _cancelButton.Enabled = running;
        _inputGroup.Enabled = !running;
        _settingsTabs.Enabled = !running;
        AllowDrop = !running;
        _statusLabel.Text = status;
        if (running)
        {
            _elapsedWatch.Restart();
            _elapsedLabel.Text = "00:00";
            _phaseLabel.ForeColor = AccentColor;
            SetIndeterminateProgress("正在准备转换与查询在线信息…");
            return;
        }

        _elapsedWatch.Stop();
        _elapsedLabel.Text = FormatElapsed(_elapsedWatch.Elapsed);
        _progressBar.Style = ProgressBarStyle.Blocks;
        _progressBar.MarqueeAnimationSpeed = 0;
        _progressBar.Maximum = 100;
        if (status == "转换完成")
        {
            _progressBar.Value = 100;
            _phaseLabel.ForeColor = Color.FromArgb(22, 120, 72);
        }
        else
        {
            _progressBar.Value = 0;
            _phaseLabel.ForeColor = status.Contains("失败", StringComparison.Ordinal)
                || status.Contains("未确认", StringComparison.Ordinal)
                ? Color.Firebrick
                : SystemColors.ControlText;
        }
        _phaseLabel.Text = status;
        UpdateAiStatus();
    }

    private void HandleFormClosing(object? sender, FormClosingEventArgs eventArgs)
    {
        if (_running && !_allowClose)
        {
            var answer = MessageBox.Show(
                this,
                "转换仍在进行。是否终止整个转换进程树并退出？",
                "确认退出",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (answer != DialogResult.Yes)
            {
                eventArgs.Cancel = true;
                return;
            }
            eventArgs.Cancel = true;
            _closeWhenStopped = true;
            CancelConversion();
            return;
        }

        try
        {
            AppSettingsStore.Save(CaptureSettings());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Closing must not be blocked by an unwritable settings directory.
        }
    }

    private static TextBox NewPathTextBox(string placeholder) => new()
    {
        Dock = DockStyle.Fill,
        PlaceholderText = placeholder,
    };

    private static ComboBox NewChoiceCombo(params ChoiceItem[] items)
    {
        var comboBox = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList };
        comboBox.Items.AddRange(items);
        comboBox.SelectedIndex = 0;
        return comboBox;
    }

    private static CheckBox NewCheckBox(string text, bool isChecked = false) => new()
    {
        Text = text,
        Checked = isChecked,
        AutoSize = true,
        Margin = new Padding(3, 4, 16, 4),
    };

    private static TabPage NewTabPage(string text) => new()
    {
        Text = text,
        BackColor = SurfaceColor,
        Padding = new Padding(3),
    };

    private static Label NewHintLabel(string text) => new()
    {
        AutoSize = true,
        Text = text,
        ForeColor = SystemColors.GrayText,
        Margin = new Padding(3, 7, 3, 3),
    };

    private static FlowLayoutPanel NewToolbar() => new()
    {
        Dock = DockStyle.Fill,
        AutoSize = true,
        FlowDirection = FlowDirection.LeftToRight,
        WrapContents = false,
        Margin = new Padding(0, 0, 0, 5),
    };

    private static Button NewToolbarButton(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Padding = new Padding(5, 1, 5, 1),
        Margin = new Padding(0, 0, 6, 0),
    };

    private static void AddPathRow(
        TableLayoutPanel table,
        int row,
        string labelText,
        TextBox textBox,
        Action browseAction,
        Action? clearAction = null,
        string? helpText = null)
    {
        table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var label = new Label
        {
            Text = labelText,
            TextAlign = ContentAlignment.MiddleLeft,
            Dock = DockStyle.Fill,
            AutoSize = true,
            Margin = new Padding(3, 8, 3, 3),
        };
        var browseButton = new Button { Text = "浏览…", AutoSize = true, Margin = new Padding(8, 2, 0, 2) };
        browseButton.AccessibleName = $"浏览{labelText}";
        textBox.AccessibleName = labelText;
        browseButton.Click += (_, _) => browseAction();
        table.Controls.Add(label, 0, row);
        table.Controls.Add(textBox, 1, row);
        table.Controls.Add(browseButton, 2, row);

        if (clearAction is not null)
        {
            var clearButton = new Button { Text = "清空", AutoSize = true, Margin = new Padding(5, 2, 0, 2) };
            clearButton.AccessibleName = $"清空{labelText}";
            clearButton.Click += (_, _) => clearAction();
            table.Controls.Add(clearButton, 3, row);
        }
        if (!string.IsNullOrWhiteSpace(helpText))
        {
            textBox.AccessibleDescription = helpText;
        }
    }

    private static void AddLabeledControl(TableLayoutPanel table, int row, int column, string labelText, Control control)
    {
        var label = new Label
        {
            Text = labelText,
            TextAlign = ContentAlignment.MiddleLeft,
            Dock = DockStyle.Fill,
            AutoSize = true,
            Margin = new Padding(3, 8, 3, 3),
        };
        table.Controls.Add(label, column, row);
        table.Controls.Add(control, column + 1, row);
    }

    private static string SelectedValue(ComboBox comboBox, string fallback) =>
        comboBox.SelectedItem is ChoiceItem item ? item.Value : fallback;

    private static void SelectOrDefault(ComboBox comboBox, string? value, string fallback)
    {
        var selected = comboBox.Items
            .OfType<ChoiceItem>()
            .FirstOrDefault(item => string.Equals(item.Value, value, StringComparison.Ordinal))
            ?? comboBox.Items
                .OfType<ChoiceItem>()
                .First(item => string.Equals(item.Value, fallback, StringComparison.Ordinal));
        comboBox.SelectedItem = selected;
    }

    private void CopyTextToClipboard(string text, string label)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            _statusLabel.Text = $"{label}为空";
            return;
        }
        try
        {
            Clipboard.SetText(text);
            _statusLabel.Text = $"已复制{label}";
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.ExternalException or ThreadStateException)
        {
            _statusLabel.Text = $"复制{label}失败：{exception.Message}";
        }
    }

    private static string FormatElapsed(TimeSpan elapsed) => elapsed.TotalHours >= 1
        ? $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}"
        : $"{elapsed.Minutes:00}:{elapsed.Seconds:00}";

    private static string? EmptyToNull(string value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static void SetInitialDirectory(FileDialog dialog, string currentPath)
    {
        try
        {
            var directory = File.Exists(currentPath) ? Path.GetDirectoryName(currentPath) : null;
            if (!string.IsNullOrWhiteSpace(directory) && Directory.Exists(directory))
            {
                dialog.InitialDirectory = directory;
            }
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            // Ignore invalid text typed into a path field.
        }
    }
}
