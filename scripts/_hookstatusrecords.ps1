# ---------------------------------------------------------------------------
# Record-building half of the hook-status scan engine. Dot-sourced by
# Get-HookStatus.ps1 ONLY - it runs in that script's scope, so every
# $script: state variable (RegistrationFindings, NativeFindings, ScanId,
# ScanRoots, RecordsAdded/Updated/Matched, ...) and every helper it calls
# (Add-ScanWarning, and Test-PathUnderAny from _hookstatusscan.ps1) resolve at
# CALL time, once the whole engine and its libraries are loaded and only
# "main" is executing. Do not dot-source this file directly, and it must not
# dot-source anything itself.
#
# Responsibility: group _hookstatusscan.ps1's raw findings into verified
# logical records, compute shared/owned runtime artifacts, and persist them
# into the existing install registry.
# ---------------------------------------------------------------------------
# ---- grouping into logical records -----------------------------------------

# Stable ids (Get-DiscoveredRecordId) and rescan/merge semantics
# (Merge-DiscoveredRecord, Test-DiscoveredRecordValid) come from
# _installregistry.ps1 via _installlib.ps1. This file never reimplements them -
# the registry layer is the single authority on what a discovered record is.

function Get-RegistrationFriendlyName {
    param($Findings)
    foreach ($finding in @($Findings)) {
        if (-not [string]::IsNullOrWhiteSpace($finding.HookMakerName)) { return [string]$finding.HookMakerName }
    }
    foreach ($finding in @($Findings)) {
        if (@($finding.ParsedTargets).Count -gt 0) {
            return [System.IO.Path]::GetFileNameWithoutExtension([string]@($finding.ParsedTargets)[0])
        }
    }
    $first = @($Findings)[0]
    return ([string]$first.Client + ' ' + [string]$first.EventName + ' handler')
}

# Groups per-handler findings into logical records.
#
# The grouping key is the PROVEN runtime identity, never a name:
#   * when every command field agrees on a target, the key is that canonical
#     path (so several events - and Claude+Codex together - collapse into one
#     record only because they provably run the same file);
#   * when no target can be proven, the key falls back to the handler
#     fingerprint AND the client/settings file, so two unprovable handlers can
#     never be merged across clients on a coincidence.
function Group-RegistrationFindings {
    # A plain hashtable plus an explicit key list: [ordered] would give the same
    # ordering, but its indexer is overloaded on both int and object and
    # PowerShell can bind the wrong one for a string key.
    $groups = @{}
    $order = New-Object System.Collections.Generic.List[string]
    # .ToArray() rather than @(...): PowerShell 7.6 throws "Argument types do
    # not match" when the array subexpression operator is applied directly to a
    # List[object]. Every List[object] in this file is unwrapped the same way.
    foreach ($finding in $script:RegistrationFindings.ToArray()) {
        $runtimeKey = ''
        if ($finding.RegistrationStatus -eq 'parsed' -or $finding.RegistrationStatus -eq 'targetMissing') {
            $runtimeKey = 'target:' + (Get-CanonicalPathKey @($finding.ParsedTargets)[0])
        }
        else {
            $runtimeKey = 'fp:' + $finding.HandlerFingerprint + '|' + $finding.Client + '|' + (Get-CanonicalPathKey $finding.SettingsPath)
        }
        $key = [string]$finding.Scope + '|' + (Get-CanonicalPathKey $finding.ProjectRoot) + '|' + $runtimeKey
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.Generic.List[object]
            [void]$order.Add($key)
        }
        [void]$groups[$key].Add($finding)
    }
    return [pscustomobject]@{ Map = $groups; Order = @($order.ToArray()) }
}

function New-ClientEvidence {
    param([string]$Client, $Findings)
    $first = @($Findings)[0]
    $statuses = @(@($Findings) | ForEach-Object { [string]$_.RegistrationStatus } | Sort-Object -Unique)
    # The worst status wins: a record must never look healthier than its least
    # provable handler.
    $status = 'parsed'
    foreach ($candidate in @('fieldsDisagree', 'unparsedCommand', 'targetMissing', 'parsed')) {
        if ($statuses -contains $candidate) { $status = $candidate; break }
    }
    return [pscustomobject][ordered]@{
        client              = $Client
        settingsPath        = [string]$first.SettingsPath
        events              = @(@($Findings) | ForEach-Object { [string]$_.EventName } | Sort-Object -Unique)
        handlerFingerprints = @(@($Findings) | ForEach-Object { [string]$_.HandlerFingerprint } | Sort-Object -Unique)
        matcherFingerprints = @(@($Findings) | ForEach-Object { [string]$_.MatcherFingerprint } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        handlerTypes        = @(@($Findings) | ForEach-Object { [string]$_.HandlerType } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        commandFieldNames   = @(@($Findings) | ForEach-Object { @($_.CommandFieldNames) } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        parsedTargets       = @(@($Findings) | ForEach-Object { @($_.ParsedTargets) } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
        registrationStatus  = $status
    }
}

function Build-RegistrationRecords {
    $records = New-Object System.Collections.Generic.List[object]
    $now = [DateTime]::UtcNow.ToString('o')
    $groups = Group-RegistrationFindings
    foreach ($key in @($groups.Order)) {
        $findings = @($groups.Map[$key].ToArray())
        $first = $findings[0]
        $clients = @(@($findings) | ForEach-Object { [string]$_.Client } | Sort-Object -Unique)
        $clientEvidence = @()
        foreach ($client in $clients) {
            $clientEvidence += (New-ClientEvidence -Client $client -Findings @(@($findings) | Where-Object { [string]$_.Client -eq $client }))
        }
        $settingsPaths = @(@($clientEvidence) | ForEach-Object { [string]$_.settingsPath } | Sort-Object -Unique)
        $handlerFingerprints = @(@($findings) | ForEach-Object { [string]$_.HandlerFingerprint } | Sort-Object -Unique)

        $statuses = @(@($clientEvidence) | ForEach-Object { [string]$_.registrationStatus })
        $status = 'active'
        $statusReason = 'registration and target verified'
        $removalPolicy = 'full'
        $needsManualRepair = $false
        if ($statuses -contains 'fieldsDisagree') {
            $status = 'ambiguous'
            $statusReason = 'command fields disagree on the target; automatic removal is unsafe'
            $removalPolicy = 'unavailable'
            $needsManualRepair = $true
        }
        elseif ($statuses -contains 'unparsedCommand') {
            $status = 'registrationOnly'
            $statusReason = 'the command could not be parsed to a target; only the registration can be removed'
            $removalPolicy = 'registrationOnly'
        }
        elseif ($statuses -contains 'targetMissing') {
            $status = 'missingTarget'
            $statusReason = 'the registered target file does not exist'
            $removalPolicy = 'registrationOnly'
        }

        $managedBy = 'unknown'
        if (@(@($findings) | Where-Object { [string]$_.ManagedBy -eq 'hookMaker' }).Count -gt 0) { $managedBy = 'hookMaker' }
        elseif (@(@($findings) | Where-Object { [string]$_.ManagedBy -eq 'external' }).Count -gt 0) { $managedBy = 'external' }

        # A perHookFile client (Kiro) registers its own JSON document per
        # installation. The discovered remover only knows how to prune a handler
        # out of a SHARED settings file, so offering any removal for one of
        # these would promise an operation that does not exist - or, worse,
        # point that pruning at a document with a completely different schema.
        # Reported in full, never offered for removal, until a per-hook-file
        # removal path exists.
        $perHookFileRecord = (@(@($clients) | Where-Object { Test-PerHookFileClient -ClientId ([string]$_) }).Count -gt 0)
        if ($perHookFileRecord) {
            $removalPolicy = 'unavailable'
            if ($status -eq 'active') {
                $statusReason = 'registration and target verified; per-hook-file removal is not implemented'
            }
        }

        $id = Get-DiscoveredRecordId -Kind 'registration' -Scope ([string]$first.Scope) `
            -TargetProjectRoot ([string]$first.ProjectRoot) -Client ($clients -join ',') `
            -SettingsPath ($settingsPaths -join ',') -HandlerFingerprints $handlerFingerprints

        [void]$records.Add([pscustomobject][ordered]@{
            id                = $id
            schema            = $script:InstallRegistrySchemaVersion
            recordType        = 'discovered'
            origin            = 'statusScan'
            friendlyName      = (Get-RegistrationFriendlyName -Findings $findings)
            hookType          = $(
                if ($clients.Count -eq 1 -and $clients[0] -eq 'codex') { 'CodexRegistration' }
                elseif ($clients.Count -eq 1 -and $clients[0] -eq 'kiro') { 'KiroRegistration' }
                else { 'ClaudeRegistration' })
            scope             = [string]$first.Scope
            targetProjectRoot = [string]$first.ProjectRoot
            firstSeenUtc      = $now
            lastSeenUtc       = $now
            lastScanId        = $script:ScanId
            scanRoots         = @($script:ScanRoots.ToArray())
            status            = $status
            statusReason      = $statusReason
            managedBy         = $managedBy
            clients           = @($clientEvidence)
            nativeGit         = $null
            runtimeArtifacts  = @()
            removalPolicy     = $removalPolicy
            needsManualRepair = $needsManualRepair
        })
    }
    return $records.ToArray()
}

function Build-NativeRecords {
    $records = New-Object System.Collections.Generic.List[object]
    $now = [DateTime]::UtcNow.ToString('o')
    foreach ($finding in $script:NativeFindings.ToArray()) {
        $status = 'active'
        $statusReason = 'native git hook present'
        $removalPolicy = 'unavailable'
        $needsManualRepair = $false
        $managedBy = 'external'
        if ($finding.Classification -eq 'hookMakerWrapper') {
            $managedBy = 'hookMaker'
            $removalPolicy = 'nativeFileOnly'
            $statusReason = 'Hook Maker managed wrapper, verified byte-for-byte'
        }
        elseif ($finding.Classification -eq 'ambiguous') {
            $status = 'manualRepair'
            $managedBy = 'unknown'
            $statusReason = 'carries the Hook Maker marker but does not match the canonical wrapper; left untouched'
            $needsManualRepair = $true
        }
        [void]$records.Add([pscustomobject][ordered]@{
            id                = (Get-DiscoveredRecordId -Kind 'native' -RepositoryRoot $finding.RepositoryRoot -HookPath $finding.HookPath -HookName $finding.HookName)
            schema            = $script:InstallRegistrySchemaVersion
            recordType        = 'discovered'
            origin            = 'statusScan'
            friendlyName      = ([string]$finding.HookName + ' (' + (Split-Path -Leaf $finding.RepositoryRoot) + ')')
            hookType          = 'NativeGitHook'
            scope             = 'project'
            targetProjectRoot = [string]$finding.RepositoryRoot
            firstSeenUtc      = $now
            lastSeenUtc       = $now
            lastScanId        = $script:ScanId
            scanRoots         = @($script:ScanRoots.ToArray())
            status            = $status
            statusReason      = $statusReason
            managedBy         = $managedBy
            clients           = @()
            nativeGit         = [pscustomobject][ordered]@{
                repositoryRoot  = [string]$finding.RepositoryRoot
                hooksPath       = [string]$finding.HooksPath
                hookName        = [string]$finding.HookName
                hookPath        = [string]$finding.HookPath
                hookHash        = [string]$finding.HookHash
                hookSize        = [int64]$finding.HookSize
                hookModifiedUtc = [string]$finding.HookModifiedUtc
                classification  = [string]$finding.Classification
                managedStages   = @($finding.ManagedStages)
            }
            runtimeArtifacts  = @()
            removalPolicy     = $removalPolicy
            needsManualRepair = $needsManualRepair
        })
    }
    return $records.ToArray()
}

# Runtime artifacts are computed AFTER every record exists, because
# "is this file shared?" is only answerable across the whole result set - and a
# shared runtime is exactly the case where deleting it would break another hook.
function Add-RuntimeArtifacts {
    param($Records)

    $referenceMap = @{}
    foreach ($record in @($Records)) {
        foreach ($client in @($record.clients)) {
            foreach ($target in @($client.parsedTargets)) {
                $key = Get-CanonicalPathKey $target
                if ($key -eq '') { continue }
                if (-not $referenceMap.ContainsKey($key)) { $referenceMap[$key] = New-Object System.Collections.Generic.List[string] }
                if (-not $referenceMap[$key].Contains([string]$record.id)) { [void]$referenceMap[$key].Add([string]$record.id) }
            }
        }
        if ($null -ne $record.nativeGit) {
            foreach ($stage in @($record.nativeGit.managedStages)) {
                $key = Get-CanonicalPathKey $stage
                if ($key -eq '') { continue }
                if (-not $referenceMap.ContainsKey($key)) { $referenceMap[$key] = New-Object System.Collections.Generic.List[string] }
                if (-not $referenceMap[$key].Contains([string]$record.id)) { [void]$referenceMap[$key].Add([string]$record.id) }
            }
        }
    }

    foreach ($record in @($Records)) {
        $artifacts = New-Object System.Collections.Generic.List[object]
        $paths = New-Object System.Collections.Generic.List[object]
        # 'registeredRuntime' + 'eligible' is the ONE combination
        # Uninstall-DiscoveredHook.ps1 will auto-delete, so a record whose
        # registration this tool cannot remove must never hand out that
        # combination: deleting the runtime while the registration survives
        # leaves a hook the client still fires and cannot find.
        $perHookFileRecord = (@(@($record.clients) |
            Where-Object { Test-PerHookFileClient -ClientId ([string]$_.client) }).Count -gt 0)
        foreach ($client in @($record.clients)) {
            # 'entrypoint' is a CONTRACT literal, not a label: together with
            # classification 'registeredRuntime' it is the only combination
            # Uninstall-DiscoveredHook.ps1 will ever auto-delete. Anything that
            # must never be auto-deleted therefore carries a different kind.
            foreach ($target in @($client.parsedTargets)) { [void]$paths.Add([pscustomobject]@{ Path = $target; Kind = 'entrypoint' }) }
        }
        if ($null -ne $record.nativeGit) {
            [void]$paths.Add([pscustomobject]@{ Path = [string]$record.nativeGit.hookPath; Kind = 'entrypoint' })
            foreach ($stage in @($record.nativeGit.managedStages)) { [void]$paths.Add([pscustomobject]@{ Path = $stage; Kind = 'nativeStage' }) }
        }
        # A record with no provable target simply has no artifacts: an artifact
        # entry needs a real canonical path, and inventing an empty one would be
        # a fabricated location. The 'registrationOnly' status already says it.
        $seen = New-Object System.Collections.Generic.HashSet[string]
        foreach ($entry in $paths) {
            $key = Get-CanonicalPathKey $entry.Path
            if ($key -eq '' -or -not $seen.Add($key)) { continue }
            $exists = (Test-Path -LiteralPath $entry.Path -PathType Leaf)
            $referencedBy = @()
            if ($referenceMap.ContainsKey($key)) { $referencedBy = @($referenceMap[$key].ToArray()) }
            if ($referencedBy.Count -eq 0) { $referencedBy = @([string]$record.id) }
            $size = 0
            if ($exists) { try { $size = [int64](New-Object System.IO.FileInfo $entry.Path).Length } catch { $size = 0 } }

            $classification = 'registeredRuntime'
            $eligibility = 'eligible'
            $reason = 'referenced only by this record'
            if (-not $exists) {
                $classification = 'missingTarget'; $eligibility = 'preserve'; $reason = 'target file does not exist'
            }
            elseif ($perHookFileRecord) {
                $eligibility = 'preserve'; $reason = 'per-hook-file registration removal is not implemented'
            }
            elseif ($referencedBy.Count -gt 1) {
                $classification = 'sharedRuntime'; $eligibility = 'preserve'; $reason = 'shared with another discovered hook'
            }
            elseif ([string]$record.status -eq 'ambiguous' -or [string]$record.status -eq 'manualRepair') {
                $classification = 'ambiguous'; $eligibility = 'preserve'; $reason = 'record identity is not fully proven'
            }
            elseif ($entry.Kind -eq 'nativeStage') {
                # A stage script is Hook Maker's own installed hook runtime and
                # is owned by ITS record, not by the native wrapper's.
                $classification = 'sharedRuntime'; $eligibility = 'preserve'; $reason = 'stage script is owned by its own hook record'
            }
            [void]$artifacts.Add([pscustomobject][ordered]@{
                path = [string]$entry.Path
                kind = [string]$entry.Kind
                hash = $(if ($exists) { Get-FileSha256Hex -Path $entry.Path } else { '' })
                size = $size
                classification = $classification
                referencedBy = @($referencedBy)
                deleteEligibility = $eligibility
                deleteReason = $reason
            })
        }
        # Only a REGISTRATION record can be demoted for a shared runtime. A
        # native record always references its own stage scripts (which belong to
        # their own hook records), so applying this to it would wrongly downgrade
        # every verified managed wrapper.
        if (@($record.clients).Count -gt 0 -and $artifacts.Count -gt 0 -and
            @($artifacts | Where-Object { $_.classification -eq 'sharedRuntime' }).Count -gt 0 -and
            [string]$record.status -eq 'active') {
            Set-ObjectProperty -Object $record -Name 'status' -Value 'sharedRuntime'
            Set-ObjectProperty -Object $record -Name 'statusReason' -Value 'the registered runtime is shared with another discovered hook'
            Set-ObjectProperty -Object $record -Name 'removalPolicy' -Value 'registrationOnly'
        }
        Set-ObjectProperty -Object $record -Name 'runtimeArtifacts' -Value @($artifacts.ToArray())
    }
    return $Records
}

# ---- persistence -----------------------------------------------------------

# Was this record's evidence location actually COVERED by this scan? Only a
# covered-and-readable location may be demoted to 'notSeen' - anything under an
# inaccessible or reparse-skipped subtree, or outside the roots entirely, is
# left exactly as it was, because absence of evidence here is not evidence of
# absence.
function Test-RecordCoveredByScan {
    param($Record, [string[]]$Roots)
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($client in @($Record.clients)) {
            if ($null -ne $client -and $null -ne $client.PSObject.Properties['settingsPath']) { [void]$paths.Add([string]$client.settingsPath) }
        }
        if ($null -ne $Record.PSObject.Properties['nativeGit'] -and $null -ne $Record.nativeGit -and
            $null -ne $Record.nativeGit.PSObject.Properties['hookPath']) {
            [void]$paths.Add([string]$Record.nativeGit.hookPath)
        }
    }
    catch { return $false }
    if ($paths.Count -eq 0) { return $false }
    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        if (-not (Test-PathUnderAny -Path $path -Parents $Roots)) { return $false }
        if (Test-PathUnderAny -Path $path -Parents @($script:Inaccessible.ToArray())) { return $false }
        if (Test-PathUnderAny -Path $path -Parents @($script:SkippedReparse.ToArray())) { return $false }
    }
    return $true
}

function Save-DiscoveredRecords {
    param($Records, [bool]$CoverageComplete)

    Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($state.State -eq 'corrupt') {
            # A corrupt registry can never be safely rewritten - its managed
            # records could be destroyed. Report and touch nothing.
            Add-ScanWarning ('the install registry is unreadable (' + [string]$state.Reason + '); no scan results were persisted')
            return
        }
        $registry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry

        # Every write goes through the registry layer's own merge, which owns
        # the rules this scanner must not second-guess: shape validation,
        # firstSeenUtc carry-forward, refusing to duplicate a hook a managed
        # install already accounts for, and refusing a notSeen claim from a scan
        # that did not actually cover everything.
        $incomingIds = New-Object System.Collections.Generic.HashSet[string]
        foreach ($record in @($Records)) {
            [void]$incomingIds.Add([string]$record.id)
            $outcome = Merge-DiscoveredRecord -Registry $registry -Record $record -CoverageComplete:$CoverageComplete
            switch ([string]$outcome.Action) {
                'added' { $script:RecordsAdded++ }
                'updated' { $script:RecordsUpdated++ }
                'coveredByManaged' { $script:RecordsMatched++ }
                default { Add-ScanWarning ('a finding was not recorded: ' + [string]$outcome.Reason) }
            }
            # This merge is the scan's slowest stage on a large registry, and it
            # runs after the walk is finished - without a tick here the progress
            # line would sit frozen (or, before it reported this stage at all,
            # simply disappear) for the rest of the run.
            Show-ScanProgress
        }

        # Demote only what this scan PROVABLY covered and did not find. The merge
        # rejects the claim outright when coverage was incomplete, so a partial
        # scan can never write a live hook off as gone.
        $roots = @($script:ScanRoots.ToArray())
        foreach ($record in @($registry.installs)) {
            if ($null -eq $record -or -not (Test-IsDiscoveredRecord -Record $record)) { continue }
            Show-ScanProgress
            if ($incomingIds.Contains([string]$record.id)) { continue }
            if ([string]$record.status -eq 'notSeen') { continue }
            if (-not (Test-RecordCoveredByScan -Record $record -Roots $roots)) { continue }
            $demoted = $record.PSObject.Copy()
            Set-ObjectProperty -Object $demoted -Name 'status' -Value 'notSeen'
            Set-ObjectProperty -Object $demoted -Name 'statusReason' -Value 'covered by a later scan of the same roots but no longer present'
            Set-ObjectProperty -Object $demoted -Name 'lastScanId' -Value $script:ScanId
            Set-ObjectProperty -Object $demoted -Name 'lastSeenUtc' -Value ([DateTime]::UtcNow.ToString('o'))
            $outcome = Merge-DiscoveredRecord -Registry $registry -Record $demoted -CoverageComplete:$CoverageComplete
            if ([string]$outcome.Action -eq 'updated') { $script:RecordsUpdated++ }
        }

        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registry

        # Read-back verify: a write that cannot be read back as a valid registry
        # is a failed write, not a successful one.
        $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($verify.State -ne 'ok') {
            throw ('registry read-back verification failed: ' + [string]$verify.Reason)
        }
        $script:Persisted = $true
    }
}
