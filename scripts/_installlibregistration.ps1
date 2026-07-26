# ---------------------------------------------------------------------------
# Registration inspection: is ONE installation still registered exactly as
# its record says? The shared-settings walk (Claude/Codex: an object keyed
# by event name) and the per-hook-file walk (Kiro: {version, hooks:[...]}
# with hooks as an ARRAY) live side by side here because they answer the
# same question in the same Reason vocabulary - 'registration missing' |
# 'duplicate registration' | 'registration drifted' | 'stale registration'
# | 'current' - and must never be pointed at each other's file shape.
#
# Split out of _installlib.ps1 (the registration-inspection concern) so that
# file could stay a manageable size. _installlib.ps1 dot-sources this file
# itself, in the same scope, so every existing consumer keeps dot-sourcing
# ONLY _installlib.ps1 and needs zero changes.
#
# Load-order contract (this file is never dot-sourced standalone - it is
# always pulled in from inside _installlib.ps1, which enforces the order):
#   1. hooks\_hooklib.ps1            (Read-JsonFile)
#   2. scripts\_clientcapability.ps1 and scripts\_installkiro.ps1
#      (Get-HookMakerClientCapability, Test-HookMakerEventMatcher,
#       Resolve-KiroScopeRoot, Test-KiroManagedFileName, Test-KiroManagedFile,
#       Get-KiroEntryField - _installlib.ps1 dot-sources both before this
#       file, and everything resolves at CALL time)
#   3. scripts\_installlib.ps1       (defines $script:DefaultHookTimeoutSeconds
#                                      in its header, THEN dot-sources this file)
#
# Nothing here mutates anything: read-only judgements over settings files
# and Kiro hook documents. Foreign entries are ignored completely - they are
# not this installation's to be current or stale.
# ---------------------------------------------------------------------------

# ---- registration inspection ---------------------------------------------

# The matcher Install-Hook.ps1 writes for a given event (SessionStart is the
# only event that carries one).
function Get-ExpectedMatcher {
    param([Parameter(Mandatory = $true)][string]$EventName)
    if ($EventName -eq 'SessionStart') { return 'startup|resume|clear|compact' }
    return ''
}

# Finds every registration in a settings file that belongs to ONE logical
# install, identified by its exact managed runtime script path (the precise
# identity - the command Install-Hook.ps1 generated points at that copy) and,
# for the sync engine, the same -Profile.
function Get-HookRegistrations {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RuntimeScript,
        [string]$ProfileId = ''
    )
    $found = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($SettingsPath) -or -not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $found.ToArray()
    }
    $json = Read-JsonFile $SettingsPath
    if ($null -eq $json -or $null -eq $json.PSObject.Properties['hooks'] -or $null -eq $json.hooks) {
        return $found.ToArray()
    }
    $scriptMarker = '"' + $RuntimeScript + '"'
    $profileMarker = ''
    if (-not [string]::IsNullOrWhiteSpace($ProfileId)) { $profileMarker = '-Profile "' + $ProfileId + '"' }

    foreach ($eventProp in $json.hooks.PSObject.Properties) {
        foreach ($group in @($eventProp.Value)) {
            $matcher = ''
            if ($null -ne $group.PSObject.Properties['matcher']) { $matcher = [string]$group.matcher }
            # A foreign/hand-edited group with no `hooks` key has none to scan -
            # never a StrictMode crash, just zero registrations found here.
            $groupHandlers = @(if ($null -ne $group.PSObject.Properties['hooks']) { $group.hooks } else { @() })
            foreach ($handler in $groupHandlers) {
                $command = ''
                if ($null -ne $handler.PSObject.Properties['command']) { $command = [string]$handler.command }
                $commandWindows = ''
                if ($null -ne $handler.PSObject.Properties['commandWindows']) { $commandWindows = [string]$handler.commandWindows }
                $combined = $command + ' ' + $commandWindows
                if (-not $combined.Contains($scriptMarker)) { continue }
                if ($profileMarker -ne '' -and -not $combined.Contains($profileMarker)) { continue }
                $timeout = 0
                if ($null -ne $handler.PSObject.Properties['timeout']) { $timeout = [int]$handler.timeout }
                $handlerType = ''
                if ($null -ne $handler.PSObject.Properties['type']) { $handlerType = [string]$handler.type }
                $statusMessage = ''
                if ($null -ne $handler.PSObject.Properties['statusMessage']) { $statusMessage = [string]$handler.statusMessage }
                [void]$found.Add([pscustomobject]@{
                    EventName      = $eventProp.Name
                    Matcher        = $matcher
                    Command        = $command
                    CommandWindows = $commandWindows
                    Timeout        = $timeout
                    StatusMessage  = $statusMessage
                    HandlerType    = $handlerType
                })
            }
        }
    }
    return $found.ToArray()
}

# Verifies that one client's live registrations match what the record says was
# installed: every expected event present exactly once, correct matcher/
# command/timeout, no leftover registration on an event this install no longer
# uses. Returns a precise reason code, never a bare boolean.
function Test-ClientRegistrationState {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RuntimeScript,
        [Parameter(Mandatory = $true)][string[]]$ExpectedEvents,
        [string]$ProfileId = '',
        [string]$ExpectedCommand = '',
        # Each of these is verified on its own. They stay optional so records
        # written before these fields were tracked are not reported as drifted
        # for lacking an expectation.
        [string]$ExpectedCommandWindows = '',
        [string]$ExpectedHandlerType = '',
        [string]$ExpectedStatusMessage = '',
        [switch]$ExpectedStatusMessageKnown,
        # Per-hook, not universal: the caller passes what the RECORD says this
        # installation registered. The default only covers a caller that has no
        # recorded expectation at all.
        [int]$ExpectedTimeout = $script:DefaultHookTimeoutSeconds
    )
    $registrations = @(Get-HookRegistrations -SettingsPath $SettingsPath -RuntimeScript $RuntimeScript -ProfileId $ProfileId)
    $byEvent = @{}
    foreach ($registration in $registrations) {
        $key = [string]$registration.EventName
        if (-not $byEvent.ContainsKey($key)) { $byEvent[$key] = New-Object System.Collections.Generic.List[object] }
        [void]$byEvent[$key].Add($registration)
    }

    $expectedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($eventName in @($ExpectedEvents)) { [void]$expectedSet.Add($eventName) }

    foreach ($eventName in @($ExpectedEvents)) {
        if (-not $byEvent.ContainsKey($eventName)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registration missing'; Detail = ('no registration for ' + $eventName) }
        }
        if ($byEvent[$eventName].Count -gt 1) {
            return [pscustomobject]@{ Ok = $false; Reason = 'duplicate registration'; Detail = ($byEvent[$eventName].Count.ToString() + ' registrations for ' + $eventName) }
        }
        $registration = $byEvent[$eventName][0]
        $expectedMatcher = Get-ExpectedMatcher -EventName $eventName
        if ([string]$registration.Matcher -ne $expectedMatcher) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('matcher changed on ' + $eventName) }
        }
        if ($ExpectedTimeout -gt 0 -and [int]$registration.Timeout -ne $ExpectedTimeout) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('timeout changed on ' + $eventName) }
        }
        # EVERY installer-owned field is checked INDEPENDENTLY. The previous
        # check accepted the handler when EITHER command form matched, so a
        # corrupted Windows command stayed hidden behind a still-correct
        # portable one (Codex handlers carry both).
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) {
            if ([string]$registration.Command -ne $ExpectedCommand) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('command changed on ' + $eventName) }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCommandWindows)) {
            if ([string]$registration.CommandWindows -ne $ExpectedCommandWindows) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('commandWindows changed on ' + $eventName) }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedHandlerType)) {
            if ([string]$registration.HandlerType -ne $ExpectedHandlerType) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('handler type changed on ' + $eventName) }
            }
        }
        # statusMessage is owned only where the installer writes one (Codex).
        if ($ExpectedStatusMessageKnown) {
            if ([string]$registration.StatusMessage -ne $ExpectedStatusMessage) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('statusMessage changed on ' + $eventName) }
            }
        }
    }
    foreach ($eventName in @($byEvent.Keys)) {
        if (-not $expectedSet.Contains($eventName)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'stale registration'; Detail = ('leftover registration on ' + $eventName) }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'current'; Detail = '' }
}

# ---- Kiro: the per-hook-file registration ---------------------------------

# The ONE .kiro hooks directory a record's own scope resolves to.
#
# Derived, never read back from the record: a record that has drifted must not
# be able to point an update (or an uninstall) at some other directory. The
# persisted registrationPath is cross-checked against THIS value by the caller
# that needs the proof, rather than being used as the location to act on.
function Get-KiroRecordRegistrationDirectory {
    param([Parameter(Mandatory = $true)]$Record)
    $capability = Get-HookMakerClientCapability -ClientId 'kiro'
    $scope = [string]$Record.scope
    $targetProjectRoot = ''
    if ($null -ne $Record.PSObject.Properties['targetProjectRoot']) { $targetProjectRoot = [string]$Record.targetProjectRoot }
    $root = Resolve-KiroScopeRoot -Scope $scope -TargetProjectRoot $targetProjectRoot
    $relative = if ($scope -eq 'project') { [string]$capability.projectRegistration } else { [string]$capability.globalRegistration }
    return (Join-Path $root $relative)
}

# Is ONE Kiro installation still registered exactly as its record says?
#
# The shared-settings equivalent (Test-ClientRegistrationState) cannot be used
# here and must never be pointed at a Kiro file: a Kiro document is
# {version, hooks:[...]} with hooks as an ARRAY, whereas Get-HookRegistrations
# walks an object keyed by event name. It would find nothing, report
# "registration missing" on every evaluation, and the updater would reinstall
# Kiro on every single run - drift detection that always says "drifted" is the
# same as none.
#
# Everything asserted here comes from the RECORD, exactly as the shared check
# does it: a field an older record does not carry is not asserted rather than
# being reported as drift. Foreign entries in a shared file are ignored
# completely - they are not this installation's to be current or stale.
#
# Returns { Ok; Reason; Detail } with the same Reason vocabulary the shared
# check uses, so the updater's plan text does not have to special-case Kiro:
# 'registration missing' | 'duplicate registration' | 'registration drifted' |
# 'stale registration' | 'current'.
function Test-KiroRegistrationState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RegistrationDirectory,
        [Parameter(Mandatory = $true)][string]$ManagedId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedEntryNames,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedEvents,
        # Persisted logical->physical trigger pairs. Kiro renamed every trigger
        # between its CLI v2 and v1 schemas, so the mapping is data: a record
        # that carries it is checked against what it actually wrote, and one
        # that does not falls back to the canonical table.
        $PhysicalTriggers = @(),
        [string]$ExpectedCommand = '',
        [int]$ExpectedTimeout = $script:DefaultHookTimeoutSeconds,
        [bool]$ExpectedEnabled = $true
    )
    function New-KiroRegistrationVerdict {
        param([string]$Reason, [string]$Detail)
        return [pscustomobject]@{ Ok = ($Reason -eq 'current'); Reason = $Reason; Detail = $Detail }
    }

    if ([string]::IsNullOrWhiteSpace($RegistrationDirectory) -or -not (Test-Path -LiteralPath $RegistrationDirectory -PathType Container)) {
        return (New-KiroRegistrationVerdict 'registration missing' 'the .kiro hooks directory no longer exists')
    }

    # Which files in that directory can this installation prove are its own?
    $managedFiles = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $RegistrationDirectory -File -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-KiroManagedFileName -Path $file.FullName)) { continue }
        $classification = Test-KiroManagedFile -Path $file.FullName -ManagedId $ManagedId
        if ([string]$classification.Reason -ne 'managed') { continue }
        [void]$managedFiles.Add([pscustomobject]@{ Path = $file.FullName; Entries = @($classification.ManagedEntries) })
    }
    if ($managedFiles.Count -eq 0) {
        return (New-KiroRegistrationVerdict 'registration missing' 'no managed hook file carries this installation''s identity')
    }
    if ($managedFiles.Count -gt 1) {
        # Two files both claiming this identity fire the hook twice.
        return (New-KiroRegistrationVerdict 'duplicate registration' ($managedFiles.Count.ToString() + ' hook files carry this installation''s identity'))
    }

    $entries = @($managedFiles[0].Entries)
    $expectedNameSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($ExpectedEntryNames)) { [void]$expectedNameSet.Add($name) }

    $seenNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $entryName = [string](Get-KiroEntryField -Entry $entry -Name 'name')
        if (-not $expectedNameSet.Contains($entryName)) {
            return (New-KiroRegistrationVerdict 'stale registration' ('leftover managed entry ' + $entryName))
        }
        if (-not $seenNames.Add($entryName)) {
            return (New-KiroRegistrationVerdict 'duplicate registration' ('two entries named ' + $entryName))
        }
    }
    foreach ($name in @($ExpectedEntryNames)) {
        if (-not $seenNames.Contains($name)) {
            return (New-KiroRegistrationVerdict 'registration missing' ('no registration for ' + $name))
        }
    }

    # Expected physical triggers, and the logical event each maps back to (the
    # matcher rule is keyed by the LOGICAL event, not by Kiro's own name).
    $expectedTriggers = @{}
    foreach ($pair in @($PhysicalTriggers)) {
        if ($null -eq $pair) { continue }
        $logical = [string](Get-KiroEntryField -Entry $pair -Name 'logical')
        $physical = [string](Get-KiroEntryField -Entry $pair -Name 'physical')
        if ([string]::IsNullOrWhiteSpace($logical) -or [string]::IsNullOrWhiteSpace($physical)) { continue }
        $expectedTriggers[$physical] = $logical
    }
    if ($expectedTriggers.Count -eq 0) {
        $capability = Get-HookMakerClientCapability -ClientId 'kiro'
        foreach ($eventName in @($ExpectedEvents)) {
            $physical = $eventName
            if ($capability.physicalEventMap.ContainsKey($eventName)) { $physical = [string]$capability.physicalEventMap[$eventName] }
            $expectedTriggers[$physical] = $eventName
        }
    }

    $seenTriggers = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        $entryName = [string](Get-KiroEntryField -Entry $entry -Name 'name')
        $trigger = [string](Get-KiroEntryField -Entry $entry -Name 'trigger')
        if (-not $expectedTriggers.ContainsKey($trigger)) {
            return (New-KiroRegistrationVerdict 'registration drifted' ('trigger changed on ' + $entryName))
        }
        if (-not $seenTriggers.Add($trigger)) {
            return (New-KiroRegistrationVerdict 'duplicate registration' ($trigger + ' is registered twice'))
        }

        # An 'agent' action spawns no subprocess, so a Hook Maker runtime
        # registered that way would never run: the type is owned, not incidental.
        $action = Get-KiroEntryField -Entry $entry -Name 'action'
        if ($null -eq $action -or [string](Get-KiroEntryField -Entry $action -Name 'type') -cne 'command') {
            return (New-KiroRegistrationVerdict 'registration drifted' ('action type changed on ' + $entryName))
        }
        # Kiro entries do NOT all carry the same command: KIRO_PROTOCOL requires
        # the physical trigger to be passed explicitly (Kiro IDE documents no
        # stdin JSON, so a hook cannot infer which event fired), so the record's
        # persisted command is the shared LAUNCHER command and each entry
        # appends its own ' -Trigger <physical>' (Install-Hook.ps1, where the
        # per-trigger command is built). Both halves are owned: a wrong prefix
        # means the entry no longer targets our runtime, and a wrong or missing
        # trigger argument means the launcher would hand the hook the wrong
        # event - live registrations that look healthy and behave wrongly.
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) {
            $actualCommand = [string](Get-KiroEntryField -Entry $action -Name 'command')
            if (-not $actualCommand.StartsWith($ExpectedCommand, [System.StringComparison]::Ordinal)) {
                return (New-KiroRegistrationVerdict 'registration drifted' ('command changed on ' + $entryName))
            }
            $commandSuffix = $actualCommand.Substring($ExpectedCommand.Length).Trim()
            if ($commandSuffix -cne ('-Trigger ' + $trigger)) {
                return (New-KiroRegistrationVerdict 'registration drifted' ('trigger argument changed on ' + $entryName))
            }
        }
        if ($ExpectedTimeout -gt 0) {
            $actualTimeout = -1
            if (-not [int]::TryParse([string](Get-KiroEntryField -Entry $entry -Name 'timeout'), [ref]$actualTimeout) -or $actualTimeout -ne $ExpectedTimeout) {
                return (New-KiroRegistrationVerdict 'registration drifted' ('timeout changed on ' + $entryName))
            }
        }
        # Absent means Kiro's own default, which is enabled.
        $enabledValue = Get-KiroEntryField -Entry $entry -Name 'enabled'
        $actualEnabled = $true
        if ($null -ne $enabledValue) { $actualEnabled = [bool]$enabledValue }
        if ($actualEnabled -ne $ExpectedEnabled) {
            return (New-KiroRegistrationVerdict 'registration drifted' ('enabled changed on ' + $entryName))
        }
        # The matcher expectation is the canonical one for the LOGICAL event,
        # blanked wherever Kiro does not actually evaluate a matcher on that
        # trigger - a filter the client ignores must not be written, and one
        # that appears later is drift either way.
        $expectedMatcher = ''
        if (Test-HookMakerEventMatcher -ClientId 'kiro' -EventName ([string]$expectedTriggers[$trigger])) {
            $expectedMatcher = Get-ExpectedMatcher -EventName ([string]$expectedTriggers[$trigger])
        }
        if ([string](Get-KiroEntryField -Entry $entry -Name 'matcher') -ne $expectedMatcher) {
            return (New-KiroRegistrationVerdict 'registration drifted' ('matcher changed on ' + $entryName))
        }
    }

    return (New-KiroRegistrationVerdict 'current' '')
}
