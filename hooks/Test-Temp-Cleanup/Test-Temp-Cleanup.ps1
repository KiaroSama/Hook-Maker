# TestTempCleanup - keeps a project free of disposable test cache/temp residue
# without ever touching tracked, staged, ambiguous, or hard-protected state.
#
# SessionStart: records a bounded, metadata-only baseline of recognized cache/
# temp candidates already present (relative path, category, size, mtime, git
# state) for THIS session - never file contents, never secret values.
#
# Stop: rescans the same bounded set, classifies each candidate, deletes only
# HIGH-CONFIDENCE safe candidates (well-known disposable caches that are not
# tracked/staged, not reparse points, and contained inside the project root),
# verifies every deletion with a rescan, and reports accurately. Diagnostic/
# review artifacts (coverage, test-results, screenshots, ...) are preserved by
# default - never auto-deleted unless DELETE_REVIEW_ARTIFACTS=true. Also
# writes a small coordination state (fingerprint + result category) so
# Cloudflare-Deploy can confirm disposable residue was handled before it shows
# a deployment decision - lifecycle hooks on the same event may run
# concurrently, so this is a state handoff, never an execution-order promise.
#
# Hard safety boundary (never overridable by config):
# - never leaves the canonical project root; never follows symlinks/junctions/
#   reparse points; never deletes tracked or staged paths (git ls-files);
#   never runs git clean/reset or touches the index; never deletes .git, .ai,
#   .claude, .codex, or well-known dependency/build/cache ROOTS (node_modules,
#   venv, target, dist, build, out, ...) merely by name; never prints file
#   contents or secret values; never claims success before a post-delete
#   rescan confirms removal.
#
# Optional .env next to this script (copy .env.example):
#   AUTO_DELETE_SAFE               master switch for auto-deleting safe candidates (default true)
#   DELETE_REVIEW_ARTIFACTS        allow deleting review-only artifacts too (default false)
#   DELETE_PREEXISTING_SAFE_CACHES delete safe caches that predate this session, not only new ones (default true)
#   EXTRA_SAFE_PATTERNS             extra literal directory/file leaf names, safe category (semicolon separated)
#   EXTRA_REVIEW_PATTERNS           extra literal directory/file leaf names, review-only category (semicolon separated)
#   MAX_DELETE_PATHS               stop deleting after this many paths (default 200)
#   MAX_DELETE_BYTES               stop deleting after this many cumulative bytes (default 524288000)
#   MAX_FINDINGS                   cap how many relative paths are listed in the report (default 20)
#   ENABLE_SUBAGENT_STOP           also run cleanup on SubagentStop (default false)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

# ---- always-explicit category tables (never grown by guessing/heuristics) ----
# Named directories that are safe to delete once confirmed untracked, whether
# they predate this session or not (gated by DELETE_PREEXISTING_SAFE_CACHES).
$script:AlwaysSafeCacheNames = @(
    '.pytest_cache', '.mypy_cache', '.ruff_cache', '.hypothesis', '.nyc_output',
    '.test-tmp', '.test-temp', 'test-tmp', 'test-temp', '.jest-cache', '.vitest-cache'
)
# Must be genuinely created/modified DURING this session (never pre-existing),
# regardless of DELETE_PREEXISTING_SAFE_CACHES - matches the spec's explicit
# "task-created" qualifier for these two.
$script:TaskCreatedOnlyNames = @('__pycache__')
$script:TaskCreatedOnlyFilePatterns = @('*.pyc', '*.pyo')
# Diagnostic/review artifacts: detected and reported, never auto-deleted unless
# DELETE_REVIEW_ARTIFACTS=true (an explicit, project-wide opt-in).
$script:ReviewOnlyNames = @('coverage', 'htmlcov', 'test-results', 'playwright-report', 'blob-report', 'TestResults')
$script:ReviewOnlyFilePatterns = @('.coverage', 'coverage.xml')
# Never descended into or treated as a candidate, regardless of any config -
# dependency stores, build/compiler output roots, and this tool's own
# protected directories. Config cannot add to or override this list.
$script:HardPruneNames = @(
    '.git', '.ai', '.claude', '.codex', 'node_modules', '.venv', 'venv', 'env',
    '__pypackages__', 'vendor', 'target', 'dist', 'build', 'out', '.next',
    '.nuxt', '.tox', '.svn', '.hg', 'graphify-out', 'logs'
)
$script:MaxScanEntries = 5000
$script:MaxScanDepth = 8

function Test-SafePatternToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    $t = $Token.Trim()
    if ($t -match '[\\/]' -or $t -match '\.\.' -or $t -match '^[A-Za-z]:' -or $t.StartsWith('\\') -or $t -match '[%$]') { return $false }
    return $true
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Bounded, non-following scan for recognized cache/temp/review candidates.
# Candidate directories are LEAF classifications (never descended into further).
function Get-CleanupCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExtraSafeNames = @(),
        [string[]]$ExtraReviewNames = @()
    )
    $safeSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in ($script:AlwaysSafeCacheNames + $ExtraSafeNames)) { [void]$safeSet.Add($n) }
    $taskCreatedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $script:TaskCreatedOnlyNames) { [void]$taskCreatedSet.Add($n) }
    $reviewSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in ($script:ReviewOnlyNames + $ExtraReviewNames)) { [void]$reviewSet.Add($n) }
    $pruneSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $script:HardPruneNames) { [void]$pruneSet.Add($n) }

    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $Root; Depth = 0 })
    $scanned = 0

    while ($stack.Count -gt 0 -and $scanned -lt $script:MaxScanEntries) {
        $current = $stack.Pop()
        $entries = $null
        try { $entries = Get-ChildItem -LiteralPath $current.Path -Force -ErrorAction Stop } catch { continue }
        foreach ($entry in $entries) {
            if ($scanned -ge $script:MaxScanEntries) { break }
            $scanned++
            if (-not $entry.PSIsContainer) {
                if (Test-IsReparsePoint $entry) { continue }
                foreach ($pattern in $script:TaskCreatedOnlyFilePatterns) {
                    if ($entry.Name -like $pattern) {
                        $found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $false; Category = 'task-created' })
                        break
                    }
                }
                foreach ($pattern in $script:ReviewOnlyFilePatterns) {
                    if ($entry.Name -like $pattern) {
                        $found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $false; Category = 'review' })
                        break
                    }
                }
                continue
            }
            if (Test-IsReparsePoint $entry) { continue }
            if ($pruneSet.Contains($entry.Name)) { continue }
            if ($taskCreatedSet.Contains($entry.Name)) {
                $found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $true; Category = 'task-created' })
                continue
            }
            if ($safeSet.Contains($entry.Name)) {
                $found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $true; Category = 'safe' })
                continue
            }
            if ($reviewSet.Contains($entry.Name)) {
                $found.Add([pscustomobject]@{ Path = $entry.FullName; Name = $entry.Name; IsDir = $true; Category = 'review' })
                continue
            }
            if ($current.Depth -lt $script:MaxScanDepth) {
                $stack.Push([pscustomobject]@{ Path = $entry.FullName; Depth = $current.Depth + 1 })
            }
        }
    }
    return $found
}

function Get-RecursiveSizeBytes {
    param([string]$Path, [bool]$IsDir)
    try {
        if (-not $IsDir) { return (Get-Item -LiteralPath $Path -Force).Length }
        $sum = 0L
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $sum += $_.Length }
        return $sum
    }
    catch { return 0L }
}

# Empty result = not inside a git repo (or git unavailable): the caller must
# then treat every candidate's git state as unknown/ambiguous.
function Test-GitTrackedOrStaged {
    param([string]$Root, [string]$RelPath, [bool]$GitAvailable)
    if (-not $GitAvailable) { return $null }
    $tracked = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'ls-files', '--', $RelPath)) | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($tracked.Count -gt 0)
}

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$projectRoot = Normalize-Path $cwd
$sessionId = [string](Get-Field $hookInput 'session_id')
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
function Get-BoolConfig { param([string]$Key, [bool]$Default) if ($config.ContainsKey($Key)) { return ($config[$Key] -eq 'true') }; return $Default }
function Get-IntConfig { param([string]$Key, [int]$Default) if ($config.ContainsKey($Key)) { $parsed = 0; if ([int]::TryParse($config[$Key], [ref]$parsed)) { return $parsed } }; return $Default }

$autoDeleteSafe = Get-BoolConfig 'AUTO_DELETE_SAFE' $true
$deleteReviewArtifacts = Get-BoolConfig 'DELETE_REVIEW_ARTIFACTS' $false
$deletePreexisting = Get-BoolConfig 'DELETE_PREEXISTING_SAFE_CACHES' $true
$maxDeletePaths = Get-IntConfig 'MAX_DELETE_PATHS' 200
$maxDeleteBytes = Get-IntConfig 'MAX_DELETE_BYTES' 524288000
$maxFindings = Get-IntConfig 'MAX_FINDINGS' 20
$enableSubagentStop = Get-BoolConfig 'ENABLE_SUBAGENT_STOP' $false
$extraSafe = @()
if ($config.ContainsKey('EXTRA_SAFE_PATTERNS')) { $extraSafe = @($config['EXTRA_SAFE_PATTERNS'].Split(';') | Where-Object { Test-SafePatternToken $_ }) }
$extraReview = @()
if ($config.ContainsKey('EXTRA_REVIEW_PATTERNS')) { $extraReview = @($config['EXTRA_REVIEW_PATTERNS'].Split(';') | Where-Object { Test-SafePatternToken $_ }) }

if ($eventName -ne 'SessionStart' -and $eventName -ne 'Stop' -and -not ($eventName -eq 'SubagentStop' -and $enableSubagentStop)) {
    exit 0
}

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash $projectRoot.ToLowerInvariant()
$baselinePath = Join-Path $stateDir ('TestTempCleanup-baseline-' + $projectKey + '.json')
$failurePath = Join-Path $stateDir ('TestTempCleanup-failure-' + $projectKey + '.txt')
$resultPath = Join-Path $stateDir ('TestTempCleanup-result-' + $projectKey + '.json')

# ==========================================================================
# SessionStart: metadata-only baseline, always silent.
# ==========================================================================
if ($eventName -eq 'SessionStart') {
    $gitAvailable = ($null -ne (Get-Command git -ErrorAction SilentlyContinue))
    if ($gitAvailable) {
        $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $projectRoot, 'rev-parse', '--is-inside-work-tree')
        $gitAvailable = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
    }
    # @(...) forces array semantics regardless of host - a function returning a
    # single-element List[object] via `return` can otherwise collapse to a bare
    # scalar under StrictMode, which has no .Count property (observed on 5.1).
    $candidates = @(Get-CleanupCandidates -Root $projectRoot -ExtraSafeNames $extraSafe -ExtraReviewNames $extraReview)
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidates) {
        $relPath = $c.Path.Substring($projectRoot.Length).TrimStart('\', '/')
        $trackedOrStaged = Test-GitTrackedOrStaged -Root $projectRoot -RelPath $relPath -GitAvailable $gitAvailable
        $gitState = if ($null -eq $trackedOrStaged) { 'unknown' } elseif ($trackedOrStaged) { 'tracked' } else { 'untracked-or-ignored' }
        $modifiedUtc = try { (Get-Item -LiteralPath $c.Path -Force).LastWriteTimeUtc.ToString('o') } catch { '' }
        [void]$records.Add([ordered]@{
            relPath = $relPath; category = $c.Category; isDir = $c.IsDir
            sizeBytes = (Get-RecursiveSizeBytes -Path $c.Path -IsDir $c.IsDir)
            modifiedUtc = $modifiedUtc; gitState = $gitState
        })
    }
    $baseline = [ordered]@{
        sessionId = $sessionId
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        candidates = $records
    }
    Write-JsonFileAtomic -Value $baseline -Path $baselinePath
    exit 0
}

# ==========================================================================
# Stop / SubagentStop: classify, delete safe candidates, verify, report.
# ==========================================================================
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }

$gitAvailable = ($null -ne (Get-Command git -ErrorAction SilentlyContinue))
if ($gitAvailable) {
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $projectRoot, 'rev-parse', '--is-inside-work-tree')
    $gitAvailable = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}

$baseline = Read-JsonFile -Path $baselinePath
$baselineAvailable = ($null -ne $baseline) -and ([string](Get-Field $baseline 'sessionId') -eq $sessionId) -and ($sessionId -ne '')
$baselineRelPaths = @{}
if ($baselineAvailable) {
    foreach ($rec in @(Get-Field $baseline 'candidates')) {
        $baselineRelPaths[[string](Get-Field $rec 'relPath')] = $true
    }
}

$candidates = @(Get-CleanupCandidates -Root $projectRoot -ExtraSafeNames $extraSafe -ExtraReviewNames $extraReview)
if ($candidates.Count -eq 0) {
    $record = [ordered]@{ sessionId = $sessionId; fingerprint = (Get-RepoStateFingerprint -ProjectRoot $projectRoot); category = 'clean'; timestampUtc = [DateTime]::UtcNow.ToString('o') }
    Write-JsonFileAtomic -Value $record -Path $resultPath
    exit 0
}

$deleted = New-Object System.Collections.Generic.List[string]
$preserved = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[string]
$limitHit = $false
$deletedPathCount = 0
$deletedByteCount = 0L

foreach ($c in $candidates) {
    if (-not (Test-PathInside -Candidate $c.Path -Parent $projectRoot)) { continue }
    $relPath = $c.Path.Substring($projectRoot.Length).TrimStart('\', '/')

    if (-not $baselineAvailable) {
        # Missing-baseline fallback: auto-delete only the smallest explicit
        # set of always-disposable framework caches; preserve everything else
        # and never claim a broader cleanup was verified.
        $alwaysDisposableNoBaseline = @('.pytest_cache', '.mypy_cache', '.ruff_cache', '.hypothesis', '.nyc_output')
        if ($autoDeleteSafe -and $c.Category -eq 'safe' -and $alwaysDisposableNoBaseline -contains $c.Name) {
            $trackedOrStaged = Test-GitTrackedOrStaged -Root $projectRoot -RelPath $relPath -GitAvailable $gitAvailable
            if ($trackedOrStaged -eq $false) {
                # falls through to the shared delete block below
            }
            else { $preserved.Add($relPath); continue }
        }
        else { $preserved.Add($relPath); continue }
    }

    $trackedOrStaged = Test-GitTrackedOrStaged -Root $projectRoot -RelPath $relPath -GitAvailable $gitAvailable
    if ($trackedOrStaged -ne $false) {
        # tracked, staged, or unknown (no git) - never a deletion candidate.
        if ($c.Category -ne 'task-created' -and $c.Category -ne 'safe') { $preserved.Add($relPath) }
        continue
    }

    $eligible = $false
    if ($c.Category -eq 'task-created') {
        $isNewThisSession = -not $baselineRelPaths.ContainsKey($relPath)
        $eligible = $autoDeleteSafe -and $isNewThisSession
    }
    elseif ($c.Category -eq 'safe') {
        $isPreexisting = $baselineRelPaths.ContainsKey($relPath)
        $eligible = $autoDeleteSafe -and (-not $isPreexisting -or $deletePreexisting)
    }
    elseif ($c.Category -eq 'review') {
        $eligible = $deleteReviewArtifacts
    }

    if (-not $eligible) {
        $preserved.Add($relPath)
        continue
    }

    $sizeBytes = Get-RecursiveSizeBytes -Path $c.Path -IsDir $c.IsDir
    if (($deletedPathCount + 1) -gt $maxDeletePaths -or ($deletedByteCount + $sizeBytes) -gt $maxDeleteBytes) {
        $limitHit = $true
        $preserved.Add($relPath)
        continue
    }

    try {
        if ($c.IsDir) { Remove-Item -LiteralPath $c.Path -Recurse -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $c.Path -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $c.Path) {
            # Rescan says it is still there - do not claim success.
            $failed.Add($relPath)
        }
        else {
            $deleted.Add($relPath)
            $deletedPathCount++
            $deletedByteCount += $sizeBytes
        }
    }
    catch {
        $failed.Add($relPath)
    }
}

# ---- failure fingerprint gate: block once per distinct fingerprint/session ----
if ($failed.Count -gt 0) {
    $failureFingerprint = Get-ShortHash (($sessionId + '|' + (($failed | Sort-Object) -join ',')))
    $alreadyReported = $false
    if (Test-Path -LiteralPath $failurePath -PathType Leaf) {
        try { $alreadyReported = ([System.IO.File]::ReadAllText($failurePath).Trim() -eq $failureFingerprint) } catch { }
    }
    $record = [ordered]@{ sessionId = $sessionId; fingerprint = (Get-RepoStateFingerprint -ProjectRoot $projectRoot); category = 'failed'; timestampUtc = [DateTime]::UtcNow.ToString('o') }
    Write-JsonFileAtomic -Value $record -Path $resultPath
    if ($alreadyReported) { exit 0 }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($failurePath, $failureFingerprint)
    $reason = 'TEST TEMP CLEANUP: could not remove ' + $failed.Count + ' safe candidate path(s): ' + (($failed | Select-Object -First $maxFindings) -join ', ') + '. Likely locked or permission-denied. Close the process holding it (or remove it manually) and retry; tracked/user data was not touched.'
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}

$category = if ($limitHit) { 'incomplete-limit' } elseif ($deleted.Count -gt 0) { 'safe-cleaned' } elseif ($preserved.Count -gt 0) { 'review-only-preserved' } else { 'clean' }
$record = [ordered]@{ sessionId = $sessionId; fingerprint = (Get-RepoStateFingerprint -ProjectRoot $projectRoot); category = $category; timestampUtc = [DateTime]::UtcNow.ToString('o') }
Write-JsonFileAtomic -Value $record -Path $resultPath

$lines = New-Object System.Collections.Generic.List[string]
if ($deleted.Count -gt 0) {
    [void]$lines.Add('TEST TEMP CLEANUP: removed safe project-local test cache/temp residue (' + $deleted.Count + ' path(s), verified by rescan). No tracked or diagnostic artifacts were touched.')
}
if ($limitHit) {
    [void]$lines.Add('TEST TEMP CLEANUP: a configured limit (MAX_DELETE_PATHS/MAX_DELETE_BYTES) was reached - cleanup is INCOMPLETE, remaining safe candidates were left in place.')
}
if ($preserved.Count -gt 0 -and -not $baselineAvailable) {
    [void]$lines.Add('TEST TEMP CLEANUP: no matching session baseline - only the smallest always-disposable caches were auto-removed; the rest is preserved and NOT fully verified: ' + (($preserved | Select-Object -First $maxFindings) -join ', '))
}
elseif ($preserved.Count -gt 0) {
    [void]$lines.Add('TEST TEMP CLEANUP: preserved (review-only or not eligible) - ' + (($preserved | Select-Object -First $maxFindings) -join ', '))
}
if ($lines.Count -eq 0) { exit 0 }
$message = $lines.ToArray() -join "`n"

# Client-aware non-blocking shape (never decision:block for a success/review
# report): Claude Code -> hookSpecificOutput.additionalContext (documented
# model-visible on Stop); Codex -> systemMessage (its only documented common
# Stop field). Same signal as the rest of this project: CLAUDE_PROJECT_DIR
# present -> Claude, absent -> Codex.
if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) {
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } | ConvertTo-Json -Depth 5 -Compress
}
else {
    @{ systemMessage = $message } | ConvertTo-Json -Compress
}
exit 0
