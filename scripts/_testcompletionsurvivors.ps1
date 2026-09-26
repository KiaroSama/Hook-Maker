# Test-TestCompletionCheck.ps1 scenario block: POSSIBLE ORPHANED TEST PROCESSES
# (hooks\Test-Completion-Check\_survivors.ps1).
#
# Proves the four properties the advisory is required to have: it NAMES a
# matching process that started after this session's SessionStart baseline, it
# is SILENT when none does (outside the window, or outside the pattern set, or
# with no baseline for this session), it reports a CAPPED list honestly as
# partial, and it NEVER blocks - on either client shape, and never in place of a
# real gate.
#
# ONE long-lived child is started here (powershell -Command Start-Sleep 30),
# shared by every case that needs a live candidate, and terminated + verified in
# this block's own finally: a suite that proves the no-orphan rule may not leak
# a process of its own.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

# The SessionStart baseline the advisory reads: Test-Temp-Cleanup's, the only
# one this state directory has. Written here exactly as that hook writes it.
function Write-SessionBaseline {
    param([object]$Copy, [string]$Root, [datetime]$Utc, [string]$SessionId = 'sess1')
    $doc = [ordered]@{
        sessionId = $SessionId; projectKey = (Get-ProjectKey $Root)
        repoStateFingerprint = ''; scanComplete = $true; partialCauses = @()
        timestampUtc = $Utc.ToString('o'); candidates = @()
    }
    Write-Utf8 (Join-Path (Get-StateDir $Copy) ('TestTempCleanup-baseline-' + (Get-ProjectKey $Root) + '.json')) ($doc | ConvertTo-Json -Depth 5)
}

# Stop advisories use the same non-continuing systemMessage on both clients.
# Get-Field throughout: under Set-StrictMode 2.0 a missing property THROWS, and
# a regression must show up as a failed assertion, never as an aborted module.
function Get-AdvisoryText {
    param([string]$Text)
    $doc = ConvertFrom-HookOutput $Text
    if ($null -eq $doc) { return '' }
    return [string](Get-Field $doc 'systemMessage')
}

    # =====================================================================
    Write-Host '--- possible orphaned test processes: advisory only, never a gate ---' -ForegroundColor Cyan

$survivorSentinel = $null
$cohortSentinel = $null
try {
    # ---- (a) a matching image started AFTER the baseline is named ----------
    # The window is anchored one second before the child's OWN start time, so on
    # a busy machine the child is still among the first rows (they are ordered by
    # start time) and cannot be pushed out of the printed cap.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'SurvivorSeen'
    # THE SENTINEL IS A GRANDCHILD, started by a launcher that exits at once -
    # the shape a real survivor has (the client starts a tool shell, the tool
    # shell starts the test, the shell goes away). A process started DIRECTLY by
    # this suite is a direct child of one of the fired hook's own ancestors,
    # which is the CLIENT'S OWN COHORT: the other hooks of the same dispatch, the
    # MCP servers, the tool shell. That cohort is excluded by design, and the
    # $cohortSentinel below is the case that proves it.
    $sentinelPidFile = Join-Path $Work ('survivor-pid-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $launcherPath = Join-Path $Work ('survivor-launch-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
    Write-Utf8 $launcherPath (
        '$child' + " = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo', '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru -WindowStyle Hidden" + [Environment]::NewLine +
        "Set-Content -LiteralPath '" + $sentinelPidFile + "' -Value " + '$child' + ".Id" + [Environment]::NewLine)
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo', '-NoProfile', '-File', $launcherPath -WindowStyle Hidden | Out-Null
    # Bounded wait on the real readiness signal (the pid file), never a blind sleep.
    $sentinelPid = 0
    for ($attempt = 0; $attempt -lt 100 -and $sentinelPid -le 0; $attempt++) {
        $raw = ''
        try { if (Test-Path -LiteralPath $sentinelPidFile -PathType Leaf) { $raw = ([System.IO.File]::ReadAllText($sentinelPidFile)).Trim() } } catch { $raw = '' }
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) { $sentinelPid = $parsed }
        if ($sentinelPid -le 0) { Start-Sleep -Milliseconds 100 }
    }
    Check 'the sentinel grandchild started and reported its pid' ($sentinelPid -gt 0) $sentinelPidFile
    if ($sentinelPid -le 0) { throw 'the survivor sentinel could not be started' }
    $survivorSentinel = Get-Process -Id $sentinelPid -ErrorAction Stop
    [void](Wait-ProcessReady -ProcessId $survivorSentinel.Id)
    # The negative fixture: the client's own cohort, started the way the 18 Stop
    # hooks of one dispatch are - a direct child of an ancestor of the hook.
    $cohortSentinel = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -Command Start-Sleep 30' -PassThru -WindowStyle Hidden
    [void](Wait-ProcessReady -ProcessId $cohortSentinel.Id)
    $survivorWindow = [datetime]::UtcNow.AddSeconds(-3)
    try { $survivorWindow = $survivorSentinel.StartTime.ToUniversalTime().AddSeconds(-1) } catch { }
    Write-SessionBaseline -Copy $c -Root $p -Utc $survivorWindow
    $r = Fire -Copy $c -Cwd $p
    $text = Get-AdvisoryText $r.Out
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'a matching process started after the session baseline is listed by pid' (
        $text -match ('(?m)^  pid ' + $survivorSentinel.Id + '\b')) $r.Out
    Check 'the row carries the start time and the command line' (
        $text -match ('(?m)^  pid ' + $survivorSentinel.Id + '  started \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z  .*powershell')) $r.Out
    Check 'the advisory names itself as advisory and states the hook kills nothing' (
        $text -match 'possible orphaned test processes started during this session' -and
        $text -match 'cannot prove ownership and kills nothing') $r.Out
    Check 'the advisory instructs the survivor sweep and cites the rule' (
        $text -match 'Run the survivor sweep before finishing \(global-test-rules\.md -> No Orphaned Test Processes; it loads on demand, so read it in full before this work\)') $r.Out
    Check 'the survivor advisory NEVER blocks: no decision, exit 0' (
        $r.Exit -eq 0 -and $r.Err -eq '' -and $null -ne $doc -and
        $null -ne $doc.PSObject.Properties['systemMessage'] -and
        $null -eq $doc.PSObject.Properties['hookSpecificOutput'] -and
        $null -eq $doc.PSObject.Properties['decision']) $r.Out
    # The loop this cost: 13 consecutive Stops in one measured session, each
    # emission a forced turn, because the client's own cohort churns the row set
    # and with it the repeat-suppression fingerprint. Neither half may return.
    Check 'the client cohort (a direct child of the hook''s own ancestor) is NOT listed as a survivor' (
        [string]$text -notmatch ('(?m)^  pid ' + $cohortSentinel.Id + ' ')) $r.Out
    Check 'it is bounded per session: the repeat-suppression fingerprint is recorded' (
        (Test-Path -LiteralPath (Join-Path (Get-StateDir $c) ('TestCompletionCheck-survivors-' + (Get-ProjectKey $p) + '.txt')) -PathType Leaf))

    # The historical model-context advisory could force another turn. The
    # current wire output does not, but unchanged continuation delivery remains
    # suppressed: a new envelope is not a reason to repeat the same sweep note.
    $cCont = New-IsolatedHookCopy
    $pCont = New-GitRepo 'SurvivorContinuation'
    Write-SessionBaseline -Copy $cCont -Root $pCont -Utc $survivorWindow
    $r = Fire -Copy $cCont -Cwd $pCont -StopHookActive
    Check 'during a continuation the survivor advisory says nothing, so it cannot repeat itself into a loop' (
        $r.Exit -eq 0 -and [string]$r.Out -eq '') $r.Out
    # ... and the genuine Stop that follows still reports, so the guard suppresses
    # the repeat and not the finding.
    $r = Fire -Copy $cCont -Cwd $pCont
    Check 'the next genuine Stop still names the survivor (the guard drops repeats, not findings)' (
        (Get-AdvisoryText $r.Out) -match ('(?m)^  pid ' + $survivorSentinel.Id + ' ')) $r.Out

    # Same finding on Codex: the Stop advisory shape, never decision:block
    # (a Codex Stop block forces a new prompt - an advisory loop).
    $c2 = New-IsolatedHookCopy
    $p2 = New-GitRepo 'SurvivorSeenCodex'
    Write-SessionBaseline -Copy $c2 -Root $p2 -Utc ([datetime]::UtcNow.AddMinutes(-1))
    $r = Fire -Copy $c2 -Cwd $p2 -Codex
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'Codex: the survivor advisory uses systemMessage and never decision:block' (
        $r.Exit -eq 0 -and $null -ne $doc -and $null -eq (Get-Field $doc 'decision') -and
        [string](Get-Field $doc 'systemMessage') -match 'possible orphaned test processes') $r.Out
    Check 'Codex: no Claude-only field is invented for it' (
        $null -ne $doc -and $null -eq (Get-Field $doc 'hookSpecificOutput')) $r.Out

    # ---- (b) nothing to report -> total silence ---------------------------
    # b1: the same live child, but the baseline is LATER than its start, so it
    # is outside this session's window and must not be named.
    $c3 = New-IsolatedHookCopy
    $p3 = New-GitRepo 'SurvivorWindow'
    Write-SessionBaseline -Copy $c3 -Root $p3 -Utc ([datetime]::UtcNow.AddSeconds(5))
    $r = Fire -Copy $c3 -Cwd $p3
    Check 'a process that started BEFORE the session baseline is not a survivor of this session' (
        $r.Exit -eq 0 -and [string]$r.Out -notmatch ('pid ' + $survivorSentinel.Id + '\b')) $r.Out

    # b2: no image matches the configured set -> the hook says nothing at all.
    $c4 = New-IsolatedHookCopy @{ TEST_COMPLETION_SURVIVOR_PATTERNS = 'zzz-hookmaker-no-such-image*' }
    $p4 = New-GitRepo 'SurvivorNone'
    Write-SessionBaseline -Copy $c4 -Root $p4 -Utc ([datetime]::UtcNow.AddMinutes(-5))
    $r = Fire -Copy $c4 -Cwd $p4
    Check 'no matching process at all -> silence, not an all-clear message' (
        $r.Exit -eq 0 -and [string]$r.Out -eq '' -and [string]$r.Err -eq '') $r.Out

    # b3: no SessionStart baseline for THIS session -> the check is simply not
    # evaluated. It never invents a window, and never widens one from another
    # session's baseline.
    $c5 = New-IsolatedHookCopy
    $p5 = New-GitRepo 'SurvivorNoBaseline'
    $r = Fire -Copy $c5 -Cwd $p5
    Check 'no SessionStart baseline -> the survivor check is not evaluated (silent)' (
        $r.Exit -eq 0 -and [string]$r.Out -eq '') $r.Out
    Write-SessionBaseline -Copy $c5 -Root $p5 -Utc ([datetime]::UtcNow.AddMinutes(-5)) -SessionId 'a-different-session'
    $r = Fire -Copy $c5 -Cwd $p5
    Check 'a baseline from ANOTHER session is not used as this session''s window' (
        $r.Exit -eq 0 -and [string]$r.Out -eq '') $r.Out

    # ---- (c) a capped list reports its partial coverage honestly ----------
    # Every image matches and the window opens at the epoch, so the machine's
    # own process list is guaranteed to overflow the row cap.
    $c6 = New-IsolatedHookCopy @{ TEST_COMPLETION_SURVIVOR_PATTERNS = '*' }
    $p6 = New-GitRepo 'SurvivorCapped'
    Write-SessionBaseline -Copy $c6 -Root $p6 -Utc ([datetime]'1970-01-01T00:00:00Z')
    $r = Fire -Copy $c6 -Cwd $p6
    $text = Get-AdvisoryText $r.Out
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'the printed rows are capped at 10' (
        (@(($text -split "`n") | Where-Object { $_ -match '^  pid \d+' }).Count) -eq 10) $r.Out
    Check 'the overflow is reported honestly as PARTIAL coverage, with the count' (
        $text -match '\.\.\. and \d+ more matching process\(es\) not listed' -and
        $text -match 'capped at 10 rows, so the coverage shown here is PARTIAL') $r.Out
    Check 'a capped list still never blocks' (
        $r.Exit -eq 0 -and $r.Err -eq '' -and $null -ne $doc -and
        $null -ne $doc.PSObject.Properties['systemMessage'] -and
        $null -eq $doc.PSObject.Properties['hookSpecificOutput'] -and
        $null -eq $doc.PSObject.Properties['decision']) $r.Out

    # ---- the advisory never displaces a real gate -------------------------
    # A terminated guarded result blocks exactly as before WITH a live candidate
    # present: the survivor list is emitted only where the hook would be silent.
    $c7 = New-IsolatedHookCopy
    $p7 = New-GitRepo 'SurvivorVsGate'
    Write-SessionBaseline -Copy $c7 -Root $p7 -Utc ([datetime]::UtcNow.AddMinutes(-5))
    Write-GuardedResult -Copy $c7 -Root $p7 -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c7 -Cwd $p7
    $doc = ConvertFrom-HookOutput $r.Out
    Check 'an existing block condition still blocks, and the advisory does not pre-empt it' (
        $null -ne $doc -and [string](Get-Field $doc 'decision') -eq 'block' -and
        [string](Get-Field $doc 'reason') -match 'wallTimeout' -and
        [string](Get-Field $doc 'reason') -notmatch 'possible orphaned test processes') $r.Out

    # ---- static: this file can neither kill nor over-enumerate -------------
    $survivorSrc = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $Hook) '_survivors.ps1'))
    Check 'the survivor module terminates nothing (no Stop-Process/Kill/taskkill)' (
        $survivorSrc -notmatch '(?i)(Stop-Process|taskkill|\.Kill\(|Stop-ProcessTree)') $survivorSrc.Substring(0, 200)
    Check 'it reads no process memory or environment - only the CIM metadata fields' (
        $survivorSrc -notmatch '(?i)(OpenProcess|ReadProcessMemory|Win32_ProcessEnvironment|GetEnvironmentVariable)') $survivorSrc.Substring(0, 200)
    # Counted over CODE lines only: the header documents the same call by name.
    $survivorCode = @(($survivorSrc -split "`n") | Where-Object { $_.TrimStart() -notlike '#*' })
    Check 'enumeration is ONE bounded CIM call with its own operation timeout' (
        (@($survivorCode | Where-Object { $_ -match 'Get-CimInstance' }).Count -eq 1) -and
        $survivorSrc -match 'OperationTimeoutSec') $survivorSrc.Substring(0, 200)
}
finally {
    # The rule this feature is about applies to this suite first: terminate the
    # child it started, then VERIFY it is gone rather than assuming the kill worked.
    foreach ($sentinel in @($survivorSentinel, $cohortSentinel)) {
        if ($null -eq $sentinel) { continue }
        try { $sentinel.Kill(); [void]$sentinel.WaitForExit(10000) } catch { }
        Check 'the suite leaves no survivor of its own (sentinel verified terminated)' (
            $null -eq (Get-Process -Id $sentinel.Id -ErrorAction SilentlyContinue))
    }
}
