# Offline smoke test for a few simple pre-task/lightweight context hooks:
# - Mcp-Usage-Check: always emits a short MCP-usage reminder on SessionStart
#   (no deterministic gate - it is meant to be cheap and constant, matching
#   the shipped hook's own design).
# - Skills-Check: silent unless a skill source exists (copied project
#   skills, .ai/SKILLS.md record, or the configured/default skill library).
# - Large-File-Check: wording-only assertions (anti-fragmentation policy,
#   threshold-as-signal-not-rule, advisory Stop reason) - a few assertions
#   here rather than a whole new suite for wording-only behavior.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-ContextHooks.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$McpHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Mcp-Usage-Check\Mcp-Usage-Check.ps1'
$SkillsHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Skills-Check\Skills-Check.ps1'
$LargeFileHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Large-File-Check\Large-File-Check.ps1'
foreach ($required in @($McpHook, $SkillsHook, $LargeFileHook)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-ctxtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Fire {
    # $RawStdin intentionally UNTYPED: [string] coerces $null to '' (see LESSON.md).
    param([string]$HookPath, [string]$Cwd, [string]$EventName = 'SessionStart', $RawStdin = $null, [string]$Exe = 'pwsh')
    $payload = $RawStdin
    if ($null -eq $payload) {
        $payload = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName } | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') {
        $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    if ($err -ne '' -and $env:HOOKMAKER_TEST_DEBUG -eq '1') {
        Write-Host ('  [stderr] ' + $err.Split("`n")[0]) -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# Copies Skills-Check + a custom .env into an isolated folder, so SKILLS_DIR /
# GLOBAL_SKILLS_DIR overrides never touch the real machine-wide skill library or
# the real per-user global skills directory. The global skills dir is defaulted
# to a guaranteed-absent path unless the caller overrides it, keeping every case
# hermetic regardless of the host.
function New-ConfiguredSkillsHookCopy {
    param([hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $SkillsHook (Join-Path $dir 'Skills-Check.ps1')
    Copy-Item (Join-Path (Split-Path -Parent $SkillsHook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    $merged = @{}
    foreach ($k in $EnvOverrides.Keys) { $merged[$k] = $EnvOverrides[$k] }
    if (-not $merged.ContainsKey('GLOBAL_SKILLS_DIR')) {
        $merged['GLOBAL_SKILLS_DIR'] = (Join-Path $Work 'no-such-global-skills')
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $merged.Keys) { [void]$lines.Add($key + '=' + $merged[$key]) }
    Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    return (Join-Path $dir 'Skills-Check.ps1')
}

# Skills-Check routes by CLAUDE_PROJECT_DIR (present -> Claude, absent -> Codex).
# Tests drive the route by setting/clearing it before a Fire; the child inherits
# the parent env at spawn time.
function Set-ClaudeProjectDir {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    }
    else {
        $env:CLAUDE_PROJECT_DIR = $Value
    }
}

function New-PromptStdin {
    param([string]$Cwd, [string]$EventName, [string]$Prompt, [string]$SessionId = 't')
    return @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName; prompt = $Prompt } | ConvertTo-Json
}

# Preserve the ambient client signal so the Skills-Check routing tests can flip
# it freely and restore it in the finally block.
$OrigClaudeProjectDir = $env:CLAUDE_PROJECT_DIR

try {
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

    # Restore the ambient client signal for the remaining (client-agnostic) tests.
    Set-ClaudeProjectDir $OrigClaudeProjectDir

    # =====================================================================
    Write-Host '--- Large-File-Check: pre-task anti-fragmentation wording ---' -ForegroundColor Cyan
    $lfProj = New-Proj 'LargeFilePlain'
    $r = Fire -HookPath $LargeFileHook -Cwd $lfProj
    Check 'pre-task note mentions the threshold is a review signal, not a rule' ($r.Out -match 'REVIEW SIGNAL, not an architectural law') $r.Out
    Check 'pre-task note explicitly forbids wrappers/forwarding/arbitrary fragmentation' (
        $r.Out -match 'wrappers, forwarding files, arbitrary fragments, or one-function files') $r.Out
    Check 'pre-task note allows appending when the code shares the same responsibility' ($r.Out -match 'appending is correct when the new code genuinely belongs') $r.Out

    # =====================================================================
    Write-Host '--- Large-File-Check: Stop report is a client-aware, non-blocking advisory (never decision:block) ---' -ForegroundColor Cyan
    # The AI owns the split decision, so the Stop report is an advisory, never a
    # decision:block (on Codex a Stop block coerces a new prompt). Cooldown state is
    # redirected under $Work so this section leaves NO residue in the real
    # LOCALAPPDATA, and each client shape uses its OWN project so the per-project
    # cooldown never suppresses the second fire.
    $lfOrigLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = (Join-Path $Work 'lf-fakelocal')
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    try {
        $lfHookLowThreshold = Join-Path $Work ('lfhookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $lfHookLowThreshold -Force | Out-Null
        Copy-Item $LargeFileHook (Join-Path $lfHookLowThreshold 'Large-File-Check.ps1')
        Copy-Item (Join-Path (Split-Path -Parent $LargeFileHook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
        Write-Utf8 (Join-Path $lfHookLowThreshold '.env') "LINE_THRESHOLD=50`r`n"
        $lfHook = Join-Path $lfHookLowThreshold 'Large-File-Check.ps1'
        # 60 lines against a threshold of 50 (the smallest LINE_THRESHOLD the hook
        # honours - values below its documented 50..100000 floor fall back to 800).
        $bigContent = (1..60 | ForEach-Object { 'line ' + $_ }) -join "`n"

        # --- Claude route: hookSpecificOutput.additionalContext, never a block ---
        Set-ClaudeProjectDir $Work
        $lfClaudeProj = New-Proj 'LargeFileOversizedClaude'
        Write-Utf8 (Join-Path $lfClaudeProj 'big.ps1') $bigContent
        $r = Fire -HookPath $lfHook -Cwd $lfClaudeProj -EventName 'Stop'
        $lfClaudeDoc = $null
        try { $lfClaudeDoc = $r.Out | ConvertFrom-Json } catch { $lfClaudeDoc = $null }
        $lfClaudeMsg = if ($null -ne $lfClaudeDoc -and $null -ne $lfClaudeDoc.PSObject.Properties['hookSpecificOutput']) { [string]$lfClaudeDoc.hookSpecificOutput.additionalContext } else { '' }
        Check 'Stop on CLAUDE emits hookSpecificOutput.additionalContext (event Stop), never decision:block' (
            $null -ne $lfClaudeDoc -and $null -ne $lfClaudeDoc.PSObject.Properties['hookSpecificOutput'] -and
            [string]$lfClaudeDoc.hookSpecificOutput.hookEventName -eq 'Stop' -and $r.Out -notmatch '"decision"') $r.Out
        Check 'an oversized file is still detected and reported' ($lfClaudeMsg -match 'LARGE FILE CHECK' -and $lfClaudeMsg -match 'big\.ps1') $lfClaudeMsg
        Check 'the reason says no split is mandatory' ($lfClaudeMsg -match 'No split is mandatory - this is advisory') $lfClaudeMsg
        Check 'the reason repeats the review-signal-not-a-rule framing' ($lfClaudeMsg -match 'a REVIEW SIGNAL, not proof of bad architecture') $lfClaudeMsg
        Check 'the reason forbids thin wrappers/pass-through/arbitrary fragments here too' ($lfClaudeMsg -match 'never create thin wrappers, pass-through modules, or arbitrary fragments') $lfClaudeMsg
        Check 'the reason forbids starting an unrelated refactor merely because a file is large' ($lfClaudeMsg -match 'never start a refactor unrelated to the current task') $lfClaudeMsg
        Check 'a safe/no-split outcome remains explicitly valid' ($lfClaudeMsg -match 'finish with no split') $lfClaudeMsg

        # --- Codex route: systemMessage, never a block (a block would loop Codex) ---
        Set-ClaudeProjectDir ''
        $lfCodexProj = New-Proj 'LargeFileOversizedCodex'
        Write-Utf8 (Join-Path $lfCodexProj 'big.ps1') $bigContent
        $rx = Fire -HookPath $lfHook -Cwd $lfCodexProj -EventName 'Stop'
        $lfCodexDoc = $null
        try { $lfCodexDoc = $rx.Out | ConvertFrom-Json } catch { $lfCodexDoc = $null }
        $lfCodexMsg = if ($null -ne $lfCodexDoc -and $null -ne $lfCodexDoc.PSObject.Properties['systemMessage']) { [string]$lfCodexDoc.systemMessage } else { '' }
        Check 'Stop on CODEX emits systemMessage (not hookSpecificOutput, not decision:block)' (
            $null -ne $lfCodexDoc -and $null -ne $lfCodexDoc.PSObject.Properties['systemMessage'] -and
            $null -eq $lfCodexDoc.PSObject.Properties['hookSpecificOutput'] -and $rx.Out -notmatch '"decision"') $rx.Out
        Check 'the CODEX advisory still carries the oversized-file report' ($lfCodexMsg -match 'LARGE FILE CHECK' -and $lfCodexMsg -match 'big\.ps1') $lfCodexMsg
    }
    finally {
        Set-ClaudeProjectDir $OrigClaudeProjectDir
        $env:LOCALAPPDATA = $lfOrigLocalAppData
    }
}
finally {
    Set-ClaudeProjectDir $OrigClaudeProjectDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
