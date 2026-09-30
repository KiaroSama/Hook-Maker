# Test-TestRunGuard.ps1 scenario block: CI runner stops (plan 046 item g;
# global-github-automation-rules.md -> Self-Hosted Runners). A stop by name or
# wildcard is refused with THIS project's own stop; a pid-based stop and this
# project's exact service name pass; `wsl --shutdown` is advised, never refused;
# a quoted string that only CONTAINS a runner name is data.
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- runner stops: by name or wildcard refused, by identity allowed ---' -ForegroundColor Cyan
    $hcRs = New-IsolatedHookCopy
    $ownFolder = (Join-Path $Proj '.ci-runner-win') + '\*'
    foreach ($forbidden in @(
            'taskkill /IM Runner.Listener.exe /F',
            'Stop-Process -Name Runner* -Force',
            'Get-Process Runner* | Stop-Process',
            'wsl.exe -e pkill -f Runner.Worker',
            'Stop-Service "actions.runner.*"',
            "systemctl stop 'actions.runner.*'",
            'Stop-Process -Name Runner.Listener,Runner.Worker',
            'kill -Name Runner*',
            'sudo -u root pkill -f Runner.Listener')) {
        $r = Fire -HookPath $hcRs.Script -Cwd $Proj -EventName 'PreToolUse' -Command $forbidden -LocalAppData $hcRs.LocalAppData
        $m = Get-Message $r.Out
        Check ('runner stop refused: ' + $forbidden) ($r.Out -match '"permissionDecision":"deny"' -and $m -match 'every other project''s runner') $r.Out
    }
    $r = Fire -HookPath $hcRs.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'taskkill /IM Runner.Listener.exe /F' -LocalAppData $hcRs.LocalAppData
    Check 'the refusal names this project''s own runner folder as the replacement' ((Get-Message $r.Out).Contains($ownFolder)) (Get-Message $r.Out)
    $r = Fire -HookPath $hcRs.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pkill -f Runner.Listener' -LocalAppData $hcRs.LocalAppData
    Check 'a WSL-side refusal names this project''s /srv/ci/runners/<slug>/ path' ((Get-Message $r.Out) -match "pkill -f '/srv/ci/runners/project/'") (Get-Message $r.Out)

    foreach ($allowed in @('taskkill /PID 4242 /T', 'Stop-Service actions.runner.KiaroSama-Hook-Maker.win-1', "pkill -f '/srv/ci/runners/project/'",
            'echo "taskkill /IM Runner.Listener.exe"')) {
        $r = Fire -HookPath $hcRs.Script -Cwd $Proj -EventName 'PreToolUse' -Command $allowed -LocalAppData $hcRs.LocalAppData
        Check ('not a runner stop by name: ' + $allowed) ($r.Out -notmatch 'permissionDecision' -and (Get-Message $r.Out) -notmatch 'runner') $r.Out
    }
    $r = Fire -HookPath $hcRs.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'wsl --shutdown' -LocalAppData $hcRs.LocalAppData
    Check 'wsl --shutdown is advised against, never refused' (
        $r.Out -notmatch '"permissionDecision":"deny"' -and (Get-Message $r.Out) -match 'stops every WSL CI runner') $r.Out
    $r = Fire -HookPath $hcRs.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'taskkill /IM Runner.Listener.exe /F' -LocalAppData $hcRs.LocalAppData -Exe 'powershell'
    Check 'the refusal holds on Windows PowerShell 5.1' ($r.Out -match '"permissionDecision":"deny"') $r.Out
