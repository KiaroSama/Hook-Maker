function Get-SecurityWorkflowFixture {
    return "on: [push, pull_request]`npermissions: {}`njobs:`n  scan:`n    runs-on: ubuntu-latest`n    timeout-minutes: 15`n    permissions:`n      contents: read`n      security-events: write`n    steps:`n      - uses: actions/checkout@v7`n      - uses: github/codeql-action/init@v4`n        with:`n          languages: javascript-typescript`n          build-mode: none`n      - uses: github/codeql-action/analyze@v4`n"
}

# One public event seam; the remaining graph variants share in-process fixtures.
function Invoke-ManualWorkflowRegression {
    param([switch]$Focused)
    $repo=New-GitRepo 'manual-root-regression'
    $dir=Join-Path $repo '.github/workflows';[void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $repo 'package.json'),'{}',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dir 'ci.yml'),"on: workflow_dispatch`njobs:`n  verify:`n    runs-on: windows-latest`n    steps:`n      - run: npm test`n",[Text.UTF8Encoding]::new($false))
    $r=Fire -HookPath $BaselineHook -Cwd $repo
    Check 'manual hosted validation satisfies CI baseline without automatic advice' ($r.Exit-eq0-and$r.Out-notmatch'none provides blocking project validation|Add CI on push/pull_request') $r.Out
    Check 'security posture binds ownership visibility support and full current owner' (
        $r.Out-match'global-github-automation-rules.md Sec12 FULL first: owner/visibility/support/plan'-and
        $r.Out-match'Public CodeQL/Socket/Semgrep/CodeRabbit'-and
        $r.Out-match'private Socket/Semgrep; preserve existing'-and
        $r.Out-match'Graph/alerts/malware/update PRs distinct'-and
        $r.Out-match'Free-first/shared quotas/financial consent/privacy'-and
        $r.Out-notmatch'CodeQL optional|Optional CodeQL absent') $r.Out
    Check 'security reminder routes real reviews privacy and nonexecuting scope' (
        $r.Out-match'All-bot disposition'-and$r.Out-match'CodeRabbit uncovered head only; no duplicates/auto-merge'-and
        $r.Out-match'Latest execution!=rate-limit/stale/skip'-and
        $r.Out-match'Verified private action links'-and
        $r.Out-match'Info-only: no actions; hook executes nothing') $r.Out
    if($Focused){return}
    . (Join-Path $HooksRoot '_hooklib.ps1');. (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Github-Baseline-Check/_readmebadges.ps1')
    $state = Get-ReadmeBadgeState $repo
    $badgeNote = Get-ReadmeBadgeNote $state
    Check 'README and packaged-logo contracts require distinct full owners before work' (
        $badgeNote -match 'BEFORE README: global-repository-rules.md README FULL' -and
        $badgeNote -match 'BEFORE app logo/signing: global-project-lifecycle-rules.md FULL; README!=app logo' -and
        $badgeNote -match '12 to 16 verified badges/Donate')
    $sourceState = Get-ManualWorkflowState (Split-Path -Parent $HooksRoot)
    Check 'own workflow batch has one manual root and reachable reusable validation' $sourceState.Compliant
    $rootText="on: workflow_dispatch`njobs:`n  child:`n    uses: ./.github/workflows/child.yml`n"
    $childText="on: workflow_call`njobs:`n  test:`n    runs-on: ubuntu-latest`n    steps:`n      - run: npm test`n"
    # A supported scan can coexist with manual validation, but never replace it.
    $securityText=Get-SecurityWorkflowFixture
    $securityPath=Join-Path $dir 'security.yml'
    [IO.File]::WriteAllText($securityPath,$securityText,[Text.UTF8Encoding]::new($false))
    foreach($client in @('claude','codex')) {
        $publicRepo=New-GitRepo ('security-advisory-'+$client)
        $publicDir=Join-Path $publicRepo '.github/workflows';[void][IO.Directory]::CreateDirectory($publicDir)
        [IO.File]::WriteAllText((Join-Path $publicDir 'ci.yml'),$securityText,[Text.UTF8Encoding]::new($false))
        $event=Fire -HookPath $BaselineHook -Cwd $publicRepo -Client $client
        Check ('supported scan emits no blanket automatic rejection: '+$client) (
            $event.Exit-eq0-and$event.Err-eq''-and$event.Out-notmatch'MANUAL CI, all hosts|automatic project/unknown trigger'-and
            $event.Out-match'global-github-automation-rules.md Sec12 FULL') $event.Out
    }
    foreach($variant in @(
        @{Name='dedicated hosted CodeQL';Text=$securityText;Expected=$true},
        @{Name='block events and schedule';Text=$securityText.Replace('on: [push, pull_request]',"on:`n  push:`n  pull_request:`n  schedule:`n    - cron: '0 12 * * 1'");Expected=$true},
        @{Name='manual scan root';Text=$securityText.Replace('[push, pull_request]','workflow_dispatch');Expected=$true},
        @{Name='dependency review PR';Text=("on: pull_request`npermissions: {}`njobs:`n  scan:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    permissions:`n      contents: read`n    steps:`n      - uses: actions/checkout@v7`n      - uses: actions/dependency-review-action@v4`n");Expected=$true},
        @{Name='dependency review unknown block shape';Text=("on:`n  pull_request:`npermissions: {}`njobs:`n  scan:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    permissions:`n      contents: read`n    steps:`n      - uses: actions/checkout@v7`n      - uses: actions/dependency-review-action@v4`n");Expected=$false},
        @{Name='mixed ordinary test';Text=($securityText+"      - run: npm test`n");Expected=$false},
        @{Name='arbitrary shell';Text=($securityText+"      - run: echo hello`n");Expected=$false},
        @{Name='security name alone';Text=$childText.Replace('workflow_call','push');Expected=$false},
        @{Name='automatic self hosted security';Text=$securityText.Replace('ubuntu-latest','self-hosted');Expected=$false},
        @{Name='privileged trigger';Text=$securityText.Replace('pull_request','pull_request_target');Expected=$false},
        @{Name='unknown action';Text=$securityText.Replace('github/codeql-action/analyze','vendor/security');Expected=$false},
        @{Name='unbounded scan';Text=$securityText.Replace("    timeout-minutes: 15`n",'');Expected=$false},
        @{Name='broad permissions';Text=$securityText.Replace('contents: read','contents: write');Expected=$false},
        @{Name='expression runner';Text=$securityText.Replace('ubuntu-latest','${{ matrix.os }}');Expected=$false},
        @{Name='autobuild';Text=$securityText.Replace('github/codeql-action/analyze','github/codeql-action/autobuild');Expected=$false},
        @{Name='mixed second job';Text=($securityText+"  ordinary:`n    runs-on: ubuntu-latest`n    steps:`n      - run: npm test`n");Expected=$false},
        @{Name='duplicate events';Text=$securityText.Replace('on: [push, pull_request]',"on: [push, pull_request]`non: workflow_dispatch");Expected=$false},
        @{Name='input can inject language';Text=$securityText.Replace('javascript-typescript','${{ inputs.language }}');Expected=$false},
        @{Name='compiled language unsupported';Text=$securityText.Replace('javascript-typescript','cpp');Expected=$false},
        @{Name='no permission scope';Text=$securityText.Replace("permissions: {}`n",'');Expected=$false},
        @{Name='nonblocking scan';Text=$securityText.Replace('    runs-on:',"    continue-on-error: true`n    runs-on:");Expected=$false},
        @{Name='cron mismatched quote';Text=$securityText.Replace('on: [push, pull_request]',"on:`n  schedule:`n    - cron: '0 12 * * 1"+'"');Expected=$false},
        @{Name='cron invalid field count';Text=$securityText.Replace('on: [push, pull_request]',"on:`n  schedule:`n    - cron: '0 12 * *'");Expected=$false},
        @{Name='cron invalid hour';Text=$securityText.Replace('on: [push, pull_request]',"on:`n  schedule:`n    - cron: '0 99 * * 1'");Expected=$false},
        @{Name='duplicate flow event';Text=$securityText.Replace('[push, pull_request]','[push, push]');Expected=$false},
        @{Name='duplicate block event';Text=$securityText.Replace('on: [push, pull_request]',"on:`n  push:`n  push:");Expected=$false},
        @{Name='duplicate job ID';Text=($securityText+$securityText.Substring($securityText.IndexOf('  scan:')));Expected=$false}
    )){
        [IO.File]::WriteAllText((Join-Path $dir 'ci.yml'),$rootText,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $dir 'child.yml'),$childText,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($securityPath,$variant.Text,[Text.UTF8Encoding]::new($false))
        $securityState=Get-ManualWorkflowState $repo
        Check ('security beside manual validation: '+$variant.Name) ($securityState.Compliant-eq$variant.Expected-and-not$securityState.SecurityOnly)
    }
    [IO.File]::WriteAllText($securityPath,$securityText,[Text.UTF8Encoding]::new($false))
    [IO.File]::Delete((Join-Path $dir 'ci.yml'));[IO.File]::Delete((Join-Path $dir 'child.yml'))
    $securityState=Get-ManualWorkflowState $repo
    Check 'security scans alone never satisfy ordinary manual project validation' ($securityState.SecurityOnly-and-not $securityState.Compliant-and-not $securityState.HasValidation)
    $renamed=Join-Path $dir 'ordinary.yml';[IO.File]::Move($securityPath,$renamed)
    Check 'security classification never depends on the workflow filename' (Get-ManualWorkflowState $repo).SecurityOnly
    [IO.File]::Delete($renamed)
    $cases=@(
        @{Name='manual reusable chain';Root=$rootText;Child=$childText;Expected=$true},
        @{Name='automatic alternate caller';Root=$rootText.Replace('workflow_dispatch','push');Child=$childText;Expected=$false},
        @{Name='nested push input is not trigger';Root="on:`n  workflow_dispatch:`n    inputs:`n      push:`n        type: boolean`njobs:`n  child:`n    uses: ./.github/workflows/child.yml`n";Child=$childText;Expected=$true},
        @{Name='disabled reusable child';Root=$rootText;Child=$childText.Replace('    runs-on:',"    if: false`n    runs-on:");Expected=$false},
        @{Name='unreachable reusable child';Root="on: workflow_dispatch`njobs:`n  echo:`n    steps:`n      - run: echo hello`n";Child=$childText;Expected=$false},
        @{Name='missing local reusable child';Root=$rootText.Replace('child.yml','missing.yml');Child=$childText;Expected=$false},
        @{Name='manual self hosted root';Root=$childText.Replace('workflow_call','workflow_dispatch').Replace('ubuntu-latest','self-hosted');Child=$childText;Expected=$true},
        @{Name='cycle cannot establish validation';Root=$rootText+"  test:`n    steps:`n      - run: npm test`n";Child=$childText+"  loop:`n    uses: ./.github/workflows/child.yml`n";Expected=$false},
        @{Name='conditional caller is unverified';Root=$rootText.Replace('    uses:',"    if: github.ref == 'refs/heads/main'`n    uses:");Child=$childText;Expected=$false},
        @{Name='disabled validation step';Root=$childText.Replace('workflow_call','workflow_dispatch').Replace('- run: npm test',"- run: npm test`n        if: false");Child=$childText;Expected=$false},
        @{Name='nonblocking validation step';Root=$childText.Replace('workflow_call','workflow_dispatch').Replace('- run: npm test',"- run: npm test`n        continue-on-error: true");Child=$childText;Expected=$false},
        @{Name='nested input run is not validation';Root="on: workflow_dispatch`njobs:`n  echo:`n    steps:`n      - uses: vendor/action@v1`n        with:`n          run: npm test`n";Child=$childText;Expected=$false},
        @{Name='automatic alternate workflow';Root=$rootText;Child=$childText+"on: push`n";Expected=$false},
        @{Name='case-sensitive local path';Root=$rootText.Replace('child.yml','Child.yml');Child=$childText;Expected=$false},
        @{Name='shell comment alone is not validation';Root=$childText.Replace('workflow_call','workflow_dispatch').Replace('npm test',"|`n          # npm test`n          echo hello");Child=$childText;Expected=$false},
        @{Name='quoted disabled job';Root=$rootText;Child=$childText.Replace('    runs-on:',"    'if': false`n    runs-on:");Expected=$false},
        @{Name='quoted nonblocking job';Root=$rootText;Child=$childText.Replace('    runs-on:',"    'continue-on-error': true`n    runs-on:");Expected=$false},
        @{Name='quoted disabled step';Root=$rootText;Child=$childText.Replace('- run: npm test',"- run: npm test`n        'if': false");Expected=$false},
        @{Name='quoted nonblocking step';Root=$rootText;Child=$childText.Replace('- run: npm test',"- run: npm test`n        'continue-on-error': true");Expected=$false},
        @{Name='PowerShell invocation is not YAML anchor';Root=$rootText;Child=$childText.Replace('npm test',"|`n          & pwsh -File ./scripts/Test-Core.ps1");Expected=$true},
        @{Name='YAML anchor stays unsupported';Root=$rootText;Child=$childText.Replace('  test:', '  test: &validation');Expected=$false}
    )
    foreach($case in $cases){
        [IO.File]::WriteAllText((Join-Path $dir 'ci.yml'),$case.Root,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $dir 'child.yml'),$case.Child,[Text.UTF8Encoding]::new($false))
        $state=Get-ManualWorkflowState $repo
        Check ('manual workflow graph: '+$case.Name) ($state.Compliant-eq$case.Expected)
    }
}
