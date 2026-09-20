# Test-ContextHooks section: Mcp-Usage-Check.
#
# Dot-sourced from Test-ContextHooks.ps1 INSIDE its try block, AFTER
# _testcontextfixtures.ps1, so it runs in that scope and uses both the
# harness ($Work, $Fire, Check, New-Proj, Write-Utf8, Set-ClaudeProjectDir,
# the counters) and the shared transcript builders directly.
#
# Split out of _testcontextskills.ps1, which covered two hooks in one file
# and had reached the size band that closes a file to new code. Pure
# relocation - the lines below are byte-identical to the ones they replaced,
# indentation included, so the move can be proved rather than reviewed line
# by line.
#
# The underscore prefix keeps this out of the runner's Test-*.ps1 glob, so it
# needs no ci.yml bucket entry of its own.

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: input handling ---' -ForegroundColor Cyan
    $plain = New-Proj 'Plain'
    $r = Fire -HookPath $McpHook -Cwd $plain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -RawStdin 'garbage'
    Check 'garbage stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -EventName 'PreToolUse'
    Check 'an unregistered event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # Stop IS registered now, but a session with no transcript and no recorded
    # MCP relevance has no evidence to report - and an evidence-free Stop must
    # stay silent rather than nag.
    $r = Fire -HookPath $McpHook -Cwd $plain -EventName 'Stop'
    Check 'Stop with no transcript and no recorded relevance -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -EventName 'SubagentStop'
    Check 'SubagentStop with no evidence -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: always reminds on SessionStart (cheap, no gate) ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'emits a valid hookSpecificOutput on SessionStart' ($null -ne $parsed -and [string]$parsed.hookSpecificOutput.hookEventName -eq 'SessionStart')
    Check 'mentions MCP USAGE CHECK' ($r.Out -like '*MCP USAGE CHECK*') $r.Out
    # Budget raised from 600 to 800: the note now also states the CLOSING
    # requirement up front, which is deliberate - the Stop gate must never be the
    # first time the agent hears about the "MCP used:" line. Measured 687 chars;
    # 800 leaves headroom without letting the note grow into a policy dump.
    Check 'note stays short (under 800 chars: 4 lines + the closing requirement)' ($null -ne $parsed -and ([string]$parsed.hookSpecificOutput.additionalContext).Length -lt 800) ([string]$parsed.hookSpecificOutput.additionalContext).Length
    Check 'SessionStart states the closing "MCP used:" requirement up front' ($r.Out -match 'CLOSING REQUIREMENT' -and $r.Out -match 'MCP used:') $r.Out
    $r2 = Fire -HookPath $McpHook -Cwd $plain
    Check 'fires again next session too (no state file on SessionStart by design)' ($r2.Out -like '*MCP USAGE CHECK*') $r2.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: UserPromptSubmit only when the prompt suggests MCP would help ---' -ForegroundColor Cyan
    $mcpProj = New-Proj 'McpRelevance'
    $r = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'fix a typo in the readme' -SessionId 's-irrelevant')
    Check 'an irrelevant prompt stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt '' -SessionId 's-empty')
    Check 'an empty prompt stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'add the new payments API library and check its docs' -SessionId 's-relevant')
    Check 'a relevant prompt (library/API/docs) emits the reminder' ($r.Out -like '*MCP USAGE CHECK*') $r.Out
    $r2 = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'now also update the library docs further' -SessionId 's-relevant')
    Check 'the SAME session does not repeat the reminder on the next relevant prompt' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'add another library dependency' -SessionId 's-relevant-2')
    Check 'a NEW session with a relevant prompt reminds again' ($r3.Out -like '*MCP USAGE CHECK*') $r3.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: Stop gate verifies the "MCP used:" summary line ---' -ForegroundColor Cyan
    # The gate fires on ONE confirmed condition: MCP tool names really are in the
    # transcript AND the summary carries no line reporting them. Everything else
    # is advisory or silent.
    $mcpStop = New-Proj 'McpStop'
    $tMcpNoSum = New-ToolTranscript 'mcp-nosum' 'mcp__context7__query-docs' "Done.`nI changed a file."
    $tMcpSum = New-ToolTranscript 'mcp-sum' 'mcp__context7__query-docs' "Done.`nMCP used: context7"
    $tNoMcp = New-ToolTranscript 'mcp-none' 'Read' "Done."

    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-b1')
    Check 'MCP called + no summary line -> a real block decision' ($r.Out -match '"decision"\s*:\s*"block"') $r.Out
    Check 'the block names the servers it actually observed' ($r.Out -match 'Servers observed in this session: context7') $r.Out
    Check 'the block names the exact single action that clears it' ($r.Out -match 'TO CLEAR THIS' -and $r.Out -match 'starting exactly with .{0,3}MCP used:') $r.Out
    # An unchanged failure blocks ONCE per session (global-hook-rules.md: a gate
    # must not loop on the same unchanged state).
    $r2 = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-b1')
    Check 'the SAME unchanged failure does not block twice in one session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-b2')
    Check 'a NEW session with the same failure blocks again' ($r3.Out -match '"decision"\s*:\s*"block"') $r3.Out

    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpSum -SessionId 'mcp-ok')
    Check 'MCP called + the summary line present -> silent, no block' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # SELF-SATISFACTION PROBE: the hook's own output lands in the transcript it
    # later reads. A transcript containing ONLY this hook's instruction text must
    # NOT count as the agent having written the line, or the hook clears its own
    # block on the next stop.
    $ownText = 'CLOSING REQUIREMENT - end the final task summary with its own line starting "MCP used:" naming every connected MCP server actually called this task. TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "MCP used:" and naming the servers actually used - e.g. "MCP used: context7".'
    $tSelf = New-ToolTranscript 'mcp-self' 'mcp__context7__query-docs' $ownText
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tSelf -SessionId 'mcp-self1')
    Check 'the hook''s OWN instruction text in the transcript never satisfies the gate' ($r.Out -match '"decision"\s*:\s*"block"') $r.Out

    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tNoMcp -SessionId 'mcp-n1')
    Check 'no MCP call and no recorded relevance -> silent (never a block on suspicion)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # A tool name MENTIONED in prose is not a tool CALL. Matching a bare token
    # anywhere in the transcript would make a conversation ABOUT MCP look like
    # one that used it - a false positive, and a gate that fires on one is worse
    # than no gate at all.
    $tMentionOnly = New-ToolTranscript 'mcp-mention' 'Read' "I considered calling mcp__context7__query-docs but read the local docs instead."
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMentionOnly -SessionId 'mcp-m1')
    Check 'a tool name merely MENTIONED in prose is not treated as a call' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-sa' -StopActive $true)
    # stop_hook_active means "a Stop gate blocked and the agent is coming
    # back" - NOT "YOU blocked". Thirteen gates share the one flag, so a gate
    # standing down on it alone went silent for somebody else's block, and
    # the next Stop ran with the secret-leak, UTF-8 and CI gates all muted.
    # Each gate now stands down only on its OWN re-entry, proven by a marker
    # it writes itself immediately before it blocks.
    Check 'stop_hook_active ALONE does not silence the gate (another hook blocked, not this one)' ($r.Exit -eq 0 -and $r.Out -ne '') $r.Out

    # UNKNOWN transcript: a missing or unreadable transcript is never an
    # all-clear and never a block - it is reported as unverified, and only for a
    # session the prompt half recorded as MCP-relevant.
    $mcpUnk = New-Proj 'McpUnknown'
    $r = Fire -HookPath $McpHook -Cwd $mcpUnk -RawStdin (New-PromptStdin -Cwd $mcpUnk -EventName 'UserPromptSubmit' -Prompt 'read the payments API docs' -SessionId 'mcp-u1')
    Check 'a relevant prompt records the session as MCP-relevant (reminder emitted)' ($r.Out -match 'MCP USAGE CHECK') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpUnk -RawStdin (New-StopStdin -Cwd $mcpUnk -Transcript (Join-Path $Work 'no-such-transcript.jsonl') -SessionId 'mcp-u1')
    Check 'a missing transcript reports UNVERIFIED, never an all-clear and never a block' (
        $r.Out -match 'could NOT be verified' -and $r.Out -match 'not an all-clear' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpUnk -RawStdin (New-StopStdin -Cwd $mcpUnk -Transcript $tNoMcp -SessionId 'mcp-u1')
    Check 'a relevant session that called no MCP tool gets an advisory, not a block' (
        $r.Out -match 'no connected MCP server tool was called' -and $r.Out -notmatch '"decision"') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: MCP_SUMMARY_ENFORCEMENT downgrades and disables the gate ---' -ForegroundColor Cyan
    function New-ConfiguredMcpHookCopy {
        param([string]$Enforcement)
        $dir = Join-Path $Work ('mcpcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item $McpHook (Join-Path $dir 'Mcp-Usage-Check.ps1')
        Copy-TestRuntimeLibraries -SourceHookLib (Join-Path (Split-Path -Parent $McpHook) '..\_hooklib.ps1') -Destination (Join-Path $Work '_hooklib.ps1')
        Write-Utf8 (Join-Path $dir '.env') ("MCP_SUMMARY_ENFORCEMENT=" + $Enforcement + "`r`n")
        return (Join-Path $dir 'Mcp-Usage-Check.ps1')
    }
    $advHook = New-ConfiguredMcpHookCopy 'advisory'
    $mcpAdv = New-Proj 'McpAdvisory'
    $r = Fire -HookPath $advHook -Cwd $mcpAdv -RawStdin (New-StopStdin -Cwd $mcpAdv -Transcript $tMcpNoSum -SessionId 'mcp-a1')
    Check 'advisory mode reports the same finding without a block decision' (
        $r.Out -match 'Servers observed in this session: context7' -and $r.Out -notmatch '"decision"') $r.Out
    $offHook = New-ConfiguredMcpHookCopy 'off'
    $mcpOff = New-Proj 'McpOff'
    $r = Fire -HookPath $offHook -Cwd $mcpOff -RawStdin (New-StopStdin -Cwd $mcpOff -Transcript $tMcpNoSum -SessionId 'mcp-o1')
    Check 'off mode skips the closing check entirely' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $offHook -Cwd $mcpOff
    Check 'off mode still runs the pre-task half' ($r.Out -match 'MCP USAGE CHECK') $r.Out
    $badHook = New-ConfiguredMcpHookCopy 'nonsense-value'
    $mcpBad = New-Proj 'McpBadConfig'
    $r = Fire -HookPath $badHook -Cwd $mcpBad -RawStdin (New-StopStdin -Cwd $mcpBad -Transcript $tMcpNoSum -SessionId 'mcp-x1')
    Check 'an invalid enforcement value falls back to the block default' ($r.Out -match '"decision"\s*:\s*"block"') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain -Exe 'powershell.exe'
    Check '5.1 host: emits cleanly, no crash' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*MCP USAGE CHECK*') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -Exe 'powershell.exe' -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-51')
    Check '5.1 host: the Stop gate produces the same block decision' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -match '"decision"\s*:\s*"block"') $r.Out
