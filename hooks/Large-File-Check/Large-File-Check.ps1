# LargeFileCheck - keeps source files small and splittable. Two stages, both
# ADVISORY: it never performs a split and never blocks a push. The AI agent makes
# every architectural decision, judging by responsibility and cohesion - not the
# hook, and never from line count alone.
#
# 1. Pre-task (SessionStart / UserPromptSubmit): injects preventive guidance so
#    the agent designs code into the right file/module FROM THE START instead of
#    growing one huge file and decomposing later. SessionStart carries the full
#    compact policy; UserPromptSubmit carries a shorter reminder. Both quote the
#    same effective LINE_THRESHOLD. Cohesion outranks line count, so the guidance
#    is equally against thin wrappers / pass-through files created merely to duck
#    the threshold.
# 2. Post-task (Stop / SubagentStop): scans the project for source files whose
#    line count is STRICTLY GREATER THAN the threshold (default 800 - so 801 is
#    reported, exactly 800 is not) and lists the largest offenders. Files already
#    present before the task are scanned too. A split is never mandatory and 801
#    never forces one; the report is a review signal, decided by the AI. The
#    Stop output is a CLIENT-AWARE, NON-BLOCKING advisory (Claude:
#    hookSpecificOutput.additionalContext, Codex: systemMessage) - never
#    decision:block, which on Codex would coerce a new prompt at Stop. Silent
#    when nothing is oversized; per-project cooldown; stop_hook_active guard so it
#    never loops.
#
# -GitPrePush is advisory-only: it exits 0 without scanning or blocking. This hook
# never blocks a push.
#
# Token-efficient by design: deterministic pruned scan, per-project cooldown on
# Stop, and state (the cooldown timestamp) lives under %LOCALAPPDATA%\HookMaker\
# state keyed by a stable hash of the project path + threshold - never inside the
# scanned project.
#
# Optional .env next to this script (copy .env.example):
#   LINE_THRESHOLD    lines above which a file is reported (default 800; a value
#                     that is missing/malformed/<50 or >100000 falls back to 800)
#   EXTENSIONS        comma-separated source extensions to scan
#   COOLDOWN_MINUTES  minimum minutes between Stop reports per project (default 60)
#   MAX_FILES         source-file scan ceiling (default 5000; when the ceiling is
#                     reached the report says so - partial, never all-clear)

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

# ---- pre-task: preventive size guidance (full on SessionStart, shorter on prompt) ----
if (-not $isStopEvent) {
    if ($eventName -eq 'UserPromptSubmit') {
        $lines = @(
            "FILE SIZE POLICY (prevent avoidable oversized files; ~$lineThreshold lines is a REVIEW SIGNAL, not a law):",
            "- Before adding substantial code, check the destination file's current size and responsibility; if the change would push it well past $lineThreshold lines and a real boundary exists, design the new code into the correct file/module from the start.",
            "- Cohesion outranks line count: append when the code shares the file's responsibility; do NOT create thin wrappers, pass-through modules, or one-function files just to stay under the number.",
            "- A small overage (e.g. $($lineThreshold + 1)-$($lineThreshold + 20) lines) needs conscious review, not a forced split - especially if it introduces a NEW responsibility. The architectural decision is yours (the AI agent), not the hook's."
        )
    }
    else {
        $lines = @(
            "FILE SIZE POLICY - design correctly from the start (~$lineThreshold lines is a REVIEW SIGNAL, not an architectural law):",
            "- Before adding substantial code, inspect the destination file's current size and responsibility, and estimate whether the planned change brings it near or above $lineThreshold lines.",
            "- Do NOT create one very large file and postpone decomposition until the end; when a real responsibility, cohesive module, layer, feature, or public-API boundary exists, put the new code in the correct file/module from the start.",
            "- Prefer keeping ordinary source files below $lineThreshold lines, but appending is correct when the new code genuinely belongs to the same responsibility as that file.",
            "- A small justified overage (e.g. $($lineThreshold + 1)-$($lineThreshold + 20) lines) does not require a forced split; it still needs conscious architectural review, more so when it adds a NEW responsibility.",
            "- Never generate wrappers, forwarding files, arbitrary fragments, or one-function files merely to stay numerically under the threshold - cohesion and maintainability outrank raw line count.",
            "- When working in a file already oversized, do not refactor unrelated parts for the current task, but do not make it worse; if the task itself touches that file and a safe, directly relevant responsibility boundary is obvious, a bounded split is fine.",
            "- Architectural analysis and the final split decision are yours (the AI agent), not the hook's."
        )
    }
    $note = $lines -join "`n"
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---- post-task (Stop): scan for oversized source files ----
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}

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

# Stop output: CLIENT-AWARE, NON-BLOCKING advisory. Mirrors Test-Completion-Check
# / Ci-Status-Check: the AI owns the split decision, so this hook NEVER emits
# decision:block (a real Stop gate that on Codex forces a new prompt - a coercive
# loop). Claude Code exports CLAUDE_PROJECT_DIR on every hook process, Codex does
# not - the same signal the other Stop hooks use. Claude gets
# hookSpecificOutput.additionalContext; Codex gets systemMessage.
function Write-Advisory {
    param([string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) {
        @{ hookSpecificOutput = @{ hookEventName = $script:eventName; additionalContext = $Message } } | ConvertTo-Json -Depth 5 -Compress
    }
    else {
        @{ systemMessage = $Message } | ConvertTo-Json -Depth 5 -Compress
    }
}

# cooldown state (per project + threshold) - never written inside the scanned project
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('LargeFileCheck-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $lineThreshold)) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# Pruned recursive scan: generated/vendor directories are never entered, reparse
# points (junctions/symlinks) are never followed, files above 3 MB are skipped
# (binary/generated), streaming line reads, and the walk is capped for safety.
$excludedDirs = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync')
$offenders = New-Object System.Collections.Generic.List[object]
$stack = New-Object System.Collections.Generic.Stack[string]
# A reparse-point ROOT (cwd itself a junction/symlink) is refused outright: its
# target can live anywhere, so walking it is the same escape the per-child check
# below already closes. Refuse before pushing anything - no scan, stay silent.
$rootIsReparse = $false
try { $rootIsReparse = ((([System.IO.File]::GetAttributes($cwd)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
if ($rootIsReparse) { exit 0 }
$stack.Push($cwd)
$scannedFiles = 0
# $scanLimitReached is the single source of truth for partial coverage: it is
# set at the EXACT point traversal stops because of the file ceiling - either
# between directories (outer gate) or inside one large directory (inner gate).
# Deriving "partial" from the residual stack alone missed the case where the
# ceiling fills up inside one big directory while the stack is already empty.
$scanLimitReached = $false
# $scanIncomplete is coverage lost to a READ FAILURE (access denied, locked
# file, an unreadable directory) - separate from the ceiling. A single failure
# must not abort the whole directory, and either flag means the project was not
# fully scanned, so a no-offender result is NOT an all-clear.
$scanIncomplete = $false
while ($stack.Count -gt 0) {
    if ($scannedFiles -ge $maxFiles) { $scanLimitReached = $true; break }
    $currentDir = $stack.Pop()
    # Per-CHILD and per-FILE isolation: one unreadable entry must not abort the
    # whole directory and silently shrink coverage. A failure is recorded in
    # $scanIncomplete (partial coverage), never swallowed into a false all-clear.
    $childDirs = @()
    try { $childDirs = @([System.IO.Directory]::EnumerateDirectories($currentDir)) } catch { $scanIncomplete = $true }
    foreach ($childDir in $childDirs) {
        try {
            $leaf = Split-Path -Leaf $childDir
            if ($excludedDirs -contains $leaf.ToLowerInvariant()) { continue }
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
            $scannedFiles++
            $info = [System.IO.FileInfo]::new($file)
            if ($info.Length -gt 3MB) { continue }
            $lineCount = 0
            foreach ($null_ in [System.IO.File]::ReadLines($file)) { $lineCount++ }
            if ($lineCount -gt $lineThreshold) {
                $relative = $file.Substring($cwd.Length).TrimStart('\', '/')
                [void]$offenders.Add([pscustomobject]@{ Path = $relative; Lines = $lineCount })
            }
        }
        catch { $scanIncomplete = $true }
    }
}
# Honest coverage: partial when the ceiling stopped the walk OR any file/dir
# could not be read. Either way an unscanned region may hide an oversized file.
$partial = $scanLimitReached -or $scanIncomplete

if ($offenders.Count -eq 0) {
    # Full scan, nothing oversized -> silent (the common case). But a PARTIAL
    # scan that found nothing is NOT an all-clear: the ceiling cut the walk
    # short, so unscanned files may exist. Emit a short, non-blocking advisory
    # (same client shape as the pre-task branch) rather than a false silence.
    # Cooldown is honoured via the shared state file so it cannot spam.
    if ($partial) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))
        $causes = New-Object System.Collections.Generic.List[string]
        if ($scanLimitReached) { [void]$causes.Add('a scan ceiling of ' + $maxFiles + ' files was reached') }
        if ($scanIncomplete) { [void]$causes.Add('one or more files or directories could not be read') }
        $coverageNote = 'LARGE FILE CHECK: coverage was INCOMPLETE - ' + ($causes -join ' and ') + ' before the whole project was scanned, so no oversized-file all-clear can be concluded. No offender was found in the scanned portion, but unscanned files may remain. Advisory only - not a block.'
        Write-Advisory $coverageNote
    }
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$top = @($offenders | Sort-Object -Property Lines -Descending | Select-Object -First 5)
$fileLines = @($top | ForEach-Object { $_.Path + ' (' + $_.Lines + ' lines)' })
$more = ''
if ($offenders.Count -gt $top.Count) {
    $more = ' and ' + ($offenders.Count - $top.Count) + ' more'
}
$partialNote = if ($partial) { ' (PARTIAL scan: a scan ceiling was reached, so this list may be incomplete - not full-repository coverage.)' } else { '' }
$reason = 'LARGE FILE CHECK: ' + $offenders.Count + ' source file(s) exceed ' + $lineThreshold + ' lines: ' + ($fileLines -join '; ') + $more + '.' + $partialNote + ' No split is mandatory - this is advisory, and a slight overage (e.g. ' + ($lineThreshold + 1) + ' lines) is a REVIEW SIGNAL, not proof of bad architecture. Cohesion outranks raw line count: large or multi-responsibility files are the stronger split candidates, and a NEW responsibility pushed past the threshold is more concerning than a small cohesive overage. Only split when a real responsibility, cohesive module, layer, or public boundary actually exists there - never create thin wrappers, pass-through modules, or arbitrary fragments merely to get under the threshold, and never start a refactor unrelated to the current task just because a file is large. If you do split: split by responsibility, keep a single clear entry point, update imports/re-exports, avoid circular dependencies, and run build/tests afterwards. If a safe split is not warranted right now, finish with no split - this reminder respects a cooldown.'
Write-Advisory $reason
exit 0
