# Preserve owner review before the existing owned-runtime removal. Recovery is
# outside the runtime, so uninstall never destroys the only reviewed original.
function Remove-ClientComponent {
    param([Parameter(Mandatory=$true)][string]$ClientName)
    if($FriendlyName-cne'Ci-Status-Check'-or$WhatIf){return Remove-ClientComponentCore $ClientName}
    $sub=Get-ClientSubrecord $record $ClientName
    if($null-eq$sub){return Remove-ClientComponentCore $ClientName}
    $identity=Test-ClientRecordIdentity -Subrecord $sub -ClientName $ClientName
    if(-not$identity.Ok){return Remove-ClientComponentCore $ClientName}
    $mutex=New-ManagedRuntimeMutex $identity.HookDir
    $held=$false
    try{
        try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not$held){throw 'Selected runtime is busy; uninstall refused.'}
        $scan=Get-ClientHandlerScan -SettingsPath $identity.CanonicalSettingsPath -Subrecord $sub -CanonicalRuntimeScript $identity.CanonicalRuntimeScript
        if($scan.NearMatch){return Remove-ClientComponentCore $ClientName}
        $review=Join-Path $identity.HookDir '_ci-policy.json'
        if(Test-Path -LiteralPath $review){
            . (Join-Path $PSScriptRoot '_ciworkloadreview.ps1')
            $bytes=Read-CiReviewBytes $review
            $null=Save-CiReviewRecovery $ToolRoot $RecordId $ClientName $bytes $bytes
        }
        return Remove-ClientComponentCore $ClientName
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
