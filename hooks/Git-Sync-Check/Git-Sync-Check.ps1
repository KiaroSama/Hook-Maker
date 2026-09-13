# GitSyncCheck - tells the agent when the current project (and, at task-end,
# any task-scoped branch/worktree it created or changed) is out of sync with
# its git remote / intended destination branch. Silent for in-sync and
# non-git projects.
#
# Events:
# - SessionStart: injects the current-repo status as additional context (as
#   before, non-blocking) AND silently captures a local, SANITIZED baseline
#   snapshot of this repo's worktrees and local branches (paths/names + HEAD
#   shas + a short per-worktree DIRTY FINGERPRINT of status, index blob ids and
#   dirty-file bytes - only hashes are persisted, never contents). One baseline per repo
#   per session (keyed by session_id, stored once): a resumed session keeps
#   its original "before this task" baseline; a new session overwrites it.
#   Never modifies the repository at session start.
# - UserPromptSubmit: unchanged non-blocking repo-context behavior.
# - Stop / SubagentStop: this is a DETECTION AND INSTRUCTION boundary, not an
#   executor - the hook itself never runs `git add`/`commit`/`pull`/`push`/
#   `merge`/`rebase`/`branch -d`/`worktree remove`. It instead gives the agent
#   a MANDATORY, operational instruction: reconcile the repository (and any
#   task-scoped branch/worktree) now rather than waiting for a separate user
#   request, unless doing so is unsafe (failing tests, incomplete work,
#   unrelated pre-existing changes, secrets/protected files, a merge/rebase/
#   conflict state, a required history rewrite, forbidding project rules, or
#   an authentication/permission/branch-protection block) - in which case the
#   agent preserves the work and reports the exact reason instead of claiming
#   synchronization succeeded. SubagentStop inspects the same task-scoped
#   state (a subagent's produced work is exactly what changed since the
#   baseline); Stop is the final task-scoped reconciliation gate.
#
# Task-scoped branches/worktrees (Stop/SubagentStop only, needs a same-session
# baseline - silently skipped when none exists, e.g. SessionStart was never
# configured): the CURRENT `git worktree list --porcelain` + local branches
# (`git for-each-ref refs/heads`) are compared against the baseline.
#   - A worktree/branch that is BYTE-IDENTICAL to baseline (same path/name AND
#     same HEAD) existed UNCHANGED before this task -> advisory context only,
#     never a completion blocker. For a WORKTREE, path+HEAD alone are NOT
#     proof of "untouched": its current dirty fingerprint (a hash of `git
#     status and bounded dirty-file content) must also match the baseline one - a
#     differing fingerprint means its UNCOMMITTED contents changed during
#     this task, which is task-scoped and blocking. An UNKNOWN fingerprint
#     (status failed at capture or now, or a baseline written before the
#     fingerprint existed) is surfaced as advisory uncertainty - never
#     treated as "unchanged", and never a hard block by itself.
#   - A worktree/branch that is NEW or has ADVANCED since baseline is
#     task-scoped and BLOCKS completion when:
#       - its worktree has uncommitted/staged/untracked changes, or
#       - its tip commit is neither reachable from the intended destination
#         branch (the branch this repo was on at SessionStart, i.e. an
#         ancestry check via `git merge-base --is-ancestor`) NOR fully pushed
#         to a configured upstream (ahead=0) - i.e. local-only work at risk of
#         being lost. A branch that IS pushed to its own upstream but not yet
#         merged into the destination is NOT itself a blocker on that account
#         alone - this hook never infers that every remote branch must be
#         merged. (Known limitation: a squash-merged branch whose original
#         commits were never pushed can still show as unreconciled, since
#         ancestry can't see through a squash; report/handle manually.)
#   Locked/prunable worktrees are always reported (real, useful operational
#   metadata) but are never a blocker by themselves.
#   Bounded: at most 50 worktrees / 300 branches / 5 seconds are inspected per
#   run; a capped or unreadable scan is reported as an advisory note, never
#   silently treated as all-clear.
#
# OUTPUT: a real block (task-scoped reconciliation is required) -> a plain
# `{ decision: 'block', reason }` for BOTH clients - on Codex this forces
# continuation, which is exactly the intended effect of a genuine completion
# gate. A non-blocking Stop/SubagentStop advisory (e.g. only a locked/
# prunable worktree, or a capped scan, with nothing to actually block on) is
# CLIENT-AWARE and never `decision:block`: Claude Code gets
# `hookSpecificOutput.additionalContext`, Codex gets `systemMessage` (client
# detected via `$env:CLAUDE_PROJECT_DIR`, exported by Claude Code on every
# hook process, not by Codex - same signal Ci-Status-Check/Rules-Check/
# Secrets-Check/Test-Completion-Check use). Pre-task (SessionStart/
# UserPromptSubmit) output stays `additionalContext` on BOTH clients, as for
# every other pre-task hook in this repo.
#
# Cooldown/repeat behavior: a real git inspection runs on EVERY Stop/
# SubagentStop (never a blind time-only early exit before inspection). The
# output (block OR advisory) is gated by a FINGERPRINT of the actionable
# state (repo, branch, HEAD, upstream, ahead/behind counts, status paths+
# codes, the task-scoped worktree/branch findings, and per-worktree dirty-
# state hashes - never file contents/secret values) combined with the hook's
# `session_id`: a given fingerprint
# is reported at most ONCE per session - a changed fingerprint (state got
# worse, different files, a new commit, a new/changed task-scoped branch or
# worktree) or a NEW session is evaluated and reported again immediately; an
# already-reported, unchanged fingerprint within the same session stays
# silent so it can never loop. `stop_hook_active` remains the immediate-
# recursion guard.
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
# Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
# for ANY gate's block, and exiting on it alone let one block silence the
# other twelve on the same Stop.
if ($isStopEvent -and (Test-StopStandDown -HookInput $hookInput -HookName 'Git-Sync-Check')) {
    exit 0
}

$sessionId = [string](Get-Field $hookInput 'session_id')

# Bounds for the task-scoped worktree/branch scan (never blindly unbounded).
$MaxWorktreesToInspect = 50
$MaxBranchesToInspect = 300
$MaxScanSeconds = 5

# ---- git inspection (always runs - no time-only early exit before this) ----
function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs, [string]$RepoPath = $cwd, [int]$TimeoutSeconds = 20)

    $output = Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $RepoPath) + $GitArgs) -TimeoutSeconds $TimeoutSeconds
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); ExitCode = $LASTEXITCODE; Output = @($output) }
}

# Repo-wide identity used to key baseline/gate state so it is shared correctly
# across every worktree of the SAME repository (worktrees share one common
# git dir; `-C <any-worktree> rev-parse --git-common-dir` resolves to it).
# Falls back to the given path itself on any failure (still stable, just
# scoped to that one directory instead of the whole repo).
function Get-RepoCommonDir {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    $result = Invoke-Git @('rev-parse', '--git-common-dir') -RepoPath $RepoPath
    if (-not $result.Ok -or $result.Output.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$result.Output[0])) {
        return $RepoPath
    }
    $raw = [string]$result.Output[0]
    try {
        $combined = if ([System.IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $RepoPath $raw }
        return Normalize-Path $combined
    }
    catch {
        return $RepoPath
    }
}

# Parses `git worktree list --porcelain` (records separated by a blank line;
# each line is "key" or "key value") into Path/Head/Branch/Detached/Bare/
# Locked+LockReason/Prunable+PrunableReason objects.
function Get-WorktreeList {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    $raw = Invoke-Git @('worktree', 'list', '--porcelain') -RepoPath $RepoPath
    $items = New-Object System.Collections.Generic.List[object]
    if (-not $raw.Ok) {
        return @($items.ToArray())
    }
    $current = $null
    foreach ($line in @($raw.Output)) {
        $text = [string]$line
        if ($text -eq '') {
            if ($null -ne $current) { [void]$items.Add([pscustomobject]$current) }
            $current = $null
            continue
        }
        # Invoke-QuietCommand drops empty lines, so a header must also end the
        # preceding record. Otherwise every worktree overwrites the first one.
        if ($text.StartsWith('worktree ') -and $null -ne $current) {
            [void]$items.Add([pscustomobject]$current)
            $current = $null
        }
        if ($null -eq $current) {
            $current = [ordered]@{
                Path = ''; Head = ''; Branch = ''; Detached = $false; Bare = $false
                Locked = $false; LockReason = ''; Prunable = $false; PrunableReason = ''
            }
        }
        $sp = $text.IndexOf(' ')
        $key = if ($sp -ge 0) { $text.Substring(0, $sp) } else { $text }
        $val = if ($sp -ge 0) { $text.Substring($sp + 1) } else { '' }
        switch ($key) {
            'worktree' { $current.Path = $val }
            'HEAD' { $current.Head = $val }
            'branch' { $current.Branch = ($val -replace '^refs/heads/', '') }
            'detached' { $current.Detached = $true }
            'bare' { $current.Bare = $true }
            'locked' { $current.Locked = $true; $current.LockReason = $val }
            'prunable' { $current.Prunable = $true; $current.PrunableReason = $val }
        }
    }
    if ($null -ne $current) { [void]$items.Add([pscustomobject]$current) }
    return @($items.ToArray())
}

# Local branches with their upstream tracking state, via one bounded plumbing
# call (tab-separated, never a per-branch subprocess).
function Get-LocalBranchList {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    $result = Invoke-Git @('for-each-ref', 'refs/heads', '--format=%(refname:short)%09%(objectname)%09%(upstream:short)%09%(upstream:track)') -RepoPath $RepoPath
    $items = New-Object System.Collections.Generic.List[object]
    if (-not $result.Ok) {
        return @($items.ToArray())
    }
    foreach ($line in @($result.Output)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $parts = $text -split "`t"
        if ($parts.Count -lt 2) { continue }
        $upstream = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        $track = if ($parts.Count -ge 4) { $parts[3] } else { '' }
        [void]$items.Add([pscustomobject]@{ Name = $parts[0]; Head = $parts[1]; Upstream = $upstream; IsAheadOfUpstream = ($track -match 'ahead') })
    }
    return @($items.ToArray())
}

# Status alone cannot detect a second edit to an already-dirty path. Porcelain
# v2 supplies index blob ids; bounded file reads cover working/untracked bytes.
# Persist only the final digest. Failure, links, submodules, conflicts or any
# exceeded bound return UNKNOWN, never a partial digest that looks unchanged.
function Get-WorktreeDirtyFingerprint {
    param([Parameter(Mandatory = $true)][string]$WorktreePath)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Git @('status', '--porcelain=v2', '-z', '--untracked-files=all') -RepoPath $WorktreePath -TimeoutSeconds 5
    if (-not $result.Ok -or $timer.ElapsedMilliseconds -ge 5000) { return '' }
    $records = ([string]($result.Output -join "`n")).Split([char]0)
    $partsToHash = New-Object System.Collections.Generic.List[string]
    $totalBytes = 0L
    $fileCount = 0
    $root = Normalize-Path $WorktreePath
    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        if ($record -eq '') { continue }
        if (++$fileCount -gt 500 -or $timer.ElapsedMilliseconds -ge 5000) { return '' }
        $xy = ''
        if ($record.StartsWith('? ')) { $relative = $record.Substring(2) }
        elseif ($record.StartsWith('1 ') -or $record.StartsWith('2 ')) {
            $fieldCount = if ($record.StartsWith('2 ')) { 10 } else { 9 }
            $fields = $record -split ' ', $fieldCount
            if ($fields.Count -ne $fieldCount -or $fields[2] -ne 'N...') { return '' }
            $xy = $fields[1]
            $relative = $fields[$fieldCount - 1]
            if ($fieldCount -eq 10) {
                if (++$i -ge $records.Count -or $records[$i] -eq '') { return '' }
                $record += "`0from:" + $records[$i]
            }
        }
        else { return '' }
        $stream = $null
        $hasher = $null
        try {
            $full = Normalize-Path (Join-Path $root $relative)
            if (-not (Test-PathInside -Candidate $full -Parent $root)) { return '' }
            if (-not [System.IO.File]::Exists($full)) {
                if ($xy.Contains('D')) { [void]$partsToHash.Add($record + "`0deleted"); continue }
                return ''
            }
            for ($ancestor = $full; $ancestor -ne $root; $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)) {
                if (([System.IO.File]::GetAttributes($ancestor) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return '' }
            }
            $stream = New-Object System.IO.FileStream($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read, 65536, [System.IO.FileOptions]::Asynchronous)
            if ($totalBytes + $stream.Length -gt 16MB) { return '' }
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            $buffer = New-Object byte[] 65536
            while ($true) {
                $remaining = [int][Math]::Max(0, 5000 - $timer.ElapsedMilliseconds)
                if ($remaining -eq 0) { return '' }
                $read = $stream.ReadAsync($buffer, 0, $buffer.Length)
                if (-not $read.Wait($remaining)) { return '' }
                $count = $read.GetAwaiter().GetResult()
                if ($count -eq 0) { break }
                $totalBytes += $count
                if ($totalBytes -gt 16MB) { return '' }
                [void]$hasher.TransformBlock($buffer, 0, $count, $buffer, 0)
            }
            [void]$hasher.TransformFinalBlock([byte[]]@(), 0, 0)
            [void]$partsToHash.Add($record + "`0" + [BitConverter]::ToString($hasher.Hash).Replace('-', ''))
        }
        catch { return '' }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $hasher) { $hasher.Dispose() }
        }
    }
    # Git leaves porcelain-v2 record order unspecified. Keep each digest bound
    # to its path/status while sorting, so swapped file contents still differ.
    $hashRecords = $partsToHash.ToArray()
    [System.Array]::Sort($hashRecords, [System.StringComparer]::Ordinal)
    return ('v2:' + (Get-ShortHash ($hashRecords -join "`0")))
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

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$repoCommonDir = Get-RepoCommonDir $cwd
$baselinePath = Join-Path $stateDir ('GitSyncCheck-baseline-' + (Get-ShortHash $repoCommonDir.ToLowerInvariant()) + '.json')

# ---- SessionStart: capture (once per session) a local sanitized baseline ----
if ($eventName -eq 'SessionStart') {
    $existingBaseline = $null
    try { $existingBaseline = Read-JsonFile $baselinePath } catch { $existingBaseline = $null }
    $haveCurrentSessionBaseline = ($null -ne $existingBaseline) -and ([string](Get-Field $existingBaseline 'sessionId') -eq $sessionId)
    if (-not $haveCurrentSessionBaseline) {
        $primaryBranchResult = Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')
        $primaryBranch = ''
        if ($primaryBranchResult.Ok -and $primaryBranchResult.Output.Count -gt 0 -and [string]$primaryBranchResult.Output[0] -ne 'HEAD') {
            $primaryBranch = [string]$primaryBranchResult.Output[0]
        }
        # Each worktree also gets a DIRTY FINGERPRINT (see the helper above):
        # HEAD alone cannot prove a pre-existing worktree stayed untouched -
        # its UNCOMMITTED files may be modified during the task without the
        # HEAD ever moving. Bounded by the same scan budget as the Stop-side
        # inspection: past the time cap (or for a bare entry, which has no
        # working tree) the fingerprint is stored as UNKNOWN, never guessed.
        $baselineTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $baselineWorktrees = @(Get-WorktreeList $cwd | Select-Object -First $MaxWorktreesToInspect | ForEach-Object {
                $dirty = if ($_.Bare -or $baselineTimer.Elapsed.TotalSeconds -ge $MaxScanSeconds) { '' } else { Get-WorktreeDirtyFingerprint $_.Path }
                [pscustomobject]@{ path = $_.Path; head = $_.Head; dirty = $dirty }
            })
        $baselineBranches = @(Get-LocalBranchList $cwd | Select-Object -First $MaxBranchesToInspect | ForEach-Object { [pscustomobject]@{ name = $_.Name; head = $_.Head } })
        $baseline = [pscustomobject]@{
            sessionId     = $sessionId
            primaryBranch = $primaryBranch
            worktrees     = $baselineWorktrees
            branches      = $baselineBranches
            capturedUtc   = [DateTime]::UtcNow.ToString('o')
        }
        try { Write-JsonFileAtomic -Value $baseline -Path $baselinePath } catch { }
    }
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
        # E-08 wording: porcelain covers all three dirty categories - name them
        # so the report reads unambiguously as staged AND unstaged AND untracked.
        [void]$findings.Add('There are ' + $statusLines.Count + ' uncommitted change(s) in the working tree (staged, unstaged, and/or untracked).')
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
            # E-08 wording: ahead/behind IS a local/remote final-SHA mismatch -
            # say so explicitly for the completion report.
            if ($behind -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $behind + ' commit(s) BEHIND ' + $upstreamName + ' (pull needed; the local and remote final SHAs do not match).')
            }
            if ($ahead -gt 0) {
                [void]$findings.Add('Branch ' + $branchName + ' is ' + $ahead + ' commit(s) AHEAD of ' + $upstreamName + ' (push needed; unpushed commits - the local and remote final SHAs do not match).')
            }
        }
    }
}
elseif ($branchName -ne '' -and $branchName -ne 'HEAD') {
    [void]$findings.Add('Branch ' + $branchName + ' has no upstream branch configured (never pushed?).')
}

if (-not $isStopEvent) {
    if ($findings.Count -eq 0) {
        exit 0
    }
    $message = 'GIT SYNC STATUS (' + $cwd + "):`n- " + ($findings.ToArray() -join "`n- ")
    $message += "`nConsider this pre-existing sync state before making further changes; this check does not modify the repository."
    $null = Write-HookResult -EventName $eventName -Kind 'context' -Message $message
    exit 0
}

# ---- Stop / SubagentStop: task-scoped worktree/branch inspection ----
# Needs a same-session baseline; silently skipped (no findings, no crash) when
# none exists - e.g. SessionStart was never configured for this project.
$blockingExtra = New-Object System.Collections.Generic.List[string]
$advisoryExtra = New-Object System.Collections.Generic.List[string]
# Extra non-message state folded into the anti-loop fingerprint: the
# pre-existing-worktree block message below is state-independent text, so the
# actual dirty hash must join the fingerprint for a FURTHER change in the same
# worktree to re-evaluate immediately instead of being silenced as "already
# reported".
$fingerprintExtra = New-Object System.Collections.Generic.List[string]
$destinationBranch = ''

$baseline = $null
try { $baseline = Read-JsonFile $baselinePath } catch { $baseline = $null }
$haveBaseline = ($null -ne $baseline) -and ([string](Get-Field $baseline 'sessionId') -eq $sessionId)

if ($haveBaseline) {
    $destinationBranch = [string](Get-Field $baseline 'primaryBranch')

    $baselineWorktreeHeads = @{}
    $baselineWorktreeDirty = @{}
    foreach ($w in @(Get-Field $baseline 'worktrees')) {
        $p = [string](Get-Field $w 'path')
        if ($p -ne '') {
            $normP = Normalize-Path $p
            $baselineWorktreeHeads[$normP] = [string](Get-Field $w 'head')
            # A baseline written before the dirty-fingerprint field existed
            # has no 'dirty' property; [string]$null coerces to '' = UNKNOWN,
            # which is exactly the honest classification for it.
            $baselineWorktreeDirty[$normP] = [string](Get-Field $w 'dirty')
        }
    }
    $baselineBranchHeads = @{}
    foreach ($b in @(Get-Field $baseline 'branches')) {
        $n = [string](Get-Field $b 'name')
        if ($n -ne '') { $baselineBranchHeads[$n] = [string](Get-Field $b 'head') }
    }

    $scanTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $scanIncomplete = $false
    $normCwd = Normalize-Path $cwd

    # -- worktrees: dirty/staged/untracked state + locked/prunable metadata --
    $inspectedWorktrees = 0
    foreach ($wt in (Get-WorktreeList $cwd)) {
        if ($wt.Path -eq '') { continue }
        $normPath = Normalize-Path $wt.Path
        if ($normPath -eq $normCwd) { continue }   # cwd's own state is already covered above

        if ($wt.Locked) {
            $reasonSuffix = if ($wt.LockReason -ne '') { ' (' + $wt.LockReason + ')' } else { '' }
            [void]$advisoryExtra.Add('Worktree at ' + $wt.Path + ' is locked' + $reasonSuffix + '.')
        }
        if ($wt.Prunable) {
            $reasonSuffix = if ($wt.PrunableReason -ne '') { ' (' + $wt.PrunableReason + ')' } else { '' }
            [void]$advisoryExtra.Add('Worktree at ' + $wt.Path + ' is prunable' + $reasonSuffix + '.')
        }

        if ($inspectedWorktrees -ge $MaxWorktreesToInspect -or $scanTimer.Elapsed.TotalSeconds -ge $MaxScanSeconds) {
            $scanIncomplete = $true
            continue
        }
        $isNew = -not $baselineWorktreeHeads.ContainsKey($normPath)
        $isChanged = (-not $isNew) -and ($baselineWorktreeHeads[$normPath] -ne $wt.Head)
        if (-not (Test-Path -LiteralPath $wt.Path -PathType Container)) { continue }   # gone from disk; prunable note above already covers it

        if (-not ($isNew -or $isChanged)) {
            # Pre-existing worktree whose HEAD never moved. That alone cannot
            # prove "untouched": its UNCOMMITTED contents may still have been
            # modified during this task. Compare the CURRENT dirty fingerprint
            # against the baseline one before treating it as advisory-only.
            if ($wt.Bare) { continue }   # a bare entry has no working tree - nothing uncommitted can exist
            $inspectedWorktrees++
            $baselineDirty = [string]$baselineWorktreeDirty[$normPath]
            $currentDirty = Get-WorktreeDirtyFingerprint $wt.Path
            if ($baselineDirty -notmatch '^v2:[a-f0-9]+$' -or $currentDirty -eq '') {
                # UNKNOWN on either side (status failed at capture or now, or
                # a baseline written before the fingerprint field existed):
                # never claim unchanged, and never hard-block on unknown alone.
                [void]$advisoryExtra.Add('The uncommitted-change state of pre-existing worktree ' + $wt.Path + ' could not be compared against its pre-task baseline; its dirty-state evidence is ambiguous/UNKNOWN and it cannot be confirmed unchanged (never treated as an all-clear).')
                continue
            }
            if ($currentDirty -eq $baselineDirty) { continue }   # genuinely unchanged (HEAD AND dirty state) -> advisory context only
            $branchLabel = if ($wt.Detached) { 'detached' } else { $wt.Branch }
            [void]$blockingExtra.Add('Uncommitted changes inside pre-existing worktree ' + $wt.Path + ' (branch: ' + $branchLabel + ') appeared or changed during this task.')
            [void]$fingerprintExtra.Add('wt-dirty:' + $normPath.ToLowerInvariant() + '=' + $currentDirty)
            continue
        }

        $inspectedWorktrees++
        $wtStatus = Invoke-Git @('status', '--porcelain') -RepoPath $wt.Path
        if ($wtStatus.Ok) {
            $dirtyCount = @($wtStatus.Output | Where-Object { $_ }).Count
            if ($dirtyCount -gt 0) {
                $label = if ($isNew) { 'created' } else { 'changed' }
                $branchLabel = if ($wt.Detached) { 'detached' } else { $wt.Branch }
                [void]$blockingExtra.Add('Task-' + $label + ' worktree at ' + $wt.Path + ' (branch: ' + $branchLabel + ') has ' + $dirtyCount + ' uncommitted change(s).')
            }
        }
    }

    # -- branches: reachability from destination + upstream push state --
    $destinationTip = ''
    if ($destinationBranch -ne '') {
        # Parentheses required (see the identical rev-list note above): the
        # array comma binds tighter than +, so an unparenthesized concat would
        # split into two separate git arguments (git then reports a plain
        # "refs/heads/" is unresolvable instead of resolving the real ref).
        $destResult = Invoke-Git @('rev-parse', ('refs/heads/' + $destinationBranch))
        if ($destResult.Ok -and $destResult.Output.Count -gt 0) { $destinationTip = [string]$destResult.Output[0] }
    }
    $inspectedBranches = 0
    foreach ($b in (Get-LocalBranchList $cwd)) {
        if ($inspectedBranches -ge $MaxBranchesToInspect -or $scanTimer.Elapsed.TotalSeconds -ge $MaxScanSeconds) {
            $scanIncomplete = $true
            break
        }
        $inspectedBranches++
        $isNew = -not $baselineBranchHeads.ContainsKey($b.Name)
        $isChanged = (-not $isNew) -and ($baselineBranchHeads[$b.Name] -ne $b.Head)
        if (-not ($isNew -or $isChanged)) { continue }   # pre-existing + unchanged -> advisory context only
        if ($destinationTip -eq '') { continue }          # destination unknown -> never block on unproven state

        $pushedClean = ($b.Upstream -ne '') -and (-not $b.IsAheadOfUpstream)
        if ($pushedClean) { continue }   # "Do NOT infer every remote branch must be merged": pushed is enough on its own

        $mb = Invoke-Git @('merge-base', '--is-ancestor', $b.Head, $destinationTip)
        if ($mb.Ok) { continue }          # reachable from destination -> reconciled
        if ($mb.ExitCode -ne 1) { continue }   # unknown/error (e.g. unrelated history) -> never block on unproven state

        $label = if ($isNew) { 'created' } else { 'advanced' }
        [void]$blockingExtra.Add('Task-' + $label + ' branch ' + $b.Name + ' has commits not reconciled into ' + $destinationBranch + ' and is not fully pushed to an upstream (local-only work at risk of being lost).')
    }

    if ($scanIncomplete) {
        [void]$advisoryExtra.Add('The worktree/branch scan was capped by its limits or time bound; some entries may not have been inspected.')
    }
}

$blockingFindings = @($findings.ToArray()) + @($blockingExtra.ToArray())
$advisoryFindings = @($advisoryExtra.ToArray())

if ($blockingFindings.Count -eq 0 -and $advisoryFindings.Count -eq 0) {
    exit 0
}

# ---- Stop: fingerprint + session gate (never a blind time-only exit) ----
# Non-secret, deterministic identity of the actionable state: repo path,
# branch, exact HEAD, upstream, ahead/behind counts, the sorted status lines
# (paths + XY codes only), and the task-scoped worktree/branch findings -
# never file contents or secret values.
$fingerprintSource = ($cwd.ToLowerInvariant() + '|' + $branchName + '|' + $headSha + '|' + $upstreamName + '|' +
    $ahead + '|' + $behind + '|' + ($statusLines -join "`n") + '|' +
    ($blockingExtra.ToArray() -join "`n") + '|' + ($advisoryExtra.ToArray() -join "`n") + '|' +
    ($fingerprintExtra.ToArray() -join "`n"))
$fingerprint = Get-ShortHash $fingerprintSource

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
    # Same actionable state, same session: already reported once - do not
    # loop. A changed fingerprint (state got worse/better, or a task-scoped
    # branch/worktree changed) or a new session is evaluated and reported
    # again immediately (see the check above).
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllLines($statePath, @($fingerprint, $sessionId, [DateTime]::UtcNow.ToString('o')))

$messageParts = New-Object System.Collections.Generic.List[string]
if ($blockingFindings.Count -gt 0) {
    [void]$messageParts.Add('- ' + ($blockingFindings -join "`n- "))
}
if ($advisoryFindings.Count -gt 0) {
    [void]$messageParts.Add("Advisory (non-blocking):`n- " + ($advisoryFindings -join "`n- "))
}
$message = 'GIT SYNC STATUS (' + $cwd + "):`n" + ($messageParts.ToArray() -join "`n")

if ($blockingFindings.Count -eq 0) {
    # Advisory-only Stop/SubagentStop output (e.g. only a locked/prunable
    # worktree, or a capped scan) - CLIENT-AWARE, never `decision:block` (see
    # the header OUTPUT note): Codex would otherwise be forced into a
    # pointless new prompt for something that was never a real gate.
    $null = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $message
    exit 0
}

$operationalInstruction = "`n`nBefore finishing, inspect and reconcile this repository state instead of waiting for another user request. Work produced by a subagent during this task is task-scoped in exactly the same way: reconcile it or report it explicitly - never leave unreconciled subagent work behind. If the current task's verified changes are ready and normal repository authorization permits: stage only those changes, commit with a neutral message, and push the current branch now. If the branch is clean and only behind with a safe fast-forward available, a fast-forward-only pull (git pull --ff-only) is acceptable after inspection; if it is dirty and behind or diverged, inspect first and do not blindly pull or merge. If there is no upstream, only create/set one when the branch is meant to be published and authorization permits. Never commit unrelated, unverified, secret, or protected files, and never force-push or rewrite history without explicit authorization. If synchronization is unsafe or impossible (failing tests, incomplete work, unrelated pre-existing changes, a merge/rebase/conflict state, or a permission/authentication/branch-protection block), preserve the work and report the exact reason instead of claiming the task is fully synchronized."
if ($blockingExtra.Count -gt 0) {
    $destinationWording = if ($destinationBranch -ne '') { $destinationBranch } else { 'the intended destination branch' }
    $operationalInstruction += "`n`nAlso reconcile every task-created or task-changed branch and worktree reported above before finishing: merge or otherwise incorporate each into " + $destinationWording + " when that is its purpose, push any that are meant to be shared (a branch that is pushed but not yet merged into the destination is acceptable on its own and is not itself a blocker), and remove a worktree with 'git worktree remove' only once its purpose is complete - never one that still holds unreconciled or uncommitted work. Never force-push or rewrite history without explicit authorization. If reconciling a branch or worktree is unsafe or impossible, preserve it and report the exact reason instead of claiming it is resolved."
}
$reason = $message + $operationalInstruction
# Record the block so THIS hook's own re-entry is recognised; another
# gate's block must not mute it, and its own must not repeat.
$emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Git-Sync-Check' -EventName $eventName -Reason $reason
exit $emit.ExitCode
