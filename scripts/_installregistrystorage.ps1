# ---------------------------------------------------------------------------
# Install registry STORAGE: where the registry lives on disk, how a record file
# is read and written, how a corrupt one is quarantined, and the cross-process
# lock every write is taken under.
#
# Split out of _installregistry.ps1 at the 800-line ceiling. That file keeps
# what a RECORD is - its identity, its client subrecords, its upsert - and
# dot-sources this one for the bytes-on-disk half. Nothing outside changed:
# consumers still dot-source only _installlib.ps1, which pulls in
# _installregistry.ps1, which pulls in this file.
#
# The public surface is unchanged and still speaks in whole
# `{version, installs[]}` documents: Read-InstallRegistryState,
# Read-InstallRegistry, Save-InstallRegistry, Get-InstallRegistryRawText, and
# the lock wrappers Invoke-WithResourceLock / Invoke-WithInstallRegistryLock.
#
# Load-order contract: never dot-sourced standalone. $script:InstallRegistrySchemaVersion
# is defined by _installlib.ps1 before _installregistry.ps1 is pulled in, and is
# read by the functions below; dot-sourcing puts every file in one script scope.
#
# Stores ONLY paths, hashes, and install parameters - never .env values, hook
# stdin, prompt text, tool input, secrets, or any copied file's contents.
# ---------------------------------------------------------------------------

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

# ---- per-record storage ----------------------------------------------------
#
# The registry is stored as ONE FILE PER RECORD under 'install-registry.d',
# not as a single document. Recording one install used to cost a full parse
# plus a full serialize of every record: measured on a real 551-record, 5.8 MB
# registry that is 364 ms + 1041 ms = ~1.4 SECONDS, paid once per hook per
# client - i.e. ~1650 times during a full update, and growing with every
# install (O(n) per write, O(n^2) overall). Writing a single record file costs
# **8.5 ms**. Reading the whole set back costs 498 ms against 364 ms for the
# single document - 134 ms worse, but that happens about once per run instead
# of once per install, so the trade is overwhelmingly in favour.
#
# The single-document form is still READ (older state directories have one)
# and is migrated on the first write. Nothing outside this file changed: the
# public API - Read-InstallRegistryState / Read-InstallRegistry /
# Save-InstallRegistry / Update-InstallRegistry - keeps its exact shape and
# still speaks in whole `{version, installs[]}` documents.
$script:InstallRegistryDirectoryName = 'install-registry.d'
$script:InstallRegistryMetaName = '_meta.json'

function Get-InstallRegistryDirectory {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Join-Path (Get-InstallStateDirectory -ToolRoot $ToolRoot) $script:InstallRegistryDirectoryName)
}

# A record id becomes a FILE NAME. Every id this tool mints is a Get-ShortHash
# hex string, but a record can also arrive from an older or hand-edited
# registry, so this fails CLOSED rather than letting a crafted id ('..',
# 'a/b', a drive letter) escape the directory or collide with the meta file.
function Test-InstallRecordIdSafe {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    if ($Id -notmatch '^[A-Za-z0-9._-]{1,64}$') { return $false }
    if ($Id -match '^\.+$') { return $false }
    if ([string]::Equals($Id + '.json', $script:InstallRegistryMetaName, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    # The generation marker and the Windows device names live in the same
    # namespace as record files; _installregistrygeneration.ps1 owns that list.
    return -not (Test-InstallRecordIdReserved -Id $Id)
}

function Get-InstallRecordPath {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)][string]$Id)
    if (-not (Test-InstallRecordIdSafe -Id $Id)) { throw ('Unsafe install-record id (cannot be used as a file name): ' + $Id) }
    return (Join-Path (Get-InstallRegistryDirectory -ToolRoot $ToolRoot) ($Id + '.json'))
}

# Metadata for the whole set: the only thing that is not per-record.
function Write-InstallRegistryMeta {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Write-JsonFileAtomic -Value ([pscustomobject][ordered]@{ version = $script:InstallRegistrySchemaVersion }) `
        -Path (Join-Path $directory $script:InstallRegistryMetaName)
}

# Every record file, newest-metadata-first so the caller can build a cache key
# without parsing anything. Sorted by name so the assembled `installs` order is
# deterministic across runs and filesystems.
function Get-InstallRecordFiles {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    # Both reserved names live in this directory and end in .json. Neither is a
    # record, and reading either as one would inject a bogus install.
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not [string]::Equals($_.Name, $script:InstallRegistryMetaName, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($_.Name, $script:InstallRegistryWritingMarkerName, [System.StringComparison]::OrdinalIgnoreCase)
        })
    return @($files | Sort-Object -Property Name)
}

function New-EmptyInstallRegistry {
    return [pscustomobject][ordered]@{ version = $script:InstallRegistrySchemaVersion; installs = @() }
}

function Read-InstallRegistryFromDirectory {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [switch]$NoCache)
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    $files = @(Get-InstallRecordFiles -ToolRoot $ToolRoot)
    # Metadata only - no parsing - so an unchanged set is served from cache for
    # the price of a directory listing instead of a 498 ms reparse.
    $stamp = ''
    try {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) { [void]$parts.Add($file.Name + '|' + $file.LastWriteTimeUtc.Ticks + '|' + $file.Length) }
        # METADATA IS PART OF THE IDENTITY OF THIS SNAPSHOT. Leaving it out meant a
        # metadata-only change - a schema bump, or corruption - was served from a
        # cache built before it, so the guards below never saw the new bytes.
        $metaStamp = 'none'
        $metaFile = Join-Path $directory $script:InstallRegistryMetaName
        if (Test-Path -LiteralPath $metaFile -PathType Leaf) {
            $metaItem = Get-Item -LiteralPath $metaFile -Force
            $metaStamp = [string]$metaItem.LastWriteTimeUtc.Ticks + '|' + [string]$metaItem.Length
        }
        $stamp = $directory + '||' + ($parts.ToArray() -join ';') + '||meta:' + $metaStamp
    }
    catch { $stamp = '' }
    if (-not $NoCache -and -not [string]::IsNullOrEmpty($stamp) -and $null -ne $script:InstallRegistryCache -and
        [string]$script:InstallRegistryCache.Stamp -ceq $stamp) {
        return $script:InstallRegistryCache.State
    }
    # SCHEMA VERSION. The bug was never a missing validator - Test-InstallRegistryShape
    # below already rejects a non-numeric, out-of-range or newer-than-supported version.
    # The bug was that this reader did not PASS THE STORED VALUE THROUGH: on an
    # unparseable version it silently left $version at the CURRENT schema, so the
    # validator was handed a valid number and had nothing to reject - unknown data
    # promoted to "this is my schema". An absent metadata FILE stays the documented
    # legacy shape; a metadata file that exists must carry a version, and whatever it
    # carries goes to the validator verbatim.
    $version = $script:InstallRegistrySchemaVersion
    $metaPath = Join-Path $directory $script:InstallRegistryMetaName
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        $meta = $null
        try { $meta = [System.IO.File]::ReadAllText($metaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
        catch {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = 'the registry metadata file is not valid JSON' }
        }
        if ($null -eq $meta -or $null -eq $meta.PSObject.Properties['version']) {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = 'the registry metadata file carries no schema version' }
        }
        $version = $meta.version
    }
    $records = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) }
        catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = ('a record file could not be read: ' + $file.Name) } }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = ('a record file exists but is empty (interrupted or truncated write): ' + $file.Name) }
        }
        $record = $null
        try { $record = $raw | ConvertFrom-Json }
        catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = ('a record file is not valid JSON: ' + $file.Name) } }
        if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = ('a record file does not contain a record object: ' + $file.Name) }
        }
        # "It parsed as an object" never established that aaa.json holds the record
        # whose id is aaa. Without this, a file is served under an id it does not
        # carry and every id-keyed lookup answers with the wrong installation.
        $agreement = Test-InstallRecordFileAgreement -FileName $file.Name -Record $record
        if (-not $agreement.Ok) {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = $agreement.Reason }
        }
        if (-not $seenIds.Add([string]$record.id)) {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = ('two record files carry the same id: ' + [string]$record.id) }
        }
        [void]$records.Add($record)
    }
    $registry = [pscustomobject][ordered]@{ version = $version; installs = @($records.ToArray()) }
    $shape = Test-InstallRegistryShape -Registry $registry
    if (-not $shape.Ok) {
        return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = $shape.Reason }
    }
    $state = [pscustomobject]@{ State = 'ok'; Registry = $registry; Path = $directory; Reason = '' }
    if (-not $NoCache -and -not [string]::IsNullOrEmpty($stamp)) {
        $script:InstallRegistryCache = [pscustomobject]@{ Stamp = $stamp; State = $state }
    }
    return $state
}

# The registry's RAW TEXT, whatever shape it is stored in: every record file
# concatenated, or the single pre-migration document. For callers that must
# prove something about the BYTES rather than the parsed records - that no
# secret was ever written, that a -WhatIf run changed nothing - and that would
# otherwise have to know which storage shape is in use.
function Get-InstallRegistryRawText {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($file in @(Get-InstallRecordFiles -ToolRoot $ToolRoot)) {
            try { [void]$parts.Add([System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)) }
            catch { }
        }
        return ($parts.ToArray() -join "`n")
    }
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
    catch { return '' }
}

# Snapshot readers use the same lock as writers; nested calls on this runspace
# are reentrant, so an update cannot deadlock when it consults the registry.
function Read-InstallRegistryState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [switch]$NoCache)
    $directory = Get-InstallStateDirectory $ToolRoot
    if (-not [IO.Directory]::Exists($directory)) { return (Read-InstallRegistryStateUnlocked -ToolRoot $ToolRoot -NoCache:$NoCache) }
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        try {
            $journal = Read-RegistryJournal $ToolRoot
            if ($null -ne $journal) { return (Read-RegistryBeforeState -ToolRoot $ToolRoot -Journal $journal) }
            return (Read-InstallRegistryStateUnlocked -ToolRoot $ToolRoot -NoCache:$NoCache)
        }
        catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = $_.Exception.Message } }
    })
}

function Read-InstallRegistryStateUnlocked {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        # Required by any caller that will mutate, save, or otherwise rely on
        # owning the returned object. See the note above.
        [switch]$NoCache
    )
    # The per-record directory is authoritative once it holds a COMPLETE
    # generation; the single document below is the pre-migration form and is
    # still read as-is.
    #
    # "The directory exists" was the old test, and it was wrong: Save creates the
    # directory before writing the first record, so an interrupted save published
    # a SUBSET as the whole registry while the intact legacy document sat beside
    # it, ignored. A write now leaves a marker until it has finished, and an
    # unfinished generation falls back to the old snapshot rather than being
    # believed.
    if (Test-Path -LiteralPath (Get-InstallRegistryDirectory -ToolRoot $ToolRoot) -PathType Container) {
        $generation = Get-InstallRegistryGenerationState -ToolRoot $ToolRoot
        if ($generation.Complete) {
            return (Read-InstallRegistryFromDirectory -ToolRoot $ToolRoot -NoCache:$NoCache)
        }
        $legacyPath = Get-InstallRegistryPath -ToolRoot $ToolRoot
        if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) {
            # No older snapshot to fall back to. Reporting the partial set as ok
            # is the one thing that must not happen, so this is corrupt - which
            # routes callers into quarantine-and-report instead of silent loss.
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = (Get-InstallRegistryDirectory -ToolRoot $ToolRoot); Reason = $generation.Reason }
        }
        # Fall through: the legacy document is still the last COMPLETE snapshot.
    }
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'missing'; Registry = (New-EmptyInstallRegistry); Path = $path; Reason = '' }
    }
    $stamp = $null
    try {
        $item = Get-Item -LiteralPath $path -Force
        $stamp = [string]$path + '|' + $item.LastWriteTimeUtc.Ticks + '|' + $item.Length
    }
    catch { }
    if (-not $NoCache -and $null -ne $stamp -and $null -ne $script:InstallRegistryCache -and
        [string]$script:InstallRegistryCache.Stamp -ceq $stamp) {
        return $script:InstallRegistryCache.State
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
    $state = [pscustomobject]@{ State = 'ok'; Registry = $parsed; Path = $path; Reason = '' }
    # Only a clean parse is cached. A corrupt/missing read returns above without
    # populating it, so a damaged registry is re-examined every time.
    if (-not $NoCache -and $null -ne $stamp) {
        $script:InstallRegistryCache = [pscustomobject]@{ Stamp = $stamp; State = $state }
    }
    return $state
}

# Read-only accessor for callers that just want the records (the updater's
# plan, tests, reporting). A corrupt registry reads back as EMPTY here but is
# never written over by this function - mutation goes through
# Update-InstallRegistry, which quarantines first.
function Read-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $state = Read-InstallRegistryState -ToolRoot $ToolRoot
    # ALWAYS AN OBJECT WITH AN installs LIST. A caller reading `.installs` off
    # the result is the normal shape, and returning $null - which a state that
    # reports ok with no registry would do - turns that read into a StrictMode
    # failure several frames away from the cause. An empty registry says the
    # same thing without the crash; the STATE, not this function, is where
    # unreadable is reported.
    if ($null -ne $state -and [string]$state.State -eq 'ok' -and $null -ne $state.Registry) {
        $current = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
        if ($null -ne $current) { return $current }
    }
    return (New-EmptyInstallRegistry)
}

# Retires the pre-migration single document once the per-record directory is
# authoritative. The bytes are KEPT under a dated name - never deleted - so a
# migration can always be inspected or reversed by hand.
function Complete-InstallRegistryMigration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $directory = Split-Path -Parent $path
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $candidate = Join-Path $directory ('install-registry.migrated-' + $stamp + '.json')
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory ('install-registry.migrated-' + $stamp + '-' + $suffix + '.json')
        $suffix++
        if ($suffix -gt 100) { return '' }
    }
    try { Move-Item -LiteralPath $path -Destination $candidate -Force; return $candidate }
    catch { return '' }
}

# Writes a WHOLE document back as per-record files. Used by the batch callers
# (uninstall, rescan, tests); the per-install hot path uses
# Update-InstallRegistry instead and never comes through here.
#
# Records absent from $Registry.installs have their files DELETED - that is how
# a removal reaches disk. Unchanged records are not rewritten: serialising and
# comparing is far cheaper than 551 atomic writes, and it keeps mtimes (and so
# the read cache) stable for everything the caller did not actually touch.
function Save-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)]$Registry)
    $snapshot = Test-InstallRegistrySnapshot $Registry
    if (-not $snapshot.Ok) { throw $snapshot.Reason }
    Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        if (-not (Get-InstallRegistryGenerationState $ToolRoot).Complete) {
            $recovery = Repair-InterruptedInstallRegistryGeneration $ToolRoot
            if (-not $recovery.Ok) { throw $recovery.Reason }
        }
        Assert-RegistryMetadataSupported (Get-InstallRegistryDirectory $ToolRoot)
        Save-InstallRegistryUnlocked -ToolRoot $ToolRoot -Registry $Registry
    }
}

function Save-InstallRegistryUnlocked {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)]$Registry)
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    # VALIDATE THE WHOLE SNAPSHOT FIRST, before the directory is even created. A
    # snapshot that cannot be stored safely must fail with nothing on disk
    # changed - the difference between "the save was rejected" and "the save half
    # happened". Duplicate ids matter as much as unsafe ones: two records sharing
    # an id collapse into one file, silently erasing the first.
    $snapshot = Test-InstallRegistrySnapshot -Registry $Registry
    if (-not $snapshot.Ok) { throw $snapshot.Reason }
    # Belt and braces beside the metadata key: drop the cached parse before the
    # bytes change, so no reader can be served a pre-write document even if a
    # filesystem's timestamp granularity ever failed to move.
    $script:InstallRegistryCache = $null
    # From here the directory is MID-WRITE and no reader may trust it. The marker
    # clears only after metadata lands, so any failure below leaves a detectable
    # incomplete generation instead of an authoritative subset. Creating the
    # DIRECTORY is part of that step now: doing it here left a window in which an
    # empty unmarked directory existed, and an unmarked directory is
    # authoritative - it published "nothing is installed".
    [void](Start-InstallRegistryGeneration -ToolRoot $ToolRoot -ExpectedFileNames @($snapshot.FileNames) -ExpectedRecords @($snapshot.Expected))
    $keep = @{}
    foreach ($record in @($Registry.installs)) {
        # Proved safe AND unique by Test-InstallRegistrySnapshot above, before
        # anything was written.
        $id = [string]$record.id
        $keep[$id + '.json'] = $true
        $recordPath = Get-InstallRecordPath -ToolRoot $ToolRoot -Id $id
        # Compared only when there is something to compare against. Serialising
        # to decide whether to serialise is pure waste on a first write, and a
        # first write is every record during the one-off migration.
        $existing = $null
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            try { $existing = [System.IO.File]::ReadAllText($recordPath, [System.Text.Encoding]::UTF8) }
            catch { $existing = $null }
        }
        # -Depth 50 mirrors Write-JsonFileAtomic exactly; a mismatch here would
        # only ever cost an unnecessary rewrite, never a wrong file.
        if ($null -eq $existing -or -not [string]::Equals($existing, ($record | ConvertTo-Json -Depth 50), [System.StringComparison]::Ordinal)) {
            $stale = $recordPath + '.tmp'
            if (Test-Path -LiteralPath $stale -PathType Leaf) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
            Write-JsonFileAtomic -Value $record -Path $recordPath
        }
    }
    foreach ($file in @(Get-InstallRecordFiles -ToolRoot $ToolRoot)) {
        if (-not $keep.ContainsKey($file.Name)) {
            # Deliberately NOT -ErrorAction SilentlyContinue. A deletion that
            # cannot land means the record is STILL TRACKED, and swallowing it
            # would let an uninstall report success while the registry still
            # lists the hook - a silent false success, which is the exact
            # failure the uninstaller's registry component exists to report.
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }
    }
    Write-InstallRegistryMeta -ToolRoot $ToolRoot
    # ACTIVATION: everything this generation promised is on disk, so the directory
    # becomes authoritative HERE and not one statement earlier.
    Complete-InstallRegistryGeneration -ToolRoot $ToolRoot
    # Only now may the legacy single document be retired - until activation it was
    # the last COMPLETE snapshot and the reader's fallback.
    [void](Complete-InstallRegistryMigration -ToolRoot $ToolRoot)
    $script:InstallRegistryCache = $null
}

# Preserves a corrupt registry's exact bytes under a collision-safe name
# instead of destroying it. Returns the quarantine path, or throws so the
# caller can leave the original untouched and report tracking failure.
# Moves ONE unreadable record file out of the set, so a single damaged record
# cannot make every other installation unrecordable. The bytes are kept.
function Move-CorruptInstallRecord {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)][string]$Id)
    $recordPath = Get-InstallRecordPath -ToolRoot $ToolRoot -Id $Id
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return '' }
    # Quarantined OUTSIDE the record directory: a '*.json' left inside it would
    # be read back as a record on the next scan.
    $stateDirectory = Get-InstallStateDirectory -ToolRoot $ToolRoot
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $candidate = Join-Path $stateDirectory ('install-record-' + $Id + '.corrupt-' + $stamp + '.json')
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $stateDirectory ('install-record-' + $Id + '.corrupt-' + $stamp + '-' + $suffix + '.json')
        $suffix++
        if ($suffix -gt 100) { throw 'Could not find a free quarantine name for the corrupt install record.' }
    }
    Move-Item -LiteralPath $recordPath -Destination $candidate -Force
    return $candidate
}

function Move-CorruptInstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    # Directory shape: rename the whole set aside. Its identity is hashed from
    # the file LISTING, never from the contents - quarantining must not depend
    # on reading files that are, by definition, possibly unreadable.
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $parts = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -Force -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
                [void]$parts.Add($file.Name + '|' + $file.Length)
            }
        }
        catch { }
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $shortHash = Get-ShortHash (($parts.ToArray() -join ';'))
        $parent = Split-Path -Parent $directory
        $candidate = Join-Path $parent ('install-registry.corrupt-' + $stamp + '-' + $shortHash + '.d')
        $suffix = 1
        while (Test-Path -LiteralPath $candidate) {
            $candidate = Join-Path $parent ('install-registry.corrupt-' + $stamp + '-' + $shortHash + '-' + $suffix + '.d')
            $suffix++
            if ($suffix -gt 100) { throw 'Could not find a free quarantine name for the corrupt install registry.' }
        }
        Move-Item -LiteralPath $directory -Destination $candidate -Force
        if (Test-Path -LiteralPath $directory) { throw 'The corrupt install registry directory could not be moved aside.' }
        $script:InstallRegistryCache = $null
        return $candidate
    }
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
#
# The default wait is sized to the HOLDERS, not guessed. A whole-registry read
# holds this lock ~2.7 s and a record write ~1.4 s (950 records, measured
# 2026-09-26), and FileShare.None has no queue: a waiter can lose the race to
# every release. At 10 s, four wizard windows relocating renamed projects at
# once lost dozens of records and three windows died on their first read. 120 s
# is a ceiling for that load, not an expected wait; a crashed holder is still
# reclaimed at once by Open-CrashAwareLock, and a live holder that never lets
# go still ends in the same timeout error. Resource locks keep their 10 s:
# their holders are short.
function Invoke-WithInstallRegistryLock {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)][scriptblock]$Action, [int]$TimeoutSeconds = 120)
    $directory = Get-InstallStateDirectory -ToolRoot $ToolRoot
    [void][IO.Directory]::CreateDirectory($directory)
    $lockPath = Join-Path $directory 'install-registry.lock'
    if ($null -eq (Get-Variable -Name InstallRegistryHeldLocks -Scope Script -ErrorAction SilentlyContinue)) { $script:InstallRegistryHeldLocks = @{} }
    $ownerKey = [IO.Path]::GetFullPath($lockPath).ToUpperInvariant() + '|' + [Threading.Thread]::CurrentThread.ManagedThreadId
    if ($script:InstallRegistryHeldLocks.ContainsKey($ownerKey)) { return (& $Action) }
    $stream = Open-CrashAwareLock -LockPath $lockPath -TimeoutSeconds $TimeoutSeconds
    $script:InstallRegistryHeldLocks[$ownerKey] = $stream
    try { return (& $Action) }
    finally {
        $script:InstallRegistryHeldLocks.Remove($ownerKey)
        if ($null -ne $stream) { $stream.Dispose() }
        # Leave the inode stable; a waiting writer may already hold this file.
    }
}

