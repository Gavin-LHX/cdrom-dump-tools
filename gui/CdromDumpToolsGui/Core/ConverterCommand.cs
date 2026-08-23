using System.Diagnostics;

namespace CdromDumpToolsGui.Core;

public static class ConverterCommand
{
    private static readonly HashSet<string> Formats = new(StringComparer.OrdinalIgnoreCase) { "flac", "wav" };
    private static readonly HashSet<string> LyricsFallbacks = new(StringComparer.Ordinal)
    {
        "Auto", "None", "Google", "AI", "GoogleThenAI", "AIThenGoogle",
    };
    private static readonly HashSet<string> AiProviders = new(StringComparer.Ordinal)
    {
        "Auto", "OpenAI", "Anthropic",
    };
    private static readonly HashSet<string> DomesticPriorities = new(StringComparer.Ordinal)
    {
        "NetEaseFirst", "QQMusicFirst",
    };
    private static readonly HashSet<string> ScriptSwitchNames = new(StringComparer.Ordinal)
    {
        "-NoMetadata", "-NoCover", "-NoLyrics", "-NoNetEase", "-NoQQMusic", "-NoPause", "-VerifyAudio",
    };
    private static readonly HashSet<string> ScriptValueNames = new(StringComparer.Ordinal)
    {
        "-BinPath", "-Format", "-TocPath", "-OutputDirectory", "-FfmpegPath",
        "-LyricsTranslationFallback", "-AiTranslationProvider", "-EnvPath",
        "-DomesticSourcePriority", "-ReleaseIndex", "-MusicBrainzUserAgent",
    };

    public static IReadOnlyList<string> BuildArguments(string scriptPath, ConversionOptions options)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptPath);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.BinPath);

        if (!Formats.Contains(options.Format))
        {
            throw new ArgumentOutOfRangeException(nameof(options.Format));
        }
        if (!LyricsFallbacks.Contains(options.LyricsTranslationFallback))
        {
            throw new ArgumentOutOfRangeException(nameof(options.LyricsTranslationFallback));
        }
        if (!AiProviders.Contains(options.AiTranslationProvider))
        {
            throw new ArgumentOutOfRangeException(nameof(options.AiTranslationProvider));
        }
        if (!DomesticPriorities.Contains(options.DomesticSourcePriority))
        {
            throw new ArgumentOutOfRangeException(nameof(options.DomesticSourcePriority));
        }
        if (options.ReleaseIndex is < 0 or > 1000)
        {
            throw new ArgumentOutOfRangeException(nameof(options.ReleaseIndex));
        }

        var arguments = new List<string>
        {
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            Path.GetFullPath(scriptPath),
        };

        arguments.AddRange(BuildScriptArguments(options));
        return arguments;
    }

    public static IReadOnlyList<string> BuildScriptArguments(ConversionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.BinPath);

        if (!Formats.Contains(options.Format))
        {
            throw new ArgumentOutOfRangeException(nameof(options.Format));
        }
        if (!LyricsFallbacks.Contains(options.LyricsTranslationFallback))
        {
            throw new ArgumentOutOfRangeException(nameof(options.LyricsTranslationFallback));
        }
        if (!AiProviders.Contains(options.AiTranslationProvider))
        {
            throw new ArgumentOutOfRangeException(nameof(options.AiTranslationProvider));
        }
        if (!DomesticPriorities.Contains(options.DomesticSourcePriority))
        {
            throw new ArgumentOutOfRangeException(nameof(options.DomesticSourcePriority));
        }
        if (options.ReleaseIndex is < 0 or > 1000)
        {
            throw new ArgumentOutOfRangeException(nameof(options.ReleaseIndex));
        }

        var arguments = new List<string>
        {
            "-BinPath",
            Path.GetFullPath(options.BinPath),
            "-Format",
            options.Format.ToLowerInvariant(),
        };

        AddPath(arguments, "-TocPath", options.TocPath);
        AddPath(arguments, "-OutputDirectory", options.OutputDirectory);
        AddPath(arguments, "-FfmpegPath", options.FfmpegPath);
        AddSwitch(arguments, "-NoMetadata", options.NoMetadata);
        AddSwitch(arguments, "-NoCover", options.NoCover);
        AddSwitch(arguments, "-NoLyrics", options.NoLyrics);
        AddSwitch(arguments, "-NoNetEase", options.NoNetEase);
        AddSwitch(arguments, "-NoQQMusic", options.NoQQMusic);
        AddSwitch(arguments, "-NoPause", options.NoPause);
        AddSwitch(arguments, "-VerifyAudio", options.VerifyAudio);

        arguments.Add("-LyricsTranslationFallback");
        arguments.Add(options.LyricsTranslationFallback);
        arguments.Add("-AiTranslationProvider");
        arguments.Add(options.AiTranslationProvider);
        AddPath(arguments, "-EnvPath", options.EnvPath);
        arguments.Add("-DomesticSourcePriority");
        arguments.Add(options.DomesticSourcePriority);
        arguments.Add("-ReleaseIndex");
        arguments.Add(options.ReleaseIndex.ToString(System.Globalization.CultureInfo.InvariantCulture));

        if (!string.IsNullOrWhiteSpace(options.MusicBrainzUserAgent))
        {
            arguments.Add("-MusicBrainzUserAgent");
            arguments.Add(options.MusicBrainzUserAgent.Trim());
        }

        return arguments;
    }

    public static ProcessStartInfo CreateStartInfo(
        string powerShellPath,
        string scriptPath,
        ConversionOptions options,
        AiTranslationConfiguration? aiConfiguration = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(powerShellPath);
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.GetFullPath(powerShellPath),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(scriptPath))!,
        };

        var arguments = IsWindowsPowerShell(powerShellPath)
            ? BuildWindowsPowerShellArguments(scriptPath, options)
            : BuildArguments(scriptPath, options);
        foreach (var argument in arguments)
        {
            // ArgumentList deliberately avoids cmd.exe and PowerShell string parsing.
            startInfo.ArgumentList.Add(argument);
        }

        if (aiConfiguration is not null)
        {
            foreach (var pair in AiTranslationEnvironment.Build(aiConfiguration))
            {
                if (!AiTranslationEnvironment.SupportedVariableNames.Contains(pair.Key))
                {
                    throw new InvalidOperationException($"Unexpected AI environment variable: {pair.Key}");
                }
                startInfo.Environment[pair.Key] = pair.Value;
            }
        }

        return startInfo;
    }

    public static IReadOnlyList<string> BuildWindowsPowerShellArguments(string scriptPath, ConversionOptions options)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scriptPath);
        var command = new System.Text.StringBuilder(
            "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); " +
            "$OutputEncoding=[Console]::OutputEncoding; & ");
        command.Append(QuotePowerShellLiteral(Path.GetFullPath(scriptPath)));

        var scriptArguments = BuildScriptArguments(options);
        for (var index = 0; index < scriptArguments.Count; index++)
        {
            var parameterName = scriptArguments[index];
            if (!ScriptSwitchNames.Contains(parameterName) && !ScriptValueNames.Contains(parameterName))
            {
                throw new InvalidOperationException($"Unexpected converter parameter name: {parameterName}");
            }

            // Parameter names stay bare so PowerShell binds them; user-controlled values are literals.
            command.Append(' ').Append(parameterName);
            if (ScriptSwitchNames.Contains(parameterName))
            {
                continue;
            }
            if (++index >= scriptArguments.Count)
            {
                throw new InvalidOperationException($"Missing value for converter parameter: {parameterName}");
            }
            command.Append(' ').Append(QuotePowerShellLiteral(scriptArguments[index]));
        }

        return new[]
        {
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command.ToString(),
        };
    }

    public static string CreateSafePreview(string powerShellPath, IReadOnlyList<string> arguments)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(powerShellPath);
        ArgumentNullException.ThrowIfNull(arguments);

        return string.Join(" ", new[] { QuoteForDisplay(powerShellPath) }.Concat(arguments.Select(QuoteForDisplay)));
    }

    private static string QuoteForDisplay(string value)
    {
        // This is display-only. Doubling single quotes also makes the text safe to paste into PowerShell.
        return "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
    }

    private static string QuotePowerShellLiteral(string value) =>
        "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";

    private static bool IsWindowsPowerShell(string executablePath) =>
        Path.GetFileName(executablePath).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase);

    private static void AddPath(List<string> arguments, string name, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            arguments.Add(name);
            arguments.Add(Path.GetFullPath(value.Trim()));
        }
    }

    private static void AddSwitch(List<string> arguments, string name, bool enabled)
    {
        if (enabled)
        {
            arguments.Add(name);
        }
    }
}
