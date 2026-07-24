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

# A repo that git-ignores .ai/, so writing a durable note between Stops does NOT
# move the porcelain-based repo fingerprint. The D1/D2 ledger cases need incident
# results recorded before the note to stay CURRENT-state across the note write.
function New-GitRepoAi {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    Write-Utf8 (Join-Path $p 'readme.txt') 'x'
    Write-Utf8 (Join-Path $p '.gitignore') ".ai/`n"
    & git -C $p add -A
    & git -C $p commit -q -m 'init'
    return $p
}

# The completion hook's own project-keyed state document (resolvedIncidents /
# pendingNotes ledger), or $null when it has not been written yet.
function Get-CompletionStateDoc {
    param([object]$Copy, [string]$Root)
    $path = Join-Path (Get-StateDir $Copy) ('TestCompletionCheck-' + (Get-ProjectKey $Root) + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}
# Element counts tolerant of the empty-array-as-'' / single-element-as-scalar JSON
# quirk. Resolved entries are non-empty strings; pending entries are objects with
# a non-empty key.
function Get-ResolvedCount {
    param($Doc)
    if ($null -eq $Doc -or $null -eq $Doc.PSObject.Properties['resolvedIncidents']) { return 0 }
    return @(@($Doc.resolvedIncidents) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
}
function Get-PendingCount {
    param($Doc)
    if ($null -eq $Doc -or $null -eq $Doc.PSObject.Properties['pendingNotes']) { return 0 }
    return @(@($Doc.pendingNotes) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['key'] -and -not [string]::IsNullOrWhiteSpace([string]$_.key) }).Count
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

# Deterministic run identity per project root, so a result and an observed record
# for the same root MATCH the hook's identity gate by construction (schema 2).
function Get-TestRunId { param([string]$Root) return ('run-' + (Get-ProjectKey $Root)) }
function Get-TestCommandFp {
    param([string]$Root)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('cmd|' + $Root.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 32) }
    finally { $sha.Dispose() }
}

# Filename-safe runId - must match Run-Tests-Guarded.ps1/Test-Run-Guard.ps1's
# Get-SafeRunId. Every coordination file is now PER-RUN:
# TestRunGuard-<kind>-<key>-<safeRunId>.json.
function Get-SafeRunId { param([string]$Id) $s = ([string]$Id).ToLowerInvariant() -replace '[^a-z0-9]', ''; if ($s -eq '') { $s = Get-ShortHash ([string]$Id) }; return $s }
function Get-RunStateFile {
    param([object]$Copy, [string]$Root, [string]$Kind, [string]$RunId = '')
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    return (Join-Path (Get-StateDir $Copy) ('TestRunGuard-' + $Kind + '-' + (Get-ProjectKey $Root) + '-' + (Get-SafeRunId $RunId) + '.json'))
}

function Write-GuardedResult {
    param(
        [object]$Copy, [string]$Root, [string]$Overall = 'ok', [int]$ExitCode = 0,
        [string]$TerminateReason = '', [string]$TerminateDetail = '', [object[]]$Leaked = @(),
        [double]$AgeMinutes = 0,
        # Override the identity to simulate a DIFFERENT run/command/state.
        [string]$RunId = '', [string]$CommandFingerprint = '', [string]$ProjectFingerprint = ''
    )
    $ended = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).ToString('o')
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    if ($CommandFingerprint -eq '') { $CommandFingerprint = Get-TestCommandFp $Root }
    if ($ProjectFingerprint -eq '') { $ProjectFingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{
        schema = 2; overall = $Overall; fileName = 'pwsh'; argumentCount = 3
        workingDirectory = $Root; exitCode = $ExitCode
        runId = $RunId; projectFingerprint = $ProjectFingerprint; commandFingerprint = $CommandFingerprint
        terminated = ($Overall -eq 'terminated'); terminateReason = $TerminateReason
        terminateDetail = $TerminateDetail; elapsedSeconds = 12.5; noProgressSeconds = 0
        heartbeats = 2; peakMemoryMB = 40; cpuSeconds = 3; peakTreeSize = 2
        leakedProcessIds = @($Leaked); lastProgress = 'Passed: 10  Failed: 0'
        stdoutBytes = 100; stderrBytes = 0; workerBudget = 4
        startedUtc = $ended; endedUtc = $ended
    }
    # PER-RUN filename, keyed by this result's own runId - two runs in one project
    # write distinct files instead of overwriting each other.
    $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'result' -RunId $RunId
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 6)
}

function Write-ObservedRecord {
    param(
        [object]$Copy, [string]$Root, [bool]$Guarded = $true, [string]$Fingerprint = '',
        [double]$AgeMinutes = 0, [bool]$RunIdControlled = $true, [string]$RunId = '',
        [string]$CommandFingerprint = ''
    )
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    if ($CommandFingerprint -eq '') { $CommandFingerprint = Get-TestCommandFp $Root }
    # observedUtc is anchored a full 60s below the result's start. Both this
    # helper and Write-GuardedResult call the git-based Get-Fingerprint, whose
    # duration under parallel git contention is unbounded-in-seconds; a tight
    # margin let observedUtc drift PAST a result written moments earlier, so the
    # hook's startedUtc>=observedUtc gate flakily rejected a genuinely-matching
    # run. 60s dwarfs any git delay yet is negligible against the 180-minute
    # evidence window, and the identity-mismatch tests use minute-scale gaps, so
    # this never masks a real "different run".
    $observedUtc = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).AddSeconds(-60).ToString('o')
    if ($Fingerprint -eq '') { $Fingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{
        schema = 2; observedUtc = $observedUtc; fingerprint = $Fingerprint; projectFingerprint = $Fingerprint
        runId = $RunId; runIdControlled = $RunIdControlled
        commandFingerprint = $CommandFingerprint; guarded = $Guarded
    }
    $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'observed' -RunId $RunId
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
}

function Write-ActiveMarker {
    param([object]$Copy, [string]$Root, [int]$ProcessId,
        [string]$StartUtc = '', [string]$ExePath = '', [string]$ProjectFingerprint = '', [string]$RunId = '')
    if ($RunId -eq '') { $RunId = Get-TestRunId $Root }
    # Schema-2 marker with owner identity. Defaults reflect the LIVE process at
    # $ProcessId (so a marker written for the current test process validates).
    if ($StartUtc -eq '') {
        try { $StartUtc = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { $StartUtc = '' }
    }
    if ($ExePath -eq '') {
        try { $ExePath = [string](Get-Process -Id $ProcessId -ErrorAction Stop).Path } catch { $ExePath = '' }
    }
    if ($ProjectFingerprint -eq '') { $ProjectFingerprint = Get-Fingerprint $Root }
    $doc = [ordered]@{
        schema = 2; runId = $RunId; ownerPid = $ProcessId
        ownerProcessStartUtc = $StartUtc; ownerExecutablePath = $ExePath
        projectFingerprint = $ProjectFingerprint; markerCreatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'active' -RunId $RunId
    Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
}

function Remove-CoordinationFile {
    param([object]$Copy, [string]$Root, [string]$Kind)
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-StateDir $Copy) -Filter ('TestRunGuard-' + $Kind + '-' + (Get-ProjectKey $Root) + '-*.json') -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
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

# The hook now tells the agent to tag its durable note with a line
# `Test incident: <key>`; a note without that exact tag no longer resolves the
# incident. These helpers mirror a real agent: extract the tag from the block the
# hook just emitted, then write a note carrying it plus real content.
function Get-IncidentTagLine {
    param([string]$Reason)
    if ($Reason -match 'Test incident:\s*([0-9a-zA-Z-]+)') { return ('Test incident: ' + $Matches[1]) }
    return ''
}
# Writes a durable note carrying the incident tag found in $Reason plus $Body.
function Add-TaggedNote {
    param([string]$Root, [string]$Reason, [string]$Body, [string]$File = 'TESTING_NOTES.md')
    Add-AiNote -Root $Root -Text ((Get-IncidentTagLine $Reason) + "`n" + $Body) -File $File
}

# Polls until a just-spawned process is fully queryable (StartTime and Path
# readable) so an active-marker written for it records the SAME identity the hook
# will later read. Removes the real-process start-up race that intermittently made
# a genuinely-live sentinel read as stale.
function Wait-ProcessReady {
    param([int]$ProcessId, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction Stop
            $st = $proc.StartTime
            $path = $proc.Path
            if ($null -ne $st -and -not [string]::IsNullOrWhiteSpace([string]$path)) { return $true }
        }
        catch { }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Fire {
    param(
        [object]$Copy, [string]$Cwd, [string]$EventName = 'Stop', [string]$SessionId = 'sess1',
        [switch]$StopHookActive, [switch]$Codex, [string]$Exe = 'pwsh',
        # E-05: optional Stop-input fields the ::deep-debug detection consumes -
        # a transcript_path (Claude Code sends one at Stop) and/or a prompt field.
        [string]$TranscriptPath = '', [string]$Prompt = ''
    )
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    if ($TranscriptPath -ne '') { $obj['transcript_path'] = $TranscriptPath }
    if ($Prompt -ne '') { $obj['prompt'] = $Prompt }
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
    Write-ObservedRecord -Copy $c -Root $p -AgeMinutes 600   # same run, aged with the result
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
    Write-ObservedRecord -Copy $c -Root $p -AgeMinutes 60
    $r = Fire -Copy $c -Cwd $p
    Check 'a 60-minute-old result is still CURRENT against the 180-minute window' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'EvidenceWindowEdge'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 179
    Write-ObservedRecord -Copy $c -Root $p -AgeMinutes 179
    $r = Fire -Copy $c -Cwd $p
    Check 'a 179-minute-old result is inside the window; 181 is outside (the boundary is the configured one)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'EvidenceWindowOver'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 181
    Write-ObservedRecord -Copy $c -Root $p -AgeMinutes 181
    $r = Fire -Copy $c -Cwd $p
    Check 'a 181-minute-old result is STALE and no longer proves the run happened' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STALE') $r.Out

    # =====================================================================
    Write-Host '--- run-identity gate: a result must belong to THIS observation (scope A) ---' -ForegroundColor Cyan
    # Exact match accepted (baseline for the mismatch cases below).
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'IdMatch'
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'an exact-matching clean result is accepted (silent)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # A fresh green result from a DIFFERENT run (mismatched runId) is not evidence.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'IdRunMismatch'
    Write-ObservedRecord -Copy $c -Root $p   # observed run B (runIdControlled)
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId 'run-A-different'
    $r = Fire -Copy $c -Cwd $p
    Check 'a fresh green result from a different runId does NOT satisfy the observed run' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'DIFFERENT run') $r.Out

    # A green result for the same command but a DIFFERENT repository fingerprint.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'IdProjMismatch'
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -ProjectFingerprint 'some-other-state'
    $r = Fire -Copy $c -Cwd $p
    Check 'a green result for a different repository fingerprint does NOT satisfy the current state' (
        $r.Out -match '"decision":"block"') $r.Out

    # A previous FAILED result must not block a later observation unless its
    # identity matches: here it is a different run, so it must NOT block.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'IdFailMismatch'
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId 'run-earlier'
    $r = Fire -Copy $c -Cwd $p
    Check 'a failed result from a different run blocks as unproven, not as the old failure' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'DIFFERENT run' -and (Get-BlockReason $r.Out) -notmatch 'FAILED \(exit code 1\)') $r.Out

    # A result whose startedUtc PREDATES observedUtc is rejected (it is from
    # before this observation). Result started 5 min ago, observation is now.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'IdTimeOrder'
    Write-ObservedRecord -Copy $c -Root $p -AgeMinutes 0
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 5
    $r = Fire -Copy $c -Cwd $p
    Check 'a result that started before the observation is rejected as a different run' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'DIFFERENT run') $r.Out

    # A malformed result (missing runId + fingerprints) with an observed record
    # fails CLOSED - it is not accepted as a clean pass.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'IdMalformed'
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ' ' -CommandFingerprint ' ' -ProjectFingerprint ' '
    $r = Fire -Copy $c -Cwd $p
    Check 'a malformed result (blank identity) is not accepted as a clean pass' (
        $r.Out -match '"decision":"block"') $r.Out

    # =====================================================================
    Write-Host '--- active marker is resistant to PID reuse (scope C) ---' -ForegroundColor Cyan
    # Exact active identity (the live test process itself) blocks completion.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerLive'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $PID
    $r = Fire -Copy $c -Cwd $p
    Check 'an active marker whose owner process is genuinely THIS live process blocks' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STILL ACTIVE') $r.Out

    # Same live pid, but the recorded start time does not match -> pid reuse,
    # treated as stale, never active.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerStartMismatch'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $PID -StartUtc '2000-01-01T00:00:00.0000000Z'
    $r = Fire -Copy $c -Cwd $p
    Check 'a live pid with a mismatched process start time is ignored as stale (no block)' ($r.Out -eq '') $r.Out
    $markerGone = -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))
    Check 'the stale (pid-reuse) marker is cleaned up' $markerGone

    # Same live pid, mismatched executable path -> stale.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerExeMismatch'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $PID -ExePath 'C:\Windows\System32\notepad.exe'
    $r = Fire -Copy $c -Cwd $p
    Check 'a live pid running a different executable is ignored as stale (no block)' ($r.Out -eq '') $r.Out

    # A dead pid is ignored and its marker cleaned.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerDead'
    $deadProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
    $deadProc.WaitForExit()
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $deadProc.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'x'
    $r = Fire -Copy $c -Cwd $p
    Check 'a dead owner pid is ignored (no block) and its marker cleaned' (
        $r.Out -eq '' -and -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $r.Out

    # A malformed marker must not create an infinite completion block.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerMalformed'
    Write-Utf8 (Get-RunStateFile -Copy $c -Root $p -Kind 'active') '{ this is not valid json'
    $r = Fire -Copy $c -Cwd $p
    Check 'a malformed active marker fails safely (no block, no loop)' ($r.Out -eq '') $r.Out

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
    # A real process kept ALIVE for the whole check with a bounded sleep. A
    # Read-Host sentinel could EOF-exit under load (no console/stdin), free its
    # pid, and a parallel test could reuse it - which the schema-2 identity check
    # (start-time + exe must match) then correctly rejects as stale, flaking this
    # "is it active" assertion. Start-Sleep stays alive well past the hook check.
    $sentinel = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
    # Wait until the sentinel is fully queryable so the marker records the SAME
    # StartTime/Path the hook will read - otherwise a not-yet-settled process could
    # be recorded with an identity the hook rejects as stale (the observed flake).
    Check 'the sentinel process is ready before its marker is written' (Wait-ProcessReady -ProcessId $sentinel.Id)
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
    Write-Host '--- concurrent runs in ONE project: per-run files aggregate; completion blocks until every run is done (Defect 1) ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'TwoRuns'
    $rA = 'runa-' + (Get-ProjectKey $p)
    $rB = 'runb-' + (Get-ProjectKey $p)
    # Run A satisfied (observed + fresh ok result); run B observed with NO result yet.
    Write-ObservedRecord -Copy $c -Root $p -RunId $rA
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rA
    Write-ObservedRecord -Copy $c -Root $p -RunId $rB
    Check 'each run gets its OWN observed file (no overwrite)' (
        @(Get-ChildItem -LiteralPath (Get-StateDir $c) -Filter 'TestRunGuard-observed-*.json').Count -eq 2)
    $r = Fire -Copy $c -Cwd $p
    Check 'completion is BLOCKED while run B has no result, even though run A passed' ($r.Out -match '"decision":"block"') $r.Out
    # Run B now fails - run A's pass must not cover it.
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 2 -RunId $rB
    $r = Fire -Copy $c -Cwd $p
    Check 'completion is BLOCKED while run B is failed (A''s pass does not cover B)' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'FAILED') $r.Out
    # Run B passes: BOTH runs are now satisfied.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rB
    $r = Fire -Copy $c -Cwd $p
    Check 'completion is ALLOWED only once BOTH current-state runs are satisfied' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'run A''s and run B''s result files coexist (per-run, never overwritten)' (
        @(Get-ChildItem -LiteralPath (Get-StateDir $c) -Filter 'TestRunGuard-result-*.json').Count -eq 2)

    # Run A finishing removes ONLY run A's marker; run B's live marker survives and
    # still blocks. The completion hook likewise removes a DEAD marker, never a live one.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'TwoMarkers'
    $rA = 'runa-' + (Get-ProjectKey $p)
    $rB = 'runb-' + (Get-ProjectKey $p)
    $sentinel = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
    [void](Wait-ProcessReady -ProcessId $sentinel.Id)
    $deadA = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
    $deadA.WaitForExit()
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $deadA.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'x' -RunId $rA
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $sentinel.Id -RunId $rB
    $r = Fire -Copy $c -Cwd $p
    Check 'run B''s live marker blocks even though run A''s marker is stale' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STILL ACTIVE') $r.Out
    Check 'run A''s stale marker is removed, but run B''s LIVE marker is NOT deleted' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active' -RunId $rA)) -and
        (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active' -RunId $rB)))
    $sentinel.Kill(); $sentinel.WaitForExit(10000) | Out-Null; $sentinel = $null

    # An OLDER-STATE run's leftover files must never block a satisfied current run.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'OldStateLeftover'
    $rCur = 'runcur-' + (Get-ProjectKey $p)
    $rOld = 'runold-' + (Get-ProjectKey $p)
    Write-ObservedRecord -Copy $c -Root $p -RunId $rCur
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rCur
    # A terminated run recorded against a DIFFERENT (older) repository state.
    Write-ObservedRecord -Copy $c -Root $p -RunId $rOld -Fingerprint 'old-state-xyz'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x' -RunId $rOld -ProjectFingerprint 'old-state-xyz'
    $r = Fire -Copy $c -Cwd $p
    Check 'an older-STATE terminated run''s leftover files do not block the satisfied current run' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # Bounded state growth: inert per-run result/observed files older than 24h are
    # pruned; a fresh run's files survive.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'PruneOld'
    $rStale = 'runstale-' + (Get-ProjectKey $p)
    Write-ObservedRecord -Copy $c -Root $p -RunId $rStale
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rStale
    $staleObs = Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId $rStale
    $staleRes = Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rStale
    (Get-Item -LiteralPath $staleObs).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    (Get-Item -LiteralPath $staleRes).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    $rFresh = 'runfresh-' + (Get-ProjectKey $p)
    Write-ObservedRecord -Copy $c -Root $p -RunId $rFresh
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rFresh
    $r = Fire -Copy $c -Cwd $p
    Check 'per-run result/observed files older than 24h are pruned' (
        -not (Test-Path -LiteralPath $staleObs) -and -not (Test-Path -LiteralPath $staleRes)) $staleObs
    Check 'a fresh run''s per-run files are NOT pruned' (
        (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId $rFresh)) -and
        (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rFresh)))

    # =====================================================================
    Write-Host '--- C1: a LIVE active marker survives a mid-run repo fingerprint change ---' -ForegroundColor Cyan
    # A real long-lived owner (bounded sleep, never Read-Host). The marker records
    # the state fingerprint as of test start; an unrelated edit then MOVES the repo
    # (git porcelain) fingerprint while the process is STILL alive. Liveness is by
    # process identity, not the mutable working-tree fingerprint, so the marker must
    # survive and still block.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C1LiveMarker'
    $fpBefore = Get-Fingerprint $p
    $sentinel = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 45') -PassThru -WindowStyle Hidden
    [void](Wait-ProcessReady -ProcessId $sentinel.Id)
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $sentinel.Id -ProjectFingerprint $fpBefore
    Write-Utf8 (Join-Path $p 'mid-edit.txt') 'edited mid run'
    $fpAfter = Get-Fingerprint $p
    Check 'editing a file actually moved the repo fingerprint (test precondition)' ($fpBefore -ne $fpAfter) ($fpBefore + ' vs ' + $fpAfter)
    $r = Fire -Copy $c -Cwd $p
    Check 'C1: the LIVE marker still BLOCKS after the fingerprint changed (liveness is process identity, not fingerprint)' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STILL ACTIVE') $r.Out
    Check 'C1: the LIVE marker was NOT deleted despite the fingerprint mismatch' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active')) $r.Out
    $sentinel.Kill(); $sentinel.WaitForExit(10000) | Out-Null; $sentinel = $null

    # =====================================================================
    Write-Host '--- C2: content-aware pruning keeps unresolved negatives, prunes clean/superseded ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C2Prune'
    $key = Get-ProjectKey $p
    # (a) an unresolved TERMINATED result older than 24h -> KEPT (negative survives age).
    $rTerm = 'c2term-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x' -RunId $rTerm -ProjectFingerprint 'c2-oldstate' -CommandFingerprint ('cmdterm' + $key)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rTerm)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    # (b) an unresolved LEAKED result older than 24h -> KEPT.
    $rLeak = 'c2leak-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -Leaked @(9111) -RunId $rLeak -ProjectFingerprint 'c2-oldstate2' -CommandFingerprint ('cmdleak' + $key)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rLeak)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    # (c) a clean OK result older than 24h -> PRUNED (staleness weakens positive evidence).
    $rCleanOld = 'c2clean-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rCleanOld -CommandFingerprint ('cmdclean' + $key)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rCleanOld)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    # (d) an old TERMINATED result SUPERSEDED by a newer clean run for the same command+state -> PRUNED.
    $rSup = 'c2sup-' + $key; $rSupOk = 'c2supok-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'x' -RunId $rSup -CommandFingerprint ('cmdsup' + $key) -AgeMinutes 200
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rSup)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rSupOk -CommandFingerprint ('cmdsup' + $key) -AgeMinutes 5
    $r = Fire -Copy $c -Cwd $p
    Check 'C2: an unresolved terminated result older than 24h is NOT pruned' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rTerm)) $r.Out
    Check 'C2: an unresolved leaked result older than 24h is NOT pruned' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rLeak)) $r.Out
    Check 'C2: a clean ok result older than 24h IS pruned' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rCleanOld))) $r.Out
    Check 'C2: an old terminated result superseded by a newer clean run IS pruned' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rSup))) $r.Out
    Check 'C2: the newer clean (superseding) result is retained' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rSupOk)) $r.Out

    # =====================================================================
    Write-Host '--- C3: two uncontrolled runs cannot share one green result (one-to-one pairing) ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C3OneToOne'
    $key = Get-ProjectKey $p
    # Two direct guarded runs of the SAME command with NO -RunId -> runIdControlled=false,
    # each with its own minted runId distinct from the runner's result runId.
    Write-ObservedRecord -Copy $c -Root $p -RunId ('c3obsa-' + $key) -RunIdControlled:$false
    Write-ObservedRecord -Copy $c -Root $p -RunId ('c3obsb-' + $key) -RunIdControlled:$false
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('c3resx-' + $key)
    $r = Fire -Copy $c -Cwd $p
    Check 'C3: two uncontrolled observations with only ONE green result -> completion BLOCKS (the second is unpaired)' (
        $r.Out -match '"decision":"block"') $r.Out
    # A SECOND green result: now each observation pairs one-to-one.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('c3resy-' + $key)
    $r = Fire -Copy $c -Cwd $p
    Check 'C3: with TWO green results both uncontrolled runs are satisfied -> completion ALLOWED' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- C4: a resolved incident does not re-block a clean rerun; an unresolved one still blocks ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C4Resolved'
    $key = Get-ProjectKey $p
    $rInc = 'c4inc-' + $key
    Write-ObservedRecord -Copy $c -Root $p -RunId $rInc
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'produced no output or state change for 300s' -RunId $rInc
    $r = Fire -Copy $c -Cwd $p
    Check 'C4: the incident blocks first and registers the owed note' ($r.Out -match '"decision":"block"') $r.Out
    Check 'C4: the block instructs the agent to tag the note with the incident key' ((Get-BlockReason $r.Out) -match 'Test incident:') (Get-BlockReason $r.Out)
    # The environmental cause is fixed WITHOUT a source change: a durable note is
    # written (tagged with the incident key) and the SAME command reruns GREEN.
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('Idle-timeout hang fixed by clearing a stuck local service; not detected earlier because no idle bound existed. ' +
        'Guard: Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300, verified by re-running the suite green.')
    $rGreen = 'c4green-' + $key
    Write-ObservedRecord -Copy $c -Root $p -RunId $rGreen
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rGreen
    $r = Fire -Copy $c -Cwd $p
    Check 'C4: a clean rerun for the same command/state is ACCEPTED, not re-blocked by the old incident' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # C2 tie-in: once resolved, the incident''s own aged files become prunable.
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rInc)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'observed' -RunId $rInc)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    $r = Fire -Copy $c -Cwd $p
    Check 'C4/C2: the RESOLVED incident''s aged result file is pruned' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rInc))) $r.Out

    # An UNRESOLVED incident (no note, no clean rerun) still blocks.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C4Unresolved'
    $rInc2 = 'c4inc2-' + (Get-ProjectKey $p)
    Write-ObservedRecord -Copy $c -Root $p -RunId $rInc2
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling' -RunId $rInc2
    $r = Fire -Copy $c -Cwd $p
    Check 'C4: a genuinely unresolved incident still blocks completion' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'wallTimeout') $r.Out

    # =====================================================================
    Write-Host '--- D1: two concurrent incidents each keep their OWN resolved-state + note (no ping-pong) ---' -ForegroundColor Cyan
    # .ai/ is git-ignored so a note between Stops leaves the repo fingerprint stable
    # and both incident runs stay CURRENT-state. A and B use DISTINCT commands so a
    # green rerun of A does NOT supersede B.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'D1TwoIncidents'
    $key = Get-ProjectKey $p
    $cmdA = 'd1cmda-' + $key; $cmdB = 'd1cmdb-' + $key
    $rA = 'd1runa-' + $key; $rB = 'd1runb-' + $key
    # A sorts first (older observedUtc) so it is the FIRST blocking representative.
    Write-ObservedRecord -Copy $c -Root $p -RunId $rA -CommandFingerprint $cmdA -AgeMinutes 2
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling' -RunId $rA -CommandFingerprint $cmdA -AgeMinutes 2
    Write-ObservedRecord -Copy $c -Root $p -RunId $rB -CommandFingerprint $cmdB -AgeMinutes 1
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'produced no output or state change for 300s' -RunId $rB -CommandFingerprint $cmdB -AgeMinutes 1
    $r = Fire -Copy $c -Cwd $p
    Check 'D1: with two incidents the first (A) blocks and names its reason' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'wallTimeout') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'D1: after A blocks, ONE note obligation is tracked (A only)' ((Get-PendingCount $st) -eq 1) ('pending=' + (Get-PendingCount $st))
    # Resolve A: write A's OWN tagged durable note AND a green rerun of cmdA that SUPERSEDES A.
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('A wall-timeout hang fixed by bounding the wall ceiling; not detected earlier because the ceiling was unset. ' +
        'Guard: Run-Tests-Guarded.ps1 -WallTimeoutSeconds 1800, verified by a green rerun.')
    $rAok = 'd1runaok-' + $key
    Write-ObservedRecord -Copy $c -Root $p -RunId $rAok -CommandFingerprint $cmdA -AgeMinutes 0
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rAok -CommandFingerprint $cmdA -AgeMinutes 0
    $r = Fire -Copy $c -Cwd $p
    Check 'D1: resolving A does NOT allow completion - B (a DISTINCT incident) still blocks' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'idleTimeout') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    # THIS is the ledger assertion: a single-slot design would have overwritten A's
    # obligation with B's, leaving pending=1. The per-incident MAP keeps BOTH.
    Check 'D1: the persisted state now carries BOTH note obligations (A not forgotten when B registered)' (
        (Get-PendingCount $st) -eq 2) ('pending=' + (Get-PendingCount $st))
    # Resolve B: its OWN tagged durable note + a green rerun of cmdB. B's block ($r
    # from the fire above) carries B's distinct incident tag, not A's.
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('B idle-timeout hang fixed by clearing a stuck fixture service; not detected earlier because no idle bound existed. ' +
        'Guard: Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300, verified by a green rerun.')
    $rBok = 'd1runbok-' + $key
    Write-ObservedRecord -Copy $c -Root $p -RunId $rBok -CommandFingerprint $cmdB -AgeMinutes 0
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rBok -CommandFingerprint $cmdB -AgeMinutes 0
    $r = Fire -Copy $c -Cwd $p
    Check 'D1: completion is ALLOWED only once BOTH incidents are resolved+noted' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'D1: the persisted state carries BOTH resolved incident keys' ((Get-ResolvedCount $st) -eq 2) ('resolved=' + (Get-ResolvedCount $st))
    Check 'D1: no note obligation remains once both are satisfied' ((Get-PendingCount $st) -eq 0) ('pending=' + (Get-PendingCount $st))
    # No A<->B ping-pong: a further Stop stays silent - A never re-blocks.
    $r = Fire -Copy $c -Cwd $p
    Check 'D1: the next Stop stays silent - resolving B never re-opened A (no ping-pong)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'D1: both resolved keys persist across the extra Stop' ((Get-ResolvedCount $st) -eq 2) ('resolved=' + (Get-ResolvedCount $st))

    # =====================================================================
    Write-Host '--- D2: an incident that self-heals BEFORE any Stop still owes its durable note ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'D2SelfHeal'
    $key = Get-ProjectKey $p
    $rInc = 'd2inc-' + $key; $rHeal = 'd2heal-' + $key
    # The timeout AND its clean rerun are BOTH recorded before the hook ever fires.
    Write-ObservedRecord -Copy $c -Root $p -RunId $rInc -AgeMinutes 5
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'produced no output or state change for 300s' -RunId $rInc -AgeMinutes 5
    Write-ObservedRecord -Copy $c -Root $p -RunId $rHeal -AgeMinutes 0
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rHeal -AgeMinutes 0
    $r = Fire -Copy $c -Cwd $p
    Check 'D2: the FIRST Stop still demands the durable note even though the run is already green again' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'durable \.ai/ note is still owed' -and (Get-BlockReason $r.Out) -match 'idleTimeout') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'D2: the self-healed incident registered a note obligation on first sighting' ((Get-PendingCount $st) -eq 1) ('pending=' + (Get-PendingCount $st))
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('Idle-timeout self-healed before the Stop hook fired; recorded so the lesson is not lost. ' +
        'Not detected earlier because no idle bound existed. Guard: Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300.')
    $r = Fire -Copy $c -Cwd $p
    Check 'D2: once the durable note is written, completion is allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # A run that was NEVER an incident demands no note (unchanged behaviour).
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'D2NeverIncident'
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'D2: a plain clean run (never an incident) owes no note' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- D3: pruning respects one-to-one pairing (an unpaired observation is not deleted) ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'D3PruneUnpaired'
    $key = Get-ProjectKey $p
    # Two UNCONTROLLED observations of one command, ONE clean result, all >24h old.
    Write-ObservedRecord -Copy $c -Root $p -RunId ('d3o1-' + $key) -RunIdControlled:$false -AgeMinutes 0
    Write-ObservedRecord -Copy $c -Root $p -RunId ('d3o2-' + $key) -RunIdControlled:$false -AgeMinutes 0
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('d3r1-' + $key) -AgeMinutes 0
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-StateDir $c) -Filter 'TestRunGuard-*.json' -File)) {
        (Get-Item -LiteralPath $f.FullName).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    }
    $r = Fire -Copy $c -Cwd $p
    $survivingObs = @(Get-ChildItem -LiteralPath (Get-StateDir $c) -Filter 'TestRunGuard-observed-*.json' -File)
    Check 'D3: exactly ONE observation survives - the unpaired one is not deleted by a shared result' (
        $survivingObs.Count -eq 1) ('observed files=' + $survivingObs.Count)
    Check 'D3: the unpaired observation still BLOCKS as observed-without-result' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'no guarded result document exists') $r.Out
    # A SECOND result now pairs the surviving observation -> completion allowed.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('d3r2-' + $key) -AgeMinutes 0
    $r = Fire -Copy $c -Cwd $p
    Check 'D3: once a second result exists the surviving observation pairs one-to-one -> allowed' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- D4: OLD-STATE negatives get bounded retention; CURRENT-state negatives are kept forever ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'D4OldStateFailed'
    $key = Get-ProjectKey $p
    # (a) an OLD-STATE plain `failed` (no incident key, never superseded) older than
    #     the 7-day bound -> PRUNED (it can never be current evidence or block).
    $rFailOld = 'd4failold-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId $rFailOld -ProjectFingerprint 'd4-oldstate' -CommandFingerprint ('d4cmdold-' + $key)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rFailOld)).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    # (b) an OLD-STATE `failed` WITHIN the 7-day bound -> KEPT (bounded, not "prune all old-state").
    $rFailRecent = 'd4failrecent-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId $rFailRecent -ProjectFingerprint 'd4-oldstate2' -CommandFingerprint ('d4cmdrecent-' + $key)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rFailRecent)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    # (c) a CURRENT-state unresolved terminated of ANY age -> KEPT forever (round-19).
    $rTermCur = 'd4termcur-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x' -RunId $rTermCur -CommandFingerprint ('d4cmdcur-' + $key)
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rTermCur)).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8)
    $r = Fire -Copy $c -Cwd $p
    Check 'D4: an OLD-STATE failed result past the 7-day bound IS pruned (no unbounded growth)' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rFailOld))) $r.Out
    Check 'D4: an OLD-STATE failed result within the 7-day bound is still retained' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rFailRecent)) $r.Out
    Check 'D4: a CURRENT-state unresolved terminated of any age is NEVER pruned (round-19 kept)' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rTermCur)) $r.Out

    # =====================================================================
    Write-Host '--- R1: a superseded incident is note-demanded even when its files are pruned before the first Stop ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'R1RegisterBeforePrune'
    $key = Get-ProjectKey $p
    $rInc = 'r1inc-' + $key; $rGreen = 'r1green-' + $key; $cmd = 'r1cmd-' + $key
    # A terminated incident, then a NEWER green rerun of the SAME command (supersedes it).
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling' -RunId $rInc -CommandFingerprint $cmd -AgeMinutes 200
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rGreen -CommandFingerprint $cmd -AgeMinutes 1
    # The incident file is already >24h old at the first Stop, so the prune WOULD
    # delete it (superseded). Its note obligation must be registered BEFORE that.
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rInc)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    $r = Fire -Copy $c -Cwd $p
    Check 'R1: the superseded incident still demands its durable note at the first Stop (register-before-prune)' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'durable \.ai/ note is still owed' -and (Get-BlockReason $r.Out) -match 'wallTimeout') $r.Out
    Check 'R1: exactly one note obligation was registered before pruning' ((Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) ''
    Check 'R1: the superseded incident file WAS pruned - the obligation outlived it in the ledger' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rInc))) $r.Out
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('Wall-timeout self-healed before the first Stop; recorded so the lesson survives pruning. Guard: bounded wall ceiling, verified green.')
    $r = Fire -Copy $c -Cwd $p
    Check 'R1: once the tagged note is written, completion is allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- R2a: per-incident tags - one untagged 80-byte note cannot clear two incidents ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'R2aTags'
    $key = Get-ProjectKey $p
    # Two SUPERSEDED incidents (distinct commands + reasons) both registered in ONE
    # Stop by R1 -> the SAME baseline (0). Under the old byte-only check a single
    # 80-byte note cleared both; the per-incident tag now requires two.
    $cmdA = 'r2acmda-' + $key; $cmdB = 'r2acmdb-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x' -RunId ('r2ainca-' + $key) -CommandFingerprint $cmdA -AgeMinutes 200
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('r2agreena-' + $key) -CommandFingerprint $cmdA -AgeMinutes 1
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'x' -RunId ('r2aincb-' + $key) -CommandFingerprint $cmdB -AgeMinutes 200
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('r2agreenb-' + $key) -CommandFingerprint $cmdB -AgeMinutes 1
    $r = Fire -Copy $c -Cwd $p
    Check 'R2a: two superseded incidents each owe a note (same baseline)' ((Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 2) ('pending=' + (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)))
    $firstReason = Get-BlockReason $r.Out
    Check 'R2a: the first block names one incident tag to write' ((Get-IncidentTagLine $firstReason) -ne '') $firstReason
    # Write a note tagged for the FIRST incident only - substantial, well over 80 bytes,
    # but WITHOUT the other incident's tag.
    Add-TaggedNote -Root $p -Reason $firstReason -Body ('First incident fixed and documented with a real substantial prevention guard so a later session can act on it - well over eighty bytes of genuine content here.')
    $r = Fire -Copy $c -Cwd $p
    Check 'R2a: after ONE tagged note completion STILL blocks - the other incident is unresolved (an 80-byte note cannot clear both)' (
        $r.Out -match '"decision":"block"') $r.Out
    $secondReason = Get-BlockReason $r.Out
    Check 'R2a: exactly ONE obligation remains after the first tagged note' ((Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) ('pending=' + (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)))
    Check 'R2a: the remaining block names a DIFFERENT incident tag' (
        (Get-IncidentTagLine $secondReason) -ne '' -and (Get-IncidentTagLine $secondReason) -ne (Get-IncidentTagLine $firstReason)) ($firstReason + ' || ' + $secondReason)
    Add-TaggedNote -Root $p -Reason $secondReason -Body ('Second incident fixed and documented with its own substantial prevention guard, distinct from the first - again well over eighty bytes of genuine content here.')
    $r = Fire -Copy $c -Cwd $p
    Check 'R2a: only with BOTH tagged notes is completion allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- R2b: a full ledger of UNRESOLVED notes surfaces overflow; a satisfied entry is evicted first ---' -ForegroundColor Cyan
    # (part 1) 50 UNRESOLVED obligations pre-seeded (baselines impossibly high so none
    # can be satisfied). A 51st incident must NOT silently drop one - it surfaces.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'R2bOverflow'
    $key = Get-ProjectKey $p
    $seed = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 50; $i++) { [void]$seed.Add([pscustomobject]@{ key = ('seed-' + $i + '-' + $key); reason = ('seeded unresolved incident ' + $i); baseline = 100000000 }) }
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + $key + '.json')) (
        ([pscustomobject]@{ resolvedIncidents = @(); pendingNotes = @($seed.ToArray()); deferredFingerprint = ''; updatedUtc = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json -Depth 6)
    $cmd = 'r2bcmd-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x' -RunId ('r2binc-' + $key) -CommandFingerprint $cmd -AgeMinutes 200
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('r2bgreen-' + $key) -CommandFingerprint $cmd -AgeMinutes 1
    $r = Fire -Copy $c -Cwd $p
    Check 'R2b: overflow of unresolved notes surfaces as a block, not a silent drop' ($r.Out -match '"decision":"block"') $r.Out
    Check 'R2b: the block names the FULL-ledger overflow condition' ((Get-BlockReason $r.Out) -match 'ledger is FULL') (Get-BlockReason $r.Out)
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'R2b: NONE of the 50 unresolved obligations was dropped (cap held, nothing lost)' ((Get-PendingCount $st) -eq 50) ('pending=' + (Get-PendingCount $st))

    # (part 2) a SATISFIED entry in a full ledger IS evicted to make room; nothing
    # unresolved is lost and the cap still holds.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'R2bEvictSatisfied'
    $key = Get-ProjectKey $p
    Add-AiNote -Root $p -Text ('Test incident: sat-0-' + $key + "`n" +
        'This seeded obligation already has its tagged note written with real substantial content well over the byte floor so it is satisfiable and evictable.')
    $seed = New-Object System.Collections.Generic.List[object]
    [void]$seed.Add([pscustomobject]@{ key = ('sat-0-' + $key); reason = 'seeded SATISFIED incident 0'; baseline = 0 })
    for ($i = 1; $i -lt 50; $i++) { [void]$seed.Add([pscustomobject]@{ key = ('seed-' + $i + '-' + $key); reason = ('seeded unresolved incident ' + $i); baseline = 100000000 }) }
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + $key + '.json')) (
        ([pscustomobject]@{ resolvedIncidents = @(); pendingNotes = @($seed.ToArray()); deferredFingerprint = ''; updatedUtc = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json -Depth 6)
    $cmd = 'r2bcmd2-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'x' -RunId ('r2binc2-' + $key) -CommandFingerprint $cmd -AgeMinutes 200
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('r2bgreen2-' + $key) -CommandFingerprint $cmd -AgeMinutes 1
    $r = Fire -Copy $c -Cwd $p
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'R2b: a SATISFIED entry is evicted so the new incident fits (cap held at 50)' ((Get-PendingCount $st) -eq 50) ('pending=' + (Get-PendingCount $st))
    Check 'R2b: the evicted entry was RESOLVED, not lost' (
        @(@($st.resolvedIncidents) | Where-Object { [string]$_ -eq ('sat-0-' + $key) }).Count -eq 1) ''
    Check 'R2b: the NEW incident replaced the satisfied one and is now tracked' (
        @(@($st.pendingNotes) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['key'] -and [string]$_.key -notlike 'seed-*' -and [string]$_.key -ne ('sat-0-' + $key) }).Count -eq 1) ''

    # =====================================================================
    Write-Host '--- R3: two genuinely concurrent Stops each register a distinct incident; the merged ledger loses neither ---' -ForegroundColor Cyan
    # Each spawned process writes its OWN incident (a terminated run superseded by a
    # green rerun) into the SHARED state dir, then invokes the hook - so both hit the
    # ONE project ledger at ~the same time. Without the cross-process lock + re-read
    # merge in Save-CompletionState the later writer would clobber the earlier one.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'R3Concurrent'
    $key = Get-ProjectKey $p
    $fp = Get-Fingerprint $p
    $stateDir = Get-StateDir $c
    $pwshExe = (Get-Process -Id $PID).Path
    # A tiny wrapper: write the incident (terminated + green supersede) then dot-source
    # the hook so it runs against the same stdin/env this test provides.
    $wrapper = Join-Path $Work 'r3-concurrent-writer.ps1'
    Write-Utf8 $wrapper @'
param([string]$Hook, [string]$StateDir, [string]$ProjectKey, [string]$Fp, [string]$Cmd, [string]$TermRunId, [string]$GreenRunId, [string]$TerminateReason)
function Write-Doc { param($Path, $Obj) [System.IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false)) }
$safeTerm = ($TermRunId.ToLowerInvariant() -replace '[^a-z0-9]', '')
$safeGreen = ($GreenRunId.ToLowerInvariant() -replace '[^a-z0-9]', '')
$termEnded = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
$greenEnded = [DateTime]::UtcNow.ToString('o')
Write-Doc (Join-Path $StateDir ('TestRunGuard-result-' + $ProjectKey + '-' + $safeTerm + '.json')) ([ordered]@{
    schema = 2; overall = 'terminated'; fileName = 'pwsh'; runId = $TermRunId; projectFingerprint = $Fp; commandFingerprint = $Cmd
    terminated = $true; terminateReason = $TerminateReason; terminateDetail = 'x'; leakedProcessIds = @(); elapsedSeconds = 12.5
    lastProgress = 'Passed: 1  Failed: 0'; exitCode = 124; startedUtc = $termEnded; endedUtc = $termEnded })
Write-Doc (Join-Path $StateDir ('TestRunGuard-result-' + $ProjectKey + '-' + $safeGreen + '.json')) ([ordered]@{
    schema = 2; overall = 'ok'; fileName = 'pwsh'; runId = $GreenRunId; projectFingerprint = $Fp; commandFingerprint = $Cmd
    terminated = $false; terminateReason = ''; terminateDetail = ''; leakedProcessIds = @(); elapsedSeconds = 10
    lastProgress = 'Passed: 5  Failed: 0'; exitCode = 0; startedUtc = $greenEnded; endedUtc = $greenEnded })
. $Hook
'@
    $evt = @{ session_id = 'r3'; cwd = $p; hook_event_name = 'Stop' } | ConvertTo-Json -Depth 5
    $inFile = Join-Path $Work ('r3in-' + $key + '.json'); Write-Utf8 $inFile $evt
    $procs = New-Object System.Collections.Generic.List[object]
    foreach ($spec in @(
            @{ Cmd = ('r3cmda-' + $key); Term = ('r3terma-' + $key); Green = ('r3greena-' + $key); Reason = 'wallTimeout' },
            @{ Cmd = ('r3cmdb-' + $key); Term = ('r3termb-' + $key); Green = ('r3greenb-' + $key); Reason = 'idleTimeout' })) {
        $argLine = '-NoLogo -NoProfile -File "' + $wrapper + '" -Hook "' + $c.Script + '" -StateDir "' + $stateDir +
        '" -ProjectKey "' + $key + '" -Fp "' + $fp + '" -Cmd "' + $spec.Cmd + '" -TermRunId "' + $spec.Term +
        '" -GreenRunId "' + $spec.Green + '" -TerminateReason "' + $spec.Reason + '"'
        $sa = @{
            FilePath = $pwshExe; ArgumentList = $argLine; RedirectStandardInput = $inFile
            RedirectStandardOutput = (Join-Path $Work ('r3out-' + $spec.Reason + '.txt'))
            RedirectStandardError  = (Join-Path $Work ('r3err-' + $spec.Reason + '.txt'))
            NoNewWindow = $true; PassThru = $true
        }
        if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
            $sa.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $c.LocalAppData; CLAUDE_PROJECT_DIR = $p }
        }
        [void]$procs.Add((Start-Process @sa))
    }
    foreach ($pr in $procs) { [void]$pr.WaitForExit(30000); if (-not $pr.HasExited) { try { $pr.Kill(); [void]$pr.WaitForExit(5000) } catch { } } }
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'R3: BOTH concurrent incidents survive in the merged ledger - no lost update' (
        (Get-PendingCount $st) -eq 2) ('pending=' + (Get-PendingCount $st))

    # =====================================================================
    Write-Host '--- migration: the old single-value state shape is read and rewritten as the ledger ---' -ForegroundColor Cyan
    # A legacy pendingNoteKey/Reason/Baseline is still ENFORCED after migration.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'MigrateLegacyNote'
    $legacyPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $legacyPath (([ordered]@{
                resolvedIncident = ''; pendingNoteKey = 'legacy-key-xyz'; pendingNoteReason = 'a legacy migrated incident'
                pendingNoteBaseline = 0; deferredFingerprint = ''; updatedUtc = [DateTime]::UtcNow.ToString('o')
            }) | ConvertTo-Json)
    $r = Fire -Copy $c -Cwd $p
    Check 'migration: a legacy single-value pendingNoteKey is still enforced as an owed note' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'a legacy migrated incident') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'migration: the state is rewritten in the new collection shape (pendingNotes, no old scalar)' (
        (Get-PendingCount $st) -eq 1 -and $null -ne $st.PSObject.Properties['pendingNotes'] -and $null -eq $st.PSObject.Properties['pendingNoteKey']) $r.Out
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('Legacy migrated incident closed out with a real note describing the cause and the verified prevention guard so a later session can act on it.')
    $r = Fire -Copy $c -Cwd $p
    Check 'migration: writing the note clears the migrated obligation -> completion allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'migration: the satisfied legacy key is now carried in resolvedIncidents' ((Get-ResolvedCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) ''

    # A legacy resolvedIncident is carried forward into the resolvedIncidents SET.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'MigrateLegacyResolved'
    $legacyPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $legacyPath (([ordered]@{
                resolvedIncident = 'legacy-resolved-abc'; pendingNoteKey = ''; pendingNoteReason = ''
                pendingNoteBaseline = -1; deferredFingerprint = ''; updatedUtc = [DateTime]::UtcNow.ToString('o')
            }) | ConvertTo-Json)
    # A clean current run makes the hook reach its final save so the migrated shape is written out.
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'migration: a legacy resolvedIncident with a clean run stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'migration: the legacy resolvedIncident is carried into the resolvedIncidents set' (
        (Get-ResolvedCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) ''

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
    # An UNTAGGED real note (long enough to clear the byte floor) still does NOT
    # satisfy it - the incident's own tag is required.
    Add-AiNote -Root $p -Text ('Idle-timeout hang in the integration suite: the runner reported no output for 300s. ' +
        'Not detected earlier because no idle bound existed at all. Guard: Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300, verified by re-running the suite.')
    $r = Fire -Copy $c -Cwd $p
    Check 'a long but UNTAGGED note does not satisfy the requirement - the incident tag is required' ($r.Out -match '"decision":"block"') $r.Out
    # Now write the SAME note tagged with the incident key the block names.
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('Idle-timeout hang in the integration suite (tagged); guard Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300.')
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
    Add-TaggedNote -Root $p3 -Reason (Get-BlockReason $r.Out) -Body ('Full suite run through the guarded runner completed clean; recorded here because this project requires a note per run. ' +
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
    Write-Host '--- E-05: ::deep-debug activation - prose never triggers, the standalone token does ---' -ForegroundColor Cyan
    # Activation signal 2: a transcript_path in the hook's OWN stdin whose
    # bounded tail carries the standalone token. Prose "deep debug" must not.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdProse'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $proseTranscript = Join-Path $Work 'transcript-prose.jsonl'
    Write-Utf8 $proseTranscript ('{"type":"user","message":{"role":"user","content":"let us deep debug the parser and deep-debug more"}}' + "`n")
    $r = Fire -Copy $c -Cwd $p -TranscriptPath $proseTranscript
    Check 'prose "deep debug" in the transcript does NOT activate the gate (clean run stays silent)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'prose left no deep-debug marker behind' (
        -not (Test-Path -LiteralPath (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json'))))
    # The standalone token activates: clean fresh evidence -> DEEP DEBUG: COMPLETE.
    $ddTranscript = Join-Path $Work 'transcript-dd.jsonl'
    Write-Utf8 $ddTranscript ('{"type":"user","message":{"role":"user","content":"::deep-debug the parser"}}' + "`n")
    $r = Fire -Copy $c -Cwd $p -TranscriptPath $ddTranscript
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'standalone ::deep-debug + clean fresh evidence -> non-blocking COMPLETE advisory (Claude shape)' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        [string]$doc.hookSpecificOutput.additionalContext -match '(?m)^DEEP DEBUG: COMPLETE$') $r.Out
    $ddCtx = [string]$doc.hookSpecificOutput.additionalContext
    Check 'COMPLETE names the verified test-evidence scope' ($ddCtx -match 'Test-evidence scope verified' -and $ddCtx -match 'fresh clean result') $ddCtx
    Check 'COMPLETE honestly lists what this hook CANNOT verify (goal/integration/review/Ponytail/UTF-8/CI)' (
        $ddCtx -match 'NOT verifiable by this hook' -and $ddCtx -match '/goal' -and $ddCtx -match 'Ponytail' -and
        $ddCtx -match 'Utf8-Encoding-Check' -and $ddCtx -match 'exact-final-SHA CI') $ddCtx
    Check 'free-form done text is named as never-proof' ($ddCtx -match '"done" text is never proof') $ddCtx
    Check 'the session-bound marker was written (schema-versioned)' (
        (Test-Path -LiteralPath (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json'))))
    # Anti-loop: same session + unchanged state -> the COMPLETE advisory does not repeat.
    $r = Fire -Copy $c -Cwd $p -TranscriptPath $ddTranscript
    Check 'anti-loop: unchanged COMPLETE state is silent on the next Stop of the same session' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- E-05: marker-only activation, no-evidence BLOCKED, once per session ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdNoEvidence'
    # Activation signal 3: a marker from an earlier Stop of the SAME session.
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 1; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'deep-debug active with NO guarded evidence -> blocks' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block carries the exact DEEP DEBUG: BLOCKED (reason) line' ($reason -match '(?m)^DEEP DEBUG: BLOCKED \(') $reason
    Check 'the block names the missing evidence and the guarded-runner recovery' (
        $reason -match 'NO guarded test evidence' -and $reason -match 'Run-Tests-Guarded\.ps1') $reason
    # Once per session: the unchanged no-evidence state does not re-block.
    $r = Fire -Copy $c -Cwd $p
    Check 'anti-loop: the unchanged no-evidence BLOCKED state emits once per session' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    # Changed state re-evaluates immediately: fresh clean evidence -> COMPLETE.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'changed state (fresh clean evidence) upgrades to the COMPLETE advisory immediately' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        [string]$doc.hookSpecificOutput.additionalContext -match '(?m)^DEEP DEBUG: COMPLETE$') $r.Out
    # A marker from a DIFFERENT session is stale: removed, never activates.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdStaleMarker'
    $staleMarkerPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $staleMarkerPath ((@{ schema = 1; sessionId = 'some-other-session'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    $r = Fire -Copy $c -Cwd $p
    Check 'a different-session marker never activates the gate (no output)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'the stale marker is removed' (-not (Test-Path -LiteralPath $staleMarkerPath))

    # =====================================================================
    Write-Host '--- E-05: existing blocks carry the BLOCKED line only under deep-debug ---' -ForegroundColor Cyan
    # Normal behavior unchanged: the SAME terminated-run scenario as the original
    # suite section, WITHOUT deep-debug - no DEEP DEBUG line anywhere.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'DdOffTerminated'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'non-deep-debug: the terminated block still fires exactly as before' ($reason -match 'wallTimeout') $reason
    Check 'non-deep-debug: NO DEEP DEBUG verdict line is present' ($reason -notmatch 'DEEP DEBUG') $reason
    # Under deep-debug the same block gains the BLOCKED verdict with a concise reason.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdOnTerminated'
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 1; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'deep-debug: the terminated block carries DEEP DEBUG: BLOCKED (concise reason)' (
        $reason -match 'wallTimeout' -and $reason -match '(?m)^DEEP DEBUG: BLOCKED \(.+\)') $reason
    Check 'the BLOCKED reason is concise (derived from the finding, not the whole message)' (
        ([regex]::Match($reason, 'DEEP DEBUG: BLOCKED \(([^)]+)\)').Groups[1].Value.Length) -le 170) $reason

    # =====================================================================
    Write-Host '--- E-05: stale/unproven evidence under deep-debug never reads COMPLETE ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdStaleResult'
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 1; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 200   # stale: > default 180 evidence window
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a stale ok result under deep-debug -> BLOCKED, never COMPLETE' (
        $r.Out -match '"decision":"block"' -and $reason -match 'STALE or not a clean current-state result' -and
        $reason -match '(?m)^DEEP DEBUG: BLOCKED \(' -and $reason -notmatch 'DEEP DEBUG: COMPLETE') $reason
    $r = Fire -Copy $c -Cwd $p
    Check 'anti-loop: the unchanged stale-evidence BLOCKED state emits once per session' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- E-05: Codex shape for the deep-debug outputs ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'DdCodex'
    Write-Utf8 (Join-Path (Get-StateDir $c) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $p) + '.json')) (
        (@{ schema = 1; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p -Codex
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'Codex COMPLETE advisory uses systemMessage, never decision:block' (
        $null -ne $doc -and $null -eq $doc.PSObject.Properties['decision'] -and
        $null -eq $doc.PSObject.Properties['hookSpecificOutput'] -and
        [string]$doc.systemMessage -match '(?m)^DEEP DEBUG: COMPLETE$') $r.Out

    # =====================================================================
    Write-Host '--- E-13: static safety - the hook never executes commands, codewords, or skills ---' -ForegroundColor Cyan
    $tccText = [System.IO.File]::ReadAllText($Hook)
    Check 'source has no execution primitive in statement position (Start-Process/Invoke-Expression/iex)' (
        $tccText -notmatch '(?im)^\s*(Start-Process|Invoke-Expression|iex)\b') $tccText.Substring(0, 200)
    Check 'source never applies the call operator to data (no "& $var" execution path)' ($tccText -notmatch '&\s+\$') $tccText.Substring(0, 200)
    Check 'source references /goal and ::deep-debug only as text, never in statement position' (
        $tccText -match '::deep-debug' -and $tccText -notmatch '(?im)^\s*/(goal|ponytail)' -and $tccText -notmatch '(?im)^\s*::deep-debug') $tccText.Substring(0, 200)
    Check 'the transcript tail is only MATCHED, never persisted (no transcript text in any state write)' (
        $tccText -notmatch 'WriteAllText\([^)]*tailText' -and $tccText -notmatch 'transcriptText\s*=') $tccText.Substring(0, 200)

    # =====================================================================
    Write-Host '--- E-13 RED-PROOF: the pre-fix hook emits no DEEP DEBUG verdict (HEAD copy, retire-guarded) ---' -ForegroundColor Cyan
    # Reconstructed via read-only `git show HEAD:` (never a tree mutation). FIX
    # MARKER retire guard: once the dd gate is committed HEAD contains
    # 'DEEP DEBUG:' and this historical proof retires (byte/extent equality is
    # never used - git show emits LF while working files are CRLF).
    $tccRepoRoot = Split-Path -Parent $PSScriptRoot
    $tccPreText = ((& git -C $tccRepoRoot show 'HEAD:hooks/Test-Completion-Check/Test-Completion-Check.ps1') -join "`n")
    if ($tccPreText -match 'DEEP DEBUG:') {
        Write-Host 'HEAD already contains the deep-debug gate; historical red-proof retired.' -ForegroundColor DarkGray
    }
    else {
        $tccPreDir = Join-Path $Work '_prefix-tcc'
        New-Item -ItemType Directory -Path $tccPreDir -Force | Out-Null
        $tccPreHook = Join-Path $tccPreDir 'Test-Completion-Check.ps1'
        [System.IO.File]::WriteAllText($tccPreHook, $tccPreText, (New-Object System.Text.UTF8Encoding $false))
        Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
        $tccPreLocal = Join-Path $tccPreDir '_fakelocal-prefix'
        New-Item -ItemType Directory -Path (Join-Path $tccPreLocal 'HookMaker\state') -Force | Out-Null
        $preCopy = [pscustomobject]@{ Script = $tccPreHook; LocalAppData = $tccPreLocal }
        $pRed = New-GitRepoAi 'DdRed'
        Write-Utf8 (Join-Path (Get-StateDir $preCopy) ('TestCompletionCheck-deepdebug-' + (Get-ProjectKey $pRed) + '.json')) (
            (@{ schema = 1; sessionId = 'sess1'; detectedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json))
        Write-GuardedResult -Copy $preCopy -Root $pRed -Overall 'ok'
        $ddRedTranscript = Join-Path $Work 'transcript-dd-red.jsonl'
        Write-Utf8 $ddRedTranscript ('{"type":"user","message":{"role":"user","content":"::deep-debug the parser"}}' + "`n")
        $rRed = Fire -Copy $preCopy -Cwd $pRed -TranscriptPath $ddRedTranscript
        Check 'RED-PROOF: the PRE-FIX hook emits NO DEEP DEBUG verdict for an active deep-debug session' (
            $rRed.Exit -eq 0 -and $rRed.Out -notmatch 'DEEP DEBUG') $rRed.Out
    }

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
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
