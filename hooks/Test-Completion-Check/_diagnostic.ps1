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
    if ($null -eq $Result) { [void]$lines.Add('TEST COMPLETION CHECK: exact observation lacks guarded result.') }
    if ($field -eq 'recordedUtc:STALE') { [void]$lines.Add('TEST COMPLETION CHECK: STALE >' + $script:evidenceMinutes + 'min, not current proof.') }
    if ((Get-Field $Observed 'guarded') -eq $false) { [void]$lines.Add('UNGUARDED: no owner/bound.') }
    [void]$lines.Add('TEST COMPLETION CHECK: UNRESOLVED; runId=' + [string](Get-Field $Observed 'runId') + '; commandFingerprint=' + [string](Get-Field $Observed 'commandFingerprint') + '; observedUtc=' + $( $at = ConvertTo-UtcTime (Get-Field $Observed 'observedUtc'); if ($null -ne $at) { $at.ToString('o') } else { '<invalid or missing>' }) + '; failedField=' + $field + '.')
    [void]$lines.Add('Missing/different run/argv/state!=pass; prove scope.')
    [void]$lines.Add('Repository=' + $State.State + '; path-only projectKey=' + $State.ProjectKey + '; candidate runId=' + [string](Get-Field $Result 'runId') + '; overall=' + [string](Get-Field $Result 'overall') + '.')
    if ($State.State -eq 'available' -and $null -ne $Observed -and (Get-ObservedFingerprint $Observed) -eq $State.RepositoryStateFingerprint) { [void]$lines.Add('CURRENT needs same scope.') }
    if ($State.State -eq 'unavailable') {
        [void]$lines.Add('Access=' + [string]$State.Diagnosis + '; physical-root owner consent required, selection != consent.')
        [void]$lines.Add('Authorized Git read/exact fingerprint only; no trust/ACL/owner edits. Retain failures; unrelated green!=identity.')
    }
    [void]$lines.Add('Recovery: later clean independently paired SAME COMPLETE argv; fresh mutation consent. Never fill identity/delete originals; UNKNOWN/SUPERSEDED!=SUCCESS.')
    [void]$lines.Add('Read-only audit (UNKNOWN blocks): pwsh -NoProfile -File "' + $HookPath + '" -AuditEvidence -ProjectRoot "' + $ProjectRoot + '" -AuditPath "<new local JSON>".')
    return $lines.ToArray()
}
