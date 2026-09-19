# ---------------------------------------------------------------------------
# Completeness and identity guards for the per-record install registry.
#
# WHY THIS FILE EXISTS (F07): Save-InstallRegistry created install-registry.d
# BEFORE writing the first record, and every reader treated "the directory
# exists" as proof that the directory is authoritative. A failure after the
# first record therefore published a SUBSET as the whole registry while the
# still-intact legacy single document was ignored - installs simply vanished,
# and nothing reported an error.
#
# The fix is a generation marker, not a rewrite of the storage format. A write
# announces itself before touching a record and clears the marker only after
# metadata lands; a reader that sees the marker knows the directory is an
# INCOMPLETE generation and must not be believed. That keeps the O(1)
# per-record hot path exactly as it was - no quadratic full rewrite - while
# making an interrupted write detectable instead of silently authoritative.
#
# Also here (F08) are the identity and version guards that must run before a
# set of record files is trusted: ids that are unique and agree with their own
# file names, and a schema version that is actually a number and not from the
# future.
#
# Split from _installregistry.ps1 because that file is already past the
# file-size ceiling; this is a distinct responsibility (is this snapshot
# COMPLETE and COHERENT) from storing and mutating records.
# ---------------------------------------------------------------------------

$script:InstallRegistryWritingMarkerName = '_writing.json'
. (Join-Path $PSScriptRoot '_installregistryjournal.ps1')

# Names a record id may never take, whatever the caller says.
#
# `_writing` was accepted, so a hook whose record id was `_writing` stored
# itself AS the generation marker - and activation then DELETED that record as
# its last step. The reserved device names are the same class of defect one
# layer down: `CON.json`, `NUL.json` and the COM/LPT family do not behave like
# files on Windows, so a record with such an id is written to a device and read
# back as something else, or not at all.
$script:InstallRegistryReservedIds = @(
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9'
)

function Test-InstallRecordIdReserved {
    param([AllowEmptyString()][string]$Id)
    $text = ([string]$Id).Trim().ToLowerInvariant()
    if ($text -eq '') { return $true }
    if ([string]::Equals(($text + '.json'), $script:InstallRegistryWritingMarkerName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    # A device name is reserved with ANY extension, so the check is on the stem.
    $stem = $text
    $dot = $stem.IndexOf('.')
    if ($dot -ge 0) { $stem = $stem.Substring(0, $dot) }
    return ($script:InstallRegistryReservedIds -contains $stem)
}

# The digest of one record's intended bytes. Not Get-FileHash: that cmdlet lives
# in a MODULE, and a Windows PowerShell 5.1 process started under a pwsh 7
# parent can come up without it - which is exactly the shape an install runs in.
function Get-InstallRecordDigest {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-InstallRegistryMarkerPath {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Get-RegistryJournalPath $ToolRoot)
}

# Validate the WHOLE proposed snapshot before any byte is written.
#
# This runs before the directory is even created, so a snapshot that cannot be
# stored safely fails with nothing on disk changed - which is the difference
# between "the save was rejected" and "the save half happened".
function Test-InstallRegistrySnapshot {
    param($Registry)
    $names = New-Object System.Collections.Generic.List[string]
    $intended = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($Registry.installs)) {
        $id = ''
        if ($null -ne $record -and $null -ne $record.PSObject.Properties['id']) { $id = [string]$record.id }
        if (-not (Test-InstallRecordIdSafe -Id $id)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('an install record has an id that cannot be stored as a file name: ' + $id); FileNames = @() }
        }
        # Two records sharing an id would collapse into ONE file, so the second
        # would silently erase the first. Caught here, before anything is written.
        if (-not $seen.Add($id)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('two install records share the id: ' + $id); FileNames = @() }
        }
        [void]$names.Add($id + '.json')
        # THE INTENDED BYTES, decided here and carried into the marker. A
        # generation that promises "these file names exist" cannot tell a file
        # that already received its new bytes from one still holding the old
        # ones, so an interrupted batch read back as complete while being half
        # old and half new. -Depth 50 mirrors Write-JsonFileAtomic exactly, so
        # the digest is of the bytes the writer will actually produce.
        [void]$intended.Add([pscustomobject]@{
                name   = ($id + '.json')
                sha256 = (Get-InstallRecordDigest -Text ($record | ConvertTo-Json -Depth 50))
            })
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; FileNames = @($names.ToArray()); Expected = @($intended.ToArray()) }
}

# Announce that the directory is mid-write. Written BEFORE the first record and
# removed only after metadata, so its presence means exactly "this generation is
# not complete".
function Start-InstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [string[]]$ExpectedFileNames = @(), [object[]]$ExpectedRecords = @())
    return (Start-RegistryJournal -ToolRoot $ToolRoot -ExpectedFileNames $ExpectedFileNames -ExpectedRecords $ExpectedRecords)
}

# Activation. After this returns the directory is a complete generation.
function Complete-InstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    Complete-RegistryJournal -ToolRoot $ToolRoot
}

# What a READER needs to know before trusting the directory.
function Get-InstallRegistryGenerationState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $marker = Get-RegistryJournalPath $ToolRoot
    $legacy = Join-Path (Get-InstallRegistryDirectory $ToolRoot) '_writing.json'
    $incomplete = [IO.File]::Exists($marker) -or [IO.Directory]::Exists($marker) -or [IO.File]::Exists($legacy)
    return [pscustomobject]@{ Complete = (-not $incomplete); MarkerPath = $marker; Reason = $(if ($incomplete) { 'The registry transaction is half written or not activated; use its previous committed snapshot.' } else { '' }) }
}

# A record file named aaa.json must contain the record whose id is aaa.
# Without this, a file can be served under an id it does not carry, and every
# id-keyed lookup above it silently answers with the wrong installation.
function Test-InstallRecordFileAgreement {
    param([Parameter(Mandatory = $true)][string]$FileName, $Record)
    $id = ''
    if ($null -ne $Record -and $null -ne $Record.PSObject.Properties['id']) { $id = [string]$Record.id }
    if ([string]::IsNullOrWhiteSpace($id)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('a record file carries no id: ' + $FileName) }
    }
    if (-not (Test-InstallRecordIdSafe -Id $id)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('a record file carries an unsafe id: ' + $FileName) }
    }
    if (-not [string]::Equals(($id + '.json'), $FileName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('a record file name disagrees with the id it contains: ' + $FileName + ' holds id ' + $id) }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# Moved here from _installregistry.ps1: this is a SNAPSHOT VALIDATOR, which is
# what this file is for, and that one is past the size ceiling. Behaviour is
# unchanged - the move is a relocation, not a rewrite.
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

# Prove that the bytes just written ARE the record that was meant to be written.
#
# The old check regex-matched the quoted id anywhere in the file, so a record
# holding the wanted id in some OTHER field satisfied the verifier:
# {"id":"bbb","unrelated_field":"aaa"} passed as proof that aaa was recorded.
# Quoting established that the value was a JSON string; it never established
# which FIELD it was. Parse, then compare the id field exactly.
function Test-InstallRecordWriteVerified {
    param(
        [string]$Text,
        [Parameter(Mandatory = $true)][string]$ExpectedId,
        # The digest of the bytes the caller meant to write. The id proves WHICH
        # record landed; only this proves it is the record that was composed -
        # an older generation of the same id passes every id check there is.
        [AllowEmptyString()][string]$ExpectedSha256 = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actualDigest = Get-InstallRecordDigest -Text $Text
        if (-not [string]::Equals($actualDigest, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'the record read back after writing does not match the bytes that were composed for it' }
        }
    }
    $record = $null
    try { $record = $Text | ConvertFrom-Json } catch { $record = $null }
    if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the record read back after writing is not a JSON object' }
    }
    if ($null -eq $record.PSObject.Properties['id']) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the record read back after writing carries no id' }
    }
    if (-not [string]::Equals([string]$record.id, $ExpectedId, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('the record read back after writing holds a different id: ' + [string]$record.id) }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# MAY THIS DIRECTORY BE MUTATED AT ALL? The per-record upsert is the hot path
# and it used to walk straight into writing: it never asked whether the
# directory held a COMPLETE generation, nor whether its metadata came from a
# NEWER Hook Maker. Writing one record into a half-written batch cements the
# mixed snapshot as the registry; writing into a future schema silently
# downgrades state this build does not understand.
#
# Both answers are REFUSALS, not repairs. A future version is not damage and is
# never quarantined - it is simply not ours to rewrite - and an interrupted
# generation is recovered by the process that owns it (or by a full save),
# never by adding one more record on top of it.
function Test-InstallRegistryMutable {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return [pscustomobject]@{ Ok = $true; Reason = '' }
    }
    $generation = Get-InstallRegistryGenerationState -ToolRoot $ToolRoot
    if (-not $generation.Complete) {
        return [pscustomobject]@{ Ok = $false; Reason = $generation.Reason }
    }
    $metaPath = Join-Path $directory $script:InstallRegistryMetaName
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        # No metadata yet is the documented legacy/first-write shape.
        return [pscustomobject]@{ Ok = $true; Reason = '' }
    }
    $meta = $null
    try { $meta = [System.IO.File]::ReadAllText($metaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Ok = $false; Reason = 'the registry metadata file is not valid JSON' } }
    if ($null -eq $meta -or $null -eq $meta.PSObject.Properties['version']) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the registry metadata file carries no schema version' }
    }
    $version = 0
    if (-not [int]::TryParse([string]$meta.version, [ref]$version)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('the registry metadata version is not a number: ' + [string]$meta.version) }
    }
    if ($version -gt $script:InstallRegistrySchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('the registry was written by a newer Hook Maker (schema ' + $version + ' > ' + $script:InstallRegistrySchemaVersion + ') and was left untouched') }
    }
    if ($version -lt 1) {
        return [pscustomobject]@{ Ok = $false; Reason = ('the registry metadata version is out of range: ' + $version) }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# Recover only a verified previous committed snapshot. A future schema is
# untouched; a legacy partial batch with no journal is explicitly unavailable.
function Repair-InterruptedInstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Restore-RegistryJournal -ToolRoot $ToolRoot)
}
