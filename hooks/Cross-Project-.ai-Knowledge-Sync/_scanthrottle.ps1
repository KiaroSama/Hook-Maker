# Route rescan throttle and run budget for the sync engine (spec 037 FR-037-10).
#
# WHY: every UserPromptSubmit walked every route's source .ai recursively. One
# source holding 1.8M files made a single prompt event cost 1234-1413 s against
# a 60 s registration, so the client reported "A hook didn't answer in time" on
# every prompt. Changes in another project's notes do not need per-prompt
# freshness: SessionStart always rescans, and a prompt rescans a route only when
# its last completed walk is older than rescanMinutes.
#
# The stamp sits beside the route state file (<key>.scan) and is written only
# after a walk finished, so an interrupted walk is retried on the next event.

function Get-ScanStampPath {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    return [IO.Path]::ChangeExtension($StatePath, '.scan')
}

# $true when this event may skip the route's walk: only UserPromptSubmit, and
# only while the last completed walk is younger than the interval. 0 disables.
function Test-RouteScanFresh {
    param([Parameter(Mandatory = $true)][string]$StatePath, [string]$EventName, [int]$RescanMinutes = 10)
    if ($EventName -ne 'UserPromptSubmit' -or $RescanMinutes -le 0) { return $false }
    try {
        $stamp = Get-ScanStampPath -StatePath $StatePath
        if (-not [IO.File]::Exists($stamp)) { return $false }
        return ([IO.File]::GetLastWriteTimeUtc($stamp) -gt [DateTime]::UtcNow.AddMinutes(-$RescanMinutes))
    }
    catch { return $false }
}

function Set-RouteScanStamp {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    try {
        $stamp = Get-ScanStampPath -StatePath $StatePath
        $parent = Split-Path -Parent $stamp
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::WriteAllText($stamp, '')
        [IO.File]::SetLastWriteTimeUtc($stamp, [DateTime]::UtcNow)
    }
    catch { }    # a missing stamp only means the next prompt walks again
}

# Integer setting from route -> profile -> defaults; a bad value keeps the default.
function Get-ScanSetting {
    param($Context, [Parameter(Mandatory = $true)][string]$Name, [int]$Default)
    $raw = Get-PropertyValue -Primary $Context.route -Secondary $Context.profile -Tertiary $Context.defaults -Name $Name -Fallback $Default
    $parsed = 0
    if ([int]::TryParse([string]$raw, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    return $Default
}
