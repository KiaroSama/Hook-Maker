# GraphUpdateCheck - after a task ends (Stop), checks whether the graphify
# knowledge graph is stale and, if so, asks the AI to decide whether updating
# it is worth it (graphify update . is AST-only, no API cost).
#
# Token-efficient by design:
# - Fires only when graphify-out\graph.json exists AND the latest project work
#   is newer than the graph (deterministic staleness via git times).
# - Respects stop_hook_active (never loops) and a per-project cooldown.
# - If the AI decides not to update, nothing happens; the reminder returns
#   after future changes (exactly once per cooldown window).
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between reminders per project (default 60)

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

# Only projects that actually keep a graph.
$graphPath = Join-Path $cwd 'graphify-out\graph.json'
if (-not (Test-Path -LiteralPath $graphPath -PathType Leaf)) {
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
$cooldownMinutes = 60
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
$statePath = Join-Path $stateDir ('GraphUpdateCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# ---- staleness: newest CODE work (git-based) vs graph.json ----
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
$graphTime = (Get-Item -LiteralPath $graphPath -Force).LastWriteTimeUtc
if ($workTime -le $graphTime.AddMinutes(2)) {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reason = 'GRAPH UPDATE CHECK: graphify-out/graph.json predates the latest project changes. Per the graphify rule, decide for yourself: if this task changed code structure (files, functions, cross-file relationships), run: graphify update .  (AST-only, no API cost). Do NOT update for tiny edits, documentation-only changes, or one-file fixes - in that case finish now; this reminder returns after future changes.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
