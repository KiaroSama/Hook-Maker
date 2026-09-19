# Test-TestCompletionCheck.ps1 scenario block: STATE MIGRATION from the old
# single-value shape into the ledger, the durable .ai/ note requirement (the
# word "done" and an untagged note both refused, the incident tag required),
# and the Test-Temp-Cleanup same-Stop race deferring to the NEXT event
# instead of looping.
#
# Dot-sourced by Test-TestCompletionCheck.ps1 into the caller's scope (uses
# its harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- migration: the old single-value state shape is read and rewritten as the ledger ---' -ForegroundColor Cyan
    # A legacy pendingNoteKey/Reason/Baseline is still ENFORCED after migration.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'MigrateLegacyNote'
    $legacyPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $legacyPath (([ordered]@{
                resolvedIncident = ''; pendingNoteKey = 'legacy-key-xyz'; pendingNoteReason = 'a legacy migrated incident'
                pendingNoteBaseline = 0; deferredFingerprint = ''; updatedUtc = [DateTime]::UtcNow.ToString('o')
            }) | ConvertTo-Json)
    $r = Fire -Copy $c -Cwd $p
    Check 'migration: a legacy single-value pendingNoteKey is still enforced as an owed note' (
        $r.Out -match '"decision":"block"' -and (Get-BlockReason $r.Out) -match 'a legacy migrated incident') $r.Out
    $st = Get-CompletionStateDoc -Copy $c -Root $p
    Check 'migration: the state is rewritten in the new collection shape (pendingNotes, no old scalar)' (
        (Get-PendingCount $st) -eq 1 -and $null -ne $st.PSObject.Properties['pendingNotes'] -and $null -eq $st.PSObject.Properties['pendingNoteKey']) $r.Out
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out) -Body ('Legacy migrated incident closed out with a real note describing the cause and the verified prevention guard so a later session can act on it.')
    $r = Fire -Copy $c -Cwd $p
    Check 'migration: writing the note clears the migrated obligation -> completion allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'migration: the satisfied legacy key is now carried in resolvedIncidents' ((Get-ResolvedCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) ''

    # A legacy resolvedIncident is carried forward into the resolvedIncidents SET.
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'MigrateLegacyResolved'
    $legacyPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $legacyPath (([ordered]@{
                resolvedIncident = 'legacy-resolved-abc'; pendingNoteKey = ''; pendingNoteReason = ''
                pendingNoteBaseline = -1; deferredFingerprint = ''; updatedUtc = [DateTime]::UtcNow.ToString('o')
            }) | ConvertTo-Json)
    # A clean current run makes the hook reach its final save so the migrated shape is written out.
    Write-ObservedRecord -Copy $c -Root $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    Check 'migration: a legacy resolvedIncident with a clean run stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'migration: the legacy resolvedIncident is carried into the resolvedIncidents set' (
        (Get-ResolvedCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) ''

    # =====================================================================
    Write-Host '--- the durable .ai/ note requirement ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy
    $p = New-GitRepo 'Note'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'idleTimeout' -TerminateDetail 'produced no output or state change for 300s'
    $r = Fire -Copy $c -Cwd $p
    Check 'the incident blocks first and registers the owed note' ($r.Out -match '"decision":"block"') $r.Out
    # The run itself is now fixed: a fresh clean result replaces the incident.
    Write-GuardedResult -Copy $c -Root $p -Overall 'ok'
    $r = Fire -Copy $c -Cwd $p
    $reason = Get-BlockReason $r.Out
    Check 'a clean re-run does NOT clear the owed note - it still blocks' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the outstanding item is identified as the durable .ai/ note' (
        $reason -match 'durable \.ai/ note is still owed' -and $reason -match 'idleTimeout') $reason
    Check 'the note requirement names the four candidate files' (
        $reason -match 'BUGS\.md' -and $reason -match 'TESTING_NOTES\.md' -and $reason -match 'COMMANDS\.md' -and $reason -match 'LESSON\.md') $reason
    Add-AiNote -Root $p -Text 'done'
    $r = Fire -Copy $c -Cwd $p
    Check 'the word "done" leaves the durable-note obligation pending without repeating output' (
        $r.Exit -eq 0 -and $r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) $r.Out
    Check 'the original block says a bare acknowledgement will not clear it' ($reason -match 'bare acknowledgement') $reason
    # An UNTAGGED real note (long enough to clear the byte floor) still does NOT
    # satisfy it - the incident's own tag is required.
    Add-AiNote -Root $p -Text ('Idle-timeout hang in the integration suite: the runner reported no output for 300s. ' +
        'Not detected earlier because no idle bound existed at all. Guard: Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300, verified by re-running the suite.')
    $r = Fire -Copy $c -Cwd $p
    Check 'an untagged note cannot resolve the pending incident even when output is deduplicated' (
        $r.Exit -eq 0 -and $r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1 -and
        (Get-ResolvedCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 0) $r.Out
    # Retain the originally delivered incident key; silence is not a new receipt.
    Add-TaggedNote -Root $p -Reason $reason -Body ('Idle-timeout hang in the integration suite (tagged); guard Run-Tests-Guarded.ps1 -IdleTimeoutSeconds 300.')
    $r = Fire -Copy $c -Cwd $p
    Check 'a real durable note satisfies the requirement -> completion allowed' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p
    Check 'the satisfied incident stays resolved on the next event (no nagging)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Test-Temp-Cleanup same-Stop race: defer to the NEXT event ---' -ForegroundColor Cyan
    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'Race'
    New-CleanupMarker $p
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    Check 'cleanup installed but not yet recorded -> defers silently on this event' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Copy $c -Cwd $p
    Check 'the NEXT event evaluates normally - the deferral never loops forever' ($r.Out -match '"decision":"block"') $r.Out

    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'RaceResolved'
    New-CleanupMarker $p
    Write-CleanupResult -Copy $c -Root $p -Category 'clean'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'exceeded the 1800s wall ceiling'
    $r = Fire -Copy $c -Cwd $p
    Check 'cleanup already recorded for the current state -> no deferral, evaluates at once' ($r.Out -match '"decision":"block"') $r.Out

    $c = New-IsolatedHookCopy @{ TEST_COMPLETION_COORDINATION_WAIT_SECONDS = '0' }
    $p = New-GitRepo 'RaceNotInstalled'
    Write-CleanupResult -Copy $c -Root $p -Category 'clean' -Fingerprint 'stale-other-state'
    Write-GuardedResult -Copy $c -Root $p -Overall 'terminated' -ExitCode 124 -TerminateReason 'wallTimeout' -TerminateDetail 'x'
    $r = Fire -Copy $c -Cwd $p
    Check 'cleanup NOT installed -> its state is irrelevant, no deferral at all' ($r.Out -match '"decision":"block"') $r.Out

