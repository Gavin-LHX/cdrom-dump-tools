[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $BinPath,

    [ValidateSet('flac', 'wav')]
    [string] $Format = 'flac',

    [string] $TocPath,

    [string] $OutputDirectory,

    [string] $FfmpegPath,

    [switch] $NoMetadata,

    [switch] $NoCover,

    [switch] $NoLyrics,

    [ValidateRange(0, 1000)]
    [int] $ReleaseIndex = 0,

    [string] $MusicBrainzUserAgent = 'BinToAudioWindows/2.1 (https://github.com/Gavin-LHX/cdrom-dump-tools)'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$workDirectory = $null

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        return $item.FullName
    }

    throw "$Description is not a file: $Path"
}

function Convert-TocPositionToBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if ($Value -match '^(\d+):(\d{2}):(\d{2})$') {
        [int64] $minutes = $Matches[1]
        [int64] $seconds = $Matches[2]
        [int64] $frames = $Matches[3]
        if ($seconds -ge 60 -or $frames -ge 75) {
            throw "Invalid TOC MSF position: $Value"
        }

        [int64] $sectors = ($minutes * 60 * 75) + ($seconds * 75) + $frames
        return $sectors * 2352
    }

    if ($Value -match '^\d+$') {
        [int64] $samples = $Value
        return $samples * 4
    }

    throw "Unsupported TOC position: $Value"
}

function Get-ObjectProperty {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-ArtistCreditText {
    param([object] $ArtistCredit)

    if ($null -eq $ArtistCredit) {
        return $null
    }

    $parts = foreach ($entry in @($ArtistCredit)) {
        $name = Get-ObjectProperty -Object $entry -Name 'name'
        $joinPhrase = Get-ObjectProperty -Object $entry -Name 'joinphrase'
        if ($null -ne $name) {
            '{0}{1}' -f $name, $joinPhrase
        }
    }

    return ($parts -join '')
}

function Get-MusicBrainzDiscIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[hashtable]] $Tracks,

        [Parameter(Mandatory = $true)]
        [int64] $BinLength
    )

    if (($BinLength % 2352) -ne 0) {
        throw 'BIN length is not aligned to CD-DA sectors; MusicBrainz Disc ID cannot be calculated.'
    }

    $trackOffsets = [System.Collections.Generic.List[int64]]::new()
    foreach ($track in $Tracks) {
        if (($track.OffsetBytes % 2352) -ne 0) {
            throw "Track $($track.Number) is not aligned to CD-DA sectors; MusicBrainz Disc ID cannot be calculated."
        }
        $trackOffsets.Add(($track.OffsetBytes / 2352) + 150)
    }

    [int64] $leadout = ($BinLength / 2352) + 150
    $hashText = ('{0:X2}{1:X2}{2:X8}' -f 1, $Tracks.Count, $leadout)
    for ($trackNumber = 1; $trackNumber -le 99; $trackNumber++) {
        [int64] $offset = 0
        if ($trackNumber -le $trackOffsets.Count) {
            $offset = $trackOffsets[$trackNumber - 1]
        }
        $hashText += ('{0:X8}' -f $offset)
    }

    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $digest = $sha1.ComputeHash([Text.Encoding]::ASCII.GetBytes($hashText))
    }
    finally {
        $sha1.Dispose()
    }

    $discId = [Convert]::ToBase64String($digest).Replace('+', '.').Replace('/', '_').Replace('=', '-')
    $tocValues = @('1', [string] $Tracks.Count, [string] $leadout) + ($trackOffsets | ForEach-Object { [string] $_ })

    return [pscustomobject]@{
        DiscId = $discId
        Toc    = $tocValues -join ' '
    }
}

function Invoke-JsonRequestWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [hashtable] $Headers,

        [string] $CachePath,

        [ValidateRange(1, 10)]
        [int] $MaximumAttempts = 5,

        [string] $SourceName = 'Metadata service'
    )

    if (-not [string]::IsNullOrWhiteSpace($CachePath) -and (Test-Path -LiteralPath $CachePath)) {
        $cacheItem = Get-Item -LiteralPath $CachePath
        if ($cacheItem.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-30)) {
            Write-Host "Using cached $SourceName metadata."
            return ([IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
        }
    }

    $lastException = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 30 -MaximumRedirection 8 -UseBasicParsing
            if ($response.Content -is [byte[]]) {
                $json = [Text.Encoding]::UTF8.GetString($response.Content)
            }
            else {
                $json = [string] $response.Content
            }
            if ([string]::IsNullOrWhiteSpace($json)) {
                throw 'The metadata server returned an empty response.'
            }

            $parsed = $json | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($CachePath)) {
                $cacheParent = Split-Path -Parent $CachePath
                if (-not (Test-Path -LiteralPath $cacheParent)) {
                    $null = New-Item -ItemType Directory -Path $cacheParent -Force
                }
                [IO.File]::WriteAllText($CachePath, $json, [Text.UTF8Encoding]::new($false))
            }
            return $parsed
        }
        catch {
            $lastException = $_.Exception
            if ($attempt -lt $MaximumAttempts) {
                $delaySeconds = [Math]::Min(16, [Math]::Pow(2, $attempt))
                Write-Warning "$SourceName request failed (attempt $attempt/$MaximumAttempts): $($lastException.Message)"
                Write-Host "Retrying in $delaySeconds seconds..."
                Start-Sleep -Seconds $delaySeconds
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CachePath) -and (Test-Path -LiteralPath $CachePath)) {
        Write-Warning "$SourceName is unavailable; using stale cached metadata."
        return ([IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }

    throw $lastException
}

function Invoke-FileDownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [hashtable] $Headers,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [ValidateRange(1, 10)]
        [int] $MaximumAttempts = 3
    )

    $lastException = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 30 -MaximumRedirection 8 -UseBasicParsing -OutFile $Destination
            if ((Get-Item -LiteralPath $Destination).Length -le 0) {
                throw 'The download was empty.'
            }
            return
        }
        catch {
            $lastException = $_.Exception
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt)))
            }
        }
    }

    throw $lastException
}

function ConvertTo-SafeFileName {
    param(
        [string] $Name,
        [ValidateRange(20, 220)]
        [int] $MaximumLength = 160
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $safeName = [regex]::Replace($Name, '[\x00-\x1F<>:"/\\|?*]', '_')
    $safeName = [regex]::Replace($safeName, '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($safeName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        $safeName = "_$safeName"
    }
    if ($safeName.Length -gt $MaximumLength) {
        $safeName = $safeName.Substring(0, $MaximumLength).TrimEnd('.', ' ')
    }

    return $safeName
}

function Normalize-MatchText {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $normalized = $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $normalized = [regex]::Replace($normalized, '\p{Mn}', '')
    return [regex]::Replace($normalized, '[\W_]', '')
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string] $Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    }
    finally {
        $sha256.Dispose()
    }
    return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-JsonCacheText {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Json
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    [IO.File]::WriteAllText($Path, $Json, [Text.UTF8Encoding]::new($false))
}

function Invoke-LrcLibJsonRequest {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][hashtable] $Headers,
        [Parameter(Mandatory = $true)][string] $CachePath,
        [ValidateRange(1, 5)][int] $MaximumAttempts = 3
    )

    $staleCache = $null
    if (Test-Path -LiteralPath $CachePath) {
        try {
            $staleCache = [IO.File]::ReadAllText($CachePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ((Get-Item -LiteralPath $CachePath).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-30)) {
                if ((Get-ObjectProperty -Object $staleCache -Name '_not_found') -eq $true) {
                    return $null
                }
                return $staleCache
            }
        }
        catch {
            $staleCache = $null
        }
    }

    $lastException = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 35 -MaximumRedirection 8 -UseBasicParsing
            if ($response.Content -is [byte[]]) {
                $json = [Text.Encoding]::UTF8.GetString($response.Content)
            }
            else {
                $json = [string] $response.Content
            }
            if ([string]::IsNullOrWhiteSpace($json)) {
                throw 'LRCLIB returned an empty response.'
            }
            $parsed = $json | ConvertFrom-Json
            Write-JsonCacheText -Path $CachePath -Json $json
            return $parsed
        }
        catch {
            $lastException = $_.Exception
            $statusCode = 0
            $retryAfter = 0
            if ($null -ne $lastException.Response) {
                try { $statusCode = [int] $lastException.Response.StatusCode } catch { $statusCode = 0 }
                try { [int]::TryParse([string] $lastException.Response.Headers['Retry-After'], [ref] $retryAfter) | Out-Null } catch { $retryAfter = 0 }
            }

            if ($statusCode -eq 404) {
                Write-JsonCacheText -Path $CachePath -Json '{"_not_found":true}'
                return $null
            }
            if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin @(408, 429)) {
                break
            }
            if ($attempt -lt $MaximumAttempts) {
                if ($statusCode -eq 429 -and $retryAfter -gt 0) {
                    $delaySeconds = [Math]::Min(60, $retryAfter)
                }
                else {
                    $delaySeconds = [Math]::Min(8, [Math]::Pow(2, $attempt))
                }
                Write-Warning "LRCLIB request failed (attempt $attempt/$MaximumAttempts): $($lastException.Message)"
                Start-Sleep -Seconds $delaySeconds
            }
        }
    }

    if ($null -ne $staleCache -and (Get-ObjectProperty -Object $staleCache -Name '_not_found') -ne $true) {
        Write-Warning 'LRCLIB is unavailable; using stale cached lyrics.'
        return $staleCache
    }
    throw $lastException
}

function Convert-LrcToPlainText {
    param([string] $SyncedLyrics)

    if ([string]::IsNullOrWhiteSpace($SyncedLyrics)) {
        return $null
    }
    $plainLines = foreach ($line in ($SyncedLyrics -split '\r?\n')) {
        if ($line -match '^\[(?:ar|al|ti|by|offset|re|ve|length):') {
            continue
        }
        $plainLine = [regex]::Replace($line, '^(?:\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\])+\s*', '')
        if (-not [string]::IsNullOrWhiteSpace($plainLine)) {
            $plainLine
        }
    }
    if (@($plainLines).Count -eq 0) {
        return $null
    }
    return (@($plainLines) -join [Environment]::NewLine)
}

function Get-LocalLyrics {
    param(
        [Parameter(Mandatory = $true)][string] $SourceDirectory,
        [Parameter(Mandatory = $true)][int] $TrackNumber,
        [string] $Title
    )

    $safeTitle = ConvertTo-SafeFileName $Title
    $baseNames = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($safeTitle)) {
        $baseNames.Add(('{0:D2} - {1}' -f $TrackNumber, $safeTitle))
        $baseNames.Add($safeTitle)
    }
    $baseNames.Add(('track-{0:D2}' -f $TrackNumber))
    $baseNames.Add(('{0:D2}' -f $TrackNumber))

    $directories = @($SourceDirectory, (Join-Path $SourceDirectory 'lyrics'))
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in $directories) {
        foreach ($baseName in $baseNames) {
            foreach ($extension in @('.lrc', '.txt')) {
                $candidate = Join-Path $directory ($baseName + $extension)
                if (-not $seen.Add($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    continue
                }
                $content = [IO.File]::ReadAllText($candidate, [Text.Encoding]::UTF8)
                if ([string]::IsNullOrWhiteSpace($content)) {
                    continue
                }
                if ($extension -eq '.lrc') {
                    return [pscustomobject]@{
                        PlainLyrics  = Convert-LrcToPlainText $content
                        SyncedLyrics = $content.Trim()
                        Instrumental = $false
                        Source       = "Local file: $([IO.Path]::GetFileName($candidate))"
                        Id           = $null
                    }
                }
                return [pscustomobject]@{
                    PlainLyrics  = $content.Trim()
                    SyncedLyrics = $null
                    Instrumental = $false
                    Source       = "Local file: $([IO.Path]::GetFileName($candidate))"
                    Id           = $null
                }
            }
        }
    }
    return $null
}

function Resolve-LrcLibLyrics {
    param(
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][string] $Artist,
        [Parameter(Mandatory = $true)][string] $Album,
        [Parameter(Mandatory = $true)][int] $DurationSeconds,
        [Parameter(Mandatory = $true)][string] $CacheRoot,
        [Parameter(Mandatory = $true)][hashtable] $Headers
    )

    $signature = "$Artist|$Title|$Album|$DurationSeconds"
    $cacheKey = Get-Sha256Text $signature
    $query = 'artist_name={0}&track_name={1}&album_name={2}&duration={3}' -f [Uri]::EscapeDataString($Artist), [Uri]::EscapeDataString($Title), [Uri]::EscapeDataString($Album), $DurationSeconds
    Start-Sleep -Milliseconds 350
    $exact = Invoke-LrcLibJsonRequest -Uri "https://lrclib.net/api/get?$query" -Headers $Headers -CachePath (Join-Path $CacheRoot "exact-$cacheKey.json")
    if ($null -ne $exact) {
        return [pscustomobject]@{
            PlainLyrics  = Get-ObjectProperty -Object $exact -Name 'plainLyrics'
            SyncedLyrics = Get-ObjectProperty -Object $exact -Name 'syncedLyrics'
            Instrumental = (Get-ObjectProperty -Object $exact -Name 'instrumental') -eq $true
            Source       = 'LRCLIB exact match'
            Id           = Get-ObjectProperty -Object $exact -Name 'id'
        }
    }

    $searchQuery = 'track_name={0}&artist_name={1}&album_name={2}' -f [Uri]::EscapeDataString($Title), [Uri]::EscapeDataString($Artist), [Uri]::EscapeDataString($Album)
    Start-Sleep -Milliseconds 350
    $searchResults = @(Invoke-LrcLibJsonRequest -Uri "https://lrclib.net/api/search?$searchQuery" -Headers $Headers -CachePath (Join-Path $CacheRoot "search-$cacheKey.json"))
    $expectedTitle = Normalize-MatchText $Title
    $expectedArtist = Normalize-MatchText $Artist
    $expectedAlbum = Normalize-MatchText $Album
    $best = $null
    $bestScore = 0
    foreach ($candidate in $searchResults) {
        $candidateTitle = Normalize-MatchText ([string](Get-ObjectProperty -Object $candidate -Name 'trackName'))
        $candidateArtist = Normalize-MatchText ([string](Get-ObjectProperty -Object $candidate -Name 'artistName'))
        $candidateAlbum = Normalize-MatchText ([string](Get-ObjectProperty -Object $candidate -Name 'albumName'))
        $candidateDuration = Get-ObjectProperty -Object $candidate -Name 'duration'
        $score = 0
        if ($candidateTitle -eq $expectedTitle -and $candidateTitle -ne '') { $score += 60 }
        elseif ($candidateTitle -ne '' -and ($candidateTitle.Contains($expectedTitle) -or $expectedTitle.Contains($candidateTitle))) { $score += 30 }
        if ($candidateArtist -eq $expectedArtist -and $candidateArtist -ne '') { $score += 30 }
        elseif ($candidateArtist -ne '' -and ($candidateArtist.Contains($expectedArtist) -or $expectedArtist.Contains($candidateArtist))) { $score += 15 }
        if ($candidateAlbum -eq $expectedAlbum -and $candidateAlbum -ne '') { $score += 15 }
        if ($null -ne $candidateDuration) {
            $durationDifference = [Math]::Abs([double] $candidateDuration - $DurationSeconds)
            if ($durationDifference -le 2) { $score += 30 }
            elseif ($durationDifference -le 5) { $score += 10 }
        }
        if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty -Object $candidate -Name 'syncedLyrics'))) { $score += 5 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $candidate
        }
    }
    if ($null -eq $best -or $bestScore -lt 85) {
        return $null
    }
    return [pscustomobject]@{
        PlainLyrics  = Get-ObjectProperty -Object $best -Name 'plainLyrics'
        SyncedLyrics = Get-ObjectProperty -Object $best -Name 'syncedLyrics'
        Instrumental = (Get-ObjectProperty -Object $best -Name 'instrumental') -eq $true
        Source       = "LRCLIB search match (score $bestScore)"
        Id           = Get-ObjectProperty -Object $best -Name 'id'
    }
}

function ConvertTo-IsoDate {
    param([object] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [DateTime]) {
        return $Value.ToString('yyyy-MM-dd')
    }

    $text = [string] $Value
    if ($text -match '^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?') {
        if ($null -ne $Matches[3] -and $Matches[3] -ne '') {
            return '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3]
        }
        if ($null -ne $Matches[2] -and $Matches[2] -ne '') {
            return '{0}-{1}' -f $Matches[1], $Matches[2]
        }
        return $Matches[1]
    }

    [DateTime] $parsedDate = [DateTime]::MinValue
    if ([DateTime]::TryParse($text, [ref] $parsedDate)) {
        return $parsedDate.ToString('yyyy-MM-dd')
    }
    return $null
}

function Get-YearFromDate {
    param([object] $Value)

    $date = ConvertTo-IsoDate $Value
    if ($null -ne $date -and $date -match '^(\d{4})') {
        return $Matches[1]
    }
    return $null
}

function Resolve-MetadataEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]] $Evidence
    )

    $yearScores = @{}
    $genreScores = @{}
    $genreDisplay = @{}

    foreach ($entry in $Evidence) {
        $sourceWeight = [int](Get-ObjectProperty -Object $entry -Name 'weight')
        $sourceYear = [string](Get-ObjectProperty -Object $entry -Name 'year')
        if ($sourceYear -match '^\d{4}$') {
            if (-not $yearScores.ContainsKey($sourceYear)) {
                $yearScores[$sourceYear] = 0
            }
            $yearScores[$sourceYear] += $sourceWeight
        }

        foreach ($genre in @(Get-ObjectProperty -Object $entry -Name 'genres')) {
            if ([string]::IsNullOrWhiteSpace([string] $genre)) {
                continue
            }
            $genreKey = Normalize-MatchText ([string] $genre)
            switch ($genreKey) {
                'electronicmusic' { $genreKey = 'electronic' }
                'hiphoprap'       { $genreKey = 'hiphop' }
                'rhythmandblues'  { $genreKey = 'rnb' }
            }
            if ($genreKey -eq '') {
                continue
            }
            if (-not $genreScores.ContainsKey($genreKey)) {
                $genreScores[$genreKey] = 0
                $genreDisplay[$genreKey] = [string] $genre
            }
            $genreScores[$genreKey] += $sourceWeight
        }
    }

    $resolvedYear = $null
    $rankedYears = @($yearScores.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
    if ($rankedYears.Count -gt 0) {
        $resolvedYear = [string] $rankedYears[0].Name
    }

    $resolvedGenres = [System.Collections.Generic.List[string]]::new()
    $rankedGenres = @($genreScores.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
    if ($rankedGenres.Count -gt 0) {
        $minimumScore = [Math]::Ceiling([double] $rankedGenres[0].Value * 0.70)
        foreach ($rankedGenre in $rankedGenres) {
            if ($rankedGenre.Value -lt $minimumScore -or $resolvedGenres.Count -ge 3) {
                continue
            }
            $resolvedGenres.Add([string] $genreDisplay[$rankedGenre.Name])
        }
    }

    return [pscustomobject]@{
        year         = $resolvedYear
        genres       = @($resolvedGenres)
        year_scores  = $yearScores
        genre_scores = $genreScores
    }
}

try {
    $BinPath = Resolve-ExistingFile -Path $BinPath -Description 'BIN path'
    if ([IO.Path]::GetExtension($BinPath) -ine '.bin') {
        throw "Input file must have a .bin extension: $BinPath"
    }

    if ([string]::IsNullOrWhiteSpace($TocPath)) {
        $TocPath = [IO.Path]::ChangeExtension($BinPath, '.toc')
    }
    $TocPath = Resolve-ExistingFile -Path $TocPath -Description 'TOC path'

    if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
        $ffmpegCommand = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
        if ($null -ne $ffmpegCommand) {
            $FfmpegPath = $ffmpegCommand.Source
        }
        elseif (Test-Path -LiteralPath 'D:\Apps\FFmpeg-8.1.2\bin\ffmpeg.exe') {
            $FfmpegPath = 'D:\Apps\FFmpeg-8.1.2\bin\ffmpeg.exe'
        }
        else {
            throw 'ffmpeg.exe was not found. Pass its location with -FfmpegPath.'
        }
    }
    else {
        $FfmpegPath = Resolve-ExistingFile -Path $FfmpegPath -Description 'FFmpeg path'
    }

    $binItem = Get-Item -LiteralPath $BinPath
    $discName = [IO.Path]::GetFileNameWithoutExtension($binItem.Name)
    $usingDefaultOutput = [string]::IsNullOrWhiteSpace($OutputDirectory)
    if ($usingDefaultOutput) {
        $OutputDirectory = Join-Path $binItem.DirectoryName "$discName-$Format"
    }
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

    $tracks = [System.Collections.Generic.List[hashtable]]::new()
    $currentTrack = $null

    foreach ($line in [IO.File]::ReadLines($TocPath)) {
        if ($line -match '^\s*TRACK\s+(\S+)') {
            $trackType = $Matches[1]
            if ($trackType -cne 'AUDIO') {
                throw "TOC contains a non-audio track ($trackType). This tool only converts CD-DA audio."
            }

            $currentTrack = @{
                Number     = $tracks.Count + 1
                Isrc       = $null
                File       = $null
                StartSpec  = $null
                LengthSpec = $null
                OffsetBytes = [int64] 0
                LengthBytes = [int64] 0
                Title       = $null
                Artist      = $null
                RecordingId = $null
                TrackId     = $null
                PlainLyrics = $null
                SyncedLyrics = $null
                LyricsSource = $null
                LyricsId     = $null
                LyricsInstrumental = $false
            }
            $tracks.Add($currentTrack)
            continue
        }

        if ($null -ne $currentTrack -and $line -match '^\s*ISRC\s+"([^"]+)"') {
            $currentTrack.Isrc = $Matches[1]
            continue
        }

        if ($line -match '^\s*(?:FILE|AUDIOFILE)\s+"([^"]+)"\s+(\S+)(?:\s+(\S+))?') {
            if ($null -eq $currentTrack) {
                throw 'TOC contains FILE data before the first TRACK.'
            }
            if ($null -ne $currentTrack.StartSpec) {
                throw "Track $($currentTrack.Number) uses multiple source segments, which is not supported."
            }

            $currentTrack.File = $Matches[1]
            $currentTrack.StartSpec = $Matches[2]
            $currentTrack.LengthSpec = $Matches[3]
        }
    }

    if ($tracks.Count -eq 0) {
        throw "No audio tracks were found in $TocPath"
    }

    [int64] $binLength = $binItem.Length
    foreach ($track in $tracks) {
        if ([string]::IsNullOrWhiteSpace($track.StartSpec)) {
            throw "Track $($track.Number) has no FILE entry."
        }

        [int64] $track.OffsetBytes = Convert-TocPositionToBytes $track.StartSpec
        if ([string]::IsNullOrWhiteSpace($track.LengthSpec)) {
            [int64] $track.LengthBytes = $binLength - $track.OffsetBytes
        }
        else {
            [int64] $track.LengthBytes = Convert-TocPositionToBytes $track.LengthSpec
        }

        if ($track.OffsetBytes -lt 0 -or $track.LengthBytes -le 0) {
            throw "Track $($track.Number) has an invalid byte range."
        }
        if (($track.OffsetBytes + $track.LengthBytes) -gt $binLength) {
            throw "Track $($track.Number) extends beyond the end of the BIN file."
        }
        if (($track.OffsetBytes % 4) -ne 0 -or ($track.LengthBytes % 4) -ne 0) {
            throw "Track $($track.Number) is not aligned to 16-bit stereo samples."
        }
    }

    $discIdentity = $null
    $metadataMatched = $false
    $selectedRelease = $null
    $selectedMedium = $null
    $albumTitle = $null
    $albumArtist = $null
    $releaseDate = $null
    $releaseCountry = $null
    $releaseBarcode = $null
    $releaseId = $null
    $releaseGroupId = $null
    $discNumber = 1
    $discTotal = 1
    $releaseYear = $null
    $resolvedDate = $null
    $resolvedGenres = @()
    $metadataEvidence = [System.Collections.Generic.List[object]]::new()
    $cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BinToAudioWindows'

    if (-not $NoMetadata) {
        try {
            $discIdentity = Get-MusicBrainzDiscIdentity -Tracks $tracks -BinLength $binLength
            Write-Host "MusicBrainz Disc ID: $($discIdentity.DiscId)"

            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $headers = @{
                'User-Agent' = $MusicBrainzUserAgent
                'Accept'     = 'application/json'
            }
            $encodedToc = [Uri]::EscapeDataString($discIdentity.Toc)
            $lookupUri = "https://musicbrainz.org/ws/2/discid/$($discIdentity.DiscId)?inc=recordings%2Bartist-credits%2Brelease-groups%2Bisrcs&toc=$encodedToc&cdstubs=no&fmt=json"
            $metadataCachePath = Join-Path $cacheRoot "MusicBrainz\$($discIdentity.DiscId).json"
            try {
                $lookup = Invoke-JsonRequestWithRetry -Uri $lookupUri -Headers $headers -CachePath $metadataCachePath -MaximumAttempts 3 -SourceName 'MusicBrainz'
            }
            catch {
                Write-Warning 'Primary MusicBrainz endpoint is unavailable; trying the musicbrainz.eu mirror.'
                $mirrorLookupUri = $lookupUri.Replace('https://musicbrainz.org/', 'https://musicbrainz.eu/')
                $lookup = Invoke-JsonRequestWithRetry -Uri $mirrorLookupUri -Headers $headers -CachePath $metadataCachePath -MaximumAttempts 3 -SourceName 'MusicBrainz mirror'
            }

            $candidates = [System.Collections.Generic.List[object]]::new()
            foreach ($release in @(Get-ObjectProperty -Object $lookup -Name 'releases')) {
                foreach ($medium in @(Get-ObjectProperty -Object $release -Name 'media')) {
                    $mediumTracks = @(Get-ObjectProperty -Object $medium -Name 'tracks')
                    if ($mediumTracks.Count -eq $tracks.Count) {
                        $candidates.Add([pscustomobject]@{
                            Release = $release
                            Medium  = $medium
                        })
                    }
                }
            }

            if ($candidates.Count -eq 0) {
                Write-Warning 'MusicBrainz did not return a release with a matching track count. Basic TOC/ISRC tags will be used.'
            }
            else {
                [int] $selectedIndex = 1
                if ($ReleaseIndex -gt 0) {
                    if ($ReleaseIndex -le $candidates.Count) {
                        $selectedIndex = $ReleaseIndex
                    }
                    else {
                        Write-Warning "ReleaseIndex $ReleaseIndex is out of range; selecting release 1."
                    }
                }
                elseif ($candidates.Count -gt 1) {
                    Write-Host 'Multiple MusicBrainz releases match this disc:'
                    for ($index = 0; $index -lt $candidates.Count; $index++) {
                        $candidateRelease = $candidates[$index].Release
                        $candidateMedium = $candidates[$index].Medium
                        $candidateArtist = Get-ArtistCreditText (Get-ObjectProperty -Object $candidateRelease -Name 'artist-credit')
                        $candidateTitle = Get-ObjectProperty -Object $candidateRelease -Name 'title'
                        $candidateDate = Get-ObjectProperty -Object $candidateRelease -Name 'date'
                        $candidateCountry = Get-ObjectProperty -Object $candidateRelease -Name 'country'
                        $candidateDisc = Get-ObjectProperty -Object $candidateMedium -Name 'position'
                        Write-Host ('  [{0}] {1} - {2} ({3}, {4}, disc {5})' -f ($index + 1), $candidateArtist, $candidateTitle, $candidateDate, $candidateCountry, $candidateDisc)
                    }

                    if (-not [Console]::IsInputRedirected) {
                        $answer = Read-Host 'Select release [1]'
                        if (-not [string]::IsNullOrWhiteSpace($answer)) {
                            [int] $parsedIndex = 0
                            if ([int]::TryParse($answer, [ref] $parsedIndex) -and $parsedIndex -ge 1 -and $parsedIndex -le $candidates.Count) {
                                $selectedIndex = $parsedIndex
                            }
                            else {
                                Write-Warning 'Invalid selection; selecting release 1.'
                            }
                        }
                    }
                    else {
                        Write-Warning 'Input is redirected; selecting release 1. Use -ReleaseIndex to choose another match.'
                    }
                }

                $selectedRelease = $candidates[$selectedIndex - 1].Release
                $selectedMedium = $candidates[$selectedIndex - 1].Medium
                $metadataMatched = $true

                $albumTitle = Get-ObjectProperty -Object $selectedRelease -Name 'title'
                $albumArtist = Get-ArtistCreditText (Get-ObjectProperty -Object $selectedRelease -Name 'artist-credit')
                $releaseDate = Get-ObjectProperty -Object $selectedRelease -Name 'date'
                $releaseCountry = Get-ObjectProperty -Object $selectedRelease -Name 'country'
                $releaseBarcode = Get-ObjectProperty -Object $selectedRelease -Name 'barcode'
                $releaseId = Get-ObjectProperty -Object $selectedRelease -Name 'id'
                $releaseGroup = Get-ObjectProperty -Object $selectedRelease -Name 'release-group'
                $releaseGroupId = Get-ObjectProperty -Object $releaseGroup -Name 'id'
                $mediumPosition = Get-ObjectProperty -Object $selectedMedium -Name 'position'
                if ($null -ne $mediumPosition) {
                    $discNumber = [int] $mediumPosition
                }
                $allMedia = @(Get-ObjectProperty -Object $selectedRelease -Name 'media')
                if ($allMedia.Count -gt 0) {
                    $discTotal = $allMedia.Count
                }

                $metadataTracks = @( @(Get-ObjectProperty -Object $selectedMedium -Name 'tracks') |
                    Sort-Object { [int](Get-ObjectProperty -Object $_ -Name 'position') } )
                for ($index = 0; $index -lt $tracks.Count; $index++) {
                    $metadataTrack = $metadataTracks[$index]
                    $recording = Get-ObjectProperty -Object $metadataTrack -Name 'recording'
                    $trackTitle = Get-ObjectProperty -Object $metadataTrack -Name 'title'
                    if ([string]::IsNullOrWhiteSpace($trackTitle)) {
                        $trackTitle = Get-ObjectProperty -Object $recording -Name 'title'
                    }
                    $trackCredit = Get-ObjectProperty -Object $metadataTrack -Name 'artist-credit'
                    if ($null -eq $trackCredit) {
                        $trackCredit = Get-ObjectProperty -Object $recording -Name 'artist-credit'
                    }

                    $tracks[$index].Title = $trackTitle
                    $tracks[$index].Artist = Get-ArtistCreditText $trackCredit
                    $tracks[$index].TrackId = Get-ObjectProperty -Object $metadataTrack -Name 'id'
                    $tracks[$index].RecordingId = Get-ObjectProperty -Object $recording -Name 'id'

                    if ([string]::IsNullOrWhiteSpace($tracks[$index].Isrc)) {
                        $recordingIsrcs = @(Get-ObjectProperty -Object $recording -Name 'isrcs')
                        if ($recordingIsrcs.Count -gt 0) {
                            $tracks[$index].Isrc = [string] $recordingIsrcs[0]
                        }
                    }
                }

                $musicBrainzGenres = @()
                $musicBrainzGroupDate = $null
                if (-not [string]::IsNullOrWhiteSpace($releaseGroupId)) {
                    try {
                        Start-Sleep -Milliseconds 1100
                        $releaseGroupUri = "https://musicbrainz.org/ws/2/release-group/$releaseGroupId`?inc=genres&fmt=json"
                        $releaseGroupCachePath = Join-Path $cacheRoot "MusicBrainz\release-group-$releaseGroupId.json"
                        try {
                            $releaseGroupData = Invoke-JsonRequestWithRetry -Uri $releaseGroupUri -Headers $headers -CachePath $releaseGroupCachePath -MaximumAttempts 3 -SourceName 'MusicBrainz genres'
                        }
                        catch {
                            $mirrorReleaseGroupUri = $releaseGroupUri.Replace('https://musicbrainz.org/', 'https://musicbrainz.eu/')
                            $releaseGroupData = Invoke-JsonRequestWithRetry -Uri $mirrorReleaseGroupUri -Headers $headers -CachePath $releaseGroupCachePath -MaximumAttempts 3 -SourceName 'MusicBrainz genres mirror'
                        }
                        $musicBrainzGroupDate = ConvertTo-IsoDate (Get-ObjectProperty -Object $releaseGroupData -Name 'first-release-date')
                        $genreItems = @(Get-ObjectProperty -Object $releaseGroupData -Name 'genres') |
                            Sort-Object { [int](Get-ObjectProperty -Object $_ -Name 'count') } -Descending
                        $musicBrainzGenres = @($genreItems | Select-Object -First 5 | ForEach-Object {
                            Get-ObjectProperty -Object $_ -Name 'name'
                        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
                    }
                    catch {
                        Write-Warning "MusicBrainz genre lookup failed: $($_.Exception.Message)"
                    }
                }

                $musicBrainzDate = ConvertTo-IsoDate $releaseDate
                if ($null -eq $musicBrainzDate) {
                    $musicBrainzDate = $musicBrainzGroupDate
                }
                $metadataEvidence.Add([pscustomobject]@{
                    source     = 'MusicBrainz'
                    weight     = 100
                    date       = $musicBrainzDate
                    year       = Get-YearFromDate $musicBrainzDate
                    genres     = @($musicBrainzGenres)
                    match      = 'Disc ID and TOC'
                    identifier = $releaseId
                })

                try {
                    $appleSearchTerm = [Uri]::EscapeDataString("$albumArtist $albumTitle")
                    $appleUri = "https://itunes.apple.com/search?term=$appleSearchTerm&media=music&entity=album&limit=25&country=US"
                    $appleCachePath = Join-Path $cacheRoot "Apple\$releaseId.json"
                    $appleData = Invoke-JsonRequestWithRetry -Uri $appleUri -Headers $headers -CachePath $appleCachePath -MaximumAttempts 3 -SourceName 'Apple iTunes Search'

                    $expectedAlbum = Normalize-MatchText $albumTitle
                    $expectedArtist = Normalize-MatchText $albumArtist
                    $bestAppleResult = $null
                    $bestAppleScore = 0
                    foreach ($appleResult in @(Get-ObjectProperty -Object $appleData -Name 'results')) {
                        $candidateAlbum = Normalize-MatchText ([string](Get-ObjectProperty -Object $appleResult -Name 'collectionName'))
                        $candidateArtist = Normalize-MatchText ([string](Get-ObjectProperty -Object $appleResult -Name 'artistName'))
                        $candidateTrackCount = Get-ObjectProperty -Object $appleResult -Name 'trackCount'
                        $score = 0
                        if ($candidateAlbum -eq $expectedAlbum -and $candidateAlbum -ne '') {
                            $score += 60
                        }
                        elseif ($candidateAlbum -ne '' -and $expectedAlbum -ne '' -and ($candidateAlbum.Contains($expectedAlbum) -or $expectedAlbum.Contains($candidateAlbum))) {
                            $score += 30
                        }
                        if ($candidateArtist -eq $expectedArtist -and $candidateArtist -ne '') {
                            $score += 30
                        }
                        elseif ($candidateArtist -ne '' -and $expectedArtist -ne '' -and ($candidateArtist.Contains($expectedArtist) -or $expectedArtist.Contains($candidateArtist))) {
                            $score += 15
                        }
                        if ($null -ne $candidateTrackCount -and [int] $candidateTrackCount -eq $tracks.Count) {
                            $score += 10
                        }
                        if ($score -gt $bestAppleScore) {
                            $bestAppleScore = $score
                            $bestAppleResult = $appleResult
                        }
                    }

                    if ($null -ne $bestAppleResult -and $bestAppleScore -ge 70) {
                        $appleDate = ConvertTo-IsoDate (Get-ObjectProperty -Object $bestAppleResult -Name 'releaseDate')
                        $appleGenre = Get-ObjectProperty -Object $bestAppleResult -Name 'primaryGenreName'
                        $metadataEvidence.Add([pscustomobject]@{
                            source     = 'Apple iTunes Search'
                            weight     = [Math]::Min(90, $bestAppleScore)
                            date       = $appleDate
                            year       = Get-YearFromDate $appleDate
                            genres     = @($appleGenre)
                            match      = "Album/artist/track-count score $bestAppleScore"
                            identifier = Get-ObjectProperty -Object $bestAppleResult -Name 'collectionId'
                        })
                    }
                    else {
                        Write-Host 'Apple did not return a sufficiently confident album match.'
                    }
                }
                catch {
                    Write-Warning "Apple metadata lookup failed: $($_.Exception.Message)"
                }

                if (-not [string]::IsNullOrWhiteSpace($releaseGroupId)) {
                    try {
                        $sparql = "SELECT ?item ?date ?genreLabel WHERE { ?item wdt:P436 `"$releaseGroupId`". OPTIONAL { ?item wdt:P577 ?date. } OPTIONAL { ?item wdt:P136 ?genre. } SERVICE wikibase:label { bd:serviceParam wikibase:language `"en,zh`". } }"
                        $wikidataUri = "https://query.wikidata.org/sparql?query=$([Uri]::EscapeDataString($sparql))&format=json"
                        $wikidataHeaders = @{
                            'User-Agent' = $MusicBrainzUserAgent
                            'Accept'     = 'application/sparql-results+json'
                        }
                        $wikidataCachePath = Join-Path $cacheRoot "Wikidata\$releaseGroupId.json"
                        $wikidataData = Invoke-JsonRequestWithRetry -Uri $wikidataUri -Headers $wikidataHeaders -CachePath $wikidataCachePath -MaximumAttempts 3 -SourceName 'Wikidata'
                        $wikidataResults = Get-ObjectProperty -Object $wikidataData -Name 'results'
                        $wikidataBindings = @(Get-ObjectProperty -Object $wikidataResults -Name 'bindings')
                        if ($wikidataBindings.Count -gt 0) {
                            $wikidataDates = @($wikidataBindings | ForEach-Object {
                                $dateBinding = Get-ObjectProperty -Object $_ -Name 'date'
                                ConvertTo-IsoDate (Get-ObjectProperty -Object $dateBinding -Name 'value')
                            } | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } | Select-Object -Unique)
                            $wikidataGenres = @($wikidataBindings | ForEach-Object {
                                $genreBinding = Get-ObjectProperty -Object $_ -Name 'genreLabel'
                                Get-ObjectProperty -Object $genreBinding -Name 'value'
                            } | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } | Select-Object -Unique)
                            $itemBinding = Get-ObjectProperty -Object $wikidataBindings[0] -Name 'item'
                            $metadataEvidence.Add([pscustomobject]@{
                                source     = 'Wikidata'
                                weight     = 80
                                date       = if ($wikidataDates.Count -gt 0) { $wikidataDates[0] } else { $null }
                                year       = if ($wikidataDates.Count -gt 0) { Get-YearFromDate $wikidataDates[0] } else { $null }
                                genres     = @($wikidataGenres)
                                match      = 'MusicBrainz release-group ID (P436)'
                                identifier = Get-ObjectProperty -Object $itemBinding -Name 'value'
                            })
                        }
                    }
                    catch {
                        Write-Warning "Wikidata lookup failed: $($_.Exception.Message)"
                    }
                }

                $resolution = Resolve-MetadataEvidence -Evidence $metadataEvidence
                $releaseYear = $resolution.year
                $resolvedGenres = @($resolution.genres)
                $resolvedDate = $musicBrainzDate
                if (-not [string]::IsNullOrWhiteSpace($releaseYear) -and (Get-YearFromDate $resolvedDate) -ne $releaseYear) {
                    $supportingDates = @($metadataEvidence | Where-Object { $_.year -eq $releaseYear -and -not [string]::IsNullOrWhiteSpace([string] $_.date) } |
                        Sort-Object weight -Descending)
                    if ($supportingDates.Count -gt 0) {
                        $resolvedDate = $supportingDates[0].date
                    }
                }

                Write-Host "Matched release: $albumArtist - $albumTitle ($releaseDate, $releaseCountry)"
                Write-Host "Resolved year:  $releaseYear"
                if ($resolvedGenres.Count -gt 0) {
                    Write-Host "Resolved genre: $($resolvedGenres -join '; ')"
                }
                else {
                    Write-Warning 'No reliable genre was returned by the metadata sources.'
                }
            }
        }
        catch {
            $metadataMatched = $false
            Write-Warning "Online metadata lookup failed: $($_.Exception.Message)"
            Write-Warning 'Conversion will continue with basic TOC/ISRC tags.'
        }
    }

    if ($usingDefaultOutput -and $metadataMatched -and -not [string]::IsNullOrWhiteSpace($albumTitle)) {
        if ([string]::IsNullOrWhiteSpace($albumArtist)) {
            $albumFolderBase = $albumTitle
        }
        else {
            $albumFolderBase = "$albumArtist - $albumTitle"
        }
        if (-not [string]::IsNullOrWhiteSpace($releaseYear)) {
            $albumFolderBase += " ($releaseYear)"
        }
        $albumFolderBase += " [$($Format.ToUpperInvariant())]"
        $safeAlbumFolderName = ConvertTo-SafeFileName -Name $albumFolderBase -MaximumLength 190
        if (-not [string]::IsNullOrWhiteSpace($safeAlbumFolderName)) {
            $OutputDirectory = Join-Path $binItem.DirectoryName $safeAlbumFolderName
        }
    }

    if ($usingDefaultOutput -and (Test-Path -LiteralPath $OutputDirectory)) {
        $baseOutputDirectory = $OutputDirectory
        $suffix = 2
        do {
            $OutputDirectory = "$baseOutputDirectory-$suffix"
            $suffix++
        } while (Test-Path -LiteralPath $OutputDirectory)
    }

    if (Test-Path -LiteralPath $OutputDirectory) {
        throw "Output directory already exists: $OutputDirectory"
    }

    $outputParent = Split-Path -Parent $OutputDirectory
    if (-not (Test-Path -LiteralPath $outputParent)) {
        $null = New-Item -ItemType Directory -Path $outputParent -Force
    }
    $outputParent = (Resolve-Path -LiteralPath $outputParent).Path
    $outputName = Split-Path -Leaf $OutputDirectory
    $workName = ".$outputName.partial.$([guid]::NewGuid().ToString('N'))"
    $workDirectory = Join-Path $outputParent $workName
    $null = New-Item -ItemType Directory -Path $workDirectory

    $lyricsManifest = [System.Collections.Generic.List[object]]::new()
    if (-not $NoLyrics) {
        $lyricsCacheRoot = Join-Path $cacheRoot 'Lyrics\LRCLIB'
        $lyricsHeaders = @{
            'User-Agent' = 'BinToAudioWindows/2.1 (https://github.com/Gavin-LHX/cdrom-dump-tools)'
            'Accept'     = 'application/json'
        }
        $lyricsFound = 0
        $instrumentalTracks = 0
        $lyricsOnlineAvailable = $true
        foreach ($track in $tracks) {
            $lyricsResult = Get-LocalLyrics -SourceDirectory $binItem.DirectoryName -TrackNumber $track.Number -Title $track.Title
            $lookupArtist = if (-not [string]::IsNullOrWhiteSpace($track.Artist)) { $track.Artist } else { $albumArtist }
            if ($null -eq $lyricsResult -and $lyricsOnlineAvailable -and $metadataMatched -and
                -not [string]::IsNullOrWhiteSpace($track.Title) -and
                -not [string]::IsNullOrWhiteSpace($lookupArtist) -and
                -not [string]::IsNullOrWhiteSpace($albumTitle)) {
                try {
                    $durationSeconds = [int] [Math]::Round($track.LengthBytes / 176400.0)
                    $lyricsResult = Resolve-LrcLibLyrics -Title $track.Title -Artist $lookupArtist -Album $albumTitle -DurationSeconds $durationSeconds -CacheRoot $lyricsCacheRoot -Headers $lyricsHeaders
                }
                catch {
                    $lyricsOnlineAvailable = $false
                    Write-Warning "LRCLIB became unavailable; remaining tracks will use local lyrics only. $($_.Exception.Message)"
                }
            }

            if ($null -ne $lyricsResult) {
                $plainLyrics = [string](Get-ObjectProperty -Object $lyricsResult -Name 'PlainLyrics')
                $syncedLyrics = [string](Get-ObjectProperty -Object $lyricsResult -Name 'SyncedLyrics')
                $isInstrumental = (Get-ObjectProperty -Object $lyricsResult -Name 'Instrumental') -eq $true
                if ([string]::IsNullOrWhiteSpace($plainLyrics) -and -not [string]::IsNullOrWhiteSpace($syncedLyrics)) {
                    $plainLyrics = Convert-LrcToPlainText $syncedLyrics
                }
                if (-not $isInstrumental -and [string]::IsNullOrWhiteSpace($plainLyrics) -and [string]::IsNullOrWhiteSpace($syncedLyrics)) {
                    $lyricsResult = $null
                }
                else {
                    $track.PlainLyrics = $plainLyrics
                    $track.SyncedLyrics = $syncedLyrics
                    $track.LyricsSource = Get-ObjectProperty -Object $lyricsResult -Name 'Source'
                    $track.LyricsId = Get-ObjectProperty -Object $lyricsResult -Name 'Id'
                    $track.LyricsInstrumental = $isInstrumental
                    if ($isInstrumental) {
                        $instrumentalTracks++
                        Write-Host ('Lyrics {0:D2}: instrumental ({1})' -f $track.Number, $track.LyricsSource)
                    }
                    else {
                        $lyricsFound++
                        $lyricsKind = if (-not [string]::IsNullOrWhiteSpace($syncedLyrics)) { 'synced' } else { 'plain' }
                        Write-Host ('Lyrics {0:D2}: {1} ({2})' -f $track.Number, $lyricsKind, $track.LyricsSource)
                    }
                }
            }

            $lyricsManifest.Add([pscustomobject]@{
                number       = $track.Number
                title        = $track.Title
                artist       = $track.Artist
                found        = $null -ne $lyricsResult
                synced       = -not [string]::IsNullOrWhiteSpace([string] $track.SyncedLyrics)
                instrumental = $track.LyricsInstrumental
                source       = $track.LyricsSource
                lrclib_id    = $track.LyricsId
            })
        }
        Write-Host "Lyrics:      $lyricsFound found, $instrumentalTracks instrumental, $($tracks.Count - $lyricsFound - $instrumentalTracks) unavailable"
        $lyricsJson = [ordered]@{
            provider = 'LRCLIB with local-file priority'
            tracks   = @($lyricsManifest)
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $workDirectory 'lyrics-metadata.json'), $lyricsJson, [Text.UTF8Encoding]::new($false))
    }

    $coverPath = $null
    if ($metadataMatched) {
        $metadataSummary = [ordered]@{
            source                 = 'MusicBrainz'
            disc_id                = $discIdentity.DiscId
            release_id             = $releaseId
            release_group_id       = $releaseGroupId
            album                  = $albumTitle
            album_artist           = $albumArtist
            date                   = $resolvedDate
            year                   = $releaseYear
            genres                 = @($resolvedGenres)
            country                = $releaseCountry
            barcode                = $releaseBarcode
            disc_number            = $discNumber
            disc_total             = $discTotal
            musicbrainz_release_url = "https://musicbrainz.org/release/$releaseId"
            metadata_sources       = @($metadataEvidence)
            consensus              = $resolution
            tracks                 = @($tracks | ForEach-Object {
                [ordered]@{
                    number       = $_.Number
                    title        = $_.Title
                    artist       = $_.Artist
                    isrc         = $_.Isrc
                    track_id     = $_.TrackId
                    recording_id = $_.RecordingId
                    lyrics_source = $_.LyricsSource
                    lyrics_id     = $_.LyricsId
                    lyrics_synced = -not [string]::IsNullOrWhiteSpace([string] $_.SyncedLyrics)
                    instrumental  = $_.LyricsInstrumental
                }
            })
        }
        $metadataJson = $metadataSummary | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $workDirectory 'musicbrainz-metadata.json'), $metadataJson, [Text.UTF8Encoding]::new($false))

        if (-not $NoCover) {
            $coverUrls = [System.Collections.Generic.List[string]]::new()
            $coverCacheKey = $releaseId
            if (-not [string]::IsNullOrWhiteSpace($releaseId)) {
                $coverUrls.Add("https://coverartarchive.org/release/$releaseId/front-500")
            }
            if (-not [string]::IsNullOrWhiteSpace($releaseGroupId)) {
                $coverUrls.Add("https://coverartarchive.org/release-group/$releaseGroupId/front-500")
                if ([string]::IsNullOrWhiteSpace($coverCacheKey)) {
                    $coverCacheKey = $releaseGroupId
                }
            }

            $candidateCoverPath = Join-Path $workDirectory 'cover.jpg'
            $coverCachePath = $null
            if (-not [string]::IsNullOrWhiteSpace($coverCacheKey)) {
                $coverCachePath = Join-Path $cacheRoot "Cover\$coverCacheKey.jpg"
            }

            if ($null -ne $coverCachePath -and (Test-Path -LiteralPath $coverCachePath)) {
                [IO.File]::Copy($coverCachePath, $candidateCoverPath, $true)
                $coverPath = $candidateCoverPath
                Write-Host 'Using cached cover art.'
            }
            else {
                foreach ($coverUrl in $coverUrls) {
                    try {
                        Invoke-FileDownloadWithRetry -Uri $coverUrl -Headers $headers -Destination $candidateCoverPath
                        $coverPath = $candidateCoverPath
                        if ($null -ne $coverCachePath) {
                            $coverCacheParent = Split-Path -Parent $coverCachePath
                            if (-not (Test-Path -LiteralPath $coverCacheParent)) {
                                $null = New-Item -ItemType Directory -Path $coverCacheParent -Force
                            }
                            [IO.File]::Copy($coverPath, $coverCachePath, $true)
                        }
                        Write-Host 'Cover art downloaded.'
                        break
                    }
                    catch {
                        if (Test-Path -LiteralPath $candidateCoverPath) {
                            Remove-Item -LiteralPath $candidateCoverPath -Force
                        }
                    }
                }
            }

            if ($null -eq $coverPath) {
                Write-Warning 'No cover art was available from the Cover Art Archive.'
            }
            else {
                [IO.File]::Copy($coverPath, (Join-Path $workDirectory 'folder.jpg'), $true)
            }
        }
    }

    Write-Host "BIN:         $BinPath"
    Write-Host "TOC:         $TocPath"
    Write-Host "Format:      $Format"
    Write-Host "Tracks:      $($tracks.Count)"
    Write-Host "Destination: $OutputDirectory"

    $createdFiles = [System.Collections.Generic.List[string]]::new()
    $createdLyricsFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($track in $tracks) {
        $safeTitle = ConvertTo-SafeFileName $track.Title
        if ([string]::IsNullOrWhiteSpace($safeTitle)) {
            $outputFileName = 'track-{0:D2}.{1}' -f $track.Number, $Format
        }
        else {
            $outputFileName = '{0:D2} - {1}.{2}' -f $track.Number, $safeTitle, $Format
        }
        $outputPath = Join-Path $workDirectory $outputFileName
        [int64] $sampleCount = $track.LengthBytes / 4

        $lyricsBaseName = [IO.Path]::GetFileNameWithoutExtension($outputFileName)
        if (-not [string]::IsNullOrWhiteSpace([string] $track.SyncedLyrics)) {
            $lyricsPath = Join-Path $workDirectory ($lyricsBaseName + '.lrc')
            [IO.File]::WriteAllText($lyricsPath, ([string] $track.SyncedLyrics).Trim() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
            $createdLyricsFiles.Add($lyricsPath)
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string] $track.PlainLyrics)) {
            $lyricsPath = Join-Path $workDirectory ($lyricsBaseName + '.txt')
            [IO.File]::WriteAllText($lyricsPath, ([string] $track.PlainLyrics).Trim() + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
            $createdLyricsFiles.Add($lyricsPath)
        }

        Write-Host ("Converting track {0}/{1} -> {2}" -f $track.Number, $tracks.Count, $outputFileName)

        $ffmpegArguments = @(
            '-hide_banner',
            '-loglevel', 'error',
            '-nostdin',
            '-f', 's16be',
            '-ar', '44100',
            '-ac', '2',
            '-skip_initial_bytes', [string] $track.OffsetBytes,
            '-i', $BinPath
        )

        $embedCover = $Format -eq 'flac' -and $null -ne $coverPath
        if ($embedCover) {
            $ffmpegArguments += @('-i', $coverPath)
        }

        $ffmpegArguments += @('-map', '0:a:0')
        if ($embedCover) {
            $ffmpegArguments += @('-map', '1:v:0')
        }
        $ffmpegArguments += @('-af', "atrim=end_sample=$sampleCount,asetpts=PTS-STARTPTS")
        if ($embedCover) {
            $ffmpegArguments += @(
                '-metadata:s:v:0', 'title=Album cover',
                '-metadata:s:v:0', 'comment=Cover (front)'
            )
        }

        $tagValues = [ordered]@{
            'TITLE'                   = $track.Title
            'ARTIST'                  = $track.Artist
            'ALBUM'                   = $albumTitle
            'ALBUMARTIST'             = $albumArtist
            'TRACKNUMBER'             = [string] $track.Number
            'TRACKTOTAL'              = [string] $tracks.Count
            'DISCNUMBER'              = [string] $discNumber
            'DISCTOTAL'               = [string] $discTotal
            'DATE'                    = $resolvedDate
            'YEAR'                    = $releaseYear
            'GENRE'                   = $resolvedGenres -join '; '
            'ISRC'                    = $track.Isrc
            'BARCODE'                 = $releaseBarcode
            'MUSICBRAINZ_RELEASEID'   = $releaseId
            'MUSICBRAINZ_TRACKID'     = $track.TrackId
            'MUSICBRAINZ_RECORDINGID' = $track.RecordingId
            'LYRICS'                  = $track.PlainLyrics
            'SYNCEDLYRICS'            = $track.SyncedLyrics
            'LYRICS_SOURCE'           = $track.LyricsSource
            'LYRICS_STATUS'           = if ($track.LyricsInstrumental) { 'instrumental' } else { $null }
        }
        foreach ($tagName in $tagValues.Keys) {
            $tagValue = $tagValues[$tagName]
            if (-not [string]::IsNullOrWhiteSpace([string] $tagValue)) {
                $ffmpegArguments += @('-metadata', "$tagName=$tagValue")
            }
        }

        if ($Format -eq 'flac') {
            $ffmpegArguments += @('-c:a', 'flac', '-compression_level', '8')
            if ($embedCover) {
                $ffmpegArguments += @('-c:v', 'copy', '-disposition:v:0', 'attached_pic')
            }
        }
        else {
            $ffmpegArguments += @('-c:a', 'pcm_s16le')
        }

        $ffmpegArguments += @('-y', $outputPath)
        & $FfmpegPath @ffmpegArguments
        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg failed while converting track $($track.Number)."
        }

        $createdFiles.Add($outputPath)
    }

    $playlistLines = @('#EXTM3U') + ($createdFiles | ForEach-Object { [IO.Path]::GetFileName($_) })
    [IO.File]::WriteAllLines((Join-Path $workDirectory 'tracks.m3u8'), $playlistLines, [Text.UTF8Encoding]::new($false))

    $checksumLines = foreach ($file in @($createdFiles) + @($createdLyricsFiles)) {
        $hash = Get-FileHash -LiteralPath $file -Algorithm SHA256
        '{0} *{1}' -f $hash.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($file)
    }
    [IO.File]::WriteAllLines((Join-Path $workDirectory 'SHA256SUMS.txt'), $checksumLines, [Text.UTF8Encoding]::new($false))

    Move-Item -LiteralPath $workDirectory -Destination $OutputDirectory
    $workDirectory = $null

    Write-Host "Done. Converted tracks are in: $OutputDirectory"
}
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
}
finally {
    if ($null -ne $workDirectory -and (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
