# ---------------------------------------------------------------------------
# Discovered-record layer: the identity, validation, and merge rules for the
# records the read-only status scan FOUND, as opposed to the managed records
# Install-Hook.ps1 wrote and owns.
#
# Split out of _installregistry.ps1 (which had grown past the file-size review
# signal) along the seam that file already documents: a discovered record
# shares nothing with a managed record but the file it is stored in, so it
# carries its own id derivation, its own field validators, and its own merge
# rules against the managed set.
#
# Dot-sourced by _installregistry.ps1 itself, near its top, so every existing
# consumer (Install-Hook.ps1, Setup-SyncGroup.ps1, Validate-Config.ps1,
# Uninstall-Hook.ps1, Get-HookStatus.ps1, and the test suites) keeps
# dot-sourcing ONLY _installlib.ps1 and needs zero changes.
#
# Cross-file note: dot-sourcing puts _installlib.ps1, _installregistry.ps1 and
# this file in ONE script scope, so the functions below see
# $script:DiscoveredRecordSchemaVersion (defined in _installlib.ps1),
# _installregistry.ps1's record-kind predicates (Test-IsDiscoveredRecord,
# Test-IsManagedRecord) and _installvalidate.ps1's Get-CanonicalPathOrNull.
# Every one of those resolves at CALL time, so load order among the three
# files does not matter - this is a normal one-directional dependency.
# ---------------------------------------------------------------------------

# The shared identity layer (Get-Sha256Hex, Get-CanonicalPathKey, ...). The
# discovered-record id MUST be computed with exactly the same hashing the
# scanner and the remover use, so it is reused here rather than reimplemented.
# Dot-sourcing it twice (Get-HookStatus.ps1 loads it directly) is harmless - it
# only defines functions and depends on nothing but the BCL.
. (Join-Path $PSScriptRoot '_hookdiscovery.ps1')

# ---- discovered records: identity, validation, merge -----------------------
#
# A discovered record describes a hook the read-only status scan FOUND; Hook
# Maker did not install it and may not own it. It therefore shares nothing with
# a managed record but the file it is stored in, and has its own id derivation,
# its own validator, and its own merge rules.

$script:DiscoveredHookTypes = @('ClaudeRegistration', 'CodexRegistration', 'NativeGitHook')
$script:DiscoveredStatuses = @('active', 'missingTarget', 'registrationOnly', 'sharedRuntime', 'orphanCandidate', 'ambiguous', 'manualRepair', 'notSeen')
$script:DiscoveredManagedByValues = @('hookMaker', 'external', 'unknown')
$script:DiscoveredRemovalPolicies = @('full', 'registrationOnly', 'nativeFileOnly', 'unavailable')
$script:DiscoveredClientNames = @('claude', 'codex')
$script:DiscoveredRegistrationStatuses = @('parsed', 'unparsedCommand', 'fieldsDisagree', 'targetMissing')
$script:DiscoveredNativeClassifications = @('hookMakerWrapper', 'externalNativeHook', 'ambiguous')
$script:DiscoveredArtifactClassifications = @('registeredRuntime', 'sharedRuntime', 'registrationOnly', 'missingTarget', 'orphanRuntimeCandidate', 'ambiguous')
$script:DiscoveredArtifactEligibility = @('eligible', 'preserve')
# A raw command line can embed a token or an expanded secret-bearing environment
# value, so a discovered record persists the FINGERPRINT instead and never the
# text. The mere presence of one of these field names is a validation failure -
# a rule, not a convention, so it cannot quietly erode.
$script:DiscoveredForbiddenFieldNames = @('command', 'commandWindows', 'command_windows')

# ---- discovered field primitives -------------------------------------------
# Each returns '' when the field holds up, or a precise English reason. They
# never throw: every lookup is guarded, because these run over records another
# writer may have produced.

function Test-DiscoveredStringField {
    param($Object, [string]$Name, [string]$Label, [switch]$AllowEmpty)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ($Label + ' is missing the required field "' + $Name + '"') }
    $value = $property.Value
    # An ACTUAL [string] - not merely something that survives a [string] cast.
    # Every one of these becomes a path, an id or display text.
    if ($value -isnot [string]) { return ($Label + ' field "' + $Name + '" is not a string') }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) { return ($Label + ' field "' + $Name + '" is empty') }
    return ''
}

function Test-DiscoveredArrayField {
    param($Object, [string]$Name, [string]$Label)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ($Label + ' is missing the required field "' + $Name + '"') }
    $value = $property.Value
    # A string is IEnumerable (over its characters) and a hashtable is not a
    # sequence of entries, so both are rejected rather than silently enumerated.
    if ($null -eq $value -or $value -is [string] -or $value -is [System.Collections.IDictionary] -or
        -not ($value -is [System.Collections.IEnumerable])) {
        return ($Label + ' field "' + $Name + '" is not an array')
    }
    return ''
}

function Test-DiscoveredEnumField {
    param($Object, [string]$Name, [string[]]$Allowed, [string]$Label)
    $reason = Test-DiscoveredStringField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    if (@($Allowed) -notcontains [string]$Object.$Name) {
        return ($Label + ' field "' + $Name + '" has the unsupported value "' + [string]$Object.$Name + '"')
    }
    return ''
}

function Test-DiscoveredUtcTimestampField {
    param($Object, [string]$Name, [string]$Label)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return ($Label + ' is missing the required field "' + $Name + '"') }
    # ConvertFrom-Json turns an ISO-8601 timestamp back into a real [datetime],
    # so the SAME record is a string on disk and a datetime once read back.
    # Rejecting the deserialized form would reject every persisted record; both
    # are accepted, and both must still PROVE they are UTC rather than a local
    # or zone-less reading.
    if ($property.Value -is [datetime]) {
        if ($property.Value.Kind -ne [System.DateTimeKind]::Utc) {
            return ($Label + ' field "' + $Name + '" is not an ISO 8601 UTC timestamp')
        }
        return ''
    }
    if ($property.Value -is [datetimeoffset]) {
        if ($property.Value.Offset -ne [System.TimeSpan]::Zero) {
            return ($Label + ' field "' + $Name + '" is not an ISO 8601 UTC timestamp')
        }
        return ''
    }
    $reason = Test-DiscoveredStringField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    $value = [string]$Object.$Name
    # An explicit zone is REQUIRED: "when was this last seen" must never be
    # ambiguous, and a bare local timestamp cannot be proven to be UTC.
    if ($value -notmatch '(Z|[+-]\d{2}:?\d{2})$') {
        return ($Label + ' field "' + $Name + '" is not an ISO 8601 UTC timestamp')
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return ($Label + ' field "' + $Name + '" is not a parseable timestamp')
    }
    return ''
}

function Test-DiscoveredStringArrayField {
    param($Object, [string]$Name, [string]$Label, [switch]$AllowEmptyEntries)
    $reason = Test-DiscoveredArrayField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    foreach ($entry in @($Object.$Name)) {
        if ($entry -isnot [string]) { return ($Label + ' field "' + $Name + '" contains a non-string entry') }
        if (-not $AllowEmptyEntries -and [string]::IsNullOrWhiteSpace($entry)) {
            return ($Label + ' field "' + $Name + '" contains an empty entry')
        }
    }
    return ''
}

# Every fingerprint this layer stores comes from Get-Sha256Hex, which always
# returns exactly 64 hex characters. Anything else could never match a
# recomputed fingerprint and would read as a permanent mismatch instead of the
# malformed record it actually is.
function Test-DiscoveredFingerprintArrayField {
    param($Object, [string]$Name, [string]$Label)
    $reason = Test-DiscoveredStringArrayField -Object $Object -Name $Name -Label $Label
    if ($reason -ne '') { return $reason }
    foreach ($entry in @($Object.$Name)) {
        if ($entry -notmatch '^[0-9a-fA-F]{64}$') {
            return ($Label + ' field "' + $Name + '" contains a value that is not a 64-character SHA-256 hex fingerprint')
        }
    }
    return ''
}

function Test-DiscoveredCanonicalPathField {
    param($Object, [string]$Name, [string]$Label, [switch]$AllowEmpty)
    $reason = Test-DiscoveredStringField -Object $Object -Name $Name -Label $Label -AllowEmpty:$AllowEmpty
    if ($reason -ne '') { return $reason }
    $value = [string]$Object.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    if ($null -eq (Get-CanonicalPathOrNull $value)) {
        return ($Label + ' field "' + $Name + '" cannot be canonicalized')
    }
    return ''
}

function Test-DiscoveredNoRawCommand {
    param($Object, [string]$Label)
    foreach ($forbidden in $script:DiscoveredForbiddenFieldNames) {
        if ($null -ne $Object.PSObject.Properties[$forbidden]) {
            return ($Label + ' persists a raw command in "' + $forbidden + '"; only fingerprints may be stored')
        }
    }
    return ''
}

# ---- stable discovered id ---------------------------------------------------

# SHA-256 over canonical, NON-SECRET identity inputs, prefixed 'disc-' plus the
# first 32 hex characters.
#
# The same unchanged installation rescanned must produce the SAME id, so every
# path component is reduced to its canonical case-insensitive key (Windows paths
# are case-insensitive; the same file typed two ways is one file) and the
# fingerprint list is sorted - a settings file whose handlers were merely
# reordered is not a different hook.
#
# Conversely two same-named hooks at DIFFERENT paths must produce different ids,
# which is why the path is part of the identity and the friendly name is not:
# an id is never derived from a display name or a basename.
function Get-DiscoveredRecordId {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('registration', 'native')][string]$Kind,
        [string]$Scope = '',
        [string]$TargetProjectRoot = '',
        [string]$Client = '',
        [string]$SettingsPath = '',
        [string[]]$HandlerFingerprints = @(),
        [string]$RepositoryRoot = '',
        [string]$HookPath = '',
        [string]$HookName = ''
    )
    if ($Kind -eq 'native') {
        $parts = @(
            'discovered'
            (Get-CanonicalPathKey -Path $RepositoryRoot)
            (Get-CanonicalPathKey -Path $HookPath)
            ([string]$HookName).ToLowerInvariant()
        )
    }
    else {
        $sortedFingerprints = @(@($HandlerFingerprints) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object -CaseSensitive)
        $parts = @(
            'discovered'
            ([string]$Scope).ToLowerInvariant()
            (Get-CanonicalPathKey -Path $TargetProjectRoot)
            ([string]$Client).ToLowerInvariant()
            (Get-CanonicalPathKey -Path $SettingsPath)
            ($sortedFingerprints -join ',')
        )
    }
    return ('disc-' + (Get-Sha256Hex -Text ($parts -join '|')).Substring(0, 32))
}

# ---- discovered record validation ------------------------------------------

# Proves a DISCOVERED record's shape before anything reads its fields. A managed
# record is refused outright here, exactly as a discovered record is refused by
# the managed path - the two shapes share no rules and accepting one under the
# other's contract would let an unvalidated field reach a consumer.
function Test-DiscoveredRecordValid {
    param($Record)

    if ($null -eq $Record) { return [pscustomobject]@{ Ok = $false; Reason = 'record is null' } }
    if ($Record -isnot [psobject]) { return [pscustomobject]@{ Ok = $false; Reason = 'record is not an object' } }
    if (-not (Test-IsDiscoveredRecord -Record $Record)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'record is not a discovered record' }
    }

    $label = 'discovered record'
    $reasons = New-Object System.Collections.Generic.List[string]

    # ---- schema ------------------------------------------------------------
    $schemaProperty = $Record.PSObject.Properties['schema']
    if ($null -eq $schemaProperty) { return [pscustomobject]@{ Ok = $false; Reason = 'discovered record has no schema version' } }
    $schemaNumber = 0
    if (-not [int]::TryParse([string]$schemaProperty.Value, [ref]$schemaNumber)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('discovered record has a non-numeric schema version "' + [string]$schemaProperty.Value + '"') }
    }
    if ($schemaNumber -gt $script:DiscoveredRecordSchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('discovered record uses unsupported schema version ' + $schemaNumber + ' (this version supports up to ' + $script:DiscoveredRecordSchemaVersion + ')') }
    }
    if ($schemaNumber -lt $script:DiscoveredRecordSchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('discovered record uses old schema version ' + $schemaNumber + ' and needs migration') }
    }

    # ---- required scalars, enums and timestamps ----------------------------
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'id' -Label $label))
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'friendlyName' -Label $label))
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'lastScanId' -Label $label))
    [void]$reasons.Add((Test-DiscoveredStringField -Object $Record -Name 'statusReason' -Label $label -AllowEmpty))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'recordType' -Allowed @('discovered') -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'origin' -Allowed @('statusScan') -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'hookType' -Allowed $script:DiscoveredHookTypes -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'scope' -Allowed @('project', 'global') -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'status' -Allowed $script:DiscoveredStatuses -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'managedBy' -Allowed $script:DiscoveredManagedByValues -Label $label))
    [void]$reasons.Add((Test-DiscoveredEnumField -Object $Record -Name 'removalPolicy' -Allowed $script:DiscoveredRemovalPolicies -Label $label))
    [void]$reasons.Add((Test-DiscoveredUtcTimestampField -Object $Record -Name 'firstSeenUtc' -Label $label))
    [void]$reasons.Add((Test-DiscoveredUtcTimestampField -Object $Record -Name 'lastSeenUtc' -Label $label))
    # targetProjectRoot is '' for a global record, so it is allowed to be empty
    # here and required non-empty by the scope rule below.
    [void]$reasons.Add((Test-DiscoveredCanonicalPathField -Object $Record -Name 'targetProjectRoot' -Label $label -AllowEmpty))
    [void]$reasons.Add((Test-DiscoveredStringArrayField -Object $Record -Name 'scanRoots' -Label $label))
    [void]$reasons.Add((Test-DiscoveredArrayField -Object $Record -Name 'clients' -Label $label))
    [void]$reasons.Add((Test-DiscoveredArrayField -Object $Record -Name 'runtimeArtifacts' -Label $label))
    [void]$reasons.Add((Test-DiscoveredNoRawCommand -Object $Record -Label $label))
    foreach ($reason in $reasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }

    $needsRepairProperty = $Record.PSObject.Properties['needsManualRepair']
    if ($null -eq $needsRepairProperty) {
        return [pscustomobject]@{ Ok = $false; Reason = 'discovered record is missing the required field "needsManualRepair"' }
    }
    if ($needsRepairProperty.Value -isnot [bool]) {
        return [pscustomobject]@{ Ok = $false; Reason = 'discovered record field "needsManualRepair" is not a boolean' }
    }
    if ([string]$Record.scope -eq 'project' -and [string]::IsNullOrWhiteSpace([string]$Record.targetProjectRoot)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'project-scoped discovered record has no targetProjectRoot' }
    }

    # ---- per-client evidence -----------------------------------------------
    foreach ($client in @($Record.clients)) {
        $clientLabel = 'discovered client evidence'
        if ($null -eq $client -or $client -isnot [psobject] -or $client -is [string]) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientLabel + ' contains a malformed entry') }
        }
        $clientReasons = @(
            (Test-DiscoveredEnumField -Object $client -Name 'client' -Allowed $script:DiscoveredClientNames -Label $clientLabel)
            (Test-DiscoveredCanonicalPathField -Object $client -Name 'settingsPath' -Label $clientLabel)
            (Test-DiscoveredEnumField -Object $client -Name 'registrationStatus' -Allowed $script:DiscoveredRegistrationStatuses -Label $clientLabel)
            (Test-DiscoveredStringArrayField -Object $client -Name 'events' -Label $clientLabel)
            (Test-DiscoveredStringArrayField -Object $client -Name 'handlerTypes' -Label $clientLabel -AllowEmptyEntries)
            (Test-DiscoveredStringArrayField -Object $client -Name 'commandFieldNames' -Label $clientLabel)
            (Test-DiscoveredStringArrayField -Object $client -Name 'parsedTargets' -Label $clientLabel)
            (Test-DiscoveredFingerprintArrayField -Object $client -Name 'handlerFingerprints' -Label $clientLabel)
            (Test-DiscoveredFingerprintArrayField -Object $client -Name 'matcherFingerprints' -Label $clientLabel)
            (Test-DiscoveredNoRawCommand -Object $client -Label $clientLabel)
        )
        foreach ($reason in $clientReasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }
        foreach ($target in @($client.parsedTargets)) {
            if ($null -eq (Get-CanonicalPathOrNull ([string]$target))) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientLabel + ' field "parsedTargets" contains a path that cannot be canonicalized') }
            }
        }
    }

    # ---- native evidence (optional; $null when this is not a native record) --
    $nativeProperty = $Record.PSObject.Properties['nativeGit']
    if ($null -eq $nativeProperty) {
        return [pscustomobject]@{ Ok = $false; Reason = 'discovered record is missing the required field "nativeGit"' }
    }
    $native = $nativeProperty.Value
    if ($null -ne $native) {
        $nativeLabel = 'discovered nativeGit evidence'
        if ($native -isnot [psobject] -or $native -is [string]) {
            return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' is not an object') }
        }
        $nativeReasons = @(
            (Test-DiscoveredCanonicalPathField -Object $native -Name 'repositoryRoot' -Label $nativeLabel)
            (Test-DiscoveredCanonicalPathField -Object $native -Name 'hooksPath' -Label $nativeLabel)
            (Test-DiscoveredCanonicalPathField -Object $native -Name 'hookPath' -Label $nativeLabel)
            (Test-DiscoveredStringField -Object $native -Name 'hookName' -Label $nativeLabel)
            (Test-DiscoveredEnumField -Object $native -Name 'classification' -Allowed $script:DiscoveredNativeClassifications -Label $nativeLabel)
            # managedStages is only ever populated when the canonical wrapper
            # parser PROVES the stages, so an empty array is normal and valid.
            (Test-DiscoveredStringArrayField -Object $native -Name 'managedStages' -Label $nativeLabel)
            (Test-DiscoveredNoRawCommand -Object $native -Label $nativeLabel)
        )
        foreach ($reason in $nativeReasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }
        # hookHash is '' when the file could not be read - a real state, not a
        # malformed one - but any non-empty value must be a genuine SHA-256.
        $hashReason = Test-DiscoveredStringField -Object $native -Name 'hookHash' -Label $nativeLabel -AllowEmpty
        if ($hashReason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $hashReason } }
        if (-not [string]::IsNullOrWhiteSpace([string]$native.hookHash) -and [string]$native.hookHash -notmatch '^[0-9a-fA-F]{64}$') {
            return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' field "hookHash" is not a 64-character SHA-256 hex value') }
        }
        $sizeProperty = $native.PSObject.Properties['hookSize']
        if ($null -eq $sizeProperty) { return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' is missing the required field "hookSize"') } }
        $parsedSize = [long]0
        if (-not [long]::TryParse([string]$sizeProperty.Value, [ref]$parsedSize)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($nativeLabel + ' field "hookSize" is not numeric') }
        }
        $modifiedReason = Test-DiscoveredUtcTimestampField -Object $native -Name 'hookModifiedUtc' -Label $nativeLabel
        if ($modifiedReason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $modifiedReason } }
    }

    # ---- runtime artifacts --------------------------------------------------
    foreach ($artifact in @($Record.runtimeArtifacts)) {
        $artifactLabel = 'discovered runtime artifact'
        if ($null -eq $artifact -or $artifact -isnot [psobject] -or $artifact -is [string]) {
            return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' contains a malformed entry') }
        }
        $artifactReasons = @(
            (Test-DiscoveredCanonicalPathField -Object $artifact -Name 'path' -Label $artifactLabel)
            (Test-DiscoveredStringField -Object $artifact -Name 'kind' -Label $artifactLabel)
            (Test-DiscoveredEnumField -Object $artifact -Name 'classification' -Allowed $script:DiscoveredArtifactClassifications -Label $artifactLabel)
            (Test-DiscoveredEnumField -Object $artifact -Name 'deleteEligibility' -Allowed $script:DiscoveredArtifactEligibility -Label $artifactLabel)
            (Test-DiscoveredStringField -Object $artifact -Name 'deleteReason' -Label $artifactLabel -AllowEmpty)
            (Test-DiscoveredStringArrayField -Object $artifact -Name 'referencedBy' -Label $artifactLabel)
            (Test-DiscoveredStringField -Object $artifact -Name 'hash' -Label $artifactLabel -AllowEmpty)
            (Test-DiscoveredNoRawCommand -Object $artifact -Label $artifactLabel)
        )
        foreach ($reason in $artifactReasons) { if ($reason -ne '') { return [pscustomobject]@{ Ok = $false; Reason = $reason } } }
        if (-not [string]::IsNullOrWhiteSpace([string]$artifact.hash) -and [string]$artifact.hash -notmatch '^[0-9a-fA-F]{64}$') {
            return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' field "hash" is not a 64-character SHA-256 hex value') }
        }
        $artifactSizeProperty = $artifact.PSObject.Properties['size']
        if ($null -eq $artifactSizeProperty) { return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' is missing the required field "size"') } }
        $parsedArtifactSize = [long]0
        if (-not [long]::TryParse([string]$artifactSizeProperty.Value, [ref]$parsedArtifactSize)) {
            return [pscustomobject]@{ Ok = $false; Reason = ($artifactLabel + ' field "size" is not numeric') }
        }
    }

    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# ---- discovered record merge ------------------------------------------------

# Every path a managed client subrecord actually REGISTERED, taken from the
# command it wrote rather than from runtimeScript alone.
#
# For a per-hook-file client those two are deliberately different: the
# registration launches the hook's shim, `<hook>\<client>-launch.ps1`, while
# runtimeScript names the hook script itself. Comparing only runtimeScript
# therefore never matched such a registration, so every affected install was ALSO
# kept as a `discovered` record - a duplicate of Hook Maker's own hook that the
# uninstall screen then listed as unremovable ("per-hook-file removal is not
# implemented"). A real registry had 510 of them, and they were most of the
# list.
function Get-ManagedRegisteredTargets {
    param($Subrecord)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('command', 'commandWindows')) {
        $property = $Subrecord.PSObject.Properties[$field]
        if ($null -eq $property) { continue }
        $text = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        foreach ($match in @([regex]::Matches($text, '-File\s+"([^"]+)"'))) {
            $key = Get-CanonicalPathKey -Path ([string]$match.Groups[1].Value)
            if ($key -ne '' -and -not $keys.Contains($key)) { [void]$keys.Add($key) }
        }
    }
    return $keys.ToArray()
}

# Does a MANAGED record already account for this discovered finding? Decided on
# EVIDENCE (the settings file plus the script actually registered, or the exact
# wrapper path), never on a friendly name - two different hooks can share a
# name, and the same hook can be registered under two.
function Test-DiscoveredCoveredByManaged {
    param([Parameter(Mandatory = $true)]$Registry, [Parameter(Mandatory = $true)]$Record)
    foreach ($managed in @($Registry.installs)) {
        if ($null -eq $managed -or -not (Test-IsManagedRecord -Record $managed)) { continue }

        # Native: the managed wrapper IS the discovered hook file.
        $nativeProperty = $Record.PSObject.Properties['nativeGit']
        if ($null -ne $nativeProperty -and $null -ne $nativeProperty.Value) {
            $discoveredHookKey = Get-CanonicalPathKey -Path ([string]$nativeProperty.Value.hookPath)
            $managedNativeProperty = $managed.PSObject.Properties['nativeGit']
            if ($discoveredHookKey -ne '' -and $null -ne $managedNativeProperty -and $null -ne $managedNativeProperty.Value) {
                $managedNative = $managedNativeProperty.Value
                $wrapperProperty = $managedNative.PSObject.Properties['wrapperPath']
                if ($null -ne $wrapperProperty -and
                    (Get-CanonicalPathKey -Path ([string]$wrapperProperty.Value)) -eq $discoveredHookKey) {
                    return $managed
                }
            }
        }

        # Registration: same settings file AND the managed runtime script is one
        # of the targets this registration actually resolves to.
        foreach ($clientEvidence in @($Record.clients)) {
            if ($null -eq $clientEvidence) { continue }
            $clientName = [string]$clientEvidence.client
            $subrecord = $null
            if ($null -ne $managed.PSObject.Properties['clients'] -and $null -ne $managed.clients -and
                $null -ne $managed.clients.PSObject.Properties[$clientName]) {
                $subrecord = $managed.clients.$clientName
            }
            if ($null -eq $subrecord) { continue }
            $settingsProperty = $subrecord.PSObject.Properties['settingsPath']
            $scriptProperty = $subrecord.PSObject.Properties['runtimeScript']
            if ($null -eq $settingsProperty -or $null -eq $scriptProperty) { continue }
            $managedSettingsKey = Get-CanonicalPathKey -Path ([string]$settingsProperty.Value)
            if ($managedSettingsKey -eq '' -or
                $managedSettingsKey -ne (Get-CanonicalPathKey -Path ([string]$clientEvidence.settingsPath))) { continue }
            # The settings file already matched exactly; a target match against
            # anything this managed record itself registered proves the same
            # install, so a foreign hook in the same file can never be claimed.
            $managedKeys = New-Object System.Collections.Generic.List[string]
            $managedScriptKey = Get-CanonicalPathKey -Path ([string]$scriptProperty.Value)
            if ($managedScriptKey -ne '') { [void]$managedKeys.Add($managedScriptKey) }
            foreach ($registered in @(Get-ManagedRegisteredTargets -Subrecord $subrecord)) {
                if (-not $managedKeys.Contains($registered)) { [void]$managedKeys.Add($registered) }
            }
            if ($managedKeys.Count -eq 0) { continue }
            foreach ($target in @($clientEvidence.parsedTargets)) {
                if ($managedKeys.Contains((Get-CanonicalPathKey -Path ([string]$target)))) { return $managed }
            }
        }
    }
    return $null
}

# Merges ONE freshly discovered record into the registry and reports what it
# decided. Action is one of:
#
#   added             a hook nothing tracked before
#   updated           the SAME hook seen again - its id already exists
#   coveredByManaged  a managed install already accounts for it; nothing is
#                     written, so a hook Hook Maker owns can never be duplicated
#                     as a foreign discovery
#   rejected          the record does not hold up (invalid, or claims notSeen
#                     from a scan that did not actually cover everything)
#
# On update, firstSeenUtc is the ONE field carried forward from the stored
# record: it answers "since when has this existed", which a later scan cannot
# re-derive. Everything else - lastSeenUtc, lastScanId, scanRoots, status,
# hashes, evidence - is refreshed from the new observation.
function Merge-DiscoveredRecord {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)]$Record,
        # Whether the scan that produced this record covered every root it
        # claimed. A partial scan (access denied, path too long, a skipped
        # reparse point) has NOT proven a hook is gone.
        [switch]$CoverageComplete
    )
    $validation = Test-DiscoveredRecordValid -Record $Record
    if (-not $validation.Ok) {
        return [pscustomobject]@{ Action = 'rejected'; Reason = $validation.Reason; Record = $null; ManagedRecord = $null }
    }
    # "Not seen" is a claim about ABSENCE, and absence can only be proven by a
    # scan that actually reached everywhere. Accepting it from a partial scan is
    # how a live hook gets written off as gone.
    if ([string]$Record.status -eq 'notSeen' -and -not $CoverageComplete) {
        return [pscustomobject]@{
            Action = 'rejected'
            Reason = 'a record cannot be marked notSeen by a scan whose coverage was incomplete'
            Record = $null; ManagedRecord = $null
        }
    }

    $managed = Test-DiscoveredCoveredByManaged -Registry $Registry -Record $Record
    if ($null -ne $managed) {
        # Retire any discovered record for this SAME id. The coverage test above
        # matches on exact paths (a native wrapper path, or a settings path plus
        # the runtime target the registration actually resolves to), and the id
        # is derived from those same paths - so such a record describes the very
        # artifact the managed record owns. It is a duplicate, not a second hook.
        #
        # Left in place it becomes a ghost that can never be cleaned up: this
        # branch returns before the update below, so the record is never
        # refreshed; the scan's demotion pass then marks it notSeen ("no longer
        # present") even though the file is right there; and the uninstall list
        # offers a row whose removal can never be proven, because the on-disk
        # evidence it would need now belongs to the managed record. Eight such
        # rows accumulated in a real registry after hooks were reinstalled over
        # paths a previous scan had discovered.
        #
        # Id first, THEN the record-kind test: this runs once per covered finding
        # against the whole registry (on a real one, ~1000 findings x ~1100
        # records), so the per-candidate work has to stay a string compare, and
        # the array is only rebuilt when a duplicate is actually there.
        $before = @($Registry.installs)
        for ($i = 0; $i -lt $before.Count; $i++) {
            $candidate = $before[$i]
            if ($null -eq $candidate -or [string]$candidate.id -ne [string]$Record.id) { continue }
            if (-not (Test-IsDiscoveredRecord -Record $candidate)) { continue }
            $kept = New-Object System.Collections.Generic.List[object]
            for ($j = 0; $j -lt $before.Count; $j++) { if ($j -ne $i) { [void]$kept.Add($before[$j]) } }
            $Registry.installs = $kept.ToArray()
            break
        }
        return [pscustomobject]@{
            Action = 'coveredByManaged'
            Reason = ('already tracked as the managed install "' + [string]$managed.friendlyName + '"')
            Record = $null; ManagedRecord = $managed
        }
    }

    $existingList = @($Registry.installs)
    for ($i = 0; $i -lt $existingList.Count; $i++) {
        $candidate = $existingList[$i]
        if ($null -eq $candidate -or -not (Test-IsDiscoveredRecord -Record $candidate)) { continue }
        if ([string]$candidate.id -ne [string]$Record.id) { continue }
        $firstSeenProperty = $candidate.PSObject.Properties['firstSeenUtc']
        if ($null -ne $firstSeenProperty -and -not [string]::IsNullOrWhiteSpace([string]$firstSeenProperty.Value)) {
            # NOT [string]: that renders a deserialized [datetime] in the current
            # culture and permanently destroys the ISO 8601 form, which is what
            # made every carried-forward discovered record unremovable.
            Set-ObjectProperty -Object $Record -Name 'firstSeenUtc' -Value (ConvertTo-RegistryUtcTimestamp -Value $firstSeenProperty.Value)
        }
        $existingList[$i] = $Record
        $Registry.installs = $existingList
        return [pscustomobject]@{ Action = 'updated'; Reason = ''; Record = $Record; ManagedRecord = $null }
    }

    $Registry.installs = @(@($existingList) + @($Record))
    return [pscustomobject]@{ Action = 'added'; Reason = ''; Record = $Record; ManagedRecord = $null }
}
