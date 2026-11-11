# Test-CiStatusCheck section: self-hosted runners stay manual (plan 012 step
# 6b, spec 010 RD-3 / FR-010).
#
# Dot-sourced from Test-CiStatusCheck.ps1 INSIDE its try block, so it runs in
# that scope with its harness: New-GitRepo, Set-Mock, Get-HeadSha, Fire,
# $CiHook, Check. The underscore keeps it out of the runner's Test-*.ps1 glob.

    Write-Host '--- self-hosted runners stay manual: facts, and final dispatch missing ---' -ForegroundColor Cyan
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
    Check 'SH05 no run on a manual self-hosted repo -> "final dispatch missing", a block, never green' (
        $r.Out -match 'final dispatch missing' -and $r.Out -match '"decision":"block"' -and
        $r.Out -match 'No bot refs/runner action' -and $r.Out -notmatch 'no runs are registered yet') $r.Out

    $shPushed = New-GitRepo 'selfhosted-push'
    New-Item -ItemType Directory -Path (Join-Path $shPushed '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $shPushed '.github\workflows\ci.yml') $wfPush
    Check 'SH06 a self-hosted workflow triggered by push is not manual' (-not (Test-ManualSelfHostedRepo -ProjectRoot $shPushed))
    Set-Mock -ExpectedSha (Get-HeadSha $shPushed)
    $r = Fire -HookPath $CiHook -Cwd $shPushed -EventName 'Stop'
    Check 'SH07 twin: a push-triggered repo with no run still gets the ordinary wait block' ($r.Out -match 'no runs are registered yet' -and $r.Out -notmatch 'not yet dispatched') $r.Out

    $hostedManual = New-GitRepo 'hosted-manual'
    New-Item -ItemType Directory -Path (Join-Path $hostedManual '.github/workflows') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $hostedManual '.github/workflows/ci.yml'), $wfDispatch.Replace('self-hosted','ubuntu-latest'), [Text.UTF8Encoding]::new($false))
    Check 'SH08 hosted manual validation uses the same bounded predicate' (Test-ManualCiRepository $hostedManual)
    Set-Mock -ExpectedSha (Get-HeadSha $hostedManual)
    $r = Fire -HookPath $CiHook -Cwd $hostedManual -EventName 'Stop'
    Check 'SH09 missing hosted dispatch is pending, never automatic or green' (
        $r.Out -match 'final dispatch missing' -and $r.Out -match 'Ordinary CI manual: workflow_dispatch/reachable workflow_call' -and $r.Out -match '"decision":"block"') $r.Out

    $tokens=$null;$errors=$null
    $helper=Join-Path $PSScriptRoot '_testmanualworkflow.ps1'
    $ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
    $fixture=$ast.Find({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Get-SecurityWorkflowFixture'},$true)
    . ([scriptblock]::Create($fixture.Extent.Text))
    $securityText=Get-SecurityWorkflowFixture
    $scanRepo=New-GitRepo 'security-only-no-run'
    [IO.File]::WriteAllText((Join-Path $scanRepo '.github/workflows/ci.yml'),$securityText,[Text.UTF8Encoding]::new($false))
    Set-Mock -ExpectedSha (Get-HeadSha $scanRepo)
    $r=Fire -HookPath $CiHook -Cwd $scanRepo -EventName 'Stop'
    Check 'security-only no run is unproven without fabricated manual missing-dispatch instruction' (
        $r.Out-match'"decision":"block"'-and$r.Out-match'security-only; no runs'-and
        $r.Out-notmatch'final dispatch missing|gh workflow run') $r.Out
    [IO.File]::WriteAllText((Join-Path $scanRepo '.github/workflows/scan.yml'),$securityText,[Text.UTF8Encoding]::new($false))
    $manual="on: [workflow_dispatch]`njobs:`n  verify:`n    runs-on: windows-latest`n    steps:`n      - run: npm test`n"
    [IO.File]::WriteAllText((Join-Path $scanRepo '.github/workflows/ci.yml'),$manual,[Text.UTF8Encoding]::new($false))
    $r=Fire -HookPath $CiHook -Cwd $scanRepo -EventName 'Stop'
    # Mixed files are unsupported by the exact-SHA verifier absent reviewed evidence.
    # Its refusal must not be loosened to obtain a missing-dispatch or green label.
    Check 'manual validation beside security scan still needs exact reviewed workload, not no-ci' (
        $r.Out-match'"decision":"block"'-and$r.Out-notmatch'security-only; no runs'-and
        $r.Out-match'UNPROVEN|UNVERIFIED|unproven|review|workload|final dispatch missing') $r.Out
