# One real installer/CLI/uninstaller fixture, isolated registry and mocked workflow API.
param([switch]$RepairRegression)
function Invoke-CiRepairRegression {
    param([string]$ToolRoot,[string]$Work)
    $repo=Join-Path $Work 'selected-repair shared settings'
    $shared=Join-Path $repo '.claude/settings.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $shared))
    Write-Utf8 $shared '{"hooks":{},"note":"Existing Hook-Maker shared settings","unrelated":{"preserved":true}}'
    $source=Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'
    & (Join-Path $ToolRoot 'scripts/Install-Hook.ps1') -CustomHook $source -TargetProject $repo -Events @('SessionStart','Stop') -Timeout 47 *> $null
    $record=@((Read-InstallRegistry $ToolRoot).installs|Where-Object{$_.targetProjectRoot-ceq$repo})[0]
    $selected=Get-ClientSubrecord $record claude
    $other=Get-ClientSubrecord $record codex
    Check 'official installer selects existing shared Claude settings' ((Normalize-Path $selected.settingsPath)-ieq(Normalize-Path $shared))
    Check 'official shared settings record passes canonical validation' (Test-InstallRecordValid $record).Ok
    $foreign=$record|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $foreign.clients.claude.settingsPath=Join-Path $repo '.claude/foreign.json'
    Check 'arbitrary settings path remains invalid' (-not(Test-InstallRecordValid $foreign).Ok)
    $local=Join-Path $repo '.claude/settings.local.json'
    Write-Utf8 $local '{"unrelatedLocal":true}'
    $localHash=Get-FileSha256 $local
    $sharedHash=Get-FileSha256 $shared
    $otherHash=Get-FileSha256 $other.settingsPath
    $otherManifest=@(Get-InstalledManifest $other.runtimeRoot $record.friendlyName)
    $out=Join-Path $Work 'repair-path.out';$err=Join-Path $Work 'repair-path.err'
    $repair=Join-Path $ToolRoot 'scripts/Repair-Hook.ps1'
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$repair,'-RecordId',$record.id,'-Client','claude')
    foreach($hostName in @('pwsh','powershell.exe')){
        $preview=Start-BoundedProcess -FilePath $hostName -ArgumentList $arguments -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
        Check ($hostName+': shared settings repair preview retains both settings files') ($preview.ExitCode-eq0-and(Get-FileSha256 $shared)-ceq$sharedHash-and(Get-FileSha256 $local)-ceq$localHash) ([IO.File]::ReadAllText($err))
        if($preview.ExitCode-ne0){Write-Output ([IO.File]::ReadAllText($err))}
    }
    foreach($hostName in @('pwsh','powershell.exe')){
        $applied=Start-BoundedProcess -FilePath $hostName -ArgumentList ($arguments+@('-Apply')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
        Check ($hostName+': shared settings repair applies without moving or touching other client') ($applied.ExitCode-eq0-and(Get-FileSha256 $local)-ceq$localHash-and(Get-FileSha256 $other.settingsPath)-ceq$otherHash-and(Compare-Manifest $otherManifest @(Get-InstalledManifest $other.runtimeRoot $record.friendlyName)).IsMatch) ([IO.File]::ReadAllText($err))
    }
    $record=Get-InstallRecordById $ToolRoot $record.id
    $selected=Get-ClientSubrecord $record claude
    $selection=Get-CiReviewSelection $ToolRoot $record.id claude
    Check 'review enrollment accepts the same official shared-settings record' ($selection.Record.id-ceq$record.id)
    $sharedBytes=[IO.File]::ReadAllBytes($shared)
    try{
        [IO.File]::WriteAllBytes($local,$sharedBytes)
        $duplicateHash=Get-FileSha256 $local
        $refused=Start-BoundedProcess -FilePath pwsh -ArgumentList ($arguments+@('-Apply')) -TimeoutMs 15000 -RedirectStandardOutput $out -RedirectStandardError $err
        Check 'duplicate selected registrations across Claude settings refuse unchanged' ($refused.ExitCode-ne0-and(Get-FileSha256 $shared)-ceq(Get-CiReviewBytesHash $sharedBytes).ToUpperInvariant()-and(Get-FileSha256 $local)-ceq$duplicateHash)
    }finally{Write-Utf8 $local '{"unrelatedLocal":true}'}
    [IO.File]::Delete($local)
    [void][IO.Directory]::CreateDirectory($local)
    try{
        $refused=Start-BoundedProcess -FilePath pwsh -ArgumentList ($arguments+@('-Apply')) -TimeoutMs 15000 -RedirectStandardOutput $out -RedirectStandardError $err
        Check 'non-file alternate settings refuses before mutation' ($refused.ExitCode-ne0-and[IO.Directory]::Exists($local)-and(Get-FileSha256 $shared)-ceq(Get-CiReviewBytesHash $sharedBytes).ToUpperInvariant())
    }finally{[IO.Directory]::Delete($local);Write-Utf8 $local '{"unrelatedLocal":true}'}
    $runtime=Split-Path -Parent $selected.runtimeScript
    $policy=Join-Path $runtime '_ci-policy.json'
    Write-Utf8 $policy '{"schema":3,"owner":"preserved fixture review"}'
    $entryBytes=[IO.File]::ReadAllBytes($selected.runtimeScript)
    $policyBytes=[IO.File]::ReadAllBytes($policy)
    $boundary=Join-Path $ToolRoot 'scripts/_installplanruntime.ps1'
    $boundaryText=[IO.File]::ReadAllLines($boundary)
    $line=@(0..($boundaryText.Length-1)|Where-Object{$boundaryText[$_].Contains('if($null-ne$BeforeCommit)')})
    if($line.Count-ne1){throw 'Expected one actual runtime precommit boundary.'}
    $probe=Join-Path $Work 'repair-mid-staging.ps1'
    foreach($hostName in @('pwsh','powershell.exe')){
    foreach($case in @('modified','added','deleted','policy','settings','alternate-directory')){
        $mutation=Join-Path $runtime 'independent-added.ps1'
        $statement=switch($case){
            modified {"[IO.File]::AppendAllText('"+$selected.runtimeScript.Replace("'","''")+"',' independent edit')"}
            added {"[IO.File]::WriteAllText('"+$mutation.Replace("'","''")+"','independent new file')"}
            deleted {"[IO.File]::Delete('"+$selected.runtimeScript.Replace("'","''")+"')"}
            policy {"[IO.File]::AppendAllText('"+$policy.Replace("'","''")+"',' ')"}
            settings {"[IO.File]::AppendAllText('"+$shared.Replace("'","''")+"',' ')"}
            alternate-directory {"[void][IO.Directory]::CreateDirectory('"+$local.Replace("'","''")+"')"}
        }
        # A debugger breakpoint makes an independent edit after staging, not a
        # scheduling guess or a production-only injection switch.
        $body="`$ErrorActionPreference='Stop'`r`n"+
            "`$bp=Set-PSBreakpoint -Script '"+$boundary.Replace("'","''")+"' -Line "+($line[0]+1)+" -Action { "+$statement+" }`r`n"+
            "try { & '"+$repair.Replace("'","''")+"' -RecordId "+$record.id+" -Client claude -Apply; `$code=`$LASTEXITCODE } finally { Remove-PSBreakpoint `$bp }`r`nexit `$code`r`n"
        Write-Utf8 $probe $body
        if($case-ceq'alternate-directory'){[IO.File]::Delete($local)}
        try{
            $refused=Start-BoundedProcess -FilePath $hostName -ArgumentList @('-NoProfile','-NonInteractive','-File',$probe) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            $retained=switch($case){
                modified {[IO.File]::ReadAllText($selected.runtimeScript).EndsWith(' independent edit')}
                added {[IO.File]::Exists($mutation)}
                deleted {-not[IO.File]::Exists($selected.runtimeScript)}
                policy {[IO.File]::ReadAllText($policy).EndsWith(' ')}
                settings {[IO.File]::ReadAllText($shared).EndsWith(' ')}
                alternate-directory {[IO.Directory]::Exists($local)}
            }
            Check ($hostName+': mid-staging '+$case+' refuses and retains independent bytes') ($refused.ExitCode-ne0-and$retained-and(Get-FileSha256 $other.settingsPath)-ceq$otherHash) ([IO.File]::ReadAllText($err))
            Check ($hostName+': mid-staging '+$case+' cleans only its disposable staging') (@(Get-ChildItem -LiteralPath $selected.runtimeRoot -Directory -Force|Where-Object{$_.Name-like'.hookmaker-*'}).Count-eq0)
        }finally{
            [IO.File]::WriteAllBytes($selected.runtimeScript,$entryBytes)
            [IO.File]::WriteAllBytes($policy,$policyBytes)
            [IO.File]::WriteAllBytes($shared,$sharedBytes)
            if([IO.File]::Exists($mutation)){[IO.File]::Delete($mutation)}
            if($case-ceq'alternate-directory'){
                if([IO.Directory]::Exists($local)){[IO.Directory]::Delete($local)}
                Write-Utf8 $local '{"unrelatedLocal":true}'
            }
        }
    }
    }
}
function Invoke-CiReviewCliRegression {
    param([string]$ToolRoot,[string]$Work)
    $repo=Join-Path $Work 'review-management'
    $sha=[string](Invoke-QuietCommand git @('-C',$repo,'rev-parse','HEAD'))
    $tree=@(Invoke-QuietCommand git @('-C',$repo,'ls-tree','-r',$sha))
    $blob=[string](Invoke-QuietCommand git @('-C',$repo,'rev-parse',($sha+':.github/workflows/ci.yml')))
    $policy=@{schema=1;repository='owner/repo';rationale='Source-defined inert CLI review';treeFingerprint=Get-RepositoryIdentityHash ($tree-join"`n");sources=@(@{path='.github/workflows/ci.yml';blob=$blob});workflows=@(@{id=9;path='.github/workflows/ci.yml';event='workflow_dispatch';branch='main';jobs=@(@{name='validate';steps=@('Validate')})})}
    $policyPath=Join-Path $Work 'review-cli-input.json'
    [IO.File]::WriteAllText($policyPath,($policy|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
    & (Join-Path $ToolRoot 'scripts/Install-Hook.ps1') -CustomHook (Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1') -TargetProject $repo -Events Stop -Timeout 47 *> $null
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
            $acquired=Start-BoundedProcess -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$acquisition,'-Library',(Join-Path $runtime '_hooklib.ps1'),'-Root',$repo,'-Sha',$sha) -TimeoutMs 15000 -RedirectStandardOutput $acqOut -RedirectStandardError $acqErr
            Check ('actual installed shared acquisition retains 4000ms contract '+$client) ($acquired.ExitCode-eq0) ([IO.File]::ReadAllText($acqOut,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($acqErr,[Text.Encoding]::UTF8))
            $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $ToolRoot 'scripts/Set-CiWorkloadReview.ps1'),'-RecordId',$record.id,'-Client',$client,'-PolicyPath',$policyPath,'-Repository','owner/repo','-Commit',$sha,'-Branch','main','-ExpectedPolicyHash','absent')
            $out=Join-Path $Work ('review-cli-'+$client+'.out');$err=Join-Path $Work ('review-cli-'+$client+'.err')
            $preview=Start-BoundedProcess -FilePath $exe -ArgumentList $arguments -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ('actual review CLI preview no policy '+$client) ($preview.ExitCode-eq0-and-not(Test-Path -LiteralPath (Join-Path $runtime '_ci-policy.json'))) ([IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err))
            $applied=Start-BoundedProcess -FilePath $exe -ArgumentList ($arguments+@('-Apply','-ReviewConfirmed')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            $applyDetail=[IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8)
            Check ('actual selected review CLI enrollment '+$client) ($applied.ExitCode-eq0-and(Test-Path -LiteralPath (Join-Path $runtime '_ci-policy.json'))) $applyDetail
            if($applied.ExitCode-ne0){Write-Output ('Review fixture refusal '+$client+': '+$applyDetail)}
            $refused=Start-BoundedProcess -FilePath $exe -ArgumentList ($arguments+@('-Apply','-ReviewConfirmed')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ('actual stale preimage refuses without registration changes '+$client) ($refused.ExitCode-ne0-and(Get-FileSha256 $settings)-ceq$settingsHash-and[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8)-match'\[policy-mismatch\]')
        }
        $record=Get-InstallRecordById $ToolRoot $record.id
        $claude=Get-ClientSubrecord $record claude
        $codex=Get-ClientSubrecord $record codex
        $selectedSettingsHash=Get-FileSha256 $claude.settingsPath
        $otherSettingsHash=Get-FileSha256 $codex.settingsPath
        $selectedManifest=@(Get-InstalledManifest $claude.runtimeRoot $record.friendlyName)
        $otherManifest=@(Get-InstalledManifest $codex.runtimeRoot $record.friendlyName)
        $policyHash=Get-FileSha256 (Join-Path (Split-Path -Parent $claude.runtimeScript) '_ci-policy.json')
        $out=Join-Path $Work 'selected-repair.out';$err=Join-Path $Work 'selected-repair.err'
        $repairArgs=@('-NoProfile','-NonInteractive','-File',(Join-Path $ToolRoot 'scripts/Repair-Hook.ps1'),'-RecordId',$record.id,'-Client','claude')
        $preview=Start-BoundedProcess -FilePath pwsh -ArgumentList $repairArgs -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
        Check 'selected repair preview changes no binding or payload' ($preview.ExitCode-eq0-and(Get-FileSha256 $claude.settingsPath)-ceq$selectedSettingsHash-and(Get-FileSha256 $codex.settingsPath)-ceq$otherSettingsHash-and(Compare-Manifest $selectedManifest @(Get-InstalledManifest $claude.runtimeRoot $record.friendlyName)).IsMatch) ([IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8))
        # Represent an older recorded source without modifying the shared checkout.
        $registry=Read-InstallRegistry $ToolRoot
        $stale=@($registry.installs|Where-Object{$_.id-ceq$record.id})[0]
        $stale.sourceManifest[0].hash='0'*64
        Save-InstallRegistry $ToolRoot $registry
        $recoveryBefore=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -File -Recurse|ForEach-Object{$_.FullName+'|'+(Get-FileSha256 $_.FullName)}|Sort-Object)
        $repair=Start-BoundedProcess -FilePath pwsh -ArgumentList ($repairArgs+@('-Apply')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
        $record=Get-InstallRecordById $ToolRoot $record.id
        $saved=Get-ClientSubrecord $record claude
        Check 'selected Claude repair preserves Codex payload and settings' ($repair.ExitCode-eq0-and(Get-FileSha256 $codex.settingsPath)-ceq$otherSettingsHash-and(Compare-Manifest $otherManifest @(Get-InstalledManifest $codex.runtimeRoot $record.friendlyName)).IsMatch) ([IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8))
        Check 'selected repair retains saved events and timeout' ((@($saved.events)-join'|')-ceq(@($claude.events)-join'|')-and$saved.timeout-eq$claude.timeout)
        Check 'selected repair preserves reviewed policy bytes' ((Get-FileSha256 (Join-Path (Split-Path -Parent $claude.runtimeScript) '_ci-policy.json'))-ceq$policyHash)
        $recoveryAfter=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -File -Recurse|ForEach-Object{$_.FullName+'|'+(Get-FileSha256 $_.FullName)}|Sort-Object)
        Check 'selected repair retains every original recovery file' (($recoveryBefore-join"`n")-ceq($recoveryAfter-join"`n"))
        $selectedSettingsHash=Get-FileSha256 $saved.settingsPath
        $reviewedSource=@(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $record.sourceScript -SourceDir $record.sourceDir -FriendlyName $record.friendlyName -ProjectRoot $repo)
        $reviewedSource[0].hash='0'*64
        $generationRefused=$false
        try{
            & (Join-Path $ToolRoot 'scripts/Install-Hook.ps1') -CustomHook $record.sourceScript -TargetProject $repo -Clients claude -Events @($saved.events) -Timeout $saved.timeout -ExpectedSourceManifest $reviewedSource *> $null
        }catch{$generationRefused=$true}
        Check 'installer refuses changed reviewed generation without payload or settings mutation' ($generationRefused-and(Get-FileSha256 $saved.settingsPath)-ceq$selectedSettingsHash-and(Compare-Manifest @($saved.installedManifest) @(Get-InstalledManifest $saved.runtimeRoot $record.friendlyName)).IsMatch)
        $ownedRegistration=Test-ClientRegistrationState -SettingsPath $saved.settingsPath -RuntimeScript $saved.runtimeScript -ExpectedEvents @($saved.events) -ExpectedCommand $saved.command -ExpectedCommandWindows $saved.commandWindows -ExpectedHandlerType $saved.handlerType -ExpectedTimeout $saved.timeout
        Check 'selected repair retains canonical matcher and commands' $ownedRegistration.Ok
        $runtimeMutex=New-ManagedRuntimeMutex (Split-Path -Parent $saved.runtimeScript)
        $runtimeHeld=$runtimeMutex.WaitOne(0)
        if(-not$runtimeHeld){$runtimeMutex.Dispose();throw 'Fixture could not own runtime mutex.'}
        try{
            $busy=Start-BoundedProcess -FilePath pwsh -ArgumentList $repairArgs -TimeoutMs 15000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check 'selected repair refuses busy runtime before mutation' ($busy.ExitCode-ne0-and[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8)-match'\[runtime-busy\]'-and(Get-FileSha256 $saved.settingsPath)-ceq$selectedSettingsHash)
        }finally{$runtimeMutex.ReleaseMutex();$runtimeMutex.Dispose()}
        $settingsBytes=[IO.File]::ReadAllBytes($saved.settingsPath)
        try{
            $settingsDoc=Read-JsonFile $saved.settingsPath
            $settingsDoc.hooks.Stop=@()
            [IO.File]::WriteAllText($saved.settingsPath,($settingsDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
            $driftHash=Get-FileSha256 $saved.settingsPath
            $refusal=Start-BoundedProcess -FilePath pwsh -ArgumentList $repairArgs -TimeoutMs 15000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check 'selected repair distinguishes registration drift without rewriting settings' ($refusal.ExitCode-ne0-and[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8)-match'\[registration-stale\]'-and(Get-FileSha256 $saved.settingsPath)-ceq$driftHash)
        }finally{[IO.File]::WriteAllBytes($saved.settingsPath,$settingsBytes)}
        $runtimeBytes=[IO.File]::ReadAllBytes($saved.runtimeScript)
        try{
            [IO.File]::AppendAllText($saved.runtimeScript,"`r`n# independent fixture edit",[Text.UTF8Encoding]::new($false))
            $changedHash=Get-FileSha256 $saved.runtimeScript
            $refusal=Start-BoundedProcess -FilePath pwsh -ArgumentList ($repairArgs+@('-Apply')) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check 'selected repair refuses independent payload without overwriting it' ($refusal.ExitCode-ne0-and(Get-FileSha256 $saved.runtimeScript)-ceq$changedHash-and(Get-FileSha256 $saved.settingsPath)-ceq$selectedSettingsHash)
        }finally{[IO.File]::WriteAllBytes($saved.runtimeScript,$runtimeBytes)}
        . (Join-Path $ToolRoot 'scripts/_installevaluate.ps1')
        $current=@(Get-UpdateEvaluationPlan @($record) $ToolRoot)
        Check 'managed plan preserves separate current input review for both clients' ($current.Count-eq1-and@($current[0].Reviews|Where-Object{$_.Status-ceq'context-current'}).Count-eq2)
        $null=Invoke-QuietCommand git @('-C',$repo,'config','branch.main.merge','refs/heads/changed')
        try{
            $drift=@(Get-UpdateEvaluationPlan @($record) $ToolRoot)
            Check 'review drift requests review without a payload reinstall loop' ($drift[0].Status-ceq$current[0].Status-and@($drift[0].Reviews|Where-Object{$_.Status-ceq'review-required'}).Count-eq2-and$drift[0].Detail-match'Set-CiWorkloadReview')
        }finally{$null=Invoke-QuietCommand git @('-C',$repo,'config','branch.main.merge','refs/heads/main')}
        $docsBytes=[Text.UTF8Encoding]::new($false).GetBytes('{"schema":3,"rationale":"owner documentation review"}')
        foreach($client in @('claude','codex')){
            $runtime=Split-Path -Parent (Get-ClientSubrecord $record $client).runtimeScript
            [IO.File]::WriteAllBytes((Join-Path $runtime '_docs-policy.json'),$docsBytes)
        }
        $docsStatus=@(Get-UpdateEvaluationPlan @($record) $ToolRoot)
        Check 'documentation review status is separate from enrolled CI input' (@($docsStatus[0].Reviews|Where-Object{$_.Policy-ceq'_docs-policy.json'}).Count-eq2)
        $before=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -File -Recurse|ForEach-Object{Get-FileSha256 $_.FullName})
        $out=Join-Path $Work 'review-uninstall.out';$err=Join-Path $Work 'review-uninstall.err'
        $removed=Start-BoundedProcess -FilePath pwsh -ArgumentList @('-NoProfile','-File',(Join-Path $ToolRoot 'scripts/Uninstall-Hook.ps1'),'-RecordId',$record.id,'-ToolRoot',$ToolRoot) -TimeoutMs 60000 -RedirectStandardOutput $out -RedirectStandardError $err
        $after=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -File -Recurse|ForEach-Object{Get-FileSha256 $_.FullName})
        . (Join-Path $ToolRoot 'scripts/_ciworkloadreview.ps1')
        $docsHash=Get-CiReviewBytesHash $docsBytes
        $docsRecovery=@(Get-ChildItem (Join-Path $env:HOOKMAKER_STATE_DIR 'ci-review-recovery') -Directory|Where-Object{$_.Name-match'-docs-'}|ForEach-Object{Get-FileSha256 (Join-Path $_.FullName 'submitted.json')})
        Check 'supported uninstall preserves both original documentation reviews outside runtime' ($removed.ExitCode-eq0-and$docsRecovery.Count-eq2-and@($docsRecovery|Where-Object{$_-ine$docsHash}).Count-eq0)
        Check 'supported uninstall retains original review recovery' ($removed.ExitCode-eq0-and@($before|Where-Object{$after-cnotcontains$_}).Count-eq0-and$after.Count-gt$before.Count) ([IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err))
    }finally{$env:PATH=$savedPath}
    Invoke-CiRepairRegression $ToolRoot $Work
}
if($RepairRegression){
    Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop'
    $root=Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'hooks/_hooklib.ps1')
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    . (Join-Path $PSScriptRoot '_installlib.ps1')
    . (Join-Path $PSScriptRoot '_installplan.ps1')
    . (Join-Path $PSScriptRoot '_ciworkloadreview.ps1')
    $script:Pass=0;$script:Fail=0
    $work=New-TestWorkspace -Prefix 'selected-repair-regression'
    try{Invoke-CiRepairRegression $root $work}
    finally{if(-not(Remove-TestWorkspace $work)){$script:Fail++}}
    Write-Output "Passed: $script:Pass Failed: $script:Fail";exit $script:Fail
}
