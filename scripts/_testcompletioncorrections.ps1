# Test-TestCompletionCheck.ps1 scenario block: three small corrections.
#   1. A negative result without project identity remains unresolved independent
#      of age; unavailable identity is never forgiven by a retention horizon.
#   2. A ledger write that fails on the normal path is reported, not swallowed.
#   3. A Test-Temp-Cleanup installed in the user profile (global scope) is
#      recognised for the cleanup-evidence coordination.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses its
# harness) - not a standalone suite.

    Write-Host '--- corrections: legacy result horizon, ledger write failure, global cleanup ---' -ForegroundColor Cyan
    function Set-LegacyResult {
        param([object]$Copy, [string]$Root, [double]$AgeMinutes)
        Write-GuardedResult -Copy $Copy -Root $Root -Overall 'failed' -ExitCode 1 -AgeMinutes $AgeMinutes
        $file = Get-RunStateFile -Copy $Copy -Root $Root -Kind 'result' -RunId (Get-TestRunId $Root)
        $doc = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        $doc.projectFingerprint = ''
        Write-Utf8 $file ($doc | ConvertTo-Json -Depth 6)
    }
    $c = New-IsolatedHookCopy
    $old = New-GitRepo 'LegacyOld'
    Set-LegacyResult -Copy $c -Root $old -AgeMinutes 1500
    $r = Fire -Copy $c -Cwd $old
    Check 'a legacy failed result older than 24 h remains unresolved, never age-forgiven' ($r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'unavailableOrLegacy') $r.Out
    $young = New-GitRepo 'LegacyYoung'
    Set-LegacyResult -Copy $c -Root $young -AgeMinutes 60
    $r = Fire -Copy $c -Cwd $young
    Check 'a legacy failed result inside 24 h still blocks' ($r.Out -match '"decision":"block"') $r.Out

    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'LedgerUnwritable'
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    # The ledger path as a DIRECTORY: every write to it fails.
    New-Item -ItemType Directory -Path (Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')) -Force | Out-Null
    $r = Fire -Copy $c -Cwd $p
    Check 'a ledger that cannot be written is reported, not swallowed' ($r.Exit -eq 0 -and $r.Out -match 'incident ledger could not be written') ($r.Out + '|' + $r.Err)
    Check 'the ledger-write report never blocks' ($r.Out -notmatch '"decision":"block"') $r.Out

    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'GlobalCleanup'
    $fakeProfile = Join-Path $Work 'fake-profile'
    New-Item -ItemType Directory -Path (Join-Path $fakeProfile '.claude\hooks\Hook-Maker\Test-Temp-Cleanup') -Force | Out-Null
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $savedProfile = $env:USERPROFILE
    try {
        # The child inherits it: Fire's -Environment merges with this process's.
        $env:USERPROFILE = $fakeProfile
        $r1 = Fire -Copy $c -Cwd $p
        $r2 = Fire -Copy $c -Cwd $p
    }
    finally { $env:USERPROFILE = $savedProfile }
    Check 'a globally installed Test-Temp-Cleanup defers once, like a project-scope one' ($r1.Exit -eq 0 -and $r1.Out -eq '') $r1.Out
    Check 'the next event after the global deferral evaluates normally' ($r2.Out -match '"decision":"block"') $r2.Out
