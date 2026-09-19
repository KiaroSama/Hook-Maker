# Batch registry journal. A reader sees the previous committed snapshot until
# activation; a crash rolls back to that snapshot, never to arbitrary survivors.
# The marker lives OUTSIDE the live directory, closing the first-save window.
# Caller serialization is shared with the O(1) per-record updater. No credentials
# or hook content is added: backups contain only existing registry metadata.

function Get-RegistryJournalPath {
    param([string]$ToolRoot)
    return (Join-Path (Get-InstallStateDirectory $ToolRoot) 'install-registry.transaction.json')
}

function Assert-RegistryMetadataSupported {
    param([string]$Directory)
    $path = Join-Path $Directory '_meta.json'
    if (-not [IO.File]::Exists($path)) { return }
    $meta = Read-JsonFile $path
    $version = 0
    if ($null -eq $meta -or -not [int]::TryParse([string](Get-Field $meta 'version'), [ref]$version) -or $version -lt 1) {
        throw 'The registry metadata version is invalid; the registry was left untouched.'
    }
    if ($version -gt $script:InstallRegistrySchemaVersion) {
        throw ('The registry was written by a newer Hook Maker (schema ' + $version + ') and was left untouched.')
    }
}

function Read-RegistryJournal {
    param([string]$ToolRoot)
    $path = Get-RegistryJournalPath $ToolRoot
    if (-not [IO.File]::Exists($path)) { return $null }
    if ((Get-Item -LiteralPath $path -ErrorAction Stop).Length -gt 4194304) { throw 'Oversized registry transaction marker.' }
    $doc = Read-JsonFile $path
    if ([string](Get-Field $doc 'schema') -ne '1' -or [string](Get-Field $doc 'generation') -notmatch '^[a-f0-9]{32}$') { throw 'Unsupported or corrupt registry transaction marker.' }
    foreach ($name in @('beforeFiles', 'expectedFiles', 'expectedRecords')) {
        if ($null -eq $doc.PSObject.Properties[$name] -or $doc.$name -isnot [System.Array] -or @($doc.$name).Count -gt 10000) { throw 'Invalid registry transaction collection.' }
    }
    if ((Get-Field $doc 'hadDirectory') -isnot [bool]) { throw 'Invalid registry transaction origin.' }
    $seen = @{}
    foreach ($entry in @($doc.beforeFiles)) {
        $name = [string](Get-Field $entry 'name')
        if ($name -notmatch '^[A-Za-z0-9._-]+\.json$' -or $seen.ContainsKey($name) -or [string](Get-Field $entry 'sha256') -notmatch '^[a-f0-9]{64}$') { throw 'Invalid registry snapshot file identity.' }
        if ($name -ne '_meta.json' -and -not (Test-InstallRecordIdSafe ([IO.Path]::GetFileNameWithoutExtension($name)))) { throw 'Unsafe registry snapshot filename.' }
        $seen[$name] = $true
    }
    return $doc
}

function Get-RegistryJournalBackup {
    param([string]$ToolRoot, $Journal)
    return (Join-Path (Get-InstallStateDirectory $ToolRoot) ('install-registry-backup-' + [string]$Journal.generation + '.d'))
}

function Read-RegistryBeforeState {
    param([string]$ToolRoot, $Journal)
    if (-not $Journal.hadDirectory) {
        # Before a first save, the existing legacy document is still authoritative.
        $legacy = Get-InstallRegistryPath $ToolRoot
        if ([IO.File]::Exists($legacy)) {
            $value = Read-JsonFile $legacy
            $shape = Test-InstallRegistryShape $value
            if (-not $shape.Ok) { throw $shape.Reason }
            return [pscustomobject]@{ State = 'ok'; Registry = $value; Path = $legacy; Reason = 'previous committed snapshot during an incomplete transaction' }
        }
        return [pscustomobject]@{ State = 'missing'; Registry = (New-EmptyInstallRegistry); Path = $legacy; Reason = 'first registry transaction has not committed' }
    }
    $backup = Get-RegistryJournalBackup $ToolRoot $Journal
    if (-not [IO.Directory]::Exists($backup) -or (Test-IsReparsePoint $backup)) { throw 'Registry rollback snapshot is missing or redirected.' }
    $records = New-Object System.Collections.Generic.List[object]
    $version = $script:InstallRegistrySchemaVersion
    foreach ($entry in @($Journal.beforeFiles)) {
        $path = Join-Path $backup ([string]$entry.name)
        if (-not [IO.File]::Exists($path) -or (Test-IsReparsePoint $path)) { throw 'Registry rollback file is missing or redirected.' }
        $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ((Get-InstallRecordDigest $raw) -cne [string]$entry.sha256) { throw 'Registry rollback file failed its recorded digest.' }
        $value = $raw | ConvertFrom-Json
        if ($entry.name -eq '_meta.json') { $version = Get-Field $value 'version' }
        else {
            $agreement = Test-InstallRecordFileAgreement -FileName $entry.name -Record $value
            if (-not $agreement.Ok) { throw $agreement.Reason }
            [void]$records.Add($value)
        }
    }
    $registry = [pscustomobject]@{ version = $version; installs = @($records.ToArray()) }
    $shape = Test-InstallRegistryShape $registry
    if (-not $shape.Ok) { throw $shape.Reason }
    return [pscustomobject]@{ State = 'ok'; Registry = $registry; Path = $backup; Reason = 'previous committed snapshot during an incomplete transaction' }
}

function Start-RegistryJournal {
    param([string]$ToolRoot, [string[]]$ExpectedFileNames, [object[]]$ExpectedRecords)
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $directory = Get-InstallRegistryDirectory $ToolRoot
        $marker = Get-RegistryJournalPath $ToolRoot
        if ([IO.File]::Exists($marker) -or [IO.File]::Exists((Join-Path $directory '_writing.json'))) { throw 'Recover the unfinished registry transaction before starting another.' }
        Assert-RegistryMetadataSupported $directory
        $beforeState = Read-InstallRegistryStateUnlocked -ToolRoot $ToolRoot -NoCache
        if ($beforeState.State -eq 'corrupt') { throw $beforeState.Reason }
        $generation = [guid]::NewGuid().ToString('N')
        $journal = [pscustomobject][ordered]@{
            schema = 1; generation = $generation; hadDirectory = [IO.Directory]::Exists($directory)
            beforeFiles = @(); expectedFiles = @($ExpectedFileNames); expectedRecords = @($ExpectedRecords)
            startedUtc = [DateTime]::UtcNow.ToString('o')
        }
        $backup = Get-RegistryJournalBackup $ToolRoot $journal
        [void][IO.Directory]::CreateDirectory($backup)
        $published = $false
        try {
            if ($journal.hadDirectory) {
                $files = @(Get-InstallRecordFiles $ToolRoot)
                $meta = Join-Path $directory '_meta.json'
                if ([IO.File]::Exists($meta)) { $files += Get-Item -LiteralPath $meta }
                if ($files.Count -gt 10000) { throw 'Registry snapshot exceeds its file bound.' }
                $bytes = 0L; $before = @()
                foreach ($file in $files) {
                    $bytes += $file.Length
                    if ($bytes -gt 67108864 -or (Test-IsReparsePoint $file.FullName)) { throw 'Registry snapshot exceeds its byte bound or contains a link.' }
                    $raw = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
                    [IO.File]::Copy($file.FullName, (Join-Path $backup $file.Name))
                    $before += [pscustomobject]@{ name = $file.Name; sha256 = Get-InstallRecordDigest $raw }
                }
                $journal.beforeFiles = @($before)
            }
            $null = Read-RegistryBeforeState -ToolRoot $ToolRoot -Journal $journal
            Write-JsonFileAtomic -Path $marker -Value $journal
            $published = $true
            # Marker publication precedes even creation of the new live directory.
            [void][IO.Directory]::CreateDirectory($directory)
            $script:InstallRegistryCache = $null
            return $generation
        }
        finally {
            if (-not $published -and [IO.Directory]::Exists($backup)) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
        }
    })
}

function Test-RegistryIntendedSnapshot {
    param([string]$ToolRoot, $Journal)
    $directory = Get-InstallRegistryDirectory $ToolRoot
    Assert-RegistryMetadataSupported $directory
    $wanted = @($Journal.expectedFiles | Sort-Object -Unique)
    $actual = @(Get-InstallRecordFiles $ToolRoot | ForEach-Object { $_.Name } | Sort-Object)
    if (($wanted -join '|') -cne ($actual -join '|') -or @($Journal.expectedRecords).Count -ne $wanted.Count) { return $false }
    $seen = @{}
    foreach ($entry in @($Journal.expectedRecords)) {
        $name = [string](Get-Field $entry 'name')
        $digest = [string](Get-Field $entry 'sha256')
        if ($wanted -cnotcontains $name -or $seen.ContainsKey($name) -or $digest -notmatch '^[a-f0-9]{64}$') { return $false }
        $seen[$name] = $true
        $raw = [IO.File]::ReadAllText((Join-Path $directory $name), [Text.Encoding]::UTF8)
        if ((Get-InstallRecordDigest $raw) -cne $digest) { return $false }
    }
    $state = Read-InstallRegistryFromDirectory -ToolRoot $ToolRoot -NoCache
    return ($state.State -eq 'ok' -and [int]$state.Registry.version -eq $script:InstallRegistrySchemaVersion)
}

function Complete-RegistryJournal {
    param([string]$ToolRoot)
    Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $journal = Read-RegistryJournal $ToolRoot
        if ($null -eq $journal) { throw 'Cannot activate a registry without its transaction journal.' }
        if (-not (Test-RegistryIntendedSnapshot $ToolRoot $journal)) { throw 'The intended registry snapshot is not complete; activation was refused.' }
        $marker = Get-RegistryJournalPath $ToolRoot
        # This is the only activation point. No filename or digest precheck in a
        # reader can substitute for successful metadata and deletion completion.
        Remove-Item -LiteralPath $marker -Force -ErrorAction Stop
        $script:InstallRegistryCache = $null
        $backup = Get-RegistryJournalBackup $ToolRoot $journal
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-RegistryJournal {
    param([string]$ToolRoot)
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        try {
            $directory = Get-InstallRegistryDirectory $ToolRoot
            # Check live metadata BEFORE considering rollback. A newer writer's
            # document must never be treated as recoverable corruption.
            Assert-RegistryMetadataSupported $directory
            $journal = Read-RegistryJournal $ToolRoot
            if ($null -eq $journal) {
                $legacyMarker = Join-Path $directory '_writing.json'
                if ([IO.File]::Exists($legacyMarker)) {
                    return [pscustomobject]@{ Ok = $false; Recovered = $false; Reason = 'Legacy incomplete transaction has no committed rollback snapshot; preserve its files and recover explicitly.' }
                }
                return [pscustomobject]@{ Ok = $true; Recovered = $false; Reason = '' }
            }
            $null = Read-RegistryBeforeState -ToolRoot $ToolRoot -Journal $journal
            $backup = Get-RegistryJournalBackup $ToolRoot $journal
            # Preserve the failed generation for inspection instead of deleting
            # possibly useful tracking records. The external marker remains live.
            if ([IO.Directory]::Exists($directory)) {
                $failed = Join-Path (Get-InstallStateDirectory $ToolRoot) ('install-registry-failed-' + [guid]::NewGuid().ToString('N') + '.d')
                Move-Item -LiteralPath $directory -Destination $failed -ErrorAction Stop
            }
            if ($journal.hadDirectory) {
                [void][IO.Directory]::CreateDirectory($directory)
                foreach ($entry in @($journal.beforeFiles)) {
                    Copy-Item -LiteralPath (Join-Path $backup $entry.name) -Destination (Join-Path $directory $entry.name) -ErrorAction Stop
                }
                $restored = Read-InstallRegistryFromDirectory -ToolRoot $ToolRoot -NoCache
                if ($restored.State -ne 'ok') { throw 'Rollback snapshot could not be restored.' }
            }
            Remove-Item -LiteralPath (Get-RegistryJournalPath $ToolRoot) -Force -ErrorAction Stop
            $script:InstallRegistryCache = $null
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Ok = $true; Recovered = $true; Reason = 'Restored the last committed registry snapshot; the failed generation was preserved separately.' }
        }
        catch { return [pscustomobject]@{ Ok = $false; Recovered = $false; Reason = $_.Exception.Message } }
    })
}
