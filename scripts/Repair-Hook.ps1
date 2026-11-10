# Repair one persisted project/client binding; never select a fleet implicitly.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{10}$')][string]$RecordId,
    [Parameter(Mandatory=$true)][ValidateSet('claude','codex')][string]$Client,
    [switch]$Apply
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$toolRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $toolRoot 'hooks/_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installlib.ps1')
. (Join-Path $PSScriptRoot '_installplan.ps1')
. (Join-Path $PSScriptRoot '_installeventmigration.ps1')
. (Join-Path $PSScriptRoot '_installinvoke.ps1')
. (Join-Path $PSScriptRoot '_installlifecycle.ps1')
. (Join-Path $PSScriptRoot '_managementaudit.ps1')
. (Join-Path $PSScriptRoot '_ciworkloadreview.ps1')
$lock=$null;$runtimeLock=$null;$runtimeHeld=$false
$sourceHandles=New-Object 'Collections.Generic.List[IDisposable]'
try {
    Start-ManagementAudit $toolRoot 'Repair-Hook'
    try{$lock=Enter-InstallLifecycle $toolRoot}catch{Stop-CiReview runtime-busy}
    $record=Get-InstallRecordById $toolRoot $RecordId
    if($null-eq$record){Stop-CiReview record-missing}
    if(-not(Test-InstallRecordValid $record).Ok-or-not(Test-IsManagedRecord $record)-or$record.scope-cne'project'-or$record.hookType-cne'CustomHook'){Stop-CiReview record-invalid}
    if((Normalize-Path $record.toolRoot)-ine(Normalize-Path $toolRoot)-or$record.friendlyName-cne'Ci-Status-Check'-or
        (Normalize-Path $record.sourceScript)-ine(Normalize-Path (Join-Path $toolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'))-or
        (Normalize-Path $record.sourceDir)-ine(Normalize-Path (Join-Path $toolRoot 'hooks/Ci-Status-Check'))-or[string]$record.profile-ne''){Stop-CiReview identity-changed}
    $sub=Get-ClientSubrecord $record $Client
    if($null-eq$sub-or-not$sub.installed){Stop-CiReview client-missing}
    if($sub.PSObject.Properties['enabled']-and-not$sub.enabled){Stop-CiReview identity-changed}
    $sourcePath=[IO.Path]::GetFullPath([string]$record.sourceScript)
    $null=Get-RepositoryPhysicalRoot (Split-Path -Parent $sourcePath)
    if(-not(Test-PathContainedIn $sourcePath (Join-Path $toolRoot 'hooks'))){Stop-CiReview identity-changed}
    $project=Get-RepositoryPhysicalRoot $record.targetProjectRoot
    $capability=Get-HookMakerClientCapability $Client
    $settingsPaths=@(Normalize-Path (Join-Path $project $capability.projectRegistration))
    if($Client-ceq'claude'){$settingsPaths+=@(Normalize-Path (Join-Path $project '.claude/settings.json'))}
    foreach($path in $settingsPaths){
        if((Test-Path -LiteralPath $path)-and(-not(Test-Path -LiteralPath $path -PathType Leaf)-or(Test-IsReparsePoint $path))){Stop-CiReview identity-changed}
    }
    $expectedSettings=Normalize-Path (Get-CanonicalClientSettingsPath $Client project $project)
    # Neither client may acquire a second registration while following a saved binding.
    foreach($path in $settingsPaths){
        if($path-ine$expectedSettings-and@(Get-HookRegistrations $path $sub.runtimeScript $record.profile).Count){Stop-CiReview registration-stale}
    }
    $expectedRuntimeRoot=Normalize-Path (Join-Path $project $capability.runtimeRelativeRoot)
    $expectedScript=Normalize-Path (Join-Path $expectedRuntimeRoot ($record.friendlyName+'/'+$record.friendlyName+'.ps1'))
    if((Normalize-Path $sub.settingsPath)-ine$expectedSettings-or(Normalize-Path $sub.runtimeRoot)-ine$expectedRuntimeRoot-or(Normalize-Path $sub.runtimeScript)-ine$expectedScript){Stop-CiReview identity-changed}
    $null=Get-RepositoryPhysicalRoot (Split-Path -Parent $sub.settingsPath)
    $directory=Get-RepositoryPhysicalRoot (Split-Path -Parent $sub.runtimeScript)
    $runtimeLock=New-ManagedRuntimeMutex $directory
    try{$runtimeHeld=$runtimeLock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$runtimeHeld=$true}
    if(-not$runtimeHeld){Stop-CiReview runtime-busy}
    $owner=Read-JsonFile (Join-Path $directory '.hookmaker-runtime.json')
    if($null-eq$owner-or$owner.recordId-cne$RecordId-or$owner.client-cne$Client-or$owner.friendlyName-cne$record.friendlyName-or$owner.scope-cne'project'-or$owner.projectKey-cne(Get-RuntimeMetadataProjectKey project $project)){Stop-CiReview identity-changed}
    $timeout=$script:DefaultHookTimeoutSeconds
    if($sub.PSObject.Properties['timeout']){$timeout=[int]$sub.timeout}
    $registration=Test-ClientRegistrationState -SettingsPath $sub.settingsPath -RuntimeScript $sub.runtimeScript -ExpectedEvents @($sub.events) -ProfileId $record.profile -ExpectedCommand $sub.command -ExpectedCommandWindows $sub.commandWindows -ExpectedHandlerType $sub.handlerType -ExpectedTimeout $timeout
    if(-not$registration.Ok){Stop-CiReview registration-stale}
    # Source staleness is repairable; independent installed bytes are not ours to replace.
    $precondition=Test-EventMigrationPrecondition $record $Client
    if(-not$precondition.Ok){Stop-CiReview identity-changed}
    $identity=Get-InstallRecordId $record.friendlyName (Normalize-Path $record.targetProjectRoot).ToLowerInvariant() $record.profile
    if($identity-cne$RecordId){Stop-CiReview identity-changed}
    $manifest=@(Get-ManagedSourceManifest -ToolRoot $toolRoot -HookScript $record.sourceScript -SourceDir $record.sourceDir -FriendlyName $record.friendlyName -ProfileId $record.profile -ProjectRoot $record.targetProjectRoot)
    Write-Output ('Repair '+$(if($Apply){'apply'}else{'preview'})+': record='+$RecordId+'; client='+$Client+'; events='+(@($sub.events)-join',')+'; timeout='+$timeout+'. Saved binding/policy retained; other clients untouched.')
    if(-not$Apply){exit 0}
    $repairPreimage=[pscustomobject]@{Record=$record;Client=$Client;Settings=@();Config=@()}
    foreach($path in $settingsPaths){
        if((Test-Path -LiteralPath $path)-and(-not(Test-Path -LiteralPath $path -PathType Leaf)-or(Test-IsReparsePoint $path))){Stop-CiReview identity-changed}
        $repairPreimage.Settings+=@([pscustomobject]@{Path=$path;Hash=Get-FileSha256 $path})
    }
    foreach($leaf in @(Get-ManagedRuntimeUserConfigNames $record.friendlyName)){
        $path=Join-Path $directory $leaf
        if((Test-Path -LiteralPath $path)-and(-not(Test-Path -LiteralPath $path -PathType Leaf)-or(Test-IsReparsePoint $path))){Stop-CiReview policy-mismatch}
        $repairPreimage.Config+=@([pscustomobject]@{Path=$path;Hash=Get-FileSha256 $path})
    }
    # Cooperative locks do not cover an independent editor during staging. Check
    # the exact destination again before rename; this is not an OS-wide exchange.
    $repairBeforeCommit={
        if(-not(Test-EventMigrationPrecondition $repairPreimage.Record $repairPreimage.Client).Ok){Stop-CiReview identity-changed}
        foreach($item in $repairPreimage.Settings){
            if((Test-Path -LiteralPath $item.Path)-and(-not(Test-Path -LiteralPath $item.Path -PathType Leaf)-or(Test-IsReparsePoint $item.Path))){Stop-CiReview registration-stale}
            if((Get-FileSha256 $item.Path)-cne$item.Hash){Stop-CiReview registration-stale}
        }
        foreach($item in $repairPreimage.Config){
            if((Test-Path -LiteralPath $item.Path)-and(-not(Test-Path -LiteralPath $item.Path -PathType Leaf)-or(Test-IsReparsePoint $item.Path))){Stop-CiReview policy-mismatch}
            if((Get-FileSha256 $item.Path)-cne$item.Hash){Stop-CiReview policy-mismatch}
        }
    }
    # Deny writes/deletion of existing payload inputs until publication finishes.
    $plan=@(Get-InstallPlanFor -HookScript $record.sourceScript -ToolRoot $toolRoot -FriendlyNameOverride $record.friendlyName -ProjectRoot $record.targetProjectRoot)
    $paths=@($record.sourceScript)+@($plan|Where-Object{$_.kind-ceq'File'}|ForEach-Object{$_.sourcePath})
    foreach($path in @($paths|Select-Object -Unique)){$sourceHandles.Add([IO.File]::Open($path,'Open','Read','Read'))}
    $pinned=@(Get-ManagedSourceManifest -ToolRoot $toolRoot -HookScript $record.sourceScript -SourceDir $record.sourceDir -FriendlyName $record.friendlyName -ProjectRoot $record.targetProjectRoot)
    if(-not(Compare-Manifest $manifest $pinned).IsMatch){Stop-CiReview source-stale}
    $installerArgs=@{CustomHook=$record.sourceScript;TargetProject=$record.targetProjectRoot;Clients=@($Client);Events=@($sub.events);Timeout=$timeout;ExpectedSourceManifest=$manifest;BeforeRuntimeCommit=$repairBeforeCommit}
    $verdict=Invoke-HookInstaller -InstallScript (Join-Path $PSScriptRoot 'Install-Hook.ps1') -InstallArgs $installerArgs
    if(-not$verdict.Ok){throw 'Selected repair did not complete; inspect installer log.'}
    $fresh=Get-InstallRecordById $toolRoot $RecordId
    $source=@(Get-ManagedSourceManifest -ToolRoot $toolRoot -HookScript $record.sourceScript -SourceDir $record.sourceDir -FriendlyName $record.friendlyName -ProfileId $record.profile -ProjectRoot $record.targetProjectRoot)
    if(-not(Compare-Manifest $manifest $source).IsMatch){Stop-CiReview source-stale}
    $integrity=Get-InstallIntegrity $fresh $toolRoot
    $bad=@($integrity.Components|Where-Object{$_.Name-in@('source',$Client)-and$_.Status-cne'current'})
    if($bad.Count){Stop-CiReview payload-stale}
    Write-ManagementAudit -Event 'repair-complete' -Data @{recordId=$RecordId;client=$Client;outcome='ok'}
    Write-Output 'Selected repair verified; review enrollment and CI evidence remain separate.'
}catch {
    Write-ManagementAudit -Event 'repair-refused' -Data @{recordId=$RecordId;client=$Client;outcome='failed'}
    [Console]::Error.WriteLine((Get-CiReviewFailureMessage $_ repair $toolRoot $RecordId $Client))
    exit 1
}finally{foreach($handle in $sourceHandles){$handle.Dispose()};if($null-ne$runtimeLock){if($runtimeHeld){$runtimeLock.ReleaseMutex()};$runtimeLock.Dispose()};if($null-ne$lock){$lock.ReleaseMutex();$lock.Dispose()}}
