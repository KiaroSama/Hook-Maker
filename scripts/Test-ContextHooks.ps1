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
$AiMemoryHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Ai-Memory-Check\Ai-Memory-Check.ps1'
$HookLib = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\_hooklib.ps1'
foreach ($required in @($McpHook, $SkillsHook, $LargeFileHook, $AiMemoryHook, $HookLib)) {
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

# ---- Write-HookResult probe -------------------------------------------------
# Runs the shared output adapter in a REAL child hook process (either host), so
# byte-comparisons below are against genuinely emitted bytes rather than an
# in-process reconstruction. stdout stays byte-pure for the comparison, stderr
# stays free for the Kiro exit-2 channel, and the returned result object is
# handed back through a file named in the stdin payload.
$HookResultProbe = Join-Path $Work 'hookresult-probe.ps1'
$hookResultProbeBody = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$outcome = Write-HookResult -EventName ([string](Get-Field $in 'event')) -Kind ([string](Get-Field $in 'kind')) `
    -Message ([string](Get-Field $in 'message')) -Reason ([string](Get-Field $in 'reason')) -Client ([string](Get-Field $in 'client'))
[System.IO.File]::WriteAllText([string](Get-Field $in 'resultPath'), ($outcome | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
'@
Write-Utf8 $HookResultProbe ($hookResultProbeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

# ---- Write-HookResult construct probe ---------------------------------------
# WHY a SAME-PROCESS comparison exists at all: .NET Core randomises string
# hashing per process, so a plain @{} with two or more keys serialises its keys
# in a DIFFERENT order in different pwsh 7 processes - measured here, both
# {"decision":..,"reason":..} and {"reason":..,"decision":..} come out of the
# identical expression. That instability belongs to the shipped hooks (they all
# build plain @{} literals), not to the adapter, and .NET Framework (5.1) is
# deterministic. So byte-compatibility is proved two ways: cross-process against
# REAL captured hook output on the 5.1 host (deterministic there), and - here -
# inside ONE process on BOTH hosts, where the shipped literal and the adapter
# share a hash seed and any construct divergence ([ordered]@{}, different
# ConvertTo-Json flags, renamed keys, different escaping) shows up immediately.
$HookShapeProbe = Join-Path $Work 'hookshape-probe.ps1'
$hookShapeProbeBody = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$text = [string](Get-Field $in 'message')
$ev = [string](Get-Field $in 'event')

# What Write-HookResult actually writes to stdout, captured inside THIS process.
function Get-AdapterBytes {
    param([string]$Kind, [string]$Client)
    $writer = New-Object System.IO.StringWriter
    $previous = [Console]::Out
    [Console]::SetOut($writer)
    try { $null = Write-HookResult -EventName $ev -Kind $Kind -Message $text -Reason $text -Client $Client }
    finally { [Console]::SetOut($previous) }
    return $writer.ToString().Trim()
}

# The literal expressions the shipped hooks emit today (Mcp-Usage-Check.ps1:35,
# Large-File-Check.ps1:187/190, Ci-Status-Check.ps1:435/467/471, and ~59 more).
$pairs = @(
    @{ label = 'claudeContext'; hook = (@{ hookSpecificOutput = @{ hookEventName = $ev; additionalContext = $text } } | ConvertTo-Json -Depth 5 -Compress); adapter = (Get-AdapterBytes -Kind 'context' -Client 'claude') },
    @{ label = 'claudeAdvisory'; hook = (@{ hookSpecificOutput = @{ hookEventName = $ev; additionalContext = $text } } | ConvertTo-Json -Depth 5 -Compress); adapter = (Get-AdapterBytes -Kind 'advisory' -Client 'claude') },
    @{ label = 'codexSystemMessage'; hook = (@{ systemMessage = $text } | ConvertTo-Json -Depth 5 -Compress); adapter = (Get-AdapterBytes -Kind 'advisory' -Client 'codex') },
    @{ label = 'decisionBlockClaude'; hook = (@{ decision = 'block'; reason = $text } | ConvertTo-Json -Compress); adapter = (Get-AdapterBytes -Kind 'block' -Client 'claude') },
    @{ label = 'decisionBlockCodex'; hook = (@{ decision = 'block'; reason = $text } | ConvertTo-Json -Compress); adapter = (Get-AdapterBytes -Kind 'block' -Client 'codex') }
)
$bad = @()
foreach ($pair in $pairs) {
    if ($pair['hook'] -cne $pair['adapter']) { $bad += ($pair['label'] + ': hook=[' + $pair['hook'] + '] adapter=[' + $pair['adapter'] + ']') }
}
[System.IO.File]::WriteAllText([string](Get-Field $in 'resultPath'), ($bad -join ' || '), (New-Object System.Text.UTF8Encoding $false))
'@
Write-Utf8 $HookShapeProbe ($hookShapeProbeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

# Deliberately nasty payload: newline, double quote, backslash, tab, and the
# characters 5.1 escapes as &/</> but pwsh 7 does not.
$HookShapeSample = "GATE line1`nline2 " + [char]34 + 'quoted' + [char]34 + " & <> \ end`ttab"

# Runs the construct probe on one host; returns '' when every shape matched.
function Test-HookResultConstruct {
    param([string]$Exe = 'pwsh')
    $resultPath = Join-Path $Work ('hshape-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $null = Fire -HookPath $HookShapeProbe -Cwd $Work -Exe $Exe `
        -RawStdin (@{ resultPath = $resultPath; event = 'Stop'; message = $HookShapeSample } | ConvertTo-Json -Compress)
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { return 'the construct probe produced no result file' }
    return ([System.IO.File]::ReadAllText($resultPath)).Trim()
}

# Fires the probe with one Write-HookResult call and returns its raw stdout /
# stderr / exit code plus the parsed result object.
function Invoke-HookResult {
    param([hashtable]$Call, [string]$Exe = 'pwsh')
    $resultPath = Join-Path $Work ('hres-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $payload = @{ resultPath = $resultPath }
    foreach ($key in $Call.Keys) { $payload[$key] = $Call[$key] }
    $fired = Fire -HookPath $HookResultProbe -Cwd $Work -RawStdin ($payload | ConvertTo-Json -Compress) -Exe $Exe
    $outcome = $null
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $outcome = ([System.IO.File]::ReadAllText($resultPath)) | ConvertFrom-Json
    }
    return [pscustomobject]@{ Out = $fired.Out; Err = $fired.Err; Exit = $fired.Exit; Result = $outcome }
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
        # BYTE-COMPATIBILITY (real emission site 2 of 4): Large-File-Check's own
        # Write-Advisory Claude branch, fed the message it actually produced.
        # Run on the 5.1 host: hookSpecificOutput has TWO keys and .NET Core
        # randomises plain-@{} key order per process, so a cross-process byte
        # comparison is only meaningful where hashing is deterministic. A fresh
        # project keeps the hook's per-project cooldown from suppressing the fire.
        $lfClaudeProj51 = New-Proj 'LargeFileOversizedClaude51'
        Write-Utf8 (Join-Path $lfClaudeProj51 'big.ps1') $bigContent
        $lfR51 = Fire -HookPath $lfHook -Cwd $lfClaudeProj51 -EventName 'Stop' -Exe 'powershell.exe'
        $lfClaudeDoc51 = $null
        try { $lfClaudeDoc51 = $lfR51.Out | ConvertFrom-Json } catch { }
        $lfClaudeMsg51 = if ($null -ne $lfClaudeDoc51 -and $null -ne $lfClaudeDoc51.PSObject.Properties['hookSpecificOutput']) { [string]$lfClaudeDoc51.hookSpecificOutput.additionalContext } else { '' }
        $lfClaudeAdapted = Invoke-HookResult -Call @{ kind = 'advisory'; event = 'Stop'; message = $lfClaudeMsg51; client = 'claude' } -Exe 'powershell.exe'
        Check '5.1 host: Write-HookResult reproduces the real CLAUDE Stop advisory byte-for-byte' (
            $lfClaudeMsg51 -ne '' -and $lfClaudeAdapted.Out -ceq $lfR51.Out -and
            $lfClaudeAdapted.Result.Shape -eq 'claudeContext' -and $lfClaudeAdapted.Result.Emitted -eq $true) (
            'hook=[' + $lfR51.Out + '] adapter=[' + $lfClaudeAdapted.Out + ']')

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
        # BYTE-COMPATIBILITY (real emission site 3 of 4): the same hook's Codex
        # branch - the one shape a Codex client actually understands at Stop.
        $lfCodexAdapted = Invoke-HookResult -Call @{ kind = 'advisory'; event = 'Stop'; message = $lfCodexMsg; client = 'codex' }
        Check 'Write-HookResult reproduces the real CODEX Stop systemMessage byte-for-byte' (
            $rx.Out -ne '' -and $lfCodexAdapted.Out -ceq $rx.Out -and
            $lfCodexAdapted.Result.Shape -eq 'codexSystemMessage' -and $lfCodexAdapted.Result.Emitted -eq $true) (
            'hook=[' + $rx.Out + '] adapter=[' + $lfCodexAdapted.Out + ']')
    }
    finally {
        Set-ClaudeProjectDir $OrigClaudeProjectDir
        $env:LOCALAPPDATA = $lfOrigLocalAppData
    }

    # =====================================================================
    Write-Host '--- Ai-Memory-Check: a staged rename in git status --porcelain does not crash Get-LatestWorkTimeUtc (5.1 illegal-path regression) ---' -ForegroundColor Cyan
    # Regression: a rename/copy porcelain line is "R  old -> new"; treating the
    # whole "old -> new" text as one literal relative path embeds the arrow's '>'
    # via Join-Path, and Test-Path -LiteralPath then throws on PS 5.1 ('>' is an
    # illegal path character) - crashing Get-LatestWorkTimeUtc and, with it, every
    # unguarded caller (Ai-Memory-Check, Graph-Update-Check) at Stop.
    $amcOrigLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = (Join-Path $Work 'amc-fakelocal')
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    try {
        $renameProj = New-Proj 'RenameRepo'
        & git -C $renameProj init -q -b main 2>$null | Out-Null
        & git -C $renameProj config user.email 't@t' 2>$null | Out-Null
        & git -C $renameProj config user.name 't' 2>$null | Out-Null
        & git -C $renameProj config core.autocrlf false 2>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $renameProj '.ai') -Force | Out-Null
        Write-Utf8 (Join-Path $renameProj 'a.ps1') "function A { 1 }`n"
        & git -C $renameProj add -A 2>$null | Out-Null
        & git -C $renameProj commit -q -m init 2>$null | Out-Null
        & git -C $renameProj mv a.ps1 b.ps1 2>$null | Out-Null

        $renameHookDir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $renameHookDir -Force | Out-Null
        Copy-Item $AiMemoryHook (Join-Path $renameHookDir 'Ai-Memory-Check.ps1')
        Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force

        $r = Fire -HookPath (Join-Path $renameHookDir 'Ai-Memory-Check.ps1') -Cwd $renameProj -EventName 'Stop' -Exe 'powershell.exe'
        Check '5.1 host: a staged rename never crashes Get-LatestWorkTimeUtc (clean exit, no StrictMode/illegal-path error)' (
            $r.Exit -eq 0 -and $r.Err -eq '') ($r.Out + ' | err=' + $r.Err)
        Check 'the reminder logic still runs (missing .ai/memory.md is still detected and blocks)' (
            $r.Out -match '"decision":"block"' -and $r.Out -match 'memory\.md') $r.Out
        # BYTE-COMPATIBILITY (real emission site 4 of 4): a genuine decision:block,
        # captured on the 5.1 host. 5.1 and pwsh 7 escape and ORDER JSON keys
        # differently, so proving the adapter on both hosts is what makes the
        # "byte-identical" claim meaningful rather than host-specific luck.
        $amcDoc = $null
        try { $amcDoc = $r.Out | ConvertFrom-Json } catch { }
        $amcReason = if ($null -ne $amcDoc -and $null -ne $amcDoc.PSObject.Properties['reason']) { [string]$amcDoc.reason } else { '' }
        $amcAdapted = Invoke-HookResult -Call @{ kind = 'block'; event = 'Stop'; reason = $amcReason; client = 'claude' } -Exe 'powershell.exe'
        Check '5.1 host: Write-HookResult reproduces the real decision:block byte-for-byte' (
            $amcReason -ne '' -and $amcAdapted.Out -ceq $r.Out -and
            $amcAdapted.Result.Shape -eq 'decisionBlock' -and $amcAdapted.Result.Degraded -eq $false) (
            'hook=[' + $r.Out + '] adapter=[' + $amcAdapted.Out + ']')
    }
    finally {
        $env:LOCALAPPDATA = $amcOrigLocalAppData
    }

    # =====================================================================
    Write-Host '--- _hooklib: the UTF-8 stdin/stdout contract survives a non-UTF-8 console code page ---' -ForegroundColor Cyan
    # Regression: every shipped hook read stdin through [Console]::In, which
    # decodes with the CONSOLE code page rather than the UTF-8 the clients
    # actually send. A hook process with no attached console - a GUI-hosted
    # client, or any parent spawning it with CreateNoWindow + redirected pipes,
    # including this repo's own parallel test runner - falls back to the machine's
    # OEM page (measured: ibm437), so a prompt of 'معماری پروژه' arrived as
    # box-drawing characters and every non-ASCII prompt, path, and filename
    # silently missed its match. _hooklib now pins UTF-8 both ways at dot-source
    # time (the fix Cross-Project-.ai-Knowledge-Sync always had).
    #
    # The probe forces CP437 BEFORE dot-sourcing, so the hostile condition is
    # reproduced deterministically on any machine instead of depending on the
    # ambient console - this assertion goes red on a real regression even where
    # the console already happens to be UTF-8. It exercises the shared library
    # itself, so it stays true for all 24 hooks that dot-source it rather than
    # tracking one hook's wording.
    $utf8Probe = Join-Path $Work 'utf8-io-probe.ps1'
    $probeBody = @'
Set-StrictMode -Version 2.0
# Hostile pre-condition: a non-UTF-8 console page, exactly what a console-less
# hook process inherits. _hooklib must override this, not inherit it.
try { [Console]::InputEncoding = [System.Text.Encoding]::GetEncoding(437) } catch { }
. (Join-Path '__LIBDIR__' '_hooklib.ps1')
$in = Read-HookInput
$prompt = ''
if ($null -ne $in) { $prompt = [string](Get-Field $in 'prompt') }
'CODEPOINTS=' + ((($prompt.ToCharArray() | ForEach-Object { [int]$_ }) -join ','))
'@
    Write-Utf8 $utf8Probe ($probeBody.Replace('__LIBDIR__', (Split-Path -Parent $HookLib)))

    # 'معماری' - the exact word the Graph-Read-Check relevance test uses.
    $persian = [string]::Join('', @(1605, 1593, 1605, 1575, 1585, 1740 | ForEach-Object { [char]$_ }))
    $expected = (($persian.ToCharArray() | ForEach-Object { [int]$_ }) -join ',')
    $probePayload = @{ session_id = 't'; hook_event_name = 'UserPromptSubmit'; prompt = $persian } | ConvertTo-Json -Compress

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoLogo', '-NoProfile', '-File', $utf8Probe)) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # No console for the child - the condition that exposed the defect.
    $psi.CreateNoWindow = $true
    $probeProc = [System.Diagnostics.Process]::Start($psi)
    # Write the payload as raw UTF-8 bytes and read the reply as raw bytes, so
    # THIS suite's own encoding can never mask or fake the hook's behavior.
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($probePayload)
    $probeProc.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $probeProc.StandardInput.BaseStream.Flush()
    $probeProc.StandardInput.Close()
    # Drain stderr asynchronously first: a full stderr pipe deadlocks a
    # synchronous stdout read (the _hooklib CopyTo lesson).
    $probeErrTask = $probeProc.StandardError.ReadToEndAsync()
    $probeOutBuffer = New-Object System.IO.MemoryStream
    $probeProc.StandardOutput.BaseStream.CopyTo($probeOutBuffer)
    [void]$probeProc.WaitForExit(60000)
    $probeErr = ''
    try { $probeErr = $probeErrTask.Result } catch { }
    $probeOut = ([System.Text.Encoding]::UTF8.GetString($probeOutBuffer.ToArray())).Trim()

    Check 'console-less hook process decodes a non-ASCII stdin payload as UTF-8, not the OEM code page' (
        $probeOut -match ('CODEPOINTS=' + [regex]::Escape($expected))) ($probeOut + ' | expected=' + $expected + ' | err=' + $probeErr)
    Check 'the probe hook still exits cleanly with nothing on stderr' (
        $probeProc.ExitCode -eq 0 -and $probeErr.Trim() -eq '') ('exit=' + $probeProc.ExitCode + ' err=' + $probeErr)

    Write-Host '--- _hooklib: client identity is explicit and never defaults a third client to Codex ---' -ForegroundColor Cyan
    # Hooks used to decide the client inline as "CLAUDE_PROJECT_DIR present ->
    # Claude, otherwise -> Codex". With a third client that silently hands Kiro
    # Codex's rules, skills, paths and output protocol. Get-HookClientId is the
    # one place that decision is made now.
    #
    # Dot-sourced into a child scope so the suite's own helpers are untouched.
    $cidOrigCpd = $env:CLAUDE_PROJECT_DIR
    try {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
        Set-ClaudeProjectDir 'C:\some\project'
        $cidClaude = & { . $HookLib; Get-HookClientId }
        $cidKiroBeatsClaude = & { . $HookLib; Get-HookClientId -Explicit 'kiro' }
        Set-ClaudeProjectDir ''
        $cidLegacyCodex = & { . $HookLib; Get-HookClientId }
        $cidUnknownName = & { . $HookLib; Get-HookClientId -Explicit 'gemini' }
        $cidLooseCase = & { . $HookLib; Get-HookClientId -Explicit '  KIRO ' }
        $env:HOOKMAKER_CLIENT = 'kiro'
        $cidEnvMarker = & { . $HookLib; Get-HookClientId }
        $env:HOOKMAKER_CLIENT = 'nonsense'
        $cidBadEnvMarker = & { . $HookLib; Get-HookClientId }
        Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue

        Check 'CLAUDE_PROJECT_DIR present resolves to claude' ($cidClaude -eq 'claude') $cidClaude
        Check 'an explicit client id overrides CLAUDE_PROJECT_DIR' ($cidKiroBeatsClaude -eq 'kiro') $cidKiroBeatsClaude
        Check 'no signal at all still resolves to codex (existing installs unchanged)' ($cidLegacyCodex -eq 'codex') $cidLegacyCodex
        Check 'an UNRECOGNISED explicit client is unknown, never codex' ($cidUnknownName -eq 'unknown') $cidUnknownName
        Check 'an explicit client id tolerates case and surrounding space' ($cidLooseCase -eq 'kiro') $cidLooseCase
        Check 'HOOKMAKER_CLIENT identifies a client that passes no argument' ($cidEnvMarker -eq 'kiro') $cidEnvMarker
        Check 'an unrecognised HOOKMAKER_CLIENT is unknown, never codex' ($cidBadEnvMarker -eq 'unknown') $cidBadEnvMarker

        # An installed runtime is self-contained: the installer rewrites
        # _hooklib.ps1 into it but copies no sibling from scripts\, so the client
        # id list CANNOT be shared by dot-sourcing and is duplicated by force.
        # This is the assertion that keeps the two copies honest.
        $cidLibIds = & { . $HookLib; @($script:HookClientIds) -join ',' }
        $cidTableIds = & { . (Join-Path $ScriptRoot '_clientcapability.ps1'); @(Get-HookMakerClientIds) -join ',' }
        Check '_hooklib client ids match the canonical capability table exactly' (
            $cidLibIds -eq $cidTableIds) ('hooklib=' + $cidLibIds + ' table=' + $cidTableIds)
    }
    finally {
        Set-ClaudeProjectDir $cidOrigCpd
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    }

    # =====================================================================
    Write-Host '--- _hooklib Write-HookResult: one adapter, client-shaped output, honest degradation ---' -ForegroundColor Cyan
    # ~62 open-coded emission sites across the shipped hooks each re-derive the
    # client shape by hand, and ~15 emit hookSpecificOutput with no client branch
    # at all - already mis-shaped for Codex. Write-HookResult is the one place a
    # SEMANTIC result becomes a client shape. Nothing calls it yet, so these
    # assertions are the whole contract: byte-identical Claude/Codex output
    # against REAL captured hook emissions, and a degradation report a caller can
    # record instead of claiming enforcement it did not get.
    $hrOrigCpd = $env:CLAUDE_PROJECT_DIR
    try {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }

        # BYTE-COMPATIBILITY (real emission site 1 of 4): Mcp-Usage-Check's
        # SessionStart context - one of the ~15 unbranched hookSpecificOutput
        # sites, so this pins the shape the adapter must keep for Claude. On the
        # 5.1 host for the deterministic-hashing reason described at the probe.
        $hrRealMcp = Fire -HookPath $McpHook -Cwd $plain -Exe 'powershell.exe'
        $hrMcpDoc = $null
        try { $hrMcpDoc = $hrRealMcp.Out | ConvertFrom-Json } catch { }
        $hrMcpMsg = if ($null -ne $hrMcpDoc -and $null -ne $hrMcpDoc.PSObject.Properties['hookSpecificOutput']) { [string]$hrMcpDoc.hookSpecificOutput.additionalContext } else { '' }
        $hrMcpAdapted = Invoke-HookResult -Call @{ kind = 'context'; event = 'SessionStart'; message = $hrMcpMsg; client = 'claude' } -Exe 'powershell.exe'
        Check '5.1 host: Write-HookResult reproduces a real SessionStart claude context byte-for-byte' (
            $hrMcpMsg -ne '' -and $hrMcpAdapted.Out -ceq $hrRealMcp.Out -and
            $hrMcpAdapted.Result.Shape -eq 'claudeContext' -and $hrMcpAdapted.Result.Degraded -eq $false) (
            'hook=[' + $hrRealMcp.Out + '] adapter=[' + $hrMcpAdapted.Out + ']')

        # Same-process construct proof, on BOTH hosts: the adapter's bytes must
        # equal the shipped literal's bytes for every shape. This is what makes
        # the byte-compatibility claim hold on pwsh 7, where cross-process key
        # order is randomised and literal equality is therefore impossible.
        $hrShape7 = Test-HookResultConstruct -Exe 'pwsh'
        Check 'pwsh 7: the adapter emits the shipped literal byte-for-byte for every shape (same process)' (
            $hrShape7 -eq '') $hrShape7
        $hrShape51 = Test-HookResultConstruct -Exe 'powershell.exe'
        Check '5.1: the adapter emits the shipped literal byte-for-byte for every shape (same process)' (
            $hrShape51 -eq '') $hrShape51

        # --- silent writes nothing at all ---
        $hrSilent = Invoke-HookResult -Call @{ kind = 'silent'; event = 'Stop'; message = 'never-emitted'; client = 'claude' }
        Check 'silent emits nothing on stdout or stderr and reports nothing degraded' (
            $hrSilent.Out -eq '' -and $hrSilent.Err -eq '' -and $hrSilent.Result.Emitted -eq $false -and
            $hrSilent.Result.Shape -eq 'none' -and $hrSilent.Result.Degraded -eq $false) ($hrSilent.Out + ' | ' + $hrSilent.Err)

        # --- an unknown client is never guessed at ---
        $hrUnknown = Invoke-HookResult -Call @{ kind = 'context'; event = 'SessionStart'; message = 'never-emitted'; client = 'gemini' }
        Check 'an unknown client emits NOTHING and reports it, never a guessed shape' (
            $hrUnknown.Out -eq '' -and $hrUnknown.Result.Emitted -eq $false -and $hrUnknown.Result.Shape -eq 'none' -and
            $hrUnknown.Result.Degraded -eq $true -and $hrUnknown.Result.DegradedReason -match 'client is unknown') (
            $hrUnknown.Out + ' | ' + [string]$hrUnknown.Result.DegradedReason)

        # --- a block on a non-block-capable event is downgraded, never faked ---
        # Kiro Stop cannot block on either surface Hook Maker targets, AND Kiro
        # discards hook stdout on Stop - so the honest result is no output at all
        # plus both facts reported. This is what lets a caller record
        # degraded-stop-gate instead of claiming a gate it never got.
        $hrKiroStopBlock = Invoke-HookResult -Call @{ kind = 'block'; event = 'Stop'; reason = 'KIRO-STOP-GATE'; client = 'kiro' }
        Check 'a block on Kiro Stop is DOWNGRADED, never emitted as a fake block' (
            $hrKiroStopBlock.Out -eq '' -and $hrKiroStopBlock.Out -notmatch 'decision' -and
            $hrKiroStopBlock.Err -notmatch 'KIRO-STOP-GATE' -and
            $hrKiroStopBlock.Result.Emitted -eq $false -and $hrKiroStopBlock.Result.ExitCode -eq 0) (
            $hrKiroStopBlock.Out + ' | ' + $hrKiroStopBlock.Err)
        Check 'the downgrade REPORTS Degraded with both reasons (no block mechanism, stdout discarded)' (
            $hrKiroStopBlock.Result.Degraded -eq $true -and
            $hrKiroStopBlock.Result.DegradedReason -match 'no block mechanism on Stop' -and
            $hrKiroStopBlock.Result.DegradedReason -match 'NOT an enforced gate' -and
            $hrKiroStopBlock.Result.DegradedReason -match 'discarded') ([string]$hrKiroStopBlock.Result.DegradedReason)

        # --- a block on a block-capable Kiro event is a REAL block ---
        $hrKiroRealBlock = Invoke-HookResult -Call @{ kind = 'block'; event = 'UserPromptSubmit'; reason = 'KIRO-REAL-GATE'; client = 'kiro' }
        Check 'a block on a block-capable Kiro event is exit 2 + stderr, and is NOT degraded' (
            $hrKiroRealBlock.Out -eq '' -and $hrKiroRealBlock.Err -match 'KIRO-REAL-GATE' -and
            $hrKiroRealBlock.Result.Emitted -eq $true -and $hrKiroRealBlock.Result.Shape -eq 'kiroExit2Stderr' -and
            $hrKiroRealBlock.Result.ExitCode -eq 2 -and $hrKiroRealBlock.Result.Degraded -eq $false) (
            $hrKiroRealBlock.Out + ' | ' + $hrKiroRealBlock.Err)

        # --- Kiro context lands only where Kiro documents it ---
        $hrKiroCtx = Invoke-HookResult -Call @{ kind = 'context'; event = 'SessionStart'; message = 'KIRO-CTX-TEXT'; client = 'kiro' }
        Check 'Kiro context on a documented trigger is plain stdout, never a Claude/Codex JSON shape' (
            $hrKiroCtx.Out -ceq 'KIRO-CTX-TEXT' -and $hrKiroCtx.Result.Shape -eq 'kiroStdout' -and
            $hrKiroCtx.Result.Emitted -eq $true -and $hrKiroCtx.Result.Degraded -eq $false) $hrKiroCtx.Out
        $hrKiroCtxIgnored = Invoke-HookResult -Call @{ kind = 'context'; event = 'PostToolUse'; message = 'KIRO-IGNORED'; client = 'kiro' }
        Check 'Kiro context on an undocumented trigger emits nothing and reports the silent no-op' (
            $hrKiroCtxIgnored.Out -eq '' -and $hrKiroCtxIgnored.Result.Emitted -eq $false -and
            $hrKiroCtxIgnored.Result.Degraded -eq $true -and
            $hrKiroCtxIgnored.Result.DegradedReason -match 'discarded') (
            $hrKiroCtxIgnored.Out + ' | ' + [string]$hrKiroCtxIgnored.Result.DegradedReason)

        # --- the same downgrade rule applies to Claude, not just Kiro ---
        $hrClaudeSsBlock = Invoke-HookResult -Call @{ kind = 'block'; event = 'SessionStart'; reason = 'CLAUDE-SS-GATE'; client = 'claude' }
        Check 'a block on Claude SessionStart downgrades to the advisory shape and reports it' (
            $hrClaudeSsBlock.Out -notmatch '"decision"' -and $hrClaudeSsBlock.Out -match 'additionalContext' -and
            $hrClaudeSsBlock.Result.Shape -eq 'claudeContext' -and $hrClaudeSsBlock.Result.Degraded -eq $true) $hrClaudeSsBlock.Out

        # --- the forced mirror of the canonical blocking table stays honest ---
        # _hooklib cannot dot-source scripts\_clientcapability.ps1 (an installed
        # runtime is self-contained), so blockCapableEvents is duplicated by
        # force - the same pattern as $script:HookClientIds. This is the guard.
        $hrMirrorDiff = & {
            . $HookLib
            . (Join-Path $ScriptRoot '_clientcapability.ps1')
            $bad = @()
            foreach ($clientId in @(Get-HookMakerClientIds)) {
                if (-not $script:HookBlockCapableEvents.ContainsKey($clientId)) { $bad += ($clientId + '/<missing>'); continue }
                foreach ($logical in @(Get-HookMakerLogicalEvents)) {
                    $fromTable = Test-HookMakerEventBlocking -ClientId $clientId -EventName $logical
                    $fromMirror = (@($script:HookBlockCapableEvents[$clientId] | Where-Object { $_ -ceq $logical }).Count -gt 0)
                    if ($fromTable -ne $fromMirror) { $bad += ($clientId + '/' + $logical) }
                }
            }
            ($bad -join ',')
        }
        Check '_hooklib block-capability mirror decides identically to Test-HookMakerEventBlocking for every client x event' (
            $hrMirrorDiff -eq '') ('mismatches=' + $hrMirrorDiff)
        $hrMirrorShape = & {
            . $HookLib
            . (Join-Path $ScriptRoot '_clientcapability.ps1')
            $keys = (@($script:HookBlockCapableEvents.Keys) | Sort-Object) -join ','
            $bogus = @()
            foreach ($clientId in @($script:HookBlockCapableEvents.Keys)) {
                foreach ($name in @($script:HookBlockCapableEvents[$clientId])) {
                    if ($null -eq (Resolve-HookMakerLogicalEvent -Name $name)) { $bogus += ($clientId + '/' + $name) }
                }
            }
            $keys + '|' + ((@(Get-HookMakerClientIds) | Sort-Object) -join ',') + '|' + ($bogus -join ',')
        }
        $hrMirrorParts = $hrMirrorShape.Split('|')
        Check 'the mirror covers exactly the canonical clients and names no unknown event' (
            $hrMirrorParts[0] -eq $hrMirrorParts[1] -and $hrMirrorParts[2] -eq '') $hrMirrorShape

        # Kiro's context-capable triggers come from .ai/KIRO_PROTOCOL.md (exit 0:
        # stdout is added to context ONLY on SessionStart and UserPromptSubmit).
        # There is no canonical table to mirror, so this pins the constant.
        $hrKiroCtxEvents = & { . $HookLib; @($script:HookKiroContextEvents) -join ',' }
        Check 'Kiro context triggers stay exactly the two the protocol documents' (
            $hrKiroCtxEvents -eq 'SessionStart,UserPromptSubmit') $hrKiroCtxEvents
    }
    finally {
        Set-ClaudeProjectDir $hrOrigCpd
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
