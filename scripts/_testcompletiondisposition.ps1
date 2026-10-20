# One cheap public validation seam; actual CLI/host coverage belongs to CI.
function Invoke-DispositionRegression {
    param([string]$Root)
    $module = New-Module -ArgumentList $Root -ScriptBlock {
        param($Root)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_identity.ps1')
        $helper = Join-Path $Root 'hooks/Test-Completion-Check/_disposition.ps1'
        if (-not [IO.File]::Exists($helper)) { throw 'Historical disposition validation is not implemented.' }
        . $helper
        $receipt = [pscustomobject]@{ schema=2; workingDirectory=$Root; runId='historical'; commandFingerprint=('a'*32); projectFingerprint='1234567890'; repositoryState='available'; overall='failed'; exitCode=1; terminated=$false; leakedProcessIds=@(); startedUtc=[DateTime]::UtcNow.AddDays(-2).ToString('o'); endedUtc=[DateTime]::UtcNow.AddDays(-2).AddSeconds(1).ToString('o') }
        $access = [pscustomobject]@{ State='available'; RepositoryStateFingerprint='0987654321'; ProjectKey='2222222222' }
        Assert-HistoricalDispositionReceipt $receipt $Root 'historical' $access
        $checks=1
        foreach($field in @('current','legacy','unknown','leak','terminated','exit','root')) {
            $copy=$receipt | ConvertTo-Json -Depth 6 | ConvertFrom-Json
            switch($field) {
                current {$copy.projectFingerprint=$access.RepositoryStateFingerprint}
                legacy {$copy.projectFingerprint=$access.ProjectKey}
                unknown {$copy.overall='unknown'}
                leak {$copy.leakedProcessIds=@(123)}
                terminated {$copy.terminated=$true}
                exit {$copy.exitCode=0}
                root {$copy.workingDirectory=Join-Path $Root 'other'}
            }
            $refused=$false
            try { Assert-HistoricalDispositionReceipt $copy $Root 'historical' $access } catch {$refused=$true}
            if(-not $refused){throw ('Invalid historical disposition accepted: '+$field)}
            $checks++
        }
        if($checks-ne8){throw 'Disposition assertion count mismatch.'}
        $access.State='unavailable'
        $refused=$false
        try{Assert-HistoricalDispositionReceipt $receipt $Root 'historical' $access}catch{$refused=$true}
        if(-not$refused){throw 'Unavailable current identity waived a historical failure.'}
        . (Join-Path $Root 'hooks/Test-Completion-Check/_recovery.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_dispositionauthorization.ps1')
        $work=Join-Path $Root ('.ci-work/disposition-unit-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($work)
        try {
            $script:cwd=$Root;$script:repositoryState=$access
            $script:historicalDispositions=New-Object Collections.Specialized.OrderedDictionary
            $script:pendingNotes=New-Object Collections.Specialized.OrderedDictionary
            $script:MalformedEvidence=New-Object 'Collections.Generic.List[string]'
            $script:activeMarkerMaxHours=12;$script:ActiveCase=''
            function Get-CompletionStateEntries {param($Kind) if($Kind-eq'active'-and$script:ActiveCase-ne''){return [pscustomobject]@{Doc=[pscustomobject]@{};Path='fixture-active'}};return @()}
            function Get-ActiveMarkerState {param($Doc,$Path,$MaxAgeHours,$ResultEntries) return [pscustomobject]@{State=$script:ActiveCase}}
            foreach($active in @('live','died')) {
                $script:ActiveCase=$active;$refused=$false
                try{Assert-DispositionCleanup @()}catch{$refused=$true}
                if(-not$refused){throw ('Disposition ignored '+$active+' process evidence.')}
            }
            $script:ActiveCase='';[void]$script:MalformedEvidence.Add('fixture-malformed')
            $refused=$false;try{Assert-DispositionCleanup @()}catch{$refused=$true}
            if(-not$refused){throw 'Disposition ignored malformed evidence.'}
            $script:MalformedEvidence.Clear()
            $path=Join-Path $work 'receipt.json'
            [IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
            $script:historicalDispositions['historical']=[pscustomobject]@{schema=1;disposition='obsolete';projectRoot=$Root;requestSha256=('b'*64);receiptSha256=(Read-RecoveryReceipt $path).Sha256;authorization=[pscustomobject]@{requestSha256=('b'*64)}}
            if(Test-HistoricalDisposition $receipt $path){throw 'Unavailable acquisition incorrectly accepted a persisted disposition.'}
            Write-Host 'Historical disposition: 13 checks passed.'
            . (Join-Path $Root 'scripts/_testcompletionadmission.ps1')
            Invoke-DispositionAdmissionRegression -Root $Root -Work $work
        }finally{if([IO.Directory]::Exists($work)){[IO.Directory]::Delete($work,$true)}}
    }
    Remove-Module $module -Force -ErrorAction SilentlyContinue
}

function Invoke-DispositionEntryRegression {
    # The default suite runs on pwsh; exercise the deterministic admission seam
    # on Framework once as well, without rebuilding the expensive entry fixtures.
    $sourceRoot=Split-Path -Parent $PSScriptRoot
    $frameworkOut=Join-Path $Work 'disposition-framework.out'
    $frameworkErr=Join-Path $Work 'disposition-framework.err'
    $command=". '"+(Join-Path $sourceRoot 'scripts/_testcompletiondisposition.ps1').Replace("'","''")+"'; Invoke-DispositionRegression '"+$sourceRoot.Replace("'","''")+"'"
    $framework=Start-BoundedProcess -FilePath powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command',$command) -RedirectStandardOutput $frameworkOut -RedirectStandardError $frameworkErr -TimeoutMs 30000
    $frameworkText=[IO.File]::ReadAllText($frameworkOut,[Text.Encoding]::UTF8)
    Check 'Framework deterministic disposition admission controls' ($framework.ExitCode-eq0-and$frameworkText-match'9 deterministic controls passed') ($frameworkText+[IO.File]::ReadAllText($frameworkErr,[Text.Encoding]::UTF8))
    $root=New-GitRepoAi 'historical disposition root'
    $copy=New-IsolatedHookCopy
    $originals=@{}
    $requests=@()
    foreach($kind in @('obsolete','cancelled')){
        $id='historical-'+$kind
        Write-GuardedResult $copy $root -Overall failed -ExitCode 1 -RunId $id -ProjectFingerprint '1234567890' -AgeMinutes 2880
        $receipt=Get-RunStateFile $copy $root result $id
        $doc=[IO.File]::ReadAllText($receipt,[Text.Encoding]::UTF8)|ConvertFrom-Json
        $doc|Add-Member NoteProperty repositoryState available
        Write-Utf8 $receipt ($doc|ConvertTo-Json -Depth 8)
        $hash=(Get-FileHash $receipt -Algorithm SHA256).Hash.ToLowerInvariant();$originals[$receipt]=$hash
        $evidence=Join-Path $Work ($id+'-evidence.json')
        Write-Utf8 $evidence ([pscustomobject]@{schema=1;projectRoot=$root;runId=$id;receiptSha256=$hash;action=$(if($kind-eq'obsolete'){'retired'}else{'cancelled'});resourceId='fixture-resource';statement='The fixture resource was explicitly retired after the failed historical snapshot; the owner accepted the loss and no restoration or successful verification is claimed.';occurredUtc=[DateTime]::UtcNow.AddMinutes(-10).ToString('o')}|ConvertTo-Json)
        $request=Join-Path $Work ($id+'-request.json')
        Write-Utf8 $request ([pscustomobject]@{schema=1;projectRoot=$root;runId=$id;receiptSha256=$hash;disposition=$kind;reason='The owner reviewed exact historical failure and retirement evidence, explicitly accepted the loss, and requests only ending repetition of this original historical obligation.';evidencePath=$evidence;evidenceSha256=(Get-FileHash $evidence -Algorithm SHA256).Hash.ToLowerInvariant();createdUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')}|ConvertTo-Json)
        $recordId=[guid]::NewGuid().ToString()
        $transcript=Join-Path $Work ($id+'-transcript.jsonl')
        $record=[pscustomobject]@{type='user';uuid=$recordId;sessionId='fixture-session';cwd=$root;timestamp=[DateTime]::UtcNow.ToString('o');message=[pscustomobject]@{role='user';content=('::test-disposition '+(Get-FileHash $request -Algorithm SHA256).Hash.ToLowerInvariant())}}
        Write-Utf8 $transcript (($record|ConvertTo-Json -Depth 8 -Compress)+"`n")
        $requests+=,[pscustomobject]@{Request=$request;Transcript=$transcript;RecordId=$recordId;Evidence=$evidence;Record=$record;Receipt=$receipt;RunId=$id}
    }
    function Invoke-DispositionEntry {
        param($Request,[string]$Exe='pwsh')
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$Exe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $psi.StandardOutputEncoding=[Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[Text.Encoding]::UTF8
        $psi.EnvironmentVariables['LOCALAPPDATA']=$copy.LocalAppData
        $psi.Arguments=ConvertTo-Win32ArgumentString @('-NoLogo','-NoProfile','-NonInteractive','-File',$copy.Script,'-ProjectRoot',$root,'-DispositionRequest',$Request.Request,'-AuthorizationTranscript',$Request.Transcript,'-AuthorizationRecordId',$Request.RecordId)
        $p=[Diagnostics.Process]::Start($psi);$created=$p.StartTime.ToUniversalTime();$p.StandardInput.Close()
        return [pscustomobject]@{Process=$p;Created=$created;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync()}
    }
    function Complete-DispositionEntry {
        param($Child)
        $p=$Child.Process
        try{
            if(-not$p.WaitForExit(20000)){throw 'Disposition entry exceeded 20-second wall/idle ceiling.'}
            if(-not[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Child.Out,$Child.Err),3000)){throw 'Disposition pipes did not close.'}
            return [pscustomobject]@{Exit=$p.ExitCode;Out=$Child.Out.Result;Err=$Child.Err.Result}
        }finally{if(-not$p.HasExited){$null=Stop-ProcessTree -ProcessId $p.Id -RootCreated $Child.Created};$p.Dispose()}
    }
    # Two real processes race on the same ledger. No artificial sleeps or
    # synthetic lock result replaces the production mutex/read-merge-write.
    $children=@()
    try{
        $children+=Invoke-DispositionEntry $requests[0] 'pwsh'
        $children+=Invoke-DispositionEntry $requests[1] 'powershell.exe'
        foreach($child in $children){$r=Complete-DispositionEntry $child;Check 'historical disposition real entry succeeds' ($r.Exit-eq0-and$r.Out-match'Original failure retained'-and$r.Out-notmatch'PASS recorded') ($r.Out+$r.Err)}
    }finally{
        foreach($child in $children){try{if(-not$child.Process.HasExited){$null=Stop-ProcessTree -ProcessId $child.Process.Id -RootCreated $child.Created}}catch{}}
    }
    $state=Get-CompletionStateDoc $copy $root
    Check 'concurrent dispositions retain both exact records without recovery' (@(Get-Field $state 'historicalDispositions').Count-eq2-and@(Get-Field $state 'recoveryAssociations').Count-eq0-and(Get-ResolvedCount $state)-eq0)
    foreach($file in $originals.Keys){Check 'disposition preserves original failure bytes' ((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$originals[$file])}
    $before=[IO.File]::ReadAllText((Join-Path (Get-StateDir $copy) ('TestCompletionCheck-'+(Get-ProjectKey $root)+'.json')),[Text.Encoding]::UTF8)
    $request=$requests[0]
    foreach($variant in @('assistant','meta','wrongHash','quoted','wrongRoot')){
        $record=$request.Record|ConvertTo-Json -Depth 8|ConvertFrom-Json
        switch($variant){
            assistant {$record.type='assistant';$record.message.role='assistant'}
            meta {$record|Add-Member NoteProperty isMeta $true}
            wrongHash {$record.message.content='::test-disposition '+('0'*64)}
            quoted {$record.message.content='> '+$record.message.content}
            wrongRoot {$record.cwd=Join-Path $root 'other'}
        }
        Write-Utf8 $request.Transcript (($record|ConvertTo-Json -Depth 8 -Compress)+"`n")
        $r=Complete-DispositionEntry (Invoke-DispositionEntry $request)
        Check ('invalid disposition authorization refuses '+$variant) ($r.Exit-ne0)
    }
    Write-Utf8 $request.Transcript (($request.Record|ConvertTo-Json -Depth 8 -Compress)+"`n")
    $after=[IO.File]::ReadAllText((Join-Path (Get-StateDir $copy) ('TestCompletionCheck-'+(Get-ProjectKey $root)+'.json')),[Text.Encoding]::UTF8)
    Check 'authorization refusals leave ledger bytes unchanged' ($before-ceq$after)
    $r=Fire $copy $root -SessionId 'disposition-history'
    Check 'historical disposition is not current success' ($r.Exit-eq0-and(Get-BlockReason $r.Out)-eq''-and$r.Out-notmatch'DEEP DEBUG: COMPLETE|all tests passed') ($r.Out+$r.Err)
    Write-GuardedResult $copy $root -Overall failed -ExitCode 1 -RunId 'different-current'
    $r=Fire $copy $root -SessionId 'disposition-current-failure'
    Check 'distinct current failure still blocks after historical disposition' ((Get-BlockReason $r.Out)-ne'') $r.Out
    Write-Utf8 $request.Evidence '{"schema":1,"tampered":true}'
    $r=Fire $copy $root -SessionId 'disposition-tamper'
    Check 'tampered retirement evidence reopens historical obligation' (((Get-BlockReason $r.Out)-ne'')-and$r.Out-match'historical disposition no longer validates') $r.Out
}
