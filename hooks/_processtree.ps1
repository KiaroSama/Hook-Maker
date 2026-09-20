# Terminating an owned process tree, with a bound and a verdict.
#
# This is the last thing standing between an abandoned run and a machine full of
# orphans, and it used to be the one step in the sequence with no time limit, no
# identity check and no result. It recursed once per level, issuing a fresh
# process query at every one, then called Stop-Process and returned nothing - so
# a caller that had just spent its entire budget handed control to something
# that could spend an unbounded amount more, and then could not tell whether it
# had worked. A real CI failure walked exactly this path.
#
# Three changes carry the whole repair:
#   ONE SNAPSHOT. A single bounded process query, then the tree is walked in
#   memory. Query latency is paid once instead of once per level, which is what
#   makes a total deadline achievable at all.
#   IDENTITY. Windows recycles process ids, and this runs after the run has
#   already gone wrong - exactly when a recorded id is most likely to have been
#   reused. A process that started BEFORE its recorded parent cannot be its
#   child, so it is not one of ours and is left alone.
#   A VERDICT. Issuing a termination request is not evidence of absence.
#   Survivors are confirmed by looking, and reported.
#
# Its own file because _hooklib.ps1 is far past the size ceiling and closed to
# new code, and because process lifetime is a responsibility of its own.

# Deep enough for any real runner tree, shallow enough to stay inside the
# deadline; the node cap bounds breadth the same way. Reaching either is
# reported as partial coverage, never as success.
$script:ProcessTreeMaxDepth = 8
$script:ProcessTreeMaxNodes = 512
$script:ProcessTreeDefaultCleanupMs = 5000

# One query, every process, bounded. Returns $null when it cannot be taken -
# which is a real outcome, not an error: cleanup then falls back to the one
# process it can identify directly rather than guessing at descendants.
function Get-ProcessSnapshot {
    param([int]$TimeoutSeconds = 3)
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate -OperationTimeoutSec $TimeoutSeconds -ErrorAction Stop)
    }
    catch { return $null }
}

# Descendants of $RootId that can actually BE its descendants. Breadth-first so
# the depth cap means what it says, with a visited set so a recycled id that
# makes the parent map cyclic cannot loop.
function Get-OwnedDescendantId {
    param([int]$RootId, [object]$RootCreated, [object[]]$Snapshot)
    $byParent = @{}
    $created = @{}
    foreach ($p in $Snapshot) {
        $pid1 = [int]$p.ProcessId
        $created[$pid1] = $p.CreationDate
        $parent = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = New-Object System.Collections.Generic.List[int] }
        [void]$byParent[$parent].Add($pid1)
    }
    $found = New-Object System.Collections.Generic.List[int]
    $seen = @{ $RootId = $true }
    $frontier = @($RootId)
    $truncated = $false
    for ($depth = 0; $depth -lt $script:ProcessTreeMaxDepth; $depth++) {
        $next = New-Object System.Collections.Generic.List[int]
        foreach ($parent in $frontier) {
            if (-not $byParent.ContainsKey($parent)) { continue }
            foreach ($childId in $byParent[$parent]) {
                if ($seen.ContainsKey($childId)) { continue }
                $seen[$childId] = $true
                # A child cannot predate its parent. When it does, the id was
                # recycled and this is a stranger wearing our number.
                if ($null -ne $RootCreated -and $null -ne $created[$childId]) {
                    if ([DateTime]$created[$childId] -lt [DateTime]$RootCreated) { continue }
                }
                if ($found.Count -ge $script:ProcessTreeMaxNodes) { $truncated = $true; break }
                [void]$found.Add($childId)
                [void]$next.Add($childId)
            }
            if ($truncated) { break }
        }
        if ($truncated -or $next.Count -eq 0) { break }
        if ($depth -eq ($script:ProcessTreeMaxDepth - 1) -and $next.Count -gt 0) { $truncated = $true }
        $frontier = $next.ToArray()
    }
    return [pscustomobject]@{ Ids = @($found.ToArray()); Truncated = $truncated }
}

function Test-ProcessGone {
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        try { return $p.HasExited } finally { $p.Dispose() }
    }
    catch { return $true }
}

# Terminate the tree rooted at $ProcessId and say what actually happened.
# Returns Cleared (every owned process confirmed gone), Survivors, Truncated
# (the walk hit a bound, so coverage is partial) and DeadlineHit.
function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMilliseconds = 0
    )
    if ($TimeoutMilliseconds -le 0) { $TimeoutMilliseconds = $script:ProcessTreeDefaultCleanupMs }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $self = $PID
    $truncated = $false

    $rootCreated = $null
    $snapshot = Get-ProcessSnapshot
    $targets = New-Object System.Collections.Generic.List[int]
    if ($null -ne $snapshot) {
        foreach ($p in $snapshot) { if ([int]$p.ProcessId -eq $ProcessId) { $rootCreated = $p.CreationDate; break } }
        $walk = Get-OwnedDescendantId -RootId $ProcessId -RootCreated $rootCreated -Snapshot $snapshot
        $truncated = $walk.Truncated
        foreach ($id in $walk.Ids) { [void]$targets.Add($id) }
    }
    else {
        # No snapshot is partial coverage, not a reason to guess. Never fall back
        # to matching by process name: it cannot tell ours from anyone else's.
        $truncated = $true
    }
    # Children before the root, so a parent cannot outlive the request and spawn
    # again into a gap.
    [void]$targets.Add($ProcessId)

    foreach ($id in $targets) {
        if ($id -eq $self) { continue }
        if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
    }

    # Confirm by looking. A termination request is not evidence of absence.
    $survivors = New-Object System.Collections.Generic.List[int]
    foreach ($id in $targets) {
        if ($id -eq $self) { continue }
        while (-not (Test-ProcessGone -ProcessId $id)) {
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-ProcessGone -ProcessId $id)) { [void]$survivors.Add($id) }
    }

    $deadlineHit = ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds)
    return [pscustomobject]@{
        Cleared     = ($survivors.Count -eq 0 -and -not $truncated)
        Survivors   = @($survivors.ToArray())
        Truncated   = $truncated
        DeadlineHit = $deadlineHit
        ElapsedMs   = [int]$timer.ElapsedMilliseconds
    }
}
