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

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: input handling ---' -ForegroundColor Cyan
    $plain = New-Proj 'Plain'
    $r = Fire -HookPath $McpHook -Cwd $plain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -RawStdin 'garbage'
    Check 'garbage stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -EventName 'Stop'
    Check 'Stop event -> silent (no longer a registered event)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -EventName 'SubagentStop'
    Check 'SubagentStop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: always reminds on SessionStart (cheap, no gate) ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'emits a valid hookSpecificOutput on SessionStart' ($null -ne $parsed -and [string]$parsed.hookSpecificOutput.hookEventName -eq 'SessionStart')
    Check 'mentions MCP USAGE CHECK' ($r.Out -like '*MCP USAGE CHECK*') $r.Out
    Check 'note stays short (under ~600 chars, matching the "3-4 lines" design)' ($null -ne $parsed -and ([string]$parsed.hookSpecificOutput.additionalContext).Length -lt 600)
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
    Write-Host '--- Mcp-Usage-Check: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain -Exe 'powershell.exe'
    Check '5.1 host: emits cleanly, no crash' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*MCP USAGE CHECK*') $r.Out

    # =====================================================================
    # Force Claude routing for the .claude-based Skills-Check cases below; the
    # dedicated routing tests flip CLAUDE_PROJECT_DIR explicitly.
    Set-ClaudeProjectDir $Work
    Write-Host '--- Skills-Check: input handling + silent with nothing to point at ---' -ForegroundColor Cyan
    $splain = New-Proj 'SkillsPlain'
    $r = Fire -HookPath $SkillsHook -Cwd $splain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $SkillsHook -Cwd $splain -EventName 'SubagentStop'
    Check 'SubagentStop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # No copied skills, no .ai/SKILLS.md, and the DEFAULT library path does not
    # exist on a throwaway machine path - override SKILLS_DIR to something
    # guaranteed absent so this run is deterministic regardless of the real host.
    $noSourceHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $noSourceHook -Cwd $splain
    Check 'no skill source anywhere -> silent on SessionStart, zero tokens' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $noSourceHook -Cwd $splain -EventName 'Stop'
    Check 'no skill source anywhere -> silent on Stop too' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: reports copied project skills (SessionStart discovery) ---' -ForegroundColor Cyan
    $proj1 = New-Proj 'WithCopiedSkills'
    New-Item -ItemType Directory -Path (Join-Path $proj1 '.claude\skills\my-skill') -Force | Out-Null
    $hook1 = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $hook1 -Cwd $proj1
    Check 'lists the copied skill folder name' ($r.Out -like '*SKILL POLICY CHECK*' -and $r.Out -like '*my-skill*') $r.Out
    Check 'SessionStart points to the Stop reminder rather than repeating the full policy text' ($r.Out -match 'see the Stop reminder') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: Stop requires the "Skills used:" summary line ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hook1 -Cwd $proj1 -EventName 'Stop'
    Check 'Stop requires a final "Skills used:" summary line for skills actually used' ($r.Out -match 'Skills used:') $r.Out
    Check 'the policy explicitly excludes merely-installed/available/considered/copied-but-unused skills' (
        $r.Out -match 'never a skill that was merely installed, available, discovered, copied, considered, or read but not used') $r.Out
    Check 'the policy requires omitting the line entirely when no skill was used' ($r.Out -match 'Omit the line entirely if no skill was actually used') $r.Out
    Check 'the policy forbids listing the whole library' ($r.Out -match 'never the whole library') $r.Out
    Check 'the policy does not force a skill for trivial tasks merely to produce the line' ($r.Out -match 'do not force a skill for trivial tasks') $r.Out
    $stopHookActiveStdin = @{ session_id = 't'; cwd = $proj1; hook_event_name = 'Stop'; stop_hook_active = $true } | ConvertTo-Json
    $r = Fire -HookPath $hook1 -Cwd $proj1 -EventName 'Stop' -RawStdin $stopHookActiveStdin
    Check 'stop_hook_active short-circuits the Stop reminder' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: UserPromptSubmit task-relevance nudge, once per session ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hook1 -Cwd $proj1 -RawStdin (New-PromptStdin -Cwd $proj1 -EventName 'UserPromptSubmit' -Prompt 'anything' -SessionId 'skills-s1')
    Check 'UserPromptSubmit emits a short task-relevance nudge' ($r.Out -match 'SKILL POLICY CHECK' -and $r.Out -match 'THIS task') $r.Out
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
        $r.Out -notmatch 'capability routing' -and $r.Out -match 'THIS task') $r.Out
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
        $r.Out -match 'NOT VISIBLE in the enumerated project/global skill sources: verification-before-completion\.' -and
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

