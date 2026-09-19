# Test-TestCompletionCheck.ps1 scenario block: the INCIDENT LEDGER and its
# retention rules - C1 a live marker surviving a mid-run fingerprint change,
# C2 content-aware pruning, C3 one-to-one pairing of uncontrolled runs, C4
# resolved-vs-unresolved incidents, D1-D4 per-incident note obligations and
# bounded retention, R1 register-before-prune, R2a per-incident tags, R2b
# ledger overflow and eviction, and R3 two genuinely concurrent Stops
# merging without a lost update.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses
# its harness, helpers and workspace) - not a standalone suite.

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
    Write-Host '--- C2b: a failure a later green run REPAIRED must stop blocking (2026-09-20) ---' -ForegroundColor Cyan
    # The supersede used to demand the SAME projectFingerprint, which is a hash of
    # HEAD + `git status --porcelain`. Fixing a failure edits the tree, so the
    # green run could never carry the failure's fingerprint and the gate cited it
    # until the 24h horizon. Reported from a consumer project and reproduced here
    # four times in one afternoon. Scope is still the command: see S3.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C2bSupersede'
    $key = Get-ProjectKey $p

    # S1: a plain FAILED record with NO project fingerprint at all. The old code
    # returned $false before scanning anything, so nothing could ever clear it.
    $rEmpty = 'c2b-empty-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId $rEmpty -CommandFingerprint ('cmdempty' + $key) -AgeMinutes 200
    $emptyPath = Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rEmpty
    $emptyDoc = Get-Content -LiteralPath $emptyPath -Raw | ConvertFrom-Json
    $emptyDoc.projectFingerprint = ''
    Write-Utf8 $emptyPath ($emptyDoc | ConvertTo-Json -Depth 6)
    (Get-Item -LiteralPath $emptyPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('c2b-emptyok-' + $key) -CommandFingerprint ('cmdempty' + $key) -AgeMinutes 5

    # S2: a plain FAILED record that DOES carry a fingerprint, repaired by a green
    # run on a DIFFERENT tree state - the shape every real fix produces.
    $rMoved = 'c2b-moved-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId $rMoved -CommandFingerprint ('cmdmoved' + $key) -ProjectFingerprint 'tree-before-the-fix' -AgeMinutes 200
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rMoved)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('c2b-movedok-' + $key) -CommandFingerprint ('cmdmoved' + $key) -ProjectFingerprint 'tree-after-the-fix' -AgeMinutes 5

    # S3: the negative control. A green run of DIFFERENT work must not clear it.
    $rOther = 'c2b-other-' + $key
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId $rOther -CommandFingerprint ('cmdother' + $key) -ProjectFingerprint 'tree-x' -AgeMinutes 200
    (Get-Item -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rOther)).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId ('c2b-otherok-' + $key) -CommandFingerprint ('cmdUNRELATED' + $key) -AgeMinutes 5

    $r = Fire -Copy $c -Cwd $p
    Check 'C2b/S1: a failure with an EMPTY project fingerprint is superseded by a later green run' (
        -not (Test-Path -LiteralPath $emptyPath)) $r.Out
    Check 'C2b/S2: a failure is superseded even though the tree changed (the fix itself changed it)' (
        -not (Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rMoved))) $r.Out
    Check 'C2b/S3: a green run of a DIFFERENT command does NOT supersede it' (
        Test-Path -LiteralPath (Get-RunStateFile -Copy $c -Root $p -Kind 'result' -RunId $rOther)) $r.Out

    # =====================================================================
    Write-Host '--- C2c: a plain assertion failure is nameable, so the printed recovery can be taken ---' -ForegroundColor Cyan
    # The block text tells the reader to resolve an incident by key; the key used
    # to be minted only for a termination or a leak, so an ordinary failing suite
    # produced a block whose own instruction could not be followed.
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'C2cKey'
    $key = Get-ProjectKey $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1 -RunId ('c2c-fail-' + $key) -CommandFingerprint ('cmdc2c' + $key)
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'C2c: a plain failed run blocks' ($r.Out -match '"decision":"block"') $r.Out
    Check 'C2c: and the block carries a resolvable incident key, not an empty one' (
        $reason -match 'ResolveIncident\s+[0-9a-fA-F]{6,}') $reason

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

