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

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
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
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 30
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$deployCommand = 'npx wrangler deploy'
if ($config.ContainsKey('DEPLOY_COMMAND') -and $config['DEPLOY_COMMAND'] -ne '') {
    $deployCommand = $config['DEPLOY_COMMAND']
}

# ---- cooldown (per project) ----
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

$reason = 'CLOUDFLARE DEPLOY CHECK: this project deploys to Cloudflare Workers (' + $wranglerConfig + ' found). Decide for yourself: if the finished task should go live, run the release checks first (tests/build pass, docs match, no secrets or local-only files staged) and then deploy with: ' + $deployCommand + '  If it is not deploy-worthy (partial work, experiments, docs-only), finish now - this reminder respects a cooldown.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
