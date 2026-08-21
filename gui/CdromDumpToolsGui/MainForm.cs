using System.Diagnostics;
using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal sealed class MainForm : Form
{
    private static readonly Color AccentColor = Color.FromArgb(34, 122, 214);

    private readonly AppSettings _settings;
    private readonly ToolTip _toolTip = new();
    private readonly TextBox _binTextBox = NewPathTextBox("把 .bin 文件拖到窗口，或点击浏览");
    private readonly TextBox _tocTextBox = NewPathTextBox("可选；留空时脚本查找同名 .toc");
    private readonly TextBox _outputTextBox = NewPathTextBox("留空时按识别出的专辑自动命名");
    private readonly TextBox _ffmpegTextBox = NewPathTextBox("可选；留空时自动查找 ffmpeg.exe");
    private readonly TextBox _envTextBox = NewPathTextBox("可选；高级用户可继续使用 EXE 同目录的 .env");
    private readonly TextBox _userAgentTextBox = new() { Dock = DockStyle.Fill, PlaceholderText = ConversionOptions.DefaultMusicBrainzUserAgent };
    private readonly ComboBox _formatComboBox = NewChoiceCombo("flac", "wav");
    private readonly ComboBox _domesticPriorityComboBox = NewChoiceCombo("NetEaseFirst", "QQMusicFirst");
    private readonly ComboBox _lyricsFallbackComboBox = NewChoiceCombo("Auto", "None", "AIThenGoogle", "GoogleThenAI", "AI", "Google");
    private readonly ComboBox _aiProviderComboBox = NewChoiceCombo("Auto", "OpenAI", "Anthropic");
    private readonly Button _aiSettingsButton = new() { Text = "模型 / API Key…", AutoSize = true, Margin = new Padding(6, 0, 0, 0) };
    private readonly NumericUpDown _releaseIndexInput = new() { Minimum = 0, Maximum = 1000, Dock = DockStyle.Fill };
    private readonly CheckBox _noMetadataCheckBox = NewCheckBox("不联网写元数据");
    private readonly CheckBox _noCoverCheckBox = NewCheckBox("不下载封面");
    private readonly CheckBox _noLyricsCheckBox = NewCheckBox("不下载歌词");
    private readonly CheckBox _noNetEaseCheckBox = NewCheckBox("禁用网易云");
    private readonly CheckBox _noQQMusicCheckBox = NewCheckBox("禁用 QQ 音乐");
    private readonly CheckBox _noPauseCheckBox = NewCheckBox("脚本不等待按键");
    private readonly CheckBox _openOnSuccessCheckBox = NewCheckBox("成功后打开目录");
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
    };
    private readonly Button _runButton = new() { Text = "开始转换", AutoSize = true, Padding = new Padding(14, 5, 14, 5) };
    private readonly Button _cancelButton = new() { Text = "取消", AutoSize = true, Padding = new Padding(12, 5, 12, 5), Enabled = false };
    private readonly Button _openOutputButton = new() { Text = "打开输出目录", AutoSize = true, Padding = new Padding(12, 5, 12, 5), Enabled = false };
    private readonly ToolStripStatusLabel _statusLabel = new() { Text = "就绪" };

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
        MinimumSize = new Size(900, 820);
        ClientSize = new Size(1150, 960);
        AllowDrop = true;

        BuildInterface();
        LoadSettingsIntoControls();
        _noPauseCheckBox.Checked = true;
        _noPauseCheckBox.Enabled = false;
        WireEvents();
        UpdateCommandPreview();
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
            Padding = new Padding(12),
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
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 1,
            RowCount = 3,
            Margin = Padding.Empty,
        };
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        scrollHost.Controls.Add(content);
        scrollHost.ClientSizeChanged += (_, _) =>
            content.MinimumSize = new Size(0, Math.Max(0, scrollHost.ClientSize.Height));

        var inputGroup = new GroupBox
        {
            Text = "输入与输出",
            Dock = DockStyle.Top,
            AutoSize = true,
            Padding = new Padding(10, 8, 10, 10),
        };
        var paths = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 4,
            RowCount = 5,
        };
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        AddPathRow(paths, 0, "BIN 镜像", _binTextBox, BrowseBin);
        AddPathRow(paths, 1, "TOC 文件", _tocTextBox, BrowseToc, () => _tocTextBox.Clear());
        AddPathRow(paths, 2, "最终输出目录", _outputTextBox, BrowseOutputParent, () => _outputTextBox.Clear(), "选择父目录后会生成一个尚不存在的最终目录；留空则由脚本按专辑自动命名。");
        AddPathRow(paths, 3, "FFmpeg", _ffmpegTextBox, BrowseFfmpeg, () => _ffmpegTextBox.Clear());
        AddPathRow(paths, 4, ".env（高级）", _envTextBox, BrowseEnvironmentFile, () => _envTextBox.Clear(), "仅把文件路径传给脚本；日常使用可直接点击“模型 / API Key…”配置。");
        inputGroup.Controls.Add(paths);

        var optionsGroup = new GroupBox
        {
            Text = "元数据、歌词与转换选项",
            Dock = DockStyle.Top,
            AutoSize = true,
            Padding = new Padding(10, 8, 10, 10),
            Margin = new Padding(0, 10, 0, 8),
        };
        var options = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 4,
            RowCount = 5,
        };
        options.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128));
        options.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        options.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        options.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));

        AddLabeledControl(options, 0, 0, "输出格式", _formatComboBox);
        AddLabeledControl(options, 0, 2, "国内源优先级", _domesticPriorityComboBox);
        AddLabeledControl(options, 1, 0, "歌词翻译回退", _lyricsFallbackComboBox);
        var aiProviderPanel = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, Margin = Padding.Empty };
        aiProviderPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        aiProviderPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        aiProviderPanel.Controls.Add(_aiProviderComboBox, 0, 0);
        aiProviderPanel.Controls.Add(_aiSettingsButton, 1, 0);
        AddLabeledControl(options, 1, 2, "AI 翻译服务", aiProviderPanel);
        AddLabeledControl(options, 2, 0, "候选专辑序号", _releaseIndexInput);
        AddLabeledControl(options, 2, 2, "MusicBrainz UA", _userAgentTextBox);

        var switches = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            WrapContents = true,
            Margin = new Padding(0, 7, 0, 0),
        };
        switches.Controls.AddRange(new Control[]
        {
            _noMetadataCheckBox,
            _noCoverCheckBox,
            _noLyricsCheckBox,
            _noNetEaseCheckBox,
            _noQQMusicCheckBox,
            _noPauseCheckBox,
            _openOnSuccessCheckBox,
        });
        options.Controls.Add(switches, 0, 3);
        options.SetColumnSpan(switches, 4);

        var hint = new Label
        {
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Text = "识别光盘优先 MusicBrainz；写标签与歌词按脚本当前的多源优先级执行。GUI 中 ReleaseIndex 为 0 时使用第 1 个候选。",
            Margin = new Padding(3, 8, 3, 0),
        };
        options.Controls.Add(hint, 0, 4);
        options.SetColumnSpan(hint, 4);
        optionsGroup.Controls.Add(options);

        var middle = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            MinimumSize = new Size(0, 300),
        };
        middle.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        middle.RowStyles.Add(new RowStyle(SizeType.Absolute, 128F));
        var logGroup = new GroupBox
        {
            Text = "实时日志",
            Dock = DockStyle.Fill,
            Padding = new Padding(8),
            MinimumSize = new Size(0, 170),
        };
        logGroup.Controls.Add(_logTextBox);
        middle.Controls.Add(logGroup, 0, 0);

        var previewGroup = new GroupBox
        {
            Text = "命令预览（不会显示 GUI 或 .env 中的 API Key）",
            Dock = DockStyle.Fill,
            Padding = new Padding(8),
            Margin = new Padding(0, 8, 0, 0),
            MinimumSize = new Size(0, 112),
        };
        previewGroup.Controls.Add(_previewTextBox);
        middle.Controls.Add(previewGroup, 0, 1);

        var actionPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(0, 8, 0, 0),
        };
        _runButton.BackColor = AccentColor;
        _runButton.ForeColor = Color.White;
        _runButton.FlatStyle = FlatStyle.Flat;
        actionPanel.Controls.AddRange(new Control[] { _runButton, _cancelButton, _openOutputButton });

        content.Controls.Add(inputGroup, 0, 0);
        content.Controls.Add(optionsGroup, 0, 1);
        content.Controls.Add(middle, 0, 2);
        root.Controls.Add(scrollHost, 0, 0);
        root.Controls.Add(actionPanel, 0, 1);

        var statusStrip = new StatusStrip();
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

        foreach (var textBox in new[] { _binTextBox, _tocTextBox, _outputTextBox, _ffmpegTextBox, _envTextBox, _userAgentTextBox })
        {
            textBox.TextChanged += (_, _) => UpdateCommandPreview();
        }
        foreach (var comboBox in new[] { _formatComboBox, _domesticPriorityComboBox, _lyricsFallbackComboBox, _aiProviderComboBox })
        {
            comboBox.SelectedIndexChanged += (_, _) => UpdateCommandPreview();
        }
        _releaseIndexInput.ValueChanged += (_, _) => UpdateCommandPreview();
        foreach (var checkBox in new[]
                 {
                     _noMetadataCheckBox, _noCoverCheckBox, _noLyricsCheckBox, _noNetEaseCheckBox,
                     _noQQMusicCheckBox, _noPauseCheckBox,
                 })
        {
            checkBox.CheckedChanged += (_, _) => UpdateCommandPreview();
        }

        _toolTip.SetToolTip(_releaseIndexInput, "0 表示非交互地使用第 1 个候选；1..1000 指定候选序号。");
        _toolTip.SetToolTip(_envTextBox, "高级兼容入口：GUI 只保存路径；日常使用请直接点击“模型 / API Key…”。");
        _toolTip.SetToolTip(_noPauseCheckBox, "GUI 始终传入 -NoPause，防止后台进程等待键盘输入。");
        _toolTip.SetToolTip(_aiSettingsButton, "直接配置 OpenAI、Anthropic、Google 的模型、兼容端点和 API Key。");
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
        _noMetadataCheckBox.Checked = _settings.NoMetadata;
        _noCoverCheckBox.Checked = _settings.NoCover;
        _noLyricsCheckBox.Checked = _settings.NoLyrics;
        _noNetEaseCheckBox.Checked = _settings.NoNetEase;
        _noQQMusicCheckBox.Checked = _settings.NoQQMusic;
        _noPauseCheckBox.Checked = true;
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
        Format = SelectedText(_formatComboBox, "flac"),
        NoMetadata = _noMetadataCheckBox.Checked,
        NoCover = _noCoverCheckBox.Checked,
        NoLyrics = _noLyricsCheckBox.Checked,
        NoNetEase = _noNetEaseCheckBox.Checked,
        NoQQMusic = _noQQMusicCheckBox.Checked,
        NoPause = true,
        LyricsTranslationFallback = SelectedText(_lyricsFallbackComboBox, "Auto"),
        AiTranslationProvider = SelectedText(_aiProviderComboBox, "Auto"),
        DomesticSourcePriority = SelectedText(_domesticPriorityComboBox, "NetEaseFirst"),
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

        try
        {
            AppSettingsStore.Save(CaptureSettings());
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            AppendLog($"警告：无法保存最近设置：{exception.Message}", isError: true);
        }

        _logTextBox.Clear();
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
                ? AiTranslationEnvironment.CreateSafeSummary(_aiConfiguration)
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
                    if (_openOnSuccessCheckBox.Checked)
                    {
                        OpenDirectorySafely(_lastOutputDirectory);
                    }
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

        _statusLabel.Text = "正在取消…";
        _cancellationRequested = true;
        _cancelButton.Enabled = false;
        try
        {
            if (!process.HasExited)
            {
                // ffmpeg and helper processes must not survive cancellation.
                process.Kill(entireProcessTree: true);
                AppendLog("已请求取消，并终止整个转换进程树。", isError: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process exited between HasExited and Kill.
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or NotSupportedException)
        {
            AppendLog("取消失败：" + exception.Message, isError: true);
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
        AppendLog(line, isError);
    }

    private void AppendLog(string text, bool isError = false)
    {
        if (IsDisposed || Disposing)
        {
            return;
        }
        if (InvokeRequired)
        {
            try
            {
                BeginInvoke(new Action<string, bool>(AppendLog), text, isError);
            }
            catch (InvalidOperationException)
            {
                // The window was closed while an asynchronous output event was in flight.
            }
            return;
        }

        var start = _logTextBox.TextLength;
        _logTextBox.AppendText(text + Environment.NewLine);
        if (isError && text.Length > 0)
        {
            _logTextBox.Select(start, text.Length);
            _logTextBox.SelectionColor = Color.Gold;
            _logTextBox.Select(_logTextBox.TextLength, 0);
            _logTextBox.SelectionColor = _logTextBox.ForeColor;
        }
        _logTextBox.ScrollToCaret();
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
            UpdateCommandPreview();
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
                SelectedText(_formatComboBox, "flac"));
        }
    }

    private void HandleDragEnter(object? sender, DragEventArgs eventArgs)
    {
        eventArgs.Effect = eventArgs.Data?.GetDataPresent(DataFormats.FileDrop) == true
            ? DragDropEffects.Copy
            : DragDropEffects.None;
    }

    private void HandleDragDrop(object? sender, DragEventArgs eventArgs)
    {
        if (eventArgs.Data?.GetData(DataFormats.FileDrop) is not string[] paths)
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
        _aiSettingsButton.Enabled = !running;
        _statusLabel.Text = status;
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

    private static ComboBox NewChoiceCombo(params string[] items)
    {
        var comboBox = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList };
        comboBox.Items.AddRange(items);
        comboBox.SelectedIndex = 0;
        return comboBox;
    }

    private static CheckBox NewCheckBox(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Margin = new Padding(3, 4, 16, 4),
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
        browseButton.Click += (_, _) => browseAction();
        table.Controls.Add(label, 0, row);
        table.Controls.Add(textBox, 1, row);
        table.Controls.Add(browseButton, 2, row);

        if (clearAction is not null)
        {
            var clearButton = new Button { Text = "清空", AutoSize = true, Margin = new Padding(5, 2, 0, 2) };
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

    private static string SelectedText(ComboBox comboBox, string fallback) =>
        comboBox.SelectedItem?.ToString() ?? fallback;

    private static void SelectOrDefault(ComboBox comboBox, string? value, string fallback)
    {
        var index = value is null ? -1 : comboBox.Items.IndexOf(value);
        comboBox.SelectedItem = index >= 0 ? value : fallback;
    }

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
