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
# ---- Reported EXTERNAL blocker (confirmed, evidenced, local-only, re-verified) ----
# When CI is failing/pending only because of a confirmed EXTERNAL condition the
# agent cannot fix (GitHub outage, no hosted runner, an org/repo permission
# failure, an externally-controlled secret being unavailable, a manual
# approval/environment gate, ...), the agent may record an explicit exception
# instead of being blocked forever:
#   pwsh -File Ci-Status-Check.ps1 -ReportExternalBlocker -Classification <see list below> -Reason "<concise evidence>"
# Recording ALWAYS queries the exact-SHA CI state first (never accepted blind):
# - refused if that commit is already fully green (nothing to excuse);
# - refused if any check shows a genuine COMPLETED failure/startup_failure -
#   a real code/test/build/lint failure is never eligible, regardless of
#   classification (this is what stops "other-external" from being a bypass);
# - otherwise the observed run states are hashed into a non-secret fingerprint
#   and stored alongside the record.
# This never marks the commit verified/green. Every subsequent Stop still
# performs a THROTTLED (EXTERNAL_BLOCKER_RECHECK_MINUTES) exact-SHA
# re-evaluation while the exception exists: the same fingerprint keeps
# completion allowed (reported as an external blocker, not success); CI
# turning green retires the exception and verifies normally; CI changing to a
# DIFFERENT state (including a real failure) invalidates the exception and
# falls back to normal blocking. Bound to the exact resolved repository +
# pushed HEAD SHA (a different SHA or repository cannot reuse it), expires
# after EXTERNAL_BLOCKER_TTL_MINUTES if never rechecked, requires no source
# edits, and is local-only (%LOCALAPPDATA%\HookMaker\state) - never written
# into the target repository.
#
# Optional .env next to this script (copy .env.example):
#   PENDING_COOLDOWN_MINUTES          minutes between "still running" reminders (default 3)
#   FAILURE_COOLDOWN_MINUTES          minutes between reminders for the same failed SHA (default 30)
#   EXTERNAL_BLOCKER_TTL_MINUTES      minutes an external-blocker exception stays valid (default 1440)
#   EXTERNAL_BLOCKER_RECHECK_MINUTES  minutes between re-verifying an active exception's CI state (default 15)

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

# Queries the exact-SHA CI state and classifies it identically for the normal
# flow and for -ReportExternalBlocker, so both always agree on what "the
# current state" means. Returns $null when it cannot be verified at all (gh
# missing/unauthenticated, or the API call itself failed) - callers must then
# degrade without claiming anything. Fingerprint is a hash of each run's
# (id, status, conclusion) - non-secret, deterministic, changes exactly when
# the observed CI state changes.
function Get-CiRunSnapshot {
    param([string]$RepoSlug, [string]$Sha)
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    $null = Invoke-QuietCommand -FilePath gh -ArgumentList @('auth', 'status')
    if ($LASTEXITCODE -ne 0) { return $null }
    $rawJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--repo', $RepoSlug, '--commit', $Sha, '--json', 'databaseId,name,workflowName,status,conclusion', '--limit', '50')
    if ($LASTEXITCODE -ne 0) { return $null }
    $runs = @()
    try {
        $parsedRuns = ((@($rawJson) -join "`n") | ConvertFrom-Json)
        $runs = @($parsedRuns | ForEach-Object { $_ })
    }
    catch { $runs = @() }

    $pendingRuns = @()
    $failedRuns = @()
    $infraRuns = @()
    $fingerprintParts = New-Object System.Collections.Generic.List[string]
    foreach ($run in @($runs | Sort-Object { [string](Get-Field $_ 'databaseId') })) {
        if ($null -eq $run) { continue }
        $name = [string](Get-Field $run 'workflowName')
        if ($name -eq '') { $name = [string](Get-Field $run 'name') }
        $id = [string](Get-Field $run 'databaseId')
        $entry = $name + ' (run ' + $id + ')'
        $status = ([string](Get-Field $run 'status')).ToLowerInvariant()
        $conclusion = ([string](Get-Field $run 'conclusion')).ToLowerInvariant()
        [void]$fingerprintParts.Add($id + ':' + $status + ':' + $conclusion)
        if ($status -ne 'completed') { $pendingRuns += $entry }
        elseif ($conclusion -in @('success', 'neutral', 'skipped')) { }
        elseif ($conclusion -in @('failure', 'startup_failure')) { $failedRuns += $entry }
        else {
            # cancelled / timed_out / stale / action_required / unknown:
            # abnormal endings that are often infrastructure or flakiness.
            $infraRuns += ($entry + ' [' + $conclusion + ']')
        }
    }
    $fingerprint = Get-ShortHash (($fingerprintParts.ToArray() -join '|'))
    $allSuccess = ($runs.Count -gt 0 -and $pendingRuns.Count -eq 0 -and $failedRuns.Count -eq 0 -and $infraRuns.Count -eq 0)
    return [pscustomobject]@{
        Runs = $runs; PendingRuns = $pendingRuns; FailedRuns = $failedRuns; InfraRuns = $infraRuns
        Fingerprint = $fingerprint; AllSuccess = $allSuccess
    }
}

# ---- explicit CLI action: record an evidenced, CI-verified external blocker ----
if ($ReportExternalBlocker) {
    if ([string]::IsNullOrWhiteSpace($Classification) -or $script:AllowedExternalClassifications -notcontains $Classification) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker requires -Classification to be one of: ' + ($script:AllowedExternalClassifications -join ', ') + '. A normal code/test failure is never eligible.')
        exit 1
    }
    $reasonLine = ($Reason -replace '[\r\n]+', ' ').Trim()
    # "other-external" is the open-ended escape hatch, so it is held to a
    # stronger evidence bar (a longer, more concrete reason) than the named
    # categories - a one-word reason is never enough for either.
    $minReasonLength = if ($Classification -eq 'other-external') { 30 } else { 10 }
    if ($reasonLine.Length -lt $minReasonLength) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker requires -Reason with at least ' + $minReasonLength + ' characters of concrete evidence' + $(if ($Classification -eq 'other-external') { ' ("other-external" needs stronger justification than the named categories' } else { '' }) + '.')
        exit 1
    }
    $cwd = (Get-Location).Path
    $info = Get-PushedHeadInfo -Cwd $cwd
    if ($null -eq $info) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker: HEAD is not a resolvable, pushed commit on a GitHub repository from ' + $cwd + '. Push the exact commit to the repository first, then retry.')
        exit 1
    }
    # Never record blind: the exact-SHA CI state must be queried and captured
    # right now, and a genuine completed failure can never be excused.
    $snapshot = Get-CiRunSnapshot -RepoSlug $info.RepoSlug -Sha $info.Sha
    if ($null -eq $snapshot) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker: could not query GitHub Actions for this commit (gh missing, unauthenticated, or the API call itself failed). An exception cannot be recorded without a capturable query result - verify gh/auth/connectivity and retry.')
        exit 1
    }
    if ($snapshot.AllSuccess) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker: CI for this commit is already fully green - there is nothing to report as an external blocker. Finish normally.')
        exit 1
    }
    if ($snapshot.FailedRuns.Count -gt 0) {
        [Console]::Error.WriteLine('Ci-Status-Check -ReportExternalBlocker: refused. This commit has a genuine COMPLETED failure (' + ($snapshot.FailedRuns -join '; ') + ') - a real test/build/lint failure is never eligible to be reported as external, regardless of classification. Fix the actual failure.')
        exit 1
    }
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $externalStatePath = Join-Path $stateDir ('CiStatusCheck-External-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $info.RepoSlug.ToLowerInvariant())) + '.txt')
    $nowIso = [DateTime]::UtcNow.ToString('o')
    [System.IO.File]::WriteAllLines($externalStatePath, @($info.Sha, $info.RepoSlug, $Classification, $reasonLine, $nowIso, $snapshot.Fingerprint, $nowIso))
    $sha7 = $info.Sha
    if ($sha7.Length -gt 7) { $sha7 = $sha7.Substring(0, 7) }
    [Console]::Out.WriteLine('Recorded an EXTERNAL CI blocker for ' + $info.RepoSlug + '@' + $sha7 + ' [' + $Classification + ']: ' + $reasonLine + '. Bound to the exact observed CI state; a later Stop re-check retires this automatically if CI turns green, or invalidates it if the state changes. This does NOT mark CI verified/green.')
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
$externalBlockerRecheckMinutes = 15
if ($config.ContainsKey('EXTERNAL_BLOCKER_RECHECK_MINUTES')) {
    try { $externalBlockerRecheckMinutes = [int]$config['EXTERNAL_BLOCKER_RECHECK_MINUTES'] } catch { }
}

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('CiStatusCheck-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $repoSlug.ToLowerInvariant())) + '.txt')
$externalStatePath = Join-Path $stateDir ('CiStatusCheck-External-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $repoSlug.ToLowerInvariant())) + '.txt')

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

# ---- explicit external-blocker exception: SHA + repo bound, local-only,
# re-verified on a throttle so it can never silently outlive a changed CI
# state (a rerun, a fix, or a genuinely different failure). ----
$prefetchedSnapshot = $null
if (Test-Path -LiteralPath $externalStatePath -PathType Leaf) {
    $extValid = $false
    $extClassification = ''
    $extReason = ''
    $extRecordedRaw = ''
    $extFingerprint = ''
    $extLastCheckedTime = [DateTime]::MinValue
    try {
        $extLines = [System.IO.File]::ReadAllLines($externalStatePath)
        if ($extLines.Count -ge 7) {
            $extSha = $extLines[0].Trim()
            $extRepo = $extLines[1].Trim()
            $extClassification = $extLines[2].Trim()
            $extReason = $extLines[3].Trim()
            $extRecordedRaw = $extLines[4].Trim()
            $extRecordedTime = [DateTime]::Parse($extRecordedRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            $extFingerprint = $extLines[5].Trim()
            $extLastCheckedTime = [DateTime]::Parse($extLines[6].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if ($extSha -eq $sha -and $extRepo -eq $repoSlug -and ([DateTime]::UtcNow - $extRecordedTime).TotalMinutes -lt $externalBlockerTtlMinutes) {
                $extValid = $true
            }
        }
    }
    catch { }
    if ($extValid) {
        if (([DateTime]::UtcNow - $extLastCheckedTime).TotalMinutes -lt $externalBlockerRecheckMinutes) {
            exit 0    # within the re-check throttle window - same external blocker still applies
        }
        $recheck = Get-CiRunSnapshot -RepoSlug $repoSlug -Sha $sha
        if ($null -eq $recheck) {
            # Cannot verify right now - keep tolerating the existing, already
            # evidenced exception (never invent a new one, never claim verified).
            try { [System.IO.File]::WriteAllLines($externalStatePath, @($sha, $repoSlug, $extClassification, $extReason, $extRecordedRaw, $extFingerprint, [DateTime]::UtcNow.ToString('o'))) } catch { }
            exit 0
        }
        if ($recheck.AllSuccess) {
            # CI recovered - retire the exception and verify normally (green,
            # not "excused").
            Remove-Item -LiteralPath $externalStatePath -Force -ErrorAction SilentlyContinue
            Save-State -Outcome 'verified'
            exit 0
        }
        if ($recheck.Fingerprint -eq $extFingerprint) {
            # The exact same external condition persists - refresh only the
            # recheck timestamp, keep allowing completion.
            try { [System.IO.File]::WriteAllLines($externalStatePath, @($sha, $repoSlug, $extClassification, $extReason, $extRecordedRaw, $extFingerprint, [DateTime]::UtcNow.ToString('o'))) } catch { }
            exit 0
        }
        # CI now shows a DIFFERENT state (possibly a genuine new failure) -
        # invalidate the stale exception and fall through to normal
        # evaluation using the snapshot just fetched (no duplicate query).
        Remove-Item -LiteralPath $externalStatePath -Force -ErrorAction SilentlyContinue
        $prefetchedSnapshot = $recheck
    }
    else {
        # Stale, expired, or bound to a different commit/repository - drop it
        # so it can never be misread as still active by a later run.
        Remove-Item -LiteralPath $externalStatePath -Force -ErrorAction SilentlyContinue
    }
}

# ---- per-repo state: sha / outcome / timestamp (skipped when a fresh
# snapshot was just fetched above - act on that, not a stale cooldown) ----
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
if ($null -eq $prefetchedSnapshot -and $stateSha -eq $sha) {
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

# ---- workflow runs for the EXACT pushed commit (reuse a just-invalidated
# exception's freshly-fetched snapshot when available, never query gh twice) ----
$snapshot = $prefetchedSnapshot
if ($null -eq $snapshot) {
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { exit 0 }    # silent degradation: never claim verified
    $null = Invoke-QuietCommand -FilePath gh -ArgumentList @('auth', 'status')
    if ($LASTEXITCODE -ne 0) { exit 0 }
    $snapshot = Get-CiRunSnapshot -RepoSlug $repoSlug -Sha $sha
    if ($null -eq $snapshot) { exit 0 }    # API/permission failure: degrade without claiming anything
}

if ($snapshot.Runs.Count -eq 0) {
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

if ($snapshot.PendingRuns.Count -gt 0) {
    Write-Block -Outcome 'pending' -Reason ('CI CHECK: pushed commit ' + $sha7 + ' on ' + $branch + ' (' + $repoSlug + ') has ' + $snapshot.PendingRuns.Count + ' check run(s) still in progress: ' + ($snapshot.PendingRuns -join '; ') + '. The work is not verifiably complete yet - wait for them and verify this exact commit (gh run list --commit ' + $sha + ').')
}

if ($snapshot.FailedRuns.Count -gt 0 -or $snapshot.InfraRuns.Count -gt 0) {
    $parts = @()
    if ($snapshot.FailedRuns.Count -gt 0) {
        $parts += ('FAILED: ' + ($snapshot.FailedRuns -join '; ') + '. Inspect the actual failed job and step (gh run view <id> --log-failed), reproduce locally when practical, make the smallest correct fix, run the relevant validation, then commit, push, and verify the replacement commit. Do not weaken or skip tests, ignore exit codes, or add continue-on-error to force green.')
    }
    if ($snapshot.InfraRuns.Count -gt 0) {
        $parts += ('Abnormal endings: ' + ($snapshot.InfraRuns -join '; ') + '. These are often infrastructure, permission, or flaky failures - report them accurately (not as code failures); one confirming rerun is acceptable (gh run rerun <id>), and repeated flakiness must be investigated. If genuinely external, it may be recorded: -ReportExternalBlocker.')
    }
    Write-Block -Outcome 'failed' -Reason ('CI CHECK for pushed commit ' + $sha7 + ' on ' + $branch + ' (' + $repoSlug + '): ' + ($parts -join ' '))
}

# All runs for this exact commit completed successfully.
Save-State -Outcome 'verified'
exit 0
