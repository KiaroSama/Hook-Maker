# ---------------------------------------------------------------------------
# Install registry SCHEMA MIGRATION: carrying a record written by an older
# build forward to the current schema, one version step at a time, plus the
# whole-document pass that applies those steps on read.
#
# Split out of _installregistry.ps1 at the 800-line ceiling. Migration is its
# own responsibility: every function here is a pure record-in / record-out step
# that must be idempotent, must never invent a value it cannot establish, and
# must never convert a record from one KIND into the other.
#
# The record-kind predicates the steps below ask (Test-IsDiscoveredRecord /
# Test-IsManagedRecord) are NOT migration - they describe what a record IS, are
# read all over the tool, and stay in _installregistry.ps1 with the rest of the
# record shape. Dot-sourcing puts both files in one script scope, so the calls
# resolve either way round.
#
# Load-order contract: never dot-sourced standalone.
# $script:InstallRegistrySchemaVersion is defined by _installlib.ps1 before
# _installregistry.ps1 pulls this file in.
# ---------------------------------------------------------------------------

# ---- v1 -> v2 migration ----------------------------------------------------

# v1 stored ONE shared events array plus clients='Claude'|'Codex'|'Both'
# inferred from runtime-file existence, which cannot represent two clients
# installed with different events. Migration rebuilds per-client subrecords and
# prefers each client's LIVE settings file as the authority for its events -
# the actual registration is ground truth, the v1 shared array is only a
# fallback. When neither can be established the record is flagged for manual
# repair rather than guessed at.
function ConvertTo-InstallRecordV2 {
    param([Parameter(Mandatory = $true)]$Record)
    if ($null -ne $Record.PSObject.Properties['schema'] -and [int]$Record.schema -ge 2) { return $Record }

    $legacyEvents = @()
    if ($null -ne $Record.PSObject.Properties['events'] -and $null -ne $Record.events) { $legacyEvents = @($Record.events) }
    $legacyClients = ''
    if ($null -ne $Record.PSObject.Properties['clients'] -and $Record.clients -is [string]) { $legacyClients = [string]$Record.clients }
    $profileId = ''
    if ($null -ne $Record.PSObject.Properties['profile']) { $profileId = [string]$Record.profile }

    $clients = [pscustomobject][ordered]@{}
    $needsManualRepair = $false
    foreach ($client in @('claude', 'codex')) {
        $wasInstalled = switch ($legacyClients) {
            'Both' { $true }
            'Claude' { $client -eq 'claude' }
            'Codex' { $client -eq 'codex' }
            default { $false }
        }
        if (-not $wasInstalled) { continue }
        $runtimeScript = ''
        $settingsPath = ''
        if ($client -eq 'claude') {
            if ($null -ne $Record.PSObject.Properties['claudeRuntimeScript']) { $runtimeScript = [string]$Record.claudeRuntimeScript }
            if ($null -ne $Record.PSObject.Properties['claudeSettingsPath']) { $settingsPath = [string]$Record.claudeSettingsPath }
        }
        else {
            if ($null -ne $Record.PSObject.Properties['codexRuntimeScript']) { $runtimeScript = [string]$Record.codexRuntimeScript }
            if ($null -ne $Record.PSObject.Properties['codexHooksPath']) { $settingsPath = [string]$Record.codexHooksPath }
        }
        if ([string]::IsNullOrWhiteSpace($runtimeScript) -or [string]::IsNullOrWhiteSpace($settingsPath)) {
            $needsManualRepair = $true
            continue
        }
        # Live registrations win over the ambiguous shared v1 array.
        $liveEvents = @()
        foreach ($registration in @(Get-HookRegistrations -SettingsPath $settingsPath -RuntimeScript $runtimeScript -ProfileId $profileId)) {
            if (@($liveEvents) -notcontains [string]$registration.EventName) { $liveEvents += [string]$registration.EventName }
        }
        $events = if (@($liveEvents).Count -gt 0) { @($liveEvents) } else { @($legacyEvents) }
        if (@($events).Count -eq 0) { $needsManualRepair = $true; continue }
        $runtimeRoot = ''
        if (-not [string]::IsNullOrWhiteSpace($runtimeScript)) { $runtimeRoot = Split-Path -Parent (Split-Path -Parent $runtimeScript) }
        $subrecord = [pscustomobject][ordered]@{
            installed         = $true
            settingsPath      = $settingsPath
            runtimeRoot       = $runtimeRoot
            runtimeScript     = $runtimeScript
            events            = @($events)
            command           = ''
            statusMessage     = ''
            timeout           = 60
            installedManifest = @()
            lastInstalledUtc  = if ($null -ne $Record.PSObject.Properties['lastInstalledUtc']) { [string]$Record.lastInstalledUtc } else { '' }
            lastResult        = 'migrated'
            lastError         = ''
            migratedFromV1    = $true
            eventsFromLive    = (@($liveEvents).Count -gt 0)
        }
        Set-ObjectProperty -Object $clients -Name $client -Value $subrecord
    }

    Set-ObjectProperty -Object $Record -Name 'schema' -Value 2
    Set-ObjectProperty -Object $Record -Name 'clients' -Value $clients
    Set-ObjectProperty -Object $Record -Name 'sourceManifest' -Value @()
    Set-ObjectProperty -Object $Record -Name 'needsManualRepair' -Value $needsManualRepair
    if (@(Get-InstalledClientNames -Record $Record).Count -eq 0) {
        Set-ObjectProperty -Object $Record -Name 'needsManualRepair' -Value $true
    }
    return $Record
}

# ---- v2 -> v3 migration ----------------------------------------------------

# v3 made the record kind EXPLICIT so managed installs and discovered findings
# can share one registry file. Nothing about a managed record's meaning changed,
# so this migration is purely additive and deterministic: it stamps recordType
# and origin and touches NOTHING else - not the id, not `schema` (a managed
# record is still schema 2), not history, not a single existing value.
#
# It is idempotent by construction (a record that already has both fields is
# returned untouched) and it never converts a discovered record into a managed
# one.
function ConvertTo-InstallRecordV3 {
    param([Parameter(Mandatory = $true)]$Record)
    if ($null -eq $Record -or $Record -isnot [psobject]) { return $Record }
    if (Test-IsDiscoveredRecord -Record $Record) { return $Record }
    if ($null -eq $Record.PSObject.Properties['recordType']) {
        Set-ObjectProperty -Object $Record -Name 'recordType' -Value 'managed'
    }
    if ($null -eq $Record.PSObject.Properties['origin']) {
        Set-ObjectProperty -Object $Record -Name 'origin' -Value 'hookMaker'
    }
    return $Record
}

function ConvertTo-InstallRegistryCurrent {
    param([Parameter(Mandatory = $true)]$Registry)
    $migrated = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Registry.installs)) {
        # Repair UTC timestamps on READ, not only on rescan. An older build
        # carried these forward with [string], which renders a deserialized
        # [datetime] in the current culture and destroys the ISO 8601 form. Doing
        # it here means an already-corrupted registry is usable immediately -
        # otherwise a record stays unremovable until something happens to rescan
        # it, which is exactly how 334 records became permanently stuck.
        # Only a zone-LESS STRING is repaired. A live [datetime] is already valid
        # (the field check accepts it), and a zone-bearing string is already ISO,
        # so touching either would rewrite healthy data and break the contract
        # that migration changes nothing but the two fields it adds.
        if ($null -ne $record) {
            foreach ($stampField in @('firstSeenUtc', 'lastSeenUtc', 'createdUtc')) {
                $stampProperty = $record.PSObject.Properties[$stampField]
                if ($null -eq $stampProperty) { continue }
                $stampValue = $stampProperty.Value
                if ($stampValue -is [string] -and -not [string]::IsNullOrWhiteSpace($stampValue) -and
                    $stampValue -notmatch '(Z|[+-]\d{2}:?\d{2})$') {
                    Set-ObjectProperty -Object $record -Name $stampField -Value (ConvertTo-RegistryUtcTimestamp -Value $stampValue)
                }
            }
        }
        # A discovered record is already current - it is only ever written by a
        # schema-3 writer - and must not be pushed through the v1->v2 managed
        # rebuild, which would try to read v1 client fields it never had.
        if (Test-IsDiscoveredRecord -Record $record) {
            [void]$migrated.Add($record)
            continue
        }
        # Already-current records skip both converters. This is not a shortcut
        # around them - it is their OWN early-return conditions, hoisted:
        # ConvertTo-InstallRecordV2 returns the record untouched when
        # schema >= 2, and ConvertTo-InstallRecordV3 only adds recordType and
        # origin when they are absent. A record satisfying all three is returned
        # unchanged by both, so the outcome is identical either way.
        #
        # What it saves is the CALLS. Measured on the real 525-record registry:
        # the whole migration pass cost 605 ms, of which the timestamp repair
        # above is 25 ms - the rest was ~1575 PowerShell function invocations
        # doing nothing. The timestamp repair still runs for every record, every
        # time: that is the check that unstuck 334 permanently-unremovable
        # records, and it is per-RECORD data that a current `version` says
        # nothing about.
        if ($null -ne $record -and
            $null -ne $record.PSObject.Properties['schema'] -and [int]$record.schema -ge 2 -and
            $null -ne $record.PSObject.Properties['recordType'] -and
            $null -ne $record.PSObject.Properties['origin']) {
            [void]$migrated.Add($record)
            continue
        }
        [void]$migrated.Add((ConvertTo-InstallRecordV3 -Record (ConvertTo-InstallRecordV2 -Record $record)))
    }
    Set-ObjectProperty -Object $Registry -Name 'installs' -Value @($migrated.ToArray())
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    return $Registry
}

