# Explicit enrollment of independently reviewed input, not observed CI outcomes.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{10}$')][string]$RecordId,
    [Parameter(Mandatory=$true)][ValidateSet('claude','codex')][string]$Client,
    [Parameter(Mandatory=$true)][string]$PolicyPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory=$true)][ValidatePattern('^(?:[a-f0-9]{40}|[a-f0-9]{64})$')][string]$Commit,
    [Parameter(Mandatory=$true)][ValidatePattern('^[^\s\x00-\x1f]+$')][string]$Branch,
    [Parameter(Mandatory=$true)][ValidatePattern('^(?:absent|[a-f0-9]{64})$')][string]$ExpectedPolicyHash,
    [switch]$Apply,[switch]$ReviewConfirmed
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$toolRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'hooks/_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installlib.ps1')
. (Join-Path $PSScriptRoot '_installplan.ps1')
. (Join-Path $PSScriptRoot '_managementaudit.ps1')
. (Join-Path $PSScriptRoot '_ciworkloadreview.ps1')
. (Join-Path $toolRoot 'hooks/Ci-Status-Check/_cireviewed.ps1')
. (Join-Path $toolRoot 'hooks/Ci-Status-Check/_cienrollment.ps1')
$script:ReviewDeadline=[DateTime]::UtcNow.AddSeconds(40)
$script:ReviewGitEnvironment=@{}
$script:ReviewApproval=$null
function Invoke-DocsGit {
    param([string[]]$Arguments)
    $remaining=[int][Math]::Floor(($script:ReviewDeadline-[DateTime]::UtcNow).TotalMilliseconds)
    if($remaining-lt1){throw 'Review validation deadline exhausted.'}
    if($null-ne$script:ReviewApproval){
        $currentApproval=Get-RepositoryApprovalIdentity $script:ReviewApproval.Root
        if($currentApproval.Identity-cne$script:ReviewApproval.Identity-or-not(Test-RepositoryRootApproval $currentApproval)){throw 'Repository approval changed during review.'}
    }
    $result=Invoke-QuietCommand git $Arguments -CaptureOutput -Environment $script:ReviewGitEnvironment -TimeoutMilliseconds ([Math]::Min(5000,$remaining))
    if($null-eq$result-or$result.ExitCode-ne0){$global:LASTEXITCODE=1;return @()}
    if($result.Output.Length-gt1048576){throw 'Review evidence exceeds 1 MiB.'}
    $global:LASTEXITCODE=0
    return @($result.Output-split'\r?\n'|Where-Object{$_-ne''})
}
$phase='selection'
try{
    Start-ManagementAudit -ToolRoot $toolRoot -Name 'Set-CiWorkloadReview'
    if($Apply-and-not$ReviewConfirmed){throw 'Apply requires ReviewConfirmed after independent review of source and context.'}
    $selection=Get-CiReviewSelection $toolRoot $RecordId $Client
    $phase='repository-context'
    $root=Get-RepositoryPhysicalRoot $selection.Record.targetProjectRoot
    $access=Get-RepositoryAccessSnapshot $root
    if($access.State-cne'available'){throw 'Repository identity unavailable; use the supported exact-root approval flow if required.'}
    $script:ReviewGitEnvironment=$access.GitEnvironment
    if($access.GitEnvironment.Count-gt0){$script:ReviewApproval=Get-RepositoryApprovalIdentity $root}
    $phase='input-review'
    $submitted=Read-CiReviewBytes ([IO.Path]::GetFullPath($PolicyPath))
    $policy=[Text.UTF8Encoding]::new($false,$true).GetString($submitted).TrimStart([char]0xfeff)|ConvertFrom-Json
    if($policy.schema-notin@(1,3)-or$policy.PSObject.Properties['enrollment']){throw 'Supply a fresh independently reviewed exact-tree schema1 or schema3 policy without enrollment.'}
    $remote=@(Invoke-DocsGit @('-C',$root,'config','--get',('branch.'+$Branch+'.remote')))
    if($LASTEXITCODE-ne0-or$remote.Count-ne1){throw 'Configured branch remote is unavailable.'}
    $pushed=@(Invoke-DocsGit @('-C',$root,'rev-parse','--verify','@{upstream}'))
    if($LASTEXITCODE-ne0-or$pushed.Count-ne1-or$pushed[0]-cne$Commit){throw 'Exact source must match the selected branch upstream.'}
    $context=Get-CiEnrollmentContext $root $Repository $Commit $Branch $remote[0]
    if($null-eq$context){throw 'Exact current repository/source/branch/remote context differs.'}
    foreach($field in @('results','runs','checks','outcome','observedUtc','completedUtc','provenance')){if($policy.PSObject.Properties[$field]){throw 'Execution results are forbidden in input review.'}}
    $context|Add-Member reviewFingerprint (Get-CiReviewedInputFingerprint $policy)
    $policy|Add-Member enrollment $context
    $json=$policy|ConvertTo-Json -Depth 30
    $expectation=ConvertFrom-CiReviewedPolicy $json $root $Repository $Commit $Branch -RuntimeReview
    if($null-eq$expectation){throw 'Reviewed source/tree/workflow/job/step contract is invalid or stale. Review changes; do not refresh identities automatically.'}
    $phase='workflow-identity'
    foreach($workflow in @($expectation.Workflows)){
        $remaining=[int][Math]::Floor(($script:ReviewDeadline-[DateTime]::UtcNow).TotalMilliseconds)
        if($remaining-lt1){throw 'Review workflow identity deadline exhausted.'}
        $response=Invoke-QuietCommand gh @('api',('repos/'+$Repository+'/actions/workflows/'+$workflow.id)) -CaptureOutput -TimeoutMilliseconds ([Math]::Min(5000,$remaining))
        if($null-eq$response-or$response.ExitCode-ne0-or$response.Output.Length-gt65536){throw 'Workflow identity API unavailable; no review enrolled.'}
        $actual=$response.Output|ConvertFrom-Json
        if([string]$actual.id-cne[string]$workflow.id-or$actual.path-cne$workflow.path){throw 'Workflow identity does not match reviewed source.'}
    }
    $phase='preimage'
    $prior=Read-CiReviewBytes $selection.PolicyPath -Optional
    if((Get-CiReviewBytesHash $prior)-cne$ExpectedPolicyHash){throw 'Review preimage differs; inspect the selected runtime policy.'}
    if(-not$Apply){
        Write-Output ('Review preview valid; selected record='+$RecordId+'; client='+$Client+'; no files changed. Apply requires ReviewConfirmed.')
        Write-ManagementAudit -Event 'review-preview' -Data @{recordId=$RecordId;client=$Client;commit=$Commit}
        exit 0
    }
    $revalidate={
        $fresh=Get-CiReviewSelection $toolRoot $RecordId $Client
        if($fresh.Directory-cne$selection.Directory-or$fresh.MetadataHash-cne$selection.MetadataHash){throw 'Selected runtime changed during review.'}
        if(-not(Test-CiEnrollmentBinding $context $root $Repository $Commit $Branch)){throw 'Repository context changed during review.'}
        if($null-eq(ConvertFrom-CiReviewedPolicy $json $root $Repository $Commit $Branch -RuntimeReview)){throw 'Source review changed during validation.'}
    }
    $phase='publication'
    $result=Publish-CiWorkloadReview $toolRoot $selection $submitted $json $ExpectedPolicyHash $revalidate
    Write-ManagementAudit -Event 'review-enrolled' -Data @{recordId=$RecordId;client=$Client;commit=$Commit;policyHash=$result.policyHash}
    Write-Output ('Reviewed input enrolled; no CI result stored. policyHash='+$result.policyHash)
    exit 0
}catch{
    Write-ManagementAudit -Event 'review-refused' -Data @{recordId=$RecordId;client=$Client;reason='Validation or atomic publication failed';exitCode=1}
    [Console]::Error.WriteLine(('CI workload review refused at '+$phase+'. Verify the selected record/client, exact source/context and expected policy hash; inspect read-only workflow access if needed. Original review/recovery data was preserved; no CI result was stored.'))
    exit 1
}
