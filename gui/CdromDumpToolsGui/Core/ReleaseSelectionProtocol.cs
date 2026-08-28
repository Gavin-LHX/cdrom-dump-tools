using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CdromDumpToolsGui.Core;

public sealed record ReleaseCandidate(
    int Index,
    string Artist,
    string Title,
    string Date,
    string Country,
    string Disc,
    string ReleaseId,
    string Barcode);

public static class ReleaseSelectionProtocol
{
    public const string Prefix = "CDROM_DUMP_TOOLS_RELEASE_SELECTION_V1:";
    private const int MaximumEncodedLength = 1_000_000;
    private const int MaximumTextLength = 500;

    public static bool IsProtocolLine(string? line) =>
        line?.StartsWith(Prefix, StringComparison.Ordinal) == true;

    public static bool TryParse(
        string? line,
        out IReadOnlyList<ReleaseCandidate> candidates,
        out string error)
    {
        candidates = Array.Empty<ReleaseCandidate>();
        error = string.Empty;
        if (!IsProtocolLine(line))
        {
            error = "不是候选专辑选择协议行。";
            return false;
        }

        var encoded = line![Prefix.Length..];
        if (encoded.Length is 0 or > MaximumEncodedLength)
        {
            error = "候选专辑数据长度无效。";
            return false;
        }

        try
        {
            var bytes = Convert.FromBase64String(encoded);
            var payloads = JsonSerializer.Deserialize<List<ReleaseCandidatePayload>>(
                bytes,
                new JsonSerializerOptions { MaxDepth = 8 });
            if (payloads is null || payloads.Count is < 2 or > 1000)
            {
                error = "候选专辑数量无效。";
                return false;
            }

            var parsed = new List<ReleaseCandidate>(payloads.Count);
            var seenIndexes = new HashSet<int>();
            foreach (var payload in payloads)
            {
                if (payload.Index is < 1 or > 1000 || !seenIndexes.Add(payload.Index))
                {
                    error = "候选专辑序号无效或重复。";
                    return false;
                }

                var title = Clean(payload.Title);
                if (title.Length == 0)
                {
                    error = "候选专辑缺少标题。";
                    return false;
                }
                parsed.Add(new ReleaseCandidate(
                    payload.Index,
                    DefaultIfBlank(Clean(payload.Artist), "未知艺术家"),
                    title,
                    Clean(payload.Date),
                    Clean(payload.Country),
                    Clean(payload.Disc),
                    Clean(payload.ReleaseId),
                    Clean(payload.Barcode)));
            }

            parsed.Sort((left, right) => left.Index.CompareTo(right.Index));
            if (parsed.Where((candidate, position) => candidate.Index != position + 1).Any())
            {
                error = "候选专辑序号不连续。";
                return false;
            }

            candidates = parsed;
            return true;
        }
        catch (Exception exception) when (exception is FormatException or JsonException or DecoderFallbackException)
        {
            error = "候选专辑数据无法解析。";
            return false;
        }
    }

    private static string Clean(string? value)
    {
        var singleLine = (value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ').Trim();
        return singleLine.Length <= MaximumTextLength
            ? singleLine
            : singleLine[..MaximumTextLength];
    }

    private static string DefaultIfBlank(string value, string fallback) =>
        value.Length == 0 ? fallback : value;

    private sealed class ReleaseCandidatePayload
    {
        [JsonPropertyName("index")]
        public int Index { get; init; }

        [JsonPropertyName("artist")]
        public string? Artist { get; init; }

        [JsonPropertyName("title")]
        public string? Title { get; init; }

        [JsonPropertyName("date")]
        public string? Date { get; init; }

        [JsonPropertyName("country")]
        public string? Country { get; init; }

        [JsonPropertyName("disc")]
        public string? Disc { get; init; }

        [JsonPropertyName("release_id")]
        public string? ReleaseId { get; init; }

        [JsonPropertyName("barcode")]
        public string? Barcode { get; init; }
    }
}
