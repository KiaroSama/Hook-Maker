# CloudflareDeploy - after a task ends (Stop), reminds the agent to deploy to
# Cloudflare Workers WHEN IT IS WARRANTED. The AI decides; nothing is deployed
# automatically by this script.
#
# Token-efficient by design:
# - Fires only in projects with a wrangler config (wrangler.toml/.json/.jsonc)
#   AND only when there is work newer than the last reminder.
# - Respects stop_hook_active (never loops) and a per-project cooldown.
#
# Optional .env next to this script (copy .env.example):
#   DEPLOY_COMMAND    the deploy command to suggest (default: npx wrangler deploy)
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

# Only Cloudflare Workers projects.
$wranglerConfig = $null
foreach ($candidate in @('wrangler.toml', 'wrangler.jsonc', 'wrangler.json')) {
    $path = Join-Path $cwd $candidate
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $wranglerConfig = $candidate
        break
    }
}
if ($null -eq $wranglerConfig) {
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
$deployCommand = 'npx wrangler deploy'
if ($config.ContainsKey('DEPLOY_COMMAND') -and $config['DEPLOY_COMMAND'] -ne '') {
    $deployCommand = $config['DEPLOY_COMMAND']
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
$statePath = Join-Path $stateDir ('CloudflareDeploy-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$lastFire = [DateTime]::MinValue
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $lastFire = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([DateTime]::UtcNow - $lastFire).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# Only remind when there is actually work newer than the last reminder
# (git-based; non-git Workers projects fall back to reminding per cooldown).
if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
    $inside = & git -C $cwd rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true') {
        $latest = [DateTime]::MinValue
        $commitUnix = & git -C $cwd log -1 --format=%ct 2>$null
        if ($LASTEXITCODE -eq 0 -and $commitUnix) {
            $latest = [DateTimeOffset]::FromUnixTimeSeconds([int64]([string]$commitUnix)).UtcDateTime
        }
        $dirty = @((& git -C $cwd status --porcelain 2>$null) | Where-Object { $_ })
        if ($dirty.Count -eq 0 -and $latest -ne [DateTime]::MinValue -and $latest -le $lastFire) {
            exit 0
        }
    }
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reason = 'CLOUDFLARE DEPLOY CHECK: this project deploys to Cloudflare Workers (' + $wranglerConfig + ' found). Decide for yourself: if the finished task should go live, verify the change works and deploy with: ' + $deployCommand + '  If it is not deploy-worthy (partial work, experiments, docs), finish now - this reminder respects a cooldown.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
