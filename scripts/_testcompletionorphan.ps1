# Test-TestCompletionCheck.ps1 module: an UNPAIRED observation (a guarded run
# whose result never pairs with it - typed by hand without the full identity,
# or killed before it wrote one) and the later run that may clear it.
#
# The gate's printed recovery is "re-run through the guarded runner". Before
# this rule that rerun could not clear the orphan: only a run that is paired to
# ITS OWN observation, for the same command and the same current state, clean
# and leak-free, and later than the orphan, is proof that replaces it. Every
# other combination must keep blocking. Dot-sourced into the caller's scope.

Write-Host '--- unpaired observation: only a later clean PAIRED run of the same command clears it ---' -ForegroundColor Cyan

# Orphan: observed 5 minutes ago under its own controlled runId; no result.
function New-OrphanObservation {
    param([object]$Copy, [string]$Root, [double]$AgeMinutes = 5)
    Write-ObservedRecord -Copy $Copy -Root $Root -RunId 'orphan-handtyped' -AgeMinutes $AgeMinutes
}

$c = New-IsolatedHookCopy; $p = New-GitRepo 'OrphanCleared'
New-OrphanObservation -Copy $c -Root $p
Write-ObservedRecord -Copy $c -Root $p
Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
$r = Fire -Copy $c -Cwd $p
Check 'orphan: a later clean run of the same command, paired to its own observation, clears it (silent)' (
    $r.Exit -eq 0 -and $r.Out -eq '') $r.Out

$c = New-IsolatedHookCopy; $p = New-GitRepo 'OrphanOtherCommand'
New-OrphanObservation -Copy $c -Root $p
Write-ObservedRecord -Copy $c -Root $p -RunId 'run-other' -CommandFingerprint 'other-command-fp'
Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -RunId 'run-other' -CommandFingerprint 'other-command-fp'
$r = Fire -Copy $c -Cwd $p
Check 'orphan: a later clean run of a DIFFERENT command still blocks' ($r.Out -match '"decision":"block"') $r.Out

$c = New-IsolatedHookCopy; $p = New-GitRepo 'OrphanLaterFailed'
New-OrphanObservation -Copy $c -Root $p
Write-ObservedRecord -Copy $c -Root $p
Write-GuardedResult -Copy $c -Root $p -Overall 'failed' -ExitCode 1
$r = Fire -Copy $c -Cwd $p
Check 'orphan: a later FAILED run of the same command still blocks' ($r.Out -match '"decision":"block"') $r.Out

$c = New-IsolatedHookCopy; $p = New-GitRepo 'OrphanLaterLeaked'
New-OrphanObservation -Copy $c -Root $p
Write-ObservedRecord -Copy $c -Root $p
Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -Leaked @(424242)
$r = Fire -Copy $c -Cwd $p
Check 'orphan: a later clean run that LEAKED a process still blocks' ($r.Out -match '"decision":"block"') $r.Out

$c = New-IsolatedHookCopy; $p = New-GitRepo 'OrphanOlderClean'
Write-ObservedRecord -Copy $c -Root $p -AgeMinutes 10
Write-GuardedResult -Copy $c -Root $p -Overall 'ok' -AgeMinutes 9
New-OrphanObservation -Copy $c -Root $p -AgeMinutes 0
$r = Fire -Copy $c -Cwd $p
Check 'orphan: a clean run that finished BEFORE the orphan was observed still blocks' ($r.Out -match '"decision":"block"') $r.Out
