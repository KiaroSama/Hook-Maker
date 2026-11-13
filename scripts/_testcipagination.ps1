# Offline collection/output contract; isolated workspace, no network/subprocess/CI result.
function Invoke-CiPagedSnapshotRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1')
    function gh { throw 'Offline snapshot must not invoke GitHub.' }
    function Test-GhAuthenticated { return $true }
    function Test-CiBillingBlocked { return $false }
    $savedScope=Get-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue
    $savedScopeValue=if($null-ne$savedScope){$savedScope.Value}else{''}
    $script:CiApiScopeKey=''
    try {
    $script:PagedSnapshotSha='a'*40
    $script:PagedSnapshotCase='complete'
    function Get-CiWorkloadExpectation {
        return [pscustomobject]@{SourceFingerprint=('c'*64);Workflows=@([pscustomobject]@{
            Path='.github/workflows/ci.yml';Id='9';Event='workflow_dispatch';Branch='main'
            Jobs=@(1..100|ForEach-Object{[pscustomobject]@{Name=('job-'+$_);Steps=@('Validate')}})
        })}
    }
    function Read-CiWorkloadApi {
        param([string]$Endpoint)
        $page=1;if($Endpoint-match'&page=(\d+)$'){$page=[int]$Matches[1]}
        if($Endpoint-match'/actions/runs\?'){
            $rows=@(for($id=($page-1)*50+1;$id-le[Math]::Min($page*50,51);$id++){
                $project=$id-eq51
                [pscustomobject]@{id=$id;workflow_id=$(if($project){9}else{10});run_attempt=2;head_sha=$script:PagedSnapshotSha
                    head_repository=[pscustomobject]@{full_name='owner/repo'};repository=[pscustomobject]@{full_name='owner/repo'}
                    path=$(if($project){'.github/workflows/ci.yml'}else{'dynamic/dependabot'});
                    event=$(if($project){'workflow_dispatch'}else{'dynamic'});head_branch='main';status='completed';conclusion='success'}
            })
            return [pscustomobject]@{total_count=51;workflow_runs=$rows}
        }
        if($Endpoint-match'/attempts/2/jobs'){
            $rows=@(for($id=1;$id-le100;$id++){
                [pscustomobject]@{id=$id;run_id=51;run_attempt=2;head_sha=$script:PagedSnapshotSha;name=('job-'+$id)
                    check_run_url=('https://api.github.com/repos/owner/repo/check-runs/'+$id)
                    status='completed';conclusion='success';completed_at='2026-10-17T10:00:00Z'
                    steps=@([pscustomobject]@{number=1;name='Validate';status='completed';conclusion='success';completed_at='2026-10-17T09:59:00Z'})}
            })
            switch($script:PagedSnapshotCase){
                'wrong-attempt' {$rows[99].run_attempt=1}
                'wrong-sha' {$rows[99].head_sha='b'*40}
                'cancelled' {$rows[99].conclusion='cancelled'}
                'timed-out' {$rows[99].conclusion='timed_out'}
                'required-skip' {$rows[99].steps[0].conclusion='skipped'}
                'missing-job' {$rows=@($rows[0..98])}
            }
            return [pscustomobject]@{total_count=100;jobs=$rows}
        }
        if($Endpoint-match'/check-runs'){
            $rows=@(for($id=($page-1)*100+1;$id-le[Math]::Min($page*100,101);$id++){
                [pscustomobject]@{id=$id;head_sha=$script:PagedSnapshotSha;status='completed';conclusion='success'}
            })
            if($page-eq2-and$script:PagedSnapshotCase-eq'missing-check'){$rows=@()}
            return [pscustomobject]@{total_count=101;check_runs=$rows}
        }
        if($Endpoint-match'/status'){return [pscustomobject]@{sha=$script:PagedSnapshotSha;total_count=0;statuses=@()}}
        throw 'Unexpected offline endpoint.'
    }
    foreach($case in @('complete','wrong-attempt','wrong-sha','cancelled','timed-out','required-skip','missing-job','missing-check')){
        $script:PagedSnapshotCase=$case
        $snapshot=Get-CiRunSnapshot owner/repo $script:PagedSnapshotSha fixture main
        Check ('paged workload snapshot '+$case) (($null-ne$snapshot-and$snapshot.AllSuccess)-eq($case-eq'complete'))
        if($case-eq'complete'){
            Check 'paged snapshot binds final-page project run and all checks' ($null-ne$snapshot-and$snapshot.ChecksComplete-and$snapshot.Provenance.runs.Count-eq1-and$snapshot.Provenance.runs[0].id-eq51-and$snapshot.Provenance.runs[0].attempt-eq2)
        }
    }
    } finally {
        if($null-ne$savedScope){$script:CiApiScopeKey=$savedScopeValue}
        else{Remove-Variable CiApiScopeKey -Scope Script -ErrorAction SilentlyContinue}
    }
}
function Invoke-CiPaginationRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1')
    $reader=Get-Command Read-CiWorkloadCollection -ErrorAction SilentlyContinue
    if($null-eq$reader){Check 'complete bounded CI pagination exists' $false;return}
    $script:PageCase='complete';$script:PageCalls=0
    function Read-CiWorkloadApi {
        param([string]$Endpoint)
        $script:PageCalls++
        $page=1;if($Endpoint-match'&page=(\d+)$'){$page=[int]$Matches[1]}
        if($script:PageCase-eq'api'-and$page-eq2){return $null}
        $total=101
        if($script:PageCase-eq'overflow'){$total=3201}
        if($script:PageCase-eq'changing'-and$page-eq2){$total=102}
        if($script:PageCase-eq'fractional'){$total=100.5}
        if($script:PageCase-eq'zero'){$total=0}
        $items=@(if($total-gt0){
            $last=[Math]::Min($page*100,$total)
            for($id=($page-1)*100+1;$id-le$last;$id++){[pscustomobject]@{id=$id;context=('case-'+$id)}}
        })
        if($script:PageCase-eq'duplicate'-and$page-eq2){$items[0].id=1;$items[0].context='case-1'}
        if($script:PageCase-eq'missing'-and$page-eq2){$items=@()}
        if($script:PageCase-eq'overfull'-and$page-eq1){$items+=@([pscustomobject]@{id=102;context='case-102'})}
        $doc=[pscustomobject]@{total_count=$total;sha=('a'*40);jobs=$items;statuses=$items}
        if($script:PageCase-eq'oversized'){$doc|Add-Member padding ('x'*1048577)}
        if($script:PageCase-eq'wrong-sha'-and$page-eq2){$doc.sha='b'*40}
        if($script:PageCase-eq'malformed'){$doc.PSObject.Properties.Remove('total_count')}
        if($script:PageCase-eq'null-row'){$doc.jobs=@($null)}
        return $doc
    }
    foreach($case in @('complete','zero','duplicate','missing','changing','api','overflow','fractional','overfull','malformed','null-row','oversized')){
        $script:PageCase=$case;$script:PageCalls=0
        $result=Read-CiWorkloadCollection -Endpoint 'repos/owner/repo/actions/runs/7/attempts/2/jobs?per_page=100' -Field jobs
        $valid=$null-ne$result
        Check ('bounded CI pages '+$case) ($valid-eq($case-in@('complete','zero')))
        if($case-eq'complete'){Check 'full collection includes second page' ($result.jobs.Count-eq101-and$result.jobs[100].id-eq101-and$script:PageCalls-eq2)}
        if($case-eq'overflow'){Check 'overflow stops before extra page requests' ($script:PageCalls-eq1)}
    }
    foreach($case in @('complete','duplicate','wrong-sha')){
        $script:PageCase=$case;$script:PageCalls=0
        $result=Read-CiWorkloadCollection -Endpoint ('repos/owner/repo/commits/'+('a'*40)+'/status?per_page=100') -Field statuses -IdentityField context -Sha ('a'*40)
        Check ('status pages retain context and exact SHA '+$case) (($null-ne$result)-eq($case-eq'complete'))
    }
    # Job success is execution evidence, never suite/case or UI verification.
    $visibility=Get-Command Get-CiVisibilityReminder -ErrorAction SilentlyContinue
    Check 'execution proof has separate complete visibility guidance' ($null-ne$visibility)
    if($null-ne$visibility){
        $text=Get-CiVisibilityReminder ('a'*40)
        Check 'visibility requires full reporting owner before all-test claims, separate from execution proof' ($text.Contains(('a'*40))-and$text.Contains('CI execution verified: ')-and$text.Contains('global-github-automation-rules.md Section8 FULL before all-test claim')-and$text.Contains('Reports/UI UNVERIFIED')-and$text.Contains('reporter cannot hide failure'))
    }
    # Exercise both real output adapters and reservation deduplication without
    # another hook process; the existing suite owns this isolated workspace.
    $work=New-TestWorkspace -Prefix 'ci-visibility-output'
    try {
        foreach($client in @('claude','codex')){
            $input=[pscustomobject]@{cwd=$work;session_id=('visibility-'+$client);hook_event_name='Stop';client=$client}
            $savedClient=$env:HOOKMAKER_CLIENT;$env:HOOKMAKER_CLIENT=$client
            $capture=New-Object IO.StringWriter;$previous=[Console]::Out
            try {
                [Console]::SetOut($capture)
                Write-CiVisibilityReminder $input ('a'*40) $work Stop
                $first=$capture.ToString();$capture.GetStringBuilder().Clear()|Out-Null
                Write-CiVisibilityReminder $input ('a'*40) $work Stop
                Check ('visibility repeats stay silent '+$client) ($capture.ToString()-eq'')
            }finally{[Console]::SetOut($previous);$env:HOOKMAKER_CLIENT=$savedClient}
            $wire=$first|ConvertFrom-Json
            Check ('visibility uses one passive complete JSON '+$client) ($wire.systemMessage.Contains(('a'*40))-and$null-eq$wire.PSObject.Properties['decision']-and$null-eq$wire.PSObject.Properties['hookSpecificOutput'])
            $key=Get-ShortHash (Normalize-Path $work).ToLowerInvariant()
            [IO.File]::WriteAllText((Join-Path $work ('CiStatusCheck-Visibility-'+$key+'.claims.json')),'{',[Text.UTF8Encoding]::new($false))
            $capture=New-Object IO.StringWriter;$previous=[Console]::Out
            $savedClient=$env:HOOKMAKER_CLIENT;$env:HOOKMAKER_CLIENT=$client
            try {
                [Console]::SetOut($capture)
                Write-CiVisibilityReminder $input ('a'*40) $work Stop
                $failedClaim=$capture.ToString()
            }finally{[Console]::SetOut($previous);$env:HOOKMAKER_CLIENT=$savedClient}
            $unknown=$null;try{$unknown=$failedClaim|ConvertFrom-Json}catch{}
            Check ('failed reservation retains explicit visibility gap '+$client) ($null-ne$unknown-and$unknown.systemMessage.Contains(('a'*40))-and$unknown.systemMessage.Contains('UNVERIFIED')-and$unknown.systemMessage.Contains('reservation')-and$null-eq$unknown.PSObject.Properties['decision'])
            [IO.File]::Delete((Join-Path $work ('CiStatusCheck-Visibility-'+$key+'.claims.json')))
        }
    }finally{if(-not(Remove-TestWorkspace $work)){throw 'Visibility workspace cleanup failed.'}}
}
