# Test-Plan-Check - the BEFORE stage of the three-stage test-health
# architecture (global-test-rules.md SS Three-Stage Test Enforcement /
# global-hook-rules.md SS Test Hook Architecture).
#
# ROLE: DETECTOR + ADVISORY (global-hook-rules.md SS Hook Roles).
#   - It NEVER executes a test, spawns a process, or invokes a runner.
#   - It NEVER writes anything into the project; its only state lives under
#     %LOCALAPPDATA%\HookMaker\state.
#   - It NEVER blocks. It emits advisory context or nothing at all.
#
# Events: SessionStart, UserPromptSubmit.
#   - SessionStart surfaces the applicable policy once per project/state.
#   - UserPromptSubmit is RELEVANCE-GATED: it reacts only to prompts that are
#     actually about tests, CI, runners, hangs, timeouts, parallelism, workers,
#     CPU/memory, sleep/polling or test cleanup. Ordinary prompts get NOTHING;
#     silence is the default and by far the common case.
#
# Token-efficient by design: a compact project/state fingerprint (git state +
# a signature of what the risk scan actually saw) plus a cooldown means an
# unchanged repository does not re-warn on every prompt. A CHANGED state
# reports immediately, ignoring the cooldown - that is the whole point.
#
# Reported risks are only ever things this hook can POINT AT (file + line) in
# the repository as it exists right now: a minute-scale blind sleep in a test
# file, an unbounded wait, an unbounded polling loop, a child process started
# with no visible wall/idle bound. Never a theoretical warning.
#
# Output shape is CLIENT-AWARE, matching Ci-Status-Check.ps1 (lines 50-54 and
# 290-322): Claude Code gets `hookSpecificOutput.additionalContext` (its
# documented model-visible context field); Codex gets `systemMessage` (its only
# documented common field). Neither path ever emits `decision:block` - on Codex
# a Stop-style block FORCES CONTINUATION, and an advisory is what is correct
# here anyway. Claude is detected by `hookSpecificOutput` being present in the
# INPUT event, or by CLAUDE_PROJECT_DIR being exported (the signal Rules-Check
# and Ci-Status-Check use); absent both -> Codex.
#
# Optional .env next to this script (copy .env.example):
#   TEST_PLAN_COOLDOWN_MINUTES  minutes before an unchanged finding repeats (default 120)
#   TEST_PLAN_EXTRA_KEYWORDS    extra comma-separated project relevance keywords
#   TEST_PLAN_ALWAYS_REPORT     1 = ignore the cooldown (hook debugging; default 0)
# An invalid value is reported in plain text inside the advisory and the
# default is used - a malformed setting must never block or crash a session.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }

# Recursion guard: this hook never registers on Stop/SubagentStop, but if a
# client ever replays such an event at it, honour the guard first and leave.
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }

$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }

# ---- optional .env (invalid -> default + a plain-text note) ----
$configWarnings = New-Object System.Collections.Generic.List[string]
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

$cooldownMinutes = 120
if ($config.ContainsKey('TEST_PLAN_COOLDOWN_MINUTES')) {
    $raw = [string]$config['TEST_PLAN_COOLDOWN_MINUTES']
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 10080) {
        $cooldownMinutes = $parsed
    }
    elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_PLAN_COOLDOWN_MINUTES is not an integer in 1..10080; using the default 120.')
    }
}

$alwaysReport = $false
if ($config.ContainsKey('TEST_PLAN_ALWAYS_REPORT')) {
    $raw = [string]$config['TEST_PLAN_ALWAYS_REPORT']
    if ($raw -eq '1') { $alwaysReport = $true }
    elseif ($raw -ne '0' -and -not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add('TEST_PLAN_ALWAYS_REPORT must be 0 or 1; using the default 0.')
    }
}

$extraKeywords = @()
if ($config.ContainsKey('TEST_PLAN_EXTRA_KEYWORDS')) {
    $extraKeywords = @(([string]$config['TEST_PLAN_EXTRA_KEYWORDS']).Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and $_ -match '^[\w.+#-]{2,40}$' })
}

# ---- relevance gate (UserPromptSubmit only) ----
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }
    $pattern = '(?i)\b(test|tests|testing|tested|testsuite|suite|suites|regression|ci|pipeline|workflow|runner|runners|pytest|vitest|jest|pester|nunit|xunit|mocha|hang|hangs|hung|hanging|stuck|freeze|frozen|timeout|timeouts|time-out|deadline|parallel|parallelism|serial|concurrency|worker|workers|throttle|cpu|memory|ram|oom|sleep|sleeps|poll|polling|wait|waits|flaky|flakiness|coverage|cleanup|clean-up|leak|leaked|leaking|zombie|orphan)\b'
    $relevant = $prompt -match $pattern
    if (-not $relevant -and $extraKeywords.Count -gt 0) {
        $escaped = @($extraKeywords | ForEach-Object { [regex]::Escape($_) })
        $relevant = $prompt -match ('(?i)(?<![\w-])(' + ($escaped -join '|') + ')(?![\w-])')
    }
    if (-not $relevant) { exit 0 }
}

# ---- bounded, read-only risk scan -------------------------------------------
# Only files that are plausibly TEST files, only a capped number of them, only
# a capped read per file. Everything reported carries a file:line the reader
# can open; nothing is inferred or theoretical.
$script:MaxFiles = 200
$script:MaxBytes = 400KB
$script:MaxFindings = 8
$script:ExcludeFragments = @('\.git\', '\node_modules\', '\.venv\', '\venv\', '\graphify-out\', '\dist\', '\build\', '\site-packages\', '\vendor\', '\.tox\', '\__pycache__\')

function Test-IsExcludedPath {
    param([string]$FullPath)
    $lower = $FullPath.ToLowerInvariant()
    foreach ($fragment in $script:ExcludeFragments) {
        if ($lower.Contains($fragment)) { return $true }
    }
    return $false
}

$testFiles = @()
try {
    $testFiles = @(Get-ChildItem -LiteralPath $cwd -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -match '(?i)^\.(ps1|psm1|py|js|mjs|cjs|ts|sh|rb|go)$' -and
            (($_.Name -match '(?i)(^|[\\/._-])(test|tests|spec)') -or ($_.DirectoryName -match '(?i)[\\/](tests?|spec|specs|__tests__)([\\/]|$)')) -and
            -not (Test-IsExcludedPath $_.FullName)
        } |
        Sort-Object FullName |
        Select-Object -First $script:MaxFiles)
}
catch { $testFiles = @() }

# A file that shows ANY of these is treated as having a visible bound, so the
# no-bound findings stay conservative (a false silence beats a false warning).
$boundTokenPattern = '(?i)(timeout|deadline|elapsed|stopwatch|maxwait|max_wait|max-wait|maxattempt|max_attempt|waitforexit\(\s*[^)\s]|-wait\b|cancellationtoken|SIGALRM|ctrl\+c)'

$findings = New-Object System.Collections.Generic.List[string]
$signatureParts = New-Object System.Collections.Generic.List[string]

foreach ($file in $testFiles) {
    if ($file.Length -gt $script:MaxBytes) {
        [void]$signatureParts.Add($file.FullName + ':oversize:' + $file.Length)
        continue
    }
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($file.FullName) }
    catch { continue }
    $text = $lines -join "`n"
    $hasBound = $text -match $boundTokenPattern
    $relative = $file.FullName
    if ($relative.StartsWith($cwd, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($cwd.Length).TrimStart('\', '/')
    }
    [void]$signatureParts.Add($relative + ':' + $file.Length + ':' + $file.LastWriteTimeUtc.Ticks)

    $reportedNoBound = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(#|//)') { continue }
        # A line that merely DESCRIBES a pattern (a -match/-replace regex
        # literal) is not a risk - this keeps detector code, lint rules and
        # this hook's own source out of the findings.
        if ($line -match '(?i)-(c?match|notmatch|c?replace|c?like|notlike)\b') { continue }
        $where = $relative + ':' + ($i + 1)

        # 1. minute-scale blind sleep in a test file
        $seconds = -1
        if ($line -match '(?i)\bStart-Sleep\s+(?:-Seconds\s+)?(\d+)\b') { $seconds = [int]$Matches[1] }
        elseif ($line -match '(?i)\bStart-Sleep\s+-Milliseconds\s+(\d+)\b') { $seconds = [int]([int]$Matches[1] / 1000) }
        elseif ($line -match '(?i)\b(?:time\.)?sleep\(\s*(\d+)') { $seconds = [int]$Matches[1] }
        elseif ($line -match '(?i)^\s*sleep\s+(\d+)\b') { $seconds = [int]$Matches[1] }
        if ($seconds -ge 60) {
            [void]$findings.Add($where + ' - blind sleep of ' + $seconds + 's in a test file. Wait on a deterministic signal or bounded polling instead.')
        }

        # 2. an explicitly unbounded wait
        if ($line -match '(?i)WaitForExit\(\s*\)') {
            [void]$findings.Add($where + ' - WaitForExit() with no timeout: an unbounded wait on a child process.')
        }

        # 3. an unbounded polling loop (only when the file shows no bound at all)
        if (-not $hasBound -and ($line -match '(?i)while\s*\(\s*\$?true\s*\)' -or $line -match '(?i)^\s*while\s+True\s*:')) {
            [void]$findings.Add($where + ' - polling loop with no timeout/deadline/elapsed bound anywhere in the file.')
        }

        # 4. a child process started with no visible bound (once per file)
        if (-not $hasBound -and -not $reportedNoBound -and
            ($line -match '(?i)\bStart-Process\b' -or $line -match '(?i)\bsubprocess\.(run|Popen|call)\b' -or $line -match '(?i)\bchild_process\b')) {
            [void]$findings.Add($where + ' - starts a child process with no wall/idle bound in the file; the suite can hang without an owner.')
            $reportedNoBound = $true
        }

        if ($findings.Count -ge $script:MaxFindings) { break }
    }
    if ($findings.Count -ge $script:MaxFindings) { break }
}

# ---- compact project/state fingerprint --------------------------------------
# git state (when available) plus what the scan actually saw, so an unchanged
# repository stays silent and any real change re-reports immediately.
$repoState = ''
try { $repoState = [string](Get-RepoStateFingerprint -ProjectRoot $cwd) } catch { $repoState = '' }
$fingerprint = Get-ShortHash (
    $cwd.ToLowerInvariant() + '|' + $repoState + '|' +
    ($signatureParts -join ';') + '|' + (($findings.ToArray()) -join ';') + '|' + ($configWarnings.ToArray() -join ';'))

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('TestPlanCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.json')

if (-not $alwaysReport) {
    $previous = $null
    try { $previous = Read-JsonFile $statePath } catch { $previous = $null }
    if ($null -ne $previous) {
        $previousFingerprint = [string](Get-Field $previous 'fingerprint')
        # UTC TICKS, deliberately not an ISO string: ConvertFrom-Json silently
        # rehydrates an ISO timestamp into a LOCAL-kind [DateTime], so a stored
        # 'o' string comes back shifted by the local offset and the cooldown
        # would expire early (verified: a +03:30 offset expired a 120-minute
        # cooldown instantly). Ticks round-trip as a plain number.
        $previousTicks = [string](Get-Field $previous 'reportedUtcTicks')
        $parsedTicks = [int64]0
        if ($previousFingerprint -eq $fingerprint -and [int64]::TryParse($previousTicks, [ref]$parsedTicks)) {
            $elapsed = [DateTime]::UtcNow - (New-Object DateTime($parsedTicks, [DateTimeKind]::Utc))
            # Same state as last time AND still inside the cooldown -> silent.
            # A negative elapsed (clock moved back) is treated as "recent".
            if ($elapsed.TotalMinutes -lt $cooldownMinutes) { exit 0 }
        }
    }
}

try {
    Write-JsonFileAtomic -Value ([pscustomobject]@{
        fingerprint = $fingerprint
        reportedUtcTicks = [string]([DateTime]::UtcNow.Ticks)
        reportedUtc = [DateTime]::UtcNow.ToString('o')   # human-readable only; never parsed back
    }) -Path $statePath
}
catch { }

# ---- the advisory ------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('TEST PLAN CHECK - test-health policy for this task. Advisory only: this hook never runs a test and never edits a file.')
[void]$lines.Add('- Give every test run a bounded WALL timeout AND an idle/no-progress timeout. A run with no bound is a defect, not a slow test.')
[void]$lines.Add('- No long blind sleeps. Wait on a deterministic signal, a readiness check, or bounded polling - never a minute-scale sleep.')
[void]$lines.Add('- Keep parallelism resource-aware: max(2, min(8, cores-2)) workers, no nested oversubscription; do not re-serialize slow independent suites.')
[void]$lines.Add('- Terminate the whole owned process tree and clean temp/state in finally. A leaked worker, port, lock or temp directory is a failed run.')
[void]$lines.Add('- Discover suites instead of hardcoding a list, and keep every suite on disk mapped to a CI bucket.')
[void]$lines.Add('- High CPU alone never means hung. A kill needs a wall/idle/memory bound, or sustained resource use WITH no progress.')
[void]$lines.Add('- When optimising a suite, record before/after timing - "feels faster" is not evidence.')
if ($findings.Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add('Observed in this project right now (each line is a real file:line - open it and confirm before changing anything):')
    foreach ($finding in $findings) { [void]$lines.Add('- ' + $finding) }
}
if ($configWarnings.Count -gt 0) {
    [void]$lines.Add('')
    foreach ($warning in $configWarnings) { [void]$lines.Add('Test-Plan-Check .env: ' + $warning) }
}
[void]$lines.Add('')
[void]$lines.Add('Silent from here until this project''s test state changes or ' + $cooldownMinutes + ' minutes pass.')
$message = ($lines.ToArray() -join "`n")

$isClaude = ($null -ne (Get-Field $hookInput 'hookSpecificOutput')) -or (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR))
if ($isClaude) {
    $payload = @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } }
}
else {
    $payload = @{ systemMessage = $message }
}
$payload | ConvertTo-Json -Depth 5 -Compress | ForEach-Object { [Console]::Out.WriteLine($_) }
exit 0
