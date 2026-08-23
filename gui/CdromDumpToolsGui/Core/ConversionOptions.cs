namespace CdromDumpToolsGui.Core;

public sealed class ConversionOptions
{
    public const string DefaultMusicBrainzUserAgent =
        "BinToAudioWindows/2.8.0 (https://github.com/Gavin-LHX/cdrom-dump-tools)";

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
}
