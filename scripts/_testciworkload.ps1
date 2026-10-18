# External API fixture only; no network, repository writes or real success records.
function Invoke-CiWorkloadRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_pathsfilter.ps1')
    $module=Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1'
    if(Test-Path -LiteralPath $module){. $module}else{
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $HooksRoot 'Ci-Status-Check/Ci-Status-Check.ps1'),[ref]$null,[ref]$null)
        $node=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Get-CiRunSnapshot'},$true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $parser=(Get-Command Get-CiWorkloadExpectation).ScriptBlock
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'ls-tree'){return '.github/workflows/ci.yml'}
        return $script:WorkflowSource
    }
    foreach($variant in @('literal','quoted-name','quoted-condition','hidden-mapping')){
        $script:WorkflowSource="on: [workflow_dispatch]`njobs:`n  native:`n    runs-on: windows-latest`n    steps:`n      - name: Setup`n        run: echo setup`n      - name: Run validation`n        run: echo check"
        if($variant-eq'quoted-name'){$script:WorkflowSource=$script:WorkflowSource.Replace('- name: Run validation','- name: "Run validation"')}
        if($variant-eq'quoted-condition'){$script:WorkflowSource+="`n        'if': false"}
        if($variant-eq'hidden-mapping'){$script:WorkflowSource+="`n        with:`n          'if': false"}
        $expectation=& $parser -ProjectRoot 'fixture' -RepoSlug 'owner/repo' -Sha ('a'*40) -Branch main
        Check ('workload source grammar '+$variant) (($null-ne$expectation)-eq($variant-eq'literal'))
    }
    $reviewed=(Get-Command Get-CiReviewedExpectation).ScriptBlock
    $policy=[ordered]@{schema=1;repository='owner/repo';rationale='Exact synthetic source closure reviewed';treeFingerprint=Get-RepositoryIdentityHash '100644 blob bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`t.github/workflows/ci.yml'.Replace('`t',"`t");sources=@(@{path='.github/workflows/ci.yml';blob=('b'*40)});workflows=@(@{path='.github/workflows/ci.yml';id=9;event='workflow_dispatch';branch='main';jobs=@(@{name='native';steps=@('Run validation')})})}
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){return $script:ReviewedJson}
        if($Arguments-contains'rev-parse'){return ('b'*40)}
        if($Arguments-contains'--name-only'){return '.github/workflows/ci.yml'}
        return ("100644 blob "+('b'*40)+"`t.github/workflows/ci.yml")
    }
    foreach($variant in @('exact','wrong-tree','wrong-blob','wrong-repo','branch-string','branch-unbound','branch-reviewed')){
        $copy=($policy|ConvertTo-Json -Depth 10)|ConvertFrom-Json
        if($variant-eq'wrong-tree'){$copy.treeFingerprint='0'*64}
        if($variant-eq'wrong-blob'){$copy.sources[0].blob='0'*40}
        if($variant-eq'wrong-repo'){$copy.repository='other/repo'}
        if($variant-like'branch-*'){
            $copy.workflows[0].branch='feature/proven'
            $copy.workflows[0]|Add-Member branchEquivalent $(if($variant-eq'branch-string'){'false'}else{$true})
            $copy.workflows[0]|Add-Member branchRationale 'All branch-sensitive source dimensions reviewed in synthetic fixture'
            $copy.workflows[0]|Add-Member equivalentTo @($(if($variant-eq'branch-unbound'){'other'}else{'main'}))
        }
        $script:ReviewedJson=$copy|ConvertTo-Json -Depth 12 -Compress
        $result=& $reviewed -ProjectRoot fixture -RepoSlug owner/repo -Sha ('a'*40) -Branch main
        Check ('reviewed workload binding '+$variant) (($null-ne$result)-eq($variant-in@('exact','branch-reviewed')))
    }
    function Test-GhAuthenticated{return $true}
    function Test-CiBillingBlocked{return $false}
    function Get-GhRemainingSeconds{return 30}
    $sha='a'*40;$script:WorkloadCase='bot'
    function Get-CiWorkloadExpectation {
        param($ProjectRoot,$RepoSlug,$Sha,$Branch)
        return [pscustomobject]@{SourceFingerprint=('c'*64);Workflows=@([pscustomobject]@{Path='.github/workflows/ci.yml';Id='9';Event='workflow_dispatch';Branch='main';Jobs=@([pscustomobject]@{Name='native';Steps=@('Run validation')})})}
    }
    function Invoke-GhBounded {
        param([string[]]$ArgumentList)
        $global:LASTEXITCODE=0;$endpoint=$ArgumentList[1]
        $run=@{id=7;workflow_id=9;run_attempt=2;head_sha=$sha;head_repository=@{full_name='owner/repo'};repository=@{full_name='owner/repo'};path='.github/workflows/ci.yml';event='workflow_dispatch';head_branch='main';status='completed';conclusion='success';updated_at='2026-10-17T10:00:00Z'}
        if($script:WorkloadCase-eq'bot'){$run.path='dynamic/dependabot';$run.event='dynamic';$run.workflow_id=10}
        if($script:WorkloadCase-eq'wrong-repo'){$run.head_repository.full_name='other/repo'}
        if($script:WorkloadCase-eq'wrong-sha'){$run.head_sha='d'*40}
        if($script:WorkloadCase-eq'neutral'){$run.conclusion='neutral'}
        if($script:WorkloadCase-eq'api-error'){$global:LASTEXITCODE=1;return ''}
        if($ArgumentList[0]-eq'run'){return (@($run)|ConvertTo-Json -Depth 8 -Compress)}
        if($endpoint-match'/actions/runs\?'){
            if($script:WorkloadCase-like'zero-*'){return '{"total_count":0,"workflow_runs":[]}'}
            $items=@(if($script:WorkloadCase-eq'duplicate'){$run;$run}else{$run})
            return (@{total_count=$(if($script:WorkloadCase-eq'partial'){2}else{$items.Count});workflow_runs=$items}|ConvertTo-Json -Depth 8 -Compress)
        }
        if($endpoint-match'/attempts/2/jobs'){
            $job=@{id=12;check_run_url='https://api.github.com/repos/owner/repo/check-runs/12';run_id=7;run_attempt=2;head_sha=$sha;name='native';status='completed';conclusion='success';completed_at='2026-10-17T09:59:00Z';steps=@(@{number=1;name='Set up job';status='completed';conclusion='success'},@{number=2;name='Run validation';status='completed';conclusion='success';completed_at='2026-10-17T09:58:00Z'})}
            if($script:WorkloadCase-eq'skipped-job'){$job.conclusion='skipped'}
            if($script:WorkloadCase-eq'skipped-step'){$job.steps[1].conclusion='skipped'}
            if($script:WorkloadCase-eq'wrong-attempt'){$job.run_attempt=1}
            if($script:WorkloadCase-eq'missing-step-time'){$job.steps[1].Remove('completed_at')}
            return (@{total_count=$(if($script:WorkloadCase-eq'partial-jobs'){2}else{1});jobs=@($job)}|ConvertTo-Json -Depth 8 -Compress)
        }
        if($endpoint-match'/check-runs') {
            $end=if($script:WorkloadCase-eq'zero-check-pending'){'queued'}else{'completed'}
            $conclusion=if($script:WorkloadCase-eq'zero-check-failed'){'failure'}else{'success'}
            $total=if($script:WorkloadCase-eq'zero-check-partial'){2}else{1}
            return (@{total_count=$total;check_runs=@(@{id=12;head_sha=$sha;status=$end;conclusion=$conclusion})}|ConvertTo-Json -Depth 6 -Compress)
        }
        if($endpoint-match'/status'){
            $items=@(if($script:WorkloadCase-eq'zero-status-failed'){@{context='external';state='failure'}})
            return (@{sha=$sha;total_count=$items.Count;state='pending';statuses=$items}|ConvertTo-Json -Depth 6 -Compress)
        }
        $global:LASTEXITCODE=1;return ''
    }
    foreach($case in @('zero-check-failed','zero-check-pending','zero-check-partial','zero-status-failed','zero-clean','bot','complete','skipped-job','skipped-step','wrong-attempt','wrong-repo','wrong-sha','partial','duplicate','neutral','api-error','partial-jobs','missing-step-time')){
        $script:WorkloadCase=$case
        $snapshot=Get-CiRunSnapshot -RepoSlug 'owner/repo' -Sha $sha
        $green=$null-ne$snapshot-and$snapshot.AllSuccess
        Check ('required workload '+$case) ($green-eq($case-eq'complete'))
        if($case-like'zero-*'){Check ('zero Actions independently verifies checks/statuses '+$case) ($null-ne$snapshot-and$snapshot.CommitChecksSafe-eq($case-eq'zero-clean'))}
        if($case-eq'bot'){Check 'auxiliary-only success leaves documentation route reachable' ($null-ne$snapshot-and$snapshot.Runs.Count-eq0)}
        if($case-eq'complete'){
            $proof=$snapshot.Provenance
            $lines=@($sha,'verified',$proof.observedUtc,'ci-green',($proof|ConvertTo-Json -Depth 10 -Compress))
            Check 'later cleanup cannot refresh required execution preceding local failure' ($null-eq(Read-CiProvenance -Lines $lines -Repository owner/repo -Sha $sha -FailureEndedUtc '2026-10-17T09:58:30Z'))
        }
    }
}
