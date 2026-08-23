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

    if ([string] $Expected -cne [string] $Actual) {
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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$mainScriptPath = Join-Path $repositoryRoot 'bin_to_audio_windows.ps1'
if (-not (Test-Path -LiteralPath $mainScriptPath -PathType Leaf)) {
    throw "Main script was not found: $mainScriptPath"
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path $temporaryBase ('cdrom-dump-tools-audio-verification-tests-' + [Guid]::NewGuid().ToString('N'))))
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
        'Get-FileSegmentSha256',
        'ConvertFrom-FfmpegHashOutput'
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

    $helperScriptPath = Join-Path $temporaryRoot 'extracted-audio-verification-functions.ps1'
    $helperSource = @($functionAsts | Sort-Object { $_.Extent.StartOffset } | ForEach-Object {
        $_.Extent.Text
    }) -join "`r`n`r`n"
    [IO.File]::WriteAllText($helperScriptPath, $helperSource, [Text.UTF8Encoding]::new($true))
    . $helperScriptPath

    # A segment longer than the helper's 1 MiB buffer exercises incremental hashing.
    $fixtureBytes = [byte[]]::new(1MB + 4096)
    for ($index = 0; $index -lt $fixtureBytes.Length; $index++) {
        $fixtureBytes[$index] = [byte](($index * 31 + 17) % 256)
    }
    $fixturePath = Join-Path $temporaryRoot 'segment fixture.bin'
    [IO.File]::WriteAllBytes($fixturePath, $fixtureBytes)

    [int] $segmentOffset = 37
    [int] $segmentLength = 1MB + 123
    $expectedHasher = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedBytes = $expectedHasher.ComputeHash($fixtureBytes, $segmentOffset, $segmentLength)
    }
    finally {
        $expectedHasher.Dispose()
    }
    $expectedHash = ([BitConverter]::ToString($expectedBytes)).Replace('-', '').ToLowerInvariant()
    $actualHash = Get-FileSegmentSha256 -Path $fixturePath -Offset $segmentOffset -Length $segmentLength
    Assert-Equal $expectedHash $actualHash 'incremental file-segment hashing differs from SHA-256 reference output'
    Assert-True ($actualHash -cmatch '^[0-9a-f]{64}$') 'file-segment hash must be canonical lowercase hexadecimal'

    $fullHasher = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedFullHash = ([BitConverter]::ToString($fullHasher.ComputeHash($fixtureBytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $fullHasher.Dispose()
    }
    Assert-Equal $expectedFullHash (Get-FileSegmentSha256 -Path $fixturePath -Offset 0 -Length $fixtureBytes.Length) 'whole-file segment hashing differs'

    Assert-Throws { Get-FileSegmentSha256 -Path $fixturePath -Offset -1 -Length 1 } 'offset must not be negative' 'negative offsets must be rejected'
    Assert-Throws { Get-FileSegmentSha256 -Path $fixturePath -Offset 0 -Length 0 } 'length must be positive' 'zero-length segments must be rejected'
    Assert-Throws { Get-FileSegmentSha256 -Path (Join-Path $temporaryRoot 'missing.bin') -Offset 0 -Length 1 } 'not found' 'missing files must be rejected'
    Assert-Throws { Get-FileSegmentSha256 -Path $fixturePath -Offset ($fixtureBytes.Length + 1) -Length 1 } 'outside the file' 'offsets beyond EOF must be rejected'
    Assert-Throws { Get-FileSegmentSha256 -Path $fixturePath -Offset ($fixtureBytes.Length - 1) -Length 2 } 'outside the file' 'segments extending beyond EOF must be rejected'

    $uppercaseHash = ('ABCDEF0123456789' * 4)
    $parsedHash = ConvertFrom-FfmpegHashOutput -Output @(
        'ffmpeg diagnostic text that must be ignored',
        "SHA256=$uppercaseHash",
        ''
    )
    Assert-Equal $uppercaseHash.ToLowerInvariant() $parsedHash 'FFmpeg hash parser did not canonicalize its single valid hash'

    Assert-Throws { ConvertFrom-FfmpegHashOutput -Output @('not a hash') } 'returned 0 valid SHA-256 hash lines' 'missing FFmpeg hash lines must be rejected'
    Assert-Throws { ConvertFrom-FfmpegHashOutput -Output @('SHA256=abc123') } 'returned 0 valid SHA-256 hash lines' 'short FFmpeg hashes must be rejected'
    Assert-Throws { ConvertFrom-FfmpegHashOutput -Output @('SHA256=' + ('g' * 64)) } 'returned 0 valid SHA-256 hash lines' 'non-hexadecimal FFmpeg hashes must be rejected'
    $firstDuplicateHashLine = 'SHA256=' + ('0' * 64)
    $secondDuplicateHashLine = 'SHA256=' + ('1' * 64)
    Assert-Throws {
        ConvertFrom-FfmpegHashOutput -Output @($firstDuplicateHashLine, $secondDuplicateHashLine)
    } 'returned 2 valid SHA-256 hash lines' 'ambiguous duplicate FFmpeg hash lines must be rejected'

    Write-Host 'Audio verification pure-function tests passed.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
