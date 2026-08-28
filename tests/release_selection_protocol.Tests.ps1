param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\bin_to_audio_windows.ps1'))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw 'The converter script did not parse before the release-selection test.'
}

$functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Read-GuiReleaseSelection'
}, $true)
if ($null -eq $functionAst) {
    throw 'Read-GuiReleaseSelection was not found in the converter script.'
}
$indexFunctionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Resolve-MusicBrainzReleaseIndex'
}, $true)
if ($null -eq $indexFunctionAst) {
    throw 'Resolve-MusicBrainzReleaseIndex was not found in the converter script.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "CdromReleaseSelection-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $temporaryRoot
$harnessPath = Join-Path $temporaryRoot 'selection-harness.ps1'
try {
$harness = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

function Get-ObjectProperty {
    param([object] $Object, [string] $Name)
    if ($Object -is [Collections.IDictionary]) {
        return $Object[$Name]
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-ArtistCreditText {
    param([object] $ArtistCredit)
    return [string] $ArtistCredit
}

__FUNCTION__
__INDEX_FUNCTION__

if ((Resolve-MusicBrainzReleaseIndex -RequestedIndex 0 -CandidateCount 2) -ne 1 -or
    (Resolve-MusicBrainzReleaseIndex -RequestedIndex 2 -CandidateCount 2) -ne 2) {
    throw 'Valid MusicBrainz release indexes resolved incorrectly.'
}
$indexRejected = $false
try {
    $null = Resolve-MusicBrainzReleaseIndex -RequestedIndex 3 -CandidateCount 2
}
catch [ArgumentOutOfRangeException] {
    $indexRejected = $_.Exception.ParamName -ceq 'ReleaseIndex'
}
if (-not $indexRejected) {
    throw 'An out-of-range forced MusicBrainz release index was not rejected.'
}

$candidates = [System.Collections.Generic.List[object]]::new()
$candidates.Add([pscustomobject]@{
    Release = @{
        'artist-credit' = 'compllege'
        title = 'Phant'
        date = '2024-10-27'
        country = 'JP'
        id = 'release-one'
        barcode = '111'
    }
    Medium = @{ position = 1 }
})
$candidates.Add([pscustomobject]@{
    Release = @{
        'artist-credit' = [string] ([char[]] @(0x30B3, 0x30F3, 0x30D7, 0x30EC, 0x30C3, 0x30B8))
        title = [string] ([char[]] @(0x30D5, 0x30A1, 0x30F3, 0x30C8))
        date = '2016-12-30'
        country = 'JP'
        id = 'release-two'
        barcode = '222'
    }
    Medium = @{ position = 1 }
})

$selected = Read-GuiReleaseSelection -Candidates $candidates
[Console]::Out.WriteLine("SELECTED=$selected")
'@
    $harness = $harness.Replace('__FUNCTION__', $functionAst.Extent.Text)
    $harness = $harness.Replace('__INDEX_FUNCTION__', $indexFunctionAst.Extent.Text)
    [IO.File]::WriteAllText($harnessPath, $harness, [Text.UTF8Encoding]::new($true))

    $powerShellExecutable = if ($PSVersionTable.PSEdition -ceq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    }
    else {
        Join-Path $PSHOME 'powershell.exe'
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellExecutable
    $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$harnessPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $processStarted = $false
    $previousConsoleInputEncoding = [Console]::InputEncoding
    try {
        # Windows PowerShell 5.1 has no ProcessStartInfo.StandardInputEncoding.
        # The protocol response is numeric ASCII, which is also valid UTF-8.
        [Console]::InputEncoding = [Text.Encoding]::ASCII
        if (-not $process.Start()) {
            throw 'The release-selection child process did not start.'
        }
        $processStarted = $true

        $protocolPrefix = 'CDROM_DUMP_TOOLS_RELEASE_SELECTION_V1:'
        $sawProtocol = $false
        $selectedLine = $null
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            $lineTask = $process.StandardOutput.ReadLineAsync()
            $remainingMilliseconds = [Math]::Max(
                1,
                [int] ($deadline - [DateTime]::UtcNow).TotalMilliseconds
            )
            if (-not $lineTask.Wait($remainingMilliseconds)) {
                throw 'Timed out waiting for the release-selection protocol response.'
            }
            $line = $lineTask.Result
            if ($null -eq $line) {
                break
            }
            if ($line.StartsWith($protocolPrefix, [StringComparison]::Ordinal)) {
                $encoded = $line.Substring($protocolPrefix.Length)
                $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
                $payloadResult = ConvertFrom-Json -InputObject $json
                $payload = @($payloadResult)
                $expectedTitle = [string] ([char[]] @(0x30D5, 0x30A1, 0x30F3, 0x30C8))
                $expectedArtist = [string] ([char[]] @(0x30B3, 0x30F3, 0x30D7, 0x30EC, 0x30C3, 0x30B8))
                if ($payload.Count -ne 2 -or
                    $payload[1].title -cne $expectedTitle -or
                    $payload[1].artist -cne $expectedArtist) {
                    throw 'The release candidate payload changed or lost non-ASCII text.'
                }
                $sawProtocol = $true
                $process.StandardInput.WriteLine('2')
                $process.StandardInput.Flush()
            }
            elseif ($line.StartsWith('SELECTED=', [StringComparison]::Ordinal)) {
                $selectedLine = $line
            }
        }
        if (-not $process.WaitForExit(5000)) {
            throw 'Release-selection child process did not exit after receiving the GUI choice.'
        }
        if (-not $standardErrorTask.Wait(5000)) {
            throw 'Timed out while collecting release-selection child-process errors.'
        }
        $standardError = $standardErrorTask.Result
        if ($process.ExitCode -ne 0) {
            throw "Release-selection child process failed with $($process.ExitCode): $standardError"
        }
        if (-not $sawProtocol -or $selectedLine -cne 'SELECTED=2') {
            throw 'The GUI protocol did not return the selected second candidate.'
        }
    }
    finally {
        [Console]::InputEncoding = $previousConsoleInputEncoding
        if ($processStarted -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}

Write-Host 'Release-selection protocol tests passed.'
