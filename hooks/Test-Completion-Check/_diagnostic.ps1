# Identity diagnostics are data-only. No rerun of a different scope repairs an
# observation, and no missing field is retrospectively filled in a receipt.
function Get-ObservationMatchingField {
    param($Observed, $Result, [string]$StateFp)
    if ($null -eq $Result) { return 'resultDocument:missing' }
    foreach ($name in @('commandFingerprint','projectFingerprint')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Field $Result $name))) { return ($name + ':missing') }
    }
    $started = ConvertTo-UtcTime (Get-Field $Result 'startedUtc')
    $ended = ConvertTo-UtcTime (Get-Field $Result 'endedUtc')
    if ($null -eq $started) { return 'startedUtc:invalid' }
    if ($null -eq $ended) { return 'endedUtc:invalid' }
    if ([string](Get-Field $Result 'commandFingerprint') -ne [string](Get-Field $Observed 'commandFingerprint')) { return 'commandFingerprint:mismatch' }
    if ([string](Get-Field $Result 'projectFingerprint') -ne (Get-ObservedFingerprint $Observed)) { return 'projectFingerprint:mismatch' }
    if ($StateFp -ne '' -and [string](Get-Field $Result 'projectFingerprint') -ne $StateFp) { return 'repositoryStateFingerprint:mismatch' }
    $at = ConvertTo-UtcTime (Get-Field $Observed 'observedUtc')
    if ($null -ne $at -and $started -lt $at.AddSeconds(-2)) { return 'startedUtc:beforeObservation' }
    if ($ended -lt $started.AddSeconds(-2)) { return 'endedUtc:beforeStart' }
    if ((Get-Field $Observed 'runIdControlled') -eq $true -and [string](Get-Field $Result 'runId') -ne [string](Get-Field $Observed 'runId')) { return 'runId:mismatch' }
    return 'resultAssignment:alreadyConsumedOrUnproven'
}

function Get-UnresolvedObservationLines {
    param($Observed, $Result, $State, [bool]$Fresh, [string]$HookPath, [string]$ProjectRoot)
    $field = Get-ObservationMatchingField $Observed $Result $State.BindingFingerprint
    if ($State.State -eq 'unavailable' -and $field -eq 'resultAssignment:alreadyConsumedOrUnproven') { $field = 'repositoryStateFingerprint:unavailable' }
    if ($State.State -ne 'unavailable' -and $null -ne $Observed -and $null -ne $Result -and (Test-ResultMatchesObserved $Result $Observed $State.BindingFingerprint)) {
        $field = if (-not $Fresh) { 'recordedUtc:STALE' } else { 'overall:' + [string](Get-Field $Result 'overall') }
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Result) { [void]$lines.Add('TEST COMPLETION CHECK: no guarded result document exists for this exact observed run.') }
    if ($field -eq 'recordedUtc:STALE') { [void]$lines.Add('TEST COMPLETION CHECK: STALE result, older than ' + $script:evidenceMinutes + ' minutes; not fresh proof.') }
    if ((Get-Field $Observed 'guarded') -eq $false) { [void]$lines.Add('This observation was UNGUARDED: no runner owned or bounded its execution.') }
    [void]$lines.Add('TEST COMPLETION CHECK: unresolved identity evidence. runId=' + [string](Get-Field $Observed 'runId') + '; commandFingerprint=' + [string](Get-Field $Observed 'commandFingerprint') + '; observedUtc=' + $( $at = ConvertTo-UtcTime (Get-Field $Observed 'observedUtc'); if ($null -ne $at) { $at.ToString('o') } else { '<invalid or missing>' }) + '; failedField=' + $field + '.')
    [void]$lines.Add('Repository state=' + $State.State + '; projectKey=' + $State.ProjectKey + ' is path identity only, not CURRENT repository-state evidence. Candidate runId=' + [string](Get-Field $Result 'runId') + '; overall=' + [string](Get-Field $Result 'overall') + '. A DIFFERENT run, command or state is not proof for this observation.')
    if ($State.State -eq 'unavailable') {
        [void]$lines.Add('Recovery: restore authorized Git read access to this exact repository before requesting a verified literal fingerprint. No automatic safe.directory, ownership or ACL change is permitted. Existing failure/timeout/leak obligations remain; unrelated green CI cannot repair missing identity.')
    }
    [void]$lines.Add('Supported recovery: only a later clean, independently paired observation of the SAME COMPLETE command (the commandFingerprint above, including every argument) can supersede this unmatched observation. A different logo/readme/health scope cannot. Do not repeat a mutating command without fresh authorization; if safe recovery is unavailable, record UNKNOWN in the read-only audit below and report the gate unresolved. Never fill fields or delete originals.')
    [void]$lines.Add('Read-only audit: powershell.exe -NoProfile -File "' + $HookPath + '" -AuditEvidence -ProjectRoot "' + $ProjectRoot + '" -AuditPath "<new local JSON path>". The export records original hashes and UNKNOWN/SUPERSEDED, never SUCCESS; UNKNOWN keeps the gate.')
    return $lines.ToArray()
}
