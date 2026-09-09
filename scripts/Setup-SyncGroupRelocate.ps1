# Repairs the installs of a project whose folder was RENAMED or MOVED.
#
# Nothing in the tool detected this before. A record stores an absolute
# targetProjectRoot and every registration inside the project stores absolute
# command paths, so renaming the folder leaves three separate wrecks at once:
#
#   * the registry still claims the hooks live at a path that no longer exists,
#     so update/uninstall/status all operate on nothing;
#   * the registrations that TRAVELLED WITH the folder still invoke the old
#     path, so every hook in the moved project is silently dead;
#   * a per-hook-file client (Kiro) carries its own documents along, so the
#     moved directory ends up holding stale documents that no record owns -
#     invisible to uninstall, because the record points somewhere else.
#
# Repairing it by hand means reinstalling per client with each client's own
# recorded events, dropping the stale records, purging the orphaned per-hook
# documents, and rewriting any sync-group route that named the old root. That
# is this flow.
#
# It NEVER guesses the new location: a missing root can equally mean "deleted",
# and reinstalling a deleted project's hooks somewhere invented would be worse
# than leaving the record broken. The user names the new path.

# The set of project roots the registry believes in that are not on disk. That
# is the only honest candidate list: a root that still exists was not moved,
# and one that does not may equally have been deleted - which is why this only
# ever OFFERS them and never acts on its own.
function Get-RelocationCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$ConfigPath = ''
    )

    $registry = Read-InstallRegistry -ToolRoot $ToolRoot
    $byRoot = @{}
    foreach ($record in @($registry.installs)) {
        if ($null -eq $record) { continue }
        if ($null -eq $record.PSObject.Properties['scope'] -or [string]$record.scope -ne 'project') { continue }
        $root = ''
        if ($null -ne $record.PSObject.Properties['targetProjectRoot']) { $root = [string]$record.targetProjectRoot }
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (Test-Path -LiteralPath $root -PathType Container) { continue }
        if (-not $byRoot.ContainsKey($root)) { $byRoot[$root] = New-Object System.Collections.Generic.List[object] }
        [void]$byRoot[$root].Add($record)
    }
    # A sync route can name a root the registry does not: a group survives its
    # member's hooks being uninstalled, and a rename repaired only in the
    # registry leaves the route behind. Two real groups (20 and 56 routes) were
    # still pointing at a folder renamed two renames ago while the registry was
    # clean, so a registry-only list could never offer it.
    foreach ($root in @(Get-SyncConfigRoot -ConfigPath $ConfigPath)) {
        if (Test-Path -LiteralPath $root -PathType Container) { continue }
        if ($byRoot.ContainsKey($root)) { continue }
        $known = @($byRoot.Keys | Where-Object { [string]::Equals($_, $root, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($known.Count -gt 0) { continue }
        $byRoot[$root] = New-Object System.Collections.Generic.List[object]
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($root in @($byRoot.Keys | Sort-Object)) {
        [void]$candidates.Add([pscustomobject]@{
                Root    = $root
                Records = @($byRoot[$root].ToArray())
            })
    }
    return $candidates.ToArray()
}

# Every project root either end of an ENABLED sync route names, deduplicated.
# Read-only, and silent about a missing or unreadable config: a relocation must
# still be offered for the registry's own missing roots when no sync config
# exists.
#
# Disabled profiles and routes are skipped deliberately. Nothing syncs through
# them, so a root they name being absent is not a fault to repair - and the
# shipped `example-sync-profile` is disabled and points at `D:\Projects\Project
# A|B`, which would otherwise put two permanent phantom entries in front of
# every user. Re-enable the group first if you do want its paths repaired.
function Get-SyncConfigRoot {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return @() }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    try { $config = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { return @() }
    $seen = @{}
    foreach ($profile in @($config.profiles)) {
        if ($null -eq $profile -or $null -eq $profile.PSObject.Properties['routes']) { continue }
        if ($null -ne $profile.PSObject.Properties['enabled'] -and -not $profile.enabled) { continue }
        foreach ($route in @($profile.routes)) {
            if ($null -eq $route) { continue }
            if ($null -ne $route.PSObject.Properties['enabled'] -and -not $route.enabled) { continue }
            foreach ($side in @('source', 'destination')) {
                if ($null -eq $route.PSObject.Properties[$side]) { continue }
                $end = $route.$side
                if ($null -eq $end -or $null -eq $end.PSObject.Properties['root']) { continue }
                $root = [string]$end.root
                if ([string]::IsNullOrWhiteSpace($root)) { continue }
                $seen[$root] = $true
            }
        }
    }
    return @($seen.Keys | Sort-Object)
}

# 'hookmaker-<slug>-<recordId>.json' -> '<slug>'. The record id is the last
# hyphen-separated token; the slug is everything between the prefix and it.
function Get-DocumentHookSlug {
    param([Parameter(Mandatory = $true)][string]$FileName)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if (-not $name.StartsWith('hookmaker-')) { return '' }
    $name = $name.Substring('hookmaker-'.Length)
    $lastDash = $name.LastIndexOf('-')
    if ($lastDash -le 0) { return '' }
    return $name.Substring(0, $lastDash)
}

# A path inside JSON is stored with its separators DOUBLED, so searching a raw
# document for the literal path never matches. Compare against both spellings.
# A root must match as a PATH, not as a substring. Renaming `...\Numera` to
# `...\Numera Browser` makes the old root a PREFIX of the new one, so a plain
# IndexOf reports every FRESH document as naming the old root too - which
# emptied the replacement set and left all 22 stale documents on disk in a real
# relocation. A hit therefore only counts when the next character ends the path:
# a separator, a closing quote, or end of text. A space never ends it, because
# that is exactly the character the collision turns on.
function Test-TextNamesRoot {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Root)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $boundary = [char[]]@('\', '/', '"', [char]0x27)
    foreach ($spelling in @($Root, $Root.Replace('\', '\\'))) {
        if ([string]::IsNullOrEmpty($spelling)) { continue }
        $index = $Text.IndexOf($spelling, [System.StringComparison]::OrdinalIgnoreCase)
        while ($index -ge 0) {
            $after = $index + $spelling.Length
            if ($after -ge $Text.Length) { return $true }
            if ([System.Array]::IndexOf($boundary, $Text[$after]) -ge 0) { return $true }
            $index = $Text.IndexOf($spelling, $after, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }
    return $false
}

# Rewrites every sync-group route end that named the old root, and the display
# names derived from it. Route IDS and the profile ID are deliberately left
# alone: the profile id is minted once at creation and used everywhere else as
# an opaque key (records and installed engines reference it), and a route id is
# written into the engine's own sync state - renaming either orphans live state
# for a label no user output shows.
function Update-SyncConfigRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$OldRoot,
        [Parameter(Mandatory = $true)][string]$NewRoot
    )
    $changed = [pscustomobject]@{ Roots = 0; Names = 0; Profiles = 0 }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $changed }

    $config = $null
    try { $config = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { return $changed }
    if ($null -eq $config -or $null -eq $config.PSObject.Properties['profiles']) { return $changed }

    $oldLeaf = Split-Path -Leaf $OldRoot
    $newLeaf = Split-Path -Leaf $NewRoot
    foreach ($profile in @($config.profiles)) {
        foreach ($route in @($profile.routes)) {
            foreach ($end in @('source', 'destination')) {
                $node = $route.$end
                if ($null -eq $node) { continue }
                if ($null -ne $node.PSObject.Properties['root'] -and
                    [string]::Equals([string]$node.root, $OldRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Set-ObjectProperty -Object $node -Name 'root' -Value $NewRoot
                    $changed.Roots++
                }
                if ($null -ne $node.PSObject.Properties['name'] -and [string]$node.name -eq $oldLeaf) {
                    Set-ObjectProperty -Object $node -Name 'name' -Value $newLeaf
                    $changed.Names++
                }
            }
        }
        if ($null -ne $profile.PSObject.Properties['name'] -and [string]$profile.name -like ('*' + $oldLeaf + '*')) {
            Set-ObjectProperty -Object $profile -Name 'name' -Value ([string]$profile.name).Replace($oldLeaf, $newLeaf)
            $changed.Profiles++
        }
    }
    if ($changed.Roots -gt 0 -or $changed.Names -gt 0 -or $changed.Profiles -gt 0) {
        Write-JsonFileAtomic -Value $config -Path $ConfigPath
    }
    return $changed
}

# The interactive flow. Mirrors the other management actions: it names exactly
# what it will touch, defaults the confirmation to No, and reports per component.
function Invoke-FixRelocatedProject {
    Write-Log 'INFO' 'RELOCATE' 'Fix a renamed or moved project started.'
    Write-PhaseHeader 'Fix a Renamed or Moved Project' $C.Input '-'

    $candidates = @(Get-RelocationCandidate -ToolRoot $ToolRoot -ConfigPath $ConfigPath)
    if ($candidates.Count -eq 0) {
        Write-NoteLine '  Every tracked project folder still exists - nothing looks moved.'
        Write-NoteLine '  This action only offers project roots the registry or a sync route names that are NOT on disk.'
        Write-Log 'INFO' 'RELOCATE' 'No missing project roots.'
        return 'back'
    }

    Write-MenuTitle 'Tracked project folders that no longer exist:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $entry = $candidates[$i]
        $what = [string]@($entry.Records).Count + ' hook(s)'
        if (@($entry.Records).Count -eq 0) { $what = 'sync routes only' }
        Write-Host ('  ' + (Get-Painted ([string]($i + 1) + '.') $C.LightBlue) + ' ' +
            (Get-Painted $entry.Root $C.Bold) + $script:MenuSep +
            (Get-Painted $what $C.HintYellow))
    }
    Write-NoteLine '  A folder listed here was renamed, moved, or deleted. Only you know which.'
    $answer = Read-Answer (New-QuestionPrompt 'Which one moved? (number, 0 to cancel)' $null '0') 'relocate pick'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq '0') { return 'back' }
    $pick = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$pick) -or $pick -lt 1 -or $pick -gt $candidates.Count) {
        Write-ErrorLine ('Not one of 1-' + $candidates.Count + '.')
        return 'back'
    }
    $chosen = $candidates[$pick - 1]
    $oldRoot = [string]$chosen.Root

    $newAnswer = Read-Answer (New-QuestionPrompt 'Its new full path' $null '') 'relocate new path'
    if ([string]::IsNullOrWhiteSpace($newAnswer)) { return 'back' }
    $newRoot = $newAnswer.Trim().Trim('"')
    try { $newRoot = Normalize-Path $newRoot } catch { Write-ErrorLine ('Not a usable path: ' + $newAnswer); return 'back' }
    if (-not (Test-Path -LiteralPath $newRoot -PathType Container)) {
        Write-ErrorLine ('That folder does not exist: ' + $newRoot)
        return 'back'
    }
    if ([string]::Equals($newRoot, $oldRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ErrorLine 'That is the same path.'
        return 'back'
    }

    $records = @($chosen.Records)
    $clientCount = 0
    foreach ($record in $records) { $clientCount += @(Get-InstalledClientNames -Record $record).Count }

    Write-Host ''
    Write-NoteLine ('  From: ' + $oldRoot)
    Write-NoteLine ('  To  : ' + $newRoot)
    Write-NoteLine ('  Reinstall ' + $records.Count + ' hook(s) across ' + $clientCount + ' client registration(s) at the new path.')
    Write-NoteLine ('  Drop ' + $records.Count + ' stale registry record(s) naming the old path.')

    Write-NoteLine '  Hook SOURCES are never touched. Nothing outside these two folders is written.'
    # Defaults to YES: the user already picked the project and typed the new
    # path, so Enter should carry that through rather than throw it away.
    if (-not (Read-YesNo (New-QuestionPrompt 'Proceed?' $null 'y') $true 'relocate confirm')) {
        Write-NoteLine '  Cancelled - nothing was changed.'
        return 'back'
    }

    $installed = 0; $installFailed = 0
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($record in $records) {
        $friendly = [string]$record.friendlyName
        foreach ($client in @(Get-InstalledClientNames -Record $record)) {
            $subrecord = Get-ClientSubrecord -Record $record -Client $client
            $events = @()
            if ($null -ne $subrecord -and $null -ne $subrecord.PSObject.Properties['events']) { $events = @($subrecord.events) }
            if ($events.Count -eq 0) {
                $installFailed++; [void]$failures.Add($friendly + '/' + $client + ': no recorded events'); continue
            }
            # Per client, with that client's OWN events - the shape the updater
            # uses to repair a record. A union would re-add events a reduced
            # client (Kiro has no SubagentStop) never had.
            $installArgs = @{ Events = @($events); TargetProject = $newRoot }
            if ([string]$record.hookType -eq 'Engine') {
                $installArgs['Profile'] = [string]$record.profile
                $installArgs['ConfigPath'] = [string]$record.configPath
            }
            else {
                $installArgs['CustomHook'] = [string]$record.sourceScript
            }
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-relocate-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
            $installArgs['ResultPath'] = $resultPath
            try {
                $output = & $InstallScript @installArgs -Clients @($client) *>&1
                foreach ($line in @($output)) { Write-Log 'INFO' 'RELOCATE' ([string]$line) }
                $result = $null
                if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                }
                $overall = ''
                if ($null -ne $result) { $overall = [string]$result.overall }
                if ($overall -eq 'ok' -or $overall -eq 'partial') { $installed++ }
                else {
                    $installFailed++
                    $detail = 'no result document'
                    if ($overall -ne '') { $detail = $overall }
                    [void]$failures.Add($friendly + '/' + $client + ': ' + $detail)
                }
            }
            catch {
                $installFailed++; [void]$failures.Add($friendly + '/' + $client + ': ' + $_.Exception.Message)
            }
            finally { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
        }
    }

    # No supported client writes a per-hook document, so relocation has nothing
    # of that shape to supersede: the reinstall below rewrites the shared
    # settings files in place.
    $documentsRemoved = 0

    $dropped = 0; $dropFailed = 0
    foreach ($record in $records) {
        $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-relocate-un-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
        try {
            & $UninstallScript -RecordId ([string]$record.id) -ResultPath $resultPath *> $null
            $result = $null
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            }
            if ($null -ne $result -and [string]$result.overall -eq 'ok') { $dropped++ }
            else {
                $dropFailed++
                $detail = 'no result document'
                if ($null -ne $result) { $detail = [string]$result.overall }
                [void]$failures.Add('record ' + [string]$record.id + ' (' + [string]$record.friendlyName + '): ' + $detail)
            }
        }
        catch { $dropFailed++; [void]$failures.Add('record ' + [string]$record.id + ': ' + $_.Exception.Message) }
        finally { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
    }

    $configChange = Update-SyncConfigRoot -ConfigPath $ConfigPath -OldRoot $oldRoot -NewRoot $newRoot

    Write-Host ''
    Write-NoteLine ('  Reinstalled at the new path : ' + $installed + ' registration(s)')
    Write-NoteLine ('  Stale records dropped       : ' + $dropped + ' of ' + $records.Count)
    if ($documentsRemoved -gt 0) { Write-NoteLine ('  Stale documents removed     : ' + $documentsRemoved) }
    if ($configChange.Roots -gt 0 -or $configChange.Names -gt 0) {
        Write-NoteLine ('  Sync routes repointed       : ' + $configChange.Roots + ' root(s), ' + $configChange.Names + ' name(s)')
        Write-NoteLine '  Run "Update installed hooks" so every other project in that group picks the change up.'
    }
    if ($installFailed -gt 0 -or $dropFailed -gt 0 -or $failures.Count -gt 0) {
        Write-ErrorLine ('  Problems: ' + $failures.Count)
        foreach ($failure in $failures) { Write-NoteLine ('    ' + $failure) }
        Write-Log 'ERROR' 'RELOCATE' ('Relocation finished with ' + $failures.Count + ' problem(s).')
    }
    else {
        Write-Log 'INFO' 'RELOCATE' ('Relocation complete: ' + $installed + ' reinstalled, ' + $dropped + ' records dropped.')
    }
    return 'done'
}
