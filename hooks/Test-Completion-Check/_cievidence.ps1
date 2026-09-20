# Does a green CI result for THIS commit supersede a local failure?
#
# Two hooks disagreed, and a reader could satisfy neither. Test-Run-Guard tells
# the agent not to run a suite this machine's CI already runs; Test-Completion-
# Check then refused to let the work finish until a clean run existed on this
# machine. In one measured task that cost two full local runs, 345s and 310s, in
# a task whose heavy pass had already gone green in CI on the pushed commit.
#
# This answers the missing question, and ONLY for a run that completed and
# FAILED. A run that was terminated, or that leaked a process, is a fact about
# THIS machine that no CI result speaks to, and keeps blocking.
#
# It reaches no network. Ci-Status-Check already queried the exact-SHA state and
# wrote down what it saw; this reads that note and checks it still describes the
# tree in front of us. The two hooks run concurrently and independently, so an
# absent note is not evidence of anything - it blocks, and the next Stop clears.

function Get-CiEvidencePath {
    param([string]$ProjectRoot, [string]$RepoSlug)
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    $key = Get-ShortHash ($ProjectRoot.ToLowerInvariant() + '|' + $RepoSlug.ToLowerInvariant())
    return (Join-Path $stateDir ('CiStatusCheck-' + $key + '.txt'))
}

# A named function, never a scriptblock reached through the call operator.
# Applying that operator to a variable is an execution path for data, shipped
# source here never does it, and a suite asserts on the source text itself -
# so even naming the pattern in a comment would fail that check.
function New-CiRefusal {
    param([AllowEmptyString()][string]$Why)
    return [pscustomobject]@{ Cleared = $false; Sha = ''; Reason = $Why }
}

function Test-CiClearedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowNull()][object]$FailureEndedUtc
    )

    if ($null -eq $FailureEndedUtc) { return (New-CiRefusal 'the failure records no end time') }
    $failureEnd = ([DateTime]$FailureEndedUtc).ToUniversalTime()

    $repo = Get-GitHubRepository -ProjectRoot $ProjectRoot
    if ($null -eq $repo -or [string]::IsNullOrWhiteSpace([string]$repo.Repository)) {
        return (New-CiRefusal 'this project has no resolvable GitHub remote')
    }

    $head = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) { return (New-CiRefusal 'HEAD cannot be resolved') }
    $head = $head.Trim()

    # A CI result describes COMMITTED code. An uncommitted edit is invisible to
    # it, so a dirty tree is not the tree the run passed on.
    $dirty = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($LASTEXITCODE -ne 0) { return (New-CiRefusal 'the working tree state cannot be read') }
    if ($dirty.Count -gt 0) { return (New-CiRefusal 'the working tree has uncommitted changes, which no CI result describes') }

    $path = Get-CiEvidencePath -ProjectRoot $ProjectRoot -RepoSlug ([string]$repo.Repository)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (New-CiRefusal 'no CI observation has been recorded for this project yet') }
    $lines = @()
    try { $lines = @([System.IO.File]::ReadAllLines($path)) } catch { return (New-CiRefusal 'the CI observation cannot be read') }

    # Three lines is the shape written before this feature existed. Treating it
    # as green would clear a failure on no evidence at all, so it fails closed -
    # which is also what a new consumer beside an old runtime must do.
    if ($lines.Count -lt 4) { return (New-CiRefusal 'the CI observation predates this check and says nothing about how it was verified') }
    if ($lines[3].Trim() -cne 'ci-green') { return (New-CiRefusal 'the recorded CI observation is not an observed all-success result') }
    if ($lines[1].Trim() -cne 'verified') { return (New-CiRefusal 'the recorded CI outcome is not verified') }
    if ($lines[0].Trim() -cne $head) { return (New-CiRefusal 'the CI observation is for a different commit than HEAD') }

    $observed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($lines[2].Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$observed)) {
        return (New-CiRefusal 'the CI observation carries no readable timestamp')
    }
    # Evidence must be NEWER than what it excuses, or a failure recorded after CI
    # went green would be waved through by a result that never saw it.
    if ($observed.ToUniversalTime() -le $failureEnd) { return (New-CiRefusal 'the CI observation predates the failure it would clear') }

    return [pscustomobject]@{ Cleared = $true; Sha = $head; Reason = 'CI is green for this exact commit' }
}
