using System.Globalization;
using System.Text.RegularExpressions;

namespace CdromDumpToolsGui.Core;

public enum ConversionProgressKind
{
    Metadata,
    Lyrics,
    Cover,
    TrackCount,
    TrackStarted,
    TrackVerificationStarted,
    TrackVerified,
}

public sealed record ConversionProgressEvent(
    ConversionProgressKind Kind,
    int? Current = null,
    int? Total = null,
    string? Detail = null);

public static partial class ConversionProgressParser
{
    [GeneratedRegex(@"^Lyrics (?<current>\d{2,3}):\s*(?<detail>.*)$", RegexOptions.CultureInvariant)]
    private static partial Regex LyricsLineRegex();

    [GeneratedRegex(@"^Tracks:\s*(?<total>\d+)$", RegexOptions.CultureInvariant)]
    private static partial Regex TrackCountLineRegex();

    [GeneratedRegex(@"^Converting track (?<current>\d+)/(?<total>\d+) -> (?<detail>.+)$", RegexOptions.CultureInvariant)]
    private static partial Regex TrackStartedLineRegex();

    [GeneratedRegex(@"^Verifying track (?<current>\d+)/(?<total>\d+) -> (?<detail>.+)$", RegexOptions.CultureInvariant)]
    private static partial Regex TrackVerificationStartedLineRegex();

    [GeneratedRegex(@"^Verified track (?<current>\d+)/(?<total>\d+): lossless PCM SHA-256 match$", RegexOptions.CultureInvariant)]
    private static partial Regex TrackVerifiedLineRegex();

    public static bool TryParse(string? line, out ConversionProgressEvent? progressEvent)
    {
        progressEvent = null;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        if (line.StartsWith("MusicBrainz Disc ID:", StringComparison.Ordinal)
            || line.StartsWith("Matched release:", StringComparison.Ordinal))
        {
            progressEvent = new ConversionProgressEvent(ConversionProgressKind.Metadata);
            return true;
        }

        var lyricsMatch = LyricsLineRegex().Match(line);
        if (lyricsMatch.Success
            && TryReadPositiveInt(lyricsMatch.Groups["current"].Value, out var lyricsTrack))
        {
            progressEvent = new ConversionProgressEvent(
                ConversionProgressKind.Lyrics,
                Current: lyricsTrack,
                Detail: CleanDetail(lyricsMatch.Groups["detail"].Value));
            return true;
        }

        const string coverPrefix = "Trying cover source: ";
        if (line.StartsWith(coverPrefix, StringComparison.Ordinal))
        {
            var detail = CleanDetail(line[coverPrefix.Length..]);
            if (detail.Length > 0)
            {
                progressEvent = new ConversionProgressEvent(ConversionProgressKind.Cover, Detail: detail);
                return true;
            }
        }

        var trackCountMatch = TrackCountLineRegex().Match(line);
        if (trackCountMatch.Success
            && TryReadPositiveInt(trackCountMatch.Groups["total"].Value, out var trackCount))
        {
            progressEvent = new ConversionProgressEvent(ConversionProgressKind.TrackCount, Total: trackCount);
            return true;
        }

        var trackMatch = TrackStartedLineRegex().Match(line);
        if (trackMatch.Success
            && TryReadPositiveInt(trackMatch.Groups["current"].Value, out var current)
            && TryReadPositiveInt(trackMatch.Groups["total"].Value, out var total)
            && current <= total)
        {
            progressEvent = new ConversionProgressEvent(
                ConversionProgressKind.TrackStarted,
                Current: current,
                Total: total,
                Detail: CleanDetail(trackMatch.Groups["detail"].Value));
            return true;
        }

        var verificationMatch = TrackVerificationStartedLineRegex().Match(line);
        if (verificationMatch.Success
            && TryReadPositiveInt(verificationMatch.Groups["current"].Value, out var verificationCurrent)
            && TryReadPositiveInt(verificationMatch.Groups["total"].Value, out var verificationTotal)
            && verificationCurrent <= verificationTotal)
        {
            progressEvent = new ConversionProgressEvent(
                ConversionProgressKind.TrackVerificationStarted,
                Current: verificationCurrent,
                Total: verificationTotal,
                Detail: CleanDetail(verificationMatch.Groups["detail"].Value));
            return true;
        }

        var verifiedMatch = TrackVerifiedLineRegex().Match(line);
        if (verifiedMatch.Success
            && TryReadPositiveInt(verifiedMatch.Groups["current"].Value, out var verifiedCurrent)
            && TryReadPositiveInt(verifiedMatch.Groups["total"].Value, out var verifiedTotal)
            && verifiedCurrent <= verifiedTotal)
        {
            progressEvent = new ConversionProgressEvent(
                ConversionProgressKind.TrackVerified,
                Current: verifiedCurrent,
                Total: verifiedTotal);
            return true;
        }

        return false;
    }

    private static bool TryReadPositiveInt(string value, out int number) =>
        int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number)
        && number is > 0 and <= 10_000;

    private static string CleanDetail(string value)
    {
        var singleLine = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return singleLine.Length <= 120 ? singleLine : singleLine[..120] + "…";
    }
}
