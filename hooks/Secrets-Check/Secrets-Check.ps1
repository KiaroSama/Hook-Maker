# Secrets-Check - keeps a project's secrets.md registry accurate and safe.
#
# Checks (pre-task SessionStart + post-task Stop):
# - secrets.md exists but is NOT git-ignored, or is tracked/staged in git -> CRITICAL.
# - Any real .env* file (not a .example/.sample/.template) is itself tracked -> CRITICAL.
# - A discovered secret VALUE turns up inside a git-TRACKED file elsewhere in the
#   repo (git grep, filenames only, value never printed) -> CRITICAL "possible leak".
# - Secret KEYs found in .env* files but missing from secrets.md are AUTO-APPENDED
#   to secrets.md (created if absent) with their real value copied in - never
#   printed, logged, or echoed anywhere, only the KEY NAME appears in reports/logs.
# - Values that look like empty placeholders (TODO, changeme, xxx, <...>, ...)
#   are flagged by key name.
# - Periodically (long cooldown - this is a heavier scan, not a per-session one):
#   secrets.md entries (## KEY headings) that are never referenced anywhere else
#   in the tracked project are flagged as possibly unused. NEVER auto-removed -
#   a false positive would destroy an unrecoverable credential, so removal is
#   always the AI's call, same as every other advisory hook in this project.
#
# This hook never makes network calls and never tests a secret against its real
# service (that would risk rate limits/unintended use); "valid" here means
# "non-placeholder and still referenced in the project", not "live-tested".
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES               minutes between repeated non-critical reports (default 60)
#   UNUSED_SCAN_COOLDOWN_MINUTES    minutes between the heavier unused-secret scan (default 10080 = 7 days)
#   AUTO_APPEND                    true/false - write missing secrets into secrets.md (default true)
#   MIN_SECRET_LENGTH              values shorter than this are skipped in the leak scan (default 8)

param([switch]$GitPrePush)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = if ($GitPrePush) {
    [pscustomobject]@{ cwd = (Get-Location).Path; hook_event_name = 'GitPrePush' }
}
else {
    Read-HookInput
}
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
$isStopEvent = ($GitPrePush -or $eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
if (-not $GitPrePush -and $isStopEvent -and (Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 60
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$unusedScanCooldownMinutes = 10080
if ($config.ContainsKey('UNUSED_SCAN_COOLDOWN_MINUTES')) {
    try { $unusedScanCooldownMinutes = [int]$config['UNUSED_SCAN_COOLDOWN_MINUTES'] } catch { }
}
$autoAppend = $true
if ($config.ContainsKey('AUTO_APPEND') -and $config['AUTO_APPEND'] -match '^(false|0|no)$') {
    $autoAppend = $false
}
$minSecretLength = 8
if ($config.ContainsKey('MIN_SECRET_LENGTH')) {
    try { $minSecretLength = [int]$config['MIN_SECRET_LENGTH'] } catch { }
}

# ---- discover real .env* files in active project trees ----
$excludedDirs = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj')
$envFiles = New-Object System.Collections.Generic.List[object]
$rootFull = (Get-Item -LiteralPath $cwd).FullName.TrimEnd('\', '/')
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($rootFull)
while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    try {
        foreach ($filePath in [System.IO.Directory]::EnumerateFiles($current, '.env*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            $leaf = Split-Path -Leaf $filePath
            if ($leaf -notmatch '(?i)\.(example|sample|template|dist)$') {
                $relative = $filePath.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                [void]$envFiles.Add([pscustomobject]@{ FullName = $filePath; Name = $relative })
            }
        }
        foreach ($dirPath in [System.IO.Directory]::EnumerateDirectories($current)) {
            $dir = Get-Item -LiteralPath $dirPath -Force -ErrorAction SilentlyContinue
            if ($null -eq $dir -or ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
            if ($excludedDirs -notcontains $dir.Name.ToLowerInvariant()) { $stack.Push($dir.FullName) }
        }
    }
    catch { }
}
$envFiles = @($envFiles.ToArray() | Sort-Object Name)

$secretsPath = Join-Path $cwd 'secrets.md'
$secretsExists = Test-Path -LiteralPath $secretsPath -PathType Leaf

# Nothing to look at: no candidate secret files and no existing registry -> silent.
if ($envFiles.Count -eq 0 -and -not $secretsExists) {
    exit 0
}

# ---- collect discovered secrets: KEY -> {Value, SourceFile} (later file wins) ----
$discovered = @{}
foreach ($file in $envFiles) {
    $values = Read-HookEnv $file.FullName
    foreach ($key in $values.Keys) {
        $discovered[$key] = [pscustomobject]@{ Value = $values[$key]; Source = $file.Name; SourcePath = $file.FullName }
    }
}

function Test-PlaceholderValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Value -match '^(todo|changeme|change_me|change-me|your[-_].*|x{3,}|<.*>|\.\.\.|test|example|placeholder|fixme|redacted|n/a|none|null)$'
}

$secretsContent = ''
if ($secretsExists) {
    try { $secretsContent = [System.IO.File]::ReadAllText($secretsPath, [System.Text.Encoding]::UTF8) } catch { }
}

function Test-KeyDocumented {
    param([string]$Key, [string]$Content)
    if ($Content -eq '') { return $false }
    return [regex]::IsMatch($Content, '\b' + [regex]::Escape($Key) + '\b')
}

# ---- auto-append missing secrets (additive only - never overwrites/removes) ----
$added = New-Object System.Collections.Generic.List[string]
$missingUndocumented = New-Object System.Collections.Generic.List[string]
foreach ($key in @($discovered.Keys | Sort-Object)) {
    if (Test-KeyDocumented -Key $key -Content $secretsContent) { continue }
    if ($autoAppend) {
        [void]$added.Add($key)
    }
    else {
        [void]$missingUndocumented.Add($key)
    }
}
if ($added.Count -gt 0) {
    if (-not $secretsExists) {
        $header = "# Secrets`n`nLocal-only registry of real secrets for this project. This file must stay" +
            " git-ignored and must never be committed, printed, or shared.`n"
        $secretsContent = $header
    }
    $entryLines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $added) {
        $entry = $discovered[$key]
        [void]$entryLines.Add('')
        [void]$entryLines.Add('## ' + $key)
        [void]$entryLines.Add('- Purpose: TODO - describe what this secret is used for')
        [void]$entryLines.Add('- Used by: (auto-detected from ' + $entry.Source + '; update if used elsewhere)')
        [void]$entryLines.Add('- Source: ' + $entry.SourcePath)
        [void]$entryLines.Add('- Created: ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd') + ' (auto-added by Secrets-Check)')
        [void]$entryLines.Add('- Value: ' + $entry.Value)
    }
    $newContent = $secretsContent.TrimEnd() + "`n" + ($entryLines.ToArray() -join "`n") + "`n"
    try {
        [System.IO.File]::WriteAllText($secretsPath, $newContent, [System.Text.UTF8Encoding]::new($false))
        $secretsExists = $true
        $secretsContent = $newContent
    }
    catch {
        # Could not write (permissions, read-only, ...) - fall back to reporting only.
        [void]$missingUndocumented.AddRange($added)
        $added.Clear()
    }
}

$placeholders = New-Object System.Collections.Generic.List[string]
foreach ($key in @($discovered.Keys | Sort-Object)) {
    if (Test-PlaceholderValue $discovered[$key].Value) {
        [void]$placeholders.Add($key)
    }
}

# ---- git-based checks: ignore/tracked/staged/leak (skipped outside a git repo) ----
$critical = New-Object System.Collections.Generic.List[string]
$inGitRepo = $false
if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
    $inGitRepo = ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true')
}

if ($inGitRepo) {
    if ($secretsExists) {
        $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'check-ignore', '-q', '--', 'secrets.md')
        if ($LASTEXITCODE -ne 0) {
            [void]$critical.Add('secrets.md exists but is NOT covered by .gitignore.')
        }
        $tracked = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'ls-files', '--', 'secrets.md')
        if ($LASTEXITCODE -eq 0 -and @($tracked | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add('secrets.md is TRACKED by git.')
        }
        $staged = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff', '--cached', '--name-only', '--', 'secrets.md')
        if ($LASTEXITCODE -eq 0 -and @($staged | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add('secrets.md is STAGED for commit.')
        }
    }
    foreach ($file in $envFiles) {
        $relPath = $file.Name
        $tracked = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'ls-files', '--', $relPath)
        if ($LASTEXITCODE -eq 0 -and @($tracked | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add($relPath + ' (contains real secrets) is TRACKED by git.')
        }
        $staged = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'diff', '--cached', '--name-only', '--', $relPath)
        if ($LASTEXITCODE -eq 0 -and @($staged | Where-Object { $_ }).Count -gt 0) {
            [void]$critical.Add($relPath + ' (contains real secrets) is STAGED for commit.')
        }
    }
    $excludeNames = @('secrets.md') + @($envFiles | ForEach-Object { $_.Name.Replace('\', '/') })
    foreach ($key in @($discovered.Keys | Sort-Object)) {
        $value = $discovered[$key].Value
        if ($value.Length -lt $minSecretLength) { continue }
        $grepHits = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'grep', '-Il', '-F', '--', $value)
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($matchFile in @($grepHits | Where-Object { $_ })) {
            if ($excludeNames -contains ([string]$matchFile).Replace('\', '/')) { continue }
            [void]$critical.Add('Value of ' + $key + ' appears in a git-tracked file: ' + $matchFile)
        }
    }
}

# ---- periodic (heavy) unused-secret scan: long cooldown, git-only ----
$unusedStateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$unusedStatePath = Join-Path $unusedStateDir ('Secrets-Check-Unused-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$runUnusedScan = $true
if (-not $GitPrePush -and (Test-Path -LiteralPath $unusedStatePath -PathType Leaf)) {
    try {
        $lastUnused = [DateTime]::Parse(([System.IO.File]::ReadAllText($unusedStatePath)).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $lastUnused.ToUniversalTime()).TotalMinutes -lt $unusedScanCooldownMinutes) {
            $runUnusedScan = $false
        }
    }
    catch { }
}
$unused = New-Object System.Collections.Generic.List[string]
if (-not $GitPrePush -and $runUnusedScan -and $inGitRepo -and $secretsExists) {
    $documentedKeys = @([regex]::Matches($secretsContent, '(?m)^##\s+(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    foreach ($key in @($documentedKeys | Sort-Object -Unique)) {
        $grepHits = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'grep', '-Il', '-F', '--', $key)
        $usedElsewhere = $false
        if ($LASTEXITCODE -eq 0) {
            foreach ($matchFile in @($grepHits | Where-Object { $_ })) {
                $leaf = Split-Path -Leaf $matchFile
                if ($leaf -eq 'secrets.md') { continue }
                if (@($envFiles | ForEach-Object { $_.Name }) -contains $leaf) { continue }
                $usedElsewhere = $true
                break
            }
        }
        if (-not $usedElsewhere) {
            [void]$unused.Add($key)
        }
    }
    if (-not $GitPrePush) {
        try {
            if (-not (Test-Path -LiteralPath $unusedStateDir -PathType Container)) {
                New-Item -ItemType Directory -Path $unusedStateDir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($unusedStatePath, [DateTime]::UtcNow.ToString('o'))
        }
        catch { }
    }
}

# ---- nothing at all to report -> silent ----
if ($critical.Count -eq 0 -and $added.Count -eq 0 -and $missingUndocumented.Count -eq 0 -and $placeholders.Count -eq 0 -and $unused.Count -eq 0) {
    exit 0
}

if ($GitPrePush -and $critical.Count -eq 0) {
    exit 0
}

# ---- non-critical fingerprint + cooldown (critical findings always bypass this) ----
$fingerprintSource = (@($added) -join ',') + '|' + (@($missingUndocumented) -join ',') + '|' + (@($placeholders) -join ',') + '|' + (@($unused) -join ',')
$fingerprint = Get-ShortHash $fingerprintSource
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('Secrets-Check-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if ($critical.Count -eq 0 -and -not $GitPrePush) {
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $lines = [System.IO.File]::ReadAllLines($statePath)
            if ($lines.Count -ge 2 -and $lines[0].Trim() -eq $fingerprint) {
                $lastTime = [DateTime]::Parse($lines[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if (([DateTime]::UtcNow - $lastTime.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
                    exit 0
                }
            }
        }
        catch { }
    }
}
if (-not $GitPrePush) {
    try {
        if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllLines($statePath, @($fingerprint, [DateTime]::UtcNow.ToString('o')))
    }
    catch { }
}

# ---- build the report (key names / file paths only - NEVER a secret value) ----
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('SECRETS CHECK (' + $cwd + '):')
if ($critical.Count -gt 0) {
    [void]$lines.Add('CRITICAL:')
    foreach ($item in $critical) { [void]$lines.Add('- ' + $item) }
}
if ($added.Count -gt 0) {
    [void]$lines.Add('Auto-added ' + $added.Count + ' new secret(s) to secrets.md (fill in Purpose/Used by): ' + ($added.ToArray() -join ', '))
}
if ($missingUndocumented.Count -gt 0) {
    [void]$lines.Add('Found in .env but NOT in secrets.md (AUTO_APPEND is off): ' + ($missingUndocumented.ToArray() -join ', '))
}
if ($placeholders.Count -gt 0) {
    [void]$lines.Add('Value looks like an empty placeholder: ' + ($placeholders.ToArray() -join ', '))
}
if ($unused.Count -gt 0) {
    [void]$lines.Add('In secrets.md but not referenced elsewhere in the tracked project (verify before removing - never auto-removed): ' + ($unused.ToArray() -join ', '))
}
[void]$lines.Add('Never print, log, or commit a secret value. Rotate anything that may have leaked. Removing a secrets.md entry is always your call, not automated.')
$message = $lines.ToArray() -join "`n"

if ($GitPrePush) {
    [Console]::Error.WriteLine($message)
    exit 1
}
if ($isStopEvent) {
    @{ decision = 'block'; reason = $message } | ConvertTo-Json -Compress
    exit 0
}

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
