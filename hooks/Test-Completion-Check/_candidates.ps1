# ---- build the candidate runs for the CURRENT state ----
# Unknown legacy path bindings remain obligations when Git becomes readable.
# They cannot be discarded as a previous tree-state or paired as current proof.
$currentObserved = @($observedEntries | Where-Object {
    $fp = Get-ObservedFingerprint $_.Doc
    $repositoryState.State -eq 'unavailable' -or $fp -eq $stateFingerprint -or $fp -eq $projectKey -or [string]::IsNullOrWhiteSpace($fp)
})
$observedCurrent = ($currentObserved.Count -gt 0)
$observedCmdFps = New-Object System.Collections.Generic.HashSet[string]
foreach ($o in $currentObserved) {
    $oc = [string](Get-Field $o.Doc 'commandFingerprint')
    if ($oc -ne '') { [void]$observedCmdFps.Add($oc) }
}

# ONE-TO-ONE pairing (C3): each guarded result may satisfy AT MOST ONE observed
# run. Exact-runId (runIdControlled) pairings are resolved FIRST so an uncontrolled
# run cannot steal a controlled run's result; the remaining uncontrolled runs then
# each take a DISTINCT result from what is left. Two same-command runs invoked
# directly without -RunId therefore cannot both pair to one green result - the
# second is left unmatched and blocks (its own result is not in yet, or it failed).
# Shared with the D3 prune pre-pass via Get-ObservedResultAssignment.
$pairableResults = if ($repositoryState.State -eq 'unavailable') { @() } else { $resultEntries }
$mainAssign = Get-ObservedResultAssignment -CurrentObserved $currentObserved -ResultEntries $pairableResults -StateFp $stateFingerprint
$sortedObserved = $mainAssign.SortedObserved
$obsResultMap = $mainAssign.Map
$pairedPaths = $mainAssign.AssignedPaths
$obsPairs = New-Object System.Collections.Generic.List[object]
for ($oi = 0; $oi -lt $sortedObserved.Count; $oi++) {
    $resEntry = if ($obsResultMap.ContainsKey($oi)) { $obsResultMap[$oi] } else { $null }
    [void]$obsPairs.Add([pscustomobject]@{ Observed = $sortedObserved[$oi].Doc; ResEntry = $resEntry })
}

$runs = New-Object System.Collections.Generic.List[object]
# Each current observed run, with its identity-matched result (if any). When none
# matches, a result for the SAME command that is NOT another run's result is
# attached for messaging only, so a genuine identity mismatch reads DIFFERENT run
# while a run that simply has no result of its own reads as missing evidence.
foreach ($op in $obsPairs) {
    $sameCmdEntry = $null
    if ($null -eq $op.ResEntry) {
        $oCmd = [string](Get-Field $op.Observed 'commandFingerprint')
        if ($oCmd -ne '') {
            $sc = @($resultEntries | Where-Object { ([string](Get-Field $_.Doc 'commandFingerprint')) -eq $oCmd -and -not $pairedPaths.Contains($_.Path) })
            if ($sc.Count -gt 0) {
                $sameCmdEntry = @($sc | Sort-Object @{ Expression = { [string](Get-Field $_.Doc 'runId') -ne [string](Get-Field $op.Observed 'runId') } }, @{ Expression = { [string]$_.Path } })[0]
            }
        }
    }
    [void]$runs.Add([pscustomobject]@{ Observed = $op.Observed; ResultEntry = $op.ResEntry; SameCmdEntry = $sameCmdEntry; HasObserved = $true; Matches = ($null -ne $op.ResEntry) })
}
# A current-state result with NO observation and whose command matches no observed
# run is an independent run (e.g. a guarded runner invoked directly). A result
# whose command DOES match an observed run is just a different run of that command
# and belongs to that observed run's messaging, not a new run.
foreach ($re in $resultEntries) {
    $rProjFp = [string](Get-Field $re.Doc 'projectFingerprint')
    $isCurrentState = if ($rProjFp -ne '') { $rProjFp -eq $stateFingerprint } else { $ended = ConvertTo-UtcStamp (Get-Field $re.Doc 'endedUtc'); ($null -ne $ended -and ([DateTime]::UtcNow - $ended).TotalHours -le 24) }   # legacy result: no identity, so the 24 h horizon governs
    if ($repositoryState.State -eq 'unavailable') {
        # Unreadable state cannot certify success, but cannot hide a negative.
        $isCurrentState = ([string](Get-Field $re.Doc 'overall') -ne 'ok' -or (Get-IncidentReasonFromDoc $re.Doc) -ne '')
    }
    $legacyNegative = (($rProjFp -eq $projectKey -or [string]::IsNullOrWhiteSpace($rProjFp)) -and ([string](Get-Field $re.Doc 'overall') -ne 'ok' -or (Get-IncidentReasonFromDoc $re.Doc) -ne ''))
    if ($legacyNegative) { $isCurrentState = $true }
    if (-not $isCurrentState) { continue }
    $rCmd = [string](Get-Field $re.Doc 'commandFingerprint')
    if ($rCmd -ne '' -and $observedCmdFps.Contains($rCmd) -and -not ($legacyNegative -or ($repositoryState.State -eq 'unavailable' -and ([string](Get-Field $re.Doc 'overall') -ne 'ok' -or (Get-IncidentReasonFromDoc $re.Doc) -ne '')))) { continue }
    [void]$runs.Add([pscustomobject]@{ Observed = $null; ResultEntry = $re; SameCmdEntry = $null; HasObserved = $false; Matches = $true })
}
