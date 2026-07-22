# ---------------------------------------------------------------------------
# Discovered-uninstall evidence proofs - split out of Uninstall-DiscoveredHook.ps1.
#
# ONE responsibility: read-only judgement over a DISCOVERED registry record's
# persisted evidence versus the live machine state. Nothing here mutates
# anything; every function returns a verdict for Uninstall-DiscoveredHook.ps1
# to act on. Keeping the proofs apart from the removal machinery is what makes
# them reviewable in isolation - the whole safety contract of the discovered
# remover lives in this file (and the staging/rollback half lives in
# _uninstalldiscoveredstage.ps1).
#
# DOT-SOURCED, not imported: Uninstall-DiscoveredHook.ps1 dot-sources this into
# its own scope, so these functions read the record identity variables from the
# including scope at CALL time exactly as they did when they lived inline. This
# file is not standalone and must not be dot-sourced anywhere else:
#   $record                    - the selected discovered registry record
#   $allRecords                - every record in the registry (managed + discovered)
#   $RecordId                  - the id being removed
#   $HookType                  - record.hookType
#   $RecordScope               - global | project
#   $RecordTargetProjectRoot   - project root for a project-scoped record
#   $script:KnownToolRoots     - roots whose hooks\ tree is never removable
#   $script:ForeignReferenceKeys - canonical path keys other records still reference
#
# It also uses Test-PathContainedIn / Get-CanonicalPathKey /
# Get-CanonicalPathOrEmpty / Get-HandlerFingerprint / Get-MatcherFingerprint /
# Get-HandlerTargetAgreement / Get-FileSha256Hex from the library chain
# (_installplan.ps1 / _installlib.ps1 / _hookdiscovery.ps1), which
# Uninstall-DiscoveredHook.ps1 dot-sources first.
# ---------------------------------------------------------------------------

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

# ---- native Git evidence ----------------------------------------------------
# Reload the exact hook path and require: the exact persisted hash, the same
# effective hooks directory, and the same repository identity. Any drift keeps
# the file byte-for-byte and retains the record. Resolved alongside the
# registration evidence (see the call site in Uninstall-DiscoveredHook.ps1),
# because a drifted native hook must block the record before anything is
# staged - not after.
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
