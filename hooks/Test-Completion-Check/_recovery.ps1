# Explicitly associate equivalent verified recovery work with one historical
# incident. Never infer command equivalence or change the normal evidence gate.
# Called under Save-CompletionState's project mutex; writes only that ledger.

function Read-RecoveryReceipt {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1048576) { throw 'Recovery requires a regular bounded result document.' }
    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    $doc = $text | ConvertFrom-Json
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ Doc = $doc; Path = $item.FullName; Sha256 = $hash }
}

function Test-RecoveryReceiptRetained {
    param([string]$RunId)
    if ($RunId -eq '') { return $false }
    foreach ($association in @($script:recoveryAssociations.Values)) {
        if ([string](Get-Field $association 'negativeRunId') -eq $RunId -or [string](Get-Field $association 'recoveryRunId') -eq $RunId) { return $true }
        foreach ($receipt in @(Get-Field $association 'negativeReceipts')) {
            if ([string](Get-Field $receipt 'runId') -ceq $RunId) { return $true }
        }
    }
    return $false
}

function Set-VerifiedIncidentRecovery {
    param([string]$IncidentKey, [string]$RecoveryRunId, [string]$Reason)
    $access = Get-RepositoryStateEvidence -ProjectRoot $script:cwd
    if ($access.State -eq 'unavailable') { throw ('Recovery requires verified repository read access; diagnosis=' + $access.Diagnosis + '. Originals remain unchanged.') }
    $entries = @(Get-CompletionStateEntries 'result')
    if ($script:MalformedEvidence.Count -gt 0) { throw 'Malformed evidence prevents recovery admission; originals remain unchanged.' }
    $negativeMatches = @($entries | Where-Object { (Get-ResultIncidentKey -Doc $_.Doc -Path $_.Path) -eq $IncidentKey })
    $recoveryMatches = @($entries | Where-Object { [string](Get-Field $_.Doc 'runId') -ceq $RecoveryRunId })
    if ($negativeMatches.Count -eq 0 -or $negativeMatches.Count -gt 50 -or $recoveryMatches.Count -ne 1) { throw 'Recovery requires one bounded original incident group and exactly one receipt for the requested recovery run ID.' }
    $negatives = @($negativeMatches | ForEach-Object { Read-RecoveryReceipt $_.Path } | Sort-Object { [string](Get-Field $_.Doc 'runId') })
    $negative = $negatives[0]
    $recovery = Read-RecoveryReceipt $recoveryMatches[0].Path
    if ((Get-ResultIncidentKey -Doc $negative.Doc -Path $negative.Path) -ne $IncidentKey -or [string](Get-Field $recovery.Doc 'runId') -cne $RecoveryRunId) { throw 'A result document changed while recovery was being validated. Retry after its writer finishes.' }
    foreach ($receipt in @($negatives) + @($recovery)) {
        $root = [string](Get-Field $receipt.Doc 'workingDirectory')
        if ([string]::IsNullOrWhiteSpace($root) -or -not [string]::Equals((Normalize-Path $root), (Normalize-Path $script:cwd), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Every original and recovery receipt must belong to this exact project directory.' }
    }
    $pins = @()
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($original in $negatives) {
        $id = [string](Get-Field $original.Doc 'runId')
        if ((Get-ResultIncidentKey $original.Doc $original.Path) -cne $IncidentKey -or [string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id) -or $id -ceq $RecoveryRunId) { throw 'Every original must have a distinct run ID and still belong to this incident group, separate from recovery.' }
        $pins += [pscustomobject][ordered]@{ runId = $id; receiptSha256 = $original.Sha256; commandFingerprint = [string](Get-Field $original.Doc 'commandFingerprint'); projectFingerprint = [string](Get-Field $original.Doc 'projectFingerprint'); endedUtc = Get-Field $original.Doc 'endedUtc' }
    }
    $negativeId = [string](Get-Field $negative.Doc 'runId')
    $recoveryFp = [string](Get-Field $recovery.Doc 'projectFingerprint')
    $recoveryCmd = [string](Get-Field $recovery.Doc 'commandFingerprint')
    # One message for four causes told the reader to look at the wrong field.
    # The projectFingerprint case is not hypothetical: Run-Tests-Guarded.ps1
    # takes -ProjectFingerprint from the observing hook and writes it verbatim,
    # so a run typed by hand rather than taken from the guard's own replacement
    # records an empty one and is disqualified here - silently, until now.
    if ([string]::IsNullOrWhiteSpace($negativeId)) { throw 'The original incident receipt records no runId, so it cannot be told apart from the recovery run.' }
    if ($negativeId -eq $RecoveryRunId) { throw 'The recovery run ID is the incident''s own run ID. Recovery needs a SEPARATE later clean run, not the failing one.' }
    if ([string]::IsNullOrWhiteSpace($recoveryCmd)) { throw 'The recovery receipt records no commandFingerprint, so what it actually ran cannot be established. Re-run through scripts\Run-Tests-Guarded.ps1 and use the new run ID.' }
    if ([string]::IsNullOrWhiteSpace($recoveryFp)) { throw 'The recovery receipt records no projectFingerprint. Run-Tests-Guarded.ps1 persists whatever -ProjectFingerprint it was given, so a hand-typed invocation leaves it empty. Re-run using the replacement command Test-Run-Guard prints (it supplies the value), or pass -ProjectFingerprint yourself, then use that new run ID.' }
    $exitCode = -1
    $rawExit = Get-Field $recovery.Doc 'exitCode'
    $leakProperty = $recovery.Doc.PSObject.Properties['leakedProcessIds']
    if ([string](Get-Field $recovery.Doc 'overall') -ne 'ok' -or -not [int]::TryParse([string]$rawExit, [ref]$exitCode) -or $exitCode -ne 0 -or (Get-Field $recovery.Doc 'terminated') -ne $false -or $null -eq $leakProperty -or -not ($leakProperty.Value -is [array]) -or $leakProperty.Value.Count -ne 0) { throw 'The recovery receipt must report overall=ok, exitCode=0, terminated=false and an empty leakedProcessIds array.' }
    $recoveryStart = ConvertTo-UtcTime (Get-Field $recovery.Doc 'startedUtc')
    $recoveryEnd = ConvertTo-UtcTime (Get-Field $recovery.Doc 'endedUtc')
    if ($null -eq $recoveryStart -or $null -eq $recoveryEnd -or $recoveryEnd -lt $recoveryStart -or $recoveryEnd -gt [DateTime]::UtcNow.AddSeconds(2)) { throw 'Recovery must start strictly after the incident ended and carry valid, ordered, non-future timestamps.' }

    foreach ($active in @(Get-CompletionStateEntries 'active')) {
        $state = Get-ActiveMarkerState -Doc $active.Doc -Path $active.Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $entries
        if ($state.State -eq 'live') { throw 'A guarded run is still active for this project. Recovery cannot be recorded while owned work is running.' }
        if ($state.State -eq 'died') { throw 'An active marker has unresolved ownership or outcome; recovery cannot certify unfinished work.' }
    }
    if ($script:MalformedEvidence.Count -gt 0) { throw 'Malformed active evidence prevents recovery admission.' }
    foreach ($original in $negatives) {
        $negativeEnd = ConvertTo-UtcTime (Get-Field $original.Doc 'endedUtc')
        if ($null -eq $negativeEnd -or $recoveryStart -le $negativeEnd) { throw 'Recovery must start strictly after every original in the incident group ended.' }
        foreach ($rawPid in @(Get-Field $original.Doc 'leakedProcessIds')) {
            if ($null -eq $rawPid) { continue }
            $leakedPid = 0
            if (-not [int]::TryParse([string]$rawPid, [ref]$leakedPid) -or $leakedPid -le 0) { throw 'A recorded leaked process ID cannot be validated.' }
            $process = $null
            try { $process = [System.Diagnostics.Process]::GetProcessById($leakedPid) }
            catch [System.ArgumentException] { continue }
            try {
                if ($process.HasExited) { continue }
                $started = $process.StartTime.ToUniversalTime()
                # A PID started after the old run ended is a reused number. Never
                # terminate it or mistake it for the recorded descendant.
                if ($started -le $negativeEnd) { throw 'A recorded leaked process is still present, or its ownership cannot be ruled out. Verify its identity and cleanup before recovery.' }
            }
            finally { if ($null -ne $process) { $process.Dispose() } }
        }

    }
    # Pin every original; a writer changing a receipt during validation must not
    # turn the earlier snapshot into evidence for different bytes.
    foreach ($receipt in @($negatives) + @($recovery)) {
        if ((Read-RecoveryReceipt $receipt.Path).Sha256 -cne $receipt.Sha256) { throw 'A result document changed while recovery was being validated.' }
    }
    if ($script:pendingNotes.Contains($IncidentKey) -and -not (Test-NoteObligationActionable $script:pendingNotes[$IncidentKey])) {
        throw 'This incident has an unresolved legacy note origin. Audited origin reconciliation is required; grouped recovery does not invent an origin or retire UNKNOWN.'
    }
    $repeatAssociation = $script:recoveryAssociations.Contains($IncidentKey)
    if ($repeatAssociation) {
        $prior = $script:recoveryAssociations[$IncidentKey]
        $priorPins = @(Get-Field $prior 'negativeReceipts')
        $samePins = if ($null -eq $prior.PSObject.Properties['negativeReceipts']) { $negatives.Count -eq 1 -and [string](Get-Field $prior 'negativeReceiptSha256') -ceq $negative.Sha256 } else { @($priorPins).Count -eq $pins.Count -and (@($priorPins | ForEach-Object { [string](Get-Field $_ 'runId') + ':' + [string](Get-Field $_ 'receiptSha256') }) -join '|') -ceq (@($pins | ForEach-Object { $_.runId + ':' + $_.receiptSha256 }) -join '|') }
        if (-not $samePins -or [string](Get-Field $prior 'recoveryRunId') -cne $RecoveryRunId -or [string](Get-Field $prior 'recoveryReceiptSha256') -cne $recovery.Sha256) { throw 'This incident already has a different pinned recovery association; it cannot be silently replaced.' }
    }
    # This proves a historical repair, not today's product state. A genuine
    # recovery does not expire with the separate current-evidence time window.
    # A note is required only where one is actually OWED. The ledger records an
    # obligation for a termination or a leak - findings whose lesson outlives the run -
    # and those still demand their tagged note here. A plain assertion failure owes
    # none, and demanding one anyway made this whole path unreachable: the failed-run
    # block prints a -ResolveIncident command, and it was refused on arrival because
    # its key had never been registered. The incident is already PROVEN at this point
    # by every matching receipt found above; the ledger is not a second proof.
    if ($script:pendingNotes.Contains($IncidentKey) -and -not (Test-PendingNoteSatisfied -Key $IncidentKey)) {
        throw 'This incident owes a durable note (it was a termination or a leak), and still needs its own exact tag plus substantive content beyond its recorded baseline.'
    }
    if ($script:pendingNotes.Contains($IncidentKey)) {
        $notePattern = '(?ms)^[ \t]*Test incident:[ \t]*' + [regex]::Escape($IncidentKey) + '[ \t]*\r?\n(?<body>.*?)(?=^[ \t]*(?:Test incident:|#{1,6}[ \t])|\z)'
        $substantive = $false
        foreach ($match in [regex]::Matches((Get-NoteText -Root $script:cwd), $notePattern)) {
            if ([System.Text.Encoding]::UTF8.GetByteCount($match.Groups['body'].Value.Trim()) -ge $script:MinNoteBytes) { $substantive = $true; break }
        }
        if (-not $substantive) { throw 'The incident tag must accompany its own substantive recovery explanation, not only unrelated note growth.' }
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Reason.Trim()) -lt 80) { throw 'Recovery needs a substantive reason describing equivalent scope and the verified repair.' }
    # The ledger mutex does not serialize receipt producers. Refuse observed
    # membership changes and new active work rather than pinning a stale subset.
    $latestEntries = @(Get-CompletionStateEntries 'result')
    $latestGroup = @($latestEntries | Where-Object { (Get-ResultIncidentKey $_.Doc $_.Path) -ceq $IncidentKey })
    $latestRecovery = @($latestEntries | Where-Object { [string](Get-Field $_.Doc 'runId') -ceq $RecoveryRunId })
    $oldPaths = @($negatives | ForEach-Object Path | Sort-Object)
    $newPaths = @($latestGroup | ForEach-Object Path | Sort-Object)
    if ($latestGroup.Count -ne $negatives.Count -or ($oldPaths -join '|') -cne ($newPaths -join '|') -or $latestRecovery.Count -ne 1 -or $latestRecovery[0].Path -cne $recovery.Path) { throw 'The incident receipt set changed during recovery validation; no association was recorded.' }
    foreach ($receipt in @($negatives) + @($recovery)) {
        if ((Read-RecoveryReceipt $receipt.Path).Sha256 -cne $receipt.Sha256) { throw 'A result document changed before recovery publication.' }
    }
    foreach ($active in @(Get-CompletionStateEntries 'active')) {
        $activeState = (Get-ActiveMarkerState -Doc $active.Doc -Path $active.Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $latestEntries).State
        if ($activeState -in @('live', 'died')) { throw 'A guarded run became active or unresolved during recovery validation.' }
    }
    if ($script:MalformedEvidence.Count -gt 0) { throw 'Malformed evidence appeared before recovery publication.' }
    # Repetition has the same admission boundary, not an early UNKNOWN-note waiver.
    if ($repeatAssociation) { Add-ResolvedIncident $IncidentKey; return }
    $script:recoveryAssociations[$IncidentKey] = [pscustomobject][ordered]@{
        incidentKey = $IncidentKey
        negativeReceipts = $pins
        negativeRunId = $negativeId
        negativeCommandFingerprint = [string](Get-Field $negative.Doc 'commandFingerprint')
        negativeProjectFingerprint = [string](Get-Field $negative.Doc 'projectFingerprint')
        negativeReceiptSha256 = $negative.Sha256
        recoveryRunId = $RecoveryRunId
        recoveryCommandFingerprint = $recoveryCmd
        recoveryProjectFingerprint = $recoveryFp
        recoveryReceiptSha256 = $recovery.Sha256
        recoveryEndedUtc = $recoveryEnd.ToString('o')
        associatedUtc = [DateTime]::UtcNow.ToString('o')
        reason = $Reason.Trim()
    }
    while ($script:recoveryAssociations.Count -gt $script:MaxResolvedIncidents) { $script:recoveryAssociations.Remove([string]@($script:recoveryAssociations.Keys)[0]) }
    Add-ResolvedIncident $IncidentKey
}
