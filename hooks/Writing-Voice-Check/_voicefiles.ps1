# Writing-Voice-Check - the voice of WRITTEN text (steering V83-V84, spec 041).
# Dot-sourced; definitions only, no exit.
#
# The Stop gate judges the reply language. The rule also covers what the agent
# writes for people to read: docs and READMEs, commit and PR prose. Their
# language can differ from the reply's (a Persian chat that writes an English
# README needs `humanizer`, not `persian`). This file names, ADVISORY only, a
# language found in prose files written or commit/PR text sent after the last
# compaction whose skill was not loaded since then. Code is never judged.

$script:VoiceProseFile = '(?i)\.(md|mdx|markdown|txt|rst|adoc|html?)$'
$script:VoiceReadBytes = 65536
$script:VoiceCommitPattern = '(?i)\bgit\s+commit\b|\bgh\s+(pr|issue|release)\s+(create|edit|comment)\b'

# The human text of a commit/PR command: -m/--message/--title/--body/--notes
# values and here-doc bodies. '' when the command carries none.
function Get-VoiceCommandProse {
    param([AllowEmptyString()][string]$Command)
    if ($Command -notmatch $script:VoiceCommitPattern) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Command, '(?s)(?:-m|--message|--title|--body|--notes|-t|-b)\s+(?:"((?:[^"\\]|\\.)*)"|''([^'']*)'')')) {
        [void]$parts.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }))
    }
    foreach ($m in [regex]::Matches($Command, '(?s)<<-?\s*[''"]?(\w+)[''"]?\r?\n(.*?)\r?\n\s*\1\b')) { [void]$parts.Add($m.Groups[2].Value) }
    # Attribution trailers are fixed English text the user requires; not prose to judge.
    return ((@($parts) -join "`n") -replace '(?im)^\s*Co-Authored-By:.*$', '')
}

# Prose of a written file with code fences, inline code and links' URLs removed.
function Get-VoiceFileProse {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch $script:VoiceProseFile -or -not [IO.File]::Exists($Path)) { return '' }
    $text = ''
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $buffer = New-Object byte[] ([int][Math]::Min([int64]$script:VoiceReadBytes, $stream.Length))
            $filled = 0
            while ($filled -lt $buffer.Length) { $n = $stream.Read($buffer, $filled, $buffer.Length - $filled); if ($n -le 0) { break }; $filled += $n }
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $filled)
        }
        finally { $stream.Dispose() }
    }
    catch { return '' }
    return [regex]::Replace($text, '(?s)```.*?(```|$)|`[^`\r\n]*`|\]\([^)]*\)|https?://\S+|<[^>]+>', ' ')
}

# @(languages) whose skill is not in $Loaded, from $Artifacts (@{ Kind; Value }).
# $Detect is the hook's own language detector, so both halves agree.
function Get-VoiceArtifactLanguages {
    param([object[]]$Artifacts, [Parameter(Mandatory = $true)][hashtable]$Loaded, [Parameter(Mandatory = $true)][scriptblock]$Detect, [string]$Cwd = '')
    $found = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Artifacts | Select-Object -Last 40)) {
        $prose = ''
        if ($item.Kind -eq 'write') {
            $path = [string]$item.Value
            if ($Cwd -ne '' -and -not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Cwd $path }
            if (-not $seen.Add($path)) { continue }
            $prose = Get-VoiceFileProse -Path $path
        }
        else { $prose = Get-VoiceCommandProse -Command ([string]$item.Value) }
        if ([string]::IsNullOrWhiteSpace($prose)) { continue }
        $language = [string](& $Detect $prose)
        if ($language -ne '' -and -not $Loaded[$language] -and -not $found.Contains($language)) { [void]$found.Add($language) }
    }
    return @($found)
}
