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
            return JsonSerializer.Deserialize<AppSettings>(json, SerializerOptions) ?? new AppSettings();
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

        // AppSettings intentionally contains only an .env path, never API key values.
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
