# Installed-hook management screens for the wizard: the shared numeric-selection
# parser, the installed-hook snapshot/list model, and the interactive uninstall
# flow behind hook-list items 21 (update) and 22 (uninstall).
#
# Split out of Setup-SyncGroup.ps1 as its own responsibility: everything here is
# about installations that ALREADY exist (reading the registry, presenting what
# is installed where, and removing selected installs), which is a different
# concern from the wizard's create/install flows. The actual removal work is
# delegated to scripts\Uninstall-Hook.ps1 - this file is UI orchestration only
# and performs no destructive filesystem or registry mutation itself.
#
# Dot-sourced by Setup-SyncGroup.ps1, which supplies the UI primitives
# ($C, Write-PhaseHeader, Write-MenuTitle, Read-Answer, Write-Log, ...). The
# dependency is one-directional: this file never reaches back into a wizard
# menu flow. Expand-MenuSelection lives here because BOTH the hook-install menu
# and these screens parse the same list/range syntax, and the task requires one
# canonical parser rather than two that can silently drift apart.

# ---- canonical numeric-selection parser -----------------------------------
# Accepts a single integer, a comma list, inclusive ascending ranges, and any
# surrounding whitespace; removes duplicates while preserving first-seen order;
# rejects reversed ranges, out-of-bounds values and malformed tokens with a
# precise reason. Empty tokens between commas are skipped (so "1,,2" is "1,2"),
# but an input that yields NO indices at all is an error rather than a silent
# no-op.
function Expand-MenuSelection {
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)][int]$MaxIndex
    )
    $indices = New-Object System.Collections.Generic.List[int]
    if ($null -eq $Value) { $Value = '' }
    foreach ($token in @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })) {
        $single = 0
        if ([int]::TryParse($token, [ref]$single)) {
            if ($single -lt 1 -or $single -gt $MaxIndex) {
                return [pscustomobject]@{ Ok = $false; Indices = @(); Reason = ('Number out of range: ' + $single + ' (enter 1 to ' + $MaxIndex + ').') }
            }
            if (-not $indices.Contains($single)) { [void]$indices.Add($single) }
            continue
        }
        $range = [regex]::Match($token, '^(\d+)\s*-\s*(\d+)$')
        if (-not $range.Success) {
            return [pscustomobject]@{ Ok = $false; Indices = @(); Reason = ('Not a number or range: "' + $token + '" (use e.g. 1, 1,2 or 1,2,3-6).') }
        }
        $first = 0
        $last = 0
        if (-not [int]::TryParse($range.Groups[1].Value, [ref]$first) -or -not [int]::TryParse($range.Groups[2].Value, [ref]$last)) {
            return [pscustomobject]@{ Ok = $false; Indices = @(); Reason = ('Not a valid range: "' + $token + '".') }
        }
        if ($first -gt $last) {
            return [pscustomobject]@{ Ok = $false; Indices = @(); Reason = ('Reversed range: "' + $token + '" - ranges must ascend, e.g. ' + $last + '-' + $first + '.') }
        }
        if ($first -lt 1 -or $last -gt $MaxIndex) {
            return [pscustomobject]@{ Ok = $false; Indices = @(); Reason = ('Range out of bounds: "' + $token + '" (enter 1 to ' + $MaxIndex + ').') }
        }
        foreach ($idx in $first..$last) {
            if (-not $indices.Contains($idx)) { [void]$indices.Add($idx) }
        }
    }
    if ($indices.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Indices = @(); Reason = ('Enter a number, list or range between 1 and ' + $MaxIndex + '.') }
    }
    return [pscustomobject]@{ Ok = $true; Indices = @($indices.ToArray()); Reason = '' }
}

# ---- installed-hook snapshot ----------------------------------------------
# Builds the numbered rows shown by the uninstall screen:
#   * one INDIVIDUAL row per logical install record (removable or, when the
#     record cannot be interpreted safely, flagged for manual repair),
#   * then one AGGREGATE row per distinct project root,
#   * then a global aggregate row when any global record exists.
# Aggregate rows carry the exact record ids they expand to, so selecting an
# aggregate together with one of its own individual rows deduplicates by id
# rather than attempting the same removal twice.
#
# A malformed record is never allowed to crash the list: it is shown as a
# non-removable manual-repair entry with a precise reason, exactly like the
# update flow treats it.
function Get-InstalledHookSnapshot {
    param([Parameter(Mandatory = $true)]$Registry)

    $rows = New-Object System.Collections.Generic.List[object]
    $byProject = @{}
    $globalIds = New-Object System.Collections.Generic.List[string]

    foreach ($record in @($Registry.installs)) {
        $recordId = ''
        if ($null -ne $record -and $null -ne $record.PSObject.Properties['id']) { $recordId = [string]$record.id }
        $friendly = Get-RecordDisplayField $record 'friendlyName' 'unknown-record'
        $hookType = Get-RecordDisplayField $record 'hookType' '(unknown type)'
        $scope = Get-RecordDisplayField $record 'scope' 'unknown'
        $targetRoot = Get-RecordDisplayField $record 'targetProjectRoot' ''
        $profileId = Get-RecordDisplayField $record 'profile' ''
        $sourceScript = Get-RecordDisplayField $record 'sourceScript' '(unknown source)'

        $validation = Test-InstallRecordValid -Record $record
        $clients = @()
        $eventsByClient = @{}
        if ($validation.Ok) {
            foreach ($client in @(Get-InstalledClientNames -Record $record)) {
                $clients += $client
                $subrecord = Get-ClientSubrecord -Record $record -Client $client
                $eventsByClient[$client] = @($subrecord.events | ForEach-Object { [string]$_ })
            }
        }

        [void]$rows.Add([pscustomobject]@{
            Kind         = 'record'
            RecordIds    = @($recordId)
            FriendlyName = $friendly
            HookType     = $hookType
            Profile      = $profileId
            Scope        = $scope
            TargetRoot   = $targetRoot
            Clients      = @($clients)
            EventsByClient = $eventsByClient
            SourceScript = $sourceScript
            Removable    = ($validation.Ok -and -not [string]::IsNullOrWhiteSpace($recordId))
            Detail       = if ($validation.Ok) { '' } else { 'manual repair: ' + $validation.Reason }
        })

        if (-not $validation.Ok -or [string]::IsNullOrWhiteSpace($recordId)) { continue }
        if ($scope -eq 'global') {
            [void]$globalIds.Add($recordId)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($targetRoot)) {
            $key = $targetRoot.ToLowerInvariant()
            if (-not $byProject.ContainsKey($key)) {
                $byProject[$key] = [pscustomobject]@{ Root = $targetRoot; Ids = (New-Object System.Collections.Generic.List[string]) }
            }
            [void]$byProject[$key].Ids.Add($recordId)
        }
    }

    foreach ($key in @($byProject.Keys | Sort-Object)) {
        $group = $byProject[$key]
        [void]$rows.Add([pscustomobject]@{
            Kind         = 'project'
            RecordIds    = @($group.Ids.ToArray())
            FriendlyName = ('Remove all Hook Maker hooks from project: ' + $group.Root)
            HookType     = ''
            Profile      = ''
            Scope        = 'project'
            TargetRoot   = $group.Root
            Clients      = @()
            EventsByClient = @{}
            SourceScript = ''
            Removable    = $true
            Detail       = ('' + $group.Ids.Count + ' installed hook(s)')
        })
    }
    if ($globalIds.Count -gt 0) {
        [void]$rows.Add([pscustomobject]@{
            Kind         = 'global'
            RecordIds    = @($globalIds.ToArray())
            FriendlyName = 'Remove all global Hook Maker hooks'
            HookType     = ''
            Profile      = ''
            Scope        = 'global'
            TargetRoot   = ''
            Clients      = @()
            EventsByClient = @{}
            SourceScript = ''
            Removable    = $true
            Detail       = ('' + $globalIds.Count + ' installed hook(s)')
        })
    }
    return $rows.ToArray()
}

# Registry client keys are lowercase ('claude'/'codex'); the UI shows the
# capitalized client name. Shared by the list and confirmation screens below
# so the two never drift onto different capitalizations.
function Get-ClientDisplayName {
    param([string]$Client)
    switch ($Client) {
        'claude' { return 'Claude' }
        'codex' { return 'Codex' }
        default { return $Client }
    }
}

# ---- menu 22: list and uninstall installed hooks --------------------------
# Lists every tracked installation, takes a numeric list/range selection over
# individual AND aggregate rows, shows exactly what would be removed, and only
# then delegates each record to scripts\Uninstall-Hook.ps1 (which owns all the
# destructive work and its own ownership/rollback safety). Nothing here mutates
# the filesystem or the registry directly.
#
# Any exit that is not an explicit 'y' - n, 0/back, quit, or an invalid
# selection - performs NO mutation at all: no backups, no registry write, no
# runtime removal.
function Invoke-UninstallInstalledHooks {
    Write-Log 'INFO' 'UNINSTALL' 'Uninstall installed hooks started.'
    Write-PhaseHeader 'Uninstall Installed Hooks' $C.Input '-'

    # A corrupt registry must never read back as a quiet "nothing installed":
    # that would hide real installations. Report it and leave the file alone -
    # this screen never repairs or rewrites it.
    $registryState = Read-InstallRegistryState -ToolRoot $ToolRoot
    if ($registryState.State -eq 'corrupt') {
        Write-NoteLine ('  WARNING: the install registry could not be used: ' + $registryState.Reason)
        Write-NoteLine ('  File: ' + $registryState.Path)
        Write-NoteLine '  Nothing can be listed or removed until it is repaired. It has NOT been modified or deleted.'
        Write-Log 'ERROR' 'UNINSTALL' ('Registry unusable: ' + $registryState.Reason)
        return 'done'
    }

    $registry = Read-InstallRegistry -ToolRoot $ToolRoot
    $rows = @(Get-InstalledHookSnapshot -Registry $registry)
    if ($rows.Count -eq 0) {
        Write-NoteLine '  No installed hooks are tracked yet - nothing to uninstall.'
        Write-Log 'INFO' 'UNINSTALL' 'No tracked installs.'
        return 'back'
    }

    while ($true) {
        Write-MenuTitle 'Installed hooks:'
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = $rows[$i]
            $number = Get-Painted (([string]($i + 1)) + '.') $C.LightBlue
            if ($row.Kind -eq 'record') {
                # Individual install: a multi-line block, never truncated to one
                # line, so the full target path, per-client events and exact
                # source script are always visible before the user picks a number.
                $hookTypeText = if ([string]::IsNullOrWhiteSpace($row.HookType)) { '(unknown type)' } else { $row.HookType }
                $scopeWord = if ($row.Scope -eq 'global') { 'global' } else { 'project' }
                $label = Get-HookFriendlyName $row.FriendlyName
                if (-not [string]::IsNullOrWhiteSpace($row.Profile)) { $label += ' [' + $row.Profile + ']' }
                $headerLine = '  ' + $number + ' ' + (Get-Painted $label $C.Bold) + $script:MenuSep + (Get-Painted $hookTypeText $C.Aqua) + $script:MenuSep + (Get-Painted $scopeWord $C.Gray)
                Write-Host $headerLine

                $targetText = if ($row.Scope -eq 'global') { 'global' } elseif ([string]::IsNullOrWhiteSpace($row.TargetRoot)) { '(unknown target)' } else { $row.TargetRoot }
                Write-Host ('     ' + (Get-Painted 'target:' $C.Gray) + ' ' + $targetText)

                if (@($row.Clients).Count -gt 0) {
                    $clientParts = @(@($row.Clients) | ForEach-Object {
                        $events = @($row.EventsByClient[$_])
                        $eventsText = if ($events.Count -gt 0) { $events -join ', ' } else { '(none)' }
                        (Get-ClientDisplayName $_) + ' [' + $eventsText + ']'
                    })
                    $clientsText = $clientParts -join ' | '
                }
                else {
                    $clientsText = '(none)'
                }
                Write-Host ('     ' + (Get-Painted 'clients:' $C.Gray) + ' ' + (Get-Painted $clientsText $C.Aqua))
                Write-Host ('     ' + (Get-Painted 'source:' $C.Gray) + ' ' + $row.SourceScript)

                if (-not $row.Removable) {
                    Write-Host ('     ' + (Get-Painted $row.Detail $C.Red))
                }
            }
            else {
                # Aggregate rows keep their existing single-line description + count.
                Write-Host ('  ' + $number + ' ' + (Get-Painted $row.FriendlyName $C.Bold) + $script:MenuSep + (Get-Painted $row.Detail $C.Amber))
            }
        }
        Write-NoteLine '  Source hook files are NEVER deleted - only installed copies, registrations and tracking are removed.'
        Write-NoteLine '  Tip: use lists and ranges, e.g. 1  |  1,2  |  1,2,3-6'

        $value = Read-Answer (New-QuestionPrompt 'Select what to uninstall (number, list, or range)' $null '0') 'select uninstall targets'
        if ($value -eq '0' -or $value -eq '') { Write-NoteLine 'Canceled. Nothing was changed.'; return 'back' }

        $parsed = Expand-MenuSelection -Value $value -MaxIndex $rows.Count
        if (-not $parsed.Ok) { Write-ErrorLine $parsed.Reason; continue }

        # Expand every picked row to its record ids and DEDUPLICATE: selecting a
        # project aggregate together with one of its own individual rows must
        # remove each record exactly once, not twice.
        $picked = @($parsed.Indices | ForEach-Object { $rows[$_ - 1] })
        $blocked = @($picked | Where-Object { -not $_.Removable })
        if ($blocked.Count -gt 0) {
            Write-ErrorLine ('That selection includes ' + $blocked.Count + ' record(s) that need manual repair and cannot be uninstalled automatically.')
            foreach ($b in $blocked) { Write-NoteLine ('    ' + (Get-HookFriendlyName $b.FriendlyName) + ' - ' + $b.Detail) }
            continue
        }
        $recordIds = New-Object System.Collections.Generic.List[string]
        foreach ($row in $picked) {
            foreach ($id in @($row.RecordIds)) {
                if (-not [string]::IsNullOrWhiteSpace($id) -and -not $recordIds.Contains($id)) { [void]$recordIds.Add($id) }
            }
        }
        if ($recordIds.Count -eq 0) { Write-ErrorLine 'Nothing removable was selected.'; continue }

        # ---- confirmation: show exactly what will be touched, before anything ----
        Write-PhaseHeader 'Confirm Uninstall' $C.Confirm '-'
        foreach ($id in $recordIds) {
            $record = @($registry.installs | Where-Object { [string]$_.id -eq $id })[0]
            if ($null -eq $record) { continue }
            $hookType = Get-RecordDisplayField $record 'hookType' '(unknown type)'
            $profileId = Get-RecordDisplayField $record 'profile' ''
            $scopeText = if ((Get-RecordDisplayField $record 'scope') -eq 'global') { 'global' } else { Get-RecordDisplayField $record 'targetProjectRoot' '(unknown target)' }
            $label = Get-HookFriendlyName (Get-RecordDisplayField $record 'friendlyName' 'unknown-record')
            if (-not [string]::IsNullOrWhiteSpace($profileId)) { $label += ' [' + $profileId + ']' }
            Write-Host ('  ' + (Get-Painted $label $C.Bold) + $script:MenuSep + (Get-Painted $hookType $C.Aqua) + $script:MenuSep + (Get-Painted $scopeText $C.Gray))
            Write-Field '    record id' $id
            Write-Field '    source script' (Get-RecordDisplayField $record 'sourceScript' '(unknown source)')
            foreach ($client in @(Get-InstalledClientNames -Record $record)) {
                $subrecord = Get-ClientSubrecord -Record $record -Client $client
                $clientLabel = Get-ClientDisplayName $client
                $events = @($subrecord.events | ForEach-Object { [string]$_ })
                $eventsText = if ($events.Count -gt 0) { $events -join ', ' } else { '(none)' }
                Write-Field ('    ' + $clientLabel + ' events') $eventsText
                Write-Field ('    ' + $clientLabel + ' settings') ([string]$subrecord.settingsPath)
                Write-Field ('    ' + $clientLabel + ' runtime script') ([string]$subrecord.runtimeScript)
            }
            $native = $null
            if ($null -ne $record.PSObject.Properties['nativeGit']) { $native = $record.nativeGit }
            if ($null -ne $native -and $null -ne $native.PSObject.Properties['managed'] -and $native.managed -eq $true) {
                Write-Field '    native Git' 'yes - the managed pre-push chain is part of this install' $C.Amber
            }
            else {
                Write-Field '    native Git' 'no'
            }
        }
        Write-Host ''
        Write-Field 'installations to remove' ([string]$recordIds.Count)
        Write-NoteLine '  Hook SOURCE files under hooks\ are never deleted.'

        $confirm = Read-YesNo (New-QuestionPrompt ('Uninstall ' + $recordIds.Count + ' installation(s) now?') 'y/n' 'n') $false 'confirm uninstall'
        if ($null -eq $confirm -or $confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was changed.'
            Write-Log 'INFO' 'UNINSTALL' 'User declined at confirmation; no changes applied.'
            return 'done'
        }

        # ---- delegate each record to the executor ----
        Write-PhaseHeader 'Removing' $C.Process '-'
        $removed = New-Object System.Collections.Generic.List[string]
        $failed = New-Object System.Collections.Generic.List[string]
        $manual = New-Object System.Collections.Generic.List[string]
        foreach ($id in $recordIds) {
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $threw = $false
            try { & $UninstallScript -RecordId $id -ToolRoot $ToolRoot -ResultPath $resultPath *> $null }
            catch { $threw = $true }
            $overall = 'failed'
            if (Test-Path -LiteralPath $resultPath) {
                try {
                    $doc = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                    if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['overall']) { $overall = [string]$doc.overall }
                }
                catch { }
                Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
            }
            elseif (-not $threw) { $overall = 'failed' }

            switch ($overall) {
                'ok' { [void]$removed.Add($id); Write-Host ('  ' + (Get-Painted 'removed' $C.Green) + ' ' + $id) }
                'manualRepair' { [void]$manual.Add($id); Write-Host ('  ' + (Get-Painted 'manual repair needed' $C.Amber) + ' ' + $id) }
                default { [void]$failed.Add($id); Write-Host ('  ' + (Get-Painted 'failed' $C.Red) + ' ' + $id) }
            }
        }
        Write-Host ''
        Write-Field 'removed' ([string]$removed.Count)
        Write-Field 'needs manual repair' ([string]$manual.Count)
        Write-Field 'failed' ([string]$failed.Count)
        if ($manual.Count -gt 0 -or $failed.Count -gt 0) {
            Write-NoteLine '  Records that did not fully uninstall are KEPT in the registry so nothing is silently lost.'
        }
        Write-Log 'INFO' 'UNINSTALL' ('Uninstall finished: removed=' + $removed.Count + ' manual=' + $manual.Count + ' failed=' + $failed.Count)
        return 'done'
    }
}
