# Only parsed user records can authorize workflow activation. A token in
# instructions, a tool result, quoted prose or an annotation is not a command.
function Test-ExplicitDeepDebugCommand {
    param($Text)
    return ($Text -is [string] -and $Text -match '\A(?:[ \t]*\r?\n)* {0,3}::deep-debug(?:[ \t\r\n]|\z)')
}

function Test-DeepDebugUserRecord {
    param($Record)
    if ($null -eq $Record -or (Get-Field $Record 'isMeta') -eq $true -or $null -ne (Get-Field $Record 'sourceToolAssistantUUID')) { return $false }
    $content = $null
    switch ([string](Get-Field $Record 'type')) {
        'user' {
            $message = Get-Field $Record 'message'
            if ([string](Get-Field $message 'role') -ne 'user' -or (Get-Field $message 'isMeta') -eq $true) { return $false }
            $content = Get-Field $message 'content'
        }
        'event_msg' {
            $payload = Get-Field $Record 'payload'
            if ([string](Get-Field $payload 'type') -ne 'user_message') { return $false }
            $content = Get-Field $payload 'message'
        }
        'response_item' {
            $payload = Get-Field $Record 'payload'
            if ([string](Get-Field $payload 'type') -ne 'message' -or [string](Get-Field $payload 'role') -ne 'user') { return $false }
            $content = Get-Field $payload 'content'
        }
        default { return $false }
    }
    if ($content -is [string]) { return Test-ExplicitDeepDebugCommand $content }
    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($part in @($content)) {
        if ([string](Get-Field $part 'type') -in @('image','input_image')) { continue }
        if ([string](Get-Field $part 'type') -notin @('text','input_text')) { return $false }
        if ($null -ne (Get-Field $part 'annotations') -and @(Get-Field $part 'annotations').Count -gt 0) { return $false }
        $text = Get-Field $part 'text'
        if ($text -isnot [string]) { return $false }
        [void]$texts.Add($text)
    }
    return Test-ExplicitDeepDebugCommand ($texts.ToArray() -join "`n")
}

function Test-DeepDebugTranscriptCommand {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $size = [int][Math]::Min([int64]65536, $stream.Length)
            $offset = $stream.Length - $size
            [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $bytes = New-Object byte[] $size
            $read = 0
            while ($read -lt $size) {
                $count = $stream.Read($bytes, $read, $size - $read)
                if ($count -eq 0) { break }
                $read += $count
            }
        }
        finally { $stream.Dispose() }
        $start = 0
        # A tail that begins within a record has no trustworthy JSON boundary.
        if ($offset -gt 0) {
            while ($start -lt $read -and $bytes[$start] -ne 10) { $start++ }
            $start++
        }
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        for ($end = $start; $end -le $read; $end++) {
            if ($end -lt $read -and $bytes[$end] -ne 10) { continue }
            if ($end -gt $start) {
                try {
                    $line = $utf8.GetString($bytes, $start, $end - $start).TrimStart([char]0xFEFF)
                    $record = $line | ConvertFrom-Json -ErrorAction Stop
                    if (Test-DeepDebugUserRecord $record) { return $true }
                }
                catch { } # Malformed/truncated records do not establish intent.
            }
            $start = $end + 1
        }
    }
    catch { }
    return $false
}

function Initialize-DeepDebugActivation {
    $script:DeepDebugActive = $false
    if ($script:recoveryMode) { return }
    $marker = $null
    try { $marker = Read-JsonFile $script:ddMarkerPath } catch { }
    $seen = Test-DeepDebugTranscriptCommand ([string](Get-Field $script:hookInput 'transcript_path'))
    if ($seen) {
        $script:DeepDebugActive = $true
        if ($script:sessionId -eq '') { return }
        $next = [ordered]@{schema=2;sessionId=$script:sessionId;activationSource='explicit-user-command';detectedUtc=[DateTime]::UtcNow.ToString('o')}
        if ($null -ne $marker) {
            if ((Get-Field $marker 'schema') -eq 1) { $next.legacyMarker = $marker }
            elseif ($null -ne (Get-Field $marker 'legacyMarker')) { $next.legacyMarker = Get-Field $marker 'legacyMarker' }
        }
        try { Write-JsonFileAtomic -Path $script:ddMarkerPath -Value ([pscustomobject]$next) } catch { }
    }
    elseif ($null -ne $marker -and (Get-Field $marker 'schema') -eq 2 -and
        [string](Get-Field $marker 'activationSource') -eq 'explicit-user-command' -and
        $script:sessionId -ne '' -and [string](Get-Field $marker 'sessionId') -eq $script:sessionId) {
        $script:DeepDebugActive = $true
    }
    # Legacy markers have no provenance. Keep them as historical evidence,
    # inactive until a real command validates them; never erase another session.
}
