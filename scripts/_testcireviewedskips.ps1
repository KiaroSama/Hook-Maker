# One offline source/API fixture; no real GitHub or consumer state is changed.
param([switch]$RunRegression,[switch]$SmokeOnly)
function Invoke-CiReviewedSkipRegression {
    param([string]$HooksRoot,[switch]$SmokeOnly)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1')
    $sha='a'*40
    $tree="100644 blob $('b'*40)`t.github/workflows/ci.yml"
    $policy=[ordered]@{
        schema=1;repository='owner/repo';rationale='Inert manual source and branch conditions reviewed'
        treeFingerprint=Get-RepositoryIdentityHash $tree
        sources=@(@{path='.github/workflows/ci.yml';blob=('b'*40)})
        workflows=@(@{path='.github/workflows/ci.yml';id=9;event='workflow_dispatch';branch='feature/reviewed'
            branchEquivalent=$true;branchRationale='No unreviewed branch-dependent validation inputs';equivalentTo=@('main')
            jobs=@(@{name='native';steps=@('Run validation')},@{name='publish';disposition='skipped';rationale='Publication is main-only and inapplicable to this reviewed branch run';steps=@()})})
    }
    $script:SkipPolicy=$policy|ConvertTo-Json -Depth 12 -Compress
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){return $script:SkipPolicy}
        if($Arguments-contains'--name-only'){return '.github/workflows/ci.yml'}
        return $tree
    }
    function Test-GhAuthenticated {return $true}
    function Test-CiBillingBlocked {return $false}
    $run=@{id=7;workflow_id=9;run_attempt=2;head_sha=$sha;repository=@{full_name='owner/repo'};head_repository=@{full_name='owner/repo'};path='.github/workflows/ci.yml';event='workflow_dispatch';head_branch='feature/reviewed';status='completed';conclusion='success'}
    $jobs=@(
        @{id=12;run_id=7;run_attempt=2;head_sha=$sha;name='native';status='completed';conclusion='success';check_run_url='https://api.github.com/repos/owner/repo/check-runs/101';completed_at='2026-10-17T09:59:00Z';steps=@(@{number=1;name='Run validation';status='completed';conclusion='success';completed_at='2026-10-17T09:58:00Z'})},
        @{id=13;run_id=7;run_attempt=2;head_sha=$sha;name='publish';status='completed';conclusion='skipped';check_run_url='https://api.github.com/repos/owner/repo/check-runs/102';completed_at='2026-10-17T10:00:00Z';steps=@()}
    )
    $checks=@(@{id=101;head_sha=$sha;status='completed';conclusion='success'},@{id=102;head_sha=$sha;status='completed';conclusion='skipped'})
    $script:SkipRuns=@{total_count=1;workflow_runs=@($run)}
    $script:SkipJobs=@{total_count=2;jobs=$jobs}
    $script:SkipChecks=@{total_count=2;check_runs=$checks}
    $script:SkipStatuses=@{sha=$sha;total_count=0;statuses=@()}
    function Read-CiWorkloadApi {
        param($Endpoint)
        if($Endpoint-match'/actions/runs\?'){return ($script:SkipRuns|ConvertTo-Json -Depth 15|ConvertFrom-Json)}
        if($Endpoint-match'/runs/6/attempts/1/jobs'){return ($script:OlderSkipJobs|ConvertTo-Json -Depth 15|ConvertFrom-Json)}
        if($Endpoint-match'/runs/7/attempts/2/jobs'){return ($script:SkipJobs|ConvertTo-Json -Depth 15|ConvertFrom-Json)}
        if($Endpoint-match'/check-runs'){return ($script:SkipChecks|ConvertTo-Json -Depth 15|ConvertFrom-Json)}
        if($Endpoint-match'/status'){return ($script:SkipStatuses|ConvertTo-Json -Depth 15|ConvertFrom-Json)}
        throw 'Unexpected fixture endpoint'
    }
    $expectation=Get-CiReviewedExpectation fixture owner/repo $sha main
    Check 'explicit reviewed inapplicable skip is source-bound input' ($null-ne$expectation)
    $snapshot=Get-CiRunSnapshot owner/repo $sha fixture main
    Check 'exact successful attempt accounts for reviewed skipped job and its own check' ($null-ne$snapshot-and$snapshot.AllSuccess)
    if($null-ne$snapshot-and$snapshot.AllSuccess){
        Check 'skipped publication cannot refresh earlier required execution' ($snapshot.Provenance.completedUtc-ceq'2026-10-17T09:58:00.0000000+00:00')
    }
    # GitHub returns checks from separate successful manual runs on one SHA.
    # Each old skip needs its own attempt proof, but cannot age the newest proof.
    $olderRun=$run|ConvertTo-Json -Depth 15|ConvertFrom-Json
    $olderRun.id=6;$olderRun.run_attempt=1
    $olderJobs=(@{jobs=$jobs}|ConvertTo-Json -Depth 15|ConvertFrom-Json).jobs
    foreach($job in $olderJobs){$job.id+=20;$job.run_id=6;$job.run_attempt=1;$job.completed_at='2026-10-16T10:00:00Z'}
    $olderJobs[0].check_run_url='https://api.github.com/repos/owner/repo/check-runs/201'
    $olderJobs[0].steps[0].completed_at='2026-10-16T09:58:00Z'
    $olderJobs[1].check_run_url='https://api.github.com/repos/owner/repo/check-runs/202'
    $oldChecks=@(@{id=201;head_sha=$sha;status='completed';conclusion='success'},@{id=202;head_sha=$sha;status='completed';conclusion='skipped'})
    $multiplePolicyJson=$script:SkipPolicy
    foreach($case in @('valid','reviewed-old-branch','unreviewed-old-branch','equivalence-disabled','missing-current-branch','older-input-step-skipped','old-step-failed','old-step-pending','old-success-check-absent','wrong-attempt','wrong-sha','missing-jobs','missing-step','failed-run','failed-check','pending-check','unexpected-skip','reused-check-id')){
        $script:OlderSkipJobs=@{total_count=2;jobs=$olderJobs}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        $script:SkipRuns=@{total_count=2;workflow_runs=@($run,$olderRun)}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        $script:SkipChecks=@{total_count=4;check_runs=@($checks)+$oldChecks}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        $script:SkipPolicy=$multiplePolicyJson
        switch($case){
            reviewed-old-branch {$script:SkipRuns.workflow_runs[1].head_branch='main'}
            unreviewed-old-branch {$script:SkipRuns.workflow_runs[1].head_branch='other'}
            equivalence-disabled {$p=$multiplePolicyJson|ConvertFrom-Json;$p.workflows[0].branchEquivalent=$false;$script:SkipPolicy=$p|ConvertTo-Json -Depth 15;$script:SkipRuns.workflow_runs[1].head_branch='main'}
            missing-current-branch {$script:SkipRuns.workflow_runs=@($script:SkipRuns.workflow_runs[1]);$script:SkipRuns.total_count=1;$script:SkipRuns.workflow_runs[0].head_branch='main'}
            older-input-step-skipped {$script:OlderSkipJobs.jobs[0].steps[0].conclusion='skipped';$script:OlderSkipJobs.jobs[0].steps[0].completed_at=$null}
            old-step-failed {$script:OlderSkipJobs.jobs[0].steps[0].conclusion='failure'}
            old-step-pending {$script:OlderSkipJobs.jobs[0].steps[0].status='in_progress'}
            old-success-check-absent {$script:SkipChecks.check_runs=@($script:SkipChecks.check_runs|Where-Object{$_.id-ne201});$script:SkipChecks.total_count=3}
            reused-check-id {$script:OlderSkipJobs.jobs[0].check_run_url='https://api.github.com/repos/owner/repo/check-runs/101'}
            pending-check {$script:SkipChecks.check_runs[2].status='in_progress'}
            wrong-attempt {$script:OlderSkipJobs.jobs[1].run_attempt=2}
            wrong-sha {$script:OlderSkipJobs.jobs[1].head_sha='d'*40}
            missing-jobs {$script:OlderSkipJobs.jobs=@()}
            missing-step {$script:OlderSkipJobs.jobs[0].steps=@()}
            failed-run {$script:SkipRuns.workflow_runs[1].conclusion='failure'}
            failed-check {$script:SkipChecks.check_runs[2].conclusion='failure'}
            unexpected-skip {$script:SkipChecks.check_runs[2].conclusion='skipped'}
        }
        $snapshot=Get-CiRunSnapshot owner/repo $sha fixture main
        Check ('multiple reviewed run skips '+$case) (($null-ne$snapshot-and$snapshot.AllSuccess)-eq($case-in@('valid','reviewed-old-branch','older-input-step-skipped','old-success-check-absent')))
        if($case-eq'valid'-and$null-ne$snapshot-and$snapshot.AllSuccess){
            Check 'only latest matched run supplies provenance and freshness' ($snapshot.Provenance.runs.Count-eq1-and$snapshot.Provenance.runs[0].id-eq7-and$snapshot.Provenance.completedUtc-ceq'2026-10-17T09:58:00.0000000+00:00')
        }
    }
    if($SmokeOnly){return}
    $policyJson=$script:SkipPolicy
    foreach($case in @('required-skip','required-step-skip','unexpected-skip','wrong-check-id','missing-check','extra-job','missing-job','duplicate-job','duplicate-check','wrong-attempt','wrong-run','wrong-sha','wrong-repo','wrong-branch','wrong-event','wrong-workflow','truncated-jobs','truncated-checks','truncated-runs','malformed-review','changed-source','changed-tree','missing-rationale','required-skip-steps','null-skip-steps','missing-skip-steps','unknown-disposition','array-disposition','all-skipped','branch-unreviewed','wrong-destination','duplicate-required-step','skip-executed','skip-has-steps','skip-check-success','skip-pending','skip-failure','skip-cancelled','future-skip','missing-skip-time','genuine-failure','genuine-pending','legacy-pending')){
        $script:SkipPolicy=$policyJson
        $copy=$policyJson|ConvertFrom-Json
        $script:SkipRuns=@{total_count=1;workflow_runs=@($run)}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        $script:SkipJobs=@{total_count=2;jobs=$jobs}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        $script:SkipChecks=@{total_count=2;check_runs=$checks}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        $script:SkipStatuses=@{sha=$sha;total_count=0;statuses=@()}|ConvertTo-Json -Depth 15|ConvertFrom-Json
        switch($case){
            required-skip {$script:SkipJobs.jobs[0].conclusion='skipped'}
            required-step-skip {$script:SkipJobs.jobs[0].steps[0].conclusion='skipped'}
            unexpected-skip {$script:SkipChecks.check_runs+=@([pscustomobject]@{id=103;head_sha=$sha;status='completed';conclusion='skipped'});$script:SkipChecks.total_count=3}
            wrong-check-id {$script:SkipChecks.check_runs[1].id=103}
            missing-check {$script:SkipChecks.check_runs=@($script:SkipChecks.check_runs[0]);$script:SkipChecks.total_count=1}
            extra-job {$script:SkipJobs.jobs+=@($script:SkipJobs.jobs[1]);$script:SkipJobs.total_count=3}
            missing-job {$script:SkipJobs.jobs=@($script:SkipJobs.jobs[0]);$script:SkipJobs.total_count=1}
            duplicate-job {$script:SkipJobs.jobs[1].id=12}
            duplicate-check {$script:SkipChecks.check_runs[1].id=101}
            wrong-attempt {$script:SkipJobs.jobs[1].run_attempt=1}
            wrong-run {$script:SkipJobs.jobs[1].run_id=8}
            wrong-sha {$script:SkipJobs.jobs[1].head_sha='d'*40}
            wrong-repo {$script:SkipRuns.workflow_runs[0].repository.full_name='other/repo'}
            wrong-branch {$script:SkipRuns.workflow_runs[0].head_branch='other'}
            wrong-event {$script:SkipRuns.workflow_runs[0].event='push'}
            wrong-workflow {$script:SkipRuns.workflow_runs[0].workflow_id=10}
            truncated-jobs {$script:SkipJobs.total_count=3}
            truncated-checks {$script:SkipChecks.total_count=3}
            truncated-runs {$script:SkipRuns.total_count=2}
            malformed-review {$script:SkipPolicy='{'}
            changed-source {$copy.sources[0].blob='d'*40}
            changed-tree {$copy.treeFingerprint='d'*64}
            missing-rationale {$copy.workflows[0].jobs[1].rationale=''}
            required-skip-steps {$copy.workflows[0].jobs[1].steps=@('Publish')}
            null-skip-steps {$copy.workflows[0].jobs[1].steps=$null}
            missing-skip-steps {$copy.workflows[0].jobs[1].PSObject.Properties.Remove('steps')}
            unknown-disposition {$copy.workflows[0].jobs[1].disposition='optional'}
            array-disposition {$copy.workflows[0].jobs[1].disposition=@('skipped')}
            all-skipped {$copy.workflows[0].jobs=@($copy.workflows[0].jobs[1])}
            branch-unreviewed {$copy.workflows[0].branchEquivalent=$false}
            wrong-destination {$copy.workflows[0].equivalentTo=@('other')}
            duplicate-required-step {$copy.workflows[0].jobs[0].steps=@('Run validation','Run validation')}
            skip-executed {$script:SkipJobs.jobs[1].conclusion='success'}
            skip-has-steps {$script:SkipJobs.jobs[1].steps=@($script:SkipJobs.jobs[0].steps[0])}
            skip-check-success {$script:SkipChecks.check_runs[1].conclusion='success'}
            skip-pending {$script:SkipJobs.jobs[1].status='queued'}
            skip-failure {$script:SkipJobs.jobs[1].conclusion='failure'}
            skip-cancelled {$script:SkipJobs.jobs[1].conclusion='cancelled'}
            future-skip {$script:SkipJobs.jobs[1].completed_at=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')}
            missing-skip-time {$script:SkipJobs.jobs[1].completed_at=$null}
            genuine-failure {$script:SkipRuns.workflow_runs[0].conclusion='failure'}
            genuine-pending {$script:SkipRuns.workflow_runs[0].status='in_progress'}
            legacy-pending {$script:SkipStatuses.statuses=@([pscustomobject]@{context='external';state='pending'});$script:SkipStatuses.total_count=1}
        }
        if($script:SkipPolicy-ne'{'){$script:SkipPolicy=$copy|ConvertTo-Json -Depth 15 -Compress}
        $snapshot=Get-CiRunSnapshot owner/repo $sha fixture main
        Check ('reviewed skip refuses '+$case) ($null-eq$snapshot-or-not$snapshot.AllSuccess)
    }
}
if($RunRegression){
    Set-StrictMode -Version 2.0
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0
    Invoke-CiReviewedSkipRegression (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') -SmokeOnly:$SmokeOnly
    Write-Output "Passed: $script:Pass Failed: $script:Fail"
    exit $script:Fail
}
