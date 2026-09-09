# ---------------------------------------------------------------------------
# Registration inspection: is ONE installation still registered exactly as
# its record says? The shared-settings walk (Claude/Codex: an object keyed
# by event name) is the only registration shape this tool writes. The Reason
# vocabulary is fixed - 'registration missing' | 'duplicate registration' |
# 'registration drifted' | 'stale registration' | 'current' - so every caller
# reads one answer set however the walk grows.
#
#
# Split out of _installlib.ps1 (the registration-inspection concern) so that
# file could stay a manageable size. _installlib.ps1 dot-sources this file
# itself, in the same scope, so every existing consumer keeps dot-sourcing
# ONLY _installlib.ps1 and needs zero changes.
#
# Load-order contract (this file is never dot-sourced standalone - it is
# always pulled in from inside _installlib.ps1, which enforces the order):
#   1. hooks\_hooklib.ps1            (Read-JsonFile)
#   2. scripts\_clientcapability.ps1
#      (Get-HookMakerClientCapability, Test-HookMakerEventMatcher -
#       _installlib.ps1 dot-sources it before this file, and
#       everything resolves at CALL time)
#
#   3. scripts\_installlib.ps1       (defines $script:DefaultHookTimeoutSeconds
#                                      in its header, THEN dot-sources this file)
#
# Nothing here mutates anything: read-only judgements over settings files
# and their entries. Foreign entries are ignored completely - they are
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
