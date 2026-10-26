# Preserve owner review before the existing owned-runtime removal. Recovery is
# outside the runtime, so uninstall never destroys the only reviewed original.
function Remove-ClientComponent {
    param([Parameter(Mandatory=$true)][string]$ClientName)
    if($WhatIf){return Remove-ClientComponentCore $ClientName}
    $sub=Get-ClientSubrecord $record $ClientName
    if($null-eq$sub){return Remove-ClientComponentCore $ClientName}
    $identity=Test-ClientRecordIdentity -Subrecord $sub -ClientName $ClientName
    if(-not$identity.Ok){return Remove-ClientComponentCore $ClientName}
    $mutex=New-ManagedRuntimeMutex $identity.HookDir
    $held=$false
    try{
        try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not$held){throw 'Selected runtime is busy; uninstall refused.'}
        Assert-UninstallRegularPath $identity.CanonicalSettingsPath
        Assert-UninstallTree $identity.HookDir
        $live=Read-InstallRegistryState $ToolRoot
        if($live.State-ne'ok'){throw 'Registry unavailable under runtime lock; no component removed.'}
        $registry=ConvertTo-InstallRegistryCurrent $live.Registry
        $liveRecord=@($registry.installs|Where-Object{[string]$_.id-ceq$RecordId})
        if($liveRecord.Count-ne1){throw 'Selected installation disappeared under runtime lock.'}
        $liveSub=Get-ClientSubrecord $liveRecord[0] $ClientName
        if(($liveSub|ConvertTo-Json -Depth 30 -Compress)-cne($sub|ConvertTo-Json -Depth 30 -Compress)){throw 'Selected client changed before removal.'}
        $pending=[string](Get-Field $sub 'uninstallStagedRuntime')
        if($pending-ne''){
            Assert-UninstallRegularPath $pending
            if((Split-Path -Parent $pending)-ine$identity.CanonicalRuntimeRoot-or(Split-Path -Leaf $pending)-notlike('.hookmaker-uninstall-'+$FriendlyName+'-*')){throw 'Retained runtime cleanup identity is invalid.'}
            if(Test-Path -LiteralPath $pending){
                Assert-UninstallTree $pending
                if(Test-Path -LiteralPath $identity.HookDir){throw 'Both live and retained runtime paths exist; manual repair required.'}
                Move-Item -LiteralPath $pending -Destination $identity.HookDir -ErrorAction Stop
            }
        }
        $scan=Get-ClientHandlerScan -SettingsPath $identity.CanonicalSettingsPath -Subrecord $sub -CanonicalRuntimeScript $identity.CanonicalRuntimeScript
        if($scan.NearMatch){return Remove-ClientComponentCore $ClientName}
        if($FriendlyName-ceq'Ci-Status-Check'){
            foreach($name in @('_ci-policy.json','_docs-policy.json')){
                $review=Join-Path $identity.HookDir $name
                if(-not(Test-Path -LiteralPath $review)){continue}
                . (Join-Path $PSScriptRoot '_ciworkloadreview.ps1')
                $bytes=Read-CiReviewBytes $review
                $null=Save-CiReviewRecovery $ToolRoot $RecordId $ClientName $bytes $bytes -PolicyName $name
            }
        }
        return Remove-ClientComponentCore $ClientName
    }catch{
        Set-ComponentResult -Component $ClientName -Status 'failed' -ReasonCode 'runtimeOwnershipOrCleanupFailed' -Message $_.Exception.Message
        return [pscustomobject]@{Removed=$false}
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
