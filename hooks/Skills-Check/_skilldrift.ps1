# Catalogue drift for Skills-Check: the deployed rules against what is installed.
#
# THE DEFECT THIS EXISTS FOR. The rules give every visible skill its own routing
# line (global-skill-routing.md, global-skills-catalogue.md) and record every
# registered plugin (catalogue\plugins-*.jsonl). Installs and removals change
# the machine without touching those files, so the rules silently start
# describing skills that are gone and omitting skills that arrived - on
# 2026-09-26 a whole plugin family was removed and the catalogue still named it.
#
# Two directions, both ADVISORY: a discovered name with no backtick-quoted
# mention in the two rule files ("uncatalogued"), and a catalogue plugin record
# for this client that the client's own install records no longer list
# ("removed"). Host-bundled skills are not on disk, so discovery never yields
# them and the plugin records never name them: neither direction can report one.
#
# Read-only, bounded, and never a block. A missing rules directory is reported
# as NOT CHECKED - absence of the rules is not evidence that there is no drift.

$script:DriftMaxRuleBytes = 2097152
$script:DriftMaxCatalogueFiles = 32
$script:DriftReportLimit = 10

function Get-SkillRulesDirectory {
    param([string]$CodexHome)
    if ($config.ContainsKey('SKILL_RULES_DIR') -and -not [string]::IsNullOrWhiteSpace([string]$config['SKILL_RULES_DIR'])) { return [string]$config['SKILL_RULES_DIR'] }
    if ($client -eq 'codex') { return (Join-Path $CodexHome 'rules') }
    return (Join-Path $homeDir '.claude\rules')
}

# Every backtick span in the two rule files, lower-cased, plus the part after a
# "<plugin>:" prefix, because the routing file writes plugin skills both ways.
function Get-CataloguedSkillNames {
    param([string]$RulesDir)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $read = 0
    foreach ($file in @('global-skill-routing.md', 'global-skills-catalogue.md')) {
        $path = Join-Path $RulesDir $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            if ((Get-Item -LiteralPath $path).Length -gt $script:DriftMaxRuleBytes) { continue }
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        }
        catch { continue }
        $read++
        foreach ($m in [regex]::Matches($text, '`([^`\r\n]{1,120})`')) {
            $span = $m.Groups[1].Value.Trim()
            [void]$names.Add($span)
            $colon = $span.LastIndexOf(':')
            if ($colon -ge 0 -and $colon -lt $span.Length - 1) { [void]$names.Add($span.Substring($colon + 1)) }
        }
    }
    if ($read -eq 0) { return $null }
    return $names
}

function Get-CataloguePluginKeys {
    param([string]$RulesDir)
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $dir = Join-Path $RulesDir 'catalogue'
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter 'plugins-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -First $script:DriftMaxCatalogueFiles)) {
        try {
            if ($file.Length -gt $script:DriftMaxRuleBytes) { continue }
            foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $record = $line | ConvertFrom-Json } catch { continue }
                if ([string](Get-Field $record 'client') -ne $client) { continue }
                $key = [string](Get-Field $record 'key')
                if ($key -ne '') { [void]$keys.Add($key) }
            }
        }
        catch { continue }
    }
    return $keys
}

# Returns $null when the rules are absent (drift NOT CHECKED), otherwise the
# two sorted name lists and a fingerprint over both.
function Get-SkillCatalogueDrift {
    param([string]$RulesDir, [string[]]$DiscoveredNames, $Index)
    $catalogued = Get-CataloguedSkillNames -RulesDir $RulesDir
    if ($null -eq $catalogued) { return $null }
    $missing = @($DiscoveredNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $catalogued.Contains($_.Trim()) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
    $removed = @()
    # Only a READABLE install record can prove a plugin is gone.
    if ($Index.InstallKnown) {
        $installed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $Index.InstallKeys) { [void]$installed.Add($k) }
        $removed = @(Get-CataloguePluginKeys -RulesDir $RulesDir | Where-Object { -not $installed.Contains($_) } | Sort-Object -Unique)
    }
    return [pscustomobject]@{
        Missing = $missing; Removed = $removed
        Fingerprint = (Get-ShortHash (($missing -join ',') + '#' + ($removed -join ',')))
    }
}

function Get-SkillDriftLines {
    param($Drift, [string]$RulesDir)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Drift) {
        [void]$lines.Add('Catalogue drift NOT CHECKED: the deployed routing rules were not found under ' + $RulesDir + ' (this is not an all-clear).')
        return $lines
    }
    if ($Drift.Missing.Count -gt 0) {
        $shown = @($Drift.Missing | Select-Object -First $script:DriftReportLimit)
        $more = if ($Drift.Missing.Count -gt $shown.Count) { ' (+' + ($Drift.Missing.Count - $shown.Count) + ' more)' } else { '' }
        [void]$lines.Add('UNCATALOGUED SKILLS (advisory): ' + ($shown -join ', ') + $more + ' - no routing line in global-skill-routing.md or global-skills-catalogue.md; the rules need an update.')
    }
    if ($Drift.Removed.Count -gt 0) {
        [void]$lines.Add('REMOVED PLUGINS (advisory): ' + ((@($Drift.Removed | Select-Object -First $script:DriftReportLimit)) -join ', ') + ' - the catalogue names a removed plugin; the rules need an update.')
    }
    return $lines
}
