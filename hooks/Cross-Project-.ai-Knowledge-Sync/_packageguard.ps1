# Owned package generations: trusted containment, verified bytes and retirement.
# Persisted paths and a manifest's self-declared fingerprint are not proof of
# ownership or reviewed content. Refusals preserve data and reach the caller.
#
# CONTAINMENT RUNS FROM THE TRUSTED CONFIGURED DESTINATION DOWN, never from the
# inbox. The check used to compare a target against the inbox, and a junction on
# an INTERNAL staging ancestor redirected every write and delete out of the
# project while each path still read as contained. Every ancestor between the
# trusted root and the target is inspected, and a reparse point anywhere on that
# chain is a refusal - including on the files root itself, which an empty record
# set would otherwise never cause anyone to look at.
#
# A FILE ANCESTOR IS NOT A MISSING DIRECTORY. Attribute failures were treated
# like nonexistent paths, so a file where a directory belonged read as "nothing
# there" instead of as the malformed tree it is. Absent, unreadable and
# wrong-kind are now three different answers.
#
# THE ACK IS BOUND TO THE BYTES ON DISK. Comparing the fingerprint inside
# manifest.json against the expected fingerprint proves only that the manifest
# agrees with itself: tampered, deleted or injected files were acknowledged.
# The staged file set, each file's digest and its containment are all verified
# against the snapshot that described them.

function Get-OwnedPathChain {
    param([Parameter(Mandatory = $true)][string]$TrustedRoot, [Parameter(Mandatory = $true)][string]$Target)
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
        [AllowEmptyString()][string]$TrustedRoot = '',
        [switch]$AllowRootItself
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($OwnedRoot)) { return $false }
    $trusted = $TrustedRoot
    # Legacy direct callers retain their old boundary; current engine mutations
    # explicitly supply the configured destination as their trusted boundary.
    if ([string]::IsNullOrWhiteSpace($trusted)) { $trusted = $OwnedRoot }
    if (-not (Test-OwnedStagingChain -TrustedRoot $trusted -OwnedRoot $OwnedRoot -Target $Path -AllowRootItself:$AllowRootItself)) { return $false }
    try {
        $target = Normalize-Path $Path
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { return $true }
        # Windows PowerShell providers differ on recursive link removal.
        # Refuse a redirected descendant before any deletion; never traverse it.
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($target); $visited = 0
        while ($pending.Count -gt 0) {
            foreach ($child in (New-Object IO.DirectoryInfo($pending.Pop())).EnumerateFileSystemInfos()) {
                if (++$visited -gt 20000 -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if (($child.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($child.FullName) }
            }
        }
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# Verify the bytes and exact file set, including empty/deletion-only packages.
function Test-StagedFilesVerified {
    param([Parameter(Mandatory = $true)][string]$FilesRoot, [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Records)
    try {
        $root = Normalize-Path $FilesRoot
        if (-not [IO.Directory]::Exists($root) -or ([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
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

function Test-PackageGenerationIntact {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PackageRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Fingerprint,
        [string]$ExpectedManifestSha256 = '', [AllowEmptyCollection()]$Records = @(),
        [string]$TrustedRoot = '', [string]$OwnedRoot = ''
    )
    # Legacy state lacking proof is rebuilt by normal delivery, never ACKed blind.
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
    # Pipeline output unwraps collections. Read the property value directly so
    # a one-file package and an empty package keep their JSON array provenance.
    $property = $Pending.PSObject.Properties['stagedFiles']
    if ($null -eq $property -or $property.Value -isnot [System.Array]) { return $false }
    $records = $property.Value
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
        if (-not (Remove-OwnedPackageDirectory -Path $full -OwnedRoot $InboxRoot -TrustedRoot $TrustedRoot)) { [void]$deferred.Add($child.Name) }
    }
    return @($deferred.ToArray())
}