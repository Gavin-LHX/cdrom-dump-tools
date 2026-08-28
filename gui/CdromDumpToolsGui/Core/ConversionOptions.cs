namespace CdromDumpToolsGui.Core;

public sealed class ConversionOptions
{
    public const string CurrentVersion = "2.10.0";
    public const string DefaultMusicBrainzUserAgent =
        "BinToAudioWindows/" + CurrentVersion + " (https://github.com/Gavin-LHX/cdrom-dump-tools)";
    private const string OfficialUserAgentSuffix =
        " (https://github.com/Gavin-LHX/cdrom-dump-tools)";

    public string BinPath { get; set; } = string.Empty;
    public string Format { get; set; } = "flac";
    public string? TocPath { get; set; }
    public string? OutputDirectory { get; set; }
    public string? FfmpegPath { get; set; }
    public bool NoMetadata { get; set; }
    public bool NoCover { get; set; }
    public bool NoLyrics { get; set; }
    public bool NoNetEase { get; set; }
    public bool NoQQMusic { get; set; }
    public bool NoPause { get; set; } = true;
    public bool VerifyAudio { get; set; }
    public string LyricsTranslationFallback { get; set; } = "Auto";
    public string AiTranslationProvider { get; set; } = "Auto";
    public string? EnvPath { get; set; }
    public string DomesticSourcePriority { get; set; } = "NetEaseFirst";
    public int ReleaseIndex { get; set; }
    public string MusicBrainzUserAgent { get; set; } = DefaultMusicBrainzUserAgent;
    public bool PromptForReleaseSelection { get; set; }

    public static string NormalizeMusicBrainzUserAgent(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return DefaultMusicBrainzUserAgent;
        }

        if (trimmed.StartsWith("BinToAudioWindows/", StringComparison.Ordinal)
            && trimmed.EndsWith(OfficialUserAgentSuffix, StringComparison.Ordinal)
            && Version.TryParse(
                trimmed["BinToAudioWindows/".Length..^OfficialUserAgentSuffix.Length],
                out _))
        {
            return DefaultMusicBrainzUserAgent;
        }

        return trimmed;
    }
}
