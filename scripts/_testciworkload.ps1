# Offline API controls plus one inert owned large Git tree; no real success records.
param([switch]$RunRegression)
function Invoke-CiWorkloadHostRegression {
    param([string]$HooksRoot,[string]$Work)
    Invoke-CiWorkloadRegression $HooksRoot
    & {param($Root,$Temp);Invoke-CiLargeReviewedTreeRegression $Root $Temp} $HooksRoot $Work
    $output=Join-Path $Work 'workload51.out';$errorFile=Join-Path $Work 'workload51.err'
    $helper=Join-Path $PSScriptRoot '_testciworkload.ps1'
    $result=Start-BoundedProcess -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$helper,'-RunRegression') -TimeoutMs 30000 -RedirectStandardOutput $output -RedirectStandardError $errorFile
    Check 'Framework executes source and raw matrix workload controls' ($result.ExitCode-eq0) ([IO.File]::ReadAllText($output,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($errorFile,[Text.Encoding]::UTF8))
}
function Invoke-CiLiteralMatrixRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot '_scope.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciworkload.ps1')
    function Get-CiReviewedExpectation { return $null }
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'ls-tree'){return '.github/workflows/ci.yml'}
        return $script:MatrixSource
    }
    $script:MatrixSource=@'
name: CI
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  core:
    strategy:
      fail-fast: false
      matrix:
        os: [windows-latest, ubuntu-24.04]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - run: echo validate
      - name: Linux validation
        if: runner.os == 'Linux'
        run: |
          echo linux
          echo check
'@
    $result=Get-CiWorkloadExpectation fixture owner/repo ('a'*40) main
    Check 'literal matrix derives two source legs without observed job names' ($null-ne$result-and@($result.Workflows[0].Jobs).Count-eq2)
    if($null-eq$result){return}
    $jobs=@($result.Workflows[0].Jobs)
    Check 'literal matrix binds exact labels and source conditional step' ($jobs[1].Labels[0]-ceq'ubuntu-24.04'-and$jobs[1].MainSteps[2].Required-and-not$jobs[0].MainSteps[2].Required)
    $expected=$jobs[1]
    $observed=[pscustomobject]@{steps=@(
        [pscustomobject]@{number=1;name='Set up job';status='completed';conclusion='success'},
        [pscustomobject]@{number=2;name=('Run actions/checkout@'+('a'*40));status='completed';conclusion='success'},
        [pscustomobject]@{number=3;name='Run echo validate';status='completed';conclusion='success'},
        [pscustomobject]@{number=4;name='Linux validation';status='completed';conclusion='success'},
        [pscustomobject]@{number=30;name=('Post Run actions/checkout@'+('a'*40));status='completed';conclusion='success'},
        [pscustomobject]@{number=31;name='Complete job';status='completed';conclusion='success'})}
    foreach($shape in @('complete','missing','skipped-required','executed-false','reordered','injected','duplicate','pre-step')){
        $copy=$observed|ConvertTo-Json -Depth 8|ConvertFrom-Json
        switch($shape){
            missing {$copy.steps=@($copy.steps|Where-Object{$_.name-cne'Run echo validate'})}
            skipped-required {$copy.steps[2].conclusion='skipped'}
            executed-false {$expected=$jobs[0]}
            reordered {$copy.steps[1].number=3;$copy.steps[2].number=2}
            injected {$copy.steps[2].name='unexpected validation'}
            duplicate {$copy.steps+=@($copy.steps[2])}
            pre-step {$copy.steps+=@([pscustomobject]@{number=0;name='Pre Run other/action@sha';status='completed';conclusion='success'})}
        }
        Check ('literal ordered execution binding '+$shape) ((Test-CiLiteralJobSteps $expected $copy)-eq($shape-eq'complete'))
        $expected=$jobs[1]
    }
    $named=$observed|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $named.steps[1].name='Checkout';$named.steps[4].name='Post Checkout'
    $namedExpected=$jobs[1]|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $namedExpected.MainSteps[0].Name='Checkout'
    Check 'explicit action display name binds its own post cleanup' (Test-CiLiteralJobSteps $namedExpected $named)
    foreach($variant in @('include','dynamic','job-condition','unknown-step','continue','duplicate-os','branch-step','quoted-condition','reserved-setup','reserved-complete','reserved-post')){
        $saved=$script:MatrixSource
        switch($variant){
            include {$script:MatrixSource=$saved.Replace('        os:',"        include: []`n        os:")}
            dynamic {$script:MatrixSource=$saved.Replace('[windows-latest, ubuntu-24.04]','${{ fromJSON(inputs.os) }}')}
            job-condition {$script:MatrixSource=$saved.Replace('    strategy:',"    if: false`n    strategy:")}
            unknown-step {$script:MatrixSource=$saved.Replace('      - run: echo validate',"      - run: echo validate`n        mysterious: true")}
            continue {$script:MatrixSource=$saved.Replace('      - run: echo validate',"      - run: echo validate`n        continue-on-error: true")}
            duplicate-os {$script:MatrixSource=$saved.Replace('ubuntu-24.04','windows-latest')}
            branch-step {$script:MatrixSource=$saved.Replace("runner.os == 'Linux'","github.ref == 'refs/heads/main'")}
            quoted-condition {$script:MatrixSource=$saved.Replace('        if:',"        'if':")}
            reserved-setup {$script:MatrixSource=$saved.Replace('Linux validation','Set up job')}
            reserved-complete {$script:MatrixSource=$saved.Replace('Linux validation','Complete job')}
            reserved-post {$script:MatrixSource=$saved.Replace('Linux validation','Post Run other/action@sha')}
        }
        $unsupported=Get-CiWorkloadExpectation fixture owner/repo ('a'*40) main
        Check ('literal matrix refuses unsupported '+$variant) ($null-eq$unsupported)
        $script:MatrixSource=$saved
    }
}
function Invoke-CiLargeReviewedTreeRegression {
    param([string]$HooksRoot,[string]$Work)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    $repo=Join-Path $Work 'large-reviewed-tree';[void][IO.Directory]::CreateDirectory($repo)
    $null=Invoke-QuietCommand git @('-C',$repo,'init','-q','-b','main')
    if($LASTEXITCODE-ne0){throw 'Large review fixture init failed'}
    $inputPath=Join-Path $Work 'large-tree.import'
    $writer=[IO.StreamWriter]::new($inputPath,$false,[Text.UTF8Encoding]::new($false))
    try{
        $writer.Write("blob`nmark :1`ndata 1`nx`ncommit refs/heads/main`ncommitter Fixture <fixture@example.invalid> 1700000000 +0000`ndata 7`nfixture`n")
        $writer.Write("M 100644 :1 .github/workflows/ci.yml`n")
        # Bound sibling lookup cost in fast-import without shrinking the >1MiB tree.
        for($i=0;$i-lt7000;$i++){$writer.Write('M 100644 :1 unrelated/'+([int][Math]::Floor($i/70)).ToString('D3')+'/'+('x'*150)+$i.ToString('D5')+".txt`n")}
        $writer.Write("`ndone`n")
    }finally{$writer.Dispose()}
    $out=Join-Path $Work 'large-tree.out';$err=Join-Path $Work 'large-tree.err'
    $import=Start-BoundedProcess -FilePath git -ArgumentList @('-C',$repo,'fast-import','--quiet') -RedirectStandardInput $inputPath -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 15000
    if($import.ExitCode-ne0){throw 'Large review fixture import failed'}
    $sha=(@(Invoke-QuietCommand git @('-C',$repo,'rev-parse','HEAD'))-join'').Trim()
    $tree=(@(Invoke-QuietCommand git @('-C',$repo,'rev-parse',($sha+'^{tree}')))-join'').Trim()
    $blob=(@(Invoke-QuietCommand git @('-C',$repo,'rev-parse',($sha+':.github/workflows/ci.yml')))-join'').Trim()
    $copyDir=Join-Path $Work 'review-module';[void][IO.Directory]::CreateDirectory($copyDir)
    Copy-Item -LiteralPath (Join-Path $HooksRoot 'Ci-Status-Check/_cireviewed.ps1') -Destination (Join-Path $copyDir '_cireviewed.ps1')
    . (Join-Path $copyDir '_cireviewed.ps1')
    $policy=@{schema=3;repository='owner/repo';rationale='Whole immutable tree and explicit branch context reviewed';objectFormat='sha1';tree=$tree;sources=@(@{path='.github/workflows/ci.yml';mode='100644';blob=$blob});contextReview=@{};workflows=@(@{path='.github/workflows/ci.yml';id=9;event='workflow_dispatch';branch='feature/deleted';branchEquivalent=$true;branchRationale='Synthetic fixture has no branch-sensitive inputs';equivalentTo=@('main');jobs=@(@{name='native';steps=@('Validate')})})}
    foreach($dimension in @('conditions','checkout','scripts','envInputs','permissionsSecrets','artifactsCache','concurrency','dependencies')){$policy.contextReview[$dimension]='Reviewed inert fixture '+$dimension}
    function Invoke-DocsGit {param($Arguments);Invoke-QuietCommand -FilePath git -ArgumentList $Arguments -TimeoutSeconds 5}
    foreach($case in @('exact','wrong-tree','wrong-mode','wrong-blob','wrong-destination','missing-context')){
        $copy=$policy|ConvertTo-Json -Depth 12|ConvertFrom-Json
        if($case-eq'wrong-tree'){$copy.tree='f'*40}
        if($case-eq'wrong-mode'){$copy.sources[0].mode='100755'}
        if($case-eq'wrong-blob'){$copy.sources[0].blob='f'*40}
        if($case-eq'wrong-destination'){$copy.workflows[0].equivalentTo=@('other')}
        if($case-eq'missing-context'){$copy.contextReview.PSObject.Properties.Remove('scripts')}
        [IO.File]::WriteAllText((Join-Path $copyDir '_ci-policy.json'),($copy|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
        $result=Get-CiReviewedExpectation $repo owner/repo $sha main
        Check ('large real tracked tree reviewed binding '+$case) (($null-ne$result)-eq($case-eq'exact'))
    }
    # 7000 paths alone have >1MiB of literal path bytes, without blob metadata.
    Check 'large fixture is genuinely above old textual tree limit' ((7000*(150+10))-gt1048576)
}
function Invoke-CiReviewedTreeRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_cireviewed.ps1')
    if(-not(Get-Command Test-CiReviewedTreeBinding -ErrorAction SilentlyContinue)){
        Check 'exact reviewed tree does not require unrelated tree enumeration' $false
        return
    }
    $review=@{schema=3;repository='owner/repo';objectFormat='sha1';tree=('c'*40);sources=@(@{path='.github/workflows/ci.yml';mode='100644';blob=('b'*40)});contextReview=@{}}
    foreach($dimension in @('conditions','checkout','scripts','envInputs','permissionsSecrets','artifactsCache','concurrency','dependencies')){$review.contextReview[$dimension]='Explicit immutable-source review of '+$dimension}
    $script:TreeCase='exact';$script:TreeFullReads=0
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'--show-object-format=storage'){if($script:TreeCase-eq'exact-sha256'){return 'sha256'};return 'sha1'}
        if($Arguments-contains'rev-parse'){
            if($script:TreeCase-eq'wrong-tree'){return ('d'*40)}
            if($script:TreeCase-eq'query-failed'){$global:LASTEXITCODE=124;return @()}
            if($script:TreeCase-eq'exact-sha256'){return ('c'*64)}
            return ('c'*40)
        }
        $script:TreeFullReads++;$global:LASTEXITCODE=124;return @()
    }
    foreach($case in @('exact','exact-sha256','wrong-tree','wrong-format','missing-context','query-failed','wrong-length','results')){
        $script:TreeCase=$case;$copy=$review|ConvertTo-Json -Depth 8|ConvertFrom-Json
        if($case-eq'exact-sha256'){$copy.objectFormat='sha256';$copy.tree='c'*64}
        if($case-eq'wrong-format'){$copy.objectFormat='sha256'}
        if($case-eq'missing-context'){$copy.contextReview.PSObject.Properties.Remove('checkout')}
        if($case-eq'wrong-length'){$copy.tree='c'*39}
        if($case-eq'results'){$copy|Add-Member results @{success=$true}}
        $shaLength=if($case-eq'exact-sha256'){64}else{40}
        $ok=Test-CiReviewedTreeBinding fixture ('a'*$shaLength) $copy
        Check ('exact reviewed tree binding '+$case) ($ok-eq($case-in@('exact','exact-sha256')))
    }
    Check 'tree binding never requests whole textual tree listing' ($script:TreeFullReads-eq0)
}
function Invoke-CiReviewedSourceRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_cireviewed.ps1')
    $script:SourceCase='exact'
    $script:FullTreeReads=0
    $script:SourcePolicy=@{schema=2;repository='owner/repo';rationale='Synthetic bounded source review';sources=@(@{path='.github/workflows/ci.yml';blob=('b'*40)});closure=@{candidates=@();documents=@('README.md');sourceBranches=@('main');destinationBranches=@('main')};workflows=@(@{path='.github/workflows/ci.yml';id=9;event='workflow_dispatch';branch='main';jobs=@(@{name='native';steps=@('Run validation')})})}|ConvertTo-Json -Depth 12 -Compress
    function Test-CiReviewedClosure { return $script:SourceCase-ne'closure-refused' }
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){return $script:SourcePolicy}
        if($Arguments-contains'--name-only'){return '.github/workflows/ci.yml'}
        if($Arguments.Count-eq5){$script:FullTreeReads++;$global:LASTEXITCODE=124;return @()}
        if($script:SourceCase-eq'query-failed'){$global:LASTEXITCODE=124;return @()}
        if($script:SourceCase-eq'missing'){return @()}
        $row='100644 blob '+('b'*40)+"`t.github/workflows/ci.yml"
        if($script:SourceCase-eq'wrong-blob'){$row=$row.Replace(('b'*40),('c'*40))}
        if($script:SourceCase-eq'duplicate'){return @($row,$row)}
        return $row
    }
    foreach($case in @('exact','missing','wrong-blob','duplicate','query-failed','closure-refused')){
        $script:SourceCase=$case
        $result=Get-CiReviewedExpectation fixture owner/repo ('a'*40) main
        Check ('reviewed selected source binding '+$case) (($null-ne$result)-eq($case-eq'exact'))
    }
    Check 'schema2 source selection does not read unrelated full tree before independent inventory validation' ($script:FullTreeReads-eq0)
}
function Invoke-CiWorkloadRegression {
    param([string]$HooksRoot)
    & {param($Root,$Helper);. $Helper;Invoke-CiReviewedSkipRegression $Root} $HooksRoot (Join-Path $PSScriptRoot '_testcireviewedskips.ps1')
    & { param($Root); Invoke-CiReviewedTreeRegression $Root } $HooksRoot
    & { param($Root); Invoke-CiReviewedSourceRegression $Root } $HooksRoot
    & { param($Root); Invoke-CiLiteralMatrixRegression $Root } $HooksRoot
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
        $expectedJobs=@([pscustomobject]@{Name='native';Steps=@('Run validation')})
        if($script:WorkloadCase-like'matrix-*'){
            $expectedJobs=@(foreach($label in @('windows-latest','ubuntu-24.04','macos-15')){
                [pscustomobject]@{Name='core';Labels=@($label);Steps=@('Run validation');MainSteps=@([pscustomobject]@{Name='Run validation';Required=$true;Uses=''})}
            })
        }
        return [pscustomobject]@{SourceFingerprint=('c'*64);Workflows=@([pscustomobject]@{Path='.github/workflows/ci.yml';Id='9';Event='workflow_dispatch';Branch='main';Jobs=$expectedJobs})}
    }
    function Invoke-GhBounded {
        param([string[]]$ArgumentList)
        $global:LASTEXITCODE=0;$endpoint=$ArgumentList[1]
        $run=@{id=7;workflow_id=9;run_attempt=2;head_sha=$sha;head_repository=@{full_name='owner/repo'};repository=@{full_name='owner/repo'};path='.github/workflows/ci.yml';event='workflow_dispatch';head_branch='main';status='completed';conclusion='success';updated_at='2026-10-17T10:00:00Z'}
        if($script:WorkloadCase-eq'bot'){$run.path='dynamic/dependabot';$run.event='dynamic';$run.workflow_id=10}
        if($script:WorkloadCase-eq'wrong-repo'){$run.head_repository.full_name='other/repo'}
        if($script:WorkloadCase-eq'wrong-sha'){$run.head_sha='d'*40}
        if($script:WorkloadCase-eq'matrix-wrong-branch'){$run.head_branch='feature/unreviewed'}
        if($script:WorkloadCase-eq'matrix-wrong-event'){$run.event='push'}
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
            if($script:WorkloadCase-like'matrix-*'){
                $items=@(for($leg=0;$leg-lt3;$leg++){
                    $copy=$job|ConvertTo-Json -Depth 8|ConvertFrom-Json
                    $copy.id=12+$leg;$copy.check_run_url='https://api.github.com/repos/owner/repo/check-runs/'+(12+$leg)
                    $copy.name='hosted implicit '+$leg
                    $copy|Add-Member labels @(@('windows-latest','ubuntu-24.04','macos-15')[$leg])
                    $copy
                })
                if($script:WorkloadCase-eq'matrix-missing'){$items=@($items[0],$items[1])}
                if($script:WorkloadCase-eq'matrix-duplicate-label'){$items[2].labels=@('windows-latest')}
                if($script:WorkloadCase-eq'matrix-wrong-attempt'){$items[2].run_attempt=1}
                if($script:WorkloadCase-eq'matrix-skipped'){$items[2].steps[1].conclusion='skipped'}
                if($script:WorkloadCase-eq'matrix-failed'){$items[2].conclusion='failure'}
                if($script:WorkloadCase-eq'matrix-extra'){$items+=@($items[2])}
                if($script:WorkloadCase-eq'matrix-wrong-sha'){$items[2].head_sha='f'*40}
                return (@{total_count=3;jobs=$items}|ConvertTo-Json -Depth 10 -Compress)
            }
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
            $checkRows=@(@{id=12;head_sha=$sha;status=$end;conclusion=$conclusion})
            if($script:WorkloadCase-like'matrix-*'){$checkRows=@(foreach($id in @(12,13,14)){@{id=$id;head_sha=$sha;status='completed';conclusion='success'}});$total=3}
            return (@{total_count=$total;check_runs=$checkRows}|ConvertTo-Json -Depth 6 -Compress)
        }
        if($endpoint-match'/status'){
            $items=@(if($script:WorkloadCase-eq'zero-status-failed'){@{context='external';state='failure'}}elseif($script:WorkloadCase-in@('zero-status-pending','matrix-pending-status')){@{context='external';state='pending'}})
            return (@{sha=$sha;total_count=$items.Count;state='pending';statuses=$items}|ConvertTo-Json -Depth 6 -Compress)
        }
        $global:LASTEXITCODE=1;return ''
    }
    foreach($case in @('matrix-wrong-branch','matrix-wrong-event','matrix-complete','matrix-missing','matrix-duplicate-label','matrix-wrong-attempt','matrix-skipped','matrix-extra','matrix-failed','matrix-wrong-sha','matrix-pending-status','zero-status-pending','zero-check-failed','zero-check-pending','zero-check-partial','zero-status-failed','zero-clean','bot','complete','skipped-job','skipped-step','wrong-attempt','wrong-repo','wrong-sha','partial','duplicate','neutral','api-error','partial-jobs','missing-step-time')){
        $script:WorkloadCase=$case
        $snapshot=Get-CiRunSnapshot -RepoSlug 'owner/repo' -Sha $sha
        $green=$null-ne$snapshot-and$snapshot.AllSuccess
        Check ('required workload '+$case) ($green-eq($case-in@('complete','matrix-complete')))
        if($case-like'zero-*'){Check ('zero Actions independently verifies checks/statuses '+$case) ($null-ne$snapshot-and$snapshot.CommitChecksSafe-eq($case-eq'zero-clean'))}
        if($case-eq'bot'){Check 'auxiliary-only success leaves documentation route reachable' ($null-ne$snapshot-and$snapshot.Runs.Count-eq0)}
        if($case-eq'complete'){
            $proof=$snapshot.Provenance
            $lines=@($sha,'verified',$proof.observedUtc,'ci-green',($proof|ConvertTo-Json -Depth 10 -Compress))
            Check 'later cleanup cannot refresh required execution preceding local failure' ($null-eq(Read-CiProvenance -Lines $lines -Repository owner/repo -Sha $sha -FailureEndedUtc '2026-10-17T09:58:30Z'))
        }
    }
}
if($RunRegression){
    Set-StrictMode -Version 2.0
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0
    Invoke-CiWorkloadRegression (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks')
    Write-Output "Passed: $script:Pass Failed: $script:Fail"
    exit $script:Fail
}
