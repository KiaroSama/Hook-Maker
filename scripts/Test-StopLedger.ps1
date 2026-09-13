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
$null = Set-StopBlockMarker -HookInput $a -HookName 'Rules-Check'
Check 'a second session is armed on its own fresh Stop' ((Test-StopStandDown -HookInput $b -HookName 'Rules-Check') -eq $false)
$null = Set-StopBlockMarker -HookInput $b -HookName 'Rules-Check'

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
$null = Set-StopBlockMarker -HookInput $sub -HookName 'Rules-Check'
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
$null = Set-StopBlockMarker -HookInput $c -HookName 'G1'
$null = Set-StopBlockMarker -HookInput $cCont -HookName 'G2'
Check 'below budget, an unspoken gate still gets its turn' ((Test-StopStandDown -HookInput $cCont -HookName 'G-unspoken') -eq $false)
$null = Set-StopBlockMarker -HookInput $cCont -HookName 'G3'
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

# ---- R01: admission is ATOMIC and scoped to ONE event -------------------
# Two gates processing the SAME initial event each rotated the chain, so the
# second rotation invalidated the first gate's reservation and the pair could
# block for ever. The event identity comes from the transcript, so build one.
$evtTranscript = Join-Path $Work 'evt.jsonl'
[System.IO.File]::WriteAllText($evtTranscript, '{"type":"assistant"}' + "`n")
function New-EventInput {
    param([string]$Session, [bool]$Continuation, [string]$Cwd = 'C:\proj\evt')
    $o = New-StopInput -Session $Session -Continuation $Continuation -Cwd $Cwd
    Add-Member -InputObject $o -NotePropertyName 'transcript_path' -NotePropertyValue $evtTranscript
    return $o
}
$e1 = New-EventInput -Session 'EVT' -Continuation $false
$admit1 = Set-StopBlockMarker -HookInput $e1 -HookName 'Gate-One'
$admit2 = Set-StopBlockMarker -HookInput $e1 -HookName 'Gate-Two'
Check 'two gates on ONE event are both admitted' ($admit1.Admitted -and $admit2.Admitted) ($admit1.Reason + '/' + $admit2.Reason)
$eCont = New-EventInput -Session 'EVT' -Continuation $true
Check 'the FIRST gate stays suppressed after the second registered for the same event' (
    (Test-StopStandDown -HookInput $eCont -HookName 'Gate-One') -eq $true)
Check 'the second gate is suppressed too' ((Test-StopStandDown -HookInput $eCont -HookName 'Gate-Two') -eq $true)

# Duplicate delivery of the same initial event must not re-admit a gate that
# already claimed it - the reservation is per chain, and the chain is per event.
$dup = Set-StopBlockMarker -HookInput $e1 -HookName 'Gate-One'
Check 'duplicate delivery of the same event is refused, not re-admitted' (
    -not $dup.Admitted -and $dup.Reason -eq 'already-claimed') ([string]$dup.Reason)

# A genuinely LATER task appends to the transcript, so its event identity
# differs and the chain rotates - the budget is not inherited.
[System.IO.File]::AppendAllText($evtTranscript, '{"type":"assistant"}' + "`n")
$e2 = New-EventInput -Session 'EVT' -Continuation $false
$admit3 = Set-StopBlockMarker -HookInput $e2 -HookName 'Gate-One'
Check 'a genuinely new task re-admits the same gate' ($admit3.Admitted) ([string]$admit3.Reason)

# ---- R01: the shared allowance cannot be overspent ----------------------
# Checking the budget and reserving against it used to be two separate steps,
# so every contender read the same remaining allowance and every one proceeded.
$env:HOOKMAKER_STOP_CORRECTION_BUDGET = '6'
$bTranscript = Join-Path $Work 'budget.jsonl'
[System.IO.File]::WriteAllText($bTranscript, 'x')
$bIn = New-StopInput -Session 'BUD' -Continuation $false -Cwd 'C:\proj\budget'
Add-Member -InputObject $bIn -NotePropertyName 'transcript_path' -NotePropertyValue $bTranscript
$bCont = New-StopInput -Session 'BUD' -Continuation $true -Cwd 'C:\proj\budget'
Add-Member -InputObject $bCont -NotePropertyName 'transcript_path' -NotePropertyValue $bTranscript
$null = Set-StopBlockMarker -HookInput $bIn -HookName 'B1'
foreach ($n in 2..5) { $null = Set-StopBlockMarker -HookInput $bCont -HookName ('B' + $n) }
$admitted = 0
$refused = 0
foreach ($n in 10..19) {
    $d = Set-StopBlockMarker -HookInput $bCont -HookName ('C' + $n)
    if ($d.Admitted) { $admitted++ } else { $refused++ }
}
Check 'ten contenders at budget-minus-one yield exactly ONE more admission' (
    $admitted -eq 1 -and $refused -eq 9) ('admitted=' + $admitted + ' refused=' + $refused)
$spent = (Get-Content -LiteralPath (Get-StopLedgerPath -ProjectRoot 'C:\proj\budget') -Raw | ConvertFrom-Json)
$chainBlocks = 0
foreach ($p in @($spent.chains.PSObject.Properties)) { $chainBlocks = [int]$p.Value.blocks }
Check 'the counter stops AT the budget instead of overshooting it' ($chainBlocks -eq 6) ('blocks=' + $chainBlocks)
$env:HOOKMAKER_STOP_CORRECTION_BUDGET = $savedBudget

# ---- R01: equivalent path spellings are ONE project ---------------------
Check 'a trailing separator does not create a second ledger' (
    (Get-StopLedgerPath -ProjectRoot 'C:\proj\alpha') -eq (Get-StopLedgerPath -ProjectRoot 'C:\proj\alpha\'))
Check 'forward slashes name the same project' (
    (Get-StopLedgerPath -ProjectRoot 'C:\proj\alpha') -eq (Get-StopLedgerPath -ProjectRoot 'C:/proj/alpha'))
Check 'a relative segment resolves to the same project' (
    (Get-StopLedgerPath -ProjectRoot 'C:\proj\alpha') -eq (Get-StopLedgerPath -ProjectRoot 'C:\proj\beta\..\alpha'))
Check 'negative control: a DIFFERENT project still gets its own ledger' (
    (Get-StopLedgerPath -ProjectRoot 'C:\proj\alpha') -ne (Get-StopLedgerPath -ProjectRoot 'C:\proj\gamma'))

# ---- R02: failed persistence must not re-arm the loop -------------------
# A DIRECTORY on the ledger's own path: the parent stays perfectly writable,
# so every write failed while every continuation stayed admissible.
$dirProj = 'C:\proj\dirblock'
$dirLedger = Get-StopLedgerPath -ProjectRoot $dirProj
[void](New-Item -ItemType Directory -Path $dirLedger -Force)
$dIn = New-StopInput -Session 'DIR' -Continuation $true -Cwd $dirProj
$dAdmit = Set-StopBlockMarker -HookInput $dIn -HookName 'Rules-Check'
Check 'a ledger that cannot be written REFUSES admission' (-not $dAdmit.Admitted) ([string]$dAdmit.Reason)
Check 'the refusal is reported as degraded, not as policy' ($dAdmit.Degraded -eq $true) ([string]$dAdmit.Reason)
$storm = 0
foreach ($n in 1..12) { if ((Set-StopBlockMarker -HookInput $dIn -HookName ('S' + $n)).Admitted) { $storm++ } }
Check 'twelve failed writes admit ZERO continuations (no untracked storm)' ($storm -eq 0) ('admitted=' + $storm)
Check 'the read-only hint stands the gate down too' ((Test-StopStandDown -HookInput $dIn -HookName 'Rules-Check') -eq $true)
Remove-Item -LiteralPath $dirLedger -Recurse -Force -ErrorAction SilentlyContinue

# A corrupt ledger is rebuilt, never read as spending - but it must also never
# be presented as a clean new task while the write path is broken.
$corProj = 'C:\proj\corrupt'
$corLedger = Get-StopLedgerPath -ProjectRoot $corProj
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $corLedger) -Force)
[System.IO.File]::WriteAllText($corLedger, '{ this is not json')
$cIn = New-StopInput -Session 'COR' -Continuation $true -Cwd $corProj
$cAdmit = Set-StopBlockMarker -HookInput $cIn -HookName 'Rules-Check'
Check 'a corrupt ledger still admits (rebuilt), and the write succeeds' ($cAdmit.Admitted) ([string]$cAdmit.Reason)
$corOk = $false
try { $corOk = ($null -ne ((Get-Content -LiteralPath $corLedger -Raw) | ConvertFrom-Json)) } catch { $corOk = $false }
Check 'the rebuilt ledger is valid JSON on disk' ($corOk) (Get-Content -LiteralPath $corLedger -Raw)
Check 'and the gate is suppressed on its next continuation' (
    (Test-StopStandDown -HookInput $cIn -HookName 'Rules-Check') -eq $true)

# ---- R01: a refusal is recorded, not forgotten --------------------------
$hist = @(Get-StopUnresolvedHistory -ProjectRoot 'C:\proj\budget')
Check 'spending the allowance leaves the findings recorded as unresolved' (
    $hist.Count -gt 0 -and @($hist | Where-Object { $_.Reason -eq 'budget-spent' }).Count -gt 0) ('entries=' + $hist.Count)
Check 'negative control: a project with no gate history reports nothing' (
    @(Get-StopUnresolvedHistory -ProjectRoot 'C:\proj\never-touched').Count -eq 0)

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
