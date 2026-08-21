[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Because
    )

    if (-not $Condition) {
        throw "Assertion failed: $Because"
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object] $Expected,
        [AllowNull()][object] $Actual,
        [Parameter(Mandatory = $true)][string] $Because
    )

    if ($Expected -is [string] -or $Actual -is [string]) {
        if ([string] $Expected -cne [string] $Actual) {
            throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
        }
        return
    }
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $MessagePattern,
        [Parameter(Mandatory = $true)][string] $Because
    )

    $caught = $null
    try {
        $null = & $Action
    }
    catch {
        $caught = $_.Exception
    }
    if ($null -eq $caught) {
        throw "Assertion failed: $Because. No exception was thrown."
    }
    if ($caught.Message -notmatch $MessagePattern) {
        throw "Assertion failed: $Because. Exception '$($caught.Message)' did not match '$MessagePattern'."
    }
}

function ConvertTo-TestJson {
    param(
        [Parameter(Mandatory = $true)][string] $RequestId,
        [Parameter(Mandatory = $true)][object[]] $Lines,
        [switch] $AddUnexpectedField
    )

    $response = [ordered]@{
        schema     = 'lyrics-zh-hans-v1'
        request_id = $RequestId
        lines      = @($Lines)
    }
    if ($AddUnexpectedField) {
        $response['explanation'] = 'must be rejected'
    }
    return $response | ConvertTo-Json -Depth 8 -Compress
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$mainScriptPath = Join-Path $repositoryRoot 'bin_to_audio_windows.ps1'
if (-not (Test-Path -LiteralPath $mainScriptPath -PathType Leaf)) {
    throw "Main script was not found: $mainScriptPath"
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path $temporaryBase ('cdrom-dump-tools-translation-tests-' + [Guid]::NewGuid().ToString('N'))))
if (-not $temporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe temporary test path: $temporaryRoot"
}
$null = New-Item -ItemType Directory -Path $temporaryRoot

try {
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [Management.Automation.Language.Parser]::ParseFile(
        $mainScriptPath,
        [ref] $tokens,
        [ref] $parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
        throw "Main script has a PowerShell parse error: $($parseErrors[0].Message)"
    }

    # Extract only deterministic helpers. Dot-sourcing the complete converter would
    # execute its mandatory-parameter workflow and could perform network or disk I/O.
    $requiredFunctions = @(
        'Import-DotEnvFile',
        'Get-TranslationConfigurationValue',
        'Clear-TranslationProcessEnvironment',
        'Resolve-TranslationServiceUrl',
        'Get-ObjectProperty',
        'ConvertTo-MatchText',
        'Get-Sha256Text',
        'Convert-LrcToPlainText',
        'Test-SyncedLyricsText',
        'Test-ContainsChineseText',
        'Convert-LrcToTimeline',
        'Format-LrcTimestamp',
        'Test-InstrumentalLyricsPlaceholder',
        'Test-HasSubstantiveLyrics',
        'Merge-SyncedLyricsTranslation',
        'Merge-MachineTranslatedSyncedLyrics',
        'New-OnlineLyricsResult',
        'Resolve-LyricsTranslationSettings',
        'Test-TranslationCreditLine',
        'Test-LikelyChineseLyrics',
        'Test-LyricsResultHasChineseContent',
        'Test-LyricsCandidatesHaveChineseContent',
        'Select-PreferredLyricsCandidate',
        'Get-LyricsTranslationPayload',
        'Get-UniqueLyricsTranslationItems',
        'Split-LyricsTranslationBatches',
        'Test-ObjectPropertySet',
        'ConvertFrom-AiLyricsTranslationResponse',
        'ConvertFrom-LyricsTranslationCache',
        'Assert-LyricsTranslationAlignment',
        'Expand-LyricsTranslations',
        'ConvertTo-TranslatedLyricsText',
        'Get-LyricsTranslationSystemPrompt',
        'Resolve-ChineseLyricsTranslationFallback'
    )
    $functionAsts = @($scriptAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $requiredFunctions -contains $node.Name
    }, $true))
    $foundNames = @($functionAsts | ForEach-Object { $_.Name })
    $missingFunctions = @($requiredFunctions | Where-Object { $_ -notin $foundNames })
    if ($missingFunctions.Count -gt 0) {
        throw "Required pure functions were not found in the main script: $($missingFunctions -join ', ')"
    }
    foreach ($duplicate in @($functionAsts | Group-Object Name | Where-Object { $_.Count -ne 1 })) {
        throw "Expected exactly one definition of '$($duplicate.Name)', found $($duplicate.Count)."
    }

    $helperScriptPath = Join-Path $temporaryRoot 'extracted-translation-functions.ps1'
    $helperSource = @($functionAsts | Sort-Object { $_.Extent.StartOffset } | ForEach-Object {
        $_.Extent.Text
    }) -join "`r`n`r`n"
    [IO.File]::WriteAllText($helperScriptPath, $helperSource, [Text.UTF8Encoding]::new($true))
    . $helperScriptPath

    # .env parsing is intentionally literal: it must not evaluate substitutions,
    # disclose malformed lines, or silently accept invalid variable names.
    $dotenvPath = Join-Path $temporaryRoot '.env'
    $dotenvText = @'
# comment
PLAIN_VALUE=alpha
export DOUBLE_QUOTED="line one\nline two\t\"quoted\""
SINGLE_QUOTED='literal # value'
INLINE_COMMENT=kept # discarded
DANGEROUS=$(Set-Item Env:CDROM_DUMP_TOOLS_TEST_EXECUTED yes)
BAD KEY=do-not-display-this-secret
'@
    [IO.File]::WriteAllText($dotenvPath, $dotenvText, [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('CDROM_DUMP_TOOLS_TEST_EXECUTED', $null, [EnvironmentVariableTarget]::Process)
    $importRecords = @(Import-DotEnvFile -Path $dotenvPath 3>&1)
    $dotenvValues = @($importRecords | Where-Object { $_ -is [Collections.IDictionary] } | Select-Object -Last 1)
    Assert-Equal 1 $dotenvValues.Count 'the parser returns exactly one dictionary'
    $dotenvValues = $dotenvValues[0]
    Assert-Equal 'alpha' $dotenvValues['PLAIN_VALUE'] 'plain .env values are parsed'
    Assert-Equal "line one`nline two`t`"quoted`"" $dotenvValues['DOUBLE_QUOTED'] 'double-quoted escapes are decoded'
    Assert-Equal 'literal # value' $dotenvValues['SINGLE_QUOTED'] 'single-quoted values stay literal'
    Assert-Equal 'kept' $dotenvValues['INLINE_COMMENT'] 'unquoted inline comments are removed'
    Assert-Equal '$(Set-Item Env:CDROM_DUMP_TOOLS_TEST_EXECUTED yes)' $dotenvValues['DANGEROUS'] 'command substitutions remain inert text'
    Assert-True (-not $dotenvValues.ContainsKey('BAD KEY')) 'invalid .env keys are ignored'
    Assert-True ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('CDROM_DUMP_TOOLS_TEST_EXECUTED', [EnvironmentVariableTarget]::Process))) 'the .env parser never executes values'
    $warningText = @($importRecords | Where-Object { $_ -isnot [Collections.IDictionary] } | ForEach-Object { $_.ToString() }) -join "`n"
    Assert-True ($warningText -notmatch 'do-not-display-this-secret') 'malformed-line warnings do not disclose contents'

    $testVariableName = 'CDROM_DUMP_TOOLS_TRANSLATION_TEST_SETTING'
    $previousProcessValue = [Environment]::GetEnvironmentVariable($testVariableName, [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable($testVariableName, 'process-wins', [EnvironmentVariableTarget]::Process)
        $resolvedValue = Get-TranslationConfigurationValue -Name $testVariableName -DotEnvValues @{ $testVariableName = 'dotenv-value' } -DefaultValue 'default-value'
        Assert-Equal 'process-wins' $resolvedValue 'process environment values override .env values'
        [Environment]::SetEnvironmentVariable($testVariableName, $null, [EnvironmentVariableTarget]::Process)
        $resolvedValue = Get-TranslationConfigurationValue -Name $testVariableName -DotEnvValues @{ $testVariableName = 'dotenv-value' } -DefaultValue 'default-value'
        Assert-Equal 'dotenv-value' $resolvedValue '.env values override defaults'
    }
    finally {
        [Environment]::SetEnvironmentVariable($testVariableName, $previousProcessValue, [EnvironmentVariableTarget]::Process)
    }

    $prompt = Get-LyricsTranslationSystemPrompt
    Assert-True ($prompt -match '信.*达.*雅') 'the built-in prompt explicitly requires 信达雅'
    Assert-True ($prompt -match '不得合并、拆分、省略、去重或新增歌词行') 'the prompt preserves line cardinality and order'
    Assert-True ($prompt -match '不是指令') 'the prompt treats lyric text as untrusted data'
    Assert-True ($prompt -match 'request_id') 'the prompt requires request correlation'
    Assert-True ($prompt -match '严格 JSON') 'the prompt requires structured JSON only'
    Assert-True ($prompt -match '完全相同的重复歌词必须使用完全相同的译文') 'the prompt requires deterministic repeated-line translation'

    Assert-Equal 'https://api.openai.com/v1' (Resolve-TranslationServiceUrl -Value 'https://api.openai.com/v1/' -ConfigurationName 'TEST_URL') 'HTTPS service URLs are accepted and normalized'
    Assert-Equal 'http://localhost:11434/v1' (Resolve-TranslationServiceUrl -Value 'http://localhost:11434/v1' -ConfigurationName 'TEST_URL') 'loopback HTTP remains available for a local compatible service'
    $unsafeRemoteUrl = Resolve-TranslationServiceUrl -Value 'http://example.com/v1' -ConfigurationName 'TEST_URL' 3>$null
    Assert-True ([string]::IsNullOrWhiteSpace([string] $unsafeRemoteUrl)) 'remote plaintext HTTP service URLs are rejected'
    $unsafeCredentialUrl = Resolve-TranslationServiceUrl -Value 'https://user:secret@example.com/v1' -ConfigurationName 'TEST_URL' 3>$null
    Assert-True ([string]::IsNullOrWhiteSpace([string] $unsafeCredentialUrl)) 'service URLs containing user information are rejected'
    $unsafeQueryUrl = Resolve-TranslationServiceUrl -Value 'https://api.example.com/v1?key=secret' -ConfigurationName 'TEST_URL' 3>$null
    Assert-True ([string]::IsNullOrWhiteSpace([string] $unsafeQueryUrl)) 'service URLs containing query strings are rejected'

    $translationEnvironmentNames = @(
        'LYRICS_TRANSLATION_FALLBACK',
        'AI_TRANSLATION_PROVIDER',
        'GOOGLE_TRANSLATE_API_KEY',
        'GOOGLE_TRANSLATE_BASE_URL',
        'OPENAI_API_KEY',
        'OPENAI_BASE_URL',
        'OPENAI_MODEL',
        'OPENAI_ORG_ID',
        'OPENAI_PROJECT_ID',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_BASE_URL',
        'ANTHROPIC_MODEL',
        'ANTHROPIC_VERSION',
        'ANTHROPIC_MAX_TOKENS',
        'AI_TRANSLATION_PROMPT_FILE'
    )
    $previousTranslationEnvironment = @{}
    try {
        foreach ($name in $translationEnvironmentNames) {
            $previousTranslationEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        $configuredServices = @{
            GOOGLE_TRANSLATE_API_KEY = 'google-test-key'
            OPENAI_API_KEY           = 'openai-test-key'
            OPENAI_MODEL             = 'openai-test-model'
            ANTHROPIC_API_KEY        = 'anthropic-test-key'
            ANTHROPIC_MODEL          = 'anthropic-test-model'
        }
        $defaultSettings = Resolve-LyricsTranslationSettings `
            -Mode 'Auto' `
            -AiProvider 'Auto' `
            -DotEnvValues $configuredServices `
            -EnvironmentDirectory $temporaryRoot
        Assert-Equal 'AIThenGoogle' $defaultSettings.Mode 'Auto defaults to AI before Google'
        Assert-Equal 'OpenAI,Anthropic,Google' (@($defaultSettings.Providers) -join ',') 'all configured AI formats run before Google'

        $googleOnlySettings = Resolve-LyricsTranslationSettings `
            -Mode 'AIThenGoogle' `
            -AiProvider 'Auto' `
            -DotEnvValues @{ GOOGLE_TRANSLATE_API_KEY = 'google-test-key' } `
            -EnvironmentDirectory $temporaryRoot
        Assert-Equal 'Google' (@($googleOnlySettings.Providers) -join ',') 'AI-first mode falls back to Google when no AI format is configured'

        $legacyOrderSettings = Resolve-LyricsTranslationSettings `
            -Mode 'GoogleThenAI' `
            -AiProvider 'Auto' `
            -DotEnvValues $configuredServices `
            -EnvironmentDirectory $temporaryRoot
        Assert-Equal 'Google,OpenAI,Anthropic' (@($legacyOrderSettings.Providers) -join ',') 'an explicit legacy Google-first order remains supported'

        foreach ($name in $translationEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, 'must-not-reach-ffmpeg', [EnvironmentVariableTarget]::Process)
        }
        Clear-TranslationProcessEnvironment
        foreach ($name in $translationEnvironmentNames) {
            Assert-True ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process))) "resolved translation setting '$name' is removed before child processes start"
        }
    }
    finally {
        foreach ($name in $translationEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $previousTranslationEnvironment[$name], [EnvironmentVariableTarget]::Process)
        }
    }

    Assert-True (Test-LikelyChineseLyrics '抬头望着夜空，我仍在寻找你的声音。') 'substantive simplified Chinese is recognized'
    Assert-True (-not (Test-LikelyChineseLyrics '夜空を見上げて、君の声を探している。')) 'Japanese kanji mixed with kana is not mistaken for Chinese'
    Assert-True (-not (Test-LikelyChineseLyrics '별이 빛나는 밤에 너를 찾고 있어')) 'Korean lyrics are not mistaken for Chinese'
    Assert-True (Test-LikelyChineseLyrics "[00:01.00]抬头望着夜空`n[00:03.00]我仍在寻找你的声音") 'Chinese detection works on timestamped LRC'
    Assert-True (Test-LikelyChineseLyrics "我只能说サヨナラ`n却仍然舍不得离开`n请记住我们的约定") 'a short Japanese word does not hide otherwise Chinese lyrics'
    Assert-True (Test-LikelyChineseLyrics "夜空を見上げて`n仰望着夜空`n君の声を探している`n我仍在寻找你的声音") 'bilingual Japanese and Chinese lyrics are recognized as already translated'
    Assert-True (-not (Test-LikelyChineseLyrics "夢幻世界`n愛情物語`n君を探してる")) 'Japanese lyrics with kanji-only lines remain eligible for translation'
    Assert-True (-not (Test-LikelyChineseLyrics "夢幻世界`n愛情物語")) 'fully kanji Japanese text is not assumed to be Chinese'
    Assert-True (-not (Test-LikelyChineseLyrics "夢幻世界`nHello world")) 'a kanji title embedded in English text is not assumed to be Chinese'
    Assert-True (-not (Test-LikelyChineseLyrics "目的達成`n目的達成")) 'repeated Han characters shared with Japanese do not count as Chinese grammar evidence'
    Assert-True (-not (Test-LikelyChineseLyrics "原点回帰`n終着点`n皇后陛下")) 'Japanese shared glyphs are not treated as simplified-only Chinese evidence'
    Assert-True (-not (Test-LikelyChineseLyrics "都内到着`n被告人着席")) 'multiple Japanese grammar-like Han characters do not imply Chinese'
    Assert-True (-not (Test-LikelyChineseLyrics "再起不能`n不要不急")) 'Japanese compounds shared with Chinese do not imply Chinese'
    Assert-True (Test-LikelyChineseLyrics "风吹麦浪`n梦回故乡") 'short simplified Chinese lyrics are recognized from simplified-only glyphs'
    Assert-True (Test-LikelyChineseLyrics "仰望着夜空`n我仍在寻找你的声音") 'Chinese phrase evidence recognizes lyrics with only one distinctive simplified glyph'
    Assert-True (Test-LikelyChineseLyrics "你好世界`n我在等你") 'modern Chinese-exclusive glyphs identify short Chinese lyrics'
    Assert-True (Test-LikelyChineseLyrics "你好吗`n我想你") 'short conversational Chinese remains recognized'
    Assert-True (Test-LikelyChineseLyrics "春风十里`n山河故人") 'one true simplified glyph can identify otherwise poetic Han-only Chinese'

    $netEaseOriginal = [pscustomobject]@{
        OriginalPlainLyrics = "夜空を見上げて`n君の声を探している"
        PlainLyrics         = "夜空を見上げて`n君の声を探している"
        SyncedLyrics        = $null
        Instrumental       = $false
        Source             = 'NetEase Cloud Music'
    }
    $qqOriginal = [pscustomobject]@{
        OriginalPlainLyrics = "星空を見上げて`n君を待っている"
        PlainLyrics         = "星空を見上げて`n君を待っている"
        SyncedLyrics        = $null
        Instrumental       = $false
        Source             = 'QQ Music'
    }
    $qqChinese = New-OnlineLyricsResult `
        -OriginalLyrics "星空を見上げて`n君を待っている" `
        -TranslatedLyrics "仰望着星空`n我依然在等你" `
        -Source 'QQ Music'
    $lrcLibChinese = [pscustomobject]@{
        PlainLyrics   = "仰望着夜空`n我仍在寻找你的声音"
        SyncedLyrics  = $null
        Instrumental = $false
        Source       = 'LRCLIB exact match'
    }
    $instrumentalCandidate = [pscustomobject]@{
        PlainLyrics   = $null
        SyncedLyrics  = $null
        Instrumental = $true
        Source       = 'NetEase Cloud Music instrumental'
    }

    Assert-True (-not (Test-LyricsCandidatesHaveChineseContent -Candidates @($netEaseOriginal))) 'NetEase original-only lyrics continue to QQ Music'
    Assert-True (-not (Test-LyricsCandidatesHaveChineseContent -Candidates @($netEaseOriginal, $qqOriginal))) 'NetEase and QQ original-only lyrics continue to LRCLIB'
    Assert-True (Test-LyricsCandidatesHaveChineseContent -Candidates @($netEaseOriginal, $qqChinese)) 'QQ Chinese translation stops the source fallback before LRCLIB'
    $qqSelection = Select-PreferredLyricsCandidate -Candidates @($netEaseOriginal, $qqChinese)
    Assert-Equal 'QQ Music' $qqSelection.Lyrics.Source 'QQ Chinese translation wins over an earlier untranslated NetEase original'
    Assert-Equal 'Chinese' $qqSelection.Selection 'the selected QQ result is classified as Chinese'
    $lrcSelection = Select-PreferredLyricsCandidate -Candidates @($netEaseOriginal, $qqOriginal, $lrcLibChinese)
    Assert-Equal 'LRCLIB exact match' $lrcSelection.Lyrics.Source 'Chinese LRCLIB text wins when both domestic sources lack Chinese'
    $originalSelection = Select-PreferredLyricsCandidate -Candidates @($netEaseOriginal, $qqOriginal)
    Assert-Equal 'NetEase Cloud Music' $originalSelection.Lyrics.Source 'the earliest source supplies the machine-translation original when no source has Chinese'
    Assert-Equal 'Original' $originalSelection.Selection 'an untranslated winning candidate is marked for AI and Google fallback'
    $lyricalSelection = Select-PreferredLyricsCandidate -Candidates @($instrumentalCandidate, $qqOriginal)
    Assert-Equal 'QQ Music' $lyricalSelection.Lyrics.Source 'substantive lyrics win over an earlier instrumental marker'

    $script:translationProviderCalls = [System.Collections.Generic.List[string]]::new()
    $script:openAiTranslationShouldFail = $false
    $script:googleTranslationShouldFail = $false
    function Get-CachedLyricsTranslation {
        param($CachePath, $Payload, $Provider, $Model, $ServiceHash, $ContextHash, $PromptHash)
        return $null
    }
    function Save-LyricsTranslationCache {
        param($CachePath, $Payload, $Provider, $Model, $ServiceHash, $ContextHash, $PromptHash, $Translations)
    }
    function New-TestTranslations {
        param([object[]] $Items, [string] $Prefix)

        return @($Items | ForEach-Object {
            [pscustomobject]@{
                Id   = [string] $_.Id
                Text = "$Prefix$($_.Id)"
            }
        })
    }
    function Invoke-OpenAiLyricsTranslation {
        param($Items, $Settings, $Title, $Artist, $Album)
        $script:translationProviderCalls.Add('OpenAI')
        if ($script:openAiTranslationShouldFail) {
            throw 'simulated OpenAI failure'
        }
        return New-TestTranslations -Items @($Items) -Prefix 'AI译文'
    }
    function Invoke-AnthropicLyricsTranslation {
        param($Items, $Settings, $Title, $Artist, $Album)
        $script:translationProviderCalls.Add('Anthropic')
        throw 'Anthropic should not be called in this test'
    }
    function Invoke-GoogleLyricsTranslation {
        param($Items, $Settings)
        $script:translationProviderCalls.Add('Google')
        if ($script:googleTranslationShouldFail) {
            throw 'simulated Google failure'
        }
        return New-TestTranslations -Items @($Items) -Prefix '谷歌译文'
    }

    $fallbackSourceLyrics = [pscustomobject]@{
        OriginalPlainLyrics   = "夜空を見上げて`n君の声を探している"
        PlainLyrics           = "夜空を見上げて`n君の声を探している"
        SyncedLyrics          = $null
        RomanizedPlainLyrics  = "yozora o miagete`nkimi no koe o sagashite iru"
        Instrumental         = $false
        HasChineseTranslation = $false
        Source               = 'NetEase Cloud Music'
        Id                   = 'netease-test-id'
    }
    $fallbackSettings = [pscustomobject]@{
        Providers          = @('OpenAI', 'Google')
        OpenAiModel        = 'openai-test-model'
        OpenAiBaseUrl      = 'https://api.openai.com/v1'
        GoogleEndpoint     = 'https://translation.googleapis.com/language/translate/v2'
        PromptHash         = 'test-prompt-hash'
        GoogleApiKey       = 'google-test-key'
    }
    $translationCacheRoot = Join-Path $temporaryRoot 'translation-cache'

    $script:translationProviderCalls.Clear()
    $script:openAiTranslationShouldFail = $false
    $script:googleTranslationShouldFail = $false
    $aiResolution = Resolve-ChineseLyricsTranslationFallback `
        -LyricsResult $fallbackSourceLyrics `
        -Settings $fallbackSettings `
        -CacheRoot $translationCacheRoot `
        -Title 'Test title' `
        -Artist 'Test artist' `
        -Album 'Test album'
    Assert-True $aiResolution.Applied 'a successful AI translation is applied'
    Assert-Equal 'OpenAI' $aiResolution.Lyrics.TranslationProvider 'AI is the first machine-translation provider'
    Assert-Equal 'OpenAI' (@($script:translationProviderCalls) -join ',') 'Google is not called after AI succeeds'

    $script:translationProviderCalls.Clear()
    $script:openAiTranslationShouldFail = $true
    $script:googleTranslationShouldFail = $false
    $googleResolution = Resolve-ChineseLyricsTranslationFallback `
        -LyricsResult $fallbackSourceLyrics `
        -Settings $fallbackSettings `
        -CacheRoot $translationCacheRoot `
        -Title 'Test title' `
        -Artist 'Test artist' `
        -Album 'Test album' `
        3>$null
    Assert-True $googleResolution.Applied 'Google is applied after AI fails'
    Assert-Equal 'Google' $googleResolution.Lyrics.TranslationProvider 'Google is recorded as the fallback provider'
    Assert-Equal 'OpenAI,Google' (@($script:translationProviderCalls) -join ',') 'machine translation calls AI before Google'

    $script:translationProviderCalls.Clear()
    $script:openAiTranslationShouldFail = $true
    $script:googleTranslationShouldFail = $true
    $failedResolution = Resolve-ChineseLyricsTranslationFallback `
        -LyricsResult $fallbackSourceLyrics `
        -Settings $fallbackSettings `
        -CacheRoot $translationCacheRoot `
        -Title 'Test title' `
        -Artist 'Test artist' `
        -Album 'Test album' `
        3>$null
    Assert-True (-not $failedResolution.Applied) 'all provider failures preserve the source lyrics'
    Assert-Equal 'NetEase Cloud Music' $failedResolution.Lyrics.Source 'all provider failures preserve the original source'
    Assert-Equal 'netease-test-id' $failedResolution.Lyrics.Id 'all provider failures preserve the original source ID'
    Assert-Equal 'OpenAI,Google' (@($script:translationProviderCalls) -join ',') 'all configured fallbacks are attempted in order'

    $creditedJapaneseLyrics = "作词：张三`n作曲：李四`n夜空を見上げて"
    $creditedJapanesePayload = Get-LyricsTranslationPayload -LyricsResult ([pscustomobject]@{
        OriginalSyncedLyrics = $null
        OriginalPlainLyrics  = $creditedJapaneseLyrics
        SyncedLyrics         = $null
        PlainLyrics          = $creditedJapaneseLyrics
    })
    Assert-True (-not $creditedJapanesePayload.AlreadyChinese) 'Chinese credit labels do not make Japanese lyrics look translated'

    $originalLrc = @'
[offset:100]
[00:01.00]夜空を見上げて
[00:02.50]君の声を探している
[00:03.00]夜空を見上げて
'@
    $lyricsResult = [pscustomobject]@{
        OriginalSyncedLyrics = $originalLrc
        OriginalPlainLyrics  = $null
        SyncedLyrics         = $originalLrc
        PlainLyrics          = $null
    }
    $payload = Get-LyricsTranslationPayload -LyricsResult $lyricsResult
    Assert-True ($payload.IsSynced) 'an LRC source creates a synchronized payload'
    Assert-True (-not $payload.AlreadyChinese) 'Japanese LRC remains eligible for translation'
    Assert-Equal 3 $payload.Items.Count 'each substantive LRC line becomes one payload item'
    Assert-Equal 'L000001' $payload.Items[0].Id 'payload ids are stable and sequential'
    Assert-Equal '夜空を見上げて' $payload.Items[0].Text 'timestamps are removed from translation text'
    Assert-Equal ([int64] 1100) ([int64] $payload.Items[0].Milliseconds) 'LRC offset is applied to the first timestamp'
    Assert-Equal ([int64] 2600) ([int64] $payload.Items[1].Milliseconds) 'LRC offset is applied to later timestamps'
    Assert-Equal 64 $payload.SourceHash.Length 'the payload gets a deterministic SHA-256 source hash'

    $uniqueItems = @(Get-UniqueLyricsTranslationItems -Items @($payload.Items))
    Assert-Equal 2 $uniqueItems.Count 'repeated lyric text is translated only once'
    $uniqueTranslations = @(
        [pscustomobject]@{ Id = $uniqueItems[0].Id; Text = '仰望夜空' },
        [pscustomobject]@{ Id = $uniqueItems[1].Id; Text = '寻找你的声音' }
    )
    $expandedTranslations = @(Expand-LyricsTranslations -AllItems @($payload.Items) -UniqueItems $uniqueItems -UniqueTranslations $uniqueTranslations)
    Assert-Equal 3 $expandedTranslations.Count 'unique translations expand back to every original line'
    Assert-Equal 'L000003' $expandedTranslations[2].Id 'expanded translations preserve each original id'
    Assert-Equal '仰望夜空' $expandedTranslations[2].Text 'repeated lyrics receive a byte-identical translation'
    $translatedLrc = ConvertTo-TranslatedLyricsText -Payload $payload -Translations $expandedTranslations
    $expectedTranslatedLrc = @(
        '[00:01.100]仰望夜空',
        '[00:02.600]寻找你的声音',
        '[00:03.100]仰望夜空'
    ) -join [Environment]::NewLine
    Assert-Equal $expectedTranslatedLrc $translatedLrc 'translated LRC is rebuilt on the original adjusted timeline'

    $plainBilingualResult = New-OnlineLyricsResult `
        -OriginalLyrics "first line`nsecond line" `
        -TranslatedLyrics "第一行`n第二行" `
        -Source 'offline-test'
    $plainBilingualLines = @($plainBilingualResult.PlainLyrics -split '\r?\n')
    Assert-Equal 4 $plainBilingualLines.Count 'plain-text translations are appended exactly once'
    Assert-Equal '第一行' $plainBilingualLines[2] 'the first plain-text translation keeps its position'
    Assert-Equal '第二行' $plainBilingualLines[3] 'the second plain-text translation is not duplicated'

    $exactTimestampResult = New-OnlineLyricsResult `
        -OriginalLyrics "[00:01.000]A`n[00:01.900]`n[00:02.000]B" `
        -TranslatedLyrics "[00:01.000]甲`n[00:02.000]乙" `
        -Source 'offline-test' `
        -MachineTranslated $true `
        -ExactTimestampTranslation
    Assert-True ($exactTimestampResult.SyncedLyrics -match '(?m)^\[00:02\.000\]乙\r?$') 'machine translation stays on its exact source timestamp'
    Assert-True ($exactTimestampResult.SyncedLyrics -notmatch '(?m)^\[00:01\.900\]乙\r?$') 'an empty nearby timestamp cannot steal a machine translation line'

    $enhancedTimestampResult = New-OnlineLyricsResult `
        -OriginalLyrics "[ar:Artist]`n[offset:100]`n[00:01.00]<00:01.00>Hello <00:01.50>world" `
        -TranslatedLyrics '[00:01.100]你好世界' `
        -Source 'offline-test' `
        -MachineTranslated $true `
        -ExactTimestampTranslation
    Assert-True ($enhancedTimestampResult.SyncedLyrics -match '(?m)^\[ar:Artist\]\r?$') 'machine translation preserves LRC metadata tags'
    Assert-True ($enhancedTimestampResult.SyncedLyrics -match '(?m)^\[offset:100\]\r?$') 'machine translation preserves the original LRC offset tag'
    Assert-True ($enhancedTimestampResult.SyncedLyrics -match '(?m)^\[00:01\.00\]<00:01\.00>Hello <00:01\.50>world\r?$') 'machine translation preserves enhanced-LRC inline timestamps'
    Assert-True ($enhancedTimestampResult.SyncedLyrics -match '(?m)^\[00:01\.00\]你好世界\r?$') 'the translated line reuses the raw timestamp so the global offset applies exactly once'

    $sameTimestampCreditResult = New-OnlineLyricsResult `
        -OriginalLyrics "[00:01.000]作词：张三`n[00:01.000]Hello" `
        -TranslatedLyrics '[00:01.000]你好' `
        -Source 'offline-test' `
        -MachineTranslated $true `
        -ExactTimestampTranslation
    $sameTimestampCreditLines = @($sameTimestampCreditResult.SyncedLyrics -split '\r?\n')
    Assert-Equal '[00:01.000]作词：张三' $sameTimestampCreditLines[0] 'a credit line remains untouched at a shared timestamp'
    Assert-Equal '[00:01.000]Hello' $sameTimestampCreditLines[1] 'the substantive source line remains after the credit'
    Assert-Equal '[00:01.000]你好' $sameTimestampCreditLines[2] 'the shared-timestamp translation follows the substantive line, not the credit'

    $unchangedTranslationResult = New-OnlineLyricsResult `
        -OriginalLyrics '[00:01.000]Baby' `
        -TranslatedLyrics '[00:01.000]Baby' `
        -Source 'offline-test' `
        -MachineTranslated $true `
        -ExactTimestampTranslation
    Assert-Equal 1 @($unchangedTranslationResult.SyncedLyrics -split '\r?\n').Count 'an unchanged proper name or vocalization is not inserted twice'

    $inconsistentRepeatedTranslations = @(
        [pscustomobject]@{ Id = 'L000001'; Text = '仰望夜空' },
        [pscustomobject]@{ Id = 'L000002'; Text = '寻找你的声音' },
        [pscustomobject]@{ Id = 'L000003'; Text = '看向夜空' }
    )
    Assert-Throws {
        Assert-LyricsTranslationAlignment -Items @($payload.Items) -Translations $inconsistentRepeatedTranslations
    } 'inconsistent translation' 'different translations for a repeated source line are rejected'

    $plainStructureSource = "Hello`n`nWorld"
    $plainStructurePayload = Get-LyricsTranslationPayload -LyricsResult ([pscustomobject]@{
        OriginalSyncedLyrics = $null
        OriginalPlainLyrics  = $plainStructureSource
        SyncedLyrics         = $null
        PlainLyrics          = $plainStructureSource
    })
    $plainStructureTranslations = @(
        [pscustomobject]@{ Id = 'L000001'; Text = '你好' },
        [pscustomobject]@{ Id = 'L000002'; Text = '世界' }
    )
    $plainStructureTranslation = ConvertTo-TranslatedLyricsText -Payload $plainStructurePayload -Translations $plainStructureTranslations
    Assert-Equal ("你好" + [Environment]::NewLine + [Environment]::NewLine + "世界") $plainStructureTranslation 'plain translation preserves empty paragraph slots'

    $expectedAiItems = @(
        [pscustomobject]@{ Id = 'L000001'; Text = '夜空を見上げて' },
        [pscustomobject]@{ Id = 'L000002'; Text = '君の声を探している' }
    )
    $validAiLines = @(
        [ordered]@{ id = 'L000001'; text = '仰望夜空' },
        [ordered]@{ id = 'L000002'; text = '寻找你的声音' }
    )
    $validAiJson = ConvertTo-TestJson -RequestId 'request-123' -Lines $validAiLines
    $validAiTranslations = @(ConvertFrom-AiLyricsTranslationResponse -Content $validAiJson -RequestId 'request-123' -ExpectedItems $expectedAiItems)
    Assert-LyricsTranslationAlignment -Items $expectedAiItems -Translations $validAiTranslations
    Assert-Equal 2 $validAiTranslations.Count 'a strictly aligned AI JSON response is accepted'

    $singleExpectedAiItem = @([pscustomobject]@{ Id = 'L000001'; Text = '夜空を見上げて' })
    $singleValidAiJson = '{"schema":"lyrics-zh-hans-v1","request_id":"single","lines":[{"id":"L000001","text":"仰望夜空"}]}'
    $singleValidAiTranslations = @(ConvertFrom-AiLyricsTranslationResponse -Content $singleValidAiJson -RequestId 'single' -ExpectedItems $singleExpectedAiItem)
    Assert-Equal 1 $singleValidAiTranslations.Count 'a one-element JSON lines array remains valid'
    Assert-Throws {
        ConvertFrom-AiLyricsTranslationResponse `
            -Content '{"schema":"lyrics-zh-hans-v1","request_id":"single","lines":{"id":"L000001","text":"仰望夜空"}}' `
            -RequestId 'single' `
            -ExpectedItems $singleExpectedAiItem
    } 'JSON array' 'a single lines object cannot masquerade as a one-element array'
    Assert-Throws {
        ConvertFrom-AiLyricsTranslationResponse `
            -Content '{"schema":"lyrics-zh-hans-v1","request_id":"single","lines":[{"id":["L000001"],"text":["仰望夜空"]}]}' `
            -RequestId 'single' `
            -ExpectedItems $singleExpectedAiItem
    } 'JSON strings' 'array-valued line ids and text are rejected'

    $validCacheJson = '{"schema":"lyrics-translation-cache-v2","created_utc":"2026-08-19T00:00:00Z","source_hash":"source","provider":"OpenAI","model":"model","service_hash":"service","context_hash":"context","prompt_hash":"prompt","target":"zh-Hans","translations":[{"Id":"L000001","Text":"仰望夜空"}]}'
    $validCachedTranslations = @(ConvertFrom-LyricsTranslationCache -Cache ($validCacheJson | ConvertFrom-Json))
    Assert-Equal 1 $validCachedTranslations.Count 'a strict one-element translation cache array is accepted'
    Assert-Throws {
        $invalidCache = $validCacheJson.Replace('"translations":[{"Id":"L000001","Text":"仰望夜空"}]', '"translations":{"Id":"L000001","Text":"仰望夜空"}') | ConvertFrom-Json
        ConvertFrom-LyricsTranslationCache -Cache $invalidCache
    } 'JSON array' 'a cache translation object cannot masquerade as a one-element array'
    Assert-Throws {
        $invalidCache = $validCacheJson.Replace('"Id":"L000001","Text":"仰望夜空"', '"Id":["L000001"],"Text":["仰望夜空"]') | ConvertFrom-Json
        ConvertFrom-LyricsTranslationCache -Cache $invalidCache
    } 'JSON strings' 'array-valued cache line ids and text are rejected'

    Assert-Throws {
        ConvertFrom-AiLyricsTranslationResponse -Content $validAiJson -RequestId 'wrong-request' -ExpectedItems $expectedAiItems
    } 'request_id' 'a mismatched AI request_id is rejected'

    $shortAiJson = ConvertTo-TestJson -RequestId 'request-123' -Lines @($validAiLines[0])
    Assert-Throws {
        ConvertFrom-AiLyricsTranslationResponse -Content $shortAiJson -RequestId 'request-123' -ExpectedItems $expectedAiItems
    } 'expected 2' 'an AI response with the wrong line count is rejected'

    $wrongIdAiJson = ConvertTo-TestJson -RequestId 'request-123' -Lines @(
        [ordered]@{ id = 'WRONG'; text = '仰望夜空' },
        $validAiLines[1]
    )
    Assert-Throws {
        ConvertFrom-AiLyricsTranslationResponse -Content $wrongIdAiJson -RequestId 'request-123' -ExpectedItems $expectedAiItems
    } 'expected.*L000001' 'an AI response with a changed line id is rejected'

    $newlineAiJson = ConvertTo-TestJson -RequestId 'request-123' -Lines @(
        [ordered]@{ id = 'L000001'; text = "仰望`n夜空" },
        $validAiLines[1]
    )
    $newlineTranslations = @(ConvertFrom-AiLyricsTranslationResponse -Content $newlineAiJson -RequestId 'request-123' -ExpectedItems $expectedAiItems)
    Assert-Throws {
        Assert-LyricsTranslationAlignment -Items $expectedAiItems -Translations $newlineTranslations
    } 'newline' 'an AI translation that embeds a newline is rejected'

    $inlineTimestampTranslations = @(
        [pscustomobject]@{ Id = 'L000001'; Text = '你<00:01.500>好' },
        [pscustomobject]@{ Id = 'L000002'; Text = '寻找你的声音' }
    )
    Assert-Throws {
        Assert-LyricsTranslationAlignment -Items $expectedAiItems -Translations $inlineTimestampTranslations
    } 'LRC timestamp' 'an AI translation cannot inject enhanced-LRC inline timestamps'

    $extraFieldAiJson = ConvertTo-TestJson -RequestId 'request-123' -Lines $validAiLines -AddUnexpectedField
    Assert-Throws {
        ConvertFrom-AiLyricsTranslationResponse -Content $extraFieldAiJson -RequestId 'request-123' -ExpectedItems $expectedAiItems
    } 'unexpected top-level fields' 'unexpected AI JSON fields are rejected'

    $batchItems = @(1..81 | ForEach-Object {
        [pscustomobject]@{ Id = 'L{0:D6}' -f $_; Text = "source line $_" }
    })
    $exactBatch = @(Split-LyricsTranslationBatches -Items @($batchItems[0..79]) -MaximumLines 80 -MaximumCharacters 100000)
    Assert-Equal 1 $exactBatch.Count 'exactly 80 lyric lines fit in one batch'
    Assert-Equal 80 @($exactBatch[0].Items).Count 'the 80-line batch keeps every item'
    $overflowBatches = @(Split-LyricsTranslationBatches -Items $batchItems -MaximumLines 80 -MaximumCharacters 100000)
    Assert-Equal 2 $overflowBatches.Count 'the 81st lyric line starts a second batch'
    Assert-Equal 80 @($overflowBatches[0].Items).Count 'the first overflow batch stops at 80 lines'
    Assert-Equal 1 @($overflowBatches[1].Items).Count 'the second overflow batch contains the boundary item'
    Assert-Equal 'L000081' $overflowBatches[1].Items[0].Id 'batch splitting preserves the 81st line id'

    Assert-Throws {
        Split-LyricsTranslationBatches `
            -Items @([pscustomobject]@{ Id = 'L000001'; Text = ('x' * 4501) }) `
            -MaximumLines 80 `
            -MaximumCharacters 4500
    } 'per-request safety limit' 'one oversized lyric line is rejected before any API call'

    $tooManyPlainLines = @(1..501 | ForEach-Object { "lyric line $_" }) -join "`n"
    Assert-Throws {
        Get-LyricsTranslationPayload -LyricsResult ([pscustomobject]@{
            OriginalSyncedLyrics = $null
            OriginalPlainLyrics  = $tooManyPlainLines
            SyncedLyrics         = $null
            PlainLyrics          = $tooManyPlainLines
        })
    } 'maximum 500' 'an implausibly large lyric is rejected before any API call'

    Write-Host 'Lyrics translation fallback offline tests passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('CDROM_DUMP_TOOLS_TEST_EXECUTED', $null, [EnvironmentVariableTarget]::Process)
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
