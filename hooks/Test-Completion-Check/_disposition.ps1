# Historical acceptance is not recovery or current test evidence. Original bytes
# and the reviewed resource attestation remain the authority on every use.
function Assert-HistoricalDispositionReceipt {
    param($Doc, [string]$Root, [string]$RunId, $Access)
    $fp=[string](Get-Field $Doc 'projectFingerprint')
    $exitCode=0
    $leaks=$Doc.PSObject.Properties['leakedProcessIds']
    $start=ConvertTo-UtcTime (Get-Field $Doc 'startedUtc')
    $end=ConvertTo-UtcTime (Get-Field $Doc 'endedUtc')
    if($Access.State-cne'available'-or[string]::IsNullOrWhiteSpace([string]$Access.RepositoryStateFingerprint)){throw 'Disposition requires current verified repository access.'}
    if((Get-Field $Doc 'schema')-ne2-or[string](Get-Field $Doc 'runId')-cne$RunId-or
        -not[string]::Equals((Normalize-Path ([string](Get-Field $Doc 'workingDirectory'))),(Normalize-Path $Root),[StringComparison]::OrdinalIgnoreCase)-or
        [string](Get-Field $Doc 'repositoryState')-cne'available'-or$fp-cnotmatch'^[a-f0-9]{10}$'-or$fp-ceq$Access.ProjectKey-or$fp-ceq$Access.RepositoryStateFingerprint-or
        [string](Get-Field $Doc 'commandFingerprint')-cnotmatch'^[a-f0-9]{32}$'-or[string](Get-Field $Doc 'overall')-cne'failed'-or
        -not[int]::TryParse([string](Get-Field $Doc 'exitCode'),[ref]$exitCode)-or$exitCode-eq0-or
        (Get-Field $Doc 'terminated')-ne$false-or$null-eq$leaks-or$leaks.Value-isnot[array]-or$leaks.Value.Count-ne0-or
        $null-eq$start-or$null-eq$end-or$end-lt$start-or$end-gt[DateTime]::UtcNow.AddHours(-24)){throw 'Only a fully identified, ended, noncurrent historical failure without termination or leaks can be disposed.'}
}

function Read-DispositionDocument {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if($item.PSIsContainer-or$item.Length-gt65536){throw 'Disposition documents must be regular files of at most 64 KiB.'}
    if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Linked disposition evidence is refused.'}
    $part=$item.Directory
    while($null-ne$part){if(($part.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Linked disposition evidence is refused.'};$part=$part.Parent}
    $value=Read-RecoveryReceipt $full
    if((Get-Item -LiteralPath $full -Force).Length-gt65536){throw 'Disposition evidence changed beyond its size bound.'}
    if($value.Doc-isnot[pscustomobject]){throw 'Malformed disposition document.'}
    return $value
}

function Read-DispositionRequest {
    param([string]$Path)
    $request=Read-DispositionDocument $Path;$d=$request.Doc
    $created=ConvertTo-UtcTime (Get-Field $d 'createdUtc')
    if((Get-Field $d 'schema')-ne1-or[string](Get-Field $d 'runId')-cnotmatch'^[A-Za-z0-9._-]{1,128}$'-or
        [string](Get-Field $d 'receiptSha256')-cnotmatch'^[a-f0-9]{64}$'-or[string](Get-Field $d 'evidenceSha256')-cnotmatch'^[a-f0-9]{64}$'-or
        [string](Get-Field $d 'disposition')-cnotin@('obsolete','cancelled')-or
        [Text.Encoding]::UTF8.GetByteCount(([string](Get-Field $d 'reason')).Trim())-lt80-or
        $null-eq$created-or$created-gt[DateTime]::UtcNow){throw 'Disposition request has missing or invalid exact identity, reason or timestamp.'}
    $evidence=Read-DispositionDocument ([string](Get-Field $d 'evidencePath'));$e=$evidence.Doc
    $at=ConvertTo-UtcTime (Get-Field $e 'occurredUtc')
    $expected=if($d.disposition-ceq'obsolete'){'retired'}else{'cancelled'}
    if($evidence.Sha256-cne$d.evidenceSha256-or(Get-Field $e 'schema')-ne1-or
        [string](Get-Field $e 'action')-cne$expected-or[string](Get-Field $e 'runId')-cne$d.runId-or
        [string](Get-Field $e 'receiptSha256')-cne$d.receiptSha256-or
        -not[string]::Equals((Normalize-Path ([string](Get-Field $e 'projectRoot'))),(Normalize-Path ([string](Get-Field $d 'projectRoot'))),[StringComparison]::OrdinalIgnoreCase)-or
        [string]::IsNullOrWhiteSpace([string](Get-Field $e 'resourceId'))-or([string]$e.resourceId).Length-gt256-or
        [Text.Encoding]::UTF8.GetByteCount(([string](Get-Field $e 'statement')).Trim())-lt80-or$null-eq$at-or$at-gt$created){throw 'Retirement/cancellation evidence does not match the exact request.'}
    return [pscustomobject]@{Request=$request;Evidence=$evidence}
}

function Assert-DispositionCleanup {
    param($Entries)
    foreach($active in @(Get-CompletionStateEntries 'active')){
        $state=Get-ActiveMarkerState -Doc $active.Doc -Path $active.Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $Entries
        if($state.State-in@('live','died')){throw 'Active or unknown process ownership prevents disposition.'}
    }
    if($script:MalformedEvidence.Count-gt0){throw 'Malformed project evidence prevents disposition.'}
}

function Set-HistoricalDisposition {
    param([string]$RequestPath,[string]$Transcript,[string]$RecordId)
    $bundle=Read-DispositionRequest $RequestPath;$request=$bundle.Request;$d=$request.Doc
    if(-not[string]::Equals((Normalize-Path $d.projectRoot),(Normalize-Path $script:cwd),[StringComparison]::OrdinalIgnoreCase)){throw 'Disposition project mismatch.'}
    $access=Get-RepositoryStateEvidence $script:cwd
    $entries=@(Get-CompletionStateEntries 'result')
    $matchingEntries=@($entries|Where-Object{[string](Get-Field $_.Doc 'runId')-ceq$d.runId})
    if($matchingEntries.Count-ne1){throw 'Disposition requires exactly one canonical receipt for this run.'}
    $receipt=Read-RecoveryReceipt $matchingEntries[0].Path
    if($receipt.Sha256-cne$d.receiptSha256){throw 'Disposition receipt hash mismatch.'}
    Assert-HistoricalDispositionReceipt $receipt.Doc $script:cwd $d.runId $access
    if((ConvertTo-UtcTime $bundle.Evidence.Doc.occurredUtc)-le(ConvertTo-UtcTime $receipt.Doc.endedUtc)){throw 'Retirement must follow the failed operation.'}
    $auth=Get-DispositionAuthorization $Transcript $RecordId $request.Sha256 $script:cwd (ConvertTo-UtcTime $d.createdUtc)
    Assert-DispositionCleanup $entries
    if($script:pendingNotes.Contains((Get-ResultIncidentKey $receipt.Doc $receipt.Path))){throw 'An unresolved note obligation cannot be waived by disposition.'}
    $prior=$script:historicalDispositions[$d.runId]
    if($null-ne$prior-and[string](Get-Field $prior 'requestSha256')-cne$request.Sha256){throw 'An existing disposition cannot be silently replaced.'}
    if($null-eq$prior-and$script:historicalDispositions.Count-ge50){throw 'Disposition capacity reached; no historical record was evicted.'}
    # The ledger mutex does not lock producers or attestation files. Re-read all
    # pins and project ownership immediately before atomic ledger publication.
    # Acquisition can spend the remaining identity budget. Re-read immutable
    # pins afterwards so changes during that wait cannot enter the ledger.
    $after=Get-RepositoryStateEvidence $script:cwd
    $last=Read-DispositionRequest $request.Path
    $latest=@(Get-CompletionStateEntries 'result'|Where-Object{[string](Get-Field $_.Doc 'runId')-ceq$d.runId})
    if($latest.Count-ne1-or$latest[0].Path-cne$receipt.Path-or(Read-RecoveryReceipt $receipt.Path).Sha256-cne$receipt.Sha256-or
        $last.Request.Sha256-cne$request.Sha256-or$last.Evidence.Sha256-cne$bundle.Evidence.Sha256-or
        $after.State-cne'available'-or$after.RepositoryStateFingerprint-cne$access.RepositoryStateFingerprint){throw 'Disposition evidence changed during validation.'}
    Assert-DispositionCleanup $entries
    $finalAuth=Get-DispositionAuthorization $Transcript $RecordId $request.Sha256 $script:cwd (ConvertTo-UtcTime $d.createdUtc)
    if(($finalAuth|ConvertTo-Json -Compress)-cne($auth|ConvertTo-Json -Compress)){throw 'Authorization changed during disposition validation.'}
    $script:historicalDispositions[$d.runId]=[pscustomobject][ordered]@{
        schema=1;runId=$d.runId;projectRoot=(Normalize-Path $script:cwd);receiptSha256=$receipt.Sha256
        commandFingerprint=[string]$receipt.Doc.commandFingerprint;endedUtc=$receipt.Doc.endedUtc
        disposition=$d.disposition;requestPath=$request.Path;requestSha256=$request.Sha256
        evidencePath=$bundle.Evidence.Path;evidenceSha256=$bundle.Evidence.Sha256
        admissionFingerprint=$access.RepositoryStateFingerprint;authorization=$auth;recordedUtc=[DateTime]::UtcNow.ToString('o')
    }
}

function Assert-PersistedDispositions {
    param($Entries)
    foreach($id in @($script:historicalDispositions.Keys)){
        $matchingEntries=@($Entries|Where-Object{[string](Get-Field $_.Doc 'runId')-ceq$id})
        if($matchingEntries.Count-ne1-or-not(Test-HistoricalDisposition $matchingEntries[0].Doc $matchingEntries[0].Path)){
            Write-Finding -Blocking $true -Lines @('TEST COMPLETION CHECK: historical disposition no longer validates for runId='+$id+'. Original failure remains unresolved; verify exact receipt, resource evidence and repository identity. No current success was inferred.')
        }
    }
}

function Test-HistoricalDisposition {
    param($Doc,[string]$Path)
    $values=Get-Variable historicalDispositions -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $id=[string](Get-Field $Doc 'runId')
    if($null-eq$values-or-not$values.Contains($id)){return $false}
    try{
        $pin=$values[$id];$state=$script:repositoryState
        if((Get-Field $pin 'schema')-ne1-or[string](Get-Field $pin 'disposition')-cnotin@('obsolete','cancelled')-or
            [string](Get-Field (Get-Field $pin 'authorization') 'requestSha256')-cne[string](Get-Field $pin 'requestSha256')-or
            -not[string]::Equals((Normalize-Path ([string](Get-Field $pin 'projectRoot'))),(Normalize-Path $script:cwd),[StringComparison]::OrdinalIgnoreCase)){return $false}
        Assert-HistoricalDispositionReceipt $Doc $script:cwd $id $state
        if((Read-RecoveryReceipt $Path).Sha256-cne$pin.receiptSha256){return $false}
        $bundle=Read-DispositionRequest $pin.requestPath
        if([string]$bundle.Request.Doc.disposition-cne[string]$pin.disposition-or
            -not[string]::Equals((Normalize-Path $bundle.Request.Doc.projectRoot),(Normalize-Path $script:cwd),[StringComparison]::OrdinalIgnoreCase)){return $false}
        return $bundle.Request.Sha256-ceq$pin.requestSha256-and$bundle.Evidence.Sha256-ceq$pin.evidenceSha256-and
            [string]$bundle.Request.Doc.runId-ceq$id-and[string]$bundle.Request.Doc.receiptSha256-ceq$pin.receiptSha256
    }catch{return $false}
}
