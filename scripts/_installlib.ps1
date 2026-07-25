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
. (Join-Path $PSScriptRoot '_installvalidate.ps1')
. (Join-Path $PSScriptRoot '_installlegacy.ps1')

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
            # A foreign/hand-edited group with no `hooks` key has none to scan -
            # never a StrictMode crash, just zero registrations found here.
            $groupHandlers = @(if ($null -ne $group.PSObject.Properties['hooks']) { $group.hooks } else { @() })
            foreach ($handler in $groupHandlers) {
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
