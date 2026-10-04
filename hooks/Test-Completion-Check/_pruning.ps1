# Test-Completion-Check: pruning responsibility, extracted from the oversized entry.
# ---- R1: register note obligations BEFORE pruning can delete a superseded run --
# The prune below removes a superseded negative (a hang that later re-ran green for
# the same command+state). A supersede lifts the RESULT-level block but NEVER the
# durable-note requirement (D2). If the superseded run's files were pruned before
# its obligation was recorded - e.g. the first Stop fires >24h after a self-heal -
# the lesson would be lost forever. So every CURRENT-state, unresolved, superseded
# incident has its note demanded here, before the prune can erase it. Its
# obligation then lives in the ledger independent of the result file. Un-superseded
# current-state negatives are KEPT by the prune and register normally when they
# block, so only the about-to-be-pruned ones need this pass.
foreach ($re in $resultEntries) {
    $cause = Get-IncidentReasonFromDoc $re.Doc
    if ([string]::IsNullOrWhiteSpace($cause)) { continue }
    $ik = Get-ResultIncidentKey -Doc $re.Doc -Path $re.Path
    if ($ik -eq '' -or (Test-ResultIncidentResolved -Doc $re.Doc -Path $re.Path) -or $script:pendingNotes.Contains($ik)) { continue }
    $rProjFp = [string](Get-Field $re.Doc 'projectFingerprint')
    $isCurrentState = ($rProjFp -eq '' -or $rProjFp -eq $stateFingerprint)
    if (-not $isCurrentState) { continue }
    if (Test-ResultSuperseded -NegDoc $re.Doc -NegTime (Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path) -AllResults $resultEntries) {
        Register-PendingNote -Key $ik -Reason $cause -Origin (New-NoteOrigin -Kind result -Path $re.Path)
    }
}

# An in-memory obligation is not durable: preserve receipts if publication fails.
if ($script:pendingNotes.Count -gt 0) { Save-CompletionState }
$persistedNotes = @(Get-Field (Read-JsonFile $script:statePath) 'pendingNotes')

# ---- bounded, CONTENT-AWARE state growth control (C2 / D3 / D4) -------------
# Age alone must never erase a NEGATIVE finding. Staleness weakens only POSITIVE
# evidence (see this file's header): a run that TERMINATED, FAILED, LEAKED, errored
# or was OBSERVED-WITHOUT-A-RESULT for the current state is an incident whose
# obligation survives until it is RESOLVED (a durable note recorded, tracked in
# resolvedIncidents) or SUPERSEDED (a strictly-newer clean ok run for the same
# command+state - which also underlies the C4 fix). A CURRENT-state unresolved
# negative is NEVER pruned by age. Only clean ok runs, resolved/superseded
# negatives, OLD-STATE clutter past a longer bound (D4), and old-STATE observations
# carrying no current obligation are pruned, so a hang whose Stop hook never fired
# within 24h can never be silently deleted before it is seen. Best-effort: a read
# or delete failure never blocks the gate.
$pruneCutoff = [DateTime]::UtcNow.AddHours(-24)
# D4: an OLD-STATE (fingerprint != current) negative can NEVER become current
# evidence and can never block, yet a plain `failed` has no incident key to ever
# resolve and, being old-state, is never superseded - so without a bound it would
# accumulate forever across states. Give old-state negatives a longer, safe
# retention and prune past it. The CURRENT-state guarantee above is untouched.
$oldStateNegativeCutoff = [DateTime]::UtcNow.AddDays(-7)
function Get-FileMtimeUtc { param([string]$Path) try { return (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc } catch { return $null } }
$prunedResultPaths = New-Object System.Collections.Generic.HashSet[string]
$prunedObservedPaths = New-Object System.Collections.Generic.HashSet[string]
foreach ($re in $resultEntries) {
    $mtime = Get-FileMtimeUtc $re.Path
    if ($null -eq $mtime -or $mtime -ge $pruneCutoff) { continue }   # keep anything not yet 24h old
    if (Test-RecoveryReceiptRetained -RunId ([string](Get-Field $re.Doc 'runId'))) { continue }
    $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
    $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    $isNegative = ((@('terminated', 'failed', 'error', 'unknown') -contains $ov) -or $lk.Count -gt 0 -or (Get-Field $re.Doc 'terminated') -eq $true)
    if (-not $isNegative) { [void]$prunedResultPaths.Add($re.Path); continue }   # clean ok run -> prunable
    $ik = Get-ResultIncidentKey -Doc $re.Doc -Path $re.Path
    $resolved = (Test-ResultIncidentResolved -Doc $re.Doc -Path $re.Path)
    $superseded = Test-ResultSuperseded -NegDoc $re.Doc -NegTime (Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path) -AllResults $resultEntries
    $cause = Get-IncidentReasonFromDoc $re.Doc
    if ($superseded -and -not $resolved -and $cause -ne '' -and
        (@($persistedNotes | Where-Object { [string](Get-Field $_ 'key') -eq $ik -and (Test-NoteObligationActionable $_) }).Count -eq 0 -or $script:LedgerWriteFailed -ne '')) { continue }
    if ($resolved -or $superseded) { [void]$prunedResultPaths.Add($re.Path); continue }
    # An unresolved, un-superseded negative. CURRENT-state -> KEEP however old
    # (round-19 guarantee). OLD-state clutter -> bounded retention (D4).
    $rProjFp = [string](Get-Field $re.Doc 'projectFingerprint')
    $isCurrentState = ($rProjFp -eq '' -or $rProjFp -eq $stateFingerprint)
    if (-not $isCurrentState -and $mtime -lt $oldStateNegativeCutoff) { [void]$prunedResultPaths.Add($re.Path) }
}
# D3: prune observations by the SAME one-to-one assignment the main flow uses. An
# observation whose ONE assigned result is a pruned clean/resolved run is fully
# accounted for; an observation with NO independently-assigned result is an
# unfinished incident and must NOT be pruned as if a shared result covered it.
$currentObservedPre = @($observedEntries | Where-Object { (Get-ObservedFingerprint $_.Doc) -eq $stateFingerprint })
$pruneAssign = Get-ObservedResultAssignment -CurrentObserved $currentObservedPre -ResultEntries $resultEntries -StateFp $stateFingerprint
$assignedResultForObserved = @{}
for ($i = 0; $i -lt $pruneAssign.SortedObserved.Count; $i++) {
    if ($pruneAssign.Map.ContainsKey($i)) { $assignedResultForObserved[$pruneAssign.SortedObserved[$i].Path] = $pruneAssign.Map[$i].Path }
}
foreach ($oe in $observedEntries) {
    $mtime = Get-FileMtimeUtc $oe.Path
    if ($null -eq $mtime -or $mtime -ge $pruneCutoff) { continue }
    if ((Get-ObservedFingerprint $oe.Doc) -ne $stateFingerprint) { [void]$prunedObservedPaths.Add($oe.Path); continue }   # old-STATE: no current obligation
    if (-not $assignedResultForObserved.ContainsKey($oe.Path)) { continue }   # unpaired -> unfinished incident, KEEP
    if ($prunedResultPaths.Contains($assignedResultForObserved[$oe.Path])) { [void]$prunedObservedPaths.Add($oe.Path) }   # its ONE assigned result is a pruned clean/resolved run
}
foreach ($path in @($prunedResultPaths)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { } }
foreach ($path in @($prunedObservedPaths)) { try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { } }
if ($prunedResultPaths.Count -gt 0) { $resultEntries = @($resultEntries | Where-Object { -not $prunedResultPaths.Contains($_.Path) }) }
if ($prunedObservedPaths.Count -gt 0) { $observedEntries = @($observedEntries | Where-Object { -not $prunedObservedPaths.Contains($_.Path) }) }

