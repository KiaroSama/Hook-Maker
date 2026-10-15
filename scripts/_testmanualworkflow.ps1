# One public event seam; the remaining graph variants share in-process fixtures.
function Invoke-ManualWorkflowRegression {
    param([switch]$Focused)
    $repo=New-GitRepo 'manual-root-regression'
    $dir=Join-Path $repo '.github/workflows';[void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $repo 'package.json'),'{}',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dir 'ci.yml'),"on: workflow_dispatch`njobs:`n  verify:`n    runs-on: windows-latest`n    steps:`n      - run: npm test`n",[Text.UTF8Encoding]::new($false))
    $r=Fire -HookPath $BaselineHook -Cwd $repo
    Check 'manual hosted validation satisfies CI baseline without automatic advice' ($r.Exit-eq0-and$r.Out-notmatch'none provides blocking project validation|Add CI on push/pull_request') $r.Out
    if($Focused){return}
    . (Join-Path $HooksRoot '_hooklib.ps1');. (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Github-Baseline-Check/_readmebadges.ps1')
    $state = Get-ReadmeBadgeState $repo
    $badgeNote = Get-ReadmeBadgeNote $state
    Check 'README setup/logo/private reference guidance stays advisory' (
        $badgeNote -match 'authorized public source' -and $badgeNote -match 'real installation' -and
        $badgeNote -match 'width="240"' -and $badgeNote -match 'not include an approved logo in the built app' -and
        $badgeNote -match 'private repositories' -and $badgeNote -match 'never invent or alter a wallet')
    $sourceState = Get-ManualWorkflowState (Split-Path -Parent $HooksRoot)
    Check 'own workflow batch has one manual root and reachable reusable validation' $sourceState.Compliant
    $rootText="on: workflow_dispatch`njobs:`n  child:`n    uses: ./.github/workflows/child.yml`n"
    $childText="on: workflow_call`njobs:`n  test:`n    runs-on: ubuntu-latest`n    steps:`n      - run: npm test`n"
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
