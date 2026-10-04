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
            'TEST COMPLETION CHECK: the durable-note ledger is FULL (' + $script:MaxPendingNotes + ' unresolved test-incident notes are already owed) and another incident was seen that cannot be tracked without discarding one.',
            'The genuine new incident receipt is retained. Resolve evidenced obligations or correlate unknown legacy records before selective repair; never invent lessons for UNKNOWN entries. No unresolved record is silently dropped.')
    }
    if ($owed.Count -gt 0) {
        Save-CompletionState
        $summary = @($owed | Select-Object -First 5 | ForEach-Object {
            'Incident ' + $_.Key + ': ' + $_.Reason + '. Origin: run=' + [string](Get-Field $_.Origin 'runId') + ', command=' + [string](Get-Field $_.Origin 'commandFingerprint') + ', outcome=' + [string](Get-Field $_.Origin 'overall') + ', receipt=' + [string](Get-Field $_.Origin 'receiptPath') + ', SHA256=' + [string](Get-Field $_.Origin 'receiptSha256')
        })
        Write-Finding -Blocking $true -Lines (@(
            'TEST COMPLETION CHECK: a durable .ai/ note is still owed because ' + $owed[0].Reason + '. ' + $owed.Count + ' evidenced obligation(s) remain (at most five shown).',
            'Write it into .ai/BUGS.md, .ai/TESTING_NOTES.md, .ai/COMMANDS.md and/or .ai/LESSON.md, whichever fits. It must state WHY the problem was not detected earlier and the verified prevention/recovery guard that now catches it - concretely enough that a later session can act on it.',
            'Tag it with a line `' + (Get-IncidentTag $owed[0].Key) + '` (exactly) so THIS specific incident is cleared; a note without this tag, or a bare tag with no real content, will not clear it, and each other owed incident needs its own tagged note.',
            'A bare acknowledgement ("done", "n/a", "fixed") does not satisfy this and will not clear it; the check looks for the tag plus real added content in those files.') + $summary)
    }
    # Unknown-only state is not completion evidence. Fall through to the
    # independent deep-debug/current-evidence gates and diagnostic tail.
    Save-CompletionState
}

