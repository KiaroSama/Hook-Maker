param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Git-Sync-Check\Git-Sync-Check.ps1'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-gitsynctest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# Isolated LOCALAPPDATA so state never touches the real user profile, and each
# repo fixture lives OUTSIDE it so the state directory itself never shows up
# as an untracked working-tree change.
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null
$ReposRoot = Join-Path $Work '_repos'
New-Item -ItemType Directory -Path $ReposRoot -Force | Out-Null

function New-Repo {
    param([string]$Name)
    $repo = Join-Path $ReposRoot $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    & git -C $repo config core.autocrlf false
    return $repo
}

function New-PushedRepo {
    param([string]$Name)
    $repo = New-Repo $Name
    $remote = Join-Path $ReposRoot ($Name + '-remote.git')
    & git init -q --bare $remote
    [System.IO.File]::WriteAllText((Join-Path $repo 'f.txt'), 'v1', (New-Object System.Text.UTF8Encoding $false))
    & git -C $repo add f.txt
    & git -C $repo commit -q -m init
    & git -C $repo remote add origin $remote
    & git -C $repo push -q -u origin main
    return $repo
}

function Fire {
    param([string]$Cwd, [string]$EventName = 'Stop', [string]$SessionId = 't', [switch]$StopHookActive, [string]$Exe = '', [switch]$Codex)
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    $file = if ([string]::IsNullOrWhiteSpace($Exe)) { (Get-Process -Id $PID).Path } else { $Exe }
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"'
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # -Environment MERGES with the inherited environment, so an ambient
        # CLAUDE_PROJECT_DIR from this very runner would otherwise leak into a
        # "Codex" case - clear it explicitly rather than omitting the key
        # (mirrors Test-TestCompletionCheck.ps1's Fire helper).
        $childEnv = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData }
        $childEnv['CLAUDE_PROJECT_DIR'] = if ($Codex) { '' } else { $Cwd }
        $startArgs.Environment = $childEnv
    }
    else {
        $env:LOCALAPPDATA = $FakeLocalAppData
        $env:CLAUDE_PROJECT_DIR = if ($Codex) { '' } else { $Cwd }
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

try {
    if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
        Write-Host 'Hook not found (expected RED before implementation).' -ForegroundColor Red
        exit 1
    }

    # =====================================================================
    Write-Host '--- clean/synchronized repository stays silent ---' -ForegroundColor Cyan
    $clean = New-PushedRepo 'clean'
    $r = Fire -Cwd $clean
    Check 'clean synchronized repository stays silent at Stop' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $clean -EventName 'SessionStart'
    Check 'clean synchronized repository stays silent at SessionStart' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- dirty task repository: mandatory operational Stop instruction ---' -ForegroundColor Cyan
    $dirty = New-PushedRepo 'dirty'
    [System.IO.File]::WriteAllText((Join-Path $dirty 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $r = Fire -Cwd $dirty
    Check 'dirty repository produces a blocking Stop instruction' ($r.Out -match '"decision":"block"' -and $r.Out -match 'uncommitted change') $r.Out
    Check 'the instruction is operational/mandatory, not discretionary' ($r.Out -match 'Before finishing, inspect and reconcile' -and $r.Out -match 'instead of waiting for another user request') $r.Out
    Check 'the message does NOT use the old discretionary "otherwise finish" wording' ($r.Out -notmatch 'otherwise finish' -and $r.Out -notmatch 'At your discretion') $r.Out
    Check 'the message forbids committing secrets/protected/unrelated files' ($r.Out -match 'Never commit unrelated, unverified, secret, or protected files') $r.Out

    # =====================================================================
    Write-Host '--- ahead repository: instructs a verified push, no second user request ---' -ForegroundColor Cyan
    $ahead = New-PushedRepo 'ahead'
    [System.IO.File]::WriteAllText((Join-Path $ahead 'f.txt'), 'v2', (New-Object System.Text.UTF8Encoding $false))
    & git -C $ahead add f.txt
    & git -C $ahead commit -q -m 'task change'
    $r = Fire -Cwd $ahead
    Check 'ahead repository is reported' ($r.Out -match 'AHEAD of origin/main') $r.Out
    Check 'ahead repository instructs pushing now without waiting for another request' ($r.Out -match 'push the current branch now' -and $r.Out -match 'instead of waiting for another user request') $r.Out

    # =====================================================================
    Write-Host '--- behind repository: safe inspection/fast-forward, not blind merge ---' -ForegroundColor Cyan
    $behindA = New-PushedRepo 'behind-a'
    # A second clone of the same remote falls behind once behind-a pushes again.
    # --branch main is required: a bare repo's symbolic HEAD can still point at
    # the git-wide default (often "master") even though "main" is the only real
    # branch, which otherwise leaves the clone on a nonexistent/empty branch.
    & git clone -q --branch main (Join-Path $ReposRoot 'behind-a-remote.git') (Join-Path $ReposRoot 'behind-b') 2>$null | Out-Null
    $behindB = Join-Path $ReposRoot 'behind-b'
    & git -C $behindB config user.email 't@t'; & git -C $behindB config user.name 't'; & git -C $behindB config core.autocrlf false
    [System.IO.File]::WriteAllText((Join-Path $behindA 'f.txt'), 'v2-from-a', (New-Object System.Text.UTF8Encoding $false))
    & git -C $behindA add f.txt
    & git -C $behindA commit -q -m 'advance origin'
    & git -C $behindA push -q origin main
    $r = Fire -Cwd $behindB
    Check 'behind repository is reported' ($r.Out -match 'BEHIND origin/main') $r.Out
    Check 'behind guidance recommends inspection/fast-forward, not a blind merge' ($r.Out -match 'fast-forward-only pull' -and $r.Out -match 'do not blindly pull or merge') $r.Out

    # =====================================================================
    Write-Host '--- missing upstream is reported ---' -ForegroundColor Cyan
    $noUpstream = New-Repo 'no-upstream'
    [System.IO.File]::WriteAllText((Join-Path $noUpstream 'f.txt'), 'v1', (New-Object System.Text.UTF8Encoding $false))
    & git -C $noUpstream add f.txt
    & git -C $noUpstream commit -q -m init
    # No remote at all -> silent (matches the pre-existing "requires a remote" behavior).
    $r = Fire -Cwd $noUpstream
    Check 'a repo with no remote at all stays silent (nothing to sync against)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $remoteOnly = Join-Path $ReposRoot 'no-upstream-remote.git'
    & git init -q --bare $remoteOnly
    & git -C $noUpstream remote add origin $remoteOnly
    $r = Fire -Cwd $noUpstream
    Check 'a branch with a remote configured but no upstream tracking is reported' ($r.Out -match 'has no upstream branch configured') $r.Out

    # =====================================================================
    Write-Host '--- the hook itself never invokes add/commit/pull/push ---' -ForegroundColor Cyan
    $hookText = [System.IO.File]::ReadAllText($Hook)
    Check 'the hook script never calls git add/commit/pull/push (detection+instruction only)' (
        $hookText -notmatch "'add'" -and $hookText -notmatch "'commit'" -and $hookText -notmatch "'pull'" -and $hookText -notmatch "'push'")
    $beforePush = New-PushedRepo 'no-write-check'
    [System.IO.File]::WriteAllText((Join-Path $beforePush 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $shaBefore = (& git -C $beforePush rev-parse HEAD)
    $remoteShaBefore = (& git -C $beforePush rev-parse origin/main)
    $r = Fire -Cwd $beforePush
    $shaAfter = (& git -C $beforePush rev-parse HEAD)
    $remoteShaAfter = (& git -C $beforePush rev-parse origin/main)
    $statusAfter = (& git -C $beforePush status --porcelain)
    Check 'running the hook does not change local HEAD, remote-tracking ref, or working-tree state' (
        $shaBefore -eq $shaAfter -and $remoteShaBefore -eq $remoteShaAfter -and @($statusAfter | Where-Object { $_ }).Count -gt 0)

    # =====================================================================
    Write-Host '--- unrelated/pre-existing changes are excluded from any blind staging instruction ---' -ForegroundColor Cyan
    # The instruction explicitly scopes staging to "this task's verified changes" and
    # explicitly excludes "unrelated, unverified" files - this is a wording assertion
    # since the hook itself never stages anything (the agent does). A distinct
    # session id is used because $dirty's default-session fingerprint was already
    # instructed above (by design: unchanged fingerprint + same session -> silent).
    $r = Fire -Cwd $dirty -SessionId 'wording-check'
    Check 'instruction explicitly scopes staging to this task''s ready/verified changes only' ($r.Out -match "stage only those changes" -and $r.Out -match 'unrelated pre-existing changes') $r.Out

    # =====================================================================
    Write-Host '--- cooldown/fingerprint/session gating ---' -ForegroundColor Cyan
    $gate = New-PushedRepo 'gate'
    [System.IO.File]::WriteAllText((Join-Path $gate 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $r1 = Fire -Cwd $gate -SessionId 'sessA'
    Check 'first Stop for an actionable fingerprint blocks' ($r1.Out -match '"decision":"block"') $r1.Out
    $r2 = Fire -Cwd $gate -SessionId 'sessA'
    Check 'unchanged fingerprint in the same session does not loop (silent, not blocked again)' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -Cwd $gate -SessionId 'sessB'
    Check 'a NEW session is evaluated and instructed again immediately, even with the same unchanged state' ($r3.Out -match '"decision":"block"') $r3.Out
    # Change the fingerprint (advance HEAD) within the SAME session that was already silenced.
    [System.IO.File]::WriteAllText((Join-Path $gate 'new.txt'), 'still uncommitted but different', (New-Object System.Text.UTF8Encoding $false))
    & git -C $gate add new.txt
    & git -C $gate commit -q -m 'commit the previously-uncommitted file'
    $r4 = Fire -Cwd $gate -SessionId 'sessB'
    Check 'cooldown does not skip inspection of a changed fingerprint (state changed -> re-evaluated)' ($r4.Out -match '"decision":"block"' -and $r4.Out -match 'AHEAD') $r4.Out

    # =====================================================================
    Write-Host '--- stop_hook_active still exits immediately ---' -ForegroundColor Cyan
    $recursion = New-PushedRepo 'recursion'
    [System.IO.File]::WriteAllText((Join-Path $recursion 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $r = Fire -Cwd $recursion -StopHookActive
    Check 'stop_hook_active short-circuits before any git inspection or state write' ($r.Exit -eq 0 -and $r.Out -eq '')

    # =====================================================================
    Write-Host '--- SessionStart/UserPromptSubmit context (non-blocking, non-destructive) ---' -ForegroundColor Cyan
    $ctx = New-PushedRepo 'context'
    [System.IO.File]::WriteAllText((Join-Path $ctx 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $r = Fire -Cwd $ctx -EventName 'SessionStart'
    Check 'SessionStart context is non-blocking additionalContext, not a block decision' ($r.Out -match '"additionalContext"' -and $r.Out -notmatch '"decision"') $r.Out
    Check 'SessionStart context tells the agent to consider pre-existing sync state first' ($r.Out -match 'Consider this pre-existing sync state before making further changes') $r.Out
    Check 'SessionStart never modifies the repository' ($r.Out -match 'this check does not modify the repository') $r.Out

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $ps5 = New-PushedRepo 'ps5'
    [System.IO.File]::WriteAllText((Join-Path $ps5 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $r = Fire -Cwd $ps5 -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1: dirty repo blocks with the mandatory instruction' ($r.Exit -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'instead of waiting for another user request') $r.Err

    Write-Host '--- Windows PowerShell 5.1: HM-08 task-scoped worktree path ---' -ForegroundColor Cyan
    $ps5wt = New-PushedRepo 'ps5-wt'
    $rBase = Fire -Cwd $ps5wt -EventName 'SessionStart' -SessionId 'ps5wt-sess' -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1: SessionStart baseline capture runs cleanly (silent, no error)' ($rBase.Exit -eq 0 -and $rBase.Out -eq '' -and $rBase.Err -eq '') $rBase.Err
    $ps5wtExtra = Join-Path $ReposRoot 'ps5-wt-extra'
    & git -C $ps5wt worktree add -q $ps5wtExtra -b ps5-wt-extra 2>$null
    [System.IO.File]::WriteAllText((Join-Path $ps5wtExtra 'new.txt'), 'uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $rWt = Fire -Cwd $ps5wt -EventName 'SubagentStop' -SessionId 'ps5wt-sess' -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1: a new task-scoped worktree with uncommitted changes blocks at SubagentStop' ($rWt.Exit -eq 0 -and $rWt.Out -match '"decision":"block"' -and $rWt.Out -match 'ps5-wt-extra') $rWt.Err

    # =====================================================================
    Write-Host '--- generated Git-sync template includes SessionStart+Stop+SubagentStop registration ---' -ForegroundColor Cyan
    $templatePath = Join-Path (Split-Path -Parent $Hook) '.env.example'
    $templateText = [System.IO.File]::ReadAllText($templatePath)
    Check 'the shipped .env.example registers SessionStart, Stop and SubagentStop' ($templateText -match 'EVENTS=SessionStart,Stop,SubagentStop')

    # =====================================================================
    # HM-08: task-scoped branches/worktrees, without becoming a destructive
    # Git executor. Each scenario below fires a real SessionStart first (to
    # capture the baseline) before creating/changing any worktree or branch,
    # so "task-scoped" classification is exercised for real, not assumed.
    # =====================================================================

    Write-Host '--- HM-08: pre-existing unrelated worktree stays advisory (never blocks) ---' -ForegroundColor Cyan
    $wtPre = New-PushedRepo 'wt-preexisting'
    $wtPreOther = Join-Path $ReposRoot 'wt-preexisting-other'
    & git -C $wtPre worktree add -q $wtPreOther -b wt-preexisting-other-branch 2>$null
    # Dirty BEFORE the baseline is captured, and left untouched afterward -
    # proves "existed unchanged before the task", not merely "nothing to see".
    [System.IO.File]::WriteAllText((Join-Path $wtPreOther 'pre.txt'), 'pre-existing dirt', (New-Object System.Text.UTF8Encoding $false))
    $rBaseline = Fire -Cwd $wtPre -EventName 'SessionStart' -SessionId 'wt-pre-sess'
    Check 'SessionStart baseline capture is silent (no output)' ($rBaseline.Exit -eq 0 -and $rBaseline.Out -eq '') $rBaseline.Out
    $r = Fire -Cwd $wtPre -SessionId 'wt-pre-sess'
    Check 'a pre-existing, unchanged worktree (even an already-dirty one) never blocks completion' ($r.Out -notmatch '"decision":"block"') $r.Out
    Check 'a pre-existing, unchanged worktree produces no output at all (main repo clean, nothing task-scoped)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- HM-08: new subagent worktree with uncommitted changes BLOCKS at SubagentStop ---' -ForegroundColor Cyan
    $wtSub = New-PushedRepo 'wt-subagent'
    Fire -Cwd $wtSub -EventName 'SessionStart' -SessionId 'wt-sub-sess' | Out-Null
    $wtSubNew = Join-Path $ReposRoot 'wt-subagent-feature'
    & git -C $wtSub worktree add -q $wtSubNew -b wt-subagent-feature 2>$null
    [System.IO.File]::WriteAllText((Join-Path $wtSubNew 'new.txt'), 'subagent work in progress', (New-Object System.Text.UTF8Encoding $false))
    $r = Fire -Cwd $wtSub -EventName 'SubagentStop' -SessionId 'wt-sub-sess'
    Check 'a new task-scoped worktree with uncommitted changes BLOCKS at SubagentStop' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block names the new worktree path and its uncommitted state' ($r.Out -match 'wt-subagent-feature' -and $r.Out -match 'uncommitted change') $r.Out

    # =====================================================================
    Write-Host '--- HM-08: new branch with commits unreachable from destination BLOCKS; reconciled+pushed clears ---' -ForegroundColor Cyan
    $wtBranch = New-PushedRepo 'wt-branch'
    Fire -Cwd $wtBranch -EventName 'SessionStart' -SessionId 'wt-branch-sess' | Out-Null
    $wtBranchNew = Join-Path $ReposRoot 'wt-branch-feature'
    & git -C $wtBranch worktree add -q $wtBranchNew -b wt-branch-feature 2>$null
    [System.IO.File]::WriteAllText((Join-Path $wtBranchNew 'feature.txt'), 'feature work', (New-Object System.Text.UTF8Encoding $false))
    & git -C $wtBranchNew add feature.txt
    & git -C $wtBranchNew commit -q -m 'feature commit, not pushed, not merged'
    $r3 = Fire -Cwd $wtBranch -SessionId 'wt-branch-sess'
    Check 'a new branch with commits unreachable from destination and no upstream BLOCKS' ($r3.Out -match '"decision":"block"') $r3.Out
    Check 'the block names the branch and says it is not reconciled into the destination' ($r3.Out -match 'wt-branch-feature' -and $r3.Out -match 'not reconciled into') $r3.Out
    Check 'the (clean, committed) worktree itself is not what is flagged - branch reconciliation is' ($r3.Out -notmatch 'uncommitted change') $r3.Out

    # Reconcile: merge into the destination branch locally and push both.
    & git -C $wtBranch merge -q wt-branch-feature -m 'merge feature'
    & git -C $wtBranch push -q origin main
    $r4 = Fire -Cwd $wtBranch -SessionId 'wt-branch-sess'
    Check 'once merged into the destination and pushed, the same branch no longer blocks (changed fingerprint re-evaluated immediately)' ($r4.Out -notmatch '"decision":"block"') $r4.Out

    # =====================================================================
    Write-Host '--- HM-08: locked/prunable worktree is reported (non-blocking, client-aware advisory) ---' -ForegroundColor Cyan
    # Two independent repos (each with its OWN baseline under its OWN session
    # id) rather than two Fire calls against one repo: the baseline/gate are
    # keyed by session id, and re-firing the SAME repo+session a second time
    # would just hit the "already reported this session" gate instead of
    # actually exercising the Codex output shape.
    $wtLockClaude = New-PushedRepo 'wt-locked-claude'
    Fire -Cwd $wtLockClaude -EventName 'SessionStart' -SessionId 'wt-lock-sess' | Out-Null
    $wtLockClaudeExtra = Join-Path $ReposRoot 'wt-locked-claude-extra'
    & git -C $wtLockClaude worktree add -q $wtLockClaudeExtra -b wt-locked-claude-extra 2>$null
    & git -C $wtLockClaude worktree lock $wtLockClaudeExtra --reason 'manual test lock' 2>$null
    $rClaude = Fire -Cwd $wtLockClaude -SessionId 'wt-lock-sess'
    Check 'a locked worktree with nothing else wrong does not block completion (advisory only)' ($rClaude.Out -notmatch '"decision":"block"') $rClaude.Out
    Check 'the locked worktree is reported with its lock reason' ($rClaude.Out -match 'locked' -and $rClaude.Out -match 'manual test lock') $rClaude.Out
    Check 'the Claude client gets additionalContext for the non-blocking advisory, not systemMessage' ($rClaude.Out -match '"additionalContext"' -and $rClaude.Out -notmatch '"systemMessage"') $rClaude.Out

    $wtLockCodex = New-PushedRepo 'wt-locked-codex'
    Fire -Cwd $wtLockCodex -EventName 'SessionStart' -SessionId 'wt-lock-sess' -Codex | Out-Null
    $wtLockCodexExtra = Join-Path $ReposRoot 'wt-locked-codex-extra'
    & git -C $wtLockCodex worktree add -q $wtLockCodexExtra -b wt-locked-codex-extra 2>$null
    & git -C $wtLockCodex worktree lock $wtLockCodexExtra --reason 'manual test lock' 2>$null
    $rCodex = Fire -Cwd $wtLockCodex -SessionId 'wt-lock-sess' -Codex
    Check 'the Codex client gets systemMessage for the identical non-blocking advisory, not additionalContext' ($rCodex.Out -match '"systemMessage"' -and $rCodex.Out -notmatch '"additionalContext"') $rCodex.Out

    # =====================================================================
    Write-Host '--- HM-08: the hook performs NO mutation anywhere in the repo (main + worktrees) ---' -ForegroundColor Cyan
    $wtNoMut = New-PushedRepo 'wt-no-mutation'
    Fire -Cwd $wtNoMut -EventName 'SessionStart' -SessionId 'wt-no-mut-sess' | Out-Null
    $wtNoMutExtra = Join-Path $ReposRoot 'wt-no-mutation-extra'
    & git -C $wtNoMut worktree add -q $wtNoMutExtra -b wt-no-mutation-extra 2>$null
    [System.IO.File]::WriteAllText((Join-Path $wtNoMutExtra 'dirty.txt'), 'still uncommitted', (New-Object System.Text.UTF8Encoding $false))
    $mainShaBefore = (& git -C $wtNoMut rev-parse HEAD)
    $mainStatusBefore = ((& git -C $wtNoMut status --porcelain) -join "`n")
    $extraShaBefore = (& git -C $wtNoMutExtra rev-parse HEAD)
    $extraStatusBefore = ((& git -C $wtNoMutExtra status --porcelain) -join "`n")
    $worktreeListBefore = ((& git -C $wtNoMut worktree list --porcelain) -join "`n")
    $r = Fire -Cwd $wtNoMut -EventName 'Stop' -SessionId 'wt-no-mut-sess'
    Check 'sanity: the extra worktree with uncommitted changes was actually detected' ($r.Out -match '"decision":"block"') $r.Out
    $mainShaAfter = (& git -C $wtNoMut rev-parse HEAD)
    $mainStatusAfter = ((& git -C $wtNoMut status --porcelain) -join "`n")
    $extraShaAfter = (& git -C $wtNoMutExtra rev-parse HEAD)
    $extraStatusAfter = ((& git -C $wtNoMutExtra status --porcelain) -join "`n")
    $worktreeListAfter = ((& git -C $wtNoMut worktree list --porcelain) -join "`n")
    Check 'main worktree HEAD/status is byte-identical before/after' ($mainShaBefore -eq $mainShaAfter -and $mainStatusBefore -eq $mainStatusAfter)
    Check 'the extra worktree HEAD/status is byte-identical before/after (still uncommitted - the hook never staged/committed it)' (
        $extraShaBefore -eq $extraShaAfter -and $extraStatusBefore -eq $extraStatusAfter -and $extraStatusAfter -ne '')
    Check 'the worktree registration list itself is unchanged (nothing added/removed/(un)locked/pruned by the hook)' ($worktreeListBefore -eq $worktreeListAfter)
    Check 'the hook script never calls git worktree add/remove/prune/lock/unlock (detection+instruction only)' (
        $hookText -notmatch "'add'" -and $hookText -notmatch "'remove'" -and $hookText -notmatch "'prune'" -and
        $hookText -notmatch "'lock'" -and $hookText -notmatch "'unlock'")

    # =====================================================================
    Write-Host '--- HM-08: an unchanged task-scoped block cannot loop (fires once per session) ---' -ForegroundColor Cyan
    $wtLoop = New-PushedRepo 'wt-loop'
    Fire -Cwd $wtLoop -EventName 'SessionStart' -SessionId 'wt-loop-sess' | Out-Null
    $wtLoopExtra = Join-Path $ReposRoot 'wt-loop-extra'
    & git -C $wtLoop worktree add -q $wtLoopExtra -b wt-loop-extra 2>$null
    [System.IO.File]::WriteAllText((Join-Path $wtLoopExtra 'still-dirty.txt'), 'v1', (New-Object System.Text.UTF8Encoding $false))
    $rFirst = Fire -Cwd $wtLoop -SessionId 'wt-loop-sess'
    Check 'first Stop for a new task-scoped dirty worktree blocks' ($rFirst.Out -match '"decision":"block"') $rFirst.Out
    $rSecond = Fire -Cwd $wtLoop -SessionId 'wt-loop-sess'
    Check 'the identical unchanged task-scoped state does not loop on a second Stop in the same session' ($rSecond.Exit -eq 0 -and $rSecond.Out -eq '') $rSecond.Out
    # Change the task-scoped state within the SAME session (commit the file -
    # the worktree becomes clean, but its branch is now unreconciled/unpushed)
    # - the fingerprint must reflect the new state and re-evaluate immediately.
    & git -C $wtLoopExtra add still-dirty.txt
    & git -C $wtLoopExtra commit -q -m 'commit the previously-uncommitted file'
    $rThird = Fire -Cwd $wtLoop -SessionId 'wt-loop-sess'
    Check 'a CHANGED task-scoped state (worktree committed, branch now unreconciled) is evaluated again immediately, same session' ($rThird.Out -match '"decision":"block"' -and $rThird.Out -match 'not reconciled into') $rThird.Out
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
