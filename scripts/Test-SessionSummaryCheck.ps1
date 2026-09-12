# Offline suite for Session-Summary-Check - the closing "what shipped / what
# is left" report, delivered BEFORE the task (SessionStart, UserPromptSubmit)
# and silent at Stop.
#
# HERMETIC BY REDIRECTING LOCALAPPDATA. The hook reads the sibling gates'
# stop-block markers out of %LOCALAPPDATA%\HookMaker\state, which on a real
# machine is full of the developer's own markers from real sessions. Every
# invocation below therefore runs with LOCALAPPDATA pointed at a directory
# inside this suite's workspace, so the fixtures are the only markers that
# exist and nothing here can read - or damage - the real state directory.
#
# Exit code is the number of failed assertions (0 = all passed).

[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HooksRoot = Join-Path $ToolRoot 'hooks'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $ScriptRoot '_testlib.ps1')
. (Join-Path $HooksRoot '_hooklib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-sessionsummary'
$Hook = Join-Path $HooksRoot 'Session-Summary-Check\Session-Summary-Check.ps1'
$FakeLocalAppData = Join-Path $Work 'localappdata'
$StateDir = Join-Path $FakeLocalAppData 'HookMaker\state'

# The hook re-delivers on a cooldown, keyed by session. Every case below wants
# a fresh first delivery, so the stamp is cleared by default. -KeepDelivered
# opts out, which is how the cooldown itself is asserted.
function Invoke-SummaryHook {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [switch]$AsClaude,
        [switch]$KeepDelivered,
        [string]$Exe = 'pwsh'
    )
    if (-not $KeepDelivered) {
        $deliveredKey = Get-ShortHash ([string]$Payload['cwd']).ToLowerInvariant()
        $deliveredPath = Join-Path $StateDir ('SessionSummary-' + $deliveredKey + '.txt')
        Remove-Item -LiteralPath $deliveredPath -Force -ErrorAction SilentlyContinue
    }
    $json = ($Payload | ConvertTo-Json -Depth 8 -Compress)
    $prevLocal = $env:LOCALAPPDATA
    $prevClaude = $env:CLAUDE_PROJECT_DIR
    $env:LOCALAPPDATA = $FakeLocalAppData
    if ($AsClaude) { $env:CLAUDE_PROJECT_DIR = [string]$Payload['cwd'] } else { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    try {
        $out = ($json | & $Exe -NoProfile -File $Hook 2>&1) -join "`n"
        return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    }
    finally {
        $env:LOCALAPPDATA = $prevLocal
        if ($null -eq $prevClaude) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_PROJECT_DIR = $prevClaude }
    }
}

# Writes a stop-block marker exactly as Set-StopBlockMarker in _hooklib.ps1
# does, deriving the key with the same helper so the fixture cannot drift away
# from the production naming.
function New-BlockMarker {
    param(
        [Parameter(Mandatory = $true)][string]$HookName,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId
    )
    $key = Get-ShortHash ([string]$ProjectRoot).ToLowerInvariant()
    $safe = [System.Text.RegularExpressions.Regex]::Replace($HookName, '[^A-Za-z0-9]+', '')
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $path = Join-Path $StateDir ('StopBlock-' + $safe + '-' + $key + '.txt')
    [System.IO.File]::WriteAllText($path, $SessionId)
    return $path
}

try {
    $proj = Join-Path $Work 'proj'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $sid = 'session-under-test'

    # =====================================================================
    Write-Host '--- events: it speaks BEFORE the task and nowhere else ---' -ForegroundColor Cyan
    $r = Invoke-SummaryHook @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = $sid }
    Check 'summary: SessionStart delivers the closing requirement' ($r.Out -match 'SESSION SUMMARY') $r.Out
    Check 'summary: SessionStart exits 0' ($r.Exit -eq 0) ([string]$r.Exit)
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    Check 'summary: UserPromptSubmit delivers it too' ($r.Out -match 'SESSION SUMMARY') $r.Out

    # Stop is the event this hook shipped on twice, and looped on twice: on
    # Claude Code a Stop additionalContext re-invokes the model, so a summary
    # asked for at Stop always arrives as one more turn AFTER the work - and
    # when nothing is left to say, that turn is "waiting." / "done.". It is
    # silent there now, whatever the session, even when nothing was delivered
    # yet - the loop assertion of this suite.
    foreach ($quiet in @('Stop', 'SubagentStop', 'PreToolUse', 'PostToolUse', 'SessionEnd')) {
        $r = Invoke-SummaryHook @{ hook_event_name = $quiet; cwd = $proj; session_id = ('fresh-' + $quiet) }
        Check ('summary: silent on ' + $quiet + ' (exit 0, no output)') ($r.Exit -eq 0 -and $r.Out.Trim() -eq '') $r.Out
    }
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid; stop_hook_active = $true }
    Check 'summary: Stop stays silent with stop_hook_active too' ($r.Out.Trim() -eq '') $r.Out

    # =====================================================================
    Write-Host '--- it is ADVISORY: a block would guarantee something comes after it ---' -ForegroundColor Cyan
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    Check 'summary: never emits a block decision' ($r.Out -notmatch '"decision"') $r.Out
    Check 'summary: never uses the blocking exit code 2' ($r.Exit -ne 2) ([string]$r.Exit)

    # =====================================================================
    Write-Host '--- the requirement itself ---' -ForegroundColor Cyan
    Check 'summary: asks for a DONE section' ($r.Out -match 'DONE') $r.Out
    Check 'summary: asks for a REMAINING section' ($r.Out -match 'REMAINING') $r.Out
    Check 'summary: places itself as the CLOSING section of the final message' ($r.Out -match 'CLOSING section') $r.Out
    Check 'summary: states WHEN (only the message that finishes) and ONCE' (($r.Out -match 'WHEN:') -and ($r.Out -match 'ONCE:')) $r.Out
    Check 'summary: names the sibling requirements it must follow' (
        ($r.Out -match 'MCP used') -and ($r.Out -match 'Skills used')) $r.Out
    Check 'summary: demands failures and untested paths be included' ($r.Out -match 'untested') $r.Out
    Check 'summary: demands every blocking gate be accounted for' ($r.Out -match 'accounted for') $r.Out
    $summaryMessage = [string](($r.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext)
    Check 'summary: successful checks and resolved blockers belong in DONE' (
        $summaryMessage -match '(?m)^  DONE.*successful.*resolved') $summaryMessage
    Check 'summary: REMAINING contains only unresolved required work' (
        $summaryMessage -match '(?m)^  REMAINING.*ONLY.*unresolved.*required') $summaryMessage
    Check 'summary: completed items must not be relisted as remaining' (
        $summaryMessage -match 'Never put completed.*REMAINING') $summaryMessage

    # =====================================================================
    Write-Host '--- with no markers there is no gate list at all ---' -ForegroundColor Cyan
    Check 'summary: says nothing about gates when none blocked' ($r.Out -notmatch 'blocked earlier in this session') $r.Out

    # =====================================================================
    Write-Host '--- gate markers: this session only ---' -ForegroundColor Cyan
    $null = New-BlockMarker -HookName 'Secrets-Check' -ProjectRoot $proj -SessionId $sid
    $null = New-BlockMarker -HookName 'Ci-Status-Check' -ProjectRoot $proj -SessionId $sid
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    Check 'summary: reports that gates blocked earlier this session' ($r.Out -match 'blocked earlier in this session') $r.Out
    Check 'summary: names both gates, sorted' ($r.Out -match 'CiStatusCheck, SecretsCheck') $r.Out
    Check 'summary: asks for each blocked gate to be accounted for' ($r.Out -match 'Account for each one') $r.Out
    Check 'summary: old gate markers are history, not evidence of an open blocker' (
        $r.Out -match 'history only' -and $r.Out -match 'do not prove.*still open') $r.Out

    # A marker left by an EARLIER session in the same project is evidence about
    # that session, not this one. Reporting it would accuse the current session
    # of a block it never hit.
    $null = New-BlockMarker -HookName 'Docs-Freshness-Check' -ProjectRoot $proj -SessionId 'an-older-session'
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    Check 'summary: ignores a marker from a different session' ($r.Out -notmatch 'DocsFreshnessCheck') $r.Out
    Check 'summary: still names this session''s own gates' ($r.Out -match 'CiStatusCheck, SecretsCheck') $r.Out

    # A marker for a DIFFERENT project shares the state directory but not the
    # project key, so it must not leak into this project's summary.
    $otherProj = Join-Path $Work 'other-proj'
    New-Item -ItemType Directory -Path $otherProj -Force | Out-Null
    $null = New-BlockMarker -HookName 'Large-File-Check' -ProjectRoot $otherProj -SessionId $sid
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    Check 'summary: ignores a marker belonging to another project' ($r.Out -notmatch 'LargeFileCheck') $r.Out

    # =====================================================================
    Write-Host '--- it is read-only: the state directory is not its to write ---' -ForegroundColor Cyan
    $before = @(Get-ChildItem -LiteralPath $StateDir -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Length }) -join '|'
    $null = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    $after = @(Get-ChildItem -LiteralPath $StateDir -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Length }) -join '|'
    Check 'summary: leaves every marker byte-for-byte untouched' ($before -eq $after) ($before + ' -> ' + $after)
    # It writes exactly ONE file of its own: the delivery stamp behind the
    # cooldown. Anything BEYOND that would mean it had started keeping state
    # it has no business keeping - the sibling gates' StopBlock markers are
    # read-only to it, asserted above.
    Check 'summary: writes only its own delivery stamp, nothing else' (
        @(Get-ChildItem -LiteralPath $StateDir -File | Where-Object {
                $_.Name -notlike 'StopBlock-*' -and $_.Name -notlike 'SessionSummary-*'
            }).Count -eq 0) $after

    # =====================================================================
    Write-Host '--- cooldown: once per window on prompts, always on SessionStart ---' -ForegroundColor Cyan
    # A long session is reminded again before it ends; a burst of prompts is
    # not. And a new session id is always told, whatever the last one did.
    $loopProj = Join-Path $Work 'loop-proj'
    New-Item -ItemType Directory -Path $loopProj -Force | Out-Null
    $first = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $loopProj; session_id = 'loop-a' }
    Check 'summary: the first prompt of a session delivers the requirement' ($first.Out -match 'SESSION SUMMARY') $first.Out
    $second = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $loopProj; session_id = 'loop-a' }
    Check 'summary: a SECOND prompt inside the window says nothing' ($second.Out.Trim() -eq '') $second.Out
    $third = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $loopProj; session_id = 'loop-a' }
    Check 'summary: a THIRD prompt stays silent too (no slow re-arming)' ($third.Out.Trim() -eq '') $third.Out
    $newSession = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $loopProj; session_id = 'loop-b' }
    Check 'summary: a NEW session is told again' ($newSession.Out -match 'SESSION SUMMARY') $newSession.Out
    # SessionStart is a rebuilt context (startup, resume, clear, compaction):
    # it always delivers, inside the window or not, and it stamps the window so
    # the very next prompt does not repeat it.
    $restart = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'SessionStart'; cwd = $loopProj; session_id = 'loop-b' }
    Check 'summary: SessionStart delivers even inside the window (rebuilt context)' ($restart.Out -match 'SESSION SUMMARY') $restart.Out
    $afterRestart = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $loopProj; session_id = 'loop-b' }
    Check 'summary: the prompt right after a SessionStart does not repeat it' ($afterRestart.Out.Trim() -eq '') $afterRestart.Out
    # The window is real: an expired stamp re-delivers on the next prompt.
    $stampPath = Join-Path $StateDir ('SessionSummary-' + (Get-ShortHash ([string]$loopProj).ToLowerInvariant()) + '.txt')
    [System.IO.File]::WriteAllText($stampPath, ('loop-b|' + [DateTime]::UtcNow.AddMinutes(-16).ToString('o')))
    $expired = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $loopProj; session_id = 'loop-b' }
    Check 'summary: a prompt after the window expired is reminded again' ($expired.Out -match 'SESSION SUMMARY') $expired.Out

    # =====================================================================
    Write-Host '--- client output shapes ---' -ForegroundColor Cyan
    # UserPromptSubmit is a context event for BOTH clients: Claude and Codex
    # each get hookSpecificOutput.additionalContext (Codex's systemMessage is
    # Stop-scoped, and this hook no longer speaks at Stop).
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid } -AsClaude
    Check 'summary: Claude gets model-visible additionalContext on the prompt' (
        ($r.Out -match 'hookSpecificOutput') -and ($r.Out -match 'additionalContext') -and ($r.Out -match '"hookEventName":"UserPromptSubmit"')) $r.Out
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid }
    Check 'summary: Codex gets additionalContext too (systemMessage is Stop-only)' (
        ($r.Out -match 'additionalContext') -and ($r.Out -notmatch 'systemMessage')) $r.Out
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'SessionStart'; cwd = $proj; session_id = $sid } -AsClaude
    Check 'summary: SessionStart carries its own event name in the shape' ($r.Out -match '"hookEventName":"SessionStart"') $r.Out

    # =====================================================================
    Write-Host '--- degrades quietly on bad or missing input ---' -ForegroundColor Cyan
    $prevLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $FakeLocalAppData
    try {
        $out = ('not json at all' | & pwsh -NoProfile -File $Hook 2>&1) -join "`n"
        Check 'summary: malformed stdin exits 0 without output' (($LASTEXITCODE -eq 0) -and ($out.Trim() -eq '')) ($out + ' exit=' + $LASTEXITCODE)
    }
    finally { $env:LOCALAPPDATA = $prevLocal }

    # Without a session id the markers cannot be scoped, and an unscoped list
    # would report other sessions' blocks as this one's. It still delivers the
    # requirement - that part needs no session - but names no gates.
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj }
    Check 'summary: no session id still yields the requirement' ($r.Out -match 'SESSION SUMMARY') $r.Out
    Check 'summary: no session id names no gates rather than guessing' ($r.Out -notmatch 'blocked earlier in this session') $r.Out

    # An empty marker must not match an empty/absent session id and quietly
    # report a gate that never blocked.
    $null = New-BlockMarker -HookName 'Rules-Check' -ProjectRoot $proj -SessionId ''
    $r = Invoke-SummaryHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj }
    Check 'summary: an empty marker is not matched by a missing session id' ($r.Out -notmatch 'RulesCheck') $r.Out

    # A state directory that does not exist yet is the normal first-run case.
    $emptyLocal = Join-Path $Work 'localappdata-empty'
    New-Item -ItemType Directory -Path $emptyLocal -Force | Out-Null
    $prevLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $emptyLocal
    try {
        $json = (@{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid } | ConvertTo-Json -Compress)
        $out = ($json | & pwsh -NoProfile -File $Hook 2>&1) -join "`n"
        Check 'summary: no state directory at all is not an error' (($LASTEXITCODE -eq 0) -and ($out -match 'SESSION SUMMARY')) ($out + ' exit=' + $LASTEXITCODE)
    }
    finally { $env:LOCALAPPDATA = $prevLocal }

    # =====================================================================
    Write-Host '--- parses under Windows PowerShell 5.1 as well as pwsh 7 ---' -ForegroundColor Cyan
    # The hook ships to both hosts, so a pwsh-only construct is a real defect.
    $parse = powershell.exe -NoLogo -NoProfile -Command "`$e=`$null; `$null=[System.Management.Automation.Language.Parser]::ParseFile('$Hook',[ref]`$null,[ref]`$e); if(`$e -and `$e.Count){'FAIL'}else{'OK'}"
    Check 'summary: parses under Windows PowerShell 5.1' (([string]$parse).Trim() -eq 'OK') ([string]$parse)
    $r51 = Invoke-SummaryHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $proj; session_id = $sid } -Exe 'powershell.exe'
    Check 'summary: Windows PowerShell 5.1 emits the same open-work classification' (
        $r51.Exit -eq 0 -and $r51.Out -match 'Never put completed.*REMAINING' -and
        $r51.Out -match 'history only') $r51.Out

    # The hook is shipped source: it must stay pure ASCII, like every other
    # hook in this set (Persian is carried as \uXXXX escapes and decoded at
    # runtime), or a non-UTF-8 console mangles it on the way to the client.
    $bytes = [System.IO.File]::ReadAllBytes($Hook)
    Check 'summary: the shipped hook source is pure ASCII' (
        @($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) ('non-ascii bytes: ' + @($bytes | Where-Object { $_ -gt 127 }).Count)
}
finally {
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
