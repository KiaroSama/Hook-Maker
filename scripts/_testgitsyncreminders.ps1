# Test-GitSyncCheck section: side-branch and push-once reminders (plan 012
# step 2c, spec 010 RD-2 / FR-009).
#
# Dot-sourced from Test-GitSyncCheck.ps1 INSIDE its try block, so it runs in
# that scope with its harness: $Work, $Hook, $FakeLocalAppData, New-Repo,
# New-PushedRepo, Check. The underscore keeps it out of the runner's
# Test-*.ps1 glob, so it needs no CI bucket of its own.
#
# Load-bearing: every reminder case has a silent twin (a listing command, a
# clean push, an unrelated tool call), and every emitted reminder is asserted to
# carry NO permission decision - a reminder must never approve or block.

    Write-Host '--- PreToolUse: side-branch and push-once reminders (advisory context only) ---' -ForegroundColor Cyan
    . (Join-Path (Split-Path -Parent $Hook) '_branchreminders.ps1')
    $kinds = [ordered]@{
        'git checkout -b feature/x'            = 'branch'
        'git switch -c fix/y'                  = 'branch'
        'git branch topic'                     = 'branch'
        'git worktree add ../wt topic'         = 'branch'
        'gh pr create --fill'                  = 'branch'
        'cd repo && git switch -c z'           = 'branch'
        'git push origin main'                 = 'push'
        'git -C "a b" push'                    = 'push'
        'git branch -d old'                    = ''
        'git branch --show-current'            = ''
        'git branch'                           = ''
        'git status --short'                   = ''
        'echo git push is documented here'     = ''
    }
    $wrong = @($kinds.Keys | Where-Object { (Get-GitWorkflowCommandKind -Command $_) -cne $kinds[$_] })
    Check 'RM01 branch/worktree/PR creation and pushes are classified; listing, deleting and prose are not' ($wrong.Count -eq 0) ($wrong -join ' | ')

    function Invoke-PreToolReminder {
        param([string]$Cwd, [string]$Command)
        $payload = @{ session_id = 'rm'; cwd = $Cwd; hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = $Command } } | ConvertTo-Json -Depth 4
        $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $inFile = Join-Path $Work ('rm-in-' + $token + '.json'); $outFile = Join-Path $Work ('rm-out-' + $token + '.txt'); $errFile = Join-Path $Work ('rm-err-' + $token + '.txt')
        [IO.File]::WriteAllText($inFile, $payload, (New-Object Text.UTF8Encoding $false))
        $startArgs = @{
            FilePath = (Get-Process -Id $PID).Path; ArgumentList = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"')
            RedirectStandardInput = $inFile; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
            Wait = $true; NoNewWindow = $true; PassThru = $true
        }
        if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
            $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData; CLAUDE_PROJECT_DIR = $Cwd }
        }
        $proc = Start-BoundedProcess @startArgs
        $out = if (Test-Path -LiteralPath $outFile) { ([IO.File]::ReadAllText($outFile)).Trim() } else { '' }
        return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out }
    }

    $rmRepo = New-PushedRepo 'reminders'
    $r = Invoke-PreToolReminder -Cwd $rmRepo -Command 'git switch -c feature/side'
    Check 'RM02 a branch-creating command gets the side-branch reminder as context' (
        $r.Exit -eq 0 -and $r.Out -match 'GIT WORKFLOW REMINDER: work stays on the default branch' -and
        $r.Out -match 'ONE branch and ONE pull request' -and $r.Out -match '"additionalContext"') $r.Out
    Check 'RM03 the reminder carries no permission decision (never approves, never blocks)' (
        $r.Out -notmatch 'permissionDecision' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Invoke-PreToolReminder -Cwd $rmRepo -Command 'git push origin main'
    Check 'RM04 a push from a clean tree is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    [IO.File]::WriteAllText((Join-Path $rmRepo 'f.txt'), 'v2', (New-Object Text.UTF8Encoding $false))
    $r = Invoke-PreToolReminder -Cwd $rmRepo -Command 'git push origin main'
    Check 'RM05 a push with uncommitted work gets the push-once reminder, naming the count' (
        $r.Out -match 'still has 1 uncommitted change' -and $r.Out -match 'pushes ONCE' -and $r.Out -notmatch 'permissionDecision') $r.Out
    $r = Invoke-PreToolReminder -Cwd $rmRepo -Command 'Get-ChildItem'
    Check 'RM06 an unrelated tool call is silent and runs no sync scan' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $hookSource = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $Hook) '_branchreminders.ps1'))
    Check 'RM07 the reminder source never executes the classified command' (
        $hookSource -notmatch 'Invoke-Expression' -and $hookSource -notmatch '(?i)\biex\b' -and $hookSource -notmatch '&\s*\$') ''
