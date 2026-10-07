# Public repository-state/approval seam; one isolated Git fixture, no real trust.
function Invoke-RepositoryAccessRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    $work = New-TestWorkspace -Prefix 'hookmaker-repository-access'
    $savedGlobal=$env:GIT_CONFIG_GLOBAL;$savedSystem=$env:GIT_CONFIG_SYSTEM
    $savedOwner=$env:GIT_TEST_ASSUME_DIFFERENT_OWNER; $savedState=$env:HOOKMAKER_STATE_DIR
    $savedCount=$env:GIT_CONFIG_COUNT; $savedKey=$env:GIT_CONFIG_KEY_0; $savedValue=$env:GIT_CONFIG_VALUE_0
    try {
        $emptyConfig=Join-Path $work 'empty-git-config';Write-Utf8 $emptyConfig ''
        $env:GIT_CONFIG_GLOBAL=$emptyConfig;$env:GIT_CONFIG_SYSTEM=$emptyConfig
        $repo=Join-Path $work ('approved root '+[char]0x03A9); [void][IO.Directory]::CreateDirectory($repo)
        & git -C $repo init -q -b main
        & git -C $repo config user.email 't@t'; & git -C $repo config user.name 't'
        Write-Utf8 (Join-Path $repo 'readme.txt') 'original'
        & git -C $repo add .; & git -C $repo commit -q -m initial
        $ordinary=Get-RepoStateFingerprint $repo
        $env:HOOKMAKER_STATE_DIR=Join-Path $work 'state'
        $env:GIT_TEST_ASSUME_DIFFERENT_OWNER='1'
        $env:GIT_CONFIG_COUNT='1';$env:GIT_CONFIG_KEY_0='safe.directory';$env:GIT_CONFIG_VALUE_0='unapproved-fixture-root'
        $denied=Get-RepositoryStateEvidence $repo
        Check 'unapproved ownership has precise sanitized diagnosis and no binding' ($denied.State-eq'unavailable'-and$denied.BindingFingerprint-eq''-and [string](Get-Field $denied 'Diagnosis')-eq'dubiousOwnership')
        $setter=Get-Command Set-RepositoryRootApproval -ErrorAction SilentlyContinue
        Check 'explicit owner approval interface exists' ($null-ne$setter)
        if($null-eq$setter){return}
        Set-RepositoryRootApproval -ProjectRoot $repo -Approve -OwnerConfirmed
        $approved=Get-RepositoryStateEvidence $repo
        Check 'approved exact root preserves independently obtained state fingerprint' ($approved.State-eq'available'-and$approved.BindingFingerprint-eq$ordinary)
        $other=Join-Path $work 'unapproved root';[void][IO.Directory]::CreateDirectory($other)
        & git -c ('safe.directory='+$other) -C $other init -q -b main
        $otherState=Get-RepositoryStateEvidence $other
        Check 'approval never trusts sibling repository' ($otherState.State-eq'unavailable'-and$otherState.BindingFingerprint-eq'')
        $child=Join-Path $repo 'child.ps1';$receipt=Join-Path $work 'runner-result.json'
        Write-Utf8 $child "`$ErrorActionPreference='Stop'; & git rev-parse --is-inside-work-tree; exit `$LASTEXITCODE"
        $binding=(Get-RepositoryStateEvidence $repo).BindingFingerprint
        $runner=Join-Path $Root 'scripts/Run-Tests-Guarded.ps1'
        $argv=@('-NoProfile','-File',$runner,'-WorkingDirectory',$repo,'-FilePath','pwsh','-ArgumentsJson',('["-NoProfile","-File","'+$child.Replace('\','\\')+'"]'),'-ProjectFingerprint',$binding,'-ResultPath',$receipt,'-Quiet','-TimeoutSeconds','20','-IdleTimeoutSeconds','10')
        $output=Invoke-QuietCommand -FilePath pwsh -ArgumentList $argv -TimeoutSeconds 30 -CaptureOutput
        $doc=Read-JsonFile $receipt
        Check 'guarded child inherits only approved command-scoped Git access' ($null-ne$output-and$output.ExitCode-eq0-and$null-ne$doc-and$doc.overall-eq'ok'-and$doc.exitCode-eq0) ($output.Output+$output.ErrorOutput)
        $beforeFiles=@(Get-ChildItem $work -Recurse -File|ForEach-Object FullName)
        $stale=@($argv);$stale[[Array]::IndexOf($stale,'-ProjectFingerprint')+1]='unchecked-state'
        $output=Invoke-QuietCommand -FilePath pwsh -ArgumentList $stale -TimeoutSeconds 15 -CaptureOutput
        Check 'unchecked runner state refuses before creating any evidence or capture' ($null-ne$output-and$output.ExitCode-eq3-and(@(Get-ChildItem $work -Recurse -File|ForEach-Object FullName)-join'|')-ceq($beforeFiles-join'|')) ($output|ConvertTo-Json -Compress)
        $savedGitParams=$env:GIT_CONFIG_PARAMETERS
        try {
            $env:GIT_CONFIG_COUNT='2';$env:GIT_CONFIG_KEY_1='core.quotepath';$env:GIT_CONFIG_VALUE_1='false'
            $withExisting=Get-RepositoryStateEvidence $repo
            Check 'unrelated existing runtime config is preserved with exact approval' ($withExisting.State-eq'available'-and$withExisting.GitEnvironment.GIT_CONFIG_KEY_1-eq'core.quotepath'-and$withExisting.GitEnvironment.GIT_CONFIG_VALUE_1-eq'false')
            $env:GIT_CONFIG_COUNT='invalid'
            Check 'malformed inherited runtime config remains unavailable' ((Get-RepositoryStateEvidence $repo).State-eq'unavailable')
        } finally {$env:GIT_CONFIG_COUNT='1';$env:GIT_CONFIG_KEY_1=$null;$env:GIT_CONFIG_VALUE_1=$null;$env:GIT_CONFIG_PARAMETERS=$savedGitParams}
        $script:GuardedRunnerRoot=Join-Path $Root 'scripts';$WorkingDirectory=$repo;$ProjectFingerprint=(Get-RepositoryStateEvidence $repo).BindingFingerprint
        $script:Result=[pscustomobject]@{workingDirectory='';repositoryState='';repositoryRoot=''}
        . (Join-Path $Root 'scripts/_guardedrepository.ps1')
        Set-RepositoryRootApproval -ProjectRoot $repo -Revoke
        $refused=$false;try{Set-GuardedRepositoryEnvironment (New-Object Diagnostics.ProcessStartInfo)}catch{$refused=$true}
        Check 'approval revoked after preflight cannot reach actual child environment' $refused
        Check 'revocation immediately restores ownership refusal' ((Get-RepositoryStateEvidence $repo).State-eq'unavailable')
        Set-RepositoryRootApproval -ProjectRoot $repo -Approve -OwnerConfirmed
        [IO.Directory]::Move((Join-Path $repo '.git'),(Join-Path $work 'old-git'))
        & git -c ('safe.directory='+$repo) -C $repo init -q -b main
        Check 'replaced repository metadata cannot inherit old approval' (-not(Test-RepositoryRootApproval (Get-RepositoryApprovalIdentity $repo)))
        $savedDir=$env:GIT_DIR;$savedTree=$env:GIT_WORK_TREE
        try {$env:GIT_DIR=Join-Path $other '.git';$env:GIT_WORK_TREE=$repo;$routed=Get-RepositoryStateEvidence $repo;Check 'repository-routing overrides cannot substitute other Git metadata' ($routed.State-eq'unavailable'-and$routed.Diagnosis-eq'repositoryRoutingOverride')}finally{$env:GIT_DIR=$savedDir;$env:GIT_WORK_TREE=$savedTree}
        $savedPath=$env:PATH
        try {$env:PATH=Join-Path $work 'no-git';$missing=Get-RepositoryStateEvidence $repo;Check 'missing Git is unavailable, never a nonrepository path binding' ($missing.State-eq'unavailable'-and$missing.Diagnosis-eq'gitMissing'-and$missing.BindingFingerprint-eq'')}finally{$env:PATH=$savedPath}
        $oldQuery=(Get-Command Invoke-QuietCommand).ScriptBlock
        try {
            $script:RepositoryFixtureStep=0
            function Invoke-QuietCommand {
                param($FilePath,$ArgumentList,[switch]$CaptureOutput,$Environment,$TimeoutSeconds)
                $script:RepositoryFixtureStep++
                $text=if($ArgumentList-contains'--show-toplevel'){$repo}elseif($ArgumentList-contains'HEAD'){'abc123'}elseif($script:RepositoryFixtureStep-lt5){'?? before.txt'}else{'?? after.txt'}
                return [pscustomobject]@{ExitCode=0;Output=$text;ErrorOutput=''}
            }
            $changing=Get-RepositoryStateEvidence $repo
            Check 'concurrent status changes never produce a trusted snapshot' ($changing.State-eq'unavailable'-and$changing.Diagnosis-eq'repositoryChanged'-and$changing.BindingFingerprint-eq'')
        }finally{Set-Item Function:Invoke-QuietCommand -Value $oldQuery}
        foreach($errorText in @('fatal: dubious ownership','fatal: not a git repository','fatal: Permission denied','fatal: other error')) {
            $expected=switch($errorText){'fatal: dubious ownership'{'dubiousOwnership'} 'fatal: not a git repository'{'nonrepository'} 'fatal: Permission denied'{'permissionDenied'} default{'gitFailed'}}
            Check ('sanitized diagnosis distinguishes '+$expected) ((Get-RepositoryGitDiagnosis ([pscustomobject]@{ExitCode=128;ErrorOutput=$errorText}))-eq$expected)
        }
    }
    finally {
        $env:GIT_CONFIG_GLOBAL=$savedGlobal;$env:GIT_CONFIG_SYSTEM=$savedSystem
        $env:GIT_TEST_ASSUME_DIFFERENT_OWNER=$savedOwner;$env:HOOKMAKER_STATE_DIR=$savedState
        $env:GIT_CONFIG_COUNT=$savedCount;$env:GIT_CONFIG_KEY_0=$savedKey;$env:GIT_CONFIG_VALUE_0=$savedValue
        if(-not(Remove-TestWorkspace $work)){$script:Fail++}
    }
}
