# LargeFileCheck - keeps source files under a HARD line ceiling. The guidance and
# the oversized-file report are ADVISORY: the hook never performs a split and
# never blocks a push. ONE Stop condition gates: a file THIS TASK pushed past the
# ceiling. The AI agent still decides where the extracted code goes, judging by
# responsibility - not the hook.
#
# 1. Pre-task (SessionStart / UserPromptSubmit): injects the ceiling policy so the
#    agent writes new code into the right file FROM THE START instead of growing
#    one huge file and decomposing later. SessionStart carries the full policy;
#    UserPromptSubmit carries a shorter reminder. Both quote the same effective
#    LINE_THRESHOLD. A new file must be a real responsibility, so the guidance is
#    equally against thin wrappers / forwarding files created to duck the number.
#    SessionStart ALSO records the baseline the Stop gate compares against (see 3).
# 2. Post-task (Stop / SubagentStop): scans the project for source files whose
#    line count is STRICTLY GREATER THAN the threshold (default 800 - so 801 is
#    reported, exactly 800 is not) and lists the largest offenders. Files already
#    present before the task are scanned too, and for those the report stays a
#    CLIENT-AWARE, NON-BLOCKING advisory (Claude:
#    hookSpecificOutput.additionalContext, Codex: systemMessage) - never
#    decision:block, which on Codex would coerce a new prompt at Stop. Silent
#    when nothing is oversized; per-project cooldown; stop_hook_active guard so it
#    never loops.
# 3. The ONE gate (Stop / SubagentStop): a source file that was at or under the
#    threshold in the SessionStart baseline and is over it NOW was pushed past the
#    ceiling by this task. That blocks ONCE PER FINGERPRINT with the exact recovery
#    (move the added code into a new responsibility-named file; no wrapper), which
#    is also what clears it. A file already over the threshold at baseline never
#    blocks - it stays advisory. Partial coverage (either scan) and a missing or
#    stale baseline never block: unknown is never treated as proof.
#
# -GitPrePush is advisory-only: it exits 0 without scanning or blocking. This hook
# never blocks a push.
#
# Token-efficient by design: deterministic pruned scan, per-project cooldown on
# Stop, and state lives under %LOCALAPPDATA%\HookMaker\state - never inside the
# scanned project. Two state files: the cooldown timestamp, keyed by a stable hash
# of the project path + threshold, and the SessionStart baseline (schema 1 JSON),
# keyed by the project path alone. The baseline is METADATA ONLY - relative path
# and line count per scanned source file, plus the walk's own partial flag. File
# CONTENTS are never read into it, never stored, and never leave the machine.
#
# Optional .env next to this script (copy .env.example):
#   LINE_THRESHOLD    lines above which a file is reported (default 800; a value
#                     that is missing/malformed/<50 or >100000 falls back to 800)
#   EXTENSIONS        comma-separated source extensions to scan
#   COOLDOWN_MINUTES  minimum minutes between Stop reports per project (default 60)
#   MAX_FILES         source-file scan ceiling (default 5000; when the ceiling is
#                     reached the report says so - partial, never all-clear)
#   MAX_DIRECTORIES   directory-traversal ceiling (default 4000, range 1..1000000):
#                     caps directories popped so a huge non-source tree cannot make
#                     the walk unbounded; reaching it marks the report partial and
#                     names "directories". Invalid/out-of-range falls back to 4000.
#   MAX_SCAN_SECONDS  total traversal wall-time ceiling in seconds (default 5, range
#                     1..3600): caps how long the walk may run; reaching it marks the
#                     report partial and names "time". Invalid/out-of-range -> 5.

param([switch]$GitPrePush)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# GitPrePush contract (single, consistent): this hook is advisory, never a push
# authorization gate. It exits 0 without scanning or blocking.
if ($GitPrePush) { exit 0 }

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) {
    $eventName = 'SessionStart'
}
$isStopEvent = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')

# ---- config: read .env ONCE, validate, one effective threshold for both stages ----
# Invalid config never crashes and never leaks a raw invalid value into a message.
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$lineThreshold = 800
if ($config.ContainsKey('LINE_THRESHOLD')) {
    $parsedThreshold = 0
    if ([int]::TryParse([string]$config['LINE_THRESHOLD'], [ref]$parsedThreshold) -and $parsedThreshold -ge 50 -and $parsedThreshold -le 100000) {
        $lineThreshold = $parsedThreshold
    }
}

# ---- pre-task: the ceiling policy (full on SessionStart, shorter on prompt) ----
# The ceiling is enforced AT WRITE TIME, so the policy is stated as a rule, not as
# a review signal: the old "review signal / small overage is fine / appending is
# correct" wording contradicted it and is gone. The prompt reminder is the first
# two bullets - the part that decides where the next write goes.
# UserPromptSubmit exits here: it must never pay for a filesystem walk. SessionStart
# falls through to record the baseline the Stop gate needs (guidance emitted first,
# so a scan problem can never cost the guidance).
$headline = "FILE SIZE POLICY - $lineThreshold lines is a HARD CEILING per source file, enforced when you write, so decomposition is never needed later."
$bullet1 = "- Before writing to ANY file, check its length. A file at or near the ceiling (about $($lineThreshold - 100) lines or more) is CLOSED to new code: create a new file named for the responsibility the new code carries, write there, wire it in with imports/re-exports."
$bullet2 = "- Never push a file past $lineThreshold lines; never grow a file already over it - extract from it instead."
$guidanceExitCode = 0
if (-not $isStopEvent) {
    if ($eventName -eq 'UserPromptSubmit') {
        $lines = @($headline, $bullet1, $bullet2)
    }
    else {
        $lines = @(
            $headline,
            $bullet1,
            $bullet2,
            "- A new file is a real responsibility: never a thin wrapper, forwarding file, or fragment created to duck the number. Test files count too. Put the ceiling in every subagent brief."
        )
    }
    $note = $lines -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    $guidanceExitCode = $emit.ExitCode
    if ($eventName -ne 'SessionStart') { exit $guidanceExitCode }
}

# ---- the scan: oversized files at Stop, the baseline at SessionStart ----
# Same bounded walk for both, so the two line counts are produced by identical
# rules and a difference can only mean the file really changed.
if ($isStopEvent -and (Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}
$recordBaseline = (-not $isStopEvent)

$cooldownMinutes = 60
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    $parsedCooldown = 0
    if ([int]::TryParse([string]$config['COOLDOWN_MINUTES'], [ref]$parsedCooldown) -and $parsedCooldown -ge 0 -and $parsedCooldown -le 100000) {
        $cooldownMinutes = $parsedCooldown
    }
}
$maxFiles = 5000
if ($config.ContainsKey('MAX_FILES')) {
    $parsedMax = 0
    if ([int]::TryParse([string]$config['MAX_FILES'], [ref]$parsedMax) -and $parsedMax -ge 1 -and $parsedMax -le 1000000) {
        $maxFiles = $parsedMax
    }
}
# MAX_FILES bounds only SOURCE files; without these two, a huge asset/non-source
# tree could make the walk run unbounded (dirs traversed / wall time) while
# $scannedFiles barely moves. Both validate exactly like MAX_FILES (safe fallback,
# documented range, invalid -> default), mirroring Test-Plan-Check.
$maxDirs = 4000
if ($config.ContainsKey('MAX_DIRECTORIES')) {
    $parsedDirs = 0
    if ([int]::TryParse([string]$config['MAX_DIRECTORIES'], [ref]$parsedDirs) -and $parsedDirs -ge 1 -and $parsedDirs -le 1000000) {
        $maxDirs = $parsedDirs
    }
}
$maxScanSeconds = 5
if ($config.ContainsKey('MAX_SCAN_SECONDS')) {
    $parsedSecs = 0
    if ([int]::TryParse([string]$config['MAX_SCAN_SECONDS'], [ref]$parsedSecs) -and $parsedSecs -ge 1 -and $parsedSecs -le 3600) {
        $maxScanSeconds = $parsedSecs
    }
}
# TEST-ONLY seam (NO effect in production): when LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES
# is set to a positive integer N, the in-file-loop wall-time check trips after N
# source files instead of consulting the real Stopwatch. It lets the offline suite
# prove a deterministic MID-directory time stop without depending on real wall-clock
# timing. Unset/invalid -> 0 -> inert, so production uses only $scanTimer.
$testTripAfterFiles = 0
if (-not [string]::IsNullOrWhiteSpace($env:LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES)) {
    $parsedTrip = 0
    if ([int]::TryParse([string]$env:LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES, [ref]$parsedTrip) -and $parsedTrip -ge 1) {
        $testTripAfterFiles = $parsedTrip
    }
}
$defaultExtensions = '.ps1,.psm1,.py,.js,.ts,.jsx,.tsx,.mjs,.cjs,.cs,.java,.go,.rb,.php,.rs,.c,.cpp,.h,.kt,.swift,.vue,.svelte'
$extensionList = $defaultExtensions
if ($config.ContainsKey('EXTENSIONS') -and $config['EXTENSIONS'] -ne '') {
    $extensionList = $config['EXTENSIONS']
}
$extensions = @{}
foreach ($ext in $extensionList.Split(',')) {
    $clean = $ext.Trim().ToLowerInvariant()
    if ($clean -ne '') {
        if (-not $clean.StartsWith('.')) { $clean = '.' + $clean }
        $extensions[$clean] = $true
    }
}
# A misconfigured EXTENSIONS (all blank) must not silently scan nothing.
if ($extensions.Count -eq 0) {
    foreach ($ext in $defaultExtensions.Split(',')) { $extensions[$ext] = $true }
}

# Stop output: NON-BLOCKING advisory, shaped by the shared adapter. The AI owns
# the split decision, so this hook NEVER emits decision:block (a real Stop gate
# that on Codex forces a new prompt - a coercive loop). Write-HookResult picks
# the client shape: Claude gets hookSpecificOutput.additionalContext, Codex gets
# systemMessage at Stop, and a client with no documented Stop context channel is
# reported as degraded instead of being handed a shape it cannot read.
function Write-Advisory {
    param([string]$Message)
    $null = Write-HookResult -EventName $script:eventName -Kind 'advisory' -Message $Message
}

# cooldown state (per project + threshold) - never written inside the scanned project
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('LargeFileCheck-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $lineThreshold)) + '.txt')
# The cooldown bounds the ADVISORY only. It deliberately no longer exits early:
# an advisory cooldown that also swallowed the gate would make the gate depend on
# when the last unrelated oversized-file report happened. The gate has its own,
# tighter bound (once per fingerprint).
$cooldownActive = $false
if ($isStopEvent -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            $cooldownActive = $true
        }
    }
    catch { }
}
# baseline state (per project) - the SessionStart snapshot the gate compares with.
$baselinePath = Join-Path $stateDir ('LargeFileCheckBaseline-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.json')

# Pruned recursive scan: generated/vendor directories are never entered, reparse
# points (junctions/symlinks) are never followed, files above 3 MB are skipped
# (binary/generated), streaming line reads, and the walk is bounded on THREE
# independent axes - source files (MAX_FILES), directories traversed
# (MAX_DIRECTORIES), and wall time (MAX_SCAN_SECONDS) - so it can never run away.
$excludedDirs = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync')
$offenders = New-Object System.Collections.Generic.List[object]
# Baseline rows, filled only on the SessionStart pass: relative path + line count,
# nothing else. Never populated at Stop, where only the offenders matter.
$baselineEntries = New-Object System.Collections.Generic.List[object]
$stack = New-Object System.Collections.Generic.Stack[string]
# A reparse-point ROOT (cwd itself a junction/symlink) is refused outright: its
# target can live anywhere, so walking it is the same escape the per-child check
# below already closes. Refuse before pushing anything - no scan, stay silent.
$rootIsReparse = $false
try { $rootIsReparse = ((([System.IO.File]::GetAttributes($cwd)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
if ($rootIsReparse) { exit 0 }
$stack.Push($cwd)
$scannedFiles = 0
$dirsVisited = 0
$scanTimer = [System.Diagnostics.Stopwatch]::StartNew()
# Partial-coverage flags - each names a DISTINCT reason the walk stopped short,
# so the advisory/offender report states the REAL cause(s), never a guess:
#   $scanLimitReached  the MAX_FILES source-file ceiling, set at the EXACT stop
#                      point - between directories (outer gate) OR inside one large
#                      directory (inner gate). Deriving "partial" from the residual
#                      stack alone missed the ceiling filling up inside one big dir.
#   $dirLimitReached   the MAX_DIRECTORIES directory-traversal ceiling.
#   $timeLimitReached  the MAX_SCAN_SECONDS wall-time ceiling, checked between
#                      directories AND before each SOURCE file inside a directory
#                      (a cheap Stopwatch read, gated behind the extension check so
#                      non-source files never pay for it), so a single huge
#                      directory can no longer overrun the advertised ceiling.
#   $scanIncomplete    a READ FAILURE (access denied, locked file, unreadable
#                      directory) - a single failure must not abort the whole
#                      directory. ANY flag means the project was not fully scanned,
#                      so a no-offender result is NOT an all-clear.
$scanLimitReached = $false
$dirLimitReached = $false
$timeLimitReached = $false
$scanIncomplete = $false
while ($stack.Count -gt 0) {
    if ($scannedFiles -ge $maxFiles) { $scanLimitReached = $true; break }
    if ($dirsVisited -ge $maxDirs) { $dirLimitReached = $true; break }
    if ($scanTimer.Elapsed.TotalSeconds -ge $maxScanSeconds) { $timeLimitReached = $true; break }
    $currentDir = $stack.Pop()
    $dirsVisited++
    # Per-CHILD and per-FILE isolation: one unreadable entry must not abort the
    # whole directory and silently shrink coverage. A failure is recorded in
    # $scanIncomplete (partial coverage), never swallowed into a false all-clear.
    $childDirs = @()
    try { $childDirs = @([System.IO.Directory]::EnumerateDirectories($currentDir)) } catch { $scanIncomplete = $true }
    foreach ($childDir in $childDirs) {
        try {
            $leaf = Split-Path -Leaf $childDir
            if ($excludedDirs -contains $leaf.ToLowerInvariant()) { continue }
            # A virtualenv is pruned by its PEP 405 marker, not its name (see _hooklib.ps1).
            if (Test-IsMarkerPrunedDirectory $childDir) { continue }
            # Never follow a reparse point (junction/symlink): it can escape the
            # project or loop back on it. Skip before descent.
            if (([System.IO.File]::GetAttributes($childDir) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $stack.Push($childDir)
        }
        catch { $scanIncomplete = $true }
    }
    $files = @()
    try { $files = @([System.IO.Directory]::EnumerateFiles($currentDir)) } catch { $scanIncomplete = $true }
    foreach ($file in $files) {
        try {
            # Extension is checked BEFORE the ceiling so the MAX_FILES ceiling
            # counts only IN-SCOPE (source) files. A trailing non-source file
            # (e.g. README.md) must never trip a false PARTIAL when no source
            # file was actually skipped.
            $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
            if (-not $extensions.ContainsKey($extension)) { continue }
            # Enforce the ceiling as a real PER-SOURCE-FILE stop. Without this, a
            # single directory holding far more source files than MAX_FILES was
            # scanned whole, because the ceiling was only re-checked between dirs.
            if ($scannedFiles -ge $maxFiles) { $scanLimitReached = $true; break }
            # Same for wall time: re-check MAX_SCAN_SECONDS here so one directory
            # holding thousands of source files cannot overrun the advertised
            # ceiling (the between-directories check alone let that happen). The
            # test seam forces a deterministic trip; production consults $scanTimer.
            $timeUp = if ($testTripAfterFiles -gt 0) { $scannedFiles -ge $testTripAfterFiles } else { $scanTimer.Elapsed.TotalSeconds -ge $maxScanSeconds }
            if ($timeUp) { $timeLimitReached = $true; break }
            $scannedFiles++
            $info = [System.IO.FileInfo]::new($file)
            if ($info.Length -gt 3MB) { continue }
            $lineCount = 0
            foreach ($null_ in [System.IO.File]::ReadLines($file)) { $lineCount++ }
            $relative = $file.Substring($cwd.Length).TrimStart('\', '/')
            # METADATA ONLY: the path and the number of lines. The loop above counts
            # line terminators and keeps no line, so no content can reach the state.
            if ($recordBaseline) { [void]$baselineEntries.Add([pscustomobject]@{ p = $relative; l = $lineCount }) }
            if ($lineCount -gt $lineThreshold) {
                [void]$offenders.Add([pscustomobject]@{ Path = $relative; Lines = $lineCount })
            }
        }
        catch { $scanIncomplete = $true }
    }
    # A mid-directory wall-time trip must stop the WHOLE traversal at once, not
    # just the current directory - otherwise any directories still on the stack
    # would be walked past the ceiling. (MAX_FILES relies on the loop-top re-check;
    # the time check deliberately does not re-run at the loop top, so break here.)
    if ($timeLimitReached) { break }
}
# Honest coverage: partial when ANY ceiling stopped the walk (source files,
# directories, or wall time) OR any file/dir could not be read. Build ONE shared
# cause string naming the REAL reason(s) - reused by BOTH the no-offender advisory
# and the offender report, so neither ever assumes a cause it did not actually hit.
$causes = New-Object System.Collections.Generic.List[string]
if ($scanLimitReached) { [void]$causes.Add('a source-file scan ceiling of ' + $maxFiles + ' files was reached') }
if ($dirLimitReached) { [void]$causes.Add('a directory ceiling of ' + $maxDirs + ' directories was reached') }
if ($timeLimitReached) { [void]$causes.Add('a scan time limit of ' + $maxScanSeconds + ' seconds was reached') }
if ($scanIncomplete) { [void]$causes.Add('one or more files or directories could not be read') }
$partial = $causes.Count -gt 0
$partialCause = $causes -join ' and '

# ---- SessionStart: store the baseline, then finish the guidance emission ----
# Written every SessionStart, so "baseline" always means the start of THIS task.
# A failed write is not fatal: the gate then has no baseline and stays silent,
# which is the fail-open direction (unknown never blocks).
if ($recordBaseline) {
    try {
        Write-JsonFileAtomic -Value ([pscustomobject]@{
                schema               = 1
                baseline             = [pscustomobject]@{
                    createdUtcTicks = [string]([DateTime]::UtcNow.Ticks)
                    partial         = $partial
                    files           = @($baselineEntries.ToArray())
                }
                lastBlockFingerprint = ''
                updatedUtc           = [DateTime]::UtcNow.ToString('o')
            }) -Path $baselinePath
    }
    catch { }
    exit $guidanceExitCode
}

# ---- the gate: files THIS TASK pushed past the ceiling --------------------
# Blocks only on evidence the task itself created: baseline count <= threshold,
# current count > threshold. Everything unproven stays advisory - a file already
# over the ceiling at baseline, a missing/stale/unreadable baseline, and any
# partial coverage on either side. The baseline goes stale at 7 days: older than
# that it no longer describes "this task" (the Utf8-Encoding-Check rule).
$baselineDoc = $null
try { $baselineDoc = Read-JsonFile $baselinePath } catch { $baselineDoc = $null }
$baselineLines = @{}
$baselineUsable = $false
$lastBlockFingerprint = ''
if ($null -ne $baselineDoc) {
    $lastBlockFingerprint = [string](Get-Field $baselineDoc 'lastBlockFingerprint')
    $baselineNode = Get-Field $baselineDoc 'baseline'
    if ($null -ne $baselineNode) {
        $ticks = [int64]0
        if ([int64]::TryParse([string](Get-Field $baselineNode 'createdUtcTicks'), [ref]$ticks) -and $ticks -gt 0) {
            $age = [DateTime]::UtcNow - (New-Object DateTime($ticks, [DateTimeKind]::Utc))
            if ($age.TotalDays -le 7 -and $age.TotalDays -ge -1 -and (Get-Field $baselineNode 'partial') -ne $true) {
                $baselineUsable = $true
                foreach ($entry in @(Get-Field $baselineNode 'files')) {
                    if ($null -eq $entry) { continue }
                    $entryPath = [string](Get-Field $entry 'p')
                    $entryLines = 0
                    if ($entryPath -ne '' -and [int]::TryParse([string](Get-Field $entry 'l'), [ref]$entryLines)) {
                        $baselineLines[$entryPath] = $entryLines
                    }
                }
            }
        }
    }
}

if ($baselineUsable -and -not $partial) {
    $grown = New-Object System.Collections.Generic.List[object]
    foreach ($offender in $offenders.ToArray()) {
        if (-not $baselineLines.ContainsKey($offender.Path)) { continue }
        $was = [int]$baselineLines[$offender.Path]
        if ($was -le $lineThreshold) {
            [void]$grown.Add([pscustomobject]@{ Path = $offender.Path; Lines = $offender.Lines; Was = $was })
        }
    }
    if ($grown.Count -gt 0) {
        # Once per fingerprint: the same unchanged set blocks once, any change
        # (a fixed file, another file over the line, a new session) is new state
        # and is evaluated at once. Without this, an unresolved file would block
        # every Stop for the rest of the session.
        $sessionId = [string](Get-Field $hookInput 'session_id')
        $signature = @($grown.ToArray() | ForEach-Object { $_.Path + ':' + $_.Lines } | Sort-Object) -join ';'
        $fingerprint = Get-ShortHash ($sessionId + '|' + $lineThreshold + '|' + $signature)
        if ($fingerprint -ne $lastBlockFingerprint) {
            try {
                Write-JsonFileAtomic -Value ([pscustomobject]@{
                        schema               = 1
                        baseline             = (Get-Field $baselineDoc 'baseline')
                        lastBlockFingerprint = $fingerprint
                        updatedUtc           = [DateTime]::UtcNow.ToString('o')
                    }) -Path $baselinePath
            }
            catch { }
            $shown = @($grown.ToArray() | Sort-Object -Property Lines -Descending | Select-Object -First 5)
            $blockLines = New-Object System.Collections.Generic.List[string]
            [void]$blockLines.Add('LARGE FILE CHECK: this task pushed ' + $grown.Count + ' source file(s) past the ' + $lineThreshold + '-line hard ceiling (each was at or under it when this session started):')
            foreach ($item in $shown) {
                [void]$blockLines.Add('- ' + $item.Path + ' (' + $item.Lines + ' lines now, ' + $item.Was + ' at session start): move the code added to ' + $item.Path + ' into a new responsibility-named file; do not create a wrapper.')
            }
            if ($grown.Count -gt $shown.Count) {
                [void]$blockLines.Add('(+' + ($grown.Count - $shown.Count) + ' more file(s) in the same state, same recovery.)')
            }
            [void]$blockLines.Add('Do that for each file above - a real responsibility, never a thin wrapper, forwarding file, or fragment created to duck the number - then stop again. This block clears as soon as each file above is back at or under ' + $lineThreshold + ' lines.')
            # Record the block the way every sibling Stop gate does, so
            # Session-Summary-Check can account for it.
            Set-StopBlockMarker -HookInput $hookInput -HookName 'Large-File-Check'
            exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason ($blockLines.ToArray() -join "`n")).ExitCode
        }
    }
}

if ($offenders.Count -eq 0) {
    # Full scan, nothing oversized -> silent (the common case). But a PARTIAL
    # scan that found nothing is NOT an all-clear: the ceiling cut the walk
    # short, so unscanned files may exist. Emit a short, non-blocking advisory
    # (same client shape as the pre-task branch) rather than a false silence.
    # Cooldown is honoured via the shared state file so it cannot spam.
    if ($partial -and -not $cooldownActive) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))
        $coverageNote = 'LARGE FILE CHECK: coverage was INCOMPLETE - ' + $partialCause + ' before the whole project was scanned, so no oversized-file all-clear can be concluded. No offender was found in the scanned portion, but unscanned files may remain. Advisory only - not a block.'
        Write-Advisory $coverageNote
    }
    exit 0
}

# The offender report is the advisory half, so here the cooldown applies: an
# unchanged repeat inside the window stays silent, exactly as before.
if ($cooldownActive) { exit 0 }

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$top = @($offenders | Sort-Object -Property Lines -Descending | Select-Object -First 5)
$fileLines = @($top | ForEach-Object { $_.Path + ' (' + $_.Lines + ' lines)' })
$more = ''
if ($offenders.Count -gt $top.Count) {
    $more = ' and ' + ($offenders.Count - $top.Count) + ' more'
}
$partialNote = if ($partial) { ' (PARTIAL scan: ' + $partialCause + ', so this list may be incomplete - not full-repository coverage.)' } else { '' }
$reason = 'LARGE FILE CHECK: ' + $offenders.Count + ' source file(s) exceed ' + $lineThreshold + ' lines: ' + ($fileLines -join '; ') + $more + '.' + $partialNote + ' These were ALREADY over the ceiling before this task, so this is advisory and nothing here blocks: the ceiling binds what you WRITE, and the gate fires only on a file this task itself pushed past it. What the ceiling does require of these files is that they stop growing - put new code in a new file named for the responsibility it carries and wire it in, and extract from the file rather than adding to it. Split by a real responsibility, cohesive module, layer or public boundary that actually exists there; never create a thin wrapper, pass-through module or arbitrary fragment merely to get under the number, and never start a refactor unrelated to the current task just because a file is large. If you do split: keep a single clear entry point, update imports/re-exports, avoid circular dependencies, and run build/tests afterwards. This reminder respects a cooldown.'
Write-Advisory $reason
exit 0
