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
#   endlessly; a NEW pushed commit resets the cycle immediately. That is also
#   the ::deep-debug contract (E-09): the workflow's final gate holds for the
#   EXACT final pushed SHA including accepted post-Ponytail changes - a later
#   commit re-verifies on its own SHA, and this hook's result alone never
#   claims the whole workflow passed.
# - NON-GREEN states (E-09): no run/status data; an expected workflow absent
#   (workflows exist on disk but no runs registered); queued/in-progress
#   (status not completed); completed cancelled / timed_out / stale /
#   action_required / unknown; failure / startup_failure; EVERY completed run
#   skipped (unexpected skip - nothing verified the commit); and any SHA
#   mismatch (an unpushed/different HEAD is never evaluated as this commit -
#   Get-PushedHeadInfo re-derives the exact pushed HEAD every Stop). An
#   external-blocker exception may permit an explicitly BLOCKED/exceptional
#   completion but NEVER reads as "CI passed".
# - Never loops: stop_hook_active exits first. Degrades silently when git,
#   a GitHub remote, or gh is unavailable (it never claims checks passed).
#
# ---- Reported EXTERNAL blocker (confirmed, evidenced, local-only, re-verified) ----
# When CI is blocked only by a confirmed EXTERNAL condition the agent cannot
# fix, the agent may record an explicit exception instead of being blocked
# forever:
#   pwsh -File Ci-Status-Check.ps1 -ReportExternalBlocker -Classification <see list below> -Reason "<concise evidence>"
# ELIGIBILITY (conservative, no log interpretation): an exception may only be
# recorded when the observed GitHub run state is one the hook can identify as
# non-code-failure WITHOUT reading logs - i.e. still pending / a manual gate,
# or a completed run whose conclusion is cancelled / timed_out / stale /
# action_required (or similar abnormal ending). A completed `failure` or
# `startup_failure` is NEVER eligible: the hook cannot distinguish a genuine
# code/test/build/lint failure from an external one without inspecting trusted
# evidence, so it always treats those as real and refuses the exception,
# regardless of classification (including `other-external`). The named
# classifications (`github-outage`, `runner-unavailable`, `permission-failure`,
# `external-service-outage`, `external-secret-unavailable`,
# `manual-approval-required`, `account-billing`, `other-external`) describe WHY,
# but are usable only when the observed run state is eligible above - they
# cannot excuse a generic `failure`.
#
# ONE narrow, evidence-backed exception to "a completed failure is never
# eligible": an ACCOUNT BILLING / PAYMENT / SPENDING-LIMIT block. When Actions
# cannot start for that reason GitHub reports every run as conclusion=failure
# even though NO job ran, so status alone is indistinguishable from a real
# failure - which is exactly why this is otherwise refused. The distinguishing
# evidence is GitHub's OWN check-run annotation ("recent account payments have
# failed or your spending limit needs to be increased"), fetched from the
# check-runs annotations API - a GitHub-authored signal, NEVER inferred from
# step counts (a broken workflow file also yields zero steps but a DIFFERENT
# annotation, so it still hard-blocks). Test-CiBillingBlocked returns true ONLY
# when EVERY failing check-run for the commit carries that billing annotation,
# and fails CLOSED on any query error, an oversized set, or a single failing
# check-run without it. A genuine test failure never carries the annotation, so
# it is never mistaken for billing. This case is AUTO-detected and AUTO-recorded
# as `account-billing` (no -ReportExternalBlocker needed); it still never marks
# CI green and reuses the same throttled recheck/retire machinery below.
# Recording ALWAYS queries the exact-SHA CI state first (never accepted blind):
# - refused if that commit is already fully green (nothing to excuse);
# - refused if any check shows a genuine COMPLETED failure/startup_failure;
# - refused if CI cannot be queried at all;
# - otherwise the observed run states are hashed into a non-secret fingerprint
#   (databaseId/attempt/workflowName/status/conclusion/updatedAt) and stored.
# This never marks the commit verified/green. While an exception authorizes
# completion, Stop emits a NON-BLOCKING "CI NOT VERIFIED GREEN" context notice
# - ONCE per session per blocker, see Write-ExternalBlockerContext - so the
# final task context can never misrepresent CI as successful. The
# notice shape is CLIENT-AWARE (see Write-ExternalBlockerContext below):
# Claude Code gets `hookSpecificOutput.additionalContext` (documented
# model-visible on Stop); Codex gets `systemMessage` (its only documented
# common Stop field - user/event-visible, not documented as model-visible for
# Codex). Client is detected the same way Rules-Check does: CLAUDE_PROJECT_DIR
# present -> Claude, absent -> Codex. Neither shape ever uses `decision:block`.
# Every subsequent Stop performs a THROTTLED (EXTERNAL_BLOCKER_RECHECK_MINUTES)
# exact-SHA re-evaluation: the same fingerprint keeps completion allowed
# (reported as an external blocker, not success); CI turning green retires the
# exception and verifies normally (no external wording); CI changing to a
# DIFFERENT state (including a real failure) invalidates the exception and
# falls back to normal blocking. Bound to the exact resolved repository +
# pushed HEAD SHA (a different SHA or repository cannot reuse it), expires
# after EXTERNAL_BLOCKER_TTL_MINUTES if never rechecked, requires no source
# edits, and is local-only (%LOCALAPPDATA%\HookMaker\state) - never written
# into the target repository.
# This is NOT a log-analysis subsystem: it does not parse job logs to decide
# whether a `failure` is external.
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
    'account-billing',
    'other-external'
)

# GitHub's own wording when Actions is blocked by account billing/payment or a
# spending limit. Matched case-insensitively against check-run annotation
# messages. Deliberately tight - these phrases appear only in GitHub's billing
# block, never in a real test/build failure annotation - so the match fails
# CLOSED (a real failure is never read as billing). Update if GitHub rewords.
$script:BillingAnnotationPattern = '(?i)(payments have failed|spending limit|billing & plans)'

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
# degrade without claiming anything. The fingerprint hashes each run's
# (databaseId, attempt, workflowName, status, conclusion, updatedAt) - all
# non-secret, stable fields actually supported by `gh run list --json` - so a
# rerun (new attempt / newer updatedAt) or any materially changed state
# produces a different fingerprint even when the run id/status/conclusion are
# unchanged. The per-run parts are normalized and sorted deterministically so
# ordering never affects the hash.
# True ONLY when the commit's failure is a GitHub account billing/payment/
# spending-limit block, proven by GitHub's OWN check-run annotations - never
# inferred from step counts. Reads the COMPLETE, paginated set of check-runs for
# the commit (raw JSON, no jq), verifying the fetched count reaches the reported
# total_count, then the (paginated) annotations of each FAILING one, and requires
# EVERY failing check-run in that complete set to carry the billing annotation.
# Fails CLOSED (returns $false, so the caller keeps treating the runs as a
# genuine failure) on: any query error, an unparseable/missing-field response, a
# total_count larger than the strict page bound can verify, a fetched count that
# does not reach total_count (truncation), no failing check-run found, or a
# single failing check-run whose annotations do not include the billing message.
# A real test failure never carries that annotation; a broken workflow yields a
# different one - so neither is ever mistaken for billing.
function Test-CiBillingBlocked {
    param([string]$RepoSlug, [string]$Sha)
    # Strict pagination bound: at most 20 pages of 100 = 2000 check-runs, and the
    # same 20-page ceiling for one check-run's annotations. Anything we cannot
    # fully verify within that bound fails CLOSED, so an unverifiable set is
    # always treated as a genuine failure, never as billing.
    # ponytail: fixed 2000-check-run ceiling; revisit only if a real commit
    # legitimately carries more check-runs than that.
    $maxPages = 20
    $perPage = 100
    $maxCheckRuns = $maxPages * $perPage

    # ---- collect EVERY check-run page; the fetched count must reach total_count ----
    $checkRuns = New-Object System.Collections.Generic.List[object]
    $totalCount = -1
    for ($page = 1; $page -le $maxPages; $page++) {
        $listJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('api', ('repos/' + $RepoSlug + '/commits/' + $Sha + '/check-runs?per_page=' + $perPage + '&page=' + $page))
        if ($LASTEXITCODE -ne 0) { return $false }              # query error - fail closed
        try { $parsed = ((@($listJson) -join "`n") | ConvertFrom-Json) }
        catch { return $false }                                 # unparseable - fail closed
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['total_count'] -or $null -eq $parsed.PSObject.Properties['check_runs']) {
            return $false                                       # missing required fields - fail closed
        }
        if ($page -eq 1) {
            $totalCount = [long]$parsed.total_count
            if ($totalCount -gt $maxCheckRuns) { return $false } # more than we can verify - fail closed
        }
        $pageRuns = @($parsed.check_runs)
        foreach ($cr in $pageRuns) { if ($null -ne $cr) { [void]$checkRuns.Add($cr) } }
        if ($checkRuns.Count -ge $totalCount) { break }          # collected the whole set
        if ($pageRuns.Count -eq 0) { break }                     # page ran dry early - truncation, caught below
    }
    if ($totalCount -lt 0 -or $checkRuns.Count -ne $totalCount) { return $false }  # incomplete set - fail closed

    $failingIds = New-Object System.Collections.Generic.List[string]
    foreach ($cr in $checkRuns) {
        if ($null -eq $cr) { continue }
        $concl = ([string](Get-Field $cr 'conclusion')).ToLowerInvariant()
        if ($concl -eq 'failure' -or $concl -eq 'startup_failure') {
            [void]$failingIds.Add([string](Get-Field $cr 'id'))
        }
    }
    if ($failingIds.Count -eq 0) { return $false }               # nothing failing here - not our case
    # GitHub attaches the billing annotation to ONE check-run; its siblings in
    # the same blocked run fail carrying NO annotations at all. Demanding the
    # annotation on EVERY failing check-run therefore can never be satisfied by
    # a multi-job workflow - measured 2026-09-12 on this repository's 7-job
    # matrix, exactly 1 of 7 carried it and the other 6 had none, so the whole
    # auto-detection was dead for any matrix build.
    #
    # "No annotations" is INCONCLUSIVE on its own, not disqualifying. A
    # DIFFERENT failure annotation still hard-blocks, which is the property the
    # stricter rule existed to protect: a broken workflow file also yields zero
    # steps, but it yields its own annotation, so it can never be read as
    # billing. Billing therefore needs one positive and zero contradictions.
    $sawBilling = $false
    foreach ($id in $failingIds) {
        $verdict = Get-CheckRunBillingVerdict -RepoSlug $RepoSlug -CheckRunId $id -MaxPages $maxPages -PerPage $perPage
        if ($verdict -eq 'billing') { $sawBilling = $true; continue }
        if ($verdict -eq 'none') { continue }                     # unannotated sibling of the blocked run
        return $false                                            # 'other' (a real annotated failure) or 'unverifiable' - fail closed
    }
    return $sawBilling
}

# One check-run's annotations, as a three-state verdict across every page up to
# the same strict bound:
#   'billing'      - carries GitHub's billing/payment failure annotation
#   'none'         - reached a terminating empty page with no failure annotation
#   'other'        - carries a failure annotation that is NOT billing
#   'unverifiable' - query error, unparseable page, or the page bound was hit
# Only 'billing' is positive evidence; 'other' and 'unverifiable' are treated as
# a genuine failure by the caller, so the function still fails CLOSED.
function Get-CheckRunBillingVerdict {
    param([string]$RepoSlug, [string]$CheckRunId, [int]$MaxPages, [int]$PerPage)
    $sawOtherFailure = $false
    for ($page = 1; $page -le $MaxPages; $page++) {
        $annJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('api', ('repos/' + $RepoSlug + '/check-runs/' + $CheckRunId + '/annotations?per_page=' + $PerPage + '&page=' + $page))
        if ($LASTEXITCODE -ne 0) { return 'unverifiable' }       # query error - fail closed
        try { $annotations = @(((@($annJson) -join "`n") | ConvertFrom-Json)) }
        catch { return 'unverifiable' }                          # unparseable - fail closed
        if ($annotations.Count -eq 0) {
            if ($sawOtherFailure) { return 'other' }
            return 'none'                                        # no annotations at all - inconclusive, not disqualifying
        }
        foreach ($ann in $annotations) {
            if ($null -eq $ann) { continue }
            $level = ([string](Get-Field $ann 'annotation_level')).ToLowerInvariant()
            $message = [string](Get-Field $ann 'message')
            if ($level -eq 'failure' -and $message -match $script:BillingAnnotationPattern) { return 'billing' }
            if ($level -eq 'failure') { $sawOtherFailure = $true }
        }
    }
    return 'unverifiable'    # exceeded the page bound without a terminating empty page - fail closed
}

function Get-CiRunSnapshot {
    param([string]$RepoSlug, [string]$Sha)
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    $null = Invoke-QuietCommand -FilePath gh -ArgumentList @('auth', 'status')
    if ($LASTEXITCODE -ne 0) { return $null }
    $rawJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--repo', $RepoSlug, '--commit', $Sha, '--json', 'databaseId,attempt,name,workflowName,status,conclusion,updatedAt', '--limit', '50')
    if ($LASTEXITCODE -ne 0) { return $null }
    $runs = @()
    try {
        $parsedRuns = ((@($rawJson) -join "`n") | ConvertFrom-Json)
        $runs = @($parsedRuns | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
    }
    catch { $runs = @() }

    $pendingRuns = @()
    $failedRuns = @()
    $infraRuns = @()
    $successRunCount = 0
    $skippedRuns = @()
    $fingerprintParts = New-Object System.Collections.Generic.List[string]
    foreach ($run in @($runs)) {
        if ($null -eq $run) { continue }
        $name = [string](Get-Field $run 'workflowName')
        if ($name -eq '') { $name = [string](Get-Field $run 'name') }
        $id = [string](Get-Field $run 'databaseId')
        $attempt = [string](Get-Field $run 'attempt')
        $updatedAt = [string](Get-Field $run 'updatedAt')
        $entry = $name + ' (run ' + $id + ')'
        $status = ([string](Get-Field $run 'status')).ToLowerInvariant()
        $conclusion = ([string](Get-Field $run 'conclusion')).ToLowerInvariant()
        # Non-secret, stable identity for this run; joined with a delimiter that
        # cannot appear in the values, and the whole set is sorted below.
        [void]$fingerprintParts.Add($id + "`t" + $attempt + "`t" + $name + "`t" + $status + "`t" + $conclusion + "`t" + $updatedAt)
        if ($status -ne 'completed') { $pendingRuns += $entry }
        elseif ($conclusion -in @('success', 'neutral')) { $successRunCount++ }
        elseif ($conclusion -eq 'skipped') { $skippedRuns += $entry }
        elseif ($conclusion -in @('failure', 'startup_failure')) { $failedRuns += $entry }
        else {
            # cancelled / timed_out / stale / action_required / unknown:
            # abnormal endings that are often infrastructure or flakiness -
            # the ONLY states an external-blocker exception may excuse
            # (a genuine completed failure/startup_failure never is).
            $infraRuns += ($entry + ' [' + $conclusion + ']')
        }
    }
    # UNEXPECTED SKIP (E-09): a 'skipped' conclusion is a normal green companion
    # to at least one genuinely successful run (path filters, conditional jobs),
    # but when EVERY completed run was skipped nothing actually verified this
    # commit - that must never read as CI-green. Classified with the abnormal
    # endings so it blocks (and stays eligible for an evidenced external-blocker
    # exception), never as success.
    if ($successRunCount -eq 0 -and $skippedRuns.Count -gt 0) {
        foreach ($skippedEntry in $skippedRuns) { $infraRuns += ($skippedEntry + ' [skipped - every run was skipped, nothing verified this commit]') }
    }
    # A completed failure is a genuine code failure UNLESS GitHub's own
    # annotations prove it is an account billing/payment block (no job ran).
    # Reclassify those out of $failedRuns so a real failure is never masked - the
    # check only runs when there IS a failure (never on the green path), keys on
    # GitHub's authored annotation, and requires EVERY failing run to be
    # billing-annotated (billing blocks everything, so a mix with a real failure
    # cannot occur). The fingerprint above is computed over ALL runs before this,
    # so reclassification never changes it and the recheck/retire logic stays
    # stable.
    $billingRuns = @()
    if ($failedRuns.Count -gt 0 -and (Test-CiBillingBlocked -RepoSlug $RepoSlug -Sha $Sha)) {
        $billingRuns = $failedRuns
        $failedRuns = @()
    }
    $fingerprint = Get-ShortHash ((@($fingerprintParts.ToArray() | Sort-Object) -join '|'))
    $allSuccess = ($runs.Count -gt 0 -and $pendingRuns.Count -eq 0 -and $failedRuns.Count -eq 0 -and $infraRuns.Count -eq 0 -and $billingRuns.Count -eq 0)
    return [pscustomobject]@{
        Runs = $runs; PendingRuns = $pendingRuns; FailedRuns = $failedRuns; InfraRuns = $infraRuns
        BillingRuns = $billingRuns; Fingerprint = $fingerprint; AllSuccess = $allSuccess
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
# Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
# for ANY gate's block, and exiting on it alone let one block silence the
# other twelve on the same Stop.
if (Test-StopStandDown -HookInput $hookInput -HookName 'Ci-Status-Check') {
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
    # Record the block so THIS hook's own re-entry is recognised; another
    # gate's block must not mute it, and its own must not repeat.
    Set-StopBlockMarker -HookInput $hookInput -HookName 'Ci-Status-Check'
    exit (Write-HookResult -EventName $script:eventName -Kind 'block' -Reason $Reason).ExitCode
}

# Emits a NON-BLOCKING completion-context notice while a valid external-blocker
# exception authorizes completion. It never emits `decision:block` and can
# never misrepresent CI as green - it states explicitly that CI is NOT verified
# and completion is allowed only because of the recorded external blocker.
#
# The output shape is CLIENT-AWARE, using the officially supported non-blocking
# Stop field for each client (verified against the current Claude Code and Codex
# hook docs, 2026-07-17):
# - Claude Code: `hookSpecificOutput.additionalContext` is documented as
#   MODEL-VISIBLE for Stop/SubagentStop ("at the end of the turn ... so Claude
#   can act on the feedback"); `systemMessage` there is only shown to the user.
# - Codex: Stop does NOT document `hookSpecificOutput.additionalContext`; its
#   supported common field is `systemMessage`, "surfaced as a warning in the UI
#   or event stream" (user/event-visible, NOT documented as model-visible).
#   Codex Stop `decision:block` would FORCE CONTINUATION (a new prompt), so it
#   is never used here.
# Client detection and the per-client wrapper both come from the shared
# Write-HookResult adapter. Neither output can claim CI success; the message
# text is identical for every client, only the JSON wrapper differs.
#
# ONCE PER SESSION PER BLOCKER. On Claude Code a Stop hook's additionalContext
# is not a passive note: the client re-invokes the model with it (observed
# in Claude Code 2.1.260 on 2026-09-07 - a hook_additional_context transcript
# entry followed by a fresh assistant turn seconds later, with no user input
# between them). Emitted on every Stop, this notice therefore re-invoked the
# agent on every Stop: it answered, stopped, was re-invoked, answered again,
# until the user interrupted - and a billing blocker stays valid for a day
# in every repository that has one. A Stop advisory is a soft block and is
# bounded like one: the same (repo, sha, classification) is delivered once
# per session; a new session, a new pushed commit or a changed blocker is
# told again.
function Write-ExternalBlockerContext {
    param([string]$Classification, [string]$Reason, [string]$Sha7, [string]$RepoSlug, [string]$EventName)
    $noticeStamp = ([string](Get-Field $hookInput 'session_id')) + '|' +
        (Get-ShortHash ($RepoSlug.ToLowerInvariant() + '|' + $Sha7 + '|' + $Classification))
    $noticePath = Join-Path $stateDir ('CiStatusCheck-Notice-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $RepoSlug.ToLowerInvariant())) + '.txt')
    $alreadyTold = $false
    try {
        if (Test-Path -LiteralPath $noticePath -PathType Leaf) {
            $alreadyTold = (([System.IO.File]::ReadAllText($noticePath)).Trim() -eq $noticeStamp)
        }
    }
    catch { $alreadyTold = $false }
    if ($alreadyTold) { exit 0 }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($noticePath, $noticeStamp)
    }
    catch { }
    $message = 'CI NOT VERIFIED GREEN. Completion is allowed only because a recorded EXTERNAL CI blocker is in effect for ' +
        $RepoSlug + '@' + $Sha7 + ' [' + $Classification + ']: ' + $Reason +
        '. This is a documented external blocker, not a successful CI run - report it accurately and do not claim CI passed.'
    $null = Write-HookResult -EventName $EventName -Kind 'advisory' -Message $message
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
            # Within the re-check throttle window - same external blocker still
            # applies; surface the non-blocking "CI not green" notice.
            Write-ExternalBlockerContext -Classification $extClassification -Reason $extReason -Sha7 $sha7 -RepoSlug $repoSlug -EventName $eventName
        }
        $recheck = Get-CiRunSnapshot -RepoSlug $repoSlug -Sha $sha
        if ($null -eq $recheck) {
            # Cannot verify right now - keep tolerating the existing, already
            # evidenced exception (never invent a new one, never claim verified).
            try { [System.IO.File]::WriteAllLines($externalStatePath, @($sha, $repoSlug, $extClassification, $extReason, $extRecordedRaw, $extFingerprint, [DateTime]::UtcNow.ToString('o'))) } catch { }
            Write-ExternalBlockerContext -Classification $extClassification -Reason $extReason -Sha7 $sha7 -RepoSlug $repoSlug -EventName $eventName
        }
        if ($recheck.AllSuccess) {
            # CI recovered - retire the exception and verify normally (green,
            # not "excused"); no external wording.
            Remove-Item -LiteralPath $externalStatePath -Force -ErrorAction SilentlyContinue
            Save-State -Outcome 'verified'
            exit 0
        }
        if ($recheck.Fingerprint -eq $extFingerprint) {
            # The exact same external condition persists - refresh the recheck
            # timestamp, keep allowing completion, and surface the notice.
            try { [System.IO.File]::WriteAllLines($externalStatePath, @($sha, $repoSlug, $extClassification, $extReason, $extRecordedRaw, $extFingerprint, [DateTime]::UtcNow.ToString('o'))) } catch { }
            Write-ExternalBlockerContext -Classification $extClassification -Reason $extReason -Sha7 $sha7 -RepoSlug $repoSlug -EventName $eventName
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
        # Record the block so THIS hook's own re-entry is recognised; another
        # gate's block must not mute it, and its own must not repeat.
        Set-StopBlockMarker -HookInput $hookInput -HookName 'Ci-Status-Check'
        exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason ('CI CHECK: pushed commit ' + $sha7 + ' still has failed checks. Detailed failure guidance was recently reported; completion remains blocked until a replacement commit is pushed or the failure is reported as an external/manual blocker.')).ExitCode
    }
    if ($stateOutcome -eq 'pending' -and $ageMinutes -lt $pendingCooldown) {
        # Record the block so THIS hook's own re-entry is recognised; another
        # gate's block must not mute it, and its own must not repeat.
        Set-StopBlockMarker -HookInput $hookInput -HookName 'Ci-Status-Check'
        exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason ('CI CHECK: pushed commit ' + $sha7 + ' is still awaiting terminal checks. Detailed status was recently reported; completion remains blocked.')).ExitCode
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
    # E-09 wording: a non-completed status covers queued AND in_progress (and any
    # other pre-terminal state) - none of them is ever green.
    Write-Block -Outcome 'pending' -Reason ('CI CHECK: pushed commit ' + $sha7 + ' on ' + $branch + ' (' + $repoSlug + ') has ' + $snapshot.PendingRuns.Count + ' check run(s) not finished yet (queued or still in progress): ' + ($snapshot.PendingRuns -join '; ') + '. The work is not verifiably complete yet - wait for them and verify this exact commit (gh run list --commit ' + $sha + ').')
}

# ---- account billing / payment block: proven external, auto-recorded ----
# Pending is already handled above (it exits), so here billing is the whole
# story only when there is no genuine failure and no abnormal infra ending
# alongside it. GitHub's own annotation proved this is a billing/payment block,
# not a code failure - auto-record it (SHA+repo bound, identical file shape to
# -ReportExternalBlocker) so every later Stop re-verifies on the throttle and
# retires it the moment CI turns green (or re-blocks if a genuine failure
# appears), then surface the non-blocking "CI NOT VERIFIED GREEN" notice. Never
# claims CI passed; no commit can clear a billing block.
if ($snapshot.BillingRuns.Count -gt 0 -and $snapshot.FailedRuns.Count -eq 0 -and $snapshot.InfraRuns.Count -eq 0) {
    $billingReason = 'GitHub Actions did not start: an account billing/payment or spending-limit block, per GitHub''s own check-run annotation ("recent account payments have failed or your spending limit needs to be increased"). No job executed, so this is not a code/test failure and no replacement commit can clear it - resolve billing in the repository''s GitHub settings, then rerun the workflow.'
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $nowIso = [DateTime]::UtcNow.ToString('o')
        [System.IO.File]::WriteAllLines($externalStatePath, @($sha, $repoSlug, 'account-billing', $billingReason, $nowIso, $snapshot.Fingerprint, $nowIso))
    }
    catch { }    # local-only convenience; the notice below still fires either way
    Write-ExternalBlockerContext -Classification 'account-billing' -Reason $billingReason -Sha7 $sha7 -RepoSlug $repoSlug -EventName $eventName
}

if ($snapshot.FailedRuns.Count -gt 0 -or $snapshot.InfraRuns.Count -gt 0) {
    $parts = @()
    if ($snapshot.FailedRuns.Count -gt 0) {
        $parts += ('FAILED: ' + ($snapshot.FailedRuns -join '; ') + '. Inspect the actual failed job and step (gh run view <id> --log-failed), reproduce locally when practical, make the smallest correct fix, run the relevant validation, then commit, push, and verify the replacement commit. Do not weaken or skip tests, ignore exit codes, or add continue-on-error to force green.')
    }
    if ($snapshot.InfraRuns.Count -gt 0) {
        $parts += ('Abnormal endings: ' + ($snapshot.InfraRuns -join '; ') + '. These are often infrastructure, permission, or flaky failures - report them accurately (not as code failures); one confirming rerun is acceptable (gh run rerun <id>), and repeated flakiness must be investigated. If genuinely external, it may be recorded: -ReportExternalBlocker.')
    }
    # E-09: completion gates (including a ::deep-debug finish) apply to the EXACT
    # final pushed SHA - any later commit, e.g. an accepted post-Ponytail
    # simplification, restarts this gate on its own SHA.
    $parts += 'Completion applies to the EXACT final pushed SHA: any later commit (including accepted post-Ponytail changes in a ::deep-debug workflow) must be pushed and re-verified on its own SHA.'
    Write-Block -Outcome 'failed' -Reason ('CI CHECK for pushed commit ' + $sha7 + ' on ' + $branch + ' (' + $repoSlug + '): ' + ($parts -join ' '))
}

# All runs for this exact commit completed successfully.
Save-State -Outcome 'verified'
exit 0
