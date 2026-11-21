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

$ciProofRoot = if ([IO.File]::Exists((Join-Path $PSScriptRoot '_ciprovenance.ps1'))) { $PSScriptRoot } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $ciProofRoot '_ciprovenance.ps1')

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

    if ($null -eq $FailureEndedUtc) { return (New-CiRefusal 'no failure end time') }
    $failureEnd = ([DateTime]$FailureEndedUtc).ToUniversalTime()

    $repo = Get-GitHubRepository -ProjectRoot $ProjectRoot
    if ($null -eq $repo -or [string]::IsNullOrWhiteSpace([string]$repo.Repository)) {
        return (New-CiRefusal 'no GitHub remote')
    }

    $head = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) { return (New-CiRefusal 'HEAD unknown') }
    $head = $head.Trim()

    # A CI result describes COMMITTED code. An uncommitted edit is invisible to
    # it, so a dirty tree is not the tree the run passed on.
    $dirty = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($LASTEXITCODE -ne 0) { return (New-CiRefusal 'working tree unreadable') }
    if ($dirty.Count -gt 0) { return (New-CiRefusal 'dirty tree: CI cannot verify') }

    $path = Get-CiEvidencePath -ProjectRoot $ProjectRoot -RepoSlug ([string]$repo.Repository)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (New-CiRefusal 'no CI observation') }
    $lines = @()
    try { $lines = @([System.IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) } catch { return (New-CiRefusal 'CI observation unreadable') }

    $proof = Read-CiProvenance -Lines $lines -Repository ([string]$repo.Repository) -Sha $head -FailureEndedUtc $failureEnd
    if ($null -eq $proof) { return (New-CiRefusal 'CI provenance missing/stale/mismatched or predates failure') }

    return [pscustomobject]@{ Cleared = $true; Sha = $head; Reason = 'CI green for commit' }
}
