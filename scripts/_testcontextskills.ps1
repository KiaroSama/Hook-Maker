# Test-ContextHooks section: Mcp-Usage-Check + Skills-Check.
#
# Dot-sourced from Test-ContextHooks.ps1 INSIDE its try block, so it runs in
# that scope and uses its harness directly: $Work, $Fire, Check, New-Proj,
# Write-Utf8, Set-ClaudeProjectDir and the counters. Pure relocation - the
# lines below are byte-identical to the ones this file replaced, indentation
# included, so the move can be proved rather than reviewed line by line.
#
# The underscore prefix keeps it out of the runner's Test-*.ps1 glob, so it
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

    # =====================================================================
    # Force Claude routing for the .claude-based Skills-Check cases below; the
    # dedicated routing tests flip CLAUDE_PROJECT_DIR explicitly.
    Set-ClaudeProjectDir $Work
    Write-Host '--- Skills-Check: input handling + silent with nothing to point at ---' -ForegroundColor Cyan
    $splain = New-Proj 'SkillsPlain'
    $r = Fire -HookPath $SkillsHook -Cwd $splain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $SkillsHook -Cwd $splain -EventName 'PreToolUse'
    Check 'an unregistered event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # No copied skills, no .ai/SKILLS.md, and the library / global / plugin paths
    # are all overridden to guaranteed-absent locations, so this run is
    # deterministic regardless of what the host machine actually has installed.
    $noSourceHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $noSourceHook -Cwd $splain
    Check 'no skill source anywhere -> silent on SessionStart, zero tokens' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $noSourceHook -Cwd $splain -EventName 'Stop'
    Check 'no skill source anywhere -> silent on Stop too' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $noSourceHook -Cwd $splain -EventName 'SubagentStop'
    Check 'no skill source anywhere -> silent on SubagentStop too' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: reports copied project skills (SessionStart discovery) ---' -ForegroundColor Cyan
    $proj1 = New-Proj 'WithCopiedSkills'
    New-Item -ItemType Directory -Path (Join-Path $proj1 '.claude\skills\my-skill') -Force | Out-Null
    $hook1 = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $hook1 -Cwd $proj1
    Check 'lists the copied skill folder name' ($r.Out -like '*SKILL POLICY CHECK*' -and $r.Out -like '*my-skill*') $r.Out
    # The closing requirement is now stated up front, so the Stop gate can never
    # be the first the agent hears of it (it used to just point at the Stop
    # reminder, which meant the requirement arrived only after the work).
    Check 'SessionStart states the closing "Skills used:" requirement up front' (
        $r.Out -match 'CLOSING REQUIREMENT' -and $r.Out -match 'Skills used:') $r.Out
    # Both advisories carry the route, not just the prompt-time one: a session
    # that never submits a matching prompt would otherwise never hear it.
    Check 'SessionStart also names the Spec Kit route' (
        $r.Out -match 'Spec Kit routes every task') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: Stop requires the "Skills used:" summary line ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hook1 -Cwd $proj1 -EventName 'Stop'
    Check 'Stop requires a final "Skills used:" summary line for skills actually used' ($r.Out -match 'Skills used:') $r.Out
    Check 'the policy explicitly excludes merely-installed/available/considered/copied-but-unused skills' (
        $r.Out -match 'never a skill that was merely installed, available, discovered, copied, considered, or read but not used') $r.Out
    Check 'no skill used is answered with an explicit "none" plus a reason, not by dropping the line' (
        $r.Out -match 'Skills used: none - <one-line reason>') $r.Out
    Check 'the policy forbids listing the whole library' ($r.Out -match 'never the whole library') $r.Out
    Check 'the policy does not force a skill for trivial tasks merely to produce the line' ($r.Out -match 'do not force a skill for trivial tasks') $r.Out
    Check 'a session with no skill invoked is advised, never blocked' ($r.Out -notmatch '"decision"') $r.Out
    $stopHookActiveStdin = @{ session_id = 't'; cwd = $proj1; hook_event_name = 'Stop'; stop_hook_active = $true } | ConvertTo-Json
    $r = Fire -HookPath $hook1 -Cwd $proj1 -EventName 'Stop' -RawStdin $stopHookActiveStdin
    Check 'stop_hook_active short-circuits the Stop reminder' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: the Stop gate fires only on a skill that was really invoked ---' -ForegroundColor Cyan
    $skStop = New-Proj 'SkillsStopGate'
    New-Item -ItemType Directory -Path (Join-Path $skStop '.claude\skills\gate-skill') -Force | Out-Null
    $skStopHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $tSkillNoLine = New-ToolTranscript 'sk-nosum' 'Skill' "Done.`nI finished the change."
    $tSkillLine = New-ToolTranscript 'sk-sum' 'Skill' "Done.`nSkills used: gate-skill"
    $tNoSkill = New-ToolTranscript 'sk-none' 'Read' "Done."

    $r = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript $tSkillNoLine -SessionId 'sk-b1')
    Check 'skill invoked + no summary line -> a real block decision' ($r.Out -match '"decision"\s*:\s*"block"') $r.Out
    Check 'the block names the exact single action that clears it' ($r.Out -match 'TO CLEAR THIS' -and $r.Out -match 'starting exactly with .{0,3}Skills used:') $r.Out
    $r2 = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript $tSkillNoLine -SessionId 'sk-b1')
    Check 'the SAME unchanged failure does not block twice in one session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript $tSkillLine -SessionId 'sk-ok')
    Check 'skill invoked + the summary line present -> silent, no block' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript $tNoSkill -SessionId 'sk-n1')
    Check 'no skill invoked -> advisory only (whether one was NEEDED is not the hook''s call)' (
        $r.Out -match 'no skill was invoked this session' -and $r.Out -notmatch '"decision"') $r.Out
    # SELF-SATISFACTION PROBE, same reasoning as the Mcp-Usage-Check one above.
    $skOwnText = 'CLOSING REQUIREMENT - end the final task summary with its own line starting "Skills used:" naming ONLY the exact skill names actually invoked. TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "Skills used:" - e.g. "Skills used: superpowers:systematic-debugging".'
    $tSkSelf = New-ToolTranscript 'sk-self' 'Skill' $skOwnText
    $r = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript $tSkSelf -SessionId 'sk-self1')
    Check 'the hook''s OWN instruction text in the transcript never satisfies the gate' ($r.Out -match '"decision"\s*:\s*"block"') $r.Out
    $r = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript (Join-Path $Work 'no-such-transcript.jsonl') -SessionId 'sk-u1')
    Check 'a missing transcript reports UNVERIFIED, never an all-clear and never a block' (
        $r.Out -match 'could NOT be verified' -and $r.Out -match 'not an all-clear' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Fire -HookPath $skStopHook -Cwd $skStop -RawStdin (New-StopStdin -Cwd $skStop -Transcript $tSkillNoLine -SessionId 'sk-sub' -EventName 'SubagentStop')
    Check 'SubagentStop gets the same gate as Stop' ($r.Out -match '"decision"\s*:\s*"block"') $r.Out
    $skAdvHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library'); SKILLS_SUMMARY_ENFORCEMENT = 'advisory' }
    $skAdvProj = New-Proj 'SkillsStopAdvisory'
    New-Item -ItemType Directory -Path (Join-Path $skAdvProj '.claude\skills\gate-skill') -Force | Out-Null
    $r = Fire -HookPath $skAdvHook -Cwd $skAdvProj -RawStdin (New-StopStdin -Cwd $skAdvProj -Transcript $tSkillNoLine -SessionId 'sk-a1')
    Check 'advisory mode reports the same finding without a block decision' (
        $r.Out -match 'invoked at least one skill' -and $r.Out -notmatch '"decision"') $r.Out
    $skOffHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library'); SKILLS_SUMMARY_ENFORCEMENT = 'off' }
    $skOffProj = New-Proj 'SkillsStopOff'
    New-Item -ItemType Directory -Path (Join-Path $skOffProj '.claude\skills\gate-skill') -Force | Out-Null
    $r = Fire -HookPath $skOffHook -Cwd $skOffProj -RawStdin (New-StopStdin -Cwd $skOffProj -Transcript $tSkillNoLine -SessionId 'sk-o1')
    Check 'off mode skips the closing check entirely' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $skOffHook -Cwd $skOffProj
    Check 'off mode still runs the pre-task half' ($r.Out -match 'SKILL POLICY CHECK') $r.Out

    # =====================================================================
    # The rest of the closing gate lives in its own file - this one had reached
    # the size ceiling. Dot-sourced here so it shares this scope and harness,
    # and here specifically so it runs while the ambient client is still Claude.
    . (Join-Path $PSScriptRoot '_testskillstopgate.ps1')

    Write-Host '--- Skills-Check: UserPromptSubmit task-relevance nudge, once per session ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hook1 -Cwd $proj1 -RawStdin (New-PromptStdin -Cwd $proj1 -EventName 'UserPromptSubmit' -Prompt 'anything' -SessionId 'skills-s1')
    Check 'UserPromptSubmit emits the mandatory-skill-check nudge' ($r.Out -match 'SKILL POLICY CHECK' -and $r.Out -match 'skill use is MANDATORY') $r.Out
    # The skills inventory is the SET a task may use; Spec Kit is the ROUTE the
    # task takes. Naming only the set reads as though the set were the whole
    # policy, which is what the 2026-09-19 rules stopped being true.
    Check 'the nudge also names the Spec Kit route' (
        $r.Out -match 'Spec Kit routes every task' -and $r.Out -match 'speckit-converge') $r.Out
    # Advisory only: naming a route must not turn this hook into a second gate.
    Check 'and naming it adds no blocking decision' ($r.Out -notmatch '"decision":"block"') $r.Out
    $r2 = Fire -HookPath $hook1 -Cwd $proj1 -RawStdin (New-PromptStdin -Cwd $proj1 -EventName 'UserPromptSubmit' -Prompt 'anything else' -SessionId 'skills-s1')
    Check 'the SAME session does not repeat the nudge' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -HookPath $hook1 -Cwd $proj1 -RawStdin (New-PromptStdin -Cwd $proj1 -EventName 'UserPromptSubmit' -Prompt 'anything' -SessionId 'skills-s2')
    Check 'a NEW session gets the nudge again' ($r3.Out -match 'SKILL POLICY CHECK') $r3.Out

    # =====================================================================
    Write-Host '--- Skills-Check: reports .ai/SKILLS.md record ---' -ForegroundColor Cyan
    $proj2 = New-Proj 'WithSkillsRecord'
    New-Item -ItemType Directory -Path (Join-Path $proj2 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj2 '.ai\SKILLS.md') '# active skills'
    $hook2 = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $hook2 -Cwd $proj2
    Check 'points at .ai/SKILLS.md' ($r.Out -like '*SKILL POLICY CHECK*' -and $r.Out -like '*.ai/SKILLS.md*') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: reports a configured skill library ---' -ForegroundColor Cyan
    $proj3 = New-Proj 'WithLibrary'
    $libDir = Join-Path $Work 'fake-skill-library'
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null
    $hook3 = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $libDir }
    $r = Fire -HookPath $hook3 -Cwd $proj3
    Check 'points at the configured library path' ($r.Out -like '*SKILL POLICY CHECK*' -and $r.Out -like ('*' + $libDir.Replace('\', '\\') + '*')) $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $hook4 = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $libDir }
    $r = Fire -HookPath $hook4 -Cwd $proj3 -Exe 'powershell.exe'
    Check '5.1 host: emits cleanly, no crash' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*SKILL POLICY CHECK*') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: client routing is isolated (Claude vs Codex, never both policies) ---' -ForegroundColor Cyan
    $routeProj = New-Proj 'SkillsRouting'
    New-Item -ItemType Directory -Path (Join-Path $routeProj '.claude\skills\route-claude') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $routeProj '.agents\skills\route-codex') -Force | Out-Null
    $routeHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    # CLAUDE_PROJECT_DIR present -> Claude route (reads .claude\skills, cites skill-policy.md).
    Set-ClaudeProjectDir $Work
    $rc = Fire -HookPath $routeHook -Cwd $routeProj
    Check 'auto-detect: CLAUDE_PROJECT_DIR present -> Claude route' ($rc.Out -match 'SKILL POLICY CHECK \(claude\)') $rc.Out
    Check 'Claude route lists only the .claude skill' ($rc.Out -like '*route-claude*' -and $rc.Out -notlike '*route-codex*') $rc.Out
    Check 'Claude route cites the non-Codex policy (skill-policy.md)' ($rc.Out -match 'skill-policy\.md') $rc.Out
    Check 'Claude route never references the Codex policy or Codex locations' ($rc.Out -notmatch 'codex' -and $rc.Out -notmatch '\.agents') $rc.Out
    # CLAUDE_PROJECT_DIR absent -> Codex route (reads .agents\skills, cites the Codex policy).
    Set-ClaudeProjectDir ''
    $rx = Fire -HookPath $routeHook -Cwd $routeProj
    Check 'auto-detect: CLAUDE_PROJECT_DIR absent -> Codex route' ($rx.Out -match 'SKILL POLICY CHECK \(codex\)') $rx.Out
    Check 'Codex route lists only the .agents skill' ($rx.Out -like '*route-codex*' -and $rx.Out -notlike '*route-claude*') $rx.Out
    Check 'Codex route cites the Codex-optimized policy' ($rx.Out -match 'skill-policy-codex-optimized\.md') $rx.Out
    Check 'Codex route never references the Claude policy or Claude locations' ($rx.Out -notmatch '\.claude' -and $rx.Out -notmatch 'skill-policy\.md') $rx.Out

    # =====================================================================
    Write-Host '--- Skills-Check: Codex route under Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $r51x = Fire -HookPath $routeHook -Cwd $routeProj -Exe 'powershell.exe'
    Check '5.1 Codex route: emits cleanly, no crash' ($r51x.Exit -eq 0 -and $r51x.Err -eq '' -and $r51x.Out -match 'SKILL POLICY CHECK \(codex\)') $r51x.Out
    Set-ClaudeProjectDir $Work

    # =====================================================================
    Write-Host '--- Skills-Check: global + project sources deduplicated by skill name: ---' -ForegroundColor Cyan
    $dedupProj = New-Proj 'SkillsDedup'
    $dedupGlobal = Join-Path $Work 'dedup-global-skills'
    # Same skill (identical SKILL.md, name: shared-skill) planted in project AND
    # global under DIFFERENT folder names, proving dedup is by name: not folder.
    $sharedBody = "---`nname: shared-skill`ndescription: test`n---`nbody"
    New-Item -ItemType Directory -Path (Join-Path $dedupProj '.claude\skills\folder-a') -Force | Out-Null
    Write-Utf8 (Join-Path $dedupProj '.claude\skills\folder-a\SKILL.md') $sharedBody
    New-Item -ItemType Directory -Path (Join-Path $dedupGlobal 'folder-b') -Force | Out-Null
    Write-Utf8 (Join-Path $dedupGlobal 'folder-b\SKILL.md') $sharedBody
    $dedupHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library'); GLOBAL_SKILLS_DIR = $dedupGlobal }
    $rd = Fire -HookPath $dedupHook -Cwd $dedupProj
    $sharedCount = ([regex]::Matches($rd.Out, 'shared-skill')).Count
    Check 'the same skill in two locations is listed once (deduped by name:)' ($sharedCount -eq 1) ($rd.Out + ' [count=' + $sharedCount + ']')
    Check 'the deduped skill shows both sources' ($rd.Out -match 'shared-skill \[global\+project\]') $rd.Out
    Check 'identical copies are NOT flagged as a conflict' ($rd.Out -notmatch 'CONFLICT') $rd.Out

    # =====================================================================
    Write-Host '--- Skills-Check: same-name/different-content conflict is flagged, not silently overwritten ---' -ForegroundColor Cyan
    $confProj = New-Proj 'SkillsConflict'
    $confGlobal = Join-Path $Work 'conflict-global-skills'
    New-Item -ItemType Directory -Path (Join-Path $confProj '.claude\skills\dup') -Force | Out-Null
    Write-Utf8 (Join-Path $confProj '.claude\skills\dup\SKILL.md') "---`nname: dup-skill`n---`nPROJECT VERSION"
    New-Item -ItemType Directory -Path (Join-Path $confGlobal 'dup') -Force | Out-Null
    Write-Utf8 (Join-Path $confGlobal 'dup\SKILL.md') "---`nname: dup-skill`n---`nGLOBAL VERSION (different)"
    $confHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library'); GLOBAL_SKILLS_DIR = $confGlobal }
    $rf = Fire -HookPath $confHook -Cwd $confProj
    Check 'a same-name/different-content skill is reported as a CONFLICT' ($rf.Out -match 'CONFLICT' -and $rf.Out -match 'dup-skill') $rf.Out
    Check 'the conflict advises explicit repair, never a silent overwrite' ($rf.Out -match 'do NOT overwrite silently') $rf.Out

    # =====================================================================
    Write-Host '--- Skills-Check: import + record guidance is accurate and secret-free ---' -ForegroundColor Cyan
    $guideProj = New-Proj 'SkillsGuide'
    New-Item -ItemType Directory -Path (Join-Path $guideProj '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $guideProj '.ai\SKILLS.md') '# active skills'
    $guideLib = Join-Path $Work 'guide-library'
    New-Item -ItemType Directory -Path $guideLib -Force | Out-Null
    $guideHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $guideLib }
    $rg = Fire -HookPath $guideHook -Cwd $guideProj
    Check 'import guidance: copy the minimal set (1-5)' ($rg.Out -match 'minimal set \(1-5\)') $rg.Out
    Check 'import guidance: never follow reparse points' ($rg.Out -match 'never reparse points') $rg.Out
    Check 'import guidance: exclude secrets/caches/VCS metadata' ($rg.Out -match 'secrets/caches/VCS metadata') $rg.Out
    Check 'import guidance: never overwrite a modified project skill silently' ($rg.Out -match 'never overwrite a modified project skill silently') $rg.Out
    Check 'record guidance: record source/destination/hash/agent/reason in .ai/SKILLS.md' ($rg.Out -match 'source/destination/hash/agent/reason') $rg.Out
    Check 'record guidance: .ai/SKILLS.md is local-only and secret-free' ($rg.Out -match 'local-only, secret-free') $rg.Out

    # =====================================================================
    Write-Host '--- Skills-Check: all THREE installed sources are enumerated (global, project, plugin) ---' -ForegroundColor Cyan
    # A plugin cache laid out the way the client lays one out:
    #   <root>\<marketplace>\<plugin>\<version>\skills\<skill>
    # The plugin id is the SECOND segment, and the client addresses these skills
    # as "<plugin>:<skill>" - so that is what the inventory has to report.
    function New-PluginCache {
        param([string]$Name, [hashtable]$Plugins)
        $root = Join-Path $Work $Name
        foreach ($plugin in $Plugins.Keys) {
            foreach ($skill in $Plugins[$plugin]) {
                New-Item -ItemType Directory -Path (Join-Path $root ('market\' + $plugin + '\1.0.0\skills\' + $skill)) -Force | Out-Null
            }
        }
        return $root
    }
    $threeProj = New-Proj 'ThreeSources'
    New-Item -ItemType Directory -Path (Join-Path $threeProj '.claude\skills\proj-only-skill') -Force | Out-Null
    $threeGlobal = Join-Path $Work 'three-global-skills'
    New-Item -ItemType Directory -Path (Join-Path $threeGlobal 'global-only-skill') -Force | Out-Null
    $threePlugins = New-PluginCache 'three-plugin-cache' @{ 'superpowers' = @('brainstorming', 'writing-plans'); 'ponytail' = @('ponytail-audit') }
    $threeHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR         = (Join-Path $Work 'no-such-library')
        GLOBAL_SKILLS_DIR  = $threeGlobal
        PLUGIN_SKILLS_ROOT = $threePlugins
    }
    $r3s = Fire -HookPath $threeHook -Cwd $threeProj
    Check 'the project source is enumerated' ($r3s.Out -match 'proj-only-skill \[project\]') $r3s.Out
    Check 'the global source is enumerated' ($r3s.Out -match 'global-only-skill \[global\]') $r3s.Out
    Check 'the plugin source is enumerated and counted' (
        $r3s.Out -match 'Plugin skills: 3 across 2 plugins' -and
        $r3s.Out -match 'ponytail \(1\)' -and $r3s.Out -match 'superpowers \(2\)') $r3s.Out
    Check 'plugin skills are addressed as <plugin>:<skill>, the form the client uses' (
        $r3s.Out -match 'Address these as <plugin>:<skill>') $r3s.Out
    # Several hundred plugin skill names would be a token bill, not information -
    # the inventory names PLUGINS, and individual plugin skills surface only in
    # the per-prompt shortlist below.
    Check 'the inventory does not dump every plugin skill name' ($r3s.Out -notmatch 'writing-plans') $r3s.Out
    $emptyPluginRoot = Join-Path $Work 'empty-plugin-cache'
    New-Item -ItemType Directory -Path $emptyPluginRoot -Force | Out-Null
    $emptyPluginHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR = (Join-Path $Work 'no-such-library'); GLOBAL_SKILLS_DIR = $threeGlobal; PLUGIN_SKILLS_ROOT = $emptyPluginRoot
    }
    $r = Fire -HookPath $emptyPluginHook -Cwd $threeProj
    Check 'an existing but empty plugin cache is reported as empty, not silently omitted' (
        $r.Out -match 'Plugin skills: none found under') $r.Out
    # A plugin skill counts as INSTALLED for ::deep-debug capability coverage.
    $ddPlugins = New-PluginCache 'dd-plugin-cache' @{ 'superpowers' = @('systematic-debugging', 'test-driven-development', 'requesting-code-review', 'verification-before-completion') }
    $ddPluginHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{
        SKILLS_DIR = (Join-Path $Work 'no-such-library'); PLUGIN_SKILLS_ROOT = $ddPlugins
    }
    $ddPluginProj = New-Proj 'DeepDebugViaPlugins'
    $r = Fire -HookPath $ddPluginHook -Cwd $ddPluginProj -RawStdin (New-PromptStdin -Cwd $ddPluginProj -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -SessionId 'ddp-1')
    Check 'core capabilities provided by PLUGINS are not reported as missing' (
        $r.Out -match 'capability routing' -and $r.Out -notmatch 'NOT VISIBLE') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: the library is searched against the PROMPT, with an exact import command ---' -ForegroundColor Cyan
    $libProj = New-Proj 'LibraryMatch'
    $matchLib = Join-Path $Work 'match-library'
    # Mixed layout, exactly like the real library: some skills sit at the root,
    # others under a category folder. Both must be found.
    foreach ($rel in @('telegram-bot-builder', 'security\api-security-testing', 'development\powershell-windows', 'unrelated\basket-weaving')) {
        $d = Join-Path $matchLib $rel
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Utf8 (Join-Path $d 'SKILL.md') ("---`nname: " + (Split-Path -Leaf $rel) + "`n---`nbody")
    }
    $libHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $matchLib }
    # Every path in the emitted message is JSON-escaped (each backslash doubled),
    # so path assertions run against the DECODED context, not the raw stdout.
    function Get-Context {
        param([string]$RawOut)
        try {
            $doc = $RawOut | ConvertFrom-Json
            if ($null -ne $doc -and $null -ne $doc.PSObject.Properties['hookSpecificOutput']) {
                return [string]$doc.hookSpecificOutput.additionalContext
            }
        }
        catch { }
        return ''
    }
    $libDirsBefore = @(Get-ChildItem -LiteralPath $matchLib -Recurse -Directory).Count
    $rl = Fire -HookPath $libHook -Cwd $libProj -RawStdin (New-PromptStdin -Cwd $libProj -EventName 'UserPromptSubmit' -Prompt 'build a telegram bot and run api security testing on it' -SessionId 'lib-1')
    Check 'a library skill matching the prompt is named' ($rl.Out -match 'telegram-bot-builder') $rl.Out
    Check 'a library skill in a CATEGORY subfolder is found too' ($rl.Out -match 'api-security-testing') $rl.Out
    Check 'an unrelated library skill is not suggested' ($rl.Out -notmatch 'basket-weaving') $rl.Out
    Check 'each suggestion carries a ready-to-run copy command with the exact source path' (
        $rl.Out -match 'Copy-Item -LiteralPath' -and $rl.Out -match 'telegram-bot-builder') $rl.Out
    $rlCtx = Get-Context $rl.Out
    Check 'the destination is the client-routed project skills directory' (
        $rlCtx -like '*Destination for this project*' -and
        $rlCtx -like ('*' + (Join-Path $libProj '.claude\skills') + '*')) $rlCtx
    Check 'importing is named as an AUTHORIZED operation the user must approve first' (
        $rl.Out -match 'AUTHORIZED operation' -and $rl.Out -match 'ask the user first') $rl.Out
    Check 'the hook states it never copies anything itself' ($rl.Out -match 'never copies anything itself') $rl.Out
    Check 'the import safety boundary travels with the command' (
        $rl.Out -match 'never reparse points' -and $rl.Out -match 'secrets/caches/VCS metadata' -and
        $rl.Out -match 'never overwrite a modified project skill silently' -and
        $rl.Out -match 'source/destination/hash/agent/reason') $rl.Out
    # THE POLICY BOUNDARY, asserted as behaviour and not just as wording: after a
    # run that recommends an import, nothing may have been copied.
    Check 'the hook copied NOTHING - the destination directory was not even created' (
        -not (Test-Path -LiteralPath (Join-Path $libProj '.claude\skills'))) $null
    Check 'the library itself is untouched' (
        (@(Get-ChildItem -LiteralPath $matchLib -Recurse -Directory)).Count -eq $libDirsBefore) $null
    $rlSame = Fire -HookPath $libHook -Cwd $libProj -RawStdin (New-PromptStdin -Cwd $libProj -EventName 'UserPromptSubmit' -Prompt 'build a telegram bot and run api security testing on it' -SessionId 'lib-1')
    Check 'an unchanged shortlist is fingerprint-suppressed in the same session' ($rlSame.Exit -eq 0 -and $rlSame.Out -eq '') $rlSame.Out
    $rlDiff = Fire -HookPath $libHook -Cwd $libProj -RawStdin (New-PromptStdin -Cwd $libProj -EventName 'UserPromptSubmit' -Prompt 'now write powershell windows scripts' -SessionId 'lib-1')
    Check 'a DIFFERENT prompt with different matches re-reports in the same session' (
        $rlDiff.Out -match 'powershell-windows' -and $rlDiff.Out -notmatch 'basket-weaving') $rlDiff.Out
    # A skill is addressed by the name: and description: in its SKILL.md, so the
    # shortlist scores those - not the folder name alone. Its own library, so the
    # index is keyed by a configuration these two fixtures are actually in.
    $idProj = New-Proj 'LibraryIdentity'
    $idLib = Join-Path $Work 'identity-library'
    foreach ($row in @(
            @('analysis\fzzlebrk', 'fzzlebrk', 'Render vector tile basemaps for offline mapping'),
            @('science\glycoengineering', 'glycoengineering', 'Metabolic pathway work on glycans'))) {
        $d = Join-Path $idLib $row[0]
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Utf8 (Join-Path $d 'SKILL.md') ("---`nname: " + $row[1] + "`ndescription: " + $row[2] + "`n---`nbody")
    }
    $idHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $idLib }
    $rid = Fire -HookPath $idHook -Cwd $idProj -RawStdin (New-PromptStdin -Cwd $idProj -EventName 'UserPromptSubmit' -Prompt 'render offline basemaps and review the engineering plan' -SessionId 'id-1')
    Check 'a library skill is found by its DESCRIPTION when its folder shares no token with the prompt' (
        $rid.Out -match 'fzzlebrk') $rid.Out
    Check 'a folder that merely CONTAINS a prompt token is no longer offered for it' (
        $rid.Out -notmatch 'glycoengineering') $rid.Out
    # An already-installed skill must not be offered as an import: that would ask
    # for an authorization that buys nothing.
    $instProj = New-Proj 'LibraryAlreadyInstalled'
    New-Item -ItemType Directory -Path (Join-Path $instProj '.claude\skills\telegram-bot-builder') -Force | Out-Null
    $rInst = Fire -HookPath $libHook -Cwd $instProj -RawStdin (New-PromptStdin -Cwd $instProj -EventName 'UserPromptSubmit' -Prompt 'build a telegram bot' -SessionId 'lib-2')
    Check 'an already-installed match is offered for ACTIVATION, not for import' (
        $rInst.Out -match 'INSTALLED and matching this prompt' -and
        $rInst.Out -match 'telegram-bot-builder \[project\]' -and
        $rInst.Out -notmatch 'Copy-Item') $rInst.Out
    $rNo = Fire -HookPath $libHook -Cwd $libProj -RawStdin (New-PromptStdin -Cwd $libProj -EventName 'UserPromptSubmit' -Prompt 'zzzz qqqq wwww' -SessionId 'lib-3')
    Check 'no name match is reported as a name-level miss, never as "no skill applies"' (
        $rNo.Out -match 'No skill name matched this prompt' -and
        $rNo.Out -match 'not proof that no skill applies') $rNo.Out

    # =====================================================================
    Write-Host '--- Skills-Check: the cached index is written, re-read, and expiry-checked ---' -ForegroundColor Cyan
    # The plugin glob and the ~1000-entry library walk cost roughly two seconds
    # together, so they are cached. Proving the READ path is not cosmetic: if it
    # silently fell through to a rebuild, every prompt would pay that cost again.
    # It is isolated by removing the library AFTER the index is built - a rebuild
    # would then find nothing, so a surviving match can only have come from the
    # cache. A non-zero TTL is used here so the expiry arithmetic runs too (the
    # suite default pins TTL to 0 to keep other cases timing-independent).
    $cacheProj = New-Proj 'IndexCache'
    New-Item -ItemType Directory -Path (Join-Path $cacheProj '.claude\skills\anchor-skill') -Force | Out-Null
    $cacheLib = Join-Path $Work 'cache-library'
    $cacheSkill = Join-Path $cacheLib 'category\cached-telemetry-skill'
    New-Item -ItemType Directory -Path $cacheSkill -Force | Out-Null
    Write-Utf8 (Join-Path $cacheSkill 'SKILL.md') "---`nname: cached-telemetry-skill`n---`nbody"
    $cacheHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $cacheLib; LIBRARY_INDEX_TTL_MINUTES = '600' }
    $rc1 = Fire -HookPath $cacheHook -Cwd $cacheProj -RawStdin (New-PromptStdin -Cwd $cacheProj -EventName 'UserPromptSubmit' -Prompt 'add telemetry to the app' -SessionId 'cache-1')
    Check 'the first prompt builds the index and matches the library skill' ($rc1.Out -match 'cached-telemetry-skill') $rc1.Out
    Remove-Item -LiteralPath $cacheLib -Recurse -Force
    $rc2 = Fire -HookPath $cacheHook -Cwd $cacheProj -RawStdin (New-PromptStdin -Cwd $cacheProj -EventName 'UserPromptSubmit' -Prompt 'add telemetry to the app' -SessionId 'cache-2')
    Check 'a later prompt is served from the cached index, not a fresh walk' ($rc2.Out -match 'cached-telemetry-skill') $rc2.Out
    $rc51 = Fire -HookPath $cacheHook -Cwd $cacheProj -Exe 'powershell.exe' -RawStdin (New-PromptStdin -Cwd $cacheProj -EventName 'UserPromptSubmit' -Prompt 'add telemetry to the app' -SessionId 'cache-3')
    Check '5.1 host: reads the same cached index, including the TTL arithmetic' (
        $rc51.Exit -eq 0 -and $rc51.Err -eq '' -and $rc51.Out -match 'cached-telemetry-skill') ($rc51.Err + ' | ' + $rc51.Out)
    # A changed source configuration invalidates the index rather than serving a
    # foreign one: the same project, pointed at a different library, must not
    # keep reporting the old library's skills.
    $otherLib = Join-Path $Work 'other-library'
    New-Item -ItemType Directory -Path $otherLib -Force | Out-Null
    $otherHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = $otherLib; LIBRARY_INDEX_TTL_MINUTES = '600' }
    $rc3 = Fire -HookPath $otherHook -Cwd $cacheProj -RawStdin (New-PromptStdin -Cwd $cacheProj -EventName 'UserPromptSubmit' -Prompt 'add telemetry to the app' -SessionId 'cache-4')
    Check 'a changed library path rebuilds the index instead of serving the old one' ($rc3.Out -notmatch 'cached-telemetry-skill') $rc3.Out

    # =====================================================================
    Write-Host '--- Skills-Check: ::deep-debug capability routing (claude shape) ---' -ForegroundColor Cyan
    Set-ClaudeProjectDir $Work
    $ddProj = New-Proj 'SkillsDeepDebug'
    # Install three of the four core capabilities; identity must come from the
    # exact name: in SKILL.md, so the folder names deliberately differ.
    foreach ($pair in @(@('sysdbg-folder', 'systematic-debugging'), @('tdd-folder', 'test-driven-development'), @('rcr-folder', 'requesting-code-review'))) {
        $d = Join-Path $ddProj ('.claude\skills\' + $pair[0])
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Utf8 (Join-Path $d 'SKILL.md') ("---`nname: " + $pair[1] + "`ndescription: test`n---`nbody")
    }
    $ddHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $ddHook -Cwd $ddProj -RawStdin (New-PromptStdin -Cwd $ddProj -EventName 'UserPromptSubmit' -Prompt 'please deep debug the login flow, maybe deep-debug harder' -SessionId 'sdd-prose')
    Check 'ordinary prose "deep debug" never surfaces the capability graph (generic nudge only)' (
        $r.Out -notmatch 'capability routing' -and $r.Out -match 'skill use is MANDATORY') $r.Out
    $r = Fire -HookPath $ddHook -Cwd $ddProj -RawStdin (New-PromptStdin -Cwd $ddProj -EventName 'UserPromptSubmit' -Prompt '::deep-debug the login flow' -SessionId 'sdd-c1')
    Check 'standalone ::deep-debug surfaces the phase-routed capability graph' (
        $r.Out -match 'SKILL POLICY CHECK \(claude\) - ::deep-debug capability routing' -and
        $r.Out -match 'Activate by PHASE, never everything at once') $r.Out
    Check 'identity rule: exact name: in each installed SKILL.md, never folder/plugin/marketplace/category' (
        $r.Out -match 'exact name: in each installed SKILL\.md' -and
        $r.Out -match 'never a folder, plugin, marketplace, or category label') $r.Out
    Check 'claude shape references native /goal and /ponytail:ponytail-audit' (
        $r.Out -match 'native /goal' -and $r.Out -match 'native /ponytail:ponytail-audit') $r.Out
    Check 'goal/orchestration: ::multi-agent = codeword dependency, parallel/subagent skills, cycle bounds' (
        $r.Out -match '::multi-agent is a codeword dependency, not a skill' -and
        $r.Out -match 'superpowers:dispatching-parallel-agents' -and
        $r.Out -match 'superpowers:subagent-driven-development' -and
        $r.Out -match 'never recursive re-runs, never nested agent trees') $r.Out
    Check 'understanding/planning: context/graphify/brainstorm/plan skills stay gated' (
        $r.Out -match 'audit-context-building' -and $r.Out -match 'Graphify only under its own policy' -and
        $r.Out -match 'only for genuine behavior/design ambiguity' -and
        $r.Out -match 'only when a complex repair lacks an executable plan') $r.Out
    Check 'known bug: debugging triad + exactly one runtime debugger route' (
        $r.Out -match 'systematic-debugging, test-driven-development, verification-before-completion' -and
        $r.Out -match 'CHOOSE debugging-code \(DAP\) OR debug-live' -and
        $r.Out -match 'not normally both for one question') $r.Out
    Check 'existing plan: executing-plans only when a real plan exists' (
        $r.Out -match 'executing-plans \(only when a real plan exists\)') $r.Out
    Check 'security: smallest applicable subset incl. fp-check/variant-analysis/language reviews' (
        $r.Out -match 'smallest applicable subset' -and $r.Out -match 'differential-review' -and
        $r.Out -match 'insecure-defaults' -and $r.Out -match 'semgrep and/or codeql' -and
        $r.Out -match 'sarif-parsing \(when SARIF output exists\)' -and
        $r.Out -match 'fp-check before treating automated findings as confirmed' -and
        $r.Out -match 'variant-analysis after a proven root cause' -and
        $r.Out -match 'supply-chain-risk-auditor' -and
        $r.Out -match 'c-review \(C/C\+\+ only\)' -and $r.Out -match 'rust-review \(Rust only\)') $r.Out
    # JSON-escaped quotes wrap "static-analysis", so assert around them.
    Check 'the static-analysis LABEL is never an invokable skill without an installed name:' (
        $r.Out -match 'static-analysis' -and
        $r.Out -match 'is a plugin/category LABEL, not an invokable skill' -and
        $r.Out -match 'unless an installed SKILL\.md declares that exact name:') $r.Out
    Check 'security phase still requires authorization for active testing' (
        $r.Out -match 'Active security testing still requires ownership/authorization') $r.Out
    Check 'test strengthening: property-based-testing only for real invariants, none manufactured' (
        $r.Out -match 'property-based-testing only where a meaningful invariant exists' -and
        $r.Out -match 'never manufacture low-value properties') $r.Out
    Check 'finalization: worktrees + branch-finishing gated, Ponytail exactly once, no second pass' (
        $r.Out -match 'using-git-worktrees only when authorized isolation' -and
        $r.Out -match 'finishing-a-development-branch only when work really occurred' -and
        $r.Out -match 'exactly ONCE' -and $r.Out -match 'never a second pass') $r.Out
    Check 'missing core capability is SURFACED (verification-before-completion), workflow blocked/partial' (
        $r.Out -match 'NOT VISIBLE in the enumerated project/global/plugin skill sources: verification-before-completion\.' -and
        $r.Out -match 'REPORTED as missing' -and $r.Out -match 'blocked/partial' -and
        $r.Out -match 'never silently skipped') $r.Out
    Check 'no silent install/copy/refresh/remove/enable, task-relevant subset only' (
        $r.Out -match 'never silently install/copy/refresh/overwrite/remove/enable' -and
        $r.Out -match 'Select only the task-relevant subset') $r.Out
    Check 'client syntax separation is explicit (neither authoritative for the other)' (
        $r.Out -match 'keep Claude and Codex invocation syntax separate' -and
        $r.Out -match 'authoritative for the other') $r.Out
    $r2 = Fire -HookPath $ddHook -Cwd $ddProj -RawStdin (New-PromptStdin -Cwd $ddProj -EventName 'UserPromptSubmit' -Prompt '::deep-debug once more' -SessionId 'sdd-c1')
    Check 'repeated unchanged ::deep-debug guidance is fingerprint-suppressed in the SAME session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    # Installing the missing capability changes the skill set -> re-report in the
    # SAME session, and the missing line disappears.
    $vbc = Join-Path $ddProj '.claude\skills\vbc-folder'
    New-Item -ItemType Directory -Path $vbc -Force | Out-Null
    Write-Utf8 (Join-Path $vbc 'SKILL.md') "---`nname: verification-before-completion`ndescription: test`n---`nbody"
    $r3 = Fire -HookPath $ddHook -Cwd $ddProj -RawStdin (New-PromptStdin -Cwd $ddProj -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -SessionId 'sdd-c1')
    Check 'an installed-skill change re-reports in the same session and clears the missing line' (
        $r3.Out -match 'capability routing' -and $r3.Out -notmatch 'NOT VISIBLE') $r3.Out

    # =====================================================================
    Write-Host '--- Skills-Check: ::deep-debug capability routing (codex shape) ---' -ForegroundColor Cyan
    Set-ClaudeProjectDir ''
    $ddxProj = New-Proj 'SkillsDeepDebugCodex'
    $dx = Join-Path $ddxProj '.agents\skills\tdd-folder'
    New-Item -ItemType Directory -Path $dx -Force | Out-Null
    Write-Utf8 (Join-Path $dx 'SKILL.md') "---`nname: test-driven-development`ndescription: test`n---`nbody"
    $ddxHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $rx = Fire -HookPath $ddxHook -Cwd $ddxProj -RawStdin (New-PromptStdin -Cwd $ddxProj -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -SessionId 'sddx-1')
    Check 'codex shape emits the same phase-routed graph under the codex client' (
        $rx.Out -match 'SKILL POLICY CHECK \(codex\) - ::deep-debug capability routing' -and
        $rx.Out -match 'superpowers:dispatching-parallel-agents' -and $rx.Out -match 'property-based-testing') $rx.Out
    Check 'codex shape does not require the Claude slash literals (client-native references instead)' (
        $rx.Out -notmatch '/ponytail:ponytail-audit' -and $rx.Out -notmatch '/goal' -and
        $rx.Out -match 'client-native goal command' -and
        $rx.Out -match 'ponytail-audit capability via this client' -and
        $rx.Out -match 'supported invocation') $rx.Out
    Check 'codex shape never references Claude locations or the claude policy file' (
        $rx.Out -notmatch '\.claude' -and $rx.Out -notmatch 'skill-policy\.md') $rx.Out
    Check 'codex-missing core capabilities are surfaced too' (
        $rx.Out -match 'NOT VISIBLE' -and $rx.Out -match 'systematic-debugging' -and
        $rx.Out -match 'verification-before-completion') $rx.Out
    Set-ClaudeProjectDir $Work

    # =====================================================================
    Write-Host '--- Skills-Check: static safety (the hook never executes anything) ---' -ForegroundColor Cyan
    # Same static-assertion style as the Test-Run-Guard suite: the DETECTOR/
    # ADVISORY hook must have no execution primitives at all - it references
    # skills and native commands as text only.
    $skillsText = [System.IO.File]::ReadAllText($SkillsHook)
    Check 'Skills-Check source has NO Start-Process / Invoke-Expression / iex / call-operator-on-data' (
        $skillsText -notmatch 'Start-Process' -and $skillsText -notmatch 'Invoke-Expression' -and
        $skillsText -notmatch '(?i)\biex\b' -and $skillsText -notmatch '&\s*\$') $null
    Check 'Skills-Check references skills/commands as text (routing graph present in source)' (
        $skillsText -match 'capability routing' -and $skillsText -match 'ponytail-audit')

    # Restore the ambient client signal for the remaining (client-agnostic) tests.
    Set-ClaudeProjectDir $OrigClaudeProjectDir

