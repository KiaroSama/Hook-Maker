# Offline test suite for Test-Completion-Check - new hook, no prior coverage.
#
# Focused on the gate boundary rather than an exhaustive message matrix:
# stop_hook_active short-circuits before anything is evaluated; no relevant
# test work is total silence; a fresh clean guarded result allows completion;
# terminated / leaked / failed results block with the reason named and an exact
# recovery instruction; a STALE result is not proof; a MISSING result for an
# observed run never claims success; the durable .ai/ note requirement is
# satisfied by a real update and not by the word "done"; the Test-Temp-Cleanup
# same-Stop race defers to the NEXT event instead of looping; both client
# output shapes including the Codex block-vs-advisory distinction; and
# TEST_COMPLETION_ADVISORY_ONLY reports without blocking.
#
# No live processes are started except one short-lived sentinel used as a
# deterministic "alive pid" for the active-run case; nothing sleeps on a
# minute scale, and every fixture lives under a uniquely prefixed temp
# workspace with its own fake LOCALAPPDATA - the real user Claude/Codex state,
# the real .ai/ of this repository, and real drives are never touched.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestCompletionCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HooksRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Test-Completion-Check\Test-Completion-Check.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-completiontest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function New-GitRepo {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    Write-Utf8 (Join-Path $p 'readme.txt') 'x'
    & git -C $p add -A
    & git -C $p commit -q -m 'init'
    return $p
}

# Isolated hook copy + fake LOCALAPPDATA per case, so coordination state files
# never collide between cases or with the real machine. _hooklib.ps1 is placed
# one level above the copy because the hook dot-sources '..\_hooklib.ps1'.
function New-IsolatedHookCopy {
    param([hashtable]$EnvOverrides = @{})
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Test-Completion-Check.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path (Join-Path $fakeLocal 'HookMaker\state') -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Completion-Check.ps1'); LocalAppData = $fakeLocal }
}

function Get-StateDir { param($Copy) return (Join-Path $Copy.LocalAppData 'HookMaker\state') }

# The hook keys every coordination file on Get-ShortHash(lowercased cwd) -
# recomputed here from the hook's own library so the test can never drift from
# the implementation's key derivation.
. $HookLib
function Get-ProjectKey { param([string]$Root) return (Get-ShortHash $Root.ToLowerInvariant()) }

# Same fingerprint the hook computes for the current repo state.
function Get-Fingerprint { param([string]$Root) return (Get-RepoStateFingerprint -ProjectRoot $Root) }

function Write-GuardedResult {
    param(
        [object]$Copy, [string]$Root, [string]$Overall = 'ok', [int]$ExitCode = 0,
        [string]$TerminateReason = '', [string]$TerminateDetail = '', [object[]]$Leaked = @(),
        [double]$AgeMinutes = 0
    )
    $ended = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).ToString('o')
    $doc = [ordered]@{
        schema = 1; overall = $Overall; fileName = 'pwsh'; argumentCount = 3
        workingDirectory = $Root; exitCode = $ExitCode
        terminated = ($Overall -eq 'terminated'); terminateReason = $TerminateReason
        terminateDetail = $TerminateDetail; elapsedSeconds = 12.5; idleSecondsAtEnd = 0
        heartbeats = 2; peakMemoryMB = 40; cpuSeconds = 3; peakTreeSize = 2
        leakedProcessIds = @($Leaked); lastProgress = 'Passed: 10  Failed: 0'
        stdoutBytes = 100; stderrBytes = 0; workerBudget = 4
        startedUtc = $ended; endedUtc = $ended
    }
    $path = Join-Path (Get-StateDir $Copy) ('TestRunGuard-result-' + (Get-ProjectKey $Root) + '.json')
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 6)
}

function Write-ObservedRecord {
    param([object]$Copy, [string]$Root, [bool]$Guarded = $true, [string]$Fingerprint = '')
    if ($Fingerprint -eq '') { $Fingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{ observedUtc = [DateTime]::UtcNow.ToString('o'); fingerprint = $Fingerprint; guarded = $Guarded }
    $path = Join-Path (Get-StateDir $Copy) ('TestRunGuard-observed-' + (Get-ProjectKey $Root) + '.json')
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
}

function Write-ActiveMarker {
    param([object]$Copy, [string]$Root, [int]$ProcessId)
    $doc = [ordered]@{ pid = $ProcessId; startedUtc = [DateTime]::UtcNow.ToString('o') }
    $path = Join-Path (Get-StateDir $Copy) ('TestRunGuard-active-' + (Get-ProjectKey $Root) + '.json')
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
}

function Remove-CoordinationFile {
    param([object]$Copy, [string]$Root, [string]$Kind)
    Remove-Item -LiteralPath (Join-Path (Get-StateDir $Copy) ('TestRunGuard-' + $Kind + '-' + (Get-ProjectKey $Root) + '.json')) -Force -ErrorAction SilentlyContinue
}

# Marks Test-Temp-Cleanup as INSTALLED for the project (the same detection
# Cloudflare-Deploy uses) without installing anything real.
function New-CleanupMarker {
    param([string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -Force | Out-Null
}
function Write-CleanupResult {
    param([object]$Copy, [string]$Root, [string]$Category = 'clean', [string]$Fingerprint = '')
    if ($Fingerprint -eq '') { $Fingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{ sessionId = 't'; fingerprint = $Fingerprint; category = $Category; timestampUtc = [DateTime]::UtcNow.ToString('o') }
    Write-Utf8 (Join-Path (Get-StateDir $Copy) ('TestTempCleanup-result-' + (Get-ProjectKey $Root) + '.json')) ($doc | ConvertTo-Json -Depth 4)
}

function Add-AiNote {
    param([string]$Root, [string]$Text, [string]$File = 'TESTING_NOTES.md')
    $dir = Join-Path $Root '.ai'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir $File
    $existing = if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::ReadAllText($path) } else { '' }
    Write-Utf8 $path ($existing + $Text + "`n")
}

function Fire {
    param(
        [object]$Copy, [string]$Cwd, [string]$EventName = 'Stop', [string]$SessionId = 'sess1',
        [switch]$StopHookActive, [switch]$Codex, [string]$Exe = 'pwsh'
    )
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    # The client signal is CLAUDE_PROJECT_DIR in the child ENVIRONMENT (set
    # below), never a field in the event input - `hookSpecificOutput` is an
    # OUTPUT field and appears in no event payload.
    $payload = $obj | ConvertTo-Json -Depth 5
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    Write-Utf8 $inFile $payload
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $Copy.Script + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Copy.Script + '"' }
    $startArgs = @{
        FilePath               = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait                   = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # -Environment MERGES with the inherited environment, so an ambient
        # CLAUDE_PROJECT_DIR from this very runner would otherwise leak into a
        # "Codex" case. Clear it explicitly rather than omitting the key.
        $childEnv = @{ PATH = $env:PATH; LOCALAPPDATA = $Copy.LocalAppData }
        $childEnv['CLAUDE_PROJECT_DIR'] = if ($Codex) { '' } else { $Cwd }
        $startArgs.Environment = $childEnv
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Parses the hook's stdout as ONE JSON document; $null when it is not valid.
function ConvertFrom-HookOutput {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}
function Get-BlockReason {
    param([string]$Text)
    $doc = ConvertFrom-HookOutput $Text
    if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['reason']) { return '' }
    return [string]$doc.reason
}

$sentinel = $null
try {
    # =====================================================================
    Write-Host '--- the recursion guard runs before anything is evaluated ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Recursion'
    # A blocking condition IS present; stop_hook_active must still win.
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p -StopHookActive
    Check 'stop_hook_active -> immediate silent exit even with a blocking finding present' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'stop_hook_active -> nothing was evaluated (no state file was written)' (
        -not (Test-Path -LiteralPath (Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')))) $r.Out
    $r = Fire -Copy $c -Cwd $p -EventName 'SubagentStop' -StopHookActive
    Check 'stop_hook_active on SubagentStop is honoured identically' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p -EventName 'PreToolUse'
    Check 'an unrelated event is ignored entirely' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- no relevant test work: total silence ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Quiet'
    $r = Fire -Copy $c -Cwd $p
    Check 'no guarded result, no observation, nothing running -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p -Codex
    Check 'silence is identical on the Codex shape' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p -EventName 'SubagentStop'
    Check 'SubagentStop with no test work is equally silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $missing = Join-Path $Work 'does-not-exist-at-all'
    $r = Fire -Copy $c -Cwd $missing
    Check 'a cwd that does not exist -> silent, never an error' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Err

    # =====================================================================
    Write-Host '--- a fresh clean guarded result allows completion ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'CleanRun'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'a fresh overall=ok result -> completion allowed, silently' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    Check 'an observed run WITH a fresh clean result -> still allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- a terminated run blocks, names the reason, gives the recovery ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Wall'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'a terminated (wallTimeout) result blocks completion' ($r.Exit -eq 0 -and $null -ne $doc -and $doc.decision -eq 'block') $r.Out
    $reason = Get-BlockReason $r.Out
    Check 'the block names the termination reason exactly' ($reason -match 'wallTimeout') $reason
    Check 'the block carries the runner detail, not a generic phrase' ($reason -match 'exceeded the 1800s wall ceiling') $reason
    Check 'the recovery instruction names the guarded runner explicitly' ($reason -match 'Run-Tests-Guarded\.ps1') $reason
    Check 'raising the ceiling to hide it is explicitly refused' ($reason -match 'do not simply raise the ceiling') $reason
    Check 'it never claims a broader test scope passed' (
        $reason -match 'cannot confirm any broader test scope passed' -and $reason -notmatch 'all tests passed[^"]*$') $reason
    Check 'the durable .ai/ note is demanded with the reason it exists' (
        $reason -match '\.ai/' -and $reason -match 'WHY this was not detected earlier' -and $reason -match 'prevention/recovery guard') $reason

    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Idle'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'produced no output or state change for 300s'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'an idleTimeout termination blocks and is named as idleTimeout' (
        $r.Out -match '"decision":"block"' -and $reason -match 'idleTimeout' -and $reason -match 'no output or state change') $reason

    # =====================================================================
    Write-Host '--- leaked process ids block ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Leak'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -ExitCode 0 -Leaked @(4321, 4322)
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a non-empty leakedProcessIds blocks even when overall=ok' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the leaked pids are named so they can actually be checked' ($reason -match '4321' -and $reason -match '4322') $reason
    Check 'the recovery tells the agent how to confirm they are gone' ($reason -match 'Get-Process -Id') $reason
    Check 'a leak also demands the durable .ai/ note' ($reason -match '\.ai/') $reason

    # =====================================================================
    Write-Host '--- a failed run blocks without weakening tests ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Failed'
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 3
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a current overall=failed result blocks completion' ($r.Out -match '"decision":"block"' -and $reason -match 'FAILED') $reason
    Check 'the real exit code is surfaced' ($reason -match 'exit code 3') $reason
    Check 'weakening or skipping tests to go green is explicitly refused' ($reason -match 'Do not weaken, skip, or delete tests') $reason

    # =====================================================================
    Write-Host '--- STALE evidence is not proof of a run ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'StaleOk'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 600   # default window is 180
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a STALE ok result does not silently allow completion for an observed run' (
        $r.Exit -eq 0 -and $r.Out -ne '' -and $r.Out -match '"decision":"block"') $r.Out
    Check 'the staleness is stated as the reason, with the window' ($reason -match 'STALE' -and $reason -match '180 minutes') $reason
    Check 'the stale path never claims a run happened' ($reason -match 'Completion cannot be claimed on evidence that does not exist') $reason

    # REGRESSION: ConvertFrom-Json rehydrates an ISO-8601 string into a
    # Kind=Utc [DateTime]; casting that to [string] drops the zone marker, so a
    # re-parse yields Kind=Unspecified and a following ToUniversalTime()
    # subtracts the local offset a SECOND time. On this machine (+03:30) that
    # aged every result by 210 minutes, so a run that had JUST ended was judged
    # STALE. These two cases fail loudly if that normalisation is ever lost.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'EvidenceWindowOffset'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 0
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    Check 'a result that JUST ended is CURRENT (no local-offset drift in the evidence window)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'EvidenceWindowMid'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 60
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    Check 'a 60-minute-old result is still CURRENT against the 180-minute window' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'EvidenceWindowEdge'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 179
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    Check 'a 179-minute-old result is inside the window; 181 is outside (the boundary is the configured one)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'EvidenceWindowOver'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 181
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    Check 'a 181-minute-old result is STALE and no longer proves the run happened' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STALE') $r.Out

    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'StaleTerminated'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 60s wall ceiling' -AgeMinutes 600
    $r = Fire -Copy $c -Cwd $p
    Check 'staleness never excuses a negative finding - an old hang still blocks' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'wallTimeout') $r.Out

    # =====================================================================
    Write-Host '--- a MISSING result where a test clearly ran ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'MissingResult'
    Write-ObservedRecord -Copy $c -Root $p -Guarded $false
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'an observed run with NO result document does not claim success' ($r.Out -match '"decision":"block"') $r.Out
    Check 'it says plainly that no result document exists' ($reason -match 'no guarded result document exists') $reason
    Check 'an unguarded run is called out as unowned and unbounded' ($reason -match 'UNGUARDED') $reason
    Check 'it forbids the "all tests passed" claim explicitly' ($reason -match 'never that "all tests passed"') $reason

    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'ObservedOtherState'
    Write-ObservedRecord -Copy $c -Root $p -Fingerprint 'notthisstate'
    $r = Fire -Copy $c -Cwd $p
    Check 'an observation from a DIFFERENT project state is not treated as current work' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- a guarded run that is still active ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Active'
    # A real, deterministically-alive process; no timing race, no sleep.
    $sentinel = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoLogo -NoProfile -Command "Read-Host"' -PassThru -WindowStyle Hidden
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $sentinel.Id
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a live guarded run blocks completion' ($r.Out -match '"decision":"block"' -and $reason -match 'STILL ACTIVE') $reason
    Check 'the owner pid is named' ($reason -match ([string]$sentinel.Id)) $reason
    $sentinel.Kill()
    $sentinel.WaitForExit(10000) | Out-Null
    $r = Fire -Copy $c -Cwd $p
    Check 'a marker whose owner pid is dead is stale, not active -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $sentinel = $null

    # =====================================================================
    Write-Host '--- the durable .ai/ note requirement ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Note'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'produced no output or state change for 300s'
    $r = Fire -Copy $c -Cwd $p
    Check 'the incident blocks first and registers the owed note' ($r.Out -match '"decision":"block"') $r.Out
    # The run itself is now fixed: a fresh clean result replaces the incident.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a clean re-run does NOT clear the owed note - it still blocks' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the outstanding item is identified as the durable .ai/ note' (
        $reason -match 'durable \.ai/ note is still owed' -and $reason -match 'idleTimeout') $reason
    Check 'the note requirement names the four candidate files' (
        $reason -match 'BUGS\.md' -and $reason -match 'TESTING_NOTES\.md' -and $reason -match 'COMMANDS\.md' -and $reason -match 'LESSON\.md') $reason
    Add-AiNote -Root $p -Text 'done'
    $r = Fire -Copy $c -Cwd $p
    Check 'the word "done" does NOT satisfy the durable-note requirement' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block says a bare acknowledgement will not clear it' ((Get-BlockReason $r.Out) -match 'bare acknowledgement') $r.Out
    Add-AiNote -Root $p -Text ('Idle-timeout hang in the integration suite: the runner reported no output for 300s. ' +
        'Not detected earlier because no idle bound existed at all. Guard: Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300, verified by re-running the suite.')
    $r = Fire -Copy $c -Cwd $p
    Check 'a real durable note satisfies the requirement -> completion allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p
    Check 'the satisfied incident stays resolved on the next event (no nagging)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Test-Temp-Cleanup same-Stop race: defer to the NEXT event ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'Race'
    New-CleanupMarker $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    Check 'cleanup installed but not yet recorded -> defers silently on this event' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p
    Check 'the NEXT event evaluates normally - the deferral never loops forever' ($r.Out -match '"decision":"block"') $r.Out

    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'RaceResolved'
    New-CleanupMarker $p
    Write-CleanupResult -Copy $c -Root $p -Category 'clean'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    Check 'cleanup already recorded for the current state -> no deferral, evaluates at once' ($r.Out -match '"decision":"block"') $r.Out

    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'RaceNotInstalled'
    Write-CleanupResult -Copy $c -Root $p -Category 'clean' -Fingerprint 'stale-other-state'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c -Cwd $p
    Check 'cleanup NOT installed -> its state is irrelevant, no deferral at all' ($r.Out -match '"decision":"block"') $r.Out

    # =====================================================================
    Write-Host '--- both client shapes, and the Codex block-vs-advisory distinction ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Shapes'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c -Cwd $p
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'Claude: a real gate emits decision:block' (
        $null -ne $doc -and $doc.decision -eq 'block' -and $null -eq $doc.PSObject.Properties['hookSpecificOutput']) $r.Out
    $c2 = New-IsolatedHookCopy
    Write-GuardedResult -Copy $c2 -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c2 -Cwd $p -Codex
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'Codex: a real gate also emits decision:block (forcing continuation is the point of a gate)' (
        $null -ne $doc -and $doc.decision -eq 'block') $r.Out
    Check 'Codex: a real gate does NOT use the advisory systemMessage shape' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['systemMessage']) $r.Out

    # ---- advisory-only: the same finding must never become a Codex block ----
    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_ADVISORY_ONLY = '1' }
    $p = New-GitRepo 'Advisory'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'ADVISORY_ONLY on Claude: reported through additionalContext, never blocked' (
        $r.Exit -eq 0 -and $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        $doc.hookSpecificOutput.additionalContext -match 'wallTimeout') $r.Out
    Check 'ADVISORY_ONLY on Claude: the advisory carries the correct hookEventName' (
        $null -ne $doc -and $doc.hookSpecificOutput.hookEventName -eq 'Stop') $r.Out
    $c2 = New-IsolatedHookCopy @{ TEST_COMPLETION_ADVISORY_ONLY = '1' }
    Write-GuardedResult -Copy $c2 -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c2 -Cwd $p -Codex
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'ADVISORY_ONLY on Codex: systemMessage only - NEVER decision:block (no forced-continuation loop)' (
        $r.Exit -eq 0 -and $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        [string]$doc.systemMessage -match 'wallTimeout') $r.Out
    Check 'ADVISORY_ONLY on Codex: no Claude-only field is invented' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['hookSpecificOutput'])
    $r = Fire -Copy $c2 -Cwd $p -EventName 'SubagentStop' -Codex
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'SubagentStop advisory keeps the same non-blocking Codex shape' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision']) $r.Out

    # =====================================================================
    Write-Host '--- .env validation: reported once, and never widens what is blocked on ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_EVIDENCE_MINUTES = 'not-a-number' }
    $p = New-GitRepo 'BadEvidence'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'an invalid EVIDENCE_MINUTES is reported in plain text with the finding' (
        $reason -match 'TEST_COMPLETION_EVIDENCE_MINUTES is not an integer' -and $reason -match 'using the default 180') $reason
    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_ADVISORY_ONLY = 'yes' }
    $p2 = New-GitRepo 'BadAdvisory'
    Write-GuardedResult -Copy $c -Root $p2 -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c -Cwd $p2
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'an invalid ADVISORY_ONLY falls back to advisory - a typo can never widen blocking' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        $doc.hookSpecificOutput.additionalContext -match 'ADVISORY_ONLY must be 0 or 1') $r.Out
    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_ALWAYS_REQUIRE_NOTE = '1' }
    $p3 = New-GitRepo 'AlwaysNote'
    Write-GuardedResult -Copy $c -Root $p3 -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p3
    Check 'ALWAYS_REQUIRE_NOTE=1 demands a note even after a clean run' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'durable \.ai/ note is still owed') $r.Out
    Add-AiNote -Root $p3 -Text ('Full suite run through the guarded runner completed clean; recorded here because this project requires a note per run. ' +
        'Wall 1800s / idle 300s, no leaked processes observed.')
    $r = Fire -Copy $c -Cwd $p3
    Check 'ALWAYS_REQUIRE_NOTE is satisfied by a real note' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- output is always exactly one valid JSON document ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Json'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'memoryLimit' -TerminateDetail 'owned process tree reached 4096MB'
    $r = Fire -Copy $c -Cwd $p
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'the blocking output parses as a single JSON document' ($null -ne $doc) $r.Out
    Check 'it is exactly one document (no concatenated objects)' (@($r.Out -split "`n" | Where-Object { $_.Trim() -ne '' }).Count -eq 1) $r.Out
    Check 'nothing is written to stderr' ($r.Err -eq '') $r.Err
    Check 'a memoryLimit termination is named too' ((Get-BlockReason $r.Out) -match 'memoryLimit') $r.Out

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Ps51'
    $r = Fire -Copy $c -Cwd $p -Exe 'powershell.exe'
    Check '5.1: silence when there is no test work' ($r.Exit -eq 0 -and $r.Out -eq '') ($r.Out + $r.Err)
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p -Exe 'powershell.exe'
    Check '5.1: the gate blocks with the same reason and no stderr noise' (
        $r.Exit -eq 0 -and $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'wallTimeout' -and $r.Err -eq '') ($r.Out + '|' + $r.Err)
    $r = Fire -Copy $c -Cwd $p -Exe 'powershell.exe' -StopHookActive
    Check '5.1: stop_hook_active short-circuits identically' ($r.Exit -eq 0 -and $r.Out -eq '') ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- the real user environment is never touched ---' -ForegroundColor Cyan
    Check 'no state was written outside the fake LOCALAPPDATA of each case' (
        @(Get-ChildItem -LiteralPath $Work -Recurse -Filter 'TestCompletionCheck-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '_fakelocal' }).Count -eq 0)
    Check 'no fixture ever created a .claude/settings.json' (
        @(Get-ChildItem -LiteralPath $Work -Recurse -Filter 'settings.json' -File -ErrorAction SilentlyContinue).Count -eq 0)
}
finally {
    if ($null -ne $sentinel) {
        try { $sentinel.Kill(); [void]$sentinel.WaitForExit(10000) } catch { }
    }
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        Get-ChildItem -LiteralPath $Work -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
