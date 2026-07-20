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
$script:ComponentResults = New-Object System.Collections.Generic.List[object]
function Set-ComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'failed', 'skipped', 'manualRepair')][string]$Status,
        [string]$ReasonCode = '',
        [string]$Message = ''
    )
    # Sanitized message only: never raw file contents, command strings, .env
    # values or stdin. A discovered command line can embed a secret, so nothing
    # derived from one ever reaches this document.
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
            recordType = 'discovered'
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

# ---- StrictMode-safe field access ------------------------------------------
# A discovered record is JSON that came from a scan of someone else's machine
# state. Under StrictMode a missing property throws, so every read goes through
# these rather than assuming a shape.
function Get-RecordValue {
    param($Object, [string]$Name, $Fallback = $null)
    if ($null -eq $Object -or $Object -isnot [psobject]) { return $Fallback }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Fallback }
    return $property.Value
}
function Get-RecordString {
    param($Object, [string]$Name, [string]$Fallback = '')
    $value = Get-RecordValue $Object $Name $null
    if ($null -eq $value) { return $Fallback }
    return [string]$value
}
function Get-RecordArray {
    param($Object, [string]$Name)
    $value = Get-RecordValue $Object $Name $null
    if ($null -eq $value) { return @() }
    return @($value)
}
function Get-RecordStringArray {
    param($Object, [string]$Name)
    return @(Get-RecordArray $Object $Name | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
}

function New-KeySet {
    param([string[]]$Values = @())
    $set = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($Values)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$set.Add($value) }
    }
    # Comma-wrapped deliberately: a HashSet is IEnumerable, so a bare `return`
    # would ENUMERATE it and hand back $null / a bare string / an object[]
    # instead of the set. A one-element "set" that is really a string still
    # answers .Contains() - as a SUBSTRING test - so this silently degrades into
    # matching the wrong handler rather than failing loudly.
    return , $set
}

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
# Refused, never repaired by guessing: a record that cannot state precisely what
# it refers to cannot be used to authorize a delete.
#
# The schema proof is the SHARED Test-DiscoveredRecordValid from
# _installregistry.ps1 (reached through _installlib.ps1 above) - the same
# validator the scanner and the registry merge use. It is deliberately NOT
# re-implemented here: a local copy would shadow the strong one at the exact
# moment it matters most, immediately before mutation, and a tampered record
# missing its event or matcher fingerprint arrays would sail past it.
#
# What the shared validator proves is SHAPE: every required field exists, is
# well typed and holds a legal value. It deliberately accepts states that are
# valid to PERSIST but insufficient to authorize a REMOVAL, so those - and only
# those - are gated separately below.
function Test-DiscoveredRemovalEvidence {
    # (a) a NativeGitHook record with no nativeGit evidence at all. The shared
    # validator allows nativeGit to be $null because that is the normal shape of
    # a registration record; nothing can be proven about a native hook without it.
    if ($HookType -eq 'NativeGitHook') {
        $native = Get-RecordValue $record 'nativeGit'
        if ($null -eq $native) { return [pscustomobject]@{ Ok = $false; Reason = 'native record carries no nativeGit evidence' } }
        # (b) hookHash '' is a legal persisted state - the scanner could not read
        # the file - but an unhashed hook can never be proven unchanged.
        if ((Get-RecordString $native 'hookHash') -notmatch '^[0-9a-fA-F]{64}$') {
            return [pscustomobject]@{ Ok = $false; Reason = 'native evidence carries no SHA-256 hookHash to prove the file is unchanged' }
        }
        return [pscustomobject]@{ Ok = $true; Reason = '' }
    }
    # (c) a registration record with no client evidence, or a client with an
    # empty fingerprint list (a registration the scanner could not parse). Both
    # are legal to persist and both authorize nothing.
    $clients = @(Get-RecordArray $record 'clients')
    if ($clients.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Reason = 'registration record carries no client evidence' } }
    foreach ($client in $clients) {
        if (@(Get-RecordStringArray $client 'handlerFingerprints').Count -eq 0) {
            return [pscustomobject]@{ Ok = $false; Reason = ((Get-RecordString $client 'client') + ' evidence has no handler fingerprints') }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

$validity = Test-DiscoveredRecordValid -Record $record
if ($validity.Ok) { $validity = Test-DiscoveredRemovalEvidence }
if (-not $validity.Ok) {
    Set-ComponentResult -Component 'registry' -Status 'manualRepair' -ReasonCode 'recordInvalid' -Message ([string]$validity.Reason)
    Write-UninstallResult -Overall 'manualRepair'
    Write-Host ("WARNING: record '" + $RecordId + "' cannot be safely interpreted (" + [string]$validity.Reason + "). Nothing was changed.")
    return
}

# ---- physical boundaries ----------------------------------------------------

# The recognized hook runtime roots. A runtime artifact may only ever be deleted
# from inside one of these: '<anything>\.claude\hooks', '<anything>\.codex\hooks'
# or the effective Git hooks directory. Anywhere else - a user's tools folder, a
# repository's src tree, a shared script library - is somebody else's file, and
# a registration pointing at it does not make it ours to delete.
function Get-RuntimeBoundaryRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $current = ''
    try { $current = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path)) } catch { return '' }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $leaf = Split-Path -Leaf $current
        $parent = Split-Path -Parent $current
        if ($leaf -eq 'hooks' -and -not [string]::IsNullOrWhiteSpace($parent)) {
            $parentLeaf = Split-Path -Leaf $parent
            if ($parentLeaf -eq '.claude' -or $parentLeaf -eq '.codex') { return $current }
        }
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return ''
}

# Hook Maker's OWN hooks\ sources are never removable by any path through this
# script - they are the tool's shipped material, not an installed artifact.
function Test-IsToolRootSource {
    param([string]$Path)
    foreach ($root in @($script:KnownToolRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (Test-PathContainedIn -ChildPath $Path -ParentPath (Join-Path $root 'hooks')) { return $true }
    }
    return $false
}

# The effective Git hooks directory, resolved by READING .git/config rather than
# invoking git: this script must not spawn an interpreter or a process on behalf
# of scanned repository state.
function Get-EffectiveGitHooksPath {
    param([string]$RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { return '' }
    $gitPath = Join-Path $RepositoryRoot '.git'
    if (-not (Test-Path -LiteralPath $gitPath -PathType Container)) { return '' }
    $configPath = Join-Path $gitPath 'config'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $inCore = $false
        foreach ($line in @([System.IO.File]::ReadAllLines($configPath))) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('[')) { $inCore = ($trimmed -replace '\s', '') -ieq '[core]'; continue }
            if (-not $inCore) { continue }
            $match = [regex]::Match($trimmed, '^hooksPath\s*=\s*(.+)$', 'IgnoreCase')
            if (-not $match.Success) { continue }
            $configured = $match.Groups[1].Value.Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($configured)) { continue }
            try {
                if ([System.IO.Path]::IsPathRooted($configured)) { return [System.IO.Path]::GetFullPath($configured) }
                return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $configured))
            }
            catch { return '' }
        }
    }
    return [System.IO.Path]::GetFullPath((Join-Path $gitPath 'hooks'))
}

# ---- what else on this machine still references a path? --------------------
# Built from EVERY other registry record (managed and discovered alike), so a
# runtime file that a second installation still points at is never deleted out
# from under it. The selected record itself is excluded - its own references are
# exactly what is being removed.
function Get-ForeignReferenceKeys {
    $keys = New-KeySet
    foreach ($other in $allRecords) {
        if ((Get-RecordString $other 'id') -eq $RecordId) { continue }
        # Managed shape.
        $clients = Get-RecordValue $other 'clients'
        if ($null -ne $clients -and $clients -is [psobject] -and $clients -isnot [System.Collections.IEnumerable]) {
            foreach ($property in @($clients.PSObject.Properties)) {
                $runtimeScript = Get-RecordString $property.Value 'runtimeScript'
                if (-not [string]::IsNullOrWhiteSpace($runtimeScript)) { [void]$keys.Add((Get-CanonicalPathKey $runtimeScript)) }
            }
        }
        # Discovered shape: clients is an ARRAY of per-client evidence.
        foreach ($client in @(Get-RecordArray $other 'clients')) {
            foreach ($target in @(Get-RecordStringArray $client 'parsedTargets')) {
                [void]$keys.Add((Get-CanonicalPathKey $target))
            }
        }
        foreach ($artifact in @(Get-RecordArray $other 'runtimeArtifacts')) {
            $path = Get-RecordString $artifact 'path'
            if (-not [string]::IsNullOrWhiteSpace($path)) { [void]$keys.Add((Get-CanonicalPathKey $path)) }
        }
        $native = Get-RecordValue $other 'nativeGit'
        if ($null -ne $native) {
            foreach ($field in @('hookPath', 'wrapperPath', 'runtimeRoot')) {
                $value = Get-RecordString $native $field
                if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$keys.Add((Get-CanonicalPathKey $value)) }
            }
            foreach ($stage in @(Get-RecordStringArray $native 'expectedStages')) {
                [void]$keys.Add((Get-CanonicalPathKey $stage))
            }
        }
    }
    return , $keys
}
$script:ForeignReferenceKeys = Get-ForeignReferenceKeys

# ---- settings scan: exact fingerprint identity ------------------------------
# Walks a settings file and classifies EVERY handler against this record's
# persisted evidence. Never matches on basename, friendly name, event name
# alone, array index or substring - only on the canonical handler fingerprint
# plus its event/matcher context.
#
# A NEAR MATCH - a handler sitting at a target this record recorded, but whose
# fingerprint no longer equals the recorded one - is the whole point of this
# function. It means the handler was edited since the scan, so the evidence
# authorizing removal is stale. That blocks the entire record rather than
# removing "the one that looks right".
function Get-DiscoveredSettingsScan {
    param([Parameter(Mandatory = $true)]$ClientEvidence)

    $result = [pscustomobject]@{
        Ok             = $false
        Reason         = ''
        SettingsPath   = ''
        MatchKeys      = (New-KeySet)
        MatchedPrints  = (New-KeySet)
        MissingPrints  = @()
        NearMatch      = $false
        NearMatchDetail = ''
        ForeignTargets = (New-KeySet)
    }

    $settingsPath = Get-RecordString $ClientEvidence 'settingsPath'
    $canonicalSettings = Get-CanonicalPathOrEmpty $settingsPath
    if ($canonicalSettings -eq '') {
        $result.Reason = 'the recorded settings path is not a usable path'
        return $result
    }
    $result.SettingsPath = $canonicalSettings

    # Physical boundary: a project-scoped record's settings file must still live
    # inside the project root the scan recorded it under. A record whose settings
    # path has drifted outside its own project is not the thing that was scanned.
    if ($RecordScope -eq 'project') {
        if ([string]::IsNullOrWhiteSpace($RecordTargetProjectRoot) -or
            -not (Test-PathContainedIn -ChildPath $canonicalSettings -ParentPath $RecordTargetProjectRoot)) {
            $result.Reason = 'the recorded settings file is no longer inside this record''s project root'
            return $result
        }
    }

    $persistedPrints = New-KeySet (Get-RecordStringArray $ClientEvidence 'handlerFingerprints')
    $persistedMatchers = New-KeySet (Get-RecordStringArray $ClientEvidence 'matcherFingerprints')
    $persistedEvents = New-KeySet (Get-RecordStringArray $ClientEvidence 'events')
    $persistedTargetKeys = New-KeySet (@(Get-RecordStringArray $ClientEvidence 'parsedTargets') | ForEach-Object { Get-CanonicalPathKey $_ })

    if (-not (Test-Path -LiteralPath $canonicalSettings -PathType Leaf)) {
        # The file is gone entirely: nothing of ours can remain in it, and there
        # is no near-match risk because there is nothing to be ambiguous with.
        $result.Ok = $true
        $result.MissingPrints = @($persistedPrints)
        return $result
    }

    $json = $null
    try { $json = [System.IO.File]::ReadAllText($canonicalSettings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch {
        $result.Reason = 'the settings file is not currently valid JSON'
        return $result
    }
    $hooks = Get-RecordValue $json 'hooks'
    if ($null -eq $hooks) {
        $result.Ok = $true
        $result.MissingPrints = @($persistedPrints)
        return $result
    }

    $seenPrints = New-KeySet
    $nearMatchCandidates = New-KeySet
    foreach ($eventProperty in @($hooks.PSObject.Properties)) {
        $eventName = [string]$eventProperty.Name
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group) { continue }
            $matcherPrint = Get-MatcherFingerprint -Group $group
            foreach ($handler in @(Get-RecordValue $group 'hooks')) {
                if ($null -eq $handler) { continue }
                $handlerPrint = Get-HandlerFingerprint -Handler $handler
                $agreement = Get-HandlerTargetAgreement -Handler $handler
                $targetKeys = @(@($agreement.ParsedTargets) | ForEach-Object { Get-CanonicalPathKey $_ })

                if ($persistedPrints.Contains($handlerPrint)) {
                    # The fingerprint alone is not enough: the same handler text
                    # registered under a DIFFERENT event is a different
                    # registration, and removing it would silence something the
                    # scan never saw.
                    if ($persistedEvents.Count -gt 0 -and -not $persistedEvents.Contains($eventName)) {
                        $result.NearMatch = $true
                        $result.NearMatchDetail = 'a handler matching this record''s fingerprint is registered under an event the scan did not record'
                        return $result
                    }
                    if ($persistedMatchers.Count -gt 0 -and -not $persistedMatchers.Contains($matcherPrint)) {
                        $result.NearMatch = $true
                        $result.NearMatchDetail = 'a handler matching this record''s fingerprint sits in a matcher group the scan did not record'
                        return $result
                    }
                    [void]$seenPrints.Add($handlerPrint)
                    [void]$result.MatchKeys.Add(($eventName + '|' + $matcherPrint + '|' + $handlerPrint))
                    [void]$result.MatchedPrints.Add($handlerPrint)
                    continue
                }

                # Not ours by fingerprint. A handler sitting at a target this
                # record recorded is only AMBIGUOUS if one of our fingerprints
                # is also missing - that pairing is what "the recorded handler
                # was edited" looks like. Two handlers legitimately sharing one
                # script (different timeouts, different events) is common and
                # must not block removal, so the escalation is deferred until
                # the whole file has been walked and the missing set is known.
                foreach ($targetKey in $targetKeys) {
                    if ($targetKey -eq '') { continue }
                    if ($persistedTargetKeys.Contains($targetKey)) { [void]$nearMatchCandidates.Add($targetKey) }
                    # Foreign either way: its target is recorded so the
                    # runtime-deletion decision can see somebody else still runs
                    # that file.
                    [void]$result.ForeignTargets.Add($targetKey)
                }
            }
        }
    }

    $result.MissingPrints = @(@($persistedPrints) | Where-Object { -not $seenPrints.Contains($_) })
    # A recorded handler we could not find, next to an unrecognized handler at
    # the very target it used to run: the registration was edited since the
    # scan, so the evidence authorizing removal is stale. Refuse the record
    # rather than remove whichever one currently "looks right".
    if ($result.MissingPrints.Count -gt 0 -and $nearMatchCandidates.Count -gt 0) {
        $result.NearMatch = $true
        $result.NearMatchDetail = 'a handler at a recorded target no longer matches its recorded fingerprint; it changed since the scan'
        return $result
    }
    $result.Ok = $true
    return $result
}

# ---- phase 1: verify ALL evidence, read-only --------------------------------
$script:CurrentPhase = 'evidence'
$script:ClientPlans = New-Object System.Collections.Generic.List[object]
$script:NativePlan = $null
$script:EvidenceBlocked = $false
$script:EvidenceBlockDetail = ''
$script:EvidenceBlockComponent = 'evidence'

if ($HookType -ne 'NativeGitHook') {
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
# Reload the exact hook path and require: the exact persisted hash, the same
# effective hooks directory, and the same repository identity. Any drift keeps
# the file byte-for-byte and retains the record. Resolved HERE, alongside the
# registration evidence, because a drifted native hook must block the record
# before anything is staged - not after.
function Resolve-NativePlan {
    $native = Get-RecordValue $record 'nativeGit'
    $repositoryRoot = Get-RecordString $native 'repositoryRoot'
    $hooksPath = Get-RecordString $native 'hooksPath'
    $hookPath = Get-RecordString $native 'hookPath'
    $hookName = Get-RecordString $native 'hookName'
    $classification = Get-RecordString $native 'classification'

    $canonicalHook = Get-CanonicalPathOrEmpty $hookPath
    if ($canonicalHook -eq '') { return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the recorded hook path is not usable'; Delegate = ''; HookPath = '' } }

    # Git's own sample hooks are inert templates and are never Hook Maker's to
    # remove, whatever a record claims.
    if ($canonicalHook.EndsWith('.sample', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'refusing to remove a Git sample hook'; Delegate = ''; HookPath = '' }
    }
    if (Test-IsToolRootSource -Path $canonicalHook) {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the recorded hook path is a Hook Maker source under the tool root'; Delegate = ''; HookPath = '' }
    }
    if (-not (Test-Path -LiteralPath $canonicalHook -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Manual = $false; Reason = 'the hook file is already gone'; Delegate = ''; HookPath = '' }
    }

    # Repository identity: the recorded root must still BE a repository, and its
    # effective hooks directory must still be the one the scan recorded.
    $effectiveHooks = Get-EffectiveGitHooksPath -RepositoryRoot $repositoryRoot
    if ($effectiveHooks -eq '') {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the recorded repository root is no longer a Git repository'; Delegate = ''; HookPath = '' }
    }
    if ((Get-CanonicalPathKey $effectiveHooks) -ne (Get-CanonicalPathKey $hooksPath)) {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the repository''s effective hooks directory has changed since the scan'; Delegate = ''; HookPath = '' }
    }
    $actualParent = Get-CanonicalPathKey (Split-Path -Parent $canonicalHook)
    if ($actualParent -ne (Get-CanonicalPathKey $hooksPath)) {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the recorded hook does not live in the recorded hooks directory'; Delegate = ''; HookPath = '' }
    }
    if ((Split-Path -Leaf $canonicalHook) -ne $hookName) {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the recorded hook name does not match the recorded hook path'; Delegate = ''; HookPath = '' }
    }
    if ((Get-FileSha256Hex -Path $canonicalHook) -ne (Get-RecordString $native 'hookHash').ToLowerInvariant()) {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Reason = 'the native hook has changed since it was scanned'; Delegate = ''; HookPath = '' }
    }

    # A Hook Maker wrapper is NOT this script's to remove. When it maps to a
    # managed registry record, that record's own uninstaller owns the removal
    # (including restoring any preserved user hook); a second removal path for
    # the same artifact is exactly the drift this split was meant to avoid.
    if ($classification -eq 'hookMakerWrapper') {
        $hookKey = Get-CanonicalPathKey $canonicalHook
        $managed = @($allRecords | Where-Object {
            (Get-RecordString $_ 'recordType' 'managed') -ne 'discovered' -and
            (Get-CanonicalPathKey (Get-RecordString (Get-RecordValue $_ 'nativeGit') 'wrapperPath')) -eq $hookKey
        })
        if ($managed.Count -eq 1) {
            return [pscustomobject]@{ Ok = $false; Manual = $false; Reason = 'routed to the managed uninstaller'; Delegate = (Get-RecordString $managed[0] 'id'); HookPath = $canonicalHook }
        }
        return [pscustomobject]@{ Ok = $false; Manual = $true; Delegate = ''; HookPath = ''
            Reason = 'this looks like a Hook Maker wrapper but no single managed record claims it; removal would be a guess' }
    }
    if ($classification -ne 'externalNativeHook') {
        return [pscustomobject]@{ Ok = $false; Manual = $true; Delegate = ''; HookPath = ''
            Reason = ("the native hook is classified '" + $classification + "' and cannot be removed automatically") }
    }
    return [pscustomobject]@{ Ok = $true; Manual = $false; Reason = ''; Delegate = ''; HookPath = $canonicalHook }
}

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
# Automatic deletion requires EVERY one of these to hold right now. Any single
# failure downgrades to registration-only removal with the file preserved -
# never to a "probably fine" delete.
function Test-RuntimeArtifactRemovable {
    param([Parameter(Mandatory = $true)]$Artifact, [Parameter(Mandatory = $true)]$ForeignTargets)

    $path = Get-RecordString $Artifact 'path'
    $canonical = Get-CanonicalPathOrEmpty $path
    if ($canonical -eq '') { return [pscustomobject]@{ Ok = $false; Reason = 'the recorded runtime path is not usable' } }

    if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the recorded runtime file is already gone' }
    }
    # (1) exact persisted canonical target of THIS record.
    $recordedTargets = New-KeySet
    foreach ($clientEvidence in @(Get-RecordArray $record 'clients')) {
        foreach ($target in @(Get-RecordStringArray $clientEvidence 'parsedTargets')) {
            [void]$recordedTargets.Add((Get-CanonicalPathKey $target))
        }
    }
    $key = Get-CanonicalPathKey $canonical
    if (-not $recordedTargets.Contains($key)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the file is not an exact recorded target of this record' }
    }
    # (2) unchanged since the scan.
    $recordedHash = Get-RecordString $Artifact 'hash'
    if ($recordedHash -notmatch '^[0-9a-fA-F]{64}$') {
        return [pscustomobject]@{ Ok = $false; Reason = 'the record carries no usable hash for this file' }
    }
    if ((Get-FileSha256Hex -Path $canonical) -ne $recordedHash.ToLowerInvariant()) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the file has changed since it was scanned' }
    }
    # (3) inside a recognized hook runtime boundary, and never Hook Maker's own
    # shipped sources.
    if (Test-IsToolRootSource -Path $canonical) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the file is a Hook Maker source under the tool root' }
    }
    $boundary = Get-RuntimeBoundaryRoot -Path $canonical
    if ($boundary -eq '' -or -not (Test-PathContainedIn -ChildPath $canonical -ParentPath $boundary)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the file is outside any recognized hook runtime directory' }
    }
    # (4) nothing else references it - neither another registry record nor a
    # foreign handler still live in the settings file we just read.
    if ($script:ForeignReferenceKeys.Contains($key)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'another tracked record still references this file' }
    }
    if ($ForeignTargets.Contains($key)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'another registration in the same settings file still runs this file' }
    }
    $referencedBy = @(Get-RecordStringArray $Artifact 'referencedBy' | Where-Object { $_ -ne $RecordId })
    if ($referencedBy.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the record itself lists other referencing records' }
    }
    # (5) a proven ENTRYPOINT, not a shared helper. The scan classifies this; an
    # unclassified or shared artifact is preserved.
    if ((Get-RecordString $Artifact 'kind') -ne 'entrypoint') {
        return [pscustomobject]@{ Ok = $false; Reason = 'the file is not a proven entrypoint' }
    }
    $classification = Get-RecordString $Artifact 'classification'
    if ($classification -ne 'registeredRuntime') {
        return [pscustomobject]@{ Ok = $false; Reason = ("the file is classified '" + $classification + "', not an exclusively registered runtime") }
    }
    if ((Get-RecordString $Artifact 'deleteEligibility') -eq 'preserve') {
        return [pscustomobject]@{ Ok = $false; Reason = 'the scan marked this file as preserve-only' }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

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
function Add-SetAside {
    param([Parameter(Mandatory = $true)][string]$Path)
    $setAside = $Path + '.hookmaker-disc-setaside-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Move-Item -LiteralPath $Path -Destination $setAside -Force
    [void]$script:SetAsides.Add([pscustomobject]@{ Original = $Path; SetAside = $setAside })
}
function Restore-SetAsides {
    foreach ($entry in @($script:SetAsides.ToArray())) {
        try {
            if (Test-Path -LiteralPath $entry.SetAside) { Move-Item -LiteralPath $entry.SetAside -Destination $entry.Original -Force }
        }
        catch { }
    }
    $script:SetAsides.Clear()
}
function Complete-SetAsides {
    $incomplete = $false
    foreach ($entry in @($script:SetAsides.ToArray())) {
        try {
            if (Test-Path -LiteralPath $entry.SetAside) { Remove-Item -LiteralPath $entry.SetAside -Recurse -Force }
        }
        catch { $incomplete = $true }
    }
    $script:SetAsides.Clear()
    return $incomplete
}

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
function Restore-PublishedSettings {
    # Returns the client names whose published settings file could NOT be put
    # back. Only PUBLISHED files are touched: restoring a file this run never
    # wrote would be a mutation dressed up as a rollback.
    $unrestored = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($script:SettingsSnapshots.ToArray())) {
        if (-not $entry.Published) { continue }
        try { Copy-Item -LiteralPath $entry.Snapshot -Destination $entry.Original -Force }
        catch { [void]$unrestored.Add([string]$entry.ClientName) }
    }
    return , $unrestored
}
function Complete-SettingsSnapshots {
    foreach ($entry in @($script:SettingsSnapshots.ToArray())) {
        try { Remove-Item -LiteralPath $entry.Snapshot -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:SettingsSnapshots.Clear()
}

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
function Remove-DiscoveredRecord {
    try {
        return Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -eq 'corrupt') { return [pscustomobject]@{ Ok = $false; Warning = ('registry is unreadable: ' + [string]$state.Reason) } }
            $live = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
            $live.installs = @(@($live.installs) | Where-Object { $null -eq $_ -or (Get-RecordString $_ 'id') -ne $RecordId })
            Save-InstallRegistry -ToolRoot $ToolRoot -Registry $live
            # Verified, not assumed.
            $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($verify.State -ne 'ok') { return [pscustomobject]@{ Ok = $false; Warning = ('registry did not read back cleanly: ' + [string]$verify.Reason) } }
            $stillPresent = @(@($verify.Registry.installs) | Where-Object { $null -ne $_ -and (Get-RecordString $_ 'id') -eq $RecordId }).Count
            if ($stillPresent -ne 0) { return [pscustomobject]@{ Ok = $false; Warning = 'the record was still present after a removal attempt' } }
            return [pscustomobject]@{ Ok = $true; Warning = '' }
        }
    }
    catch { return [pscustomobject]@{ Ok = $false; Warning = $_.Exception.Message } }
}

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
