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
            'failed historical runId=' + [string](Get-Field $Doc 'runId') + '; commandFingerprint=' + [string](Get-Field $Doc 'commandFingerprint') + '; endedUtc=' + [string](Get-Field $Doc 'endedUtc') + '; failedField=' + $NoCiRecoveryReason + '. Exit code=' + $exitCode + '.',
            'Retain receipt; SAME COMPLETE argv/audited scope only, unrelated CI!=repair.') }
    }
    $ci = Test-CiClearedFailure -ProjectRoot $ProjectRoot -FailureEndedUtc (ConvertTo-UtcStamp (Get-Field $Doc 'endedUtc'))
    if ($ci.Cleared) {
        if ($key -ne '') { Add-ResolvedIncident $key }
        $short = $ci.Sha; if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
        return [pscustomobject]@{
            Blocking = $false
            Lines    = @('guarded failure exit=' + $exitCode +
                '), but every CI check for commit ' + $short + ' (clean HEAD), passed after failure. ' +
                '. No heavy duplicate; local only for evidence CI cannot provide.')
        }
    }

    return [pscustomobject]@{
        Blocking = $true
        Lines    = @(
            'latest guarded run FAILED, exit=' + $exitCode + '; incomplete.',
            $(if ($LastProgress -ne '') { 'Last recorded progress: ' + $LastProgress } else { 'No final progress recorded.' }),
            'Repair SAME-command scripts\Run-Tests-Guarded.ps1 overall=ok or newer clean-HEAD exact-SHA CI; no weaker assertions/exits, unresolved!=pass.',
            # Pushing the repair and letting CI go green on that exact commit clears
            # this too, on a clean tree - which is the cheaper route when CI already
            # runs the suite. Stated because the alternative was an eleven-minute
            # duplicate local run that the sibling guard had already refused.
            'CI eligibility: ' + $ci.Reason + '.',
            # The supersede matches the COMMAND, not the tree state, so the edit that
            # fixed the failure does not disqualify the green run proving it. The escape
            # hatch is for when a re-run cannot reproduce the identity at all.
            'SAME WHOLE argv green survives edits, three suites!=one. Identity: pwsh -NoProfile -File "' + $HookPath + '" -ResolveIncident ' + $key + ' -RecoveryRunId "<verified recovery run id>" -ProjectRoot "' + $ProjectRoot + '" -Reason "<substantive equivalent test scope and verified repair, at least 80 UTF-8 bytes>".',
            'Supersession: exact WHOLE argv; three suites!=one.')
    }
}
