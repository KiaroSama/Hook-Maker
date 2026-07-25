# Test-TestCompletionCheck.ps1 scenario block: OUTPUT SHAPE - both client
# shapes and the Codex block-vs-advisory distinction, TEST_COMPLETION_
# ADVISORY_ONLY, .env validation reported once and never widening what is
# blocked on, exactly one valid JSON document on stdout, and the Windows
# PowerShell 5.1 host.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses
# its harness, helpers and workspace) - not a standalone suite.

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

