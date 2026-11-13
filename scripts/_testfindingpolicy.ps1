# Shared R035 seam, invoked inside existing owning suites; no extra CI bucket.
# Reservations are delivery history, not evidence of successful tests or repair.
function Invoke-FindingPolicyRegression {
    param([string]$Root,[string]$HookName)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    $work=Join-Path $Root ('.ci-work/finding-policy-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $savedLocal=$env:LOCALAPPDATA;$savedClient=$env:HOOKMAKER_CLIENT
    $savedInput=Get-Variable HookRuntimeInput -Scope Script -ErrorAction SilentlyContinue
    $savedName=Get-Variable HookRuntimeName -Scope Script -ErrorAction SilentlyContinue
    $savedPolicy=Get-Variable HookPolicySettings -Scope Script -ErrorAction SilentlyContinue
    try {
        $env:LOCALAPPDATA=$work
        foreach($client in @('claude','codex')) {
            $env:HOOKMAKER_CLIENT=$client
            $inputObject=[pscustomobject]@{cwd=$work;session_id=($client+'-'+$HookName);hook_event_name='Stop';stop_hook_active=$false}
            $script:HookRuntimeInput=$inputObject;$script:HookRuntimeName=$HookName;$script:HookPolicySettings=@{}
            $capture=New-Object IO.StringWriter;$previous=[Console]::Out
            try {
                [Console]::SetOut($capture)
                $first=Write-StopBlockResult -HookInput $inputObject -HookName $HookName -EventName Stop -Reason ($HookName+': fixture state, review exact evidence.')
                $wire=$capture.ToString();[void]$capture.GetStringBuilder().Clear()
                $second=Write-StopBlockResult -HookInput $inputObject -HookName $HookName -EventName Stop -Reason ($HookName+': fixture state, review exact evidence.')
                $repeat=$capture.ToString();[void]$capture.GetStringBuilder().Clear()
                $unknown=Write-StopBlockResult -HookInput $inputObject -HookName $HookName -EventName Stop -Condition unknown -Reason ($HookName+': cannot determine fixture.')
                $unknownText=$capture.ToString();[void]$capture.GetStringBuilder().Clear()
                # A confirmed safety finding must still refuse exactly once.
                $safety=Write-StopBlockResult -HookInput $inputObject -HookName Secrets-Check -EventName Stop -Condition secret-exposure -Reason 'Secrets-Check: fixture staged token, unstage/rotate.'
                $safetyText=$capture.ToString();[void]$capture.GetStringBuilder().Clear()
                $safetyAgain=Write-StopBlockResult -HookInput $inputObject -HookName Secrets-Check -EventName Stop -Condition secret-exposure -Reason 'Secrets-Check: fixture staged token, unstage/rotate.'
                $safetyRepeat=$capture.ToString();[void]$capture.GetStringBuilder().Clear()
                $script:HookPolicySettings=@{HOOK_ENFORCEMENT='block'}
                $override=Write-StopBlockResult -HookInput $inputObject -HookName $HookName -EventName Stop -Reason ($HookName+': persisted override fixture.')
                $overrideText=$capture.ToString();[void]$capture.GetStringBuilder().Clear()
                $script:HookPolicySettings=@{HOOK_ENFORCEMENT='off';RULES_CONFIRMATION_ENFORCEMENT='off';SKILLS_SUMMARY_ENFORCEMENT='off';MCP_SUMMARY_ENFORCEMENT='off'}
                $off=Write-StopBlockResult -HookInput $inputObject -HookName $HookName -EventName Stop -Reason ($HookName+': off fixture.')
                $offText=$capture.ToString()
            } finally {[Console]::SetOut($previous)}
            $doc=$null;try{$doc=$wire|ConvertFrom-Json}catch{}
            Check ('035 advisory exit0 '+$HookName+'/'+$client) ($first.ExitCode-eq0-and$null-ne$doc-and$null-eq$doc.PSObject.Properties['decision']-and$doc.systemMessage.Contains($HookName)) $wire
            Check ('035 repeated payload silent '+$HookName+'/'+$client) ($second.ExitCode-eq0-and$repeat-eq'') $repeat
            Check ('035 unknown silent '+$HookName+'/'+$client) ($unknown.ExitCode-eq0-and$unknownText-eq'') $unknownText
            Check ('035 secret blocks once '+$HookName+'/'+$client) ($safetyText-match'"decision":"block"'-and$safetyRepeat-eq''-and$safetyAgain.ExitCode-eq0) $safetyText
            Check ('035 persisted override wins '+$HookName+'/'+$client) ($overrideText-match'"decision":"block"'-and$override.Emitted) $overrideText
            Check ('035 off override silent '+$HookName+'/'+$client) ($off.ExitCode-eq0-and$offText-eq'') $offText
        }
        # FR005 source contracts complement the real no-git event smoke: these
        # exact unavailable-state branches must return before an output call.
        foreach($entry in @('Rules-Check','Mcp-Usage-Check','Skills-Check')) {
            $source=[IO.File]::ReadAllText((Join-Path $Root ('hooks/'+$entry+'/'+$entry+'.ps1')))
            Check ('035 unreadable closing evidence silent '+$entry) ($source.Contains('if ($null -eq $tail) { exit 0 }'))
            Check ('035 reservation failure never prints '+$entry) ($source-notmatch '\[Console\]::Out\.WriteLine[^\r\n]+Closing reservation UNVERIFIED')
        }
        $graph=[IO.File]::ReadAllText((Join-Path $Root 'hooks/Graph-Update-Check/Graph-Update-Check.ps1'))
        Check '035 partial graph without stale fact is silent' ($graph.Contains('if (-not $codeStale -and -not $markdownStale) { exit 0 }'))
        $cleanup=[IO.File]::ReadAllText((Join-Path $Root 'hooks/Test-Temp-Cleanup/Test-Temp-Cleanup.ps1'))
        Check '035 partial cleanup record is silent' ($cleanup.Contains("if (`$category-in@('clean','partial','unknown')) { exit 0 }"))
        if($HookName-in@('Utf8-Encoding-Check','Git-Sync-Check')) {
            $errorCapture=New-Object IO.StringWriter;$previousError=[Console]::Error
            try {
                [Console]::SetError($errorCapture)
                $script:HookPolicySettings=@{}
                $nativeFirst=Write-NativeFinding $HookName 'native fixture invalid.txt' $work
                $nativeText=$errorCapture.ToString();[void]$errorCapture.GetStringBuilder().Clear()
                $nativeSecond=Write-NativeFinding $HookName 'native fixture invalid.txt' $work
                $nativeRepeat=$errorCapture.ToString();[void]$errorCapture.GetStringBuilder().Clear()
                $script:HookPolicySettings=@{HOOK_ENFORCEMENT='block'}
                $nativeBlock=Write-NativeFinding $HookName 'native override invalid.txt' $work
                $nativeBlockText=$errorCapture.ToString();[void]$errorCapture.GetStringBuilder().Clear()
                $nativeBlockSecond=Write-NativeFinding $HookName 'native override invalid.txt' $work
                $nativeBlockRepeat=$errorCapture.ToString()
            } finally {[Console]::SetError($previousError)}
            Check ('035 native advisory once '+$HookName) ($nativeFirst-eq0-and$nativeText-ne''-and$nativeSecond-eq0-and$nativeRepeat-eq'') $nativeText
            Check ('035 native persisted block once '+$HookName) ($nativeBlock-eq1-and$nativeBlockText-ne''-and$nativeBlockSecond-eq0-and$nativeBlockRepeat-eq'') $nativeBlockText
        }
    } finally {
        $env:LOCALAPPDATA=$savedLocal;$env:HOOKMAKER_CLIENT=$savedClient
        foreach($saved in @(@{Name='HookRuntimeInput';Value=$savedInput},@{Name='HookRuntimeName';Value=$savedName},@{Name='HookPolicySettings';Value=$savedPolicy})) {
            if($null-ne$saved.Value){Set-Variable -Name $saved.Name -Value $saved.Value.Value -Scope Script}else{Remove-Variable -Name $saved.Name -Scope Script -ErrorAction SilentlyContinue}
        }
        if([IO.Directory]::Exists($work)){[IO.Directory]::Delete($work,$true)}
    }
}
