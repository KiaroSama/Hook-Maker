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
#   TEST_PLAN_COOLDOWN_MINUTES   minutes before an unchanged finding repeats (default 120)
#   TEST_PLAN_EXTRA_KEYWORDS     extra comma-separated project relevance keywords
#   TEST_PLAN_ALWAYS_REPORT      1 = ignore the cooldown (hook debugging; default 0)
#   TEST_PLAN_MAX_DIRS           directories the scan may visit          (default 4000)
#   TEST_PLAN_MAX_FILES          candidate test files it may inspect     (default 200)
#   TEST_PLAN_MAX_FILE_KB        KB read from any one file               (default 400)
#   TEST_PLAN_MAX_SCAN_SECONDS   total wall time for the whole scan      (default 5)
#   TEST_PLAN_MAX_FINDINGS       findings emitted before it stops        (default 8)
# An invalid value is reported in plain text inside the advisory and the
# default is used - a malformed setting must never block or crash a session.
# Hitting any ceiling (or an unreadable directory) makes the scan PARTIAL, and
# the advisory says so instead of implying the whole repository was covered.

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

# Every integer ceiling shares one validated reader: a value outside [Min..Max]
# (or non-numeric) is reported once and the documented safe default is used.
function Read-BoundedIntSetting {
    param([string]$Key, [int]$Default, [int]$Min, [int]$Max)
    if (-not $config.ContainsKey($Key)) { return $Default }
    $raw = [string]$config[$Key]
    $parsed = 0
    if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) { return $parsed }
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$configWarnings.Add($Key + ' is not an integer in ' + $Min + '..' + $Max + '; using the default ' + $Default + '.')
    }
    return $Default
}

$cooldownMinutes = Read-BoundedIntSetting 'TEST_PLAN_COOLDOWN_MINUTES' 120 1 10080

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

# ---- bounded, read-only, iterative risk scan --------------------------------
# An EXPLICIT-STACK directory walk that PRUNES excluded trees before descending
# (node_modules/.git/.venv are never even enumerated), refuses a reparse-point
# ROOT, and never follows a child reparse point (junction/symlink). Every
# dimension is capped and configurable: directories visited, candidate test files
# inspected, bytes read per file, total wall time, and findings emitted. The wall
# time is enforced BETWEEN directories and DURING file/subdir enumeration, so one
# huge directory cannot overrun the ceiling. Everything reported still carries a
# file:line the reader can open; nothing is inferred or theoretical.
$maxDirs      = Read-BoundedIntSetting 'TEST_PLAN_MAX_DIRS'          4000 1 1000000
$maxFiles     = Read-BoundedIntSetting 'TEST_PLAN_MAX_FILES'          200 1 100000
$maxFileBytes = 1KB * (Read-BoundedIntSetting 'TEST_PLAN_MAX_FILE_KB' 400 1 1048576)
$maxSeconds   = Read-BoundedIntSetting 'TEST_PLAN_MAX_SCAN_SECONDS'     5 1 3600
$maxFindings  = Read-BoundedIntSetting 'TEST_PLAN_MAX_FINDINGS'         8 1 1000

# TEST-ONLY seam (NO effect in production; deliberately absent from .env.example).
# Mirrors Large-File-Check's LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES: when set to
# a positive integer N, the in-file-loop wall-time check trips after N
# extension-matching files instead of consulting the real Stopwatch, so the offline
# suite can prove a deterministic MID-ENUMERATION time stop without depending on
# real wall-clock timing. Unset/invalid -> 0 -> inert, so production uses only the
# real $scanTimer.
$testTripAfterFiles = 0
if (-not [string]::IsNullOrWhiteSpace($env:TESTPLANCHECK_TEST_TRIP_TIME_AFTER_FILES)) {
    $parsedTrip = 0
    if ([int]::TryParse($env:TESTPLANCHECK_TEST_TRIP_TIME_AFTER_FILES, [ref]$parsedTrip) -and $parsedTrip -ge 1) {
        $testTripAfterFiles = $parsedTrip
    }
}

# Directory names pruned BEFORE descent - mirrors Secrets-Check.ps1 $excludedDirs
# (plus .tox/site-packages that this scan has always skipped).
$excludedDirs = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj', '.tox', 'site-packages')
$extRegex = '(?i)^\.(ps1|psm1|py|js|mjs|cjs|ts|sh|rb|go)$'

# Partial-coverage flags - each names a DISTINCT reason the walk stopped short, so
# the advisory states the REAL cause(s), never a guess (mirrors Large-File-Check):
#   $fileLimitReached     the candidate-file (MAX_FILES) ceiling.
#   $dirLimitReached      the MAX_DIRS directory-traversal ceiling.
#   $timeLimitReached     the MAX_SCAN_SECONDS wall-time ceiling, now checked
#                         BETWEEN directories AND per file (behind the extension
#                         match) AND per subdir, so a single huge directory can no
#                         longer overrun the advertised ceiling during enumeration.
#   $findingsLimitReached the MAX_FINDINGS ceiling (set in the processing loop).
#   $scanIncomplete       a read failure (locked/unreadable directory or file).
#   $rootReparse          the scan ROOT itself is a junction/symlink; it is refused
#                         (nothing pushed) so no finding can come from behind it.
# ANY flag means the project was not fully scanned, so a no-finding result is NOT
# an all-clear.
$fileLimitReached = $false
$dirLimitReached = $false
$timeLimitReached = $false
$findingsLimitReached = $false
$scanIncomplete = $false
$rootReparse = $false
$dirsVisited = 0
$filesScanned = 0
$scanTimer = [System.Diagnostics.Stopwatch]::StartNew()
$candidates = New-Object System.Collections.Generic.List[object]

$rootFull = $cwd.TrimEnd('\', '/')
try { $rootFull = (Get-Item -LiteralPath $cwd -Force -ErrorAction Stop).FullName.TrimEnd('\', '/') } catch { }
# A reparse-point ROOT (cwd itself a junction/symlink) is refused: its target can
# live anywhere, so walking it is the same escape the per-child check below closes.
# Unlike Large-File-Check (a silent Stop hook that exits here) this hook still emits
# its advisory, so it does not exit - it pushes nothing and marks the scan PARTIAL,
# so no finding can come from behind the junction.
try { $rootReparse = ((([System.IO.File]::GetAttributes($rootFull)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
$stack = New-Object System.Collections.Generic.Stack[string]
if (-not $rootReparse) { $stack.Push($rootFull) }
while ($stack.Count -gt 0) {
    if ($candidates.Count -ge $maxFiles) { $fileLimitReached = $true; break }
    if ($dirsVisited -ge $maxDirs) { $dirLimitReached = $true; break }
    if ($scanTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
    $current = $stack.Pop()
    $dirsVisited++

    # Child directories are enumerated and pushed FIRST, files LAST, so the single
    # time-break after file processing stops the WHOLE walk at once (matching
    # Large-File-Check). Each enumerate is materialized inside its own try so an
    # unreadable directory marks partial coverage without aborting the walk.
    $childDirs = @()
    try { $childDirs = @([System.IO.Directory]::EnumerateDirectories($current)) } catch { $scanIncomplete = $true }
    foreach ($dirPath in $childDirs) {
        # Per-subdir wall check: this hook does a Get-Item per subdirectory, so a
        # directory with very many subdirectories must not overrun the ceiling
        # during enumeration either.
        if ($scanTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
        $dir = Get-Item -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $dir -or ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
        if ($excludedDirs -notcontains $dir.Name.ToLowerInvariant()) { $stack.Push($dir.FullName) }
    }
    if ($timeLimitReached) { break }

    $files = @()
    try { $files = @([System.IO.Directory]::EnumerateFiles($current)) } catch { $scanIncomplete = $true }
    foreach ($filePath in $files) {
        if ($candidates.Count -ge $maxFiles) { $fileLimitReached = $true; break }
        if ([System.IO.Path]::GetExtension($filePath) -notmatch $extRegex) { continue }
        # TIME check gated behind the cheap extension match (like Large-File-Check):
        # only extension-matching files pay the Stopwatch read, but a huge single
        # directory of non-test yet extension-matching files can no longer overrun
        # the advertised ceiling DURING enumeration (the between-directories check
        # alone let that happen). The seam forces a deterministic trip in tests;
        # production consults $scanTimer.
        $timeUp = if ($testTripAfterFiles -gt 0) { $filesScanned -ge $testTripAfterFiles } else { $scanTimer.Elapsed.TotalSeconds -ge $maxSeconds }
        if ($timeUp) { $timeLimitReached = $true; break }
        $filesScanned++
        $name = [System.IO.Path]::GetFileName($filePath)
        $isTest = ($name -match '(?i)(^|[\\/._-])(test|tests|spec)') -or ($current -match '(?i)[\\/](tests?|spec|specs|__tests__)([\\/]|$)')
        if (-not $isTest) { continue }
        # Only now touch the filesystem for metadata; skip file-level reparse points too.
        $info = Get-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
        if ($null -eq $info -or ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
        [void]$candidates.Add($info)
    }
    if ($timeLimitReached) { break }
}

$testFiles = @($candidates.ToArray() | Sort-Object FullName | Select-Object -First $maxFiles)

# A file that shows ANY of these is treated as having a visible bound, so the
# no-bound findings stay conservative (a false silence beats a false warning).
$boundTokenPattern = '(?i)(timeout|deadline|elapsed|stopwatch|maxwait|max_wait|max-wait|maxattempt|max_attempt|waitforexit\(\s*[^)\s]|-wait\b|cancellationtoken|SIGALRM|ctrl\+c)'

$findings = New-Object System.Collections.Generic.List[string]
$signatureParts = New-Object System.Collections.Generic.List[string]

foreach ($file in $testFiles) {
    if ($scanTimer.Elapsed.TotalSeconds -ge $maxSeconds) { $timeLimitReached = $true; break }
    if ($file.Length -gt $maxFileBytes) {
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

        if ($findings.Count -ge $maxFindings) { $findingsLimitReached = $true; break }
    }
    if ($findings.Count -ge $maxFindings) { $findingsLimitReached = $true; break }
}

# Honest coverage: partial when ANY cause stopped the walk short. Build ONE shared
# cause string naming the REAL reason(s), reused by the advisory NOTE below, so it
# never assumes a cause it did not actually hit (mirrors Large-File-Check).
$causes = New-Object System.Collections.Generic.List[string]
if ($rootReparse) { [void]$causes.Add('the scan root is a junction/symlink and was not followed') }
if ($fileLimitReached) { [void]$causes.Add('a candidate-file ceiling of ' + $maxFiles + ' files was reached') }
if ($dirLimitReached) { [void]$causes.Add('a directory ceiling of ' + $maxDirs + ' directories was reached') }
if ($timeLimitReached) { [void]$causes.Add('a scan time limit of ' + $maxSeconds + ' seconds was reached') }
if ($findingsLimitReached) { [void]$causes.Add('a findings ceiling of ' + $maxFindings + ' was reached') }
if ($scanIncomplete) { [void]$causes.Add('one or more files or directories could not be read') }
$partialScan = $causes.Count -gt 0
$partialCause = $causes -join ' and '

# ---- compact project/state fingerprint --------------------------------------
# git state (when available) plus what the scan actually saw, so an unchanged
# repository stays silent and any real change re-reports immediately.
$repoState = ''
try { $repoState = [string](Get-RepoStateFingerprint -ProjectRoot $cwd) } catch { $repoState = '' }
$fingerprint = Get-ShortHash (
    $cwd.ToLowerInvariant() + '|' + $repoState + '|' +
    ($signatureParts -join ';') + '|' + (($findings.ToArray()) -join ';') + '|' + ($configWarnings.ToArray() -join ';') + '|partial=' + $partialScan)

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
if ($partialScan) {
    [void]$lines.Add('')
    [void]$lines.Add('NOTE: this scan was PARTIAL - ' + $partialCause + ' before the whole repository was covered. Treat the findings above as a sample, not a complete audit.')
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
