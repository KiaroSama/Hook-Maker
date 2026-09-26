# Test-CiStatusCheck section: self-hosted runners stay manual (plan 012 step
# 6b, spec 010 RD-3 / FR-010).
#
# Dot-sourced from Test-CiStatusCheck.ps1 INSIDE its try block, so it runs in
# that scope with its harness: New-GitRepo, Set-Mock, Get-HeadSha, Fire,
# $CiHook, Check. The underscore keeps it out of the runner's Test-*.ps1 glob.

    Write-Host '--- self-hosted runners stay manual: facts, and final CI not yet dispatched ---' -ForegroundColor Cyan
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $CiHook)) '_scope.ps1')
    $wfPush = "on:`n  push:`n    branches: [main]`n  workflow_dispatch:`njobs:`n  test:`n    runs-on: [self-hosted, windows]`n    steps:`n      - run: echo test"
    $wfDispatch = "on:`n  workflow_dispatch:`n    inputs:`n      push:`n        type: boolean`njobs:`n  test:`n    runs-on:`n      - self-hosted`n      - linux`n    steps:`n      - run: echo test"
    $wfHosted = "on: [push, pull_request]`njobs:`n  test:`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo test"
    Check 'SH01 block-style triggers are read; an input named push under workflow_dispatch is not a trigger' (
        ((Get-WorkflowTopTriggers $wfPush) -join ',') -ceq 'push,workflow_dispatch' -and
        ((Get-WorkflowTopTriggers $wfDispatch) -join ',') -ceq 'workflow_dispatch') ((Get-WorkflowTopTriggers $wfDispatch) -join ',')
    Check 'SH02 flow-style triggers are read' (((Get-WorkflowTopTriggers $wfHosted) -join ',') -ceq 'pull_request,push')
    Check 'SH03 self-hosted is found inline, in a flow list and in a block list; a hosted runner is not' (
        (Test-WorkflowSelfHosted $wfPush) -and (Test-WorkflowSelfHosted $wfDispatch) -and -not (Test-WorkflowSelfHosted $wfHosted))

    $shManual = New-GitRepo 'selfhosted-manual'
    New-Item -ItemType Directory -Path (Join-Path $shManual '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $shManual '.github\workflows\ci.yml') $wfDispatch
    Check 'SH04 a dispatch-only self-hosted repository is manual' (Test-ManualSelfHostedRepo -ProjectRoot $shManual)
    Set-Mock -ExpectedSha (Get-HeadSha $shManual)
    $r = Fire -HookPath $CiHook -Cwd $shManual -EventName 'Stop'
    Check 'SH05 no run on a manual self-hosted repo -> "final CI not yet dispatched", a block, never green' (
        $r.Out -match 'final CI not yet dispatched' -and $r.Out -match '"decision":"block"' -and
        $r.Out -match 'never for a GitHub- or bot-created branch' -and $r.Out -notmatch 'no runs are registered yet') $r.Out

    $shPushed = New-GitRepo 'selfhosted-push'
    New-Item -ItemType Directory -Path (Join-Path $shPushed '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $shPushed '.github\workflows\ci.yml') $wfPush
    Check 'SH06 a self-hosted workflow triggered by push is not manual' (-not (Test-ManualSelfHostedRepo -ProjectRoot $shPushed))
    Set-Mock -ExpectedSha (Get-HeadSha $shPushed)
    $r = Fire -HookPath $CiHook -Cwd $shPushed -EventName 'Stop'
    Check 'SH07 twin: a push-triggered repo with no run still gets the ordinary wait block' ($r.Out -match 'no runs are registered yet' -and $r.Out -notmatch 'not yet dispatched') $r.Out
