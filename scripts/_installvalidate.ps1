# ---------------------------------------------------------------------------
# Install-record validation: what ONE persisted managed record must prove
# about its own shape before any field of it is read.
#
# Split out of _installlib.ps1 (the record-validation concern) so that file
# could stay a manageable size. _installlib.ps1 dot-sources this file itself,
# near its top, in the required load order - every existing consumer
# (Install-Hook.ps1, Setup-SyncGroup.ps1, Uninstall-Hook.ps1, Get-HookStatus.ps1,
# and the test suites) keeps dot-sourcing ONLY _installlib.ps1 and needs zero
# changes.
#
# Load-order contract (this file is never dot-sourced standalone - it is
# always pulled in from inside _installlib.ps1, which enforces the order):
#   1. hooks\_hooklib.ps1        (Read-JsonFile, Set-ObjectProperty)
#   2. scripts\_installplan.ps1  (Test-PathContainedIn)
#   3. scripts\_installlib.ps1   (defines $script:ManagedRecordSchemaVersion
#                                  in its header, THEN dot-sources this file)
#
# Nothing here mutates anything: every function is a read-only judgement that
# returns { Ok; Reason } for the caller to act on. A record is never "repaired"
# by guessing - an invalid one is reported for manual attention, and nothing
# about it is modified.
#
# Cross-file notes. All three resolve at CALL time, and dot-sourcing every
# file into the same caller puts them in ONE script scope, so definition order
# between these files does not matter:
#   * $script:ManagedRecordSchemaVersion is defined in _installlib.ps1 (the
#     managed record schema number this validator holds a record to).
#   * Test-IsDiscoveredRecord / Test-DiscoveredRecordValid live in
#     _installregistry.ps1 - a discovered record has a completely different
#     shape and is handed to its own validator instead.
#   * Get-CanonicalPathOrNull below is also called from _installregistry.ps1,
#     so it must stay reachable from that file's scope (it is - same scope).
#   * Get-HookMakerClientIds / Get-HookMakerClientCapability live in
#     _clientcapability.ps1, and, for a per-hook-file client, that client's own
#     managed-name producers - the per-hook-file
#     ownership and naming rules are USED from here, never re-implemented.
#     _installlib.ps1 dot-sources both files before this one.
# ---------------------------------------------------------------------------

# Canonicalizes a path for structural comparison, defensively: GetFullPath
# throws on input it cannot interpret at all (e.g. an embedded null
# character), which must be a validation REJECTION - never an unhandled
# exception escaping past Test-InstallRecordValid's caller.
function Get-CanonicalPathOrNull {
    param($Path)
    if ($null -eq $Path -or $Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [System.IO.Path]::GetFullPath($Path) }
    catch { return $null }
}

# The exact per-client settings location Install-Hook.ps1 writes to for a
# given record scope. MUST mirror its own $ClaudeSettings/$CodexHooks
# expressions exactly:
#   project: <root>\.claude\settings.local.json / <root>\.codex\hooks.json
#   global:  $HOME\.claude\settings.json / $HOME\.codex\hooks.json
# Duplicated here (rather than shared) because a validator has to be able to
# prove a persisted settingsPath without re-running the installer.
function Get-CanonicalClientSettingsPath {
    param(
        [Parameter(Mandatory = $true)][string]$ClientName,
        [Parameter(Mandatory = $true)][string]$Scope,
        [string]$TargetProjectRoot = ''
    )
    # Explicit lookup, never a fallthrough. This used to be
    #   if ($ClientName -eq 'claude') { .claude\... } else { .codex\... }
    # so EVERY client that was not Claude resolved to Codex's hooks.json - a
    # third client would have had its records validated, updated and uninstalled
    # against the wrong client's settings file. An unknown client is now
    # rejected outright rather than silently becoming Codex.
    $capability = Get-HookMakerClientCapability -ClientId $ClientName

    # A client without a single settings document would need each logical
    # installation owns its own registration file, so there is nothing for this
    # function to return and a synthesised path would be a fake. Callers must
    # branch on registrationKind and use the record's own persisted
    # registrationPath instead of asking for a canonical settings path.
    if ($capability.registrationKind -ne 'sharedSettingsFile') {
        throw ($capability.displayName + " registers one file per installation (registrationKind '" + $capability.registrationKind + "'), so it has no canonical shared settings path. Use the record's persisted registrationPath.")
    }

    if ($Scope -eq 'project') {
        return (Join-Path $TargetProjectRoot $capability.projectRegistration)
    }
    return (Join-Path $HOME $capability.globalRegistration)
}

# Validates ONE record's shape before anything reads its fields.
#
# Under StrictMode a missing property throws, so a single malformed record used
# to abort the entire update run and leave every healthy record after it
# unevaluated. Callers use this to turn a bad record into an isolated,
# precisely-reported skip instead of a batch failure.
#
# A record is never "repaired" by guessing: an invalid one is reported for
# manual attention, and nothing about it is modified.
function Test-InstallRecordValid {
    param($Record)

    if ($null -eq $Record) { return [pscustomobject]@{ Ok = $false; Reason = 'record is null' } }
    if ($Record -isnot [psobject]) { return [pscustomobject]@{ Ok = $false; Reason = 'record is not an object' } }

    # DISCRIMINATION (schema 3). A discovered record has a completely different
    # shape - no runtime, no managed command, no installed manifest - so running
    # the managed rules over it could only ever produce a misleading reason. It
    # is handed to its own validator instead. A record with recordType absent or
    # 'managed' falls through to the UNCHANGED managed rules below.
    if (Test-IsDiscoveredRecord -Record $Record) {
        return (Test-DiscoveredRecordValid -Record $Record)
    }

    function Get-RecordField {
        param($Object, [string]$Name)
        if ($null -eq $Object.PSObject.Properties[$Name]) { return $null }
        return $Object.$Name
    }

    foreach ($required in @('id', 'friendlyName', 'hookType', 'sourceScript', 'sourceDir', 'scope')) {
        $value = Get-RecordField -Object $Record -Name $required
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('record is missing the required field "' + $required + '"') }
        }
    }
    $schema = Get-RecordField -Object $Record -Name 'schema'
    if ($null -eq $schema) {
        return [pscustomobject]@{ Ok = $false; Reason = 'record has no schema version' }
    }
    $schemaNumber = 0
    if (-not [int]::TryParse([string]$schema, [ref]$schemaNumber)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('record has a non-numeric schema version "' + [string]$schema + '"') }
    }
    # schema >= current is NOT automatically valid: a newer writer may store
    # fields this version cannot interpret, so it is refused explicitly rather
    # than acted on with partial understanding.
    if ($schemaNumber -gt $script:ManagedRecordSchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('record uses unsupported schema version ' + $schemaNumber + ' (this version supports up to ' + $script:ManagedRecordSchemaVersion + ')') }
    }
    if ($schemaNumber -lt $script:ManagedRecordSchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('record uses old schema version ' + $schemaNumber + ' and needs migration') }
    }
    $scope = [string](Get-RecordField -Object $Record -Name 'scope')
    if ($scope -ne 'global' -and $scope -ne 'project') {
        return [pscustomobject]@{ Ok = $false; Reason = ('record has an invalid scope "' + $scope + '"') }
    }
    if ($scope -eq 'project') {
        $target = Get-RecordField -Object $Record -Name 'targetProjectRoot'
        if ($null -eq $target -or [string]::IsNullOrWhiteSpace([string]$target)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'project-scoped record has no targetProjectRoot' }
        }
    }
    $hookType = [string](Get-RecordField -Object $Record -Name 'hookType')
    if ($hookType -ne 'Engine' -and $hookType -ne 'CustomHook') {
        return [pscustomobject]@{ Ok = $false; Reason = ('record has an unknown hookType "' + $hookType + '"') }
    }
    if ($hookType -eq 'Engine') {
        foreach ($required in @('profile', 'configPath')) {
            $value = Get-RecordField -Object $Record -Name $required
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                return [pscustomobject]@{ Ok = $false; Reason = ('engine record is missing "' + $required + '"') }
            }
        }
    }
    # A legacy import (Get-LegacyHookCandidates) is a conservative, one-time
    # snapshot of a live registration Hook Maker discovered but has not yet
    # re-run the installer for - Get-InstallIntegrity's own 'imported'
    # fast-path above sends it straight to a real reinstall rather than
    # inspecting it further. Its clients deliberately carry an empty
    # command/commandWindows until that reinstall fills them in for real, so
    # the command-driven checks below (never the path/settings checks, which
    # ARE real for an import) do not apply to it - that gap is closed by
    # reinstalling, never by this validator guessing a value for it.
    $isImportedRecord = ($null -ne $Record.PSObject.Properties['imported']) -and ($Record.imported -eq $true)

    $clients = Get-RecordField -Object $Record -Name 'clients'
    if ($null -eq $clients -or $clients -isnot [psobject]) {
        return [pscustomobject]@{ Ok = $false; Reason = 'record has no clients object' }
    }
    # Derived from the canonical client table, never a hardcoded pair. The old
    # @('claude', 'codex') did not REJECT a third client's subrecord - it
    # `continue`d straight past it, so an untouched subrecord was persisted, updated
    # and uninstalled without a single field of it ever being proved.
    foreach ($clientName in @(Get-HookMakerClientIds)) {
        $client = Get-RecordField -Object $clients -Name $clientName
        if ($null -eq $client) { continue }
        # WHAT a subrecord must prove depends on how its client registers.
        # 'sharedSettingsFile' (claude, codex) is the shape every rule below was
        # written for. Every supported client shares one settings document, and
        # exactly two of those rules are FALSE FOR IT BY DESIGN:
        #   * there is no canonical shared settings path - Get-CanonicalClientSettingsPath
        #     throws for such a client, correctly, and that refusal is not weakened here;
        #   * the command targets the generated launcher, not <FriendlyName>.ps1.
        # Both are REPLACED with the equivalent per-hook-file proof rather than
        # skipped. Everything else applies unchanged to both shapes.
        # runtimeRoot joins runtimeScript/settingsPath here: Get-InstallIntegrity
        # reads it unguarded (via Get-InstalledManifest) for every client on
        # every evaluation, not only when something is already known to be wrong.
        # Every one of these must be an ACTUAL [string] - not merely something
        # that survives a [string] cast (a number, an object) - since each is
        # used directly as a path or command-line fragment.
        #
        # settingsPath stays required for a per-hook-file client too: it is the
        # registration file there rather than a shared document, and the
        # installed-hooks view reads `$subrecord.settingsPath` unguarded for
        # every client it enumerates.
        $requiredClientFields = @('runtimeScript', 'settingsPath', 'runtimeRoot')
        # registrationPath is the only location evidence a per-hook-file client
        # has - there is no shared settings document to re-derive it from.
        foreach ($required in $requiredClientFields) {
            $value = Get-RecordField -Object $client -Name $required
            if ($null -eq $value -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord is missing "' + $required + '"') }
            }
        }
        # command is required the same way for every genuinely installed
        # client. commandWindows carries the REAL Windows invocation only for
        # Codex - Claude's single `command` line already IS the Windows form
        # (see New-ClientSubrecord), so requiring commandWindows non-empty
        # there would reject every genuine Claude install, which never sets a
        # second form.
        if (-not $isImportedRecord) {
            $commandValue = Get-RecordField -Object $client -Name 'command'
            if ($null -eq $commandValue -or $commandValue -isnot [string] -or [string]::IsNullOrWhiteSpace($commandValue)) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord is missing "command"') }
            }
            if ($clientName -eq 'codex') {
                $commandWindowsValue = Get-RecordField -Object $client -Name 'commandWindows'
                if ($null -eq $commandWindowsValue -or $commandWindowsValue -isnot [string] -or [string]::IsNullOrWhiteSpace($commandWindowsValue)) {
                    return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord is missing "commandWindows"') }
                }
            }
        }
        $events = Get-RecordField -Object $client -Name 'events'
        if ($null -eq $events -or @($events).Count -eq 0) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord has no events') }
        }
        foreach ($eventEntry in @($events)) {
            if ($eventEntry -isnot [string]) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord events contains a non-string entry') }
            }
            if ([string]::IsNullOrWhiteSpace($eventEntry)) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord events contains an empty entry') }
            }
        }
        # timeout, when present, is cast with [int] during integrity evaluation -
        # a non-numeric value fails that cast, not a StrictMode property lookup,
        # so it needs its own type check rather than a presence check.
        $timeoutValue = Get-RecordField -Object $client -Name 'timeout'
        if ($null -ne $timeoutValue) {
            $parsedTimeout = 0
            if (-not [int]::TryParse([string]$timeoutValue, [ref]$parsedTimeout)) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord has a non-numeric timeout "' + [string]$timeoutValue + '"') }
            }
        }

        # ---- canonicalized structural consistency --------------------------
        # A path that cannot even be canonicalized is rejected here, precisely,
        # rather than throwing later inside Get-InstallIntegrity/Compare-Manifest.
        $canonicalRuntimeRoot = Get-CanonicalPathOrNull ([string]$client.runtimeRoot)
        if ($null -eq $canonicalRuntimeRoot) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord runtimeRoot cannot be canonicalized') }
        }
        $canonicalRuntimeScript = Get-CanonicalPathOrNull ([string]$client.runtimeScript)
        if ($null -eq $canonicalRuntimeScript) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord runtimeScript cannot be canonicalized') }
        }
        $canonicalSettingsPath = Get-CanonicalPathOrNull ([string]$client.settingsPath)
        if ($null -eq $canonicalSettingsPath) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord settingsPath cannot be canonicalized') }
        }

        # runtimeScript must be a PROPER child of runtimeRoot (not equal to it,
        # and not outside it) - Get-InstalledManifest walks runtimeRoot and
        # Compare-Manifest trusts runtimeScript's presence under it.
        if ([string]::Equals($canonicalRuntimeScript, $canonicalRuntimeRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-PathContainedIn -ChildPath $canonicalRuntimeScript -ParentPath $canonicalRuntimeRoot)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord runtimeScript is outside runtimeRoot') }
        }
        # ...and its PARENT must be a managed hook directory one level under
        # runtimeRoot (<runtimeRoot>\<FriendlyName>\<FriendlyName>.ps1), never
        # runtimeRoot itself - Copy-HookRuntime never installs a script
        # directly at the runtime root.
        $runtimeScriptParent = Split-Path -Parent $canonicalRuntimeScript
        if ([string]::Equals($runtimeScriptParent, $canonicalRuntimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord runtimeScript parent does not match managed hook directory') }
        }
        # ...and BOTH leaf names must still agree with the name this record
        # claims the installation has - parity with Uninstall-Hook.ps1's
        # Test-ClientRecordIdentity, which already refuses this. A record whose
        # friendlyName and runtimeScript disagree can never be safely acted on:
        # the updater would refresh a directory the uninstaller would then
        # decline to remove, so both gates must reject it identically.
        $friendlyNameValue = [string](Get-RecordField -Object $Record -Name 'friendlyName')
        $hookDirLeaf = Split-Path -Leaf $runtimeScriptParent
        $runtimeScriptLeaf = Split-Path -Leaf $canonicalRuntimeScript
        if (-not [string]::Equals($hookDirLeaf, $friendlyNameValue, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($runtimeScriptLeaf, ($friendlyNameValue + '.ps1'), [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord runtimeScript does not match managed hook directory for friendlyName "' + $friendlyNameValue + '"') }
        }

        # ---- registration location, and what the command must target -------

        # settingsPath must be the EXACT canonical location Install-Hook.ps1
        # would write to for this record's scope/client - never merely "some
        # settings file", which would let a record silently point updates or
        # uninstalls at the wrong client's (or a foreign) settings file.
        $targetProjectRootValue = [string](Get-RecordField -Object $Record -Name 'targetProjectRoot')
        # Get-CanonicalClientSettingsPath now THROWS for an unknown client and
        # for a per-hook-file client, both of which are correct refusals. This
        # function's contract is to RETURN { Ok; Reason }, though: a validator
        # that throws aborts the whole update run and leaves every healthy
        # record after it unevaluated, which is a regression this codebase has
        # already had once. So the refusal is turned into an ordinary rejection.
        $expectedSettingsPath = $null
        try { $expectedSettingsPath = Get-CanonicalClientSettingsPath -ClientName $clientName -Scope $scope -TargetProjectRoot $targetProjectRootValue }
        catch {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord has no canonical shared settings path for this client') }
        }
        $canonicalExpectedSettingsPath = Get-CanonicalPathOrNull $expectedSettingsPath
        if ($null -eq $canonicalExpectedSettingsPath -or
            -not [string]::Equals($canonicalSettingsPath, $canonicalExpectedSettingsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord settingsPath does not match project scope/client') }
        }

        # The persisted command(s) must actually target the persisted
        # runtimeScript - a record whose command points somewhere else could
        # never be safely "updated" (Get-InstallIntegrity's registration check
        # would be proving the wrong file is registered) or uninstalled
        # (ownership pruning matches by this same command/script pairing).
        if (-not $isImportedRecord) {
            $commandValue = [string]$client.command
            if ($commandValue.IndexOf($canonicalRuntimeScript, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord persisted command does not target persisted runtimeScript') }
            }
            $commandWindowsValue = Get-RecordField -Object $client -Name 'commandWindows'
            if ($null -ne $commandWindowsValue -and $commandWindowsValue -is [string] -and -not [string]::IsNullOrWhiteSpace($commandWindowsValue)) {
                if ($commandWindowsValue.IndexOf($canonicalRuntimeScript, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord persisted commandWindows does not target persisted runtimeScript') }
                }
            }
        }
    }
    $manifest = Get-RecordField -Object $Record -Name 'sourceManifest'
    if ($null -ne $manifest) {
        foreach ($entry in @($manifest)) {
            if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['path'] -or $null -eq $entry.PSObject.Properties['hash']) {
                return [pscustomobject]@{ Ok = $false; Reason = 'sourceManifest contains a malformed entry' }
            }
        }
    }
    # nativeGit shape is only ever read by Get-InstallIntegrity/Test-NativePrePushState
    # when managed=true; an unmanaged or absent nativeGit is never dereferenced.
    $nativeGit = Get-RecordField -Object $Record -Name 'nativeGit'
    if ($null -ne $nativeGit) {
        $nativeManaged = $false
        if ($null -ne $nativeGit.PSObject.Properties['managed']) { $nativeManaged = ($nativeGit.managed -eq $true) }
        if ($nativeManaged) {
            foreach ($required in @('wrapperPath', 'runtimeRoot')) {
                $value = Get-RecordField -Object $nativeGit -Name $required
                if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                    return [pscustomobject]@{ Ok = $false; Reason = ('managed nativeGit record is missing "' + $required + '"') }
                }
            }
            # companions is enumerated twice by Test-NativePrePushState (to build
            # the expected stage list and to rebuild the installed manifest), and
            # each entry is cast to a string used as a path segment - so the
            # collection shape AND every entry has to hold up, not just presence.
            $companionsProperty = $nativeGit.PSObject.Properties['companions']
            if ($null -eq $companionsProperty) {
                return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit record is missing "companions"' }
            }
            $companionsValue = $companionsProperty.Value
            if ($null -eq $companionsValue -or $companionsValue -is [string] -or
                $companionsValue -is [System.Collections.IDictionary] -or
                -not ($companionsValue -is [System.Collections.IEnumerable])) {
                return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "companions" is not an array' }
            }
            # Each companion becomes a PATH SEGMENT and a wrapper stage name, so
            # it must be an ACTUAL string - casting a number/object to string
            # would invent a path segment out of something that was never a name.
            foreach ($companion in @($companionsValue)) {
                if ($companion -isnot [string]) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "companions" contains a non-string entry' }
                }
                if ([string]::IsNullOrWhiteSpace($companion)) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "companions" contains an empty entry' }
                }
            }
            # sourceManifest is read UNGUARDED by Test-NativePrePushState
            # (`@($NativeRecord.sourceManifest)`), so a managed record without it
            # previously passed validation and then threw under StrictMode during
            # integrity evaluation - the exact "passes validation, fails later"
            # gap this validator exists to close.
            $nativeManifestProperty = $nativeGit.PSObject.Properties['sourceManifest']
            if ($null -eq $nativeManifestProperty) {
                return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit record is missing "sourceManifest"' }
            }
            $nativeManifestValue = $nativeManifestProperty.Value
            if ($null -eq $nativeManifestValue -or $nativeManifestValue -is [string] -or
                $nativeManifestValue -is [System.Collections.IDictionary] -or
                -not ($nativeManifestValue -is [System.Collections.IEnumerable])) {
                return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "sourceManifest" is not an array' }
            }
            foreach ($nativeEntry in @($nativeManifestValue)) {
                # A bare scalar (string/number) has no 'path'/'hash' properties,
                # so the property checks below reject it; requiring an object
                # first makes the intent explicit rather than incidental.
                if ($null -eq $nativeEntry -or $nativeEntry -is [string] -or
                    $nativeEntry -is [System.Collections.IEnumerable] -or
                    $null -eq $nativeEntry.PSObject.Properties['path'] -or
                    $null -eq $nativeEntry.PSObject.Properties['hash']) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "sourceManifest" contains a malformed entry' }
                }
                # path is compared and joined as a path - an ACTUAL string, not
                # a number/object that merely survives a [string] cast.
                $nativePath = $nativeEntry.path
                if ($nativePath -isnot [string]) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "sourceManifest" contains an entry whose path is not a string' }
                }
                if ([string]::IsNullOrWhiteSpace($nativePath)) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "sourceManifest" contains an entry with an empty path' }
                }
                # Compare-Manifest matches on the recorded hash. Get-FileSha256
                # returns (Get-FileHash -Algorithm SHA256).Hash, which is ALWAYS
                # exactly 64 hex characters - anything else (wrong length, non-hex,
                # or not even a string) could never equal a real hash and would
                # silently read as permanent drift instead of the malformed
                # record it actually is.
                $nativeHash = $nativeEntry.hash
                if ($nativeHash -isnot [string]) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "sourceManifest" contains an entry whose hash is not a string' }
                }
                if ($nativeHash -notmatch '^[0-9a-fA-F]{64}$') {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "sourceManifest" contains an entry whose hash is not a 64-character SHA-256 hex value' }
                }
            }
            # expectedStages, when present, is enumerated and each entry cast to
            # a string used to rebuild the wrapper body for an exact comparison.
            $stagesProperty = $nativeGit.PSObject.Properties['expectedStages']
            if ($null -ne $stagesProperty -and $null -ne $stagesProperty.Value) {
                $stagesValue = $stagesProperty.Value
                if ($stagesValue -is [string] -or $stagesValue -is [System.Collections.IDictionary] -or
                    -not ($stagesValue -is [System.Collections.IEnumerable])) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "expectedStages" is not an array' }
                }
                # Each stage name is used to rebuild the wrapper body for an
                # exact byte comparison, so it must be an ACTUAL string.
                foreach ($stage in @($stagesValue)) {
                    if ($stage -isnot [string]) {
                        return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "expectedStages" contains a non-string entry' }
                    }
                    if ([string]::IsNullOrWhiteSpace($stage)) {
                        return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "expectedStages" contains an empty entry' }
                    }
                }
            }
            # The preserved user hook is checked by path existence, and the
            # sticky flag is compared with -eq $true; a non-string path or a
            # non-boolean flag means the record cannot be interpreted safely.
            $previousPathProperty = $nativeGit.PSObject.Properties['previousHookPath']
            if ($null -ne $previousPathProperty -and $null -ne $previousPathProperty.Value -and
                $previousPathProperty.Value -isnot [string]) {
                return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "previousHookPath" is not a string' }
            }
            $preservedProperty = $nativeGit.PSObject.Properties['previousHookPreserved']
            if ($null -ne $preservedProperty -and $null -ne $preservedProperty.Value -and
                $preservedProperty.Value -isnot [bool]) {
                return [pscustomobject]@{ Ok = $false; Reason = 'managed nativeGit "previousHookPreserved" is not a boolean' }
            }
        }
    }
    # lastComponents entries are read unguarded (.component/.status/.reason) by
    # Set-InstallRecord when present; a null or shapeless entry crashes that read.
    $lastComponents = Get-RecordField -Object $Record -Name 'lastComponents'
    if ($null -ne $lastComponents) {
        foreach ($entry in @($lastComponents)) {
            if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['component'] -or
                $null -eq $entry.PSObject.Properties['status'] -or $null -eq $entry.PSObject.Properties['reason']) {
                return [pscustomobject]@{ Ok = $false; Reason = 'lastComponents contains a malformed entry' }
            }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}