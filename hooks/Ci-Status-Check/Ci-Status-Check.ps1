# CiStatusCheck - after a task ends (Stop), verifies the GitHub checks of the
# EXACT pushed commit before the agent may declare the work complete. There is
# no literal post-push hook event in either client, so the Stop event acts as
# the completion gate: a pushed-but-unverified HEAD blocks with concise
# next-step context; a verified or irrelevant state stays silent.
#
# Design notes:
# - The exact commit SHA is correlated via `gh run list --commit <sha>` -
#   never "the newest run in the repository".
# - Local remote-tracking state decides whether HEAD is pushed (no network
#   fetch). Unpushed work is GitSyncCheck's domain and stays silent here.
# - State per repo remembers the last verified/reported SHA so the same
#   commit is never re-verified and a deterministic failure is not nagged
#   endlessly; a NEW pushed commit resets the cycle immediately.
# - Never loops: stop_hook_active exits first. Degrades silently when git,
#   a GitHub remote, or gh is unavailable (it never claims checks passed).
#
# Optional .env next to this script (copy .env.example):
#   PENDING_COOLDOWN_MINUTES  minutes between "still running" reminders (default 3)
#   FAILURE_COOLDOWN_MINUTES  minutes between reminders for the same failed SHA (default 30)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') {
    exit 0
}
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

# ---- pushed HEAD on a GitHub repo? ----
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    exit 0
}
$inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') {
    exit 0
}
$repoSlug = ''
foreach ($remoteName in @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'remote'))) {
    if ([string]::IsNullOrWhiteSpace([string]$remoteName)) { continue }
    $url = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'remote', 'get-url', $remoteName))
    if ($LASTEXITCODE -ne 0) { continue }
    if ($url -match 'github\.com[:/]([^/]+)/([^/\s]+?)(\.git)?/?$') {
        $repoSlug = $Matches[1] + '/' + $Matches[2]
        break
    }
}
if ($repoSlug -eq '') {
    exit 0
}
$branch = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--abbrev-ref', 'HEAD'))
if ($LASTEXITCODE -ne 0 -or $branch -eq '' -or $branch -eq 'HEAD') {
    exit 0
}
$null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--abbrev-ref', '@{upstream}')
if ($LASTEXITCODE -ne 0) {
    exit 0    # never pushed - not this hook's concern
}
$aheadRaw = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-list', '--count', '@{upstream}..HEAD')
if ($LASTEXITCODE -ne 0) {
    exit 0
}
if ([int]([string]$aheadRaw).Trim() -gt 0) {
    exit 0    # HEAD not pushed yet - GitSyncCheck's domain
}
$sha = ([string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', 'HEAD'))).Trim()
if ($LASTEXITCODE -ne 0 -or $sha -eq '') {
    exit 0
}
$sha7 = $sha
if ($sha7.Length -gt 7) { $sha7 = $sha7.Substring(0, 7) }

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$pendingCooldown = 3
if ($config.ContainsKey('PENDING_COOLDOWN_MINUTES')) {
    try { $pendingCooldown = [int]$config['PENDING_COOLDOWN_MINUTES'] } catch { }
}
$failureCooldown = 30
if ($config.ContainsKey('FAILURE_COOLDOWN_MINUTES')) {
    try { $failureCooldown = [int]$config['FAILURE_COOLDOWN_MINUTES'] } catch { }
}

# ---- per-repo state: sha / outcome / timestamp ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('CiStatusCheck-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $repoSlug.ToLowerInvariant())) + '.txt')
$stateSha = ''
$stateOutcome = ''
$stateTime = [DateTime]::MinValue
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $stateLines = [System.IO.File]::ReadAllLines($statePath)
        if ($stateLines.Count -ge 3) {
            $stateSha = $stateLines[0].Trim()
            $stateOutcome = $stateLines[1].Trim()
            $stateTime = [DateTime]::Parse($stateLines[2].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
    }
    catch { }
}
if ($stateSha -eq $sha) {
    if ($stateOutcome -eq 'verified') {
        exit 0    # this exact commit was already verified green
    }
    $ageMinutes = ([DateTime]::UtcNow - $stateTime).TotalMinutes
    if ($stateOutcome -eq 'failed' -and $ageMinutes -lt $failureCooldown) {
        exit 0    # already reported; don't nag a deterministic failure
    }
    if ($stateOutcome -eq 'pending' -and $ageMinutes -lt $pendingCooldown) {
        exit 0
    }
}

function Save-State {
    param([string]$Outcome)
    New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
    [System.IO.File]::WriteAllLines($script:statePath, @($script:sha, $Outcome, [DateTime]::UtcNow.ToString('o')))
}

function Write-Block {
    param([string]$Outcome, [string]$Reason)
    Save-State -Outcome $Outcome
    @{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress
    exit 0
}

# ---- gh availability (silent degradation: never claim verified) ----
if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
    exit 0
}
$null = Invoke-QuietCommand -FilePath gh -ArgumentList @('auth', 'status')
if ($LASTEXITCODE -ne 0) {
    exit 0
}

# ---- workflow runs for the EXACT pushed commit ----
$rawJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--commit', $sha, '--json', 'databaseId,name,workflowName,status,conclusion', '--limit', '50')
if ($LASTEXITCODE -ne 0) {
    exit 0    # API/permission failure: degrade without claiming anything
}
$runs = @()
try { $runs = @((@($rawJson) -join "`n") | ConvertFrom-Json) } catch { $runs = @() }

if ($runs.Count -eq 0) {
    $workflowsDir = Join-Path $cwd '.github\workflows'
    $hasWorkflows = $false
    if (Test-Path -LiteralPath $workflowsDir -PathType Container) {
        $hasWorkflows = (@(Get-ChildItem -LiteralPath $workflowsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml', '.yaml') }).Count -gt 0)
    }
    if (-not $hasWorkflows) {
        Save-State -Outcome 'verified'    # no CI configured - nothing to verify
        exit 0
    }
    Write-Block -Outcome 'pending' -Reason ('CI CHECK: workflows exist but no runs are registered yet for pushed commit ' + $sha7 + ' (' + $repoSlug + '). Do not declare the work complete: wait briefly, then verify the checks for this exact commit with: gh run list --commit ' + $sha)
}

$pendingRuns = @()
$failedRuns = @()
$infraRuns = @()
foreach ($run in $runs) {
    if ($null -eq $run) { continue }
    $name = [string](Get-Field $run 'workflowName')
    if ($name -eq '') { $name = [string](Get-Field $run 'name') }
    $id = [string](Get-Field $run 'databaseId')
    $entry = $name + ' (run ' + $id + ')'
    $status = ([string](Get-Field $run 'status')).ToLowerInvariant()
    $conclusion = ([string](Get-Field $run 'conclusion')).ToLowerInvariant()
    if ($status -ne 'completed') {
        $pendingRuns += $entry
    }
    elseif ($conclusion -in @('success', 'neutral', 'skipped')) {
        # fine
    }
    elseif ($conclusion -in @('failure', 'startup_failure')) {
        $failedRuns += $entry
    }
    else {
        # cancelled / timed_out / stale / action_required / unknown:
        # abnormal endings that are often infrastructure or flakiness.
        $infraRuns += ($entry + ' [' + $conclusion + ']')
    }
}

if ($pendingRuns.Count -gt 0) {
    Write-Block -Outcome 'pending' -Reason ('CI CHECK: pushed commit ' + $sha7 + ' on ' + $branch + ' (' + $repoSlug + ') has ' + $pendingRuns.Count + ' check run(s) still in progress: ' + ($pendingRuns -join '; ') + '. The work is not verifiably complete yet - wait for them and verify this exact commit (gh run list --commit ' + $sha + ').')
}

if ($failedRuns.Count -gt 0 -or $infraRuns.Count -gt 0) {
    $parts = @()
    if ($failedRuns.Count -gt 0) {
        $parts += ('FAILED: ' + ($failedRuns -join '; ') + '. Inspect the actual failed job and step (gh run view <id> --log-failed), reproduce locally when practical, make the smallest correct fix, run the relevant validation, then commit, push, and verify the replacement commit. Do not weaken or skip tests, ignore exit codes, or add continue-on-error to force green.')
    }
    if ($infraRuns.Count -gt 0) {
        $parts += ('Abnormal endings: ' + ($infraRuns -join '; ') + '. These are often infrastructure, permission, or flaky failures - report them accurately (not as code failures); one confirming rerun is acceptable (gh run rerun <id>), and repeated flakiness must be investigated.')
    }
    Write-Block -Outcome 'failed' -Reason ('CI CHECK for pushed commit ' + $sha7 + ' on ' + $branch + ' (' + $repoSlug + '): ' + ($parts -join ' '))
}

# All runs for this exact commit completed successfully.
Save-State -Outcome 'verified'
exit 0
