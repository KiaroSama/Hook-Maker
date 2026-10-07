# Shared repository-state acquisition; hooks and standalone runners use identical bytes.
. (Join-Path $PSScriptRoot '_repositorytrust.ps1')

function Get-RepositoryGitEnvironment {
    param($Identity)
    $values=@{}
    if(-not(Test-RepositoryRootApproval $Identity)){return $values}
    if(-not[string]::IsNullOrWhiteSpace([string]$env:GIT_CONFIG_PARAMETERS)){throw 'Unsupported GIT_CONFIG_PARAMETERS cannot be combined with exact-root approval.'}
    $count=0;$raw=[string]$env:GIT_CONFIG_COUNT
    if($raw-ne''-and(-not[int]::TryParse($raw,[ref]$count)-or$count-lt0-or$count-gt64)){throw 'Git runtime configuration count is invalid or exceeds 64.'}
    for($i=0;$i-lt$count;$i++) {
        $key=[Environment]::GetEnvironmentVariable('GIT_CONFIG_KEY_'+$i)
        $value=[Environment]::GetEnvironmentVariable('GIT_CONFIG_VALUE_'+$i)
        if([string]::IsNullOrWhiteSpace($key)-or$null-eq$value){throw 'Git runtime configuration contains an incomplete pair.'}
        $values['GIT_CONFIG_KEY_'+$i]=$key;$values['GIT_CONFIG_VALUE_'+$i]=$value
    }
    # Reset inherited broad safe.directory values for this child only, then add
    # the explicitly approved root. Unrelated runtime settings are preserved.
    $values['GIT_CONFIG_KEY_'+$count]='safe.directory';$values['GIT_CONFIG_VALUE_'+$count]=''
    $values['GIT_CONFIG_KEY_'+($count+1)]='safe.directory';$values['GIT_CONFIG_VALUE_'+($count+1)]=$Identity.Root
    $values['GIT_CONFIG_COUNT']=[string]($count+2)
    return $values
}

function Get-RepositoryGitDiagnosis {
    param($Result)
    if($null-eq$Result){return 'gitExecutionUnavailable'}
    if($Result.ExitCode-eq124){return 'gitTimedOut'}
    $errorText=[string]$Result.ErrorOutput
    if($errorText-match'dubious ownership|unsafe repository'){return 'dubiousOwnership'}
    if($errorText-match'not a git repository'){return 'nonrepository'}
    if($errorText-match'Permission denied|Access is denied|Operation not permitted'){return 'permissionDenied'}
    return 'gitFailed'
}

function Get-RepositoryAccessSnapshot {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $deadline=[Diagnostics.Stopwatch]::StartNew()
    function Invoke-RepositoryGit {
        param([string[]]$Arguments)
        $remaining=[int][Math]::Floor(4-$deadline.Elapsed.TotalSeconds)
        if($remaining-lt1){return [pscustomobject]@{ExitCode=124;Output='';ErrorOutput=''}}
        return Invoke-QuietCommand -FilePath git -ArgumentList $Arguments -CaptureOutput -Environment $answer.GitEnvironment -TimeoutSeconds $remaining
    }
    $root=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char[]]@('\','/'))
    $answer=[pscustomobject]@{State='unavailable';Fingerprint='';Diagnosis='gitMissing';RepositoryRoot='';GitEnvironment=@{}}
    if($null-eq(Get-Command git -ErrorAction SilentlyContinue)){return $answer}
    foreach($routing in @('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
        if(-not[string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($routing))){$answer.Diagnosis='repositoryRoutingOverride';return $answer}
    }
    try {$physical=Get-RepositoryPhysicalRoot $root} catch {
        $answer.Diagnosis=if($_.Exception -is [UnauthorizedAccessException]){'permissionDenied'}else{'physicalRootUnproven'}
        return $answer
    }
    $candidate=$physical;$repo=''
    $ceilings=@(([string]$env:GIT_CEILING_DIRECTORIES)-split[IO.Path]::PathSeparator|Where-Object{$_})
    while($candidate) {
        if($candidate-ne$physical-and$ceilings-contains$candidate){break}
        if(Test-Path -LiteralPath (Join-Path $candidate '.git')){$repo=$candidate;break}
        $parent=[IO.Directory]::GetParent($candidate);if($null-eq$parent){break};$candidate=$parent.FullName
    }
    $identity=$null
    if($repo-ne'') {
        try {$identity=Get-RepositoryApprovalIdentity $repo;$answer.GitEnvironment=Get-RepositoryGitEnvironment $identity}
        catch {$answer.Diagnosis='repositoryIdentityOrConfigurationInvalid';return $answer}
    }
    $first=Invoke-RepositoryGit -Arguments @('-C',$root,'rev-parse','--show-toplevel')
    if($null-eq$first-or$first.ExitCode-ne0) {
        $answer.Diagnosis=Get-RepositoryGitDiagnosis $first
        if($answer.Diagnosis-eq'nonrepository'-and$repo-eq''){$answer.State='nonrepository'}
        return $answer
    }
    $verifiedRoot=([string]$first.Output).Trim()
    try {$verifiedRoot=Get-RepositoryPhysicalRoot $verifiedRoot} catch {$answer.Diagnosis='physicalRootUnproven';return $answer}
    if($repo-eq''-or-not[string]::Equals($verifiedRoot,$repo,[StringComparison]::OrdinalIgnoreCase)){$answer.Diagnosis='repositoryRootMismatch';return $answer}
    $answer.RepositoryRoot=$verifiedRoot
    $head1=Invoke-RepositoryGit -Arguments @('-C',$root,'rev-parse','HEAD')
    $status1=Invoke-RepositoryGit -Arguments @('-C',$root,'status','--porcelain')
    $head2=Invoke-RepositoryGit -Arguments @('-C',$root,'rev-parse','HEAD')
    $status2=Invoke-RepositoryGit -Arguments @('-C',$root,'status','--porcelain')
    foreach($result in @($head1,$status1,$head2,$status2)){if($null-eq$result-or$result.ExitCode-ne0){$answer.Diagnosis=Get-RepositoryGitDiagnosis $result;return $answer}}
    $head=([string]$head1.Output).Trim()
    $lines1=@([string]$status1.Output-split'\r?\n'|Where-Object{$_}|Sort-Object)
    $lines2=@([string]$status2.Output-split'\r?\n'|Where-Object{$_}|Sort-Object)
    if($head-eq''-or$head-cne([string]$head2.Output).Trim()-or($lines1-join'|')-cne($lines2-join'|')){$answer.Diagnosis='repositoryChanged';return $answer}
    try {$identityAfter=Get-RepositoryApprovalIdentity $repo} catch {$answer.Diagnosis='repositoryChanged';return $answer}
    if($identity.Identity-cne$identityAfter.Identity){$answer.Diagnosis='repositoryChanged';return $answer}
    if($answer.GitEnvironment.Count-gt0-and-not(Test-RepositoryRootApproval $identityAfter)){$answer.Diagnosis='approvalChanged';return $answer}
    $answer.Fingerprint=(Get-RepositoryIdentityHash ($head+'|'+($lines1-join'|'))).Substring(0,10)
    $answer.State='available';$answer.Diagnosis=''
    return $answer
}
