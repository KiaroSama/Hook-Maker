# Skill discovery and indexing for Skills-Check.
#
# Split out of the hook for two reasons. It is a real responsibility - walk the
# expensive sources once, cache what was found - and the hook itself had reached
# the file-size ceiling, so nothing new could be written there.
#
# WHAT CHANGED WHEN THIS MOVED: the index used to record a skill's FOLDER NAME
# and nothing else, so the prompt shortlist scored directory names. A skill whose
# folder shares no token with the prompt was invisible however well its
# description matched, and a folder that merely CONTAINED a token was offered for
# it. Each entry now also carries the `name:` and `description:` from its
# SKILL.md, which is the identity the Skill Policy actually addresses skills by.
#
# Every function here reads $indexPath / $indexConfigHash / $indexTtlMinutes /
# $hasPluginRoot / $pluginRoot / $hasLibrary / $libraryDir / $stateDir and
# $skillDiscovery (_skilldiscovery.ps1) from the caller's scope.

# Index format. Flat lines, not JSON: ~1700 entries parse in milliseconds and the
# file is only ever produced and consumed here.
#   header  HookMakerSkillsIndex|3|<configHash>|<builtUtcTicks>
#   plugin  p|<plugin>|<folder>|<name>|<description>|<full path>|<source>|<version>|<status>|<explicit>|<invocation>
#   library l|<folder>|<name>|<description>|<full path>
#   partial x|<reason>            install key k|<name@market>        install known m|1
#
# Version 3 because the shape changed again (per-skill discovery, see
# _skilldiscovery.ps1): an older file on disk is rebuilt, never misread.
$script:SkillIndexVersion = '3'

# '|' is the field separator and a description may contain anything, so every
# stored field is flattened first. Lossy on purpose - these values are only ever
# matched against prompt tokens, never displayed back or written to a skill.
function ConvertTo-SkillIndexField {
    param([string]$Value, [int]$MaxLength = 240)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $flat = ($Value -replace '[\r\n\t|]+', ' ').Trim()
    $flat = ($flat -replace '\s{2,}', ' ')
    if ($flat.Length -gt $MaxLength) { $flat = $flat.Substring(0, $MaxLength) }
    return $flat
}

# The `name:` and `description:` of one SKILL.md, read from its FRONTMATTER only.
# Bounded: frontmatter is at the top of the file, so a fixed prefix is read
# rather than the whole document - this runs across ~1700 files on a cold index.
# A file that cannot be read contributes nothing and never throws.
function Get-SkillIdentity {
    param([string]$SkillFile, [int]$MaxBytes = 4096)
    $result = [pscustomobject]@{ Name = ''; Description = ''; Explicit = $false }
    try {
        $stream = [System.IO.File]::Open($SkillFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $take = [int][Math]::Min([int64]$MaxBytes, $stream.Length)
            if ($take -le 0) { return $result }
            $buffer = New-Object byte[] $take
            $filled = 0
            while ($filled -lt $take) {
                $chunk = $stream.Read($buffer, $filled, $take - $filled)
                if ($chunk -le 0) { break }
                $filled += $chunk
            }
            if ($filled -le 0) { return $result }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $filled)
        }
        finally { $stream.Dispose() }
    }
    catch { return $result }

    # Only the leading frontmatter block counts. A `description:` further down in
    # prose is documentation about something else, not this skill's identity.
    $body = $text
    $fenceEnd = -1
    if ($text -match '^\s*---') {
        $afterOpen = $text.IndexOf("---")
        if ($afterOpen -ge 0) { $fenceEnd = $text.IndexOf("`n---", $afterOpen + 3) }
    }
    if ($fenceEnd -gt 0) { $body = $text.Substring(0, $fenceEnd) }

    $nameMatch = [regex]::Match($body, '(?im)^[ \t]*name[ \t]*:[ \t]*(.+)$')
    # Trim() FIRST: with CRLF frontmatter the capture ends in `r, and a quote
    # before it survived, so `name: "pdf"` indexed as pdf" and matched nothing.
    if ($nameMatch.Success) { $result.Name = ConvertTo-SkillIndexField ($nameMatch.Groups[1].Value.Trim().Trim(([char]34), ([char]39), ' ')) 120 }
    $descMatch = [regex]::Match($body, '(?im)^[ \t]*description[ \t]*:[ \t]*(.+)$')
    if ($descMatch.Success) { $result.Description = ConvertTo-SkillIndexField ($descMatch.Groups[1].Value.Trim().Trim(([char]34), ([char]39), ' ')) }
    # Claude never loads such a skill on its own, so it must never be a skill
    # the Stop gate holds the agent to (see _promptmatch.ps1).
    $result.Explicit = ($body -match '(?im)^[ \t]*disable-model-invocation[ \t]*:[ \t]*true\b')
    return $result
}

# Reads the index when it is present, current and built from THIS configuration.
# Returns $null otherwise - a stale, foreign or older-format index is rebuilt,
# never trusted.
function Read-SkillIndex {
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($indexPath)
        if ($lines.Count -lt 1) { return $null }
        $head = $lines[0].Split('|')
        if ($head.Count -lt 4 -or $head[0] -ne 'HookMakerSkillsIndex' -or $head[1] -ne $script:SkillIndexVersion) { return $null }
        if ($head[2] -ne $indexConfigHash) { return $null }
        $ticks = 0L
        if (-not [int64]::TryParse($head[3], [ref]$ticks)) { return $null }
        if ($indexTtlMinutes -gt 0) {
            $age = ([DateTime]::UtcNow - [DateTime]::new($ticks, [DateTimeKind]::Utc)).TotalMinutes
            if ($age -lt 0 -or $age -gt $indexTtlMinutes) { return $null }
        }
        $plugin = New-Object System.Collections.Generic.List[object]
        $library = New-Object System.Collections.Generic.List[object]
        $partial = New-Object System.Collections.Generic.List[string]
        $keys = New-Object System.Collections.Generic.List[string]
        $known = $false
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $parts = $lines[$i].Split('|')
            if ($parts[0] -eq 'p' -and $parts.Count -ge 11) {
                [void]$plugin.Add([pscustomobject]@{ Plugin = $parts[1]; Leaf = $parts[2]; Name = $parts[3]; Description = $parts[4]; Path = $parts[5]
                        Source = $parts[6]; Version = $parts[7]; Status = $parts[8]; Explicit = $parts[9]; Invocation = $parts[10] })
            }
            elseif ($parts[0] -eq 'l' -and $parts.Count -ge 5) {
                [void]$library.Add([pscustomobject]@{ Leaf = $parts[1]; Name = $parts[2]; Description = $parts[3]; Path = $parts[4] })
            }
            elseif ($parts[0] -eq 'x' -and $parts.Count -ge 2) { [void]$partial.Add($parts[1]) }
            elseif ($parts[0] -eq 'k' -and $parts.Count -ge 2) { [void]$keys.Add($parts[1]) }
            elseif ($parts[0] -eq 'm') { $known = $true }
        }
        return [pscustomobject]@{ Plugin = $plugin; Library = $library; Partial = $partial; InstallKeys = $keys; InstallKnown = $known }
    }
    catch { return $null }
}

# Walks both expensive sources and writes the index. Bounded on both sides; a
# source that is absent or unreadable simply contributes nothing, and the
# resulting partial coverage is reported rather than presented as complete.
function Build-SkillIndex {
    $plugin = New-Object System.Collections.Generic.List[object]
    $library = New-Object System.Collections.Generic.List[object]
    $maxPlugin = 600
    $maxLibrary = 4000

    if ($hasPluginRoot) {
        try {
            foreach ($skillsDir in @(Get-ChildItem -Path (Join-Path $pluginRoot '*\*\*\skills') -Directory -ErrorAction SilentlyContinue)) {
                # <root>\<marketplace>\<plugin>\<version>\skills -> the plugin
                # name is three levels up, which is the id the client prefixes.
                $pluginName = ''
                try { $pluginName = (Get-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $skillsDir.FullName))).Name } catch { $pluginName = '' }
                if ($pluginName -eq '') { continue }
                foreach ($d in @(Get-ChildItem -LiteralPath $skillsDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                    if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $identity = Get-SkillIdentity (Join-Path $d.FullName 'SKILL.md')
                    [void]$plugin.Add([pscustomobject]@{ Plugin = $pluginName; Leaf = $d.Name; Name = $identity.Name; Description = $identity.Description; Path = $d.FullName
                            Source = 'cache-walk'; Version = ''; Status = 'enabled'; Explicit = $(if ($identity.Explicit) { '1' } else { '0' }); Invocation = ($pluginName + ':' + $d.Name) })
                    if ($plugin.Count -ge $maxPlugin) { break }
                }
                if ($plugin.Count -ge $maxPlugin) { break }
            }
        }
        catch { }
    }

    # The install records are the primary source; the cache walk above runs only
    # when PLUGIN_SKILLS_ROOT is set explicitly. A folder both found is kept once.
    $discovered = Invoke-SkillDiscovery -Discovery $skillDiscovery
    $seen = @{}
    foreach ($p in $plugin) { $seen[$p.Path.ToLowerInvariant()] = $true }
    foreach ($s in $discovered.Skills) {
        if ($seen.ContainsKey($s.Path.ToLowerInvariant())) { continue }
        $seen[$s.Path.ToLowerInvariant()] = $true
        [void]$plugin.Add($s)
    }

    if ($hasLibrary) {
        # A skill is a directory holding SKILL.md. The library mixes flat skills
        # and category\skill layouts, so depth 2 covers both. -Recurse does not
        # follow reparse points, which is the containment guarantee wanted here.
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $libraryDir -Recurse -Depth 2 -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue)) {
                $dir = Split-Path -Parent $f.FullName
                $identity = Get-SkillIdentity $f.FullName
                [void]$library.Add([pscustomobject]@{ Leaf = (Split-Path -Leaf $dir); Name = $identity.Name; Description = $identity.Description; Path = $dir })
                if ($library.Count -ge $maxLibrary) { break }
            }
        }
        catch { }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('HookMakerSkillsIndex|' + $script:SkillIndexVersion + '|' + $indexConfigHash + '|' + [DateTime]::UtcNow.Ticks)
    foreach ($p in $plugin) {
        [void]$lines.Add('p|' + $p.Plugin + '|' + $p.Leaf + '|' + $p.Name + '|' + $p.Description + '|' + $p.Path + '|' +
            $p.Source + '|' + (ConvertTo-SkillIndexField $p.Version 60) + '|' + $p.Status + '|' + $p.Explicit + '|' + (ConvertTo-SkillIndexField $p.Invocation 200))
    }
    foreach ($l in $library) { [void]$lines.Add('l|' + $l.Leaf + '|' + $l.Name + '|' + $l.Description + '|' + $l.Path) }
    foreach ($reason in $discovered.Partial) { [void]$lines.Add('x|' + (ConvertTo-SkillIndexField $reason)) }
    foreach ($key in $discovered.InstallKeys) { [void]$lines.Add('k|' + (ConvertTo-SkillIndexField $key)) }
    if ($discovered.InstallKnown) { [void]$lines.Add('m|1') }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $tmp = $indexPath + '.tmp'
        [System.IO.File]::WriteAllLines($tmp, [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $indexPath -Force
    }
    catch { }
    return [pscustomobject]@{ Plugin = $plugin; Library = $library; Partial = $discovered.Partial; InstallKeys = $discovered.InstallKeys; InstallKnown = $discovered.InstallKnown }
}
