# ---------------------------------------------------------------------------
# Noninteractive remover for a DISCOVERED registry record (recordType =
# 'discovered'), i.e. a hook the status scan found on disk that Hook Maker did
# not install and therefore cannot prove ownership of by construction.
#
# This is a deliberately SEPARATE path from scripts\Uninstall-Hook.ps1. That
# script removes what Hook Maker itself installed, and proves ownership from
# managed path shape plus its own persisted install plan. None of that evidence
# exists for a discovered hook, so the proof here is a different one entirely:
#
#   the artifact must still be BYTE-FOR-BYTE what the scan recorded.
#
# Every mutation is gated on recomputing the scan's own fingerprints/hashes from
# the LIVE file and proving they still equal what the record persisted. If any
# single piece of evidence moved since the scan, nothing is removed for that
# logical record - the record is retained, marked needsManualRepair, and the
# exact mismatch is reported. "We are no longer sure" must never resolve to a
# delete.
#
# Two decisions are kept strictly apart, because conflating them is how a
# remover destroys someone else's work:
#
#   1. REGISTRATION removal - taking a handler out of a settings file. Matched
#      by exact canonical handler fingerprint plus its event/matcher context.
#      Array indices are hints, never identity.
#   2. RUNTIME removal - deleting a file on disk. Allowed only when the file is
#      the exact recorded target, hashes identically, sits inside a recognized
#      hook runtime boundary, is a proven entrypoint rather than a shared
#      helper, and nothing else on the machine still references it. When any of
#      that fails the registration still comes off and the FILE IS PRESERVED
#      ('registration removed; runtime preserved').
#
# Mirrors Uninstall-Hook.ps1's conventions exactly - same -ResultPath structured
# result contract, same top-level `trap {...; break}` so a result document is
# guaranteed on every terminal outcome, same per-settings-file crash-aware lock,
# same atomic JSON writer, same timestamped backup, and the same compensating
# sibling-rename staging so a failure mid-run leaves the machine exactly as it
# was.
#
# Full machine-crash atomicity is explicitly NOT provided (matching the rest of
# this project): the guarantee is ordered, compensating-rollback safety for a
# single foreground run, not survival of a power cut between two file
# operations.
# ---------------------------------------------------------------------------

param(
    # The discovered registry record id to remove. Required: like the managed
    # uninstaller, this only ever acts on a single, already-identified logical
    # record - it never searches by name, basename or path.
    [Parameter(Mandatory = $true)][string]$RecordId,
    [string]$ToolRoot,
    # Machine-readable per-component outcome document; same shape as
    # Uninstall-Hook.ps1's so one UI can consume both.
    [string]$ResultPath,
    # Dry run: proves every safety check and reports what WOULD happen without
    # writing, moving or deleting anything.
    [switch]$WhatIf
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- structured outcome (same contract as Uninstall-Hook.ps1) --------------
# Set-ComponentResult / Write-UninstallResult live in
# _uninstalldiscoveredstage.ps1, dot-sourced below before the trap needs them.
$script:ComponentResults = New-Object System.Collections.Generic.List[object]

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
$ToolRoot = [System.IO.Path]::GetFullPath($ToolRoot)

# Same load order as Uninstall-Hook.ps1 (hook runtime helpers -> install plan ->
# install state library), then the shared discovery identity layer LAST so the
# fingerprint/hash functions this file gates every mutation on are exactly the
# ones the scanner used. _hookdiscovery.ps1 re-defines Test-IsReparsePoint with
# the same semantics as _installplan.ps1's; neither is called here.
#
# These come from THIS script's own location, not from -ToolRoot. -ToolRoot
# names the installation being managed (and supplies the "never touch Hook
# Maker's own sources" boundary), which is not necessarily the checkout this
# script is running from - loading our own libraries out of it would make the
# remover's behaviour depend on a directory it is only supposed to inspect.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installplan.ps1')
. (Join-Path $PSScriptRoot '_installlib.ps1')
. (Join-Path $PSScriptRoot '_hookdiscovery.ps1')
# The two halves of this remover, split by responsibility (same convention as
# _uninstallownership.ps1 for the managed uninstaller) and dot-sourced into
# THIS scope so every function still reads the record identity variables from
# it at CALL time: first the read-only evidence proofs, then the staging/
# rollback and result-document machinery that acts on their verdicts.
. (Join-Path $PSScriptRoot '_uninstalldiscoveredscan.ps1')
. (Join-Path $PSScriptRoot '_uninstalldiscoveredstage.ps1')

$script:CurrentPhase = 'validation'
trap {
    $failedPhase = if ($null -ne $script:CurrentPhase -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentPhase)) { [string]$script:CurrentPhase } else { 'unknown' }
    $alreadyReported = @($script:ComponentResults | Where-Object { $_.component -eq $failedPhase })
    if ($alreadyReported.Count -eq 0) {
        $sanitizedMessage = [string]$_.Exception.Message
        if ($sanitizedMessage.Length -gt 500) { $sanitizedMessage = $sanitizedMessage.Substring(0, 500) + '...' }
        Set-ComponentResult -Component $failedPhase -Status 'failed' -ReasonCode 'exception' -Message $sanitizedMessage
    }
    Write-UninstallResult -Overall 'failed'
    break
}

if ([string]::IsNullOrWhiteSpace($RecordId)) { throw '-RecordId is required.' }

# ---- lookup + validate BEFORE anything is touched --------------------------
$script:CurrentPhase = 'registry'
$registryState = Read-InstallRegistryState -ToolRoot $ToolRoot
if ($registryState.State -eq 'corrupt') {
    Set-ComponentResult -Component 'registry' -Status 'manualRepair' -ReasonCode 'registryCorrupt' -Message ([string]$registryState.Reason)
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ('WARNING: the install registry is unreadable (' + [string]$registryState.Reason + '). Nothing was changed.')
    return
}
$registry = ConvertTo-InstallRegistryCurrent -Registry $registryState.Registry
$allRecords = @(@($registry.installs) | Where-Object { $null -ne $_ })
$record = @($allRecords | Where-Object { (Get-RecordString $_ 'id') -eq $RecordId }) | Select-Object -First 1
if ($null -eq $record) {
    # Idempotent, exactly like the managed uninstaller: removing an id that is
    # already gone is success, so a UI may retry after a crash.
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'notFound' -Message 'no record with this id - already removed'
    Write-UninstallResult -Overall 'ok'
    Write-Host ("No record found for id '" + $RecordId + "'. Nothing to do.")
    return
}

# A record with no recordType predates schema 3 and is therefore MANAGED. This
# script must never touch one: the managed uninstaller owns that contract and
# its safety proofs, and routing a managed record here would bypass all of them.
$recordType = Get-RecordString $record 'recordType' 'managed'
if ($recordType -ne 'discovered') {
    Set-ComponentResult -Component 'registry' -Status 'manualRepair' -ReasonCode 'wrongRecordType' `
        -Message ("record '" + $RecordId + "' is recordType '" + $recordType + "'; use scripts\Uninstall-Hook.ps1 for managed records")
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ("WARNING: record '" + $RecordId + "' is not a discovered record. Nothing was changed.")
    return
}

$FriendlyName = Get-RecordString $record 'friendlyName' $RecordId
$HookType = Get-RecordString $record 'hookType'
$RecordScope = Get-RecordString $record 'scope'
$RecordTargetProjectRoot = Get-RecordString $record 'targetProjectRoot'
$script:KnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)

# ---- shape validation -------------------------------------------------------
# Refused, never repaired by guessing. The SHARED Test-DiscoveredRecordValid
# proves shape; Test-DiscoveredRemovalEvidence (_uninstalldiscoveredscan.ps1)
# gates the states that are valid to persist but insufficient to authorize a
# removal - see that file for why the shape proof is never re-implemented here.
$validity = Test-DiscoveredRecordValid -Record $record
if ($validity.Ok) { $validity = Test-DiscoveredRemovalEvidence }
if (-not $validity.Ok) {
    Set-ComponentResult -Component 'registry' -Status 'manualRepair' -ReasonCode 'recordInvalid' -Message ([string]$validity.Reason)
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ("WARNING: record '" + $RecordId + "' cannot be safely interpreted (" + [string]$validity.Reason + "). Nothing was changed.")
    return
}

# ---- what else on this machine still references a path? --------------------
# Get-ForeignReferenceKeys (_uninstalldiscoveredscan.ps1) walks EVERY other
# registry record, so a runtime file a second installation still points at is
# never deleted out from under it.
$script:ForeignReferenceKeys = Get-ForeignReferenceKeys

# ---- phase 1: verify ALL evidence, read-only --------------------------------
# Get-DiscoveredSettingsScan (_uninstalldiscoveredscan.ps1) classifies every
# handler by exact canonical fingerprint plus event/matcher context; a NEAR
# MATCH (a recorded target whose handler was edited since the scan) blocks the
# whole record rather than removing "the one that looks right".
$script:CurrentPhase = 'evidence'
$script:ClientPlans = New-Object System.Collections.Generic.List[object]
$script:NativePlan = $null
$script:EvidenceBlocked = $false
$script:EvidenceBlockDetail = ''
$script:EvidenceBlockComponent = 'evidence'

# A KiroRegistration record is refused OUTRIGHT, before any evidence is read.
#
# Kiro is registrationKind 'perHookFile': its registrations are per-hook JSON
# documents whose ownership is proved per ENTRY, not handlers inside a shared
# settings file. Get-DiscoveredSettingsScan below only understands the shared
# shape, so it would almost certainly return Ok=$false and block anyway - but
# "almost certainly blocks" is not a safety property for a path that deletes
# files. Discovered-record removal for Kiro is simply not implemented, so it
# says so, explicitly and fail-closed. Managed Kiro installs are removed by
# Uninstall-Hook.ps1, which does understand the format.
#
# This became reachable the moment 'KiroRegistration'/'kiro' were added to the
# discovered enums in _installdiscovered.ps1; before that a Kiro record could
# not persist at all, so this guard and that change belong together.
if ($HookType -eq 'KiroRegistration') {
    $script:EvidenceBlocked = $true
    $script:EvidenceBlockComponent = 'kiro'
    $script:EvidenceBlockDetail = 'Kiro registers one JSON document per hook and its ownership is proved per entry, ' +
    'which this discovered-record remover does not implement. Nothing was changed. ' +
    'Remove a Hook Maker managed Kiro install with the normal uninstall action instead.'
}
elseif ($HookType -ne 'NativeGitHook') {
    foreach ($clientEvidence in @(Get-RecordArray $record 'clients')) {
        $clientName = Get-RecordString $clientEvidence 'client'
        $scan = Get-DiscoveredSettingsScan -ClientEvidence $clientEvidence
        if (-not $scan.Ok) {
            $script:EvidenceBlocked = $true
            $script:EvidenceBlockComponent = $clientName
            $script:EvidenceBlockDetail = $scan.Reason
            break
        }
        if ($scan.NearMatch) {
            $script:EvidenceBlocked = $true
            $script:EvidenceBlockComponent = $clientName
            $script:EvidenceBlockDetail = $scan.NearMatchDetail
            break
        }
        [void]$script:ClientPlans.Add([pscustomobject]@{
            ClientName = $clientName
            Evidence   = $clientEvidence
            Scan       = $scan
        })
    }
}

# ---- native Git evidence ----------------------------------------------------
# Resolve-NativePlan (_uninstalldiscoveredscan.ps1) requires the exact
# persisted hash, hooks directory and repository identity. Resolved HERE,
# alongside the registration evidence, because a drifted native hook must
# block the record before anything is staged - not after.
if ($HookType -eq 'NativeGitHook') {
    $script:NativePlan = Resolve-NativePlan
    # Drifted / ambiguous native evidence blocks the record exactly like a
    # changed handler fingerprint does: preserve the file, keep the record.
    if (-not $script:NativePlan.Ok -and $script:NativePlan.Manual) {
        $script:EvidenceBlocked = $true
        $script:EvidenceBlockComponent = 'nativeGit'
        $script:EvidenceBlockDetail = $script:NativePlan.Reason
    }
}

if ($script:EvidenceBlocked) {
    Set-ComponentResult -Component $script:EvidenceBlockComponent -Status 'manualRepair' -ReasonCode 'evidenceChanged' -Message $script:EvidenceBlockDetail
    if (-not $WhatIf) {
        try {
            Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
                $state = Read-InstallRegistryState -ToolRoot $ToolRoot
                if ($state.State -ne 'ok') { return }
                $live = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
                $list = @($live.installs)
                for ($i = 0; $i -lt $list.Count; $i++) {
                    if ((Get-RecordString $list[$i] 'id') -ne $RecordId) { continue }
                    Set-ObjectProperty -Object $list[$i] -Name 'needsManualRepair' -Value $true
                    Set-ObjectProperty -Object $list[$i] -Name 'status' -Value 'manualRepair'
                    Set-ObjectProperty -Object $list[$i] -Name 'statusReason' -Value $script:EvidenceBlockDetail
                    $live.installs = $list
                    Save-InstallRegistry -ToolRoot $ToolRoot -Registry $live
                    break
                }
            } | Out-Null
        }
        catch { }
    }
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'retained' -Message 'the record was retained and flagged for manual repair'
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ("WARNING: the on-disk evidence for '" + $FriendlyName + "' no longer matches what was recorded (" + $script:EvidenceBlockDetail + "). Nothing was removed.")
    return
}

# ---- runtime artifact eligibility (a SEPARATE decision) ---------------------
# Test-RuntimeArtifactRemovable (_uninstalldiscoveredscan.ps1): automatic
# deletion requires EVERY proof to hold right now. Any single failure
# downgrades to registration-only removal with the file preserved - never to a
# "probably fine" delete.
$script:AllForeignTargets = New-KeySet
foreach ($plan in $script:ClientPlans) {
    foreach ($target in @($plan.Scan.ForeignTargets)) { [void]$script:AllForeignTargets.Add($target) }
}
$script:RuntimeRemovable = New-Object System.Collections.Generic.List[string]
$script:RuntimePreserved = New-Object System.Collections.Generic.List[string]
foreach ($artifact in @(Get-RecordArray $record 'runtimeArtifacts')) {
    $decision = Test-RuntimeArtifactRemovable -Artifact $artifact -ForeignTargets $script:AllForeignTargets
    $canonical = Get-CanonicalPathOrEmpty (Get-RecordString $artifact 'path')
    if ($decision.Ok) { [void]$script:RuntimeRemovable.Add($canonical) }
    else { [void]$script:RuntimePreserved.Add($decision.Reason) }
}

# ---- WhatIf: every proof ran; report and stop -------------------------------
if ($WhatIf) {
    foreach ($plan in $script:ClientPlans) {
        Set-ComponentResult -Component $plan.ClientName -Status 'ok' -ReasonCode 'wouldRemove' `
            -Message ('would remove ' + @($plan.Scan.MatchedPrints).Count + ' handler(s) by exact fingerprint')
    }
    if ($null -ne $script:NativePlan) {
        if ($script:NativePlan.Ok) { Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'wouldRemove' }
        elseif ($script:NativePlan.Delegate -ne '') { Set-ComponentResult -Component 'nativeGit' -Status 'skipped' -ReasonCode 'wouldDelegateToManaged' -Message $script:NativePlan.Delegate }
        elseif ($script:NativePlan.Manual) { Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'nativeEvidenceChanged' -Message $script:NativePlan.Reason }
        else { Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'alreadyRemoved' -Message $script:NativePlan.Reason }
    }
    Set-ComponentResult -Component 'runtime' -Status 'ok' -ReasonCode 'wouldRemove' `
        -Message ('' + $script:RuntimeRemovable.Count + ' removable, ' + $script:RuntimePreserved.Count + ' preserved')
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'wouldRemove'
    Write-UninstallResult -Overall 'ok'
    Write-Host ("[WhatIf] Would remove discovered record '" + $FriendlyName + "' (" + $RecordId + ").")
    return
}

# ---- delegation: a managed wrapper goes through the managed uninstaller -----
if ($null -ne $script:NativePlan -and $script:NativePlan.Delegate -ne '') {
    $script:CurrentPhase = 'nativeGit'
    $managedId = $script:NativePlan.Delegate
    $delegateResultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-delegate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $delegateOverall = 'failed'
    try {
        & (Join-Path $PSScriptRoot 'Uninstall-Hook.ps1') -RecordId $managedId -ToolRoot $ToolRoot -ResultPath $delegateResultPath *> $null
    }
    catch { }
    if (Test-Path -LiteralPath $delegateResultPath -PathType Leaf) {
        try {
            $delegateDocument = [System.IO.File]::ReadAllText($delegateResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $delegateOverall = Get-RecordString $delegateDocument 'overall' 'failed'
        }
        catch { }
        Remove-Item -LiteralPath $delegateResultPath -Force -ErrorAction SilentlyContinue
    }
    Set-ComponentResult -Component 'nativeGit' -Status $(if ($delegateOverall -eq 'ok') { 'ok' } elseif ($delegateOverall -eq 'manualRepair') { 'manualRepair' } else { 'failed' }) `
        -ReasonCode 'delegatedToManagedUninstaller' -Message ('managed record ' + $managedId + ' -> ' + $delegateOverall)
    if ($delegateOverall -ne 'ok') {
        Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'retained' -Message 'the discovered record is retained until the managed uninstall succeeds'
        Write-UninstallResult -Overall $(if ($delegateOverall -eq 'manualRepair') { 'manualRepair' } else { 'failed' })
        Write-Host ('WARNING: the managed uninstaller reported ' + $delegateOverall + ' for record ' + $managedId + '. The discovered record is retained.')
        return
    }
}

# ---- phase 2: stage every irreversible removal aside ------------------------
# Sibling renames only. Nothing is destroyed until every required commit has
# succeeded, so any failure below restores the machine exactly as it was.
$script:SetAsides = New-Object System.Collections.Generic.List[object]

$script:CurrentPhase = 'runtime'
$stagingError = ''
try {
    foreach ($path in @($script:RuntimeRemovable.ToArray())) { Add-SetAside -Path $path }
    if ($null -ne $script:NativePlan -and $script:NativePlan.Ok) { Add-SetAside -Path $script:NativePlan.HookPath }
}
catch { $stagingError = $_.Exception.Message }
if ($stagingError -ne '') {
    Restore-SetAsides
    Set-ComponentResult -Component 'runtime' -Status 'failed' -ReasonCode 'stageFailed' -Message $stagingError
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'retained'
    Write-UninstallResult -Overall 'failed'
    Write-Host ('WARNING: staging the runtime artifacts failed. Nothing was removed.')
    return
}

# ---- phase 3: commit the registration removals ------------------------------
# Each client's settings file is published SEPARATELY, so a failure on the
# second client would otherwise leave the first client's registration already
# gone while the run reported a full rollback. Every file this run intends to
# write is copied aside BEFORE the first publish, and any file that really was
# published is restored from its copy if a later client fails. A restore that
# itself fails is reported by name rather than papered over - no message may
# claim a restoration that did not happen.
#
# Full machine-crash atomicity is still explicitly NOT provided (a power cut
# between two restores remains an accepted, documented limitation); this is
# ordered compensating rollback for a single foreground run.
$script:SettingsSnapshots = New-Object System.Collections.Generic.List[object]

$script:CurrentPhase = 'settings'
$snapshotError = ''
try {
    foreach ($plan in $script:ClientPlans) {
        if (@($plan.Scan.MatchedPrints).Count -eq 0) { continue }
        if (-not (Test-Path -LiteralPath $plan.Scan.SettingsPath -PathType Leaf)) { continue }
        $snapshot = $plan.Scan.SettingsPath + '.hookmaker-disc-snapshot-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Copy-Item -LiteralPath $plan.Scan.SettingsPath -Destination $snapshot -Force
        [void]$script:SettingsSnapshots.Add([pscustomobject]@{
            ClientName = $plan.ClientName; Original = $plan.Scan.SettingsPath; Snapshot = $snapshot; Published = $false
        })
    }
}
catch { $snapshotError = $_.Exception.Message }
if ($snapshotError -ne '') {
    Complete-SettingsSnapshots
    Restore-SetAsides
    Set-ComponentResult -Component 'settings' -Status 'failed' -ReasonCode 'snapshotFailed' -Message $snapshotError
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'retained'
    Write-UninstallResult -Overall 'failed'
    Write-Host ('WARNING: the settings files could not be copied aside for rollback. Nothing was removed.')
    return
}

$settingsError = ''
$settingsErrorClient = ''
foreach ($plan in $script:ClientPlans) {
    $scan = $plan.Scan
    if (@($scan.MatchedPrints).Count -eq 0) {
        # Already absent AND provably unambiguous (a near match would have
        # blocked the whole record in phase 1).
        Set-ComponentResult -Component $plan.ClientName -Status 'ok' -ReasonCode 'alreadyRemoved'
        continue
    }
    try {
        $matchKeys = $scan.MatchKeys
        $settingsPath = $scan.SettingsPath
        Invoke-WithResourceLock -ResourcePath $settingsPath -Action {
            $raw = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
            $json = $raw | ConvertFrom-Json
            $hooks = Get-RecordValue $json 'hooks'
            if ($null -eq $hooks) { return }
            # Every identity actually matched under the lock. Compared against
            # the persisted plan as a SET below - "we removed something" is not
            # the same claim as "we removed exactly what we verified".
            $observedKeys = New-KeySet
            $emptyEvents = New-Object System.Collections.Generic.List[string]
            foreach ($eventProperty in @($hooks.PSObject.Properties)) {
                $eventName = [string]$eventProperty.Name
                $keptGroups = @()
                foreach ($group in @($eventProperty.Value)) {
                    if ($null -eq $group) { continue }
                    $matcherPrint = Get-MatcherFingerprint -Group $group
                    $keptHandlers = @()
                    foreach ($handler in @(Get-RecordValue $group 'hooks')) {
                        if ($null -eq $handler) { continue }
                        # Identity, recomputed here inside the lock - the array
                        # position this handler happens to occupy is irrelevant.
                        $key = $eventName + '|' + $matcherPrint + '|' + (Get-HandlerFingerprint -Handler $handler)
                        if ($matchKeys.Contains($key)) { [void]$observedKeys.Add($key); continue }
                        $keptHandlers += $handler
                    }
                    # An emptied group is dropped; a group that still holds
                    # foreign handlers keeps every one of its own fields.
                    if ($keptHandlers.Count -gt 0) {
                        $group.hooks = $keptHandlers
                        $keptGroups += $group
                    }
                }
                if ($keptGroups.Count -gt 0) { $hooks.$eventName = $keptGroups }
                else { [void]$emptyEvents.Add($eventName) }
            }
            # The plan must be matched EXACTLY - same identities, not merely a
            # non-zero count. A record owning two handlers, one of which was
            # edited between phase 1 and this lock, would otherwise remove the
            # unchanged one, leave the changed one live, and report success on
            # evidence that is provably stale. Every key here was matched by
            # recomputed fingerprint, so the observed set is a subset of the
            # plan by construction and a missing entry is the whole test.
            $unmatchedKeys = @(@($matchKeys) | Where-Object { -not $observedKeys.Contains($_) })
            if ($unmatchedKeys.Count -gt 0) {
                # No mutation has been published at this point - the edits above
                # are in-memory only and the backup below has not been taken.
                throw ('the settings file changed between verification and removal: ' + $unmatchedKeys.Count +
                    ' of ' + @($matchKeys).Count + ' verified handler(s) no longer match their recorded identity')
            }
            # An event whose every group is gone loses its key. The `hooks`
            # object itself is left in place even when empty - it is a field the
            # user's file declares, not something this record created.
            foreach ($eventName in @($emptyEvents.ToArray())) { $hooks.PSObject.Properties.Remove($eventName) }
            Copy-Item -LiteralPath $settingsPath -Destination ($settingsPath + '.backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss')) -Force
            $newJson = $json | ConvertTo-Json -Depth 50
            $temporary = $settingsPath + '.hookmaker-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            try {
                [System.IO.File]::WriteAllText($temporary, $newJson, $Utf8NoBom)
                # Parse the candidate BEFORE publishing it: a settings file that
                # does not read back as JSON would break the client entirely.
                $null = [System.IO.File]::ReadAllText($temporary, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                [System.IO.File]::Replace($temporary, $settingsPath, [NullString]::Value)
            }
            finally {
                if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            }
        } | Out-Null
        foreach ($entry in @($script:SettingsSnapshots.ToArray())) {
            if ($entry.ClientName -eq $plan.ClientName) { $entry.Published = $true }
        }
        Set-ComponentResult -Component $plan.ClientName -Status 'ok'
    }
    catch {
        $settingsError = $_.Exception.Message
        $settingsErrorClient = $plan.ClientName
        break
    }
}

if ($settingsError -ne '') {
    # Put back everything this run actually published - the staged runtime
    # artifacts AND any earlier client's settings file - so the discovered hook
    # keeps working exactly as it did before this run.
    $unrestored = Restore-PublishedSettings
    Restore-SetAsides
    Complete-SettingsSnapshots
    Set-ComponentResult -Component $settingsErrorClient -Status 'failed' -ReasonCode 'settingsWriteFailed' -Message $settingsError
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'retained'
    if (@($unrestored).Count -gt 0) {
        # The claim "nothing was removed" would be false, so it is not made.
        $names = (@($unrestored) -join ', ')
        Set-ComponentResult -Component 'settings' -Status 'manualRepair' -ReasonCode 'rollbackIncomplete' `
            -Message ('the registration was already published and could not be restored for: ' + $names)
        Write-UninstallResult -Overall 'manualRepair'
        Write-Host ("WARNING: removing the registration for '" + $FriendlyName + "' failed. The registration was ALREADY REMOVED for " +
            $names + " and could not be restored; that client needs manual repair. Everything else was restored.")
        return
    }
    Write-UninstallResult -Overall 'failed'
    Write-Host ("WARNING: removing the registration for '" + $FriendlyName + "' failed. Every artifact was restored; nothing was removed.")
    return
}
Complete-SettingsSnapshots

# ---- phase 4: registry -------------------------------------------------------
# For a NATIVE record the set-asides are still reversible here, so the record is
# removed BEFORE they are finalized and rolled back if persistence fails. For a
# registration record the settings commit above is already published, so the
# set-asides are finalized first and a registry failure is reported honestly
# instead of being rolled back into a lie.
$script:CurrentPhase = 'registry'

$isNativeRecord = ($HookType -eq 'NativeGitHook')
$cleanupIncomplete = $false
if (-not $isNativeRecord) { $cleanupIncomplete = Complete-SetAsides }

$removeResult = Remove-DiscoveredRecord
if (-not $removeResult.Ok) {
    if ($isNativeRecord) {
        # Reversible: put the hook back exactly where it was so the record and
        # the filesystem still agree with each other.
        Restore-SetAsides
        Set-ComponentResult -Component 'nativeGit' -Status 'failed' -ReasonCode 'registryWriteFailed' -Message ([string]$removeResult.Warning)
        Set-ComponentResult -Component 'registry' -Status 'failed' -ReasonCode 'registryWriteFailed' -Message ([string]$removeResult.Warning)
        Write-UninstallResult -Overall 'failed'
        Write-Host ('WARNING: the registry could not be updated, so the native hook was restored. Nothing was removed.')
        return
    }
    # Not reversible: the registration really is gone, so the record must never
    # be left claiming otherwise. Retain it, honestly marked.
    try {
        Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -ne 'ok') { return }
            $live = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
            $list = @($live.installs)
            for ($i = 0; $i -lt $list.Count; $i++) {
                if ((Get-RecordString $list[$i] 'id') -ne $RecordId) { continue }
                Set-ObjectProperty -Object $list[$i] -Name 'needsManualRepair' -Value $true
                Set-ObjectProperty -Object $list[$i] -Name 'status' -Value 'manualRepair'
                Set-ObjectProperty -Object $list[$i] -Name 'statusReason' -Value 'the registration was removed but the tracking record could not be cleared'
                $live.installs = $list
                Save-InstallRegistry -ToolRoot $ToolRoot -Registry $live
                break
            }
        } | Out-Null
    }
    catch { }
    Set-ComponentResult -Component 'registry' -Status 'failed' -ReasonCode 'registryRemovalFailed' -Message ([string]$removeResult.Warning)
    Write-UninstallResult -Overall 'partial'
    Write-Host ('WARNING: the registration was removed but the registry record could not be - ' + [string]$removeResult.Warning)
    return
}
if ($isNativeRecord) { $cleanupIncomplete = Complete-SetAsides }

# ---- report ------------------------------------------------------------------
if ($null -ne $script:NativePlan) {
    if ($script:NativePlan.Ok) { Set-ComponentResult -Component 'nativeGit' -Status 'ok' }
    elseif ($script:NativePlan.Delegate -ne '') { } # already reported by the delegation block
    elseif ($script:NativePlan.Manual) { Set-ComponentResult -Component 'nativeGit' -Status 'manualRepair' -ReasonCode 'nativeEvidenceChanged' -Message $script:NativePlan.Reason }
    else { Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'alreadyRemoved' -Message $script:NativePlan.Reason }
}
if ($script:RuntimePreserved.Count -gt 0) {
    Set-ComponentResult -Component 'runtime' -Status 'ok' -ReasonCode 'registrationRemovedRuntimePreserved' `
        -Message ('registration removed; runtime preserved (' + ($script:RuntimePreserved.ToArray() -join '; ') + ')')
}
elseif ($cleanupIncomplete) {
    Set-ComponentResult -Component 'runtime' -Status 'ok' -ReasonCode 'runtimeCleanupIncomplete' -Message 'a staged artifact could not be deleted after the commit'
}
else {
    Set-ComponentResult -Component 'runtime' -Status 'ok' -ReasonCode ('removed:' + $script:RuntimeRemovable.Count)
}
Set-ComponentResult -Component 'registry' -Status 'ok'

# A record whose native evidence had drifted never reaches here (it is refused
# above), so any manualRepair left in the list is a genuinely partial outcome.
$anyManual = @($script:ComponentResults | Where-Object { $_.status -eq 'manualRepair' }).Count -gt 0
$anyFailed = @($script:ComponentResults | Where-Object { $_.status -eq 'failed' }).Count -gt 0
$overall = if ($anyManual) { 'manualRepair' } elseif ($anyFailed) { 'partial' } else { 'ok' }
Write-UninstallResult -Overall $overall
Write-Host ("Removed discovered record '" + $FriendlyName + "' (" + $RecordId + ").")
