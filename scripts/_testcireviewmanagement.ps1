# Shared isolated management fixture; one real Git repository, no network.
param([switch]$RunRegression)
function Invoke-CiReviewManagementRegression {
    param([string]$ToolRoot,[string]$Work)
    . (Join-Path $ToolRoot 'hooks/_hooklib.ps1')
    . (Join-Path $ToolRoot 'scripts/_installlib.ps1')
    . (Join-Path $ToolRoot 'scripts/_installplan.ps1')
    . (Join-Path $ToolRoot 'scripts/_ciworkloadreview.ps1')
    . (Join-Path $ToolRoot 'hooks/Ci-Status-Check/_cireviewed.ps1')
    . (Join-Path $ToolRoot 'hooks/Ci-Status-Check/_cienrollment.ps1')
    $repo=Join-Path $Work 'review-management';[void][IO.Directory]::CreateDirectory($repo)
    foreach($arguments in @(@('init','-q','-b','main'),@('config','user.email','fixture@example.invalid'),@('config','user.name','Fixture'),@('remote','add','origin','https://github.com/owner/repo.git'),@('config','branch.main.remote','origin'),@('config','branch.main.merge','refs/heads/main'))){
        $null=Invoke-QuietCommand git (@('-C',$repo)+$arguments)
        if($LASTEXITCODE-ne0){throw 'Review management Git setup failed'}
    }
    $workflowDir=Join-Path $repo '.github/workflows';[void][IO.Directory]::CreateDirectory($workflowDir)
    [IO.File]::WriteAllText((Join-Path $workflowDir 'ci.yml'),"on: [workflow_dispatch]`njobs:`n  validate:`n    runs-on: ubuntu-latest`n    steps:`n      - name: Validate`n        run: echo fixture`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $repo '.gitignore'),"/.claude/`n/.codex/`n",[Text.UTF8Encoding]::new($false))
    $null=Invoke-QuietCommand git @('-C',$repo,'add','.')
    $null=Invoke-QuietCommand git @('-C',$repo,'commit','-qm','fixture')
    if($LASTEXITCODE-ne0){throw 'Review management commit failed'}
    function Invoke-DocsGit {param($Arguments);Invoke-QuietCommand git $Arguments -TimeoutSeconds 5}
    $sha=[string](Invoke-DocsGit @('-C',$repo,'rev-parse','HEAD'))
    $null=Invoke-QuietCommand git @('-C',$repo,'update-ref','refs/remotes/origin/main',$sha)
    $acquisitionWatch=[Diagnostics.Stopwatch]::StartNew()
    $snapshot=Get-RepositoryAccessSnapshot $repo
    $acquisitionMs=$acquisitionWatch.ElapsedMilliseconds
    Check 'real clean acquisition retains exact identity within unchanged 4000ms budget' ($snapshot.State-ceq'available'-and$snapshot.Fingerprint-ceq(Get-RepositoryIdentityHash ($sha+'|')).Substring(0,10)) ('elapsedMs='+$acquisitionMs+' diagnosis='+$snapshot.Diagnosis)
    Write-Output ('Review fixture acquisition elapsedMs='+$acquisitionMs+' state='+$snapshot.State)
    $tree=@(Invoke-DocsGit @('-C',$repo,'ls-tree','-r',$sha))
    $blob=[string](Invoke-DocsGit @('-C',$repo,'rev-parse',($sha+':.github/workflows/ci.yml')))
    $policy=@{schema=1;repository='owner/repo';rationale='Independent inert workflow review';treeFingerprint=Get-RepositoryIdentityHash ($tree-join"`n");sources=@(@{path='.github/workflows/ci.yml';blob=$blob});workflows=@(@{id=9;path='.github/workflows/ci.yml';event='workflow_dispatch';branch='main';jobs=@(@{name='validate';steps=@('Validate')})})}
    $context=Get-CiEnrollmentContext $repo owner/repo $sha main origin
    Check 'enrollment binds actual Git source and configured remote/ref' ($null-ne$context)
    if($null-eq$context){return}
    $context|Add-Member reviewFingerprint (Get-CiReviewedInputFingerprint ($policy|ConvertTo-Json -Depth 15|ConvertFrom-Json))
    $policy.enrollment=$context
    $json=$policy|ConvertTo-Json -Depth 15
    Check 'enrolled exact-tree review validates through canonical parser' ($null-ne(ConvertFrom-CiReviewedPolicy $json $repo owner/repo $sha main -RuntimeReview))
    foreach($case in @('commit','branch','root','remoteFingerprint','repository')){
        $copy=$json|ConvertFrom-Json
        $copy.enrollment.$case='mismatch'
        Check ('enrollment refuses changed '+$case) ($null-eq(ConvertFrom-CiReviewedPolicy ($copy|ConvertTo-Json -Depth 15) $repo owner/repo $sha main -RuntimeReview))
    }
    $runtime=Join-Path $Work 'review-publication/Ci-Status-Check';[void][IO.Directory]::CreateDirectory($runtime)
    $selection=[pscustomobject]@{Directory=$runtime;PolicyPath=Join-Path $runtime '_ci-policy.json';Record=[pscustomobject]@{id='0123456789'};Client='claude'}
    $submitted=[Text.UTF8Encoding]::new($false).GetBytes($json)
    $published=Publish-CiWorkloadReview $ToolRoot $selection $submitted $json absent { }
    Check 'explicit review publication returns input identity not CI success' ($published.status-ceq'enrolled'-and$published.policyHash-match'^[a-f0-9]{64}$'-and-not$published.PSObject.Properties['results'])
    Check 'submitted review bytes retained for recovery' ((Get-CiReviewBytesHash (Read-CiReviewBytes (Join-Path $published.recoveryPath 'submitted.json')))-ceq(Get-CiReviewBytesHash $submitted))
    $refused=$false;try{$null=Publish-CiWorkloadReview $ToolRoot $selection $submitted $json absent { }}catch{$refused=$true}
    Check 'concurrent preimage conflict preserves current review' ($refused-and(Get-CiReviewBytesHash (Read-CiReviewBytes $selection.PolicyPath))-ceq$published.policyHash)
    $null=Install-PlannedRuntime @((New-PlanArtifact -RelativePath 'Ci-Status-Check/entry.ps1' -Kind Generated -GeneratedContent '# fixture')) (Split-Path -Parent $runtime) 'Ci-Status-Check'
    Check 'supported update preserves enrolled review and recovery bytes' ((Get-CiReviewBytesHash (Read-CiReviewBytes $selection.PolicyPath))-ceq$published.policyHash-and[IO.File]::Exists((Join-Path $published.recoveryPath 'submitted.json')))
    $prior=Read-CiReviewBytes $selection.PolicyPath
    $again=Publish-CiWorkloadReview $ToolRoot $selection $submitted $json $published.policyHash { }
    Check 'replacement preserves previous review independently of runtime' ((Get-CiReviewBytesHash (Read-CiReviewBytes (Join-Path $again.recoveryPath 'previous.json')))-ceq(Get-CiReviewBytesHash $prior))
    . (Join-Path $ToolRoot 'scripts/_installevaluate.ps1')
    $malformed=[pscustomobject]@{friendlyName='Ci-Status-Check';clients=[pscustomobject]@{claude=[pscustomobject]@{installed=$true}}}
    $badStatus=Get-RecordUpdateState $malformed $ToolRoot
    Check 'malformed review record stays a bounded skip, never throws' ($badStatus.Status-ceq'skip')
    $tampered=$json|ConvertFrom-Json;$tampered.workflows[0].jobs[0].steps=@('Different')
    Check 'enrollment detects edited review content' ($null-eq(ConvertFrom-CiReviewedPolicy ($tampered|ConvertTo-Json -Depth 15) $repo owner/repo $sha main -RuntimeReview))
}
if($RunRegression){
    Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0
    $work=New-TestWorkspace -Prefix 'review-management-seam'
    $saved=$env:HOOKMAKER_STATE_DIR
    try{
        $env:HOOKMAKER_STATE_DIR=Join-Path $work 'state';[void][IO.Directory]::CreateDirectory($env:HOOKMAKER_STATE_DIR)
        Invoke-CiReviewManagementRegression (Split-Path -Parent $PSScriptRoot) $work
    }finally{$env:HOOKMAKER_STATE_DIR=$saved;if(-not(Remove-TestWorkspace $work)){$script:Fail++}}
    Write-Output "Passed: $script:Pass Failed: $script:Fail"
    exit $script:Fail
}
