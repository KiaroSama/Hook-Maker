# Cloudflare-Deploy / cleanup-evidence validation.
#
# ONE responsibility: decide whether Test-Temp-Cleanup's coordination record is
# usable EVIDENCE right now, and revalidate it against the filesystem it claims
# to describe. Nothing here reads hook input, writes state, mutates anything, or
# decides whether to emit the deployment block - Cloudflare-Deploy.ps1 owns all
# of that and dot-sources this file. It is not runnable on its own: it uses
# Get-CleanupResultPath from the entry point and Get-Field / Read-JsonFile /
# Get-RepoStateFingerprint from _hooklib.ps1, both already loaded by then.
#
# WHY A SEPARATE FILE: Cloudflare-Deploy.ps1 is 659 lines and this logic is
# ~190, so keeping them together would push one file past the 800-line ceiling.
# The install plan stages every .ps1 in a hook's package directory beside its
# entry point, so the installed runtime gets this file automatically.
#
# WHAT READS THIS HOOK'S SOURCE AS TEXT must read BOTH files: a source-text or
# AST assertion pointed at the entry point alone now covers a fraction of the
# hook while still reporting green (the round-35 lesson in .ai/DECISIONS.md).
# scripts\Test-CleanupFreshness.ps1 reads both; the red-proof export path in
# scripts\Test-CloudflareDeploy.ps1 -HookPathOverride needs this file copied
# next to the export for the same reason _hooklib.ps1 does.

# ---- WHAT MAKES A RECORD USABLE AS EVIDENCE ------------------------------
# The category is only half the contract. A record is evidence only when it is
# the CURRENT schema, from a generation whose 'clean' means what this hook thinks
# it means, produced by THIS session, backed by a COMPLETE scan, internally
# consistent, recent - and still true of the filesystem right now. Anything else
# reads as 'unknown', which is never release-ready.
#
# THE DEFECT THAT PUT THIS HERE was accepting a matching `fingerprint` plus a
# `category`. `fingerprint` is Get-RepoStateFingerprint, which hashes HEAD plus
# the SORTED PORCELAIN STRINGS: two different contents behind one ' M path' line
# hash identically, and an IGNORED path never appears in porcelain at all, so
# creating a .pytest_cache after a clean scan leaves it completely unchanged. It
# stays a cheap CACHE HINT below; the proof is Test-CleanupEvidenceStillCurrent.
# The handoff's accepted configuration, MIRRORED from the producer's
# _cleanuprecord.ps1 (an installed runtime is self-contained, so the value is
# copied rather than shared - and Test-CleanupFreshness asserts the two agree).
$script:CleanupWitnessNameMaxLength = 64
$script:CleanupWitnessNameMaxCount = 200

$script:CleanupResultSchemaVersion = 3
$script:CleanupResultProducerGeneration = 3
# Checked as a SET, before the versions: the field shape is a fact about the
# document, a version is only an assertion inside it, and a record from another
# build cannot fake a shape it never had.
$script:CleanupResultRequiredFields = @(
    'schemaVersion', 'producerGeneration', 'sessionId', 'fingerprint', 'category',
    'scanComplete', 'partialCauses', 'candidateCount', 'reviewCount', 'residueCount',
    'evidenceFingerprint', 'timestampUtc',
    # Generation 3: the freshness reference and the detection configuration
    # the verdict was produced under. A record without them is from an older
    # producer and cannot be revalidated the way this consumer revalidates.
    'scanStartedUtc', 'extraCandidateNames', 'extraReviewNames'
)
# A freshness BACKSTOP, never the freshness signal - no TTL notices a
# .pytest_cache created one second after a clean scan. It only bounds how long
# one record may be reused inside a single long session.
$script:CleanupResultMaxAgeMinutes = 120
# Clock-adjustment tolerance when rejecting a future-dated record. Deliberately
# NOT applied to the filesystem comparison, where being strict costs one silent
# Stop and being lax costs a wrong verdict.
$script:CleanupResultSkewSeconds = 2

# ---- CLEANUP-RELEVANT FILESYSTEM OBSERVATION -----------------------------
# Mirrored from hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1's SHIPPED tables -
# $script:DisposableCacheNames + $script:TaskCreatedOnlyNames +
# $script:ReviewOnlyNames, then its two file-pattern lists, then
# $script:HardPruneNames. scripts\Test-CleanupFreshness.ps1 asserts these still
# EQUAL those tables, the same arrangement that keeps the registration and
# runtime-root mirrors in the entry point from rotting into stale lists.
#
# The SHIPPED names are the floor. EXTRA_CANDIDATE_NAMES / EXTRA_REVIEW_NAMES
# live in the producer's installed .env, which this separate runtime cannot
# read - so mirroring only what ships made the observation a strict SUBSET of
# the producer's. Safe against false rejection, and wrong the other way: a
# configured extra candidate appearing after the scan was a name this witness
# never looked for, so a stale verdict stayed 'clean'. The record carries the
# effective configuration now (generation 3) and Get-CleanupWitnessNames widens
# this set to match the scan that actually ran.
$script:CleanupWitnessNames = @(
    '.pytest_cache', '.mypy_cache', '.ruff_cache', '.hypothesis', '.nyc_output',
    '.test-tmp', '.test-temp', 'test-tmp', 'test-temp', '.jest-cache', '.vitest-cache',
    '__pycache__',
    'coverage', 'htmlcov', 'test-results', 'playwright-report', 'blob-report', 'TestResults'
)
$script:CleanupWitnessFilePatterns = @('*.pyc', '*.pyo', '.coverage', 'coverage.xml')
$script:CleanupWitnessPruneNames = @(
    '.git', '.ai', '.claude', '.codex', 'node_modules', '.venv', 'venv', 'env',
    '__pypackages__', 'vendor', 'target', 'dist', 'build', 'out', '.next',
    '.nuxt', '.tox', '.svn', '.hg', 'graphify-out', 'logs', '.cache', '.ci-runner', '.ci-work'
)
# Bounds, so one pathological tree cannot slow a Stop hook. Generous against the
# producer's own 15000-entry default on purpose: hitting a bound reads as
# 'unknown', the safe direction but a SILENT one. No depth bound - the prune set
# and these two already bound the walk, and a third way to go silent buys
# nothing.
$script:CleanupWitnessMaxEntries = 60000
$script:CleanupWitnessMaxSeconds = 5

# The names this witness must look for: the shipped set plus whatever extra
# names the record says the scan was configured with. Bounded, and every entry
# is a literal leaf name - the producer validates them before use and they are
# only ever compared, never expanded or executed.
function Get-CleanupWitnessNames {
    param($Record)
    $names = @($script:CleanupWitnessNames)
    # The cap counts CONFIGURED names only, exactly as the producer's does. The
    # shipped table is not part of anyone's configuration, and counting it here
    # would refuse a configuration the producer accepted - the same
    # producer/consumer disagreement in the opposite direction.
    $extraCount = 0
    foreach ($field in @('extraCandidateNames', 'extraReviewNames')) {
        foreach ($extra in @(Get-Field $Record $field)) {
            $name = ([string]$extra).Trim()
            if ($name -eq '') { continue }
            # DROPPING A NAME HERE IS NOT SAFE. The witness looks for exactly the
            # names the scan looked for; silently skipping one it cannot carry
            # leaves residue under that name invisible and a stale verdict
            # standing. The producer enforces the same bounds, so a record that
            # still exceeds them is from a configuration this side cannot
            # revalidate - the caller is told, and $null says so.
            if ($name.Length -gt $script:CleanupWitnessNameMaxLength) { return $null }
            if ($name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
            $extraCount++
            if ($extraCount -gt $script:CleanupWitnessNameMaxCount) { return $null }
            if ($names -contains $name) { continue }
            $names += $name
        }
    }
    return $names
}

# Does a cleanup-relevant leaf name match? Case-insensitive, like the producer's
# own name sets; the file patterns apply to files only, exactly as they do there.
function Test-CleanupWitnessMatch {
    param([string]$Name, [bool]$IsDir, [string[]]$Names = @())
    $set = $Names
    if (@($set).Count -eq 0) { $set = $script:CleanupWitnessNames }
    if ($set -contains $Name) { return $true }
    if (-not $IsDir) {
        foreach ($pattern in $script:CleanupWitnessFilePatterns) {
            if ($Name -like $pattern) { return $true }
        }
    }
    return $false
}

# Is every cleanup-relevant path still no newer than the instant the producer
# recorded? This is the correctness-bearing half of freshness: the producer's
# verdict describes the tree as it stood at $RecordedUtc, so it still holds only
# while nothing cleanup-relevant has appeared or changed since. That is a
# positive fact about the filesystem rather than a timer, which is exactly what
# the fingerprint could not give (see the contract block above).
#
# Returns $false both for "something newer is there" and for "could not look
# everywhere" - a bound, an unreadable directory, an unusable timestamp. An
# all-clear is never reported on incomplete coverage. Never follows a reparse
# point and never descends into a matched candidate: the producer does neither,
# and a cache tree is the shape that would burn the entry bound.
function Test-CleanupEvidenceStillCurrent {
    param([string]$Root, [DateTime]$RecordedUtc, [string[]]$WitnessNames = @())
    $rootInfo = $null
    try { $rootInfo = New-Object System.IO.DirectoryInfo ($Root) }
    catch { return $false }
    if (-not $rootInfo.Exists) { return $false }
    $queue = New-Object System.Collections.Generic.Queue[System.IO.DirectoryInfo]
    $queue.Enqueue($rootInfo)
    $examined = 0
    $deadline = [DateTime]::UtcNow.AddSeconds($script:CleanupWitnessMaxSeconds)
    while ($queue.Count -gt 0) {
        if ([DateTime]::UtcNow -gt $deadline) { return $false }
        $entries = $null
        try { $entries = @($queue.Dequeue().EnumerateFileSystemInfos()) }
        catch { return $false }
        foreach ($entry in $entries) {
            $examined++
            if ($examined -gt $script:CleanupWitnessMaxEntries) { return $false }
            $attributes = $entry.Attributes
            $isDir = (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            $isLink = (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isDir -and ($script:CleanupWitnessPruneNames -contains $entry.Name)) { continue }
            # The producer also prunes by MARKER FILE - pyvenv.cfg for a
            # virtualenv under any name, CACHEDIR.TAG for any regenerable
            # cache - and this witness did not, so it descended into trees the
            # scan never entered and rejected evidence over paths the producer
            # had deliberately excluded: a permanent 'unknown' no cleanup could
            # clear. Same helper, same rule.
            if ($isDir -and -not $isLink -and (Test-IsMarkerPrunedDirectory $entry.FullName)) { continue }
            if (Test-CleanupWitnessMatch -Name $entry.Name -IsDir $isDir -Names $WitnessNames) {
                $stamp = [DateTime]::MinValue
                try {
                    $stamp = $entry.LastWriteTimeUtc
                    if ($entry.CreationTimeUtc -gt $stamp) { $stamp = $entry.CreationTimeUtc }
                }
                catch { return $false }
                if ($stamp -gt $RecordedUtc) { return $false }
                continue
            }
            if ($isDir -and -not $isLink) { $queue.Enqueue($entry) }
        }
    }
    return $true
}

# The ONE place Test-Temp-Cleanup's coordination record becomes - or fails to
# become - evidence. Always returns a value from $script:CleanupCategories;
# every rejection is 'unknown', never $null and never a pass-through of whatever
# the file happened to say. Ownership is proven by Test-CleanupInstalled BEFORE
# this runs: a record is never installation evidence on its own.
function Get-CleanupEvidenceVerdict {
    param([string]$Root, [string]$SessionId)
    # Read-JsonFile does not catch a malformed document, and this hook runs under
    # $ErrorActionPreference='Stop', so a corrupt record would CRASH a Stop hook
    # rather than degrade. 'unknown' is the documented answer to "cannot read".
    $record = $null
    try { $record = Read-JsonFile -Path (Get-CleanupResultPath -Root $Root) }
    catch { return 'unknown' }
    if ($null -eq $record) { return 'unknown' }

    # 1) SHAPE, then the declared versions.
    foreach ($field in $script:CleanupResultRequiredFields) {
        if ($null -eq $record.PSObject.Properties[$field]) { return 'unknown' }
    }
    if ([string](Get-Field $record 'schemaVersion') -ne [string]$script:CleanupResultSchemaVersion) { return 'unknown' }
    if ([string](Get-Field $record 'producerGeneration') -ne [string]$script:CleanupResultProducerGeneration) { return 'unknown' }

    # 2) ORIGIN - the producer/consumer barrier. Stop hooks for one event run
    # CONCURRENTLY, so this hook regularly reaches the record before the producer
    # rewrites it. Inside one session that is fine, because step 7 revalidates
    # the tree; across sessions it is not, because an earlier session's clean
    # verdict describes a task that has already ended. Both ids must be real -
    # two empty ids are not a match, they are two absences.
    $recordedSession = [string](Get-Field $record 'sessionId')
    if ([string]::IsNullOrWhiteSpace($recordedSession)) { return 'unknown' }
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return 'unknown' }
    if ($recordedSession -ne $SessionId) { return 'unknown' }

    # 3) COVERAGE. The producer already refuses to call a partial scan 'clean';
    # this refuses to take the category on trust without the completeness
    # evidence the same record carries.
    if ((Get-Field $record 'scanComplete') -ne $true) { return 'unknown' }
    if (@(Get-Field $record 'partialCauses').Count -gt 0) { return 'unknown' }

    # 4) VOCABULARY, then internal agreement: a record calling itself clean while
    # counting work still to do is not a clean record, whichever field is wrong.
    $category = [string](Get-Field $record 'category')
    if ($script:CleanupCategories -notcontains $category) { return 'unknown' }
    if ($category -eq 'clean') {
        $reviewCount = -1
        $residueCount = -1
        if (-not [int]::TryParse([string](Get-Field $record 'reviewCount'), [ref]$reviewCount)) { return 'unknown' }
        if (-not [int]::TryParse([string](Get-Field $record 'residueCount'), [ref]$residueCount)) { return 'unknown' }
        if ($reviewCount -ne 0 -or $residueCount -ne 0) { return 'unknown' }
    }

    # 5) FRESHNESS backstop, and the instant step 7 measures against.
    #
    # The reference is scanStartedUtc, not the completion stamp. A candidate
    # created after its own directory had been visited but before the record
    # was written is OLDER than a completion stamp, so it slipped through a
    # witness that compared against one - evidence accepted for a path the scan
    # never inspected. The start instant cannot be beaten that way.
    #
    # ConvertFrom-Json is NOT type-stable across hosts, and casting to [string]
    # first is what breaks. Measured on pwsh 7.6.5 and Windows PowerShell
    # 5.1.26100.9444 for the identical document `"2026-09-13T01:00:00.0000000Z"`:
    # 5.1 leaves it a String, while 7.6.5 decodes it to a [DateTime] whose
    # [string] cast is the CULTURE SHORT FORM '09/13/2026 01:00:00' - no Z, no
    # Kind. Parsing that yields Kind=Unspecified, ToUniversalTime() then reads it
    # as LOCAL and shifts the instant by the machine's offset (+03:30 here), so
    # a record written seconds ago measured 210 minutes old and every clean
    # verdict was rejected on pwsh while passing on 5.1. Take the DateTime as it
    # comes and normalize by KIND instead: an Unspecified value here carries the
    # UTC wall clock the producer wrote ([DateTime]::UtcNow.ToString('o')), so
    # assuming "local" would move it.
    $rawStamp = Get-Field $record 'scanStartedUtc'
    $recordedUtc = [DateTime]::MinValue
    if ($rawStamp -is [DateTime]) { $recordedUtc = $rawStamp }
    elseif (-not [DateTime]::TryParse([string]$rawStamp,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$recordedUtc)) { return 'unknown' }
    if ($recordedUtc.Kind -eq [System.DateTimeKind]::Local) { $recordedUtc = $recordedUtc.ToUniversalTime() }
    elseif ($recordedUtc.Kind -eq [System.DateTimeKind]::Unspecified) {
        $recordedUtc = [DateTime]::SpecifyKind($recordedUtc, [System.DateTimeKind]::Utc)
    }
    $now = [DateTime]::UtcNow
    if ($recordedUtc -gt $now.AddSeconds($script:CleanupResultSkewSeconds)) { return 'unknown' }
    if (($now - $recordedUtc).TotalMinutes -gt $script:CleanupResultMaxAgeMinutes) { return 'unknown' }

    # 6) CACHE HINT. Cheap, and it catches the tracked motion it can see. Kept
    # for that, and explicitly not sufficient on its own.
    if ([string](Get-Field $record 'fingerprint') -ne (Get-RepoStateFingerprint -ProjectRoot $Root)) { return 'unknown' }

    # 7) REVALIDATION against the filesystem the verdict is about.
    # A configuration this side cannot revalidate is UNKNOWN, never clean: the
    # witness would otherwise be looking for fewer names than the scan did.
    $witnessNames = Get-CleanupWitnessNames -Record $record
    if ($null -eq $witnessNames) { return 'unknown' }
    if (-not (Test-CleanupEvidenceStillCurrent -Root $Root -RecordedUtc $recordedUtc -WitnessNames $witnessNames)) { return 'unknown' }

    return $category
}
