# Deterministic admission races at the repository adapter seam: mutate exactly
# between the two production validation reads, without timing sleeps or threads.
function Invoke-DispositionAdmissionRegression {
    param([string]$Root, [string]$Work)
    . (Join-Path $Root 'hooks/Test-Completion-Check/_dispositionauthorization.ps1')
    $script:cwd=$Root
    $script:pendingNotes=New-Object Collections.Specialized.OrderedDictionary
    $script:MalformedEvidence=New-Object 'Collections.Generic.List[string]'
    $script:activeMarkerMaxHours=12
    $script:AdmissionCase=''
    $script:AdmissionReads=0
    $receiptPath=Join-Path $Work 'admission-receipt.json'
    $evidencePath=Join-Path $Work 'admission-evidence.json'
    $requestPath=Join-Path $Work 'admission-request.json'
    $transcriptPath=Join-Path $Work 'admission-transcript.jsonl'
    $recordId=[guid]::NewGuid().ToString()
    $receipt=[pscustomobject]@{schema=2;workingDirectory=$Root;runId='admission';commandFingerprint=('a'*32);projectFingerprint='1234567890';repositoryState='available';overall='failed';exitCode=1;terminated=$false;leakedProcessIds=@();startedUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o');endedUtc=[DateTime]::UtcNow.AddDays(-2).AddSeconds(1).ToString('o')}
    $utf8=[Text.UTF8Encoding]::new($false)
    $receiptText=$receipt|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($receiptPath,$receiptText,$utf8)
    $originalHash=(Read-RecoveryReceipt $receiptPath).Sha256
    $evidence=[pscustomobject]@{schema=1;projectRoot=$Root;runId='admission';receiptSha256=$originalHash;action='retired';resourceId='admission-fixture';statement='The isolated fixture resource was retired after this historical failure. This attestation accepts loss without claiming successful recovery or current verification.';occurredUtc=[DateTime]::UtcNow.AddMinutes(-10).ToString('o')}
    $evidenceText=$evidence|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($evidencePath,$evidenceText,$utf8)
    $request=[pscustomobject]@{schema=1;projectRoot=$Root;runId='admission';receiptSha256=$originalHash;disposition='obsolete';reason='The fixture owner explicitly accepts this exact historical loss after reviewing resource retirement. Only repetition of this obligation may end; no success is claimed.';evidencePath=$evidencePath;evidenceSha256=(Read-RecoveryReceipt $evidencePath).Sha256;createdUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')}
    $requestText=$request|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($requestPath,$requestText,$utf8)
    $authorization=[pscustomobject]@{type='user';uuid=$recordId;sessionId='isolated-admission';cwd=$Root;timestamp=[DateTime]::UtcNow.ToString('o');message=[pscustomobject]@{role='user';content=('::test-disposition '+(Read-RecoveryReceipt $requestPath).Sha256)}}
    $authorizationText=($authorization|ConvertTo-Json -Depth 8 -Compress)+"`n"
    [IO.File]::WriteAllText($transcriptPath,$authorizationText,$utf8)
    # Only these slow/external adapter seams are replaced. Request, receipt,
    # authorization and the admission implementation all read actual fixture bytes.
    $script:AdmissionReceiptDoc=$receipt
    $script:AdmissionReceiptPath=$receiptPath
    function Get-CompletionStateEntries {
        param($Kind)
        if($Kind-eq'result'){return [pscustomobject]@{Doc=$script:AdmissionReceiptDoc;Path=$script:AdmissionReceiptPath}}
        return @()
    }
    function Get-ResultIncidentKey {param($Doc,$Path) return 'fixture-incident'}
    function Get-RepositoryStateEvidence {
        param($ProjectRoot)
        $script:AdmissionReads++
        $fingerprint='0987654321'
        if($script:AdmissionReads-eq2){
            switch($script:AdmissionCase){
                request {[IO.File]::AppendAllText($requestPath,"`n",$utf8)}
                evidence {[IO.File]::AppendAllText($evidencePath,"`n",$utf8)}
                receipt {[IO.File]::AppendAllText($receiptPath,"`n",$utf8)}
                authorization {[IO.File]::WriteAllText($transcriptPath,$authorizationText.Replace('isolated-admission','changed-session'),$utf8)}
                state {$fingerprint='1111111111'}
            }
        }
        return [pscustomobject]@{State='available';RepositoryStateFingerprint=$fingerprint;ProjectKey='2222222222'}
    }
    $checks=0
    foreach($case in @('positive','capacity','conflict','request','evidence','receipt','authorization','state','note')){
        [IO.File]::WriteAllText($receiptPath,$receiptText,$utf8)
        [IO.File]::WriteAllText($evidencePath,$evidenceText,$utf8)
        [IO.File]::WriteAllText($requestPath,$requestText,$utf8)
        [IO.File]::WriteAllText($transcriptPath,$authorizationText,$utf8)
        $script:historicalDispositions=New-Object Collections.Specialized.OrderedDictionary
        $script:pendingNotes.Clear();$script:AdmissionReads=0;$script:AdmissionCase=$case
        if($case-eq'capacity'){foreach($i in 1..50){$script:historicalDispositions['existing-'+$i]=[pscustomobject]@{runId=('existing-'+$i);requestSha256=('b'*64)}}}
        if($case-eq'conflict'){$script:historicalDispositions['admission']=[pscustomobject]@{runId='admission';requestSha256=('b'*64)}}
        if($case-eq'note'){$script:pendingNotes['fixture-incident']=[pscustomobject]@{key='fixture-incident'}}
        $before=ConvertTo-Json -InputObject @($script:historicalDispositions.Values) -Depth 8 -Compress
        $failure=''
        try{Set-HistoricalDisposition $requestPath $transcriptPath $recordId}catch{$failure=$_.Exception.Message}
        if($case-eq'positive'){
            if($failure-or$script:historicalDispositions.Count-ne1-or$script:historicalDispositions['admission'].receiptSha256-cne$originalHash){throw ('Valid admission control did not exercise publication: '+$failure)}
        }else{
            $expected=switch($case){capacity{'capacity reached'}conflict{'cannot be silently replaced'}evidence{'Retirement/cancellation evidence does not match'}authorization{'Authorization changed'}note{'note obligation'}default{'evidence changed during validation'}}
            if($failure-notmatch[regex]::Escape($expected)){throw ('Admission negative did not reach its intended refusal: '+$case+'; '+$failure)}
            $after=ConvertTo-Json -InputObject @($script:historicalDispositions.Values) -Depth 8 -Compress
            if($before-cne$after){throw ('Refused admission changed existing dispositions: '+$case)}
            if($case-ne'receipt'-and(Read-RecoveryReceipt $receiptPath).Sha256-cne$originalHash){throw ('Admission modified original receipt: '+$case)}
            if($case-eq'receipt'-and[IO.File]::ReadAllText($receiptPath,[Text.Encoding]::UTF8)-cne($receiptText+"`n")){throw 'Admission rewrote the concurrently changed original receipt.'}
        }
        $checks++
    }
    Write-Host ('Historical admission: '+$checks+' deterministic controls passed.')
}
