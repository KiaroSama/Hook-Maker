# TestTempCleanup - a DETECTOR + ADVISOR + COMPLETION GATE for disposable test
# cache/temp residue. It has NO deletion feature and no mutation authority over
# project content at all.
#
# ABSOLUTE MUTATION PROHIBITION. This hook never deletes, moves, renames,
# truncates, normalizes, stages, unstages, or otherwise mutates ANY project
# file or directory - not with a flag, not with a config key, not as a
# "verified safe" special case. There is no setting that can turn deletion on,
# because the feature does not exist. The ONLY thing it writes is bounded
# metadata (fingerprints, classifications, relative paths, sizes, timestamps)
# into Hook Maker's own private state directory under
# %LOCALAPPDATA%\HookMaker\state, and every one of those writes goes through
# Write-JsonFileAtomic with a $stateDir-derived path variable. It never records
# candidate file contents, secret values, raw prompts, tool inputs, or raw logs.
# The AGENT performs any deletion, with normal agent tools, after independently
# confirming each candidate.
#
# Concretely, the executable body contains no reachable Remove-Item, Move-Item,
# Rename-Item, Set-Content, Add-Content or Out-File, and never runs git clean,
# git reset, git rm, git add, git restore or git checkout. Those names appear in
# THIS COMMENT deliberately: the guard in scripts\Test-TestTempCleanup.ps1
# asserts on the parsed AST, not on the file's text, so documenting the
# prohibition can never be mistaken for violating it - and if that guard is ever
# rewritten as a text grep, this paragraph makes it fail loudly instead of
# silently weakening.
#
# SessionStart: bounded, metadata-only baseline of recognized candidates
# (relative path, kind, link state, size, mtime, git state) PLUS the scan's
# completeness and its exact partial causes. Silent unless the scan itself was
# partial - a partial baseline means later cleanliness checks cannot be
# complete, and that has to be said once rather than hidden.
#
# Stop / SubagentStop: rescans under the same bounded rules, compares against
# this session's baseline when one exists, classifies every candidate, and
# emits a concise instruction. A candidate it already surfaced as
# likely-disposable on an EARLIER Stop of this session and that is STILL
# present is reported as residue-confirmed - that is evidence the instruction
# was not resolved, NOT a claim that this hook confirmed the path is safe to
# delete. Unresolved residue and partial coverage gate completion (once per
# distinct evidence fingerprint, so unchanged evidence never loops while
# materially changed evidence re-surfaces immediately).
#
# Hard protections, none of them overridable by config: the hard-prune set is
# never surfaced and never descended into; symlinks/junctions/reparse points
# are never followed and are classified protected; nothing outside the
# canonical project root is surfaced; tracked and staged paths are protected;
# diagnostic/review artifacts, user-created folders of uncertain purpose, and
# anything with incomplete metadata or unknown git state are never described as
# disposable. EXTRA_CANDIDATE_NAMES / EXTRA_REVIEW_NAMES are DETECTION HINTS
# ONLY: config can add something to look at, never mark something safe to
# delete and never weaken a protection.
#
# Optional .env next to this script (copy .env.example):
#   MAX_SCAN_ENTRIES       filesystem entries the scan may examine (default 15000)
#   MAX_SCAN_DEPTH         directory depth the scan may descend (default 12)
#   MAX_FINDINGS           how many candidate lines the report may list (default 20)
#   ENABLE_SUBAGENT_STOP   also evaluate on SubagentStop (default false)
#   EXTRA_CANDIDATE_NAMES  extra literal leaf names to DETECT (semicolon separated)
#   EXTRA_REVIEW_NAMES     extra literal leaf names to detect as review-only (semicolon separated)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

# ---- SHARED RESULT-CATEGORY CONTRACT -------------------------------------
# These five strings are the whole vocabulary of the { fingerprint, category }
# handoff this hook writes to TestTempCleanup-result-<projectKey>.json.
# THE OTHER SIDE OF THIS CONTRACT IS hooks\Cloudflare-Deploy\Cloudflare-Deploy.ps1
# ($script:CleanupCategories / $script:CleanupReleaseReadyCategories). Only
# 'clean' is release-ready there; every other value keeps that hook silent.
# Change this list and you MUST change that one in the same commit - a past
# round shipped a dead gate because two components drifted on exactly this kind
# of shared state contract.
#   clean             complete bounded scan; no recognized candidate requiring review
#   review-required   candidates exist; the agent has not yet remediated them
#   residue-confirmed a candidate surfaced on an earlier Stop is still present
#   partial           coverage bounds / read failures prevented a complete decision
#   unknown           missing baseline or unknown git evidence prevents classification
$script:ResultCategories = @('clean', 'review-required', 'residue-confirmed', 'partial', 'unknown')

# ---- classification vocabulary (exactly one per surfaced candidate) -------
# 'likely-disposable' is a DESCRIPTION, never deletion approval.
$script:Classifications = @(
    'likely-disposable', 'review-or-diagnostic', 'protected',
    'ambiguous', 'unknown-git-state', 'partial-or-unreadable'
)
# A 'protected' candidate needs no remediation (it must simply be left alone),
# so it alone does not make a project 'review-required'.
$script:ReviewRequiringClassifications = @(
    'likely-disposable', 'review-or-diagnostic', 'ambiguous'
)

# ---- named partial causes -------------------------------------------------
# COVERAGE causes mean the scan did not see everything it needed to -> 'partial'.
# EVIDENCE causes mean it saw the paths but cannot classify them -> 'unknown'.
# Both are recorded verbatim in the report and in state; neither may ever be
# reported as 'clean'.
$script:CoverageCauses = @(
    'max-scan-entries-reached',        # MAX_SCAN_ENTRIES ceiling stopped the walk
    'max-scan-depth-reached',          # MAX_SCAN_DEPTH prevented required coverage
    'directory-unreadable',            # a directory could not be enumerated
    'candidate-metadata-unreadable',   # a candidate's size/mtime could not be read
    'classification-incomplete',       # a required classification could not finish
    'extra-names-unsupported'          # a configured extra name exceeded the shared handoff bounds
)
$script:EvidenceCauses = @(
    'git-state-unknown',               # git status unknown for at least one candidate
    'baseline-missing',                # no SessionStart baseline exists for this project
    'baseline-session-mismatch'        # the baseline belongs to a different session
)

# ---- candidate discovery: detection tables + the bounded scan ------------
# Lives in _discovery.ps1 beside this script (split at the 800-line ceiling),
# dot-sourced HERE so its tables are built in this scope before anything below
# reads them.
. (Join-Path $PSScriptRoot '_discovery.ps1')

# One text form for a baseline timestamp, whichever shape ConvertFrom-Json hands
# back. That decode is HOST-DIVERGENT and it silently broke the session-delta
# comparison on one of the two supported hosts: Windows PowerShell 5.1 returns
# the ISO-8601 text as a [string], pwsh 7 coerces it to a [DateTime] - and
# [string] on a DateTime yields the CURRENT CULTURE's short form
# ('07/26/2026 03:15:22'), which can never equal the round-trip 'o' text the live
# side produces. So on pwsh 7 every pre-existing candidate compared unequal and
# was reported during-session=modified whether or not anything had changed, while
# 5.1 reported it correctly. Normalizing both shapes here is what makes the two
# hosts agree - and what makes the bounded-size rule below reachable at all.
function Format-BaselineTimestamp {
    param($Value)
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime().ToString('o') }
    return [string]$Value
}

# tracked | staged | untracked | ignored | unknown. 'unknown' is returned
# whenever git is unavailable, the path is outside a work tree, or any probe
# fails - it is never silently downgraded to 'untracked'.
function Get-GitCandidateState {
    param([string]$Root, [string]$RelPath, [bool]$GitAvailable)
    if (-not $GitAvailable) { return 'unknown' }
    $gitRel = $RelPath.Replace('\', '/')
    if ($gitRel -eq '') { return 'unknown' }
    $cached = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'ls-files', '--cached', '--', $gitRel)) | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    if ($cached.Count -gt 0) {
        $staged = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'diff', '--cached', '--name-only', '--', $gitRel)) | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { return 'unknown' }
        if ($staged.Count -gt 0) { return 'staged' }
        return 'tracked'
    }
    # check-ignore: 0 = ignored, 1 = not ignored, anything else = do not guess.
    $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'check-ignore', '--quiet', '--', $gitRel)
    if ($LASTEXITCODE -eq 0) { return 'ignored' }
    if ($LASTEXITCODE -eq 1) { return 'untracked' }
    return 'unknown'
}

function Test-GitWorkTree {
    param([string]$Root)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--is-inside-work-tree')
    return ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}

function Get-CandidateTypeLabel {
    param([string]$Kind)
    switch ($Kind) {
        'cache-dir' { return 'test-cache-dir' }
        'task-created-dir' { return 'task-created-cache-dir' }
        'review-dir' { return 'review-artifact-dir' }
        'task-created-file' { return 'task-created-bytecode-file' }
        'review-file' { return 'review-artifact-file' }
        default { return 'unrecognized' }
    }
}

function Get-MatchReason {
    param([string]$Kind)
    switch ($Kind) {
        'cache-dir' { return 'recognized disposable test cache/temp directory name' }
        'task-created-dir' { return 'recognized task-created bytecode cache directory name' }
        'review-dir' { return 'recognized diagnostic/review artifact directory name' }
        'task-created-file' { return 'recognized compiled-bytecode file pattern' }
        'review-file' { return 'recognized coverage/report file pattern' }
        default { return 'unrecognized' }
    }
}

function Get-ReviewReason {
    param([string]$Classification)
    switch ($Classification) {
        'likely-disposable' { return 'confirm independently that it is disposable, then delete it yourself' }
        'review-or-diagnostic' { return 'diagnostic/review artifact - keep unless you have confirmed it is no longer needed' }
        'protected' { return 'protected (tracked, staged, or a link) - do not delete' }
        'ambiguous' { return 'origin or purpose is not established - leave intact and report it' }
        'unknown-git-state' { return 'git state could not be determined - leave intact and report it' }
        'partial-or-unreadable' { return 'metadata could not be read - leave intact and report it' }
        default { return 'leave intact and report it' }
    }
}

# The instruction is built ONCE, client-independently, so every client adapter
# carries the same semantics.
function Get-AgentInstructionLines {
    return @(
        'Inspect every candidate before deletion.',
        'Do not rely on the directory name alone.',
        'Never delete tracked, staged, linked, diagnostic, ambiguous, protected, or user-owned data.',
        'Delete only project-local residue that you have independently confirmed is disposable.',
        'Use normal agent tools; this hook performs no deletion.',
        'Leave uncertain candidates intact and report them.'
    )
}

# Client adapter. The message text and the blocking decision are already final;
# this only chooses the envelope, and it delegates that choice to the shared
# Write-HookResult so a third client is shaped in ONE place instead of here.
# A blocking gate stays { decision: 'block' } for the clients that document a
# Stop gate; a client that documents none has it downgraded to the strongest
# available advisory and reported as degraded, never emitted as a fake gate.
# This hook remains ADVISORY-ONLY with respect to the filesystem either way: it
# still deletes nothing, and no classification/category decision moves here.
# Write-HookResult never exits, so a real block exit code is propagated - both
# call sites are followed by `exit 0`, which would otherwise swallow it.
function Write-ClientMessage {
    param([string]$Message, [string]$EventName, [bool]$Blocking)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $kind = 'advisory'
    if ($Blocking) { $kind = 'block' }
    # A block must be ADMITTED before it is emitted, so the shared correction
    # allowance cannot be overspent; a refusal emits nothing and the finding
    # stays recorded as unresolved. An advisory claims nothing - it never
    # stopped anything - so it goes straight out.
    if ($kind -eq 'block') {
        $emit = Write-StopBlockResult -HookInput $script:hookInput -HookName 'Test-Temp-Cleanup' -EventName $EventName -Reason $Message
        if ($emit.ExitCode -ne 0) { exit $emit.ExitCode }
        return
    }
    $emit = Write-HookResult -EventName $EventName -Kind $kind -Message $Message -Reason $Message
    if ($emit.ExitCode -ne 0) { exit $emit.ExitCode }
}

# ==========================================================================
# input + config
# ==========================================================================
$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$projectRoot = Normalize-Path $cwd
$sessionId = [string](Get-Field $hookInput 'session_id')

# The handoff document is its own responsibility, and this file is past the
# size ceiling. The installer stages a hook's whole folder, so it ships here.
. (Join-Path $PSScriptRoot '_cleanuprecord.ps1')
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
function Get-BoolConfig { param([string]$Key, [bool]$Default) if ($config.ContainsKey($Key)) { return ($config[$Key] -eq 'true') }; return $Default }
function Get-IntConfig {
    param([string]$Key, [int]$Default, [int]$Min, [int]$Max)
    if ($config.ContainsKey($Key)) {
        $parsed = 0
        if ([int]::TryParse($config[$Key], [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) { return $parsed }
    }
    return $Default
}

# Raised from 5000/8 after measuring 14 real project trees: twelve of them
# never exceed depth 4, so a deeper ceiling costs them literally nothing -
# the walk simply never descends that far. The two that DO go deeper reach
# depth 10 through ordinary vendored content (an Android SDK's
# build-tools/.../renderscript/lib/bc/<abi>), and one of them also passed
# 5000 entries, so both reported PARTIAL for structure that is genuinely
# theirs. A PARTIAL nobody can act on trains readers to ignore the signal.
# The entry ceiling is what actually bounds the work; depth is a secondary
# guard, which is why raising it is the cheaper half of this change.
$maxScanEntries = Get-IntConfig 'MAX_SCAN_ENTRIES' 15000 1 1000000
$maxScanDepth = Get-IntConfig 'MAX_SCAN_DEPTH' 12 1 64
$maxFindings = Get-IntConfig 'MAX_FINDINGS' 20 1 1000
$enableSubagentStop = Get-BoolConfig 'ENABLE_SUBAGENT_STOP' $false
# A configured name this hook cannot hand over intact is REJECTED rather than
# quietly scanned: Test-CandidateNameToken enforces the shared length, and the
# shared count is applied here. $script:ExtraNamesTruncated records that it
# happened, so a scan run under a configuration the handoff could not carry is
# never reported as complete coverage - the caller learns the configuration is
# unsupported instead of reading a confident verdict built on half of it.
$script:ExtraNamesTruncated = $false
function Select-BoundedNames {
    param([AllowEmptyCollection()][string[]]$Names)
    $accepted = @(@($Names) | ForEach-Object { ([string]$_).Trim() } | Where-Object { Test-CandidateNameToken $_ })
    if (@($Names).Count -gt 0 -and @($accepted).Count -lt @(@($Names) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) {
        $script:ExtraNamesTruncated = $true
    }
    if (@($accepted).Count -gt $script:CleanupExtraNameMaxCount) {
        $script:ExtraNamesTruncated = $true
        $accepted = @($accepted | Select-Object -First $script:CleanupExtraNameMaxCount)
    }
    return @($accepted)
}
$extraCandidateNames = @()
if ($config.ContainsKey('EXTRA_CANDIDATE_NAMES')) { $extraCandidateNames = Select-BoundedNames -Names @($config['EXTRA_CANDIDATE_NAMES'].Split(';')) }
$extraReviewNames = @()
if ($config.ContainsKey('EXTRA_REVIEW_NAMES')) { $extraReviewNames = Select-BoundedNames -Names @($config['EXTRA_REVIEW_NAMES'].Split(';')) }

if ($eventName -ne 'SessionStart' -and $eventName -ne 'Stop' -and -not ($eventName -eq 'SubagentStop' -and $enableSubagentStop)) {
    exit 0
}

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash $projectRoot.ToLowerInvariant()
$baselinePath = Join-Path $stateDir ('TestTempCleanup-baseline-' + $projectKey + '.json')
$resultPath = Join-Path $stateDir ('TestTempCleanup-result-' + $projectKey + '.json')
# Anti-loop + residue-tracking state. The old build's
# TestTempCleanup-failure-<key>.txt belonged to the deleted "could not remove"
# failure model; it is never read or written again. A leftover file from an
# older build is inert (this hook has no deletion authority even over its own
# obsolete state, so it is left where it is rather than removed).
$hookStatePath = Join-Path $stateDir ('TestTempCleanup-state-' + $projectKey + '.json')

# ==========================================================================
# SessionStart: bounded metadata-only baseline. Silent unless the SCAN was
# partial - never any project mutation, never an agent action.
# ==========================================================================
if ($eventName -eq 'SessionStart') {
    $gitAvailable = Test-GitWorkTree $projectRoot
    $scan = Get-CleanupScan -Root $projectRoot -ExtraCandidateNames $extraCandidateNames -ExtraReviewNames $extraReviewNames -MaxEntries $maxScanEntries -MaxDepth $maxScanDepth
    $causes = @{}
    foreach ($cause in @($scan.PartialCauses)) { $causes[$cause] = $true }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($scan.Candidates)) {
        if (-not (Test-PathInside -Candidate $candidate.Path -Parent $projectRoot)) { continue }
        $relPath = $candidate.Path.Substring($projectRoot.Length).TrimStart('\', '/')
        $size = Get-CandidateSize -Path $candidate.Path -IsDir $candidate.IsDir -IsLink $candidate.IsLink
        if (-not $size.Ok) { $causes['candidate-metadata-unreadable'] = $true }
        $modifiedUtc = ''
        try { $modifiedUtc = (Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop).LastWriteTimeUtc.ToString('o') }
        catch { $causes['candidate-metadata-unreadable'] = $true }
        $gitState = Get-GitCandidateState -Root $projectRoot -RelPath $relPath -GitAvailable $gitAvailable
        if ($gitState -eq 'unknown') { $causes['git-state-unknown'] = $true }
        # sizeBounded is load-bearing, not decorative: it is what makes the
        # neighbouring sizeBytes a LOWER BOUND rather than a size, and the Stop
        # comparison below reads it. Anything that ever consumes sizeBytes must
        # read sizeBounded in the same breath.
        [void]$records.Add([ordered]@{
            relPath = $relPath; kind = $candidate.Kind; isDir = $candidate.IsDir; isLink = $candidate.IsLink
            sizeBytes = $size.Bytes; sizeBounded = $size.Bounded; modifiedUtc = $modifiedUtc; gitState = $gitState
        })
    }

    $allCauses = @($causes.Keys | Sort-Object)
    $baseline = [ordered]@{
        sessionId = $sessionId
        projectKey = $projectKey
        repoStateFingerprint = (Get-RepoStateFingerprint -ProjectRoot $projectRoot)
        scanComplete = ($allCauses.Count -eq 0)
        partialCauses = $allCauses
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        candidates = $records.ToArray()
    }
    Write-JsonFileAtomic -Value $baseline -Path $baselinePath

    $coverage = @($allCauses | Where-Object { $script:CoverageCauses -contains $_ })
    if ($coverage.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('TEST TEMP CLEANUP (detector only - this hook never deletes anything): the SessionStart residue baseline scan was PARTIAL (' + ($coverage -join ', ') + ').')
        [void]$lines.Add('A partial baseline means a later cleanliness check for this session cannot be complete. Resolve the unreadable path(s), or raise MAX_SCAN_ENTRIES/MAX_SCAN_DEPTH in this hook''s .env, if disposable-residue coverage matters for this task.')
        Write-ClientMessage -Message ($lines.ToArray() -join "`n") -EventName $eventName -Blocking $false
    }
    exit 0
}

# ==========================================================================
# Stop / SubagentStop: rescan, classify, instruct, gate. Still no mutation of
# any project file.
# ==========================================================================
# Stand down only on THIS hook's OWN re-entry. The shared `stop_hook_active`
# flag is set for ANY gate's block, so keying on it lets one gate silence the
# rest; keying on nothing at all - which this hook did - means blocking on
# every Stop for ever. The marker written just before the block is the key.
if (Test-StopStandDown -HookInput $hookInput -HookName 'Test-Temp-Cleanup') { exit 0 }
# Reachable from Write-ClientMessage, which records the block marker.
$script:hookInput = $hookInput

$gitAvailable = Test-GitWorkTree $projectRoot

$baseline = Read-JsonFile -Path $baselinePath
$baselineMap = @{}
$baselineAvailable = $false
$causes = @{}
if ($null -eq $baseline) {
    $causes['baseline-missing'] = $true
}
elseif ([string](Get-Field $baseline 'sessionId') -ne $sessionId -or $sessionId -eq '') {
    $causes['baseline-session-mismatch'] = $true
}
else {
    $baselineAvailable = $true
    foreach ($record in @(Get-Field $baseline 'candidates')) {
        if ($null -eq $record) { continue }
        # SizeBounded travels with SizeBytes deliberately. A baseline written by
        # an older build has no sizeBounded field at all; Get-Field returns
        # $null there, which reads as "not bounded" - the same answer that build
        # would have given, so an old baseline is not retroactively distrusted.
        $baselineMap[[string](Get-Field $record 'relPath')] = [pscustomobject]@{
            SizeBytes = [string](Get-Field $record 'sizeBytes')
            SizeBounded = ((Get-Field $record 'sizeBounded') -eq $true)
            ModifiedUtc = (Format-BaselineTimestamp (Get-Field $record 'modifiedUtc'))
        }
    }
    # A baseline whose own scan was partial cannot prove a candidate is new.
    foreach ($cause in @(Get-Field $baseline 'partialCauses')) {
        if (@($script:CoverageCauses) -contains [string]$cause) { $causes['classification-incomplete'] = $true }
    }
}

# Previously surfaced likely-disposable paths for THIS session (residue check)
# plus the last emitted evidence fingerprint (anti-loop).
$hookState = Read-JsonFile -Path $hookStatePath
$lastEvidenceFingerprint = ''
$previouslyReported = @{}
if ($null -ne $hookState -and [string](Get-Field $hookState 'sessionId') -eq $sessionId -and $sessionId -ne '') {
    $lastEvidenceFingerprint = [string](Get-Field $hookState 'evidenceFingerprint')
    foreach ($reported in @(Get-Field $hookState 'reportedDisposable')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reported)) { $previouslyReported[[string]$reported] = $true }
    }
}

# BEFORE the walk, not after it: a candidate created while the scan was
# already past its directory is newer than a completion stamp would be,
# so the consumer would accept evidence that never inspected it.
if ($script:ExtraNamesTruncated) { $causes['extra-names-unsupported'] = $true }
$scanStartedUtc = [DateTime]::UtcNow.ToString('o')
$scan = Get-CleanupScan -Root $projectRoot -ExtraCandidateNames $extraCandidateNames -ExtraReviewNames $extraReviewNames -MaxEntries $maxScanEntries -MaxDepth $maxScanDepth
foreach ($cause in @($scan.PartialCauses)) { $causes[$cause] = $true }

$findings = New-Object System.Collections.Generic.List[object]
foreach ($candidate in @($scan.Candidates)) {
    # Nothing outside the canonical project root is ever surfaced.
    if (-not (Test-PathInside -Candidate $candidate.Path -Parent $projectRoot)) { continue }
    $relPath = $candidate.Path.Substring($projectRoot.Length).TrimStart('\', '/')
    if ($relPath -eq '') { continue }

    $size = Get-CandidateSize -Path $candidate.Path -IsDir $candidate.IsDir -IsLink $candidate.IsLink
    $metadataOk = $size.Ok
    $modifiedUtc = ''
    try { $modifiedUtc = (Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop).LastWriteTimeUtc.ToString('o') }
    catch { $metadataOk = $false }
    if (-not $metadataOk) { $causes['candidate-metadata-unreadable'] = $true }

    $gitState = Get-GitCandidateState -Root $projectRoot -RelPath $relPath -GitAvailable $gitAvailable
    if ($gitState -eq 'unknown') { $causes['git-state-unknown'] = $true }

    # Existence at SessionStart, and whether it appeared/changed during the
    # session - only when the baseline can actually answer that.
    $existedAtStart = 'unknown'
    $sessionDelta = 'unknown'
    if ($baselineAvailable) {
        if ($baselineMap.ContainsKey($relPath)) {
            $existedAtStart = 'yes'
            $before = $baselineMap[$relPath]
            # A '>=N' measurement on EITHER side can never prove 'unchanged':
            # two equal lower bounds are two ceilings that happened to land in
            # the same place, not two equal sizes - and two different lower
            # bounds prove nothing either, since a partial walk has no
            # guaranteed order. So a bounded size may still confirm a change
            # via the mtime (a positive fact), but may never be the evidence
            # for 'unchanged'; without that evidence the delta is 'unknown',
            # which is already this field's vocabulary for "cannot tell".
            if ($before.ModifiedUtc -ne $modifiedUtc) { $sessionDelta = 'modified' }
            elseif ($before.SizeBounded -or $size.Bounded) { $sessionDelta = 'unknown' }
            elseif ($before.SizeBytes -ne ([string]$size.Bytes)) { $sessionDelta = 'modified' }
            else { $sessionDelta = 'unchanged' }
        }
        else {
            $existedAtStart = 'no'
            $sessionDelta = 'appeared'
        }
    }

    # ---- exactly one classification, protections first ----
    $classification = ''
    if (-not $metadataOk) { $classification = 'partial-or-unreadable' }
    elseif ($candidate.IsLink) { $classification = 'protected' }
    elseif ($gitState -eq 'unknown') { $classification = 'unknown-git-state' }
    elseif ($gitState -eq 'tracked' -or $gitState -eq 'staged') { $classification = 'protected' }
    elseif ($candidate.Kind -eq 'review-dir' -or $candidate.Kind -eq 'review-file') { $classification = 'review-or-diagnostic' }
    elseif (-not $baselineAvailable) { $classification = 'ambiguous' }
    elseif ($candidate.Kind -eq 'task-created-dir' -or $candidate.Kind -eq 'task-created-file') {
        # Task-created output is only describable as disposable when it really
        # appeared during this session; a pre-existing one stays ambiguous.
        if ($sessionDelta -eq 'appeared') { $classification = 'likely-disposable' } else { $classification = 'ambiguous' }
    }
    else { $classification = 'likely-disposable' }
    if (@($script:Classifications) -notcontains $classification) {
        # Unreachable by construction; if it ever happens, say so rather than
        # emit a category the contract does not define.
        $causes['classification-incomplete'] = $true
        $classification = 'partial-or-unreadable'
    }

    $sizeText = 'unknown'
    if ($size.Bytes -ge 0 -and $metadataOk) { $sizeText = if ($size.Bounded) { '>=' + $size.Bytes } else { [string]$size.Bytes } }

    [void]$findings.Add([pscustomobject]@{
        RelPath = $relPath
        Classification = $classification
        TypeLabel = (Get-CandidateTypeLabel $candidate.Kind)
        ExistedAtStart = $existedAtStart
        SessionDelta = $sessionDelta
        GitState = $gitState
        LinkState = if ($candidate.IsLink) { 'reparse-point' } else { 'none' }
        SizeText = $sizeText
        MatchReason = (Get-MatchReason $candidate.Kind)
        ReviewReason = (Get-ReviewReason $classification)
    })
}

# .ToArray() once, then work with plain arrays only (see the PSObject-wrapped
# collection note in Get-CleanupScan).
$foundList = $findings.ToArray()
$allCauses = @($causes.Keys | Sort-Object)
$coverageCauses = @($allCauses | Where-Object { $script:CoverageCauses -contains $_ })
$evidenceCauses = @($allCauses | Where-Object { $script:EvidenceCauses -contains $_ })
$disposableNow = @($foundList | Where-Object { $_.Classification -eq 'likely-disposable' })
$residueNow = @($disposableNow | Where-Object { $previouslyReported.ContainsKey($_.RelPath) })
$reviewNeeded = @($foundList | Where-Object { $script:ReviewRequiringClassifications -contains $_.Classification })
$sortedFound = @($foundList | Sort-Object -Property RelPath)

# ---- result category (the shared contract). 'clean' requires a COMPLETE scan
# with nothing needing review - a candidate-free PARTIAL scan is 'partial'. ----
if ($coverageCauses.Count -gt 0) { $category = 'partial' }
elseif ($evidenceCauses.Count -gt 0) { $category = 'unknown' }
elseif ($residueNow.Count -gt 0) { $category = 'residue-confirmed' }
elseif ($reviewNeeded.Count -gt 0) { $category = 'review-required' }
else { $category = 'clean' }
# Enforce the shared vocabulary rather than merely documenting it: a future edit
# that invents a category the consumer does not know degrades to the safe
# 'unknown' (never release-ready) instead of writing an unrecognized value.
if ($script:ResultCategories -notcontains $category) { $category = 'unknown' }

# ---- anti-loop evidence fingerprint ----
# Enough bounded metadata to tell a REAL evidence change from a repeat: project
# and session identity, scan completeness and its causes, the resolved
# category, and every candidate's path + classification + git state + baseline
# delta + a size/mtime hash. A changed candidate state re-surfaces; an
# unchanged one is reported once.
$evidenceParts = New-Object System.Collections.Generic.List[string]
[void]$evidenceParts.Add('p=' + $projectKey)
[void]$evidenceParts.Add('s=' + $sessionId)
[void]$evidenceParts.Add('complete=' + ($allCauses.Count -eq 0))
[void]$evidenceParts.Add('causes=' + ($allCauses -join ','))
[void]$evidenceParts.Add('cat=' + $category)
foreach ($finding in $sortedFound) {
    [void]$evidenceParts.Add('c=' + $finding.RelPath + '~' + $finding.Classification + '~' + $finding.GitState +
        '~' + $finding.ExistedAtStart + '~' + $finding.SessionDelta + '~' + $finding.LinkState +
        '~' + (Get-ShortHash ($finding.SizeText + '|' + $finding.TypeLabel)))
}
$evidenceFingerprint = Get-ShortHash ($evidenceParts.ToArray() -join '|')

# ---- coordination record: ALWAYS written, even when the message is
# suppressed, because Cloudflare-Deploy and Test-Completion-Check need a result
# bound to the CURRENT repo state (concurrent lifecycle hooks; registration
# order is display-only and never an execution order). ----
$record = New-CleanupCoordinationRecord -SessionId $sessionId -Category $category -Fingerprint (Get-RepoStateFingerprint -ProjectRoot $projectRoot) -ScanComplete ($allCauses.Count -eq 0) -PartialCauses $allCauses -CandidateCount $foundList.Count -ReviewCount $reviewNeeded.Count -ResidueCount $residueNow.Count -EvidenceFingerprint $evidenceFingerprint -ScanStartedUtc $scanStartedUtc -ExtraCandidateNames $extraCandidateNames -ExtraReviewNames $extraReviewNames
Write-JsonFileAtomic -Value $record -Path $resultPath

Write-JsonFileAtomic -Path $hookStatePath -Value ([ordered]@{
    sessionId = $sessionId
    evidenceFingerprint = $evidenceFingerprint
    reportedDisposable = @(@($disposableNow | ForEach-Object { $_.RelPath }) | Sort-Object)
    category = $category
    updatedUtc = [DateTime]::UtcNow.ToString('o')
})

if ($category -eq 'clean') { exit 0 }
if ($evidenceFingerprint -eq $lastEvidenceFingerprint) { exit 0 }

# ---- report ----
$lines = New-Object System.Collections.Generic.List[string]
$blocking = $false
switch ($category) {
    'residue-confirmed' {
        $blocking = $true
        [void]$lines.Add('TEST TEMP CLEANUP (detector only - this hook never deletes anything): ' + $residueNow.Count +
            ' candidate(s) already surfaced as likely-disposable on an earlier Stop of this session are STILL PRESENT: ' +
            ((@($residueNow | Select-Object -First $maxFindings | ForEach-Object { $_.RelPath })) -join ', ') + '.')
        [void]$lines.Add('Do not claim the task is complete while unresolved disposable residue remains. Either delete what YOU have independently confirmed is disposable, or state explicitly why it must stay. (This hook is reporting that its earlier instruction was not resolved - it has NOT itself confirmed any path is safe to delete.)')
    }
    'partial' {
        $blocking = $true
        [void]$lines.Add('TEST TEMP CLEANUP (detector only - this hook never deletes anything): the residue scan was PARTIAL (' + ($coverageCauses -join ', ') + '), so this project state cannot be reported as clean.')
        [void]$lines.Add('Do not claim the workspace is free of disposable test residue. Resolve the unreadable path(s), or raise MAX_SCAN_ENTRIES/MAX_SCAN_DEPTH in this hook''s .env, then re-check - or state the coverage limit explicitly instead of assuming it is clean.')
    }
    'unknown' {
        [void]$lines.Add('TEST TEMP CLEANUP (detector only - this hook never deletes anything): candidate classification is UNKNOWN for this state (' + ($evidenceCauses -join ', ') + ').')
        [void]$lines.Add('Without that evidence nothing can be described as disposable - treat every candidate below as ambiguous and leave it intact.')
    }
    default {
        [void]$lines.Add('TEST TEMP CLEANUP (detector only - this hook never deletes anything): ' + $reviewNeeded.Count + ' recognized candidate(s) need YOUR review in this project.')
    }
}

if ($foundList.Count -gt 0) {
    [void]$lines.Add('Candidates (relative paths and bounded metadata only - no file contents are read or shown):')
    foreach ($finding in @($sortedFound | Select-Object -First $maxFindings)) {
        [void]$lines.Add('  ' + $finding.RelPath +
            ' | class=' + $finding.Classification +
            ' | type=' + $finding.TypeLabel +
            ' | at-session-start=' + $finding.ExistedAtStart +
            ' | during-session=' + $finding.SessionDelta +
            ' | git=' + $finding.GitState +
            ' | link=' + $finding.LinkState +
            ' | size=' + $finding.SizeText +
            ' | matched=' + $finding.MatchReason +
            ' | needs-review=' + $finding.ReviewReason)
    }
    if ($foundList.Count -gt $maxFindings) {
        [void]$lines.Add('  ... and ' + ($foundList.Count - $maxFindings) + ' more (MAX_FINDINGS reached - the list is truncated, the scan is not).')
    }
}
[void]$lines.Add('Scan coverage: ' + $(if ($allCauses.Count -eq 0) { 'complete' } else { 'PARTIAL - ' + ($allCauses -join ', ') }))
foreach ($instruction in (Get-AgentInstructionLines)) { [void]$lines.Add($instruction) }

Write-ClientMessage -Message ($lines.ToArray() -join "`n") -EventName $eventName -Blocking $blocking
exit 0
