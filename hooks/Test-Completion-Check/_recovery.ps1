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
    }
    return $false
}

function Set-VerifiedIncidentRecovery {
    param([string]$IncidentKey, [string]$RecoveryRunId, [string]$Reason)
    $entries = @(Get-CompletionStateEntries 'result')
    $negativeMatches = @($entries | Where-Object { (Get-ResultIncidentKey -Doc $_.Doc -Path $_.Path) -eq $IncidentKey })
    $recoveryMatches = @($entries | Where-Object { [string](Get-Field $_.Doc 'runId') -ceq $RecoveryRunId })
    if ($negativeMatches.Count -ne 1 -or $recoveryMatches.Count -ne 1) { throw 'Recovery requires exactly one original incident receipt and one receipt for the requested recovery run ID.' }
    $negative = Read-RecoveryReceipt $negativeMatches[0].Path
    $recovery = Read-RecoveryReceipt $recoveryMatches[0].Path
    if ((Get-ResultIncidentKey -Doc $negative.Doc -Path $negative.Path) -ne $IncidentKey -or [string](Get-Field $recovery.Doc 'runId') -cne $RecoveryRunId) { throw 'A result document changed while recovery was being validated. Retry after its writer finishes.' }
    foreach ($receipt in @($negative, $recovery)) {
        $root = [string](Get-Field $receipt.Doc 'workingDirectory')
        if ([string]::IsNullOrWhiteSpace($root) -or -not [string]::Equals((Normalize-Path $root), (Normalize-Path $script:cwd), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Both recovery receipts must belong to this exact project directory.' }
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
    $negativeEnd = ConvertTo-UtcTime (Get-Field $negative.Doc 'endedUtc')
    $recoveryStart = ConvertTo-UtcTime (Get-Field $recovery.Doc 'startedUtc')
    $recoveryEnd = ConvertTo-UtcTime (Get-Field $recovery.Doc 'endedUtc')
    if ($null -eq $negativeEnd -or $null -eq $recoveryStart -or $null -eq $recoveryEnd -or $recoveryStart -le $negativeEnd -or $recoveryEnd -lt $recoveryStart -or $recoveryEnd -gt [DateTime]::UtcNow.AddSeconds(2)) { throw 'Recovery must start strictly after the incident ended and carry valid, ordered, non-future timestamps.' }

    foreach ($active in @(Get-CompletionStateEntries 'active')) {
        $state = Get-ActiveMarkerState -Doc $active.Doc -Path $active.Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $entries
        if ($state.State -eq 'live') { throw 'A guarded run is still active for this project. Recovery cannot be recorded while owned work is running.' }
    }
    foreach ($rawPid in @(Get-Field $negative.Doc 'leakedProcessIds')) {
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

    if ($script:recoveryAssociations.Contains($IncidentKey)) {
        $prior = $script:recoveryAssociations[$IncidentKey]
        if ([string](Get-Field $prior 'recoveryRunId') -cne $RecoveryRunId -or [string](Get-Field $prior 'negativeReceiptSha256') -cne $negative.Sha256 -or [string](Get-Field $prior 'recoveryReceiptSha256') -cne $recovery.Sha256) { throw 'This incident already has a different pinned recovery association; it cannot be silently replaced.' }
        Add-ResolvedIncident $IncidentKey
        return
    }
    # This proves a historical repair, not today's product state. A genuine
    # recovery does not expire with the separate current-evidence time window.
    # A note is required only where one is actually OWED. The ledger records an
    # obligation for a termination or a leak - findings whose lesson outlives the run -
    # and those still demand their tagged note here. A plain assertion failure owes
    # none, and demanding one anyway made this whole path unreachable: the failed-run
    # block prints a -ResolveIncident command, and it was refused on arrival because
    # its key had never been registered. The incident is already PROVEN at this point
    # by the single matching receipt found above; the ledger is not a second proof.
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
    $script:recoveryAssociations[$IncidentKey] = [pscustomobject][ordered]@{
        incidentKey = $IncidentKey
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
