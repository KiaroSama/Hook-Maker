# What to say about a guarded run that COMPLETED but failed.
#
# Its own file for two reasons. It is one question with two answers, and
# Test-Completion-Check.ps1 is far past the size ceiling and closed to new code -
# so the CI-evidence branch had to shrink it, not grow it.

. (Join-Path $PSScriptRoot '_cievidence.ps1')

# The marker stores a round-trip 'o' stamp, but ConvertFrom-Json on pwsh 7 hands
# back a [DateTime] while 5.1 leaves it a string, and stringifying that DateTime
# renders it in the CURRENT CULTURE with no zone marker - which TryParse then
# reads as local time and shifts by the machine's UTC offset. Same trap that hid
# a pinning defect in Test-Run-Guard until a +03:30 workstation surfaced it.
function ConvertTo-UtcStamp {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($text, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $null }
    return $parsed.ToUniversalTime()
}

function Resolve-FailedRunVerdict {
    param(
        [Parameter(Mandatory = $true)]$Doc,
        [AllowEmptyString()][string]$Path,
        [AllowEmptyString()][string]$LastProgress,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$HookPath,
        [bool]$AllowCiRecovery = $true,
        [ValidateSet('repositoryState:unavailable','projectFingerprint:currentStateMismatch','projectFingerprint:unavailableOrLegacy')]
        [string]$NoCiRecoveryReason = 'projectFingerprint:unavailableOrLegacy'
    )
    $exitCode = [string](Get-Field $Doc 'exitCode')
    # Derived once, because the -ResolveIncident line below must print the SAME
    # key recovery looks for.
    $key = Get-ResultIncidentKey -Doc $Doc -Path $Path

    # A green CI result for THIS exact commit is the other kind of proof that the
    # failure is behind us, and the only one available to a project whose heavy
    # pass runs in CI. Without it this gate demanded a second local run of the
    # suite the sibling guard had just told the reader not to run here.
    if (-not $AllowCiRecovery) {
        return [pscustomobject]@{ Blocking = $true; Lines = @(
            'failed runId=' + [string](Get-Field $Doc 'runId') + '; cmd=' + [string](Get-Field $Doc 'commandFingerprint') + '; ended=' + [string](Get-Field $Doc 'endedUtc') + '; failedField=' + $NoCiRecoveryReason + '; exit=' + $exitCode + '.',
            'Retain receipt; SAME COMPLETE argv/scope, unrelated CI!=repair.') }
    }
    $ci = Test-CiClearedFailure -ProjectRoot $ProjectRoot -FailureEndedUtc (ConvertTo-UtcStamp (Get-Field $Doc 'endedUtc'))
    if ($ci.Cleared) {
        if ($key -ne '') { Add-ResolvedIncident $key }
        $short = $ci.Sha; if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
        return [pscustomobject]@{
            Blocking = $false
            Lines    = @('guarded failure exit=' + $exitCode +
                ', CI green for ' + $short + ' (clean HEAD). ' +
                'No duplicate CI; local only if CI down.')
        }
    }

    return [pscustomobject]@{
        Blocking = $true
        Lines    = @(
            'latest guarded run FAILED, exit=' + $exitCode + '.',
            $(if ($LastProgress -ne '') { 'Progress: ' + $LastProgress } else { 'No progress.' }),
            'Wait until ALL checks finish, collect every failure, fix all in one batch, then rerun SAME scripts\Run-Tests-Guarded.ps1 overall=ok or clean-HEAD CI; no weaker assertions/exits, unresolved!=pass.',
            'CI: ' + $ci.Reason + '.',
            'SAME WHOLE argv green survives edits, three suites!=one. pwsh -NoProfile -File "' + $HookPath + '" -ResolveIncident ' + $key + ' -RecoveryRunId "<id>" -ProjectRoot "' + $ProjectRoot + '" -Reason "<>=80B verified repair>".')
    }
}
