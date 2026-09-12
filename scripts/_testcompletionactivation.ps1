# Explicit user-command provenance; fixtures never use live client state.
$activationRoot = New-GitRepoAi 'ExplicitActivation'
$activationCases = @(
    @{ Name='Claude user string'; Active=$true; Record=@{type='user';message=@{role='user';content='::deep-debug parser'}} },
    @{ Name='Claude text blocks'; Active=$true; Record=@{type='user';message=@{role='user';content=@(@{type='text';text='::deep-debug parser'})}} },
    @{ Name='Claude command with image'; Active=$true; Record=@{type='user';message=@{role='user';content=@(@{type='text';text='::deep-debug attached error'},@{type='image';source=@{type='base64';data='example'}})}} },
    @{ Name='Codex command with image'; Active=$true; Record=@{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_image';image_url='example'},@{type='input_text';text='::deep-debug attached error'})}} },
    @{ Name='image content never supplies a command'; Active=$false; Record=@{type='user';message=@{role='user';content=@(@{type='image';text='::deep-debug';source=@{type='base64';data='example'}})}} },
    @{ Name='Codex user event'; Active=$true; Record=@{type='event_msg';payload=@{type='user_message';message='::deep-debug parser'}} },
    @{ Name='Codex response user'; Active=$true; Record=@{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text='::deep-debug parser'})}} },
    @{ Name='assistant'; Active=$false; Record=@{type='assistant';message=@{role='assistant';content='::deep-debug parser'}} },
    @{ Name='system'; Active=$false; Record=@{type='system';message=@{role='system';content='::deep-debug parser'}} },
    @{ Name='Claude hook meta'; Active=$false; Record=@{type='user';isMeta=$true;message=@{role='user';content='::deep-debug parser'}} },
    @{ Name='tool result'; Active=$false; Record=@{type='user';message=@{role='user';content=@(@{type='tool_result';content='::deep-debug parser'})}} },
    @{ Name='quoted example'; Active=$false; Record=@{type='user';message=@{role='user';content='"::deep-debug parser"'}} },
    @{ Name='inline code'; Active=$false; Record=@{type='user';message=@{role='user';content='`::deep-debug`'}} },
    @{ Name='code fence'; Active=$false; Record=@{type='user';message=@{role='user';content="``````text`n::deep-debug parser`n``````"}} },
    @{ Name='blockquote'; Active=$false; Record=@{type='user';message=@{role='user';content='> ::deep-debug parser'}} },
    @{ Name='loaded instructions'; Active=$false; Record=@{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text="# AGENTS.md instructions`n<INSTRUCTIONS>`n::deep-debug parser`n</INSTRUCTIONS>"})}} },
    @{ Name='Codex developer'; Active=$false; Record=@{type='response_item';payload=@{type='message';role='developer';content=@(@{type='input_text';text='::deep-debug parser'})}} },
    @{ Name='Codex tool output'; Active=$false; Record=@{type='response_item';payload=@{type='function_call_output';output='::deep-debug parser'}} },
    @{ Name='response annotation'; Active=$false; Record=@{type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text='::deep-debug parser';annotations=@(@{type='hook'})})}} },
    @{ Name='hook wrapper'; Active=$false; Record=@{type='event_msg';payload=@{type='user_message';message='<system-reminder>::deep-debug parser</system-reminder>'}} },
    @{ Name='explanation before token'; Active=$false; Record=@{type='user';message=@{role='user';content="Do not activate this example:`n::deep-debug parser"}} },
    @{ Name='malformed JSON'; Active=$false; Text='{"type":"user","message":{"role":"user","content":"::deep-debug parser"' },
    @{ Name='partial tail record'; Active=$false; Text=(('x' * 66000) + ' ::deep-debug parser') }
)
foreach ($hostName in @('pwsh','powershell')) {
    foreach ($case in $activationCases) {
        $copy = New-IsolatedHookCopy
        $path = Join-Path $Work ('activation-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        $text = if ($case.ContainsKey('Text')) { $case.Text } else { $case.Record | ConvertTo-Json -Depth 10 -Compress }
        Write-Utf8 $path ($text + "`n")
        $result = Fire -Copy $copy -Cwd $activationRoot -TranscriptPath $path -Exe $hostName -Codex:($hostName -eq 'powershell')
        $activated = $result.Out -match 'DEEP DEBUG: BLOCKED'
        Check ($hostName + ': ' + $case.Name) ($result.Exit -eq 0 -and $activated -eq $case.Active) ($result.Out + $result.Err)
    }
    $copy = New-IsolatedHookCopy
    $result = Fire -Copy $copy -Cwd $activationRoot -Prompt '::deep-debug is quoted in a Stop payload' -Exe $hostName
    Check ($hostName + ': a Stop prompt field has no user-command provenance') ($result.Exit -eq 0 -and $result.Out -eq '') ($result.Out + $result.Err)

    $copy = New-IsolatedHookCopy
    $markerPath = Join-Path (Get-StateDir $copy) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $activationRoot) + '.json')
    $legacy = @{schema=1;sessionId='sess1';detectedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json
    Write-Utf8 $markerPath $legacy
    $result = Fire -Copy $copy -Cwd $activationRoot -Exe $hostName
    Check ($hostName + ': legacy marker alone is inactive and preserved') ($result.Out -eq '' -and [IO.File]::ReadAllText($markerPath) -eq $legacy) $result.Out

    $path = Join-Path $Work ('activation-valid-' + $hostName + '.jsonl')
    Write-Utf8 $path (('x' * 66000) + "`n" + '{"type":"event_msg","payload":{"type":"user_message","message":"::deep-debug parser"}}' + "`n" + '{"broken":')
    $result = Fire -Copy $copy -Cwd $activationRoot -TranscriptPath $path -Exe $hostName
    $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
    Check ($hostName + ': complete record after truncated boundary activates and migrates legacy proof') ($result.Out -match 'DEEP DEBUG: BLOCKED' -and $marker.schema -eq 2 -and $null -ne $marker.PSObject.Properties['legacyMarker']) $result.Out
    Write-GuardedResult -Copy $copy -Root $activationRoot -Overall 'ok'
    $result = Fire -Copy $copy -Cwd $activationRoot -Exe $hostName
    Check ($hostName + ': validated marker persists after command leaves tail') ($result.Out -match 'DEEP DEBUG: COMPLETE') $result.Out
    $result = Fire -Copy $copy -Cwd $activationRoot -SessionId 'another-session' -Exe $hostName
    Check ($hostName + ': another session cannot reuse or erase validated activation') ($result.Out -eq '' -and (Test-Path -LiteralPath $markerPath)) $result.Out
}
