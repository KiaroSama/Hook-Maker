# AiMemoryCheck - after a task ends (Stop), checks whether the project's .ai
# working memory was updated per the AI Context Memory Policy: memory.md first,
# then only the specialized files that gained value (LESSON, REFERENCE, ...).
#
# Token-efficient by design:
# - Fires only when .ai\ exists AND the latest project work is newer than
#   .ai\memory.md (deterministic staleness via git commit/dirty-file times).
# - Respects stop_hook_active (never loops) and a per-project cooldown.
# - The decision stays with the AI: the reminder explicitly allows finishing
#   without updates when nothing durable was learned.
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between reminders per project (default 30)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Field {
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) {
        return $Obj.$Name
    }
    return $null
}

$hookInput = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $hookInput = $raw | ConvertFrom-Json
    }
}
catch { }
if ($null -eq $hookInput) {
    exit 0
}
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

# Only projects that actually keep .ai working memory.
$aiDir = Join-Path $cwd '.ai'
if (-not (Test-Path -LiteralPath $aiDir -PathType Container)) {
    exit 0
}

# ---- optional .env ----
$config = @{}
$envPath = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    foreach ($line in [System.IO.File]::ReadAllLines($envPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -gt 0) {
            $config[$trimmed.Substring(0, $separator).Trim()] = $trimmed.Substring($separator + 1).Trim()
        }
    }
}
$cooldownMinutes = 30
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}

# ---- cooldown (per project) ----
function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally {
        $sha.Dispose()
    }
}
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('AiMemoryCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# ---- staleness: newest project work (git-based) vs .ai\memory.md ----
function Get-LatestWorkTimeUtc {
    param([string]$ProjectRoot)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return $null
    }
    $inside = & git -C $ProjectRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') {
        return $null
    }
    $latest = [DateTime]::MinValue
    $commitUnix = & git -C $ProjectRoot log -1 --format=%ct 2>$null
    if ($LASTEXITCODE -eq 0 -and $commitUnix) {
        $latest = [DateTimeOffset]::FromUnixTimeSeconds([int64]([string]$commitUnix)).UtcDateTime
    }
    $status = & git -C $ProjectRoot status --porcelain 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($status)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            $relative = ([string]$line).Substring(3).Trim('"')
            # The memory itself (and generated graph output) must not count as "work".
            if ($relative -like '.ai/*' -or $relative -like 'graphify-out/*' -or $relative -like 'logs/*') { continue }
            $full = Join-Path $ProjectRoot ($relative.Replace('/', '\'))
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $modified = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
                if ($modified -gt $latest) { $latest = $modified }
            }
        }
    }
    if ($latest -eq [DateTime]::MinValue) {
        return $null
    }
    return $latest
}

$workTime = Get-LatestWorkTimeUtc $cwd
if ($null -eq $workTime) {
    exit 0
}

$reasonWhy = ''
$memoryPath = Join-Path $aiDir 'memory.md'
if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) {
    $reasonWhy = '.ai exists but .ai/memory.md (the startup router) is missing'
}
else {
    $memoryTime = (Get-Item -LiteralPath $memoryPath -Force).LastWriteTimeUtc
    if ($workTime -gt $memoryTime.AddMinutes(2)) {
        $reasonWhy = '.ai/memory.md is older than the latest project changes'
    }
}
if ($reasonWhy -eq '') {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reason = 'AI MEMORY CHECK: the task is ending but ' + $reasonWhy + '. Per the memory policy: if this task produced durable, reusable knowledge, update .ai/memory.md first and then ONLY the specialized files that gained value (LESSON.md, REFERENCE.md, COMMANDS.md, ...). If nothing reusable was learned, finish now without updating - this reminder respects a cooldown.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
