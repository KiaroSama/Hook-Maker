# Positive exact-workload evidence. Unknown metadata is not an empty failure list.
$ciProofRoot = if ([IO.File]::Exists((Join-Path $PSScriptRoot '_ciprovenance.ps1'))) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $ciProofRoot '_ciprovenance.ps1')
. (Join-Path $PSScriptRoot '_cireviewed.ps1')
. (Join-Path $PSScriptRoot '_docsquery.ps1')
. (Join-Path $PSScriptRoot '_cibatch.ps1')
. (Join-Path $PSScriptRoot '_ciliteral.ps1')

function Read-CiWorkloadApi {
    param([string]$Endpoint)
    if((Get-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue)-and$script:CiApiScopeKey-ne''){
        return (Read-CiBatchApi -Endpoint $Endpoint -ScopeKey $script:CiApiScopeKey)
    }
    $raw=@(Invoke-GhBounded -ArgumentList @('api',$Endpoint))-join"`n"
    if($LASTEXITCODE-ne0-or[string]::IsNullOrWhiteSpace($raw)){return $null}
    try{return ($raw|ConvertFrom-Json -ErrorAction Stop)}catch{return $null}
}

function Get-CiWorkloadExpectation {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string]$Branch)
    $reviewed = Get-CiReviewedExpectation -ProjectRoot $ProjectRoot -RepoSlug $RepoSlug -Sha $Sha -Branch $Branch
    if ($null -ne $reviewed) { return $reviewed }
    # Literal unconditional workflows only. Unsupported expansion needs reviewed
    # source-bound expectations, never a guess based on observed successful jobs.
    $paths=@(Invoke-DocsGit -Arguments @('-C',$ProjectRoot,'ls-tree','-r','--name-only',$Sha,'--','.github/workflows'))
    if($LASTEXITCODE-ne0-or$paths.Count-gt50){return $null}
    $workflows=New-Object Collections.Generic.List[object]
    $sources=New-Object Collections.Generic.List[string]
    foreach($path in $paths){
        if($path-cnotmatch'^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$'){return $null}
        $text=@(Invoke-DocsGit -Arguments @('-C',$ProjectRoot,'show',($Sha+':'+$path)))-join"`n"
        if($LASTEXITCODE-ne0-or$text.Length-gt262144){return $null}
        $normalized=$text.Replace("`r`n","`n").TrimEnd("`n")+"`n"
        $stepPattern='      - name: [A-Za-z0-9 _./()-]+\n        run: [^\r\n{}|>&*!]+\n'
        $jobPattern='  [A-Za-z0-9_-]+:\n    runs-on: [A-Za-z0-9_.-]+\n    steps:\n(?:'+$stepPattern+')+'
        if($normalized-cnotmatch('\Aon: \[(?:workflow_dispatch|push)\]\njobs:\n(?:'+$jobPattern+')+\z')){
            $literal=Get-CiLiteralWorkflow -Text $text -Path $path -Branch $Branch
            if($null-eq$literal){return $null}
            $workflows.Add($literal);$sources.Add($path+'|'+$text);continue
        }
        $triggers=@(Get-WorkflowTopTriggers $text)
        $onLines=@($text-split'\r?\n'|Where-Object{$_-cmatch'^on:'})
        if($onLines.Count-ne1-or$onLines[0]-cnotmatch'^on: \[(workflow_dispatch|push)\]$'){return $null}
        if($triggers.Count-eq1-and$triggers[0]-ceq'workflow_call'){return $null}
        if($triggers.Count-ne1-or@($triggers|Where-Object{$_-cnotin@('workflow_dispatch','push')}).Count){return $null}
        # Preserve the original tiny grammar's name-based evidence contract.
        $jobs=New-Object Collections.Generic.List[object]
        $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($block in [regex]::Matches($normalized,$jobPattern)){
            $name=([regex]::Match($block.Value,'\A  ([A-Za-z0-9_-]+):')).Groups[1].Value
            if(-not$names.Add($name)){return $null}
            $steps=@([regex]::Matches($block.Value,'(?m)^      - name: ([A-Za-z0-9 _./()-]+)$')|ForEach-Object{$_.Groups[1].Value})
            if(@($steps|Select-Object -Unique).Count-ne$steps.Count-or@($steps|Where-Object{$_-cin@('Set up job','Complete job')-or$_-cmatch'^(Post|Pre) '}).Count){return $null}
            $jobs.Add([pscustomobject]@{Name=$name;Steps=$steps})
        }
        $event=if($triggers-ccontains'workflow_dispatch'){'workflow_dispatch'}elseif($triggers-ccontains'push'){'push'}else{'pull_request'}
        $workflows.Add([pscustomobject]@{Path=$path;Id='';Event=$event;Branch=$Branch;Jobs=$jobs.ToArray()})
        $sources.Add($path+'|'+$text)
    }
    if($workflows.Count-eq0){return $null}
    return [pscustomobject]@{SourceFingerprint=Get-RepositoryIdentityHash ($sources.ToArray()-join"`n");Workflows=$workflows.ToArray()}
}

function Get-CiRunSnapshot {
    param([string]$RepoSlug,[string]$Sha,[string]$ProjectRoot='',[string]$Branch='')
    try {
    if($null-eq(Get-Command gh -ErrorAction SilentlyContinue)){return $null}
    if((Get-Command Test-GhAuthenticated -ErrorAction SilentlyContinue)-and-not(Test-GhAuthenticated)){return $null}
    if($ProjectRoot-eq''){$ProjectRoot=(Get-Location).Path}
    $runEndpoint='repos/'+$RepoSlug+'/actions/runs?head_sha='+$Sha+'&per_page=50'
    $checkEndpoint='repos/'+$RepoSlug+'/commits/'+$Sha+'/check-runs?filter=latest&per_page=100'
    $statusEndpoint='repos/'+$RepoSlug+'/commits/'+$Sha+'/status?per_page=100'
    if((Get-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue)-and$script:CiApiScopeKey-ne''){
        $prefetched=Invoke-CiApiBatch -Endpoints @($runEndpoint,$checkEndpoint,$statusEndpoint) -ScopeKey $script:CiApiScopeKey
        if($null-eq$prefetched){return $null}
    }
    $doc=Read-CiWorkloadApi $runEndpoint
    if($null-eq$doc-or$null-eq(Get-Field $doc 'total_count')-or$null-eq$doc.PSObject.Properties['workflow_runs']){return $null}
    $all=@($doc.workflow_runs|Where-Object{$null-ne$_})
    if($all.Count-gt50-or$all.Count-ne$doc.total_count){return $null}
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($run in $all){
        if([string](Get-Field $run 'id')-cnotmatch'^[1-9][0-9]*$'-or-not$seen.Add([string]$run.id)-or
            [string](Get-Field $run 'workflow_id')-cnotmatch'^[1-9][0-9]*$'-or
            [string](Get-Field $run 'run_attempt')-cnotmatch'^[1-9][0-9]*$'-or
            [string](Get-Field $run 'head_sha')-cne$Sha-or
            [string](Get-Field (Get-Field $run 'head_repository') 'full_name')-ine$RepoSlug-or
            [string](Get-Field (Get-Field $run 'repository') 'full_name')-ine$RepoSlug-or
            [string]::IsNullOrWhiteSpace([string](Get-Field $run 'path'))-or
            [string]::IsNullOrWhiteSpace([string](Get-Field $run 'event'))-or
            [string]::IsNullOrWhiteSpace([string](Get-Field $run 'head_branch'))){return $null}
    }
    $project=@($all|Where-Object{[string]$_.path-cmatch'^\.github/workflows/[^/]+\.ya?ml$'})
    $auxiliary=@($all|Where-Object{[string]$_.path-cnotmatch'^\.github/workflows/[^/]+\.ya?ml$'})
    $pending=New-Object Collections.Generic.List[string];$failed=New-Object Collections.Generic.List[string]
    $infra=New-Object Collections.Generic.List[string];$parts=New-Object Collections.Generic.List[string]
    foreach($run in $all){
        $entry='run '+$run.id
        $parts.Add(([string]$run.id+'|'+$run.run_attempt+'|'+$run.path+'|'+$run.status+'|'+$run.conclusion))
        if($run.status-cne'completed'){$pending.Add($entry)}
        elseif($run.conclusion-cin@('failure','startup_failure')){$failed.Add($entry)}
        elseif($run.conclusion-cne'success'){$infra.Add($entry+' ['+$run.conclusion+']')}
    }
    $expected=$null
    if($project.Count-gt0){$expected=Get-CiWorkloadExpectation -ProjectRoot $ProjectRoot -RepoSlug $RepoSlug -Sha $Sha -Branch $Branch}
    $proven=$null-ne$expected;$proofRuns=New-Object Collections.Generic.List[object]
    $requiredCheckIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $skippedCheckIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $oldest=[DateTimeOffset]::MaxValue
    if($proven){
        if((Get-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue)-and$script:CiApiScopeKey-ne''){
            $jobEndpoints=@(foreach($workflow in @($expected.Workflows)){
                $matched=@($project|Where-Object{$_.path-ceq$workflow.Path-and$_.event-ceq$workflow.Event-and$_.head_branch-ceq$workflow.Branch-and($workflow.Id-eq''-or[string]$_.workflow_id-ceq[string]$workflow.Id)}|Sort-Object {[long]$_.id} -Descending)
                if($matched.Count-and$matched[0].status-ceq'completed'-and$matched[0].conclusion-ceq'success'){
                    'repos/'+$RepoSlug+'/actions/runs/'+$matched[0].id+'/attempts/'+$matched[0].run_attempt+'/jobs?per_page=100'
                }
            })
            if($jobEndpoints.Count-and$null-eq(Invoke-CiApiBatch -Endpoints $jobEndpoints -ScopeKey $script:CiApiScopeKey)){return $null}
        }
        foreach($workflow in @($expected.Workflows)){
            $matching=@($project|Where-Object{$_.path-ceq$workflow.Path-and$_.event-ceq$workflow.Event-and$_.head_branch-ceq$workflow.Branch-and($workflow.Id-eq''-or[string]$_.workflow_id-ceq[string]$workflow.Id)}|Sort-Object {[long]$_.id} -Descending)
            if($matching.Count-eq0){$proven=$false;continue}
            $run=$matching[0]
            if($run.status-cne'completed'-or$run.conclusion-cne'success'){$proven=$false;continue}
            $jobsDoc=Read-CiWorkloadApi ('repos/'+$RepoSlug+'/actions/runs/'+$run.id+'/attempts/'+$run.run_attempt+'/jobs?per_page=100')
            if($null-eq$jobsDoc-or$null-eq(Get-Field $jobsDoc 'total_count')-or$null-eq$jobsDoc.PSObject.Properties['jobs']){$proven=$false;continue}
            $jobs=@($jobsDoc.jobs|Where-Object{$null-ne$_})
            if($jobs.Count-eq0-or$jobs.Count-gt100-or$jobs.Count-ne$jobsDoc.total_count-or$jobs.Count-ne@($workflow.Jobs).Count){$proven=$false;continue}
            $jobIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $jobNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $legKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $runEnd=[DateTimeOffset]::MaxValue
            foreach($job in $jobs){
                $required=@($workflow.Jobs|Where-Object{
                    if($_.PSObject.Properties['MainSteps']){
                        $labels=@(Get-Field $job 'labels')
                        $labels.Count-eq1-and$_.Labels.Count-eq1-and$labels[0]-ceq$_.Labels[0]
                    }else{$_.Name-ceq$job.name}
                })
                if($required.Count-ne1-or-not$jobNames.Add([string]$job.name)-or[string]$job.id-cnotmatch'^[1-9][0-9]*$'-or-not$jobIds.Add([string]$job.id)-or
                    [string]$job.run_id-cne[string]$run.id-or[string]$job.run_attempt-cne[string]$run.run_attempt-or
                    $job.head_sha-cne$Sha-or$job.status-cne'completed'){$proven=$false;continue}
                $skip=(Get-Field $required[0] 'disposition')-ceq'skipped'
                if(($skip-and($job.conclusion-cne'skipped'-or$job.steps-isnot[Array]-or$job.steps.Count-ne0))-or
                    (-not$skip-and$job.conclusion-cne'success')){$proven=$false;continue}
                if($required[0].PSObject.Properties['MainSteps']){
                    if(-not$legKeys.Add(($required[0].Labels-join'|'))-or-not(Test-CiLiteralJobSteps $required[0] $job)){$proven=$false;continue}
                }
                $checkUrl=[string](Get-Field $job 'check_run_url')
                $checkPrefix='https://api.github.com/repos/'+$RepoSlug+'/check-runs/'
                if(-not$checkUrl.StartsWith($checkPrefix,[StringComparison]::OrdinalIgnoreCase)-or
                    $checkUrl.Substring($checkPrefix.Length)-cnotmatch'^[1-9][0-9]*$'-or
                    -not$requiredCheckIds.Add($checkUrl.Substring($checkPrefix.Length))){$proven=$false;continue}
                $end=ConvertTo-CiUtcTime (Get-Field $job 'completed_at')
                if($null-eq$end-or$end-gt[DateTimeOffset]::UtcNow){$proven=$false;continue}
                if($skip){
                    # Only this exact attempt's validated job can authorize its
                    # correlated skipped check. It supplies no execution freshness.
                    [void]$skippedCheckIds.Add($checkUrl.Substring($checkPrefix.Length))
                    continue
                }
                # A later unrelated job/cleanup cannot refresh an earlier validation.
                if($end-lt$runEnd){$runEnd=$end}
                $steps=@(Get-Field $job 'steps')
                $numbers=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                foreach($step in $steps){if([string]$step.number-cnotmatch'^[1-9][0-9]*$'-or-not$numbers.Add([string]$step.number)-or$step.status-cne'completed'-or$step.conclusion-cnotin@('success','skipped')){$proven=$false}}
                foreach($name in @($required[0].Steps)){
                    $actual=@($steps|Where-Object{$_.name-ceq$name})
                    if($actual.Count-ne1-or$actual[0].status-cne'completed'-or$actual[0].conclusion-cne'success'){$proven=$false;continue}
                    $stepEnd=ConvertTo-CiUtcTime (Get-Field $actual[0] 'completed_at')
                    if($null-eq$stepEnd-or$stepEnd-gt$end){$proven=$false;continue}
                    if($stepEnd-lt$runEnd){$runEnd=$stepEnd}
                }
            }
            if($runEnd-eq[DateTimeOffset]::MaxValue){$proven=$false;continue}
            if($runEnd-lt$oldest){$oldest=$runEnd}
            $proofRuns.Add([ordered]@{id=$run.id;attempt=$run.run_attempt;workflowId=$run.workflow_id;path=$run.path;event=$run.event;branch=$run.head_branch;completedUtc=$runEnd.ToString('o')})
        }
    }
    $checksComplete=$false
    $commitChecksSafe=$false
    $checkFingerprint=''
    # Check/status evidence exists independently of Actions, including a zero-run
    # documentation commit. Never let an absent workflow hide a failing check.
    $checks=Read-CiWorkloadApi ('repos/'+$RepoSlug+'/commits/'+$Sha+'/check-runs?filter=latest&per_page=100')
    $status=Read-CiWorkloadApi ('repos/'+$RepoSlug+'/commits/'+$Sha+'/status?per_page=100')
    if($null-eq$checks-or$null-eq$status-or$null-eq(Get-Field $checks 'total_count')-or$null-eq$checks.PSObject.Properties['check_runs']-or
        $null-eq(Get-Field $status 'total_count')-or$null-eq$status.PSObject.Properties['statuses']-or(Get-Field $status 'sha')-cne$Sha){$proven=$false}
    else{
        $cr=@($checks.check_runs);$st=@($status.statuses)
        $checksComplete=$cr.Count-le100-and$cr.Count-eq$checks.total_count-and$st.Count-le100-and$st.Count-eq$status.total_count
        $commitChecksSafe=$checksComplete
        $checkIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $checkParts=New-Object Collections.Generic.List[string]
        foreach($check in $cr){
            if([string](Get-Field $check 'id')-cnotmatch'^[1-9][0-9]*$'-or-not$checkIds.Add([string](Get-Field $check 'id'))-or(Get-Field $check 'head_sha')-cne$Sha){$checksComplete=$false;$commitChecksSafe=$false}
            $expectedConclusion=if($skippedCheckIds.Contains([string](Get-Field $check 'id'))){'skipped'}else{'success'}
            if((Get-Field $check 'status')-cne'completed'-or(Get-Field $check 'conclusion')-cne$expectedConclusion){$commitChecksSafe=$false}
            $checkParts.Add('check|'+(Get-Field $check 'id')+'|'+(Get-Field $check 'status')+'|'+(Get-Field $check 'conclusion'))
        }
        foreach($requiredId in $requiredCheckIds){if(-not$checkIds.Contains($requiredId)){$proven=$false}}
        $contexts=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($state in $st){
            if([string]::IsNullOrWhiteSpace([string](Get-Field $state 'context'))-or-not$contexts.Add([string](Get-Field $state 'context'))){$checksComplete=$false;$commitChecksSafe=$false}
            if((Get-Field $state 'state')-cne'success'){$commitChecksSafe=$false}
            $checkParts.Add('status|'+(Get-Field $state 'context')+'|'+(Get-Field $state 'state'))
        }
        [string[]]$checkOrder=$checkParts.ToArray();[Array]::Sort($checkOrder,[StringComparer]::Ordinal)
        $checkFingerprint=Get-RepositoryIdentityHash ($checkOrder-join"`n")
        if(-not$commitChecksSafe-or$cr.Count-eq0){$proven=$false}
    }
    $billing=@()
    if($failed.Count-gt0-and(Get-Command Test-CiBillingBlocked -ErrorAction SilentlyContinue)-and(Test-CiBillingBlocked -RepoSlug $RepoSlug -Sha $Sha)){$billing=$failed.ToArray();$failed.Clear()}
    if($proven-and$proofRuns.Count-ne@($expected.Workflows).Count){$proven=$false}
    $allSuccess=$proven-and$project.Count-gt0-and$pending.Count-eq0-and$failed.Count-eq0-and$infra.Count-eq0-and$billing.Count-eq0
    [string[]]$orderedParts=$parts.ToArray();[Array]::Sort($orderedParts,[StringComparer]::Ordinal)
    $fingerprint=Get-RepositoryIdentityHash (($orderedParts-join"`n")+'|'+$checkFingerprint)
    $provenance=$null
    if($allSuccess){$provenance=[pscustomobject]@{schema=1;repository=$RepoSlug;sha=$Sha;outcome='ci-green';observedUtc=[DateTimeOffset]::UtcNow.ToString('o');completedUtc=$oldest.ToString('o');workloadFingerprint=$fingerprint;sourceFingerprint=$expected.SourceFingerprint;runs=$proofRuns.ToArray()}}
    return [pscustomobject]@{Runs=$project;AuxiliaryRuns=$auxiliary;PendingRuns=$pending.ToArray();FailedRuns=$failed.ToArray();InfraRuns=$infra.ToArray();BillingRuns=$billing;Fingerprint=$fingerprint;AllSuccess=$allSuccess;Provenance=$provenance;ChecksComplete=$checksComplete;CommitChecksSafe=$commitChecksSafe}
    } catch { return $null }
}
