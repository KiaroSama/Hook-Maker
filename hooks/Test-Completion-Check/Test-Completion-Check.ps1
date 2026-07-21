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
# same key Test-Temp-Cleanup and Cloudflare-Deploy already use.
#   read  TestRunGuard-result-<key>.json    Run-Tests-Guarded.ps1's result
#                                           document (schema/overall/exitCode/
#                                           terminated/terminateReason/
#                                           leakedProcessIds/endedUtc/...), with
#                                           optional `fingerprint`/`recordedUtc`
#                                           added by Test-Run-Guard.
#   read  TestRunGuard-active-<key>.json    { pid, startedUtc } while a guarded
#                                           run holds a live child. A dead pid
#                                           makes the marker stale, not active.
#   read  TestRunGuard-observed-<key>.json  { observedUtc, fingerprint, guarded }
#                                           a test command was seen running for
#                                           that repo-state fingerprint.
#   read  TestTempCleanup-result-<key>.json  Test-Temp-Cleanup's existing
#                                           { fingerprint, category } handoff.
#   write TestCompletionCheck-<key>.json    this hook's own resolved-incident /
#                                           owed-note / deferral state.
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
$resultPath = Join-Path $stateDir ('TestRunGuard-result-' + $projectKey + '.json')
$activePath = Join-Path $stateDir ('TestRunGuard-active-' + $projectKey + '.json')
$observedPath = Join-Path $stateDir ('TestRunGuard-observed-' + $projectKey + '.json')
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

# ---- read the recorded evidence -------------------------------------------
$result = $null
try { $result = Read-JsonFile $resultPath } catch { $result = $null }

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
    $resultTime = ConvertTo-UtcTime (Get-Field $result 'recordedUtc')
    if ($null -eq $resultTime) { $resultTime = ConvertTo-UtcTime (Get-Field $result 'endedUtc') }
    if ($null -eq $resultTime) {
        try { $resultTime = (Get-Item -LiteralPath $resultPath -Force).LastWriteTimeUtc } catch { $resultTime = $null }
    }
}
$resultIsCurrent = ($null -ne $resultTime -and ([DateTime]::UtcNow - $resultTime).TotalMinutes -lt $evidenceMinutes)
# Stable, locale-independent identity for the run this result describes.
$script:ResultTicks = if ($null -ne $resultTime) { [string]$resultTime.Ticks } else { '0' }

# A test command was seen for THIS project state (Test-Run-Guard's PostToolUse
# handoff). Only trusted while its fingerprint still matches - an observation
# from an earlier state says nothing about the state being completed now.
$observedCurrent = $false
$observedGuarded = $true
$observed = $null
try { $observed = Read-JsonFile $observedPath } catch { $observed = $null }
if ($null -ne $observed) {
    $observedFingerprint = [string](Get-Field $observed 'fingerprint')
    if ($observedFingerprint -eq $stateFingerprint) {
        $observedCurrent = $true
        if ((Get-Field $observed 'guarded') -eq $false) { $observedGuarded = $false }
    }
}

# Does the recorded result actually describe THIS run/command/state? A result
# for a DIFFERENT run is not evidence about the current one, so every
# result-driven finding below is gated on identity - never on file age.
#   $resultRunMatches         : identity/state match, NO age check. Negative
#                               findings (a terminated/leaked incident) use this,
#                               because staleness must never weaken a real
#                               incident - only a genuine identity mismatch clears
#                               it (spec: a mismatched negative result for a
#                               DIFFERENT run must not block the current state).
#   $resultIsCurrentEvidence  : the above AND still fresh. POSITIVE evidence (a
#                               clean pass, a definite fail) additionally requires
#                               freshness, since an old pass is not proof a run
#                               happened for the current state.
# When an observed record exists, bind exactly by run identity; when none does,
# bind on the result's own project fingerprint (schema 2) or, for a legacy
# result with no identity at all, keep the prior age-only behaviour.
$resultRunMatches = $false
if ($null -ne $result) {
    if ($null -ne $observed) {
        $resultRunMatches = (Test-ResultMatchesObserved -Result $result -Observed $observed -CurrentStateFingerprint $stateFingerprint)
    }
    else {
        $rProjectFp = [string](Get-Field $result 'projectFingerprint')
        if (-not [string]::IsNullOrWhiteSpace($rProjectFp)) { $resultRunMatches = ($rProjectFp -eq $stateFingerprint) }
        else { $resultRunMatches = $true }   # legacy result: no identity to bind on, age governs at the positive sites
    }
}
$resultIsCurrentEvidence = ($resultRunMatches -and $resultIsCurrent)

# An active guarded run: only when the recorded owner process is STILL THE SAME
# process. A bare {pid} marker is a PID-REUSE trap - an unrelated process that
# later inherits that pid would block completion forever. The schema-2 marker
# also records the owner's own start time and executable path, so "alive" now
# means the live process at ownerPid has that EXACT start time and executable and
# the marker belongs to the current project. A recycled pid, a different program,
# or a different project makes the marker stale, never active. A malformed marker
# is treated as absent (no infinite block). A stale marker is removed best-effort.
$activePid = 0
$active = $null
try { $active = Read-JsonFile $activePath } catch { $active = $null }
if ($null -ne $active) {
    $ownerPidRaw = Get-Field $active 'ownerPid'
    if ($null -eq $ownerPidRaw) { $ownerPidRaw = Get-Field $active 'pid' }   # schema-1 fallback
    $candidate = 0
    if ([int]::TryParse([string]$ownerPidRaw, [ref]$candidate) -and $candidate -gt 0) {
        $liveProcess = $null
        try { $liveProcess = Get-Process -Id $candidate -ErrorAction Stop } catch { $liveProcess = $null }
        if ($null -ne $liveProcess) {
            $markerStartUtc = ConvertTo-UtcTime (Get-Field $active 'ownerProcessStartUtc')
            $markerExe = [string](Get-Field $active 'ownerExecutablePath')
            $markerProjFp = [string](Get-Field $active 'projectFingerprint')
            if ($null -ne $markerStartUtc -or $markerExe -ne '') {
                # Schema-2 identity check: everything present must match the LIVE process.
                $identityOk = $true
                if ($markerProjFp -ne '' -and $markerProjFp -ne $stateFingerprint) { $identityOk = $false }
                if ($identityOk -and $null -ne $markerStartUtc) {
                    $liveStart = $null
                    try { $liveStart = $liveProcess.StartTime.ToUniversalTime() } catch { $liveStart = $null }
                    if ($null -eq $liveStart -or [Math]::Abs(($liveStart - $markerStartUtc).TotalSeconds) -gt 2) { $identityOk = $false }
                }
                if ($identityOk -and $markerExe -ne '') {
                    $liveExe = ''
                    try { $liveExe = [string]$liveProcess.Path } catch { $liveExe = '' }
                    if ($liveExe -ne '' -and -not [string]::Equals($liveExe, $markerExe, [System.StringComparison]::OrdinalIgnoreCase)) { $identityOk = $false }
                }
                if ($identityOk) { $activePid = $candidate }
            }
            else {
                # Schema-1 marker (no owner identity): best-effort legacy behaviour.
                $activePid = $candidate
            }
        }
    }
    # A marker that resolved to no active owner is stale - drop it so a recycled
    # pid can never resurrect it. Best-effort; failure to delete never blocks.
    if ($activePid -eq 0) {
        try { Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

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
