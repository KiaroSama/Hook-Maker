# Explicit multi-root input review; optional archive bytes stay source-bound.
# Only Git/API transport is synthetic. The production validator is unchanged.
function Invoke-CiReviewedRootsRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1')
    $sha='a'*40
    $definitions=@(
        @{File='tests';Count=11},@{File='lint';Count=1},
        @{File='analysis';Count=1},@{File='secrets';Count=1},
        @{File='container';Count=3},@{File='archive';Count=0})
    $sources=@();$rows=@();$workflows=@();$runs=@();$jobDocuments=@{};$checks=@()
    $ordinal=0
    foreach($definition in $definitions){
        $ordinal++;$path='.github/workflows/'+$definition.File+'.yml'
        $blob=(Get-RepositoryIdentityHash $definition.File).Substring(0,40)
        $sources+=@{path=$path;blob=$blob}
        $rows+="100644 blob $blob`t$path"
        if($definition.Count-eq0){continue}
        $steps=@('Checkout','Validate','Build')
        $expected=@();$jobs=@()
        for($i=0;$i-lt$definition.Count;$i++){
            $id=100*$ordinal+$i;$name=$definition.File+' '+$i
            $expected+=@{name=$name;steps=$steps}
            $jobs+=@{id=$id;run_id=$ordinal;run_attempt=1;head_sha=$sha;name=$name;status='completed';conclusion='success';check_run_url=('https://api.github.com/repos/owner/repo/check-runs/'+$id);completed_at='2026-10-17T10:00:00Z';steps=@(
                for($n=0;$n-lt$steps.Count;$n++){@{number=$n+1;name=$steps[$n];status='completed';conclusion='success';completed_at='2026-10-17T09:59:00Z'}})}
            $checks+=@{id=$id;head_sha=$sha;status='completed';conclusion='success'}
        }
        $workflows+=@{id=$ordinal;path=$path;event='workflow_dispatch';branch='main';jobs=$expected}
        $runs+=@{id=$ordinal;workflow_id=$ordinal;run_attempt=1;head_sha=$sha;repository=@{full_name='owner/repo'};head_repository=@{full_name='owner/repo'};path=$path;event='workflow_dispatch';head_branch='main';status='completed';conclusion='success'}
        $jobDocuments[[string]$ordinal]=@{total_count=$jobs.Count;jobs=$jobs}
    }
    $tree=$rows-join"`n"
    $policy=@{schema=1;repository='owner/repo';rationale='Five mandatory validation roots; archive is opt-in production, not validation; every workflow blob remains bound';treeFingerprint=Get-RepositoryIdentityHash $tree;sources=$sources;workflows=$workflows}
    $baseline=@{policy=$policy;runs=@{total_count=5;workflow_runs=$runs};jobs=$jobDocuments;checks=@{total_count=17;check_runs=$checks};statuses=@{sha=$sha;total_count=0;statuses=@()}}|ConvertTo-Json -Depth 25
    $script:RootsSourceTree=$tree
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){return ($script:RootsData.policy|ConvertTo-Json -Depth 20)}
        if($Arguments-contains'--name-only'){return @($sources|ForEach-Object{$_.path})}
        if($script:RootsCase-eq'changed-archive'){return @($script:RootsSourceTree.Replace($sources[-1].blob,('f'*40))-split"`n")}
        return @($script:RootsSourceTree-split"`n")
    }
    function Test-GhAuthenticated {return $true}
    function Test-CiBillingBlocked {return $false}
    function Read-CiWorkloadApi {
        param($Endpoint)
        if($Endpoint-match'/actions/runs\?'){return $script:RootsData.runs}
        if($Endpoint-match'/actions/runs/([0-9]+)/attempts/1/jobs'){return $script:RootsData.jobs.PSObject.Properties[$Matches[1]].Value}
        if($Endpoint-match'/check-runs'){return $script:RootsData.checks}
        if($Endpoint-match'/status'){return $script:RootsData.statuses}
        return $null
    }
    foreach($case in @('valid','new-sha-old-execution','new-sha-exact-execution','changed-archive','missing-workflow','missing-job','failed-step','wrong-repository','wrong-attempt','truncated-jobs','truncated-checks','pending')){
        $script:RootsCase=$case;$script:RootsData=$baseline|ConvertFrom-Json
        $requested=$sha
        switch($case){
            new-sha-old-execution {$requested='d'*40}
            new-sha-exact-execution {
                $requested='d'*40
                foreach($run in $script:RootsData.runs.workflow_runs){$run.head_sha=$requested}
                foreach($document in $script:RootsData.jobs.PSObject.Properties){foreach($job in $document.Value.jobs){$job.head_sha=$requested}}
                foreach($check in $script:RootsData.checks.check_runs){$check.head_sha=$requested}
                $script:RootsData.statuses.sha=$requested
            }
            missing-workflow {$script:RootsData.runs.workflow_runs=@($script:RootsData.runs.workflow_runs|Select-Object -Skip 1);$script:RootsData.runs.total_count--}
            missing-job {$script:RootsData.jobs.'1'.jobs=@($script:RootsData.jobs.'1'.jobs|Select-Object -Skip 1);$script:RootsData.jobs.'1'.total_count--}
            failed-step {$script:RootsData.jobs.'1'.jobs[0].steps[1].conclusion='failure'}
            wrong-repository {$script:RootsData.runs.workflow_runs[0].repository.full_name='foreign/repo'}
            wrong-attempt {$script:RootsData.jobs.'1'.jobs[0].run_attempt=2}
            truncated-jobs {$script:RootsData.jobs.'1'.total_count++}
            truncated-checks {$script:RootsData.checks.total_count++}
            pending {$script:RootsData.runs.workflow_runs[0].status='in_progress'}
        }
        $result=Get-CiRunSnapshot owner/repo $requested fixture main
        $valid=$case-in@('valid','new-sha-exact-execution')
        Check ('five reviewed roots17jobs '+$case) (($null-ne$result-and$result.AllSuccess)-eq$valid)
        if($valid-and$null-ne$result){
            Check 'optional archive is bound input, not fabricated execution' (@($result.Provenance.runs).Count-eq5-and$result.Provenance.sha-ceq$requested)
        }
        if($case-eq'pending'){
            Check 'actual pending stays distinct from missing workload review' ($null-ne$result-and$result.PendingRuns.Count-eq1-and$result.WorkloadReason-eq'')
        }
    }
}
