# Building ONE review package generation.
#
# Extracted from the hook body at the 800-line ceiling: the entry script routes
# events and owns state, while the shape of a package - what changed, what is
# staged, what the manifest says and what proves it - is its own
# responsibility, and it is the half that grew. Ownership, containment,
# verification and retirement stay in _packageguard.ps1, which this file calls.
#
# Dot-sourced by Cross-Project-.ai-Knowledge-Sync.ps1 into its scope (uses its
# helpers: Convert-FileRecordsToMap, Get-AcknowledgementCommand,
# Write-JsonFileAtomic, Get-Field) - not a standalone script.

function New-PendingPackage {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$StatePaths,
        [Parameter(Mandatory = $true)][string]$QuickFingerprint,
        [Parameter(Mandatory = $true)]$ContentSnapshot
    )

    $previousMap = Convert-FileRecordsToMap $State.lastAppliedFiles
    $currentMap = Convert-FileRecordsToMap $ContentSnapshot.files
    $added = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $deleted = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($currentMap.Keys | Sort-Object)) {
        if (-not $previousMap.ContainsKey($path)) {
            [void]$added.Add($path)
        }
        elseif (-not [string]::Equals([string]$previousMap[$path].sha256, [string]$currentMap[$path].sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$modified.Add($path)
        }
    }
    foreach ($path in @($previousMap.Keys | Sort-Object)) {
        if (-not $currentMap.ContainsKey($path)) {
            [void]$deleted.Add($path)
        }
    }
    $added = $added.ToArray()
    $modified = $modified.ToArray()
    $deleted = $deleted.ToArray()

    # STAGE A NEW GENERATION, NEVER DEMOLISH THE OLD ONE FIRST. This used to
    # delete the whole inbox before the first byte of the replacement was
    # copied: a copy that then failed left the state record pointing at files
    # that no longer existed, and the route announced that dead path on every
    # event afterwards. It also destroyed a generation a reviewer might still be
    # working through, which is why an ACK could arrive for a package that no
    # longer existed - the source had merely changed in the meantime.
    #
    # The generation is named for its own content fingerprint, so a new one
    # never collides with the one under review. The old generations are retired
    # only AFTER this one is built and verified.
    $packageRoot = Join-Path $StatePaths.inboxRoot ([string]$ContentSnapshot.fingerprint).Substring(0, 16)
    $filesRoot = Join-Path $packageRoot 'files'
    if (-not (Test-OwnedStagingChain -TrustedRoot $Context.destinationRoot -OwnedRoot $StatePaths.inboxRoot -Target $packageRoot)) {
        # The staging path is not provably inside the configured destination -
        # a link somewhere on the chain, or a root that moved. Refuse to write.
        return $null
    }
    # A half-built generation from an interrupted earlier run is the one thing
    # that may be removed here, and only because it carries THIS fingerprint and
    # has just been proven to be ours.
    if (Test-Path -LiteralPath $packageRoot -PathType Container) {
        if (-not (Remove-OwnedPackageDirectory -Path $packageRoot -OwnedRoot $StatePaths.inboxRoot -TrustedRoot $Context.destinationRoot)) { return $null }
    }
    New-Item -ItemType Directory -Path $filesRoot -Force | Out-Null

    foreach ($relativePath in ($added + $modified)) {
        $sourcePath = Join-Path $Context.sourceDirectory ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $destinationPath = Join-Path $filesRoot ($relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    $ackCommand = Get-AcknowledgementCommand -Context $Context -Fingerprint $ContentSnapshot.fingerprint

    $manifest = [pscustomobject][ordered]@{
        version = 2
        profileId = $Context.profileId
        profileName = if ($null -ne $Context.profile.PSObject.Properties['name']) { [string]$Context.profile.name } else { $Context.profileId }
        routeId = $Context.routeId
        sourceName = if ($null -ne $Context.route.source.PSObject.Properties['name']) { [string]$Context.route.source.name } else { $Context.sourceRoot }
        sourceRoot = $Context.sourceRoot
        sourceDirectory = $Context.sourceDirectory
        destinationName = if ($null -ne $Context.route.destination.PSObject.Properties['name']) { [string]$Context.route.destination.name } else { $Context.destinationRoot }
        destinationRoot = $Context.destinationRoot
        destinationDirectory = $Context.destinationDirectory
        detectedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceQuickFingerprint = $QuickFingerprint
        sourceContentFingerprint = $ContentSnapshot.fingerprint
        added = $added
        modified = $modified
        deleted = $deleted
        acknowledgementCommand = $ackCommand
    }
    # PROVE THE BYTES BEFORE ANNOUNCING THEM. The reviewer reads the staged copy
    # and nothing else, so a truncated or concurrently-modified file would be
    # reviewed as if it were the source. Verified against the same snapshot the
    # manifest describes; a mismatch abandons this generation and leaves the
    # previous one - and its state record - untouched.
    $stagedRecords = @(@($ContentSnapshot.files) | Where-Object {
            $relative = [string](Get-Field $_ 'path')
            (@($added) -contains $relative) -or (@($modified) -contains $relative)
        })
    if (-not (Test-StagedFilesVerified -FilesRoot $filesRoot -Records $stagedRecords)) {
        [void](Remove-OwnedPackageDirectory -Path $packageRoot -OwnedRoot $StatePaths.inboxRoot -TrustedRoot $Context.destinationRoot)
        return $null
    }

    $manifestPath = Join-Path $packageRoot 'manifest.json'
    Write-JsonFileAtomic -Value $manifest -Path $manifestPath

    # Only now is the previous generation disposable. A refusal is carried out
    # to the caller as DEFERRED CLEANUP rather than swallowed: staging that
    # could not be retired is a different outcome from a review that failed.
    $deferredCleanup = @(Remove-SupersededGenerations -InboxRoot $StatePaths.inboxRoot -TrustedRoot $Context.destinationRoot -KeepPackageRoot $packageRoot)

    return [pscustomobject][ordered]@{
        sourceQuickFingerprint = $QuickFingerprint
        sourceContentFingerprint = $ContentSnapshot.fingerprint
        sourceFiles = @($ContentSnapshot.files)
        packageRoot = $packageRoot
        manifestPath = $manifestPath
        filesRoot = $filesRoot
        acknowledgementCommand = $ackCommand
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        deferredCleanup = @($deferredCleanup)
    }
}
