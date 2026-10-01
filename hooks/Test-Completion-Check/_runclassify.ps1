# Test-Completion-Check private sibling: run classification and the choice of the
# representative (worst) run. Moved out of the entry script, which is over the
# size ceiling, as ONE responsibility. REQUIRED: dot-sourced unconditionally.

# ---- classify + select the representative (worst) run ----
function Test-ResultFresh {
    param($ResEntry)
    if ($null -eq $ResEntry) { return $false }
    $t = Get-ResultRecordedTime -Doc $ResEntry.Doc -Path $ResEntry.Path
    if ($null -eq $t) { return $false }
    return (([DateTime]::UtcNow - $t).TotalMinutes -lt $script:evidenceMinutes)
}
function Get-RunClass {
    param($Run)
    $re = $Run.ResultEntry
    if ($null -ne $re) {
        $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
        $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($ov -eq 'terminated' -or $lk.Count -gt 0) { return 'incident' }
        if ($ov -eq 'failed' -and (Test-ResultFresh $re)) { return 'failed' }
        if ($ov -eq 'ok' -and $lk.Count -eq 0) {
            if (Test-ResultFresh $re) { return 'clean' }
            # A matched historical SUCCESS is finished, not fresh proof and not
            # an unfinished observation. Revalidate identity: a stale malformed
            # result must not gain this exemption merely by claiming overall=ok.
            if ($Run.HasObserved -and $Run.Matches -and
                (Test-ResultMatchesObserved -Result $re.Doc -Observed $Run.Observed -CurrentStateFingerprint $stateFingerprint) -and
                $null -ne (Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path)) { return 'historical-success' }
        }
        return 'unproven'
    }
    return 'noresult'
}
# A run whose negative finding is ALREADY ACCOUNTED FOR must not be chosen as a
# blocking representative (C4). Accounted for means EITHER its incident note was
# already recorded (its key is in resolvedIncidents) OR it is SUPERSEDED by a
# strictly-newer clean ok run for the same command/state. This is what lets a green
# rerun win when an environmental problem is fixed WITHOUT a source change (same
# fingerprint): the old incident no longer outranks the clean rerun, and it breaks
# the deadlock where the terminated run's own case-2/3 block would otherwise fire
# before case 6 could ever process the durable note. A genuinely unresolved,
# un-superseded incident is NOT excluded and still blocks; the durable-note
# obligation registered on the first sighting still stands (case 6 enforces it once
# the run stops outranking everything else).
function Test-RunNegativeAccounted {
    param($Run, $AllResults)
    if ($null -eq $Run.ResultEntry) { return (Test-ObservationSuperseded -Observed $Run.Observed -Pairs $obsPairs.ToArray() -StateFp $stateFingerprint) }
    $doc = $Run.ResultEntry.Doc
    $path = $Run.ResultEntry.Path
    $ik = Get-ResultIncidentKey -Doc $doc -Path $path
    if (Test-ResultIncidentResolved -Doc $Run.ResultEntry.Doc -Path $path) { return $true }
    return (Test-ResultSuperseded -NegDoc $doc -NegTime (Get-ResultRecordedTime -Doc $doc -Path $path) -AllResults $AllResults)
}

# D2 first-sighting note registration and the representative-run ladder, moved
# verbatim into one function; it reads the entry's script-scope state
# ($resultEntries, $script:pendingNotes) exactly as the inline block did.
function Select-RepresentativeRun {
    param($Runs)
    $runs = $Runs
    $classified = @($runs | ForEach-Object { [pscustomobject]@{ Run = $_; Class = (Get-RunClass $_) } })

    # ---- D2: register the durable-note obligation on FIRST SIGHTING -------------
    # For EVERY current-state incident, the note obligation is registered the first
    # time it is seen - BEFORE the supersede/resolve exclusion is applied to the block
    # decision. A supersede lifts only the RESULT-level block (case 2/3); it never
    # lifts the note requirement. So a hang that self-heals into green BEFORE any Stop
    # still owes its lesson once (case 6 enforces it). Only ACCOUNTED (already
    # superseded) incidents are registered here; an un-superseded incident is left to
    # register when it becomes the blocking representative (case 2/3), which spaces two
    # concurrent incidents' note baselines across Stops so each demands a DISTINCT note.
    # ponytail: two incidents self-healing within ONE Stop would share a baseline and
    # one note could clear both - the byte-growth heuristic's inherent limit; sequential
    # real-world surfacing gives distinct baselines. Upgrade path: per-incident note tags.
    foreach ($cl in $classified) {
        if ($cl.Class -ne 'incident' -or $null -eq $cl.Run.ResultEntry) { continue }
        $ikSeen = Get-ResultIncidentKey -Doc $cl.Run.ResultEntry.Doc -Path $cl.Run.ResultEntry.Path
        if ($ikSeen -eq '' -or (Test-ResultIncidentResolved -Doc $cl.Run.ResultEntry.Doc -Path $cl.Run.ResultEntry.Path) -or $script:pendingNotes.Contains($ikSeen)) { continue }
        if (Test-RunNegativeAccounted -Run $cl.Run -AllResults $resultEntries) {
            Register-PendingNote -Key $ikSeen -Reason (Get-IncidentReasonFromDoc $cl.Run.ResultEntry.Doc)
        }
    }

    $rep = $null
    foreach ($wanted in @('incident', 'failed')) {
        $m = @($classified | Where-Object { $_.Class -eq $wanted -and -not (Test-RunNegativeAccounted -Run $_.Run -AllResults $resultEntries) })
        if ($m.Count -gt 0) { $rep = $m[0]; break }
    }
    if ($null -eq $rep) {
        $m = @($classified | Where-Object { $_.Run.HasObserved -and $_.Class -notin @('clean', 'historical-success') -and -not (Test-RunNegativeAccounted -Run $_.Run -AllResults $resultEntries) })   # condition 5: observed, not satisfied
        if ($m.Count -gt 0) { $rep = $m[0] }
    }
    if ($null -eq $rep) {
        $m = @($classified | Where-Object { $_.Class -eq 'clean' })
        if ($m.Count -gt 0) { $rep = $m[0] }
    }
    if ($null -eq $rep -and $classified.Count -gt 0) { $rep = $classified[0] }
    return [pscustomobject]@{ Classified = $classified; Rep = $rep }
}
