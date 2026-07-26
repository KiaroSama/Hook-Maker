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
# _installlib.ps1. That file in turn dot-sources _installdiscovered.ps1 (the
# discovered-record identity/validation/merge rules), so the whole registry
# concern still arrives through this single dot-source.
. (Join-Path $PSScriptRoot '_installregistry.ps1')

# Record validation (the shape one persisted managed record must prove before
# any field of it is read) and legacy pre-registry discovery live in their own
# files for the same reason, and are dot-sourced HERE on the same terms: after
# the schema constants above, and before any function below can call into
# them. Consumers of THIS file still only need to dot-source _installlib.ps1.
# The canonical client/event capability table. Loaded HERE so every existing
# consumer keeps dot-sourcing only _installlib.ps1: _installvalidate.ps1 below
# derives canonical registration paths from it instead of an if/else that made
# every non-Claude client mean Codex.
. (Join-Path $PSScriptRoot '_clientcapability.ps1')
# The Kiro per-hook-file document, path and ownership module, on exactly the
# same terms: the integrity check below needs it to evaluate a 'perHookFile'
# client, and Uninstall-Hook.ps1 needs it to prove which files it owns. Both
# already dot-source only THIS file, so it is loaded here rather than in each
# consumer. It is a pure module - it defines functions and touches no state.
. (Join-Path $PSScriptRoot '_installkiro.ps1')
. (Join-Path $PSScriptRoot '_installvalidate.ps1')
. (Join-Path $PSScriptRoot '_installlegacy.ps1')
# The manifest / native-pre-push concern (_installlibmanifest.ps1) and the
# registration-inspection concern (_installlibregistration.ps1) live in
# their own files on the same terms: dot-sourced HERE, after the schema
# constants and exclusion lists above, before any function below can call
# into them. Consumers of THIS file still only need to dot-source
# _installlib.ps1.
. (Join-Path $PSScriptRoot '_installlibmanifest.ps1')
. (Join-Path $PSScriptRoot '_installlibregistration.ps1')

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

        # A per-hook-file client is evaluated by its OWN registration check.
        # Pointing the shared-settings one at a Kiro document would report
        # "registration missing" every time (its hooks are an array, not an
        # object keyed by event), so this client would be reinstalled on every
        # update run for ever.
        if ([string](Get-HookMakerClientCapability -ClientId $client).registrationKind -ceq 'perHookFile') {
            $kiroDirectory = ''
            try { $kiroDirectory = Get-KiroRecordRegistrationDirectory -Record $Record }
            catch {
                # An unresolvable scope is not repairable by reinstalling on top
                # of it - it needs a human, exactly like a missing user-owned
                # native wrapper.
                Add-Component -Name $client -Status 'skip' -Detail ('registration location cannot be resolved: ' + $_.Exception.Message)
                continue
            }
            $kiroManagedId = ''
            if ($null -ne $subrecord.PSObject.Properties['managedId']) { $kiroManagedId = [string]$subrecord.managedId }
            if ([string]::IsNullOrWhiteSpace($kiroManagedId)) { $kiroManagedId = [string]$Record.id }
            $kiroEntryNames = @()
            if ($null -ne $subrecord.PSObject.Properties['managedEntryNames'] -and $null -ne $subrecord.managedEntryNames) {
                $kiroEntryNames = @(@($subrecord.managedEntryNames) | ForEach-Object { [string]$_ })
            }
            if ($kiroEntryNames.Count -eq 0) {
                Add-Component -Name $client -Status 'skip' -Detail 'record does not name the hook entries it installed - reinstall this hook once to repair tracking'
                continue
            }
            $kiroTriggers = @()
            if ($null -ne $subrecord.PSObject.Properties['physicalTriggers'] -and $null -ne $subrecord.physicalTriggers) {
                $kiroTriggers = @($subrecord.physicalTriggers)
            }
            $kiroEnabled = $true
            if ($null -ne $subrecord.PSObject.Properties['enabled']) { $kiroEnabled = ($subrecord.enabled -eq $true) }
            $kiroTimeout = $script:DefaultHookTimeoutSeconds
            if ($null -ne $subrecord.PSObject.Properties['timeout']) { $kiroTimeout = [int]$subrecord.timeout }
            $kiroCommand = ''
            if ($null -ne $subrecord.PSObject.Properties['command']) { $kiroCommand = [string]$subrecord.command }
            $kiroState = Test-KiroRegistrationState `
                -RegistrationDirectory $kiroDirectory `
                -ManagedId $kiroManagedId `
                -ExpectedEntryNames @($kiroEntryNames) `
                -ExpectedEvents @($subrecord.events) `
                -PhysicalTriggers $kiroTriggers `
                -ExpectedCommand $kiroCommand `
                -ExpectedTimeout $kiroTimeout `
                -ExpectedEnabled $kiroEnabled
            if (-not $kiroState.Ok) {
                Add-Component -Name $client -Status 'update' -Detail ($kiroState.Reason + ' (' + $kiroState.Detail + ')')
                continue
            }
            Add-Component -Name $client -Status 'current' -Detail ''
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
