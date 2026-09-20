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
        [Parameter(Mandatory = $true)][string]$HookPath
    )
    $exitCode = [string](Get-Field $Doc 'exitCode')
    # Derived once, because the -ResolveIncident line below must print the SAME
    # key recovery looks for.
    $key = Get-ResultIncidentKey -Doc $Doc -Path $Path

    # A green CI result for THIS exact commit is the other kind of proof that the
    # failure is behind us, and the only one available to a project whose heavy
    # pass runs in CI. Without it this gate demanded a second local run of the
    # suite the sibling guard had just told the reader not to run here.
    $ci = Test-CiClearedFailure -ProjectRoot $ProjectRoot -FailureEndedUtc (ConvertTo-UtcStamp (Get-Field $Doc 'endedUtc'))
    if ($ci.Cleared) {
        if ($key -ne '') { Add-ResolvedIncident $key }
        $short = $ci.Sha; if ($short.Length -gt 7) { $short = $short.Substring(0, 7) }
        return [pscustomobject]@{
            Blocking = $false
            Lines    = @('TEST COMPLETION CHECK: a guarded test run for this project FAILED (exit code ' + $exitCode +
                '), but every CI check for commit ' + $short + ' - the exact commit this clean tree is on - passed after that failure ended. ' +
                'That is the heavy pass, so it is not run again here. Re-run locally only if you need evidence CI cannot give you.')
        }
    }

    return [pscustomobject]@{
        Blocking = $true
        Lines    = @(
            'TEST COMPLETION CHECK: the latest guarded test run for this project FAILED (exit code ' + $exitCode + '). The work is not verifiably complete.',
            $(if ($LastProgress -ne '') { 'Last recorded progress: ' + $LastProgress } else { 'The result document records no final progress line.' }),
            'Recovery: inspect the actual failure, fix the root cause, and re-run the suite through scripts\Run-Tests-Guarded.ps1 until the result reports overall=ok. Do not weaken, skip, or delete tests to make it pass, and do not claim tests passed while this result stands.',
            # Pushing the repair and letting CI go green on that exact commit clears
            # this too, on a clean tree - which is the cheaper route when CI already
            # runs the suite. Stated because the alternative was an eleven-minute
            # duplicate local run that the sibling guard had already refused.
            'A green CI result for the exact commit HEAD is on also clears this, provided the tree is clean and the result is newer than the failure. Here: ' + $ci.Reason + '.',
            # The supersede matches the COMMAND, not the tree state, so the edit that
            # fixed the failure does not disqualify the green run proving it. The escape
            # hatch is for when a re-run cannot reproduce the identity at all.
            'Re-running the SAME command green supersedes this automatically, even though your fix changed the working tree. Only if the command itself had to change, or the old receipt carries no command identity, associate the newer clean receipt explicitly: powershell.exe -NoProfile -File "' + $HookPath + '" -ResolveIncident ' + $key + ' -RecoveryRunId "<verified recovery run id>" -ProjectRoot "' + $ProjectRoot + '" -Reason "<substantive equivalent test scope and verified repair, at least 80 UTF-8 bytes>".',
            'Note: the supersede matches the WHOLE argument vector, so a run covering three suites does not supersede a one-suite failure.')
    }
}
