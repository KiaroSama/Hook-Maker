# Supported Desktop surfaces only, bounded snapshots reused for scan and stamp.
function Get-DesktopSkillRoots {
    param($Discovery)
    $roots = @()
    if ($null -ne $Discovery.PSObject.Properties['DesktopRoots']) { $roots = @($Discovery.DesktopRoots) }
    elseif (-not [string]::IsNullOrWhiteSpace($Discovery.DesktopRoot)) { $roots = @($Discovery.DesktopRoot) }
    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-DesktopSkillSnapshot {
    param($Discovery)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $partial = New-Object 'System.Collections.Generic.List[string]'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($root in @(Get-DesktopSkillRoots $Discovery)) {
        if (-not [IO.Directory]::Exists($root)) { continue }
        try {
            if ((Get-Item -LiteralPath $root -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { [void]$partial.Add('Desktop root reparse point skipped'); continue }
            $owners = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Select-Object -First 65)
            if ($owners.Count -gt 64) { [void]$partial.Add('Desktop owner ceiling reached') }
            foreach ($owner in @($owners | Select-Object -First 64)) {
                if ($clock.Elapsed.TotalSeconds -gt 2) { [void]$partial.Add('Desktop snapshot time ceiling reached'); break }
                if ($owner.Attributes -band [IO.FileAttributes]::ReparsePoint) { [void]$partial.Add('Desktop owner reparse point skipped'); continue }
                $sessions = @(Get-ChildItem -LiteralPath $owner.FullName -Directory -ErrorAction Stop | Select-Object -First 65)
                if ($sessions.Count -gt 64) { [void]$partial.Add('Desktop session ceiling reached') }
                foreach ($session in @($sessions | Select-Object -First 64 | Sort-Object LastWriteTimeUtc -Descending)) {
                    if ($files.Count -ge 64 -or $clock.Elapsed.TotalSeconds -gt 2) { [void]$partial.Add('Desktop snapshot ceiling reached'); break }
                    if ($session.Attributes -band [IO.FileAttributes]::ReparsePoint) { [void]$partial.Add('Desktop session reparse point skipped'); continue }
                    $manifest = Join-Path $session.FullName 'manifest.json'
                    $skills = Join-Path $session.FullName 'skills'
                    if (-not [IO.Directory]::Exists($skills)) { continue }
                    if (-not (Test-DiscoveryContainedPath -Path $skills -Root $root)) { [void]$partial.Add('Desktop skills reparse point skipped'); continue }
                    $stamp = $session.LastWriteTimeUtc.Ticks
                    if ([IO.File]::Exists($manifest)) { $item = Get-Item -LiteralPath $manifest -ErrorAction Stop; $stamp = $item.LastWriteTimeUtc.Ticks }
                    $definitions = @(Get-ChildItem -LiteralPath $skills -Directory -ErrorAction Stop | Select-Object -First 121 | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { Join-Path $_.FullName 'SKILL.md' })
                    if ($definitions.Count -gt 120) { [void]$partial.Add('Desktop skill ceiling reached'); $definitions = @($definitions | Select-Object -First 120) }
                    [void]$files.Add([pscustomobject]@{ Owner = $owner.Name; Skills = $skills; Manifest = $manifest; Ticks = $stamp; Definitions = $definitions })
                }
                if ($files.Count -ge 64 -or $clock.Elapsed.TotalSeconds -gt 2) { break }
            }
        }
        catch { [void]$partial.Add('Desktop root unreadable') }
    }
    return [pscustomobject]@{ Sessions = $files.ToArray(); Partial = $partial.ToArray() }
}

function Get-DesktopDiscovery {
    param($Discovery, $Result)
    $snapshot = Get-DesktopSkillSnapshot $Discovery
    foreach ($reason in $snapshot.Partial) { [void]$Result.Partial.Add($reason) }
    $seen = @{}
    $uncertainOwners = @{}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $readCount = 0
    foreach ($session in @($snapshot.Sessions | Sort-Object Ticks -Descending)) {
        $manifest = Read-DiscoveryJson -Path $session.Manifest -Partial $Result.Partial -Label 'Desktop manifest'
        if ($null -eq $manifest -or $null -eq $manifest.PSObject.Properties['skills'] -or $manifest.skills -isnot [array]) { [void]$Result.Partial.Add('Desktop manifest missing or malformed'); $uncertainOwners[$session.Owner] = $true; continue }
        $folders = @(Get-ChildItem -LiteralPath $session.Skills -Directory -ErrorAction SilentlyContinue | Select-Object -First 121)
        if ($folders.Count -gt 120) { [void]$Result.Partial.Add('Desktop skill ceiling reached'); $folders = @($folders | Select-Object -First 120) }
        foreach ($folder in $folders) {
            if ($readCount -ge 1200 -or $clock.Elapsed.TotalSeconds -gt 2) { [void]$Result.Partial.Add('Desktop discovery time/file ceiling reached'); return }
            $readCount++
            if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { [void]$Result.Partial.Add('Desktop skill reparse point skipped'); continue }
            if (-not [IO.File]::Exists((Join-Path $folder.FullName 'SKILL.md'))) { continue }
            $skill = New-DiscoveredSkill -Plugin 'anthropic-skills' -Folder $folder.FullName -Source 'claude-desktop' -Version '' -Enabled $true -Client claude
            $flags = @($manifest.skills | Where-Object { [string](Get-Field $_ 'name') -ceq $skill.Name })
            if ($flags.Count -ne 1 -or (Get-Field $flags[0] 'enabled') -isnot [bool]) { [void]$Result.Partial.Add('Desktop skill enabled/source evidence ambiguous'); $uncertainOwners[$session.Owner] = $true; continue }
            if ((Get-Field $flags[0] 'enabled') -eq $false) { $skill.Status = 'disabled' }
            $hash = Get-DiscoverySkillHash $folder.FullName
            $referenceState = Get-DiscoveryReferenceState $folder.FullName
            if ($referenceState -ne 'complete') {
                [void]$Result.Partial.Add('Desktop reference package incomplete: ' + $skill.Name)
                if ($skill.Status -eq 'enabled') { $skill.Status = 'unknown' }
            }
            $source = [string](Get-Field $flags[0] 'source')
            $sourceId = [string](Get-Field $flags[0] 'skillId')
            if ($source -ne '' -or $sourceId -ne '') { Set-ObjectProperty $skill 'SourceIdentity' (Get-ShortHash ($source + '|' + $sourceId)) }
            Set-ObjectProperty $skill 'ReferenceState' $referenceState
            if ($hash -eq '') { [void]$Result.Partial.Add('Desktop skill unreadable or over byte ceiling'); continue }
            $key = $session.Owner + '|' + $skill.Name
            if ($seen.ContainsKey($key)) {
                $prior = $seen[$key]
                if ($prior.Hash -ne $hash -or $prior.Skill.Status -ne $skill.Status -or [string](Get-Field $prior.Skill 'SourceIdentity') -cne [string](Get-Field $skill 'SourceIdentity')) {
                    [void]$Result.Partial.Add('Desktop stale/conflicting definition: ' + $skill.Name)
                    if ($prior.Ticks -eq $session.Ticks -or [string](Get-Field $prior.Skill 'SourceIdentity') -cne [string](Get-Field $skill 'SourceIdentity')) { $prior.Skill.Status = 'unknown' }
                }
                continue
            }
            $seen[$key] = [pscustomobject]@{ Hash = $hash; Skill = $skill; Ticks = $session.Ticks }
            foreach ($prior in $Result.Skills) {
                if ($prior.Source -eq 'claude-desktop' -and $prior.Invocation -ceq $skill.Invocation) {
                    $prior.Status = 'unknown'; $skill.Status = 'unknown'
                    [void]$Result.Partial.Add('Desktop owner/source collision: ' + $skill.Name)
                }
            }
            Set-ObjectProperty $skill 'InstallationKey' ('desktop:' + $session.Owner)
            Set-ObjectProperty $skill 'DefinitionHash' $hash
            Add-DiscoveredSkill $Result $skill
        }
    }
    foreach ($skill in $Result.Skills) {
        if ($skill.Source -eq 'claude-desktop') {
            $owner = ([string](Get-Field $skill 'InstallationKey')) -replace '^desktop:', ''
            if ($uncertainOwners.ContainsKey($owner)) { $skill.Status = 'unknown' }
        }
    }
}

function Test-DiscoveryContainedPath {
    param([string]$Path, [string]$Root)
    try {
        $current = [IO.Path]::GetFullPath($Path)
        $boundary = [IO.Path]::GetFullPath($Root)
        if (-not (Test-PathInside -Candidate $current -Parent $boundary)) { return $false }
        while ($current -ne $boundary) {
            if ((Get-Item -LiteralPath $current -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            $current = Split-Path -Parent $current
            if ($current -eq '') { return $false }
        }
        return -not ((Get-Item -LiteralPath $boundary -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)
    }
    catch { return $false }
}

function Get-DiscoveryReferenceState {
    param([string]$Folder)
    try {
        $path = Join-Path $Folder 'SKILL.md'
        if ((Get-Item -LiteralPath $path).Length -gt 262144) { return 'unknown' }
        $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true))
        $links = [regex]::Matches($text, '\[[^\]\r\n]*\]\(([^)\r\n]+)\)')
        if ($links.Count -gt 64) { return 'partial' }
        foreach ($link in $links) {
            $target = $link.Groups[1].Value.Trim()
            if ($target -match '^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#)') { continue }
            $target = ($target -split '#',2)[0]
            if ($target -eq '') { continue }
            $full = [IO.Path]::GetFullPath((Join-Path $Folder $target))
            if (-not (Test-DiscoveryContainedPath -Path $full -Root $Folder)) { return 'incomplete' }
        }
        return 'complete'
    }
    catch { return 'unknown' }
}

function Get-DiscoverySkillHash {
    param([string]$Folder)
    try {
        $path = Join-Path $Folder 'SKILL.md'
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.Length -gt 262144 -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return '' }
        $bytes = [IO.File]::ReadAllBytes($path)
        [void][Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    catch { return '' }
}
