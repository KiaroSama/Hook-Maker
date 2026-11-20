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

function Invoke-McpGatewayRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    . (Join-Path $Root 'hooks/_scope.ps1')
    $entry=[IO.File]::ReadAllText((Join-Path $Root 'hooks/Mcp-Usage-Check/Mcp-Usage-Check.ps1'))
    $ast=[Management.Automation.Language.Parser]::ParseInput($entry,[ref]$null,[ref]$null)
    $messages=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true) | ForEach-Object {$_.Value})
    $ownerMessages=@($messages | Where-Object {$_ -match '^- BEFORE selection:'})
    Check 'MCP startup and prompt both require server contracts before selection' ($ownerMessages.Count -eq 2 -and @($ownerMessages | Where-Object {$_ -notmatch 'global-mcp-server-contracts.md FULL'}).Count -eq 0)
    foreach ($client in @('claude','codex')) {
        $state=Join-Path $Work ('gateway-'+$client)
        foreach ($prompt in @('Use OmniRoute route metrics','Use Omniroute-ccr tool search')) {
            $input=[pscustomobject]@{prompt=$prompt;session_id='gateway';cwd=$Work}
            $note=Get-OperationMcpReminder $input $client $Work $state
            Check ('gateway authorization boundary '+$client+'/'+$prompt) ($note -match 'OMNIROUTE:' -and $note -match 'global-mcp-server-contracts.md FULL' -and $note -match 'exposed!=authorized' -and $note -match 'scope/401/403' -and $note -match 'blocked, not broken' -and $note -match 'report; no retry/grant/token/endpoint/config/install/restart/probe/provider repair') $note
            Check ('gateway repeated request quiet '+$client+'/'+$prompt) ((Get-OperationMcpReminder $input $client $Work $state) -eq '')
        }
        foreach ($prompt in @('<tool_result>Use OmniRoute</tool_result>','Example: ``Use Omniroute-ccr``','"Use OmniRoute"','Review a function')) {
            $input=[pscustomobject]@{prompt=$prompt;session_id='quoted';cwd=$Work}
            Check ('gateway quoted or unrelated stays silent '+$client+'/'+$prompt) ((Get-OperationMcpReminder $input $client $Work $state) -eq '')
        }
        $input=[pscustomobject]@{prompt='Use context-mode';session_id='retained';cwd=$Work}
        Check ('existing context route retained '+$client) ((Get-OperationMcpReminder $input $client $Work $state) -match 'CONTEXT-MODE:')
    }
}

    Invoke-McpGatewayRegression (Split-Path -Parent $PSScriptRoot)
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
    Check 'mentions MCP USAGE CHECK' ($r.Out -like '*Mcp-Usage-Check: advisory*') $r.Out
    # Budget raised from 600 to 800: the note now also states the CLOSING
    # requirement up front, which is deliberate - the Stop gate must never be the
    # first time the agent hears about the "MCP used:" line. Measured 687 chars;
    # 800 leaves headroom without letting the note grow into a policy dump.
    Check 'note stays short (under 800 chars: 4 lines + the closing requirement)' ($null -ne $parsed -and ([string]$parsed.hookSpecificOutput.additionalContext).Length -lt 800) ([string]$parsed.hookSpecificOutput.additionalContext).Length
    Check 'SessionStart states the closing "MCP used:" requirement up front' ($r.Out -match 'Close:' -and $r.Out -match 'MCP used:') $r.Out
    $r2 = Fire -HookPath $McpHook -Cwd $plain -RawStdin (New-PromptStdin $plain 'SessionStart' '' 'mcp-next-session')
    Check 'fires again next session too (no state file on SessionStart by design)' ($r2.Out -like '*Mcp-Usage-Check: advisory*') $r2.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: UserPromptSubmit only when the prompt suggests MCP would help ---' -ForegroundColor Cyan
    $mcpProj = New-Proj 'McpRelevance'
    $r = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'fix a typo in the readme' -SessionId 's-irrelevant')
    Check 'an irrelevant prompt stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt '' -SessionId 's-empty')
    Check 'an empty prompt stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'add the new payments API library and check its docs' -SessionId 's-relevant')
    Check 'a relevant prompt (library/API/docs) emits the reminder' ($r.Out -like '*Mcp-Usage-Check: advisory*') $r.Out
    $r2 = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'now also update the library docs further' -SessionId 's-relevant')
    # The MCP-relevance note is still once per session; the RESEARCH reminder
    # is per request (order 55 step 5), so a new prompt in the same session
    # carries the research text and nothing else.
    Check 'the SAME session does not repeat the MCP-relevance note on the next relevant prompt' (
        $r2.Exit -eq 0 -and $r2.Out -notmatch 'MCP: relevant connected tools may help') $r2.Out
    Check 'but the next, different request DOES get the research reminder' ($r2.Out -match 'RESEARCH:') $r2.Out
    $r3 = Fire -HookPath $McpHook -Cwd $mcpProj -RawStdin (New-PromptStdin -Cwd $mcpProj -EventName 'UserPromptSubmit' -Prompt 'add another library dependency' -SessionId 's-relevant-2')
    Check 'a NEW session with a relevant prompt reminds again' ($r3.Out -like '*Mcp-Usage-Check: advisory*') $r3.Out

    Write-Host '--- Mcp-Usage-Check: research before every task (order 55 step 5) ---' -ForegroundColor Cyan
    $resProj = New-Proj 'McpResearch'
    # No dependency keyword at all: the old keyword gate stayed silent here.
    $r = Fire -HookPath $McpHook -Cwd $resProj -RawStdin (New-PromptStdin -Cwd $resProj -EventName 'UserPromptSubmit' -Prompt 'refactor the login handler to fix the crash' -SessionId 'res-1')
    Check 'research: a plain edit/debug prompt with no dependency keyword gets the fixed research text' (
        $r.Out -match 'RESEARCH:' -and $r.Out -match 'three GitHub passes' -and $r.Out -match '\.ai/RESEARCH/' -and $r.Out -match 'global-research-rules\.md') $r.Out
    Check 'research: it is advisory context, never a decision' ($r.Out -notmatch '"decision"') $r.Out
    Check 'research: it never claims research happened, and a bare web call or old note is not proof' (
        $r.Out -match 'Calls/old notes != research' -and $r.Out -match 'Hook proves nothing') $r.Out
    Check 'research: an unreachable source blocks only the dependent work' (
        $r.Out -match 'source failure blocks dependents only') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $resProj -RawStdin (New-PromptStdin -Cwd $resProj -EventName 'UserPromptSubmit' -Prompt 'add a retry option to the export command' -SessionId 'res-1')
    Check 'research: a second, different request in the same session is NOT suppressed' ($r.Out -match 'RESEARCH:') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $resProj -RawStdin (New-PromptStdin -Cwd $resProj -EventName 'UserPromptSubmit' -Prompt 'add a retry option to the export command' -SessionId 'res-1')
    Check 'research: the same request repeated is said once' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $resProj -RawStdin (New-PromptStdin -Cwd $resProj -EventName 'UserPromptSubmit' -Prompt 'what time is it?' -SessionId 'res-2')
    Check 'research: chat that is neither work nor a technical question stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $resProj
    Check 'research: SessionStart requires full research and MCP owners before work' (
        $r.Out -match 'BEFORE selection: global-mcp-rules.md/global-mcp-server-contracts.md FULL' -and $r.Out -match 'research owner FULL, live docs/GitHub -> .ai/RESEARCH/' -and $r.Out -notmatch 'whose behavior may have changed') $r.Out

    $operationProject = New-Proj 'McpOperations'
    # Each conditional process contract is now behind its exact FULL-before-use
    # owner pointer. This proves routing/authority, not the private owner's content.
    $requests = @(
        @('Use ScraplingServer to scrape permitted static content','SCRAPLING:','BEFORE use global-research-workflows.md Scrapling FULL','skill/schema'),
        @('Use REA to inspect an artifact','REA:','BEFORE use global-rea-summary.md -> global-rea-rules.md FULL','Missing controls BLOCK; reconcile timeout'),
        @('Use telegram-operator for a backup','TELEGRAM:','BEFORE use global-connected-skill-contracts.md Telegram Operator FULL/job/schema','No deletion'),
        @('Use context-mode to inspect output','CONTEXT-MODE:','BEFORE use global-mcp-server-contracts.md FULL/schema','Not a sandbox'),
        @('Use Omniroute-ccr tool search','OMNIROUTE:','global-mcp-server-contracts.md FULL','unverified, not broken')
    )
    $operationIndex = 0
    foreach ($case in $requests) {
        $operationIndex++
        $operationSession = 'operation-' + $operationIndex
        $r = Fire -HookPath $McpHook -Cwd $operationProject -RawStdin (New-PromptStdin $operationProject 'UserPromptSubmit' $case[0] $operationSession)
        $parsed = $null; try { $parsed = $r.Out | ConvertFrom-Json } catch { }
        Check ('pertinent operation route ' + $case[1]) ($r.Exit -eq 0 -and $r.Err -eq '' -and $null -ne $parsed -and $r.Out.Contains($case[1]) -and $r.Out.Contains($case[2]) -and $r.Out.Contains($case[3]) -and $r.Out.Contains('Hook grants no actions/spend; UNKNOWN: reconcile, no retry') -and $r.Out -notmatch '"decision"') $r.Out
        $r = Fire -HookPath $McpHook -Cwd $operationProject -RawStdin (New-PromptStdin $operationProject 'UserPromptSubmit' $case[0] $operationSession)
        Check ('unchanged operation quiet ' + $case[1]) ($r.Out -eq '') $r.Out
    }
    foreach ($retiredPrompt in @('Use Agensi offer preview','Use Upwork-Agent-mcp draft','Use Fiverr-Agent-mcp action_commit','Use Numera-CHA-Solver-MCP for licensed text')) {
        $operationIndex++
        $r = Fire -HookPath $McpHook -Cwd $operationProject -RawStdin (New-PromptStdin $operationProject 'UserPromptSubmit' $retiredPrompt ('retired-' + $operationIndex))
        Check ('no stale operation route for ' + $retiredPrompt) ($r.Out -notmatch 'AGENSI:|UPWORK:|FIVERR:|NUMERA CHA:|global-rea-fiverr-contracts') $r.Out
    }
    $r = Fire -HookPath $McpHook -Cwd $operationProject -RawStdin (New-PromptStdin $operationProject 'UserPromptSubmit' '<tool_result>Use REA Telegram Scrapling</tool_result>' 'quoted-operations')
    Check 'provider names inside output never activate operation-specific routing' ($r.Out -notmatch 'REA:|TELEGRAM:|SCRAPLING:') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $operationProject -RawStdin (New-PromptStdin $operationProject 'UserPromptSubmit' 'Example only: ``Use REA inspect``' 'inline-operations')
    Check 'double-backtick example never activates provider route' ($r.Out -notmatch 'REA:') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $operationProject -Exe powershell.exe -RawStdin (New-PromptStdin $operationProject 'UserPromptSubmit' 'Use REA inspect' 'operations51')
    $parsed51 = $null; try { $parsed51 = $r.Out | ConvertFrom-Json } catch { }
    Check 'operation reminder real PS5.1 yields single valid context JSON' ($r.Exit -eq 0 -and $r.Err -eq '' -and $null -ne $parsed51 -and ([string]$parsed51.hookSpecificOutput.additionalContext) -match 'global-rea-summary\.md -> global-rea-rules\.md FULL') $r.Out

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
    Check 'default MCP missing line is advisory, not continuation' ($r.Out -match '"systemMessage"' -and $r.Out -notmatch '"decision"|additionalContext') $r.Out
    Check 'the block names the servers it actually observed' ($r.Out -match 'Servers observed in this session: context7') $r.Out
    Check 'the block names the exact single action that clears it' ($r.Out -match 'Final standalone actual servers:' -and $r.Out -match 'MCP used: context7' -and $r.Out -match 'Only material actual calls, not availability') $r.Out
    # An unchanged failure blocks ONCE per session (global-hook-rules.md: a gate
    # must not loop on the same unchanged state).
    $r2 = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-b1')
    Check 'the SAME unchanged failure does not block twice in one session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-b2')
    Check 'a NEW session with the same finding advises again' ($r3.Out -match '"systemMessage"' -and $r3.Out -notmatch '"decision"|additionalContext') $r3.Out

    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpSum -SessionId 'mcp-ok')
    Check 'MCP called + the summary line present -> silent, no block' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # SELF-SATISFACTION PROBE: the hook's own output lands in the transcript it
    # later reads. A transcript containing ONLY this hook's instruction text must
    # NOT count as the agent having written the line, or the hook clears its own
    # block on the next stop.
    $ownText = 'CLOSING REQUIREMENT - end the final task summary with its own line starting "MCP used:" naming every connected MCP server actually called this task. TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "MCP used:" and naming the servers actually used - e.g. "MCP used: context7".'
    $tSelf = New-ToolTranscript 'mcp-self' 'mcp__context7__query-docs' $ownText
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tSelf -SessionId 'mcp-self1')
    Check 'the hook''s OWN instruction text never satisfies the declaration' ($r.Out -match '"systemMessage"' -and $r.Out -notmatch '"decision"|additionalContext') $r.Out

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
    # A relevant prompt with NO connector trigger (order 105 triggers gate instead).
    $r = Fire -HookPath $McpHook -Cwd $mcpUnk -RawStdin (New-PromptStdin -Cwd $mcpUnk -EventName 'UserPromptSubmit' -Prompt 'check the database schema' -SessionId 'mcp-u1')
    Check 'a relevant prompt records the session as MCP-relevant (reminder emitted)' ($r.Out -match 'Mcp-Usage-Check: advisory') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpUnk -RawStdin (New-StopStdin -Cwd $mcpUnk -Transcript (Join-Path $Work 'no-such-transcript.jsonl') -SessionId 'mcp-u1')
    Check 'a missing transcript stays silent without claiming an all-clear' (
        $r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpUnk -RawStdin (New-StopStdin -Cwd $mcpUnk -Transcript $tNoMcp -SessionId 'mcp-u1')
    Check 'a relevant session that called no MCP tool gets an advisory, not a block' (
        $r.Out -match 'no connected tool called' -and $r.Out -notmatch '"decision"') $r.Out

    # Order 105 (steering V94): connector triggers, Stop gate, pairing notes, carry-over.
    $mcpTrig = New-Proj 'McpTrigger'
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-PromptStdin -Cwd $mcpTrig -EventName 'UserPromptSubmit' -Prompt 'scrape https://example.com and summarise it' -SessionId 'mcp-t1')
    Check '105 1a: a URL prompt names Scrapling + scrapling-official in one CONNECTORS line' (
        $r.Out -match 'CONNECTORS first: URL/web page -> Scrapling-Server \+ skill anthropic-skills:scrapling-official') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-PromptStdin -Cwd $mcpTrig -EventName 'UserPromptSubmit' -Prompt 'what happens in clip.mp4 at the end' -SessionId 'mcp-t2')
    Check '105 4c: a video prompt names rea-video skill then rea-video decompose' ($r.Out -match 'rea-video:rea-video skill, then rea-video decompose') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-PromptStdin -Cwd $mcpTrig -EventName 'UserPromptSubmit' -Prompt 'fix a typo in the readme' -SessionId 'mcp-t3')
    Check '105 1a: a text-only prompt names no connector' ($r.Out -notmatch 'CONNECTORS first') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-StopStdin -Cwd $mcpTrig -Transcript $tNoMcp -SessionId 'mcp-t1')
    Check '105 1b: trigger matched, no MCP call, no line -> blocks once (required-workflow)' (
        $r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'Connector trigger matched \(web\)') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-StopStdin -Cwd $mcpTrig -Transcript $tNoMcp -SessionId 'mcp-t1')
    Check '105 1b: the same finding does not block twice' ($r.Out -notmatch '"decision"') $r.Out
    $tNoneReason = New-ToolTranscript 'mcp-none-reason' 'Read' "Done.`nMCP used: none - the page is a local fixture"
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-PromptStdin -Cwd $mcpTrig -EventName 'UserPromptSubmit' -Prompt 'scrape https://example.org' -SessionId 'mcp-t4')
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-StopStdin -Cwd $mcpTrig -Transcript $tNoneReason -SessionId 'mcp-t4')
    Check '105 1b: "MCP used: none - <reason>" passes the trigger gate' ($r.Out -notmatch '"decision"') $r.Out
    $tPair = Join-Path $Work 'mcp-pair.jsonl'
    Write-Utf8 $tPair ((@(
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = 'mcp__Scrapling-Server__get'; input = @{ a = 1 } }) } } | ConvertTo-Json -Compress -Depth 8),
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = 'mcp__plugin_playwright_playwright__browser_navigate'; input = @{ a = 1 } }) } } | ConvertTo-Json -Compress -Depth 8),
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "Done.`nMCP used: Scrapling-Server, playwright" }) } } | ConvertTo-Json -Compress -Depth 8)
    ) -join "`n") + "`n")
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-StopStdin -Cwd $mcpTrig -Transcript $tPair -SessionId 'mcp-t5')
    Check '105 1c: Scrapling call without scrapling-official -> one advisory' ($r.Out -match 'SCRAPLING:' -and $r.Out -notmatch '"decision"') $r.Out
    Check '105 1d: Playwright with no chrome-devtools call -> one advisory' ($r.Out -match 'PLAYWRIGHT:') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-PromptStdin -Cwd $mcpTrig -EventName 'UserPromptSubmit' -Prompt 'thanks' -SessionId 'mcp-t5')
    Check '105 item 2: the Stop advisory reaches the model on the next prompt as context' (
        $r.Out -match 'additionalContext' -and $r.Out -match 'STOP NOTICES from the previous turn' -and $r.Out -match 'SCRAPLING:') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpTrig -RawStdin (New-PromptStdin -Cwd $mcpTrig -EventName 'UserPromptSubmit' -Prompt 'thanks again' -SessionId 'mcp-t5')
    Check '105 item 2: the carry-over queue is delivered exactly once' ($r.Out -notmatch 'STOP NOTICES') $r.Out

    # Desktop control order (spec 041): computer-use with no earlier agent-desktop
    # attempt is named once; agent-desktop first, or no computer-use, is silent.
    $tCu = New-ToolTranscript 'mcp-cu' 'mcp__computer-use__screenshot' "Done.`nMCP used: computer-use"
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tCu -SessionId 'mcp-cu1')
    Check 'desktop route: computer-use without agent-desktop is named, advisory only' ($r.Out -match 'DESKTOP ROUTE' -and $r.Out -match 'agent-desktop MCP \+ skill FIRST' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tCu -SessionId 'mcp-cu1')
    Check 'desktop route: said once per session' ($r.Out -notmatch 'DESKTOP ROUTE') $r.Out
    $tAdFirst = Join-Path $Work 'mcp-adfirst.jsonl'
    $adLines = @('mcp__agent-desktop__snapshot', 'mcp__computer-use__screenshot' | ForEach-Object { @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = $_; input = @{ a = 1 } }) } } | ConvertTo-Json -Compress -Depth 8 })
    $adLines += (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "Done.`nMCP used: agent-desktop, computer-use" }) } } | ConvertTo-Json -Compress -Depth 8)
    Write-Utf8 $tAdFirst (($adLines -join "`n") + "`n")
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tAdFirst -SessionId 'mcp-cu2')
    Check 'desktop route: an agent-desktop attempt before computer-use -> silent' ($r.Out -notmatch 'DESKTOP ROUTE') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpSum -SessionId 'mcp-cu3')
    Check 'desktop route: no computer-use call -> no desktop note' ($r.Out -notmatch 'DESKTOP ROUTE') $r.Out

    # Order 107 (steering V95): rust-anything trigger, Stop gate, CLI fallback,
    # mid-turn PreToolUse pairing advisory, and cross-session SessionStart carryover.
    $mcpV95 = New-Proj 'McpV95Rust'
    $faPortToRust = (-join [char[]]@(0x067E,0x0648,0x0631,0x062A)) + ' ' + (-join [char[]]@(0x0628,0x0647)) + ' ' + (-join [char[]]@(0x0631,0x0627,0x0633,0x062A))
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-PromptStdin -Cwd $mcpV95 -EventName 'UserPromptSubmit' -Prompt 'port src/parser.py to Rust' -SessionId 'ra-1')
    Check 'V95 1a: English Rust-port prompt names rust-anything MCP + skill' (
        $r.Out -match 'CONNECTORS first: Rust port/rewrite -> rust-anything MCP \+ skill rust-anything:rust-anything') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-PromptStdin -Cwd $mcpV95 -EventName 'UserPromptSubmit' -Prompt $faPortToRust -SessionId 'ra-fa')
    Check 'V95 1a: Persian Rust-port prompt names rust-anything MCP + skill' (
        $r.Out -match 'CONNECTORS first: Rust port/rewrite -> rust-anything MCP \+ skill rust-anything:rust-anything') $r.Out
    $tRaHandPort = New-ToolTranscript 'mcp-ra-hand' 'mcp__Context7__query-docs' "Done.`nMCP used: Context7"
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-StopStdin -Cwd $mcpV95 -Transcript $tRaHandPort -SessionId 'ra-1')
    Check 'V95 1a: Rust-port prompt without rust-anything MCP/CLI or opt-out blocks once even if another MCP ran' (
        $r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'Connector trigger matched \(rust-anything\)') $r.Out
    $tRaMcpNoSkill = New-ToolTranscript 'mcp-ra-noskill' 'mcp__plugin_rust-anything_rust-anything__analyze' "Done.`nMCP used: rust-anything"
    $preRaStdin = @{ session_id = 'ra-mid'; cwd = $mcpV95; hook_event_name = 'PreToolUse'; tool_name = 'mcp__plugin_rust-anything_rust-anything__analyze'; tool_input = @{ path = 'src/parser.py' }; transcript_path = $tNoMcp } | ConvertTo-Json -Compress -Depth 6
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin $preRaStdin
    Check 'V95 mid-turn PreToolUse: rust-anything call before skill emits additionalContext immediately' (
        $r.Out -match 'additionalContext' -and $r.Out -match 'RUST-ANYTHING: called before skill rust-anything:rust-anything') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-StopStdin -Cwd $mcpV95 -Transcript $tRaMcpNoSkill -SessionId 'ra-mid')
    Check 'V95 mid-turn PreToolUse suppresses duplicate Stop pairing notice in same session' ($r.Out -notmatch 'RUST-ANYTHING:') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-StopStdin -Cwd $mcpV95 -Transcript $tRaMcpNoSkill -SessionId 'ra-stoppair')
    Check 'V95 1a: rust-anything MCP satisfies trigger gate and emits pairing advisory once if PreToolUse did not run' (
        $r.Out -match 'RUST-ANYTHING:' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-PromptStdin $mcpV95 'SessionStart' '' 'ra-fresh-session-after-end')
    Check 'V95 carryover survives session end and delivers on next SessionStart' (
        $r.Out -match 'STOP NOTICES from the previous turn' -and $r.Out -match 'RUST-ANYTHING:') $r.Out
    $tRaCli = Join-Path $Work 'mcp-ra-cli.jsonl'
    Write-Utf8 $tRaCli ((@(
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = 'Bash'; input = @{ command = '"G:\Program Files\Rust\cargo\bin\rust-anything.exe" analyze src/parser.py' } }) } } | ConvertTo-Json -Compress -Depth 8),
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = 'Done.' }) } } | ConvertTo-Json -Compress -Depth 8)
    ) -join "`n") + "`n")
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-PromptStdin -Cwd $mcpV95 -EventName 'UserPromptSubmit' -Prompt 'rewrite src/parser.py in Rust' -SessionId 'ra-cli')
    $r = Fire -HookPath $McpHook -Cwd $mcpV95 -RawStdin (New-StopStdin -Cwd $mcpV95 -Transcript $tRaCli -SessionId 'ra-cli')
    Check 'V95 1a: verified rust-anything CLI invocation satisfies the Rust-port trigger gate' ($r.Out -notmatch '"decision"') $r.Out

    # ---- V96-V98: cloudflare trigger + pairing + Standing Order 8 disabled connectors ----
    $mcpV98 = New-Proj 'McpV98'
    $r = Fire -HookPath $McpHook -Cwd $mcpV98 -RawStdin (New-PromptStdin -Cwd $mcpV98 -EventName 'UserPromptSubmit' -Prompt 'Deploy a Cloudflare Workers Turnstile route with Wrangler and D1 database' -SessionId 'cf-tr1')
    Check 'V96 cloudflare trigger routes Cloudflare Workers/Turnstile prompt' (
        $r.Exit -eq 0 -and $r.Out -match 'Cloudflare platform/Workers -> cloudflare MCP \+ matching cloudflare:\* skill \(cloudflare:turnstile-spin for Turnstile\)') $r.Out
    $tCfNoSkill = Join-Path $Work 'mcp-cf-noskill.jsonl'
    Write-Utf8 $tCfNoSkill ((@(
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; name = 'mcp__plugin_cloudflare_cloudflare__workers_list'; input = @{} }) } } | ConvertTo-Json -Compress -Depth 8),
        (@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "Done.`nMCP used: cloudflare" }) } } | ConvertTo-Json -Compress -Depth 8)
    ) -join "`n") + "`n")
    $cfPreStdin = @{ session_id = 'cf-pre1'; cwd = $mcpV98; hook_event_name = 'PreToolUse'; tool_name = 'mcp__plugin_cloudflare_cloudflare__workers_list'; tool_input = @{}; transcript_path = (Join-Path $Work 'absent-cf.jsonl') } | ConvertTo-Json -Compress
    $r = Fire -HookPath $McpHook -Cwd $mcpV98 -RawStdin $cfPreStdin
    Check 'V96 cloudflare PreToolUse emits non-blocking pairing advisory without cloudflare:* skill' (
        $r.Exit -eq 0 -and $r.Out -match 'CLOUDFLARE:' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpV98 -RawStdin (New-StopStdin -Cwd $mcpV98 -Transcript $tCfNoSkill -SessionId 'cf-stoppair')
    Check 'V96 cloudflare Stop emits non-blocking pairing advisory when PreToolUse did not run' (
        $r.Exit -eq 0 -and $r.Out -match 'CLOUDFLARE:' -and $r.Out -notmatch '"decision"') $r.Out

    $mcpDisabledProj = New-Proj 'McpDisabledSO8'
    New-Item -ItemType Directory -Path (Join-Path $mcpDisabledProj '.claude') -Force | Out-Null
    Write-Utf8 (Join-Path $mcpDisabledProj '.claude\settings.local.json') '{"enabledPlugins":{"cloudflare@cloudflare":false,"rust-anything@rust-anything":false},"deniedMcpServers":[{"serverName":"Snyk"}],"permissions":{"deny":["mcp__Semgrep__*"]}}'
    $r = Fire -HookPath $McpHook -Cwd $mcpDisabledProj -RawStdin (New-PromptStdin -Cwd $mcpDisabledProj -EventName 'UserPromptSubmit' -Prompt 'Configure Cloudflare Workers with Wrangler' -SessionId 'so8-cf')
    Check 'Standing Order 8 suppresses cloudflare trigger when plugin is disabled locally' ($r.Out -notmatch 'Cloudflare platform/Workers') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpDisabledProj -RawStdin (New-PromptStdin -Cwd $mcpDisabledProj -EventName 'UserPromptSubmit' -Prompt 'Run Snyk on package dependencies' -SessionId 'so8-snyk')
    Check 'Standing Order 8 emits non-blocking re-enable advisory when prompt names disabled connector' (
        $r.Exit -eq 0 -and $r.Out -match 'Standing Order 8' -and $r.Out -match 'Snyk' -and $r.Out -notmatch 'dependency/package change -> Snyk') $r.Out
    $tSo8Empty = Join-Path $Work 'mcp-so8-empty.jsonl'
    Write-Utf8 $tSo8Empty ((@{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = 'Done.' }) } } | ConvertTo-Json -Compress -Depth 8) + "`n")
    $r = Fire -HookPath $McpHook -Cwd $mcpDisabledProj -RawStdin (New-StopStdin -Cwd $mcpDisabledProj -Transcript $tSo8Empty -SessionId 'so8-snyk')
    Check 'Standing Order 8 suppresses Stop block for locally disabled connector' ($r.Out -notmatch '"decision"\s*:\s*"block"') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: MCP_SUMMARY_ENFORCEMENT downgrades and disables the gate ---' -ForegroundColor Cyan
    function New-ConfiguredMcpHookCopy {
        param([string]$Enforcement)
        $dir = Join-Path $Work ('mcpcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item (Join-Path (Split-Path -Parent $McpHook) '*.ps1') $dir
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
    Check 'off mode still runs the pre-task half' ($r.Out -match 'Mcp-Usage-Check: advisory') $r.Out
    $badHook = New-ConfiguredMcpHookCopy 'nonsense-value'
    $mcpBad = New-Proj 'McpBadConfig'
    $r = Fire -HookPath $badHook -Cwd $mcpBad -RawStdin (New-StopStdin -Cwd $mcpBad -Transcript $tMcpNoSum -SessionId 'mcp-x1')
    Check 'an invalid enforcement value falls back to advisory' ($r.Out -match '"systemMessage"' -and $r.Out -notmatch '"decision"|additionalContext') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain -Exe 'powershell.exe' -RawStdin (New-PromptStdin $plain 'SessionStart' '' 'mcp-host51-fresh')
    Check '5.1 host: emits cleanly, no crash' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*Mcp-Usage-Check: advisory*') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $mcpStop -Exe 'powershell.exe' -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-51')
    Check '5.1 host: default Stop is advisory without continuation' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -match '"systemMessage"' -and $r.Out -notmatch '"decision"|additionalContext')
    $blockHook = New-ConfiguredMcpHookCopy 'block'
    $r = Fire -HookPath $blockHook -Cwd $mcpStop -RawStdin (New-StopStdin -Cwd $mcpStop -Transcript $tMcpNoSum -SessionId 'mcp-explicit-block')
    Check 'explicit MCP block configuration remains effective' ($r.Exit -eq 0 -and $r.Out -match '"decision"\s*:\s*"block"') $r.Out
