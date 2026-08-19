using System.IO;
using System.Text.Json;

namespace CdromDumpToolsGui;

/// <summary>
/// Persists the user's last-used paths and options between runs so that
/// dragging a disc onto the window does not force re-typing everything.
/// </summary>
internal sealed class AppSettings
{
    public string? BinPath { get; set; }
    public string? TocPath { get; set; }
    public string? OutputDirectory { get; set; }
    public string? FfmpegPath { get; set; }
    public string? EnvPath { get; set; }
    public string Format { get; set; } = "flac";
    public string DomesticSourcePriority { get; set; } = "NetEaseFirst";
    public string LyricsTranslationFallback { get; set; } = "Auto";
    public string AiTranslationProvider { get; set; } = "Auto";
    public int ReleaseIndex { get; set; }
    public bool NoMetadata { get; set; }
    public bool NoCover { get; set; }
    public bool NoLyrics { get; set; }
    public bool NoNetEase { get; set; }
    public bool NoQQMusic { get; set; }
    public string? MusicBrainzUserAgent { get; set; }

    private static string SettingsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CdromDumpToolsGui");

    private static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath));
                if (loaded is not null)
                {
                    return loaded;
                }
            }
        }
        catch
        {
            // Corrupt or unreadable settings should never block the GUI from starting.
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // Failing to persist settings is not fatal.
        }
    }
}
