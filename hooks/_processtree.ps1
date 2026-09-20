# Bounded cleanup of an identified process tree. A PID is not an identity.
# Retain creation times through enumeration, termination and verification.
$script:ProcessTreeMaxDepth = 8
$script:ProcessTreeMaxNodes = 512
$script:ProcessTreeDefaultCleanupMs = 5000

function Get-ProcessSnapshot {
    param([int]$TimeoutSeconds = 3)
    try { return @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, CreationDate -OperationTimeoutSec $TimeoutSeconds -ErrorAction Stop) }
    catch { return $null }
}

function ConvertTo-ProcessCreatedUtc {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    try {
        $valueUtc = ([DateTime]$Value).ToUniversalTime()
        if ($valueUtc -eq [DateTime]::MinValue -or $valueUtc -eq [DateTime]::MaxValue) { return $null }
        return $valueUtc
    }
    catch { return $null }
}

function Test-ProcessCreationMatch {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected)
    $a = ConvertTo-ProcessCreatedUtc $Actual; $b = ConvertTo-ProcessCreatedUtc $Expected
    # CIM serializes creation time to microseconds; process handles use ticks.
    return ($null -ne $a -and $null -ne $b -and [Math]::Abs(($a - $b).Ticks) -lt 10)
}

function Get-OwnedDescendantId {
    param([int]$RootId, [object]$RootCreated, [object[]]$Snapshot)
    $byParent = @{}; $created = @{}; $truncated = $false
    $rootTime = ConvertTo-ProcessCreatedUtc $RootCreated
    foreach ($p in $Snapshot) {
        try { $id = [int]$p.ProcessId; $parent = [int]$p.ParentProcessId }
        catch { $truncated = $true; continue }
        if ($created.ContainsKey($id)) { $truncated = $true; continue }
        $created[$id] = ConvertTo-ProcessCreatedUtc $p.CreationDate
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = New-Object 'System.Collections.Generic.List[int]' }
        [void]$byParent[$parent].Add($id)
    }
    $found = New-Object 'System.Collections.Generic.List[int]'
    $identities = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{ $RootId = $true }; $frontier = @($RootId)
    if ($null -eq $rootTime) {
        return [pscustomobject]@{ Ids = @(); Identities = @(); Truncated = $true }
    }
    # A retained caller handle can identify an exited root no longer in CIM.
    # A DIFFERENT live root under that id cannot authorize its descendants.
    if ($created.ContainsKey($RootId) -and -not (Test-ProcessCreationMatch $created[$RootId] $rootTime)) {
        return [pscustomobject]@{ Ids = @(); Identities = @(); Truncated = $true }
    }
    $created[$RootId] = $rootTime
    for ($depth = 0; $depth -lt $script:ProcessTreeMaxDepth; $depth++) {
        $next = New-Object 'System.Collections.Generic.List[int]'
        foreach ($parent in $frontier) {
            if (-not $byParent.ContainsKey($parent)) { continue }
            foreach ($childId in $byParent[$parent]) {
                if ($seen.ContainsKey($childId)) { continue }
                $seen[$childId] = $true
                $parentTime = $created[$parent]; $childTime = $created[$childId]
                if ($null -eq $parentTime -or $null -eq $childTime) { $truncated = $true; continue }
                # Compare every edge with its DIRECT parent, not the root.
                if ($childTime -lt $parentTime) { continue }
                if ($found.Count -ge $script:ProcessTreeMaxNodes) { $truncated = $true; break }
                [void]$found.Add($childId)
                [void]$identities.Add([pscustomobject]@{ Id = $childId; Created = $childTime })
                [void]$next.Add($childId)
            }
            if ($truncated -and $found.Count -ge $script:ProcessTreeMaxNodes) { break }
        }
        if ($next.Count -eq 0) { break }
        if ($depth -eq ($script:ProcessTreeMaxDepth - 1)) {
            foreach ($id in $next) {
                if ($byParent.ContainsKey($id)) {
                    foreach ($child in $byParent[$id]) { if (-not $seen.ContainsKey($child)) { $truncated = $true } }
                }
            }
        }
        $frontier = $next.ToArray()
    }
    return [pscustomobject]@{ Ids = @($found.ToArray()); Identities = @($identities.ToArray()); Truncated = $truncated }
}

function Test-ProcessGone {
    param([int]$ProcessId, [AllowNull()][object]$ExpectedCreated = $null)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        try {
            if ($p.HasExited) { return $true }
            if ($null -ne $ExpectedCreated -and -not (Test-ProcessCreationMatch $p.StartTime $ExpectedCreated)) { return $true }
            return $false
        }
        finally { $p.Dispose() }
    }
    catch {
        # Access denied, a provider failure or unreadable identity is UNKNOWN,
        # never evidence of absence. Only the documented no-such-PID error is gone.
        return ($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*' -and
            $_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound)
    }
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMilliseconds = 0,
        [AllowNull()][object]$RootCreated = $null
    )
    if ($TimeoutMilliseconds -le 0) { $TimeoutMilliseconds = $script:ProcessTreeDefaultCleanupMs }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) {
        # Protect the whole self-rooted tree, not merely the caller's own PID.
        return [pscustomobject]@{ Cleared = $false; Survivors = @($ProcessId); Truncated = $true; DeadlineHit = $false; ElapsedMs = 0; Reason = 'protected-root' }
    }
    $ownedRoot = $null; $rootTime = ConvertTo-ProcessCreatedUtc $RootCreated
    $targets = New-Object 'System.Collections.Generic.List[object]'
    $truncated = $false
    try {
        # Pin the root before enumeration; callers of an already exited child
        # supply the creation time recorded while their retained handle was live.
        if ($null -eq $rootTime) {
            try {
                $ownedRoot = Get-Process -Id $ProcessId -ErrorAction Stop
                $null = $ownedRoot.Handle
                $rootTime = ConvertTo-ProcessCreatedUtc $ownedRoot.StartTime
            }
            catch { $truncated = $true }
        }
        $remaining = $TimeoutMilliseconds - $timer.ElapsedMilliseconds
        $snapshot = $null
        if ($remaining -ge 1000 -and $null -ne $rootTime) {
            $querySeconds = [int][Math]::Min(3, [Math]::Floor($remaining / 1000))
            $snapshot = Get-ProcessSnapshot -TimeoutSeconds $querySeconds
        }
        if ($null -eq $snapshot) { $truncated = $true }
        else {
            $walk = Get-OwnedDescendantId -RootId $ProcessId -RootCreated $rootTime -Snapshot $snapshot
            $truncated = $truncated -or $walk.Truncated
            # Reverse breadth-first order visits grandchildren before parents.
            for ($i = $walk.Identities.Count - 1; $i -ge 0; $i--) { [void]$targets.Add($walk.Identities[$i]) }
        }
        [void]$targets.Add([pscustomobject]@{ Id = $ProcessId; Created = $rootTime })
        foreach ($target in $targets) {
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
            if ($target.Id -eq $PID -or $null -eq $target.Created) { $truncated = $true; continue }
            $live = $null
            try {
                $live = Get-Process -Id $target.Id -ErrorAction Stop
                # Opening the handle BEFORE identity validation binds Kill to
                # the same OS object instead of looking up a recycled id again.
                $null = $live.Handle
                if (-not $live.HasExited -and (Test-ProcessCreationMatch $live.StartTime $target.Created)) { $live.Kill() }
            }
            catch {
                if (-not (Test-ProcessGone -ProcessId $target.Id -ExpectedCreated $target.Created)) { $truncated = $true }
            }
            finally { if ($null -ne $live) { $live.Dispose() } }
        }
        $survivors = New-Object 'System.Collections.Generic.List[int]'
        foreach ($target in $targets) {
            $gone = Test-ProcessGone -ProcessId $target.Id -ExpectedCreated $target.Created
            while (-not $gone -and $timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                Start-Sleep -Milliseconds ([int][Math]::Min(50, [Math]::Max(1, $TimeoutMilliseconds - $timer.ElapsedMilliseconds)))
                $gone = Test-ProcessGone -ProcessId $target.Id -ExpectedCreated $target.Created
            }
            if (-not $gone) { [void]$survivors.Add($target.Id) }
        }
        $deadlineHit = $timer.ElapsedMilliseconds -ge $TimeoutMilliseconds
        return [pscustomobject]@{
            Cleared = ($survivors.Count -eq 0 -and -not $truncated -and -not $deadlineHit)
            Survivors = @($survivors.ToArray()); Truncated = $truncated; DeadlineHit = $deadlineHit
            ElapsedMs = [int]$timer.ElapsedMilliseconds
        }
    }
    finally { if ($null -ne $ownedRoot) { $ownedRoot.Dispose() } }
}
