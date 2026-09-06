# Offline suite for Session-Summary-Check - the closing "what shipped / what
# is left" report.
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

# The hook speaks ONCE PER SESSION (it looped otherwise - see the hook
# header). Every case below wants a fresh first Stop, so the delivery marker
# is cleared by default. -KeepDelivered opts out, which is how the
# once-per-session behaviour itself is asserted.
function Invoke-SummaryHook {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [switch]$AsClaude,
        [switch]$KeepDelivered
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
        $out = ($json | & pwsh -NoProfile -File $Hook 2>&1) -join "`n"
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
    Write-Host '--- events: it speaks on the two stop events and nowhere else ---' -ForegroundColor Cyan
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: Stop produces the closing requirement' ($r.Out -match 'SESSION SUMMARY') $r.Out
    Check 'summary: Stop exits 0' ($r.Exit -eq 0) ([string]$r.Exit)

    $r = Invoke-SummaryHook @{ hook_event_name = 'SubagentStop'; cwd = $proj; session_id = $sid }
    Check 'summary: SubagentStop produces it too' ($r.Out -match 'SESSION SUMMARY') $r.Out

    foreach ($quiet in @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'SessionEnd')) {
        $r = Invoke-SummaryHook @{ hook_event_name = $quiet; cwd = $proj; session_id = $sid }
        Check ('summary: silent on ' + $quiet) ($r.Out.Trim() -eq '') $r.Out
    }

    # =====================================================================
    Write-Host '--- it is ADVISORY: a block would guarantee something comes after it ---' -ForegroundColor Cyan
    # This is the whole design premise, so it is asserted rather than assumed:
    # a gate that blocks sends the agent back to work, and whatever it does
    # next lands after the summary - which is exactly what this hook exists to
    # prevent. If it ever starts blocking, the hook has defeated itself.
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: never emits a block decision' ($r.Out -notmatch '"decision"') $r.Out
    Check 'summary: never uses the blocking exit code 2' ($r.Exit -ne 2) ([string]$r.Exit)

    # =====================================================================
    Write-Host '--- stop_hook_active must NOT silence it (the differentiator) ---' -ForegroundColor Cyan
    # Every other Stop hook exits on this flag to avoid re-firing on its own
    # block. This one keys on SESSION IDENTITY instead, because the flag is set
    # for ANY gate's block: honouring it would skip the very first Stop
    # whenever some other gate happened to fire first, which is exactly when a
    # wrap-up matters most.
    #
    # An earlier comment here claimed this hook "cannot loop - it never
    # blocks". That was wrong and it is why the loop shipped: a hook does not
    # need to BLOCK to loop, it only needs to keep asking. See the
    # once-per-session block below.
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid; stop_hook_active = $true }
    Check 'summary: stop_hook_active alone does not silence a first Stop' ($r.Out -match 'SESSION SUMMARY') $r.Out

    # =====================================================================
    Write-Host '--- the requirement itself ---' -ForegroundColor Cyan
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: asks for a DONE section' ($r.Out -match 'DONE') $r.Out
    Check 'summary: asks for a REMAINING section' ($r.Out -match 'REMAINING') $r.Out
    Check 'summary: places itself as the CLOSING section of the reply' ($r.Out -match 'CLOSING section') $r.Out
    Check 'summary: names the sibling requirements it must follow' (
        ($r.Out -match 'MCP used') -and ($r.Out -match 'Skills used')) $r.Out
    Check 'summary: demands failures and untested paths be included' ($r.Out -match 'untested') $r.Out

    # =====================================================================
    Write-Host '--- with no markers there is no gate list at all ---' -ForegroundColor Cyan
    Check 'summary: says nothing about gates when none blocked' ($r.Out -notmatch 'blocked this session') $r.Out

    # =====================================================================
    Write-Host '--- gate markers: this session only ---' -ForegroundColor Cyan
    $null = New-BlockMarker -HookName 'Secrets-Check' -ProjectRoot $proj -SessionId $sid
    $null = New-BlockMarker -HookName 'Ci-Status-Check' -ProjectRoot $proj -SessionId $sid
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: reports that gates blocked this session' ($r.Out -match 'blocked this session') $r.Out
    Check 'summary: names both gates, sorted' ($r.Out -match 'CiStatusCheck, SecretsCheck') $r.Out
    Check 'summary: asks for each blocked gate to be accounted for' ($r.Out -match 'Account for each one') $r.Out

    # A marker left by an EARLIER session in the same project is evidence about
    # that session, not this one. Reporting it would accuse the current session
    # of a block it never hit.
    $null = New-BlockMarker -HookName 'Docs-Freshness-Check' -ProjectRoot $proj -SessionId 'an-older-session'
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: ignores a marker from a different session' ($r.Out -notmatch 'DocsFreshnessCheck') $r.Out
    Check 'summary: still names this session''s own gates' ($r.Out -match 'CiStatusCheck, SecretsCheck') $r.Out

    # A marker for a DIFFERENT project shares the state directory but not the
    # project key, so it must not leak into this project's summary.
    $otherProj = Join-Path $Work 'other-proj'
    New-Item -ItemType Directory -Path $otherProj -Force | Out-Null
    $null = New-BlockMarker -HookName 'Large-File-Check' -ProjectRoot $otherProj -SessionId $sid
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: ignores a marker belonging to another project' ($r.Out -notmatch 'LargeFileCheck') $r.Out

    # =====================================================================
    Write-Host '--- it is read-only: the state directory is not its to write ---' -ForegroundColor Cyan
    $before = @(Get-ChildItem -LiteralPath $StateDir -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Length }) -join '|'
    $null = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    $after = @(Get-ChildItem -LiteralPath $StateDir -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Length }) -join '|'
    Check 'summary: leaves every marker byte-for-byte untouched' ($before -eq $after) ($before + ' -> ' + $after)
    # It writes exactly ONE file of its own: the once-per-session delivery
    # marker that stops it re-asking on every Stop. Anything BEYOND that would
    # mean it had started keeping state it has no business keeping - the
    # sibling gates' StopBlock markers are read-only to it, asserted above.
    Check 'summary: writes only its own delivery marker, nothing else' (
        @(Get-ChildItem -LiteralPath $StateDir -File | Where-Object {
                $_.Name -notlike 'StopBlock-*' -and $_.Name -notlike 'SessionSummary-*'
            }).Count -eq 0) $after

    # =====================================================================
    # =====================================================================
    Write-Host '--- once per session: the loop this hook caused in production ---' -ForegroundColor Cyan
    # An earlier revision emitted on EVERY Stop. Other gates block, the agent
    # works and stops again, this hook re-asks for the summary, and the agent
    # rewrites the whole DONE/REMAINING block. The user saw it four times in
    # one turn. The requirement only has to arrive once.
    $loopProj = Join-Path $Work 'loop-proj'
    New-Item -ItemType Directory -Path $loopProj -Force | Out-Null
    $first = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $loopProj; session_id = 'loop-a' }
    Check 'summary: the first Stop of a session delivers the requirement' ($first.Out -match 'SESSION SUMMARY') $first.Out
    $second = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'Stop'; cwd = $loopProj; session_id = 'loop-a' }
    Check 'summary: a SECOND Stop of the same session says nothing' ($second.Out.Trim() -eq '') $second.Out
    $third = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'Stop'; cwd = $loopProj; session_id = 'loop-a' }
    Check 'summary: a THIRD Stop stays silent too (no slow re-arming)' ($third.Out.Trim() -eq '') $third.Out
    # ...but a genuinely new session must still be told, or the guard would
    # simply have disabled the hook after its first use ever.
    $newSession = Invoke-SummaryHook -KeepDelivered -Payload @{ hook_event_name = 'Stop'; cwd = $loopProj; session_id = 'loop-b' }
    Check 'summary: a NEW session is told again' ($newSession.Out -match 'SESSION SUMMARY') $newSession.Out
    # stop_hook_active must not be used as the key: it is set for ANY gate's
    # block, so honouring it would skip the first Stop whenever another gate
    # happened to fire first.
    $flagged = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $loopProj; session_id = 'loop-c'; stop_hook_active = $true }
    Check 'summary: a first Stop still delivers even when another gate blocked' ($flagged.Out -match 'SESSION SUMMARY') $flagged.Out
    Write-Host '--- client output shapes ---' -ForegroundColor Cyan
    $r = Invoke-SummaryHook -Payload @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid } -AsClaude
    Check 'summary: Claude gets model-visible additionalContext' (
        ($r.Out -match 'hookSpecificOutput') -and ($r.Out -match 'additionalContext')) $r.Out
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid }
    Check 'summary: Codex gets systemMessage' ($r.Out -match 'systemMessage') $r.Out

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
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj }
    Check 'summary: no session id still yields the requirement' ($r.Out -match 'SESSION SUMMARY') $r.Out
    Check 'summary: no session id names no gates rather than guessing' ($r.Out -notmatch 'blocked this session') $r.Out

    # An empty marker must not match an empty/absent session id and quietly
    # report a gate that never blocked.
    $null = New-BlockMarker -HookName 'Rules-Check' -ProjectRoot $proj -SessionId ''
    $r = Invoke-SummaryHook @{ hook_event_name = 'Stop'; cwd = $proj }
    Check 'summary: an empty marker is not matched by a missing session id' ($r.Out -notmatch 'RulesCheck') $r.Out

    # A state directory that does not exist yet is the normal first-run case.
    $emptyLocal = Join-Path $Work 'localappdata-empty'
    New-Item -ItemType Directory -Path $emptyLocal -Force | Out-Null
    $prevLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $emptyLocal
    try {
        $json = (@{ hook_event_name = 'Stop'; cwd = $proj; session_id = $sid } | ConvertTo-Json -Compress)
        $out = ($json | & pwsh -NoProfile -File $Hook 2>&1) -join "`n"
        Check 'summary: no state directory at all is not an error' (($LASTEXITCODE -eq 0) -and ($out -match 'SESSION SUMMARY')) ($out + ' exit=' + $LASTEXITCODE)
    }
    finally { $env:LOCALAPPDATA = $prevLocal }

    # =====================================================================
    Write-Host '--- parses under Windows PowerShell 5.1 as well as pwsh 7 ---' -ForegroundColor Cyan
    # The hook ships to both hosts, so a pwsh-only construct is a real defect.
    $parse = powershell.exe -NoLogo -NoProfile -Command "`$e=`$null; `$null=[System.Management.Automation.Language.Parser]::ParseFile('$Hook',[ref]`$null,[ref]`$e); if(`$e -and `$e.Count){'FAIL'}else{'OK'}"
    Check 'summary: parses under Windows PowerShell 5.1' (([string]$parse).Trim() -eq 'OK') ([string]$parse)

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
