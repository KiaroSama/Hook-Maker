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
    return -not [string]::Equals($Id + '.json', $script:InstallRegistryMetaName, [System.StringComparison]::OrdinalIgnoreCase)
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
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::Equals($_.Name, $script:InstallRegistryMetaName, [System.StringComparison]::OrdinalIgnoreCase) })
    return @($files | Sort-Object -Property Name)
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
# Parsed-registry cache for READ-ONLY callers, valid only while the file on disk
# is provably unchanged.
#
# Measured against the real 5.0 MB / 525-record registry: ONE install parses the
# whole document THREE times - Get-KnownToolRoots, Get-InstallRecordById, and
# Update-InstallRegistry - at ~700-990 ms each, and Install-Hook.ps1 runs 105
# times in a 21-hook x 5-project wizard run. The first two only READ (a toolRoot
# string and a timeout int); they were paying a full parse for it.
#
# The key is (path, last-write ticks, length), so ANY change by any process -
# including another Hook Maker - misses and re-parses. It is not a TTL and never
# guesses.
#
# WHY THE MUTATING PATH MUST BYPASS IT: ConvertTo-InstallRegistryCurrent mutates
# the registry object IN PLACE and returns it, and Set-InstallRecord then adds to
# it. Handing the cached document to that path would leave an unsaved record
# sitting in the cache if the write failed, and a later read in the same process
# would report it as persisted. Update-InstallRegistry therefore passes -NoCache
# and always parses fresh under the lock.
$script:InstallRegistryCache = $null

# Assembles the whole `{version, installs[]}` document from the per-record
# files. ONE unreadable or unparsable record file makes the WHOLE state
# corrupt, exactly as a damaged single document did: a partial registry that
# reads back as "these are all the installs" would let a real installation be
# silently forgotten and then overwritten, which is the precise failure the
# corrupt state exists to prevent. The reason names the offending file.
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
        $stamp = $directory + '||' + ($parts.ToArray() -join ';')
    }
    catch { $stamp = '' }
    if (-not $NoCache -and -not [string]::IsNullOrEmpty($stamp) -and $null -ne $script:InstallRegistryCache -and
        [string]$script:InstallRegistryCache.Stamp -ceq $stamp) {
        return $script:InstallRegistryCache.State
    }
    $version = $script:InstallRegistrySchemaVersion
    $metaPath = Join-Path $directory $script:InstallRegistryMetaName
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        try {
            $meta = [System.IO.File]::ReadAllText($metaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $meta -and $null -ne $meta.PSObject.Properties['version']) {
                $parsedVersion = 0
                if ([int]::TryParse([string]$meta.version, [ref]$parsedVersion)) { $version = $parsedVersion }
            }
        }
        catch {
            return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = 'the registry metadata file is not valid JSON' }
        }
    }
    $records = New-Object System.Collections.Generic.List[object]
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

function Read-InstallRegistryState {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        # Required by any caller that will mutate, save, or otherwise rely on
        # owning the returned object. See the note above.
        [switch]$NoCache
    )
    # The per-record directory is authoritative once it exists; the single
    # document below is the pre-migration form and is still read as-is.
    if (Test-Path -LiteralPath (Get-InstallRegistryDirectory -ToolRoot $ToolRoot) -PathType Container) {
        return (Read-InstallRegistryFromDirectory -ToolRoot $ToolRoot -NoCache:$NoCache)
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
    if ($state.State -eq 'ok') { return (ConvertTo-InstallRegistryCurrent -Registry $state.Registry) }
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
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    # Belt and braces beside the metadata key: drop the cached parse before the
    # bytes change, so no reader can be served a pre-write document even if a
    # filesystem's timestamp granularity ever failed to move.
    $script:InstallRegistryCache = $null
    $keep = @{}
    foreach ($record in @($Registry.installs)) {
        $id = ''
        if ($null -ne $record -and $null -ne $record.PSObject.Properties['id']) { $id = [string]$record.id }
        if (-not (Test-InstallRecordIdSafe -Id $id)) {
            throw ('An install record has an id that cannot be stored as a file name: ' + $id)
        }
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
        # The id is written as a JSON string value, so match it with its quotes:
        # a bare substring could hit an unrelated field that merely contains it.
        if ($verifyText -notmatch ('"' + [regex]::Escape($id) + '"')) {
            return [pscustomobject]@{
                Ok             = $false
                QuarantinePath = $quarantinePath
                Warning        = 'the record was not found in the registry after writing - this installation was NOT recorded'
            }
        }
        return [pscustomobject]@{ Ok = $true; QuarantinePath = $quarantinePath; Warning = $warning }
    })
}
