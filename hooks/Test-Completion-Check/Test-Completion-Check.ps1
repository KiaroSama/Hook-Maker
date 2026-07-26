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
# ::DEEP-DEBUG SESSION GATE (E-05). When the ::deep-debug workflow is ACTIVE
# for the current session, this hook's output additionally carries the exact
# workflow verdict lines `DEEP DEBUG: COMPLETE` or `DEEP DEBUG: BLOCKED
# (reason)`, judged ONLY from the fresh, scoped, fingerprinted evidence this
# hook already aggregates (guarded-run results, the incident-note ledger,
# active/cleanup state). Free-form "done" text is never proof, and points with
# no machine evidence here (/goal receipts, workstream integration, code/
# security review, the single Ponytail pass, UTF-8 file validation, Git/exact-
# SHA CI) are reported honestly as not verifiable by this hook - they belong to
# their own gates.
#   ACTIVATION SIGNALS (documented honestly - no client exposes a perfect
#   Stop-side "::deep-debug was invoked earlier" receipt):
#     1. a `prompt` field in THIS hook's own stdin carrying the STANDALONE
#        token (rare at Stop, but the strongest direct signal when present);
#     2. a readable `transcript_path` in this hook's own stdin whose BOUNDED
#        tail (last 64KB) contains the standalone token - only the token is
#        searched for; transcript contents are never stored, printed, hashed
#        into state, or exposed;
#     3. a marker file TestCompletionCheck-deepdebug-<projectKey>.json written
#        by an EARLIER Stop of this hook for the SAME session (schema-versioned,
#        session-bound; a different session's marker is stale and removed).
#   Prose "deep debug" never activates it (CODEWORDS.md: standalone ::-token
#   only), lifecycle-hook independence is preserved (no other hook's state
#   layout is read), and the hook still never executes a codeword, slash
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

# ---- ::deep-debug session detection (E-05; signals documented in the header) --
# The token must be STANDALONE (::-prefixed); the boundary class includes the
# JSON-string delimiters a transcript line wraps a prompt in, so `"::deep-debug"`
# inside a transcript matches while prose "deep debug" (no ::) never can.
$script:DeepDebugActive = $false
$ddTokenPattern = '(?i)(^|[\s"])::deep-debug([\s.,;:!?"\\]|$)'
$ddSeenNow = $false
$ddPromptField = [string](Get-Field $hookInput 'prompt')
if (-not [string]::IsNullOrWhiteSpace($ddPromptField) -and $ddPromptField -match $ddTokenPattern) { $ddSeenNow = $true }
if (-not $ddSeenNow) {
    $ddTranscriptPath = [string](Get-Field $hookInput 'transcript_path')
    if (-not [string]::IsNullOrWhiteSpace($ddTranscriptPath) -and (Test-Path -LiteralPath $ddTranscriptPath -PathType Leaf)) {
        # BOUNDED tail read (64KB), shared-read so a live writer is never blocked.
        # Only the token is searched; the text is discarded, never stored/printed.
        try {
            $ddStream = [System.IO.File]::Open($ddTranscriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $ddTailBytes = [int][Math]::Min([int64]65536, $ddStream.Length)
                if ($ddStream.Length -gt $ddTailBytes) { [void]$ddStream.Seek(-$ddTailBytes, [System.IO.SeekOrigin]::End) }
                $ddBuffer = New-Object byte[] $ddTailBytes
                $ddRead = $ddStream.Read($ddBuffer, 0, $ddTailBytes)
                if ($ddRead -gt 0 -and ([System.Text.Encoding]::UTF8.GetString($ddBuffer, 0, $ddRead)) -match $ddTokenPattern) { $ddSeenNow = $true }
            }
            finally { $ddStream.Dispose() }
        }
        catch { }
    }
}
if ($ddSeenNow) {
    # Persist the session-bound marker so LATER Stops of this session stay in
    # deep-debug mode even if the token has scrolled out of the bounded tail.
    try { Write-JsonFileAtomic -Path $ddMarkerPath -Value ([pscustomobject]@{ schema = 1; sessionId = $sessionId; detectedUtc = [DateTime]::UtcNow.ToString('o') }) } catch { }
    $script:DeepDebugActive = $true
}
else {
    $ddMarker = $null
    try { $ddMarker = Read-JsonFile $ddMarkerPath } catch { $ddMarker = $null }
    if ($null -ne $ddMarker) {
        if ($sessionId -ne '' -and [string](Get-Field $ddMarker 'sessionId') -eq $sessionId) { $script:DeepDebugActive = $true }
        else { try { Remove-Item -LiteralPath $ddMarkerPath -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

# Once-per-session-per-state gate for the dd-specific outputs (anti-loop): an
# unchanged state token reports once; a changed token or a new session reports
# again immediately. Never consulted for the pre-existing condition-1..6 blocks.
function Test-DdGateShouldReport {
    param([string]$StateToken)
    $ddFp = Get-ShortHash ($StateToken + '|' + $script:sessionId)
    try {
        if (Test-Path -LiteralPath $script:ddGatePath -PathType Leaf) {
            if (([System.IO.File]::ReadAllText($script:ddGatePath)).Trim() -eq $ddFp) { return $false }
        }
    }
    catch { }
    try {
        if (-not (Test-Path -LiteralPath $script:stateDir -PathType Container)) { New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:ddGatePath, $ddFp, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
    return $true
}

# The four durable-memory files a hang/timeout finding may legitimately be
# recorded in (AI Context Memory Policy). Any of them growing satisfies the
# requirement - the hook never dictates which one.
$script:NoteFiles = @('.ai\BUGS.md', '.ai\TESTING_NOTES.md', '.ai\COMMANDS.md', '.ai\LESSON.md')
# Net bytes a durable note must add before it counts. A bare acknowledgement
# ("done", "n/a", "fixed") cannot clear this; a real note trivially does.
$script:MinNoteBytes = 80
# Each incident's note must carry THIS exact tag line so one note can no longer
# resolve two distinct incidents by byte growth alone (a single 80-byte note used
# to clear every incident that shared its baseline). The block message tells the
# agent the exact string to write; resolution requires the marker AND the byte
# floor, so a bare tag with no substance still does not count.
$script:IncidentTagPrefix = 'Test incident: '
function Get-IncidentTag { param([string]$Key) return ($script:IncidentTagPrefix + $Key) }

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

# Concatenated text of the four durable-note files (empty when none exist). Read
# so an incident's own tag can be searched for; a read failure yields '' rather
# than throwing, so a locked/absent file never crashes the gate.
function Get-NoteText {
    param([string]$Root)
    $sb = New-Object System.Text.StringBuilder
    foreach ($relative in $script:NoteFiles) {
        $path = Join-Path $Root $relative
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) { [void]$sb.AppendLine([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)) }
        }
        catch { }
    }
    return $sb.ToString()
}

# Is this incident's own tag ("Test incident: <key>") present in the .ai/ notes?
# Whitespace after the colon is tolerated; the key is regex-escaped so it matches
# literally. This is the per-incident marker that makes two notes genuinely
# required for two incidents.
function Test-NoteTagPresent {
    param([string]$Root, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    $text = Get-NoteText -Root $Root
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match ('Test incident:\s*' + [regex]::Escape($Key)))
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

# ---- this hook's own state: the per-incident LEDGER ------------------------
. (Join-Path $PSScriptRoot '_ledger.ps1')

# ---- output ---------------------------------------------------------------
# A real block uses `decision:block` for both clients (Ci-Status-Check's
# blocking paths do the same). An advisory is CLIENT-AWARE and never a block:
# on Codex `decision:block` at Stop forces a new prompt, which for an advisory
# would be an infinite loop.
function Write-Finding {
    param([string[]]$Lines, [bool]$Blocking)
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { [void]$all.Add($line) }
    # E-05: while ::deep-debug is active, every blocking finding also carries the
    # exact workflow verdict line with a concise reason derived from the first
    # finding line. Constant text riding an EXISTING block - it adds no new loop
    # path; the dd-specific outputs have their own once-per-session gate.
    if ($Blocking -and $script:DeepDebugActive) {
        $ddReason = ''
        if (@($Lines).Count -gt 0) {
            $ddReason = ([string]$Lines[0]) -replace '^TEST COMPLETION CHECK:\s*', ''
            $ddDot = $ddReason.IndexOf('. ')
            if ($ddDot -gt 0) { $ddReason = $ddReason.Substring(0, $ddDot) }
            if ($ddReason.Length -gt 160) { $ddReason = $ddReason.Substring(0, 160) }
        }
        if ($ddReason -eq '') { $ddReason = 'unresolved test-completion evidence' }
        [void]$all.Add('')
        [void]$all.Add('DEEP DEBUG: BLOCKED (' + $ddReason + ')')
    }
    if ($script:configWarnings.Count -gt 0) {
        [void]$all.Add('')
        foreach ($warning in $script:configWarnings) { [void]$all.Add('Test-Completion-Check .env: ' + $warning) }
    }
    $message = ($all.ToArray() -join "`n")
    # The gating DECISION is made above and is unchanged here; Write-HookResult
    # only turns it into the client's wire shape (claude/codex block ->
    # decision:block, claude advisory -> hookSpecificOutput.additionalContext,
    # codex Stop advisory -> systemMessage). A client that documents no Stop
    # gate has its block downgraded to the strongest advisory and reported as
    # degraded, which is what 'degraded-stop-gate' means - never a fake gate.
    $kind = 'advisory'
    if ($Blocking -and -not $script:advisoryOnly) { $kind = 'block' }
    $emit = Write-HookResult -EventName $script:eventName -Kind $kind -Message $message -Reason $message
    exit $emit.ExitCode
}

# ---- read the recorded evidence (AGGREGATED across per-run files) ----------
. (Join-Path $PSScriptRoot '_evidence.ps1')

# The evidence is loaded BEFORE pruning so pruning can read each file's content.
$resultEntries = Get-CompletionStateEntries 'result'
$observedEntries = Get-CompletionStateEntries 'observed'
$activeEntries = Get-CompletionStateEntries 'active'

# ---- R1: register note obligations BEFORE pruning can delete a superseded run --
# The prune below removes a superseded negative (a hang that later re-ran green for
# the same command+state). A supersede lifts the RESULT-level block but NEVER the
# durable-note requirement (D2). If the superseded run's files were pruned before
# its obligation was recorded - e.g. the first Stop fires >24h after a self-heal -
# the lesson would be lost forever. So every CURRENT-state, unresolved, superseded
# incident has its note demanded here, before the prune can erase it. Its
# obligation then lives in the ledger independent of the result file. Un-superseded
# current-state negatives are KEPT by the prune and register normally when they
# block, so only the about-to-be-pruned ones need this pass.
foreach ($re in $resultEntries) {
    $ik = Get-ResultIncidentKey -Doc $re.Doc -Path $re.Path
    if ($ik -eq '' -or (Test-IncidentResolved $ik) -or $script:pendingNotes.Contains($ik)) { continue }
    $rProjFp = [string](Get-Field $re.Doc 'projectFingerprint')
    $isCurrentState = ($rProjFp -eq '' -or $rProjFp -eq $stateFingerprint)
    if (-not $isCurrentState) { continue }
    if (Test-ResultSuperseded -NegDoc $re.Doc -NegTime (Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path) -AllResults $resultEntries) {
        Register-PendingNote -Key $ik -Reason (Get-IncidentReasonFromDoc $re.Doc)
    }
}

# ---- bounded, CONTENT-AWARE state growth control (C2 / D3 / D4) -------------
# Age alone must never erase a NEGATIVE finding. Staleness weakens only POSITIVE
# evidence (see this file's header): a run that TERMINATED, FAILED, LEAKED, errored
# or was OBSERVED-WITHOUT-A-RESULT for the current state is an incident whose
# obligation survives until it is RESOLVED (a durable note recorded, tracked in
# resolvedIncidents) or SUPERSEDED (a strictly-newer clean ok run for the same
# command+state - which also underlies the C4 fix). A CURRENT-state unresolved
# negative is NEVER pruned by age. Only clean ok runs, resolved/superseded
# negatives, OLD-STATE clutter past a longer bound (D4), and old-STATE observations
# carrying no current obligation are pruned, so a hang whose Stop hook never fired
# within 24h can never be silently deleted before it is seen. Best-effort: a read
# or delete failure never blocks the gate.
$pruneCutoff = [DateTime]::UtcNow.AddHours(-24)
# D4: an OLD-STATE (fingerprint != current) negative can NEVER become current
# evidence and can never block, yet a plain `failed` has no incident key to ever
# resolve and, being old-state, is never superseded - so without a bound it would
# accumulate forever across states. Give old-state negatives a longer, safe
# retention and prune past it. The CURRENT-state guarantee above is untouched.
$oldStateNegativeCutoff = [DateTime]::UtcNow.AddDays(-7)
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
    $resolved = (Test-IncidentResolved $ik)
    $superseded = Test-ResultSuperseded -NegDoc $re.Doc -NegTime (Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path) -AllResults $resultEntries
    if ($resolved -or $superseded) { [void]$prunedResultPaths.Add($re.Path); continue }
    # An unresolved, un-superseded negative. CURRENT-state -> KEEP however old
    # (round-19 guarantee). OLD-state clutter -> bounded retention (D4).
    $rProjFp = [string](Get-Field $re.Doc 'projectFingerprint')
    $isCurrentState = ($rProjFp -eq '' -or $rProjFp -eq $stateFingerprint)
    if (-not $isCurrentState -and $mtime -lt $oldStateNegativeCutoff) { [void]$prunedResultPaths.Add($re.Path) }
}
# D3: prune observations by the SAME one-to-one assignment the main flow uses. An
# observation whose ONE assigned result is a pruned clean/resolved run is fully
# accounted for; an observation with NO independently-assigned result is an
# unfinished incident and must NOT be pruned as if a shared result covered it.
$currentObservedPre = @($observedEntries | Where-Object { (Get-ObservedFingerprint $_.Doc) -eq $stateFingerprint })
$pruneAssign = Get-ObservedResultAssignment -CurrentObserved $currentObservedPre -ResultEntries $resultEntries -StateFp $stateFingerprint
$assignedResultForObserved = @{}
for ($i = 0; $i -lt $pruneAssign.SortedObserved.Count; $i++) {
    if ($pruneAssign.Map.ContainsKey($i)) { $assignedResultForObserved[$pruneAssign.SortedObserved[$i].Path] = $pruneAssign.Map[$i].Path }
}
foreach ($oe in $observedEntries) {
    $mtime = Get-FileMtimeUtc $oe.Path
    if ($null -eq $mtime -or $mtime -ge $pruneCutoff) { continue }
    if ((Get-ObservedFingerprint $oe.Doc) -ne $stateFingerprint) { [void]$prunedObservedPaths.Add($oe.Path); continue }   # old-STATE: no current obligation
    if (-not $assignedResultForObserved.ContainsKey($oe.Path)) { continue }   # unpaired -> unfinished incident, KEEP
    if ($prunedResultPaths.Contains($assignedResultForObserved[$oe.Path])) { [void]$prunedObservedPaths.Add($oe.Path) }   # its ONE assigned result is a pruned clean/resolved run
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
# already recorded (its key is in resolvedIncidents) OR it is SUPERSEDED by a
# strictly-newer clean ok run for the same command/state. This is what lets a green
# rerun win when an environmental problem is fixed WITHOUT a source change (same
# fingerprint): the old incident no longer outranks the clean rerun, and it breaks
# the deadlock where the terminated run's own case-2/3 block would otherwise fire
# before case 6 could ever process the durable note. A genuinely unresolved,
# un-superseded incident is NOT excluded and still blocks; the durable-note
# obligation registered on the first sighting still stands (case 6 enforces it once
# the run stops outranking everything else).
function Test-RunNegativeAccounted {
    param($Run, $AllResults)
    if ($null -eq $Run.ResultEntry) { return $false }
    $doc = $Run.ResultEntry.Doc
    $path = $Run.ResultEntry.Path
    $ik = Get-ResultIncidentKey -Doc $doc -Path $path
    if (Test-IncidentResolved $ik) { return $true }
    return (Test-ResultSuperseded -NegDoc $doc -NegTime (Get-ResultRecordedTime -Doc $doc -Path $path) -AllResults $AllResults)
}
$classified = @($runs | ForEach-Object { [pscustomobject]@{ Run = $_; Class = (Get-RunClass $_) } })

# ---- D2: register the durable-note obligation on FIRST SIGHTING -------------
# For EVERY current-state incident, the note obligation is registered the first
# time it is seen - BEFORE the supersede/resolve exclusion is applied to the block
# decision. A supersede lifts only the RESULT-level block (case 2/3); it never
# lifts the note requirement. So a hang that self-heals into green BEFORE any Stop
# still owes its lesson once (case 6 enforces it). Only ACCOUNTED (already
# superseded) incidents are registered here; an un-superseded incident is left to
# register when it becomes the blocking representative (case 2/3), which spaces two
# concurrent incidents' note baselines across Stops so each demands a DISTINCT note.
# ponytail: two incidents self-healing within ONE Stop would share a baseline and
# one note could clear both - the byte-growth heuristic's inherent limit; sequential
# real-world surfacing gives distinct baselines. Upgrade path: per-incident note tags.
foreach ($cl in $classified) {
    if ($cl.Class -ne 'incident' -or $null -eq $cl.Run.ResultEntry) { continue }
    $ikSeen = Get-ResultIncidentKey -Doc $cl.Run.ResultEntry.Doc -Path $cl.Run.ResultEntry.Path
    if ($ikSeen -eq '' -or (Test-IncidentResolved $ikSeen) -or $script:pendingNotes.Contains($ikSeen)) { continue }
    if (Test-RunNegativeAccounted -Run $cl.Run -AllResults $resultEntries) {
        Register-PendingNote -Key $ikSeen -Reason (Get-IncidentReasonFromDoc $cl.Run.ResultEntry.Doc)
    }
}

$rep = $null
foreach ($wanted in @('incident', 'failed')) {
    $m = @($classified | Where-Object { $_.Class -eq $wanted -and -not (Test-RunNegativeAccounted -Run $_.Run -AllResults $resultEntries) })
    if ($m.Count -gt 0) { $rep = $m[0]; break }
}
if ($null -eq $rep) {
    $m = @($classified | Where-Object { $_.Run.HasObserved -and $_.Class -ne 'clean' -and -not (Test-RunNegativeAccounted -Run $_.Run -AllResults $resultEntries) })   # condition 5: observed, not satisfied
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
if ($null -eq $result -and -not $observedCurrent -and $activePid -eq 0 -and $script:pendingNotes.Count -eq 0) {
    if ($script:DeepDebugActive -and (Test-DdGateShouldReport ('noevidence|' + $stateFingerprint))) {
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: ::deep-debug is active for this session but NO guarded test evidence exists for the current project state - no observed run, no guarded result, nothing active.',
            'The deep-debug completion gate consumes only fresh scoped evidence: run the affected suites through scripts\Run-Tests-Guarded.ps1 (the Test-Run-Guard gate supplies the exact bounded command) so a verifiable result document exists, then finish.')
    }
    exit 0
}
# A recorded incident that was already resolved, no pending note, nothing
# current to prove, nothing running: also silence. Under an active ::deep-debug
# session this still lacks CURRENT clean evidence, so it is the same blocked
# no-evidence state (its own once-per-session token).
if ($incidentKey -ne '' -and (Test-IncidentResolved $incidentKey) -and $script:pendingNotes.Count -eq 0 -and
    -not $observedCurrent -and $activePid -eq 0) {
    if ($script:DeepDebugActive -and (Test-DdGateShouldReport ('resolvedonly|' + $stateFingerprint))) {
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: ::deep-debug is active for this session, and while a past incident is resolved, no CURRENT-state guarded test evidence exists.',
            'Run the affected suites through scripts\Run-Tests-Guarded.ps1 so a fresh clean result document exists for the current project state, then finish.')
    }
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

# ---- 2/3. a terminated or leaking run -------------------------------------
# Gated on identity, not age: an incident from a DIFFERENT run/state is not this
# run's problem and must not block the current state; a real incident for THIS
# run still blocks however old its file is.
if ($incidentKey -ne '' -and -not (Test-IncidentResolved $incidentKey) -and $resultRunMatches -and -not $repAccounted) {
    # Register the owed durable note (its own byte baseline is captured now, so a
    # bare "done" cannot satisfy it later and a second concurrent incident demands
    # its own distinct note). No-op when this incident already owes one.
    Register-PendingNote -Key $incidentKey -Reason $incidentReason
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
    [void]$lines.Add('Report only what the evidence shows: this hook has seen one guarded run for this project and cannot confirm any broader test scope passed.')
    Write-Finding -Blocking $true -Lines $lines.ToArray()
}

# ---- 4. the run completed but failed --------------------------------------
if ($null -ne $result -and $overall -eq 'failed' -and $resultIsCurrentEvidence -and -not $repAccounted) {
    Save-CompletionState
    $exitCode = [string](Get-Field $result 'exitCode')
    Write-Finding -Blocking $true -Lines @(
        'TEST COMPLETION CHECK: the latest guarded test run for this project FAILED (exit code ' + $exitCode + '). The work is not verifiably complete.',
        $(if ($lastProgress -ne '') { 'Last recorded progress: ' + $lastProgress } else { 'The result document records no final progress line.' }),
        'Recovery: inspect the actual failure, fix the root cause, and re-run the suite through scripts\Run-Tests-Guarded.ps1 until the result reports overall=ok. Do not weaken, skip, or delete tests to make it pass, and do not claim tests passed while this result stands.')
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
    if ($alwaysRequireNote -and $script:pendingNotes.Count -eq 0) {
        $runKey = Get-ShortHash ('run|' + $script:ResultTicks + '|' + $projectKey)
        Register-PendingNote -Key $runKey -Reason 'a guarded test run completed and TEST_COMPLETION_ALWAYS_REQUIRE_NOTE is enabled'
    }
}

# ---- 6. every durable note that is still owed ------------------------------
# EVERY pending incident is enforced, not one: a satisfied note (its OWN tag present
# AND real added content past its byte baseline) is resolved and dropped; any
# still-owed note keeps blocking. The tag is what makes two concurrent incidents
# each require their OWN note - one 80-byte note can no longer clear both by byte
# growth alone. Resolving one never forgets the other.
if ($script:pendingNotes.Count -gt 0 -or $script:pendingOverflow) {
    $owed = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($script:pendingNotes.Keys)) {
        if (Test-PendingNoteSatisfied -Key ([string]$k)) { Add-ResolvedIncident ([string]$k) }   # satisfied -> resolved, dropped
        else { [void]$owed.Add([pscustomobject]@{ Key = [string]$k; Reason = [string]$script:pendingNotes[$k].reason }) }
    }
    if ($script:pendingOverflow -and $owed.Count -gt 0) {
        # R2b: the ledger is full of UNRESOLVED obligations and a newer incident
        # could not be tracked without discarding one. Surface it - never drop a
        # live lesson - and keep blocking until the backlog is cleared.
        Save-CompletionState
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: the durable-note ledger is FULL (' + $script:MaxPendingNotes + ' unresolved test-incident notes are already owed) and another incident was seen that cannot be tracked without discarding one.',
            'No unresolved note is being dropped - completion stays blocked until the backlog clears. Write the owed .ai/ notes (each tagged with its own `' + $script:IncidentTagPrefix + '<key>` line as instructed on the Stop that first reported it) so their obligations resolve, then re-run so the newest incident can be recorded.')
    }
    if ($owed.Count -gt 0) {
        Save-CompletionState
        Write-Finding -Blocking $true -Lines @(
            'TEST COMPLETION CHECK: a durable .ai/ note is still owed because ' + $owed[0].Reason + '.',
            'Write it into .ai/BUGS.md, .ai/TESTING_NOTES.md, .ai/COMMANDS.md and/or .ai/LESSON.md, whichever fits. It must state WHY the problem was not detected earlier and the verified prevention/recovery guard that now catches it - concretely enough that a later session can act on it.',
            'Tag it with a line `' + (Get-IncidentTag $owed[0].Key) + '` (exactly) so THIS specific incident is cleared; a note without this tag, or a bare tag with no real content, will not clear it, and each other owed incident needs its own tagged note.',
            'A bare acknowledgement ("done", "n/a", "fixed") does not satisfy this and will not clear it; the check looks for the tag plus real added content in those files.')
    }
    # Every owed note is now satisfied: the incident(s) and their notes are closed.
    Save-CompletionState
    if ($timingRegressionLines.Count -gt 0) { Write-Finding -Blocking $false -Lines $timingRegressionLines }
    exit 0
}

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
            [void]$ddLines.Add('NOT verifiable by this hook (each has its own gate/evidence; free-form "done" text is never proof): the /goal objective+ledger receipt, one-time workstream integration, code/security review closure, the exactly-one Ponytail pass, UTF-8 file validation (Utf8-Encoding-Check), and Git/exact-final-SHA CI state.')
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
exit 0
