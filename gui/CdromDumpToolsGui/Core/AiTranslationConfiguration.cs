using System.Collections.ObjectModel;

namespace CdromDumpToolsGui.Core;

public sealed class AiTranslationConfiguration
{
    public const string DefaultGoogleBaseUrl = "https://translation.googleapis.com/language/translate/v2";
    public const string DefaultMicrosoftBaseUrl = "https://api.cognitive.microsofttranslator.com";
    public const string DefaultOpenAiBaseUrl = "https://api.openai.com/v1";
    public const string DefaultAnthropicBaseUrl = "https://api.anthropic.com/v1";
    public const string DefaultAnthropicVersion = "2023-06-01";
    public const int DefaultAnthropicMaxTokens = 4096;

    public string GoogleApiKey { get; set; } = string.Empty;
    public string GoogleBaseUrl { get; set; } = DefaultGoogleBaseUrl;
    public string MicrosoftApiKey { get; set; } = string.Empty;
    public string MicrosoftBaseUrl { get; set; } = DefaultMicrosoftBaseUrl;
    public string MicrosoftRegion { get; set; } = string.Empty;
    public string OpenAiApiKey { get; set; } = string.Empty;
    public string OpenAiBaseUrl { get; set; } = DefaultOpenAiBaseUrl;
    public string OpenAiModel { get; set; } = string.Empty;
    public string OpenAiOrganizationId { get; set; } = string.Empty;
    public string OpenAiProjectId { get; set; } = string.Empty;
    public string AnthropicApiKey { get; set; } = string.Empty;
    public string AnthropicBaseUrl { get; set; } = DefaultAnthropicBaseUrl;
    public string AnthropicModel { get; set; } = string.Empty;
    public string AnthropicVersion { get; set; } = DefaultAnthropicVersion;
    public int AnthropicMaxTokens { get; set; } = DefaultAnthropicMaxTokens;
    public string PromptFile { get; set; } = string.Empty;

    public AiTranslationConfiguration Clone() => new()
    {
        GoogleApiKey = GoogleApiKey,
        GoogleBaseUrl = GoogleBaseUrl,
        MicrosoftApiKey = MicrosoftApiKey,
        MicrosoftBaseUrl = MicrosoftBaseUrl,
        MicrosoftRegion = MicrosoftRegion,
        OpenAiApiKey = OpenAiApiKey,
        OpenAiBaseUrl = OpenAiBaseUrl,
        OpenAiModel = OpenAiModel,
        OpenAiOrganizationId = OpenAiOrganizationId,
        OpenAiProjectId = OpenAiProjectId,
        AnthropicApiKey = AnthropicApiKey,
        AnthropicBaseUrl = AnthropicBaseUrl,
        AnthropicModel = AnthropicModel,
        AnthropicVersion = AnthropicVersion,
        AnthropicMaxTokens = AnthropicMaxTokens,
        PromptFile = PromptFile,
    };
}

public static class AiTranslationEnvironment
{
    public static readonly IReadOnlySet<string> SupportedVariableNames = new HashSet<string>(StringComparer.Ordinal)
    {
        "GOOGLE_TRANSLATE_API_KEY",
        "GOOGLE_TRANSLATE_BASE_URL",
        "MICROSOFT_TRANSLATOR_API_KEY",
        "MICROSOFT_TRANSLATOR_BASE_URL",
        "MICROSOFT_TRANSLATOR_REGION",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_MODEL",
        "OPENAI_ORG_ID",
        "OPENAI_PROJECT_ID",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_VERSION",
        "ANTHROPIC_MAX_TOKENS",
        "AI_TRANSLATION_PROMPT_FILE",
    };

    public static IReadOnlyDictionary<string, string> Build(AiTranslationConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        Validate(configuration);

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var googleIsConfigured = HasText(configuration.GoogleApiKey)
            || !IsDefaultUrl(configuration.GoogleBaseUrl, AiTranslationConfiguration.DefaultGoogleBaseUrl);
        if (googleIsConfigured)
        {
            Add(values, "GOOGLE_TRANSLATE_API_KEY", configuration.GoogleApiKey);
            Add(values, "GOOGLE_TRANSLATE_BASE_URL", configuration.GoogleBaseUrl);
        }

        var microsoftIsConfigured = HasText(configuration.MicrosoftApiKey)
            || HasText(configuration.MicrosoftRegion)
            || !IsDefaultUrl(configuration.MicrosoftBaseUrl, AiTranslationConfiguration.DefaultMicrosoftBaseUrl);
        if (microsoftIsConfigured)
        {
            Add(values, "MICROSOFT_TRANSLATOR_API_KEY", configuration.MicrosoftApiKey);
            Add(values, "MICROSOFT_TRANSLATOR_BASE_URL", configuration.MicrosoftBaseUrl);
            Add(values, "MICROSOFT_TRANSLATOR_REGION", configuration.MicrosoftRegion);
        }

        var openAiIsConfigured = HasText(configuration.OpenAiApiKey)
            || HasText(configuration.OpenAiModel)
            || HasText(configuration.OpenAiOrganizationId)
            || HasText(configuration.OpenAiProjectId)
            || !IsDefaultUrl(configuration.OpenAiBaseUrl, AiTranslationConfiguration.DefaultOpenAiBaseUrl);
        if (openAiIsConfigured)
        {
            Add(values, "OPENAI_API_KEY", configuration.OpenAiApiKey);
            Add(values, "OPENAI_BASE_URL", configuration.OpenAiBaseUrl);
            Add(values, "OPENAI_MODEL", configuration.OpenAiModel);
            Add(values, "OPENAI_ORG_ID", configuration.OpenAiOrganizationId);
            Add(values, "OPENAI_PROJECT_ID", configuration.OpenAiProjectId);
        }

        var anthropicIsConfigured = HasText(configuration.AnthropicApiKey)
            || HasText(configuration.AnthropicModel)
            || !IsDefaultUrl(configuration.AnthropicBaseUrl, AiTranslationConfiguration.DefaultAnthropicBaseUrl)
            || !string.Equals(configuration.AnthropicVersion.Trim(), AiTranslationConfiguration.DefaultAnthropicVersion, StringComparison.Ordinal)
            || configuration.AnthropicMaxTokens != AiTranslationConfiguration.DefaultAnthropicMaxTokens;
        if (anthropicIsConfigured)
        {
            Add(values, "ANTHROPIC_API_KEY", configuration.AnthropicApiKey);
            Add(values, "ANTHROPIC_BASE_URL", configuration.AnthropicBaseUrl);
            Add(values, "ANTHROPIC_MODEL", configuration.AnthropicModel);
            Add(values, "ANTHROPIC_VERSION", configuration.AnthropicVersion);
            values["ANTHROPIC_MAX_TOKENS"] = configuration.AnthropicMaxTokens.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        if (HasText(configuration.PromptFile))
        {
            values["AI_TRANSLATION_PROMPT_FILE"] = Path.GetFullPath(configuration.PromptFile.Trim());
        }

        return new ReadOnlyDictionary<string, string>(values);
    }

    public static bool ShouldApply(ConversionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        return !options.NoLyrics
            && !string.Equals(options.LyricsTranslationFallback, "None", StringComparison.Ordinal);
    }

    public static string CreateSafeSummary(AiTranslationConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var providers = new List<string>();
        if (HasText(configuration.OpenAiApiKey) && HasText(configuration.OpenAiModel))
        {
            providers.Add($"OpenAI ({configuration.OpenAiModel.Trim()})");
        }
        if (HasText(configuration.AnthropicApiKey) && HasText(configuration.AnthropicModel))
        {
            providers.Add($"Anthropic ({configuration.AnthropicModel.Trim()})");
        }
        if (HasText(configuration.GoogleApiKey))
        {
            providers.Add("Google Cloud Translation");
        }
        if (HasText(configuration.MicrosoftApiKey))
        {
            providers.Add("Microsoft Translator (Azure)");
        }
        return providers.Count == 0
            ? "GUI 中未填写完整服务；如有 .env，将继续使用其中的配置"
            : string.Join(" → ", providers);
    }

    public static void Validate(AiTranslationConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ValidateOptionalServiceUrl(configuration.GoogleBaseUrl, "Google Base URL");
        ValidateOptionalServiceUrl(configuration.MicrosoftBaseUrl, "Microsoft Base URL");
        ValidateOptionalServiceUrl(configuration.OpenAiBaseUrl, "OpenAI Base URL");
        ValidateOptionalServiceUrl(configuration.AnthropicBaseUrl, "Anthropic Base URL");
        var microsoftRegion = configuration.MicrosoftRegion?.Trim() ?? string.Empty;
        if (microsoftRegion.Length > 64
            || microsoftRegion.Any(character => !((character is >= 'a' and <= 'z')
                                                    || (character is >= 'A' and <= 'Z')
                                                    || (character is >= '0' and <= '9')
                                                    || character == '-')))
        {
            throw new ArgumentException(
                "Microsoft Region 只能包含字母、数字和连字符，且不能超过 64 个字符。",
                nameof(configuration.MicrosoftRegion));
        }
        if (configuration.AnthropicMaxTokens is < 256 or > 32768)
        {
            throw new ArgumentOutOfRangeException(
                nameof(configuration.AnthropicMaxTokens),
                "Anthropic Max Tokens 必须在 256 到 32768 之间。");
        }
        if (HasText(configuration.PromptFile) && !File.Exists(Path.GetFullPath(configuration.PromptFile.Trim())))
        {
            throw new FileNotFoundException("找不到自定义提示词文件。", configuration.PromptFile.Trim());
        }
    }

    public static void ValidateOptionalServiceUrl(string? value, string fieldName)
    {
        if (!HasText(value))
        {
            return;
        }
        if (!Uri.TryCreate(value!.Trim(), UriKind.Absolute, out var uri)
            || string.IsNullOrWhiteSpace(uri.Host)
            || !string.IsNullOrEmpty(uri.UserInfo)
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment)
            || !(uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
                 || (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) && uri.IsLoopback)))
        {
            throw new ArgumentException(
                $"{fieldName} 必须是 HTTPS 绝对地址；仅回环地址允许 HTTP，且不能含账号、查询参数或片段。",
                fieldName);
        }
    }

    private static bool IsDefaultUrl(string? value, string defaultValue) =>
        string.Equals(value?.Trim().TrimEnd('/'), defaultValue.TrimEnd('/'), StringComparison.OrdinalIgnoreCase);

    private static bool HasText(string? value) => !string.IsNullOrWhiteSpace(value);

    private static void Add(Dictionary<string, string> values, string name, string? value)
    {
        if (HasText(value))
        {
            values[name] = value!.Trim();
        }
    }
}
