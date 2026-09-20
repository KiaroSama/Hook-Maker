# Test-Temp-Cleanup: WHAT IS OUT THERE. The explicit detection tables, the
# name-token validator that keeps a configured hint a bare leaf name, and the
# bounded, reparse-point-refusing walk that finds candidates and measures them.
#
# This is discovery only. It decides nothing about a candidate's fate: it
# returns the recognized candidates AND the scan's completeness with its exact
# named causes, and the entry script is what turns that into a report. Keeping
# the two apart is the point - an empty result from an INCOMPLETE scan must
# never read as "the project is clean".
#
# Split out of Test-Temp-Cleanup.ps1 at the 800-line ceiling; dot-sourced by it
# in the same position the block occupied, so the tables below are built in that
# scope before anything reads them.
#
# $script:CleanupExtraNameMaxLength comes from _cleanuprecord.ps1, which the
# entry script dot-sources after this file. That is unchanged: the value is read
# at call time, and every call happens after both files are loaded.
# ---------------------------------------------------------------------------

# ---- explicit detection tables (never grown by guessing/heuristics) -------
$script:DisposableCacheNames = @(
    '.pytest_cache', '.mypy_cache', '.ruff_cache', '.hypothesis', '.nyc_output',
    '.test-tmp', '.test-temp', 'test-tmp', 'test-temp', '.jest-cache', '.vitest-cache'
)
# Only describable as disposable when they genuinely APPEARED during this
# session; a pre-existing one is ambiguous, never disposable.
$script:TaskCreatedOnlyNames = @('__pycache__')
$script:TaskCreatedOnlyFilePatterns = @('*.pyc', '*.pyo')
$script:ReviewOnlyNames = @('coverage', 'htmlcov', 'test-results', 'playwright-report', 'blob-report', 'TestResults')
$script:ReviewOnlyFilePatterns = @('.coverage', 'coverage.xml')
# Never surfaced as a candidate and never descended into, whatever any config
# says: source control, this tool's and every supported client's own config and
# runtime state, dependency stores, and build/compiler output roots. A client's
# config/runtime directory must never be mistaken for test residue.
# '.cache' and '.ci-runner' are the same lesson twice. A pip HTTP cache
# (.cache/pip/http-v2/<hash fan-out>) and a registered Actions runner checked out
# in the project (.ci-runner - measured at 21,050 entries and 16 levels, 79% of
# one project's directories) each blow the entry/depth ceilings on their own, for
# a PARTIAL baseline describing CI or package-manager runtime state, not residue.
# The 2026-09-19 additions are the same lesson a third time. '.codebase-memory'
# is rewritten wholesale on every index and one team measured it at ~6 GB, and
# '.ci-runner-win' and '.ci-cache' are the other two spellings the environment
# rules give project-owned CI artifacts - each blows the entry/depth ceilings
# on its own, for a PARTIAL baseline describing runtime state, not residue.
# '.specify' joins them as local-only planning infrastructure.
#
# 'specs' and 'plans' are deliberately NOT here. This list matches by NAME at
# any depth, which is broader than the rooted '/specs/' and '/plans/' ignore
# patterns, and both are plausible names for ordinary project directories that
# could hold real residue. Nothing is lost by walking them: a candidate is only
# ever surfaced from the named lists above, so neither can be deleted either way.
$script:HardPruneNames = @(
    '.git', '.ai', '.claude', '.codex', 'node_modules', '.venv', 'venv', 'env',
    '__pypackages__', 'vendor', 'target', 'dist', 'build', 'out', '.next',
    '.nuxt', '.tox', '.svn', '.hg', 'graphify-out', 'logs', '.cache', '.ci-runner', '.ci-work',
    '.ci-runner-win', '.ci-cache', '.codebase-memory', '.specify'
)
# Bounds the per-candidate size walk so one pathological tree cannot make the
# hook slow. ENTRIES, not files: a tree of empty directories contains no files
# to count, so a file-only ceiling left the walk unbounded on exactly the shape
# that runs away. The seconds ceiling is the outer backstop for a filesystem
# where each entry is cheap to count but slow to read. DEPTH is the third bound:
# Get-CleanupScan has always had a MaxDepth, this walk had none at all, so a
# deep real tree was bounded only by entries and time.
$script:SizeWalkMaxEntries = 2000
$script:SizeWalkMaxSeconds = 5
$script:SizeWalkMaxDepth = 8

# Production-inert test seam for the TIME bound, which is otherwise unprovable -
# a genuine 5-second walk cannot be forced deterministically, so the guard would
# ship with no red proof behind it. Read from the ENVIRONMENT only: never from
# .env, never documented in .env.example (same convention as
# LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES in Large-File-Check). It can only
# TIGHTEN the ceiling - a value that is negative, unparseable, or above
# $script:SizeWalkMaxSeconds is ignored - so it can never be used to widen the
# bound it exists to prove. Invariant culture, because a comma-decimal machine
# must read '0.5' the same way.
$script:SizeWalkSecondsEnvVar = 'TESTTEMPCLEANUP_TEST_SIZE_WALK_MAX_SECONDS'
function Get-SizeWalkSecondsBudget {
    $raw = [string][Environment]::GetEnvironmentVariable($script:SizeWalkSecondsEnvVar)
    $parsed = 0.0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and
        [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and
        $parsed -ge 0 -and $parsed -le $script:SizeWalkMaxSeconds) {
        return $parsed
    }
    return [double]$script:SizeWalkMaxSeconds
}

# A plain hashtable, deliberately, as the name/cause set type throughout this
# hook. It is case-insensitive by default (matching the old HashSet's
# OrdinalIgnoreCase), and unlike a generic collection it is NOT unrolled when
# returned from a function and never hits the PSObject-wrapped-collection trap
# described at Get-CleanupScan.
function New-NameSet {
    param([string[]]$Names)
    $set = @{}
    foreach ($name in $Names) { if (-not [string]::IsNullOrWhiteSpace($name)) { $set[$name.Trim()] = $true } }
    return $set
}

# A detection hint must be a bare leaf NAME: no separators, no traversal, no
# drive letter, no UNC prefix, no environment-variable expansion.
function Test-CandidateNameToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    $t = $Token.Trim()
    if ($t -match '[\\/]' -or $t -match '\.\.' -or $t -match '^[A-Za-z]:' -or $t.StartsWith('\\') -or $t -match '[%$]') { return $false }
    # The handoff's accepted length, enforced HERE so this side never scans for a
    # name it cannot hand to the consumer intact. The witness silently dropped
    # anything longer than this, so a 65-character configured name was scanned
    # here, invisible there, and residue under it left a stale 'clean' standing.
    if ($t.Length -gt $script:CleanupExtraNameMaxLength) { return $false }
    return $true
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Bounded, non-following scan. Returns the recognized candidates AND the scan's
# completeness with its exact named causes - the caller must never assume a
# candidate-free result means the project is clean (defect B-06: the old code
# recorded 'clean' on an empty result with no completeness check at all).
function Get-CleanupScan {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExtraCandidateNames = @(),
        [string[]]$ExtraReviewNames = @(),
        [int]$MaxEntries = 5000,
        [int]$MaxDepth = 8
    )
    $candidateSet = New-NameSet ($script:DisposableCacheNames + $ExtraCandidateNames)
    $taskCreatedSet = New-NameSet $script:TaskCreatedOnlyNames
    $reviewSet = New-NameSet ($script:ReviewOnlyNames + $ExtraReviewNames)
    $pruneSet = New-NameSet $script:HardPruneNames

    # Collections built with New-Object come back PSObject-WRAPPED, and `@($list)`
    # on such a List[object] takes the ICollection.CopyTo fast path into a
    # PSObject[] and throws "Argument types do not match" on BOTH pwsh 7 and
    # Windows PowerShell 5.1 (measured). Always cross the boundary with
    # .ToArray() (or a hashtable's .Keys), never with @($listVariable).
    $found = New-Object System.Collections.Generic.List[object]
    $causes = @{}
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $Root; Depth = 0 })
    $scanned = 0
    $limitReached = $false

    while ($stack.Count -gt 0) {
        if ($scanned -ge $MaxEntries) { $limitReached = $true; break }
        $current = $stack.Pop()
        $entries = $null
        try { $entries = @(Get-ChildItem -LiteralPath $current.Path -Force -ErrorAction Stop) }
        catch {
            # B-01: a directory that cannot be enumerated used to be swallowed
            # by a bare `continue`, so the caller could not tell coverage apart
            # from cleanliness. It is now a NAMED partial cause.
            $causes['directory-unreadable'] = $true
            continue
        }
        foreach ($entry in $entries) {
            if ($scanned -ge $MaxEntries) { $limitReached = $true; break }
            $scanned++
            $isLink = Test-IsReparsePoint $entry

            if (-not $entry.PSIsContainer) {
                $kind = ''
                foreach ($pattern in $script:TaskCreatedOnlyFilePatterns) {
                    if ($entry.Name -like $pattern) { $kind = 'task-created-file'; break }
                }
                if ($kind -eq '') {
                    foreach ($pattern in $script:ReviewOnlyFilePatterns) {
                        if ($entry.Name -like $pattern) { $kind = 'review-file'; break }
                    }
                }
                if ($kind -eq '') { continue }
                [void]$found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $false; Kind = $kind; IsLink = $isLink })
                continue
            }

            # Hard prune first: never surfaced, never descended, whatever config says.
            if ($pruneSet.Contains($entry.Name)) { continue }
            # Same standing as a hard prune, and checked before classification so
            # that a marker-bearing directory can never be OFFERED for deletion
            # either. Recognized by a MARKER FILE it contains rather than by
            # name, because the names above are only the conventional spellings:
            #
            #   pyvenv.cfg     any virtualenv, whatever the folder is called
            #                  ('spotdl-env' is as legal as 'venv')
            #   CACHEDIR.TAG   any tool's regenerable cache
            #
            # The marker list itself lives in _hooklib.ps1 beside this file
            # ($script:PruneMarkerFiles) - named here too so that grepping THIS
            # file for 'pyvenv' or 'CACHEDIR.TAG' finds the behaviour instead of
            # reporting it missing.
            if (Test-IsMarkerPrunedDirectory $entry.FullName) { continue }
            $kind = ''
            if ($taskCreatedSet.Contains($entry.Name)) { $kind = 'task-created-dir' }
            elseif ($candidateSet.Contains($entry.Name)) { $kind = 'cache-dir' }
            elseif ($reviewSet.Contains($entry.Name)) { $kind = 'review-dir' }
            if ($kind -ne '') {
                # Recognized directories are LEAF classifications - reported, never descended.
                [void]$found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $true; Kind = $kind; IsLink = $isLink })
                continue
            }
            if ($isLink) { continue }
            if ($current.Depth -ge $MaxDepth) { $causes['max-scan-depth-reached'] = $true; continue }
            $stack.Push([pscustomobject]@{ Path = $entry.FullName; Depth = $current.Depth + 1 })
        }
    }
    if ($limitReached -or $stack.Count -gt 0) { $causes['max-scan-entries-reached'] = $true }

    return [pscustomobject]@{
        Candidates    = $found.ToArray()
        Complete      = ($causes.Count -eq 0)
        PartialCauses = @($causes.Keys | Sort-Object)
    }
}

# Bounded size probe. Ok=$false means the metadata is genuinely unreadable (a
# named partial cause). Bounded=$true means the value is a LOWER BOUND (">=N"),
# never a size - it is reported as '>=N', stored beside sizeBounded=true, and it
# must never be allowed to satisfy a comparison that an exact value would.
function Get-CandidateSize {
    param([Parameter(Mandatory = $true)][string]$Path, [bool]$IsDir, [bool]$IsLink)
    # A reparse point is never traversed, so its contents are simply not known.
    if ($IsLink) { return [pscustomobject]@{ Bytes = -1; Bounded = $false; Ok = $true } }
    try {
        if (-not $IsDir) {
            return [pscustomobject]@{ Bytes = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length; Bounded = $false; Ok = $true }
        }
        $sum = 0L
        $examined = 0
        # Two distinct facts, deliberately not one flag: $bounded says the
        # RESULT is only a lower bound, $ceilingHit says a hard ceiling stopped
        # the walk outright. Depth sets the first without the second, so one
        # over-deep branch marks the total as a lower bound instead of
        # abandoning the measurement of every shallower sibling.
        $bounded = $false
        $ceilingHit = $false
        $ok = $true
        # A Stopwatch, NOT [DateTime]::UtcNow: the wall clock is not monotonic,
        # so an NTP correction or a manual clock change landing between the two
        # reads could collapse this budget to nothing or extend it arbitrarily.
        # Stopwatch measures elapsed time from a tick source that cannot step.
        $budgetSeconds = Get-SizeWalkSecondsBudget
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        # An explicit non-following stack walk, the same bounded traversal shape
        # Get-CleanupScan uses - including its depth counter, which this walk
        # previously lacked. [System.IO.Directory]::EnumerateFiles(...,
        # AllDirectories) was used here, and it FOLLOWS junctions/symlinks: the
        # size probe could descend through a link and measure a tree outside the
        # project, which is precisely what this hook promises never to do, and a
        # link loop had no reliable bound because the old ceiling counted files
        # only. Skipping reparse points makes the walk a finite tree; the entry,
        # time and depth ceilings bound a pathological real tree on top of that.
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push([pscustomobject]@{ Path = $Path; Depth = 0 })
        while ($stack.Count -gt 0) {
            if ($ceilingHit) { break }
            $current = $stack.Pop()
            try {
                # Lazy enumeration so the walk stops at the ceiling instead of
                # materialising an arbitrarily large directory first.
                foreach ($child in [System.IO.Directory]::EnumerateFileSystemEntries($current.Path)) {
                    if ($examined -ge $script:SizeWalkMaxEntries -or $timer.Elapsed.TotalSeconds -ge $budgetSeconds) {
                        $bounded = $true
                        $ceilingHit = $true
                        break
                    }
                    # Counted before the attribute read, so entries that are
                    # skipped or unreadable still consume the ceiling - a
                    # directory full of junctions cannot spin here.
                    $examined++
                    $attributes = [System.IO.FileAttributes]::Normal
                    try { $attributes = [System.IO.File]::GetAttributes($child) } catch { $ok = $false; continue }
                    # Never followed and never measured, exactly as in the
                    # candidate scan: a link's contents are simply not known.
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                        # Depth is a COVERAGE limit, not a stop condition: the
                        # subtree below it goes unmeasured, which makes the
                        # total a lower bound, but the rest of the tree is
                        # still worth measuring honestly.
                        if ($current.Depth -ge $script:SizeWalkMaxDepth) { $bounded = $true; continue }
                        $stack.Push([pscustomobject]@{ Path = $child; Depth = $current.Depth + 1 })
                        continue
                    }
                    try { $sum += (New-Object System.IO.FileInfo $child).Length } catch { $ok = $false }
                }
            }
            catch { $ok = $false }
        }
        return [pscustomobject]@{ Bytes = $sum; Bounded = $bounded; Ok = $ok }
    }
    catch { return [pscustomobject]@{ Bytes = -1; Bounded = $false; Ok = $false } }
}

