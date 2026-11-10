# Explicitly associate equivalent verified recovery work with one historical
# incident. Never infer command equivalence or change the normal evidence gate.
# Called under Save-CompletionState's project mutex; writes only that ledger.

function Read-RecoveryReceipt {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1048576) { throw 'Recovery: regular bounded receipt required.' }
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
    if ($script:MalformedEvidence.Count -gt 0) { throw 'Malformed evidence: recovery refused; originals retained.' }
    $negativeMatches = @($entries | Where-Object { (Get-ResultIncidentKey -Doc $_.Doc -Path $_.Path) -eq $IncidentKey })
    $recoveryMatches = @($entries | Where-Object { [string](Get-Field $_.Doc 'runId') -ceq $RecoveryRunId })
    if ($negativeMatches.Count -eq 0 -or $negativeMatches.Count -gt 50 -or $recoveryMatches.Count -ne 1) { throw 'Recovery: bounded original group + ONE requested run-ID receipt.' }
    $negatives = @($negativeMatches | ForEach-Object { Read-RecoveryReceipt $_.Path } | Sort-Object { [string](Get-Field $_.Doc 'runId') })
    $negative = $negatives[0]
    $recovery = Read-RecoveryReceipt $recoveryMatches[0].Path
    if ((Get-ResultIncidentKey -Doc $negative.Doc -Path $negative.Path) -ne $IncidentKey -or [string](Get-Field $recovery.Doc 'runId') -cne $RecoveryRunId) { throw 'Receipt changed; await writer, retry.' }
    foreach ($receipt in @($negatives) + @($recovery)) {
        $root = [string](Get-Field $receipt.Doc 'workingDirectory')
        if ([string]::IsNullOrWhiteSpace($root) -or -not [string]::Equals((Normalize-Path $root), (Normalize-Path $script:cwd), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Original/recovery root != exact project.' }
    }
    $pins = @()
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($original in $negatives) {
        $id = [string](Get-Field $original.Doc 'runId')
        if ((Get-ResultIncidentKey $original.Doc $original.Path) -cne $IncidentKey -or [string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id) -or $id -ceq $RecoveryRunId) { throw 'Originals: same incident, distinct IDs, not recovery.' }
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
    if ([string]::IsNullOrWhiteSpace($negativeId)) { throw 'Original runId missing; incident/recovery indistinguishable.' }
    if ($negativeId -eq $RecoveryRunId) { throw 'Same incident/recovery ID; need distinct later clean run.' }
    if ([string]::IsNullOrWhiteSpace($recoveryCmd)) { throw 'commandFingerprint missing: UNKNOWN. New run ID via scripts\Run-Tests-Guarded.ps1.' }
    if ([string]::IsNullOrWhiteSpace($recoveryFp)) { throw 'projectFingerprint missing: use Test-Run-Guard replacement/valid -ProjectFingerprint/new run ID.' }
    $exitCode = -1
    $rawExit = Get-Field $recovery.Doc 'exitCode'
    $leakProperty = $recovery.Doc.PSObject.Properties['leakedProcessIds']
    if ([string](Get-Field $recovery.Doc 'overall') -ne 'ok' -or -not [int]::TryParse([string]$rawExit, [ref]$exitCode) -or $exitCode -ne 0 -or (Get-Field $recovery.Doc 'terminated') -ne $false -or $null -eq $leakProperty -or -not ($leakProperty.Value -is [array]) -or $leakProperty.Value.Count -ne 0) { throw 'Recovery requires overall=ok/exitCode=0/terminated=false/leakedProcessIds=[].' }
    $recoveryStart = ConvertTo-UtcTime (Get-Field $recovery.Doc 'startedUtc')
    $recoveryEnd = ConvertTo-UtcTime (Get-Field $recovery.Doc 'endedUtc')
    if ($null -eq $recoveryStart -or $null -eq $recoveryEnd -or $recoveryEnd -lt $recoveryStart -or $recoveryEnd -gt [DateTime]::UtcNow.AddSeconds(2)) { throw 'Recovery: strictly after incident end; valid ordered nonfuture timestamps.' }

    foreach ($active in @(Get-CompletionStateEntries 'active')) {
        $state = Get-ActiveMarkerState -Doc $active.Doc -Path $active.Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $entries
        if ($state.State -eq 'live') { throw 'Project guarded run active; no recovery until owned work ends.' }
        if ($state.State -eq 'died') { throw 'Active ownership/outcome UNKNOWN; unfinished work cannot recover.' }
    }
    if ($script:MalformedEvidence.Count -gt 0) { throw 'Malformed active evidence prevents recovery admission.' }
    foreach ($original in $negatives) {
        $negativeEnd = ConvertTo-UtcTime (Get-Field $original.Doc 'endedUtc')
        if ($null -eq $negativeEnd -or $recoveryStart -le $negativeEnd) { throw 'Recovery starts strictly after ALL incident originals ended.' }
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
                if ($started -le $negativeEnd) { throw 'Leaked PID present/ownership uncertain: verify identity + cleanup before recovery.' }
            }
            finally { if ($null -ne $process) { $process.Dispose() } }
        }

    }
    # Pin every original; a writer changing a receipt during validation must not
    # turn the earlier snapshot into evidence for different bytes.
    foreach ($receipt in @($negatives) + @($recovery)) {
        if ((Read-RecoveryReceipt $receipt.Path).Sha256 -cne $receipt.Sha256) { throw 'Receipt changed during recovery validation.' }
    }
    if ($script:pendingNotes.Contains($IncidentKey) -and -not (Test-NoteObligationActionable $script:pendingNotes[$IncidentKey])) {
        throw 'Legacy origin UNKNOWN: audit first; grouped recovery cannot invent/retire it.'
    }
    $repeatAssociation = $script:recoveryAssociations.Contains($IncidentKey)
    if ($repeatAssociation) {
        $prior = $script:recoveryAssociations[$IncidentKey]
        $priorPins = @(Get-Field $prior 'negativeReceipts')
        $samePins = if ($null -eq $prior.PSObject.Properties['negativeReceipts']) { $negatives.Count -eq 1 -and [string](Get-Field $prior 'negativeReceiptSha256') -ceq $negative.Sha256 } else { @($priorPins).Count -eq $pins.Count -and (@($priorPins | ForEach-Object { [string](Get-Field $_ 'runId') + ':' + [string](Get-Field $_ 'receiptSha256') }) -join '|') -ceq (@($pins | ForEach-Object { $_.runId + ':' + $_.receiptSha256 }) -join '|') }
        if (-not $samePins -or [string](Get-Field $prior 'recoveryRunId') -cne $RecoveryRunId -or [string](Get-Field $prior 'recoveryReceiptSha256') -cne $recovery.Sha256) { throw 'Different recovery already pinned; no silent replacement.' }
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
        throw 'Termination/leak: own exact tag + substantive growth beyond baseline required.'
    }
    if ($script:pendingNotes.Contains($IncidentKey)) {
        $notePattern = '(?ms)^[ \t]*Test incident:[ \t]*' + [regex]::Escape($IncidentKey) + '[ \t]*\r?\n(?<body>.*?)(?=^[ \t]*(?:Test incident:|#{1,6}[ \t])|\z)'
        $substantive = $false
        foreach ($match in [regex]::Matches((Get-NoteText -Root $script:cwd), $notePattern)) {
            if ([System.Text.Encoding]::UTF8.GetByteCount($match.Groups['body'].Value.Trim()) -ge $script:MinNoteBytes) { $substantive = $true; break }
        }
        if (-not $substantive) { throw 'Own tag: substantive recovery, not unrelated growth.' }
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Reason.Trim()) -lt 80) { throw 'Reason: substantive equivalent scope + verified repair required.' }
    # The ledger mutex does not serialize receipt producers. Refuse observed
    # membership changes and new active work rather than pinning a stale subset.
    $latestEntries = @(Get-CompletionStateEntries 'result')
    $latestGroup = @($latestEntries | Where-Object { (Get-ResultIncidentKey $_.Doc $_.Path) -ceq $IncidentKey })
    $latestRecovery = @($latestEntries | Where-Object { [string](Get-Field $_.Doc 'runId') -ceq $RecoveryRunId })
    $oldPaths = @($negatives | ForEach-Object Path | Sort-Object)
    $newPaths = @($latestGroup | ForEach-Object Path | Sort-Object)
    if ($latestGroup.Count -ne $negatives.Count -or ($oldPaths -join '|') -cne ($newPaths -join '|') -or $latestRecovery.Count -ne 1 -or $latestRecovery[0].Path -cne $recovery.Path) { throw 'Receipt set changed; recovery refused, no association saved.' }
    foreach ($receipt in @($negatives) + @($recovery)) {
        if ((Read-RecoveryReceipt $receipt.Path).Sha256 -cne $receipt.Sha256) { throw 'A result document changed before recovery publication.' }
    }
    foreach ($active in @(Get-CompletionStateEntries 'active')) {
        $activeState = (Get-ActiveMarkerState -Doc $active.Doc -Path $active.Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $latestEntries).State
        if ($activeState -in @('live', 'died')) { throw 'Guarded work became active/unresolved during validation.' }
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
