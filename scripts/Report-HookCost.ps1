# ---------------------------------------------------------------------------
# Report what each Stop hook costs per event, read from Claude Code's own
# session transcripts.
#
# Claude Code writes one `stop_hook_summary` record per Stop into the session
# .jsonl, with hookInfos[].command and (usually) hookInfos[].durationMs. This
# script turns those records into median / p95 / max per hook plus the number
# of invocations at or past the hook's registered timeout.
#
# READ-ONLY: it reads transcript files and the project's
# .claude\settings.local.json (timeouts only) and prints a table. It never
# writes a file and never prints a command string (they carry absolute paths).
#
# The record is an UNDOCUMENTED client-internal format. Any line that does not
# parse, or lacks hookInfos, is skipped; a missing durationMs is counted, not
# guessed. A shape change degrades to "no data", never to a failure.
#
# Usage:
#   pwsh -NoProfile -File .\scripts\Report-HookCost.ps1 [-ProjectRoot <dir>] [-Newest 3]
#   pwsh -NoProfile -File .\scripts\Report-HookCost.ps1 -TranscriptPath <file.jsonl> [-Json]
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    # The project whose transcripts are read. Defaults to the current directory.
    [string]$ProjectRoot,
    # One explicit transcript file; bypasses the project folder lookup.
    [string]$TranscriptPath,
    # How many of the project's newest .jsonl files to read.
    [ValidateRange(1, 1000)][int]$Newest = 3,
    # Emit the table as JSON instead of text.
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DefaultTimeoutSeconds = 60
$Caveat = 'durations come from an undocumented client field and may be absent'

function Get-SanitizedProjectFolderName {
    param([Parameter(Mandatory = $true)][string]$Root)
    # Observed client rule: every character outside [A-Za-z0-9] becomes '-'.
    return ($Root -replace '[^A-Za-z0-9]', '-')
}

function Get-HookLeafName {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return '(other)' }
    $path = $null
    if ($Command -match '-File\s+"([^"]+)"') { $path = $Matches[1] }
    elseif ($Command -match "-File\s+'([^']+)'") { $path = $Matches[1] }
    elseif ($Command -match '-File\s+(\S+)') { $path = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($path)) { return '(other)' }
    $leaf = @($path -split '[\\/]')[-1]
    $leaf = $leaf -replace '\.ps1$', ''
    if ([string]::IsNullOrWhiteSpace($leaf)) { return '(other)' }
    return $leaf
}

function Get-JsonMember {
    param($Object, [string]$Name)
    if ($null -eq $Object -or -not ($Object -is [psobject])) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# Leaf -> timeout seconds from the project's installed Claude registrations.
# Stop registrations win over the same hook's registration on another event.
function Get-RegisteredTimeouts {
    param([string]$Root)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Root)) { return $map }
    $settingsPath = Join-Path $Root '.claude\settings.local.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return $map }
    try {
        $settings = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch { return $map }
    $hooks = Get-JsonMember $settings 'hooks'
    if ($null -eq $hooks) { return $map }
    $events = @($hooks.PSObject.Properties | Sort-Object { if ($_.Name -eq 'Stop') { 0 } else { 1 } })
    foreach ($event in $events) {
        foreach ($group in @($event.Value)) {
            foreach ($entry in @(Get-JsonMember $group 'hooks')) {
                if ($null -eq $entry) { continue }
                $leaf = Get-HookLeafName -Command ([string](Get-JsonMember $entry 'command'))
                $timeout = Get-JsonMember $entry 'timeout'
                if ($leaf -eq '(other)' -or $map.ContainsKey($leaf) -or $null -eq $timeout) { continue }
                $seconds = 0.0
                if ([double]::TryParse([string]$timeout, [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -and $seconds -gt 0) {
                    $map[$leaf] = $seconds
                }
            }
        }
    }
    return $map
}

# Median: mean of the two middle values for an even count. P95: nearest rank.
function Get-DurationStats {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = [double[]]@($Values | Sort-Object)
    $n = $sorted.Count
    if ($n % 2 -eq 1) { $median = $sorted[($n - 1) / 2] }
    else { $median = ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2 }
    $rank = [int][math]::Ceiling(0.95 * $n)
    if ($rank -lt 1) { $rank = 1 }
    return [pscustomobject]@{ Median = $median; P95 = $sorted[$rank - 1]; Max = $sorted[$n - 1] }
}

# ---- resolve the files -----------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).ProviderPath }
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char]92, [char]47)

$files = @()
if (-not [string]::IsNullOrWhiteSpace($TranscriptPath)) {
    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        Write-Output ('Transcript file not found: ' + $TranscriptPath)
        exit 1
    }
    $files = @((Get-Item -LiteralPath $TranscriptPath).FullName)
}
else {
    $folder = Join-Path (Join-Path $env:USERPROFILE '.claude\projects') (Get-SanitizedProjectFolderName -Root $ProjectRoot)
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Write-Output ('No transcript folder found for ' + $ProjectRoot + ' (looked for ' + $folder + ')')
        exit 0
    }
    $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Newest | ForEach-Object { $_.FullName })
}

# ---- read ----------------------------------------------------------------
$timeouts = Get-RegisteredTimeouts -Root $ProjectRoot
$durations = @{}
$missing = @{}
$recordCount = 0
$skippedLines = 0
foreach ($file in $files) {
    $reader = $null
    $stream = $null
    try {
        # ReadWrite share: the live session's file is still open for writing by the client.
        $stream = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding $false))
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        continue
    }
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.IndexOf('stop_hook_summary', [System.StringComparison]::Ordinal) -lt 0) { continue }
            try { $record = $line | ConvertFrom-Json }
            catch { $skippedLines++; continue }
            if ([string](Get-JsonMember $record 'subtype') -ne 'stop_hook_summary') { continue }
            $infos = Get-JsonMember $record 'hookInfos'
            if ($null -eq $infos) { $skippedLines++; continue }
            $recordCount++
            foreach ($info in @($infos)) {
                $leaf = Get-HookLeafName -Command ([string](Get-JsonMember $info 'command'))
                if (-not $durations.ContainsKey($leaf)) {
                    $durations[$leaf] = New-Object System.Collections.Generic.List[double]
                    $missing[$leaf] = 0
                }
                $ms = Get-JsonMember $info 'durationMs'
                $value = 0.0
                if ($null -ne $ms -and [double]::TryParse([string]$ms, [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                    [void]$durations[$leaf].Add($value)
                }
                else { $missing[$leaf]++ }
            }
        }
    }
    catch { }
    finally { $reader.Dispose() }
}

$rows = foreach ($leaf in $durations.Keys) {
    $values = $durations[$leaf].ToArray()
    $stats = Get-DurationStats -Values $values
    $timeout = if ($timeouts.ContainsKey($leaf)) { $timeouts[$leaf] } else { $DefaultTimeoutSeconds }
    $atTimeout = @($values | Where-Object { $_ -ge ($timeout * 1000) }).Count
    [pscustomobject]@{
        Hook            = $leaf
        Count           = $values.Count + $missing[$leaf]
        NoDuration      = $missing[$leaf]
        MedianMs        = if ($stats) { $stats.Median } else { $null }
        P95Ms           = if ($stats) { $stats.P95 } else { $null }
        MaxMs           = if ($stats) { $stats.Max } else { $null }
        TimeoutSeconds  = $timeout
        AtOrOverTimeout = $atTimeout
    }
}
$rows = @($rows | Sort-Object @{ Expression = { if ($null -eq $_.MedianMs) { -1 } else { $_.MedianMs } }; Descending = $true }, Hook)

# ---- print ---------------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        Rows         = $rows
        FilesRead    = $files.Count
        RecordCount  = $recordCount
        SkippedLines = $skippedLines
        Caveat       = $Caveat
    } | ConvertTo-Json -Depth 4
    exit 0
}

function Format-Seconds {
    param($Ms)
    if ($null -eq $Ms) { return '-' }
    return ([double]$Ms / 1000).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + 's'
}

if ($rows.Count -eq 0) {
    Write-Output 'No stop_hook_summary records found.'
}
else {
    $format = '{0,-32} {1,6} {2,6} {3,8} {4,8} {5,8} {6,8} {7,9}'
    Write-Output ($format -f 'Hook', 'n', 'no-dur', 'median', 'p95', 'max', 'timeout', '>=timeout')
    foreach ($row in $rows) {
        Write-Output ($format -f $row.Hook, $row.Count, $row.NoDuration, (Format-Seconds $row.MedianMs),
            (Format-Seconds $row.P95Ms), (Format-Seconds $row.MaxMs), ([string]$row.TimeoutSeconds + 's'), $row.AtOrOverTimeout)
    }
}
Write-Output ''
Write-Output ('Files read: ' + $files.Count + '; records: ' + $recordCount + '; skipped lines: ' + $skippedLines)
Write-Output ('Note: ' + $Caveat + '.')
exit 0
