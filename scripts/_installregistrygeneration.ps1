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

function Get-InstallRegistryMarkerPath {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Join-Path (Get-InstallRegistryDirectory -ToolRoot $ToolRoot) $script:InstallRegistryWritingMarkerName)
}

# Validate the WHOLE proposed snapshot before any byte is written.
#
# This runs before the directory is even created, so a snapshot that cannot be
# stored safely fails with nothing on disk changed - which is the difference
# between "the save was rejected" and "the save half happened".
function Test-InstallRegistrySnapshot {
    param($Registry)
    $names = New-Object System.Collections.Generic.List[string]
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
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; FileNames = @($names.ToArray()) }
}

# Announce that the directory is mid-write. Written BEFORE the first record and
# removed only after metadata, so its presence means exactly "this generation is
# not complete".
function Start-InstallRegistryGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string[]]$ExpectedFileNames = @()
    )
    $marker = Get-InstallRegistryMarkerPath -ToolRoot $ToolRoot
    $payload = [pscustomobject][ordered]@{
        generation   = [guid]::NewGuid().ToString('N')
        startedUtc   = [DateTime]::UtcNow.ToString('o')
        ownerPid     = $PID
        expectedFiles = @($ExpectedFileNames)
    }
    # Deliberately NOT atomic-written: a marker that fails to appear must fail
    # the save, and a torn marker is still a marker - any content at this path
    # means "incomplete", so its bytes never have to parse.
    [System.IO.File]::WriteAllText($marker, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    return $payload.generation
}

# Activation. After this returns the directory is a complete generation.
function Complete-InstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $marker = Get-InstallRegistryMarkerPath -ToolRoot $ToolRoot
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        # -ErrorAction Stop: a marker that will not clear means the generation
        # cannot be declared complete, and reporting success then would restore
        # the exact false-authority bug this file exists to prevent.
        Remove-Item -LiteralPath $marker -Force -ErrorAction Stop
    }
}

# What a READER needs to know before trusting the directory.
function Get-InstallRegistryGenerationState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $marker = Get-InstallRegistryMarkerPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        return [pscustomobject]@{ Complete = $true; Reason = ''; MarkerPath = $marker }
    }
    # A marker alone does not prove the record SET is partial. The write may have
    # failed at the deletion, metadata or activation step with every record file
    # already on disk - and calling that corrupt would make surviving records
    # UNREADABLE, destroying the documented recovery path where a record that
    # could not be removed is left stale but still findable by a human or a retry.
    #
    # expectedFiles is what distinguishes the two. Every expected record present
    # means the set is whole and may be read; a MISSING expected record is the
    # genuinely partial snapshot that must never be reported as the registry.
    $detail = ''
    $expected = @()
    $known = $false
    try {
        $parsed = [System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -ne $parsed) {
            if ($null -ne $parsed.PSObject.Properties['startedUtc']) { $detail = ' (started ' + [string]$parsed.startedUtc + ')' }
            if ($null -ne $parsed.PSObject.Properties['expectedFiles']) { $expected = @($parsed.expectedFiles); $known = $true }
        }
    }
    catch { $detail = ' (the marker itself is unreadable, which is still an incomplete write)' }
    if ($known) {
        $directory = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
        $missing = @(@($expected) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $directory ([string]$_)) -PathType Leaf) })
        if ($missing.Count -eq 0) {
            return [pscustomobject]@{ Complete = $true; Reason = ''; MarkerPath = $marker }
        }
        $detail += ' (missing ' + [string]$missing.Count + ' expected record file(s))'
    }
    return [pscustomobject]@{
        Complete   = $false
        Reason     = ('the registry directory holds an INCOMPLETE generation' + $detail + ' - an interrupted write, so its record set is not the whole registry')
        MarkerPath = $marker
    }
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
    param([string]$Text, [Parameter(Mandatory = $true)][string]$ExpectedId)
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
