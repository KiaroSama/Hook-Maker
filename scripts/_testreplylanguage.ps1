# Test-SessionSummaryCheck section: the reply-language line (plan 012 step 6e,
# steering V45, spec 010 RD-9 / FR-015).
#
# Dot-sourced from Test-SessionSummaryCheck.ps1 INSIDE its try block, after the
# read-only assertions (this section writes ReplyLanguage-* state on purpose).
# Uses that suite's harness: $Work, $Hook, $HooksRoot, $FakeLocalAppData,
# $StateDir, Invoke-SummaryHook, Check. The underscore keeps it out of the
# runner's Test-*.ps1 glob.
#
# Persian text is built from code points, so this file stays ASCII like the
# hooks it tests.

    Write-Host '--- V45: replies stay in the language the user TYPED ---' -ForegroundColor Cyan
    $rlFa = -join ([char[]](0x0633, 0x0644, 0x0627, 0x0645, 0x0020, 0x0648, 0x0636, 0x0639, 0x06CC, 0x062A, 0x0020, 0x0686, 0x06CC, 0x0647))
    $rlLine = 'LANGUAGE: the user writes in Persian. Every message in this turn, progress notes included, is in Persian; code, commands, file contents and commit messages stay English.'
    . (Join-Path $HooksRoot '_replylanguage.ps1')
    $rlCases = [ordered]@{
        'persian'   = @($rlFa, 'persian')
        'english'   = @('please run the tests and fix the failure', 'english')
        'mixed'     = @(($rlFa + ' Get-ReplyLanguageLine Write-StopBlockResult Test-InjectedPromptText'), '')
        'skill'     = @(('Base directory for this skill: C:\x' + "`n" + $rlFa + $rlFa), '')
        'compacted' = @(('This session is being continued from a previous conversation. ' + $rlFa + $rlFa), '')
        'digits'    = @('12345 ...', '')
    }
    $rlWrong = @($rlCases.Keys | Where-Object { (Get-TypedPromptLanguage -Text $rlCases[$_][0]) -cne $rlCases[$_][1] })
    Check 'RL01 detection: Persian, English, mixed-with-code, skill text, compaction summary, no letters' ($rlWrong.Count -eq 0) ($rlWrong -join ', ')

    $rlProj = Join-Path $Work 'rl-project'
    New-Item -ItemType Directory -Path $rlProj -Force | Out-Null
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $rlProj; session_id = 'rl-1'; prompt = $rlFa } -AsClaude
    Check 'RL02 a Persian prompt yields the LANGUAGE line as Claude additionalContext' (
        $r.Exit -eq 0 -and $r.Out.Contains($rlLine) -and $r.Out -match 'additionalContext' -and $r.Out -notmatch '"decision"') $r.Out
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $rlProj; session_id = 'rl-1'; prompt = $rlFa } -AsClaude -KeepDelivered
    Check 'RL03 inside the summary cooldown the line still arrives, alone' (
        $r.Out.Contains($rlLine) -and $r.Out -notmatch 'SESSION SUMMARY' -and $r.Out -match 'additionalContext') $r.Out
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $rlProj; session_id = 'rl-c'; prompt = $rlFa }
    Check 'RL02b the Codex shape carries it as additionalContext too' ($r.Out.Contains($rlLine) -and $r.Out -match 'additionalContext') $r.Out
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $rlProj; session_id = 'rl-1'; prompt = ('Base directory for this skill: C:\x ' + $rlFa) } -AsClaude -KeepDelivered
    Check 'RL04 a skill expansion is not the user typing: no line' ($r.Out -notmatch 'LANGUAGE:') $r.Out
    foreach ($source in @('compact', 'resume')) {
        $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'SessionStart'; cwd = $rlProj; session_id = 'rl-1'; source = $source } -AsClaude
        Check ('RL05 SessionStart after ' + $source + ' repeats the line from state') ($r.Out.Contains($rlLine) -and $r.Out -match 'SESSION SUMMARY') $r.Out
    }
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'SessionStart'; cwd = $rlProj; session_id = 'rl-1'; source = 'startup' } -AsClaude
    Check 'RL06 a fresh startup does not repeat it' ($r.Out -notmatch 'LANGUAGE:') $r.Out

    $rlStateFor = { param($Sid) Join-Path $StateDir ('ReplyLanguage-' + (Get-ShortHash $Sid) + '.txt') }
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $rlProj; session_id = 'rl-2'; prompt = 'fix the build please' }
    Check 'RL07 an English prompt yields no line and writes no state' (
        $r.Out -notmatch 'LANGUAGE:' -and -not (Test-Path -LiteralPath (& $rlStateFor 'rl-2'))) $r.Out
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $rlProj; session_id = 'rl-1'; prompt = 'now answer in English please' } -AsClaude -KeepDelivered
    Check 'RL08 switching to English clears it for the session' (
        $r.Out -notmatch 'LANGUAGE:' -and ([IO.File]::ReadAllText((& $rlStateFor 'rl-1'))).Trim() -eq 'english') $r.Out

    # The shared Stop block path: every gate's block text ends with the line.
    $rlProbe = Join-Path $Work 'rl-blockprobe.ps1'
    [IO.File]::WriteAllText($rlProbe, (@(
                'param([string]$HookLibPath, [string]$InputPath)',
                'Set-StrictMode -Version 2.0',
                '$ErrorActionPreference = ''Stop''',
                '. $HookLibPath',
                '$in = [IO.File]::ReadAllText($InputPath) | ConvertFrom-Json',
                '$r = Write-StopBlockResult -HookInput $in -HookName ''Rules-Check'' -EventName ''Stop'' -Reason ''RULES CHECK: language probe''',
                'exit $r.ExitCode'
            ) -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    foreach ($client in @('claude', 'codex')) {
        [IO.File]::WriteAllText((& $rlStateFor ('rl-block-' + $client)), 'persian')
        $rlIn = Join-Path $Work ('rl-block-' + $client + '.json')
        [IO.File]::WriteAllText($rlIn, (@{ session_id = ('rl-block-' + $client); cwd = $rlProj; hook_event_name = 'Stop'; stop_hook_active = $false } | ConvertTo-Json -Compress))
        $prevLocal = $env:LOCALAPPDATA; $prevClaude = $env:CLAUDE_PROJECT_DIR; $prevClient = $env:HOOKMAKER_CLIENT
        $env:LOCALAPPDATA = $FakeLocalAppData; $env:HOOKMAKER_CLIENT = $client
        if ($client -eq 'claude') { $env:CLAUDE_PROJECT_DIR = $rlProj } else { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
        try { $out = (& pwsh -NoLogo -NoProfile -NonInteractive -File $rlProbe -HookLibPath (Join-Path $HooksRoot '_hooklib.ps1') -InputPath $rlIn 2>$null) -join "`n" }
        finally {
            $env:LOCALAPPDATA = $prevLocal; $env:HOOKMAKER_CLIENT = $prevClient
            if ($null -eq $prevClaude) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevClaude }
        }
        $reason = ''
        try {
            $doc = $out | ConvertFrom-Json
            foreach ($field in @('reason', 'systemMessage', 'stopReason')) { if ($null -ne $doc.PSObject.Properties[$field]) { $reason = [string]$doc.$field; break } }
        }
        catch { $reason = '' }
        Check ('RL09 a gate block (' + $client + ') ends with the LANGUAGE line') (
            $reason -match 'RULES CHECK: language probe' -and $reason.TrimEnd().EndsWith($rlLine)) $out
    }

    $rlLib = Join-Path $HooksRoot '_replylanguage.ps1'
    $rlParse = powershell.exe -NoLogo -NoProfile -Command "`$e=`$null; `$null=[System.Management.Automation.Language.Parser]::ParseFile('$rlLib',[ref]`$null,[ref]`$e); if(`$e -and `$e.Count){'FAIL'}else{'OK'}"
    Check 'RL10 the shared library parses under Windows PowerShell 5.1 and is pure ASCII' (
        ([string]$rlParse).Trim() -eq 'OK' -and @([System.IO.File]::ReadAllBytes($rlLib) | Where-Object { $_ -gt 127 }).Count -eq 0) ([string]$rlParse)
