# ---------------------------------------------------------------------------
# Noninteractive, record-based uninstaller: given a registry record id, removes
# EXACTLY that logical installation's artifacts (Claude settings registration,
# Codex settings registration, per-client runtime copy, native Git pre-push
# integration) and then its registry record. A separate UI layer calls this;
# it never prompts.
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
$script:KnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)

# ---- ownership-proven settings pruning -------------------------------------
# Identical identity rule to Install-Hook.ps1's Remove-StaleHandlers: a handler
# is ours only when its command resolves (via the centralized, path-shape
# based parser) to THIS friendly name (or its legacy internal name) and THIS
# profile. A foreign handler that merely shares a script basename is left
# untouched, no matter how similar it looks.
function Remove-OwnedHandlers {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName
    )
    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) { return $false }
    $removedAny = $false
    $keptGroups = @()
    foreach ($group in @($HooksObject.$EventName)) {
        $keptHandlers = @()
        foreach ($handler in @($group.hooks)) {
            $owned = Test-HandlerBelongsToInstall -Handler $handler -FriendlyName $FriendlyName `
                -ProfileId $ProfileId -AlsoMatchHookNames @($InternalName) `
                -KnownToolRoots $script:KnownToolRoots
            if ($owned) { $removedAny = $true } else { $keptHandlers += $handler }
        }
        if ($keptHandlers.Count -gt 0) {
            $group.hooks = $keptHandlers
            $keptGroups += $group
        }
    }
    $HooksObject.$EventName = $keptGroups
    return $removedAny
}

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

    $settingsPath = [string]$subrecord.settingsPath
    $runtimeRoot = [string]$subrecord.runtimeRoot
    $hookDir = if (-not [string]::IsNullOrWhiteSpace($runtimeRoot)) { Join-Path $runtimeRoot $FriendlyName } else { '' }
    $hasRuntimeDir = (-not [string]::IsNullOrWhiteSpace($hookDir)) -and (Test-Path -LiteralPath $hookDir -PathType Container)

    if ($hasRuntimeDir -and -not (Test-SafeManagedDir -Dir $hookDir -Root $runtimeRoot)) {
        Set-ComponentResult -Component $ClientName -Status 'manualRepair' -ReasonCode 'unsafeRuntimePath' -Message ('runtime path is outside the expected boundary: ' + $hookDir)
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
                        $eventNames = @()
                        foreach ($property in $json.hooks.PSObject.Properties) { $eventNames += $property.Name }
                        foreach ($eventName in $eventNames) { [void](Remove-OwnedHandlers -HooksObject $json.hooks -EventName $eventName) }
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
    if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'alreadyRemoved'
        return [pscustomobject]@{ Removed = $true }
    }
    $body = [System.IO.File]::ReadAllText($wrapperPath)
    if (-not $body.Contains($script:PrePushMarker)) {
        # No longer our wrapper - nothing of ours is left to remove here.
        Set-ComponentResult -Component 'nativeGit' -Status 'ok' -ReasonCode 'notManagedAnymore'
        return [pscustomobject]@{ Removed = $true }
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

    # Stages this record itself owns: its own primary script plus every
    # companion recorded alongside it. Anything else in expectedStages
    # belongs to some other logical owner and is left running.
    $ownRuntimeRoot = [string]$native.runtimeRoot
    $ownStages = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ownRuntimeRoot)) {
        [void]$ownStages.Add((Join-Path $ownRuntimeRoot ($FriendlyName + '\' + $FriendlyName + '.ps1')))
        foreach ($companion in @($native.companions)) {
            [void]$ownStages.Add((Join-Path $ownRuntimeRoot ([string]$companion + '\' + [string]$companion + '.ps1')))
        }
    }
    $ownStageSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($stage in @($ownStages.ToArray())) { [void]$ownStageSet.Add([System.IO.Path]::GetFullPath($stage)) }
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
        $dirsToRemove = New-Object System.Collections.Generic.List[string]
        [void]$dirsToRemove.Add((Join-Path $ownRuntimeRoot $FriendlyName))
        foreach ($companion in @($native.companions)) {
            $companionName = [string]$companion
            $companionScriptFull = [System.IO.Path]::GetFullPath((Join-Path $ownRuntimeRoot ($companionName + '\' + $companionName + '.ps1')))
            $stillOwnedElsewhere = @($remainingStages | Where-Object { [System.IO.Path]::GetFullPath($_) -eq $companionScriptFull }).Count -gt 0
            if (-not $stillOwnedElsewhere) { [void]$dirsToRemove.Add((Join-Path $ownRuntimeRoot $companionName)) }
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

$script:CurrentPhase = 'claude'
$claudeResult = Remove-ClientComponent -ClientName 'claude'
$script:CurrentPhase = 'codex'
$codexResult = Remove-ClientComponent -ClientName 'codex'

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
