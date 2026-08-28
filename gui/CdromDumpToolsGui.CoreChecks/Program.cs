using CdromDumpToolsGui;
using CdromDumpToolsGui.Core;

var checks = new (string Name, Action Run)[]
{
    ("all converter parameters", CheckAllConverterParameters),
    ("ArgumentList preserves special paths", CheckArgumentListSpecialPaths),
    ("Windows PowerShell UTF-8 wrapper is safely quoted", CheckWindowsPowerShellWrapper),
    ("output path parsing", CheckOutputPathParsing),
    ("conversion progress parsing", CheckConversionProgressParsing),
    ("GUI release selection protocol", CheckReleaseSelectionProtocol),
    ("embedded component version consistency", CheckVersionConsistency),
    ("legacy built-in user agent migration", CheckMusicBrainzUserAgentMigration),
    ("unused output suggestion", CheckUnusedOutputSuggestion),
    ("explicit output validation", CheckExplicitOutputValidation),
    ("default output prediction", CheckDefaultOutputPrediction),
    ("embedded script extraction and repair", CheckEmbeddedScriptExtraction),
    ("concurrent embedded script extraction", CheckConcurrentEmbeddedScriptExtraction),
    ("verified execution lease", CheckVerifiedExecutionLease),
    ("elevated interactive-launch policy", CheckElevationPolicy),
    ("adjacent environment-file resolution", CheckEnvironmentFileResolution),
    ("AI environment mapping and preview redaction", CheckAiEnvironmentMapping),
    ("AI configuration activation follows lyrics settings", CheckAiConfigurationActivation),
    ("AI service URL validation", CheckAiServiceUrlValidation),
    ("DPAPI-protected AI settings", CheckProtectedAiSettings),
    ("embedded script clears every AI environment variable", CheckEmbeddedScriptEnvironmentCleanupContract),
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
    VerifyAudio = true,
    LyricsTranslationFallback = "AIThenGoogle",
    AiTranslationProvider = "Anthropic",
    EnvPath = @"C:\Secrets\my config.env",
    DomesticSourcePriority = "QQMusicFirst",
    ReleaseIndex = 1000,
    MusicBrainzUserAgent = "Test Agent'; Write-Error 'must remain text",
};

static void CheckAllConverterParameters()
{
    True(new AppSettings().VerifyAudio,
        "new and legacy settings without an explicit audio-verification field must default to enabled");

    var arguments = ConverterCommand.BuildScriptArguments(FullOptions());
    var expectedNames = new HashSet<string>(StringComparer.Ordinal)
    {
        "-BinPath", "-Format", "-TocPath", "-OutputDirectory", "-FfmpegPath",
        "-NoMetadata", "-NoCover", "-NoLyrics", "-NoNetEase", "-NoQQMusic", "-NoPause", "-VerifyAudio",
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
    True(arguments.Contains("-VerifyAudio"), "audio verification switch was not emitted");

    var interactiveOptions = FullOptions();
    interactiveOptions.NoMetadata = false;
    interactiveOptions.ReleaseIndex = 0;
    interactiveOptions.PromptForReleaseSelection = true;
    var interactiveArguments = ConverterCommand.BuildScriptArguments(interactiveOptions);
    True(interactiveArguments.Contains("-GuiReleaseSelection"),
        "GUI release-selection switch was not emitted for automatic candidate selection");

    interactiveOptions.ReleaseIndex = 2;
    True(!ConverterCommand.BuildScriptArguments(interactiveOptions).Contains("-GuiReleaseSelection"),
        "an explicit release index must bypass the GUI candidate prompt");

    interactiveOptions.ReleaseIndex = 0;
    interactiveOptions.NoMetadata = true;
    True(!ConverterCommand.BuildScriptArguments(interactiveOptions).Contains("-GuiReleaseSelection"),
        "metadata-disabled conversion must not request a MusicBrainz candidate prompt");
}

static void CheckReleaseSelectionProtocol()
{
    var payload = """
        [
          {"index":1,"artist":"compllege","title":"Phant","date":"2024-10-27","country":"JP","disc":"1","release_id":"id-1","barcode":"111"},
          {"index":2,"artist":"コンプレッジ","title":"ファント","date":"2016-12-30","country":"JP","disc":"1","release_id":"id-2","barcode":"222"}
        ]
        """;
    var line = ReleaseSelectionProtocol.Prefix
        + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(payload));
    True(ReleaseSelectionProtocol.IsProtocolLine(line), "valid protocol prefix was not recognized");
    True(ReleaseSelectionProtocol.TryParse(line, out var candidates, out var error),
        "valid candidate payload was rejected: " + error);
    Equal(2, candidates.Count, "candidate count differs");
    Equal("コンプレッジ", candidates[1].Artist, "non-ASCII candidate artist changed");
    Equal("ファント", candidates[1].Title, "non-ASCII candidate title changed");
    Equal("id-2", candidates[1].ReleaseId, "release ID changed");

    True(!ReleaseSelectionProtocol.TryParse(
            ReleaseSelectionProtocol.Prefix + "not-base64",
            out _,
            out _),
        "malformed Base64 payload was accepted");
    var duplicatePayload = """
        [{"index":1,"title":"A"},{"index":1,"title":"B"}]
        """;
    True(!ReleaseSelectionProtocol.TryParse(
            ReleaseSelectionProtocol.Prefix
            + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(duplicatePayload)),
            out _,
            out _),
        "duplicate candidate indexes were accepted");

    var script = System.Text.Encoding.UTF8.GetString(EmbeddedConverterScript.ReadEmbeddedBytesForChecks());
    True(script.Contains("[switch] $GuiReleaseSelection", StringComparison.Ordinal),
        "embedded converter lacks the GUI release-selection switch");
    True(script.Contains(ReleaseSelectionProtocol.Prefix, StringComparison.Ordinal),
        "embedded converter protocol prefix differs from the GUI parser");
    True(script.Contains("[Console]::In.ReadLine()", StringComparison.Ordinal),
        "embedded converter does not wait for the GUI selection over redirected standard input");
    True(script.Contains("Resolve-MusicBrainzReleaseIndex", StringComparison.Ordinal),
        "embedded converter does not validate forced release indexes");
    True(script.Contains("$_.Exception.ParamName -ceq 'ReleaseIndex'", StringComparison.Ordinal),
        "embedded converter fallback can swallow an invalid forced release index");
}

static void CheckMusicBrainzUserAgentMigration()
{
    Equal(
        ConversionOptions.DefaultMusicBrainzUserAgent,
        ConversionOptions.NormalizeMusicBrainzUserAgent(
            "BinToAudioWindows/2.7.0 (https://github.com/Gavin-LHX/cdrom-dump-tools)"),
        "legacy built-in user agent was not upgraded");
    Equal(
        ConversionOptions.DefaultMusicBrainzUserAgent,
        ConversionOptions.NormalizeMusicBrainzUserAgent(null),
        "blank user agent did not use the current default");
    Equal(
        "MyCdRipper/1.0 (contact@example.com)",
        ConversionOptions.NormalizeMusicBrainzUserAgent("  MyCdRipper/1.0 (contact@example.com)  "),
        "custom user agent was not preserved");
}

static void CheckVersionConsistency()
{
    var script = System.Text.Encoding.UTF8.GetString(EmbeddedConverterScript.ReadEmbeddedBytesForChecks());
    var embeddedVersions = System.Text.RegularExpressions.Regex
        .Matches(script, @"BinToAudioWindows/(?<version>[0-9]+\.[0-9]+\.[0-9]+)")
        .Select(match => match.Groups["version"].Value)
        .Distinct(StringComparer.Ordinal)
        .ToArray();
    Equal(1, embeddedVersions.Length, "embedded script contains inconsistent component versions");
    Equal(ConversionOptions.CurrentVersion, embeddedVersions[0], "embedded script version differs from GUI version");
    True(
        ConversionOptions.DefaultMusicBrainzUserAgent.Contains(
            "/" + ConversionOptions.CurrentVersion + " ",
            StringComparison.Ordinal),
        "default MusicBrainz user agent differs from GUI version");
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
    Equal("utf-8", startInfo.StandardInputEncoding?.WebName, "GUI selection input is not UTF-8");
    Equal(0, startInfo.StandardInputEncoding?.GetPreamble().Length ?? -1, "GUI selection input must not emit a BOM");
}

static void CheckAiEnvironmentMapping()
{
    const string openAiKey = "sk-test-secret-never-log";
    const string anthropicKey = "ant-test-secret-never-log";
    const string googleKey = "google-test-secret-never-log";
    const string microsoftKey = "microsoft-test-secret-never-log";
    var configuration = new AiTranslationConfiguration
    {
        OpenAiApiKey = openAiKey,
        OpenAiBaseUrl = "https://gateway.example.test/openai/v1",
        OpenAiModel = "gpt-test-model",
        OpenAiOrganizationId = "org-test",
        OpenAiProjectId = "project-test",
        AnthropicApiKey = anthropicKey,
        AnthropicBaseUrl = "https://gateway.example.test/anthropic/v1",
        AnthropicModel = "claude-test-model",
        AnthropicVersion = "2023-06-01",
        AnthropicMaxTokens = 8192,
        GoogleApiKey = googleKey,
        MicrosoftApiKey = microsoftKey,
        MicrosoftBaseUrl = "https://translator.example.test",
        MicrosoftRegion = "eastus2",
        PromptFile = string.Empty,
    };

    var environment = AiTranslationEnvironment.Build(configuration);
    Equal(openAiKey, environment["OPENAI_API_KEY"], "OpenAI key mapping differs");
    Equal("gpt-test-model", environment["OPENAI_MODEL"], "OpenAI model mapping differs");
    Equal(anthropicKey, environment["ANTHROPIC_API_KEY"], "Anthropic key mapping differs");
    Equal("8192", environment["ANTHROPIC_MAX_TOKENS"], "Anthropic token mapping differs");
    Equal(googleKey, environment["GOOGLE_TRANSLATE_API_KEY"], "Google key mapping differs");
    Equal(microsoftKey, environment["MICROSOFT_TRANSLATOR_API_KEY"], "Microsoft key mapping differs");
    Equal("https://translator.example.test", environment["MICROSOFT_TRANSLATOR_BASE_URL"], "Microsoft URL mapping differs");
    Equal("eastus2", environment["MICROSOFT_TRANSLATOR_REGION"], "Microsoft region mapping differs");
    var summary = AiTranslationEnvironment.CreateSafeSummary(configuration);
    True(summary.Contains("Microsoft Translator (Azure)", StringComparison.Ordinal),
        "safe summary omitted configured Microsoft Translator");

    var startInfo = ConverterCommand.CreateStartInfo(
        @"C:\Program Files\PowerShell\7\pwsh.exe",
        @"C:\repo path\bin_to_audio_windows.ps1",
        FullOptions(),
        configuration);
    Equal(openAiKey, startInfo.Environment["OPENAI_API_KEY"], "OpenAI key was not injected into the child environment");
    Equal(anthropicKey, startInfo.Environment["ANTHROPIC_API_KEY"], "Anthropic key was not injected into the child environment");
    Equal(microsoftKey, startInfo.Environment["MICROSOFT_TRANSLATOR_API_KEY"], "Microsoft key was not injected into the child environment");
    var preview = ConverterCommand.CreateSafePreview(startInfo.FileName, startInfo.ArgumentList.ToArray());
    foreach (var secret in new[] { openAiKey, anthropicKey, googleKey, microsoftKey })
    {
        True(!startInfo.ArgumentList.Contains(secret), "an API key leaked into ArgumentList");
        True(!preview.Contains(secret, StringComparison.Ordinal), "an API key leaked into the command preview");
        True(!summary.Contains(secret, StringComparison.Ordinal), "an API key leaked into the safe summary");
    }

    Equal(0, AiTranslationEnvironment.Build(new AiTranslationConfiguration()).Count,
        "untouched GUI defaults must not mask values supplied by .env");
}

static void CheckAiConfigurationActivation()
{
    var options = new ConversionOptions
    {
        LyricsTranslationFallback = "Auto",
    };
    True(AiTranslationEnvironment.ShouldApply(options),
        "AI configuration should apply when lyrics and translation fallback are enabled");

    options.NoLyrics = true;
    True(!AiTranslationEnvironment.ShouldApply(options),
        "AI configuration must not be validated or injected when lyrics are disabled");

    options.NoLyrics = false;
    options.LyricsTranslationFallback = "None";
    True(!AiTranslationEnvironment.ShouldApply(options),
        "AI configuration must not be validated or injected when machine translation is disabled");
}

static void CheckAiServiceUrlValidation()
{
    AiTranslationEnvironment.ValidateOptionalServiceUrl("https://api.example.test/v1", "test");
    AiTranslationEnvironment.ValidateOptionalServiceUrl("http://127.0.0.1:8080/v1", "test");
    ExpectArgumentException(() =>
        AiTranslationEnvironment.ValidateOptionalServiceUrl("http://api.example.test/v1", "test"));
    ExpectArgumentException(() =>
        AiTranslationEnvironment.ValidateOptionalServiceUrl("https://api.example.test/v1?key=secret", "test"));
    ExpectArgumentException(() =>
        AiTranslationEnvironment.ValidateOptionalServiceUrl("https://user:pass@api.example.test/v1", "test"));
    AiTranslationEnvironment.Validate(new AiTranslationConfiguration { MicrosoftRegion = "eastus2" });
    ExpectArgumentException(() =>
        AiTranslationEnvironment.Validate(new AiTranslationConfiguration { MicrosoftRegion = "east us" }));
    ExpectArgumentException(() =>
        AiTranslationEnvironment.Validate(new AiTranslationConfiguration { MicrosoftRegion = "东亚" }));
}

static void CheckProtectedAiSettings()
{
    if (!OperatingSystem.IsWindows())
    {
        return;
    }

    const string key = "sk-local-dpapi-roundtrip-secret";
    var protectedValue = SecretProtector.Protect(key);
    True(!protectedValue.Contains(key, StringComparison.Ordinal), "DPAPI ciphertext contains plaintext key");
    True(SecretProtector.TryUnprotect(protectedValue, out var recovered), "DPAPI ciphertext could not be decrypted");
    Equal(key, recovered, "DPAPI roundtrip changed the key");
    True(!SecretProtector.TryUnprotect(protectedValue + "broken", out _), "tampered DPAPI ciphertext was accepted");

    var configuration = new AiTranslationConfiguration
    {
        OpenAiApiKey = key,
        OpenAiModel = "gpt-test",
        MicrosoftApiKey = "microsoft-" + key,
        MicrosoftRegion = "eastus2",
    };
    var stored = AiSettingsPersistence.Save(configuration, rememberApiKeys: true);
    var json = System.Text.Json.JsonSerializer.Serialize(stored);
    True(!json.Contains(key, StringComparison.Ordinal), "settings JSON contains a plaintext API key");
    var loaded = AiSettingsPersistence.Load(stored, out var hadUnreadableSecret);
    True(!hadUnreadableSecret, "valid DPAPI ciphertext was reported unreadable");
    Equal(key, loaded.OpenAiApiKey, "saved OpenAI key did not roundtrip");
    Equal("microsoft-" + key, loaded.MicrosoftApiKey, "saved Microsoft key did not roundtrip");
    Equal("eastus2", loaded.MicrosoftRegion, "saved Microsoft region did not roundtrip");

    stored.ProtectedOpenAiApiKey += "broken";
    var unreadable = AiSettingsPersistence.Load(stored, out hadUnreadableSecret);
    True(hadUnreadableSecret, "tampered saved key was not reported unreadable");
    Equal(string.Empty, unreadable.OpenAiApiKey, "tampered saved key entered the runtime configuration");
    Equal(string.Empty, stored.ProtectedOpenAiApiKey, "tampered saved key was left behind for repeated warnings");

    var sessionOnly = AiSettingsPersistence.Save(configuration, rememberApiKeys: false);
    Equal(string.Empty, sessionOnly.ProtectedOpenAiApiKey, "session-only key was persisted");
    Equal(string.Empty, sessionOnly.ProtectedMicrosoftApiKey, "session-only Microsoft key was persisted");
}

static void CheckEmbeddedScriptEnvironmentCleanupContract()
{
    var script = System.Text.Encoding.UTF8.GetString(EmbeddedConverterScript.ReadEmbeddedBytesForChecks());
    var functionStart = script.IndexOf("function Clear-TranslationProcessEnvironment", StringComparison.Ordinal);
    var functionEnd = script.IndexOf("function Resolve-TranslationServiceUrl", functionStart, StringComparison.Ordinal);
    True(functionStart >= 0 && functionEnd > functionStart, "environment cleanup function was not found");
    var functionText = script[functionStart..functionEnd];
    foreach (var name in AiTranslationEnvironment.SupportedVariableNames)
    {
        True(functionText.Contains("'" + name + "'", StringComparison.Ordinal),
            $"PowerShell cleanup list is missing {name}");
    }

    var settingsCall = script.LastIndexOf("$lyricsTranslationSettings = Resolve-LyricsTranslationSettings", StringComparison.Ordinal);
    var cleanupCall = script.LastIndexOf("    Clear-TranslationProcessEnvironment", StringComparison.Ordinal);
    var inputResolution = script.LastIndexOf("$BinPath = Resolve-ExistingFile", StringComparison.Ordinal);
    True(settingsCall >= 0 && cleanupCall > settingsCall && inputResolution > cleanupCall,
        "translation environment cleanup must run immediately after settings resolution and before conversion work");
}

static void CheckWindowsPowerShellWrapper()
{
    var options = FullOptions();
    var arguments = ConverterCommand.BuildWindowsPowerShellArguments(
        @"C:\repo's folder\bin_to_audio_windows.ps1",
        options);
    Equal("-Command", arguments[^2], "Windows PowerShell must use a UTF-8 command wrapper");
    var command = arguments[^1];

    True(command.Contains("[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)", StringComparison.Ordinal),
        "UTF-8 input setup missing");
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

static void CheckConversionProgressParsing()
{
    True(ConversionProgressParser.TryParse(
        "Converting track 3/16 -> 03 - title.flac",
        out var trackProgress), "valid track progress was not parsed");
    Equal(ConversionProgressKind.TrackStarted, trackProgress!.Kind, "track event kind differs");
    Equal(3, trackProgress.Current, "track current differs");
    Equal(16, trackProgress.Total, "track total differs");
    Equal("03 - title.flac", trackProgress.Detail, "track detail differs");

    True(ConversionProgressParser.TryParse(
        "Verifying track 3/16 -> 03 - title.flac",
        out var verificationProgress), "valid verification progress was not parsed");
    Equal(ConversionProgressKind.TrackVerificationStarted, verificationProgress!.Kind,
        "verification-start event kind differs");
    Equal(3, verificationProgress.Current, "verification current differs");
    Equal(16, verificationProgress.Total, "verification total differs");
    Equal("03 - title.flac", verificationProgress.Detail, "verification detail differs");

    True(ConversionProgressParser.TryParse(
        "Verified track 3/16: lossless PCM SHA-256 match",
        out var verifiedProgress), "valid verified progress was not parsed");
    Equal(ConversionProgressKind.TrackVerified, verifiedProgress!.Kind,
        "verified event kind differs");
    Equal(3, verifiedProgress.Current, "verified current differs");
    Equal(16, verifiedProgress.Total, "verified total differs");

    True(ConversionProgressParser.TryParse("Tracks:      16", out var trackCount),
        "track count was not parsed");
    Equal(ConversionProgressKind.TrackCount, trackCount!.Kind, "track-count event kind differs");
    Equal(16, trackCount.Total, "track count differs");

    True(ConversionProgressParser.TryParse(
        "Lyrics 03: synced bilingual (Chinese translation) (NetEase)",
        out var lyricsProgress), "lyrics progress was not parsed");
    Equal(ConversionProgressKind.Lyrics, lyricsProgress!.Kind, "lyrics event kind differs");
    Equal(3, lyricsProgress.Current, "lyrics track differs");

    True(ConversionProgressParser.TryParse(
        "Trying cover source: Cover Art Archive release",
        out var coverProgress), "cover progress was not parsed");
    Equal(ConversionProgressKind.Cover, coverProgress!.Kind, "cover event kind differs");
    Equal("Cover Art Archive release", coverProgress.Detail, "cover source differs");

    True(ConversionProgressParser.TryParse(
        "MusicBrainz Disc ID: example",
        out var metadataProgress), "metadata progress was not parsed");
    Equal(ConversionProgressKind.Metadata, metadataProgress!.Kind, "metadata event kind differs");

    foreach (var invalid in new[]
             {
                 "Converting track 0/16 -> x.flac",
                 "Converting track 17/16 -> x.flac",
                 "Converting track 1/0 -> x.flac",
                 "WARNING: Converting track 1/16 -> x.flac",
                 "Converting track 1/16",
                 "Verifying track 0/16 -> x.flac",
                 "Verifying track 17/16 -> x.flac",
                 "Verified track 0/16: lossless PCM SHA-256 match",
                 "Verified track 17/16: lossless PCM SHA-256 match",
                 "Verified track 1/16: hash mismatch",
                 string.Empty,
             })
    {
        True(!ConversionProgressParser.TryParse(invalid, out _), $"invalid progress was accepted: {invalid}");
    }
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

static void CheckEmbeddedScriptExtraction()
{
    var root = Path.Combine(Path.GetTempPath(), "CdromDumpToolsGuiEmbedded-" + Guid.NewGuid().ToString("N"));
    try
    {
        var embeddedBytes = EmbeddedConverterScript.ReadEmbeddedBytesForChecks();
        True(embeddedBytes.Length >= 3
             && embeddedBytes[0] == 0xEF
             && embeddedBytes[1] == 0xBB
             && embeddedBytes[2] == 0xBF,
            "embedded PowerShell bytes lost their UTF-8 BOM");

        var extractedPath = EmbeddedConverterScript.EnsureExtractedUnder(root);
        Equal(EmbeddedConverterScript.EmbeddedSha256ForChecks,
            Directory.GetParent(extractedPath)?.Name,
            "version directory is not the embedded-content SHA-256");
        True(embeddedBytes.SequenceEqual(File.ReadAllBytes(extractedPath)),
            "extracted bytes differ from the embedded resource");

        File.WriteAllBytes(extractedPath, new byte[] { 0x62, 0x61, 0x64 });
        var repairedPath = EmbeddedConverterScript.EnsureExtractedUnder(root);
        Equal(extractedPath, repairedPath, "repair changed the versioned script path");
        True(embeddedBytes.SequenceEqual(File.ReadAllBytes(repairedPath)),
            "a tampered extracted script was not repaired from the embedded bytes");
        True(!Directory.EnumerateFiles(Path.GetDirectoryName(repairedPath)!, "*.tmp").Any(),
            "atomic extraction left a temporary file behind");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void CheckConcurrentEmbeddedScriptExtraction()
{
    var root = Path.Combine(Path.GetTempPath(), "CdromDumpToolsGuiConcurrent-" + Guid.NewGuid().ToString("N"));
    try
    {
        var paths = new string[16];
        Parallel.For(0, paths.Length, index =>
        {
            paths[index] = EmbeddedConverterScript.EnsureExtractedUnder(root);
        });

        Equal(1, paths.Distinct(StringComparer.OrdinalIgnoreCase).Count(),
            "concurrent extraction returned multiple version paths");
        True(EmbeddedConverterScript.ReadEmbeddedBytesForChecks().SequenceEqual(File.ReadAllBytes(paths[0])),
            "concurrent extraction did not leave the expected script bytes");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void CheckVerifiedExecutionLease()
{
    var root = Path.Combine(Path.GetTempPath(), "CdromDumpToolsGuiLease-" + Guid.NewGuid().ToString("N"));
    try
    {
        string path;
        using (var lease = EmbeddedConverterScript.AcquireVerifiedExecutionLeaseUnder(root))
        {
            path = lease.ScriptPath;
            True(EmbeddedConverterScript.ReadEmbeddedBytesForChecks().SequenceEqual(File.ReadAllBytes(path)),
                "lease did not verify the embedded script bytes");

            var writeWasBlocked = false;
            try
            {
                using var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                writeWasBlocked = true;
            }
            True(writeWasBlocked, "verified execution lease did not block a writer");

            var deleteWasBlocked = false;
            try
            {
                File.Delete(path);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                deleteWasBlocked = true;
            }
            True(deleteWasBlocked && File.Exists(path),
                "verified execution lease did not block deletion");
        }

        File.WriteAllBytes(path, new byte[] { 0x62, 0x61, 0x64 });
        using var repairedLease = EmbeddedConverterScript.AcquireVerifiedExecutionLeaseUnder(root);
        True(EmbeddedConverterScript.ReadEmbeddedBytesForChecks().SequenceEqual(File.ReadAllBytes(repairedLease.ScriptPath)),
            "lease acquisition did not repair and verify a modified script");
    }
    finally
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

static void CheckElevationPolicy()
{
    True(ElevationGuard.ShouldRefuseInteractiveLaunch(isSelfTest: false, isElevated: true),
        "an elevated interactive launch must be refused");
    True(!ElevationGuard.ShouldRefuseInteractiveLaunch(isSelfTest: false, isElevated: false),
        "a normal asInvoker launch must remain allowed");
    True(!ElevationGuard.ShouldRefuseInteractiveLaunch(isSelfTest: true, isElevated: true),
        "the hidden CI self-test must remain usable under an elevated runner");

    if (OperatingSystem.IsWindows())
    {
        _ = ElevationGuard.IsCurrentProcessElevated();
    }
}

static void CheckEnvironmentFileResolution()
{
    var root = Path.Combine(Path.GetTempPath(), "CdromDumpToolsGuiEnv-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
        Equal(null, EnvironmentFileResolver.Resolve(null, root),
            "missing adjacent .env should leave EnvPath empty");

        var adjacent = Path.Combine(root, ".env");
        File.WriteAllText(adjacent, "LYRICS_TRANSLATION_FALLBACK=None");
        Equal(Path.GetFullPath(adjacent), EnvironmentFileResolver.Resolve(null, root),
            "adjacent .env was not selected explicitly");

        var configured = Path.Combine(root, "configured.env");
        Equal(configured, EnvironmentFileResolver.Resolve("  " + configured + "  ", root),
            "an explicit .env path must override the adjacent file");
    }
    finally
    {
        Directory.Delete(root, recursive: true);
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

static void ExpectArgumentException(Action action)
{
    try
    {
        action();
    }
    catch (ArgumentException)
    {
        return;
    }
    throw new InvalidOperationException("expected ArgumentException was not thrown");
}

static void Equal<T>(T expected, T actual, string message)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{message}; expected <{expected}>, actual <{actual}>");
    }
}
