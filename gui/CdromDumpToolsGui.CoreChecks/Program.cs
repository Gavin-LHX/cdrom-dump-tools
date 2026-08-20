using CdromDumpToolsGui.Core;

var checks = new (string Name, Action Run)[]
{
    ("all converter parameters", CheckAllConverterParameters),
    ("ArgumentList preserves special paths", CheckArgumentListSpecialPaths),
    ("Windows PowerShell UTF-8 wrapper is safely quoted", CheckWindowsPowerShellWrapper),
    ("output path parsing", CheckOutputPathParsing),
    ("unused output suggestion", CheckUnusedOutputSuggestion),
    ("explicit output validation", CheckExplicitOutputValidation),
    ("default output prediction", CheckDefaultOutputPrediction),
};

var failures = 0;
foreach (var check in checks)
{
    try
    {
        check.Run();
        Console.WriteLine($"PASS  {check.Name}");
    }
    catch (Exception exception)
    {
        failures++;
        Console.Error.WriteLine($"FAIL  {check.Name}: {exception.Message}");
    }
}

Console.WriteLine($"{checks.Length - failures}/{checks.Length} checks passed.");
return failures == 0 ? 0 : 1;

static ConversionOptions FullOptions() => new()
{
    BinPath = @"C:\Music\O'Brien & 夜鹿 ヨルシカ\disc.bin",
    Format = "wav",
    TocPath = @"C:\Music\O'Brien & 夜鹿 ヨルシカ\disc.toc",
    OutputDirectory = @"C:\Output\尚不存在的专辑",
    FfmpegPath = @"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
    NoMetadata = true,
    NoCover = true,
    NoLyrics = true,
    NoNetEase = true,
    NoQQMusic = true,
    NoPause = true,
    LyricsTranslationFallback = "AIThenGoogle",
    AiTranslationProvider = "Anthropic",
    EnvPath = @"C:\Secrets\my config.env",
    DomesticSourcePriority = "QQMusicFirst",
    ReleaseIndex = 1000,
    MusicBrainzUserAgent = "Test Agent'; Write-Error 'must remain text",
};

static void CheckAllConverterParameters()
{
    var arguments = ConverterCommand.BuildScriptArguments(FullOptions());
    var expectedNames = new HashSet<string>(StringComparer.Ordinal)
    {
        "-BinPath", "-Format", "-TocPath", "-OutputDirectory", "-FfmpegPath",
        "-NoMetadata", "-NoCover", "-NoLyrics", "-NoNetEase", "-NoQQMusic", "-NoPause",
        "-LyricsTranslationFallback", "-AiTranslationProvider", "-EnvPath",
        "-DomesticSourcePriority", "-ReleaseIndex", "-MusicBrainzUserAgent",
    };
    var actualNames = arguments.Where(value => expectedNames.Contains(value)).ToHashSet(StringComparer.Ordinal);
    Equal(expectedNames.Count, actualNames.Count, "not every script parameter was emitted");
    True(expectedNames.SetEquals(actualNames), "script parameter set differs");
    ParameterEquals(arguments, "-Format", "wav");
    ParameterEquals(arguments, "-LyricsTranslationFallback", "AIThenGoogle");
    ParameterEquals(arguments, "-AiTranslationProvider", "Anthropic");
    ParameterEquals(arguments, "-DomesticSourcePriority", "QQMusicFirst");
    ParameterEquals(arguments, "-ReleaseIndex", "1000");
}

static void CheckArgumentListSpecialPaths()
{
    var options = FullOptions();
    var startInfo = ConverterCommand.CreateStartInfo(
        @"C:\Program Files\PowerShell\7\pwsh.exe",
        @"C:\repo path\bin_to_audio_windows.ps1",
        options);
    var arguments = startInfo.ArgumentList.ToArray();

    Equal(Path.GetFullPath(options.BinPath), ValueAfter(arguments, "-BinPath"), "BIN path changed");
    Equal(Path.GetFullPath(options.OutputDirectory!), ValueAfter(arguments, "-OutputDirectory"), "output path changed");
    Equal(options.MusicBrainzUserAgent, ValueAfter(arguments, "-MusicBrainzUserAgent"), "user agent changed");
    True(arguments.Contains("-File"), "pwsh must use -File");
    True(!startInfo.UseShellExecute, "shell execution must remain disabled");
}

static void CheckWindowsPowerShellWrapper()
{
    var options = FullOptions();
    var arguments = ConverterCommand.BuildWindowsPowerShellArguments(
        @"C:\repo's folder\bin_to_audio_windows.ps1",
        options);
    Equal("-Command", arguments[^2], "Windows PowerShell must use a UTF-8 command wrapper");
    var command = arguments[^1];

    True(command.Contains("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)", StringComparison.Ordinal),
        "UTF-8 output setup missing");
    True(command.Contains(" -BinPath 'C:\\Music\\O''Brien & 夜鹿 ヨルシカ\\disc.bin'", StringComparison.Ordinal),
        "apostrophe in BIN path was not escaped");
    True(!command.Contains("'-BinPath'", StringComparison.Ordinal), "parameter name must remain a bare token");
    True(command.Contains("'Test Agent''; Write-Error ''must remain text'", StringComparison.Ordinal),
        "user-controlled text was not quoted as one PowerShell literal");

    var startInfo = ConverterCommand.CreateStartInfo(
        @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
        @"C:\repo's folder\bin_to_audio_windows.ps1",
        options);
    Equal(command, startInfo.ArgumentList[^1], "CreateStartInfo did not select the PS5 wrapper");
}

static void CheckOutputPathParsing()
{
    True(OutputPathResolver.TryParseFromLogLine(
        @"Done. Converted tracks are in: C:\Music\歌手 - 专辑 (2026) [FLAC]",
        out var donePath), "completion line was not parsed");
    Equal(Path.GetFullPath(@"C:\Music\歌手 - 专辑 (2026) [FLAC]"), donePath, "completion path differs");

    True(OutputPathResolver.TryParseFromLogLine(
        @"  Done. Converted tracks are in: ""C:\Music\A B""  ",
        out var quotedDonePath), "trimmed completion line was not parsed");
    Equal(Path.GetFullPath(@"C:\Music\A B"), quotedDonePath, "quoted completion path differs");
    True(!OutputPathResolver.TryParseFromLogLine(@"Destination: C:\Music\A B", out _),
        "Destination must not count as successful completion");
    True(!OutputPathResolver.TryParseFromLogLine(@"prefix Done. Converted tracks are in: C:\Music\A B", out _),
        "completion marker must begin the trimmed line");
    True(!OutputPathResolver.TryParseFromLogLine("Done. Converted tracks are in:", out _),
        "empty completion path must be rejected");
}

static void CheckUnusedOutputSuggestion()
{
    var parent = Path.Combine(Path.GetTempPath(), "CdromDumpToolsGuiChecks-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(parent);
    try
    {
        var occupied = Path.Combine(parent, "disc-flac");
        Directory.CreateDirectory(occupied);
        var suggestion = OutputPathResolver.SuggestUnusedDirectory(parent, @"C:\input\disc.bin", "flac");
        Equal(Path.Combine(parent, "disc-flac-2"), suggestion, "suffix selection differs");
        True(!Directory.Exists(suggestion) && !File.Exists(suggestion), "suggestion must not already exist");
    }
    finally
    {
        Directory.Delete(parent, recursive: true);
    }
}

static void CheckDefaultOutputPrediction()
{
    var predicted = OutputPathResolver.PredictDefaultDirectory(@"C:\rip\disc.bin", "FLAC");
    Equal(Path.GetFullPath(@"C:\rip\disc-flac"), predicted, "default output prediction differs");
    Equal(null, OutputPathResolver.PredictDefaultDirectory(string.Empty, "flac"), "empty BIN should not predict");
}

static void CheckExplicitOutputValidation()
{
    var parent = Path.Combine(Path.GetTempPath(), "CdromDumpToolsGuiValidation-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(parent);
    try
    {
        var existing = Path.Combine(parent, "existing");
        Directory.CreateDirectory(existing);
        True(!OutputPathResolver.TryValidateExplicitDirectory(existing, out _, out _),
            "an existing final directory must be rejected");

        var nestedMissing = Path.Combine(parent, "missing-parent", "final-album");
        True(OutputPathResolver.TryValidateExplicitDirectory(nestedMissing, out var resolved, out var error),
            "a missing parent must be accepted: " + error);
        Equal(Path.GetFullPath(nestedMissing), resolved, "nested output path differs");

        True(!OutputPathResolver.TryValidateExplicitDirectory("invalid\0path", out _, out _),
            "an invalid path must be rejected without throwing");
    }
    finally
    {
        Directory.Delete(parent, recursive: true);
    }
}

static string ValueAfter(IReadOnlyList<string> arguments, string name)
{
    var index = arguments.ToList().IndexOf(name);
    True(index >= 0 && index + 1 < arguments.Count, $"missing value for {name}");
    return arguments[index + 1];
}

static void ParameterEquals(IReadOnlyList<string> arguments, string name, string expected) =>
    Equal(expected, ValueAfter(arguments, name), $"unexpected value for {name}");

static void True(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void Equal<T>(T expected, T actual, string message)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{message}; expected <{expected}>, actual <{actual}>");
    }
}
