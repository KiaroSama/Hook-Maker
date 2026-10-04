# Test-Completion-Check - the AFTER stage of the three-stage test-health
# architecture (global-test-rules.md SS Three-Stage Test Enforcement /
# global-hook-rules.md SS Test Hook Architecture).
#
# ROLE: GATE, plus an explicit recovery EXECUTOR (global-hook-rules.md SS Hook Roles).
#   Events: Stop, SubagentStop.
#   It blocks completion ONLY on a CONFIRMED, CURRENT-state condition, and it
#   never runs a test, never spawns a process, and never edits project files. Its own
#   state lives under %LOCALAPPDATA%\HookMaker\state - never in the project.
#   -ResolveIncident/-RecoveryRunId/-ProjectRoot/-Reason associates one verified
#   newer clean same-project receipt with a substantively documented incident.
#   The ledger pins both receipt hashes, identities, scope/repair reason and UTC
#   time under its bounded mutex; note-only, unrelated and still-active work do
#   not resolve. Historical associations never certify today's product state.
#
# THE RECURSION GUARD COMES FIRST, and it is THIS hook's own block marker, not
# the shared `stop_hook_active` flag: that flag is set for any gate's block, so
# keying on it makes one gate silence the rest. Standing down on its own
# re-entry bounds this gate at one block per session - a gate that can refuse
# completion on every Stop for ever is a hang, not a check.
#
# WHAT IT BLOCKS ON (each one confirmed from recorded evidence, never inferred):
#   1. a guarded run is STILL ACTIVE (the recorded owner process - pid AND its
#      recorded start time, never the pid alone - is the one running now);
#  1b. a guarded run DIED without recording how it ended: its owner is gone and
#      no result document exists, so the outcome is unknown and unrecoverable;
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
#                                           ownerExecutablePath, markerCreatedUtc,
#                                           ... } while THAT run holds a live child.
#                                           LIVENESS NEEDS THE WHOLE IDENTITY: pids
#                                           are recycled, so a marker is 'live' only
#                                           when the process at ownerPid still has
#                                           the recorded start time (and executable).
#                                           There is NO pid-only fallback - a marker
#                                           that cannot be pinned is not a live run.
#                                           An unpinnable/dead owner with a result on
#                                           record is leftover; with none it DIED
#                                           (blocks, case 1b) until its note clears
#                                           it, or - past
#                                           TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS -
#                                           it is an earlier session's record, which
#                                           is reconciled into the ledger and dropped
#                                           rather than blocking this task forever.
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
# ::DEEP-DEBUG SESSION GATE (E-05). When the ::deep-debug workflow is ACTIVE
# for the current session, this hook's output additionally carries the exact
# workflow verdict lines `DEEP DEBUG: COMPLETE` or `DEEP DEBUG: BLOCKED
# (reason)`, judged ONLY from the fresh, scoped, fingerprinted evidence this
# hook already aggregates (guarded-run results, the incident-note ledger,
# active/cleanup state). Free-form "done" text is never proof, and points with
# no machine evidence here (the goal ledger receipt, workstream integration, code/
# security review, the single Ponytail pass, UTF-8 file validation, Git/exact-
# SHA CI) are reported honestly as not verifiable by this hook - they belong to
# their own gates.
#   Activation requires a parsed Claude user message or Codex user event/message
#   whose text starts with the explicit command ::deep-debug. Quoted examples,
#   instructions, annotations, assistant/tool/hook records and arbitrary Stop
#   prompt fields cannot activate it. The transcript read is bounded to 64KB;
#   incomplete/malformed records are ignored, and transcript text is never stored.
#   Schema-2 markers retain validated intent for the same session after the
#   command leaves the tail. Schema-1 markers lack provenance: preserved but
#   inactive until a real command validates them (original marker retained).
#   This hook never executes a codeword, slash
#   command, skill, or discovered hook. Anti-loop: the dd-specific outputs
#   (COMPLETE advisory / no-evidence BLOCKED) are emitted once per session per
#   unchanged state; the pre-existing condition-1..6 blocks keep their own
#   established repeat behavior and merely carry the extra BLOCKED line.
#
# Optional .env next to this script (copy .env.example):
#   TEST_COMPLETION_EVIDENCE_MINUTES           minutes a result stays current (default 180)
#   TEST_COMPLETION_ADVISORY_ONLY              1 = report, never block (default 0)
#   TEST_COMPLETION_ALWAYS_REQUIRE_NOTE        1 = a note after every run (default 0)
#   TEST_COMPLETION_COORDINATION_WAIT_SECONDS  bounded same-Stop wait (default 2)
#   TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS    hours an ownerless, result-less active
#                                              record can still describe this task
#                                              before it is expired (default 12)
# An invalid value is reported in plain text with the output it is attached to
# and the fallback is applied so it can only ever NARROW what is blocked on -
# never widen it. A malformed setting must not turn this gate into a nag.

param([string]$ResolveIncident = '', [string]$RecoveryRunId = '', [string]$ProjectRoot = '', [string]$Reason = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$recoveryMode = ($ResolveIncident -ne '' -or $RecoveryRunId -ne '' -or $ProjectRoot -ne '' -or $Reason -ne '')
if ($recoveryMode) {
    if ($ResolveIncident -notmatch '^[a-f0-9]{10}$' -or $RecoveryRunId -notmatch '^[A-Za-z0-9._-]{1,128}$' -or [string]::IsNullOrWhiteSpace($ProjectRoot) -or [System.Text.Encoding]::UTF8.GetByteCount($Reason.Trim()) -lt 80) {
        throw 'Recovery requires -ResolveIncident <incident key>, -RecoveryRunId <verified run id>, -ProjectRoot, and a substantive -Reason of at least 80 UTF-8 bytes describing the equivalent test scope and verified repair.'
    }
    $ResolveIncident = $ResolveIncident.ToLowerInvariant()
    $hookInput = [pscustomobject]@{ hook_event_name = 'Stop'; cwd = $ProjectRoot; session_id = '' }
}
else { $hookInput = Read-HookInput }
if ($null -eq $hookInput) { exit 0 }; $gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Test-Completion-Check' } else { $null }; try {

# ---- recursion guard: FIRST, before anything is read or evaluated ----
# Stand down only on THIS hook's OWN re-entry. `stop_hook_active` is set for
# ANY gate's block, so exiting on it alone let one gate silence the other
# twelve on the same Stop - and leaving it UNGUARDED, as this hook was, means
# blocking on every Stop for ever with no per-session bound. Neither is right:
# the marker written immediately before this gate blocks is the correct key.
if (-not $recoveryMode -and (Test-StopStandDown -HookInput $hookInput -HookName 'Test-Completion-Check')) { exit 0 }

$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    if ($recoveryMode) { throw 'The recovery project directory does not exist.' }
    exit 0
}

. (Join-Path $PSScriptRoot '_config.ps1')

# ---- paths ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
# Normalize-Path is load-bearing, not decoration, and this key names THREE
# things: Test-Temp-Cleanup's coordination record (read below), this hook's own
# incident ledger, and its deep-debug marker.
#
# The producer of the cleanup record hashes Normalize-Path($cwd) (see
# Test-Temp-Cleanup.ps1's $projectRoot), while ToLowerInvariant alone folds case
# only. A cwd carrying a trailing separator or a '.'/'..' segment therefore
# hashed to a key the producer never writes - so the cleanup record read as
# ABSENT, and, worse, THIS hook's own ledger split across two keys for one
# project, which can drop a pending note obligation the ledger exists to hold.
# Both sides of a shared-state contract must canonicalize with the same helper
# or the state is only nominally shared. $cwd is already proven non-empty and an
# existing directory by the guard above, so Normalize-Path cannot throw here.
$projectKey = Get-ShortHash (Normalize-Path $cwd).ToLowerInvariant()
# result/observed/active are PER-RUN now (TestRunGuard-<kind>-<key>-<runId>.json)
# and are enumerated + aggregated below, never read from one fixed path.
$cleanupPath = Join-Path $stateDir ('TestTempCleanup-result-' + $projectKey + '.json')
$statePath = Join-Path $stateDir ('TestCompletionCheck-' + $projectKey + '.json')
$ddMarkerPath = Join-Path $stateDir ('TestCompletionCheck-deepdebug-' + $projectKey + '.json')
$ddGatePath = Join-Path $stateDir ('TestCompletionCheck-ddgate-' + $projectKey + '.txt')
$sessionId = [string](Get-Field $hookInput 'session_id')

# ---- Explicit user-command activation; transcript data never executes. ----
. (Join-Path $PSScriptRoot '_deepdebug.ps1')
Initialize-DeepDebugActivation

# The durable-note and incident-tag helpers: a REQUIRED sibling (the gate cannot
# decide a note obligation without them).
. (Join-Path $PSScriptRoot '_notes.ps1')


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

# ---- this hook's own state: the per-incident LEDGER ------------------------
. (Join-Path $PSScriptRoot '_ledger.ps1')

. (Join-Path $PSScriptRoot '_output.ps1')

# ---- read the recorded evidence (AGGREGATED across per-run files) ----------
. (Join-Path $PSScriptRoot '_evidence.ps1')
. (Join-Path $PSScriptRoot '_recovery.ps1')
. (Join-Path $PSScriptRoot '_noteobligations.ps1')
. (Join-Path $PSScriptRoot '_failedrun.ps1')
# Possible orphaned test processes: ADVISORY ONLY, never a block, never a kill.
# Write-SurvivorAdvisory is called ONLY where this hook is about to go silent,
# so it can never pre-empt a gate: every block below still speaks first.
. (Join-Path $PSScriptRoot '_survivors.ps1')

# Explicit recovery is a narrowly scoped executor. It validates and records an
# association before the ordinary gate/prune paths, preserving historical receipts.
if ($recoveryMode) {
    Save-CompletionState -ResolveIncidentKey $ResolveIncident -RecoveryRunId $RecoveryRunId -RecoveryReason $Reason
    $saved = Read-JsonFile $statePath
    $savedAssociation = @(@(Get-Field $saved 'recoveryAssociations') | Where-Object { [string](Get-Field $_ 'incidentKey') -eq $ResolveIncident -and [string](Get-Field $_ 'recoveryRunId') -eq $RecoveryRunId })
    if ($savedAssociation.Count -ne 1 -or -not (@(Get-Field $saved 'resolvedIncidents') -contains $ResolveIncident)) { throw 'The verified recovery association was not persisted.' }
    [Console]::Out.WriteLine('Recovery association recorded for incident ' + $ResolveIncident + '. Current-run evidence checks remain independent.')
    exit 0
}

# The evidence is loaded BEFORE pruning so pruning can read each file's content.
$resultEntries = Get-CompletionStateEntries 'result'
$observedEntries = Get-CompletionStateEntries 'observed'
$activeEntries = Get-CompletionStateEntries 'active'
# Reconcile before pruning can remove the only original receipt.
if ($script:pendingNotes.Count -gt 0) { Save-CompletionState }

. (Join-Path $PSScriptRoot '_pruning.ps1')

# ---- 1. classify every active marker across all runs ----
# Four outcomes, each acted on differently (Get-ActiveMarkerState is the
# authority on how they are told apart):
#   live      -> $activePid. A marker whose owner PROCESS is genuinely alive is
#                NEVER removed (C1) - not on a fingerprint change, not because
#                another run finished: a running test blocks completion whatever
#                the working tree now looks like.
#   finished  -> the run recorded a result; the marker is leftover, drop it and
#                let the normal result path judge the outcome.
#   died      -> the owner is gone and NOTHING recorded how the run ended. The
#                marker is KEPT (it is the evidence) and blocks at 1b below, once
#                its owed durable note has not already resolved it.
#   expired   -> the same, but past the abandoned-record horizon, so it cannot
#                describe this task. Reconciled into the ledger - a trace, never
#                a silent delete - and dropped so it can never block forever.
$activePid = 0
$abandonedRuns = New-Object System.Collections.Generic.List[object]
foreach ($ae in $activeEntries) {
    $ms = Get-ActiveMarkerState -Doc $ae.Doc -Path $ae.Path -MaxAgeHours $activeMarkerMaxHours -ResultEntries $resultEntries
    if ($ms.State -eq 'live') {
        if ($activePid -eq 0) { $activePid = $ms.OwnerPid }
        continue
    }
    if ($ms.State -eq 'died') {
        # Its durable note is the real resolution (the marker file is only the
        # blunt one), so honour a satisfied note here exactly as case 6 does -
        # otherwise 1b would preempt case 6 forever and the note could never clear.
        $ak = Get-AbandonedIncidentKey -Doc $ae.Doc
        if (Test-PendingNoteSatisfied -Key $ak) { Add-ResolvedIncident $ak }
        if (-not (Test-IncidentResolved $ak)) {
            [void]$abandonedRuns.Add([pscustomobject]@{ Key = $ak; RunId = $ms.RunId; Detail = $ms.Detail; Path = $ae.Path })
            continue
        }
    }
    if ($ms.State -eq 'expired') {
        Add-ExpiredMarker -RunId $ms.RunId -Detail $ms.Detail
        [void]$script:expiredNow.Add($(if ($ms.RunId -ne '') { 'run id ' + $ms.RunId } else { 'a record with no run id' }) + ' (' + $ms.Detail + ')')
    }
    try { Remove-Item -LiteralPath $ae.Path -Force -ErrorAction SilentlyContinue } catch { }
}

# Persist the reconciliation NOW. Several paths below exit silently (no test work
# recorded, an already-resolved incident, the cleanup deferral), and the trace of
# an expired abandoned record has to survive every one of them - a record dropped
# with no trace is the exact blind spot this classification exists to close.
if ($script:expiredNow.Count -gt 0) { Save-CompletionState }

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
# Shared with the D3 prune pre-pass via Get-ObservedResultAssignment.
$mainAssign = Get-ObservedResultAssignment -CurrentObserved $currentObserved -ResultEntries $resultEntries -StateFp $stateFingerprint
$sortedObserved = $mainAssign.SortedObserved
$obsResultMap = $mainAssign.Map
$pairedPaths = $mainAssign.AssignedPaths
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
    $isCurrentState = if ($rProjFp -ne '') { $rProjFp -eq $stateFingerprint } else { $ended = ConvertTo-UtcStamp (Get-Field $re.Doc 'endedUtc'); ($null -ne $ended -and ([DateTime]::UtcNow - $ended).TotalHours -le 24) }   # legacy result: no identity, so the 24 h horizon governs
    if (-not $isCurrentState) { continue }
    $rCmd = [string](Get-Field $re.Doc 'commandFingerprint')
    if ($rCmd -ne '' -and $observedCmdFps.Contains($rCmd)) { continue }
    [void]$runs.Add([pscustomobject]@{ Observed = $null; ResultEntry = $re; SameCmdEntry = $null; HasObserved = $false; Matches = $true })
}

# ---- classify + select the representative (worst) run: _runclassify.ps1 (REQUIRED) ----
. (Join-Path $PSScriptRoot '_runclassify.ps1')
$selection = Select-RepresentativeRun -Runs $runs
$classified = $selection.Classified; $rep = $selection.Rep

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

# ---- HM-07: meaningful timing regression (advisory) ------------------------
# Compared against the ROBUST median of PRIOR clean runs at the same worker
# ceiling (this run's own just-recorded sample is excluded by runId, and a
# different worker count is not comparable). Advisory by design: it is surfaced
# only on an otherwise-silent tail, so a real block always wins, and it never
# blocks completion by itself.
$timingRegressionLines = @()
if ($null -ne $result -and $elapsedSeconds -gt 0) {
    $tKey = [string](Get-Field $result 'projectKey')
    $tCmd = [string](Get-Field $result 'commandFingerprint')
    $tRun = [string](Get-Field $result 'runId')
    $tWc = -1; [void][int]::TryParse([string](Get-Field $result 'workerBudget'), [ref]$tWc)
    if ($tKey -ne '' -and $tCmd -ne '') {
        $tHist = $null
        try { $tHist = Read-JsonFile (Get-TimingHistoryPath -StateDir $stateDir -ProjectKey $tKey -CommandFingerprint $tCmd) } catch { $tHist = $null }
        $reg = Test-TimingRegression -History $tHist -WorkerCeiling $tWc -ElapsedSeconds $elapsedSeconds -ExcludeRunId $tRun
        if ($reg.IsRegression) {
            $timingRegressionLines = @(
                'TEST COMPLETION CHECK (advisory): this guarded run took ' + $reg.ElapsedSeconds + 's, vs a median of ' +
                $reg.Median + 's over ' + $reg.Samples + ' prior clean runs at the same worker ceiling (' + $tWc + '). That is a ' +
                'meaningful slowdown - investigate a real regression (a new blind wait, added work, resource pressure) before ' +
                'accepting it. Advisory only: it does not by itself block completion.')
        }
    }
}

# ---- incident identity ----
# Keyed on what actually happened, so re-reading the same document never
# re-opens a resolved incident and a NEW run always produces a new key.
$incidentKey = ''
$incidentKeyLegacy = ''
$incidentReason = ''
if ($null -ne $result) {
    $incidentReason = Get-IncidentReasonFromDoc $result
    if ($incidentReason -ne '') {
        $incidentKey = Get-ResultIncidentKey -Doc $result -Path $resultEntryPath
        $incidentKeyLegacy = Get-ResultIncidentKeyLegacy -Doc $result -Path $resultEntryPath
    }
}

# Is the REPRESENTATIVE run's negative finding already accounted for (superseded
# by a clean rerun, or resolved)? An accounted rep must NOT block via the
# result-level cases 2/3/4/5 - a green rerun WON. Its note obligation (registered
# on first sighting) is still enforced by case 6. Without this guard, a superseded
# incident picked as the fallback representative would re-block forever (the D1/D2
# ping-pong the ledger and this guard together close).
$repAccounted = $false
if ($null -ne $rep -and $null -ne $rep.Run.ResultEntry) {
    $repAccounted = (Test-RunNegativeAccounted -Run $rep.Run -AllResults $resultEntries)
}

# Nothing recorded at all for this project - no relevant test work. Silence -
# UNLESS ::deep-debug is active for this session: the workflow's completion
# gate REQUIRES fresh guarded evidence, so its total absence is itself a
# blocked state (once per session per unchanged state - anti-loop).
if ($null -eq $result -and -not $observedCurrent -and $activePid -eq 0 -and $abandonedRuns.Count -eq 0 -and $script:pendingNotes.Count -eq 0) {
    if ($script:DeepDebugActive -and (Test-DdGateShouldReport ('noevidence|' + $stateFingerprint))) {
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: ::deep-debug is active for this session but NO guarded test evidence exists for the current project state - no observed run, no guarded result, nothing active.',
            'The deep-debug completion gate consumes only fresh scoped evidence: run the affected suites through scripts\Run-Tests-Guarded.ps1 (the Test-Run-Guard gate supplies the exact bounded command) so a verifiable result document exists, then finish.')
    }
    Write-UnknownNoteDiagnostic
    Write-SurvivorAdvisory
    exit 0
}
# A recorded incident that was already resolved, no pending note, nothing
# current to prove, nothing running: also silence. Under an active ::deep-debug
# session this still lacks CURRENT clean evidence, so it is the same blocked
# no-evidence state (its own once-per-session token).
if ($incidentKey -ne '' -and (Test-AnyIncidentResolved $incidentKey $incidentKeyLegacy) -and $script:pendingNotes.Count -eq 0 -and
    -not $observedCurrent -and $activePid -eq 0 -and $abandonedRuns.Count -eq 0) {
    if ($script:DeepDebugActive -and (Test-DdGateShouldReport ('resolvedonly|' + $stateFingerprint))) {
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: ::deep-debug is active for this session, and while a past incident is resolved, no CURRENT-state guarded test evidence exists.',
            'Run the affected suites through scripts\Run-Tests-Guarded.ps1 so a fresh clean result document exists for the current project state, then finish.')
    }
    Write-UnknownNoteDiagnostic
    Write-SurvivorAdvisory
    exit 0
}

# ---- Test-Temp-Cleanup coordination: defer ONCE, never loop ---------------
# Only relevant when Test-Temp-Cleanup is actually installed for this project
# (same detection Cloudflare-Deploy uses). A same-Stop race is resolved by
# deferring to the NEXT event; a producer that never records cannot silence
# this gate beyond that single deferral.
$cleanupInstalled = (Test-Path -LiteralPath (Join-Path $cwd '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -PathType Container) -or (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -PathType Container) -or
    (Test-Path -LiteralPath (Join-Path $cwd '.codex\hooks\Hook-Maker\Test-Temp-Cleanup') -PathType Container) -or (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex\hooks\Hook-Maker\Test-Temp-Cleanup') -PathType Container)
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
        Save-CompletionState -Deferred $stateFingerprint
        exit 0
    }
}

# ---- 1. a guarded run is still active -------------------------------------
if ($activePid -gt 0) {
    Save-CompletionState
    Write-Finding -Blocking $true -Lines @(
        'TEST COMPLETION CHECK: a guarded test run is STILL ACTIVE (owner process ' + $activePid + ' is alive). The work cannot be complete while its result is unknown.',
        'Recovery: wait for that run to finish and read its result document, or stop it deliberately with the guarded runner and record how it ended. Do not declare the task complete, and do not claim any test outcome until the run has actually ended.')
}

# ---- 1b. a guarded run DIED without recording how it ended (OWNERLESS) -----
# The owner process is gone (or, when it cannot be proven to be the recorded one,
# is not this run's owner at all) and no result document was ever written. The
# runner writes a terminal result in `finally` on every path it can intercept, so
# this state means the process was terminated outright - a stuck run that was
# killed, a torn-down session, a machine that went down mid-suite. The outcome is
# not merely unknown, it is unrecoverable: nothing will ever produce it. That is a
# genuine finding, not an absence of one, and it is exactly the ownerless leftover
# that used to be deleted in silence (or, worse, read as a LIVE run once its pid
# was recycled). It fails closed and names both ways out.
if ($abandonedRuns.Count -gt 0) {
    $ab = $abandonedRuns[0]
    Register-PendingNote -Key $ab.Key -Reason ('a guarded test run (' + $(if ($ab.RunId -ne '') { 'run id ' + $ab.RunId } else { 'no recorded run id' }) + ') died without recording how it ended') -Origin (New-NoteOrigin -Kind ownerless -Path $ab.Path)
    Save-CompletionState
    Write-Finding -Blocking $true -Lines @(
        'TEST COMPLETION CHECK: a guarded test run DIED without recording how it ended - it is OWNERLESS. ' +
            $(if ($abandonedRuns.Count -gt 1) { 'There are ' + $abandonedRuns.Count + ' such runs; the first is reported here. ' } else { '' }) +
            'Evidence: ' + $ab.Detail + ', and no guarded result document exists for ' + $(if ($ab.RunId -ne '') { 'run id ' + $ab.RunId } else { 'this marker' }) + '.',
        'Its result is UNKNOWN AND UNRECOVERABLE: the guarded runner records a terminal result on every exit path it can intercept, so nothing was recorded means the process was killed outright, and no later run will ever fill that gap. Do not treat it as a pass, and do not claim any test outcome from it.',
        'Recovery: re-run the affected suite through scripts\Run-Tests-Guarded.ps1 so a real result document exists, then record a durable note in .ai/ (BUGS.md, TESTING_NOTES.md, COMMANDS.md and/or LESSON.md) covering what killed the run, why nothing detected it at the time, and the verified guard that now catches it.',
        'Tag that note with a line `' + (Get-IncidentTag $ab.Key) + '` (exactly) to clear THIS incident; a bare acknowledgement will not.',
        'If the run genuinely belonged to abandoned work and there is nothing to learn from it, delete its record instead - the exact file is: ' + $ab.Path)
}

# ---- 2/3. a terminated or leaking run -------------------------------------
# Gated on identity, not age: an incident from a DIFFERENT run/state is not this
# run's problem and must not block the current state; a real incident for THIS
# run still blocks however old its file is.
if ($incidentKey -ne '' -and -not (Test-AnyIncidentResolved $incidentKey $incidentKeyLegacy) -and $resultRunMatches -and -not $repAccounted) {
    # Register the owed durable note (its own byte baseline is captured now, so a
    # bare "done" cannot satisfy it later and a second concurrent incident demands
    # its own distinct note). No-op when this incident already owes one.
    Register-PendingNote -Key $incidentKey -Reason $incidentReason -Origin (New-NoteOrigin -Kind result -Path $resultEntryPath)
    Save-CompletionState
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
    [void]$lines.Add('Tag that note with a line `' + (Get-IncidentTag $incidentKey) + '` (exactly) so THIS specific incident is cleared - a note without this tag will not resolve it, and a second concurrent incident needs its own separately tagged note.')
    [void]$lines.Add('If the verified repair changes the command or the old receipt lacks identity, explicitly associate its newer clean receipt: powershell.exe -NoProfile -File "' + $PSCommandPath + '" -ResolveIncident ' + $incidentKey + ' -RecoveryRunId "<verified recovery run id>" -ProjectRoot "' + $cwd + '" -Reason "<substantive equivalent test scope and verified repair, at least 80 UTF-8 bytes>". This still requires the incident note and verified process cleanup.')
    [void]$lines.Add('Report only what the evidence shows: this hook has seen one guarded run for this project and cannot confirm any broader test scope passed.')
    Write-Finding -Blocking $true -Lines $lines.ToArray()
}

# ---- 4. the run completed but failed --------------------------------------
# Two answers, both in _failedrun.ps1: a green CI result for this exact commit
# on a clean tree clears it, anything else blocks exactly as before.
if ($null -ne $result -and $overall -eq 'failed' -and $resultIsCurrentEvidence -and -not $repAccounted) {
    $verdict = Resolve-FailedRunVerdict -Doc $result -Path $resultEntryPath -LastProgress $lastProgress -ProjectRoot $cwd -HookPath $PSCommandPath
    Save-CompletionState
    Write-Finding -Blocking $verdict.Blocking -Lines $verdict.Lines
}

# ---- 5. a test ran but there is no current proof of how it ended ----------
if ($observedCurrent -and -not ($resultIsCurrentEvidence -and $overall -eq 'ok') -and -not $repAccounted) {
    Save-CompletionState
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
    if ($incidentKey -ne '') { Add-ResolvedIncident $incidentKey }
    if ($alwaysRequireNote -and @($script:pendingNotes.Values | Where-Object { Test-NoteObligationActionable $_ }).Count -eq 0) {
        $runKey = Get-ShortHash ('run|' + $script:ResultTicks + '|' + $projectKey)
        Register-PendingNote -Key $runKey -Reason 'a guarded test run completed and TEST_COMPLETION_ALWAYS_REQUIRE_NOTE is enabled' -Origin (New-NoteOrigin -Kind always -Path $resultEntryPath)
    }
}

. (Join-Path $PSScriptRoot '_notegate.ps1')

# Everything accounted for. If this run was a meaningful timing regression, surface
# it now as advisory context (never a block); otherwise stay silent.
Save-CompletionState
# ---- E-05: the ::deep-debug verdict on the otherwise-silent tail ------------
# COMPLETE only on a fresh, clean, current-state guarded result; a stale or
# unproven result reaching this tail must NOT read as a passed gate. The claim
# is scoped honestly: this hook has machine evidence only for guarded-run
# results, the incident-note ledger, and active/cleanup state - everything else
# is named as not verifiable here rather than silently assumed.
if ($script:DeepDebugActive) {
    if ($null -ne $result -and $resultIsCurrentEvidence -and $overall -eq 'ok') {
        if (Test-DdGateShouldReport ('complete|' + $stateFingerprint)) {
            $ddLines = New-Object System.Collections.Generic.List[string]
            [void]$ddLines.Add('DEEP DEBUG: COMPLETE')
            [void]$ddLines.Add('Test-evidence scope verified from recorded state: every current-state observed guarded run has a fresh clean result, no run is still active, no owned process leak or unresolved timeout/kill incident remains, and no durable .ai/ incident note is owed.')
            [void]$ddLines.Add('NOT verifiable by this hook (each has its own gate/evidence; free-form "done" text is never proof): the goal ledger receipt (every item closed), one-time workstream integration, code/security review closure, the exactly-one Ponytail pass, UTF-8 file validation (Utf8-Encoding-Check), and Git/exact-final-SHA CI state.')
            if ($timingRegressionLines.Count -gt 0) {
                [void]$ddLines.Add('')
                foreach ($trl in $timingRegressionLines) { [void]$ddLines.Add($trl) }
            }
            Write-Finding -Blocking $false -Lines $ddLines.ToArray()
        }
    }
    elseif (Test-DdGateShouldReport ('staleorunproven|' + $stateFingerprint)) {
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: ::deep-debug is active for this session but the only recorded guarded evidence is STALE or not a clean current-state result - the deep-debug gate cannot pass on evidence that does not describe the current state.',
            'Re-run the affected suites through scripts\Run-Tests-Guarded.ps1 so a fresh clean result document exists for the current project state, then finish.')
    }
}
if ($timingRegressionLines.Count -gt 0) { Write-Finding -Blocking $false -Lines $timingRegressionLines }
Write-UnknownNoteDiagnostic
Write-SurvivorAdvisory
exit 0 } catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw } finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
