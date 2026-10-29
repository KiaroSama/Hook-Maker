# Public executor regressions; the entry suite owns isolated registry/profile roots.
function Invoke-CompleteNativeRemovalRegression {
    $nativeProject=New-Proj 'CompleteNativeRecovery'
    & git -C $nativeProject init --quiet -b main
    if($LASTEXITCODE-ne0){throw 'Native fixture repository initialization failed.'}
    $wrapper=Join-Path $nativeProject '.git/hooks/pre-push'
    # Opaque legacy user-hook bytes must survive without decoding or rewriting.
    $userBytes=[byte[]]@(35,33,47,98,105,110,47,115,104,10,35,255,254,128)
    [IO.File]::WriteAllBytes($wrapper,$userBytes)
    $source=Join-Path $RealHooksDir 'Ignore-Rules-Check/Ignore-Rules-Check.ps1'
    & $InstallScript -CustomHook $source -Events @('Stop') -TargetProject $nativeProject -ClaudeOnly *> $null
    $nativeRecord=Get-RecordForScope 'Ignore-Rules-Check' $nativeProject
    $managedBytes=[IO.File]::ReadAllBytes($wrapper)
    . (Join-Path $ScriptRoot '_installlifecycle.ps1')
    $heldLifecycle=Enter-InstallLifecycle $ToolRoot
    try {
        $absentRemoval=Invoke-UninstallProcess -RecordId 'absent-lifecycle-fixture'
        Check 'absent record no-op does not contend with mutation lifecycle' ([string]$absentRemoval.Result.overall-eq'ok')
        $busyRemoval=Invoke-UninstallProcess -RecordId $nativeRecord.id -Complete
        Check 'concurrent uninstaller refuses before mutation' ([string]$busyRemoval.Result.overall-eq'failed'-and$busyRemoval.Err.Contains('Another install or uninstall owns this registry'))
        Check 'busy lifecycle preserves wrapper and selected record' ((Test-BytesEqual ([IO.File]::ReadAllBytes($wrapper)) $managedBytes)-and @(Get-RecordsFor 'Ignore-Rules-Check'|Where-Object{$_.id-eq$nativeRecord.id}).Count-eq1)
    }
    finally { $heldLifecycle.ReleaseMutex();$heldLifecycle.Dispose() }
    $shadow=Join-Path $Work 'native-failure-executor'
    [void][IO.Directory]::CreateDirectory($shadow)
    Copy-Item -Path (Join-Path $ScriptRoot '_*.ps1') -Destination $shadow
    $executor=Join-Path $shadow 'Uninstall-Hook.ps1'
    Copy-Item -LiteralPath $UninstallScript -Destination $executor
    $module=Join-Path $shadow '_uninstallnative.ps1'
    $original=[IO.File]::ReadAllText($module,[Text.Encoding]::UTF8)
    $anchor='[IO.File]::Copy($wrapperPath, $wrapperBackup, $false)'
    Check 'native backup failure injection targets the real backup boundary' ($original.Contains($anchor))
    Write-Utf8 $module ($original.Replace($anchor,"throw 'Controlled native backup failure.'"))
    $backupFailure=Invoke-UninstallProcess -RecordId $nativeRecord.id -Complete -ScriptPath $executor
    Check 'backup failure never reports complete or changes the wrapper' ([string]$backupFailure.Result.overall-ne'ok'-and(Test-BytesEqual ([IO.File]::ReadAllBytes($wrapper)) $managedBytes))
    $anchor='                        Remove-Item -LiteralPath $dir -Recurse -Force'
    Check 'native cleanup failure injection targets the real deletion boundary' ($original.Contains($anchor))
    Write-Utf8 $module ($original.Replace($anchor,"                    throw 'Controlled native cleanup failure.'"))
    $cleanupFailure=Invoke-UninstallProcess -RecordId $nativeRecord.id -Complete -ScriptPath $executor
    Check 'native cleanup failure retains tracking and reports failure' ([string]$cleanupFailure.Result.overall-eq'failed'-and @(Get-RecordsFor 'Ignore-Rules-Check'|Where-Object{$_.id-eq$nativeRecord.id}).Count-eq1) ($cleanupFailure.Result|ConvertTo-Json -Depth 5)
    Check 'native cleanup failure restores the managed retry wrapper' (Test-BytesEqual ([IO.File]::ReadAllBytes($wrapper)) $managedBytes)
    Check 'native cleanup failure preserves opaque user hook bytes' (Test-BytesEqual ([IO.File]::ReadAllBytes($wrapper+'.hookmaker-existing')) $userBytes)
    $retry=Invoke-UninstallProcess -RecordId $nativeRecord.id -Complete
    Check 'native complete retry retires owned runtime and tracking' ([string]$retry.Result.overall-eq'ok'-and-not(Test-Path -LiteralPath ([string]$nativeRecord.nativeGit.runtimeRoot))-and @(Get-RecordsFor 'Ignore-Rules-Check'|Where-Object{$_.id-eq$nativeRecord.id}).Count-eq0) ($retry.Result|ConvertTo-Json -Depth 5)
    Check 'native complete retry restores user bytes without backup residue' ((Test-BytesEqual ([IO.File]::ReadAllBytes($wrapper)) $userBytes)-and-not(Test-Path -LiteralPath ($wrapper+'.hookmaker-existing'))-and @(Get-ChildItem -LiteralPath (Split-Path -Parent $wrapper) -Filter 'pre-push.hookmaker-uninstall-backup-*').Count-eq0)
    & $InstallScript -CustomHook $source -Events @('Stop') -TargetProject $nativeProject -ClaudeOnly *> $null
    foreach($name in @('Secrets-Check','Utf8-Encoding-Check')){
        & $InstallScript -CustomHook (Join-Path $RealHooksDir ($name+'/'+$name+'.ps1')) -Events @('Stop') -TargetProject $nativeProject -ClaudeOnly *> $null
        $companion=Get-RecordForScope $name $nativeProject
        if($name-eq'Secrets-Check'){
            $companionAnchor='            Remove-Item -LiteralPath $utf8Dir -Recurse -Force'
            Check 'companion failure injection targets its native deletion boundary' ($original.Contains($companionAnchor))
            Write-Utf8 $module ($original.Replace($companionAnchor,"            throw 'Controlled companion cleanup failure.'"))
            $failedCompanion=Invoke-UninstallProcess -RecordId $companion.id -Complete -ScriptPath $executor
            Check 'companion cleanup failure remains incomplete and tracked' ([string]$failedCompanion.Result.overall-eq'failed'-and @(Get-RecordsFor $name|Where-Object{$_.id-eq$companion.id}).Count-eq1)
            $retirementAnchor='            [IO.File]::Move($wrapperBackup, $retiredBackup)'
            Check 'companion retirement injection targets recovery publication' ($original.Contains($retirementAnchor))
            Write-Utf8 $module ($original.Replace($retirementAnchor,"            throw 'Controlled native recovery retirement failure.'"))
            $retirementFailure=Invoke-UninstallProcess -RecordId $companion.id -Complete -ScriptPath $executor
            $retainedOwner=Get-RecordForScope 'Ignore-Rules-Check' $nativeProject
            Check 'backup retirement failure keeps owner preimage and selected tracking' ([string]$retirementFailure.Result.overall-eq'failed'-and @($retainedOwner.nativeGit.companions)-contains$name-and @(Get-RecordsFor $name|Where-Object{$_.id-eq$companion.id}).Count-eq1)
        }
        $removed=Invoke-UninstallProcess -RecordId $companion.id -Complete
        $owner=Get-RecordForScope 'Ignore-Rules-Check' $nativeProject
        Check 'selected companion complete removal succeeds' ([string]$removed.Result.overall-eq'ok') ($removed.Result|ConvertTo-Json -Depth 5)
        Check 'selected companion leaves no native stage, runtime or active backup' (@($owner.nativeGit.companions)-notcontains$name-and-not(Test-Path -LiteralPath (Join-Path ([string]$owner.nativeGit.runtimeRoot) $name))-and-not(Test-Path -LiteralPath ($wrapper+'.hookmaker-chainstage-backup-'+$companion.id)))
        Check 'native owner wrapper and user hook remain intact' ((Compare-PrePushWrapperBody -Expected (New-PrePushWrapperBody -ManagedScripts @($owner.nativeGit.expectedStages)) -Actual ([IO.File]::ReadAllText($wrapper,[Text.Encoding]::UTF8)))-and(Test-BytesEqual ([IO.File]::ReadAllBytes($wrapper+'.hookmaker-existing')) $userBytes))
    }
}
Invoke-CompleteNativeRemovalRegression

Write-Host '--- runtime cleanup failure stays retryable, never a false success ---' -ForegroundColor Cyan
$lockedSource = New-FixtureHook 'ZZZ-Uninst-Lockedruntime'
try {
    $lockedProject = New-Proj 'LockedRuntimeProject'
    & $InstallScript -CustomHook $lockedSource -Events @('Stop') -TargetProject $lockedProject -ClaudeOnly *> $null
    $lockedRecord = Get-RecordForScope 'ZZZ-Uninst-Lockedruntime' $lockedProject
    $lockedScript = [string]$lockedRecord.clients.claude.runtimeScript
    $unsupported = Invoke-UninstallProcess -RecordId $lockedRecord.id -Complete
    Check 'unknown custom external effects refuse before runtime removal' ([string]$unsupported.Result.overall-eq'manualRepair'-and(Test-Path -LiteralPath $lockedScript))
    # Inject failure at the remover boundary: Windows Delete sharing covers both
    # rename and deletion, so an open-file fixture cannot isolate the latter.
    $shadow = Join-Path $Work 'cleanup-failure-executor'
    [void][IO.Directory]::CreateDirectory($shadow)
    Copy-Item -Path (Join-Path $ScriptRoot '_*.ps1') -Destination $shadow
    $shadowScript = Join-Path $shadow 'Uninstall-Hook.ps1'
    $body = [IO.File]::ReadAllText($UninstallScript,[Text.Encoding]::UTF8)
    $anchor = 'try { Remove-Item -LiteralPath $setAside -Recurse -Force }'
    Check 'cleanup failure injection targets the real executor cleanup' ($body.Contains($anchor))
    $body = $body.Replace($anchor,"try { throw 'Controlled owned runtime cleanup failure.' }")
    Write-Utf8 $shadowScript $body
    $failedRemoval = Invoke-UninstallProcess -RecordId $lockedRecord.id -ScriptPath $shadowScript
    Check 'runtime cleanup failure is never reported complete' ([string]$failedRemoval.Result.overall -eq 'failed') ($failedRemoval.Result|ConvertTo-Json -Depth 5)
    $retained = @(Get-RecordsFor 'ZZZ-Uninst-Lockedruntime' | Where-Object { $_.targetProjectRoot -eq $lockedProject })
    Check 'runtime cleanup failure retains its client identity' ($retained.Count -eq 1 -and $null -ne $retained[0].clients.claude)
    Check 'runtime cleanup failure restores the persisted path for retry' (Test-Path -LiteralPath $lockedScript -PathType Leaf)
    $retriedRemoval = Invoke-UninstallProcess -RecordId $lockedRecord.id
    Check 'normal retry removes retained runtime and tracking' ([string]$retriedRemoval.Result.overall -eq 'ok' -and -not(Test-Path -LiteralPath $lockedScript) -and @(Get-RecordsFor 'ZZZ-Uninst-Lockedruntime').Count -eq 0)
}
finally { Remove-FixtureHook 'ZZZ-Uninst-Lockedruntime' }

Write-Host '--- complete removal retires exact owned state, never another project ---' -ForegroundColor Cyan
$completeSource=Join-Path $RealHooksDir 'Ai-Memory-Check/Ai-Memory-Check.ps1'
$completeProject=New-Proj 'CompleteStateProject'
& $InstallScript -CustomHook $completeSource -Events @('Stop') -TargetProject $completeProject -ClaudeOnly *> $null
$completeRecord=Get-RecordForScope 'Ai-Memory-Check' $completeProject
. (Join-Path $ScriptRoot '_uninstallresidue.ps1')
$cleanupLeaves=@(Get-UninstallStateLeaves 'Test-Temp-Cleanup' $completeProject)
$cleanupKey=Get-ShortHash (Normalize-Path $completeProject).ToLowerInvariant()
Check 'complete cleanup removal retains baseline and reporting evidence' ($cleanupLeaves-notcontains("TestTempCleanup-baseline-$cleanupKey.json")-and$cleanupLeaves-notcontains("TestTempCleanup-state-$cleanupKey.json")-and$cleanupLeaves-contains("TestTempCleanup-result-$cleanupKey.json"))
$globalOwner=($completeRecord|ConvertTo-Json -Depth 30)|ConvertFrom-Json
$globalOwner.id='global-owner';$globalOwner.scope='global';$globalOwner.targetProjectRoot=''
Check 'global same-hook owner preserves shared project state' (Test-UninstallStateShared $completeRecord ([pscustomobject]@{installs=@($completeRecord,$globalOwner)}))
$repositoryResolver=(Get-Command Get-GitHubRepository).ScriptBlock
try {
    function Get-GitHubRepository { param($ProjectRoot) return [pscustomobject]@{Repository='fixture/owned-state'} }
    $authKey=Get-ShortHash ($completeProject.ToLowerInvariant()+'|fixture/owned-state')
    $ciLeaves=@(Get-UninstallStateLeaves 'Ci-Status-Check' $completeProject)
    Check 'complete CI inventory retires auth cache without deleting shared CI provenance' ($ciLeaves-contains('CiStatusCheck-Auth-'+$authKey+'.json')-and$ciLeaves-notcontains('CiStatusCheck-'+$authKey+'.txt'))
}
finally { Set-Item Function:Get-GitHubRepository -Value $repositoryResolver }
$stateRoot=Join-Path $FakeLocalAppData 'HookMaker/state'
[void][IO.Directory]::CreateDirectory($stateRoot)
$ownState=Join-Path $stateRoot ('AiMemoryCheck-'+(Get-ShortHash $completeProject.ToLowerInvariant())+'.txt')
$foreignState=Join-Path $stateRoot 'AiMemoryCheck-foreign.txt'
Write-Utf8 $ownState 'owned-marker';Write-Utf8 $foreignState 'foreign-marker'
$dry=Invoke-UninstallProcess -RecordId $completeRecord.id -Complete -WhatIf
Check 'complete dry run leaves runtime, state and registry' ([string]$dry.Result.overall-eq'ok'-and(Test-Path -LiteralPath $ownState)-and(Test-Path -LiteralPath ([string]$completeRecord.clients.claude.runtimeScript))-and @(Get-RecordsFor 'Ai-Memory-Check').Count-eq1) $dry.Err
$heldState=[IO.File]::Open($ownState,'Open','Read','Read')
try{$stateFailure=Invoke-UninstallProcess -RecordId $completeRecord.id -Complete}finally{$heldState.Dispose()}
Check 'locked operational state refuses complete success and retains tracking' ([string]$stateFailure.Result.overall-ne'ok'-and @(Get-RecordsFor 'Ai-Memory-Check').Count-eq1-and(Test-Path -LiteralPath $ownState))
$completeResult=Invoke-UninstallProcess -RecordId $completeRecord.id -Complete
Check 'complete removal reports verified success' ([string]$completeResult.Result.overall-eq'ok') ($completeResult.Result|ConvertTo-Json -Depth 5)
Check 'complete removal removes exact operational marker' (-not(Test-Path -LiteralPath $ownState))
Check 'complete removal preserves foreign state bytes' ([IO.File]::ReadAllText($foreignState,[Text.Encoding]::UTF8)-ceq'foreign-marker')
Check 'complete result explicitly accounts for retained evidence' (@($completeResult.Result.components|Where-Object{$_.component-eq'retainedEvidence'-and$_.reason-eq'historyPreserved'}).Count-eq1)
$skillsSource=Join-Path $RealHooksDir 'Skills-Check/Skills-Check.ps1'
& $InstallScript -CustomHook $skillsSource -Events @('Stop') -TargetProject $completeProject -ClaudeOnly *> $null
$skillsRecord=Get-RecordForScope 'Skills-Check' $completeProject
$shortlist=Join-Path $stateRoot ('SkillsCheck-shortlist-'+(Get-ShortHash $completeProject.ToLowerInvariant())+'-'+(Get-ShortHash 'fixture-session')+'.txt')
$foreignShortlist=Join-Path $stateRoot 'SkillsCheck-shortlist-foreign-0123456789.txt'
Write-Utf8 $shortlist 'owned-shortlist';Write-Utf8 $foreignShortlist 'foreign-shortlist'
$skillClaims=@(foreach($kind in @('close','deepdebug','prompt')){
    $path=Join-Path $stateRoot ('SkillsCheck-'+$kind+'-'+(Get-ShortHash $completeProject.ToLowerInvariant())+'.txt.claims.json')
    $claim=Invoke-DeliveryClaim -Path $path -Identity 'fixture-session' -Fingerprint 'fixture-note'
    if(-not$claim.Ok){throw 'Delivery reservation fixture failed.'}
    $path
})
$skillsRemoved=Invoke-UninstallProcess -RecordId $skillsRecord.id -Complete
Check 'project-owned session shortlist retires with complete removal' ([string]$skillsRemoved.Result.overall-eq'ok'-and-not(Test-Path -LiteralPath $shortlist)-and[IO.File]::ReadAllText($foreignShortlist,[Text.Encoding]::UTF8)-ceq'foreign-shortlist')
Check 'complete removal retires every owned skill delivery reservation' (@($skillClaims|Where-Object{Test-Path -LiteralPath $_}).Count-eq0)

Write-Host '--- cleanup removal retains session evidence, retires coordination ---' -ForegroundColor Cyan
$cleanupSource=Join-Path $RealHooksDir 'Test-Temp-Cleanup/Test-Temp-Cleanup.ps1'
& $InstallScript -CustomHook $cleanupSource -Events @('SessionStart','Stop') -TargetProject $completeProject -ClaudeOnly *> $null
$cleanupRecord=Get-RecordForScope 'Test-Temp-Cleanup' $completeProject
$cleanupEvidence=@("TestTempCleanup-baseline-$cleanupKey.json","TestTempCleanup-state-$cleanupKey.json",("TestTempCleanup-baseline-$cleanupKey-"+(Get-ShortHash 'session-A')+'.json'),("TestTempCleanup-state-$cleanupKey-"+(Get-ShortHash 'session-A')+'.json'))
foreach($leaf in $cleanupEvidence){Write-Utf8 (Join-Path $stateRoot $leaf) 'retained-original'}
$coordination=Join-Path $stateRoot "TestTempCleanup-result-$cleanupKey.json"
Write-Utf8 $coordination '{"schemaVersion":3}'
$cleanupRemoved=Invoke-UninstallProcess -RecordId $cleanupRecord.id -Complete
Check 'cleanup uninstall preserves exact legacy and scoped evidence bytes' ([string]$cleanupRemoved.Result.overall-eq'ok'-and @($cleanupEvidence|Where-Object{[IO.File]::ReadAllText((Join-Path $stateRoot $_),[Text.Encoding]::UTF8)-cne'retained-original'}).Count-eq0) ($cleanupRemoved.Result|ConvertTo-Json -Depth 5)
Check 'cleanup uninstall retires its project coordination signal' (-not(Test-Path -LiteralPath $coordination))

Write-Host '--- complete engine removal retires selected mesh membership ---' -ForegroundColor Cyan
$meshProjects=@((New-Proj 'CompleteMeshA'),(New-Proj 'CompleteMeshB'),(New-Proj 'CompleteMeshC'))
$meshRoutes=New-Object 'Collections.Generic.List[object]'
for($i=0;$i-lt3;$i++){for($j=0;$j-lt3;$j++){
    if($i-eq$j){continue}
    $meshRoutes.Add([pscustomobject]@{id="r$i-$j";enabled=$true;source=[pscustomobject]@{name="P$i";root=$meshProjects[$i];directory='.ai';aliases=@()};destination=[pscustomobject]@{name="P$j";root=$meshProjects[$j];directory='.ai';aliases=@()}})
}}
$meshConfig=Join-Path $Work 'complete-mesh.json'
Write-Utf8 $meshConfig (([pscustomobject]@{version=1;profiles=@([pscustomobject]@{id='complete-mesh';name='Mesh';enabled=$true;routes=$meshRoutes.ToArray()},[pscustomobject]@{id='unrelated-profile';name='Unrelated';enabled=$true;routes=@()})})|ConvertTo-Json -Depth 12)
foreach($project in $meshProjects){
    [void][IO.Directory]::CreateDirectory((Join-Path $project '.ai'))
    & $InstallScript -Profile 'complete-mesh' -ConfigPath $meshConfig -Events @('SessionStart') -TargetProject $project *> $null
}
$meshRecords=@(Get-RecordsFor 'Cross-Project-.ai-Knowledge-Sync'|Where-Object{$_.profile-eq'complete-mesh'})
Check 'mesh setup has three real installed records' ($meshRecords.Count-eq3)
$selectedMesh=@($meshRecords|Where-Object{$_.targetProjectRoot-eq$meshProjects[0]})[0]
. (Join-Path $ScriptRoot '_uninstallresidue.ps1')
. (Join-Path $ScriptRoot '_uninstallsyncstate.ps1')
$stateRoute=@($meshRoutes.ToArray()|Where-Object{$_.id-eq'r0-1'})[0]
$stateEntry=@(Get-UninstallSyncStatePlan -Routes @($stateRoute) -Profile 'complete-mesh')[0]
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $stateEntry.State))
[void][IO.Directory]::CreateDirectory($stateEntry.Inbox)
Write-Utf8 $stateEntry.State (([pscustomobject]@{profileId='complete-mesh';routeId='r0-1';sourceRoot=$meshProjects[0]})|ConvertTo-Json)
$pendingSentinel=Join-Path $stateEntry.Inbox 'review-sentinel.txt';Write-Utf8 $pendingSentinel 'review-evidence'
$meshDry=Invoke-UninstallProcess -RecordId $selectedMesh.id -Complete -WhatIf
Check 'mesh complete dry run validates without retirement' ([string]$meshDry.Result.overall-eq'ok'-and @((Read-JsonFile $meshConfig).profiles[0].routes).Count-eq6) $meshDry.Err
$peerRecord=@($meshRecords|Where-Object{$_.targetProjectRoot-eq$meshProjects[1]})[0]
$peerConfig=Join-Path (Split-Path -Parent ([string]$peerRecord.clients.claude.runtimeScript)) 'sync-hooks.json'
$peerOriginal=[IO.File]::ReadAllBytes($peerConfig)
$selectedSettings=[IO.File]::ReadAllBytes([string]$selectedMesh.clients.claude.settingsPath)
$peerLifecycle=Join-Path (Split-Path -Parent $peerConfig) '_routelifecycle.ps1'
$peerLifecycleBytes=[IO.File]::ReadAllBytes($peerLifecycle)
[IO.File]::AppendAllText($peerLifecycle,"`n# old contract",[Text.Encoding]::UTF8)
$oldPeer=Invoke-UninstallProcess -RecordId $selectedMesh.id -Complete
Check 'unverified peer lifecycle refuses before selected registration changes' ([string]$oldPeer.Result.overall-eq'manualRepair'-and(Test-BytesEqual ([IO.File]::ReadAllBytes([string]$selectedMesh.clients.claude.settingsPath)) $selectedSettings))
[IO.File]::WriteAllBytes($peerLifecycle,$peerLifecycleBytes)
[IO.File]::AppendAllText($peerConfig,"`n ",[Text.Encoding]::UTF8)
$driftedMesh=Invoke-UninstallProcess -RecordId $selectedMesh.id -Complete
Check 'drifted peer routing blocks before selected registration changes' ([string]$driftedMesh.Result.overall-eq'manualRepair'-and(Test-BytesEqual ([IO.File]::ReadAllBytes([string]$selectedMesh.clients.claude.settingsPath)) $selectedSettings)-and(Test-Path -LiteralPath $pendingSentinel))
[IO.File]::WriteAllBytes($peerConfig,$peerOriginal)
$manifestShadow=Join-Path $Work 'manifest-failure-executor'
[void][IO.Directory]::CreateDirectory($manifestShadow)
Copy-Item -Path (Join-Path $ScriptRoot '_*.ps1') -Destination $manifestShadow
$manifestExecutor=Join-Path $manifestShadow 'Uninstall-Hook.ps1'
Copy-Item -LiteralPath $UninstallScript -Destination $manifestExecutor
$manifestModule=Join-Path $manifestShadow '_uninstallsyncmanifest.ps1'
$manifestBody=[IO.File]::ReadAllText($manifestModule,[Text.Encoding]::UTF8)
$manifestAnchor='            Save-InstallRegistry $ToolRoot $working'
Check 'manifest failure injection targets registry publication' ($manifestBody.Contains($manifestAnchor))
Write-Utf8 $manifestModule ($manifestBody.Replace($manifestAnchor,"            Save-InstallRegistry `$ToolRoot `$working; throw 'Controlled manifest commit acknowledgement failure.'"))
$configPreimage=[IO.File]::ReadAllBytes($meshConfig)
$manifestFailure=Invoke-UninstallProcess -RecordId $selectedMesh.id -Complete -ScriptPath $manifestExecutor
Check 'manifest publication failure retains selected tracking' ([string]$manifestFailure.Result.overall-eq'failed'-and @(Get-RecordsFor 'Cross-Project-.ai-Knowledge-Sync'|Where-Object{$_.id-eq$selectedMesh.id}).Count-eq1)
Check 'manifest publication failure restores routing preimages' ((Test-BytesEqual ([IO.File]::ReadAllBytes($meshConfig)) $configPreimage)-and(Test-BytesEqual ([IO.File]::ReadAllBytes($peerConfig)) $peerOriginal))
$restoredPeer=@((Read-InstallRegistry $ToolRoot).installs|Where-Object{$_.id-eq$peerRecord.id})[0]
Check 'manifest publication failure restores peer recorded hashes' (($restoredPeer|ConvertTo-Json -Depth 50 -Compress)-ceq($peerRecord|ConvertTo-Json -Depth 50 -Compress))
$heldRoute=[IO.File]::Open($stateEntry.State,'Open','Read','Read')
try{$blockedRetirement=Invoke-UninstallProcess -RecordId $selectedMesh.id -Complete}finally{$heldRoute.Dispose()}
Check 'locked sync state retains retry journal and tracking' ([string]$blockedRetirement.Result.overall-eq'failed'-and(Test-Path -LiteralPath $stateEntry.State)-and @(Get-RecordsFor 'Cross-Project-.ai-Knowledge-Sync'|Where-Object{$_.id-eq$selectedMesh.id}).Count-eq1)
$meshRemoval=Invoke-UninstallProcess -RecordId $selectedMesh.id -Complete
if([string]$meshRemoval.Result.overall-ne'ok'){Write-Host ($meshRemoval.Result|ConvertTo-Json -Depth 6 -Compress);Write-Host $meshRemoval.Err}
Check 'mesh complete removal succeeds' ([string]$meshRemoval.Result.overall-eq'ok') ($meshRemoval.Result|ConvertTo-Json -Depth 5)
Check 'selected route state and inbox are no longer active' (-not(Test-Path -LiteralPath $stateEntry.State)-and-not(Test-Path -LiteralPath $stateEntry.Inbox))
$retiredSentinels=@(Get-ChildItem -LiteralPath (Join-Path $stateEntry.SyncRoot 'retired') -Filter 'review-sentinel.txt' -Recurse -File)
Check 'pending review evidence survives in retired recovery' ($retiredSentinels.Count-eq1-and[IO.File]::ReadAllText($retiredSentinels[0].FullName,[Text.Encoding]::UTF8)-ceq'review-evidence')
$afterMesh=Read-JsonFile $meshConfig
Check 'canonical mesh retains only the two peer routes' (@($afterMesh.profiles[0].routes).Count-eq2 -and @($afterMesh.profiles[0].routes|Where-Object{$_.id-in@('r1-2','r2-1')}).Count-eq2)
Check 'unrelated profile remains' (@($afterMesh.profiles|Where-Object{$_.id-eq'unrelated-profile'}).Count-eq1)
foreach($peer in @($meshRecords|Where-Object{$_.id-ne$selectedMesh.id})){
    $copy=Read-JsonFile (Join-Path (Split-Path -Parent ([string]$peer.clients.claude.runtimeScript)) 'sync-hooks.json')
    Check 'live peer configuration no longer routes selected member' (@($copy.profiles[0].routes).Count-eq2)
    $livePeer=@((Read-InstallRegistry $ToolRoot).installs|Where-Object{$_.id-eq$peer.id})[0]
    $expected=@(Get-ManagedClientManifest -ToolRoot $ToolRoot -Client claude -HookScript $livePeer.sourceScript -FriendlyName $livePeer.friendlyName -RecordId $livePeer.id -Scope project -ProjectRoot $livePeer.targetProjectRoot -ConfigPath $meshConfig -IncludeConfig -ProfileId $livePeer.profile -TimeoutSeconds $livePeer.clients.claude.timeout)
    $actual=@(Get-InstalledManifest -RuntimeRoot $livePeer.clients.claude.runtimeRoot -FriendlyName $livePeer.friendlyName)
    Check 'peer runtime metadata remains current after retirement' (Compare-Manifest -Expected $expected -Actual $actual).IsMatch
    Check 'peer tracked manifest matches remaining runtime' (Compare-Manifest -Expected $livePeer.clients.claude.installedManifest -Actual $actual).IsMatch
    $expectedSource=@(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $livePeer.sourceScript -SourceDir $livePeer.sourceDir -FriendlyName $livePeer.friendlyName -ConfigPath $meshConfig -IncludeConfig -ProfileId $livePeer.profile -ProjectRoot $livePeer.targetProjectRoot)
    Check 'peer source manifest remains current after retirement' (Compare-Manifest -Expected $livePeer.sourceManifest -Actual $expectedSource).IsMatch
    $codex=@(Get-InstalledManifest -RuntimeRoot $livePeer.clients.codex.runtimeRoot -FriendlyName $livePeer.friendlyName)
    Check 'Codex peer tracked manifest matches remaining runtime' (Compare-Manifest -Expected $livePeer.clients.codex.installedManifest -Actual $codex).IsMatch
}
# Resolve before retirement, then inspect under the real route lock: a waiter
# holding old config must not recreate state after the retirement transaction.
$engineDir=Split-Path -Parent (Join-Path $RealHooksDir 'Cross-Project-.ai-Knowledge-Sync/Cross-Project-.ai-Knowledge-Sync.ps1')
. (Join-Path $engineDir '_routelifecycle.ps1')
$ConfigPath=$meshConfig
$tokens=$null;$errors=$null
$engineAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $engineDir 'Cross-Project-.ai-Knowledge-Sync.ps1'),[ref]$tokens,[ref]$errors)
foreach($functionName in @('Get-StringHash','Get-PropertyValue','Get-EndpointRoots')){
    $definition=@($engineAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object{$_.Name-eq$functionName})[0]
    . ([scriptblock]::Create($definition.Extent.Text))
}
$liveContext=[pscustomobject]@{matchedDestinationRoot=$meshProjects[1];profileId='complete-mesh';routeId='r2-1';route=@($meshRoutes.ToArray()|Where-Object{$_.id-eq'r2-1'})[0]}
$staleContext=[pscustomobject]@{matchedDestinationRoot=$meshProjects[1];profileId='complete-mesh';routeId='r0-1';route=$stateRoute}
$routeLock=Enter-RouteStateLock $stateEntry.State
try{
    Check 'remaining peer route is accepted under the lifecycle lock' (Test-SyncRouteCurrent $liveContext)
    Check 'retired route is rejected from an old resolved context' (-not(Test-SyncRouteCurrent $staleContext))
}finally{$routeLock.ReleaseMutex();$routeLock.Dispose()}
