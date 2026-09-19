# Test-TestRunGuard.ps1 scenario block: SILENT EXECUTION.
#
# global-test-rules.md gained a Silent Execution section on 2026-09-19:
# everything the agent starts runs out of the user's sight. Run-Tests-Guarded.ps1
# already sets CreateNoWindow, so what is tested here is DETECTION - that a
# recognised test command whose INVOCATION would open a window is refused with
# the exact silent form, and, just as importantly, that an ambiguous one is not.
#
# EVERY POSITIVE CASE LAUNCHES A COMMAND THIS HOOK ALREADY RECOGNISES. That is
# the contract, not an accident of the fixtures: the hook has never invented a
# framework, so a headed flag on a runner it does not recognise (`npx playwright
# test --headed` - `playwright` is not in its program list) is NOT refused.
# Widening recognition to catch it would change what the hook demands a guarded
# runner for, which is a different decision from this one.
#
# The negative cases are the load-bearing half. A visibility check that fired on
# `pytest -k "start the server"` or on a quoted `--filter=headless` would make
# the hook unusable, and only a test that pins those forms keeps the matcher on
# whole tokens instead of substrings.
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- silent execution: an unmistakably visible invocation is refused ---' -ForegroundColor Cyan
    $hcVis = New-IsolatedHookCopy

    # Each of these wraps a command the hook recognises: `pytest`, `vitest`, and
    # a `-File` target matching its Run-Tests / Test-* shapes.
    $visibleCases = @(
        'Start-Process pytest -ArgumentList ''-q''',
        'npx --no-install vitest run --headed',
        'cmd /c start pytest -q',
        'wt pwsh -NoProfile -File .\scripts\Run-Tests.ps1',
        'powershell -NoExit -File .\scripts\Test-RulesCheck.ps1'
    )
    foreach ($command in $visibleCases) {
        $r = Fire -HookPath $hcVis.Script -Cwd $Proj -EventName 'PreToolUse' -Command $command -LocalAppData $hcVis.LocalAppData
        Check ('a visible invocation is denied: ' + $command) (
            $r.Out -match '"permissionDecision":"deny"') $r.Out
        # A refusal that does not name the replacement is one the reader cannot
        # act on, which is the failure mode the hook rules single out.
        Check ('and the refusal names the silent form: ' + $command) (
            (Get-Message $r.Out) -match 'current session|headless is the default|Invoke the interpreter directly|Drop -NoExit') $r.Out
    }

    # =====================================================================
    Write-Host '--- silent execution: the silent forms pass, and ambiguity is left alone ---' -ForegroundColor Cyan

    # -Wait, -NoNewWindow and -WindowStyle Hidden each make Start-Process silent.
    # None may be refused FOR VISIBILITY; the ordinary guarded-runner requirement
    # still applies to them and is asserted elsewhere in this suite.
    foreach ($silent in @(
            'Start-Process pytest -Wait -NoNewWindow -ArgumentList ''-q''',
            'Start-Process -FilePath pytest -WindowStyle Hidden -ArgumentList ''-q''')) {
        $r = Fire -HookPath $hcVis.Script -Cwd $Proj -EventName 'PreToolUse' -Command $silent -LocalAppData $hcVis.LocalAppData
        Check ('a silent Start-Process is not refused for visibility: ' + $silent) (
            (Get-Message $r.Out) -notmatch 'NEW WINDOW') $r.Out
    }

    # THE FALSE-POSITIVE GUARD. Each of these carries the literal text of a
    # visible form inside a quoted argument or a longer flag. Matching on
    # substrings rather than whole tokens would refuse all three, and none of
    # them opens anything.
    $ambiguous = @(
        'pytest -q -k "start the server"',
        'pytest -q --deselect tests/test_headed.py',
        'node scripts/run.js --filter=headless'
    )
    foreach ($command in $ambiguous) {
        $r = Fire -HookPath $hcVis.Script -Cwd $Proj -EventName 'PreToolUse' -Command $command -LocalAppData $hcVis.LocalAppData
        Check ('an ambiguous command is never refused for visibility: ' + $command) (
            (Get-Message $r.Out) -notmatch 'NEW WINDOW|VISIBLE browser|terminal host|-NoExit') $r.Out
    }

    # A command that is not a recognised test command is none of this hook's
    # business, however it is launched. This is what the InnerTokens re-check
    # buys: the launcher is stripped, `notepad.exe` is not a test, nothing fires.
    foreach ($notATest in @('Start-Process notepad.exe', 'wt notepad.exe')) {
        $r = Fire -HookPath $hcVis.Script -Cwd $Proj -EventName 'PreToolUse' -Command $notATest -LocalAppData $hcVis.LocalAppData
        Check ('a non-test command is left alone even when it opens a window: ' + $notATest) (
            $r.Out -notmatch '"permissionDecision":"deny"') $r.Out
    }
