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
#   Pushed-state is resolved via the SAME selected remote that Get-GitHubRepository
#   chose for the CI query (Get-PushedHeadInfo/`.TrackingRef`) - never a raw
#   `@{upstream}` that could silently belong to a different remote.
# - State per repo remembers the last verified/reported SHA so the same
#   commit is never re-verified and a deterministic failure is not nagged
#   endlessly; a NEW pushed commit resets the cycle immediately.
# - Never loops: stop_hook_active exits first. Degrades silently when git,
#   a GitHub remote, or gh is unavailable (it never claims checks passed).
#
# ---- Reported EXTERNAL blocker (confirmed, evidenced, local-only) ----
# When CI is failing/pending only because of a confirmed EXTERNAL condition the
# agent cannot fix (GitHub outage, no hosted runner, an org/repo permission
# failure, an externally-controlled secret being unavailable, a manual
# approval/environment gate, ...), the agent may record an explicit exception
# instead of being blocked forever:
#   pwsh -File Ci-Status-Check.ps1 -ReportExternalBlocker -Classification <see list below> -Reason "<concise evidence>"
# This never marks the commit verified/green - it is stored as a distinct
# 'external-blocker' record, bound to the exact resolved repository + pushed
# HEAD SHA (a different SHA or repository cannot reuse it), expires after
# EXTERNAL_BLOCKER_TTL_MINUTES if unused, requires no source edits, and is
# local-only (%LOCALAPPDATA%\HookMaker\state) - never written into the target
# repository. Classification must be one of the fixed external categories
# below; a normal code/test failure is never eligible.
#
# Optional .env next to this script (copy .env.example):
#   PENDING_COOLDOWN_MINUTES        minutes between "still running" reminders (default 3)
#   FAILURE_COOLDOWN_MINUTES        minutes between reminders for the same failed SHA (default 30)
#   EXTERNAL_BLOCKER_TTL_MINUTES    minutes an external-blocker exception stays valid (default 1440)

param(
    [switch]$ReportExternalBlocker,
    [string]$Classification,
    [string]$Reason
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$script:AllowedExternalClassifications = @(
    'github-outage',
    'runner-unavailable',
    'permission-failure',
    'external-service-outage',
    'external-secret-unavailable',
    'manual-approval-required',
    'other-external'
)

# Resolves "is HEAD an exact, pushed commit on a resolvable GitHub repository"
# identically for the normal Stop flow and for -ReportExternalBlocker, so both
# are always bound to the same repository + tracking ref - this is also what
# fixes the prior mismatch where pushed-state was checked against a different
# remote than the one CI status was actually queried against.
function Get-PushedHeadInfo {
    param([Parameter(Mandatory = $true)][string]$Cwd)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $null }
    $repository = Get-GitHubRepository -ProjectRoot $Cwd
    if ($null -eq $repository -or [string]::IsNullOrWhiteSpace($repository.Branch) -or [string]::IsNullOrWhiteSpace($repository.TrackingRef)) {
        return $null    # no branch, or no trustworthy remote-tracking ref for the selected remote
    }
    $aheadRaw = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-list', '--count', ($repository.TrackingRef + '..HEAD'))
    if ($LASTEXITCODE -ne 0) { return $null }
    if ([int]([string]$aheadRaw).Trim() -gt 0) {
        return $null    # HEAD not pushed yet (relative to the selected remote) - GitSyncCheck's domain
    }
    $sha = ([string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Cwd, 'rev-parse', 'HEAD'))).Trim()
    if ($LASTEXITCODE -ne 0 -or $sha -eq '') { return $null }
    return [pscustomobject]@{ RepoSlug = $repository.Repository; Branch = $repository.Branch; Sha = $sha }
}

# ---- explicit CLI action: record an evidenced external CI blocker ----
if ($ReportExternalBlocker) {
    if ([string]::IsNullOrWhiteSpace($Classification) -or $script:AllowedExternalClassifications -notcontains $Classification) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker requires -Classification to be one of: ' + ($script:AllowedExternalClassifications -join ', ') + '. A normal code/test failure is never eligible.')
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker requires -Reason with concise, concrete evidence.')
        exit 1
    }
    $cwd = (Get-Location).Path
    $info = Get-PushedHeadInfo -Cwd $cwd
    if ($null -eq $info) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker: HEAD is not a resolvable, pushed commit on a GitHub repository from ' + $cwd + '. Push the exact commit to the repository first, then retry.')
        exit 1
    }
    $reasonLine = ($Reason -replace '[\r\n]+', ' ').Trim()
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $externalStatePath = Join-Path $stateDir ('CiStatusCheck-External-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $info.RepoSlug.ToLowerInvariant())) + '.txt')
    [System.IO.File]::WriteAllLines($externalStatePath, @($info.Sha, $info.RepoSlug, $Classification, $reasonLine, [DateTime]::UtcNow.ToString('o')))
    $sha7 = $info.Sha
    if ($sha7.Length -gt 7) { $sha7 = $sha7.Substring(0, 7) }
    [Console]::Out.WriteLine('Recorded an EXTERNAL CI blocker for ' + $info.RepoSlug + '@' + $sha7 + ' [' + $Classification + ']: ' + $reasonLine + '. This does NOT mark CI verified/green - it allows completion to be reported as a documented external blocker until a new commit is pushed or the exception expires.')
    exit 0
}

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

# ---- pushed HEAD on a resolvable GitHub repository? ----
$info = Get-PushedHeadInfo -Cwd $cwd
if ($null -eq $info) { exit 0 }
$repoSlug = $info.RepoSlug
$branch = $info.Branch
$sha = $info.Sha
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
$externalBlockerTtlMinutes = 1440
if ($config.ContainsKey('EXTERNAL_BLOCKER_TTL_MINUTES')) {
    try { $externalBlockerTtlMinutes = [int]$config['EXTERNAL_BLOCKER_TTL_MINUTES'] } catch { }
}

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'

# ---- explicit external-blocker exception: SHA + repo bound, local-only ----
$externalStatePath = Join-Path $stateDir ('CiStatusCheck-External-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $repoSlug.ToLowerInvariant())) + '.txt')
if (Test-Path -LiteralPath $externalStatePath -PathType Leaf) {
    $exceptionValid = $false
    try {
        $extLines = [System.IO.File]::ReadAllLines($externalStatePath)
        if ($extLines.Count -ge 5) {
            $extSha = $extLines[0].Trim()
            $extRepo = $extLines[1].Trim()
            $extTime = [DateTime]::Parse($extLines[4].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if ($extSha -eq $sha -and $extRepo -eq $repoSlug -and ([DateTime]::UtcNow - $extTime).TotalMinutes -lt $externalBlockerTtlMinutes) {
                $exceptionValid = $true
            }
        }
    }
    catch { }
    if ($exceptionValid) {
        exit 0    # explicit, evidenced external blocker recorded for this exact commit - allow completion; never marks CI verified/green
    }
    # Stale, expired, or bound to a different commit/repository - drop it so it
    # can never be misread as still active by a later run.
    Remove-Item -LiteralPath $externalStatePath -Force -ErrorAction SilentlyContinue
}

# ---- per-repo state: sha / outcome / timestamp ----
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
        @{ decision = 'block'; reason = ('CI CHECK: pushed commit ' + $sha7 + ' still has failed checks. Detailed failure guidance was recently reported; completion remains blocked until a replacement commit is pushed or the failure is reported as an external/manual blocker.') } | ConvertTo-Json -Compress
        exit 0
    }
    if ($stateOutcome -eq 'pending' -and $ageMinutes -lt $pendingCooldown) {
        @{ decision = 'block'; reason = ('CI CHECK: pushed commit ' + $sha7 + ' is still awaiting terminal checks. Detailed status was recently reported; completion remains blocked.') } | ConvertTo-Json -Compress
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
    $json = @{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine($json)
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
$rawJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--repo', $repoSlug, '--commit', $sha, '--json', 'databaseId,name,workflowName,status,conclusion', '--limit', '50')
if ($LASTEXITCODE -ne 0) {
    exit 0    # API/permission failure: degrade without claiming anything
}
$runs = @()
try {
    $parsedRuns = ((@($rawJson) -join "`n") | ConvertFrom-Json)
    $runs = @($parsedRuns | ForEach-Object { $_ })
}
catch { $runs = @() }

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
