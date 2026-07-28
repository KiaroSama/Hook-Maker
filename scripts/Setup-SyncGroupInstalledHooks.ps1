# Installed-hook management screens for the wizard: the shared numeric-selection
# parser, the installed-hook snapshot/list model, and the interactive uninstall
# flow behind the hook list's [manage] items (update, and uninstall).
#
# Split out of Setup-SyncGroup.ps1 as its own responsibility: everything here is
# about installations that ALREADY exist (reading the registry, presenting what
# is installed where, and removing selected installs), which is a different
# concern from the wizard's create/install flows. The actual removal work is
# delegated to an executor - scripts\Uninstall-Hook.ps1 for MANAGED records,
# scripts\Uninstall-DiscoveredHook.ps1 for DISCOVERED ones - and this file is UI
# orchestration only, performing no destructive filesystem or registry mutation
# itself.
#
# The registry holds two kinds of record (schema 3) and they are NOT
# interchangeable:
#   * 'managed'    - Hook Maker installed it, so ownership is provable from the
#                    install plan, and Uninstall-Hook.ps1's settled safety
#                    contract applies.
#   * 'discovered' - a status scan FOUND it on disk. Ownership is never assumed;
#                    removal is gated on the scan's fingerprints/hashes still
#                    matching exactly, which is a different proof and therefore
#                    a different executor.
# Routing a record to the wrong executor would bypass the proofs the other one
# depends on, so record type decides the executor - never the friendly name and
# never the row's position in the list.
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

# ---- record-type helpers ---------------------------------------------------

# A record written before schema 3 carries no recordType and is, by definition,
# one Hook Maker installed itself. Defaulting to 'managed' keeps every existing
# record routed to the executor whose safety contract already covers it.
function Get-RecordType {
    param($Record)
    $value = Get-RecordDisplayField $Record 'recordType' 'managed'
    if ($value -eq 'discovered') { return 'discovered' }
    return 'managed'
}

# WHERE does this record actually live? A native Git hook is a single file and
# that exact path is the only useful answer; everything else is identified by
# the project it was installed into, or by being global. Used wherever an
# outcome needs a human to go and look at something.
function Get-RecordLocationText {
    param($Record)
    if ($null -eq $Record) { return '(unknown location)' }
    $native = $Record.PSObject.Properties['nativeGit']
    if ($null -ne $native -and $null -ne $native.Value -and
        $null -ne $native.Value.PSObject.Properties['hookPath']) {
        $hookPath = [string]$native.Value.hookPath
        if (-not [string]::IsNullOrWhiteSpace($hookPath)) { return $hookPath }
    }
    # Read the two fields directly rather than through Get-RecordDisplayField:
    # this helper is called from outcome reporting and from tests, and must not
    # depend on the wider UI scope being loaded to answer "where is it".
    $scope = $Record.PSObject.Properties['scope']
    if ($null -ne $scope -and [string]$scope.Value -eq 'global') { return 'global (user profile)' }
    $target = $Record.PSObject.Properties['targetProjectRoot']
    if ($null -ne $target -and -not [string]::IsNullOrWhiteSpace([string]$target.Value)) { return [string]$target.Value }
    return '(unknown location)'
}

# Can this DISCOVERED record be removed automatically, and if not, why not?
#
# Discovered records are found, not installed, so the scan itself records how
# far removal can safely go. Anything short of a clear answer is shown as
# non-removable with the reason visible - never quietly dropped from the list
# (which would hide a real installed hook) and never silently included in a
# bulk "remove everything here" row.
function Get-DiscoveredRemovalCapability {
    param($Record)

    if ($null -ne $Record -and $null -ne $Record.PSObject.Properties['needsManualRepair'] -and $Record.needsManualRepair -eq $true) {
        return [pscustomobject]@{ Removable = $false; Capability = 'manual review'; Reason = 'manual repair: the scan flagged this record for review' }
    }
    $status = Get-RecordDisplayField $Record 'status' 'unknown'
    if (@('ambiguous', 'manualRepair', 'orphanCandidate') -contains $status) {
        $reason = Get-RecordDisplayField $Record 'statusReason' ''
        $detail = if ([string]::IsNullOrWhiteSpace($reason)) { $status } else { $status + ' - ' + $reason }
        return [pscustomobject]@{ Removable = $false; Capability = 'manual review'; Reason = ('not removable: ' + $detail) }
    }
    $policy = Get-RecordDisplayField $Record 'removalPolicy' 'unavailable'
    switch ($policy) {
        'full' { return [pscustomobject]@{ Removable = $true; Capability = 'registration + runtime'; Reason = '' } }
        'registrationOnly' { return [pscustomobject]@{ Removable = $true; Capability = 'registration only (runtime preserved)'; Reason = '' } }
        'nativeFileOnly' { return [pscustomobject]@{ Removable = $true; Capability = 'native hook file'; Reason = '' } }
        default {
            return [pscustomobject]@{ Removable = $false; Capability = 'manual review'; Reason = ('not removable: removal policy is ' + $policy) }
        }
    }
}

# Per-client events for display. The two record shapes store this differently -
# managed records keep a clients OBJECT keyed by client name, discovered records
# keep an ARRAY of per-client evidence - so the list model normalizes both into
# one shape here rather than teaching the renderer about either.
function Get-DiscoveredClientEvents {
    param($Record)
    $clients = @()
    $eventsByClient = @{}
    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties['clients'] -or $null -eq $Record.clients) {
        return [pscustomobject]@{ Clients = $clients; EventsByClient = $eventsByClient }
    }
    foreach ($evidence in @($Record.clients)) {
        if ($null -eq $evidence -or $null -eq $evidence.PSObject.Properties['client']) { continue }
        $name = [string]$evidence.client
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $clients += $name
        $events = @()
        if ($null -ne $evidence.PSObject.Properties['events'] -and $null -ne $evidence.events) {
            $events = @($evidence.events | ForEach-Object { [string]$_ })
        }
        $eventsByClient[$name] = $events
    }
    return [pscustomobject]@{ Clients = $clients; EventsByClient = $eventsByClient }
}

# ---- installed-hook snapshot ----------------------------------------------
# Builds the numbered rows shown by the uninstall screen:
#   * one INDIVIDUAL row per logical record - managed installs, discovered
#     external registrations, discovered native Git hooks, and the ambiguous /
#     orphan ones that are shown but explicitly NOT removable,
#   * then one AGGREGATE row per distinct project root,
#   * then a global aggregate row when any global record exists.
#
# Aggregate rows carry the exact record ids they expand to, so selecting an
# aggregate together with one of its own individual rows deduplicates by id
# rather than attempting the same removal twice. They include managed records
# and SAFELY REMOVABLE discovered ones, and exclude every record needing manual
# review: a bulk row must never become a way to remove something the individual
# row refuses to remove.
#
# A malformed record is never allowed to crash the list: it is shown as a
# non-removable manual-repair entry with a precise reason, exactly like the
# update flow treats it.
function Get-InstalledHookSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        # When set, only records installed into this folder - or into a folder
        # inside it - are listed. Global-scope records are dropped entirely: a
        # project filter asks about one tree, and a global hook lives in none.
        # The aggregates below are built from what survives this filter, so the
        # "remove all" row means "all of THIS project", not all of everything.
        [string]$ProjectFilter = ''
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $byProject = @{}
    $globalIds = New-Object System.Collections.Generic.List[string]
    $aggregatedIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($record in @($Registry.installs)) {
        $recordId = ''
        if ($null -ne $record -and $null -ne $record.PSObject.Properties['id']) { $recordId = [string]$record.id }
        $recordType = Get-RecordType $record
        $friendly = Get-RecordDisplayField $record 'friendlyName' 'unknown-record'
        $hookType = Get-RecordDisplayField $record 'hookType' '(unknown type)'
        $scope = Get-RecordDisplayField $record 'scope' 'unknown'
        $targetRoot = Get-RecordDisplayField $record 'targetProjectRoot' ''
        $profileId = Get-RecordDisplayField $record 'profile' ''

        if (-not [string]::IsNullOrWhiteSpace($ProjectFilter)) {
            if ($scope -eq 'global') { continue }
            if (-not (Test-PathContainedIn -ChildPath $targetRoot -ParentPath $ProjectFilter)) { continue }
        }

        if ($recordType -eq 'discovered') {
            # Discovered: the source is the place it was FOUND, not a hook file
            # this tool shipped, so the row shows that instead of a sourceScript.
            $capability = Get-DiscoveredRemovalCapability $record
            $clientInfo = Get-DiscoveredClientEvents $record
            $sourceScript = '(found by scan - not installed by Hook Maker)'
            if ($null -ne $record.PSObject.Properties['nativeGit'] -and $null -ne $record.nativeGit -and
                $null -ne $record.nativeGit.PSObject.Properties['hookPath']) {
                $hookPath = [string]$record.nativeGit.hookPath
                if (-not [string]::IsNullOrWhiteSpace($hookPath)) { $sourceScript = $hookPath }
            }
            $removable = ($capability.Removable -and -not [string]::IsNullOrWhiteSpace($recordId))
            [void]$rows.Add([pscustomobject]@{
                Kind           = 'record'
                RecordType     = 'discovered'
                RecordIds      = @($recordId)
                FriendlyName   = $friendly
                HookType       = $hookType
                Profile        = $profileId
                Scope          = $scope
                TargetRoot     = $targetRoot
                Clients        = @($clientInfo.Clients)
                EventsByClient = $clientInfo.EventsByClient
                SourceScript   = $sourceScript
                Removable      = $removable
                Capability     = $capability.Capability
                Detail         = $capability.Reason
            })
            if (-not $removable) { continue }
        }
        else {
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
                Kind           = 'record'
                RecordType     = 'managed'
                RecordIds      = @($recordId)
                FriendlyName   = $friendly
                HookType       = $hookType
                Profile        = $profileId
                Scope          = $scope
                TargetRoot     = $targetRoot
                Clients        = @($clients)
                EventsByClient = $eventsByClient
                SourceScript   = Get-RecordDisplayField $record 'sourceScript' '(unknown source)'
                Removable      = ($validation.Ok -and -not [string]::IsNullOrWhiteSpace($recordId))
                Capability     = 'registration + runtime'
                Detail         = if ($validation.Ok) { '' } else { 'manual repair: ' + $validation.Reason }
            })
            if (-not $validation.Ok -or [string]::IsNullOrWhiteSpace($recordId)) { continue }
        }

        # Only rows that reached here are removable, so only these ever join an
        # aggregate. The id set makes a duplicate id in the registry collapse to
        # one entry instead of being removed twice.
        if (-not $aggregatedIds.Add($recordId)) { continue }
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
            Kind           = 'project'
            RecordType     = 'mixed'
            RecordIds      = @($group.Ids.ToArray())
            FriendlyName   = ('Remove all removable hooks from project: ' + $group.Root)
            HookType       = ''
            Profile        = ''
            Scope          = 'project'
            TargetRoot     = $group.Root
            Clients        = @()
            EventsByClient = @{}
            SourceScript   = ''
            Removable      = $true
            Capability     = 'registration + runtime'
            Detail         = ('' + $group.Ids.Count + ' removable hook(s)')
        })
    }
    if ($globalIds.Count -gt 0) {
        [void]$rows.Add([pscustomobject]@{
            Kind           = 'global'
            RecordType     = 'mixed'
            RecordIds      = @($globalIds.ToArray())
            FriendlyName   = 'Remove all removable global hooks'
            HookType       = ''
            Profile        = ''
            Scope          = 'global'
            TargetRoot     = ''
            Clients        = @()
            EventsByClient = @{}
            SourceScript   = ''
            Removable      = $true
            Capability     = 'registration + runtime'
            Detail         = ('' + $globalIds.Count + ' removable hook(s)')
        })
    }
    return $rows.ToArray()
}

# Registry client keys are lowercase ('claude'/'codex'/'kiro'); the UI shows the
# capitalized client name. Shared by the list and confirmation screens below
# so the two never drift onto different capitalizations.
#
# The name comes from the ONE client capability table rather than a switch with
# a case per client. A switch silently falls through for any client added to
# the table later - which is exactly what happened to Kiro: it rendered as a
# bare lowercase 'kiro' next to 'Claude' and 'Codex'. An id the table does not
# know is still returned unchanged, exactly as the old default branch did, so a
# foreign or malformed record renders something rather than nothing.
function Get-ClientDisplayName {
    param([string]$Client)
    if ([string]::IsNullOrWhiteSpace($Client)) { return $Client }
    try { return [string](Get-HookMakerClientCapability -ClientId $Client).displayName }
    catch { return $Client }
}

# ---- list and uninstall installed hooks ------------------------------------
# Lists every tracked record, takes a numeric list/range selection over
# individual AND aggregate rows, shows exactly what would be removed, and only
# then delegates each record to its own executor by RECORD TYPE - managed to
# scripts\Uninstall-Hook.ps1, discovered to scripts\Uninstall-DiscoveredHook.ps1
# - each of which owns all the destructive work and its own ownership/rollback
# safety. Nothing here mutates the filesystem or the registry directly.
#
# Any exit that is not an explicit 'y' - n, 0/back, quit, or an invalid
# selection - performs NO mutation at all: no backups, no registry write, no
# runtime removal.
# Turns whatever the user typed into a folder path to match records against.
#
# The folder does NOT have to exist: the filter is compared to the paths the
# registry RECORDED, and removing the tracking for a project that has already
# been deleted is exactly when this is most useful. Surrounding quotes are
# stripped because a path pasted from Explorer usually arrives wrapped in them.
function Resolve-UninstallProjectFilter {
    param([string]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = 'Enter a folder path.' }
    }
    $text = $text.Trim().Trim('"').Trim("'").Trim()
    try {
        return [pscustomobject]@{ Ok = $true; Path = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($text)); Reason = '' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = ('Not a usable folder path: ' + $text) }
    }
}

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
    if (@(Get-InstalledHookSnapshot -Registry $registry).Count -eq 0) {
        Write-NoteLine '  No installed hooks are tracked yet - nothing to uninstall.'
        Write-Log 'INFO' 'UNINSTALL' 'No tracked installs.'
        return 'back'
    }

    # WHICH set first, then which rows. A machine that has been used for a while
    # holds hundreds of installs, and one flat list of all of them is not
    # something anyone can actually pick from - the numbers are meaningless
    # until the set is small enough to read.
    $outerScope = $true
    $projectFilter = ''
    $rows = @()
    while ($true) {
        if ($outerScope) {
            Write-MenuTitle 'What do you want to uninstall?'
            # The project route is first and is the default: on a machine with
            # hundreds of installs it is the only one that produces a list
            # anyone can pick from.
            Write-MenuLine 1 'Only the hooks in one project' '(you give the folder)'
            Write-MenuLine 2 'Every installed hook' '(one list of everything tracked)'
            $mode = Read-Answer (New-QuestionPrompt 'Choose' $null '1') 'uninstall scope'
            if ($mode -eq '') { $mode = '1' }
            if ($mode -eq '0') {
                Write-NoteLine 'Canceled. Nothing was changed.'
                Write-Log 'INFO' 'UNINSTALL' 'User left the uninstall scope menu; nothing was changed.'
                return 'back'
            }
            if ($mode -eq '1') {
                $answer = Read-Answer (New-QuestionPrompt 'Project folder' (
                        'example: ' + (Get-ExampleText 'G:\Projects\My App') + ' - subfolders are included') $null) 'uninstall project filter'
                if ($answer -eq '0' -or $answer -eq '') { continue }
                $resolvedFilter = Resolve-UninstallProjectFilter $answer
                if (-not $resolvedFilter.Ok) {
                    Write-ErrorLine $resolvedFilter.Reason
                    Write-Log 'WARNING' 'UNINSTALL' ('Rejected project folder: ' + $resolvedFilter.Reason)
                    continue
                }
                $projectFilter = $resolvedFilter.Path
            }
            elseif ($mode -eq '2') { $projectFilter = '' }
            else {
                Write-ErrorLine 'Enter 1 or 2.'
                continue
            }

            $rows = @(Get-InstalledHookSnapshot -Registry $registry -ProjectFilter $projectFilter)
            if ($rows.Count -eq 0) {
                # Not an error, and not a dead end: the folder simply has no
                # tracked installs, so the scope menu is offered again.
                Write-NoteLine ('  No tracked hooks are installed in ' + $projectFilter)
                Write-NoteLine '  Nothing was changed. Pick another folder, or list everything.'
                Write-Log 'INFO' 'UNINSTALL' ('Project folder matched no tracked installs: ' + $projectFilter)
                continue
            }
            Write-Log 'INFO' 'UNINSTALL' (
                'Scope: ' + $(if ($projectFilter -eq '') { 'every installed hook' } else { 'project ' + $projectFilter }) +
                '; rows=' + $rows.Count)
            $outerScope = $false
        }

        Write-MenuTitle 'Installed hooks:'
        if ($projectFilter -ne '') { Write-NoteLine ('  Showing only hooks installed in ' + $projectFilter) }
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
                # Record type and removal capability are shown for EVERY row:
                # "this was found, not installed" and "only the registration can
                # come off" both change what the user is agreeing to, so neither
                # may be something they have to infer from the name.
                $recordTypeColor = if ($row.RecordType -eq 'discovered') { $C.Amber } else { $C.Gray }
                $capabilityColor = if ($row.Removable) { $C.Gray } else { $C.Red }
                Write-Host ('     ' + (Get-Painted 'record:' $C.Gray) + ' ' + (Get-Painted $row.RecordType $recordTypeColor) +
                    $script:MenuSep + (Get-Painted ('removal: ' + $row.Capability) $capabilityColor))

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
        Write-NoteLine '  To clear one project in one pick, use its "Remove all removable hooks from project:" row - those are listed last, just above.'

        # When the screen offers exactly ONE "remove all" row - which is what a
        # project scope always produces - that row is the default, because it is
        # the answer this screen exists to give. With several of them (the
        # whole-machine list has one per project) there is no single "all", so
        # the default stays 0 and Enter cancels as before. Either way the y/n
        # confirmation still defaults to No, so Enter twice changes nothing.
        $aggregateNumbers = @()
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Kind -ne 'record') { $aggregateNumbers += ($i + 1) }
        }
        $defaultSelection = if ($aggregateNumbers.Count -eq 1) { [string]$aggregateNumbers[0] } else { '0' }

        $value = Read-Answer (New-QuestionPrompt 'Select what to uninstall (number, list, or range)' $null $defaultSelection) 'select uninstall targets'
        if ($value -eq '') { $value = $defaultSelection }
        if ($value -eq '0') { Write-NoteLine 'Canceled. Nothing was changed.'; return 'back' }

        $parsed = Expand-MenuSelection -Value $value -MaxIndex $rows.Count
        # A refused selection removes NOTHING, so it must be visible in the log.
        # Round 40 spent a whole diagnosis reconstructing which of two refusals
        # fired, because both wrote to the console only and the log recorded the
        # input but never the outcome.
        if (-not $parsed.Ok) {
            Write-ErrorLine $parsed.Reason
            Write-Log 'WARNING' 'UNINSTALL' ('Selection refused: ' + $parsed.Reason + ' rows=' + $rows.Count)
            continue
        }

        # Expand every picked row to its record ids and DEDUPLICATE: selecting a
        # project aggregate together with one of its own individual rows must
        # remove each record exactly once, not twice.
        $picked = @($parsed.Indices | ForEach-Object { $rows[$_ - 1] })
        # A record that needs manual repair is SKIPPED, never a veto over the
        # rest of the selection. Rejecting the whole batch made a broad pick
        # useless in practice: selecting 370 rows with 3 unrepairable ones
        # removed NOTHING and simply re-asked, so the only way forward was to
        # hand-compute the gaps. The executor below already reports every record
        # individually (removed / manual repair / partial / failed), so
        # proceeding with what CAN be removed loses no honesty - it just stops
        # three bad rows from holding the other 367 hostage.
        $blocked = @($picked | Where-Object { -not $_.Removable })
        $picked = @($picked | Where-Object { $_.Removable })
        if ($blocked.Count -gt 0) {
            Write-NoteLine ('  ' + $blocked.Count + ' selected record(s) need manual repair and are SKIPPED - the rest of the selection still proceeds:')
            foreach ($b in $blocked) { Write-NoteLine ('    ' + (Get-HookFriendlyName $b.FriendlyName) + ' - ' + $b.Detail) }
        }
        $recordIds = New-Object System.Collections.Generic.List[string]
        foreach ($row in $picked) {
            foreach ($id in @($row.RecordIds)) {
                if (-not [string]::IsNullOrWhiteSpace($id) -and -not $recordIds.Contains($id)) { [void]$recordIds.Add($id) }
            }
        }
        # Only when the WHOLE selection was unremovable is there nothing to do.
        if ($recordIds.Count -eq 0) {
            Write-ErrorLine 'Nothing removable was selected.'
            Write-Log 'WARNING' 'UNINSTALL' ('Selection refused: every selected record needs manual repair; selected=' + $blocked.Count)
            continue
        }

        # ---- confirmation: show exactly what will be touched, before anything ----
        Write-PhaseHeader 'Confirm Uninstall' $C.Confirm '-'
        foreach ($id in $recordIds) {
            $record = @($registry.installs | Where-Object { (Get-RecordDisplayField $_ 'id' '') -eq $id })[0]
            if ($null -eq $record) { continue }
            $recordType = Get-RecordType $record
            $hookType = Get-RecordDisplayField $record 'hookType' '(unknown type)'
            $profileId = Get-RecordDisplayField $record 'profile' ''
            $scopeText = if ((Get-RecordDisplayField $record 'scope') -eq 'global') { 'global' } else { Get-RecordDisplayField $record 'targetProjectRoot' '(unknown target)' }
            $label = Get-HookFriendlyName (Get-RecordDisplayField $record 'friendlyName' 'unknown-record')
            if (-not [string]::IsNullOrWhiteSpace($profileId)) { $label += ' [' + $profileId + ']' }
            Write-Host ('  ' + (Get-Painted $label $C.Bold) + $script:MenuSep + (Get-Painted $hookType $C.Aqua) + $script:MenuSep + (Get-Painted $scopeText $C.Gray))
            Write-Field '    record id' $id
            Write-Field '    record type' $recordType

            if ($recordType -eq 'discovered') {
                # Discovered evidence, not an install plan: what the scan saw,
                # and exactly how far removal will go. Nothing here is presented
                # as something Hook Maker owns.
                $capability = Get-DiscoveredRemovalCapability $record
                Write-Field '    removal' $capability.Capability $C.Amber
                $clientInfo = Get-DiscoveredClientEvents $record
                foreach ($client in @($clientInfo.Clients)) {
                    $events = @($clientInfo.EventsByClient[$client])
                    $eventsText = if ($events.Count -gt 0) { $events -join ', ' } else { '(none)' }
                    Write-Field ('    ' + (Get-ClientDisplayName $client) + ' events') $eventsText
                }
                foreach ($evidence in @($record.clients)) {
                    if ($null -eq $evidence -or $null -eq $evidence.PSObject.Properties['settingsPath']) { continue }
                    Write-Field ('    ' + (Get-ClientDisplayName (Get-RecordDisplayField $evidence 'client' '')) + ' settings') ([string]$evidence.settingsPath)
                }
                $discoveredNative = $null
                if ($null -ne $record.PSObject.Properties['nativeGit']) { $discoveredNative = $record.nativeGit }
                if ($null -ne $discoveredNative) {
                    Write-Field '    native Git hook' (Get-RecordDisplayField $discoveredNative 'hookPath' '(unknown path)') $C.Amber
                    Write-Field '    native Git classification' (Get-RecordDisplayField $discoveredNative 'classification' 'unknown')
                }
                else {
                    Write-Field '    native Git' 'no'
                }
                continue
            }

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
        # Record type decides the executor. Resolved per id from the registry
        # rather than carried on the row, so a stale row can never route a
        # managed record into the discovered remover (which cannot prove managed
        # ownership) or the reverse.
        $discoveredUninstallScript = Join-Path (Split-Path -Parent $UninstallScript) 'Uninstall-DiscoveredHook.ps1'
        foreach ($id in $recordIds) {
            $record = @($registry.installs | Where-Object { (Get-RecordDisplayField $_ 'id' '') -eq $id })[0]
            $executor = if ((Get-RecordType $record) -eq 'discovered') { $discoveredUninstallScript } else { $UninstallScript }
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $threw = $false
            try { & $executor -RecordId $id -ToolRoot $ToolRoot -ResultPath $resultPath *> $null }
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

            # A bare record id tells the user NOTHING about which hook this was or
            # where it lives, which is exactly what they need when a row asks for
            # manual repair - the id alone forced a registry lookup by hand. A
            # clean removal stays short; anything needing action names the file.
            $rowName = Get-HookFriendlyName (Get-RecordDisplayField $record 'friendlyName' 'unknown-record')
            $rowWhere = Get-RecordLocationText $record
            switch ($overall) {
                'ok' { [void]$removed.Add($id); Write-Host ('  ' + (Get-Painted 'removed' $C.Green) + ' ' + $rowName) }
                'manualRepair' {
                    [void]$manual.Add($id)
                    Write-Host ('  ' + (Get-Painted 'manual repair needed' $C.Amber) + ' ' + $rowName)
                    Write-Host ('      ' + (Get-Painted $rowWhere $C.Gray))
                    Write-Log 'WARNING' 'UNINSTALL' ('Manual repair needed: ' + $rowName + ' at ' + $rowWhere + ' (id ' + $id + ')')
                }
                # 'partial' is the discovered remover's honest middle outcome:
                # something really came off but not everything, so it must not be
                # reported as a clean removal.
                'partial' {
                    [void]$manual.Add($id)
                    Write-Host ('  ' + (Get-Painted 'partially removed - needs attention' $C.Amber) + ' ' + $rowName)
                    Write-Host ('      ' + (Get-Painted $rowWhere $C.Gray))
                    Write-Log 'WARNING' 'UNINSTALL' ('Partially removed: ' + $rowName + ' at ' + $rowWhere + ' (id ' + $id + ')')
                }
                default {
                    [void]$failed.Add($id)
                    Write-Host ('  ' + (Get-Painted 'failed' $C.Red) + ' ' + $rowName)
                    Write-Host ('      ' + (Get-Painted $rowWhere $C.Gray))
                    Write-Log 'ERROR' 'UNINSTALL' ('Uninstall failed: ' + $rowName + ' at ' + $rowWhere + ' (id ' + $id + ')')
                }
            }
        }
        Write-Host ''
        Write-Field 'removed' ([string]$removed.Count)
        Write-Field 'needs manual repair' ([string]$manual.Count)
        Write-Field 'failed' ([string]$failed.Count)
        # Skipped rows never reached the executor, so they appear in no other
        # count. Surfacing them here is what keeps "the rest still proceeds"
        # from quietly becoming "some of your selection vanished".
        if ($blocked.Count -gt 0) { Write-Field 'skipped (manual repair)' ([string]$blocked.Count) }
        if ($manual.Count -gt 0 -or $failed.Count -gt 0 -or $blocked.Count -gt 0) {
            Write-NoteLine '  Records that did not fully uninstall are KEPT in the registry so nothing is silently lost.'
        }
        Write-Log 'INFO' 'UNINSTALL' ('Uninstall finished: removed=' + $removed.Count + ' manual=' + $manual.Count + ' failed=' + $failed.Count + ' skipped=' + $blocked.Count)
        return 'done'
    }
}
