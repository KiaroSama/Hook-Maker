# Validated deletion of an OWNED package generation.
#
# Why this exists: the previous helper deleted whatever directory path it was
# handed, recursively, with no ownership check at all. Two of its three callers
# pass `state.pending.packageRoot` - a path read back out of a JSON file on
# disk. A corrupted, hand-edited or forged state record therefore selected the
# directory to destroy, and nothing stopped it pointing outside the inbox.
#
# The rule here is ownership, not string shape: a deletion is permitted only
# when the target is physically contained in a root this route actually owns,
# and only when no reparse point on the path from that root down to the target
# could redirect the walk somewhere else. A refusal returns $false rather than
# throwing, because failing to delete disposable staging is always preferable
# to deleting something that was never ours - and the caller reports it.

function Remove-OwnedPackageDirectory {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$OwnedRoot,
        # The inbox root itself is a legitimate target when a route rebuilds its
        # whole staging area; a package generation underneath it never is.
        [switch]$AllowRootItself
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($OwnedRoot)) { return $false }

    try {
        $target = Normalize-Path $Path
        $root = Normalize-Path $OwnedRoot
    }
    catch { return $false }

    $isRootItself = [string]::Equals($target, $root, [System.StringComparison]::OrdinalIgnoreCase)
    if ($isRootItself) {
        if (-not $AllowRootItself) { return $false }
    }
    elseif (-not (Test-PathInside -Candidate $target -Parent $root)) {
        # Outside the owned root entirely: a forged or stale record.
        return $false
    }

    # Absent is success: the generation this caller wanted gone is gone.
    try { if (-not (Test-Path -LiteralPath $target -PathType Container)) { return $true } }
    catch { return $false }

    # A reparse point anywhere between the owned root and the target can make a
    # contained-looking path resolve elsewhere, so the containment check above
    # is only meaningful once the whole chain is proven free of them.
    try {
        for ($ancestor = $target; $ancestor -ne $root; $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)) {
            if ([string]::IsNullOrEmpty($ancestor)) { return $false }
            if (([System.IO.File]::GetAttributes($ancestor) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        if (([System.IO.File]::GetAttributes($root) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    catch { return $false }

    try {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        return $true
    }
    catch {
        # Report the refusal rather than pretending the generation was retired;
        # a caller that believes stale staging is gone will trust it next run.
        return $false
    }
}
