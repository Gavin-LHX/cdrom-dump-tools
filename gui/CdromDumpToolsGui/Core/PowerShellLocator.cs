namespace CdromDumpToolsGui.Core;

public static class PowerShellLocator
{
    public static string? FindExecutable()
    {
        var fixedPwsh = FixedPwshCandidate();
        if (fixedPwsh is not null && File.Exists(fixedPwsh))
        {
            return Path.GetFullPath(fixedPwsh);
        }

        // A non-default PowerShell 7 installation is still preferable to Windows PowerShell 5.1.
        var pathPwsh = FindOnPath("pwsh.exe");
        if (pathPwsh is not null)
        {
            return pathPwsh;
        }

        foreach (var candidate in FixedWindowsPowerShellCandidates())
        {
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return FindOnPath("powershell.exe");
    }

    private static string? FixedPwshCandidate()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return string.IsNullOrWhiteSpace(programFiles)
            ? null
            : Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
    }

    private static IEnumerable<string> FixedWindowsPowerShellCandidates()
    {
        var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
        if (!string.IsNullOrWhiteSpace(systemDirectory))
        {
            yield return Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        }

        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (!string.IsNullOrWhiteSpace(windows))
        {
            yield return Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        }
    }

    private static string? FindOnPath(string executable)
    {
        var pathValue = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(pathValue))
        {
            return null;
        }

        foreach (var rawDirectory in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var directory = rawDirectory.Trim().Trim('"');
            if (directory.Length == 0)
            {
                continue;
            }

            try
            {
                var candidate = Path.Combine(directory, executable);
                if (File.Exists(candidate))
                {
                    return Path.GetFullPath(candidate);
                }
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
            {
                // Ignore malformed PATH entries.
            }
        }

        return null;
    }
}
