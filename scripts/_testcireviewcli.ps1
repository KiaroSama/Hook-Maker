# One real installer/CLI/uninstaller fixture, isolated registry and mocked workflow API.
function Invoke-CiReviewCliRegression {
    param([string]$ToolRoot,[string]$Work)
    $repo=Join-Path $Work 'review-management'
    $sha=[string](Invoke-QuietCommand git @('-C',$repo,'rev-parse','HEAD'))
    $tree=@(Invoke-QuietCommand git @('-C',$repo,'ls-tree','-r',$sha))
    $blob=[string](Invoke-QuietCommand git @('-C',$repo,'rev-parse',($sha+':.github/workflows/ci.yml')))
    $policy=@{schema=1;repository='owner/repo';rationale='Source-defined inert CLI review';treeFingerprint=Get-RepositoryIdentityHash ($tree-join"`n");sources=@(@{path='.github/workflows/ci.yml';blob=$blob});workflows=@(@{id=9;path='.github/workflows/ci.yml';event='workflow_dispatch';branch='main';jobs=@(@{name='validate';steps=@('Validate')})})}
    $policyPath=Join-Path $Work 'review-cli-input.json'
    [IO.File]::WriteAllText($policyPath,($policy|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
    & (Join-Path $ToolRoot 'scripts/Install-Hook.ps1') -CustomHook (Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1') -TargetProject $repo -Events Stop *> $null
    $records=@((Read-InstallRegistry $ToolRoot).installs|Where-Object{$_.friendlyName-ceq'Ci-Status-Check'-and$_.targetProjectRoot-ceq$repo})
    if($records.Count-ne1){throw 'CLI fixture installation missing'}
    $record=$records[0]
    $shim=Join-Path $Work 'review-gh';[void][IO.Directory]::CreateDirectory($shim)
    [IO.File]::WriteAllText((Join-Path $shim 'gh.ps1'),"if(`$args.Count -eq 2 -and `$args[0] -eq 'api' -and `$args[1] -eq 'repos/owner/repo/actions/workflows/9'){Write-Output '{`"id`":9,`"path`":`".github/workflows/ci.yml`"}';exit 0};exit 1",[Text.UTF8Encoding]::new($false))
    $savedPath=$env:PATH
    try{
        $env:PATH=(@($shim)+@($env:PATH-split';'|Where-Object{$_-ne''-and-not(Test-Path -LiteralPath (Join-Path $_ 'gh.exe'))}))-join';'
        $acquisition=Join-Path $Work 'installed-acquisition.ps1'
        $acquisitionBody=@'
param([string]$Library,[string]$Root,[string]$Sha)
$ErrorActionPreference='Stop'
. $Library
$watch=[Diagnostics.Stopwatch]::StartNew()
$snapshot=Get-RepositoryAccessSnapshot $Root
$expected=(Get-RepositoryIdentityHash ($Sha+'|')).Substring(0,10)
Write-Output ('elapsedMs='+$watch.ElapsedMilliseconds+' state='+$snapshot.State+' diagnosis='+$snapshot.Diagnosis)
if($snapshot.State-cne'available'-or$snapshot.Fingerprint-cne$expected){exit 1}
exit 0
'@
        [IO.File]::WriteAllText($acquisition,$acquisitionBody,[Text.UTF8Encoding]::new($false))
        foreach($client in @('claude','codex')){
            $exe=if($client-ceq'claude'){'powershell.exe'}else{'pwsh'}
            $runtime=Split-Path -Parent (Get-ClientSubrecord $record $client).runtimeScript
            $settings=(Get-ClientSubrecord $record $client).settingsPath
            $settingsHash=Get-FileSha256 $settings
            $acqOut=Join-Path $Work ('installed-acquisition-'+$client+'.out');$acqErr=Join-Path $Work ('installed-acquisition-'+$client+'.err')
            $acquired=Start-BoundedProcess $exe @('-NoLogo','-NoProfile','-NonInteractive','-File',$acquisition,'-Library',(Join-Path $runtime '_hooklib.ps1'),'-Root',$repo,'-Sha',$sha) -TimeoutMs 15000 -RedirectStandardOutput $acqOut -RedirectStandardError $acqErr
            Check ('actual installed shared acquisition retains 4000ms contract '+$client) ($acquired.ExitCode-eq0) ([IO.File]::ReadAllText($acqOut,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($acqErr,[Text.Encoding]::UTF8))
            $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $ToolRoot 'scripts/Set-CiWorkloadReview.ps1'),'-RecordId',$record.id,'-Client',$client,'-PolicyPath',$policyPath,'-Repository','owner/repo','-Commit',$sha,'-Branch','main','-ExpectedPolicyHash','absent')
            $out=Join-Path $Work ('review-cli-'+$client+'.out');$err=Join-Path $Work ('review-cli-'+$client+'.err')
            $preview=Start-BoundedProcess $exe $arguments -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ('actual review CLI preview no policy '+$client) ($preview.ExitCode-eq0-and-not(Test-Path -LiteralPath (Join-Path $runtime '_ci-policy.json'))) ([IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err))
            $applied=Start-BoundedProcess $exe ($arguments+@('-Apply','-ReviewConfirmed')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ('actual selected review CLI enrollment '+$client) ($applied.ExitCode-eq0-and(Test-Path -LiteralPath (Join-Path $runtime '_ci-policy.json'))) ([IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err))
            $refused=Start-BoundedProcess $exe ($arguments+@('-Apply','-ReviewConfirmed')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ('actual stale preimage refuses without registration changes '+$client) ($refused.ExitCode-ne0-and(Get-FileSha256 $settings)-ceq$settingsHash)
        }
        . (Join-Path $ToolRoot 'scripts/_installevaluate.ps1')
        $current=@(Get-UpdateEvaluationPlan @($record) $ToolRoot)
        Check 'managed plan preserves separate current input review for both clients' ($current.Count-eq1-and@($current[0].Reviews|Where-Object{$_.Status-ceq'context-current'}).Count-eq2)
        $null=Invoke-QuietCommand git @('-C',$repo,'config','branch.main.merge','refs/heads/changed')
        try{
            $drift=@(Get-UpdateEvaluationPlan @($record) $ToolRoot)
            Check 'review drift requests review without a payload reinstall loop' ($drift[0].Status-ceq$current[0].Status-and@($drift[0].Reviews|Where-Object{$_.Status-ceq'review-required'}).Count-eq2-and$drift[0].Detail-match'Set-CiWorkloadReview')
        }finally{$null=Invoke-QuietCommand git @('-C',$repo,'config','branch.main.merge','refs/heads/main')}
        $before=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -File -Recurse|ForEach-Object{Get-FileSha256 $_.FullName})
        $out=Join-Path $Work 'review-uninstall.out';$err=Join-Path $Work 'review-uninstall.err'
        $removed=Start-BoundedProcess pwsh @('-NoProfile','-File',(Join-Path $ToolRoot 'scripts/Uninstall-Hook.ps1'),'-RecordId',$record.id,'-ToolRoot',$ToolRoot) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
        $after=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -File -Recurse|ForEach-Object{Get-FileSha256 $_.FullName})
        Check 'supported uninstall retains original review recovery' ($removed.ExitCode-eq0-and@($before|Where-Object{$after-cnotcontains$_}).Count-eq0-and$after.Count-gt$before.Count) ([IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err))
    }finally{$env:PATH=$savedPath}
}
