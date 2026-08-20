namespace CdromDumpToolsGui.Core;

public static class OutputPathResolver
{
    public const string CompletionMarker = "Done. Converted tracks are in:";

    public static string SuggestUnusedDirectory(string parentDirectory, string binPath, string format)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(parentDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(binPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(format);

        var parent = Path.GetFullPath(parentDirectory);
        var baseName = Path.GetFileNameWithoutExtension(binPath);
        if (string.IsNullOrWhiteSpace(baseName))
        {
            baseName = "cdrom";
        }

        var stem = $"{SanitizeFileName(baseName)}-{format.ToLowerInvariant()}";
        var candidate = Path.Combine(parent, stem);
        for (var suffix = 2; Directory.Exists(candidate) || File.Exists(candidate); suffix++)
        {
            candidate = Path.Combine(parent, $"{stem}-{suffix}");
        }

        return candidate;
    }

    public static string? PredictDefaultDirectory(string binPath, string format)
    {
        if (string.IsNullOrWhiteSpace(binPath) || string.IsNullOrWhiteSpace(format))
        {
            return null;
        }

        var fullBinPath = Path.GetFullPath(binPath);
        var parent = Path.GetDirectoryName(fullBinPath);
        var name = Path.GetFileNameWithoutExtension(fullBinPath);
        return string.IsNullOrWhiteSpace(parent) || string.IsNullOrWhiteSpace(name)
            ? null
            : Path.Combine(parent, $"{name}-{format.ToLowerInvariant()}");
    }

    public static bool TryValidateExplicitDirectory(
        string? value,
        out string? fullPath,
        out string? error)
    {
        fullPath = null;
        error = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        try
        {
            fullPath = Path.GetFullPath(value.Trim());
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            error = "最终输出目录不是有效路径：" + exception.Message;
            return false;
        }

        if (Directory.Exists(fullPath) || File.Exists(fullPath))
        {
            error = "最终输出目录必须尚不存在。请点击“浏览”重新生成目录，或清空以使用自动命名。";
            return false;
        }

        // Missing parents are valid: the converter creates the directory tree itself.
        return true;
    }

    public static bool TryParseFromLogLine(string? line, out string? outputDirectory)
    {
        outputDirectory = null;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        var trimmedLine = line.Trim();
        if (!trimmedLine.StartsWith(CompletionMarker, StringComparison.Ordinal))
        {
            return false;
        }

        var candidate = trimmedLine[CompletionMarker.Length..].Trim().Trim('"');
        if (candidate.Length == 0)
        {
            return false;
        }

        try
        {
            outputDirectory = Path.GetFullPath(candidate);
            return true;
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static string SanitizeFileName(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var characters = value.Select(character => invalid.Contains(character) ? '_' : character).ToArray();
        var result = new string(characters).Trim().TrimEnd('.', ' ');
        return string.IsNullOrWhiteSpace(result) ? "cdrom" : result;
    }
}
