# Evidenced note gate; unknown legacy state is diagnostic, never a fabricated lesson.
# ---- 6. every durable note that is still owed ------------------------------
# EVERY pending incident is enforced, not one: a satisfied note (its OWN tag present
# AND real added content past its byte baseline) is resolved and dropped; any
# still-owed note keeps blocking. The tag is what makes two concurrent incidents
# each require their OWN note - one 80-byte note can no longer clear both by byte
# growth alone. Resolving one never forgets the other.
if ($script:pendingNotes.Count -gt 0 -or $script:pendingOverflow) {
    $owed = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($script:pendingNotes.Keys)) {
        if (-not (Test-NoteObligationActionable $script:pendingNotes[$k])) { continue }
        if (Test-PendingNoteSatisfied -Key ([string]$k)) { Add-ResolvedIncident ([string]$k) }   # satisfied -> resolved, dropped
        else { [void]$owed.Add([pscustomobject]@{ Key = [string]$k; Reason = [string]$script:pendingNotes[$k].reason; Origin = (Get-Field $script:pendingNotes[$k] 'origin') }) }
    }
    if ($script:pendingOverflow) {
        # R2b: the ledger is full of UNRESOLVED obligations and a newer incident
        # could not be tracked without discarding one. Surface it - never drop a
        # live lesson - and keep blocking until the backlog is cleared.
        Save-CompletionState
        Write-Finding -Blocking $true -Lines @(
            'note ledger FULL (' + $script:MaxPendingNotes + ' unresolved); new incident would lose evidence.',
            'Retain receipt; correlate legacy/resolve notes before selective repair, no invented lesson/evidence loss.')
    }
    if ($owed.Count -gt 0) {
        Save-CompletionState
        $summary = @($owed | Select-Object -First 5 | ForEach-Object {
            'Incident ' + $_.Key + ': ' + $_.Reason + '. Origin: run=' + [string](Get-Field $_.Origin 'runId') + ', command=' + [string](Get-Field $_.Origin 'commandFingerprint') + ', outcome=' + [string](Get-Field $_.Origin 'overall') + ', receipt=' + [string](Get-Field $_.Origin 'receiptPath') + ', SHA256=' + [string](Get-Field $_.Origin 'receiptSha256')
        })
        Write-Finding -Blocking $true -Lines (@(
            '.ai/ note owed: ' + $owed[0].Reason + '; ' + $owed.Count + ' obligations, max5 shown.',
            '.ai/{BUGS,TESTING_NOTES,COMMANDS,LESSON}.md: missed-detection cause + verified prevention/recovery.',
            'Tag it with a line `' + (Get-IncidentTag $owed[0].Key) + '`: exact incident tag + substantive content per obligation.',
            'done/n/a/fixed or tag alone != added lesson.') + $summary)
    }
    # Unknown-only state is not completion evidence. Fall through to the
    # independent deep-debug/current-evidence gates and diagnostic tail.
    Save-CompletionState
}

