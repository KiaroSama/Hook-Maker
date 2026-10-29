# Shared cheap delivery seam; actual entry output belongs to Completion CI.
function Invoke-FailedDeliveryRegression {
    param([string]$Root, [string]$Work)
    $module = New-Module -ArgumentList $Root,$Work -ScriptBlock {
        param($Root,$Work)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        $helper=Join-Path $Root 'hooks/Test-Completion-Check/_failureadmission.ps1'
        if(-not [IO.File]::Exists($helper)){throw 'Completed failure delivery admission is missing.'}
        . $helper
        $oldLocal=$env:LOCALAPPDATA;$oldClient=$env:HOOKMAKER_CLIENT
        try {
            $env:LOCALAPPDATA=Join-Path $Work ('delivery-'+[guid]::NewGuid().ToString('N'));$env:HOOKMAKER_CLIENT='claude'
            [void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
            $event=[pscustomobject]@{cwd=$Root;session_id='delivery-a';hook_event_name='Stop'}
            $path=Join-Path $env:LOCALAPPDATA 'receipt.json'
            $doc=[pscustomobject]@{schema=2;runId='failure-a';overall='failed';exitCode=1;terminated=$false;leakedProcessIds=@();workingDirectory=$Root;endedUtc='2026-01-01T00:00:00.1234567Z'}
            $utf8=[Text.UTF8Encoding]::new($false)
            $text=$doc|ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($path,$text,$utf8)
            $doc=[IO.File]::ReadAllText($path,$utf8)|ConvertFrom-Json
            function Claim { Get-FailedReceiptDeliveryClaim $event $doc $path @($path) }
            $first=Claim
            if($null-eq$first-or-not$first.Ok-or-not$first.Admitted){throw 'Initial failure was not admitted.'}
            foreach($diagnostic in @('available','unavailable','available')){
                $event|Add-Member NoteProperty task_id ([guid]::NewGuid().ToString()) -Force
                $event|Add-Member NoteProperty diagnostic $diagnostic -Force
                $claim=Claim
                if($null-eq$claim-or-not$claim.Ok-or$claim.Admitted){throw 'Diagnostic/task churn repeated unchanged failure.'}
            }
            [IO.File]::AppendAllText($path,' ',$utf8)
            if(-not(Claim).Admitted){throw 'Changed raw bytes did not re-arm.'}
            [IO.File]::WriteAllText($path,$text,$utf8)
            if((Claim).Admitted){throw 'A/B/A forgot original snapshot.'}
            $event.session_id='delivery-b'
            if(-not(Claim).Admitted){throw 'New session did not report.'}
            $event.session_id='delivery-a';$event|Add-Member NoteProperty agent_id 'other-agent'
            if(-not(Claim).Admitted){throw 'New agent did not report.'}
            $env:HOOKMAKER_CLIENT='codex'
            if(-not(Claim).Admitted){throw 'New client did not report.'}
            $other=Join-Path $env:LOCALAPPDATA 'observed.json'
            [IO.File]::WriteAllText($other,'{}',$utf8)
            if(-not(Get-FailedReceiptDeliveryClaim $event $doc $path @($path,$other)).Admitted){throw 'New evidence did not report.'}
            $reordered=Get-FailedReceiptDeliveryClaim $event $doc $path @($other,$path,$path)
            if($null-eq$reordered-or-not$reordered.Ok-or$reordered.Admitted){throw 'Evidence enumeration order changed snapshot.'}
            foreach($case in @('malformed','mismatch','terminated','leak','unknown','missing-session','missing-file','invalid-utf8','oversized')){
                [IO.File]::WriteAllText($path,$text,$utf8)
                $copy=$doc|Select-Object *;$inputCopy=$event|Select-Object *
                switch($case){
                    malformed {[IO.File]::WriteAllText($path,'{',$utf8)}
                    mismatch {$copy.runId='different'}
                    terminated {$copy.terminated=$true}
                    leak {$copy.leakedProcessIds=@(123)}
                    unknown {$copy.overall='unknown'}
                    missing-session {$inputCopy.session_id=''}
                    missing-file {[IO.File]::Delete($path)}
                    invalid-utf8 {[IO.File]::WriteAllBytes($path,[byte[]]@(255))}
                    oversized {[IO.File]::WriteAllBytes($path,(New-Object byte[] 1048577))}
                }
                if($null-ne(Get-FailedReceiptDeliveryClaim $inputCopy $copy $path @($path))){throw ('Unsafe reservation: '+$case)}
            }
            [IO.File]::WriteAllText($path,$text,$utf8)
            $reservation=@([IO.Directory]::GetFiles((Join-Path $env:LOCALAPPDATA 'HookMaker/state'),'FailedReceiptDelivery-*.json'))
            if($reservation.Count-ne1){throw 'Expected one project reservation.'}
            [IO.File]::WriteAllText($reservation[0],'{',$utf8)
            $bad=Claim
            if($null-eq$bad-or$bad.Ok){throw 'Malformed reservation did not retain normal gate.'}
            $entries=[ordered]@{}
            foreach($i in 1..1024){$entries[$i.ToString('x64')]=@{fingerprint=('a'*64);reservedTicks=[string][DateTime]::UtcNow.Ticks;expiresTicks='0'}}
            [IO.File]::WriteAllText($reservation[0],(@{schema=1;entries=$entries}|ConvertTo-Json -Depth 6 -Compress),$utf8)
            $full=Claim
            if($null-eq$full-or$full.Ok-or$full.Reason-ne'capacity'){throw 'Capacity evicted evidence or failed open.'}
            if([IO.File]::ReadAllText($path,$utf8)-cne$text){throw 'Original receipt changed.'}
            Write-Host 'Completed failure delivery controls passed.'
        }finally{$env:LOCALAPPDATA=$oldLocal;$env:HOOKMAKER_CLIENT=$oldClient}
    }
    Remove-Module $module -Force -ErrorAction SilentlyContinue
}
