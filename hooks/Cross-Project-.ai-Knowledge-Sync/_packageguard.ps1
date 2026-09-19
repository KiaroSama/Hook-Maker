# OWNED PACKAGE GENERATIONS: containment, verified staging, and retirement.
#
# Why this exists: the previous helper deleted whatever directory path it was
# handed, recursively, with no ownership check at all. Two of its three callers
# pass `state.pending.packageRoot` - a path read back out of a JSON file on
# disk. A corrupted, hand-edited or forged state record therefore selected the
# directory to destroy, and nothing stopped it pointing outside the inbox.
#
# The rule here is ownership, not string shape: a deletion is permitted only
# when the target is physically contained in a root this route actually owns,
# that root is itself contained in the TRUSTED CONFIGURED DESTINATION, and no
# reparse point anywhere on the chain from the trusted root down to the target
# could redirect the walk somewhere else. Checking only target-to-inbox was not
# enough: a junction on `inbox` itself - or on `.ai`, or on `.cross-project-sync`
# - redirects every write and every delete out of the project while each
# individual path still looks contained.
#
# A refusal returns $false rather than throwing, because failing to delete
# disposable staging is always preferable to deleting something that was never
# ours - and every caller now reports it instead of discarding it.

# The chain from the trusted root down to the target, ending AT the trusted
# root. Returns $null when the target is not under the trusted root at all.
function Get-OwnedPathChain {
    param(
        [Parameter(Mandatory = $true)][string]$TrustedRoot,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $chain = New-Object System.Collections.Generic.List[string]
    $cursor = $Target
    for ($hop = 0; $hop -lt 64; $hop++) {
        [void]$chain.Add($cursor)
        if ([string]::Equals($cursor, $TrustedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $chain }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or [string]::Equals($parent, $cursor, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        $cursor = $parent
    }
    return $null
}

# $true only when every existing segment between the trusted root and the target
# is a real directory rather than a reparse point. A segment that does not exist
# yet is skipped: a generation about to be created cannot be redirected by a
# link that is not there, and its parents are checked on the same walk.
function Test-OwnedStagingChain {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TrustedRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$OwnedRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target,
        [switch]$AllowRootItself
    )
    if ([string]::IsNullOrWhiteSpace($TrustedRoot) -or [string]::IsNullOrWhiteSpace($OwnedRoot) -or [string]::IsNullOrWhiteSpace($Target)) { return $false }
    try {
        $trusted = Normalize-Path $TrustedRoot
        $owned = Normalize-Path $OwnedRoot
        $target = Normalize-Path $Target
    }
    catch { return $false }

    $ownedIsTrusted = [string]::Equals($owned, $trusted, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $ownedIsTrusted -and -not (Test-PathInside -Candidate $owned -Parent $trusted)) { return $false }

    if ([string]::Equals($target, $owned, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not $AllowRootItself) { return $false }
    }
    elseif (-not (Test-PathInside -Candidate $target -Parent $owned)) { return $false }

    $chain = Get-OwnedPathChain -TrustedRoot $trusted -Target $target
    if ($null -eq $chain) { return $false }
    foreach ($segment in $chain) {
        try {
            $attributes = [System.IO.File]::GetAttributes($segment)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { return $false }
        }
        catch [System.IO.FileNotFoundException] { continue }
        catch [System.IO.DirectoryNotFoundException] { continue }
        catch { return $false }  # Unreadable is not equivalent to absent.
    }
    return $true
}

function Remove-OwnedPackageDirectory {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$OwnedRoot,
        # The trusted configured destination. Optional only so a runtime copied
        # before this parameter existed keeps working; when it is absent the
        # owned root is trusted as its own ancestor, which is the older, weaker
        # rule this parameter exists to replace.
        [AllowEmptyString()][string]$TrustedRoot = '',
        # The inbox root itself is a legitimate target when a route rebuilds its
        # whole staging area; a package generation underneath it never is.
        [switch]$AllowRootItself
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($OwnedRoot)) { return $false }
    $trusted = $TrustedRoot
    if ([string]::IsNullOrWhiteSpace($trusted)) { $trusted = $OwnedRoot }

    if (-not (Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $OwnedRoot -Target $Path -AllowRootItself:$AllowRootItself)) { return $false }

    try {
        $target = Normalize-Path $Path
        # Absent is success: the generation this caller wanted gone is gone.
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { return $true }
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        return $true
    }
    catch {
        # Report the refusal rather than pretending the generation was retired;
        # a caller that believes stale staging is gone will trust it next run.
        return $false
    }
}

# The staged bytes, proven against the snapshot that described them. Copy-Item
# reports success for a file that was truncated or replaced underneath it, and
# the package is the only thing the reviewer ever reads - so the hash is taken
# from what actually landed, not from what was asked for.
function Test-StagedFilesVerified {
    param([Parameter(Mandatory = $true)][string]$FilesRoot, [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Records)
    try {
        $root = Normalize-Path $FilesRoot
        if (-not [IO.Directory]::Exists($root)) { return $false }
        $seen = @{}; $totalBytes = 0L
        foreach ($record in @($Records)) {
            $relative = [string](Get-Field $record 'path')
            $expected = [string](Get-Field $record 'sha256')
            if (-not (Test-PackageRelativePath $relative) -or $expected -notmatch '^[a-fA-F0-9]{64}$' -or $seen.ContainsKey($relative)) { return $false }
            $seen[$relative] = $true
            $staged = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not (Test-PathInside -Candidate $staged -Parent $root)) { return $false }
            $parent = [IO.Path]::GetDirectoryName($staged)
            if (-not (Test-OwnedStagingChain -TrustedRoot $root -OwnedRoot $root -Target $parent -AllowRootItself)) { return $false }
            $attributes = [IO.File]::GetAttributes($staged)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [IO.FileAttributes]::Directory) -ne 0) { return $false }
            $totalBytes += (Get-Item -LiteralPath $staged -ErrorAction Stop).Length
            if ($totalBytes -gt 536870912 -or $seen.Count -gt 10000) { return $false }
            if ((Get-PackageFileDigest $staged) -ine $expected) { return $false }
        }
        # A reviewed generation has an exact file set; a newly injected file is
        # not part of the reviewed snapshot even when every expected file exists.
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($root); $count = 0; $visited = 0
        while ($stack.Count -gt 0) {
            foreach ($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)) {
                if (++$visited -gt 20000 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if ($item.PSIsContainer) { $stack.Push($item.FullName); continue }
                $relative = $item.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
                if (-not $seen.ContainsKey($relative)) { return $false }
                $count++
            }
        }
        return ($count -eq $seen.Count)
    }
    catch { return $false }
}

# Is the generation a reviewer was pointed at still the one they reviewed?
# An ACK arrives long after the announcement, and between the two the package
# can be deleted by a cleaner, half-rebuilt by an interrupted run, or edited.
# The fingerprint in the state record proves only what was INTENDED; this proves
# what is on disk.
function Test-PackageGenerationIntact {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PackageRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Fingerprint,
        [string]$ExpectedManifestSha256 = '', [AllowEmptyCollection()]$Records = @(),
        [string]$TrustedRoot = '', [string]$OwnedRoot = ''
    )
    # A legacy manifest's self-declared fingerprint is not evidence. Legacy
    # pending generations are rebuilt by the normal event path, never ACKed blind.
    if ($ExpectedManifestSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Fingerprint -notmatch '^[a-fA-F0-9]{64}$') { return $false }
    if (-not (Test-OwnedStagingChain -TrustedRoot $TrustedRoot -OwnedRoot $OwnedRoot -Target $PackageRoot)) { return $false }
    try {
        $manifestPath = Join-Path $PackageRoot 'manifest.json'
        $attributes = [IO.File]::GetAttributes($manifestPath)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [IO.FileAttributes]::Directory) -ne 0) { return $false }
        if ((Get-Item -LiteralPath $manifestPath -ErrorAction Stop).Length -gt 4194304) { return $false }
        if ((Get-PackageFileDigest $manifestPath) -ine $ExpectedManifestSha256) { return $false }
        $manifest = Read-JsonFile $manifestPath
        if ([string](Get-Field $manifest 'version') -ne '3' -or [string](Get-Field $manifest 'sourceContentFingerprint') -ine $Fingerprint) { return $false }
        return (Test-StagedFilesVerified -FilesRoot (Join-Path $PackageRoot 'files') -Records $Records)
    }
    catch { return $false }
}

function Test-PendingPackageIntact {
    param($Pending, $Context, $StatePaths)
    if ($null -eq $Pending) { return $false }
    $root = [string](Get-Field $Pending 'packageRoot')
    try {
        if ((Normalize-Path ([string](Get-Field $Pending 'manifestPath'))) -ine (Normalize-Path (Join-Path $root 'manifest.json'))) { return $false }
        if ((Normalize-Path ([string](Get-Field $Pending 'filesRoot'))) -ine (Normalize-Path (Join-Path $root 'files'))) { return $false }
    }
    catch { return $false }
    $records = Get-Field $Pending 'stagedFiles'
    if ($null -eq $Pending.PSObject.Properties['stagedFiles'] -or $records -isnot [System.Array]) { return $false }
    return (Test-PackageGenerationIntact -PackageRoot $root -Fingerprint ([string](Get-Field $Pending 'sourceContentFingerprint')) `
        -ExpectedManifestSha256 ([string](Get-Field $Pending 'manifestSha256')) -Records $records `
        -TrustedRoot $Context.destinationRoot -OwnedRoot $StatePaths.inboxRoot)
}

function Test-PackageRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path -match '[:\\]') { return $false }
    foreach ($part in $Path.Split('/')) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    }
    return $true
}

function Get-PackageFileDigest {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

# Retire every generation under the inbox EXCEPT the one just published. Each
# refusal is returned rather than swallowed, so a caller can report that cleanup
# was deferred - which is a different outcome from a failed review, and the two
# used to be indistinguishable.
function Remove-SupersededGenerations {
    param(
        [Parameter(Mandatory = $true)][string]$InboxRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TrustedRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$KeepPackageRoot
    )
    $deferred = New-Object System.Collections.Generic.List[string]
    $keep = ''
    if (-not [string]::IsNullOrWhiteSpace($KeepPackageRoot)) {
        try { $keep = Normalize-Path $KeepPackageRoot } catch { $keep = '' }
    }
    $children = @()
    try { $children = @(Get-ChildItem -LiteralPath $InboxRoot -Directory -Force -ErrorAction SilentlyContinue) }
    catch { return @() }
    foreach ($child in $children) {
        $full = ''
        try { $full = Normalize-Path $child.FullName } catch { continue }
        if ($keep -ne '' -and [string]::Equals($full, $keep, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Remove-OwnedPackageDirectory -Path $full -OwnedRoot $InboxRoot -TrustedRoot $TrustedRoot)) {
            [void]$deferred.Add($child.Name)
        }
    }
    return @($deferred.ToArray())
}
