using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal sealed class AiSettingsForm : Form
{
    private readonly TextBox _googleApiKeyTextBox = NewSecretTextBox();
    private readonly TextBox _googleBaseUrlTextBox = NewTextBox();
    private readonly TextBox _openAiApiKeyTextBox = NewSecretTextBox();
    private readonly TextBox _openAiBaseUrlTextBox = NewTextBox();
    private readonly TextBox _openAiModelTextBox = NewTextBox();
    private readonly TextBox _openAiOrganizationTextBox = NewTextBox();
    private readonly TextBox _openAiProjectTextBox = NewTextBox();
    private readonly TextBox _anthropicApiKeyTextBox = NewSecretTextBox();
    private readonly TextBox _anthropicBaseUrlTextBox = NewTextBox();
    private readonly TextBox _anthropicModelTextBox = NewTextBox();
    private readonly TextBox _anthropicVersionTextBox = NewTextBox();
    private readonly NumericUpDown _anthropicMaxTokensInput = new()
    {
        Dock = DockStyle.Fill,
        Minimum = 256,
        Maximum = 32768,
        Increment = 256,
        ThousandsSeparator = true,
    };
    private readonly TextBox _promptFileTextBox = NewTextBox();
    private readonly CheckBox _rememberKeysCheckBox = new()
    {
        AutoSize = true,
        Text = "记住 API Key（使用 Windows 当前用户 DPAPI 加密保存在本机）",
        Checked = true,
    };

    public AiTranslationConfiguration Configuration { get; private set; }
    public bool RememberApiKeys => _rememberKeysCheckBox.Checked;

    public AiSettingsForm(AiTranslationConfiguration configuration, bool rememberApiKeys)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        Configuration = configuration.Clone();

        Text = "AI 模型与翻译 API 设置";
        Font = new Font("Microsoft YaHei UI", 9F);
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(780, 610);
        MinimumSize = new Size(720, 570);
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;

        BuildInterface();
        LoadConfiguration(configuration, rememberApiKeys);
    }

    protected override void OnFormClosing(FormClosingEventArgs eventArgs)
    {
        if (DialogResult == DialogResult.OK)
        {
            try
            {
                Configuration = CaptureConfiguration();
                AiTranslationEnvironment.Validate(Configuration);
            }
            catch (Exception exception) when (exception is ArgumentException or IOException or NotSupportedException)
            {
                eventArgs.Cancel = true;
                MessageBox.Show(this, exception.Message, "AI 设置无效", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
        base.OnFormClosing(eventArgs);
    }

    private void BuildInterface()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(12),
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var introduction = new Label
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            MaximumSize = new Size(740, 0),
            Text = "在这里直接填写模型、兼容 API 地址和密钥。为某个服务填写 Key、模型或自定义地址后，该服务的 GUI 配置优先；未启用服务仍可由 .env 提供。API Key 不会出现在命令预览或日志中。",
            ForeColor = SystemColors.ControlText,
            Margin = new Padding(3, 0, 3, 10),
        };
        root.Controls.Add(introduction, 0, 0);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildOpenAiPage());
        tabs.TabPages.Add(BuildAnthropicPage());
        tabs.TabPages.Add(BuildGooglePage());
        root.Controls.Add(tabs, 0, 1);

        var commonGroup = new GroupBox
        {
            Text = "通用设置",
            Dock = DockStyle.Top,
            AutoSize = true,
            Padding = new Padding(10, 8, 10, 10),
            Margin = new Padding(0, 10, 0, 0),
        };
        var common = NewSettingsTable();
        var promptPanel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, AutoSize = true };
        promptPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        promptPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        promptPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        promptPanel.Controls.Add(_promptFileTextBox, 0, 0);
        var browsePromptButton = new Button { Text = "浏览…", AutoSize = true, Margin = new Padding(6, 0, 0, 0) };
        browsePromptButton.Click += (_, _) => BrowsePromptFile();
        var clearPromptButton = new Button { Text = "清空", AutoSize = true, Margin = new Padding(5, 0, 0, 0) };
        clearPromptButton.Click += (_, _) => _promptFileTextBox.Clear();
        promptPanel.Controls.Add(browsePromptButton, 1, 0);
        promptPanel.Controls.Add(clearPromptButton, 2, 0);
        AddSettingsRow(common, 0, "自定义 Prompt 文件", promptPanel);
        var promptHint = NewHint("留空即使用 EXE 内置的“信、达、雅”歌词翻译 Prompt；文件只传路径，不写入 EXE。", 0);
        common.Controls.Add(promptHint, 0, 1);
        common.SetColumnSpan(promptHint, 2);
        commonGroup.Controls.Add(common);
        root.Controls.Add(commonGroup, 0, 2);

        var footer = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 2,
            Margin = new Padding(0, 10, 0, 0),
        };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.Controls.Add(_rememberKeysCheckBox, 0, 0);
        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = Padding.Empty,
        };
        var saveButton = new Button { Text = "保存", AutoSize = true, DialogResult = DialogResult.OK, Padding = new Padding(12, 3, 12, 3) };
        var cancelButton = new Button { Text = "取消", AutoSize = true, DialogResult = DialogResult.Cancel, Padding = new Padding(12, 3, 12, 3) };
        buttons.Controls.Add(saveButton);
        buttons.Controls.Add(cancelButton);
        footer.Controls.Add(buttons, 1, 0);
        root.Controls.Add(footer, 0, 3);

        AcceptButton = saveButton;
        CancelButton = cancelButton;
        Controls.Add(root);
    }

    private TabPage BuildOpenAiPage()
    {
        var page = NewTabPage("OpenAI / 兼容接口");
        var table = NewSettingsTable();
        AddSettingsRow(table, 0, "API Key", BuildSecretPanel(_openAiApiKeyTextBox));
        AddSettingsRow(table, 1, "Base URL", _openAiBaseUrlTextBox);
        AddSettingsRow(table, 2, "模型", _openAiModelTextBox);
        AddSettingsRow(table, 3, "Organization ID（可选）", _openAiOrganizationTextBox);
        AddSettingsRow(table, 4, "Project ID（可选）", _openAiProjectTextBox);
        var hint = NewHint("兼容 Chat Completions 格式；填写 API Key、Base URL 和模型后才会启用。脚本会在 Base URL 后追加 /chat/completions。", 10);
        table.Controls.Add(hint, 0, 5);
        table.SetColumnSpan(hint, 2);
        page.Controls.Add(table);
        return page;
    }

    private TabPage BuildAnthropicPage()
    {
        var page = NewTabPage("Anthropic / 兼容接口");
        var table = NewSettingsTable();
        AddSettingsRow(table, 0, "API Key", BuildSecretPanel(_anthropicApiKeyTextBox));
        AddSettingsRow(table, 1, "Base URL", _anthropicBaseUrlTextBox);
        AddSettingsRow(table, 2, "模型", _anthropicModelTextBox);
        AddSettingsRow(table, 3, "API Version", _anthropicVersionTextBox);
        AddSettingsRow(table, 4, "Max Tokens", _anthropicMaxTokensInput);
        var hint = NewHint("兼容 Anthropic Messages 格式；填写 API Key、Base URL 和模型后才会启用。脚本会在 Base URL 后追加 /messages。", 10);
        table.Controls.Add(hint, 0, 5);
        table.SetColumnSpan(hint, 2);
        page.Controls.Add(table);
        return page;
    }

    private TabPage BuildGooglePage()
    {
        var page = NewTabPage("Google 翻译");
        var table = NewSettingsTable();
        AddSettingsRow(table, 0, "API Key", BuildSecretPanel(_googleApiKeyTextBox));
        AddSettingsRow(table, 1, "Base URL", _googleBaseUrlTextBox);
        var hint = NewHint("Google Cloud Translation Basic v2。它只在 AI 提供方不可用或翻译失败后参与默认回退。", 10);
        table.Controls.Add(hint, 0, 2);
        table.SetColumnSpan(hint, 2);
        page.Controls.Add(table);
        return page;
    }

    private void LoadConfiguration(AiTranslationConfiguration configuration, bool rememberApiKeys)
    {
        _googleApiKeyTextBox.Text = configuration.GoogleApiKey;
        _googleBaseUrlTextBox.Text = configuration.GoogleBaseUrl;
        _openAiApiKeyTextBox.Text = configuration.OpenAiApiKey;
        _openAiBaseUrlTextBox.Text = configuration.OpenAiBaseUrl;
        _openAiModelTextBox.Text = configuration.OpenAiModel;
        _openAiOrganizationTextBox.Text = configuration.OpenAiOrganizationId;
        _openAiProjectTextBox.Text = configuration.OpenAiProjectId;
        _anthropicApiKeyTextBox.Text = configuration.AnthropicApiKey;
        _anthropicBaseUrlTextBox.Text = configuration.AnthropicBaseUrl;
        _anthropicModelTextBox.Text = configuration.AnthropicModel;
        _anthropicVersionTextBox.Text = configuration.AnthropicVersion;
        _anthropicMaxTokensInput.Value = Math.Clamp(configuration.AnthropicMaxTokens, 256, 32768);
        _promptFileTextBox.Text = configuration.PromptFile;
        _rememberKeysCheckBox.Checked = rememberApiKeys;
    }

    private AiTranslationConfiguration CaptureConfiguration() => new()
    {
        GoogleApiKey = _googleApiKeyTextBox.Text,
        GoogleBaseUrl = _googleBaseUrlTextBox.Text.Trim(),
        OpenAiApiKey = _openAiApiKeyTextBox.Text,
        OpenAiBaseUrl = _openAiBaseUrlTextBox.Text.Trim(),
        OpenAiModel = _openAiModelTextBox.Text.Trim(),
        OpenAiOrganizationId = _openAiOrganizationTextBox.Text.Trim(),
        OpenAiProjectId = _openAiProjectTextBox.Text.Trim(),
        AnthropicApiKey = _anthropicApiKeyTextBox.Text,
        AnthropicBaseUrl = _anthropicBaseUrlTextBox.Text.Trim(),
        AnthropicModel = _anthropicModelTextBox.Text.Trim(),
        AnthropicVersion = _anthropicVersionTextBox.Text.Trim(),
        AnthropicMaxTokens = Decimal.ToInt32(_anthropicMaxTokensInput.Value),
        PromptFile = _promptFileTextBox.Text.Trim(),
    };

    private void BrowsePromptFile()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "选择 UTF-8 自定义 Prompt 文件",
            Filter = "文本文件 (*.txt;*.md)|*.txt;*.md|所有文件 (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        };
        var current = _promptFileTextBox.Text.Trim();
        if (File.Exists(current))
        {
            dialog.InitialDirectory = Path.GetDirectoryName(Path.GetFullPath(current));
        }
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            _promptFileTextBox.Text = dialog.FileName;
        }
    }

    private static TableLayoutPanel BuildSecretPanel(TextBox textBox)
    {
        var panel = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoSize = true, Margin = Padding.Empty };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        panel.Controls.Add(textBox, 0, 0);
        var showCheckBox = new CheckBox { Text = "显示", AutoSize = true, Margin = new Padding(8, 4, 0, 0) };
        showCheckBox.CheckedChanged += (_, _) => textBox.UseSystemPasswordChar = !showCheckBox.Checked;
        panel.Controls.Add(showCheckBox, 1, 0);
        return panel;
    }

    private static TableLayoutPanel NewSettingsTable()
    {
        var table = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 2,
            Padding = new Padding(12),
        };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 175));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        return table;
    }

    private static TabPage NewTabPage(string text) => new(text)
    {
        Padding = new Padding(4),
        UseVisualStyleBackColor = true,
        AutoScroll = true,
    };

    private static TextBox NewTextBox() => new() { Dock = DockStyle.Fill };

    private static TextBox NewSecretTextBox() => new()
    {
        Dock = DockStyle.Fill,
        UseSystemPasswordChar = true,
    };

    private static Label NewHint(string text, int topMargin) => new()
    {
        Dock = DockStyle.Fill,
        AutoSize = true,
        ForeColor = SystemColors.GrayText,
        Text = text,
        Margin = new Padding(3, topMargin, 3, 3),
        MaximumSize = new Size(650, 0),
    };

    private static void AddSettingsRow(TableLayoutPanel table, int row, string labelText, Control control)
    {
        table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var label = new Label
        {
            Text = labelText,
            Dock = DockStyle.Fill,
            AutoSize = true,
            TextAlign = ContentAlignment.MiddleLeft,
            Margin = new Padding(3, 8, 8, 4),
        };
        control.Margin = new Padding(3, 4, 3, 4);
        table.Controls.Add(label, 0, row);
        table.Controls.Add(control, 1, row);
    }
}
