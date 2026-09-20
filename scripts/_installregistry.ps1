# ---------------------------------------------------------------------------
# Install registry persistence layer for MANAGED install records. This file
# owns what a RECORD IS: its stable identity, its per-client subrecords, the
# record-kind predicates, and the upsert that merges one install outcome in.
# Two neighbours carry the rest of the same concern and are dot-sourced below -
# scripts\_installregistrystorage.ps1 (bytes on disk: paths, per-record files,
# read/save, quarantine, locking) and scripts\_installregistrymigrate.ps1
# (schema migration). The other record kind that shares the registry file - the
# discovered records the read-only status scan finds - has its own id
# derivation, validators and merge rules, and lives in
# scripts\_installdiscovered.ps1, which this file also dot-sources below.
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

# The bytes-on-disk half (paths, per-record files, read/save, quarantine, the
# cross-process lock) and the schema-migration half were split out of this file
# at the 800-line ceiling. They are dot-sourced HERE, for the same reason as
# above: the three concerns share one registry file, so consumers keep
# dot-sourcing only _installlib.ps1.
. (Join-Path $PSScriptRoot '_installregistrystorage.ps1')
. (Join-Path $PSScriptRoot '_installregistrymigrate.ps1')

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
        # 'perHookFile': each logical installation owns its OWN file, so ownership
        # is per-file AND per-entry. No shipped client uses it; records do.
        #
        # Such a client is NOT forced into the settingsPath model. A synthesised
        # "settings path" for a per-hook-file client would be a fake that every
        # later consumer would treat as real, which is exactly how an updater
        # ends up rewriting the wrong file. Instead the shape is recorded
        # explicitly and the real location lives in registrationPath.
        [ValidateSet('sharedSettingsFile', 'perHookFile')][string]$RegistrationKind = 'sharedSettingsFile',
        [string]$RegistrationPath = '',
        # Logical -> physical trigger names actually written, so a later reader
        # never has to re-derive the mapping (a client that renames its triggers
        # between schema versions makes the mapping data, not a constant).
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
        # Read defensively, like lastResult/lastReason above: StrictMode throws
        # on a missing property, and an existing record without createdUtc is
        # reachable - a hand-edited or pre-schema record file, which the
        # per-record storage makes an ordinary thing to encounter. Falling back
        # to "now" records the record we are writing rather than aborting the
        # whole install over a field the previous writer never set.
        $existingCreated = ''
        if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['createdUtc']) {
            $existingCreated = [string]$existing.createdUtc
        }
        if ([string]::IsNullOrWhiteSpace($existingCreated)) { $existingCreated = $nowIso }
        Set-ObjectProperty -Object $Record -Name 'createdUtc' -Value (ConvertTo-RegistryUtcTimestamp -Value $existingCreated)
        # Carry forward every client subrecord this invocation did NOT touch.
        #
        # Derived from the capability table, NOT a literal pair. When it was
        # hardcoded, a subrecord for any client outside that pair was silently
        # DROPPED the next time the same record id was installed - taking
        # registrationPath and managedEntryNames with it, which are a
        # per-hook-file client's only proof of what it owns, and leaving an
        # orphaned registration nothing can ever prove is removable.
        #
        # This file already derives the client list this way in
        # Get-InstalledClientNames, with a comment explaining why; the two were
        # inconsistent. Note the OTHER literal pair above (the legacy migration
        # loop) is correct and must stay: its $legacyClients vocabulary only ever
        # held Both/Claude/Codex, so it has nothing else to migrate.
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
# Records ONE install outcome. This is the hot path: called once per hook per
# client - about 1650 times during a full update of a 551-record registry - so
# it must not be O(n) in the number of records. It reads and writes exactly one
# record file (~8.5 ms) instead of parsing and re-serialising the whole
# document (~1.4 s measured on the real registry).
#
# DELIBERATE SEMANTIC NARROWING, worth knowing before debugging a surprise:
# this path validates ONLY the record it is about to write. It no longer parses
# the other 550 records, so it cannot notice that one of THEM is damaged - and
# should not have to, since recording this installation does not depend on
# them. Whole-set validation still happens in Read-InstallRegistryState for
# every caller that reads the whole registry.
function Update-InstallRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)]$Record
    )
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $quarantinePath = ''
        $warning = ''
        $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot

        if ([IO.File]::Exists((Get-RegistryJournalPath $ToolRoot))) {
            $recovery = Repair-InterruptedInstallRegistryGeneration $ToolRoot
            if (-not $recovery.Ok) { return [pscustomobject]@{ Ok = $false; QuarantinePath = ''; Warning = $recovery.Reason } }
            $warning = $recovery.Reason
        }

        # ---- one-off migration from the pre-record-per-file document --------
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            # -NoCache: this path mutates the document it is handed and saves it.
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot -NoCache
            if ($state.State -eq 'corrupt') {
                try { $quarantinePath = Move-CorruptInstallRegistry -ToolRoot $ToolRoot }
                catch {
                    return [pscustomobject]@{
                        Ok = $false
                        QuarantinePath = ''
                        Warning = ('The install registry is unreadable (' + $state.Reason + ') and could not be quarantined: ' + $_.Exception.Message + '. It was left untouched and this installation was NOT recorded.')
                    }
                }
                $warning = 'The install registry was unreadable (' + $state.Reason + '). Its exact contents were preserved at: ' + $quarantinePath + ' - a new registry was started, so previously tracked installations are no longer listed.'
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
                Write-InstallRegistryMeta -ToolRoot $ToolRoot
            }
            else {
                # Splits the single document into per-record files and retires
                # it under a dated name. Paid once, not once per install.
                Save-InstallRegistry -ToolRoot $ToolRoot -Registry (ConvertTo-InstallRegistryCurrent -Registry $state.Registry)
            }
        }

        # PRECONDITIONS ON AN EXISTING DIRECTORY. Asked here, before the merge
        # reads anything: an incomplete generation or a future schema means this
        # build must not write, and finding that out AFTER composing the record
        # would be finding it out too late.
        $mutable = Test-InstallRegistryMutable -ToolRoot $ToolRoot
        if (-not $mutable.Ok) {
            # RECOVER FIRST. An interrupted batch must not wedge the registry:
            # the records that survived it are a coherent set, so they become the
            # registry and nothing is deleted. A future schema is refused here
            # and is never recovered - it is not ours to rewrite.
            $repair = Repair-InterruptedInstallRegistryGeneration -ToolRoot $ToolRoot
            if ($repair.Recovered) {
                if ([string]::IsNullOrWhiteSpace($warning)) { $warning = $repair.Reason }
                $mutable = Test-InstallRegistryMutable -ToolRoot $ToolRoot
            }
            if (-not $mutable.Ok) {
                return [pscustomobject]@{
                    Ok             = $false
                    QuarantinePath = $quarantinePath
                    Warning        = ($mutable.Reason + ' - this installation was NOT recorded and the registry was left exactly as it was')
                }
            }
        }

        # ---- the O(1) path --------------------------------------------------
        $id = ''
        if ($null -ne $Record.PSObject.Properties['id']) { $id = [string]$Record.id }
        if (-not (Test-InstallRecordIdSafe -Id $id)) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = ('the record has an id that cannot be stored (' + $id + ') - this installation was NOT recorded')
            }
        }
        $recordPath = Get-InstallRecordPath -ToolRoot $ToolRoot -Id $id

        # The EXISTING record is needed, and only it: Set-InstallRecord keeps
        # its createdUtc, its history and the OTHER client's subrecord, so
        # installing Claude-only must never drop what Codex registered.
        $existingRecord = $null
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            $raw = ''
            $readable = $true
            try { $raw = [System.IO.File]::ReadAllText($recordPath, [System.Text.Encoding]::UTF8) }
            catch { $readable = $false }
            if ($readable -and -not [string]::IsNullOrWhiteSpace($raw)) {
                try { $existingRecord = $raw | ConvertFrom-Json }
                catch { $existingRecord = $null; $readable = $false }
            }
            elseif ($readable) { $readable = $false }
            if (-not $readable -or $null -eq $existingRecord -or $existingRecord -isnot [System.Management.Automation.PSCustomObject]) {
                # Only THIS record is damaged. Preserve its bytes and carry on:
                # the merge below then starts from nothing for this id, which is
                # the same outcome as a first install, and every other record is
                # untouched.
                $existingRecord = $null
                try {
                    $recordQuarantine = Move-CorruptInstallRecord -ToolRoot $ToolRoot -Id $id
                    if (-not [string]::IsNullOrEmpty($recordQuarantine)) {
                        if ([string]::IsNullOrEmpty($quarantinePath)) { $quarantinePath = $recordQuarantine }
                        $warning = ('The previous record for this installation was unreadable. Its exact contents were preserved at: ' + $recordQuarantine + ' - its install history was not carried forward.')
                    }
                }
                catch {
                    return [pscustomobject]@{
                        Ok             = $false
                        QuarantinePath = $quarantinePath
                        Warning        = ('the previous record for this installation is unreadable and could not be quarantined: ' + $_.Exception.Message + ' - this installation was NOT recorded')
                    }
                }
            }
        }

        # A one-record document, so Set-InstallRecord and the schema migration
        # are reused UNCHANGED - they only ever look at $Registry.installs.
        $existingList = @()
        if ($null -ne $existingRecord) { $existingList = @($existingRecord) }
        $scratch = ConvertTo-InstallRegistryCurrent -Registry ([pscustomobject][ordered]@{
                version  = $script:InstallRegistrySchemaVersion
                installs = $existingList
            })
        Set-InstallRecord -Registry $scratch -Record $Record
        $merged = @($scratch.installs)
        if ($merged.Count -lt 1) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = 'the record could not be merged - this installation was NOT recorded'
            }
        }
        $script:InstallRegistryCache = $null
        $stale = $recordPath + '.tmp'
        if (Test-Path -LiteralPath $stale -PathType Leaf) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
        # The digest of the bytes this write INTENDS, taken from the same
        # serialisation Write-JsonFileAtomic performs (-Depth 50), so the
        # readback below proves the composed record landed - not merely that
        # something carrying the right id is there, which an older generation of
        # the same record satisfies.
        $intendedText = ($merged[0] | ConvertTo-Json -Depth 50)
        $intendedDigest = Get-InstallRecordDigest -Text $intendedText
        Write-JsonFileAtomic -Value $merged[0] -Path $recordPath
        # The set's version marker, written only when it is actually absent -
        # an extra atomic write per install would give back part of what this
        # whole change is for.
        if (-not (Test-Path -LiteralPath (Join-Path $directory $script:InstallRegistryMetaName) -PathType Leaf)) {
            Write-InstallRegistryMeta -ToolRoot $ToolRoot
        }

        # PERSISTENCE IS VERIFIED, NOT ASSUMED. Writing without checking let a
        # silent failure look like success: when a DIRECTORY occupied the
        # registry path, the atomic write moved the temp file INSIDE it and
        # reported ok, so the install was never actually tracked.
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = ('the registry could not be written to ' + $recordPath + ' (the path is not a writable file) - this installation was NOT recorded')
            }
        }
        # Verified by reading the BYTES back, not by re-parsing: the document
        # was serialised from an in-memory object one statement earlier, so a
        # parse could only fail if the atomic write corrupted bytes - which the
        # id check below would equally catch.
        $verifyText = ''
        try { $verifyText = [System.IO.File]::ReadAllText($recordPath, [System.Text.Encoding]::UTF8) }
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
        # Compare the id FIELD - see Test-InstallRecordWriteVerified for why a quoted-id match was not proof.
        $written = Test-InstallRecordWriteVerified -Text $verifyText -ExpectedId $id -ExpectedSha256 $intendedDigest
        if (-not $written.Ok) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = ($written.Reason + ' - this installation was NOT recorded')
            }
        }
        return [pscustomobject]@{ Ok = $true; QuarantinePath = $quarantinePath; Warning = $warning }
    })
}
