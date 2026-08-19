using System.Diagnostics;
using System.Text;

namespace CdromDumpToolsGui;

/// <summary>
/// A Windows Forms wrapper around bin_to_audio_windows.ps1. The PowerShell
/// converter remains the single source of truth for conversion logic; this
/// GUI only collects options, streams the script's output into a log pane,
/// and exposes a cancel button and an "open output folder" shortcut.
/// </summary>
internal sealed class MainForm : Form
{
    private readonly AppSettings _settings = AppSettings.Load();

    private TextBox _binTextBox = null!;
    private TextBox _tocTextBox = null!;
    private TextBox _outputTextBox = null!;
    private TextBox _ffmpegTextBox = null!;
    private TextBox _envTextBox = null!;
    private TextBox _userAgentTextBox = null!;
    private ComboBox _formatCombo = null!;
    private ComboBox _domesticPriorityCombo = null!;
    private ComboBox _lyricsFallbackCombo = null!;
    private ComboBox _aiProviderCombo = null!;
    private NumericUpDown _releaseIndexInput = null!;
    private CheckBox _noMetadataCheck = null!;
    private CheckBox _noCoverCheck = null!;
    private CheckBox _noLyricsCheck = null!;
    private CheckBox _noNetEaseCheck = null!;
    private CheckBox _noQQMusicCheck = null!;
    private RichTextBox _log = null!;
    private Button _runButton = null!;
    private Button _cancelButton = null!;
    private Button _openOutputButton = null!;
    private ToolStripStatusLabel _statusLabel = null!;
    private readonly ToolTip _toolTip = new();

    private Process? _process;
    private bool _running;
    private string? _outputFolder;

    public MainForm()
    {
        Text = "CD-ROM Dump Tools GUI";
        Font = new Font("Microsoft YaHei UI", 9F);
        MinimumSize = new Size(760, 620);
        StartPosition = FormStartPosition.CenterScreen;
        AllowDrop = true;

        BuildUi();
        LoadSettingsIntoUi();
    }

    private void BuildUi()
    {
        // ----- settings panel -----
        var settingsGroup = new GroupBox { Text = "转换设置", Dock = DockStyle.Fill, Padding = new Padding(10) };
        var settingsTable = new TableLayoutPanel
        {
            ColumnCount = 4,
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnStyles =
            {
                new ColumnStyle(SizeType.Absolute, 96),
                new ColumnStyle(SizeType.Percent, 100F),
                new ColumnStyle(SizeType.Absolute, 84),
                new ColumnStyle(SizeType.Absolute, 12),
            },
        };

        _binTextBox = AddPathRow(settingsTable, 0, "BIN 镜像", "选择 BIN 文件",
            "BIN 文件 (*.bin)|*.bin|所有文件 (*.*)|*.*", BrowseForFile);
        _tocTextBox = AddPathRow(settingsTable, 1, "TOC 文件", "选择 cdrdao TOC 文件(可选,默认与 BIN 同名)",
            "TOC 文件 (*.toc)|*.toc|所有文件 (*.*)|*.*", BrowseForFile);
        _outputTextBox = AddPathRow(settingsTable, 2, "输出目录", "选择输出目录(可选,默认 BIN 旁生成)",
            null, BrowseForFolder);
        _ffmpegTextBox = AddPathRow(settingsTable, 3, "FFmpeg", "选择 ffmpeg.exe(可选,自动从 PATH 查找)",
            "ffmpeg.exe|ffmpeg.exe|所有文件 (*.*)|*.*", BrowseForFile);
        _envTextBox = AddPathRow(settingsTable, 4, ".env 文件", "选择 .env(可选,默认读取脚本旁的 .env)",
            "env 文件|*.env;*.example|所有文件 (*.*)|*.*", BrowseForFile);

        var optionsPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(0, 6, 0, 0),
        };

        _formatCombo = AddOptionCombo(optionsPanel, "输出格式", "flac", "wav");
        _domesticPriorityCombo = AddOptionCombo(optionsPanel, "国内源优先", "NetEaseFirst", "QQMusicFirst");
        _lyricsFallbackCombo = AddOptionCombo(optionsPanel, "歌词翻译回退", "Auto", "None", "Google", "AI", "GoogleThenAI", "AIThenGoogle");
        _aiProviderCombo = AddOptionCombo(optionsPanel, "AI 提供方", "Auto", "OpenAI", "Anthropic");

        optionsPanel.Controls.Add(new Label { Text = "ReleaseIndex", AutoSize = true, Margin = new Padding(12, 6, 2, 0) });
        _releaseIndexInput = new NumericUpDown
        {
            Width = 64,
            Minimum = 0,
            Maximum = 1000,
            Margin = new Padding(0, 3, 12, 0),
        };
        optionsPanel.Controls.Add(_releaseIndexInput);

        _noMetadataCheck = AddOptionCheck(optionsPanel, "禁用在线元数据");
        _noCoverCheck = AddOptionCheck(optionsPanel, "不下载封面");
        _noLyricsCheck = AddOptionCheck(optionsPanel, "不获取歌词");
        _noNetEaseCheck = AddOptionCheck(optionsPanel, "不用网易云");
        _noQQMusicCheck = AddOptionCheck(optionsPanel, "不用 QQ 音乐");

        _userAgentTextBox = new TextBox
        {
            Dock = DockStyle.Fill,
            Margin = new Padding(0, 3, 0, 0),
        };
        var userAgentRow = new TableLayoutPanel
        {
            ColumnCount = 2,
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnStyles =
            {
                new ColumnStyle(SizeType.Absolute, 96),
                new ColumnStyle(SizeType.Percent, 100F),
            },
        };
        userAgentRow.Controls.Add(new Label { Text = "User-Agent", AutoSize = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, 0);
        userAgentRow.Controls.Add(_userAgentTextBox, 1, 0);

        settingsGroup.Controls.Add(settingsTable);
        settingsGroup.Controls.Add(optionsPanel);
        settingsGroup.Controls.Add(userAgentRow);

        // ----- log panel -----
        var logGroup = new GroupBox { Text = "日志", Dock = DockStyle.Fill, Padding = new Padding(10) };
        _log = new RichTextBox
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            BackColor = Color.White,
            Font = new Font("Consolas", 9.5F),
            DetectUrls = false,
            WordWrap = false,
            ScrollBars = RichTextBoxScrollBars.Both,
        };
        logGroup.Controls.Add(_log);

        // ----- bottom buttons -----
        var buttonPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(0, 6, 0, 0),
        };
        _runButton = new Button { Text = "开始转换", Width = 110, Height = 30, AutoSize = false };
        _runButton.Click += (_, _) => StartConversion();
        _cancelButton = new Button { Text = "取消", Width = 90, Height = 30, Enabled = false, AutoSize = false };
        _cancelButton.Click += (_, _) => CancelConversion();
        _openOutputButton = new Button { Text = "打开输出文件夹", Width = 130, Height = 30, Enabled = false, AutoSize = false };
        _openOutputButton.Click += (_, _) => OpenOutputFolder();
        buttonPanel.Controls.Add(_runButton);
        buttonPanel.Controls.Add(_cancelButton);
        buttonPanel.Controls.Add(_openOutputButton);

        // ----- status strip -----
        var statusStrip = new StatusStrip();
        _statusLabel = new ToolStripStatusLabel { Text = "就绪" };
        statusStrip.Items.Add(_statusLabel);

        // ----- main layout -----
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            RowCount = 4,
            ColumnCount = 1,
            Padding = new Padding(10),
            RowStyles =
            {
                new RowStyle(SizeType.AutoSize),
                new RowStyle(SizeType.AutoSize),
                new RowStyle(SizeType.Percent, 100F),
                new RowStyle(SizeType.AutoSize),
            },
        };
        root.Controls.Add(settingsGroup, 0, 0);
        root.Controls.Add(buttonPanel, 0, 1);
        root.Controls.Add(logGroup, 0, 2);
        root.Controls.Add(statusStrip, 0, 3);
        Controls.Add(root);

        // ----- drag & drop -----
        AllowDrop = true;
        settingsGroup.AllowDrop = true;
        DragEnter += OnFormDragEnter;
        DragDrop += OnFormDragDrop;
        settingsGroup.DragEnter += OnFormDragEnter;
        settingsGroup.DragDrop += OnFormDragDrop;
    }

    private TextBox AddPathRow(TableLayoutPanel table, int row, string label, string placeholder,
        string? filter, Action<TextBox> browseAction)
    {
        table.RowCount = Math.Max(table.RowCount, row + 1);
        table.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var textBox = new TextBox { Dock = DockStyle.Fill, Margin = new Padding(0, 3, 6, 0) };
        if (!string.IsNullOrEmpty(placeholder))
        {
            textBox.Tag = placeholder;
            textBox.Enter += (_, _) =>
            {
                if (string.Equals(textBox.Text, textBox.Tag as string, StringComparison.Ordinal))
                {
                    textBox.Text = "";
                }
            };
            textBox.Leave += (_, _) =>
            {
                if (string.IsNullOrWhiteSpace(textBox.Text))
                {
                    textBox.Text = textBox.Tag as string ?? "";
                }
            };
            textBox.Text = placeholder;
        }
        table.Controls.Add(new Label { Text = label, AutoSize = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(0, 3, 0, 0) }, 0, row);
        table.Controls.Add(textBox, 1, row);

        var browseButton = new Button
        {
            Text = "浏览...",
            Width = 74,
            Height = 26,
            Margin = new Padding(0, 2, 0, 0),
            Tag = (textBox, filter, browseAction),
        };
        browseButton.Click += (_, _) =>
        {
            var (target, fileFilter, action) = ((TextBox, string?, Action<TextBox>))browseButton.Tag!;
            action(target);
        };
        table.Controls.Add(browseButton, 2, row);
        return textBox;
    }

    private void BrowseForFile(TextBox target)
    {
        using var dialog = new OpenFileDialog
        {
            Filter = (string?)target.Tag is { Length: > 0 } f ? f : "所有文件 (*.*)|*.*",
            CheckFileExists = true,
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            target.Text = dialog.FileName;
            target.Tag = null;
        }
    }

    private void BrowseForFolder(TextBox target)
    {
        using var dialog = new FolderBrowserDialog { Description = "选择输出目录" };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            target.Text = dialog.SelectedPath;
            target.Tag = null;
        }
    }

    private static ComboBox AddOptionCombo(FlowLayoutPanel panel, string label, params string[] items)
    {
        panel.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new Padding(0, 6, 2, 0) });
        var combo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Width = 130,
            Margin = new Padding(0, 3, 12, 0),
        };
        combo.Items.AddRange(items);
        combo.SelectedIndex = 0;
        panel.Controls.Add(combo);
        return combo;
    }

    private static CheckBox AddOptionCheck(FlowLayoutPanel panel, string text)
    {
        var check = new CheckBox
        {
            Text = text,
            AutoSize = true,
            Margin = new Padding(0, 6, 12, 0),
        };
        panel.Controls.Add(check);
        return check;
    }

    // ----- settings persistence -----

    private void LoadSettingsIntoUi()
    {
        if (!string.IsNullOrWhiteSpace(_settings.BinPath))
        {
            _binTextBox.Text = _settings.BinPath;
            _binTextBox.Tag = null;
        }
        if (!string.IsNullOrWhiteSpace(_settings.TocPath))
        {
            _tocTextBox.Text = _settings.TocPath;
            _tocTextBox.Tag = null;
        }
        if (!string.IsNullOrWhiteSpace(_settings.OutputDirectory))
        {
            _outputTextBox.Text = _settings.OutputDirectory;
            _outputTextBox.Tag = null;
        }
        if (!string.IsNullOrWhiteSpace(_settings.FfmpegPath))
        {
            _ffmpegTextBox.Text = _settings.FfmpegPath;
            _ffmpegTextBox.Tag = null;
        }
        if (!string.IsNullOrWhiteSpace(_settings.EnvPath))
        {
            _envTextBox.Text = _settings.EnvPath;
            _envTextBox.Tag = null;
        }
        SelectCombo(_formatCombo, _settings.Format);
        SelectCombo(_domesticPriorityCombo, _settings.DomesticSourcePriority);
        SelectCombo(_lyricsFallbackCombo, _settings.LyricsTranslationFallback);
        SelectCombo(_aiProviderCombo, _settings.AiTranslationProvider);
        _releaseIndexInput.Value = Math.Clamp(_settings.ReleaseIndex, 0, 1000);
        _noMetadataCheck.Checked = _settings.NoMetadata;
        _noCoverCheck.Checked = _settings.NoCover;
        _noLyricsCheck.Checked = _settings.NoLyrics;
        _noNetEaseCheck.Checked = _settings.NoNetEase;
        _noQQMusicCheck.Checked = _settings.NoQQMusic;
        _userAgentTextBox.Text = _settings.MusicBrainzUserAgent ?? "";
    }

    private void SaveSettingsFromUi()
    {
        _settings.BinPath = GetRealText(_binTextBox);
        _settings.TocPath = GetRealText(_tocTextBox);
        _settings.OutputDirectory = GetRealText(_outputTextBox);
        _settings.FfmpegPath = GetRealText(_ffmpegTextBox);
        _settings.EnvPath = GetRealText(_envTextBox);
        _settings.Format = (string)_formatCombo.SelectedItem!;
        _settings.DomesticSourcePriority = (string)_domesticPriorityCombo.SelectedItem!;
        _settings.LyricsTranslationFallback = (string)_lyricsFallbackCombo.SelectedItem!;
        _settings.AiTranslationProvider = (string)_aiProviderCombo.SelectedItem!;
        _settings.ReleaseIndex = (int)_releaseIndexInput.Value;
        _settings.NoMetadata = _noMetadataCheck.Checked;
        _settings.NoCover = _noCoverCheck.Checked;
        _settings.NoLyrics = _noLyricsCheck.Checked;
        _settings.NoNetEase = _noNetEaseCheck.Checked;
        _settings.NoQQMusic = _noQQMusicCheck.Checked;
        _settings.MusicBrainzUserAgent = _userAgentTextBox.Text.Trim();
        _settings.Save();
    }

    private static void SelectCombo(ComboBox combo, string value)
    {
        var index = combo.Items.IndexOf(value);
        combo.SelectedIndex = index >= 0 ? index : 0;
    }

    private static string GetRealText(TextBox box) =>
        box.Tag is string placeholder && string.Equals(box.Text, placeholder, StringComparison.Ordinal)
            ? ""
            : box.Text.Trim();

    // ----- drag & drop -----

    private static void OnFormDragEnter(object? sender, DragEventArgs e)
    {
        if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true)
        {
            e.Effect = DragDropEffects.Copy;
        }
    }

    private void OnFormDragDrop(object? sender, DragEventArgs e)
    {
        if (e.Data?.GetData(DataFormats.FileDrop) is not string[] files)
        {
            return;
        }

        foreach (var file in files)
        {
            var extension = Path.GetExtension(file).ToLowerInvariant();
            if (extension == ".bin")
            {
                _binTextBox.Text = file;
                _binTextBox.Tag = null;
                var toc = Path.ChangeExtension(file, ".toc");
                if (File.Exists(toc))
                {
                    _tocTextBox.Text = toc;
                    _tocTextBox.Tag = null;
                }
                return;
            }
        }
        foreach (var file in files)
        {
            if (Path.GetExtension(file).Equals(".toc", StringComparison.OrdinalIgnoreCase))
            {
                _tocTextBox.Text = file;
                _tocTextBox.Tag = null;
                var bin = Path.ChangeExtension(file, ".bin");
                if (File.Exists(bin))
                {
                    _binTextBox.Text = bin;
                    _binTextBox.Tag = null;
                }
                return;
            }
        }

        MessageBox.Show(this, "请拖入 .bin 或 .toc 文件。", "CD-ROM Dump Tools GUI",
            MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    // ----- conversion -----

    private void StartConversion()
    {
        var binPath = GetRealText(_binTextBox);
        if (string.IsNullOrWhiteSpace(binPath))
        {
            MessageBox.Show(this, "请先选择 BIN 镜像文件。", "缺少输入",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (!File.Exists(binPath))
        {
            MessageBox.Show(this, $"BIN 文件不存在:\n{binPath}", "缺少输入",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        var scriptPath = FindConverterScript();
        if (scriptPath is null)
        {
            MessageBox.Show(this,
                "找不到 bin_to_audio_windows.ps1。\n请把本程序放到 cdrom-dump-tools 仓库目录内(gui\\CdromDumpToolsGui 之外任意位置)。",
                "缺少转换脚本", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var host = FindPowerShellHost();
        var (executable, processArgs) = BuildInvocation(host, scriptPath, binPath);

        SaveSettingsFromUi();
        _log.Clear();
        AppendLogLine($"转换脚本: {scriptPath}");
        AppendLogLine($"PowerShell: {executable}");
        AppendLogLine($"开始转换 {binPath} ...");
        AppendLogLine("");

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var arg in processArgs)
            {
                psi.ArgumentList.Add(arg);
            }

            _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _process.OutputDataReceived += OnOutputLine;
            _process.ErrorDataReceived += OnErrorLine;
            _process.Exited += OnProcessExited;
            _process.Start();
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            _process = null;
            AppendLogLine($"无法启动转换进程: {ex.Message}");
            MessageBox.Show(this, $"无法启动 PowerShell 转换进程:\n{ex.Message}", "启动失败",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        _running = true;
        _outputFolder = null;
        _runButton.Enabled = false;
        _cancelButton.Enabled = true;
        _openOutputButton.Enabled = false;
        _statusLabel.Text = "转换中...";
    }

    private void CancelConversion()
    {
        if (_process is null)
        {
            return;
        }
        AppendLogLine("");
        AppendLogLine("用户请求取消,正在终止转换进程...");
        try
        {
            _process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // The process already exited between the check and the kill.
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // No permission to kill; the process will end on its own.
        }
    }

    private void OnOutputLine(object sender, DataReceivedEventArgs e)
    {
        if (e.Data is not null)
        {
            AppendLogLine(e.Data);
        }
    }

    private void OnErrorLine(object sender, DataReceivedEventArgs e)
    {
        if (e.Data is not null)
        {
            AppendLogLine(e.Data);
        }
    }

    private void OnProcessExited(object? sender, EventArgs e)
    {
        var process = _process;
        _process = null;
        if (process is null)
        {
            return;
        }
        process.WaitForExit();
        int exitCode = process.ExitCode;
        process.Dispose();
        BeginInvoke(() => FinishConversion(exitCode));
    }

    private void FinishConversion(int exitCode)
    {
        _running = false;
        _runButton.Enabled = true;
        _cancelButton.Enabled = false;

        if (exitCode == 0)
        {
            _outputFolder = FindOutputFolderFromLog();
            _openOutputButton.Enabled = _outputFolder is not null && Directory.Exists(_outputFolder);
            _statusLabel.Text = _openOutputButton.Enabled ? "转换完成" : "转换完成(未找到输出目录)";
            AppendLogLine("");
            AppendLogLine("转换完成。");
            if (_openOutputButton.Enabled)
            {
                _toolTip.SetToolTip(_openOutputButton, _outputFolder!);
            }
        }
        else
        {
            _statusLabel.Text = $"转换失败(退出码 {exitCode})";
            AppendLogLine("");
            AppendLogLine($"转换失败,退出码 {exitCode}。请检查上方日志。");
        }
    }

    private string? FindOutputFolderFromLog()
    {
        var text = _log.Text;
        var lines = text.Split('\n');
        for (var i = lines.Length - 1; i >= 0; i--)
        {
            var line = lines[i].TrimEnd('\r');
            const string donePrefix = "Done. Converted tracks are in: ";
            const string destinationPrefix = "Destination: ";
            if (line.StartsWith(donePrefix, StringComparison.Ordinal))
            {
                return line.Substring(donePrefix.Length).Trim();
            }
            if (line.StartsWith(destinationPrefix, StringComparison.Ordinal) && i > lines.Length - 5)
            {
                return line.Substring(destinationPrefix.Length).Trim();
            }
        }
        return null;
    }

    private void OpenOutputFolder()
    {
        if (string.IsNullOrWhiteSpace(_outputFolder) || !Directory.Exists(_outputFolder))
        {
            MessageBox.Show(this, "输出目录不存在:\n" + _outputFolder, "无法打开",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        try
        {
            Process.Start("explorer.exe", $"\"{_outputFolder}\"");
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"无法打开资源管理器:\n{ex.Message}", "无法打开",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void AppendLogLine(string line)
    {
        if (IsDisposed || _log.IsDisposed || !_log.IsHandleCreated)
        {
            return;
        }
        if (InvokeRequired)
        {
            try
            {
                BeginInvoke(() => AppendLogLine(line));
            }
            catch (InvalidOperationException)
            {
                // The form was closed while the message was queued.
            }
            return;
        }
        _log.AppendText(line + Environment.NewLine);
        _log.ScrollToCaret();
    }

    // ----- helpers -----

    private static string? FindConverterScript()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "bin_to_audio_windows.ps1");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            directory = directory.Parent;
        }
        return null;
    }

    private static string FindPowerShellHost()
    {
        var pwsh = FindOnPath("pwsh.exe");
        if (pwsh is not null)
        {
            return pwsh;
        }
        foreach (var root in new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        })
        {
            foreach (var sub in new[]
            {
                Path.Combine(root, "PowerShell", "7", "pwsh.exe"),
                Path.Combine(root, "PowerShell", "7-preview", "pwsh.exe"),
            })
            {
                if (File.Exists(sub))
                {
                    return sub;
                }
            }
        }
        return "powershell.exe"; // Windows PowerShell 5.1 is always present on Windows.
    }

    private static string? FindOnPath(string fileName)
    {
        if (Path.IsPathRooted(fileName))
        {
            return File.Exists(fileName) ? fileName : null;
        }
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(directory.Trim('"'), fileName);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch
            {
                // A malformed PATH entry must not crash the GUI.
            }
        }
        return null;
    }

    /// <summary>
    /// Builds the process invocation. pwsh (PowerShell 7) accepts plain -File
    /// arguments and writes UTF-8 by default; Windows PowerShell 5.1 needs a
    /// wrapper command that switches its console output encoding to UTF-8 so
    /// Chinese log lines survive the pipe intact.
    /// </summary>
    private (string Executable, List<string> Arguments) BuildInvocation(
        string host, string scriptPath, string binPath)
    {
        var args = new List<string>
        {
            "-BinPath", binPath,
            "-Format", (string)_formatCombo.SelectedItem!,
            "-DomesticSourcePriority", (string)_domesticPriorityCombo.SelectedItem!,
            "-LyricsTranslationFallback", (string)_lyricsFallbackCombo.SelectedItem!,
            "-AiTranslationProvider", (string)_aiProviderCombo.SelectedItem!,
        };

        var toc = GetRealText(_tocTextBox);
        var output = GetRealText(_outputTextBox);
        var ffmpeg = GetRealText(_ffmpegTextBox);
        var env = GetRealText(_envTextBox);
        var userAgent = _userAgentTextBox.Text.Trim();
        var releaseIndex = (int)_releaseIndexInput.Value;

        if (!string.IsNullOrWhiteSpace(toc)) { args.Add("-TocPath"); args.Add(toc); }
        if (!string.IsNullOrWhiteSpace(output)) { args.Add("-OutputDirectory"); args.Add(output); }
        if (!string.IsNullOrWhiteSpace(ffmpeg)) { args.Add("-FfmpegPath"); args.Add(ffmpeg); }
        if (!string.IsNullOrWhiteSpace(env)) { args.Add("-EnvPath"); args.Add(env); }
        if (releaseIndex > 0) { args.Add("-ReleaseIndex"); args.Add(releaseIndex.ToString()); }
        if (_noMetadataCheck.Checked) { args.Add("-NoMetadata"); }
        if (_noCoverCheck.Checked) { args.Add("-NoCover"); }
        if (_noLyricsCheck.Checked) { args.Add("-NoLyrics"); }
        if (_noNetEaseCheck.Checked) { args.Add("-NoNetEase"); }
        if (_noQQMusicCheck.Checked) { args.Add("-NoQQMusic"); }
        args.Add("-NoPause");
        if (!string.IsNullOrWhiteSpace(userAgent)) { args.Add("-MusicBrainzUserAgent"); args.Add(userAgent); }

        // Windows PowerShell 5.1 writes redirected output with the console code
        // page (for example GBK on Chinese systems). Wrapping the call switches
        // the encoding to UTF-8 first so the log pane renders correctly.
        if (Path.GetFileNameWithoutExtension(host).Equals("powershell", StringComparison.OrdinalIgnoreCase))
        {
            var command = new StringBuilder("& { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & ");
            command.Append(PsQuote(scriptPath));
            foreach (var arg in args)
            {
                command.Append(' ').Append(PsQuote(arg));
            }
            command.Append(" }");
            return (host, new List<string>
            {
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-Command", command.ToString(),
            });
        }

        var pwshArgs = new List<string>
        {
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", scriptPath,
        };
        pwshArgs.AddRange(args);
        return (host, pwshArgs);
    }

    /// <summary>Quotes a value as a PowerShell single-quoted string literal.</summary>
    private static string PsQuote(string value) => "'" + value.Replace("'", "''") + "'";

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_running)
        {
            var result = MessageBox.Show(this, "转换还在进行中,确定要退出吗?", "退出确认",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (result != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }
            try
            {
                _process?.Kill(entireProcessTree: true);
            }
            catch
            {
                // Best effort; the OS reaps the child when we exit.
            }
        }
        SaveSettingsFromUi();
        base.OnFormClosing(e);
    }
}
