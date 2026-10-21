# Persistent workload-review diagnostics; external Git boundary only is synthetic.
param([switch]$RunRegression,[switch]$SmokeOnly)
function Invoke-CiEnrollmentRegression {
    param([string]$HooksRoot,[switch]$SmokeOnly)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1')
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'ls-tree'){return '.github/workflows/ci.yml'}
        if($Arguments[-1]-like'*:.hookmaker-ci-policy.json'){$global:LASTEXITCODE=128;return @()}
        return "on:`n  workflow_dispatch:`njobs:`n  verify:`n    strategy:`n      matrix:`n        node: [22, 24]`n    runs-on: ubuntu-latest`n    steps:`n      - run: echo fixture"
    }
    $value=Get-CiWorkloadExpectation fixture owner/repo ('a'*40) main
    $reason=Get-Variable CiWorkloadReason -Scope Script -ErrorAction SilentlyContinue
    Check 'unsupported node matrix requires actionable source review, never running' ($null-eq$value-and$null-ne$reason-and$reason.Value-match'Set-CiWorkloadReview'-and$reason.Value-notmatch'awaiting|running')
    if($SmokeOnly){return}
    foreach($count in @(3,10)){
        & {param($Size,$Root)
            . (Join-Path $Root 'Ci-Status-Check/_ciworkload.ps1')
            $sha='a'*40;$tree="100644 blob $('b'*40)`t.github/workflows/ci.yml"
            $definitions=@(for($i=0;$i-lt$Size;$i++){@{name=('verify '+$i);steps=@('Checkout','Validate','Build')}})
            $policy=@{schema=1;repository='owner/repo';rationale='Source-defined expanded matrix fixture, independent of observed response';treeFingerprint=Get-RepositoryIdentityHash $tree;sources=@(@{path='.github/workflows/ci.yml';blob=('b'*40)});workflows=@(@{id=9;path='.github/workflows/ci.yml';event='workflow_dispatch';branch='feature/reviewed';branchEquivalent=$true;branchRationale='Explicit immutable source and context review';equivalentTo=@('main');jobs=$definitions})}|ConvertTo-Json -Depth 15
            function Invoke-DocsGit {
                param($Arguments)
                $global:LASTEXITCODE=0
                if($Arguments-contains'show'){return $script:EnrollmentPolicy}
                if($Arguments-contains'--name-only'){return '.github/workflows/ci.yml'}
                return $tree
            }
            function Test-GhAuthenticated{return $true}
            function Test-CiBillingBlocked{return $false}
            $run=@{id=7;workflow_id=9;run_attempt=1;head_sha=$sha;repository=@{full_name='owner/repo'};head_repository=@{full_name='owner/repo'};path='.github/workflows/ci.yml';event='workflow_dispatch';head_branch='feature/reviewed';status='completed';conclusion='success'}
            $jobs=@(for($i=0;$i-lt$Size;$i++){@{id=(100+$i);run_id=7;run_attempt=1;head_sha=$sha;name=$definitions[$i].name;status='completed';conclusion='success';check_run_url=('https://api.github.com/repos/owner/repo/check-runs/'+(100+$i));completed_at='2026-10-17T10:00:00Z';steps=@(for($n=0;$n-lt3;$n++){@{number=($n+1);name=$definitions[$i].steps[$n];status='completed';conclusion='success';completed_at='2026-10-17T09:59:00Z'}})}})
            $checks=@(for($i=0;$i-lt$Size;$i++){@{id=(100+$i);head_sha=$sha;status='completed';conclusion='success'}})
            function Read-CiWorkloadApi {
                param($Endpoint)
                if($script:EnrollmentCase-eq'api-unavailable'){return $null}
                if($Endpoint-match'/actions/runs\?'){return $script:EnrollmentRuns}
                if($Endpoint-match'/attempts/1/jobs'){return $script:EnrollmentJobs}
                if($Endpoint-match'/check-runs'){return $script:EnrollmentChecks}
                if($Endpoint-match'/status'){return $script:EnrollmentStatuses}
                return $null
            }
            foreach($case in @('valid','diagnostic-skipped','missing-job','failed-job','pending-job','wrong-sha','wrong-attempt','missing-step','skipped-step','failed-step','missing-check','failed-check','pending-check','wrong-repo','wrong-workflow','wrong-event','wrong-branch','changed-source','changed-tree','duplicate-job','duplicate-check','partial-checks','partial-statuses','auxiliary-only','api-unavailable')){
                $script:EnrollmentCase=$case;$script:EnrollmentPolicy=$policy
                $p=$policy|ConvertFrom-Json
                $script:EnrollmentRuns=@{total_count=1;workflow_runs=@($run)}|ConvertTo-Json -Depth 15|ConvertFrom-Json
                $script:EnrollmentJobs=@{total_count=$Size;jobs=$jobs}|ConvertTo-Json -Depth 15|ConvertFrom-Json
                $script:EnrollmentChecks=@{total_count=$Size;check_runs=$checks}|ConvertTo-Json -Depth 15|ConvertFrom-Json
                $script:EnrollmentStatuses=@{sha=$sha;total_count=0;statuses=@()}|ConvertTo-Json|ConvertFrom-Json
                if($case-eq'diagnostic-skipped'){
                    $script:EnrollmentJobs.jobs[0].steps+=@([pscustomobject]@{number=4;name='Upload diagnostics';status='completed';conclusion='skipped';completed_at='2026-10-17T09:59:30Z'})
                }
                switch($case){
                    missing-job {$script:EnrollmentJobs.jobs=@($script:EnrollmentJobs.jobs|Select-Object -Skip 1);$script:EnrollmentJobs.total_count--}
                    failed-job {$script:EnrollmentJobs.jobs[0].conclusion='failure'}
                    pending-job {$script:EnrollmentJobs.jobs[0].status='queued'}
                    wrong-sha {$script:EnrollmentJobs.jobs[0].head_sha='d'*40}
                    wrong-attempt {$script:EnrollmentJobs.jobs[0].run_attempt=2}
                    missing-step {$script:EnrollmentJobs.jobs[0].steps=@($script:EnrollmentJobs.jobs[0].steps|Select-Object -Skip 1)}
                    skipped-step {$script:EnrollmentJobs.jobs[0].steps[1].conclusion='skipped'}
                    failed-step {$script:EnrollmentJobs.jobs[0].steps[1].conclusion='failure'}
                    missing-check {$script:EnrollmentChecks.check_runs=@($script:EnrollmentChecks.check_runs|Select-Object -Skip 1);$script:EnrollmentChecks.total_count--}
                    failed-check {$script:EnrollmentChecks.check_runs[0].conclusion='failure'}
                    pending-check {$script:EnrollmentChecks.check_runs[0].status='queued'}
                    wrong-repo {$script:EnrollmentRuns.workflow_runs[0].repository.full_name='other/repo'}
                    wrong-workflow {$script:EnrollmentRuns.workflow_runs[0].workflow_id=8}
                    wrong-event {$script:EnrollmentRuns.workflow_runs[0].event='push'}
                    wrong-branch {$script:EnrollmentRuns.workflow_runs[0].head_branch='other'}
                    changed-source {$p.sources[0].blob='d'*40}
                    changed-tree {$p.treeFingerprint='d'*64}
                    duplicate-job {$script:EnrollmentJobs.jobs[1].id=100}
                    duplicate-check {$script:EnrollmentChecks.check_runs[1].id=100}
                    partial-checks {$script:EnrollmentChecks.total_count++}
                    partial-statuses {$script:EnrollmentStatuses.total_count=1}
                    auxiliary-only {$script:EnrollmentRuns.workflow_runs[0].path='dynamic/dependabot'}
                }
                $script:EnrollmentPolicy=$p|ConvertTo-Json -Depth 15
                $result=Get-CiRunSnapshot owner/repo $sha fixture main
                Check ('reviewed expanded '+$Size+' jobs '+$case) (($null-ne$result-and$result.AllSuccess)-eq($case-in@('valid','diagnostic-skipped')))
            }
        } $count $HooksRoot
    }
}
if($RunRegression){
    Set-StrictMode -Version 2.0
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0
    Invoke-CiEnrollmentRegression (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') -SmokeOnly:$SmokeOnly
    Write-Output "Passed: $script:Pass Failed: $script:Fail"
    exit $script:Fail
}
