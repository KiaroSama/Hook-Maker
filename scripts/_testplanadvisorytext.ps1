# Test-TestPlanCheck.ps1 scenario block: THE ADVISORY TEXT CONTRACT - the
# always-emitted policy bullets Test-Plan-Check carries on every relevant
# event, independent of relevance gating, findings, cooldown and client shape.
#
# The bullets ARE the hook's product: an agent that reads only this summary
# must see the whole test policy, so each one is pinned here by its own
# phrases, in order, and proven to survive both client output shapes intact.
#
# Dot-sourced by Test-TestPlanCheck.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- advisory text: every always-emitted policy bullet is present ---' -ForegroundColor Cyan
    $hcAdv = New-IsolatedHookCopy
    $projAdv = New-GitRepo 'AdvisoryText'
    $rAdv = Fire -HookPath $hcAdv.Script -Cwd $projAdv -EventName 'SessionStart' -LocalAppData $hcAdv.LocalAppData
    $msgAdv = Get-Message $rAdv.Out
    Check 'SessionStart emits the advisory' ($rAdv.Exit -eq 0 -and $msgAdv -match '(?i)TEST PLAN CHECK') ($rAdv.Out + '|' + $rAdv.Err)
    # The pre-existing bullets: an edit that adds a line must not drop one.
    Check 'text: bounded wall + idle timeout bullet' (
        $msgAdv -match 'bounded WALL timeout AND an idle/no-progress timeout' -and
        $msgAdv -match 'A run with no bound is a defect') $msgAdv
    Check 'text: no-blind-sleep bullet' (
        $msgAdv -match 'No long blind sleeps' -and $msgAdv -match 'never a fixed multi-second delay') $msgAdv
    Check 'text: resource-aware parallelism bullet' (
        $msgAdv -match 'max\(2, min\(8, cores-2\)\) workers' -and $msgAdv -match 'no nested oversubscription') $msgAdv
    Check 'text: process-tree + temp cleanup bullet' (
        $msgAdv -match 'Terminate the whole owned process tree' -and $msgAdv -match 'clean temp/state in finally') $msgAdv
    Check 'text: suite discovery + CI mapping bullet' (
        $msgAdv -match 'Discover suites instead of hardcoding a list' -and $msgAdv -match 'mapped to a CI bucket') $msgAdv
    Check 'text: high-CPU-alone-is-not-hung bullet' (
        $msgAdv -match 'High CPU alone never means hung' -and $msgAdv -match 'wall/idle/memory bound') $msgAdv
    Check 'text: before/after timing bullet' (
        $msgAdv -match 'record before/after timing' -and $msgAdv -match '"feels faster" is not evidence') $msgAdv

    # =====================================================================
    Write-Host '--- advisory text: the verification-cadence bullet ---' -ForegroundColor Cyan
    # Without this line an agent reading only the hook summary never sees the
    # cadence rule and re-runs the whole suite after every edit.
    Check 'cadence: light checks while code is still being written' (
        $msgAdv -match '- Cadence: while code is still being written run only LIGHT checks' -and
        $msgAdv -match 'one narrowly scoped test, or a smoke run of the changed path') $msgAdv
    Check 'cadence: the heavy pass runs ONCE after all edits are complete' (
        $msgAdv -match 'Run the HEAVY pass' -and $msgAdv -match 'every guarded run' -and
        $msgAdv -match 'ONCE after all edits are complete') $msgAdv
    Check 'cadence: fix-all-then-re-run-once, never re-run per file' (
        $msgAdv -match 'on failure fix everything that pass reported together, then re-run once' -and
        $msgAdv -match 'Never re-run a suite because one more file changed') $msgAdv

    # =====================================================================
    Write-Host '--- advisory text: the optimization-before-any-run bullet ---' -ForegroundColor Cyan
    # The timing bullet above covers only the MEASUREMENT half of the rule;
    # this line carries the precondition: nothing runs before it is optimized.
    Check 'optimization: every evidence-producing run counts as a test, whatever it is called' (
        $msgAdv -match '- Optimization before any run: everything that executes code to produce evidence is a test' -and
        $msgAdv -match 'suite, pass, matrix, guarded run, benchmark, check') $msgAdv
    Check 'optimization: EXISTING suites are included and an un-optimized run is not permitted' (
        $msgAdv -match 'EXISTING suites optimized before they run again' -and
        $msgAdv -match 'An un-optimized run is not permitted: optimize first, then run') $msgAdv
    Check 'optimization: validity is never traded for speed, and the record lands in TESTING_NOTES' (
        $msgAdv -match 'Never trade validity for speed' -and
        $msgAdv -match 'Record suite/date/before-after timing in \.ai/TESTING_NOTES\.md') $msgAdv

    # =====================================================================
    Write-Host '--- advisory text: the no-orphaned-test-process bullet ---' -ForegroundColor Cyan
    # The runner-teardown bullet above is the RUNNER's obligation; this line
    # is the AGENT's: never detach, never finish with a run alive, always sweep.
    Check 'no-orphan: detached starts are named and the guarded runner is the owner' (
        $msgAdv -match '- No orphaned test process: never start a test detached' -and
        $msgAdv -match 'Start-Job, Start-Process without -Wait' -and
        $msgAdv -match 'the guarded runner is that owner') $msgAdv
    Check 'no-orphan: never finish with a run alive, and an interrupted wait has no result' (
        $msgAdv -match 'Never end your turn or report done while a run you started is alive' -and
        $msgAdv -match 'an interrupted wait has NO result - kill the tree first') $msgAdv
    Check 'no-orphan: the sweep runs before finishing AND after every subagent reports' (
        $msgAdv -match 'Before finishing, and after every subagent reports, sweep' -and
        $msgAdv -match 'terminate every survivor, verify it is gone, report each pid' -and
        $msgAdv -match 'On Windows check pid AND start time and exclude your own shell') $msgAdv

    # =====================================================================
    Write-Host '--- advisory text: both new lines sit in the ALWAYS-emitted block ---' -ForegroundColor Cyan
    # Order pins the documented insertion point: ... timing -> cadence ->
    # efficiency -> (optional ::deep-debug section).
    $idxTiming = $msgAdv.IndexOf('- When optimising a suite')
    $idxCadence = $msgAdv.IndexOf('- Cadence: while code')
    $idxOptimization = $msgAdv.IndexOf('- Optimization before any run')
    $idxOrphan = $msgAdv.IndexOf('- No orphaned test process')
    Check 'the three new bullets sit in order after the timing bullet' (
        $idxTiming -ge 0 -and $idxCadence -gt $idxTiming -and
        $idxOptimization -gt $idxCadence -and $idxOrphan -gt $idxOptimization) (
        'timing=' + $idxTiming + ' cadence=' + $idxCadence +
        ' optimization=' + $idxOptimization + ' orphan=' + $idxOrphan)
    # Not gated behind ::deep-debug: an ordinary test prompt carries them too.
    $hcAdvPlain = New-IsolatedHookCopy
    $projAdvPlain = New-GitRepo 'AdvisoryTextPlain'
    $rAdvPlain = Fire -HookPath $hcAdvPlain.Script -Cwd $projAdvPlain -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hcAdvPlain.LocalAppData
    $msgAdvPlain = Get-Message $rAdvPlain.Out
    Check 'a plain test prompt (no ::deep-debug) still carries all three new lines' (
        $msgAdvPlain -notmatch '::deep-debug detected' -and
        $msgAdvPlain -match '- Cadence: while code is still being written' -and
        $msgAdvPlain -match '- Optimization before any run' -and
        $msgAdvPlain -match '- No orphaned test process') $msgAdvPlain

    # =====================================================================
    Write-Host '--- advisory text: both client shapes render the new lines in FULL ---' -ForegroundColor Cyan
    # The no-orphan bullet is last and longest; its FINAL clause proves the
    # shared Write-HookResult adapter truncated nothing on either client.
    $hcAdvCl = New-IsolatedHookCopy
    $projAdvCl = New-GitRepo 'AdvisoryTextClaude'
    $rAdvCl = Fire -HookPath $hcAdvCl.Script -Cwd $projAdvCl -EventName 'SessionStart' -LocalAppData $hcAdvCl.LocalAppData -ClaudeProjectDir $projAdvCl
    $parsedAdvCl = $null
    try { $parsedAdvCl = $rAdvCl.Out | ConvertFrom-Json } catch { $parsedAdvCl = $null }
    $msgAdvCl = Get-Message $rAdvCl.Out
    Check 'Claude shape carries all three new lines whole (additionalContext, no decision)' (
        $null -ne $parsedAdvCl -and $null -ne $parsedAdvCl.PSObject.Properties['hookSpecificOutput'] -and
        $rAdvCl.Out -notmatch '"decision"' -and
        $msgAdvCl -match 'Never re-run a suite because one more file changed' -and
        $msgAdvCl -match 'Record suite/date/before-after timing in \.ai/TESTING_NOTES\.md' -and
        $msgAdvCl -match 'exclude your own shell') $rAdvCl.Out
    Check 'Codex OFF-Stop shape carries all three new lines whole (never systemMessage)' (
        $rAdv.Out -notmatch 'systemMessage' -and
        $msgAdv -match 'Never re-run a suite because one more file changed' -and
        $msgAdv -match 'Record suite/date/before-after timing in \.ai/TESTING_NOTES\.md' -and
        $msgAdv -match 'exclude your own shell') $rAdv.Out
