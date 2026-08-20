namespace CdromDumpToolsGui.Core;

public static class ScriptLocator
{
    public const string ScriptFileName = "bin_to_audio_windows.ps1";

    public static string? FindConverterScript(string startDirectory)
    {
        if (string.IsNullOrWhiteSpace(startDirectory))
        {
            return null;
        }

        DirectoryInfo? directory;
        try
        {
            directory = new DirectoryInfo(Path.GetFullPath(startDirectory));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }

        for (var depth = 0; directory is not null && depth < 8; depth++, directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, ScriptFileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}
