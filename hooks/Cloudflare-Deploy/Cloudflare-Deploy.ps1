# CloudflareDeploy - after a task ends (Stop), reminds the agent to work
# through BOTH a deployment-worthiness decision and post-deployment
# verification. The AI decides; nothing is deployed or verified automatically
# by this script - it never deploys merely because a wrangler config exists.
#
# The decision is gated on actual RELEASE READINESS (deterministic repo/CI/
# cleanup state), never on menu position or hook registration order - Stop
# hooks for the same event may run concurrently, so this hook never assumes
# it runs "after" Git-Sync-Check, Ci-Status-Check, or Test-Temp-Cleanup. It
# stays completely silent (no reminder at all this Stop) when the working
# tree is dirty, the branch is ahead/unpushed, the exact release commit isn't
# known to be pushed, CI exists but is not verified green for that exact SHA,
# or Test-Temp-Cleanup (when installed for this project) has not reported a
# fresh `clean` result for the CURRENT repo state. If Test-Temp-Cleanup races
# on the same Stop and hasn't recorded yet, this hook simply stays silent and
# re-evaluates on the next Stop - it never loops or retries within one
# invocation.
#
# Token-efficient by design:
# - Fires only in projects with a wrangler config (wrangler.toml/.json/.jsonc)
#   AND only when release-readiness actually holds.
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
# Only used to shape the result (Write-HookResult below). This is a Stop-only
# hook, so an absent event name reads as 'Stop' rather than as "no event".
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
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

# ---- SHARED RESULT-CATEGORY CONTRACT -------------------------------------
# The complete vocabulary of the { fingerprint, category } handoff written to
# TestTempCleanup-result-<projectKey>.json.
# THE OTHER SIDE OF THIS CONTRACT IS hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1
# ($script:ResultCategories). Keep both lists identical, in the same commit - a
# past round shipped a dead gate because two components drifted on exactly this
# kind of shared state contract.
$script:CleanupCategories = @('clean', 'review-required', 'residue-confirmed', 'partial', 'unknown')
# Only a fully clean, complete scan is release-ready. `review-required`,
# `residue-confirmed`, `partial` and `unknown` each mean the workspace state is
# unresolved or unproven, so none of them may show a deployment decision. An
# unrecognized value (an older or newer producer) is treated the same way.
$script:CleanupReleaseReadyCategories = @('clean')

# ---- MIRRORED CLIENT RUNTIME ROOTS ---------------------------------------
# Where an installed Hook Maker runtime lives, relative to the project root,
# for EVERY supported client. This mirrors runtimeRelativeRoot in
# scripts\_clientcapability.ps1 and is duplicated for the same structural
# reason $script:HookClientIds in hooks\_hooklib.ps1 is: an installed runtime
# is self-contained - the installer rewrites _hooklib.ps1 into it but copies no
# sibling out of scripts\ - so the capability table cannot be shared by
# dot-sourcing. Test-CloudflareDeploy.ps1 asserts this mirror equals the table
# for every Get-HookMakerClientIds entry, which is how the duplication is kept
# honest instead of drifting into a stale hardcoded list.
#
# Kiro's runtime is deliberately NOT under .kiro\hooks: that directory is
# Kiro's hook-CONFIG discovery root, so a copied .ps1 tree there would be
# scanned as configuration. A check that only knew the .claude/.codex layouts
# therefore saw a Kiro-only install as "cleanup not installed" and skipped the
# coordination gate entirely.
$script:ClientRuntimeRelativeRoots = @(
    '.claude\hooks\Hook-Maker',
    '.codex\hooks\Hook-Maker',
    '.kiro\hook-runtime\Hook-Maker'
)

# The single definition of WHERE Test-Temp-Cleanup's coordination record lives,
# so "does a record exist at all" (install evidence) and "what does it currently
# say" (the gate itself) can never disagree about which file they mean.
function Get-CleanupResultPath {
    param([string]$Root)
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('TestTempCleanup-result-' + (Get-ShortHash $Root.ToLowerInvariant()) + '.json'))
}

# Is Test-Temp-Cleanup actually part of this project? A directory listing alone
# is WEAK evidence: a hand-made, half-deleted or orphaned
# <runtimeRoot>\Test-Temp-Cleanup folder satisfies it while nothing there ever
# runs, and an install whose runtime lives somewhere this mirrored list does not
# know about satisfies it not at all. A coordination record in Hook Maker's own
# private state is REAL evidence - only the hook itself writes one, only for this
# exact project key - so it is preferred and checked first; the directory remains
# the weaker second signal for an install that has not recorded yet.
#
# NEITHER signal can SATISFY the cleanliness gate. Only a FRESH 'clean' category
# does that, so an orphan or hand-made folder can never assert that the workspace
# was proven clean - the strongest thing it can do is make the gate APPLY.
#
# The two signals are OR'd on purpose, which is the conservative side of the
# failure direction: a false "installed" costs at most a missed reminder, while a
# false "not installed" skips the cleanliness half of release readiness and shows
# a deploy decision this hook cannot support. Inconclusive evidence therefore
# keeps this hook silent rather than letting it claim coverage it does not have.
function Test-CleanupInstalled {
    param([string]$Root)
    if (Test-Path -LiteralPath (Get-CleanupResultPath -Root $Root) -PathType Leaf) { return $true }
    foreach ($relativeRoot in $script:ClientRuntimeRelativeRoots) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $Root $relativeRoot) 'Test-Temp-Cleanup') -PathType Container) { return $true }
    }
    return $false
}

# Reads Test-Temp-Cleanup's coordination state, only trusting it when its
# recorded repo-state fingerprint still matches the CURRENT state (never a
# stale/racing read from an earlier Stop).
function Get-CleanupCoordinationState {
    param([string]$Root)
    $record = Read-JsonFile -Path (Get-CleanupResultPath -Root $Root)
    if ($null -eq $record) { return $null }
    $recordedFingerprint = [string](Get-Field $record 'fingerprint')
    if ([string]::IsNullOrWhiteSpace($recordedFingerprint)) { return $null }
    if ($recordedFingerprint -ne (Get-RepoStateFingerprint -ProjectRoot $Root)) { return $null }
    return [string](Get-Field $record 'category')
}

# Deterministic release-readiness gate: only when this holds does the
# deployment-worthiness decision get shown at all.
function Test-ReleaseReady {
    param([string]$Root)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $false }

    # 1) no uncommitted task changes.
    $status = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'status', '--porcelain')) | Where-Object { $_ })
    if ($status.Count -gt 0) { return $false }

    $headSha = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headSha)) { return $false }

    # 2) the release commit must be known to be pushed - ANY configured
    # upstream (Cloudflare Workers projects need not be hosted on GitHub at
    # all); Get-GitHubRepository is reserved for the GitHub-specific CI query
    # below, not for this generic pushed/ahead check.
    $upstreamRef = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--abbrev-ref', '@{upstream}'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamRef)) { return $false }
    $aheadRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-list', '--count', ($upstreamRef + '..HEAD')))
    if ($LASTEXITCODE -ne 0) { return $false }
    $ahead = -1
    if (-not [int]::TryParse($aheadRaw, [ref]$ahead) -or $ahead -ne 0) { return $false }

    # 3) if this repo uses CI, the exact HEAD sha must be verified green.
    $workflowsDir = Join-Path $Root '.github\workflows'
    $usesCi = (Test-Path -LiteralPath $workflowsDir -PathType Container) -and
        (@(Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yml' -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yaml' -ErrorAction SilentlyContinue)).Count -gt 0
    if ($usesCi) {
        $repoInfo = Get-GitHubRepository -ProjectRoot $Root
        if ($null -eq $repoInfo) { return $false }
        if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
        $runsJson = [string](Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--repo', $repoInfo.Repository, '--commit', $headSha, '--json', 'status,conclusion', '--limit', '20'))
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($runsJson)) { return $false }
        $runs = $null
        # The INNER parentheses are load-bearing on Windows PowerShell 5.1.
        # `@($json | ConvertFrom-Json)` there collects the decoded array as ONE
        # element of type Object[] instead of enumerating it - at ANY array
        # length, including one. Get-Field reads $Object.PSObject.Properties,
        # which is empty on an Object[], so every field read returns $null, no
        # run ever looks 'completed'/'success', and this gate can never pass.
        #
        # What hides it: `$wrapped[0].status` DOES print the right value,
        # because PowerShell member-enumerates over the array. Only a real
        # property lookup exposes it, so the shape looks fine under casual
        # inspection and the failure is silent (never a wrong deploy prompt).
        #
        # `@((...))` enumerates identically on both hosts; same form as
        # Ci-Status-Check.ps1's annotation decode.
        try { $runs = @(($runsJson | ConvertFrom-Json)) } catch { return $false }
        if ($runs.Count -eq 0) { return $false }
        foreach ($run in $runs) {
            if ([string](Get-Field $run 'status') -ne 'completed' -or [string](Get-Field $run 'conclusion') -ne 'success') { return $false }
        }
    }

    # 4) Test-Temp-Cleanup coordination, only enforced when it is installed for
    # this project - and "installed" is proven by a real coordination record
    # first, a runtime directory only as weaker evidence (see Test-CleanupInstalled).
    if (Test-CleanupInstalled -Root $Root) {
        $cleanupCategory = Get-CleanupCoordinationState -Root $Root
        # Missing/stale ($null), a non-ready category, and an unrecognized
        # category all keep this hook silent until a later Stop.
        if ($script:CleanupCategories -notcontains $cleanupCategory) { return $false }
        if ($script:CleanupReleaseReadyCategories -notcontains $cleanupCategory) { return $false }
    }

    return $true
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

# Only show the decision when the repository and release state are actually
# ready - never based on hook registration order (see header).
if (-not (Test-ReleaseReady $cwd)) {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reasonLines = New-Object System.Collections.Generic.List[string]
[void]$reasonLines.Add('CLOUDFLARE DEPLOY CHECK: this project deploys to Cloudflare Workers (' + $wranglerConfig + ' found). Deployment is NOT automatic just because this config exists - work through both steps below.')
[void]$reasonLines.Add('1) Deployment-worthiness: deploy ONLY if the task is complete (not partial/experimental/local-only diagnostic), relevant tests/typecheck/lint/build pass, the exact release commit is known, CI for that commit is green if this repo uses CI (or an explicit documented policy allows otherwise), no secrets/local-only/debug files, unrelated changes, or disposable test cache/temp residue are included, the target environment and any required bindings/migrations are understood, and project/user rules permit it. If any of that is not true - or the change is documentation-only, an experiment, or the release commit is not known - finish now WITHOUT deploying and briefly state why.')
[void]$reasonLines.Add('2) Environment: explicitly decide production / staging / preview-development / a named Wrangler environment before deploying - never silently default to production - and use the matching Wrangler config/command for it.')
[void]$reasonLines.Add('3) Cloudflare-specific pre-deploy review, only where relevant to this diff: Worker name and account/environment selection, environment-specific variables, bindings, D1 databases and migrations, KV namespaces, R2 buckets, Queues, Durable Objects and migrations, service bindings, routes/custom domains, cron triggers, compatibility date/flags, deployment CLI/version compatibility, and build output. Never print secret values.')
[void]$reasonLines.Add('4) If deployment is warranted, run: ' + $deployCommand)
[void]$reasonLines.Add('5) Post-deployment verification is REQUIRED - do not claim deployment succeeded solely because the command exited 0. Record the target environment, deployed Worker/project, exact source commit SHA, the deploy command used (excluding secrets), and the deployment/version identifier or URL. Then perform the smallest appropriate check: smoke-test the public/staging URL, call a health endpoint, verify the changed feature, inspect recent Cloudflare deployment output/logs, verify routes/bindings, or confirm migrations completed. If verification cannot be performed, state that limitation accurately instead of assuming success.')
[void]$reasonLines.Add('6) On failure: do not repeatedly redeploy blindly - inspect the actual failure, fix only confirmed deployment/configuration issues, rerun relevant local validation, retry only when safe, never hide a failed deployment, and never claim the task is live if it is not. This reminder respects a cooldown.')
$reason = $reasonLines.ToArray() -join "`n"
exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason).ExitCode
