using System.Text;
using System.Text.Json;
using CdromDumpToolsGui.Core;

namespace CdromDumpToolsGui;

internal sealed class AppSettings
{
    public string BinPath { get; set; } = string.Empty;
    public string TocPath { get; set; } = string.Empty;
    public string OutputDirectory { get; set; } = string.Empty;
    public string FfmpegPath { get; set; } = string.Empty;
    public string EnvPath { get; set; } = string.Empty;
    public string Format { get; set; } = "flac";
    public bool NoMetadata { get; set; }
    public bool NoCover { get; set; }
    public bool NoLyrics { get; set; }
    public bool NoNetEase { get; set; }
    public bool NoQQMusic { get; set; }
    public bool NoPause { get; set; } = true;
    public string LyricsTranslationFallback { get; set; } = "Auto";
    public string AiTranslationProvider { get; set; } = "Auto";
    public string DomesticSourcePriority { get; set; } = "NetEaseFirst";
    public int ReleaseIndex { get; set; }
    public string MusicBrainzUserAgent { get; set; } = ConversionOptions.DefaultMusicBrainzUserAgent;
    public bool OpenOutputOnSuccess { get; set; }
    public StoredAiSettings AiSettings { get; set; } = new();
}

internal sealed class StoredAiSettings
{
    public bool RememberApiKeys { get; set; } = true;
    public string ProtectedGoogleApiKey { get; set; } = string.Empty;
    public string GoogleBaseUrl { get; set; } = AiTranslationConfiguration.DefaultGoogleBaseUrl;
    public string ProtectedMicrosoftApiKey { get; set; } = string.Empty;
    public string MicrosoftBaseUrl { get; set; } = AiTranslationConfiguration.DefaultMicrosoftBaseUrl;
    public string MicrosoftRegion { get; set; } = string.Empty;
    public string ProtectedOpenAiApiKey { get; set; } = string.Empty;
    public string OpenAiBaseUrl { get; set; } = AiTranslationConfiguration.DefaultOpenAiBaseUrl;
    public string OpenAiModel { get; set; } = string.Empty;
    public string OpenAiOrganizationId { get; set; } = string.Empty;
    public string OpenAiProjectId { get; set; } = string.Empty;
    public string ProtectedAnthropicApiKey { get; set; } = string.Empty;
    public string AnthropicBaseUrl { get; set; } = AiTranslationConfiguration.DefaultAnthropicBaseUrl;
    public string AnthropicModel { get; set; } = string.Empty;
    public string AnthropicVersion { get; set; } = AiTranslationConfiguration.DefaultAnthropicVersion;
    public int AnthropicMaxTokens { get; set; } = AiTranslationConfiguration.DefaultAnthropicMaxTokens;
    public string PromptFile { get; set; } = string.Empty;

    public StoredAiSettings Clone() => (StoredAiSettings)MemberwiseClone();
}

internal static class AiSettingsPersistence
{
    public static AiTranslationConfiguration Load(StoredAiSettings? stored, out bool hadUnreadableSecret)
    {
        stored ??= new StoredAiSettings();
        hadUnreadableSecret = false;
        var googleKey = Unprotect(
            stored.ProtectedGoogleApiKey,
            ref hadUnreadableSecret,
            () => stored.ProtectedGoogleApiKey = string.Empty);
        var microsoftKey = Unprotect(
            stored.ProtectedMicrosoftApiKey,
            ref hadUnreadableSecret,
            () => stored.ProtectedMicrosoftApiKey = string.Empty);
        var openAiKey = Unprotect(
            stored.ProtectedOpenAiApiKey,
            ref hadUnreadableSecret,
            () => stored.ProtectedOpenAiApiKey = string.Empty);
        var anthropicKey = Unprotect(
            stored.ProtectedAnthropicApiKey,
            ref hadUnreadableSecret,
            () => stored.ProtectedAnthropicApiKey = string.Empty);
        return new AiTranslationConfiguration
        {
            GoogleApiKey = googleKey,
            GoogleBaseUrl = DefaultIfBlank(stored.GoogleBaseUrl, AiTranslationConfiguration.DefaultGoogleBaseUrl),
            MicrosoftApiKey = microsoftKey,
            MicrosoftBaseUrl = DefaultIfBlank(stored.MicrosoftBaseUrl, AiTranslationConfiguration.DefaultMicrosoftBaseUrl),
            MicrosoftRegion = stored.MicrosoftRegion ?? string.Empty,
            OpenAiApiKey = openAiKey,
            OpenAiBaseUrl = DefaultIfBlank(stored.OpenAiBaseUrl, AiTranslationConfiguration.DefaultOpenAiBaseUrl),
            OpenAiModel = stored.OpenAiModel ?? string.Empty,
            OpenAiOrganizationId = stored.OpenAiOrganizationId ?? string.Empty,
            OpenAiProjectId = stored.OpenAiProjectId ?? string.Empty,
            AnthropicApiKey = anthropicKey,
            AnthropicBaseUrl = DefaultIfBlank(stored.AnthropicBaseUrl, AiTranslationConfiguration.DefaultAnthropicBaseUrl),
            AnthropicModel = stored.AnthropicModel ?? string.Empty,
            AnthropicVersion = DefaultIfBlank(stored.AnthropicVersion, AiTranslationConfiguration.DefaultAnthropicVersion),
            AnthropicMaxTokens = stored.AnthropicMaxTokens is >= 256 and <= 32768
                ? stored.AnthropicMaxTokens
                : AiTranslationConfiguration.DefaultAnthropicMaxTokens,
            PromptFile = stored.PromptFile ?? string.Empty,
        };
    }

    public static StoredAiSettings Save(AiTranslationConfiguration configuration, bool rememberApiKeys)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        AiTranslationEnvironment.Validate(configuration);
        return new StoredAiSettings
        {
            RememberApiKeys = rememberApiKeys,
            ProtectedGoogleApiKey = rememberApiKeys ? SecretProtector.Protect(configuration.GoogleApiKey) : string.Empty,
            GoogleBaseUrl = configuration.GoogleBaseUrl.Trim(),
            ProtectedMicrosoftApiKey = rememberApiKeys ? SecretProtector.Protect(configuration.MicrosoftApiKey) : string.Empty,
            MicrosoftBaseUrl = configuration.MicrosoftBaseUrl.Trim(),
            MicrosoftRegion = configuration.MicrosoftRegion.Trim(),
            ProtectedOpenAiApiKey = rememberApiKeys ? SecretProtector.Protect(configuration.OpenAiApiKey) : string.Empty,
            OpenAiBaseUrl = configuration.OpenAiBaseUrl.Trim(),
            OpenAiModel = configuration.OpenAiModel.Trim(),
            OpenAiOrganizationId = configuration.OpenAiOrganizationId.Trim(),
            OpenAiProjectId = configuration.OpenAiProjectId.Trim(),
            ProtectedAnthropicApiKey = rememberApiKeys ? SecretProtector.Protect(configuration.AnthropicApiKey) : string.Empty,
            AnthropicBaseUrl = configuration.AnthropicBaseUrl.Trim(),
            AnthropicModel = configuration.AnthropicModel.Trim(),
            AnthropicVersion = configuration.AnthropicVersion.Trim(),
            AnthropicMaxTokens = configuration.AnthropicMaxTokens,
            PromptFile = configuration.PromptFile.Trim(),
        };
    }

    private static string Unprotect(string? value, ref bool hadUnreadableSecret, Action clearUnreadableValue)
    {
        if (SecretProtector.TryUnprotect(value, out var plaintext))
        {
            return plaintext;
        }
        hadUnreadableSecret = true;
        clearUnreadableValue();
        return string.Empty;
    }

    private static string DefaultIfBlank(string? value, string defaultValue) =>
        string.IsNullOrWhiteSpace(value) ? defaultValue : value.Trim();
}

internal static class AppSettingsStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new() { WriteIndented = true };

    private static string SettingsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CdromDumpToolsGui");

    private static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new AppSettings();
            }

            var json = File.ReadAllText(SettingsPath, Encoding.UTF8);
            var settings = JsonSerializer.Deserialize<AppSettings>(json, SerializerOptions) ?? new AppSettings();
            settings.AiSettings ??= new StoredAiSettings();
            return settings;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            // A damaged settings file must never prevent the app from starting.
            return new AppSettings();
        }
    }

    public static void Save(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        Directory.CreateDirectory(SettingsDirectory);

        // API keys are serialized only as Windows-current-user DPAPI ciphertext.
        var json = JsonSerializer.Serialize(settings, SerializerOptions);
        var temporaryPath = Path.Combine(SettingsDirectory, $"settings.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            if (File.Exists(SettingsPath))
            {
                try
                {
                    File.Replace(temporaryPath, SettingsPath, destinationBackupFileName: null);
                }
                catch (PlatformNotSupportedException)
                {
                    File.Move(temporaryPath, SettingsPath, overwrite: true);
                }
            }
            else
            {
                File.Move(temporaryPath, SettingsPath);
            }
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // The completed settings write is more important than temporary-file cleanup.
            }
        }
    }
}
