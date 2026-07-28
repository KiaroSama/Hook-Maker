# ---------------------------------------------------------------------------
# Kiro per-hook-file uninstall - split out of Uninstall-Hook.ps1.
#
# ONE responsibility: take this record's registration off the 'perHookFile'
# client. Claude and Codex share ONE settings document nobody owns, so removal
# there is per-handler-entry inside a foreign file; Kiro instead owns its OWN
# JSON file(s) under <scope root>\.kiro\hooks, which a user may also hand-add
# entries to - so removal here is entry-level, and the file itself only goes
# once nothing but ours was ever in it. That model is structurally unlike the
# shared clients', which is why it is reviewable on its own.
#
# DOT-SOURCED, not imported: Uninstall-Hook.ps1 dot-sources this into its own
# scope, so these functions read $record, $FriendlyName and $WhatIf from the
# including scope exactly as they did when they lived inline. NOT standalone -
# it must be dot-sourced after Backup-SettingsFile, Write-SettingsFileAtomic
# and Remove-EmptyManagedRoot exist, and after _installkiro.ps1 (reached via
# _installplan.ps1) has supplied Test-KiroManagedFile / Test-KiroManagedFileName /
# ConvertTo-KiroSlug / Get-KiroManagedNamePrefix / Get-KiroEntryField, plus
# Get-KiroRecordRegistrationDirectory from _installlib.ps1.
# ---------------------------------------------------------------------------

# ---- Kiro: the per-hook-file client ----------------------------------------
# Claude and Codex register inside ONE shared settings document, so ownership
# there is per-handler-entry. Kiro is 'perHookFile': this installation owns its
# OWN JSON file(s) under <scope root>\.kiro\hooks - and a user can hand-add
# entries to one of them, which is exactly what the install side's
# Merge-KiroManagedEntries is built to preserve. Removal is therefore
# entry-level, not file-level: our entries come off, foreign entries survive as
# the SAME parsed objects (nothing re-derives them), and the file itself is
# deleted only once nothing but ours was ever in it.
#
# Nothing below is derived from a filename, a friendly name, an event or an
# array index. A file is touched only when all of this is proven, right now:
#   * it sits in the exact .kiro\hooks directory this record's own scope
#     resolves to - the analogue of Get-ExpectedSettingsPath for the shared
#     clients, and what stops a drifted registrationPath aiming elsewhere;
#   * its leaf matches Test-KiroManagedFileName;
#   * Test-KiroManagedFile classifies it 'managed' for THIS record's managed id;
#   * every entry that classification calls ours is also named in the record's
#     own persisted managedEntryNames.
# Anything else - foreign, empty, unreadable, schema-unknown, or holding an
# entry this record never recorded - is left completely untouched and reported
# as manualRepair, so the record is retained instead of a guess being acted on.

function Get-KiroSubrecordValue {
    param([Parameter(Mandatory = $true)]$Subrecord, [Parameter(Mandatory = $true)][string]$Name)
    $property = $Subrecord.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# Everything that must hold about the persisted kiro subrecord BEFORE anything
# is staged or removed. Returns a verdict; mutates nothing.
function Resolve-KiroOwnership {
    param([Parameter(Mandatory = $true)]$Subrecord)

    function New-KiroOwnershipFailure {
        param([string]$Reason)
        return [pscustomobject]@{
            Ok = $false; Reason = $Reason
            RegistrationDir = ''; HookDir = ''; RuntimeRoot = ''; ManagedId = ''; EntryNames = @()
        }
    }

    # A kiro subrecord that does not declare the per-hook-file shape cannot be
    # interpreted: the whole removal model below depends on it, and guessing
    # would mean either rewriting a shared document as if it were ours or
    # deleting a file whose ownership model we never verified.
    $registrationKind = [string](Get-KiroSubrecordValue -Subrecord $Subrecord -Name 'registrationKind')
    if ($registrationKind -cne 'perHookFile') {
        return (New-KiroOwnershipFailure ("kiro.registrationKind is '" + $registrationKind + "' rather than 'perHookFile', so this record's registration shape cannot be proven"))
    }
    foreach ($field in @('runtimeRoot', 'runtimeScript', 'command')) {
        if (-not (Test-RequiredStringField (Get-KiroSubrecordValue -Subrecord $Subrecord -Name $field))) {
            return (New-KiroOwnershipFailure ('kiro.' + $field + ' is missing or is not a genuine non-empty string'))
        }
    }

    # ---- the runtime directory to remove, proven exactly as the shared
    # clients prove theirs: from the persisted runtimeScript, never rebuilt by
    # joining runtimeRoot to a friendly name.
    $canonicalRuntimeRoot = Get-CanonicalPathOrNull ([string]$Subrecord.runtimeRoot)
    $canonicalRuntimeScript = Get-CanonicalPathOrNull ([string]$Subrecord.runtimeScript)
    if ($null -eq $canonicalRuntimeRoot -or $null -eq $canonicalRuntimeScript) {
        return (New-KiroOwnershipFailure 'kiro has a runtime path that cannot be canonicalized')
    }
    if (-not (Test-PathContainedIn -ChildPath $canonicalRuntimeScript -ParentPath $canonicalRuntimeRoot)) {
        return (New-KiroOwnershipFailure 'kiro.runtimeScript is outside runtimeRoot')
    }
    $hookDir = Split-Path -Parent $canonicalRuntimeScript
    if ([string]::Equals($hookDir, $canonicalRuntimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PathContainedIn -ChildPath $hookDir -ParentPath $canonicalRuntimeRoot)) {
        return (New-KiroOwnershipFailure 'kiro.runtimeScript parent is the runtime root itself or lies outside it')
    }
    if (-not [string]::Equals((Split-Path -Leaf $hookDir), $FriendlyName, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Split-Path -Leaf $canonicalRuntimeScript), ($FriendlyName + '.ps1'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return (New-KiroOwnershipFailure ('kiro.runtimeScript parent does not match the managed hook directory for friendlyName ''' + $FriendlyName + ''''))
    }

    # ---- the ONE directory this record's own scope may register in. Derived
    # by the same helper the updater's drift check uses, so the two gates can
    # never disagree about where this record's registration lives.
    $expectedDir = $null
    try { $expectedDir = Get-CanonicalPathOrNull (Get-KiroRecordRegistrationDirectory -Record $record) }
    catch { return (New-KiroOwnershipFailure ([string]$_.Exception.Message)) }
    if ($null -eq $expectedDir) {
        return (New-KiroOwnershipFailure 'the .kiro hooks directory for this record''s scope cannot be canonicalized')
    }
    # The persisted path is cross-checked against that directory rather than
    # trusted as the place to act on. It may legitimately be the directory or a
    # file inside it; anything else means the record drifted and nothing is
    # touched.
    $persistedRegistration = [string](Get-KiroSubrecordValue -Subrecord $Subrecord -Name 'registrationPath')
    if (-not [string]::IsNullOrWhiteSpace($persistedRegistration)) {
        $canonicalPersisted = Get-CanonicalPathOrNull $persistedRegistration
        if ($null -eq $canonicalPersisted) {
            return (New-KiroOwnershipFailure 'kiro.registrationPath cannot be canonicalized')
        }
        $persistedDir = $canonicalPersisted
        if (Test-KiroManagedFileName -Path $canonicalPersisted) { $persistedDir = Split-Path -Parent $canonicalPersisted }
        if (-not [string]::Equals($persistedDir, $expectedDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (New-KiroOwnershipFailure 'kiro.registrationPath is not the .kiro hooks directory for this record''s scope')
        }
    }

    # ---- the persisted entry identities. Without them no entry inside a file
    # that may also hold the user's own hooks can be proven ours, so an empty
    # list is a refusal, never a licence to remove whatever looks familiar.
    $entryNames = @()
    $persistedNames = Get-KiroSubrecordValue -Subrecord $Subrecord -Name 'managedEntryNames'
    if ($null -ne $persistedNames) {
        $entryNames = @(@($persistedNames) | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($entryNames.Count -eq 0) {
        return (New-KiroOwnershipFailure 'kiro.managedEntryNames is empty, so no entry inside a shared file can be proven to belong to this installation')
    }

    # The managed id the entries were written with. An explicit persisted value
    # wins; otherwise it is the record id, and either way it must AGREE with the
    # record's own persisted entry names - Get-KiroManagedNamePrefix anchors the
    # id immediately after the fixed 'hookmaker-' prefix, so this is a real
    # check and not a formality.
    $managedId = [string](Get-KiroSubrecordValue -Subrecord $Subrecord -Name 'managedId')
    if ([string]::IsNullOrWhiteSpace($managedId)) { $managedId = [string]$record.id }
    $namePrefix = ''
    try { $namePrefix = Get-KiroManagedNamePrefix -ManagedId $managedId }
    catch { return (New-KiroOwnershipFailure ([string]$_.Exception.Message)) }
    foreach ($entryName in $entryNames) {
        if (-not $entryName.StartsWith($namePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (New-KiroOwnershipFailure ("kiro.managedEntryNames contains '" + $entryName + "', which does not carry this record's own managed identity"))
        }
    }

    return [pscustomobject]@{
        Ok = $true; Reason = ''
        RegistrationDir = $expectedDir
        HookDir         = $hookDir
        RuntimeRoot     = $canonicalRuntimeRoot
        ManagedId       = $managedId
        EntryNames      = @($entryNames)
    }
}

# Every managed entry a fresh classification calls ours must ALSO be named in
# the record's own persisted list. An entry carrying our identity that this
# record never recorded means two installations wrote the same file (or the
# file was hand-edited): ambiguous, so nothing is removed.
function Get-KiroUnrecordedEntryName {
    param([Parameter(Mandatory = $true)]$Classification, [Parameter(Mandatory = $true)][string[]]$EntryNames)
    foreach ($entry in @($Classification.ManagedEntries)) {
        $entryName = [string](Get-KiroEntryField -Entry $entry -Name 'name')
        if (@($EntryNames | Where-Object { $_ -ieq $entryName }).Count -eq 0) { return $entryName }
    }
    return ''
}

function Remove-KiroClientComponent {
    $subrecord = Get-ClientSubrecord -Record $record -Client 'kiro'
    if ($null -eq $subrecord) {
        Set-ComponentResult -Component 'kiro' -Status 'skipped' -ReasonCode 'notInstalled'
        return [pscustomobject]@{ Removed = $true }
    }
    $identity = Resolve-KiroOwnership -Subrecord $subrecord
    if (-not $identity.Ok) {
        Set-ComponentResult -Component 'kiro' -Status 'manualRepair' -ReasonCode 'identityInvalid' -Message $identity.Reason
        return [pscustomobject]@{ Removed = $false }
    }

    # ---- read-only pre-flight over the live directory.
    $candidates = New-Object System.Collections.Generic.List[string]
    $ambiguousDetail = ''
    # Used ONLY to widen caution, never to claim ownership: an unreadable file
    # under this hook's own name shape might be ours, and reporting a clean
    # uninstall while a live registration may still exist would be a false
    # success. It can never cause a deletion.
    $ownNamePrefix = 'hookmaker-' + (ConvertTo-KiroSlug -Text $FriendlyName) + '-'
    foreach ($file in @(Get-ChildItem -LiteralPath $identity.RegistrationDir -File -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-KiroManagedFileName -Path $file.FullName)) { continue }
        $classification = Test-KiroManagedFile -Path $file.FullName -ManagedId $identity.ManagedId
        if ([string]$classification.Reason -eq 'managed') {
            $unrecorded = Get-KiroUnrecordedEntryName -Classification $classification -EntryNames @($identity.EntryNames)
            if ($unrecorded -ne '') {
                $ambiguousDetail = "'" + (Split-Path -Leaf $file.FullName) + "' holds a managed entry ('" + $unrecorded + "') this record never recorded, so its entries cannot be proven to be ours alone"
                break
            }
            [void]$candidates.Add($file.FullName)
            continue
        }
        if (@('invalid-json', 'unexpected-schema', 'unreadable', 'not-a-file') -contains [string]$classification.Reason -and
            (Split-Path -Leaf $file.FullName).StartsWith($ownNamePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ambiguousDetail = "'" + (Split-Path -Leaf $file.FullName) + "' carries this hook's own filename shape but is " + [string]$classification.Reason + ', so whether it is still our registration cannot be established'
            break
        }
    }
    if ($ambiguousDetail -ne '') {
        Set-ComponentResult -Component 'kiro' -Status 'manualRepair' -ReasonCode 'ambiguousRegistration' -Message $ambiguousDetail
        return [pscustomobject]@{ Removed = $false }
    }

    if ($WhatIf) {
        Set-ComponentResult -Component 'kiro' -Status 'ok' -ReasonCode 'wouldRemove'
        return [pscustomobject]@{ Removed = $true }
    }

    # ---- compensating rollback, same order as the shared clients: the runtime
    # is staged aside (reversible) before any registration file is touched.
    $setAside = ''
    if (Test-Path -LiteralPath $identity.HookDir -PathType Container) {
        $setAside = Join-Path $identity.RuntimeRoot ('.hookmaker-uninstall-' + $FriendlyName + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { Move-Item -LiteralPath $identity.HookDir -Destination $setAside -Force }
        catch {
            Set-ComponentResult -Component 'kiro' -Status 'failed' -ReasonCode 'stageRuntimeFailed' -Message $_.Exception.Message
            return [pscustomobject]@{ Removed = $false }
        }
    }

    $registrationError = ''
    foreach ($candidate in @($candidates.ToArray())) {
        try {
            # Under the SAME per-file lock the install side takes on this exact
            # path, so a concurrent install cannot interleave with this
            # read-classify-write and lose the user's own entries - the shared
            # clients lock their settings file here for the same reason.
            $fileError = Invoke-WithResourceLock -ResourcePath $candidate -Action {
                # Re-read and re-classify IMMEDIATELY before mutating: the
                # pre-flight above proves the plan is safe, this proves the file
                # has not changed since, and only this fresh classification is
                # acted on.
                $fresh = Test-KiroManagedFile -Path $candidate -ManagedId $identity.ManagedId
                if ([string]$fresh.Reason -ne 'managed') {
                    return ("'" + (Split-Path -Leaf $candidate) + "' changed while it was being removed (now " + [string]$fresh.Reason + ')')
                }
                $unrecorded = Get-KiroUnrecordedEntryName -Classification $fresh -EntryNames @($identity.EntryNames)
                if ($unrecorded -ne '') {
                    return ("'" + (Split-Path -Leaf $candidate) + "' gained an unrecorded managed entry ('" + $unrecorded + "') while it was being removed")
                }
                $candidateBackup = Get-SettingsBackupPath -Path $candidate
                Backup-SettingsFile $candidate
                if (@($fresh.ForeignEntries).Count -eq 0) {
                    Remove-Item -LiteralPath $candidate -Force
                    # The document was entirely ours - proven managed twice, and
                    # it carried no foreign entry - so it is gone now and the
                    # backup is a copy of a file this tool wrote and just
                    # removed. It restores nothing that reinstalling does not,
                    # and .kiro\hooks is the directory Kiro SCANS as its
                    # configuration: leaving one dead copy per hook turned a
                    # clean 24-hook uninstall into 24 files of debris sitting in
                    # the user's config folder. The rewrite branch below keeps
                    # its backup - there the file survives and holds the user's
                    # own entries, which is exactly when a backup is worth having.
                    if (-not [string]::IsNullOrWhiteSpace($candidateBackup) -and
                        (Test-Path -LiteralPath $candidateBackup -PathType Leaf)) {
                        try { Remove-Item -LiteralPath $candidateBackup -Force } catch { }
                    }
                }
                else {
                    # The user's own entries are written back as the very objects
                    # that were parsed, so their order, matcher, timeout, command
                    # and enabled state cannot be perturbed. Write-SettingsFileAtomic
                    # serializes at depth 50 - deeper than ConvertTo-KiroHookJson's
                    # 12 and far past the 3 a Kiro document needs - and re-parses
                    # the temp file before replacing the original.
                    Write-SettingsFileAtomic -Value ([pscustomobject][ordered]@{ version = 'v1'; hooks = @($fresh.ForeignEntries) }) -Path $candidate
                }
                return ''
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$fileError)) {
                $registrationError = [string]$fileError
                break
            }
        }
        catch {
            $registrationError = $_.Exception.Message
            break
        }
    }

    if ($registrationError -ne '') {
        if (-not [string]::IsNullOrWhiteSpace($setAside) -and (Test-Path -LiteralPath $setAside)) {
            try { Move-Item -LiteralPath $setAside -Destination $identity.HookDir -Force } catch { }
        }
        Set-ComponentResult -Component 'kiro' -Status 'failed' -ReasonCode 'registrationWriteFailed' -Message $registrationError
        return [pscustomobject]@{ Removed = $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($setAside) -and (Test-Path -LiteralPath $setAside)) {
        try { Remove-Item -LiteralPath $setAside -Recurse -Force }
        catch {
            Set-ComponentResult -Component 'kiro' -Status 'ok' -ReasonCode 'runtimeCleanupIncomplete' -Message $_.Exception.Message
            return [pscustomobject]@{ Removed = $true }
        }
    }
    Remove-EmptyManagedRoot -Root $identity.RuntimeRoot
    Set-ComponentResult -Component 'kiro' -Status 'ok'
    return [pscustomobject]@{ Removed = $true }
}