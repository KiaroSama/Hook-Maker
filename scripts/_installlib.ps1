# ---------------------------------------------------------------------------
# Install-state library: the machine-local registry of what Hook Maker has
# installed and where, plus everything needed to decide whether an install is
# still intact ("Update previously installed hooks").
#
# Lives in scripts\ (NOT hooks\) on purpose: this is install-time-only logic.
# hooks\_hooklib.ps1 is COPIED into every self-contained runtime, so registry
# code must not live there - a runtime hook never reads the registry.
#
# Dot-sourced by Install-Hook.ps1 and Setup-SyncGroup.ps1. Requires
# hooks\_hooklib.ps1 to be dot-sourced FIRST (Get-ShortHash, Read-JsonFile,
# Write-JsonFileAtomic, Set-ObjectProperty).
#
# Registry file: <ToolRoot>\state\install-registry.json (git-ignored;
# $env:HOOKMAKER_STATE_DIR overrides the directory for test isolation).
# Stores ONLY paths, hashes, and install parameters - never .env values, hook
# stdin, prompt text, tool input, secrets, or any copied file's contents.
# ---------------------------------------------------------------------------

# The REGISTRY FILE's schema version. v3 introduced discriminated records: the
# file may now hold managed install records (written by Install-Hook.ps1) and
# discovered records (written by the read-only status scan) side by side, told
# apart by their `recordType` field.
$script:InstallRegistrySchemaVersion = 3

# A RECORD's own `schema` version is NOT the registry's. They were the same
# number until v3 and are deliberately separated now:
#
#   * a managed record's shape did not change in v3 - it only GAINED
#     recordType/origin - so it stays at 2. Bumping it would have declared every
#     record written by every shipped Install-Hook.ps1 "in need of migration".
#   * a discovered record is new in v3 and carries 3.
#
# Test-InstallRecordValid compares against the MANAGED number and
# Test-DiscoveredRecordValid against the DISCOVERED one, so each record kind is
# held to exactly its own contract.
$script:ManagedRecordSchemaVersion = 2
$script:DiscoveredRecordSchemaVersion = 3

# ---- per-hook registration timeout ----------------------------------------
# BOTH clients document `timeout` as a field of the INDIVIDUAL hook entry, not
# of the event group or the file, so a per-hook value is safe to write:
#   * Claude Code hooks reference, hook-object field table: "timeout | no |
#     Seconds before canceling. Defaults: 600 for `command` ...".
#   * Codex hooks reference, "Config shape": "`timeout` is in seconds. If
#     `timeout` is omitted, Codex uses `600` seconds."
# Neither client documents a minimum or a maximum, so the bounds below are
# Hook Maker's own conservative policy rather than a client limit: a hook must
# be fast, and a registration that can stall a client for longer than the
# clients' own 600s default is a defect, not a configuration choice.
#
# 60 remains the DEFAULT for every hook that does not ask for its own value -
# it is what every previously shipped install wrote, and changing it would
# silently rewrite existing registrations.
$script:DefaultHookTimeoutSeconds = 60
$script:MinHookTimeoutSeconds = 5
$script:MaxHookTimeoutSeconds = 600

# Files that exist inside a managed runtime directory but are NOT part of the
# installed identity: generated at install time from inputs already covered by
# the manifest (SYNC-PROJECTS.txt is derived from sync-hooks.json), or mutated
# at runtime. Comparing them would report permanent false drift.
# RUNTIME-MUTABLE ARTIFACTS ARE DECLARED BY EXACT RELATIVE PATH, never by a
# broad extension rule.
#
# The previous `.log`/`.tmp`/`.bak` extension exclusions plus a hard-coded
# 'SYNC-PROJECTS.txt' name exclusion were a SECOND source of truth that
# disagreed with the install plan: the plan generates SYNC-PROJECTS.txt (so it
# is expected) while the scanner skipped it (so it was never found), which made
# every sync-engine install report "installed file missing: sync-projects.txt"
# forever - a permanent update loop, reproduced end-to-end.
#
# The plan is now the only authority. This list exists so that a genuinely
# runtime-written file can be declared explicitly if one is ever introduced;
# no shipped hook writes into its own runtime directory today (hook state lives
# under %LOCALAPPDATA%), so it is intentionally empty.
$script:ManagedRuntimeMutablePaths = @()
# Never copied into a runtime, so never part of a manifest.
$script:ManagedSourceExcludedNames = @('.env.example')

# Registry-persistence layer (storage, validation, locking, migration, and
# upsert of install records) lives in its own file. Dot-sourced HERE, after
# $script:InstallRegistrySchemaVersion above is defined and before any
# function below can call into it, so every existing consumer of THIS file
# keeps working with zero changes - they still only need to dot-source
# _installlib.ps1.
. (Join-Path $PSScriptRoot '_installregistry.ps1')

function Test-ManagedRuntimeFileTracked {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $normalized = ([string]$RelativePath).Replace('\', '/').TrimStart('/')
    foreach ($mutable in $script:ManagedRuntimeMutablePaths) {
        if ([string]::Equals($normalized, ([string]$mutable).Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Normalizes a manifest entry list into a deterministic, comparable form:
# forward-slash relative paths, lower-cased for comparison stability on
# Windows, sorted by path. Never contains file contents - path + hash only.
function ConvertTo-ManifestArray {
    param($Entries)
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $relative = ([string]$entry.path).Replace('\', '/').TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        [void]$normalized.Add([pscustomobject][ordered]@{
            path = $relative.ToLowerInvariant()
            hash = ([string]$entry.hash).ToUpperInvariant()
        })
    }
    return @($normalized.ToArray() | Sort-Object -Property path)
}

# The manifest of SOURCE files that Copy-HookRuntime will place into this
# hook's managed runtime, keyed by their logical path RELATIVE TO THE RUNTIME
# ROOT (the Hook-Maker folder) so it compares directly against what is
# actually installed there.
#
# Mirrors Copy-HookRuntime exactly: _hooklib.ps1 at the runtime root, the main
# script renamed to <FriendlyName>.ps1, every other file in the hook's source
# folder (including a real .env - hashed whole, never read), and, for the sync
# engine, the routing config copied in as sync-hooks.json.
# Delegates to the CANONICAL install plan so the updater's expectation is
# derived from exactly the same description the installer builds from - a
# separate approximation here is what previously let the two drift apart.
# Looks up a single existing record without failing on a missing/corrupt
# registry - callers use it to carry sticky facts (e.g. "a user pre-push hook
# was preserved here once") forward across a reinstall.
function Get-InstallRecordById {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$Id
    )
    try {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($state.State -ne 'ok' -or $null -eq $state.Registry) { return $null }
        foreach ($record in @($state.Registry.installs)) {
            if ($null -eq $record) { continue }
            if ($null -eq $record.PSObject.Properties['id']) { continue }
            if ([string]$record.id -eq $Id) { return $record }
        }
    }
    catch { return $null }
    return $null
}

# Every tool root Hook Maker can PROVE is its own: this installation, plus any
# tool root recorded by a previous install in the registry. Only a historical
# tool-folder registration rooted under one of these may be claimed; anything
# else that merely looks similar is ambiguous and is preserved untouched.
function Get-KnownToolRoots {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)

    $roots = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if ($seen.Add($ToolRoot)) { [void]$roots.Add($ToolRoot) }
    try {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        if ($state.State -eq 'ok' -and $null -ne $state.Registry) {
            foreach ($record in @($state.Registry.installs)) {
                if ($null -eq $record -or $null -eq $record.PSObject.Properties['toolRoot']) { continue }
                $recorded = [string]$record.toolRoot
                if ([string]::IsNullOrWhiteSpace($recorded)) { continue }
                if ($seen.Add($recorded)) { [void]$roots.Add($recorded) }
            }
        }
    }
    catch { }
    return $roots.ToArray()
}

# Structural validation for a PARSED sync-hooks config object: every profile
# has a unique non-empty id, every route within it has a unique non-empty id,
# and every route's source/destination has a non-empty root. This is the SAME
# rule set Validate-Config.ps1 enforces - extracted here as the single shared
# source of truth so Install-Hook.ps1 can prove a config is well-formed BEFORE
# any mutation, without duplicating (and risking drifting from) that validator.
#
# Every access is guarded (PSObject.Properties checked before use, $null
# checked before member access) so a malformed/fuzzed config - a profile that
# is a bare string, a null entry in an array, a missing routes array - is
# REJECTED with a precise reason instead of throwing an unhandled StrictMode
# exception past the caller.
function Test-SyncConfigStructure {
    param($Config)
    if ($null -eq $Config -or $null -eq $Config.PSObject.Properties['profiles'] -or $null -eq $Config.profiles) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the config must contain a profiles array' }
    }
    $profileIds = @{}
    foreach ($configProfile in @($Config.profiles)) {
        $profileId = ''
        if ($null -ne $configProfile -and $null -ne $configProfile.PSObject.Properties['id']) { $profileId = [string]$configProfile.id }
        if ([string]::IsNullOrWhiteSpace($profileId)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'every profile requires a non-empty id' }
        }
        if ($profileIds.ContainsKey($profileId)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('duplicate profile id: ' + $profileId) }
        }
        $profileIds[$profileId] = $true

        # 'name' is not just cosmetic: Install-Hook.ps1 generates SYNC-PROJECTS.txt
        # from it (profile name on one line, each endpoint's name alongside its
        # root). A profile/endpoint missing it previously crashed deep inside the
        # install (an unguarded property access on a well-formed-per-id config),
        # reproduced directly - a config that structurally validates must never
        # be able to crash the installer it is handed to.
        $profileName = ''
        if ($null -ne $configProfile.PSObject.Properties['name']) { $profileName = [string]$configProfile.name }
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            return [pscustomobject]@{ Ok = $false; Reason = ("profile '" + $profileId + "' requires a non-empty name") }
        }

        # 'routes' is REQUIRED and must be a genuine route sequence. Defaulting a
        # missing property to @() (the previous behavior) silently turned a
        # profile with no routes property at all into a "valid profile with an
        # empty route list", which is exactly the malformed-structure case this
        # validator exists to reject before any mutation.
        #
        # EMPTY routes (`"routes": []`) is deliberately still STRUCTURALLY valid:
        # Validate-Config.ps1 runs this over EVERY profile in a whole config
        # file, including profiles the user is not installing, and an emptied-out
        # or placeholder group is a legitimate file state - failing the entire
        # config for one would be a regression with no safety benefit. The
        # stricter "the profile being installed must actually have a route" rule
        # belongs where a specific profile is known, and is enforced in
        # Install-Hook.ps1's pre-mutation engine block.
        $routesProperty = $configProfile.PSObject.Properties['routes']
        if ($null -eq $routesProperty) {
            return [pscustomobject]@{ Ok = $false; Reason = ("profile '" + $profileId + "' requires a routes array") }
        }
        $routesValue = $routesProperty.Value
        if ($null -eq $routesValue) {
            return [pscustomobject]@{ Ok = $false; Reason = ("profile '" + $profileId + "' has a null routes value; a routes array is required") }
        }
        # A string is IEnumerable (over its characters) and a PSCustomObject /
        # hashtable is not a route sequence at all, so both are rejected rather
        # than being silently enumerated into nonsense routes.
        if ($routesValue -is [string] -or
            $routesValue -is [System.Collections.IDictionary] -or
            -not ($routesValue -is [System.Collections.IEnumerable])) {
            return [pscustomobject]@{ Ok = $false; Reason = ("profile '" + $profileId + "' has a routes value that is not an array") }
        }
        $routeIds = @{}
        foreach ($route in @($routesValue)) {
            $routeId = ''
            if ($null -ne $route -and $null -ne $route.PSObject.Properties['id']) { $routeId = [string]$route.id }
            if ([string]::IsNullOrWhiteSpace($routeId)) {
                return [pscustomobject]@{ Ok = $false; Reason = ("every route in profile '" + $profileId + "' requires a non-empty id") }
            }
            if ($routeIds.ContainsKey($routeId)) {
                return [pscustomobject]@{ Ok = $false; Reason = ("duplicate route id '" + $routeId + "' in profile '" + $profileId + "'") }
            }
            $routeIds[$routeId] = $true

            foreach ($side in @('source', 'destination')) {
                $endpoint = $null
                if ($null -ne $route.PSObject.Properties[$side]) { $endpoint = $route.$side }
                $root = ''
                if ($null -ne $endpoint -and $null -ne $endpoint.PSObject.Properties['root']) { $root = [string]$endpoint.root }
                if ($null -eq $endpoint -or [string]::IsNullOrWhiteSpace($root)) {
                    return [pscustomobject]@{ Ok = $false; Reason = ("route '" + $routeId + "' in profile '" + $profileId + "' requires " + $side + '.root') }
                }
                $endpointName = ''
                if ($null -ne $endpoint.PSObject.Properties['name']) { $endpointName = [string]$endpoint.name }
                if ([string]::IsNullOrWhiteSpace($endpointName)) {
                    return [pscustomobject]@{ Ok = $false; Reason = ("route '" + $routeId + "' in profile '" + $profileId + "' requires " + $side + '.name') }
                }
            }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

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
    if ($Scope -eq 'project') {
        $relative = if ($ClientName -eq 'claude') { '.claude\settings.local.json' } else { '.codex\hooks.json' }
        return (Join-Path $TargetProjectRoot $relative)
    }
    $relative = if ($ClientName -eq 'claude') { '.claude\settings.json' } else { '.codex\hooks.json' }
    return (Join-Path $HOME $relative)
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
    foreach ($clientName in @('claude', 'codex')) {
        $client = Get-RecordField -Object $clients -Name $clientName
        if ($null -eq $client) { continue }
        # runtimeRoot joins runtimeScript/settingsPath here: Get-InstallIntegrity
        # reads it unguarded (via Get-InstalledManifest) for every client on
        # every evaluation, not only when something is already known to be wrong.
        # Every one of these must be an ACTUAL [string] - not merely something
        # that survives a [string] cast (a number, an object) - since each is
        # used directly as a path or command-line fragment.
        foreach ($required in @('runtimeScript', 'settingsPath', 'runtimeRoot')) {
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

        # settingsPath must be the EXACT canonical location Install-Hook.ps1
        # would write to for this record's scope/client - never merely "some
        # settings file", which would let a record silently point updates or
        # uninstalls at the wrong client's (or a foreign) settings file.
        $targetProjectRootValue = [string](Get-RecordField -Object $Record -Name 'targetProjectRoot')
        $expectedSettingsPath = Get-CanonicalClientSettingsPath -ClientName $clientName -Scope $scope -TargetProjectRoot $targetProjectRootValue
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

function Get-ManagedSourceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$HookScript,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [string]$ConfigPath = '',
        [switch]$IncludeConfig,
        [string]$ProfileId = ''
    )
    $plan = Get-InstallPlanFor -HookScript $HookScript -ToolRoot $ToolRoot -FriendlyNameOverride $FriendlyName `
        -ProfileId $ProfileId -ConfigPath $ConfigPath -IsEngine:$IncludeConfig -AllowMissing
    return ConvertTo-ManifestArray (Get-PlanManifest -Plan $plan)
}

# The manifest of what is ACTUALLY on disk inside a managed runtime root, in
# the same shape/keys as Get-ManagedSourceManifest so the two compare directly.
# Only this hook's own folder plus the shared _hooklib.ps1 are considered -
# other hooks' folders under the same runtime root belong to other records.
function Get-InstalledManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    $entries = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot) -or -not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        return @()
    }
    # The runtime-root _hooklib.ps1 is deliberately NOT part of any hook's
    # manifest: each hook owns a private copy inside its own directory. A root
    # copy left over from an older layout belongs to no record and is cleaned
    # up only after a successful install (see Remove-SharedRuntimeLibrary).
    $hookDir = Join-Path $RuntimeRoot $FriendlyName
    if (Test-Path -LiteralPath $hookDir -PathType Container) {
        $hookRoot = [System.IO.Path]::GetFullPath($hookDir).TrimEnd('\') + '\'
        foreach ($file in @(Get-ChildItem -LiteralPath $hookDir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($hookRoot.Length)
            if (-not (Test-ManagedRuntimeFileTracked -RelativePath $relative)) { continue }
            [void]$entries.Add([pscustomobject]@{ path = ($FriendlyName + '/' + $relative); hash = (Get-FileSha256 $file.FullName) })
        }
    }
    # .ToArray(): @($aListOfObject) throws "Argument types do not match" on
    # both PS hosts, even when empty - a documented trap in this project.
    return ConvertTo-ManifestArray $entries.ToArray()
}

# Compares two manifests and returns the concrete differences, so a caller can
# report a precise reason ("installed file modified: X") instead of a bare
# "stale". Never returns file contents.
function Compare-Manifest {
    param($Expected, $Actual)
    $expectedMap = @{}
    foreach ($entry in @($Expected)) { $expectedMap[[string]$entry.path] = [string]$entry.hash }
    $actualMap = @{}
    foreach ($entry in @($Actual)) { $actualMap[[string]$entry.path] = [string]$entry.hash }

    $missing = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($expectedMap.Keys)) {
        if (-not $actualMap.ContainsKey($path)) { [void]$missing.Add($path); continue }
        if ($actualMap[$path] -ne $expectedMap[$path]) { [void]$modified.Add($path) }
    }
    foreach ($path in @($actualMap.Keys)) {
        if (-not $expectedMap.ContainsKey($path)) { [void]$unexpected.Add($path) }
    }
    return [pscustomobject]@{
        Missing    = @(@($missing.ToArray()) | Sort-Object)
        Modified   = @(@($modified.ToArray()) | Sort-Object)
        Unexpected = @(@($unexpected.ToArray()) | Sort-Object)
        IsMatch    = ($missing.Count -eq 0 -and $modified.Count -eq 0 -and $unexpected.Count -eq 0)
    }
}

# The native Git pre-push chain is part of the logical Ignore-Rules-Check
# installation, not a separate install: the same operation copies a managed
# runtime for the hook itself PLUS a managed copy of every bundled companion
# (currently Secrets-Check) under the repository's git hooks path. Its manifest
# must therefore include the companions' SOURCE hashes - otherwise a change to
# only Secrets-Check.ps1 leaves the native chain stale while the parent hook
# still looks current.
#
# Mirrors Copy-PrePushCompanion exactly: a companion contributes its own
# <Name>.ps1 and, when the source folder has one, its .env - not the whole
# folder (that is only true for the primary hook, via Copy-HookRuntime).
function Get-NativePrePushSourceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$PrimaryFriendlyName,
        [Parameter(Mandatory = $true)][string]$PrimaryHookScript,
        [Parameter(Mandatory = $true)][string]$PrimarySourceDir,
        [string[]]$Companions = @()
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $PrimaryHookScript -SourceDir $PrimarySourceDir -FriendlyName $PrimaryFriendlyName)) {
        [void]$entries.Add($entry)
    }
    # Companions are installed through the canonical plan (private library +
    # dot-source rewrite), so their expected hashes MUST come from that same
    # plan. Hashing the raw source files here was a second rule that no longer
    # describes what is actually installed.
    foreach ($companion in @($Companions)) {
        $companionScript = Join-Path $ToolRoot ('hooks\' + $companion + '\' + $companion + '.ps1')
        if (-not (Test-Path -LiteralPath $companionScript -PathType Leaf)) { continue }
        $companionPlan = Get-InstallPlanFor -HookScript $companionScript -ToolRoot $ToolRoot -FriendlyNameOverride $companion -AllowMissing
        foreach ($entry in @(Get-PlanManifest -Plan $companionPlan)) {
            [void]$entries.Add($entry)
        }
    }
    # .ToArray(): @($aListOfObject) throws "Argument types do not match" on
    # both PS hosts, even when empty - a documented trap in this project.
    return ConvertTo-ManifestArray $entries.ToArray()
}

# What is actually installed under the native git hooks runtime root, in the
# same shape as Get-NativePrePushSourceManifest.
function Get-NativePrePushInstalledManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$PrimaryFriendlyName,
        [string[]]$Companions = @()
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-InstalledManifest -RuntimeRoot $RuntimeRoot -FriendlyName $PrimaryFriendlyName)) {
        [void]$entries.Add($entry)
    }
    foreach ($companion in @($Companions)) {
        $companionDir = Join-Path $RuntimeRoot $companion
        if (-not (Test-Path -LiteralPath $companionDir -PathType Container)) { continue }
        $companionRoot = [System.IO.Path]::GetFullPath($companionDir).TrimEnd('\') + '\'
        foreach ($file in @(Get-ChildItem -LiteralPath $companionDir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($companionRoot.Length)
            if (-not (Test-ManagedRuntimeFileTracked -RelativePath $relative)) { continue }
            [void]$entries.Add([pscustomobject]@{ path = ($companion + '/' + $relative); hash = (Get-FileSha256 $file.FullName) })
        }
    }
    # .ToArray(): @($aListOfObject) throws "Argument types do not match" on
    # both PS hosts, even when empty - a documented trap in this project.
    return ConvertTo-ManifestArray $entries.ToArray()
}

# Verifies the managed wrapper itself: present, ours (marker), chains every
# managed stage exactly once, and still honours the preserved user hook. The
# preserved hook is USER-OWNED - its mere existence is checked, its content is
# never hashed, rewritten, or compared.
function Test-NativePrePushState {
    param(
        [Parameter(Mandatory = $true)]$NativeRecord,
        [Parameter(Mandatory = $true)][string]$PrimaryFriendlyName
    )
    $wrapper = [string]$NativeRecord.wrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapper) -or -not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = 'managed pre-push wrapper is missing' }
    }
    $body = [System.IO.File]::ReadAllText($wrapper)
    if (-not $body.Contains($script:PrePushMarker)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = 'pre-push hook is no longer the Hook Maker managed wrapper' }
    }
    # Exact comparison against a wrapper REBUILT by the same generator the
    # installer uses. This proves stage order, single invocation per stage, the
    # mktemp stdin buffer, the cleanup trap, `|| exit $?` fail-closed behaviour,
    # argument forwarding and the previous-hook stage all at once - substring
    # probes could only ever approximate that.
    if ($null -ne $NativeRecord.PSObject.Properties['expectedStages'] -and $null -ne $NativeRecord.expectedStages) {
        $expectedStages = @($NativeRecord.expectedStages | ForEach-Object { [string]$_ })
        if ($expectedStages.Count -gt 0) {
            $expectedBody = New-PrePushWrapperBody -ManagedScripts $expectedStages
            if (-not (Compare-PrePushWrapperBody -Expected $expectedBody -Actual $body)) {
                return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = 'the managed pre-push wrapper does not match its expected content' }
            }
        }
    }
    else {
        # Records written before expectedStages existed: fall back to proving
        # each stage appears exactly once (the previous, weaker check).
        $stages = @($PrimaryFriendlyName)
        foreach ($companion in @($NativeRecord.companions)) { $stages += [string]$companion }
        foreach ($stage in $stages) {
            $marker = '/' + $stage + '/' + $stage + '.ps1"'
            $occurrences = ([regex]::Matches($body, [regex]::Escape($marker))).Count
            if ($occurrences -eq 0) {
                return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = ('pre-push chain no longer runs ' + $stage) }
            }
            if ($occurrences -gt 1) {
                return [pscustomobject]@{ Ok = $false; Reason = 'duplicate registration'; Detail = ('pre-push chain runs ' + $stage + ' more than once') }
            }
        }
    }
    # The preserved user hook is USER-OWNED: existence only, never hashed or
    # rewritten. Because previousHookPreserved is sticky, a hook that once
    # existed and has since vanished stays an unresolved state needing manual
    # attention - it is never silently forgotten.
    if ($null -ne $NativeRecord.PSObject.Properties['previousHookPath']) {
        $previous = [string]$NativeRecord.previousHookPath
        if (-not [string]::IsNullOrWhiteSpace($previous) -and
            $null -ne $NativeRecord.PSObject.Properties['previousHookPreserved'] -and $NativeRecord.previousHookPreserved -eq $true -and
            -not (Test-Path -LiteralPath $previous -PathType Leaf)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'manual repair required'; Detail = 'a previously preserved user pre-push hook is missing; Hook Maker will not recreate or overwrite a user-owned hook' }
        }
    }
    $expected = @($NativeRecord.sourceManifest)
    $actual = @(Get-NativePrePushInstalledManifest -RuntimeRoot ([string]$NativeRecord.runtimeRoot) -PrimaryFriendlyName $PrimaryFriendlyName -Companions @($NativeRecord.companions))
    $difference = Compare-Manifest -Expected $expected -Actual $actual
    if (-not $difference.IsMatch) {
        $detail = 'native managed files differ'
        if ($difference.Missing.Count -gt 0) { $detail = 'native managed file missing: ' + $difference.Missing[0] }
        elseif ($difference.Modified.Count -gt 0) { $detail = 'native managed file modified: ' + $difference.Modified[0] }
        return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = $detail }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'current'; Detail = '' }
}

# ---- registration inspection ---------------------------------------------

# The matcher Install-Hook.ps1 writes for a given event (SessionStart is the
# only event that carries one).
function Get-ExpectedMatcher {
    param([Parameter(Mandatory = $true)][string]$EventName)
    if ($EventName -eq 'SessionStart') { return 'startup|resume|clear|compact' }
    return ''
}

# Finds every registration in a settings file that belongs to ONE logical
# install, identified by its exact managed runtime script path (the precise
# identity - the command Install-Hook.ps1 generated points at that copy) and,
# for the sync engine, the same -Profile.
function Get-HookRegistrations {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RuntimeScript,
        [string]$ProfileId = ''
    )
    $found = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($SettingsPath) -or -not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $found.ToArray()
    }
    $json = Read-JsonFile $SettingsPath
    if ($null -eq $json -or $null -eq $json.PSObject.Properties['hooks'] -or $null -eq $json.hooks) {
        return $found.ToArray()
    }
    $scriptMarker = '"' + $RuntimeScript + '"'
    $profileMarker = ''
    if (-not [string]::IsNullOrWhiteSpace($ProfileId)) { $profileMarker = '-Profile "' + $ProfileId + '"' }

    foreach ($eventProp in $json.hooks.PSObject.Properties) {
        foreach ($group in @($eventProp.Value)) {
            $matcher = ''
            if ($null -ne $group.PSObject.Properties['matcher']) { $matcher = [string]$group.matcher }
            foreach ($handler in @($group.hooks)) {
                $command = ''
                if ($null -ne $handler.PSObject.Properties['command']) { $command = [string]$handler.command }
                $commandWindows = ''
                if ($null -ne $handler.PSObject.Properties['commandWindows']) { $commandWindows = [string]$handler.commandWindows }
                $combined = $command + ' ' + $commandWindows
                if (-not $combined.Contains($scriptMarker)) { continue }
                if ($profileMarker -ne '' -and -not $combined.Contains($profileMarker)) { continue }
                $timeout = 0
                if ($null -ne $handler.PSObject.Properties['timeout']) { $timeout = [int]$handler.timeout }
                $handlerType = ''
                if ($null -ne $handler.PSObject.Properties['type']) { $handlerType = [string]$handler.type }
                $statusMessage = ''
                if ($null -ne $handler.PSObject.Properties['statusMessage']) { $statusMessage = [string]$handler.statusMessage }
                [void]$found.Add([pscustomobject]@{
                    EventName      = $eventProp.Name
                    Matcher        = $matcher
                    Command        = $command
                    CommandWindows = $commandWindows
                    Timeout        = $timeout
                    StatusMessage  = $statusMessage
                    HandlerType    = $handlerType
                })
            }
        }
    }
    return $found.ToArray()
}

# Verifies that one client's live registrations match what the record says was
# installed: every expected event present exactly once, correct matcher/
# command/timeout, no leftover registration on an event this install no longer
# uses. Returns a precise reason code, never a bare boolean.
function Test-ClientRegistrationState {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RuntimeScript,
        [Parameter(Mandatory = $true)][string[]]$ExpectedEvents,
        [string]$ProfileId = '',
        [string]$ExpectedCommand = '',
        # Each of these is verified on its own. They stay optional so records
        # written before these fields were tracked are not reported as drifted
        # for lacking an expectation.
        [string]$ExpectedCommandWindows = '',
        [string]$ExpectedHandlerType = '',
        [string]$ExpectedStatusMessage = '',
        [switch]$ExpectedStatusMessageKnown,
        # Per-hook, not universal: the caller passes what the RECORD says this
        # installation registered. The default only covers a caller that has no
        # recorded expectation at all.
        [int]$ExpectedTimeout = $script:DefaultHookTimeoutSeconds
    )
    $registrations = @(Get-HookRegistrations -SettingsPath $SettingsPath -RuntimeScript $RuntimeScript -ProfileId $ProfileId)
    $byEvent = @{}
    foreach ($registration in $registrations) {
        $key = [string]$registration.EventName
        if (-not $byEvent.ContainsKey($key)) { $byEvent[$key] = New-Object System.Collections.Generic.List[object] }
        [void]$byEvent[$key].Add($registration)
    }

    $expectedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($eventName in @($ExpectedEvents)) { [void]$expectedSet.Add($eventName) }

    foreach ($eventName in @($ExpectedEvents)) {
        if (-not $byEvent.ContainsKey($eventName)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registration missing'; Detail = ('no registration for ' + $eventName) }
        }
        if ($byEvent[$eventName].Count -gt 1) {
            return [pscustomobject]@{ Ok = $false; Reason = 'duplicate registration'; Detail = ($byEvent[$eventName].Count.ToString() + ' registrations for ' + $eventName) }
        }
        $registration = $byEvent[$eventName][0]
        $expectedMatcher = Get-ExpectedMatcher -EventName $eventName
        if ([string]$registration.Matcher -ne $expectedMatcher) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('matcher changed on ' + $eventName) }
        }
        if ($ExpectedTimeout -gt 0 -and [int]$registration.Timeout -ne $ExpectedTimeout) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('timeout changed on ' + $eventName) }
        }
        # EVERY installer-owned field is checked INDEPENDENTLY. The previous
        # check accepted the handler when EITHER command form matched, so a
        # corrupted Windows command stayed hidden behind a still-correct
        # portable one (Codex handlers carry both).
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) {
            if ([string]$registration.Command -ne $ExpectedCommand) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('command changed on ' + $eventName) }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCommandWindows)) {
            if ([string]$registration.CommandWindows -ne $ExpectedCommandWindows) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('commandWindows changed on ' + $eventName) }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedHandlerType)) {
            if ([string]$registration.HandlerType -ne $ExpectedHandlerType) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('handler type changed on ' + $eventName) }
            }
        }
        # statusMessage is owned only where the installer writes one (Codex).
        if ($ExpectedStatusMessageKnown) {
            if ([string]$registration.StatusMessage -ne $ExpectedStatusMessage) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('statusMessage changed on ' + $eventName) }
            }
        }
    }
    foreach ($eventName in @($byEvent.Keys)) {
        if (-not $expectedSet.Contains($eventName)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'stale registration'; Detail = ('leftover registration on ' + $eventName) }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'current'; Detail = '' }
}

# ---- installed-state integrity --------------------------------------------

# Decides whether ONE recorded installation is genuinely current. An install
# is "current" only when the recorded source identity still matches the real
# source, AND every managed file that is actually on disk matches that source,
# AND every expected registration exists exactly once with the right
# semantics, AND no stale registration is left behind, AND any native Git
# integration is intact. Anything else is a precise, repairable 'update' or a
# non-destructive 'skip'.
#
# Deliberately does NOT trust the registry's own last-known hashes as proof of
# the installed state: they only describe what was true at install time.
function Get-InstallIntegrity {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$ToolRoot
    )
    if ($null -ne $Record.PSObject.Properties['imported'] -and $Record.imported -eq $true) {
        return [pscustomobject]@{ Status = 'update'; Detail = 'not yet tracked - will be registered' }
    }
    if ($null -ne $Record.PSObject.Properties['needsManualRepair'] -and $Record.needsManualRepair -eq $true) {
        return [pscustomobject]@{ Status = 'skip'; Detail = 'record cannot be interpreted safely - reinstall this hook once to repair tracking' }
    }
    $installedClients = @(Get-InstalledClientNames -Record $Record)
    if ($installedClients.Count -eq 0) {
        return [pscustomobject]@{ Status = 'skip'; Detail = 'record lists no installed client - reinstall this hook once to repair tracking' }
    }

    $isEngine = ([string]$Record.hookType -eq 'Engine')
    $configPath = ''
    if ($null -ne $Record.PSObject.Properties['configPath']) { $configPath = [string]$Record.configPath }
    $currentSource = @(Get-ManagedSourceManifest -ToolRoot $ToolRoot `
            -HookScript ([string]$Record.sourceScript) `
            -SourceDir ([string]$Record.sourceDir) `
            -FriendlyName ([string]$Record.friendlyName) `
            -ConfigPath $configPath -IncludeConfig:$isEngine `
            -ProfileId ([string]$Record.profile))

    # Component-level evaluation. Nothing early-returns any more: every
    # component is evaluated so the caller can repair ONLY what is damaged.
    # Repairing a healthy client would rewrite its settings, add a backup and
    # bump its runtime mtimes for no reason.
    #
    # SOURCE is a shared dependency: when it changes every component is stale
    # by definition, so they are all marked for repair together.
    $components = New-Object System.Collections.Generic.List[object]
    function Add-Component {
        param([string]$Name, [string]$Status, [string]$Detail)
        [void]$components.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    }

    $recordedSource = @()
    if ($null -ne $Record.PSObject.Properties['sourceManifest'] -and $null -ne $Record.sourceManifest) { $recordedSource = @($Record.sourceManifest) }
    $sourceDifference = Compare-Manifest -Expected $recordedSource -Actual $currentSource
    $sourceChanged = (-not $sourceDifference.IsMatch)
    $sourceDetail = ''
    if ($sourceChanged) {
        $sourceDetail = 'source changed since last install'
        if ($recordedSource.Count -eq 0) { $sourceDetail = 'tracked before managed-file tracking existed - will be refreshed' }
        elseif ($sourceDifference.Modified.Count -gt 0) { $sourceDetail = 'source changed: ' + $sourceDifference.Modified[0] }
        elseif ($sourceDifference.Unexpected.Count -gt 0) { $sourceDetail = 'source file added: ' + $sourceDifference.Unexpected[0] }
        elseif ($sourceDifference.Missing.Count -gt 0) { $sourceDetail = 'source file removed: ' + $sourceDifference.Missing[0] }
        Add-Component -Name 'source' -Status 'update' -Detail $sourceDetail
    }
    else {
        Add-Component -Name 'source' -Status 'current' -Detail ''
    }

    foreach ($client in $installedClients) {
        # A changed source invalidates every client regardless of what is on
        # disk right now, so they are repaired together with it.
        if ($sourceChanged) {
            Add-Component -Name $client -Status 'update' -Detail $sourceDetail
            continue
        }
        $subrecord = Get-ClientSubrecord -Record $Record -Client $client
        $runtimeScript = [string]$subrecord.runtimeScript
        if ([string]::IsNullOrWhiteSpace($runtimeScript) -or -not (Test-Path -LiteralPath $runtimeScript -PathType Leaf)) {
            Add-Component -Name $client -Status 'update' -Detail 'installed hook script is missing'
            continue
        }
        $installed = @(Get-InstalledManifest -RuntimeRoot ([string]$subrecord.runtimeRoot) -FriendlyName ([string]$Record.friendlyName))
        $difference = Compare-Manifest -Expected $currentSource -Actual $installed
        if (-not $difference.IsMatch) {
            $reason = ''
            if ($difference.Missing.Count -gt 0) {
                $missing = $difference.Missing[0]
                $reason = if ($missing -like '*/_hooklib.ps1') { 'private runtime library is missing: ' + $missing } else { 'installed file missing: ' + $missing }
            }
            elseif ($difference.Modified.Count -gt 0) {
                $modified = $difference.Modified[0]
                $reason = if ($modified -like '*/_hooklib.ps1') { 'private runtime library is stale: ' + $modified } else { 'installed file modified: ' + $modified }
            }
            else {
                $reason = 'unexpected managed file: ' + $difference.Unexpected[0]
            }
            Add-Component -Name $client -Status 'update' -Detail $reason
            continue
        }

        # Each owned field is passed separately so each is verified on its own.
        # A field the record does not carry (older records) is simply not
        # asserted, rather than being treated as drift.
        $expectedCommand = ''
        if ($null -ne $subrecord.PSObject.Properties['command']) { $expectedCommand = [string]$subrecord.command }
        $expectedCommandWindows = ''
        if ($null -ne $subrecord.PSObject.Properties['commandWindows']) { $expectedCommandWindows = [string]$subrecord.commandWindows }
        $expectedHandlerType = ''
        if ($null -ne $subrecord.PSObject.Properties['handlerType']) { $expectedHandlerType = [string]$subrecord.handlerType }
        $expectedStatusMessage = ''
        $statusMessageKnown = $false
        if ($null -ne $subrecord.PSObject.Properties['statusMessage']) {
            $expectedStatusMessage = [string]$subrecord.statusMessage
            # Only assert it where the installer actually writes one (Codex);
            # an empty recorded value means "this client has none".
            $statusMessageKnown = (-not [string]::IsNullOrWhiteSpace($expectedStatusMessage))
        }
        # Per-client PERSISTED timeout is the expectation, so a hook installed
        # with its own value drifts against THAT value, not against the default.
        # A record written before timeouts were per-hook simply carries 60.
        $expectedTimeout = $script:DefaultHookTimeoutSeconds
        if ($null -ne $subrecord.PSObject.Properties['timeout']) { $expectedTimeout = [int]$subrecord.timeout }
        $registrationState = Test-ClientRegistrationState `
            -SettingsPath ([string]$subrecord.settingsPath) `
            -RuntimeScript $runtimeScript `
            -ExpectedEvents @($subrecord.events) `
            -ProfileId ([string]$Record.profile) `
            -ExpectedCommand $expectedCommand `
            -ExpectedCommandWindows $expectedCommandWindows `
            -ExpectedHandlerType $expectedHandlerType `
            -ExpectedStatusMessage $expectedStatusMessage `
            -ExpectedStatusMessageKnown:$statusMessageKnown `
            -ExpectedTimeout $expectedTimeout
        if (-not $registrationState.Ok) {
            Add-Component -Name $client -Status 'update' -Detail ($registrationState.Reason + ' (' + $registrationState.Detail + ')')
            continue
        }
        Add-Component -Name $client -Status 'current' -Detail ''
    }

    # Native Git pre-push chain: part of this logical install, evaluated as its
    # own component so a damaged wrapper does not force a client reinstall.
    if ($null -ne $Record.PSObject.Properties['nativeGit'] -and $null -ne $Record.nativeGit) {
        $native = $Record.nativeGit
        if ($null -ne $native.PSObject.Properties['managed'] -and $native.managed -eq $true) {
            if ($sourceChanged) {
                Add-Component -Name 'nativeGit' -Status 'update' -Detail $sourceDetail
            }
            else {
                $currentNative = @(Get-NativePrePushSourceManifest -ToolRoot $ToolRoot `
                        -PrimaryFriendlyName ([string]$Record.friendlyName) `
                        -PrimaryHookScript ([string]$Record.sourceScript) `
                        -PrimarySourceDir ([string]$Record.sourceDir) `
                        -Companions @($native.companions))
                $recordedNative = @()
                if ($null -ne $native.PSObject.Properties['sourceManifest'] -and $null -ne $native.sourceManifest) { $recordedNative = @($native.sourceManifest) }
                $nativeSourceDifference = Compare-Manifest -Expected $recordedNative -Actual $currentNative
                if (-not $nativeSourceDifference.IsMatch) {
                    $nativeDetail = 'native pre-push companion source changed'
                    if ($nativeSourceDifference.Modified.Count -gt 0) { $nativeDetail = 'native pre-push source changed: ' + $nativeSourceDifference.Modified[0] }
                    Add-Component -Name 'nativeGit' -Status 'update' -Detail $nativeDetail
                }
                else {
                    $nativeState = Test-NativePrePushState -NativeRecord $native -PrimaryFriendlyName ([string]$Record.friendlyName)
                    if (-not $nativeState.Ok) {
                        # 'manual repair required' is NOT fixable by reinstalling:
                        # it means a user-owned file is missing and Hook Maker
                        # must not recreate it.
                        $nativeStatus = if ($nativeState.Reason -eq 'manual repair required') { 'skip' } else { 'update' }
                        Add-Component -Name 'nativeGit' -Status $nativeStatus -Detail ($nativeState.Reason + ': ' + $nativeState.Detail)
                    }
                    else {
                        Add-Component -Name 'nativeGit' -Status 'current' -Detail ''
                    }
                }
            }
        }
    }

    $componentArray = @($components.ToArray())
    $damaged = @($componentArray | Where-Object { $_.Status -eq 'update' })
    $blocked = @($componentArray | Where-Object { $_.Status -eq 'skip' })
    if ($damaged.Count -gt 0) {
        $firstDamaged = $damaged[0]
        $prefix = if ($firstDamaged.Name -eq 'source' -or $firstDamaged.Name -eq 'nativeGit') { '' } else { $firstDamaged.Name + ': ' }
        return [pscustomobject]@{ Status = 'update'; Detail = ($prefix + $firstDamaged.Detail); Components = $componentArray }
    }
    if ($blocked.Count -gt 0) {
        return [pscustomobject]@{ Status = 'skip'; Detail = $blocked[0].Detail; Components = $componentArray }
    }
    return [pscustomobject]@{ Status = 'current'; Detail = 'up to date'; Components = $componentArray }
}

# ---- legacy (pre-registry) install discovery -------------------------------
# Moved out of Setup-SyncGroup.ps1: this is install-STATE discovery (reading
# live settings files / sync config to find Hook-Maker-managed registrations
# the registry doesn't know about yet), not wizard UI - it belongs beside the
# other registry/integrity functions, and Setup-SyncGroup.ps1 already
# dot-sources this file. Ambient script-scope variables ($ConfigPath,
# $ToolRoot, $HooksDir) became explicit parameters so these functions do not
# depend on the calling script's own variable names.

# Scopes a legacy (pre-registry) scan can safely and provably reach: the
# current project (cwd), global (~/.claude + ~/.codex), and every OTHER
# project root the current sync-hooks.json's profiles/routes already
# reference. Any other project Hook Maker has never recorded a path for is
# genuinely unreachable without the user pointing at it once - reported, never
# guessed (reinstalling there, by any method, enters it into the registry).
function Get-LegacyScanScopes {
    param([string]$ConfigPath)
    $scopes = New-Object System.Collections.Generic.List[object]
    $cwdRoot = (Get-Location).Path.TrimEnd('\', '/')
    [void]$scopes.Add([pscustomobject]@{ ScopeLabel = 'project'; Root = $cwdRoot })
    [void]$scopes.Add([pscustomobject]@{ ScopeLabel = 'global'; Root = '' })
    $config = Read-JsonFile $ConfigPath
    if ($null -ne $config -and $null -ne $config.PSObject.Properties['profiles'] -and $null -ne $config.profiles) {
        $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        [void]$seen.Add($cwdRoot)
        foreach ($profileConfig in @($config.profiles)) {
            if ($null -eq $profileConfig.PSObject.Properties['routes'] -or $null -eq $profileConfig.routes) { continue }
            foreach ($route in @($profileConfig.routes)) {
                foreach ($endpoint in @($route.source, $route.destination)) {
                    if ($null -eq $endpoint) { continue }
                    $root = [string]$endpoint.root
                    if ([string]::IsNullOrWhiteSpace($root)) { continue }
                    $normalized = $root.TrimEnd('\', '/')
                    if ($seen.Contains($normalized)) { continue }
                    [void]$seen.Add($normalized)
                    [void]$scopes.Add([pscustomobject]@{ ScopeLabel = 'project'; Root = $normalized })
                }
            }
        }
    }
    return $scopes.ToArray()
}

function Get-ScopeSettingsPaths {
    param([Parameter(Mandatory = $true)]$Scope)
    if ($Scope.ScopeLabel -eq 'project') {
        return [pscustomobject]@{ Claude = (Join-Path $Scope.Root '.claude\settings.local.json'); Codex = (Join-Path $Scope.Root '.codex\hooks.json') }
    }
    return [pscustomobject]@{ Claude = (Join-Path $HOME '.claude\settings.json'); Codex = (Join-Path $HOME '.codex\hooks.json') }
}

# Scans one settings file for Hook-Maker-managed commands
# (...\hooks\Hook-Maker\<Name>\<Name>.ps1), extracting the friendly name, the
# event it is registered under, and - when present - the exact -Profile/
# -ConfigPath a sync-engine install embeds in its own command line. This reads
# Hook Maker's OWN generated invocation syntax (New-HookCommands), so it is a
# precise parse, never a guess at ambiguous metadata.
function Find-ManagedCommands {
    param([string]$SettingsPath, [string]$ClientLabel, [string[]]$KnownToolRoots = @())
    $found = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($SettingsPath) -or -not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $found.ToArray()
    }
    $json = Read-JsonFile $SettingsPath
    if ($null -eq $json -or $null -eq $json.PSObject.Properties['hooks'] -or $null -eq $json.hooks) {
        return $found.ToArray()
    }
    foreach ($eventProp in $json.hooks.PSObject.Properties) {
        foreach ($group in @($eventProp.Value)) {
            foreach ($handler in @($group.hooks)) {
                # Every command-bearing field is inspected via the SAME
                # centralized helper/parser used elsewhere (Get-HandlerCommandValues
                # + Get-HookMakerCommandInfo), so a registration stored only
                # under commandWindows/command_windows is never missed here.
                # A handler commonly carries the SAME logical command in more
                # than one field (portable + Windows form) - only the first
                # provably-owned field is used, so one handler never yields
                # more than one candidate. An ambiguous shape (unproven tool
                # root) is never imported, matching Test-HandlerBelongsToInstall.
                $info = $null
                foreach ($commandValue in @(Get-HandlerCommandValues -Handler $handler)) {
                    $candidate = Get-HookMakerCommandInfo -Command $commandValue -KnownToolRoots $KnownToolRoots
                    if (-not $candidate.IsHookMaker) { continue }
                    $info = $candidate
                    break
                }
                if ($null -eq $info) { continue }
                [void]$found.Add([pscustomobject]@{
                    FriendlyName = $info.HookName
                    EventName    = $eventProp.Name
                    Client       = $ClientLabel
                    Profile      = $info.Profile
                    ConfigPath   = $info.ConfigPath
                })
            }
        }
    }
    return $found.ToArray()
}

# Builds best-effort candidate records for Hook-Maker-managed registrations
# that exist live in a reachable scope's settings files but are NOT already in
# the registry - a conservative one-time import: every field is read directly
# from the actual settings file (or resolved from a known source layout),
# never invented. Already-tracked ids (by the same identity rule as a real
# install) are skipped.
function Get-LegacyHookCandidates {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$HooksDir,
        [string]$ConfigPath
    )
    $trackedIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($existing in @($Registry.installs)) { [void]$trackedIds.Add([string]$existing.id) }

    $knownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @(Get-LegacyScanScopes -ConfigPath $ConfigPath)) {
        $paths = Get-ScopeSettingsPaths $scope
        $allFound = @(Find-ManagedCommands -SettingsPath $paths.Claude -ClientLabel 'Claude' -KnownToolRoots $knownToolRoots) + @(Find-ManagedCommands -SettingsPath $paths.Codex -ClientLabel 'Codex' -KnownToolRoots $knownToolRoots)
        $byKey = @{}
        foreach ($entry in $allFound) {
            $key = $entry.FriendlyName + '|' + $entry.Profile
            if (-not $byKey.ContainsKey($key)) {
                $byKey[$key] = [pscustomobject]@{
                    FriendlyName = $entry.FriendlyName
                    Profile      = $entry.Profile
                    ConfigPath   = $entry.ConfigPath
                    # Events are tracked PER CLIENT: a live Claude-only
                    # SessionStart install alongside a Codex-only Stop install
                    # is legitimate, and merging them would silently rewrite
                    # one client's semantics with the other's on repair.
                    EventsByClient = @{ 'claude' = (New-Object System.Collections.Generic.List[string]); 'codex' = (New-Object System.Collections.Generic.List[string]) }
                }
            }
            $clientKey = $entry.Client.ToLowerInvariant()
            if (-not $byKey[$key].EventsByClient[$clientKey].Contains($entry.EventName)) {
                [void]$byKey[$key].EventsByClient[$clientKey].Add($entry.EventName)
            }
        }
        foreach ($key in $byKey.Keys) {
            $foundEntry = $byKey[$key]
            $scopeKey = if ($scope.ScopeLabel -eq 'project') { $scope.Root.ToLowerInvariant() } else { 'global' }
            $recordId = Get-InstallRecordId -FriendlyName $foundEntry.FriendlyName -ScopeKey $scopeKey -ProfileId $foundEntry.Profile
            if ($trackedIds.Contains($recordId)) { continue }

            $hookType = if ([string]::IsNullOrWhiteSpace($foundEntry.Profile) -and [string]::IsNullOrWhiteSpace($foundEntry.ConfigPath)) { 'CustomHook' } else { 'Engine' }
            $sourceScript = if ($hookType -eq 'Engine') {
                Join-Path $HooksDir 'Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'
            }
            else {
                Join-Path $HooksDir ($foundEntry.FriendlyName + '\' + $foundEntry.FriendlyName + '.ps1')
            }
            $scopePaths = Get-ScopeSettingsPaths $scope
            # Per-client subrecords built from what each client's settings file
            # ACTUALLY registers right now - never merged, never guessed.
            $clients = [pscustomobject][ordered]@{}
            $importedClients = New-Object System.Collections.Generic.List[string]
            foreach ($client in @('claude', 'codex')) {
                $clientEvents = @(@($foundEntry.EventsByClient[$client].ToArray()) | Sort-Object)
                if (@($clientEvents).Count -eq 0) { continue }
                $settingsPath = if ($client -eq 'claude') { $scopePaths.Claude } else { $scopePaths.Codex }
                $clientDir = Split-Path -Parent $settingsPath
                $runtimeRoot = Join-Path $clientDir 'hooks\Hook-Maker'
                Set-ObjectProperty -Object $clients -Name $client -Value ([pscustomobject][ordered]@{
                    installed         = $true
                    settingsPath      = $settingsPath
                    runtimeRoot       = $runtimeRoot
                    runtimeScript     = (Join-Path $runtimeRoot ($foundEntry.FriendlyName + '\' + $foundEntry.FriendlyName + '.ps1'))
                    events            = @($clientEvents)
                    command           = ''
                    statusMessage     = ''
                    timeout           = 60
                    installedManifest = @()
                    lastInstalledUtc  = ''
                    lastResult        = 'imported'
                    lastError         = ''
                })
                [void]$importedClients.Add($client)
            }
            if ($importedClients.Count -eq 0) { continue }
            $record = [pscustomobject][ordered]@{
                id                = $recordId
                schema            = 2
                internalName      = $foundEntry.FriendlyName
                friendlyName      = $foundEntry.FriendlyName
                hookType          = $hookType
                sourceScript      = $sourceScript
                sourceDir         = Split-Path -Parent $sourceScript
                scope             = $scope.ScopeLabel
                targetProjectRoot = if ($scope.ScopeLabel -eq 'project') { $scope.Root } else { '' }
                profile           = $foundEntry.Profile
                configPath        = $foundEntry.ConfigPath
                sourceManifest    = @()
                clients           = $clients
                nativeGit         = $null
                lastUpdatedUtc    = ''
                lastResult        = ''
                lastReason        = ''
                lastError         = ''
                needsManualRepair = $false
                imported          = $true
                importedClients   = @($importedClients.ToArray())
            }
            [void]$candidates.Add($record)
        }
    }
    return $candidates.ToArray()
}
