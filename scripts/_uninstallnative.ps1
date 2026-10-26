# ---------------------------------------------------------------------------
# Native Git pre-push uninstall - split out of Uninstall-Hook.ps1.
#
# ONE responsibility: take stages out of a project's managed pre-push chain.
# Both functions edit the SAME artifact - the generated wrapper in
# .git\hooks\pre-push - under the SAME ownership proof (marker present AND a
# byte-exact match against a wrapper rebuilt from the owning record's persisted
# expectedStages) and the same wrapper backup/restore on failure.
# Remove-NativeGitComponent handles the record's OWN chain;
# Remove-CompanionChainStage handles the stage this record's uninstall owns
# inside ANOTHER record's chain. Nothing else in the uninstaller touches a Git
# hook, so this is the whole native-integration surface in one place.
#
# DOT-SOURCED, not imported: these functions read $record, $registry,
# $FriendlyName, $ToolRoot, $Utf8NoBom, $WhatIf and $script:PrePushMarker from
# the including scope exactly as they did when they lived inline. NOT standalone -
# it must be dot-sourced after Test-SafeManagedDir and Remove-EmptyManagedRoot
# exist, and after _installplan.ps1 (New-PrePushWrapperBody,
# Compare-PrePushWrapperBody, Test-PathContainedIn) and _installlib.ps1
# (Invoke-WithInstallRegistryLock, Get-NativePrePushSourceManifest,
# Read-InstallRegistryState, Save-InstallRegistry) are loaded.
# ---------------------------------------------------------------------------

# ---- native Git pre-push integration ----------------------------------------

# Only ever touches the wrapper when it is PROVEN to still be the exact Hook
# Maker managed wrapper (marker present AND byte-exact match against a wrapper
# rebuilt from the record's own recorded stage list). Anything else - hand
# edited, replaced, or otherwise drifted - stops with manualRepair and
# preserves every file untouched.
function Remove-NativeGitComponent {
    if ($WhatIf -or $null -eq (Get-Field $record 'nativeGit') -or (Get-Field $record.nativeGit 'managed') -ne $true) {
        return Remove-NativeGitComponentCore
    }
    $wrapper = [string](Get-Field $record.nativeGit 'wrapperPath')
    try {
        Assert-UninstallRegularPath $wrapper
        return Invoke-WithResourceLock -ResourcePath $wrapper -Action {
            $live = Read-InstallRegistryState $ToolRoot
            if ($live.State -ne 'ok') { throw 'Registry unavailable before native removal.' }
            $selected = @($live.Registry.installs | Where-Object { [string]$_.id -ceq $RecordId })
            if ($selected.Count -ne 1 -or ($selected[0].nativeGit | ConvertTo-Json -Depth 30 -Compress) -cne ($record.nativeGit | ConvertTo-Json -Depth 30 -Compress)) {
                throw 'Native installation changed before removal.'
            }
            return Remove-NativeGitComponentCore
        }
    }
    catch {
        Set-ComponentResult -Component 'nativeGit' -Status 'failed' -ReasonCode 'nativeCleanupIncomplete' -Message $_.Exception.Message
        return [pscustomobject]@{ Removed = $false }
    }
}

function Remove-NativeGitComponentCore {
    if ($null -eq $record.PSObject.Properties['nativeGit'] -or $null -eq $record.nativeGit -or
        $null -eq $record.nativeGit.PSObject.Properties['managed'] -or $record.nativeGit.managed -ne $true) {
        Set-ComponentResult -Component 'nativeGit' -Status 'skipped' -ReasonCode 'notApplicable'
        return [pscustomobject]@{ Removed = $true }
    }
    $native = $record.nativeGit
    $wrapperPath = [string]$native.wrapperPath

    # Everything this record owns on disk is PROVEN from its own persisted
    # expectedStages - never rebuilt from FriendlyName. Computed read-only, up
    # front, so the "wrapper already gone" idempotency proof below, the
    # remaining-stage split and the cleanup step all share one definition of
    # "ours". A record whose name and persisted stages disagree is refused
    # outright rather than being allowed to compute a delete target from its
    # name.
    $ownRuntimeRoot = [string]$native.runtimeRoot
    $ownership = Resolve-OwnNativeStages -Native $native -OwnRuntimeRoot $ownRuntimeRoot
    if (-not $ownership.Ok) {
        Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'nativeOwnershipUnproven' `
            -Message ([string]$ownership.Reason)
        return [pscustomobject]@{ Removed = $false }
    }
    $ownStageDirs = @($ownership.Dirs)
    if ($Complete) {
        Assert-UninstallRegularPath $wrapperPath
        foreach ($directory in $ownStageDirs) { Assert-UninstallTree $directory }
    }
    $anyOwnedArtifactRemains = @($ownStageDirs | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0

    if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        if ($anyOwnedArtifactRemains) {
            # The wrapper is gone, but this record's own managed native runtime
            # is still on disk - a genuinely partial state. Idempotent success
            # is only safe to claim when NOTHING of ours is left behind; here
            # something is, so retain the record and stop rather than silently
            # abandoning those artifacts.
            Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'wrapperMissingArtifactsRemain' `
                -Message 'the pre-push wrapper is gone but managed native runtime artifacts for this record still exist on disk'
            return [pscustomobject]@{ Removed = $false }
        }
        Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'alreadyRemoved'
        return [pscustomobject]@{ Removed = $true }
    }

    # wrapperPath must live directly inside the record's own recorded Git hooks
    # path (when the record has one - it does for every record written by the
    # current installer). A mismatch means wrapperPath cannot be trusted to
    # mean what the record claims, so this stops here rather than trusting it.
    if ($null -ne $native.PSObject.Properties['hooksPath'] -and -not [string]::IsNullOrWhiteSpace([string]$native.hooksPath)) {
        $expectedParent = [System.IO.Path]::GetFullPath([string]$native.hooksPath)
        $actualParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $wrapperPath))
        if (-not [string]::Equals($expectedParent, $actualParent, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'wrapperPathHooksPathMismatch' `
                -Message 'wrapperPath does not live in the record''s own recorded Git hooks path; ownership cannot be proven safely'
            return [pscustomobject]@{ Removed = $false }
        }
    }

    $body = [System.IO.File]::ReadAllText($wrapperPath)
    if (-not $body.Contains($script:PrePushMarker)) {
        # A file exists at wrapperPath but carries no Hook Maker marker. This is
        # NOT "no longer managed" - ownership of whatever now occupies this
        # path is UNKNOWN (a user or another tool may have replaced it). Stop
        # and preserve every file rather than guessing this away as success.
        Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'wrapperReplacedOrOwnershipUnknown' `
            -Message 'a file exists at the recorded wrapper path but does not carry the Hook Maker marker; ownership cannot be proven safely'
        return [pscustomobject]@{ Removed = $false }
    }

    $expectedStages = @()
    if ($null -ne $native.PSObject.Properties['expectedStages'] -and $null -ne $native.expectedStages) {
        $expectedStages = @($native.expectedStages | ForEach-Object { [string]$_ })
    }
    $expectedBody = New-PrePushWrapperBody -ManagedScripts $expectedStages
    if (-not (Compare-PrePushWrapperBody -Expected $expectedBody -Actual $body)) {
        Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'wrapperDrifted' `
            -Message 'the pre-push wrapper does not match its expected content; ownership cannot be proven safely'
        return [pscustomobject]@{ Removed = $false }
    }

    # Stages this record itself owns (already PROVEN against its persisted
    # expectedStages by Resolve-OwnNativeStages above). Anything else in
    # expectedStages belongs to some other logical owner and is left running.
    $ownStageSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($stage in @($ownership.Stages)) { [void]$ownStageSet.Add($stage) }
    $remainingStages = @($expectedStages | Where-Object { -not $ownStageSet.Contains([System.IO.Path]::GetFullPath($_)) })

    $previousPath = [string](Get-Field $native 'previousHookPath')
    $previousPreserved = (Get-Field $native 'previousHookPreserved') -eq $true
    if ($Complete -and $previousPreserved) {
        if ((Get-CanonicalPathOrNull $previousPath) -ine ($wrapperPath + '.hookmaker-existing')) { throw 'Preserved native hook path is not the recorded wrapper sidecar.' }
        Assert-UninstallRegularPath $previousPath
        if (-not (Test-Path -LiteralPath $previousPath -PathType Leaf)) { throw 'Preserved user hook is missing; no native removal performed.' }
    }
    if ($WhatIf) {
        Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'wouldRemove'
        return [pscustomobject]@{ Removed = $true }
    }
    $wrapperBackup = $wrapperPath + '.hookmaker-uninstall-backup-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    if ($Complete) {
        $wrapperBackup = $wrapperPath + '.hookmaker-uninstall-backup-' + $RecordId
        Assert-UninstallRegularPath $wrapperBackup
        $wrapperPreimage = Read-UninstallSnapshot $wrapperPath
        if (-not (Compare-PrePushWrapperBody -Expected $expectedBody -Actual $wrapperPreimage.Raw)) { throw 'Native wrapper changed before backup; no removal performed.' }
        if (Test-Path -LiteralPath $wrapperBackup) {
            if ((Read-UninstallSnapshot $wrapperBackup).Hash -cne $wrapperPreimage.Hash) { throw 'Native recovery backup differs from the proven wrapper; manual repair required.' }
        }
        else { [IO.File]::Copy($wrapperPath, $wrapperBackup, $false) }
        if ((Read-UninstallSnapshot $wrapperBackup).Hash -cne $wrapperPreimage.Hash -or (Get-FileSha256 $wrapperPath) -cne $wrapperPreimage.Hash) {
            throw 'Native wrapper preimage changed before removal.'
        }
    }
    else { try { Copy-Item -LiteralPath $wrapperPath -Destination $wrapperBackup -Force } catch { } }

    $wrapperOk = $true
    $wrapperError = ''
    try {
        if ($remainingStages.Count -gt 0) {
            # Other managed stages remain: regenerate from the ONE canonical
            # generator - never hand-edited - so order/stdin-buffering/
            # fail-closed semantics stay exactly correct.
            $newBody = New-PrePushWrapperBody -ManagedScripts $remainingStages
            [System.IO.File]::WriteAllText($wrapperPath, $newBody, $Utf8NoBom)
        }
        else {
            $previousPath = ''
            if ($null -ne $native.PSObject.Properties['previousHookPath']) { $previousPath = [string]$native.previousHookPath }
            $previousPreserved = ($null -ne $native.PSObject.Properties['previousHookPreserved'] -and $native.previousHookPreserved -eq $true)
            if ($previousPreserved -and -not [string]::IsNullOrWhiteSpace($previousPath) -and (Test-Path -LiteralPath $previousPath -PathType Leaf)) {
                # Restore the user's own hook BYTE-FOR-BYTE: a move, never a
                # copy-then-rewrite, so binary content / missing trailing
                # newline survive exactly.
                Remove-Item -LiteralPath $wrapperPath -Force
                Move-Item -LiteralPath $previousPath -Destination $wrapperPath -Force
            }
            else {
                # Nothing to restore (never preserved, or it has since
                # vanished) - just remove the now-empty managed wrapper.
                Remove-Item -LiteralPath $wrapperPath -Force
            }
        }
    }
    catch { $wrapperOk = $false; $wrapperError = $_.Exception.Message }

    if (-not $wrapperOk) {
        try { if (Test-Path -LiteralPath $wrapperBackup) { Copy-Item -LiteralPath $wrapperBackup -Destination $wrapperPath -Force } } catch { }
        Set-ComponentResult -Component 'nativeGit' -Status 'failed' -ReasonCode 'wrapperCommitFailed' -Message $wrapperError
        return [pscustomobject]@{ Removed = $false }
    }
    if (-not $Complete) { try { if (Test-Path -LiteralPath $wrapperBackup) { Remove-Item -LiteralPath $wrapperBackup -Force -ErrorAction SilentlyContinue } } catch { } }

    # Complete mode keeps the wrapper preimage until owned cleanup is verified;
    # ordinary mode retains its existing best-effort runtime cleanup contract.
    try {
        if (-not [string]::IsNullOrWhiteSpace($ownRuntimeRoot)) {
            foreach ($dir in @($ownership.Dirs)) {
                if ((Test-Path -LiteralPath $dir -PathType Container) -and (Test-SafeManagedDir -Dir $dir -Root $ownRuntimeRoot)) {
                    try {
                        if ($Complete) { Assert-UninstallTree $dir }
                        Remove-Item -LiteralPath $dir -Recurse -Force
                        if ($Complete -and (Test-Path -LiteralPath $dir)) { throw 'Owned native runtime remains after cleanup.' }
                    }
                    catch { if ($Complete) { throw } }
                }
            }
            Remove-EmptyManagedRoot -Root $ownRuntimeRoot
        }
        if ($Complete -and (Test-Path -LiteralPath $wrapperBackup)) { Remove-Item -LiteralPath $wrapperBackup -Force -ErrorAction Stop }
    }
    catch {
        $cleanupMessage = $_.Exception.Message
        try {
            if ($remainingStages.Count -eq 0 -and $previousPreserved -and (Test-Path -LiteralPath $wrapperPath)) {
                if (Test-Path -LiteralPath $previousPath) { throw 'User hook recovery sidecar already exists.' }
                Move-Item -LiteralPath $wrapperPath -Destination $previousPath -ErrorAction Stop
            }
            Copy-Item -LiteralPath $wrapperBackup -Destination $wrapperPath -Force -ErrorAction Stop
        }
        catch { $cleanupMessage += '; retained backup requires manual wrapper recovery' }
        Set-ComponentResult -Component 'nativeGit' -Status 'failed' -ReasonCode 'nativeCleanupIncomplete' -Message $cleanupMessage
        return [pscustomobject]@{ Removed = $false }
    }
    Set-ComponentResult -Component 'nativeGit' -Status 'ok'
    return [pscustomobject]@{ Removed = $true }
}

# Ordinary removal retains the existing Utf8 chain-stage contract. Complete
# removal also retires a selected Secrets companion: otherwise its native
# execution would survive the selected lifecycle registration. The chain owner,
# remaining stages and preserved user hook remain independently owned.
function Remove-CompanionChainStage {
    if ($WhatIf -or ($FriendlyName -ne 'Utf8-Encoding-Check' -and -not ($Complete -and $FriendlyName -eq 'Secrets-Check'))) { return Remove-CompanionChainStageCore }
    $state = Read-InstallRegistryState $ToolRoot
    if ($state.State -ne 'ok') { throw 'Registry unavailable before native companion removal.' }
    $registry = $state.Registry
    $owners = @($registry.installs | Where-Object {
        [string](Get-Field $_ 'friendlyName') -ceq 'Ignore-Rules-Check' -and
        [string](Get-Field $_ 'targetProjectRoot') -ieq $RecordTargetProjectRoot -and
        (Get-Field (Get-Field $_ 'nativeGit') 'managed') -eq $true -and
        @(Get-Field (Get-Field $_ 'nativeGit') 'companions') -contains $FriendlyName
    })
    if ($owners.Count -eq 0) { return Remove-CompanionChainStageCore }
    if ($owners.Count -ne 1) { throw 'Multiple native companion owners require manual repair.' }
    $wrapper = [string]$owners[0].nativeGit.wrapperPath
    Assert-UninstallRegularPath $wrapper
    Invoke-WithResourceLock -ResourcePath $wrapper -Action {
        $live = Read-InstallRegistryState $ToolRoot
        if ($live.State -ne 'ok') { throw 'Registry unavailable under native companion lock.' }
        $owner = @($live.Registry.installs | Where-Object { [string]$_.id -ceq [string]$owners[0].id })
        if ($owner.Count -ne 1 -or ($owner[0].nativeGit | ConvertTo-Json -Depth 30 -Compress) -cne ($owners[0].nativeGit | ConvertTo-Json -Depth 30 -Compress)) { throw 'Native companion owner changed before removal.' }
        $registry = $live.Registry
        Remove-CompanionChainStageCore
    } | Out-Null
}

function Remove-CompanionChainStageCore {
    if ($FriendlyName -ne 'Utf8-Encoding-Check' -and -not ($Complete -and $FriendlyName -eq 'Secrets-Check')) { return }
    $projectRoot = ''
    if ($null -ne $record.PSObject.Properties['targetProjectRoot']) { $projectRoot = [string]$record.targetProjectRoot }
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        Set-ComponentResult -Component 'chainStage' -Status 'skipped' -ReasonCode 'notApplicable'
        return
    }
    # The chain owner: the same-project managed Ignore-Rules-Check record whose
    # companions list actually names this hook. None -> nothing to remove.
    $ignoreRecord = $null
    foreach ($candidate in @($registry.installs)) {
        if ($null -eq $candidate) { continue }
        if ([string](Get-Field $candidate 'friendlyName') -ne 'Ignore-Rules-Check') { continue }
        $candRoot = [string](Get-Field $candidate 'targetProjectRoot')
        if ([string]::IsNullOrWhiteSpace($candRoot)) { continue }
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($candRoot), [System.IO.Path]::GetFullPath($projectRoot), [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $candNative = Get-Field $candidate 'nativeGit'
        if ($null -eq $candNative -or $null -eq $candNative.PSObject.Properties['managed'] -or $candNative.managed -ne $true) { continue }
        if (@(Get-Field $candNative 'companions') -notcontains $FriendlyName) { continue }
        $ignoreRecord = $candidate
        break
    }
    if ($null -eq $ignoreRecord) {
        Set-ComponentResult -Component 'chainStage' -Status 'skipped' -ReasonCode 'notApplicable'
        return
    }
    $chainNative = $ignoreRecord.nativeGit
    $wrapperPath = [string]$chainNative.wrapperPath
    $chainRuntimeRoot = [string]$chainNative.runtimeRoot
    $expectedStages = @()
    if ($null -ne $chainNative.PSObject.Properties['expectedStages'] -and $null -ne $chainNative.expectedStages) {
        $expectedStages = @($chainNative.expectedStages | ForEach-Object { [string]$_ })
    }
    # The selected companion must be an exact persisted stage inside its owner.
    $utf8Stage = @($expectedStages | Where-Object {
            $full = [System.IO.Path]::GetFullPath($_)
            $full.EndsWith(('\' + $FriendlyName + '\' + $FriendlyName + '.ps1'), [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-PathContainedIn -ChildPath $full -ParentPath $chainRuntimeRoot)
        })
    if ($utf8Stage.Count -ne 1) {
        Set-ComponentResult -Component 'chainStage' -Status 'manualRepair' -ReasonCode 'chainStageUnproven' `
            -Message ('expected exactly one contained selected companion in the chain owner''s expectedStages, found ' + $utf8Stage.Count)
        return
    }
    if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        Set-ComponentResult -Component 'chainStage' -Status 'manualRepair' -ReasonCode 'chainWrapperMissing' `
            -Message 'the chain owner records a managed wrapper but none exists at its recorded path'
        return
    }
    $body = [System.IO.File]::ReadAllText($wrapperPath)
    if (-not $body.Contains($script:PrePushMarker)) {
        Set-ComponentResult -Component 'chainStage' -Status 'manualRepair' -ReasonCode 'chainWrapperReplacedOrOwnershipUnknown' `
            -Message 'the file at the chain wrapper path does not carry the Hook Maker marker; ownership cannot be proven safely'
        return
    }
    $expectedBody = New-PrePushWrapperBody -ManagedScripts $expectedStages
    if (-not (Compare-PrePushWrapperBody -Expected $expectedBody -Actual $body)) {
        Set-ComponentResult -Component 'chainStage' -Status 'manualRepair' -ReasonCode 'chainWrapperDrifted' `
            -Message 'the chain wrapper does not match its expected content; ownership cannot be proven safely'
        return
    }
    $utf8Dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($utf8Stage[0]))
    if ($Complete) {
        Assert-UninstallRegularPath $wrapperPath
        Assert-UninstallTree $utf8Dir
        if (-not (Test-SafeManagedDir -Dir $utf8Dir -Root $chainRuntimeRoot)) { throw 'Selected native companion directory is unsafe.' }
    }
    if ($WhatIf) {
        Set-ComponentResult -Component 'chainStage' -Status 'ok' -ReasonCode 'wouldRemove'
        return
    }

    $remainingStages = @($expectedStages | Where-Object { $_ -ne $utf8Stage[0] })
    $remainingCompanions = @(@(Get-Field $chainNative 'companions') | Where-Object { [string]$_ -ne $FriendlyName } | ForEach-Object { [string]$_ })
    $wrapperBackup = $wrapperPath + '.hookmaker-chainstage-backup-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    if ($Complete) {
        $wrapperBackup = $wrapperPath + '.hookmaker-chainstage-backup-' + $RecordId
        Assert-UninstallRegularPath $wrapperBackup
        if (Test-Path -LiteralPath $wrapperBackup) {
            if ((Get-FileSha256 $wrapperBackup) -cne (Get-FileSha256 $wrapperPath)) { throw 'Native companion recovery preimage differs; manual repair required.' }
        }
        else { [IO.File]::Copy($wrapperPath, $wrapperBackup, $false) }
        $snapshot = Read-UninstallSnapshot $wrapperPath
        if (-not (Compare-PrePushWrapperBody -Expected $expectedBody -Actual $snapshot.Raw) -or (Get-FileSha256 $wrapperBackup) -cne $snapshot.Hash) { throw 'Native companion changed before removal.' }
    }
    else { Copy-Item -LiteralPath $wrapperPath -Destination $wrapperBackup -Force }
    $chainSaved = $false
    try {
        # 1) Wrapper first, so the chain never references a script that is gone.
        $newBody = New-PrePushWrapperBody -ManagedScripts $remainingStages
        [System.IO.File]::WriteAllText($wrapperPath, $newBody, $Utf8NoBom)
        # 2) The companion runtime dir, containment-proven against the OWNER's root.
        $utf8Dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($utf8Stage[0]))
        if ((Test-Path -LiteralPath $utf8Dir -PathType Container) -and (Test-SafeManagedDir -Dir $utf8Dir -Root $chainRuntimeRoot)) {
            Remove-Item -LiteralPath $utf8Dir -Recurse -Force
        }
        if ($Complete -and (Test-Path -LiteralPath $utf8Dir)) { throw 'Selected native companion remains after cleanup.' }
        if ($Complete) {
            # Retire recovery before publishing the shortened owner: otherwise a
            # retry no longer finds this companion and can abandon its backup.
            $recovery = Join-Path (Get-InstallStateDirectory $ToolRoot) 'uninstall-recovery'
            Assert-UninstallRegularPath $recovery
            [void][IO.Directory]::CreateDirectory($recovery)
            $retiredBackup = Join-Path $recovery ($RecordId+'-native-'+[guid]::NewGuid().ToString('N')+'.bak')
            [IO.File]::Move($wrapperBackup, $retiredBackup)
            $wrapperBackup = $retiredBackup
        }
        # 3) The chain owner's record, under the registry lock, so its integrity
        #    check keeps matching what is actually installed.
        $ignoreId = [string]$ignoreRecord.id
        $chainSave = Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -eq 'corrupt') { return [pscustomobject]@{ Ok = $false; Warning = ('registry is unreadable: ' + [string]$state.Reason) } }
            $liveRegistry = ConvertTo-InstallRegistryCurrent -Registry (Read-InstallRegistryState $ToolRoot -NoCache).Registry
            $registryPreimage = (Read-InstallRegistryState $ToolRoot -NoCache).Registry
            $liveList = @($liveRegistry.installs)
            $matched = @($liveList | Where-Object { [string]$_.id -ceq $ignoreId })
            if ($matched.Count -ne 1 -or ($matched[0].nativeGit | ConvertTo-Json -Depth 30 -Compress) -cne ($chainNative | ConvertTo-Json -Depth 30 -Compress)) { throw 'Native chain owner changed before persistence.' }
            for ($i = 0; $i -lt $liveList.Count; $i++) {
                $live = $liveList[$i]
                if ($null -eq $live -or $null -eq $live.PSObject.Properties['id'] -or [string]$live.id -ne $ignoreId) { continue }
                $liveNative = $live.nativeGit
                Set-ObjectProperty -Object $liveNative -Name 'expectedStages' -Value @($remainingStages)
                Set-ObjectProperty -Object $liveNative -Name 'companions' -Value @($remainingCompanions)
                Set-ObjectProperty -Object $liveNative -Name 'wrapperBodyHash' -Value (Get-ShortHash $newBody)
                $ignoreSource = Join-Path $ToolRoot 'hooks\Ignore-Rules-Check\Ignore-Rules-Check.ps1'
                Set-ObjectProperty -Object $liveNative -Name 'sourceManifest' -Value @(
                    Get-NativePrePushSourceManifest -ToolRoot $ToolRoot -PrimaryFriendlyName 'Ignore-Rules-Check' `
                        -PrimaryHookScript $ignoreSource -PrimarySourceDir (Split-Path -Parent $ignoreSource) -Companions $remainingCompanions)
                Set-ObjectProperty -Object $live -Name 'lastUpdatedUtc' -Value ([DateTime]::UtcNow.ToString('o'))
                break
            }
            $liveRegistry.installs = $liveList
            try {
                Save-InstallRegistry -ToolRoot $ToolRoot -Registry $liveRegistry
                $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
                if ($verify.State -ne 'ok') { throw ('registry did not read back cleanly: ' + [string]$verify.Reason) }
            }
            catch {
                $failure = $_.Exception.Message
                try { Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registryPreimage }
                catch { throw ('Native chain persistence and recovery failed: ' + $failure) }
                throw ('Native chain persistence failed; registry restored: ' + $failure)
            }
            return [pscustomobject]@{ Ok = $true; Warning = '' }
        }
        if (-not $chainSave.Ok) { throw ('chain-owner record update failed: ' + [string]$chainSave.Warning) }
        $chainSaved = $true
        try { Remove-Item -LiteralPath $wrapperBackup -Force -ErrorAction Stop }
        catch {
            # The owner already committed the shortened chain. Recovery evidence
            # must leave the active hooks directory before success can be claimed.
            $recovery = Join-Path (Get-InstallStateDirectory $ToolRoot) 'uninstall-recovery'
            Assert-UninstallRegularPath $recovery
            [void][IO.Directory]::CreateDirectory($recovery)
            Move-Item -LiteralPath $wrapperBackup -Destination (Join-Path $recovery ($RecordId+'-native-'+[guid]::NewGuid().ToString('N')+'.bak')) -ErrorAction Stop
        }
        Set-ComponentResult -Component 'chainStage' -Status 'ok'
    }
    catch {
        # Roll the wrapper back to the proven pre-removal bytes; the companion
        # dir (if already removed) is re-created by the next install/update, and
        # the failure keeps the record retained for a retry.
        $failure = $_.Exception.Message
        if (-not $chainSaved) {
            try { Copy-Item -LiteralPath $wrapperBackup -Destination $wrapperPath -Force -ErrorAction Stop }
            catch { $failure += '; original wrapper backup retained for manual recovery' }
        }
        Set-ComponentResult -Component 'chainStage' -Status 'failed' -ReasonCode 'chainStageRemovalFailed' -Message $failure
    }
}