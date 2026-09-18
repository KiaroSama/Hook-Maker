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
# MID-TASK, a corrupt ledger must NOT be rebuilt: an empty document has
# blocks = 0, so rebuilding one here refunds the allowance the chain already
# spent and restores the very loop it bounds.
$cIn = New-StopInput -Session 'COR' -Continuation $true -Cwd $corProj
$cAdmit = Set-StopBlockMarker -HookInput $cIn -HookName 'Rules-Check'
Check 'a corrupt ledger REFUSES admission during a continuation (no refund)' (
    -not $cAdmit.Admitted -and $cAdmit.Reason -eq 'ledger-corrupt') ([string]$cAdmit.Reason)
Check 'and the refusal is reported as degraded, not as policy' ($cAdmit.Degraded -eq $true) ([string]$cAdmit.Reason)
Check 'the damaged file is left alone mid-task, not silently replaced' (
    ([System.IO.File]::ReadAllText($corLedger)) -eq '{ this is not json')
$corStorm = 0
foreach ($n in 1..8) { if ((Set-StopBlockMarker -HookInput $cIn -HookName ('COR' + $n)).Admitted) { $corStorm++ } }
Check 'eight more gates on the corrupt ledger admit ZERO continuations' ($corStorm -eq 0) ('admitted=' + $corStorm)

# AT A TASK BOUNDARY the same damage is recoverable: a genuine Stop is already
# entitled to a fresh chain, so quarantining costs nothing and stops the
# project being wedged for ever.
$cFresh = New-StopInput -Session 'COR' -Continuation $false -Cwd $corProj
$cFreshAdmit = Set-StopBlockMarker -HookInput $cFresh -HookName 'Rules-Check'
Check 'a genuine Stop recovers from the damage and admits' ($cFreshAdmit.Admitted) ([string]$cFreshAdmit.Reason)
Check 'the damaged file was quarantined, not deleted' (
    @(Get-ChildItem -LiteralPath (Split-Path -Parent $corLedger) -Filter '*.corrupt-*' -File -ErrorAction SilentlyContinue).Count -ge 1)
$corOk = $false
try { $corOk = ($null -ne ((Get-Content -LiteralPath $corLedger -Raw) | ConvertFrom-Json)) } catch { $corOk = $false }
Check 'and the replacement ledger is valid JSON on disk' ($corOk) (Get-Content -LiteralPath $corLedger -Raw)
Check 'the gate is then suppressed on its next continuation' (
    (Test-StopStandDown -HookInput $cIn -HookName 'Rules-Check') -eq $true)

# A ledger from a NEWER build is not damaged and is never rewritten.
$futProj = 'C:\projuture'
$futLedger = Get-StopLedgerPath -ProjectRoot $futProj
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $futLedger) -Force)
[System.IO.File]::WriteAllText($futLedger, '{"version":99,"chains":{},"entries":{},"unresolved":{}}')
$futIn = New-StopInput -Session 'FUT' -Continuation $false -Cwd $futProj
$futAdmit = Set-StopBlockMarker -HookInput $futIn -HookName 'Rules-Check'
Check 'a FUTURE-schema ledger refuses admission rather than being reset' (
    -not $futAdmit.Admitted -and $futAdmit.Reason -eq 'ledger-unsupported') ([string]$futAdmit.Reason)
Check 'and the newer build''s ledger is left byte-for-byte alone' (
    ([System.IO.File]::ReadAllText($futLedger)) -match '"version":99')

# ---- R01: a refusal is recorded, not forgotten --------------------------
$hist = @(Get-StopUnresolvedHistory -ProjectRoot 'C:\proj\budget')
Check 'spending the allowance leaves the findings recorded as unresolved' (
    $hist.Count -gt 0 -and @($hist | Where-Object { $_.Reason -eq 'budget-spent' }).Count -gt 0) ('entries=' + $hist.Count)
Check 'negative control: a project with no gate history reports nothing' (
    @(Get-StopUnresolvedHistory -ProjectRoot 'C:\proj\never-touched').Count -eq 0)

# ---- L01: the finalization barrier -------------------------------------
# The user's complaint, verbatim: the wrap-up 'does not come at the very end -
# then a few more hooks arrive, and it repeats'. A gate blocks after the answer,
# the agent corrects and writes a SECOND wrap-up, the next gate blocks again.
Check 'a real wrap-up is recognised (both labels, each starting a line)' (
    Test-ClosingSummaryPublished -Text "All set.`nDONE`n- shipped X`nREMAINING`n- nothing")
Check 'the JSONL escape form counts as a line start too' (
    Test-ClosingSummaryPublished -Text 'All set.
DONE
- shipped X
REMAINING
- nothing')
Check 'markdown bold/bullet decoration does not hide it' (
    Test-ClosingSummaryPublished -Text "x`n**DONE**`ny`n**REMAINING**`nz")
Check 'NEGATIVE: prose that merely mentions the words is not a wrap-up' (
    -not (Test-ClosingSummaryPublished -Text 'I will write DONE and REMAINING at the end.'))
Check 'NEGATIVE: only one of the two labels is not a wrap-up' (
    -not (Test-ClosingSummaryPublished -Text "x`nDONE`n- shipped"))
Check 'NEGATIVE: empty text is not a wrap-up' (-not (Test-ClosingSummaryPublished -Text ''))

# The clause a blocking gate appends. Two forms, and picking the wrong one is
# exactly what produced the repeats.
$finProj = 'C:\projinalize'
$finFresh = New-StopInput -Session 'FIN' -Continuation $false -Cwd $finProj
$clauseBefore = Get-StopFinalizationClause -HookInput $finFresh
Check 'before any wrap-up, the clause says it belongs in the LAST message' (
    $clauseBefore -match 'after which nothing blocks') $clauseBefore
Check 'and it forbids writing one in this correction turn' (
    $clauseBefore -match 'do not write the DONE / REMAINING wrap-up in this correction turn') $clauseBefore

# Now the agent HAS published one - the event carries its own final answer.
$finPublished = New-StopInput -Session 'FIN' -Continuation $true -Cwd $finProj
Add-Member -InputObject $finPublished -NotePropertyName 'last_assistant_message' -NotePropertyValue "Fixed it.`nDONE`n- pushed`nREMAINING`n- nothing"
$clauseAfter = Get-StopFinalizationClause -HookInput $finPublished
Check 'once published, the clause REFUSES a second wrap-up' (
    $clauseAfter -match 'Do NOT write a second wrap-up') $clauseAfter
Check 'and it names this a correction turn' ($clauseAfter -match 'CORRECTION turn') $clauseAfter

# The state is REMEMBERED: a later block in the same task still refuses, even
# when that later event carries no closing text of its own.
$null = Set-StopBlockMarker -HookInput $finPublished -HookName 'Gate-A'
$finLater = New-StopInput -Session 'FIN' -Continuation $true -Cwd $finProj
$clauseLater = Get-StopFinalizationClause -HookInput $finLater
Check 'a later gate with no closing text still knows the wrap-up was published' (
    $clauseLater -match 'Do NOT write a second wrap-up') $clauseLater

# A DIFFERENT task must start clean - the refusal is per task, not per project.
$finOther = New-StopInput -Session 'FIN-OTHER' -Continuation $false -Cwd $finProj
Check 'a different task is not held to another task''s published wrap-up' (
    (Get-StopFinalizationClause -HookInput $finOther) -match 'after which nothing blocks')

# And the clause actually reaches the user: every gate emits through this path.
$finEmitProj = 'C:\projinalize-emit'
$finEmit = New-StopInput -Session 'EMIT' -Continuation $false -Cwd $finEmitProj
Add-Member -InputObject $finEmit -NotePropertyName 'last_assistant_message' -NotePropertyValue "Shipped.`nDONE`n- a`nREMAINING`n- b"
$emitted = Write-StopBlockResult -HookInput $finEmit -HookName 'Gate-Emit' -EventName 'Stop' -Reason 'ORIGINAL GATE TEXT'
Check 'the block was emitted' ($emitted.Emitted -eq $true) ([string]$emitted.ExitCode)

# ---- L05: a closing declaration must CLAIM something, not just look like one
# The three closing gates tested for a PREFIX. 'MCP used:' with nothing after
# it satisfied the gate, so did a bare 'none', and so did a line inside a
# fenced block the agent wrote to SHOW the format rather than to claim it.
Check 'the evidence library loaded beside the ledger' ($script:EvidenceLibReady -eq $true)

$mcpLabel = 'MCP[ 	]+(?:servers?[ 	]+|tools?[ 	]+)?used'
$decCases = @(
    @{ Name = 'a real list is substantive'; Text = "done`nMCP used: synapse, github"; Want = $true }
    @{ Name = 'the JSONL escape form counts as a line start'; Text = 'done
MCP used: synapse'; Want = $true }
    @{ Name = 'bold decoration does not hide it'; Text = "done`n**MCP used:** synapse"; Want = $true }
    @{ Name = 'none WITH a reason is a real answer'; Text = "done`nMCP used: none - nothing the task needed"; Want = $true }
    @{ Name = 'an EMPTY declaration claims nothing'; Text = "done`nMCP used:"; Want = $false }
    @{ Name = 'whitespace only claims nothing'; Text = "done`nMCP used:    "; Want = $false }
    @{ Name = 'a bare none claims nothing'; Text = "done`nMCP used: none"; Want = $false }
    @{ Name = 'none with only a dash claims nothing'; Text = "done`nMCP used: none -"; Want = $false }
    @{ Name = 'a bracketed template is a placeholder'; Text = "done`nMCP used: <server names>"; Want = $false }
    @{ Name = 'TBD is a placeholder'; Text = "done`nMCP used: TBD"; Want = $false }
    @{ Name = 'the label never appearing is absent, not substantive'; Text = 'done, nothing to report'; Want = $false }
)
foreach ($c in $decCases) {
    $d = Test-ClosingDeclaration -Text $c.Text -LabelPattern $mcpLabel
    Check ('declaration: ' + $c.Name) ([bool]$d.Substantive -eq [bool]$c.Want) (
        'substantive=' + [string]$d.Substantive + ' reason=' + [string]$d.Reason)
}

# A FENCED example is the format being shown, not a claim being made.
$fenced = "Here is the shape:`n``````n MCP used: synapse`n```````nI have not finished yet."
$fencedResult = Test-ClosingDeclaration -Text $fenced -LabelPattern $mcpLabel
Check 'a declaration inside a fenced example does not count as a claim' (
    -not $fencedResult.Substantive) ('reason=' + [string]$fencedResult.Reason)

# A real claim AFTER a fenced example still counts - the fence skips one match,
# it does not disable the check.
$afterFence = "Shape:`n``````n MCP used: <names>`n```````ndone`nMCP used: synapse, github"
Check 'a real claim after a fenced example is still found' (
    (Test-ClosingDeclaration -Text $afterFence -LabelPattern $mcpLabel).Substantive)

# The capture stops at the line, so a name mentioned in later prose is not
# swallowed into the claim.
$laterProse = 'done
MCP used:
I considered synapse and did not use it.'
Check 'prose on the NEXT line is not absorbed into an empty declaration' (
    -not (Test-ClosingDeclaration -Text $laterProse -LabelPattern $mcpLabel).Substantive)

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
