namespace CdromDumpToolsGui.Core;

public static class EnvironmentFileResolver
{
    public static string? Resolve(string? configuredPath, string executableBaseDirectory)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return configuredPath.Trim();
        }

        if (string.IsNullOrWhiteSpace(executableBaseDirectory))
        {
            return null;
        }

        var adjacentPath = Path.GetFullPath(Path.Combine(executableBaseDirectory, ".env"));
        return File.Exists(adjacentPath) ? adjacentPath : null;
    }
}
