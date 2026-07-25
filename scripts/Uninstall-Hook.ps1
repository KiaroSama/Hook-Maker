# ---------------------------------------------------------------------------
# Noninteractive, record-based uninstaller: given a registry record id, removes
# EXACTLY that logical installation's artifacts (Claude settings registration,
# Codex settings registration, Kiro per-hook-file registration, per-client
# runtime copy, native Git pre-push integration) and then its registry record.
# A separate UI layer calls this; it never prompts.
#
# Mirrors Install-Hook.ps1's conventions: the same -ResultPath structured-
# result contract, the same top-level `trap {...; break}` so a result document
# is guaranteed on every terminal outcome, and the same per-settings-file
# crash-aware locking / atomic JSON writer.
#
# Safety model (see scripts\_installlib.ps1 / scripts\_installplan.ps1 for the
# centralized helpers this delegates to):
#   - Ownership of a settings handler is proven by managed runtime PATH SHAPE
#     via Test-HandlerBelongsToInstall - never by basename or friendly name
#     alone.
#   - Ownership of a Kiro per-hook file is proven by the record's own persisted
#     managed id and entry names, re-classified through _installkiro.ps1's
#     Test-KiroManagedFile immediately before each mutation - never by the
#     filename, which that module treats as a hint and never as evidence.
#   - Runtime directories are staged aside (sibling rename) BEFORE any
#     irreversible delete, and restored if the matching settings/native commit
#     fails - so a partial failure never leaves a hook half-removed.
#   - The native Git pre-push wrapper is only ever touched when it is proven
#     to still be the Hook Maker managed wrapper with the expected exact
#     content; anything else stops that record with a manual-repair status
#     and preserves every file.
#   - The registry record is removed ONLY after every owned component is
#     verified successful. A partial/ambiguous outcome RETAINS the record
#     (reflecting exactly what did and did not come off) instead of
#     pretending success.
#   - Full machine-crash atomicity is explicitly NOT required (matching the
#     rest of this project) - only ordered, compensating-rollback safety for a
#     single foreground run.
# ---------------------------------------------------------------------------

param(
    # The install-registry record id to remove (Read-InstallRegistry's
    # installs[].id). Required: this uninstaller only ever acts on a single,
    # already-identified logical installation - it never searches by name.
    [Parameter(Mandatory = $true)][string]$RecordId,
    # Defaults to the real Hook Maker tool root (same convention as
    # Install-Hook.ps1). Overridable for tests / relocated checkouts.
    [string]$ToolRoot,
    # When set, a machine-readable result document is written here describing
    # the outcome of EACH component (nativeGit, claude, codex, registry) -
    # same shape/purpose as Install-Hook.ps1's -ResultPath.
    [string]$ResultPath,
    # Dry run: proves every safety check (ownership, path containment, native
    # wrapper integrity) and reports what WOULD happen, without writing,
    # moving or deleting anything.
    [switch]$WhatIf
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- structured outcome (same contract as Install-Hook.ps1) ---------------
$script:ComponentResults = New-Object System.Collections.Generic.List[object]
function Set-ComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'failed', 'skipped', 'manualRepair')][string]$Status,
        [string]$ReasonCode = '',
        [string]$Message = ''
    )
    # Sanitized message only: never raw file contents, .env values or stdin.
    [void]$script:ComponentResults.Add([pscustomobject][ordered]@{
        component = $Component
        status    = $Status
        reason    = $ReasonCode
        message   = $Message
        atUtc     = [DateTime]::UtcNow.ToString('o')
    })
}
function Write-UninstallResult {
    param([string]$Overall)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $document = [pscustomobject][ordered]@{
            schema     = 1
            overall    = $Overall
            dryRun     = [bool]$WhatIf
            recordId   = $RecordId
            components = @($script:ComponentResults.ToArray())
            atUtc      = [DateTime]::UtcNow.ToString('o')
        }
        $directory = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ResultPath, ($document | ConvertTo-Json -Depth 20), ([System.Text.UTF8Encoding]::new($false)))
    }
    catch {
        # A result-file failure must never fail the uninstall itself.
    }
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
$ToolRoot = [System.IO.Path]::GetFullPath($ToolRoot)
# Required order: hook-runtime shared helpers first (Get-ShortHash,
# Read-JsonFile, Write-JsonFileAtomic, Set-ObjectProperty), then the install
# plan (Test-PathContainedIn, the wrapper generator, registration-ownership
# parsing), then the install-state library (registry + integrity), which
# itself calls into the plan.
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installplan.ps1')
. (Join-Path $PSScriptRoot '_installlib.ps1')

# ---- guarantee a structured result on ANY terminal outcome -----------------
# Same reasoning as Install-Hook.ps1: a bare exception thrown anywhere below
# must still land a valid, correctly-attributed result document when
# -ResultPath is given, then re-propagate exactly as it would without the
# trap (same exit code, same printed exception text).
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

if ([string]::IsNullOrWhiteSpace($RecordId)) {
    throw '-RecordId is required.'
}

# ---- lookup + validate BEFORE anything is touched --------------------------
$script:CurrentPhase = 'registry'
$registryState = Read-InstallRegistryState -ToolRoot $ToolRoot
if ($registryState.State -eq 'corrupt') {
    # A corrupt registry can never be safely mutated (its OTHER records could
    # be destroyed by a naive rewrite) - report and touch nothing.
    Set-ComponentResult -Component 'registry' -Status 'manualRepair' -ReasonCode 'registryCorrupt' -Message ([string]$registryState.Reason)
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ('WARNING: the install registry is unreadable (' + [string]$registryState.Reason + '). Nothing was changed. Run an install once to trigger quarantine-and-rebuild, then retry.')
    return
}
$registry = ConvertTo-InstallRegistryCurrent -Registry $registryState.Registry
$record = @(@($registry.installs) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['id'] -and [string]$_.id -eq $RecordId }) | Select-Object -First 1
if ($null -eq $record) {
    # Idempotent: uninstalling an id that is already gone is success, not an
    # error - a UI may retry after a crash without knowing whether the first
    # attempt actually finished.
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'notFound' -Message 'no install record with this id - already removed'
    Write-UninstallResult -Overall 'ok'
    Write-Host ("No install record found for id '" + $RecordId + "'. Nothing to do.")
    return
}
$recordValidity = Test-InstallRecordValid -Record $record
if (-not $recordValidity.Ok) {
    Set-ComponentResult -Component 'registry' -Status 'manualRepair' -ReasonCode 'recordInvalid' -Message ([string]$recordValidity.Reason)
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ("WARNING: record '" + $RecordId + "' cannot be safely interpreted (" + [string]$recordValidity.Reason + "). Nothing was changed.")
    return
}

$FriendlyName = [string]$record.friendlyName
$ProfileId = [string]$record.profile
$InternalName = ''
if ($null -ne $record.PSObject.Properties['internalName']) { $InternalName = [string]$record.internalName }
$RecordScope = [string]$record.scope
$RecordTargetProjectRoot = ''
if ($null -ne $record.PSObject.Properties['targetProjectRoot']) { $RecordTargetProjectRoot = [string]$record.targetProjectRoot }
$script:KnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)

# The ownership proofs - "what can this record PROVE it owns?" - live in their
# own file so the safety contract is reviewable apart from the removal
# machinery below. Dot-sourced HERE, deliberately: those functions read the
# record identity variables assigned just above from this scope, so this line
# must stay after them and before the first proof is called.
. (Join-Path $PSScriptRoot '_uninstallownership.ps1')

function Read-OrCreateJsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{} }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    return ($raw | ConvertFrom-Json)
}

$script:UninstallTimestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
function Backup-SettingsFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination ($Path + '.backup-' + $script:UninstallTimestamp) -Force
    }
}

# Same transactional pattern as Install-Hook.ps1's Write-JsonFile: serialize to
# a sibling temp file, re-parse it to PROVE it is valid JSON, then atomically
# replace the real file. A failure at any step leaves the original untouched.
function Write-SettingsFileAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('Cannot write settings: "' + $Path + '" exists but is not a file.')
    }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 50
    $temporaryPath = $Path + '.hookmaker-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $Utf8NoBom)
        $verify = [System.IO.File]::ReadAllText($temporaryPath, [System.Text.Encoding]::UTF8)
        $null = $verify | ConvertFrom-Json
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Strict containment: hookDir must be a PROPER child of runtimeRoot (never
# equal to it - that would risk wiping the whole Hook-Maker folder) and
# genuinely contained per Test-PathContainedIn. A record whose stored paths
# fail this check is refused rather than guessed at.
function Test-SafeManagedDir {
    param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Dir) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-PathContainedIn -ChildPath $Dir -ParentPath $Root)) { return $false }
    return (-not [string]::Equals([System.IO.Path]::GetFullPath($Dir), [System.IO.Path]::GetFullPath($Root), [System.StringComparison]::OrdinalIgnoreCase))
}

# Deletes an emptied Hook-Maker/HookMaker runtime root ONLY when containment
# and emptiness are both proven right here, right now.
function Remove-EmptyManagedRoot {
    param([Parameter(Mandatory = $true)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $leaf = Split-Path -Leaf $Root
    if ($leaf -ne 'Hook-Maker' -and $leaf -ne 'HookMaker') { return }
    # A pre-private-copy install can leave a shared _hooklib.ps1 sitting
    # directly in this root (see _uninstallownership.ps1's
    # Get-RemovableSharedRuntimeRootFiles). Once no sibling hook directory
    # remains, retiring it here is what lets the root become genuinely empty
    # instead of staying orphaned forever; the function itself proves it is
    # safe (no sibling, known filename, contained, not a reparse point), so
    # this only ever deletes what was already proven removable.
    foreach ($file in @(Get-RemovableSharedRuntimeRootFiles -RuntimeRoot $Root)) {
        try { Remove-Item -LiteralPath $file -Force } catch { }
    }
    if (@(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        try { Remove-Item -LiteralPath $Root -Force } catch { }
    }
}

# ---- one client's owned settings registration + runtime copy ---------------
# Compensating rollback: the runtime directory is staged aside (sibling
# rename - reversible) BEFORE the settings file is rewritten. The set-aside is
# only permanently deleted after the settings commit succeeds; if it fails,
# the set-aside is moved back so the client keeps working exactly as before.
function Remove-ClientComponent {
    param([Parameter(Mandatory = $true)][string]$ClientName)

    $subrecord = Get-ClientSubrecord -Record $record -Client $ClientName
    if ($null -eq $subrecord) {
        Set-ComponentResult -Component $ClientName -Status 'skipped' -ReasonCode 'notInstalled'
        return [pscustomobject]@{ Removed = $true }
    }
    # ---- identity validation FIRST: every consumed invariant must be proven
    # before anything is even staged. Nothing here is reconstructed from
    # FriendlyName - the directory to remove comes only from the persisted
    # runtimeScript.
    $identity = Test-ClientRecordIdentity -Subrecord $subrecord -ClientName $ClientName
    if (-not $identity.Ok) {
        Set-ComponentResult -Component $ClientName -Status 'manualRepair' -ReasonCode 'identityInvalid' -Message $identity.Reason
        return [pscustomobject]@{ Removed = $false }
    }

    $settingsPath = $identity.CanonicalSettingsPath
    $runtimeRoot = $identity.CanonicalRuntimeRoot
    $hookDir = $identity.HookDir
    $hasRuntimeDir = Test-Path -LiteralPath $hookDir -PathType Container

    # ---- read-only ownership pre-flight: a registration that merely NAMES
    # this install without exactly matching it (wrong path, wrong event, wrong
    # profile, drifted fields) is a suspicious near-match, not "nothing to do"
    # and not "safe to remove". It blocks the ENTIRE client - nothing staged,
    # nothing written - so it can be reviewed rather than guessed at.
    $scan = Get-ClientHandlerScan -SettingsPath $settingsPath -Subrecord $subrecord -CanonicalRuntimeScript $identity.CanonicalRuntimeScript
    if ($scan.NearMatch) {
        Set-ComponentResult -Component $ClientName -Status 'manualRepair' -ReasonCode 'ambiguousRegistration' -Message $scan.NearMatchDetail
        return [pscustomobject]@{ Removed = $false }
    }

    if ($WhatIf) {
        Set-ComponentResult -Component $ClientName -Status 'ok' -ReasonCode 'wouldRemove'
        return [pscustomobject]@{ Removed = $true }
    }

    $setAside = ''
    if ($hasRuntimeDir) {
        $setAside = Join-Path $runtimeRoot ('.hookmaker-uninstall-' + $FriendlyName + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { Move-Item -LiteralPath $hookDir -Destination $setAside -Force }
        catch {
            Set-ComponentResult -Component $ClientName -Status 'failed' -ReasonCode 'stageRuntimeFailed' -Message $_.Exception.Message
            return [pscustomobject]@{ Removed = $false }
        }
    }

    $settingsOk = $true
    $settingsError = ''
    if (-not [string]::IsNullOrWhiteSpace($settingsPath) -and (Test-Path -LiteralPath $settingsPath)) {
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
            # Something other than a settings FILE occupies this path (e.g. a
            # directory) - a genuine anomaly, not "nothing to prune". Surfaced
            # as a failure rather than silently skipped.
            $settingsOk = $false
            $settingsError = 'settings path exists but is not a file: ' + $settingsPath
        }
        else {
            try {
                Invoke-WithResourceLock -ResourcePath $settingsPath -Action {
                    $json = Read-OrCreateJsonObject $settingsPath
                    if ($null -ne $json.PSObject.Properties['hooks'] -and $null -ne $json.hooks) {
                        $persistedEvents = Get-PersistedEventSet -Subrecord $subrecord
                        $eventNames = @()
                        foreach ($property in $json.hooks.PSObject.Properties) { $eventNames += $property.Name }
                        foreach ($eventName in $eventNames) {
                            [void](Remove-ExactlyOwnedHandlers -HooksObject $json.hooks -EventName $eventName -Subrecord $subrecord `
                                -CanonicalRuntimeScript $identity.CanonicalRuntimeScript -PersistedEvents $persistedEvents)
                        }
                        Backup-SettingsFile $settingsPath
                        Write-SettingsFileAtomic -Value $json -Path $settingsPath
                    }
                } | Out-Null
            }
            catch { $settingsOk = $false; $settingsError = $_.Exception.Message }
        }
    }

    if (-not $settingsOk) {
        # Rollback: put the runtime back exactly where it was. The client's
        # hook keeps working - a failed uninstall must never leave it worse
        # off than before this attempt.
        if (-not [string]::IsNullOrWhiteSpace($setAside) -and (Test-Path -LiteralPath $setAside)) {
            try { Move-Item -LiteralPath $setAside -Destination $hookDir -Force } catch { }
        }
        Set-ComponentResult -Component $ClientName -Status 'failed' -ReasonCode 'settingsWriteFailed' -Message $settingsError
        return [pscustomobject]@{ Removed = $false }
    }

    # ---- past this point: settings are committed; only irreversible cleanup
    # of the now-orphaned staged runtime remains. A failure here is reported
    # but does not undo the (already-correct) settings state.
    if (-not [string]::IsNullOrWhiteSpace($setAside) -and (Test-Path -LiteralPath $setAside)) {
        try { Remove-Item -LiteralPath $setAside -Recurse -Force }
        catch {
            Set-ComponentResult -Component $ClientName -Status 'ok' -ReasonCode 'runtimeCleanupIncomplete' -Message $_.Exception.Message
            return [pscustomobject]@{ Removed = $true }
        }
    }
    Remove-EmptyManagedRoot -Root $runtimeRoot
    Set-ComponentResult -Component $ClientName -Status 'ok'
    return [pscustomobject]@{ Removed = $true }
}

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
                Backup-SettingsFile $candidate
                if (@($fresh.ForeignEntries).Count -eq 0) {
                    Remove-Item -LiteralPath $candidate -Force
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

# ---- execution order: native Git first (cheapest, read-mostly proof of
# ownership) - a drifted wrapper stops the WHOLE record before anything else
# is touched, matching "stop that record ... preserve every file". ----------
$script:CurrentPhase = 'nativeGit'
$nativeGitResult = Remove-NativeGitComponent
$nativeGitBlocked = @($script:ComponentResults | Where-Object { $_.component -eq 'nativeGit' -and $_.status -eq 'manualRepair' }).Count -gt 0
if ($nativeGitBlocked) {
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ("WARNING: the native pre-push wrapper for '" + $FriendlyName + "' is ambiguous or has drifted. Nothing was changed for this record; manual repair is required.")
    return
}

# The Utf8-Encoding-Check chain stage comes off between the record's own
# native proof and the client registrations: a manualRepair/failed result here
# flows into the SAME partial-outcome machinery below (record retained,
# component-level truth reported), never a silent skip.
$script:CurrentPhase = 'chainStage'
Remove-CompanionChainStage

$script:CurrentPhase = 'claude'
$claudeResult = Remove-ClientComponent -ClientName 'claude'
$script:CurrentPhase = 'codex'
$codexResult = Remove-ClientComponent -ClientName 'codex'
# Kiro has its own remover because it is the per-hook-file client: there is no
# shared settings document to prune, and its ownership is per-file AND
# per-entry. A record without a kiro subrecord reports 'skipped' and nothing
# about the two shared clients changes.
$script:CurrentPhase = 'kiro'
$kiroResult = Remove-KiroClientComponent

if ($WhatIf) {
    Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'wouldRemove'
    Write-UninstallResult -Overall 'ok'
    Write-Host ("[WhatIf] Would uninstall '" + $FriendlyName + "' (record " + $RecordId + ").")
    return
}

$script:CurrentPhase = 'registry'
$anyFailed = @($script:ComponentResults | Where-Object { $_.status -eq 'failed' })
$anyManual = @($script:ComponentResults | Where-Object { $_.status -eq 'manualRepair' })

if ($anyFailed.Count -gt 0 -or $anyManual.Count -gt 0) {
    # Partial / ambiguous outcome: RETAIN the record, but make it reflect
    # reality exactly - a component that really did come off is dropped from
    # the record; one that failed or needs manual repair is left exactly as
    # it was, never guessed at or silently restored.
    if ($claudeResult.Removed) { Set-ObjectProperty -Object $record.clients -Name 'claude' -Value $null }
    if ($codexResult.Removed) { Set-ObjectProperty -Object $record.clients -Name 'codex' -Value $null }
    if ($kiroResult.Removed) { Set-ObjectProperty -Object $record.clients -Name 'kiro' -Value $null }
    if ($nativeGitResult.Removed -and $null -ne $record.PSObject.Properties['nativeGit']) {
        Set-ObjectProperty -Object $record -Name 'nativeGit' -Value $null
    }
    Set-ObjectProperty -Object $record -Name 'needsManualRepair' -Value ($anyManual.Count -gt 0)
    Set-ObjectProperty -Object $record -Name 'lastResult' -Value 'partial'
    Set-ObjectProperty -Object $record -Name 'lastReason' -Value 'uninstall incomplete'
    Set-ObjectProperty -Object $record -Name 'lastUpdatedUtc' -Value ([DateTime]::UtcNow.ToString('o'))
    $componentSnapshot = @($script:ComponentResults.ToArray() | ForEach-Object {
        [pscustomobject][ordered]@{ component = [string]$_.component; status = [string]$_.status; reason = [string]$_.reason }
    })
    Set-ObjectProperty -Object $record -Name 'lastComponents' -Value $componentSnapshot

    $partialSaveResult = $null
    try {
        $partialSaveResult = Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -eq 'corrupt') {
                return [pscustomobject]@{ Ok = $false; Warning = ('registry is unreadable: ' + [string]$state.Reason) }
            }
            $liveRegistry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
            $liveList = @($liveRegistry.installs)
            $index = -1
            for ($i = 0; $i -lt $liveList.Count; $i++) {
                if ($null -ne $liveList[$i] -and $null -ne $liveList[$i].PSObject.Properties['id'] -and [string]$liveList[$i].id -eq $RecordId) { $index = $i; break }
            }
            if ($index -ge 0) {
                $liveList[$index] = $record
                $liveRegistry.installs = $liveList
                Save-InstallRegistry -ToolRoot $ToolRoot -Registry $liveRegistry
            }
            # If the record is already gone (e.g. removed by a concurrent run),
            # there is nothing left to retain - that is success, not a failure.
            $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($verify.State -ne 'ok') {
                return [pscustomobject]@{ Ok = $false; Warning = ('registry did not read back cleanly: ' + [string]$verify.Reason) }
            }
            return [pscustomobject]@{ Ok = $true; Warning = '' }
        }
    }
    catch { $partialSaveResult = [pscustomobject]@{ Ok = $false; Warning = $_.Exception.Message } }
    if (-not $partialSaveResult.Ok) {
        Set-ComponentResult -Component 'registry' -Status 'failed' -ReasonCode 'registryWriteFailed' -Message ([string]$partialSaveResult.Warning)
    }
    else {
        Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'partiallyRetained'
    }
    # 'manualRepair' only when a component genuinely needs a human (tampered
    # wrapper, unsafe path); a plain 'failed' (e.g. a momentarily locked
    # settings file) is retryable - the caller can simply run this again.
    $partialOverall = if ($anyManual.Count -gt 0) { 'manualRepair' } else { 'failed' }
    Write-UninstallResult -Overall $partialOverall
    Write-Host ("WARNING: uninstalling '" + $FriendlyName + "' (record " + $RecordId + ") was only partially applied. The record is retained; see the result document for exactly which components still need attention.")
    return
}

# ---- everything owned by this record came off cleanly: remove the record --
$removeResult = $null
try {
    $removeResult = Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($state.State -eq 'corrupt') {
            return [pscustomobject]@{ Ok = $false; Warning = ('registry is unreadable: ' + [string]$state.Reason) }
        }
        $liveRegistry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
        $liveRegistry.installs = @(@($liveRegistry.installs) | Where-Object { $null -eq $_ -or $null -eq $_.PSObject.Properties['id'] -or [string]$_.id -ne $RecordId })
        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $liveRegistry
        # Verified, not assumed: read the registry back and prove the record is
        # really gone (same discipline Update-InstallRegistry uses for a write).
        $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($verify.State -ne 'ok') {
            return [pscustomobject]@{ Ok = $false; Warning = ('registry did not read back cleanly after removal: ' + [string]$verify.Reason) }
        }
        $stillPresent = @(@($verify.Registry.installs) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['id'] -and [string]$_.id -eq $RecordId }).Count
        if ($stillPresent -ne 0) {
            return [pscustomobject]@{ Ok = $false; Warning = 'the record was still present after a removal attempt' }
        }
        return [pscustomobject]@{ Ok = $true; Warning = '' }
    }
}
catch { $removeResult = [pscustomobject]@{ Ok = $false; Warning = $_.Exception.Message } }
if (-not $removeResult.Ok) {
    # Every owned artifact really is gone at this point, so the record must
    # never be left claiming otherwise. Fall back to persisting a record that
    # reflects reality (no client/nativeGit subrecords left) instead of
    # leaving the stale original in place - a lying "still installed" record
    # is worse than one honestly marked as needing its tracking entry cleared.
    Set-ObjectProperty -Object $record.clients -Name 'claude' -Value $null
    Set-ObjectProperty -Object $record.clients -Name 'codex' -Value $null
    Set-ObjectProperty -Object $record.clients -Name 'kiro' -Value $null
    if ($null -ne $record.PSObject.Properties['nativeGit']) { Set-ObjectProperty -Object $record -Name 'nativeGit' -Value $null }
    Set-ObjectProperty -Object $record -Name 'needsManualRepair' -Value $true
    Set-ObjectProperty -Object $record -Name 'lastResult' -Value 'partial'
    Set-ObjectProperty -Object $record -Name 'lastReason' -Value 'uninstall cleanup succeeded but the registry record could not be removed'
    Set-ObjectProperty -Object $record -Name 'lastUpdatedUtc' -Value ([DateTime]::UtcNow.ToString('o'))
    try {
        Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -eq 'corrupt') { return }
            $liveRegistry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
            $liveList = @($liveRegistry.installs)
            for ($i = 0; $i -lt $liveList.Count; $i++) {
                if ($null -ne $liveList[$i] -and $null -ne $liveList[$i].PSObject.Properties['id'] -and [string]$liveList[$i].id -eq $RecordId) {
                    $liveList[$i] = $record
                    $liveRegistry.installs = $liveList
                    Save-InstallRegistry -ToolRoot $ToolRoot -Registry $liveRegistry
                    break
                }
            }
        } | Out-Null
    }
    catch { }
    Set-ComponentResult -Component 'registry' -Status 'failed' -ReasonCode 'registryRemovalFailed' -Message ([string]$removeResult.Warning)
    Write-UninstallResult -Overall 'failed'
    Write-Host ('WARNING: every owned component was removed, but the registry record could not be removed - ' + [string]$removeResult.Warning)
    return
}
Set-ComponentResult -Component 'registry' -Status 'ok'
Write-UninstallResult -Overall 'ok'
Write-Host ("Uninstalled '" + $FriendlyName + "' (record " + $RecordId + ").")
