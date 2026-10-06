# Normalises a timestamp read back out of JSON to a genuine UTC DateTime.
#
# THIS IS NOT DEFENSIVE PADDING - it fixes a measured 210-minute error on this
# machine. ConvertFrom-Json rehydrates an ISO-8601 string into a [DateTime]
# whose Kind is already Utc; casting that to [string] renders the UTC clock
# with NO zone marker, and re-parsing the result yields Kind=Unspecified, so a
# following ToUniversalTime() subtracts the local offset a SECOND time. A run
# that had just ended then read as 3.5 hours old - i.e. STALE - which is the
# exact failure this hook exists to prevent. Every producer here (the guarded
# runner's startedUtc/endedUtc, Test-Run-Guard's recordedUtc) writes UTC, so an
# Unspecified Kind is treated as UTC rather than converted.
function ConvertTo-UtcTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = [DateTime]::MinValue
    if ($Value -is [DateTime]) {
        $parsed = $Value
    }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        if (-not [DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return $null
        }
    }
    if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { return $parsed }
    if ($parsed.Kind -eq [System.DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
    return [DateTime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
}

# The exact run-identity gate (mirrors Test-Run-Guard's Test-ResultMatchesObserved).
# A result describes the current observation ONLY when its command and project
# fingerprints match the observed record AND the current state, its start is not
# before the observation, its end is not before its start, its required fields
# are present, and - when the observing hook controlled the runId - the runId
# matches. A fresh result for a different run/command/state is NOT evidence.
function Test-ResultMatchesObserved {
    param($Result, $Observed, [string]$CurrentStateFingerprint)
    if ($null -eq $Result -or $null -eq $Observed) { return $false }
    $rCmdFp = [string](Get-Field $Result 'commandFingerprint')
    $rProjFp = [string](Get-Field $Result 'projectFingerprint')
    $rRunId = [string](Get-Field $Result 'runId')
    $rStarted = ConvertTo-UtcTime (Get-Field $Result 'startedUtc')
    $rEnded = ConvertTo-UtcTime (Get-Field $Result 'endedUtc')
    if ([string]::IsNullOrWhiteSpace($rCmdFp) -or [string]::IsNullOrWhiteSpace($rProjFp) -or $null -eq $rStarted -or $null -eq $rEnded) { return $false }
    $oCmdFp = [string](Get-Field $Observed 'commandFingerprint')
    $oProjFp = [string](Get-Field $Observed 'projectFingerprint')
    if ([string]::IsNullOrWhiteSpace($oProjFp)) { $oProjFp = [string](Get-Field $Observed 'fingerprint') }
    $oRunId = [string](Get-Field $Observed 'runId')
    $oControlled = ((Get-Field $Observed 'runIdControlled') -eq $true)
    $oObserved = ConvertTo-UtcTime (Get-Field $Observed 'observedUtc')
    if ($rCmdFp -ne $oCmdFp) { return $false }
    if ($rProjFp -ne $oProjFp) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($CurrentStateFingerprint) -and $rProjFp -ne $CurrentStateFingerprint) { return $false }
    if ($null -ne $oObserved -and $rStarted -lt $oObserved.AddSeconds(-2)) { return $false }
    if ($rEnded -lt $rStarted.AddSeconds(-2)) { return $false }
    if ($oControlled -and $rRunId -ne $oRunId) { return $false }
    return $true
}
