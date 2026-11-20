# Offline test suite for Synapse-Rules-Check.
#
# The hook is ADVISORY and holds no MCP client, so what is worth testing is not
# "did it read Synapse" - it never does - but the four decisions it actually
# makes: is Synapse present at all, which event it is on, was the store
# consulted this session, and has this exact answer already been given.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-SynapseRulesCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Synapse-Rules-Check\Synapse-Rules-Check.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 600
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-synapsetest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

# A fake USERPROFILE is what makes the relevance gate testable in BOTH
# directions: the hook looks for %USERPROFILE%\.synapse\synapse.db, so a
# workspace-local profile can present or withhold a store on demand without
# touching the real one.
$FakeProfileWith = Join-Path $Work '_profile-with'
$FakeProfileWithout = Join-Path $Work '_profile-without'
New-Item -ItemType Directory -Path (Join-Path $FakeProfileWith '.synapse') -Force | Out-Null
New-Item -ItemType Directory -Path $FakeProfileWithout -Force | Out-Null
Write-Utf8 (Join-Path $FakeProfileWith '.synapse\synapse.db') 'not a real database - only its EXISTENCE is the signal'

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

function Fire {
    param(
        [string]$Cwd,
        [string]$EventName = 'SessionStart',
        [string]$SessionId = 't',
        [string]$Profile = '',
        [string]$TranscriptPath = '',
        [switch]$StopHookActive,
        [string]$Exe = 'pwsh'
    )
    if ($Profile -eq '') { $Profile = $FakeProfileWith }
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    if ($TranscriptPath -ne '') { $obj['transcript_path'] = $TranscriptPath }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    Write-Utf8 $inFile $payload
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $Hook + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"' }
    $startArgs = @{
        FilePath               = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait                   = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData; USERPROFILE = $Profile }
    }
    $proc = Start-BoundedProcess @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# A transcript is only ever read as a bounded TAIL, so a fixture that needs the
# marker to be found must put it at the END - which is also how a real one
# behaves once the session grows past the window.
function New-Transcript {
    param([string]$Name, [string]$Body, [int]$PadKb = 0)
    $path = Join-Path $Work $Name
    $text = ''
    if ($PadKb -gt 0) { $text = ('x' * 1024 * $PadKb) + "`n" }
    Write-Utf8 $path ($text + $Body)
    return $path
}

try {
    if (-not (Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        Write-Host 'Start-Process has no -Environment on this host; the suite cannot redirect USERPROFILE.' -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host '--- the relevance gate: no Synapse on this machine, no output ---' -ForegroundColor Cyan
    # The single most important behaviour: a project on a host without Synapse
    # must never see this hook at all, on any event.
    $proj = New-Proj 'Project'
    $rNoneStart = Fire -Cwd $proj -EventName 'SessionStart' -Profile $FakeProfileWithout
    Check 'no store: SessionStart is silent and clean' ($rNoneStart.Exit -eq 0 -and $rNoneStart.Out -eq '') ($rNoneStart.Out + $rNoneStart.Err)
    $rNoneStop = Fire -Cwd $proj -EventName 'Stop' -Profile $FakeProfileWithout
    Check 'no store: Stop is silent too' ($rNoneStop.Exit -eq 0 -and $rNoneStop.Out -eq '') ($rNoneStop.Out + $rNoneStop.Err)

    Write-Host ''
    Write-Host '--- SessionStart: the instruction and the measured settings ---' -ForegroundColor Cyan
    $rStart = Fire -Cwd $proj -EventName 'SessionStart' -SessionId 's-start'
    Check 'start: it fires when a store exists' ($rStart.Exit -eq 0 -and $rStart.Out -match 'Synapse-Rules-Check: ENFORCED at Stop') ($rStart.Out + $rStart.Err)
    Check 'start: it names memory_digest and the tokenBudget' (
        $rStart.Out -match 'memory_digest' -and $rStart.Out -match 'tokenBudget') $rStart.Out
    Check 'start: it says to index BEFORE reading the digest' ($rStart.Out -match 'memory_digest once with tokenBudget, index id/type/preview then full task matches') $rStart.Out
    # The two settings this store measured and that are easy to get wrong.
    Check 'start: it carries the 0.65 threshold' ($rStart.Out -match '0\.65') $rStart.Out
    Check 'start: it warns against minScore together with tags' (
        $rStart.Out -match 'minScore0.65 OR project:<slug> tags, never both') $rStart.Out
    Check 'start: recall is not policy or consent' (
        $rStart.Out -match 'Recall != canonical policy or consent') $rStart.Out
    Check 'start: it names Synapse: none - <reason>' ($rStart.Out -match 'Synapse: none - <reason>') $rStart.Out
    Check 'start: nothing is written to stderr' ($rStart.Err -eq '') $rStart.Err

    Write-Host ''
    Write-Host '--- UserPromptSubmit: one mid-session note, only after unread file changes ---' -ForegroundColor Cyan
    $wroteUnread = New-Transcript 'transcript-wrote.jsonl' '{"type":"tool_use","name":"Write","input":{}}'
    $midProj = New-Proj 'MidSession'
    $rMid = Fire -Cwd $midProj -EventName 'UserPromptSubmit' -SessionId 's-mid' -TranscriptPath $wroteUnread
    Check 'mid: files changed and the store unread -> the one mid-session note' (
        $rMid.Exit -eq 0 -and $rMid.Out -match 'files changed without store read' -and $rMid.Out -match 'memory_digest') ($rMid.Out + $rMid.Err)
    $rMidAgain = Fire -Cwd $midProj -EventName 'UserPromptSubmit' -SessionId 's-mid' -TranscriptPath $wroteUnread
    Check 'mid: the same session is never told twice' ($rMidAgain.Exit -eq 0 -and $rMidAgain.Out -eq '') $rMidAgain.Out
    $rQuiet = Fire -Cwd (New-Proj 'MidQuiet') -EventName 'UserPromptSubmit' -SessionId 's-quiet' -TranscriptPath (New-Transcript 'transcript-read-only.jsonl' '{"type":"tool_use","name":"Read","input":{}}')
    Check 'mid: a session with no file-changing call is silent (no per-prompt noise)' ($rQuiet.Exit -eq 0 -and $rQuiet.Out -eq '') $rQuiet.Out
    $wroteRead = New-Transcript 'transcript-wrote-read.jsonl' ('{"type":"tool_use","name":"Write","input":{}}' + "`n" + '{"type":"tool_use","name":"mcp__synapse__memory_digest","input":{}}')
    $rRead = Fire -Cwd (New-Proj 'MidRead') -EventName 'UserPromptSubmit' -SessionId 's-read' -TranscriptPath $wroteRead
    Check 'mid: a session that read the store is silent' ($rRead.Exit -eq 0 -and $rRead.Out -eq '') $rRead.Out
    # The hook's own earlier words land in the transcript as an escaped string;
    # they are prose, never the client's tool-call record, so they prove nothing.
    $ownNote = New-Transcript 'transcript-own-note.jsonl' (@{ type = 'attachment'; content = $rMid.Out } | ConvertTo-Json -Compress)
    $rOwn = Fire -Cwd (New-Proj 'MidOwn') -EventName 'UserPromptSubmit' -SessionId 's-own' -TranscriptPath $ownNote
    Check 'mid: the hook''s own earlier note never counts as a file change' ($rOwn.Exit -eq 0 -and $rOwn.Out -eq '') $rOwn.Out
    $rMidNone = Fire -Cwd (New-Proj 'MidNone') -EventName 'UserPromptSubmit' -SessionId 's-none' -Profile $FakeProfileWithout -TranscriptPath $wroteUnread
    Check 'mid: no store -> silent' ($rMidNone.Exit -eq 0 -and $rMidNone.Out -eq '') $rMidNone.Out

    Write-Host ''
    Write-Host '--- Stop gate: read and write duties over the complete transcript (spec 037) ---' -ForegroundColor Cyan
    # Real client record shapes: tool_use parts inside assistant messages, the
    # closing reply as the last assistant text.
    function New-GateTranscript {
        param([string]$Name, [string]$Root, [string[]]$Steps, [string]$FinalText = 'Done.')
        $entries = New-Object System.Collections.Generic.List[string]
        [void]$entries.Add((@{ type = 'user'; message = @{ role = 'user'; content = 'fix the parser' } } | ConvertTo-Json -Depth 8 -Compress))
        foreach ($s in @($Steps)) {
            if ($s -like 'edit:*') { $part = @{ type = 'tool_use'; name = 'Edit'; input = @{ file_path = (Join-Path $Root $s.Substring(5)) } } }
            else { $part = @{ type = 'tool_use'; name = ('mcp__synapse__memory_' + $s); input = @{} } }
            [void]$entries.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @($part) } } | ConvertTo-Json -Depth 8 -Compress))
        }
        [void]$entries.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = $FinalText }) } } | ConvertTo-Json -Depth 8 -Compress))
        $path = Join-Path $Work ($Name + '.jsonl')
        [System.IO.File]::WriteAllText($path, (($entries.ToArray() -join "`n") + "`n"))
        return $path
    }
    $blockPattern = '"decision"\s*:\s*"block"'
    $g = New-Proj 'GateNoRead'
    $rNoRead = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-noread' -TranscriptPath (New-GateTranscript 'g-noread' $g @('edit:src\a.ps1'))
    Check 'gate: edits with no Synapse call -> blocked' ($rNoRead.Out -match $blockPattern -and $rNoRead.Out -match 'SYNAPSE RULES CHECK') ($rNoRead.Out + $rNoRead.Err)
    Check 'gate: the block names the read duty and memory_digest' ($rNoRead.Out -match 'Read duty' -and $rNoRead.Out -match 'memory_digest') $rNoRead.Out
    Check 'gate: the block also names the write duty and the opt-out line' ($rNoRead.Out -match 'Write duty' -and $rNoRead.Out -match 'Synapse: none - <reason>') $rNoRead.Out
    $rAgain = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-noread' -TranscriptPath (New-GateTranscript 'g-noread2' $g @('edit:src\a.ps1'))
    Check 'gate: an unchanged outcome is not refused twice' ($rAgain.Out -notmatch $blockPattern) $rAgain.Out

    $g = New-Proj 'GateReadNoWrite'
    $rNoWrite = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-nowrite' -TranscriptPath (New-GateTranscript 'g-nowrite' $g @('digest', 'edit:src\a.ps1'))
    Check 'gate: read first, no write, no opt-out -> blocked on the write duty only' (
        $rNoWrite.Out -match $blockPattern -and $rNoWrite.Out -match 'Write duty' -and $rNoWrite.Out -notmatch 'Read duty') $rNoWrite.Out

    $g = New-Proj 'GateWrote'
    $rWrote = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-wrote' -TranscriptPath (New-GateTranscript 'g-wrote' $g @('retrieve', 'edit:src\a.ps1', 'write'))
    Check 'gate: read first + memory_write -> silent' ($rWrote.Exit -eq 0 -and $rWrote.Out -eq '') ($rWrote.Out + $rWrote.Err)

    $g = New-Proj 'GateOptOut'
    $rOpt = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-opt' -TranscriptPath (New-GateTranscript 'g-opt' $g @('digest', 'edit:src\a.ps1') "Fixed it.`nSynapse: no durable learning - a one-line typo fix")
    Check 'gate: a reasoned opt-out line clears the write duty' ($rOpt.Exit -eq 0 -and $rOpt.Out -eq '') ($rOpt.Out + $rOpt.Err)
    # Order 106 step 5c: the short form 'Synapse: none - <reason>' clears the write duty too.
    $rNone = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-none' -TranscriptPath (New-GateTranscript 'g-none' $g @('digest', 'edit:src\a.ps1') "Fixed it.`nSynapse: none - a one-line typo fix with nothing durable")
    Check '106 5c: Synapse: none - <reason> clears the write duty' ($rNone.Out -notmatch '"decision"\s*:\s*"block"') $rNone.Out
    $rNoWrite = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-nowrite' -TranscriptPath (New-GateTranscript 'g-nowrite' $g @('digest', 'edit:src\a.ps1') "Fixed it.")
    Check '106 5c: edits with a read but no write and no none-line -> blocks once' ($rNoWrite.Out -match '"decision"\s*:\s*"block"' -and $rNoWrite.Out -match 'Write duty') $rNoWrite.Out
    $g = New-Proj 'GateOptEmpty'
    $rOptEmpty = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-optempty' -TranscriptPath (New-GateTranscript 'g-optempty' $g @('digest', 'edit:src\a.ps1') "Fixed it.`nSynapse: no durable learning -")
    Check 'gate: an opt-out with an empty reason is still refused' ($rOptEmpty.Out -match $blockPattern) $rOptEmpty.Out

    $g = New-Proj 'GateLate'
    $rLate = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-late' -TranscriptPath (New-GateTranscript 'g-late' $g @('edit:src\a.ps1', 'digest', 'write'))
    Check 'gate: a read only after the first edit is an advisory, not a block' (
        $rLate.Out -match 'read after first of' -and $rLate.Out -notmatch $blockPattern) $rLate.Out

    $g = New-Proj 'GateQuestion'
    $rQuestion = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-q' -TranscriptPath (New-GateTranscript 'g-q' $g @())
    Check 'gate: a session without project edits is silent' ($rQuestion.Exit -eq 0 -and $rQuestion.Out -eq '') $rQuestion.Out
    $g = New-Proj 'GateExcluded'
    $rExcluded = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-x' -TranscriptPath (New-GateTranscript 'g-x' $g @('edit:.ai\memory.md', 'edit:specs\001\spec.md', 'edit:plans\p.md'))
    Check 'gate: edits only under .ai/specs/plans are not project edits' ($rExcluded.Out -eq '') $rExcluded.Out
    $rSub = Fire -Cwd (New-Proj 'GateSub') -EventName 'SubagentStop' -SessionId 'g-sub' -TranscriptPath (New-GateTranscript 'g-sub' $g @('edit:src\a.ps1'))
    Check 'gate: SubagentStop is never refused' ($rSub.Exit -eq 0 -and $rSub.Out -eq '') $rSub.Out
    $rNoTranscript = Fire -Cwd (New-Proj 'GateNoTranscript') -EventName 'Stop' -SessionId 'g-nt'
    Check 'gate: no transcript is unknown evidence - silent' ($rNoTranscript.Exit -eq 0 -and $rNoTranscript.Out -eq '') $rNoTranscript.Out
    # The hook's own SessionStart note names every memory_* tool as prose; only
    # a tool_use record may count as a call.
    $g = New-Proj 'GateOwnNote'
    $rOwnNote = Fire -Cwd $g -EventName 'Stop' -SessionId 'g-own' -TranscriptPath (New-GateTranscript 'g-own' $g @('edit:src\a.ps1') ('Noted: ' + $rStart.Out))
    Check 'gate: the hook''s own note text never counts as a Synapse call' ($rOwnNote.Out -match 'Read duty') $rOwnNote.Out

    Write-Host ''
    Write-Host '--- anti-loop: stop_hook_active ---' -ForegroundColor Cyan
    $g = New-Proj 'Recursion'
    $rRecursion = Fire -Cwd $g -EventName 'Stop' -SessionId 's-rec' -TranscriptPath (New-GateTranscript 'g-rec' $g @('edit:src\a.ps1')) -StopHookActive
    Check 'stop_hook_active is honoured (no re-entry)' (
        $rRecursion.Exit -eq 0 -and $rRecursion.Out -eq '') ($rRecursion.Out + $rRecursion.Err)

    Write-Host ''
    Write-Host '--- SYNAPSE_HOME is the fallback signal for a non-default layout ---' -ForegroundColor Cyan
    $altHome = New-Proj '_synapse-elsewhere'
    $envProj = New-Proj 'EnvConfigured'
    $hookDir = Split-Path -Parent $Hook
    $envPath = Join-Path $hookDir '.env'
    $hadEnv = Test-Path -LiteralPath $envPath -PathType Leaf
    $savedEnv = if ($hadEnv) { [System.IO.File]::ReadAllText($envPath) } else { '' }
    try {
        Write-Utf8 $envPath ('SYNAPSE_HOME=' + $altHome)
        $rAlt = Fire -Cwd $envProj -EventName 'SessionStart' -SessionId 's-alt' -Profile $FakeProfileWithout
        Check 'SYNAPSE_HOME makes the hook speak with no store at the default path' (
            $rAlt.Exit -eq 0 -and $rAlt.Out -match 'Synapse-Rules-Check: ENFORCED at Stop') ($rAlt.Out + $rAlt.Err)
        # A configured path that does not exist is NOT a signal.
        Write-Utf8 $envPath ('SYNAPSE_HOME=' + (Join-Path $Work 'no-such-synapse'))
        $rBadAlt = Fire -Cwd (New-Proj 'EnvBogus') -EventName 'SessionStart' -SessionId 's-bad' -Profile $FakeProfileWithout
        Check 'a SYNAPSE_HOME that does not exist keeps the hook silent' (
            $rBadAlt.Exit -eq 0 -and $rBadAlt.Out -eq '') ($rBadAlt.Out + $rBadAlt.Err)
        Write-Utf8 $envPath 'MID_SESSION_REMINDER=0'
        $rOff = Fire -Cwd (New-Proj 'MidOff') -EventName 'UserPromptSubmit' -SessionId 's-off' -TranscriptPath $wroteUnread
        Check 'MID_SESSION_REMINDER=0 turns the mid-session note off' ($rOff.Exit -eq 0 -and $rOff.Out -eq '') $rOff.Out
        $offProj = New-Proj 'MidOffStop'
        $rOffStop = Fire -Cwd $offProj -EventName 'Stop' -SessionId 's-off' -TranscriptPath (New-GateTranscript 'g-off' $offProj @('edit:src\a.ps1'))
        Check 'MID_SESSION_REMINDER=0 leaves the Stop gate enforced' ($rOffStop.Out -match 'Read duty') $rOffStop.Out
    }
    finally {
        # Never leave a .env behind next to a shipped hook: the installer would
        # package it, and it is not part of the source.
        if ($hadEnv) { Write-Utf8 $envPath $savedEnv }
        elseif (Test-Path -LiteralPath $envPath -PathType Leaf) { Remove-Item -LiteralPath $envPath -Force }
    }

    Write-Host ''
    Write-Host '--- the shipped .env.example documents only what the hook reads ---' -ForegroundColor Cyan
    $examplePath = Join-Path $hookDir '.env.example'
    Check '.env.example ships beside the hook' (Test-Path -LiteralPath $examplePath -PathType Leaf)
    $exampleText = [System.IO.File]::ReadAllText($examplePath)
    Check '.env.example documents SYNAPSE_HOME' ($exampleText -match '(?m)^SYNAPSE_HOME=') $exampleText
    Check '.env.example documents MID_SESSION_REMINDER' ($exampleText -match '(?m)^MID_SESSION_REMINDER=1') $exampleText
    $declared = @([regex]::Matches($exampleText, '(?m)^([A-Z0-9_]+)=') | ForEach-Object { $_.Groups[1].Value })
    $hookText = [System.IO.File]::ReadAllText($Hook)
    $undocumented = @($declared | Where-Object { $hookText -notmatch [regex]::Escape($_) })
    Check 'every key in .env.example is one the hook actually reads' ($undocumented.Count -eq 0) ($undocumented -join ',')

    Write-Host ''
    Write-Host '--- Windows PowerShell 5.1 runs it identically ---' -ForegroundColor Cyan
    $r51 = Fire -Cwd (New-Proj 'Ps51') -EventName 'SessionStart' -SessionId 's-51' -Exe 'powershell'
    Check '5.1: the reminder is emitted cleanly' (
        $r51.Exit -eq 0 -and $r51.Out -match 'Synapse-Rules-Check: ENFORCED at Stop') ($r51.Out + $r51.Err)
    $r51None = Fire -Cwd (New-Proj 'Ps51None') -EventName 'SessionStart' -SessionId 's-51n' -Profile $FakeProfileWithout -Exe 'powershell'
    Check '5.1: the relevance gate holds there too' ($r51None.Exit -eq 0 -and $r51None.Out -eq '') ($r51None.Out + $r51None.Err)
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
