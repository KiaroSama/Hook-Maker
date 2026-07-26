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

    if ($WhatIf) {
        Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'wouldRemove'
        return [pscustomobject]@{ Removed = $true }
    }

    $wrapperBackup = $wrapperPath + '.hookmaker-uninstall-backup-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try { Copy-Item -LiteralPath $wrapperPath -Destination $wrapperBackup -Force } catch { }

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
    try { if (Test-Path -LiteralPath $wrapperBackup) { Remove-Item -LiteralPath $wrapperBackup -Force -ErrorAction SilentlyContinue } } catch { }

    # ---- post-commit cleanup only, best-effort: the wrapper is already
    # correct at this point regardless of whether this succeeds. ----
    if (-not [string]::IsNullOrWhiteSpace($ownRuntimeRoot)) {
        # Both lists come from Resolve-OwnNativeStages and stay index-aligned:
        # entry i's directory is the parent of entry i's persisted stage path.
        # Nothing here is derived from a name.
        $dirsToRemove = New-Object System.Collections.Generic.List[string]
        $ownStagesResolved = @($ownership.Stages)
        $ownDirsResolved = @($ownership.Dirs)
        for ($i = 0; $i -lt $ownStagesResolved.Count; $i++) {
            $stillOwnedElsewhere = @($remainingStages | Where-Object { [System.IO.Path]::GetFullPath($_) -eq $ownStagesResolved[$i] }).Count -gt 0
            if (-not $stillOwnedElsewhere) { [void]$dirsToRemove.Add($ownDirsResolved[$i]) }
        }
        foreach ($dir in @($dirsToRemove.ToArray())) {
            if ((Test-Path -LiteralPath $dir -PathType Container) -and (Test-SafeManagedDir -Dir $dir -Root $ownRuntimeRoot)) {
                try { Remove-Item -LiteralPath $dir -Recurse -Force } catch { }
            }
        }
        Remove-EmptyManagedRoot -Root $ownRuntimeRoot
    }

    Set-ComponentResult -Component 'nativeGit' -Status 'ok'
    return [pscustomobject]@{ Removed = $true }
}

# ---- Utf8-Encoding-Check chain-stage removal (30.md Part D, item 27) -------
# Uninstalling the Utf8-Encoding-Check LIFECYCLE record must also take its
# stage out of the project's managed pre-push chain. The chain belongs to the
# SAME project's Ignore-Rules-Check record (which installed the Utf8 COMPANION
# under its own native runtime root), so this edits THAT record - under exactly
# the ownership proofs Remove-NativeGitComponent applies to its own record:
# marker present, byte-exact wrapper match against the record's persisted
# expectedStages, containment-checked companion dir, wrapper backup + restore
# on failure. Ignore-Rules-Check, Secrets-Check and the preserved user hook are
# never touched. Deliberately scoped to Utf8-Encoding-Check: Secrets-Check's
# stage lifecycle predates this rule and is unchanged.
function Remove-CompanionChainStage {
    if ($FriendlyName -ne 'Utf8-Encoding-Check') { return }
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
        if (@(Get-Field $candNative 'companions') -notcontains 'Utf8-Encoding-Check') { continue }
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
    # The Utf8 stage this record's uninstall owns: the expectedStages entry that
    # is the Utf8 companion script INSIDE the chain owner's runtime root. Proven
    # by path + containment, never by basename alone.
    $utf8Stage = @($expectedStages | Where-Object {
            $full = [System.IO.Path]::GetFullPath($_)
            $full.EndsWith('\Utf8-Encoding-Check\Utf8-Encoding-Check.ps1', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-PathContainedIn -ChildPath $full -ParentPath $chainRuntimeRoot)
        })
    if ($utf8Stage.Count -ne 1) {
        Set-ComponentResult -Component 'chainStage' -Status 'manualRepair' -ReasonCode 'chainStageUnproven' `
            -Message ('expected exactly one contained Utf8-Encoding-Check stage in the chain owner''s expectedStages, found ' + $utf8Stage.Count)
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
    if ($WhatIf) {
        Set-ComponentResult -Component 'chainStage' -Status 'ok' -ReasonCode 'wouldRemove'
        return
    }

    $remainingStages = @($expectedStages | Where-Object { $_ -ne $utf8Stage[0] })
    $remainingCompanions = @(@(Get-Field $chainNative 'companions') | Where-Object { [string]$_ -ne 'Utf8-Encoding-Check' } | ForEach-Object { [string]$_ })
    $wrapperBackup = $wrapperPath + '.hookmaker-chainstage-backup-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Copy-Item -LiteralPath $wrapperPath -Destination $wrapperBackup -Force
    try {
        # 1) Wrapper first, so the chain never references a script that is gone.
        $newBody = New-PrePushWrapperBody -ManagedScripts $remainingStages
        [System.IO.File]::WriteAllText($wrapperPath, $newBody, $Utf8NoBom)
        # 2) The companion runtime dir, containment-proven against the OWNER's root.
        $utf8Dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($utf8Stage[0]))
        if ((Test-Path -LiteralPath $utf8Dir -PathType Container) -and (Test-SafeManagedDir -Dir $utf8Dir -Root $chainRuntimeRoot)) {
            Remove-Item -LiteralPath $utf8Dir -Recurse -Force
        }
        # 3) The chain owner's record, under the registry lock, so its integrity
        #    check keeps matching what is actually installed.
        $ignoreId = [string]$ignoreRecord.id
        $chainSave = Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -eq 'corrupt') { return [pscustomobject]@{ Ok = $false; Warning = ('registry is unreadable: ' + [string]$state.Reason) } }
            $liveRegistry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
            $liveList = @($liveRegistry.installs)
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
            Save-InstallRegistry -ToolRoot $ToolRoot -Registry $liveRegistry
            $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($verify.State -ne 'ok') { return [pscustomobject]@{ Ok = $false; Warning = ('registry did not read back cleanly: ' + [string]$verify.Reason) } }
            return [pscustomobject]@{ Ok = $true; Warning = '' }
        }
        if (-not $chainSave.Ok) { throw ('chain-owner record update failed: ' + [string]$chainSave.Warning) }
        Remove-Item -LiteralPath $wrapperBackup -Force -ErrorAction SilentlyContinue
        Set-ComponentResult -Component 'chainStage' -Status 'ok'
    }
    catch {
        # Roll the wrapper back to the proven pre-removal bytes; the companion
        # dir (if already removed) is re-created by the next install/update, and
        # the failure keeps the record retained for a retry.
        try { Copy-Item -LiteralPath $wrapperBackup -Destination $wrapperPath -Force } catch { }
        Remove-Item -LiteralPath $wrapperBackup -Force -ErrorAction SilentlyContinue
        Set-ComponentResult -Component 'chainStage' -Status 'failed' -ReasonCode 'chainStageRemovalFailed' -Message ([string]$_.Exception.Message)
    }
}