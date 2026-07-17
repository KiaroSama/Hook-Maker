# Offline smoke test for the two simplest pre-task context hooks, which had
# ZERO dedicated coverage before this suite (only implicitly touched by
# Test-Wizard's generic install flow, never actually fired and verified):
# - Mcp-Usage-Check: always emits a short MCP-usage reminder on SessionStart
#   (no deterministic gate - it is meant to be cheap and constant, matching
#   the shipped hook's own design).
# - Skills-Check: silent unless a skill source exists (copied project
#   skills, .ai/SKILLS.md record, or the configured/default skill library).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-ContextHooks.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$McpHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Mcp-Usage-Check\Mcp-Usage-Check.ps1'
$SkillsHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Skills-Check\Skills-Check.ps1'
foreach ($required in @($McpHook, $SkillsHook)) {
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

# Copies Skills-Check + a custom .env into an isolated folder, so SKILLS_DIR
# overrides never touch the real machine-wide skill library.
function New-ConfiguredSkillsHookCopy {
    param([hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $SkillsHook (Join-Path $dir 'Skills-Check.ps1')
    Copy-Item (Join-Path (Split-Path -Parent $SkillsHook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
    Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    return (Join-Path $dir 'Skills-Check.ps1')
}

try {
    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: input handling ---' -ForegroundColor Cyan
    $plain = New-Proj 'Plain'
    $r = Fire -HookPath $McpHook -Cwd $plain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -RawStdin 'garbage'
    Check 'garbage stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $McpHook -Cwd $plain -EventName 'Stop'
    Check 'Stop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: always reminds on SessionStart (cheap, no gate) ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'emits a valid hookSpecificOutput on SessionStart' ($null -ne $parsed -and [string]$parsed.hookSpecificOutput.hookEventName -eq 'SessionStart')
    Check 'mentions MCP USAGE CHECK' ($r.Out -like '*MCP USAGE CHECK*') $r.Out
    Check 'note stays short (under ~600 chars, matching the "3-4 lines" design)' ($null -ne $parsed -and ([string]$parsed.hookSpecificOutput.additionalContext).Length -lt 600)
    $r2 = Fire -HookPath $McpHook -Cwd $plain
    Check 'fires again next session too (no state file by design)' ($r2.Out -like '*MCP USAGE CHECK*') $r2.Out
    $r3 = Fire -HookPath $McpHook -Cwd $plain -EventName 'UserPromptSubmit'
    Check 'also emits on UserPromptSubmit' ($r3.Out -like '*MCP USAGE CHECK*') $r3.Out

    # =====================================================================
    Write-Host '--- Mcp-Usage-Check: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $r = Fire -HookPath $McpHook -Cwd $plain -Exe 'powershell.exe'
    Check '5.1 host: emits cleanly, no crash' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*MCP USAGE CHECK*') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: input handling + silent with nothing to point at ---' -ForegroundColor Cyan
    $splain = New-Proj 'SkillsPlain'
    $r = Fire -HookPath $SkillsHook -Cwd $splain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $SkillsHook -Cwd $splain -EventName 'Stop'
    Check 'Stop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # No copied skills, no .ai/SKILLS.md, and the DEFAULT library path does not
    # exist on a throwaway machine path - override SKILLS_DIR to something
    # guaranteed absent so this run is deterministic regardless of the real host.
    $noSourceHook = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $noSourceHook -Cwd $splain
    Check 'no skill source anywhere -> silent, zero tokens' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Skills-Check: reports copied project skills ---' -ForegroundColor Cyan
    $proj1 = New-Proj 'WithCopiedSkills'
    New-Item -ItemType Directory -Path (Join-Path $proj1 '.claude\skills\my-skill') -Force | Out-Null
    $hook1 = New-ConfiguredSkillsHookCopy -EnvOverrides @{ SKILLS_DIR = (Join-Path $Work 'no-such-library') }
    $r = Fire -HookPath $hook1 -Cwd $proj1
    Check 'lists the copied skill folder name' ($r.Out -like '*SKILL POLICY CHECK*' -and $r.Out -like '*my-skill*') $r.Out
    Check 'requires a final "Skills used:" summary line for skills actually used' ($r.Out -match 'Skills used:') $r.Out
    Check 'the policy explicitly excludes merely-installed/available/considered/copied-but-unused skills' (
        $r.Out -match 'never a skill that was merely installed, available, discovered, copied, considered, or read but not used') $r.Out
    Check 'the policy requires omitting the line entirely when no skill was used' ($r.Out -match 'Omit the line entirely if no skill was actually used') $r.Out
    Check 'the policy forbids listing the whole library' ($r.Out -match 'never the whole library') $r.Out
    Check 'the policy does not force a skill for trivial tasks merely to produce the line' ($r.Out -match 'do not force a skill for trivial tasks') $r.Out

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
}
finally {
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
