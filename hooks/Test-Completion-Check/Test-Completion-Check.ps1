# Test-Completion-Check - the AFTER stage of the three-stage test-health
# architecture (global-test-rules.md SS Three-Stage Test Enforcement /
# global-hook-rules.md SS Test Hook Architecture).
#
# ROLE: GATE (global-hook-rules.md SS Hook Roles).
#   Events: Stop, SubagentStop.
#   It blocks completion ONLY on a CONFIRMED, CURRENT-state condition, and it
#   never runs a test, never spawns a process, and never edits a file. Its own
#   state lives under %LOCALAPPDATA%\HookMaker\state - never in the project.
#
# THE RECURSION GUARD COMES FIRST. `stop_hook_active` is checked and exited on
# before anything else is read or evaluated (the pattern proven by
# Ci-Status-Check.ps1:235). A Stop gate that can re-trigger itself is a hang,
# not a check.
#
# WHAT IT BLOCKS ON (each one confirmed from recorded evidence, never inferred):
#   1. a guarded run is STILL ACTIVE (its recorded owner pid is alive);
#   2. the guarded result says `terminated` (wallTimeout / idleTimeout /
#      memoryLimit) and that incident is not yet resolved;
#   3. the guarded result carries a non-empty `leakedProcessIds`;
#   4. the guarded result says `failed` - the run did not complete cleanly;
#   5. a test command was OBSERVED for the current project state but there is
#      no CURRENT guarded result to prove how it ended;
#   6. a durable `.ai/` note is owed for a hang/timeout/kill/leak and has not
#      been written yet.
# Everything else is silence. No relevant test work is by far the common case.
#
# STALENESS ONLY WEAKENS POSITIVE EVIDENCE, NEVER NEGATIVE FINDINGS. A result
# older than TEST_COMPLETION_EVIDENCE_MINUTES is not proof that a run happened
# for the current state (case 5 then applies), but an old hang is still an
# unrecorded hang - cases 2/3 are evaluated regardless of age until resolved.
# This hook NEVER says "all tests passed": it reports only what the recorded
# evidence actually shows, and stays silent rather than claim a scope it has
# not seen.
#
# COORDINATION STATE (all consumed files are OPTIONAL - an absent file means
# that check is simply not evaluated, so a missing producer can never widen
# what this hook blocks on). Project key = Get-ShortHash(lowercased cwd), the
# same key Test-Temp-Cleanup and Cloudflare-Deploy already use. The result,
# observed and active files are PER-RUN - keyed by <projectKey>-<runId> - so two
# guarded runs in one project never overwrite each other; this hook ENUMERATES
# and AGGREGATES all of a project's per-run files rather than reading one path,
# and accepts completion only when every current-state observed run is finished.
# (A legacy non-suffixed file from an older build is still honoured.)
#   read  TestRunGuard-result-<key>-<runId>.json    each run's Run-Tests-Guarded.ps1
#                                           result document (schema/overall/
#                                           exitCode/terminated/terminateReason/
#                                           leakedProcessIds/endedUtc/... plus the
#                                           run identity runId/commandFingerprint/
#                                           projectFingerprint).
#   read  TestRunGuard-active-<key>-<runId>.json     { ownerPid, ownerProcessStartUtc,
#                                           ownerExecutablePath, ... } while THAT
#                                           run holds a live child. A dead/recycled
#                                           pid makes the marker stale, not active.
#   read  TestRunGuard-observed-<key>-<runId>.json   { observedUtc, projectFingerprint,
#                                           runId, guarded } - a test command was
#                                           seen running for that repo-state.
#   read  TestTempCleanup-result-<key>.json  Test-Temp-Cleanup's existing
#                                           { fingerprint, category } handoff.
#   write TestCompletionCheck-<key>.json    this hook's own resolved-incident /
#                                           owed-note / deferral state (project-keyed,
#                                           not per-run - it tracks the project).
#
# TEST-TEMP-CLEANUP RACE. Stop hooks for one event run CONCURRENTLY and
# independently; registration order is display-only and is never an execution
# order (the same reasoning Cloudflare-Deploy.ps1 lines 1-20 document). When
# Test-Temp-Cleanup is installed for this project but has not yet recorded a
# result for the CURRENT fingerprint, this hook waits at most
# TEST_COMPLETION_COORDINATION_WAIT_SECONDS, then DEFERS ONCE: it stays silent
# and re-evaluates on the NEXT event. It never retries inside one invocation.
# The deferral is recorded per fingerprint, so a producer that never records
# cannot silence this gate forever - the next event evaluates normally.
#
# OUTPUT (Ci-Status-Check.ps1 lines 50-54 and 290-322 is the authority):
#   real block  -> { decision: 'block', reason } for BOTH clients. On Codex a
#                  Stop block FORCES CONTINUATION (a new prompt) - which is
#                  exactly the intended effect of a genuine completion gate, and
#                  is why Ci-Status-Check emits it on its blocking paths too.
#   advisory    -> CLIENT-AWARE and never `decision:block`. The client is
#                  detected by CLAUDE_PROJECT_DIR being exported (Claude Code
#                  sets it on every hook process, Codex does not - the same
#                  signal Ci-Status-Check, Rules-Check and Secrets-Check use).
#                  Claude Code gets
#                  `hookSpecificOutput.additionalContext` (its documented
#                  model-visible Stop field); Codex gets `systemMessage` (its
#                  only documented common field). Emitting a Codex block for an
#                  advisory would force a pointless new prompt - an infinite
#                  loop for Codex users - so it is never done.
# TEST_COMPLETION_ADVISORY_ONLY=1 turns every would-be block into that advisory.
#
# Optional .env next to this script (copy .env.example):
#   TEST_COMPLETION_EVIDENCE_MINUTES           minutes a result stays current (default 180)
#   TEST_COMPLETION_ADVISORY_ONLY              1 = report, never block (default 0)
#   TEST_COMPLETION_ALWAYS_REQUIRE_NOTE        1 = a note after every run (default 0)
#   TEST_COMPLETION_COORDINATION_WAIT_SECONDS  bounded same-Stop wait (default 2)
# An invalid value is reported in plain text with the output it is attached to
# and the fallback is applied so it can only ever NARROW what is blocked on -
# never widen it. A malformed setting must not turn this gate into a nag.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }

# ---- recursion guard: FIRST, before anything is read or evaluated ----
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }

$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }

# ---- optional .env (invalid -> reported + a NON-WIDENING fallback) ----
$configWarnings = New-Object System.Collections.Generic.List[string]
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

$evidenceMinutes = 180
if ($config.ContainsKey('TEST_COMPLETION_EVIDENCE_MINUTES')) {
    $raw = [string]$config['TEST_COMPLETION_EVIDENCE_MINUTES']
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 10080) {
        $evidenceMinutes = $parsed
    }
    elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_EVIDENCE_MINUTES is not an integer in 1..10080; using the default 180.')
    }
}

# An invalid value here falls back to ADVISORY (1), not to the blocking default:
# the setting was clearly meant to be changed, and a typo must never make this
# hook block on MORE than it would have. Reported, never silent.
$advisoryOnly = $false
if ($config.ContainsKey('TEST_COMPLETION_ADVISORY_ONLY')) {
    $raw = [string]$config['TEST_COMPLETION_ADVISORY_ONLY']
    if ($raw -eq '1') { $advisoryOnly = $true }
    elseif ($raw -ne '0' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        $advisoryOnly = $true
        [void]$configWarnings.Add('TEST_COMPLETION_ADVISORY_ONLY must be 0 or 1; falling back to advisory-only (1) so a malformed value can never widen what is blocked on.')
    }
}

$alwaysRequireNote = $false
if ($config.ContainsKey('TEST_COMPLETION_ALWAYS_REQUIRE_NOTE')) {
    $raw = [string]$config['TEST_COMPLETION_ALWAYS_REQUIRE_NOTE']
    if ($raw -eq '1') { $alwaysRequireNote = $true }
    elseif ($raw -ne '0' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_ALWAYS_REQUIRE_NOTE must be 0 or 1; using the default 0 (a note is required only after an incident).')
    }
}

$coordinationWaitSeconds = 2
if ($config.ContainsKey('TEST_COMPLETION_COORDINATION_WAIT_SECONDS')) {
    $raw = [string]$config['TEST_COMPLETION_COORDINATION_WAIT_SECONDS']
    $parsed = -1
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 30) {
        $coordinationWaitSeconds = $parsed
    }
    elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_COMPLETION_COORDINATION_WAIT_SECONDS is not an integer in 0..30; using the default 2.')
    }
}

# ---- paths ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash $cwd.ToLowerInvariant()
# result/observed/active are PER-RUN now (TestRunGuard-<kind>-<key>-<runId>.json)
# and are enumerated + aggregated below, never read from one fixed path.
$cleanupPath = Join-Path $stateDir ('TestTempCleanup-result-' + $projectKey + '.json')
$statePath = Join-Path $stateDir ('TestCompletionCheck-' + $projectKey + '.json')

# The four durable-memory files a hang/timeout finding may legitimately be
# recorded in (AI Context Memory Policy). Any of them growing satisfies the
# requirement - the hook never dictates which one.
$script:NoteFiles = @('.ai\BUGS.md', '.ai\TESTING_NOTES.md', '.ai\COMMANDS.md', '.ai\LESSON.md')
# Net bytes a durable note must add before it counts. A bare acknowledgement
# ("done", "n/a", "fixed") cannot clear this; a real note trivially does.
$script:MinNoteBytes = 80

function Get-NoteBytes {
    param([string]$Root)
    $total = 0L
    foreach ($relative in $script:NoteFiles) {
        $path = Join-Path $Root $relative
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) { $total += (Get-Item -LiteralPath $path -Force).Length }
        }
        catch { }
    }
    return $total
}

# Normalises a timestamp read back out of JSON to a genuine UTC DateTime.
#
# THIS IS NOT DEFENSIVE PADDING - it fixes a measured 210-minute error on this
# machine. ConvertFrom-Json rehydrates an ISO-8601 string into a [DateTime]
# whose Kind is already Utc; casting that to [string] renders the UTC clock
# with NO zone marker, and re-parsing the result yields Kind=Unspecified, so a
# following ToUniversalTime() subtracts the local offset a SECOND time. A run
# that had just ended then read as 3.5 hours old - i.e. STALE - which is the
# exact failure this hook exists to prevent. Every producer here (the guarded
# runner's startedUtc/endedUtc, Test-Run-Guard's recordedUtc) writes UTC, so an
# Unspecified Kind is treated as UTC rather than converted.
function ConvertTo-UtcTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = [DateTime]::MinValue
    if ($Value -is [DateTime]) {
        $parsed = $Value
    }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        if (-not [DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return $null
        }
    }
    if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { return $parsed }
    if ($parsed.Kind -eq [System.DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
    return [DateTime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
}

# The exact run-identity gate (mirrors Test-Run-Guard's Test-ResultMatchesObserved).
# A result describes the current observation ONLY when its command and project
# fingerprints match the observed record AND the current state, its start is not
# before the observation, its end is not before its start, its required fields
# are present, and - when the observing hook controlled the runId - the runId
# matches. A fresh result for a different run/command/state is NOT evidence.
function Test-ResultMatchesObserved {
    param($Result, $Observed, [string]$CurrentStateFingerprint)
    if ($null -eq $Result -or $null -eq $Observed) { return $false }
    $rCmdFp = [string](Get-Field $Result 'commandFingerprint')
    $rProjFp = [string](Get-Field $Result 'projectFingerprint')
    $rRunId = [string](Get-Field $Result 'runId')
    $rStarted = ConvertTo-UtcTime (Get-Field $Result 'startedUtc')
    $rEnded = ConvertTo-UtcTime (Get-Field $Result 'endedUtc')
    if ([string]::IsNullOrWhiteSpace($rCmdFp) -or [string]::IsNullOrWhiteSpace($rProjFp) -or $null -eq $rStarted -or $null -eq $rEnded) { return $false }
    $oCmdFp = [string](Get-Field $Observed 'commandFingerprint')
    $oProjFp = [string](Get-Field $Observed 'projectFingerprint')
    if ([string]::IsNullOrWhiteSpace($oProjFp)) { $oProjFp = [string](Get-Field $Observed 'fingerprint') }
    $oRunId = [string](Get-Field $Observed 'runId')
    $oControlled = ((Get-Field $Observed 'runIdControlled') -eq $true)
    $oObserved = ConvertTo-UtcTime (Get-Field $Observed 'observedUtc')
    if ($rCmdFp -ne $oCmdFp) { return $false }
    if ($rProjFp -ne $oProjFp) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($CurrentStateFingerprint) -and $rProjFp -ne $CurrentStateFingerprint) { return $false }
    if ($null -ne $oObserved -and $rStarted -lt $oObserved.AddSeconds(-2)) { return $false }
    if ($rEnded -lt $rStarted.AddSeconds(-2)) { return $false }
    if ($oControlled -and $rRunId -ne $oRunId) { return $false }
    return $true
}

# ---- current state fingerprint (git-based when available, else the cwd) ----
$stateFingerprint = ''
try { $stateFingerprint = [string](Get-RepoStateFingerprint -ProjectRoot $cwd) } catch { $stateFingerprint = '' }
if ([string]::IsNullOrWhiteSpace($stateFingerprint)) { $stateFingerprint = Get-ShortHash $cwd.ToLowerInvariant() }

# ---- this hook's own state ----
$previous = $null
try { $previous = Read-JsonFile $statePath } catch { $previous = $null }
$resolvedIncident = ''
$pendingNoteKey = ''
$pendingNoteReason = ''
$pendingNoteBaseline = -1L
$deferredFingerprint = ''
if ($null -ne $previous) {
    $resolvedIncident = [string](Get-Field $previous 'resolvedIncident')
    $pendingNoteKey = [string](Get-Field $previous 'pendingNoteKey')
    $pendingNoteReason = [string](Get-Field $previous 'pendingNoteReason')
    $rawBaseline = Get-Field $previous 'pendingNoteBaseline'
    if ($null -ne $rawBaseline) { try { $pendingNoteBaseline = [int64]$rawBaseline } catch { $pendingNoteBaseline = -1L } }
    $deferredFingerprint = [string](Get-Field $previous 'deferredFingerprint')
}

function Save-CompletionState {
    param([string]$ResolvedIncident, [string]$NoteKey, [string]$NoteReason, [int64]$NoteBaseline, [string]$Deferred)
    try {
        Write-JsonFileAtomic -Value ([pscustomobject]@{
                resolvedIncident    = $ResolvedIncident
                pendingNoteKey      = $NoteKey
                pendingNoteReason   = $NoteReason
                pendingNoteBaseline = $NoteBaseline
                deferredFingerprint = $Deferred
                updatedUtc          = [DateTime]::UtcNow.ToString('o')
            }) -Path $script:statePath
    }
    catch { }
}

# ---- output ---------------------------------------------------------------
# A real block uses `decision:block` for both clients (Ci-Status-Check's
# blocking paths do the same). An advisory is CLIENT-AWARE and never a block:
# on Codex `decision:block` at Stop forces a new prompt, which for an advisory
# would be an infinite loop.
function Write-Finding {
    param([string[]]$Lines, [bool]$Blocking)
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { [void]$all.Add($line) }
    if ($script:configWarnings.Count -gt 0) {
        [void]$all.Add('')
        foreach ($warning in $script:configWarnings) { [void]$all.Add('Test-Completion-Check .env: ' + $warning) }
    }
    $message = ($all.ToArray() -join "`n")
    if ($Blocking -and -not $script:advisoryOnly) {
        @{ decision = 'block'; reason = $message } | ConvertTo-Json -Compress | ForEach-Object { [Console]::Out.WriteLine($_) }
        exit 0
    }
    # Client detection is the project's existing signal: Claude Code exports
    # CLAUDE_PROJECT_DIR on every hook process, Codex does not (Ci-Status-Check
    # .ps1:314, Rules-Check.ps1:52, Secrets-Check.ps1:808). `hookSpecificOutput`
    # is an OUTPUT field and appears in no event INPUT, so it is never a signal.
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) {
        $payload = @{ hookSpecificOutput = @{ hookEventName = $script:eventName; additionalContext = $message } }
    }
    else {
        $payload = @{ systemMessage = $message }
    }
    $payload | ConvertTo-Json -Depth 5 -Compress | ForEach-Object { [Console]::Out.WriteLine($_) }
    exit 0
}

# ---- read the recorded evidence (AGGREGATED across per-run files) ----------
# result/observed/active are PER-RUN (TestRunGuard-<kind>-<key>-<runId>.json), so
# two runs in one project each own their own files and never overwrite each other.
# Completion is accepted only when EVERY current-state observed run is satisfied
# and none is unfinished; it is BLOCKED when ANY run is active, terminated/leaked/
# failed, or observed-with-no-result. Older-STATE runs are not current evidence
# and never block. The single representative run selected below drives the exact
# same conditions 1-6 the single-file path used, so one-run behaviour is unchanged.

# All per-run files for one kind (+ a legacy non-suffixed file if an older build's
# run is still in flight), each with its parsed document.
function Get-CompletionStateEntries {
    param([string]$Kind)
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:stateDir -PathType Container)) { return @() }
    $files = New-Object System.Collections.Generic.List[object]
    try { foreach ($f in @(Get-ChildItem -LiteralPath $script:stateDir -Filter ('TestRunGuard-' + $Kind + '-' + $script:projectKey + '-*.json') -File -ErrorAction SilentlyContinue)) { [void]$files.Add($f) } } catch { }
    $legacy = Join-Path $script:stateDir ('TestRunGuard-' + $Kind + '-' + $script:projectKey + '.json')
    try { if (Test-Path -LiteralPath $legacy -PathType Leaf) { [void]$files.Add((Get-Item -LiteralPath $legacy -Force)) } } catch { }
    foreach ($file in $files) {
        $doc = $null
        try { $doc = Read-JsonFile $file.FullName } catch { $doc = $null }
        if ($null -eq $doc) { continue }
        [void]$entries.Add([pscustomobject]@{ Doc = $doc; Path = $file.FullName })
    }
    return @($entries.ToArray())
}

# The recorded time of a result: recordedUtc, else endedUtc, else file write time.
function Get-ResultRecordedTime {
    param($Doc, [string]$Path)
    $t = ConvertTo-UtcTime (Get-Field $Doc 'recordedUtc')
    if ($null -eq $t) { $t = ConvertTo-UtcTime (Get-Field $Doc 'endedUtc') }
    if ($null -eq $t -and -not [string]::IsNullOrWhiteSpace($Path)) {
        try { $t = (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc } catch { $t = $null }
    }
    return $t
}

function Get-ObservedFingerprint {
    param($Doc)
    $fp = [string](Get-Field $Doc 'projectFingerprint')
    if ([string]::IsNullOrWhiteSpace($fp)) { $fp = [string](Get-Field $Doc 'fingerprint') }
    return $fp
}

# The stable incident identity of a RESULT document, or '' when it is not an
# incident. Only a TERMINATED run or one carrying leaked process ids is an
# incident (a plain non-zero `failed` creates no durable-note obligation). The key
# is byte-identical to the one the main flow records into resolvedIncident, so a
# resolved incident can be recognised again per-run - used by the content-aware
# prune (C2) and the resolved-incident representative exclusion (C4).
function Get-ResultIncidentKey {
    param($Doc, [string]$Path)
    if ($null -eq $Doc) { return '' }
    $ov = ([string](Get-Field $Doc 'overall')).ToLowerInvariant()
    $tr = [string](Get-Field $Doc 'terminateReason')
    $lk = @(@(Get-Field $Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    if ($ov -ne 'terminated' -and $lk.Count -eq 0) { return '' }
    $t = Get-ResultRecordedTime -Doc $Doc -Path $Path
    $ticks = if ($null -ne $t) { [string]$t.Ticks } else { '0' }
    return (Get-ShortHash ($ticks + '|' + $ov + '|' + $tr + '|' + (@($lk) -join ',')))
}

# Has a NEGATIVE result been SUPERSEDED by a strictly-newer clean run for the same
# command AND project state? A clean (overall=ok, no leak) result recorded after
# the negative one means the same work was re-run green, so the old incident's
# files are safe to prune (this is the C2/C4 supersede rule).
# ponytail: O(n*m) over one project's per-run files, which are 24h-bounded and few.
function Test-ResultSuperseded {
    param($NegDoc, $NegTime, $AllResults)
    if ($null -eq $NegDoc -or $null -eq $NegTime) { return $false }
    $cmd = [string](Get-Field $NegDoc 'commandFingerprint')
    $proj = [string](Get-Field $NegDoc 'projectFingerprint')
    if ($cmd -eq '' -or $proj -eq '') { return $false }
    foreach ($re in @($AllResults)) {
        $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
        if ($ov -ne 'ok') { continue }
        $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($lk.Count -gt 0) { continue }
        if (([string](Get-Field $re.Doc 'commandFingerprint')) -ne $cmd) { continue }
        if (([string](Get-Field $re.Doc 'projectFingerprint')) -ne $proj) { continue }
        $t = Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path
        if ($null -ne $t -and $t -gt $NegTime) { return $true }
    }
    return $false
}

# Is a live guarded run recorded by THIS active marker? Returns the owner pid, or
# 0. LIVENESS IS PROVEN BY PROCESS IDENTITY ONLY (C1): the owner pid must be alive
# AND still carry the recorded process start time AND executable path (the
# PID-REUSE-resistant check). The marker's projectFingerprint is DELIBERATELY not
# consulted here - a test process is running regardless of what the working tree
# looks like now, so editing an unrelated file mid-run (which moves the repo
# fingerprint) must never make a genuinely-live marker read as stale and be
# deleted. The fingerprint governs only whether a RESULT is current-state
# evidence, never whether a running process exists.
function Resolve-ActiveOwnerPid {
    param($Doc)
    $ownerPidRaw = Get-Field $Doc 'ownerPid'
    if ($null -eq $ownerPidRaw) { $ownerPidRaw = Get-Field $Doc 'pid' }   # schema-1 fallback
    $candidate = 0
    if (-not [int]::TryParse([string]$ownerPidRaw, [ref]$candidate) -or $candidate -le 0) { return 0 }
    $liveProcess = $null
    try { $liveProcess = Get-Process -Id $candidate -ErrorAction Stop } catch { $liveProcess = $null }
    if ($null -eq $liveProcess) { return 0 }
    $markerStartUtc = ConvertTo-UtcTime (Get-Field $Doc 'ownerProcessStartUtc')
    $markerExe = [string](Get-Field $Doc 'ownerExecutablePath')
    if ($null -eq $markerStartUtc -and $markerExe -eq '') { return $candidate }   # schema-1 marker: best-effort legacy
    $identityOk = $true
    if ($null -ne $markerStartUtc) {
        $liveStart = $null
        try { $liveStart = $liveProcess.StartTime.ToUniversalTime() } catch { $liveStart = $null }
        if ($null -eq $liveStart -or [Math]::Abs(($liveStart - $markerStartUtc).TotalSeconds) -gt 2) { $identityOk = $false }
    }
    if ($identityOk -and $markerExe -ne '') {
        $liveExe = ''
        try { $liveExe = [string]$liveProcess.Path } catch { $liveExe = '' }
        if ($liveExe -ne '' -and -not [string]::Equals($liveExe, $markerExe, [System.StringComparison]::OrdinalIgnoreCase)) { $identityOk = $false }
    }
    if ($identityOk) { return $candidate }
    return 0
}

# The evidence is loaded BEFORE pruning so pruning can read each file's content.
$resultEntries = Get-CompletionStateEntries 'result'
$observedEntries = Get-CompletionStateEntries 'observed'
$activeEntries = Get-CompletionStateEntries 'active'

# ---- bounded, CONTENT-AWARE state growth control (C2) ----------------------
# Age alone must never erase a NEGATIVE finding. Staleness weakens only POSITIVE
# evidence (see this file's header): a run that TERMINATED, FAILED, LEAKED, errored
# or was OBSERVED-WITHOUT-A-RESULT for the current state is an incident whose
# obligation survives until it is RESOLVED (a durable note recorded, tracked in
# resolvedIncident) or SUPERSEDED (a strictly-newer clean ok run for the same
# command+state - which also underlies the C4 fix). Only clean ok runs,
# resolved/superseded negatives, and old-STATE observations that carry no current
# obligation are pruned, so a hang whose Stop hook never fired within 24h can never
# be silently deleted before it is seen. Best-effort: a read or delete failure
# never blocks the gate.
$pruneCutoff = [DateTime]::UtcNow.AddHours(-24)
function Get-FileMtimeUtc { param([string]$Path) try { return (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc } catch { return $null } }
$prunedResultPaths = New-Object System.Collections.Generic.HashSet[string]
$prunedObservedPaths = New-Object System.Collections.Generic.HashSet[string]
foreach ($re in $resultEntries) {
    $mtime = Get-FileMtimeUtc $re.Path
    if ($null -eq $mtime -or $mtime -ge $pruneCutoff) { continue }   # keep anything not yet 24h old
    $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
    $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    $isNegative = ((@('terminated', 'failed', 'error', 'unknown') -contains $ov) -or $lk.Count -gt 0)
    if (-not $isNegative) { [void]$prunedResultPaths.Add($re.Path); continue }   # clean ok run -> prunable
    $ik = Get-ResultIncidentKey -Doc $re.Doc -Path $re.Path
    $resolved = ($ik -ne '' -and $ik -eq $resolvedIncident)
    $superseded = Test-ResultSuperseded -NegDoc $re.Doc -NegTime (Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path) -AllResults $resultEntries
    if ($resolved -or $superseded) { [void]$prunedResultPaths.Add($re.Path) }
    # else: an unresolved, un-superseded negative finding -> KEEP, however old.
}
foreach ($oe in $observedEntries) {
    $mtime = Get-FileMtimeUtc $oe.Path
    if ($null -eq $mtime -or $mtime -ge $pruneCutoff) { continue }
    if ((Get-ObservedFingerprint $oe.Doc) -ne $stateFingerprint) { [void]$prunedObservedPaths.Add($oe.Path); continue }   # old-STATE: no current obligation
    $matched = @($resultEntries | Where-Object { Test-ResultMatchesObserved -Result $_.Doc -Observed $oe.Doc -CurrentStateFingerprint $stateFingerprint })
    if ($matched.Count -eq 0) { continue }   # observed-without-result for the CURRENT state -> keep (unfinished incident)
    $allPruned = $true
    foreach ($m in $matched) { if (-not $prunedResultPaths.Contains($m.Path)) { $allPruned = $false; break } }
    if ($allPruned) { [void]$prunedObservedPaths.Add($oe.Path) }   # its run is fully accounted for by a pruned clean/resolved result
}
foreach ($path in @($prunedResultPaths)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { } }
foreach ($path in @($prunedObservedPaths)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { } }
if ($prunedResultPaths.Count -gt 0) { $resultEntries = @($resultEntries | Where-Object { -not $prunedResultPaths.Contains($_.Path) }) }
if ($prunedObservedPaths.Count -gt 0) { $observedEntries = @($observedEntries | Where-Object { -not $prunedObservedPaths.Contains($_.Path) }) }

# ---- 1. any live active marker across all runs ----
# Set $activePid from the first genuinely-alive owner; drop every marker whose
# owner is proven DEAD or pid-reused. A marker whose owner PROCESS is alive is
# NEVER removed (C1) - not on a fingerprint change, not because one run finished:
# a running test blocks completion regardless of the current working-tree state.
$activePid = 0
foreach ($ae in $activeEntries) {
    $p = Resolve-ActiveOwnerPid -Doc $ae.Doc
    if ($p -gt 0) { if ($activePid -eq 0) { $activePid = $p } }
    else { try { Remove-Item -LiteralPath $ae.Path -Force -ErrorAction SilentlyContinue } catch { } }
}

# ---- build the candidate runs for the CURRENT state ----
$currentObserved = @($observedEntries | Where-Object { (Get-ObservedFingerprint $_.Doc) -eq $stateFingerprint })
$observedCurrent = ($currentObserved.Count -gt 0)
$observedCmdFps = New-Object System.Collections.Generic.HashSet[string]
foreach ($o in $currentObserved) {
    $oc = [string](Get-Field $o.Doc 'commandFingerprint')
    if ($oc -ne '') { [void]$observedCmdFps.Add($oc) }
}

# ONE-TO-ONE pairing (C3): each guarded result may satisfy AT MOST ONE observed
# run. Exact-runId (runIdControlled) pairings are resolved FIRST so an uncontrolled
# run cannot steal a controlled run's result; the remaining uncontrolled runs then
# each take a DISTINCT result from what is left. Two same-command runs invoked
# directly without -RunId therefore cannot both pair to one green result - the
# second is left unmatched and blocks (its own result is not in yet, or it failed).
$pairedPaths = New-Object System.Collections.Generic.HashSet[string]
$assignedResultPaths = New-Object System.Collections.Generic.HashSet[string]
$sortedObserved = @($currentObserved | Sort-Object `
    @{ Expression = { [string](Get-Field $_.Doc 'observedUtc') } }, `
    @{ Expression = { [string](Get-Field $_.Doc 'runId') } })
$sortedResults = @($resultEntries | Sort-Object `
    @{ Expression = { $t = Get-ResultRecordedTime -Doc $_.Doc -Path $_.Path; if ($null -ne $t) { $t.Ticks } else { [int64]0 } } }, `
    @{ Expression = { [string]$_.Path } })
$obsResultMap = @{}
for ($pass = 0; $pass -lt 2; $pass++) {
    $controlledPass = ($pass -eq 0)
    for ($oi = 0; $oi -lt $sortedObserved.Count; $oi++) {
        if ($obsResultMap.ContainsKey($oi)) { continue }
        $odoc = $sortedObserved[$oi].Doc
        $controlled = ((Get-Field $odoc 'runIdControlled') -eq $true)
        if ($controlled -ne $controlledPass) { continue }
        foreach ($re in $sortedResults) {
            if ($assignedResultPaths.Contains($re.Path)) { continue }
            if (Test-ResultMatchesObserved -Result $re.Doc -Observed $odoc -CurrentStateFingerprint $stateFingerprint) {
                $obsResultMap[$oi] = $re
                [void]$assignedResultPaths.Add($re.Path)
                [void]$pairedPaths.Add($re.Path)
                break
            }
        }
    }
}
$obsPairs = New-Object System.Collections.Generic.List[object]
for ($oi = 0; $oi -lt $sortedObserved.Count; $oi++) {
    $resEntry = if ($obsResultMap.ContainsKey($oi)) { $obsResultMap[$oi] } else { $null }
    [void]$obsPairs.Add([pscustomobject]@{ Observed = $sortedObserved[$oi].Doc; ResEntry = $resEntry })
}

$runs = New-Object System.Collections.Generic.List[object]
# Each current observed run, with its identity-matched result (if any). When none
# matches, a result for the SAME command that is NOT another run's result is
# attached for messaging only, so a genuine identity mismatch reads DIFFERENT run
# while a run that simply has no result of its own reads as missing evidence.
foreach ($op in $obsPairs) {
    $sameCmdEntry = $null
    if ($null -eq $op.ResEntry) {
        $oCmd = [string](Get-Field $op.Observed 'commandFingerprint')
        if ($oCmd -ne '') {
            $sc = @($resultEntries | Where-Object { ([string](Get-Field $_.Doc 'commandFingerprint')) -eq $oCmd -and -not $pairedPaths.Contains($_.Path) })
            if ($sc.Count -gt 0) { $sameCmdEntry = $sc[0] }
        }
    }
    [void]$runs.Add([pscustomobject]@{ Observed = $op.Observed; ResultEntry = $op.ResEntry; SameCmdEntry = $sameCmdEntry; HasObserved = $true; Matches = ($null -ne $op.ResEntry) })
}
# A current-state result with NO observation and whose command matches no observed
# run is an independent run (e.g. a guarded runner invoked directly). A result
# whose command DOES match an observed run is just a different run of that command
# and belongs to that observed run's messaging, not a new run.
foreach ($re in $resultEntries) {
    $rProjFp = [string](Get-Field $re.Doc 'projectFingerprint')
    $isCurrentState = if ($rProjFp -ne '') { $rProjFp -eq $stateFingerprint } else { $true }   # legacy result: no identity, age governs
    if (-not $isCurrentState) { continue }
    $rCmd = [string](Get-Field $re.Doc 'commandFingerprint')
    if ($rCmd -ne '' -and $observedCmdFps.Contains($rCmd)) { continue }
    [void]$runs.Add([pscustomobject]@{ Observed = $null; ResultEntry = $re; SameCmdEntry = $null; HasObserved = $false; Matches = $true })
}

# ---- classify + select the representative (worst) run ----
function Test-ResultFresh {
    param($ResEntry)
    if ($null -eq $ResEntry) { return $false }
    $t = Get-ResultRecordedTime -Doc $ResEntry.Doc -Path $ResEntry.Path
    if ($null -eq $t) { return $false }
    return (([DateTime]::UtcNow - $t).TotalMinutes -lt $script:evidenceMinutes)
}
function Get-RunClass {
    param($Run)
    $re = $Run.ResultEntry
    if ($null -ne $re) {
        $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
        $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($ov -eq 'terminated' -or $lk.Count -gt 0) { return 'incident' }
        if ($ov -eq 'failed' -and (Test-ResultFresh $re)) { return 'failed' }
        if ($ov -eq 'ok' -and (Test-ResultFresh $re) -and $lk.Count -eq 0) { return 'clean' }
        return 'unproven'
    }
    return 'noresult'
}
# A run whose negative finding is ALREADY ACCOUNTED FOR must not be chosen as a
# blocking representative (C4). Accounted for means EITHER its incident note was
# already recorded (its key is in resolvedIncident) OR it is SUPERSEDED by a
# strictly-newer clean ok run for the same command/state. This is what lets a green
# rerun win when an environmental problem is fixed WITHOUT a source change (same
# fingerprint): the old incident no longer outranks the clean rerun, and it breaks
# the deadlock where the terminated run's own case-2/3 block would otherwise fire
# before case 6 could ever process the durable note. A genuinely unresolved,
# un-superseded incident is NOT excluded and still blocks; the durable-note
# obligation registered on the first block still stands (case 6 enforces it once
# the run stops outranking everything else).
function Test-RunNegativeAccounted {
    param($Run, [string]$ResolvedIncident, $AllResults)
    if ($null -eq $Run.ResultEntry) { return $false }
    $doc = $Run.ResultEntry.Doc
    $path = $Run.ResultEntry.Path
    $ik = Get-ResultIncidentKey -Doc $doc -Path $path
    if ($ik -ne '' -and $ik -eq $ResolvedIncident) { return $true }
    return (Test-ResultSuperseded -NegDoc $doc -NegTime (Get-ResultRecordedTime -Doc $doc -Path $path) -AllResults $AllResults)
}
$classified = @($runs | ForEach-Object { [pscustomobject]@{ Run = $_; Class = (Get-RunClass $_) } })
$rep = $null
foreach ($wanted in @('incident', 'failed')) {
    $m = @($classified | Where-Object { $_.Class -eq $wanted -and -not (Test-RunNegativeAccounted -Run $_.Run -ResolvedIncident $resolvedIncident -AllResults $resultEntries) })
    if ($m.Count -gt 0) { $rep = $m[0]; break }
}
if ($null -eq $rep) {
    $m = @($classified | Where-Object { $_.Run.HasObserved -and $_.Class -ne 'clean' -and -not (Test-RunNegativeAccounted -Run $_.Run -ResolvedIncident $resolvedIncident -AllResults $resultEntries) })   # condition 5: observed, not satisfied
    if ($m.Count -gt 0) { $rep = $m[0] }
}
if ($null -eq $rep) {
    $m = @($classified | Where-Object { $_.Class -eq 'clean' })
    if ($m.Count -gt 0) { $rep = $m[0] }
}
if ($null -eq $rep -and $classified.Count -gt 0) { $rep = $classified[0] }

# ---- project the representative onto the single-run variables ----
$result = $null
$resultEntry = $null
$observed = $null
$observedGuarded = $true
$resultRunMatches = $false
if ($null -ne $rep) {
    $observed = $rep.Run.Observed
    if ($null -ne $observed -and (Get-Field $observed 'guarded') -eq $false) { $observedGuarded = $false }
    if ($null -ne $rep.Run.ResultEntry) {
        $resultEntry = $rep.Run.ResultEntry
        $result = $resultEntry.Doc
        $resultRunMatches = $rep.Run.Matches
    }
    elseif ($null -ne $rep.Run.SameCmdEntry) {
        # A DIFFERENT run's result for this command - carried for messaging only.
        $resultEntry = $rep.Run.SameCmdEntry
        $result = $resultEntry.Doc
        $resultRunMatches = $false
    }
}

$resultTime = $null
$overall = ''
$terminateReason = ''
$terminateDetail = ''
$leaked = @()
$elapsedSeconds = 0.0
$lastProgress = ''
if ($null -ne $result) {
    $overall = ([string](Get-Field $result 'overall')).ToLowerInvariant()
    $terminateReason = [string](Get-Field $result 'terminateReason')
    $terminateDetail = [string](Get-Field $result 'terminateDetail')
    $leaked = @(@(Get-Field $result 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    try { $elapsedSeconds = [double](Get-Field $result 'elapsedSeconds') } catch { $elapsedSeconds = 0.0 }
    $lastProgress = [string](Get-Field $result 'lastProgress')
    $resultEntryPath = if ($null -ne $resultEntry) { $resultEntry.Path } else { '' }
    $resultTime = Get-ResultRecordedTime -Doc $result -Path $resultEntryPath
}
$resultIsCurrent = ($null -ne $resultTime -and ([DateTime]::UtcNow - $resultTime).TotalMinutes -lt $evidenceMinutes)
# Stable, locale-independent identity for the run this result describes.
$script:ResultTicks = if ($null -ne $resultTime) { [string]$resultTime.Ticks } else { '0' }
$resultIsCurrentEvidence = ($resultRunMatches -and $resultIsCurrent)

# ---- incident identity ----
# Keyed on what actually happened, so re-reading the same document never
# re-opens a resolved incident and a NEW run always produces a new key.
$incidentKey = ''
$incidentReason = ''
if ($null -ne $result) {
    if ($overall -eq 'terminated') {
        $incidentReason = 'the guarded run was TERMINATED (' +
            $(if ($terminateReason -ne '') { $terminateReason } else { 'unknown reason' }) + ')' +
            $(if ($terminateDetail -ne '') { ': ' + $terminateDetail } else { '' })
    }
    elseif ($leaked.Count -gt 0) {
        $incidentReason = 'the guarded run LEAKED process(es) ' + (@($leaked) -join ', ') + ' that survived termination'
    }
    if ($incidentReason -ne '') {
        # Identity uses normalised UTC TICKS, never a culture-formatted date
        # string: the key must be byte-identical across hosts and locales or a
        # resolved incident would silently re-open on the next event.
        $incidentKey = Get-ShortHash (
            $script:ResultTicks + '|' + $overall + '|' + $terminateReason + '|' + (@($leaked) -join ','))
    }
}

# Nothing recorded at all for this project - no relevant test work. Silence.
if ($null -eq $result -and -not $observedCurrent -and $activePid -eq 0 -and $pendingNoteKey -eq '') {
    exit 0
}
# A recorded incident that was already resolved, no pending note, nothing
# current to prove, nothing running: also silence.
if ($incidentKey -ne '' -and $incidentKey -eq $resolvedIncident -and $pendingNoteKey -eq '' -and
    -not $observedCurrent -and $activePid -eq 0) {
    exit 0
}

# ---- Test-Temp-Cleanup coordination: defer ONCE, never loop ---------------
# Only relevant when Test-Temp-Cleanup is actually installed for this project
# (same detection Cloudflare-Deploy uses). A same-Stop race is resolved by
# deferring to the NEXT event; a producer that never records cannot silence
# this gate beyond that single deferral.
$cleanupInstalled = (Test-Path -LiteralPath (Join-Path $cwd '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -PathType Container) -or
    (Test-Path -LiteralPath (Join-Path $cwd '.codex\hooks\Hook-Maker\Test-Temp-Cleanup') -PathType Container)
if ($cleanupInstalled) {
    $cleanupCurrent = $false
    $deadline = [DateTime]::UtcNow.AddSeconds($coordinationWaitSeconds)
    while ($true) {
        $cleanupRecord = $null
        try { $cleanupRecord = Read-JsonFile $cleanupPath } catch { $cleanupRecord = $null }
        if ($null -ne $cleanupRecord -and [string](Get-Field $cleanupRecord 'fingerprint') -eq $stateFingerprint) {
            $cleanupCurrent = $true
            break
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $cleanupCurrent -and $deferredFingerprint -ne $stateFingerprint) {
        # First same-state race: hand the event back and re-evaluate next time.
        Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey $pendingNoteKey `
            -NoteReason $pendingNoteReason -NoteBaseline $pendingNoteBaseline -Deferred $stateFingerprint
        exit 0
    }
}

# ---- 1. a guarded run is still active -------------------------------------
if ($activePid -gt 0) {
    Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey $pendingNoteKey `
        -NoteReason $pendingNoteReason -NoteBaseline $pendingNoteBaseline -Deferred $deferredFingerprint
    Write-Finding -Blocking $true -Lines @(
        'TEST COMPLETION CHECK: a guarded test run is STILL ACTIVE (owner process ' + $activePid + ' is alive). The work cannot be complete while its result is unknown.',
        'Recovery: wait for that run to finish and read its result document, or stop it deliberately with the guarded runner and record how it ended. Do not declare the task complete, and do not claim any test outcome until the run has actually ended.')
}

# ---- 2/3. a terminated or leaking run -------------------------------------
# Gated on identity, not age: an incident from a DIFFERENT run/state is not this
# run's problem and must not block the current state; a real incident for THIS
# run still blocks however old its file is.
if ($incidentKey -ne '' -and $incidentKey -ne $resolvedIncident -and $resultRunMatches) {
    # Register the owed durable note and capture the byte baseline the note
    # will be measured against, so a bare "done" cannot satisfy it later.
    if ($pendingNoteKey -ne $incidentKey) {
        $pendingNoteKey = $incidentKey
        $pendingNoteReason = $incidentReason
        $pendingNoteBaseline = Get-NoteBytes -Root $cwd
    }
    Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey $pendingNoteKey `
        -NoteReason $pendingNoteReason -NoteBaseline $pendingNoteBaseline -Deferred $deferredFingerprint
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('TEST COMPLETION CHECK: ' + $incidentReason + '. This is a confirmed finding from the guarded runner''s own result document, not an inference.')
    if ($elapsedSeconds -gt 0) { [void]$lines.Add('It ran for ' + $elapsedSeconds + 's before ending.') }
    if ($lastProgress -ne '') { [void]$lines.Add('Last recorded progress: ' + $lastProgress) }
    if ($leaked.Count -gt 0) {
        [void]$lines.Add('Recovery: confirm process(es) ' + (@($leaked) -join ', ') + ' are gone (Get-Process -Id <id>), terminate the surviving tree if not, then re-run the suite through scripts\Run-Tests-Guarded.ps1 and confirm the new result reports overall=ok with an empty leakedProcessIds.')
    }
    else {
        [void]$lines.Add('Recovery: fix the cause of the ' + $(if ($terminateReason -ne '') { $terminateReason } else { 'termination' }) + ' - do not simply raise the ceiling to hide it - then re-run the suite through scripts\Run-Tests-Guarded.ps1 and confirm the new result reports overall=ok.')
    }
    [void]$lines.Add('Then record a durable note in .ai/ (BUGS.md, TESTING_NOTES.md, COMMANDS.md and/or LESSON.md as appropriate) covering WHY this was not detected earlier and the verified prevention/recovery guard. A bare acknowledgement is not a note.')
    [void]$lines.Add('Report only what the evidence shows: this hook has seen one guarded run for this project and cannot confirm any broader test scope passed.')
    Write-Finding -Blocking $true -Lines $lines.ToArray()
}

# ---- 4. the run completed but failed --------------------------------------
if ($null -ne $result -and $overall -eq 'failed' -and $resultIsCurrentEvidence) {
    Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey $pendingNoteKey `
        -NoteReason $pendingNoteReason -NoteBaseline $pendingNoteBaseline -Deferred $deferredFingerprint
    $exitCode = [string](Get-Field $result 'exitCode')
    Write-Finding -Blocking $true -Lines @(
        'TEST COMPLETION CHECK: the latest guarded test run for this project FAILED (exit code ' + $exitCode + '). The work is not verifiably complete.',
        $(if ($lastProgress -ne '') { 'Last recorded progress: ' + $lastProgress } else { 'The result document records no final progress line.' }),
        'Recovery: inspect the actual failure, fix the root cause, and re-run the suite through scripts\Run-Tests-Guarded.ps1 until the result reports overall=ok. Do not weaken, skip, or delete tests to make it pass, and do not claim tests passed while this result stands.')
}

# ---- 5. a test ran but there is no current proof of how it ended ----------
if ($observedCurrent -and -not ($resultIsCurrentEvidence -and $overall -eq 'ok')) {
    Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey $pendingNoteKey `
        -NoteReason $pendingNoteReason -NoteBaseline $pendingNoteBaseline -Deferred $deferredFingerprint
    $why = if ($null -eq $result) {
        'no guarded result document exists for it'
    }
    elseif (-not $resultRunMatches) {
        'the only guarded result on record is for a DIFFERENT run, command, or repository state (its run identity does not match this observation) and says nothing about how THIS run ended'
    }
    elseif (-not $resultIsCurrent) {
        'the only guarded result on record is STALE (older than ' + $evidenceMinutes + ' minutes) and is not proof that a run happened for the current state'
    }
    else {
        'the current guarded result reports overall=' + $(if ($overall -ne '') { $overall } else { 'unknown' }) + ' rather than a clean completion'
    }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('TEST COMPLETION CHECK: a test command was observed for the CURRENT project state, but ' + $why + '. Completion cannot be claimed on evidence that does not exist.')
    if (-not $observedGuarded) {
        [void]$lines.Add('That command was recorded as running UNGUARDED, so nothing owned it, bounded it, or proved how it ended.')
    }
    [void]$lines.Add('Recovery: re-run the suite through scripts\Run-Tests-Guarded.ps1 with a bounded wall and idle timeout, then confirm the result document reports overall=ok with an empty leakedProcessIds. State the actual scope you verified - never that "all tests passed".')
    Write-Finding -Blocking $true -Lines $lines.ToArray()
}

# ---- clean, current result -------------------------------------------------
# From here the run itself is accounted for. Mark the incident resolved and,
# when configured, register the always-on note requirement.
if ($null -ne $result -and $resultIsCurrentEvidence -and $overall -eq 'ok') {
    if ($incidentKey -ne '') { $resolvedIncident = $incidentKey }
    if ($alwaysRequireNote -and $pendingNoteKey -eq '') {
        $runKey = Get-ShortHash ('run|' + $script:ResultTicks + '|' + $projectKey)
        if ($runKey -ne $resolvedIncident) {
            $pendingNoteKey = $runKey
            $pendingNoteReason = 'a guarded test run completed and TEST_COMPLETION_ALWAYS_REQUIRE_NOTE is enabled'
            $pendingNoteBaseline = Get-NoteBytes -Root $cwd
        }
    }
}

# ---- 6. the durable note that is still owed --------------------------------
if ($pendingNoteKey -ne '') {
    $grown = 0L
    if ($pendingNoteBaseline -ge 0) { $grown = (Get-NoteBytes -Root $cwd) - $pendingNoteBaseline }
    if ($grown -ge $script:MinNoteBytes) {
        # Satisfied: the incident and its note are both closed out.
        Save-CompletionState -ResolvedIncident $pendingNoteKey -NoteKey '' -NoteReason '' `
            -NoteBaseline ([int64](-1)) -Deferred $deferredFingerprint
        exit 0
    }
    Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey $pendingNoteKey `
        -NoteReason $pendingNoteReason -NoteBaseline $pendingNoteBaseline -Deferred $deferredFingerprint
    Write-Finding -Blocking $true -Lines @(
        'TEST COMPLETION CHECK: a durable .ai/ note is still owed because ' + $pendingNoteReason + '.',
        'Write it into .ai/BUGS.md, .ai/TESTING_NOTES.md, .ai/COMMANDS.md and/or .ai/LESSON.md, whichever fits. It must state WHY the problem was not detected earlier and the verified prevention/recovery guard that now catches it - concretely enough that a later session can act on it.',
        'A bare acknowledgement ("done", "n/a", "fixed") does not satisfy this and will not clear it; the check looks for real added content in those files.')
}

# Everything accounted for: silent.
Save-CompletionState -ResolvedIncident $resolvedIncident -NoteKey '' -NoteReason '' `
    -NoteBaseline ([int64](-1)) -Deferred $deferredFingerprint
exit 0
