# Test-ContextHooks fixtures: the transcript and stdin builders shared by
# the Mcp-Usage-Check and Skills-Check sections.
#
# Dot-sourced from Test-ContextHooks.ps1 INSIDE its try block, FIRST, so the
# two section files that follow can use these builders. They run in that
# scope and use its harness directly: $Work, $Fire, Check, New-Proj,
# Write-Utf8, Set-ClaudeProjectDir and the counters.
#
# A JSONL entry is one JSON object per line, so a real newline inside a
# message arrives as the two-character escape. That distinction is the whole
# point of the anchored detectors these fixtures feed, which is why they are
# built this way rather than as plain text.
#
# The underscore prefix keeps this out of the runner's Test-*.ps1 glob, so it
# needs no ci.yml bucket entry of its own.

    # A JSONL session transcript, written the way a client writes one: each
    # entry is a JSON object on its own line, so a real newline inside a message
    # arrives as the two-character \n ESCAPE. That distinction is the whole point
    # of the anchored detectors in Mcp-Usage-Check / Rules-Check / Skills-Check,
    # so the fixtures must reproduce it rather than writing plain text.
    function New-Transcript {
        param([string]$Name, [string[]]$Entries)
        $path = Join-Path $Work ($Name + '.jsonl')
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($e in $Entries) { [void]$lines.Add(($e | ConvertTo-Json -Compress)) }
        Write-Utf8 $path (($lines.ToArray() -join "`n") + "`n")
        return $path
    }
    function New-ToolTranscript {
        param([string]$Name, [string]$ToolName, [string]$FinalText)
        $path = Join-Path $Work ($Name + '.jsonl')
        $lines = New-Object System.Collections.Generic.List[string]
        if ($ToolName -ne '') {
            [void]$lines.Add((@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = $ToolName; input = @{ a = 1 } }) } } | ConvertTo-Json -Compress -Depth 8))
        }
        [void]$lines.Add((@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = $FinalText }) } } | ConvertTo-Json -Compress -Depth 8))
        Write-Utf8 $path (($lines.ToArray() -join "`n") + "`n")
        return $path
    }
    function New-StopStdin {
        param([string]$Cwd, [string]$Transcript = '', [string]$SessionId = 't', [string]$EventName = 'Stop', [bool]$StopActive = $false)
        $o = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
        if ($Transcript -ne '') {
            $o['transcript_path'] = $Transcript
            # The child final response belongs to its documented child path.
            if ($EventName -eq 'SubagentStop') { $o['agent_transcript_path'] = $Transcript; $o['agent_id'] = 'fixture-child' }
        }
        if ($StopActive) { $o['stop_hook_active'] = $true }
        return ($o | ConvertTo-Json)
    }
