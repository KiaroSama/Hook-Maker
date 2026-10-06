# Structured contracts are evidence of provider coverage, never runtime loading.
function Read-SkillCatalogueContracts {
    param([string]$RulesDir)
    $records = New-Object 'System.Collections.Generic.List[object]'
    $partial = New-Object 'System.Collections.Generic.List[string]'
    $clock = [Diagnostics.Stopwatch]::StartNew(); $bytes = 0L; $rows = 0
    $files = @(Get-ChildItem -LiteralPath (Join-Path $RulesDir 'catalogue') -Filter 'skills-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 257)
    if ($files.Count -gt 256) { [void]$partial.Add('catalogue file ceiling reached') }
    foreach ($file in @($files | Select-Object -First 256)) {
        if ($file.Length -gt 2097152 -or $bytes + $file.Length -gt 16777216 -or $clock.Elapsed.TotalSeconds -gt 2) { [void]$partial.Add('catalogue byte/time ceiling reached'); break }
        $bytes += $file.Length
        try {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { [void]$partial.Add('catalogue reparse file skipped'); continue }
            $lines = [IO.File]::ReadAllLines($file.FullName, [Text.UTF8Encoding]::new($false,$true))
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($rows -ge 20000 -or $clock.Elapsed.TotalSeconds -gt 2) { [void]$partial.Add('catalogue row/time ceiling reached'); break }
                $rows++
                try {
                    $record = $line | ConvertFrom-Json -ErrorAction Stop
                    $kind = [string](Get-Field $record 'category')
                    if ($kind -ne '' -and $kind -ne 'skill') { continue }
                    if ([string](Get-Field $record 'name') -eq '' -or $null -eq (Get-Field $record 'sources')) { [void]$partial.Add('catalogue skill identity missing'); continue }
                    [void]$records.Add($record)
                }
                catch { [void]$partial.Add('catalogue record unreadable') }
            }
        }
        catch { [void]$partial.Add('catalogue file unreadable') }
        if ($rows -ge 20000) { break }
    }
    return [pscustomobject]@{ Records = $records.ToArray(); Partial = @($partial | Sort-Object -Unique) }
}

function Test-SkillCatalogueContract {
    param($Skill, $Record, [string]$Client)
    if ([string](Get-Field $Record 'name') -cne [string]$Skill.Name) { return $false }
    $skillPath = Join-Path $Skill.Path 'SKILL.md'
    $installKeys = @(([string](Get-Field $Skill 'InstallationKey')).Split(';'))
    $plugin = $Skill.Source -in @('claude-plugin','codex-plugin','cache-walk')
    if ($Skill.Source -eq 'user-global') { $installKeys = @($Client + '-user-standalone') }
    foreach ($source in @(Get-Field $Record 'sources')) {
        if ([string](Get-Field $source 'client') -cne $Client) { continue }
        $path = [string](Get-Field $source 'path')
        if ($path -eq '' -or (Normalize-Path $path) -ne (Normalize-Path $skillPath)) { continue }
        $package = [string](Get-Field $source 'package')
        $provider = [string](Get-Field $Record 'provider')
        if ($plugin -and ($installKeys -notcontains $package -or ($provider -ne '' -and $provider -cne $package))) { continue }
        $invocation = [string](Get-Field $source 'invocation')
        if ($invocation -ne '' -and $invocation -cne [string]$Skill.Invocation) { continue }
        # Historical multi-source rows without an invocation must prove the exact
        # installed source path/package. Library and marketplace clients never count.
        if (-not $plugin -and $invocation -ne '' -and $invocation.Contains(':') -and $Skill.Source -ne 'claude-desktop') { continue }
        if ($Skill.Source -eq 'user-global' -and $provider -ne '' -and ($installKeys -notcontains $provider -or $provider -cne $package)) { continue }
        $version = [string](Get-Field $source 'version')
        if ($version -ne '' -and $version -notmatch '^byte-match checked \d{4}-\d{2}-\d{2}$' -and $version -cne [string]$Skill.Version) { continue }
        $expected = [string](Get-Field $source 'sha256')
        if ($expected -eq '') { $expected = [string](Get-Field $Record 'sha256') }
        $actual = [string](Get-Field $Skill 'DefinitionHash')
        if ($expected -ne '') {
            if ($expected -notmatch '^[a-fA-F0-9]{64}$') { continue }
            $actual = Get-DiscoverySkillHash $Skill.Path
            if ($actual -eq '' -or $actual -cne $expected.ToLowerInvariant()) { continue }
        }
        return $true
    }
    return $false
}
