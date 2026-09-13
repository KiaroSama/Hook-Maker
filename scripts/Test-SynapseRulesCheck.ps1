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
    Check 'start: it fires when a store exists' ($rStart.Exit -eq 0 -and $rStart.Out -match 'SYNAPSE RULES CHECK') ($rStart.Out + $rStart.Err)
    Check 'start: it names memory_digest and the tokenBudget' (
        $rStart.Out -match 'memory_digest' -and $rStart.Out -match 'tokenBudget') $rStart.Out
    Check 'start: it says to index BEFORE reading the digest' ($rStart.Out -match '(?i)index it first') $rStart.Out
    # The two settings this store measured and that are easy to get wrong.
    Check 'start: it carries the 0.65 threshold' ($rStart.Out -match '0\.65') $rStart.Out
    Check 'start: it warns against minScore together with tags' (
        $rStart.Out -match '(?i)NEVER pass minScore and tags together') $rStart.Out
    Check 'start: it says an environment fact must be re-verified, not recalled' (
        $rStart.Out -match '(?i)observation with a timestamp') $rStart.Out
    Check 'start: nothing is written to stderr' ($rStart.Err -eq '') $rStart.Err

    Write-Host ''
    Write-Host '--- an unrelated event is not this hook''s business ---' -ForegroundColor Cyan
    $rOther = Fire -Cwd $proj -EventName 'UserPromptSubmit'
    Check 'UserPromptSubmit is ignored (the digest is a once-per-session read)' (
        $rOther.Exit -eq 0 -and $rOther.Out -eq '') ($rOther.Out + $rOther.Err)

    Write-Host ''
    Write-Host '--- Stop: was the store actually consulted? ---' -ForegroundColor Cyan
    # NOT consulted: the transcript holds ordinary work and no memory_* call.
    $plain = New-Transcript 'transcript-plain.jsonl' '{"role":"assistant","text":"edited a file and ran the tests"}'
    $rMissed = Fire -Cwd (New-Proj 'Missed') -EventName 'Stop' -SessionId 's-missed' -TranscriptPath $plain
    Check 'stop: an unread store is reported' (
        $rMissed.Exit -eq 0 -and $rMissed.Out -match 'never queried') ($rMissed.Out + $rMissed.Err)
    Check 'stop: the unread message still says how to write back' ($rMissed.Out -match 'memory_write') $rMissed.Out

    # Consulted: the same shape, with a real tool name in it.
    $used = New-Transcript 'transcript-used.jsonl' '{"role":"assistant","name":"mcp__synapse__memory_digest"}'
    $rUsed = Fire -Cwd (New-Proj 'Used') -EventName 'Stop' -SessionId 's-used' -TranscriptPath $used
    Check 'stop: a consulted store gets the WRITE-BACK half instead' (
        $rUsed.Exit -eq 0 -and $rUsed.Out -match 'SYNAPSE WRITE-BACK' -and $rUsed.Out -notmatch 'never queried') ($rUsed.Out + $rUsed.Err)
    Check 'stop: write-back demands an entityKey so a new version supersedes' (
        $rUsed.Out -match 'entityKey') $rUsed.Out
    Check 'stop: it says to correct a CONTRADICTED memory in the same turn' (
        $rUsed.Out -match '(?i)CONTRADICTED this session') $rUsed.Out
    Check 'stop: it refuses secrets explicitly' ($rUsed.Out -match '(?i)Never store secrets') $rUsed.Out
    Check 'stop: "nothing durable" is a normal answer' ($rUsed.Out -match '(?i)write nothing') $rUsed.Out

    Write-Host ''
    Write-Host '--- the marker: a long session that read it EARLY still counts ---' -ForegroundColor Cyan
    # The tail window is bounded, so the marker is the only thing that can carry
    # "already read" across a session long enough to push the call out of it.
    $longProj = New-Proj 'LongSession'
    $early = New-Transcript 'transcript-early.jsonl' '{"tool_name":"mcp__synapse__memory_retrieve"}'
    $rFirst = Fire -Cwd $longProj -EventName 'Stop' -SessionId 's-long' -TranscriptPath $early
    Check 'marker: the first Stop sees the call and says write-back' ($rFirst.Out -match 'SYNAPSE WRITE-BACK') $rFirst.Out
    # Same session, same project, but the call has now scrolled away entirely.
    $scrolled = New-Transcript 'transcript-scrolled.jsonl' '{"role":"assistant","text":"much later work"}' -PadKb 8
    $rLater = Fire -Cwd $longProj -EventName 'SubagentStop' -SessionId 's-long' -TranscriptPath $scrolled
    Check 'marker: a later Stop of the SAME session does not call it unread' (
        $rLater.Out -notmatch 'never queried') $rLater.Out
    # A different session in the same project must not inherit it.
    $rNewSession = Fire -Cwd $longProj -EventName 'Stop' -SessionId 's-different' -TranscriptPath $scrolled
    Check 'marker: a NEW session does not inherit the previous one''s marker' (
        $rNewSession.Out -match 'never queried') $rNewSession.Out

    Write-Host ''
    Write-Host '--- anti-loop: stop_hook_active, and one answer per session-state ---' -ForegroundColor Cyan
    $rRecursion = Fire -Cwd (New-Proj 'Recursion') -EventName 'Stop' -SessionId 's-rec' -TranscriptPath $plain -StopHookActive
    Check 'stop_hook_active is honoured (no re-entry)' (
        $rRecursion.Exit -eq 0 -and $rRecursion.Out -eq '') ($rRecursion.Out + $rRecursion.Err)

    $repeatProj = New-Proj 'Repeat'
    $rOnce = Fire -Cwd $repeatProj -EventName 'Stop' -SessionId 's-repeat' -TranscriptPath $plain
    Check 'gate: the first Stop reports' ($rOnce.Out -match 'never queried') $rOnce.Out
    $rTwice = Fire -Cwd $repeatProj -EventName 'Stop' -SessionId 's-repeat' -TranscriptPath $plain
    Check 'gate: an unchanged answer is not repeated on the next Stop' ($rTwice.Out -eq '') $rTwice.Out
    # A CHANGED answer must get through immediately - the gate is per state,
    # not a mute switch.
    $rChanged = Fire -Cwd $repeatProj -EventName 'Stop' -SessionId 's-repeat' -TranscriptPath $used
    Check 'gate: a changed answer is reported immediately' ($rChanged.Out -match 'SYNAPSE WRITE-BACK') $rChanged.Out

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
            $rAlt.Exit -eq 0 -and $rAlt.Out -match 'SYNAPSE RULES CHECK') ($rAlt.Out + $rAlt.Err)
        # A configured path that does not exist is NOT a signal.
        Write-Utf8 $envPath ('SYNAPSE_HOME=' + (Join-Path $Work 'no-such-synapse'))
        $rBadAlt = Fire -Cwd (New-Proj 'EnvBogus') -EventName 'SessionStart' -SessionId 's-bad' -Profile $FakeProfileWithout
        Check 'a SYNAPSE_HOME that does not exist keeps the hook silent' (
            $rBadAlt.Exit -eq 0 -and $rBadAlt.Out -eq '') ($rBadAlt.Out + $rBadAlt.Err)
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
    $declared = @([regex]::Matches($exampleText, '(?m)^([A-Z0-9_]+)=') | ForEach-Object { $_.Groups[1].Value })
    $hookText = [System.IO.File]::ReadAllText($Hook)
    $undocumented = @($declared | Where-Object { $hookText -notmatch [regex]::Escape($_) })
    Check 'every key in .env.example is one the hook actually reads' ($undocumented.Count -eq 0) ($undocumented -join ',')

    Write-Host ''
    Write-Host '--- Windows PowerShell 5.1 runs it identically ---' -ForegroundColor Cyan
    $r51 = Fire -Cwd (New-Proj 'Ps51') -EventName 'SessionStart' -SessionId 's-51' -Exe 'powershell'
    Check '5.1: the reminder is emitted cleanly' (
        $r51.Exit -eq 0 -and $r51.Out -match 'SYNAPSE RULES CHECK') ($r51.Out + $r51.Err)
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
