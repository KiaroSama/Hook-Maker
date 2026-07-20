# ---------------------------------------------------------------------------
# Install registry persistence layer: how install records are stored,
# validated, locked, migrated, and written back to disk.
#
# Split out of _installlib.ps1 (the registry-persistence concern) so that
# file could stay a manageable size. _installlib.ps1 dot-sources this file
# itself, near its top, in the required load order - every existing
# consumer (Install-Hook.ps1, Setup-SyncGroup.ps1, Validate-Config.ps1,
# Uninstall-Hook.ps1, and the test suites) keeps dot-sourcing ONLY
# _installlib.ps1 and needs zero changes.
#
# Load-order contract (this file is never dot-sourced standalone - it is
# always pulled in from inside _installlib.ps1, which enforces the order):
#   1. hooks\_hooklib.ps1        (Get-ShortHash, Read-JsonFile,
#                                  Write-JsonFileAtomic, Set-ObjectProperty)
#   2. scripts\_installplan.ps1
#   3. scripts\_installlib.ps1   (defines $script:InstallRegistrySchemaVersion
#                                  in its header, THEN dot-sources this file)
#
# Cross-file note: $script:InstallRegistrySchemaVersion is defined in
# _installlib.ps1 (used there too, by Test-InstallRecordValid) and read by
# several functions below (New-EmptyInstallRegistry, Test-InstallRegistryShape,
# Save-InstallRegistry, ConvertTo-InstallRegistryCurrent). This works because
# dot-sourcing both files into the same caller puts them in one script scope -
# the definition stays with _installlib.ps1 since it is also read there.
#
# Registry file: <ToolRoot>\state\install-registry.json (git-ignored;
# $env:HOOKMAKER_STATE_DIR overrides the directory for test isolation).
# Stores ONLY paths, hashes, and install parameters - never .env values, hook
# stdin, prompt text, tool input, secrets, or any copied file's contents.
# ---------------------------------------------------------------------------

# The shared identity layer (Get-Sha256Hex, Get-CanonicalPathKey, ...). The
# discovered-record id MUST be computed with exactly the same hashing the
# scanner and the remover use, so it is reused here rather than reimplemented.
# Dot-sourcing it twice (Get-HookStatus.ps1 loads it directly) is harmless - it
# only defines functions and depends on nothing but the BCL.
. (Join-Path $PSScriptRoot '_hookdiscovery.ps1')

# ---- registry file: path, validation, quarantine, locking ------------------

function Get-InstallStateDirectory {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    if (-not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_STATE_DIR)) { return $env:HOOKMAKER_STATE_DIR }
    return (Join-Path $ToolRoot 'state')
}

function Get-InstallRegistryPath {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Join-Path (Get-InstallStateDirectory -ToolRoot $ToolRoot) 'install-registry.json')
}

function New-EmptyInstallRegistry {
    return [pscustomobject][ordered]@{ version = $script:InstallRegistrySchemaVersion; installs = @() }
}

# Structural validation, not merely "did JSON parse". A registry whose version
# is unsupported, or whose installs is not an array of records with a usable
# identity, is CORRUPT - it must never be silently treated as "nothing tracked
# yet" and then overwritten (that would destroy real install history).
function Test-InstallRegistryShape {
    param($Registry)
    if ($null -eq $Registry) { return [pscustomobject]@{ Ok = $false; Reason = 'registry is empty or unparsable' } }
    if ($Registry -isnot [System.Management.Automation.PSCustomObject]) { return [pscustomobject]@{ Ok = $false; Reason = 'registry root is not an object' } }
    if ($null -eq $Registry.PSObject.Properties['version']) { return [pscustomobject]@{ Ok = $false; Reason = 'registry has no version field' } }
    $version = 0
    if (-not [int]::TryParse([string]$Registry.version, [ref]$version)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('registry version is not a number: ' + [string]$Registry.version) }
    }
    if ($version -lt 1) { return [pscustomobject]@{ Ok = $false; Reason = ('registry version is out of range: ' + $version) } }
    if ($version -gt $script:InstallRegistrySchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('registry schema version ' + $version + ' is newer than this Hook Maker supports (' + $script:InstallRegistrySchemaVersion + ')') }
    }
    if ($null -eq $Registry.PSObject.Properties['installs'] -or $null -eq $Registry.installs) {
        return [pscustomobject]@{ Ok = $false; Reason = 'registry has no installs list' }
    }
    foreach ($record in @($Registry.installs)) {
        if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registry contains a non-object install record' }
        }
        if ($null -eq $record.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$record.id)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registry contains an install record with no id' }
        }
        if ($null -eq $record.PSObject.Properties['friendlyName'] -or [string]::IsNullOrWhiteSpace([string]$record.friendlyName)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('install record ' + [string]$record.id + ' has no friendlyName') }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Version = $version }
}

# Reads and validates without writing anything. State is one of:
#   missing | ok | corrupt
# A corrupt registry keeps its ORIGINAL bytes available to the caller so they
# can be preserved verbatim on quarantine.
function Read-InstallRegistryState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'missing'; Registry = (New-EmptyInstallRegistry); Path = $path; Reason = '' }
    }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
    catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = ('registry could not be read: ' + $_.Exception.Message) } }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        # A registry file that EXISTS but is empty/whitespace is an interrupted
        # or truncated write, not an absent registry: the previous contents may
        # have held real installs. Treat it as corrupt so it is quarantined
        # rather than silently overwritten. (An absent file is 'missing' above.)
        return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = 'registry file exists but is empty (interrupted or truncated write)' }
    }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = 'registry is not valid JSON' } }
    $shape = Test-InstallRegistryShape -Registry $parsed
    if (-not $shape.Ok) {
        return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = $shape.Reason }
    }
    return [pscustomobject]@{ State = 'ok'; Registry = $parsed; Path = $path; Reason = '' }
}

# Read-only accessor for callers that just want the records (the updater's
# plan, tests, reporting). A corrupt registry reads back as EMPTY here but is
# never written over by this function - mutation goes through
# Update-InstallRegistry, which quarantines first.
function Read-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $state = Read-InstallRegistryState -ToolRoot $ToolRoot
    if ($state.State -eq 'ok') { return (ConvertTo-InstallRegistryCurrent -Registry $state.Registry) }
    return (New-EmptyInstallRegistry)
}

function Save-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)]$Registry)
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    # A previous interrupted write can leave a stale .tmp beside the registry;
    # Write-JsonFileAtomic overwrites it, but clear it first so a partially
    # written file is never mistaken for real state by anything else.
    $stale = $path + '.tmp'
    if (Test-Path -LiteralPath $stale -PathType Leaf) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
    Write-JsonFileAtomic -Value $Registry -Path $path
}

# Preserves a corrupt registry's exact bytes under a collision-safe name
# instead of destroying it. Returns the quarantine path, or throws so the
# caller can leave the original untouched and report tracking failure.
function Move-CorruptInstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $shortHash = Get-ShortHash ([System.BitConverter]::ToString($bytes))
    $directory = Split-Path -Parent $path
    $candidate = Join-Path $directory ('install-registry.corrupt-' + $stamp + '-' + $shortHash + '.json')
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory ('install-registry.corrupt-' + $stamp + '-' + $shortHash + '-' + $suffix + '.json')
        $suffix++
        if ($suffix -gt 100) { throw 'Could not find a free quarantine name for the corrupt install registry.' }
    }
    # Copy-then-verify-then-remove: if anything fails the original is still
    # there, and the quarantine copy is proven byte-identical before the
    # original is released.
    [System.IO.File]::WriteAllBytes($candidate, $bytes)
    $written = [System.IO.File]::ReadAllBytes($candidate)
    if ($written.Length -ne $bytes.Length) { throw 'Quarantine copy of the install registry does not match the original.' }
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($written[$i] -ne $bytes[$i]) { throw 'Quarantine copy of the install registry does not match the original.' }
    }
    Remove-Item -LiteralPath $path -Force
    return $candidate
}

# Crash-aware exclusive lock.
#
# A plain CreateNew lock file is permanently fatal: if the owning process is
# killed, the file survives and every future write fails forever. This keeps
# the file OPEN with FileShare.None for as long as the lock is held, so the OS
# releases the handle when the owner dies - which is what makes a leftover file
# distinguishable from a live lock:
#
#   * can't open it exclusively  -> a live owner still holds it -> wait.
#   * can open it exclusively    -> no live owner -> it is an orphan we may
#                                   reclaim (we already hold the handle).
#
# Ownership metadata (PID, process start time, host, creation UTC, random
# token - all non-secret) is written for diagnosability and to guard against
# PID reuse: a recorded PID that now belongs to a process with a DIFFERENT
# start time is not the original owner.
function Open-CrashAwareLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [int]$TimeoutSeconds = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $stream = $null
        try {
            # OpenOrCreate + FileShare.None: succeeds only when no live owner
            # holds the file. An orphan left by a killed process has no open
            # handle, so this reclaims it instead of failing forever.
            $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            if ([DateTime]::UtcNow -gt $deadline) {
                throw ('Timed out waiting for the lock held by another Hook Maker process (' + $LockPath + '). Nothing was changed.')
            }
            Start-Sleep -Milliseconds 100
            continue
        }
        try {
            $process = Get-Process -Id $PID
            $owner = [pscustomobject][ordered]@{
                pid              = $PID
                processStartUtc  = $process.StartTime.ToUniversalTime().ToString('o')
                host             = [System.Net.Dns]::GetHostName()
                acquiredUtc      = [DateTime]::UtcNow.ToString('o')
                ownerToken       = [guid]::NewGuid().ToString('N')
            }
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($owner | ConvertTo-Json -Compress))
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        catch {
            # Metadata is diagnostic only - never fail the lock over it.
        }
        return $stream
    }
}

# Bounded exclusive lock around ANY install resource (a settings file, a
# runtime directory, the native git integration), using the same crash-aware
# primitive as the registry lock.
#
# LOCK ORDERING (must be kept to avoid deadlock): a caller acquires at most one
# resource lock at a time and never holds a settings lock while taking the
# registry lock. Install-Hook writes Claude settings, then Codex settings, then
# the registry - each lock released before the next is taken - so no cycle can
# form. The lock file lives beside the resource it guards.
function Invoke-WithResourceLock {
    param(
        [Parameter(Mandatory = $true)][string]$ResourcePath,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutSeconds = 10
    )
    $directory = Split-Path -Parent $ResourcePath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $lockPath = $ResourcePath + '.hookmaker-lock'
    $stream = Open-CrashAwareLock -LockPath $lockPath -TimeoutSeconds $TimeoutSeconds
    try { return (& $Action) }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

# Bounded exclusive lock around registry read-modify-write so two installs
# running near-simultaneously cannot lose each other's records.
function Invoke-WithInstallRegistryLock {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutSeconds = 10
    )
    $directory = Get-InstallStateDirectory -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $lockPath = Join-Path $directory 'install-registry.lock'
    $stream = Open-CrashAwareLock -LockPath $lockPath -TimeoutSeconds $TimeoutSeconds
    try { return (& $Action) }
    finally {
        try { $stream.Dispose() } catch { }
        try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ---- record identity and shape --------------------------------------------

# Stable id for "this hook, in this scope, for this profile". Client is NOT
# part of the identity on purpose: one logical installation can target Claude,
# Codex, or both, and each client's own semantics live in its own subrecord
# (record.clients.claude / .codex) so installing one never rewrites the other.
function Get-InstallRecordId {
    param(
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)][string]$ScopeKey,
        [string]$ProfileId = ''
    )
    return Get-ShortHash ($FriendlyName.ToLowerInvariant() + '|' + $ScopeKey.ToLowerInvariant() + '|' + $ProfileId)
}

function New-ClientSubrecord {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeScript,
        [Parameter(Mandatory = $true)][string[]]$Events,
        [Parameter(Mandatory = $true)][string]$Command,
        # Recorded so integrity can verify the Windows command INDEPENDENTLY.
        # Codex handlers carry both a portable `command` and a `commandWindows`;
        # storing only one meant a corrupt Windows command could hide behind a
        # still-correct portable one. Empty for Claude, which has no second form.
        [string]$CommandWindows = '',
        [string]$HandlerType = 'command',
        [string]$StatusMessage = '',
        [int]$Timeout = 60,
        $InstalledManifest = @()
    )
    return [pscustomobject][ordered]@{
        installed         = $true
        settingsPath      = $SettingsPath
        runtimeRoot       = $RuntimeRoot
        runtimeScript     = $RuntimeScript
        events            = @($Events)
        command           = $Command
        commandWindows    = $CommandWindows
        handlerType       = $HandlerType
        statusMessage     = $StatusMessage
        timeout           = $Timeout
        installedManifest = @($InstalledManifest)
        lastInstalledUtc  = [DateTime]::UtcNow.ToString('o')
        lastResult        = 'ok'
        lastError         = ''
    }
}

function Get-ClientSubrecord {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Client)
    if ($null -eq $Record.PSObject.Properties['clients'] -or $null -eq $Record.clients) { return $null }
    $key = $Client.ToLowerInvariant()
    if ($null -eq $Record.clients.PSObject.Properties[$key]) { return $null }
    $subrecord = $Record.clients.$key
    if ($null -eq $subrecord) { return $null }
    if ($null -ne $subrecord.PSObject.Properties['installed'] -and -not $subrecord.installed) { return $null }
    return $subrecord
}

function Get-InstalledClientNames {
    param([Parameter(Mandatory = $true)]$Record)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($client in @('claude', 'codex')) {
        if ($null -ne (Get-ClientSubrecord -Record $Record -Client $client)) { [void]$names.Add($client) }
    }
    return $names.ToArray()
}

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

# ---- record-kind predicates ------------------------------------------------

# StrictMode-safe: a missing property THROWS on member access, and these run
# over records read straight from a file that another tool may have written, so
# every lookup is guarded and anything unrecognizable answers $false rather than
# erroring.
function Test-IsDiscoveredRecord {
    param($Record)
    if ($null -eq $Record -or $Record -isnot [psobject]) { return $false }
    $property = $Record.PSObject.Properties['recordType']
    if ($null -eq $property -or $null -eq $property.Value) { return $false }
    return ([string]$property.Value -eq 'discovered')
}

# A record with NO recordType is managed: that is what every registry written
# before schema 3 contains, and migration only makes the fact explicit.
function Test-IsManagedRecord {
    param($Record)
    if ($null -eq $Record -or $Record -isnot [psobject]) { return $false }
    $property = $Record.PSObject.Properties['recordType']
    if ($null -eq $property -or $null -eq $property.Value) { return $true }
    return ([string]$property.Value -eq 'managed')
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
        # A discovered record is already current - it is only ever written by a
        # schema-3 writer - and must not be pushed through the v1->v2 managed
        # rebuild, which would try to read v1 client fields it never had.
        if (Test-IsDiscoveredRecord -Record $record) {
            [void]$migrated.Add($record)
            continue
        }
        [void]$migrated.Add((ConvertTo-InstallRecordV3 -Record (ConvertTo-InstallRecordV2 -Record $record)))
    }
    Set-ObjectProperty -Object $Registry -Name 'installs' -Value @($migrated.ToArray())
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    return $Registry
}

# ---- record upsert ---------------------------------------------------------

# Merges one install outcome into the registry. A record is keyed by id; an
# existing record keeps its createdUtc and its OTHER client's subrecord
# untouched - installing Claude-only must never rewrite or drop what Codex has
# registered. History is bounded and carries the per-client outcome.
function Set-InstallRecord {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)]$Record
    )
    $nowIso = [DateTime]::UtcNow.ToString('o')
    $existingList = @($Registry.installs)
    $existingIndex = -1
    for ($i = 0; $i -lt $existingList.Count; $i++) {
        if ([string]$existingList[$i].id -eq [string]$Record.id) { $existingIndex = $i; break }
    }
    $touchedClients = @(Get-InstalledClientNames -Record $Record)
    # Read defensively: StrictMode throws on a missing property, and a record
    # arriving from an older schema (or a partially-built one) must not be able
    # to abort the whole registry write.
    $recordResult = ''
    if ($null -ne $Record.PSObject.Properties['lastResult']) { $recordResult = [string]$Record.lastResult }
    $recordReason = ''
    if ($null -ne $Record.PSObject.Properties['lastReason']) { $recordReason = [string]$Record.lastReason }
    # PER-COMPONENT history: the outcome of each component this attempt, not
    # just one overall verdict, so a partial failure stays visible afterwards
    # instead of being flattened into a single 'ok'. Sanitized fields only -
    # never file contents, .env values, prompt text or raw tool output.
    $componentOutcomes = @()
    if ($null -ne $Record.PSObject.Properties['lastComponents'] -and $null -ne $Record.lastComponents) {
        $componentOutcomes = @(@($Record.lastComponents) | ForEach-Object {
            [pscustomobject][ordered]@{
                component = [string]$_.component
                status    = [string]$_.status
                reason    = [string]$_.reason
            }
        })
    }
    $historyEntry = [pscustomobject][ordered]@{
        ts         = $nowIso
        result     = $recordResult
        clients    = ($touchedClients -join ',')
        reason     = $recordReason
        components = $componentOutcomes
    }
    if ($existingIndex -ge 0) {
        $existing = $existingList[$existingIndex]
        Set-ObjectProperty -Object $Record -Name 'createdUtc' -Value ([string]$existing.createdUtc)
        # Carry forward every client subrecord this invocation did NOT touch.
        foreach ($client in @('claude', 'codex')) {
            if (@($touchedClients) -contains $client) { continue }
            $previous = $null
            if ($null -ne $existing.PSObject.Properties['clients'] -and $null -ne $existing.clients -and $null -ne $existing.clients.PSObject.Properties[$client]) {
                $previous = $existing.clients.$client
            }
            if ($null -ne $previous) { Set-ObjectProperty -Object $Record.clients -Name $client -Value $previous }
        }
        # Same for a native-git subrecord an unrelated client-only reinstall did not rebuild.
        if (($null -eq $Record.PSObject.Properties['nativeGit'] -or $null -eq $Record.nativeGit) -and
            $null -ne $existing.PSObject.Properties['nativeGit'] -and $null -ne $existing.nativeGit) {
            Set-ObjectProperty -Object $Record -Name 'nativeGit' -Value $existing.nativeGit
        }
        $priorHistory = @()
        if ($null -ne $existing.PSObject.Properties['history'] -and $null -ne $existing.history) { $priorHistory = @($existing.history) }
        $newHistory = @(@($priorHistory) + @($historyEntry))
        if ($newHistory.Count -gt 10) { $newHistory = @($newHistory | Select-Object -Last 10) }
        Set-ObjectProperty -Object $Record -Name 'history' -Value $newHistory
        $existingList[$existingIndex] = $Record
    }
    else {
        Set-ObjectProperty -Object $Record -Name 'createdUtc' -Value $nowIso
        Set-ObjectProperty -Object $Record -Name 'history' -Value @($historyEntry)
        $existingList = @(@($existingList) + @($Record))
    }
    $Registry.installs = $existingList
}

# The single safe mutation entry point: takes the lock, validates, quarantines
# a corrupt registry BEFORE recovering into a fresh one, upserts, saves.
# Returns a result the caller must report honestly - tracking can fail while
# the hook itself is correctly installed, and that must never be reported as a
# fully tracked install.
function Update-InstallRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)]$Record
    )
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        $quarantinePath = ''
        $warning = ''
        $registry = $null
        if ($state.State -eq 'corrupt') {
            try {
                $quarantinePath = Move-CorruptInstallRegistry -ToolRoot $ToolRoot
            }
            catch {
                return [pscustomobject]@{
                    Ok = $false
                    QuarantinePath = ''
                    Warning = ('The install registry is unreadable (' + $state.Reason + ') and could not be quarantined: ' + $_.Exception.Message + '. It was left untouched and this installation was NOT recorded.')
                }
            }
            $warning = 'The install registry was unreadable (' + $state.Reason + '). Its exact contents were preserved at: ' + $quarantinePath + ' - a new registry was started, so previously tracked installations are no longer listed.'
            $registry = New-EmptyInstallRegistry
        }
        else {
            $registry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
        }
        Set-InstallRecord -Registry $registry -Record $Record
        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registry

        # PERSISTENCE IS VERIFIED, NOT ASSUMED. Writing without checking let a
        # silent failure look like success: when a DIRECTORY occupied the
        # registry path, the atomic write moved the temp file INSIDE it and
        # reported ok, so the install was never actually tracked. Read the
        # registry back and confirm this exact record is really there.
        $registryPath = Get-InstallRegistryPath -ToolRoot $ToolRoot
        if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = ('the registry could not be written to ' + $registryPath + ' (the path is not a writable file) - this installation was NOT recorded')
            }
        }
        $verifyState = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($verifyState.State -ne 'ok' -or $null -eq $verifyState.Registry) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = ('the registry did not read back cleanly after writing (' + $verifyState.Reason + ') - this installation may NOT be recorded')
            }
        }
        $persisted = @(@($verifyState.Registry.installs) | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties['id'] -and [string]$_.id -eq [string]$Record.id
        })
        if ($persisted.Count -ne 1) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = 'the record was not found in the registry after writing - this installation was NOT recorded'
            }
        }
        return [pscustomobject]@{ Ok = $true; QuarantinePath = $quarantinePath; Warning = $warning }
    })
}

# ---- discovered records: identity, validation, merge -----------------------
#
# A discovered record describes a hook the read-only status scan FOUND; Hook
# Maker did not install it and may not own it. It therefore shares nothing with
# a managed record but the file it is stored in, and has its own id derivation,
# its own validator, and its own merge rules.

$script:DiscoveredHookTypes = @('ClaudeRegistration', 'CodexRegistration', 'NativeGitHook')
$script:DiscoveredStatuses = @('active', 'missingTarget', 'registrationOnly', 'sharedRuntime', 'orphanCandidate', 'ambiguous', 'manualRepair', 'notSeen')
$script:DiscoveredManagedByValues = @('hookMaker', 'external', 'unknown')
$script:DiscoveredRemovalPolicies = @('full', 'registrationOnly', 'nativeFileOnly', 'unavailable')
$script:DiscoveredClientNames = @('claude', 'codex')
$script:DiscoveredRegistrationStatuses = @('parsed', 'unparsedCommand', 'fieldsDisagree', 'targetMissing')
$script:DiscoveredNativeClassifications = @('hookMakerWrapper', 'externalNativeHook', 'ambiguous')
$script:DiscoveredArtifactClassifications = @('registeredRuntime', 'sharedRuntime', 'registrationOnly', 'missingTarget', 'orphanRuntimeCandidate', 'ambiguous')
$script:DiscoveredArtifactEligibility = @('eligible', 'preserve')
# A raw command line can embed a token or an expanded secret-bearing environment
# value, so a discovered record persists the FINGERPRINT instead and never the
# text. The mere presence of one of these field names is a validation failure -
# a rule, not a convention, so it cannot quietly erode.
$script:DiscoveredForbiddenFieldNames = @('command', 'commandWindows', 'command_windows')

# ---- discovered field primitives -------------------------------------------
# Each returns '' when the field holds up, or a precise English reason. They
# never throw: every lookup is guarded, because these run over records another
# writer may have produced.

function Test-DiscoveredStringField {
    param($Object, [string]$Name, [string]$Label, [switch]$AllowEmpty)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ($Label + ' is missing the required field "' + $Name + '"') }
    $value = $property.Value
    # An ACTUAL [string] - not merely something that survives a [string] cast.
    # Every one of these becomes a path, an id or display text.
    if ($value -isnot [string]) { return ($Label + ' field "' + $Name + '" is not a string') }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) { return ($Label + ' field "' + $Name + '" is empty') }
    return ''
}

function Test-DiscoveredArrayField {
    param($Object, [string]$Name, [string]$Label)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ($Label + ' is missing the required field "' + $Name + '"') }
    $value = $property.Value
    # A string is IEnumerable (over its characters) and a hashtable is not a
    # sequence of entries, so both are rejected rather than silently enumerated.
    if ($null -eq $value -or $value -is [string] -or $value -is [System.Collections.IDictionary] -or
        -not ($value -is [System.Collections.IEnumerable])) {
        return ($Label + ' field "' + $Name + '" is not an array')
    }
    return ''
}

function Test-DiscoveredEnumField {
    param($Object, [string]$Name, [string[]]$Allowed, [string]$Label)
    $reason = Test-DiscoveredStringField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    if (@($Allowed) -notcontains [string]$Object.$Name) {
        return ($Label + ' field "' + $Name + '" has the unsupported value "' + [string]$Object.$Name + '"')
    }
    return ''
}

function Test-DiscoveredUtcTimestampField {
    param($Object, [string]$Name, [string]$Label)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ($Label + ' is missing the required field "' + $Name + '"') }
    # ConvertFrom-Json turns an ISO-8601 timestamp back into a real [datetime],
    # so the SAME record is a string on disk and a datetime once read back.
    # Rejecting the deserialized form would reject every persisted record; both
    # are accepted, and both must still PROVE they are UTC rather than a local
    # or zone-less reading.
    if ($property.Value -is [datetime]) {
        if ($property.Value.Kind -ne [System.DateTimeKind]::Utc) {
            return ($Label + ' field "' + $Name + '" is not an ISO 8601 UTC timestamp')
        }
        return ''
    }
    if ($property.Value -is [datetimeoffset]) {
        if ($property.Value.Offset -ne [System.TimeSpan]::Zero) {
            return ($Label + ' field "' + $Name + '" is not an ISO 8601 UTC timestamp')
        }
        return ''
    }
    $reason = Test-DiscoveredStringField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    $value = [string]$Object.$Name
    # An explicit zone is REQUIRED: "when was this last seen" must never be
    # ambiguous, and a bare local timestamp cannot be proven to be UTC.
    if ($value -notmatch '(Z|[+-]\d{2}:?\d{2})$') {
        return ($Label + ' field "' + $Name + '" is not an ISO 8601 UTC timestamp')
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return ($Label + ' field "' + $Name + '" is not a parseable timestamp')
    }
    return ''
}

function Test-DiscoveredStringArrayField {
    param($Object, [string]$Name, [string]$Label, [switch]$AllowEmptyEntries)
    $reason = Test-DiscoveredArrayField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    foreach ($entry in @($Object.$Name)) {
        if ($entry -isnot [string]) { return ($Label + ' field "' + $Name + '" contains a non-string entry') }
        if (-not $AllowEmptyEntries -and [string]::IsNullOrWhiteSpace($entry)) {
            return ($Label + ' field "' + $Name + '" contains an empty entry')
        }
    }
    return ''
}

# Every fingerprint this layer stores comes from Get-Sha256Hex, which always
# returns exactly 64 hex characters. Anything else could never match a
# recomputed fingerprint and would read as a permanent mismatch instead of the
# malformed record it actually is.
function Test-DiscoveredFingerprintArrayField {
    param($Object, [string]$Name, [string]$Label)
    $reason = Test-DiscoveredStringArrayField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    foreach ($entry in @($Object.$Name)) {
        if ($entry -notmatch '^[0-9a-fA-F]{64}$') {
            return ($Label + ' field "' + $Name + '" contains a value that is not a 64-character SHA-256 hex fingerprint')
        }
    }
    return ''
}

function Test-DiscoveredCanonicalPathField {
    param($Object, [string]$Name, [string]$Label, [switch]$AllowEmpty)
    $reason = Test-DiscoveredStringField -Object $Object -Name $Name -Label $Label -AllowEmpty:$AllowEmpty
    if ($reason -ne '') { return $reason }
    $value = [string]$Object.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    if ($null -eq (Get-CanonicalPathOrNull $value)) {
        return ($Label + ' field "' + $Name + '" cannot be canonicalized')
    }
    return ''
}

function Test-DiscoveredNoRawCommand {
    param($Object, [string]$Label)
    foreach ($forbidden in $script:DiscoveredForbiddenFieldNames) {
        if ($null -ne $Object.PSObject.Properties[$forbidden]) {
            return ($Label + ' persists a raw command in "' + $forbidden + '"; only fingerprints may be stored')
        }
    }
    return ''
}

# ---- stable discovered id ---------------------------------------------------

# SHA-256 over canonical, NON-SECRET identity inputs, prefixed 'disc-' plus the
# first 32 hex characters.
#
# The same unchanged installation rescanned must produce the SAME id, so every
# path component is reduced to its canonical case-insensitive key (Windows paths
# are case-insensitive; the same file typed two ways is one file) and the
# fingerprint list is sorted - a settings file whose handlers were merely
# reordered is not a different hook.
#
# Conversely two same-named hooks at DIFFERENT paths must produce different ids,
# which is why the path is part of the identity and the friendly name is not:
# an id is never derived from a display name or a basename.
function Get-DiscoveredRecordId {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('registration', 'native')][string]$Kind,
        [string]$Scope = '',
        [string]$TargetProjectRoot = '',
        [string]$Client = '',
        [string]$SettingsPath = '',
        [string[]]$HandlerFingerprints = @(),
        [string]$RepositoryRoot = '',
        [string]$HookPath = '',
        [string]$HookName = ''
    )
    if ($Kind -eq 'native') {
        $parts = @(
            'discovered'
            (Get-CanonicalPathKey -Path $RepositoryRoot)
            (Get-CanonicalPathKey -Path $HookPath)
            ([string]$HookName).ToLowerInvariant()
        )
    }
    else {
        $sortedFingerprints = @(@($HandlerFingerprints) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object -CaseSensitive)
        $parts = @(
            'discovered'
            ([string]$Scope).ToLowerInvariant()
            (Get-CanonicalPathKey -Path $TargetProjectRoot)
            ([string]$Client).ToLowerInvariant()
            (Get-CanonicalPathKey -Path $SettingsPath)
            ($sortedFingerprints -join ',')
        )
    }
    return ('disc-' + (Get-Sha256Hex -Text ($parts -join '|')).Substring(0, 32))
}

# ---- discovered record validation ------------------------------------------

# Proves a DISCOVERED record's shape before anything reads its fields. A managed
# record is refused outright here, exactly as a discovered record is refused by
# the managed path - the two shapes share no rules and accepting one under the
# other's contract would let an unvalidated field reach a consumer.
function Test-DiscoveredRecordValid {
    param($Record)

    if ($null -eq $Record) { return [pscustomobject]@{ Ok = $false; Reason = 'record is null' } }
    if ($Record -isnot [psobject]) { return [pscustomobject]@{ Ok = $false; Reason = 'record is not an object' } }
    if (-not (Test-IsDiscoveredRecord -Record $Record)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'record is not a discovered record' }
    }

    $label = 'discovered record'
    $reasons = New-Object System.Collections.Generic.List[string]

    # ---- schema ------------------------------------------------------------
    $schemaProperty = $Record.PSObject.Properties['schema']
    if ($null -eq $schemaProperty) { return [pscustomobject]@{ Ok = $false; Reason = 'discovered record has no schema version' } }
    $schemaNumber = 0
    if (-not [int]::TryParse([string]$schemaProperty.Value, [ref]$schemaNumber)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('discovered record has a non-numeric schema version "' + [string]$schemaProperty.Value + '"') }
    }
    if ($schemaNumber -gt $script:DiscoveredRecordSchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('discovered record uses unsupported schema version ' + $schemaNumber + ' (this version supports up to ' + $script:DiscoveredRecordSchemaVersion + ')') }
    }
    if ($schemaNumber -lt $script:DiscoveredRecordSchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('discovered record uses old schema version ' + $schemaNumber + ' and needs migration') }
    }

    # ---- required scalars, enums and timestamps ----------------------------
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'id' -Label $label))
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'friendlyName' -Label $label))
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'lastScanId' -Label $label))
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'statusReason' -Label $label -AllowEmpty))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'recordType' -Allowed @('discovered') -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'origin' -Allowed @('statusScan') -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'hookType' -Allowed $script:DiscoveredHookTypes -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'scope' -Allowed @('project', 'global') -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'status' -Allowed $script:DiscoveredStatuses -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'managedBy' -Allowed $script:DiscoveredManagedByValues -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'removalPolicy' -Allowed $script:DiscoveredRemovalPolicies -Label $label))
    [void]$reasons.Add((Test-DiscoveredUtcTimestampField -Object $Record -Name 'firstSeenUtc' -Label $label))
    [void]$reasons.Add((Test-DiscoveredUtcTimestampField -Object $Record -Name 'lastSeenUtc' -Label $label))
    # targetProjectRoot is '' for a global record, so it is allowed to be empty
    # here and required non-empty by the scope rule below.
    [void]$reasons.Add((Test-DiscoveredCanonicalPathField -Object $Record -Name 'targetProjectRoot' -Label $label -AllowEmpty))
    [void]$reasons.Add((Test-DiscoveredStringArrayField -Object $Record -Name 'scanRoots' -Label $label))
    [void]$reasons.Add((Test-DiscoveredArrayField -Object $Record -Name 'clients' -Label $label))
    [void]$reasons.Add((Test-DiscoveredArrayField -Object $Record -Name 'runtimeArtifacts' -Label $label))
    [void]$reasons.Add((Test-DiscoveredNoRawCommand -Object $Record -Label $label))
    foreach ($reason in $reasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }

    $needsRepairProperty = $Record.PSObject.Properties['needsManualRepair']
    if ($null -eq $needsRepairProperty) {
        return [pscustomobject]@{ Ok = $false; Reason = 'discovered record is missing the required field "needsManualRepair"' }
    }
    if ($needsRepairProperty.Value -isnot [bool]) {
        return [pscustomobject]@{ Ok = $false; Reason = 'discovered record field "needsManualRepair" is not a boolean' }
    }
    if ([string]$Record.scope -eq 'project' -and [string]::IsNullOrWhiteSpace([string]$Record.targetProjectRoot)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'project-scoped discovered record has no targetProjectRoot' }
    }

    # ---- per-client evidence -----------------------------------------------
    foreach ($client in @($Record.clients)) {
        $clientLabel = 'discovered client evidence'
        if ($null -eq $client -or $client -isnot [psobject] -or $client -is [string]) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientLabel + ' contains a malformed entry') }
        }
        $clientReasons = @(
            (Test-DiscoveredEnumField -Object $client -Name 'client' -Allowed $script:DiscoveredClientNames -Label $clientLabel)
            (Test-DiscoveredCanonicalPathField -Object $client -Name 'settingsPath' -Label $clientLabel)
            (Test-DiscoveredEnumField -Object $client -Name 'registrationStatus' -Allowed $script:DiscoveredRegistrationStatuses -Label $clientLabel)
            (Test-DiscoveredStringArrayField -Object $client -Name 'events' -Label $clientLabel)
            (Test-DiscoveredStringArrayField -Object $client -Name 'handlerTypes' -Label $clientLabel -AllowEmptyEntries)
            (Test-DiscoveredStringArrayField -Object $client -Name 'commandFieldNames' -Label $clientLabel)
            (Test-DiscoveredStringArrayField -Object $client -Name 'parsedTargets' -Label $clientLabel)
            (Test-DiscoveredFingerprintArrayField -Object $client -Name 'handlerFingerprints' -Label $clientLabel)
            (Test-DiscoveredFingerprintArrayField -Object $client -Name 'matcherFingerprints' -Label $clientLabel)
            (Test-DiscoveredNoRawCommand -Object $client -Label $clientLabel)
        )
        foreach ($reason in $clientReasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }
        foreach ($target in @($client.parsedTargets)) {
            if ($null -eq (Get-CanonicalPathOrNull ([string]$target))) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientLabel + ' field "parsedTargets" contains a path that cannot be canonicalized') }
            }
        }
    }

    # ---- native evidence (optional; $null when this is not a native record) --
    $nativeProperty = $Record.PSObject.Properties['nativeGit']
    if ($null -eq $nativeProperty) {
        return [pscustomobject]@{ Ok = $false; Reason = 'discovered record is missing the required field "nativeGit"' }
    }
    $native = $nativeProperty.Value
    if ($null -ne $native) {
        $nativeLabel = 'discovered nativeGit evidence'
        if ($native -isnot [psobject] -or $native -is [string]) {
            return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' is not an object') }
        }
        $nativeReasons = @(
            (Test-DiscoveredCanonicalPathField -Object $native -Name 'repositoryRoot' -Label $nativeLabel)
            (Test-DiscoveredCanonicalPathField -Object $native -Name 'hooksPath' -Label $nativeLabel)
            (Test-DiscoveredCanonicalPathField -Object $native -Name 'hookPath' -Label $nativeLabel)
            (Test-DiscoveredStringField -Object $native -Name 'hookName' -Label $nativeLabel)
            (Test-DiscoveredEnumField -Object $native -Name 'classification' -Allowed $script:DiscoveredNativeClassifications -Label $nativeLabel)
            # managedStages is only ever populated when the canonical wrapper
            # parser PROVES the stages, so an empty array is normal and valid.
            (Test-DiscoveredStringArrayField -Object $native -Name 'managedStages' -Label $nativeLabel)
            (Test-DiscoveredNoRawCommand -Object $native -Label $nativeLabel)
        )
        foreach ($reason in $nativeReasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }
        # hookHash is '' when the file could not be read - a real state, not a
        # malformed one - but any non-empty value must be a genuine SHA-256.
        $hashReason = Test-DiscoveredStringField -Object $native -Name 'hookHash' -Label $nativeLabel -AllowEmpty
        if ($hashReason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $hashReason } }
        if (-not [string]::IsNullOrWhiteSpace([string]$native.hookHash) -and [string]$native.hookHash -notmatch '^[0-9a-fA-F]{64}$') {
            return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' field "hookHash" is not a 64-character SHA-256 hex value') }
        }
        $sizeProperty = $native.PSObject.Properties['hookSize']
        if ($null -eq $sizeProperty) { return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' is missing the required field "hookSize"') } }
        $parsedSize = [long]0
        if (-not [long]::TryParse([string]$sizeProperty.Value, [ref]$parsedSize)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' field "hookSize" is not numeric') }
        }
        $modifiedReason = Test-DiscoveredUtcTimestampField -Object $native -Name 'hookModifiedUtc' -Label $nativeLabel
        if ($modifiedReason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $modifiedReason } }
    }

    # ---- runtime artifacts --------------------------------------------------
    foreach ($artifact in @($Record.runtimeArtifacts)) {
        $artifactLabel = 'discovered runtime artifact'
        if ($null -eq $artifact -or $artifact -isnot [psobject] -or $artifact -is [string]) {
            return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' contains a malformed entry') }
        }
        $artifactReasons = @(
            (Test-DiscoveredCanonicalPathField -Object $artifact -Name 'path' -Label $artifactLabel)
            (Test-DiscoveredStringField -Object $artifact -Name 'kind' -Label $artifactLabel)
            (Test-DiscoveredEnumField -Object $artifact -Name 'classification' -Allowed $script:DiscoveredArtifactClassifications -Label $artifactLabel)
            (Test-DiscoveredEnumField -Object $artifact -Name 'deleteEligibility' -Allowed $script:DiscoveredArtifactEligibility -Label $artifactLabel)
            (Test-DiscoveredStringField -Object $artifact -Name 'deleteReason' -Label $artifactLabel -AllowEmpty)
            (Test-DiscoveredStringArrayField -Object $artifact -Name 'referencedBy' -Label $artifactLabel)
            (Test-DiscoveredStringField -Object $artifact -Name 'hash' -Label $artifactLabel -AllowEmpty)
            (Test-DiscoveredNoRawCommand -Object $artifact -Label $artifactLabel)
        )
        foreach ($reason in $artifactReasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }
        if (-not [string]::IsNullOrWhiteSpace([string]$artifact.hash) -and [string]$artifact.hash -notmatch '^[0-9a-fA-F]{64}$') {
            return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' field "hash" is not a 64-character SHA-256 hex value') }
        }
        $artifactSizeProperty = $artifact.PSObject.Properties['size']
        if ($null -eq $artifactSizeProperty) { return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' is missing the required field "size"') } }
        $parsedArtifactSize = [long]0
        if (-not [long]::TryParse([string]$artifactSizeProperty.Value, [ref]$parsedArtifactSize)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' field "size" is not numeric') }
        }
    }

    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# ---- discovered record merge ------------------------------------------------

# Does a MANAGED record already account for this discovered finding? Decided on
# EVIDENCE (the settings file plus the script actually registered, or the exact
# wrapper path), never on a friendly name - two different hooks can share a
# name, and the same hook can be registered under two.
function Test-DiscoveredCoveredByManaged {
    param([Parameter(Mandatory = $true)]$Registry, [Parameter(Mandatory = $true)]$Record)
    foreach ($managed in @($Registry.installs)) {
        if ($null -eq $managed -or -not (Test-IsManagedRecord -Record $managed)) { continue }

        # Native: the managed wrapper IS the discovered hook file.
        $nativeProperty = $Record.PSObject.Properties['nativeGit']
        if ($null -ne $nativeProperty -and $null -ne $nativeProperty.Value) {
            $discoveredHookKey = Get-CanonicalPathKey -Path ([string]$nativeProperty.Value.hookPath)
            $managedNativeProperty = $managed.PSObject.Properties['nativeGit']
            if ($discoveredHookKey -ne '' -and $null -ne $managedNativeProperty -and $null -ne $managedNativeProperty.Value) {
                $managedNative = $managedNativeProperty.Value
                $wrapperProperty = $managedNative.PSObject.Properties['wrapperPath']
                if ($null -ne $wrapperProperty -and
                    (Get-CanonicalPathKey -Path ([string]$wrapperProperty.Value)) -eq $discoveredHookKey) {
                    return $managed
                }
            }
        }

        # Registration: same settings file AND the managed runtime script is one
        # of the targets this registration actually resolves to.
        foreach ($clientEvidence in @($Record.clients)) {
            if ($null -eq $clientEvidence) { continue }
            $clientName = [string]$clientEvidence.client
            $subrecord = $null
            if ($null -ne $managed.PSObject.Properties['clients'] -and $null -ne $managed.clients -and
                $null -ne $managed.clients.PSObject.Properties[$clientName]) {
                $subrecord = $managed.clients.$clientName
            }
            if ($null -eq $subrecord) { continue }
            $settingsProperty = $subrecord.PSObject.Properties['settingsPath']
            $scriptProperty = $subrecord.PSObject.Properties['runtimeScript']
            if ($null -eq $settingsProperty -or $null -eq $scriptProperty) { continue }
            $managedSettingsKey = Get-CanonicalPathKey -Path ([string]$settingsProperty.Value)
            if ($managedSettingsKey -eq '' -or
                $managedSettingsKey -ne (Get-CanonicalPathKey -Path ([string]$clientEvidence.settingsPath))) { continue }
            $managedScriptKey = Get-CanonicalPathKey -Path ([string]$scriptProperty.Value)
            if ($managedScriptKey -eq '') { continue }
            foreach ($target in @($clientEvidence.parsedTargets)) {
                if ((Get-CanonicalPathKey -Path ([string]$target)) -eq $managedScriptKey) { return $managed }
            }
        }
    }
    return $null
}

# Merges ONE freshly discovered record into the registry and reports what it
# decided. Action is one of:
#
#   added             a hook nothing tracked before
#   updated           the SAME hook seen again - its id already exists
#   coveredByManaged  a managed install already accounts for it; nothing is
#                     written, so a hook Hook Maker owns can never be duplicated
#                     as a foreign discovery
#   rejected          the record does not hold up (invalid, or claims notSeen
#                     from a scan that did not actually cover everything)
#
# On update, firstSeenUtc is the ONE field carried forward from the stored
# record: it answers "since when has this existed", which a later scan cannot
# re-derive. Everything else - lastSeenUtc, lastScanId, scanRoots, status,
# hashes, evidence - is refreshed from the new observation.
function Merge-DiscoveredRecord {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)]$Record,
        # Whether the scan that produced this record covered every root it
        # claimed. A partial scan (access denied, path too long, a skipped
        # reparse point) has NOT proven a hook is gone.
        [switch]$CoverageComplete
    )
    $validation = Test-DiscoveredRecordValid -Record $Record
    if (-not $validation.Ok) {
        return [pscustomobject]@{ Action = 'rejected'; Reason = $validation.Reason; Record = $null; ManagedRecord = $null }
    }
    # "Not seen" is a claim about ABSENCE, and absence can only be proven by a
    # scan that actually reached everywhere. Accepting it from a partial scan is
    # how a live hook gets written off as gone.
    if ([string]$Record.status -eq 'notSeen' -and -not $CoverageComplete) {
        return [pscustomobject]@{
            Action = 'rejected'
            Reason = 'a record cannot be marked notSeen by a scan whose coverage was incomplete'
            Record = $null; ManagedRecord = $null
        }
    }

    $managed = Test-DiscoveredCoveredByManaged -Registry $Registry -Record $Record
    if ($null -ne $managed) {
        return [pscustomobject]@{
            Action = 'coveredByManaged'
            Reason = ('already tracked as the managed install "' + [string]$managed.friendlyName + '"')
            Record = $null; ManagedRecord = $managed
        }
    }

    $existingList = @($Registry.installs)
    for ($i = 0; $i -lt $existingList.Count; $i++) {
        $candidate = $existingList[$i]
        if ($null -eq $candidate -or -not (Test-IsDiscoveredRecord -Record $candidate)) { continue }
        if ([string]$candidate.id -ne [string]$Record.id) { continue }
        $firstSeenProperty = $candidate.PSObject.Properties['firstSeenUtc']
        if ($null -ne $firstSeenProperty -and -not [string]::IsNullOrWhiteSpace([string]$firstSeenProperty.Value)) {
            Set-ObjectProperty -Object $Record -Name 'firstSeenUtc' -Value ([string]$firstSeenProperty.Value)
        }
        $existingList[$i] = $Record
        $Registry.installs = $existingList
        return [pscustomobject]@{ Action = 'updated'; Reason = ''; Record = $Record; ManagedRecord = $null }
    }

    $Registry.installs = @(@($existingList) + @($Record))
    return [pscustomobject]@{ Action = 'added'; Reason = ''; Record = $Record; ManagedRecord = $null }
}

