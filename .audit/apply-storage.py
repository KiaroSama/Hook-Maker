from pathlib import Path
import re

root = Path('.')
def read(path):
    return (root / path).read_text(encoding='utf-8-sig')
def write(path, text):
    (root / path).write_text(text, encoding='utf-8', newline='\r\n')
def replace_function(text, name, replacement):
    start = re.search(r'(?m)^function ' + re.escape(name) + r' \{', text)
    assert start, name
    end = re.search(r'(?m)^\}', text[start.end():])
    assert end, name
    return text[:start.start()] + replacement.rstrip() + text[start.end() + end.end():]

path = 'scripts/_installregistrygeneration.ps1'
s = read(path)
s = s.replace("$script:InstallRegistryWritingMarkerName = '_writing.json'", "$script:InstallRegistryWritingMarkerName = '_writing.json'\n. (Join-Path $PSScriptRoot '_installregistryjournal.ps1')")
s = replace_function(s, 'Get-InstallRegistryMarkerPath', '''function Get-InstallRegistryMarkerPath {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Get-RegistryJournalPath $ToolRoot)
}''')
s = replace_function(s, 'Start-InstallRegistryGeneration', '''function Start-InstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [string[]]$ExpectedFileNames = @(), [object[]]$ExpectedRecords = @())
    return (Start-RegistryJournal -ToolRoot $ToolRoot -ExpectedFileNames $ExpectedFileNames -ExpectedRecords $ExpectedRecords)
}''')
s = replace_function(s, 'Complete-InstallRegistryGeneration', '''function Complete-InstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    Complete-RegistryJournal -ToolRoot $ToolRoot
}''')
s = replace_function(s, 'Get-InstallRegistryGenerationState', '''function Get-InstallRegistryGenerationState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $marker = Get-RegistryJournalPath $ToolRoot
    $legacy = Join-Path (Get-InstallRegistryDirectory $ToolRoot) '_writing.json'
    $incomplete = [IO.File]::Exists($marker) -or [IO.Directory]::Exists($marker) -or [IO.File]::Exists($legacy)
    return [pscustomobject]@{ Complete = (-not $incomplete); MarkerPath = $marker; Reason = $(if ($incomplete) { 'The registry transaction is half written or not activated; use its previous committed snapshot.' } else { '' }) }
}''')
s = replace_function(s, 'Repair-InterruptedInstallRegistryGeneration', '''function Repair-InterruptedInstallRegistryGeneration {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Restore-RegistryJournal -ToolRoot $ToolRoot)
}''')
a = s.index('# RECOVER an interrupted generation')
b = s.index('function Repair-InterruptedInstallRegistryGeneration', a)
s = s[:a] + '# Recover only a verified previous committed snapshot. A future schema is\n# untouched; a legacy partial batch with no journal is explicitly unavailable.\n' + s[b:]
write(path, s)

path = 'scripts/_installregistry.ps1'
s = read(path).replace('function Read-InstallRegistryState {', 'function Read-InstallRegistryStateUnlocked {', 1)
pos = s.index('function Read-InstallRegistryStateUnlocked')
s = s[:pos] + '''# Snapshot readers use the same lock as writers; nested calls on this runspace
# are reentrant, so an update cannot deadlock when it consults the registry.
function Read-InstallRegistryState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [switch]$NoCache)
    $directory = Get-InstallStateDirectory $ToolRoot
    if (-not [IO.Directory]::Exists($directory)) { return (Read-InstallRegistryStateUnlocked -ToolRoot $ToolRoot -NoCache:$NoCache) }
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        try {
            $journal = Read-RegistryJournal $ToolRoot
            if ($null -ne $journal) { return (Read-RegistryBeforeState -ToolRoot $ToolRoot -Journal $journal) }
            return (Read-InstallRegistryStateUnlocked -ToolRoot $ToolRoot -NoCache:$NoCache)
        }
        catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $directory; Reason = $_.Exception.Message } }
    })
}

''' + s[pos:]
s = s.replace('function Save-InstallRegistry {', 'function Save-InstallRegistryUnlocked {', 1)
pos = s.index('function Save-InstallRegistryUnlocked')
s = s[:pos] + '''function Save-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)]$Registry)
    $snapshot = Test-InstallRegistrySnapshot $Registry
    if (-not $snapshot.Ok) { throw $snapshot.Reason }
    Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        if (-not (Get-InstallRegistryGenerationState $ToolRoot).Complete) {
            $recovery = Repair-InterruptedInstallRegistryGeneration $ToolRoot
            if (-not $recovery.Ok) { throw $recovery.Reason }
        }
        Assert-RegistryMetadataSupported (Get-InstallRegistryDirectory $ToolRoot)
        Save-InstallRegistryUnlocked -ToolRoot $ToolRoot -Registry $Registry
    }
}

''' + s[pos:]
s = replace_function(s, 'Invoke-WithInstallRegistryLock', '''function Invoke-WithInstallRegistryLock {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)][scriptblock]$Action, [int]$TimeoutSeconds = 10)
    $directory = Get-InstallStateDirectory -ToolRoot $ToolRoot
    [void][IO.Directory]::CreateDirectory($directory)
    $lockPath = Join-Path $directory 'install-registry.lock'
    if ($null -eq (Get-Variable -Name InstallRegistryHeldLocks -Scope Script -ErrorAction SilentlyContinue)) { $script:InstallRegistryHeldLocks = @{} }
    $ownerKey = [IO.Path]::GetFullPath($lockPath).ToUpperInvariant() + '|' + [Threading.Thread]::CurrentThread.ManagedThreadId
    if ($script:InstallRegistryHeldLocks.ContainsKey($ownerKey)) { return (& $Action) }
    $stream = Open-CrashAwareLock -LockPath $lockPath -TimeoutSeconds $TimeoutSeconds
    $script:InstallRegistryHeldLocks[$ownerKey] = $stream
    try { return (& $Action) }
    finally {
        $script:InstallRegistryHeldLocks.Remove($ownerKey)
        if ($null -ne $stream) { $stream.Dispose() }
        # Leave the inode stable; a waiting writer may already hold this file.
    }
}''')
needle = '        # ---- one-off migration from the pre-record-per-file document --------'
assert needle in s
s = s.replace(needle, '''        if ([IO.File]::Exists((Get-RegistryJournalPath $ToolRoot))) {
            $recovery = Repair-InterruptedInstallRegistryGeneration $ToolRoot
            if (-not $recovery.Ok) { return [pscustomobject]@{ Ok = $false; QuarantinePath = ''; Warning = $recovery.Reason } }
            $warning = $recovery.Reason
        }

''' + needle)
write(path, s)

path = 'hooks/Cross-Project-.ai-Knowledge-Sync/_packageguard.ps1'
s = read(path)
s = s.replace('''            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        catch { continue }   # not created yet: nothing can be redirecting through it''', '''            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { return $false }
        }
        catch [System.IO.FileNotFoundException] { continue }
        catch [System.IO.DirectoryNotFoundException] { continue }
        catch { return $false }  # Unreadable is not equivalent to absent.''')
s = replace_function(s, 'Test-StagedFilesVerified', r'''function Test-StagedFilesVerified {
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
}''')
s = replace_function(s, 'Test-PackageGenerationIntact', r'''function Test-PackageGenerationIntact {
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
}''')
write(path, s)

path = 'hooks/Cross-Project-.ai-Knowledge-Sync/_packagebuild.ps1'
s = read(path)
s = s.replace("$packageRoot = Join-Path $StatePaths.inboxRoot ([string]$ContentSnapshot.fingerprint).Substring(0, 16)", "$packageRoot = Join-Path $StatePaths.inboxRoot (([string]$ContentSnapshot.fingerprint).Substring(0, 16) + '-' + [guid]::NewGuid().ToString('N'))")
a = s.index('    # A half-built generation')
b = s.index('    New-Item -ItemType Directory -Path $filesRoot', a)
s = s[:a] + '    # A unique generation never replaces a still-published package in place.\n' + s[b:]
s = s.replace('    foreach ($relativePath in ($added + $modified)) {', '''    foreach ($relativePath in ($added + $modified)) {
        if (-not (Test-PackageRelativePath $relativePath)) { throw 'Unsafe relative path in the source snapshot.' }''')
s = s.replace('        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force', '''        if (-not (Test-OwnedStagingChain -TrustedRoot $Context.sourceDirectory -OwnedRoot $Context.sourceDirectory -Target $Context.sourceDirectory -AllowRootItself)) { throw 'Source root is redirected or unreadable.' }
        if (-not (Test-OwnedStagingChain -TrustedRoot $Context.sourceDirectory -OwnedRoot $Context.sourceDirectory -Target (Split-Path -Parent $sourcePath) -AllowRootItself)) { throw 'Source ancestry is redirected or unreadable.' }
        if (([IO.File]::GetAttributes($sourcePath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source file is redirected.' }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop''')
s = s.replace('        version = 2', '        version = 3')
a = s.index('    # Only now is the previous generation')
b = s.index('    return [pscustomobject]', a)
s = s[:a] + '    # State publication owns retirement. Building a package does not make its\n    # predecessor disposable: a later state write can still fail.\n' + s[b:]
s = s.replace('        sourceFiles = @($ContentSnapshot.files)', '''        sourceFiles = @($ContentSnapshot.files)
        stagedFiles = @($stagedRecords)
        manifestSha256 = Get-PackageFileDigest $manifestPath''')
s = s.replace('        deferredCleanup = @($deferredCleanup)', '        deferredCleanup = @()')
s += '''
# The durable state pointer commits first. Cleanup is a separate post-commit
# outcome; failure can leave disposable old generations but cannot lose review.
function Publish-PendingPackage {
    param($Context, $State, $StatePaths, $Pending, [string]$SessionId)
    if (-not (Test-PendingPackageIntact $Pending $Context $StatePaths)) { throw 'Refusing to publish an unverified review package.' }
    $next = $State.PSObject.Copy()
    Set-ObjectProperty -Object $next -Name 'pending' -Value $Pending
    Set-ObjectProperty -Object $next -Name 'lastNotifiedSessionId' -Value $SessionId
    Set-ObjectProperty -Object $next -Name 'lastNotifiedAtUtc' -Value ([DateTime]::UtcNow.ToString('o'))
    Write-JsonFileAtomic -Value $next -Path $StatePaths.statePath
    $deferred = @(Remove-SupersededGenerations -InboxRoot $StatePaths.inboxRoot -TrustedRoot $Context.destinationRoot -KeepPackageRoot $Pending.packageRoot)
    Set-ObjectProperty -Object $Pending -Name 'deferredCleanup' -Value $deferred
    return $next
}
'''
write(path, s)

path = 'hooks/Cross-Project-.ai-Knowledge-Sync/Cross-Project-.ai-Knowledge-Sync.ps1'
s = read(path)
s = s.replace("        sourceFiles              = @(Get-SafeArrayField (Get-Field $Pending 'sourceFiles') @())", """        sourceFiles              = @(Get-SafeArrayField (Get-Field $Pending 'sourceFiles') @())
        stagedFiles              = @(Get-SafeArrayField (Get-Field $Pending 'stagedFiles') @())
        manifestSha256           = Get-SafeStringField (Get-Field $Pending 'manifestSha256') ''""")
s = s.replace('Test-PackageGenerationIntact -PackageRoot $pendingPackageRoot -Fingerprint ([string]$state.pending.sourceContentFingerprint)', 'Test-PendingPackageIntact -Pending $state.pending -Context $context -StatePaths $statePaths')
s = s.replace('Test-PackageGenerationIntact -PackageRoot ([string]$state.pending.packageRoot) -Fingerprint ([string]$state.pending.sourceContentFingerprint)', 'Test-PendingPackageIntact -Pending $state.pending -Context $context -StatePaths $statePaths')
old = """        Set-ObjectProperty -Object $state -Name 'pending' -Value $pending
        Set-ObjectProperty -Object $state -Name 'lastNotifiedSessionId' -Value $sessionId
        Set-ObjectProperty -Object $state -Name 'lastNotifiedAtUtc' -Value ([DateTime]::UtcNow.ToString('o'))
        Write-JsonFileAtomic -Value $state -Path $statePaths.statePath
        [void]$messages.Add((New-ReviewMessage -Context $context -Pending $pending))"""
assert old in s
s = s.replace(old, """        $state = Publish-PendingPackage -Context $context -State $state -StatePaths $statePaths -Pending $pending -SessionId $sessionId
        [void]$messages.Add((New-ReviewMessage -Context $context -Pending $pending))""")
s = s.replace("""                Set-ObjectProperty -Object $state -Name 'pending' -Value $null
                Write-JsonFileAtomic -Value $state -Path $statePaths.statePath""", """                Set-ObjectProperty -Object $state -Name 'pending' -Value $null
                # Keep the disk record until a replacement can be committed.""")
a = s.index('        if ([string]$state.lastAppliedContentFingerprint -eq [string]$contentSnapshot.fingerprint) {')
b = s.index('        $pending = New-PendingPackage', a)
seg = s[a:b]
x = seg.index('            if ($null -ne $state.pending) {')
y = seg.index("            Set-ObjectProperty -Object $state -Name 'lastAppliedQuickFingerprint'", x)
seg = seg[:x] + "            $retireRoot = if ($null -ne $state.pending) { [string]$state.pending.packageRoot } else { '' }\n" + seg[y:]
seg = seg.replace('            Write-JsonFileAtomic -Value $state -Path $statePaths.statePath\n            continue', '''            Write-JsonFileAtomic -Value $state -Path $statePaths.statePath
            if ($retireRoot -ne '' -and -not (Remove-OwnedPackageDirectory -Path $retireRoot -OwnedRoot $statePaths.inboxRoot -TrustedRoot $context.destinationRoot)) {
                [void]$messages.Add('Sync review state was committed; obsolete package cleanup was deferred.')
            }
            continue''')
s = s[:a] + seg + s[b:]
write(path, s)
