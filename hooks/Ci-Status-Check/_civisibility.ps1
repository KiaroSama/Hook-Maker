# REST jobs/steps prove execution only. There is no universal test-case or UI
# API: report that limitation rather than synthesizing coverage from green jobs.
function Get-CiVisibilityReminder {
    param([string]$Sha)
    $message='CI execution verified: '+$Sha+'. Suite/case reports + commit/check UI UNVERIFIED. BEFORE all-test claim: global-github-automation-rules.md Section8 FULL. Missing proof BLOCKS; reporter cannot mask test failure. No auto dispatch/upload/token/permissions.'
    return $message
}
function Write-CiVisibilityReminder {
    param($HookInput,[string]$Sha,[string]$StateDirectory,[string]$EventName)
    $key=Get-ShortHash (Normalize-Path ([string](Get-Field $HookInput 'cwd'))).ToLowerInvariant()
    $claim=Invoke-DeliveryClaim -Path (Join-Path $StateDirectory ('CiStatusCheck-Visibility-'+$key+'.claims.json')) -Identity (Get-DeliveryIdentity $HookInput) -Fingerprint $Sha
    if($claim.Admitted){$null=Write-HookResult -EventName $EventName -Kind advisory -Message (Get-CiVisibilityReminder $Sha)}
    elseif(-not$claim.Ok){$null=Write-HookResult -EventName $EventName -Kind advisory -Message ('CI visibility reservation UNVERIFIED; '+(Get-CiVisibilityReminder $Sha))}
}
