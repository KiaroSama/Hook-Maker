# CloudflareDeploy - after a task ends (Stop), reminds the agent to work
# through BOTH a deployment-worthiness decision and post-deployment
# verification. The AI decides; nothing is deployed or verified automatically
# by this script - it never deploys merely because a wrangler config exists.
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
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -eq 0 -and [string]$inside -eq 'true') {
        $latest = [DateTime]::MinValue
        $commitUnix = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'log', '-1', '--format=%ct')
        if ($LASTEXITCODE -eq 0 -and $commitUnix) {
            $latest = [DateTimeOffset]::FromUnixTimeSeconds([int64]([string]$commitUnix)).UtcDateTime
        }
        $dirty = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'status', '--porcelain')) | Where-Object { $_ })
        if ($dirty.Count -eq 0 -and $latest -ne [DateTime]::MinValue -and $latest -le $lastFire) {
            exit 0
        }
    }
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reasonLines = New-Object System.Collections.Generic.List[string]
[void]$reasonLines.Add('CLOUDFLARE DEPLOY CHECK: this project deploys to Cloudflare Workers (' + $wranglerConfig + ' found). Deployment is NOT automatic just because this config exists - work through both steps below.')
[void]$reasonLines.Add('1) Deployment-worthiness: deploy ONLY if the task is complete (not partial/experimental/local-only diagnostic), relevant tests/typecheck/lint/build pass, the exact release commit is known, CI for that commit is green if this repo uses CI (or an explicit documented policy allows otherwise), no secrets/local-only/debug files or unrelated changes are included, the target environment and any required bindings/migrations are understood, and project/user rules permit it. If any of that is not true - or the change is documentation-only, an experiment, or the release commit is not known - finish now WITHOUT deploying and briefly state why.')
[void]$reasonLines.Add('2) Environment: explicitly decide production / staging / preview-development / a named Wrangler environment before deploying - never silently default to production - and use the matching Wrangler config/command for it.')
[void]$reasonLines.Add('3) Cloudflare-specific pre-deploy review, only where relevant to this diff: Worker name and account/environment selection, environment-specific variables, bindings, D1 databases and migrations, KV namespaces, R2 buckets, Queues, Durable Objects and migrations, service bindings, routes/custom domains, cron triggers, compatibility date/flags, deployment CLI/version compatibility, and build output. Never print secret values.')
[void]$reasonLines.Add('4) If deployment is warranted, run: ' + $deployCommand)
[void]$reasonLines.Add('5) Post-deployment verification is REQUIRED - do not claim deployment succeeded solely because the command exited 0. Record the target environment, deployed Worker/project, exact source commit SHA, the deploy command used (excluding secrets), and the deployment/version identifier or URL. Then perform the smallest appropriate check: smoke-test the public/staging URL, call a health endpoint, verify the changed feature, inspect recent Cloudflare deployment output/logs, verify routes/bindings, or confirm migrations completed. If verification cannot be performed, state that limitation accurately instead of assuming success.')
[void]$reasonLines.Add('6) On failure: do not repeatedly redeploy blindly - inspect the actual failure, fix only confirmed deployment/configuration issues, rerun relevant local validation, retry only when safe, never hide a failed deployment, and never claim the task is live if it is not. This reminder respects a cooldown.')
$reason = $reasonLines.ToArray() -join "`n"
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
