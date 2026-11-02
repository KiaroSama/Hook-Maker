# Public diagnostic contract: unavailable access is not an invalid historical pin.
function Invoke-DispositionAccessRegression {
    param([string]$Root)
    & {
        param($Root)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_disposition.ps1')
        function Write-Finding { param([bool]$Blocking,[string[]]$Lines) if(-not$Blocking){throw 'Historical uncertainty must still block.'};throw ($Lines-join' ') }
        $script:historicalDispositions=@{historical=[pscustomobject]@{}}
        foreach($kind in @('unavailable','empty','invalid')) {
            $script:repositoryState=[pscustomobject]@{State=$(if($kind-eq'unavailable'){'unavailable'}else{'available'});RepositoryStateFingerprint=$(if($kind-eq'empty'){''}else{'1234567890'});Diagnosis='gitTimedOut'}
            $message=''
            try{Assert-PersistedDispositions @()}catch{$message=$_.Exception.Message}
            if($kind-eq'invalid') {
                if($message-notmatch'historical disposition no longer validates'){throw 'Invalid pin diagnostic was lost.'}
            }elseif($message-notmatch'UNKNOWN'-or$message-notmatch'gitTimedOut'-or$message-match'no longer validates') {throw ('Unavailable access mislabeled invalid: '+$kind)}
        }
        $script:historicalDispositions=@{}
        Assert-PersistedDispositions @()
        Write-Output 'Disposition access: 4 controls passed.'
    } $Root
}
