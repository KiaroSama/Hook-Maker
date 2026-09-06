# Test-TestCompletionCheck.ps1 scenario block: the CORE GATE - the recursion
# guard, total silence when no test work is relevant, a fresh clean result
# allowing completion, terminated / leaked / failed results blocking with the
# reason and recovery named, STALE evidence and the evidence-window boundary,
# the run-identity gate (scope A), the pid-reuse-resistant active marker
# (scope C), a MISSING result for an observed run, a live guarded run, and
# concurrent runs in one project aggregating per-run files (Defect 1).
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses
# its harness, helpers and workspace) - not a standalone suite.

    # A fixture process must be PROVEN dead before a marker is written for it,
    # and the wait must be bounded: an unbounded WaitForExit() inside the suite
    # whose whole subject is unbounded waits would hang exactly where it must
    # not. The house pattern (hooks\_hooklib.ps1 Invoke-QuietCommand) is a
    # millisecond ceiling, then Stop-ProcessTree on expiry. These fixtures have
    # no redirected pipes, so there is nothing to drain first. The result is an
    # ASSERTION, never a best-effort swallow: a fixture that will not die fails
    # the suite instead of silently invalidating the case built on it.
    function Wait-FixtureExit {
        param([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 10000)
        if ($null -eq $Process) { return $false }
        if ($Process.WaitForExit($TimeoutMs)) { return $true }
        try { Stop-ProcessTree -ProcessId $Process.Id } catch { }
        return $Process.WaitForExit(5000)
    }

    # Age an already-written active marker by rewriting its recorded creation
    # time. The horizon is read from the document, so this makes a "previous
    # session" deterministic without touching the clock or file timestamps.
    function Set-MarkerAge {
        param([object]$Copy, [string]$Root, [string]$RunId = '', [double]$AgeHours)
        $path = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'active' -RunId $RunId
        $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $doc.markerCreatedUtc = [DateTime]::UtcNow.AddHours(-$AgeHours).ToString('o')
        Write-Utf8 $path ($doc | ConvertTo-Json -Depth 4)
    }

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

    # Same live pid, but the recorded start time does not match -> pid reuse. The
    # marker is never ACTIVE; with the run's own result on record it is merely
    # leftover, so the Stop is silent and the marker is cleaned.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerStartMismatch'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $PID -StartUtc '2000-01-01T00:00:00.0000000Z'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'a live pid with a mismatched process start time is ignored as stale (no block)' ($r.Out -eq '') $r.Out
    $markerGone = -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))
    Check 'the stale (pid-reuse) marker is cleaned up' $markerGone

    # Same live pid, mismatched executable path -> stale.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerExeMismatch'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $PID -ExePath 'C:\Windows\System32\notepad.exe'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'a live pid running a different executable is ignored as stale (no block)' ($r.Out -eq '') $r.Out

    # A dead pid is ignored and its marker cleaned.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'MarkerDead'
    $deadProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
    Check 'the dead-owner fixture exits within its bound (an unbounded wait here would hang the very suite that hunts hangs)' (Wait-FixtureExit $deadProc)
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $deadProc.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'x'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
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
    Check 'the live-run sentinel exits within its bound' (Wait-FixtureExit $sentinel)
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'   # the run ended AND recorded how
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
    Check 'the run-A fixture exits within its bound' (Wait-FixtureExit $deadA)
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $deadA.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'x' -RunId $rA
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId $rA   # run A ended and recorded how
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $sentinel.Id -RunId $rB
    $r = Fire -Copy $c -Cwd $p
    Check 'run B''s live marker blocks even though run A''s marker is stale' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STILL ACTIVE') $r.Out
    Check 'run A''s stale marker is removed, but run B''s LIVE marker is NOT deleted' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active' -RunId $rA)) -and
        (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active' -RunId $rB)))
    $sentinel.Kill(); Check 'the run-B sentinel exits within its bound' (Wait-FixtureExit $sentinel); $sentinel = $null

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
    # THE ACTIVE-RECORD STATE MACHINE: live / finished / died / expired.
    #
    # The defect these close, from the session that produced them: on Stop the
    # gate blocked with "a guarded test run is STILL ACTIVE (owner process 38004
    # is alive)" while the run it named had already finished green. 38004 was
    # alive - but it was a BRAND-NEW guarded runner that had merely inherited the
    # pid of the marker's long-dead owner. Liveness was pinned to the pid plus an
    # OPTIONAL start time, and whenever that field was absent, empty or
    # unparseable the check fell back to the pid alone; the executable path is no
    # discriminator, because whatever recycles a pwsh pid is almost always
    # another pwsh. A probe against the shipped function reproduced it directly:
    # a marker with an empty ownerProcessStartUtc and a recycled pid returned
    # that pid as a live owner. Identity is now mandatory - there is no pid-only
    # path - and the three states a non-live record can be in are told apart with
    # evidence instead of all being deleted in silence.
    Write-Host '--- active records: live vs finished vs died vs expired (pid reuse) ---' -ForegroundColor Cyan

    # A live pwsh standing in for whatever inherited a recycled pid.
    $recycler = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 45') -PassThru -WindowStyle Hidden
    Check 'the pid-recycler stand-in is fully queryable before any marker names it' (Wait-ProcessReady -ProcessId $recycler.Id)
    $recyclerExe = (Get-Process -Id $recycler.Id).Path

    # THE REPORTED DEFECT. Marker with NO recorded start time, its pid now held
    # by an unrelated live pwsh, and the run's own green result on record.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'RecycledNoStartTime'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $recycler.Id -StartUtc ' ' -ExePath $recyclerExe
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'a marker with NO start time whose pid was recycled is NEVER reported as a live run' (
        $r.Out -notmatch 'STILL ACTIVE') $r.Out
    Check 'that finished run completes silently (the exact Stop that used to block)' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'its leftover marker is cleaned up' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $r.Out

    # Same, with a start time that cannot be parsed - equally unpinnable.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'RecycledBadStartTime'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $recycler.Id -StartUtc 'not-a-timestamp' -ExePath $recyclerExe
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'an UNPARSEABLE start time is not a licence to fall back to the pid alone' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # A schema-1 bare {pid} marker: the legacy shape that used to be honoured
    # pid-only. It can never prove a run is live either.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'RecycledSchema1'
    Write-Utf8 (Get-RunStateFile -Copy $c -Root $p -Kind 'active') ('{ "pid": ' + $recycler.Id + ', "runId": "' + (Get-TestRunId $p) + '", "markerCreatedUtc": "' + ([DateTime]::UtcNow.ToString('o')) + '" }')
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'a legacy bare-pid marker is not evidence of a live run when that pid was recycled' (
        $r.Out -notmatch 'STILL ACTIVE') $r.Out

    # The same recycled pid with NO result is not "active" either - it is a run
    # that died, and it must be reported as exactly that.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'RecycledNoResult'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $recycler.Id -StartUtc ' ' -ExePath $recyclerExe
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a recycled pid with no result blocks as OWNERLESS, never as a live run' (
        $r.Out -match '"decision":"block"' -and $reason -match 'OWNERLESS' -and $reason -notmatch 'STILL ACTIVE') $reason
    Check 'the block says WHY the pid proves nothing, naming the missing identity' (
        $reason -match 'no parseable owner start time') $reason

    # A genuinely live, FULLY PINNED owner still blocks - the strict identity
    # rule must not have cost the case the gate exists for.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'RecyclerTruePin'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $recycler.Id
    $r = Fire -Copy $c -Cwd $p
    Check 'a fully pinned live owner still blocks as STILL ACTIVE' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STILL ACTIVE') $r.Out
    # ...and age never overrides liveness: a running test blocks however old its record.
    Set-MarkerAge -Copy $c -Root $p -AgeHours 240
    $r = Fire -Copy $c -Cwd $p
    Check 'an ANCIENT marker whose owner is genuinely alive still blocks (age never expires a live run)' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'STILL ACTIVE') $r.Out
    Check 'a live marker is never expired away' (
        (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $r.Out

    $recycler.Kill()
    Check 'the pid-recycler stand-in exits within its bound' (Wait-FixtureExit $recycler)

    # =====================================================================
    Write-Host '--- a run that DIED without recording a result (ownerless) ---' -ForegroundColor Cyan
    # The guarded runner writes a terminal result in finally on every path it can
    # intercept, so a dead owner with no result document means the process was
    # killed outright. That is a finding, not an absence of one - and it used to
    # be deleted in silence, which is precisely the "ownerless task" complaint.
    $c = New-IsolatedHookCopy; $p = New-GitRepoAi 'DiedNoResult'
    $goner = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
    Check 'the died-run fixture exits within its bound' (Wait-FixtureExit $goner)
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $goner.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'C:\gone\pwsh.exe'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a run whose owner died with no result BLOCKS completion' (
        $r.Out -match '"decision":"block"' -and $reason -match 'OWNERLESS') $reason
    Check 'the evidence names the dead owner process' ($reason -match ('owner process ' + $goner.Id + ' is gone')) $reason
    Check 'it states the result is unknown AND unrecoverable, not merely pending' (
        $reason -match 'UNKNOWN AND UNRECOVERABLE') $reason
    Check 'it refuses to let the run be read as a pass' ($reason -match 'Do not treat it as a pass') $reason
    Check 'the recovery names the guarded runner' ($reason -match 'Run-Tests-Guarded\.ps1') $reason
    Check 'the recovery names the exact record to delete if the work was abandoned' (
        $reason -match [regex]::Escape((Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $reason
    Check 'the durable .ai/ note is demanded with its own tag' (
        $reason -match '\.ai/' -and $reason -match 'Test incident: ') $reason
    Check 'the marker is KEPT while it blocks - it is the evidence, not litter' (
        (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $reason

    # The same finding blocks again on the next Stop: nothing has changed.
    $r2 = Fire -Copy $c -Cwd $p
    Check 'it does not evaporate on the next Stop' ($r2.Out -match '"decision":"block"') $r2.Out
    # ...and the tagged durable note resolves it, so the gate cannot loop forever.
    Add-TaggedNote -Root $p -Reason $reason -Body 'The guarded runner was killed by the session teardown before it could write its result. Nothing detected it because the active record was deleted unread. Guard: the completion gate now classifies an ownerless record instead of dropping it.'
    $r3 = Fire -Copy $c -Cwd $p
    Check 'a real tagged note resolves the ownerless incident (no infinite block)' (
        $r3.Exit -eq 0 -and $r3.Out -eq '') $r3.Out
    Check 'the resolved record is then dropped' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $r3.Out

    # A dead owner WITH its result on record is a finished run, not a died one.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'DiedButResultExists'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $goner.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'C:\gone\pwsh.exe'
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 3
    $r = Fire -Copy $c -Cwd $p
    Check 'a dead owner whose run DID record a result is judged by that result, not as ownerless' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'FAILED' -and (Get-BlockReason $r.Out) -notmatch 'OWNERLESS') $r.Out

    # =====================================================================
    Write-Host '--- a STALE record from a previous session is reconciled, not blocking ---' -ForegroundColor Cyan
    # One abandoned run used to block every future Stop for good: nothing ever
    # expired an active record. A real 8-day-old marker was still sitting in the
    # machine's state directory when this was diagnosed. Past the horizon the
    # record cannot describe the current task, so it is expired - but it is
    # recorded in the ledger on the way out, never silently deleted.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'StalePreviousSession'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $goner.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'C:\gone\pwsh.exe'
    Set-MarkerAge -Copy $c -Root $p -AgeHours 240   # 10 days; default horizon is 12h
    $r = Fire -Copy $c -Cwd $p
    Check 'an abandoned record from a previous session does NOT block the current task' (
        $r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'the expired record is dropped so it can never block again' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active'))) $r.Out
    $stateDoc = Get-CompletionStateDoc -Copy $c -Root $p
    $traced = @()
    if ($null -ne $stateDoc -and $null -ne $stateDoc.PSObject.Properties['expiredMarkers']) { $traced = @($stateDoc.expiredMarkers) }
    $stateJson = if ($null -ne $stateDoc) { $stateDoc | ConvertTo-Json -Depth 4 } else { '(no state document)' }
    Check 'expiring it leaves a durable TRACE in the ledger, not a silent delete' (
        $traced.Count -eq 1 -and [string]$traced[0].runId -eq (Get-TestRunId $p)) ($r.Out + ' | ' + $stateJson)
    Check 'the trace records WHY it was expired' (
        $traced.Count -eq 1 -and ([string]$traced[0].detail) -match 'abandoned-record horizon') $stateJson

    # Just INSIDE the horizon it is still a died run and still blocks - the
    # boundary is the configured one, and ageing is not an escape hatch.
    $c = New-IsolatedHookCopy; $p = New-GitRepo 'AbandonedInsideHorizon'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $goner.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'C:\gone\pwsh.exe'
    Set-MarkerAge -Copy $c -Root $p -AgeHours 11   # default horizon is 12h
    $r = Fire -Copy $c -Cwd $p
    Check 'an 11h-old ownerless record is still INSIDE the 12h horizon and still blocks' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'OWNERLESS') $r.Out

    # The horizon is configurable, and the expiry is then reported alongside a
    # finding the hook was already emitting (never as a reason to break silence).
    $c = New-IsolatedHookCopy -EnvOverrides @{ TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS = '1' }
    $p = New-GitRepo 'HorizonConfigured'
    $rExp = 'expired-' + (Get-ProjectKey $p)
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $goner.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'C:\gone\pwsh.exe' -RunId $rExp
    Set-MarkerAge -Copy $c -Root $p -RunId $rExp -AgeHours 3
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1   # an unrelated finding to ride along
    Write-ObservedRecord -Copy $c -Root $p
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a 3h-old record expires under a configured 1h horizon' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'active' -RunId $rExp))) $reason
    Check 'the expiry is surfaced on an output the hook was already emitting' (
        $reason -match 'Also reconciled' -and $reason -match [regex]::Escape($rExp)) $reason
    Check 'and it is stated as NOT a block and not part of this task' (
        $reason -match 'not a block, and not part of this task') $reason

    # An out-of-range horizon is reported and the default applied - a malformed
    # setting can neither widen nor silence the gate.
    $c = New-IsolatedHookCopy -EnvOverrides @{ TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS = 'soon' }
    $p = New-GitRepo 'HorizonInvalid'
    Write-ActiveMarker -Copy $c -Root $p -ProcessId $goner.Id -StartUtc ([DateTime]::UtcNow.ToString('o')) -ExePath 'C:\gone\pwsh.exe'
    Set-MarkerAge -Copy $c -Root $p -AgeHours 11
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'an invalid horizon is reported in plain text' (
        $reason -match 'TEST_COMPLETION_ACTIVE_MARKER_MAX_HOURS is not an integer in 1\.\.168') $reason
    Check 'and the documented default still governs (11h is inside 12h -> still blocks)' (
        $r.Out -match '"decision":"block"' -and $reason -match 'OWNERLESS') $reason
