# GitSyncCheck - tells the agent when the current project is out of sync with
# its git remote (GitHub etc.): uncommitted changes, unpushed/unpulled commits,
# or a branch without an upstream. Silent for in-sync and non-git projects.
#
# Events:
# - SessionStart / UserPromptSubmit: injects the status as additional context
#   (non-blocking) so any pre-existing sync state is considered before making
#   further changes. Never modifies the repository at session start.
# - Stop / SubagentStop: this is a DETECTION AND INSTRUCTION boundary, not an
#   executor - the hook itself never runs `git add`/`commit`/`pull`/`push`. It
#   instead gives the agent a MANDATORY, operational instruction: reconcile the
#   repository now (stage only this task's verified changes, commit with a
#   neutral message, and push) rather than waiting for a separate user request,
#   unless doing so is unsafe (failing tests, incomplete work, unrelated
#   pre-existing changes, secrets/protected files, a merge/rebase/conflict
#   state, a required history rewrite, forbidding project rules, or an
#   authentication/permission/branch-protection block) - in which case the
#   agent preserves the work and reports the exact reason instead of claiming
#   synchronization succeeded.
#
# Cooldown/repeat behavior: a real git inspection runs on EVERY Stop (never a
# blind time-only early exit before inspection). The block is gated by a
# FINGERPRINT of the actionable state (repo, branch, HEAD, upstream, ahead/
# behind counts, and status paths+codes - never file contents/secret values)
# combined with the hook's `session_id`: a given fingerprint is instructed
# (blocked) at most ONCE per session - a changed fingerprint (state got worse,
# different files, a new commit) or a NEW session is evaluated and instructed
# again immediately; an already-instructed, unchanged fingerprint within the
# same session stays silent so it can never loop. `stop_hook_active` remains
# the immediate-recursion guard.
#
# Optional .env next to this script (copy .env.example):
#   (no cooldown-minutes setting - see fingerprint/session gating above)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) {
    $eventName = 'SessionStart'
}
$isStopEvent = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')

# Never loop: if this stop was already continued by a hook, stay silent.
if ($isStopEvent -and (Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}

$sessionId = [string](Get-Field $hookInput 'session_id')

# ---- git inspection (always runs - no time-only early exit before this) ----
function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    $output = Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $cwd) + $GitArgs)
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = @($output) }
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    exit 0
}
$inRepo = Invoke-Git @('rev-parse', '--is-inside-work-tree')
if (-not $inRepo.Ok -or [string]$inRepo.Output[0] -ne 'true') {
    exit 0
}
$remotes = Invoke-Git @('remote')
if (-not $remotes.Ok -or @($remotes.Output | Where-Object { $_ }).Count -eq 0) {
    exit 0
}

$findings = New-Object System.Collections.Generic.List[string]

# Refresh remote refs; when offline, fall back to the last fetched state.
$fetch = Invoke-Git @('fetch', '--quiet')
if (-not $fetch.Ok) {
    [void]$findings.Add('The remote could not be fetched (offline?); comparison uses the last known remote state.')
}

$status = Invoke-Git @('status', '--porcelain')
$statusLines = @()
if ($status.Ok) {
    $statusLines = @($status.Output | Where-Object { $_ } | Sort-Object)
    if ($statusLines.Count -gt 0) {
        [void]$findings.Add('There are ' + $statusLines.Count + ' uncommitted change(s) in the working tree.')
    }
}

$headSha = ''
$head = Invoke-Git @('rev-parse', 'HEAD')
if ($head.Ok) { $headSha = [string]$head.Output[0] }

$branch = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
$branchName = ''
if ($branch.Ok) {
    $branchName = [string]$branch.Output[0]
}
$upstreamName = ''
$ahead = 0
$behind = 0
$upstream = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
if ($upstream.Ok) {
    $upstreamName = [string]$upstream.Output[0]
    # Parentheses required: the array comma binds tighter than +, so an
    # unparenthesized concat would split into two separate git arguments.
    $counts = Invoke-Git @('rev-list', '--left-right', '--count', ($upstreamName + '...HEAD'))
    if ($counts.Ok -and $counts.Output.Count -gt 0) {
        $parts = ([string]$counts.Output[0]) -split '\s+'
        if ($parts.Count -ge 2) {
            $behind = [int]$parts[0]
            $ahead = [int]$parts[1]
            if ($behind -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $behind + ' commit(s) BEHIND ' + $upstreamName + ' (pull needed).')
            }
            if ($ahead -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $ahead + ' commit(s) AHEAD of ' + $upstreamName + ' (push needed).')
            }
        }
    }
}
elseif ($branchName -ne '' -and $branchName -ne 'HEAD') {
    [void]$findings.Add('Branch ' + $branchName + ' has no upstream branch configured (never pushed?).')
}

if ($findings.Count -eq 0) {
    exit 0
}

$message = 'GIT SYNC STATUS (' + $cwd + "):`n- " + ($findings.ToArray() -join "`n- ")

if (-not $isStopEvent) {
    $message += "`nConsider this pre-existing sync state before making further changes; this check does not modify the repository."
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---- Stop: fingerprint + session gate (never a blind time-only exit) ----
# Non-secret, deterministic identity of the actionable state: repo path,
# branch, exact HEAD, upstream, ahead/behind counts, and the sorted status
# lines (paths + XY codes only - never file contents or secret values).
$fingerprintSource = ($cwd.ToLowerInvariant() + '|' + $branchName + '|' + $headSha + '|' + $upstreamName + '|' +
    $ahead + '|' + $behind + '|' + ($statusLines -join "`n"))
$fingerprint = Get-ShortHash $fingerprintSource

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('GitSyncCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$alreadyInstructed = $false
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $stateLines = [System.IO.File]::ReadAllLines($statePath)
        if ($stateLines.Count -ge 2 -and $stateLines[0].Trim() -eq $fingerprint -and $stateLines[1].Trim() -eq $sessionId) {
            $alreadyInstructed = $true
        }
    }
    catch { }
}

if ($alreadyInstructed) {
    # Same actionable state, same session: already instructed once - do not
    # loop. A changed fingerprint (state got worse/better) or a new session
    # is evaluated and instructed again immediately (see the check above).
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllLines($statePath, @($fingerprint, $sessionId, [DateTime]::UtcNow.ToString('o')))

$operationalInstruction = "`n`nBefore finishing, inspect and reconcile this repository state instead of waiting for another user request. If the current task's verified changes are ready and normal repository authorization permits: stage only those changes, commit with a neutral message, and push the current branch now. If the branch is clean and only behind with a safe fast-forward available, a fast-forward-only pull (git pull --ff-only) is acceptable after inspection; if it is dirty and behind or diverged, inspect first and do not blindly pull or merge. If there is no upstream, only create/set one when the branch is meant to be published and authorization permits. Never commit unrelated, unverified, secret, or protected files, and never force-push or rewrite history without explicit authorization. If synchronization is unsafe or impossible (failing tests, incomplete work, unrelated pre-existing changes, a merge/rebase/conflict state, or a permission/authentication/branch-protection block), preserve the work and report the exact reason instead of claiming the task is fully synchronized."
$reason = $message + $operationalInstruction
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
