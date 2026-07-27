# ---------------------------------------------------------------------------
# Install registry persistence layer: how MANAGED install records are stored,
# validated, locked, migrated, and written back to disk. The other record kind
# that shares this file - the discovered records the read-only status scan
# finds - has its own id derivation, validators and merge rules, and lives in
# scripts\_installdiscovered.ps1, which this file dot-sources below.
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

# The discovered-record layer: stable discovered id, field validation, and the
# merge against managed records. Dot-sourced HERE rather than from
# _installlib.ps1 because it is the same registry-file concern - the two record
# kinds share one file and differ only in their rules - so consumers keep
# dot-sourcing only _installlib.ps1. It also pulls in _hookdiscovery.ps1, the
# shared identity layer both this file's callers and the scanner hash with.
. (Join-Path $PSScriptRoot '_installdiscovered.ps1')

# Carry a stored UTC timestamp forward WITHOUT destroying its ISO 8601 form.
#
# `ConvertFrom-Json` turns an ISO-8601 string back into a real [datetime], so a
# field that was written correctly is a [datetime] once read back. Casting that
# with [string] renders it in the CURRENT CULTURE - "07/26/2026 23:22:47" - and
# writing that back destroys the format permanently. Round 40 found every one of
# 334 discovered records corrupted this way: each survived one rescan, failed
# `Test-DiscoveredUtcTimestampField` forever after, and so could never be
# uninstalled. Same trap as the cross-host ConvertFrom-Json bug in
# LESSON_POWERSHELL.md, in a new place.
#
# A zone-less string is REPAIRED rather than passed through: it is an older
# build's locale rendering of a UTC time, and leaving it would leave the record
# permanently unremovable. Parsing assumes UTC because that is what the field
# means. An unparseable value is returned untouched so the validator still
# reports it honestly instead of this function inventing a timestamp.
function ConvertTo-RegistryUtcTimestamp {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o') }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    # A value that already carries a zone is returned BYTE-FOR-BYTE. Re-emitting
    # it through ToString('o') would rewrite "...:47Z" as "...:47.0000000Z" -
    # the same instant, but it breaks the migration contract that only malformed
    # data is ever touched. A zone-bearing value that is still nonsense is also
    # left alone, so the validator reports it instead of this function hiding it.
    if ($text -match '(Z|[+-]\d{2}:?\d{2})$') { return $text }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    foreach ($culture in @([System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.CultureInfo]::InvariantCulture)) {
        if ([datetime]::TryParse($text, $culture, $styles, [ref]$parsed)) {
            return ([DateTime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)).ToString('o')
        }
    }
    return $text
}

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
        $InstalledManifest = @(),
        # ---- registration shape ------------------------------------------
        # 'sharedSettingsFile' (Claude, Codex): ONE settings document holds every
        # hook, so $SettingsPath is that document and ownership is per-handler.
        # 'perHookFile' (Kiro): each logical installation owns its OWN file, so
        # ownership is per-file AND per-entry.
        #
        # Kiro is NOT forced into the settingsPath model. A synthesised
        # "settings path" for a per-hook-file client would be a fake that every
        # later consumer would treat as real, which is exactly how an updater
        # ends up rewriting the wrong file. Instead the shape is recorded
        # explicitly and the real location lives in registrationPath.
        [ValidateSet('sharedSettingsFile', 'perHookFile')][string]$RegistrationKind = 'sharedSettingsFile',
        [string]$RegistrationPath = '',
        # Logical -> physical trigger names actually written, so a later reader
        # never has to re-derive the mapping (Kiro renamed every trigger between
        # its CLI v2 and v1 schemas - the mapping is data, not a constant).
        $PhysicalTriggers = @(),
        # Events the caller REQUESTED that this client cannot support, named
        # individually. An empty array means full parity; a non-empty one is why
        # the component result is 'partial' rather than 'ok'.
        [string[]]$UnsupportedEvents = @(),
        # Non-secret reasons this install is weaker than requested, e.g.
        # 'degraded-stop-gate' when the client documents Stop as non-blocking.
        [string[]]$DegradedReasons = @(),
        # Managed entry identities inside a per-hook file, so pruning can target
        # exactly what Hook Maker owns and leave foreign entries alone.
        [string[]]$ManagedEntryNames = @(),
        [bool]$Enabled = $true
    )
    return [pscustomobject][ordered]@{
        installed         = $true
        settingsPath      = $SettingsPath
        registrationKind  = $RegistrationKind
        registrationPath  = $RegistrationPath
        runtimeRoot       = $RuntimeRoot
        runtimeScript     = $RuntimeScript
        events            = @($Events)
        physicalTriggers  = @($PhysicalTriggers)
        unsupportedEvents = @($UnsupportedEvents)
        degradedReasons   = @($DegradedReasons)
        managedEntryNames = @($ManagedEntryNames)
        enabled           = $Enabled
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
    # Derived from the canonical client table, not a second hard-coded pair:
    # this is what "Update previously installed hooks" enumerates to decide
    # which components to evaluate and repair, so a client missing here is a
    # client that can never be refreshed. The table's order is preserved, so a
    # record without the newer client still yields exactly 'claude,codex'.
    foreach ($client in @(Get-HookMakerClientIds)) {
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
        Set-ObjectProperty -Object $Record -Name 'createdUtc' -Value (ConvertTo-RegistryUtcTimestamp -Value $existing.createdUtc)
        # Carry forward every client subrecord this invocation did NOT touch.
        #
        # Derived from the capability table, NOT a literal pair. It was
        # @('claude','codex'), so a kiro subrecord was silently DROPPED the next
        # time the same record id was installed for claude/codex only - and it
        # took registrationPath and managedEntryNames with it, which are Kiro
        # uninstall's only proof of what it owns. The result is an orphaned
        # .kiro\hooks registration nothing can ever prove is removable.
        #
        # This file already derives the client list this way in
        # Get-InstalledClientNames, with a comment explaining why; the two were
        # inconsistent. Note the OTHER literal pair above (the legacy migration
        # loop) is correct and must stay: its $legacyClients vocabulary only
        # ever held Both/Claude/Codex, so there is no kiro to migrate.
        foreach ($client in @(Get-HookMakerClientIds)) {
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
        # Verify by reading the BYTES back, not by re-parsing the whole document.
        # A full Read-InstallRegistryState here cost ~960 ms against a 4.7 MB
        # registry while the raw read costs ~17 ms, and Update-InstallRegistry is
        # called once per hook per project - 105 times for a 21-hook install into
        # 5 projects. Re-parsing to confirm a write we just serialised ourselves
        # was the single largest cost in the install path.
        #
        # The guarantee is preserved. What this check exists for (see above) is a
        # write that silently went somewhere else - the directory-at-the-path
        # case - and that is caught by the -PathType Leaf test plus finding this
        # record's id in the bytes actually on disk. What it never proved is that
        # the JSON is semantically valid: Save-InstallRegistry serialised it from
        # an in-memory object one statement earlier, so a parse here could only
        # fail if the atomic write itself corrupted bytes, and that would equally
        # break the id check below.
        $verifyText = ''
        try { $verifyText = [System.IO.File]::ReadAllText($registryPath, [System.Text.Encoding]::UTF8) }
        catch {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = ('the registry could not be read back after writing (' + $_.Exception.Message + ') - this installation may NOT be recorded')
            }
        }
        if ([string]::IsNullOrWhiteSpace($verifyText)) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = 'the registry was empty when read back after writing - this installation was NOT recorded'
            }
        }
        # The id is written as a JSON string value, so match it with its quotes:
        # a bare substring could hit an unrelated field that merely contains it.
        if ($verifyText -notmatch ('"' + [regex]::Escape([string]$Record.id) + '"')) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = 'the record was not found in the registry after writing - this installation was NOT recorded'
            }
        }
        return [pscustomobject]@{ Ok = $true; QuarantinePath = $quarantinePath; Warning = $warning }
    })
}

