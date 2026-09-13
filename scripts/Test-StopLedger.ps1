# Offline test suite for the Stop delivery/continuation ledger in
# hooks\_stoplib.ps1, and for the three helpers in hooks\_hooklib.ps1 that
# route through it.
#
# What it pins (F01): the old guard was ONE file per project+hook holding a
# single session id. Two sessions overwrote each other's marker, so alternating
# A/B defeated it in both directions - each session's continuation Stop read the
# other's id, concluded "not mine" and blocked again. The audit model produced
# 60 consecutive blocks with the underlying findings never changing.
#
# What it pins (F02): a session id is not a task id and not an agent id. A later
# task in the same session inherited the earlier task's suppression, and a parent
# and its subagent share a session while needing separate evidence.
#
# Cost: no child processes and no real hook invocation - the helpers are called
# directly against a scratch LOCALAPPDATA. That is the cheapest tier that still
# fails when the identity or the budget is wrong.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-StopLedger.ps1
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_testlib.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray }
    }
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-ledger-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $Work -Force)
$savedLocalAppData = $env:LOCALAPPDATA
$savedBudget = $env:HOOKMAKER_STOP_CORRECTION_BUDGET
$env:LOCALAPPDATA = $Work

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\_hooklib.ps1')

function New-StopInput {
    param([string]$Session, [bool]$Continuation, [string]$Agent = '', [string]$Event = 'Stop', [string]$Cwd = 'C:\proj\alpha')
    $o = [pscustomobject]@{
        session_id       = $Session
        cwd              = $Cwd
        stop_hook_active = $Continuation
        hook_event_name  = $Event
    }
    if ($Agent -ne '') { Add-Member -InputObject $o -NotePropertyName 'agent_transcript_path' -NotePropertyValue $Agent }
    return $o
}

Check 'the ledger module loaded (these assertions are about the ledger, not the fallback)' ($script:StopLedgerReady -eq $true) ('StopLedgerReady=' + [string]$script:StopLedgerReady)

# ---- F01: two sessions must not overwrite each other ----------------------
$a = New-StopInput -Session 'AAA' -Continuation $false
$b = New-StopInput -Session 'BBB' -Continuation $false
Check 'a fresh Stop arms the gate' ((Test-StopStandDown -HookInput $a -HookName 'Rules-Check') -eq $false)
Set-StopBlockMarker -HookInput $a -HookName 'Rules-Check'
Check 'a second session is armed on its own fresh Stop' ((Test-StopStandDown -HookInput $b -HookName 'Rules-Check') -eq $false)
Set-StopBlockMarker -HookInput $b -HookName 'Rules-Check'

$aCont = New-StopInput -Session 'AAA' -Continuation $true
$bCont = New-StopInput -Session 'BBB' -Continuation $true
Check 'session A stands down on its own continuation although B blocked after it' ((Test-StopStandDown -HookInput $aCont -HookName 'Rules-Check') -eq $true)
Check 'session B stands down on its own continuation' ((Test-StopStandDown -HookInput $bCont -HookName 'Rules-Check') -eq $true)

# The defect itself: alternate the two sessions and neither may ever re-arm.
$reArmed = 0
for ($i = 0; $i -lt 8; $i++) {
    if (-not (Test-StopStandDown -HookInput $aCont -HookName 'Rules-Check')) { $reArmed++ }
    if (-not (Test-StopStandDown -HookInput $bCont -HookName 'Rules-Check')) { $reArmed++ }
}
Check 'alternating A/B never re-arms either gate (the 60-block loop)' ($reArmed -eq 0) ('re-armed ' + [string]$reArmed + ' time(s)')

# A gate that has NOT spoken still gets its turn - the narrow rule this whole
# mechanism exists to preserve.
Check 'a gate that has not spoken still gets its turn on a continuation' ((Test-StopStandDown -HookInput $aCont -HookName 'Secrets-Check') -eq $false)

# Projects are isolated: the same session in another project is a fresh start.
$other = New-StopInput -Session 'AAA' -Continuation $true -Cwd 'C:\proj\beta'
Check 'another project is not muted by this one' ((Test-StopStandDown -HookInput $other -HookName 'Rules-Check') -eq $false)

# ---- F02: session id is not agent id, and not task id --------------------
$sub = New-StopInput -Session 'AAA' -Continuation $true -Agent 'C:\t\child.jsonl' -Event 'SubagentStop'
Check 'a subagent sharing the session is not muted by the parent block' ((Test-StopStandDown -HookInput $sub -HookName 'Rules-Check') -eq $false)
Set-StopBlockMarker -HookInput $sub -HookName 'Rules-Check'
Check 'the subagent then stands down on its own re-entry' ((Test-StopStandDown -HookInput $sub -HookName 'Rules-Check') -eq $true)
Check 'the parent is still standing down independently' ((Test-StopStandDown -HookInput $aCont -HookName 'Rules-Check') -eq $true)

$sub2 = New-StopInput -Session 'AAA' -Continuation $true -Agent 'C:\t\other-child.jsonl' -Event 'SubagentStop'
Check 'a SECOND subagent is independent of the first' ((Test-StopStandDown -HookInput $sub2 -HookName 'Rules-Check') -eq $false)

# A genuine, non-continuation Stop is the task boundary: it rotates the chain.
# Deliberately NOT keyed on UserPromptSubmit or a turn id - on Codex a Stop block
# generates a continuation that arrives as a new user prompt, so resetting there
# would refund the budget the block just spent and restore the loop.
$aNew = New-StopInput -Session 'AAA' -Continuation $false
Check 'a genuine non-continuation Stop re-arms the gate for a new task' ((Test-StopStandDown -HookInput $aNew -HookName 'Rules-Check') -eq $false)

# ---- F01: the correction budget is finite and shared ---------------------
$env:HOOKMAKER_STOP_CORRECTION_BUDGET = '3'
$c = New-StopInput -Session 'CCC' -Continuation $false
$cCont = New-StopInput -Session 'CCC' -Continuation $true
Set-StopBlockMarker -HookInput $c -HookName 'G1'
Set-StopBlockMarker -HookInput $cCont -HookName 'G2'
Check 'below budget, an unspoken gate still gets its turn' ((Test-StopStandDown -HookInput $cCont -HookName 'G-unspoken') -eq $false)
Set-StopBlockMarker -HookInput $cCont -HookName 'G3'
Check 'budget spent: even an unspoken gate stands down, ending the chain' ((Test-StopStandDown -HookInput $cCont -HookName 'G-never-spoke') -eq $true)
Check 'the budget is shared across cooperating gates, not per gate' ((Test-StopStandDown -HookInput $cCont -HookName 'G-another') -eq $true)
$env:HOOKMAKER_STOP_CORRECTION_BUDGET = $savedBudget

# ---- unavailable persistence degrades honestly, never into a loop --------
$blocked = New-StopInput -Session 'DDD' -Continuation $true -Cwd 'C:\proj\gamma'
$savedRoot = $env:LOCALAPPDATA
# A FILE where the state directory must go: New-Item -Force happily creates a
# deep new path, so 'a path that does not exist' is not unwritable at all.
$blocker = Join-Path $Work 'blocker.dat'
[System.IO.File]::WriteAllText($blocker, 'x')
$env:LOCALAPPDATA = $blocker
Check 'an unwritable ledger stands the gate DOWN rather than looping' ((Test-StopStandDown -HookInput $blocked -HookName 'Rules-Check') -eq $true)
$env:LOCALAPPDATA = $savedRoot

# ---- negative control ----------------------------------------------------
# Without this, a Test-StopStandDown that returned a constant $true would pass
# most of the assertions above.
$fresh = New-StopInput -Session 'ZZZ' -Continuation $false -Cwd 'C:\proj\delta'
Check 'negative control: a never-seen gate in a never-seen project is ARMED' ((Test-StopStandDown -HookInput $fresh -HookName 'Never-Seen') -eq $false)

$env:LOCALAPPDATA = $savedLocalAppData
if (-not $KeepArtifacts) {
    if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++; Write-Host '[FAIL] workspace cleanup left files behind' -ForegroundColor Red }
}
else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
