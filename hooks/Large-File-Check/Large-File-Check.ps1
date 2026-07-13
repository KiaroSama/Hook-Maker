# LargeFileCheck - keeps source files small and splittable.
#
# Two behaviors in one hook:
# - SessionStart / UserPromptSubmit (pre-task): injects a short reminder to
#   prefer small, multi-part files and not to create one big file unless
#   unavoidable (split by responsibility; ~500-800 logical lines = split signal).
# - Stop (post-task): scans the project for source files above the line
#   threshold and reports them, asking the AI to judge for itself whether a
#   split is SAFE and worthwhile. Silent when nothing is oversized.
#
# Token-efficient by design: deterministic scan, per-project cooldown on Stop,
# stop_hook_active guard (never loops), and the decision stays with the AI.
#
# Optional .env next to this script (copy .env.example):
#   LINE_THRESHOLD    lines above which a file is reported (default 800)
#   EXTENSIONS        comma-separated source extensions to scan
#   COOLDOWN_MINUTES  minimum minutes between Stop reports per project (default 60)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

# ---- pre-task: short policy reminder, nothing else ----
if (-not $isStopEvent) {
    $note = @(
        'FILE SIZE POLICY - prefer small, multi-part files:',
        '- Do not create one big file unless unavoidable; plan a multi-file layout up front and split by responsibility (features, layers, cohesive groups).',
        '- Treat ~500-800 logical lines as the signal to split; when extending an already-large file, prefer a new well-named file over appending.'
    ) -join "`n"
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---- post-task (Stop): scan for oversized source files ----
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}

# optional .env
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$lineThreshold = 800
if ($config.ContainsKey('LINE_THRESHOLD')) {
    try { $lineThreshold = [int]$config['LINE_THRESHOLD'] } catch { }
}
$cooldownMinutes = 60
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$extensionList = '.ps1,.psm1,.py,.js,.ts,.jsx,.tsx,.mjs,.cjs,.cs,.java,.go,.rb,.php,.rs,.c,.cpp,.h,.kt,.swift,.vue,.svelte'
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

# cooldown state (per project)
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('LargeFileCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# Pruned recursive scan: generated/vendor directories are never entered, files
# above 3 MB are skipped (binary/generated), and the walk is capped for safety.
$excludedDirs = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync')
$offenders = New-Object System.Collections.Generic.List[object]
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($cwd)
$scannedFiles = 0
while ($stack.Count -gt 0 -and $scannedFiles -lt 5000) {
    $currentDir = $stack.Pop()
    try {
        foreach ($childDir in [System.IO.Directory]::EnumerateDirectories($currentDir)) {
            $leaf = Split-Path -Leaf $childDir
            if ($excludedDirs -notcontains $leaf.ToLowerInvariant()) {
                $stack.Push($childDir)
            }
        }
        foreach ($file in [System.IO.Directory]::EnumerateFiles($currentDir)) {
            $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
            if (-not $extensions.ContainsKey($extension)) { continue }
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
    }
    catch { }
}

if ($offenders.Count -eq 0) {
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
$reason = 'LARGE FILE CHECK: ' + $offenders.Count + ' source file(s) exceed ' + $lineThreshold + ' lines: ' + ($fileLines -join '; ') + $more + '. Decide for yourself whether splitting is SAFE and worthwhile: split by responsibility (features, layers, cohesive groups - never arbitrary line count), keep a single clear entry point, update imports/re-exports, avoid circular dependencies, and run build/tests afterwards. If a safe split is not practical right now, finish - this reminder respects a cooldown.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
