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
# The suite is split by scenario into dot-sourced helper blocks (they run in
# this script's scope; execution order is the file order below):
#   _testcompletionharness.ps1   shared fixture builders + state-document writers
#   _testcompletionrecovery.ps1  explicit historical recovery and audit/ownership checks
#   _testcompletiongate.ps1      the core gate: evidence, identity, and the
#                                active-record state machine (live / finished /
#                                died / expired, incl. pid reuse)
#   _testcompletionledger.ps1    incident ledger, pruning and retention (C/D/R)
#   _testcompletionnotes.ps1     state migration, the durable .ai/ note, the race
#   _testcompletionoutput.ps1    client shapes, .env validation, JSON, 5.1
#   _testcompletionsurvivors.ps1 the advisory-only possible-orphan process list
#   _testcompletiondeepdebug.ps1 the E-05 ::deep-debug verdicts + E-13 safety
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestCompletionCheck.ps1 [-KeepArtifacts] [-RecoveryOnly]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts, [switch]$RecoveryOnly, [switch]$ActivationOnly)

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

$Work = New-TestWorkspace -Prefix 'hookmaker-completiontest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

. (Join-Path $PSScriptRoot '_testcompletionharness.ps1')

$sentinel = $null
try {
    if ($ActivationOnly) {
        . (Join-Path $PSScriptRoot '_testcompletionactivation.ps1')
    }
    else {
    . (Join-Path $PSScriptRoot '_testcompletionrecovery.ps1')
    if (-not $RecoveryOnly) {
    # The core gate: recursion guard, evidence freshness, run identity, active
    # markers, missing results, and concurrent runs in one project.
    . (Join-Path $PSScriptRoot '_testcompletiongate.ps1')

    # The incident ledger, its pruning rules and its retention bounds.
    . (Join-Path $PSScriptRoot '_testcompletionledger.ps1')
    . (Join-Path $PSScriptRoot '_testcompletionci.ps1')

    # State migration, the durable .ai/ note, and the cleanup-race deferral.
    . (Join-Path $PSScriptRoot '_testcompletionnotes.ps1')

    # Client output shapes, .env validation, JSON shape, and 5.1.
    . (Join-Path $PSScriptRoot '_testcompletionoutput.ps1')

    # The advisory-only list of possible orphaned test processes.
    . (Join-Path $PSScriptRoot '_testcompletionsurvivors.ps1')

    # The E-05 ::deep-debug verdicts and the E-13 static-safety proofs.
    . (Join-Path $PSScriptRoot '_testcompletiondeepdebug.ps1')
    . (Join-Path $PSScriptRoot '_testcompletionactivation.ps1')

    # =====================================================================
    Write-Host '--- the real user environment is never touched ---' -ForegroundColor Cyan
    Check 'no state was written outside the fake LOCALAPPDATA of each case' (
        @(Get-ChildItem -LiteralPath $Work -Recurse -Filter 'TestCompletionCheck-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '_fakelocal' }).Count -eq 0)
    Check 'no fixture ever created a .claude/settings.json' (
        @(Get-ChildItem -LiteralPath $Work -Recurse -Filter 'settings.json' -File -ErrorAction SilentlyContinue).Count -eq 0)
    }
    }
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
