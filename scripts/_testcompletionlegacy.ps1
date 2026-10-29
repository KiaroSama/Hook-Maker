# Sanitized historical shape controls; no consumer receipt or authorization copied.
function Invoke-LegacyDispositionRegression {
    param([string]$Root,[string]$Work)
    $now=[DateTime]::UtcNow
    $access=[pscustomobject]@{State='available';ProjectKey='2222222222';RepositoryStateFingerprint='aaaaaaaaaa'}
    $doc=[pscustomobject]@{schema=2;runId='legacy-fixture';projectKey=(Get-DeliveryHash (Normalize-Path $Root).ToLowerInvariant()).Substring(0,12);projectFingerprint='';workingDirectory=$Root;commandFingerprint=('b'*32);overall='failed';exitCode=1;terminated=$false;leakedProcessIds=@();startedUtc=$now.AddDays(-3).ToString('o');endedUtc=$now.AddDays(-3).AddSeconds(1).ToString('o')}
    $request=[pscustomobject]@{identityKind='legacy-missing';commandFingerprint=$doc.commandFingerprint;endedUtc=$doc.endedUtc}
    function Assert-Eligibility {
        param($Value,$Request,[bool]$Expected,[string]$Name)
        $accepted=$true
        try{Assert-HistoricalDispositionReceipt $Value $Root 'legacy-fixture' $access $Request}catch{$accepted=$false}
        if($accepted-ne$Expected){throw ('Legacy eligibility: '+$Name)}
    }
    Assert-Eligibility $doc $null $false 'default must reject missing identity'
    Assert-Eligibility $doc $request $true 'explicit exact shape must be eligible'
    foreach($case in @('schema','current','key','unknown','success','terminated','leak','null-leak','recent','root','start','exit','missing-fp','null-fp','state-present','command','time','kind')){
        $copy=$doc|Select-Object *;$req=$request|Select-Object *
        switch($case){
            schema {$copy.schema=1}
            current {$copy.projectFingerprint=$access.RepositoryStateFingerprint}
            key {$copy.projectKey='ffffffffffff'}
            unknown {$copy.overall='unknown'}
            success {$copy.overall='ok';$copy.exitCode=0}
            terminated {$copy.terminated=$true}
            leak {$copy.leakedProcessIds=@(123)}
            null-leak {$copy.leakedProcessIds=$null}
            recent {$copy.endedUtc=$now.ToString('o')}
            root {$copy.workingDirectory=Join-Path $Root 'other'}
            start {$copy.startedUtc='invalid'}
            exit {$copy.exitCode=0}
            missing-fp {$copy.PSObject.Properties.Remove('projectFingerprint')}
            null-fp {$copy.projectFingerprint=$null}
            state-present {$copy|Add-Member NoteProperty repositoryState $null}
            command {$req.commandFingerprint='c'*32}
            time {$req.endedUtc=$now.AddDays(-4).ToString('o')}
            kind {$req.identityKind='unknown'}
        }
        Assert-Eligibility $copy $req $false $case
    }
    $recorded=$doc|Select-Object *;$recorded.projectFingerprint='cccccccccc'
    $recorded|Add-Member NoteProperty repositoryState available
    Assert-Eligibility $recorded $null $true 'recorded backward compatibility'
    Assert-Eligibility $recorded ([pscustomobject]@{identityKind='recorded'}) $true 'explicit recorded'
    Assert-Eligibility $recorded $request $false 'recorded cannot masquerade as missing'
    $access.State='unavailable';Assert-Eligibility $doc $request $false 'unavailable';$access.State='available'
    $utf8=[Text.UTF8Encoding]::new($false)
    $receiptPath=Join-Path $Work 'legacy-original.json';$evidencePath=Join-Path $Work 'legacy-evidence.json';$requestPath=Join-Path $Work 'legacy-request.json'
    $text=$doc|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($receiptPath,$text,$utf8)
    $receipt=Read-RecoveryReceipt $receiptPath
    $evidence=[pscustomobject]@{schema=1;action='retired';runId=$doc.runId;receiptSha256=$receipt.Sha256;projectRoot=$Root;resourceId='synthetic-retired-operation';statement=('Synthetic fixture retirement accepts loss, never recovery or current verification. '*2);occurredUtc=$now.AddDays(-1).ToString('o')}
    [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 8),$utf8)
    $req=[pscustomobject]@{schema=1;identityKind='legacy-missing';runId=$doc.runId;receiptSha256=$receipt.Sha256;projectRoot=$Root;disposition='obsolete';reason=('Fixture-only acceptance of this historical loss, never evidence of current success. '*2);createdUtc=$now.ToString('o');evidencePath=$evidencePath;evidenceSha256=(Read-RecoveryReceipt $evidencePath).Sha256;commandFingerprint=$doc.commandFingerprint;endedUtc=$doc.endedUtc}
    $requestText=$req|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($requestPath,$requestText,$utf8)
    $bundle=Read-DispositionRequest $requestPath
    $script:cwd=$Root;$script:repositoryState=$access
    $script:historicalDispositions=New-Object Collections.Specialized.OrderedDictionary
    $pin=[pscustomobject]@{schema=1;identityKind='legacy-missing';disposition='obsolete';projectRoot=$Root;receiptSha256=$receipt.Sha256;requestPath=$requestPath;requestSha256=$bundle.Request.Sha256;evidenceSha256=$bundle.Evidence.Sha256;authorization=[pscustomobject]@{requestSha256=$bundle.Request.Sha256}}
    $script:historicalDispositions[$doc.runId]=$pin
    $parsed=Read-RecoveryReceipt $receiptPath
    if(-not(Test-HistoricalDisposition $parsed.Doc $receiptPath)){throw 'Persisted exact legacy disposition rejected.'}
    foreach($path in @($receiptPath,$requestPath,$evidencePath)){
        $original=[IO.File]::ReadAllBytes($path)
        [IO.File]::AppendAllText($path,' ',$utf8)
        if(Test-HistoricalDisposition $parsed.Doc $receiptPath){throw 'Changed immutable bytes accepted.'}
        [IO.File]::WriteAllBytes($path,$original)
    }
    $pin.identityKind='recorded'
    if(Test-HistoricalDisposition $parsed.Doc $receiptPath){throw 'Persisted identity kind changed silently.'}
    $pin.identityKind='legacy-missing'
    foreach($field in @('commandFingerprint','endedUtc')){
        $bad=$req|Select-Object *;$bad.PSObject.Properties.Remove($field)
        [IO.File]::WriteAllText($requestPath,($bad|ConvertTo-Json -Depth 8),$utf8)
        $refused=$false;try{$null=Read-DispositionRequest $requestPath}catch{$refused=$true}
        if(-not$refused){throw ('Legacy request omitted '+$field)}
    }
    [IO.File]::WriteAllText($requestPath,$requestText,$utf8)
    $transcript=Join-Path $Work 'legacy-generic-approval.jsonl';$id=[guid]::NewGuid().ToString()
    $record=@{uuid=$id;type='user';sessionId='synthetic-only';cwd=$Root;timestamp=$now.ToString('o');message=@{role='user';content='repair the hook'}}
    [IO.File]::WriteAllText($transcript,(($record|ConvertTo-Json -Depth 6 -Compress)+"`n"),$utf8)
    $refused=$false;try{$null=Get-DispositionAuthorization $transcript $id $bundle.Request.Sha256 $Root $now.AddMinutes(-1)}catch{$refused=$true}
    if(-not$refused){throw 'Generic repair text approved retirement.'}
    if((Read-RecoveryReceipt $receiptPath).Sha256-cne$receipt.Sha256){throw 'Original legacy receipt changed.'}
    Write-Host 'Legacy disposition compatibility controls passed.'
}
