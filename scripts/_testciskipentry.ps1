# Real stdin-driven Stop with a reviewed manual/matrix/reusable source shape.
# Dot-sourced by the existing Ci suite; private runtime/config/state are fixtures.
$reviewRepo=New-GitRepo 'ci-reviewed-skipped-entry'
$reviewWorkflow=@'
name: Reviewed manual
on:
  workflow_dispatch:
    inputs:
      diagnostic:
        type: boolean
        default: false
jobs:
  native:
    strategy:
      matrix:
        os: [windows-latest, ubuntu-24.04]
    runs-on: ${{ matrix.os }}
    steps:
      - name: Validate
        run: echo fixture
  reusable:
    uses: ./.github/workflows/reusable.yml
  diagnostic:
    if: inputs.diagnostic
    runs-on: ubuntu-latest
    steps:
      - run: echo diagnostic
  publish:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - run: echo publish
'@
$utf8=New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $reviewRepo '.github/workflows/ci.yml'),$reviewWorkflow,$utf8)
[IO.File]::WriteAllText((Join-Path $reviewRepo '.github/workflows/reusable.yml'),"on: [workflow_call]`njobs:`n  validate:`n    runs-on: ubuntu-latest`n    steps:`n      - name: Review`n        run: echo fixture`n",$utf8)
$null=& git -C $reviewRepo add .
$null=& git -C $reviewRepo commit -q -m fixture
$reviewSha=Get-HeadSha $reviewRepo
$null=& git -C $reviewRepo update-ref refs/remotes/origin/main $reviewSha
$reviewTree=@(& git -c core.quotePath=false -C $reviewRepo ls-tree -r $reviewSha)
$sourceRows=@(foreach($row in $reviewTree){if($row-match'^100644 blob ([a-f0-9]{40})\t(\.github/workflows/.+)$'){@{path=$Matches[2];blob=$Matches[1]}}})
. (Join-Path $HooksRoot '_hooklib.ps1')
$reviewPolicy=@{schema=1;repository='testowner/testrepo-ci-reviewed-skipped-entry';rationale='Inert complete manual/matrix/reusable fixture reviewed independently of responses';treeFingerprint=Get-RepositoryIdentityHash ($reviewTree-join"`n");sources=$sourceRows;workflows=@(@{path='.github/workflows/ci.yml';id=9;event='workflow_dispatch';branch='feature/reviewed';branchEquivalent=$true;branchRationale='Inert validation same source; main publication remains inapplicable to original branch run';equivalentTo=@('main');jobs=@(@{name='native (windows-latest)';steps=@('Validate')},@{name='native (ubuntu-24.04)';steps=@('Validate')},@{name='reusable / validate';steps=@('Review')},@{name='diagnostic';disposition='skipped';rationale='Diagnostic input was false for reviewed manual event';steps=@()},@{name='publish';disposition='skipped';rationale='Original reviewed branch is not main; publication not executed';steps=@()})})}
$reviewHook=New-ConfiguredCiHookCopy @{PENDING_COOLDOWN_MINUTES='3'}
$reviewPath=Join-Path (Split-Path -Parent $reviewHook) '_ci-policy.json'
$reviewJson=$reviewPolicy|ConvertTo-Json -Depth 15 -Compress
[IO.File]::WriteAllText($reviewPath,$reviewJson,$utf8)
$run=@{id=701;workflow_id=9;run_attempt=1;head_sha=$reviewSha;repository=@{full_name='testowner/testrepo-ci-reviewed-skipped-entry'};head_repository=@{full_name='testowner/testrepo-ci-reviewed-skipped-entry'};path='.github/workflows/ci.yml';event='workflow_dispatch';head_branch='feature/reviewed';status='completed';conclusion='success'}
$jobRows=@(for($i=0;$i-lt5;$i++){
    $job=$reviewPolicy.workflows[0].jobs[$i];$skip=$i-ge3
    @{id=(710+$i);run_id=701;run_attempt=1;head_sha=$reviewSha;name=$job.name;status='completed';conclusion=$(if($skip){'skipped'}else{'success'});check_run_url=('https://api.github.com/repos/testowner/testrepo-ci-reviewed-skipped-entry/check-runs/'+(810+$i));completed_at='2026-10-17T10:00:00Z';steps=@(if(-not$skip){@{number=1;name=$job.steps[0];status='completed';conclusion='success';completed_at='2026-10-17T09:58:00Z'}})}
})
$checkRows=@(for($i=0;$i-lt5;$i++){@{id=(810+$i);head_sha=$reviewSha;status='completed';conclusion=$(if($i-ge3){'skipped'}else{'success'})}})
Set-Mock -ExpectedSha $reviewSha
foreach($pair in @(@('runs',@{total_count=1;workflow_runs=@($run)}),@('jobs',@{total_count=5;jobs=$jobRows}),@('checks',@{total_count=5;check_runs=$checkRows}),@('statuses',@{sha=$reviewSha;total_count=0;statuses=@()}))){
    [IO.File]::WriteAllText((Join-Path $MockDir ('raw-'+$pair[0]+'.json')),($pair[1]|ConvertTo-Json -Depth 15 -Compress),$utf8)
}
$fixtureState=Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker/state') ('CiStatusCheck-'+(Get-ShortHash ($reviewRepo.ToLowerInvariant()+'|testowner/testrepo-ci-reviewed-skipped-entry'))+'.txt')
# The first event produces pending itself; the next refresh must supersede it
# without editing state or requiring a skip-marked commit.
$run.status='in_progress';$run.conclusion=$null
[IO.File]::WriteAllText((Join-Path $MockDir 'raw-runs.json'),(@{total_count=1;workflow_runs=@($run)}|ConvertTo-Json -Depth 10 -Compress),$utf8)
$initial=Fire -HookPath $reviewHook -Cwd $reviewRepo -EventName Stop -Extra @{session_id='reviewed-pending'}
Check 'reviewed public Stop genuinely running remains blocking' ($initial.Out-match'not finished yet') $initial.Out
$run.status='completed';$run.conclusion='success'
[IO.File]::WriteAllText((Join-Path $MockDir 'raw-runs.json'),(@{total_count=1;workflow_runs=@($run)}|ConvertTo-Json -Depth 10 -Compress),$utf8)
foreach($hostKind in @('primary','framework')){
    $exe=if($hostKind-eq'framework'){'powershell.exe'}else{''}
    $result=Fire -HookPath $reviewHook -Cwd $reviewRepo -EventName Stop -Exe $exe -Extra @{session_id=('reviewed-'+$hostKind)}
    Check ('reviewed public Stop manual matrix reusable skipped '+$hostKind) ($result.Exit-eq0-and$result.Out-eq''-and$result.Err-eq'') ($result.Out+$result.Err)
}
$lines=[IO.File]::ReadAllLines($fixtureState,[Text.Encoding]::UTF8)
Check 'fresh terminal review replaces actual pending with validated provenance' ($lines[1]-ceq'verified'-and$lines[3]-ceq'ci-green'-and$lines[4]-match'reviewed')
# Invalidating the source review must not reuse the previous green label.
$bad=$reviewJson|ConvertFrom-Json;$bad.workflows[0].jobs[4].rationale=''
[IO.File]::WriteAllText($reviewPath,($bad|ConvertTo-Json -Depth 15 -Compress),$utf8)
$unknown=Fire -HookPath $reviewHook -Cwd $reviewRepo -EventName Stop -Extra @{session_id='reviewed-unknown'}
Check 'public Stop malformed review remains unproven not running' ($unknown.Out-match'not proven'-and$unknown.Out-notmatch'awaiting terminal') $unknown.Out
$lines=[IO.File]::ReadAllLines($fixtureState,[Text.Encoding]::UTF8)
Check 'unknown workload uses distinct unproven state' ($lines[1]-ceq'unproven')
[IO.File]::WriteAllText($reviewPath,$reviewJson,$utf8)
$jobRows[0].steps[0].conclusion='skipped'
[IO.File]::WriteAllText((Join-Path $MockDir 'raw-jobs.json'),(@{total_count=5;jobs=$jobRows}|ConvertTo-Json -Depth 15 -Compress),$utf8)
$negative=Fire -HookPath $reviewHook -Cwd $reviewRepo -EventName Stop -Extra @{session_id='reviewed-required-skip'}
Check 'public Stop skipped required validation never passes' ($negative.Out-match'not proven') $negative.Out
Set-Mock
