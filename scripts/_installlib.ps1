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

$script:InstallRegistrySchemaVersion = 2

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

    function Get-RecordField {
        param($Object, [string]$Name)
        if ($null -eq $Object.PSObject.Properties[$Name]) { return $null }
        return $Object.$Name
    }

    foreach ($required in @('id', 'friendlyName', 'hookType', 'sourceScript', 'scope')) {
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
    if ($schemaNumber -gt $script:InstallRegistrySchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('record uses unsupported schema version ' + $schemaNumber + ' (this version supports up to ' + $script:InstallRegistrySchemaVersion + ')') }
    }
    if ($schemaNumber -lt $script:InstallRegistrySchemaVersion) {
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
    $clients = Get-RecordField -Object $Record -Name 'clients'
    if ($null -eq $clients -or $clients -isnot [psobject]) {
        return [pscustomobject]@{ Ok = $false; Reason = 'record has no clients object' }
    }
    foreach ($clientName in @('claude', 'codex')) {
        $client = Get-RecordField -Object $clients -Name $clientName
        if ($null -eq $client) { continue }
        foreach ($required in @('runtimeScript', 'settingsPath')) {
            $value = Get-RecordField -Object $client -Name $required
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord is missing "' + $required + '"') }
            }
        }
        $events = Get-RecordField -Object $client -Name 'events'
        if ($null -eq $events -or @($events).Count -eq 0) {
            return [pscustomobject]@{ Ok = $false; Reason = ($clientName + ' subrecord has no events') }
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
                $statusMessage = ''
                if ($null -ne $handler.PSObject.Properties['statusMessage']) { $statusMessage = [string]$handler.statusMessage }
                [void]$found.Add([pscustomobject]@{
                    EventName      = $eventProp.Name
                    Matcher        = $matcher
                    Command        = $command
                    CommandWindows = $commandWindows
                    Timeout        = $timeout
                    StatusMessage  = $statusMessage
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
        [int]$ExpectedTimeout = 60
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
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCommand)) {
            $actual = [string]$registration.Command
            $actualWindows = [string]$registration.CommandWindows
            if ($actual -ne $ExpectedCommand -and $actualWindows -ne $ExpectedCommand) {
                return [pscustomobject]@{ Ok = $false; Reason = 'registration drifted'; Detail = ('command changed on ' + $eventName) }
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

    # 1. Did the source itself change since this install was recorded?
    $recordedSource = @()
    if ($null -ne $Record.PSObject.Properties['sourceManifest'] -and $null -ne $Record.sourceManifest) { $recordedSource = @($Record.sourceManifest) }
    $sourceDifference = Compare-Manifest -Expected $recordedSource -Actual $currentSource
    if (-not $sourceDifference.IsMatch) {
        $detail = 'source changed since last install'
        if ($recordedSource.Count -eq 0) { $detail = 'tracked before managed-file tracking existed - will be refreshed' }
        elseif ($sourceDifference.Modified.Count -gt 0) { $detail = 'source changed: ' + $sourceDifference.Modified[0] }
        elseif ($sourceDifference.Unexpected.Count -gt 0) { $detail = 'source file added: ' + $sourceDifference.Unexpected[0] }
        elseif ($sourceDifference.Missing.Count -gt 0) { $detail = 'source file removed: ' + $sourceDifference.Missing[0] }
        return [pscustomobject]@{ Status = 'update'; Detail = $detail }
    }

    # 2. Does what is actually installed still match that source, per client?
    foreach ($client in $installedClients) {
        $subrecord = Get-ClientSubrecord -Record $Record -Client $client
        $runtimeScript = [string]$subrecord.runtimeScript
        if ([string]::IsNullOrWhiteSpace($runtimeScript) -or -not (Test-Path -LiteralPath $runtimeScript -PathType Leaf)) {
            return [pscustomobject]@{ Status = 'update'; Detail = ($client + ': installed hook script is missing') }
        }
        $installed = @(Get-InstalledManifest -RuntimeRoot ([string]$subrecord.runtimeRoot) -FriendlyName ([string]$Record.friendlyName))
        $difference = Compare-Manifest -Expected $currentSource -Actual $installed
        if (-not $difference.IsMatch) {
            if ($difference.Missing.Count -gt 0) {
                $missing = $difference.Missing[0]
                $reason = if ($missing -like '*/_hooklib.ps1') { 'private runtime library is missing: ' + $missing } else { 'installed file missing: ' + $missing }
                return [pscustomobject]@{ Status = 'update'; Detail = ($client + ': ' + $reason) }
            }
            if ($difference.Modified.Count -gt 0) {
                $modified = $difference.Modified[0]
                $reason = if ($modified -like '*/_hooklib.ps1') { 'private runtime library is stale: ' + $modified } else { 'installed file modified: ' + $modified }
                return [pscustomobject]@{ Status = 'update'; Detail = ($client + ': ' + $reason) }
            }
            return [pscustomobject]@{ Status = 'update'; Detail = ($client + ': unexpected managed file: ' + $difference.Unexpected[0]) }
        }

        # 3. Is the registration still there, exactly once, with the semantics
        #    this client was installed with?
        $expectedCommand = ''
        if ($null -ne $subrecord.PSObject.Properties['command']) { $expectedCommand = [string]$subrecord.command }
        $expectedTimeout = 60
        if ($null -ne $subrecord.PSObject.Properties['timeout']) { $expectedTimeout = [int]$subrecord.timeout }
        $registrationState = Test-ClientRegistrationState `
            -SettingsPath ([string]$subrecord.settingsPath) `
            -RuntimeScript $runtimeScript `
            -ExpectedEvents @($subrecord.events) `
            -ProfileId ([string]$Record.profile) `
            -ExpectedCommand $expectedCommand `
            -ExpectedTimeout $expectedTimeout
        if (-not $registrationState.Ok) {
            return [pscustomobject]@{ Status = 'update'; Detail = ($client + ': ' + $registrationState.Reason + ' (' + $registrationState.Detail + ')') }
        }
    }

    # 4. Native Git pre-push chain (part of this logical install, not separate).
    if ($null -ne $Record.PSObject.Properties['nativeGit'] -and $null -ne $Record.nativeGit) {
        $native = $Record.nativeGit
        if ($null -ne $native.PSObject.Properties['managed'] -and $native.managed -eq $true) {
            $currentNative = @(Get-NativePrePushSourceManifest -ToolRoot $ToolRoot `
                    -PrimaryFriendlyName ([string]$Record.friendlyName) `
                    -PrimaryHookScript ([string]$Record.sourceScript) `
                    -PrimarySourceDir ([string]$Record.sourceDir) `
                    -Companions @($native.companions))
            $recordedNative = @()
            if ($null -ne $native.PSObject.Properties['sourceManifest'] -and $null -ne $native.sourceManifest) { $recordedNative = @($native.sourceManifest) }
            $nativeSourceDifference = Compare-Manifest -Expected $recordedNative -Actual $currentNative
            if (-not $nativeSourceDifference.IsMatch) {
                $detail = 'native pre-push companion source changed'
                if ($nativeSourceDifference.Modified.Count -gt 0) { $detail = 'native pre-push source changed: ' + $nativeSourceDifference.Modified[0] }
                return [pscustomobject]@{ Status = 'update'; Detail = $detail }
            }
            $nativeState = Test-NativePrePushState -NativeRecord $native -PrimaryFriendlyName ([string]$Record.friendlyName)
            if (-not $nativeState.Ok) {
                return [pscustomobject]@{ Status = 'update'; Detail = ($nativeState.Reason + ': ' + $nativeState.Detail) }
            }
        }
    }

    return [pscustomobject]@{ Status = 'current'; Detail = 'up to date' }
}

# ---- registry file: path, validation, quarantine, locking ------------------

function Get-InstallStateDirectory {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    if (-not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_STATE_DIR)) { return $env:HOOKMAKER_STATE_DIR }
    return (Join-Path $ToolRoot 'state')
}

function Get-InstallRegistryPath {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    return (Join-Path (Get-InstallStateDirectory -ToolRoot $ToolRoot) 'install-registry.json')
}

function New-EmptyInstallRegistry {
    return [pscustomobject][ordered]@{ version = $script:InstallRegistrySchemaVersion; installs = @() }
}

# Structural validation, not merely "did JSON parse". A registry whose version
# is unsupported, or whose installs is not an array of records with a usable
# identity, is CORRUPT - it must never be silently treated as "nothing tracked
# yet" and then overwritten (that would destroy real install history).
function Test-InstallRegistryShape {
    param($Registry)
    if ($null -eq $Registry) { return [pscustomobject]@{ Ok = $false; Reason = 'registry is empty or unparsable' } }
    if ($Registry -isnot [System.Management.Automation.PSCustomObject]) { return [pscustomobject]@{ Ok = $false; Reason = 'registry root is not an object' } }
    if ($null -eq $Registry.PSObject.Properties['version']) { return [pscustomobject]@{ Ok = $false; Reason = 'registry has no version field' } }
    $version = 0
    if (-not [int]::TryParse([string]$Registry.version, [ref]$version)) {
        return [pscustomobject]@{ Ok = $false; Reason = ('registry version is not a number: ' + [string]$Registry.version) }
    }
    if ($version -lt 1) { return [pscustomobject]@{ Ok = $false; Reason = ('registry version is out of range: ' + $version) } }
    if ($version -gt $script:InstallRegistrySchemaVersion) {
        return [pscustomobject]@{ Ok = $false; Reason = ('registry schema version ' + $version + ' is newer than this Hook Maker supports (' + $script:InstallRegistrySchemaVersion + ')') }
    }
    if ($null -eq $Registry.PSObject.Properties['installs'] -or $null -eq $Registry.installs) {
        return [pscustomobject]@{ Ok = $false; Reason = 'registry has no installs list' }
    }
    foreach ($record in @($Registry.installs)) {
        if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registry contains a non-object install record' }
        }
        if ($null -eq $record.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$record.id)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'registry contains an install record with no id' }
        }
        if ($null -eq $record.PSObject.Properties['friendlyName'] -or [string]::IsNullOrWhiteSpace([string]$record.friendlyName)) {
            return [pscustomobject]@{ Ok = $false; Reason = ('install record ' + [string]$record.id + ' has no friendlyName') }
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Version = $version }
}

# Reads and validates without writing anything. State is one of:
#   missing | ok | corrupt
# A corrupt registry keeps its ORIGINAL bytes available to the caller so they
# can be preserved verbatim on quarantine.
function Read-InstallRegistryState {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'missing'; Registry = (New-EmptyInstallRegistry); Path = $path; Reason = '' }
    }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
    catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = ('registry could not be read: ' + $_.Exception.Message) } }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        # A registry file that EXISTS but is empty/whitespace is an interrupted
        # or truncated write, not an absent registry: the previous contents may
        # have held real installs. Treat it as corrupt so it is quarantined
        # rather than silently overwritten. (An absent file is 'missing' above.)
        return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = 'registry file exists but is empty (interrupted or truncated write)' }
    }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = 'registry is not valid JSON' } }
    $shape = Test-InstallRegistryShape -Registry $parsed
    if (-not $shape.Ok) {
        return [pscustomobject]@{ State = 'corrupt'; Registry = $null; Path = $path; Reason = $shape.Reason }
    }
    return [pscustomobject]@{ State = 'ok'; Registry = $parsed; Path = $path; Reason = '' }
}

# Read-only accessor for callers that just want the records (the updater's
# plan, tests, reporting). A corrupt registry reads back as EMPTY here but is
# never written over by this function - mutation goes through
# Update-InstallRegistry, which quarantines first.
function Read-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $state = Read-InstallRegistryState -ToolRoot $ToolRoot
    if ($state.State -eq 'ok') { return (ConvertTo-InstallRegistryCurrent -Registry $state.Registry) }
    return (New-EmptyInstallRegistry)
}

function Save-InstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)]$Registry)
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    # A previous interrupted write can leave a stale .tmp beside the registry;
    # Write-JsonFileAtomic overwrites it, but clear it first so a partially
    # written file is never mistaken for real state by anything else.
    $stale = $path + '.tmp'
    if (Test-Path -LiteralPath $stale -PathType Leaf) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
    Write-JsonFileAtomic -Value $Registry -Path $path
}

# Preserves a corrupt registry's exact bytes under a collision-safe name
# instead of destroying it. Returns the quarantine path, or throws so the
# caller can leave the original untouched and report tracking failure.
function Move-CorruptInstallRegistry {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $path = Get-InstallRegistryPath -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $shortHash = Get-ShortHash ([System.BitConverter]::ToString($bytes))
    $directory = Split-Path -Parent $path
    $candidate = Join-Path $directory ('install-registry.corrupt-' + $stamp + '-' + $shortHash + '.json')
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory ('install-registry.corrupt-' + $stamp + '-' + $shortHash + '-' + $suffix + '.json')
        $suffix++
        if ($suffix -gt 100) { throw 'Could not find a free quarantine name for the corrupt install registry.' }
    }
    # Copy-then-verify-then-remove: if anything fails the original is still
    # there, and the quarantine copy is proven byte-identical before the
    # original is released.
    [System.IO.File]::WriteAllBytes($candidate, $bytes)
    $written = [System.IO.File]::ReadAllBytes($candidate)
    if ($written.Length -ne $bytes.Length) { throw 'Quarantine copy of the install registry does not match the original.' }
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($written[$i] -ne $bytes[$i]) { throw 'Quarantine copy of the install registry does not match the original.' }
    }
    Remove-Item -LiteralPath $path -Force
    return $candidate
}

# Crash-aware exclusive lock.
#
# A plain CreateNew lock file is permanently fatal: if the owning process is
# killed, the file survives and every future write fails forever. This keeps
# the file OPEN with FileShare.None for as long as the lock is held, so the OS
# releases the handle when the owner dies - which is what makes a leftover file
# distinguishable from a live lock:
#
#   * can't open it exclusively  -> a live owner still holds it -> wait.
#   * can open it exclusively    -> no live owner -> it is an orphan we may
#                                   reclaim (we already hold the handle).
#
# Ownership metadata (PID, process start time, host, creation UTC, random
# token - all non-secret) is written for diagnosability and to guard against
# PID reuse: a recorded PID that now belongs to a process with a DIFFERENT
# start time is not the original owner.
function Open-CrashAwareLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [int]$TimeoutSeconds = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $stream = $null
        try {
            # OpenOrCreate + FileShare.None: succeeds only when no live owner
            # holds the file. An orphan left by a killed process has no open
            # handle, so this reclaims it instead of failing forever.
            $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch {
            if ([DateTime]::UtcNow -gt $deadline) {
                throw ('Timed out waiting for the lock held by another Hook Maker process (' + $LockPath + '). Nothing was changed.')
            }
            Start-Sleep -Milliseconds 100
            continue
        }
        try {
            $process = Get-Process -Id $PID
            $owner = [pscustomobject][ordered]@{
                pid              = $PID
                processStartUtc  = $process.StartTime.ToUniversalTime().ToString('o')
                host             = [System.Net.Dns]::GetHostName()
                acquiredUtc      = [DateTime]::UtcNow.ToString('o')
                ownerToken       = [guid]::NewGuid().ToString('N')
            }
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($owner | ConvertTo-Json -Compress))
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        catch {
            # Metadata is diagnostic only - never fail the lock over it.
        }
        return $stream
    }
}

# Bounded exclusive lock around registry read-modify-write so two installs
# running near-simultaneously cannot lose each other's records.
function Invoke-WithInstallRegistryLock {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$TimeoutSeconds = 10
    )
    $directory = Get-InstallStateDirectory -ToolRoot $ToolRoot
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $lockPath = Join-Path $directory 'install-registry.lock'
    $stream = Open-CrashAwareLock -LockPath $lockPath -TimeoutSeconds $TimeoutSeconds
    try { return (& $Action) }
    finally {
        try { $stream.Dispose() } catch { }
        try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ---- record identity and shape --------------------------------------------

# Stable id for "this hook, in this scope, for this profile". Client is NOT
# part of the identity on purpose: one logical installation can target Claude,
# Codex, or both, and each client's own semantics live in its own subrecord
# (record.clients.claude / .codex) so installing one never rewrites the other.
function Get-InstallRecordId {
    param(
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)][string]$ScopeKey,
        [string]$ProfileId = ''
    )
    return Get-ShortHash ($FriendlyName.ToLowerInvariant() + '|' + $ScopeKey.ToLowerInvariant() + '|' + $ProfileId)
}

function New-ClientSubrecord {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeScript,
        [Parameter(Mandatory = $true)][string[]]$Events,
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$StatusMessage = '',
        [int]$Timeout = 60,
        $InstalledManifest = @()
    )
    return [pscustomobject][ordered]@{
        installed         = $true
        settingsPath      = $SettingsPath
        runtimeRoot       = $RuntimeRoot
        runtimeScript     = $RuntimeScript
        events            = @($Events)
        command           = $Command
        statusMessage     = $StatusMessage
        timeout           = $Timeout
        installedManifest = @($InstalledManifest)
        lastInstalledUtc  = [DateTime]::UtcNow.ToString('o')
        lastResult        = 'ok'
        lastError         = ''
    }
}

function Get-ClientSubrecord {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Client)
    if ($null -eq $Record.PSObject.Properties['clients'] -or $null -eq $Record.clients) { return $null }
    $key = $Client.ToLowerInvariant()
    if ($null -eq $Record.clients.PSObject.Properties[$key]) { return $null }
    $subrecord = $Record.clients.$key
    if ($null -eq $subrecord) { return $null }
    if ($null -ne $subrecord.PSObject.Properties['installed'] -and -not $subrecord.installed) { return $null }
    return $subrecord
}

function Get-InstalledClientNames {
    param([Parameter(Mandatory = $true)]$Record)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($client in @('claude', 'codex')) {
        if ($null -ne (Get-ClientSubrecord -Record $Record -Client $client)) { [void]$names.Add($client) }
    }
    return $names.ToArray()
}

# ---- v1 -> v2 migration ----------------------------------------------------

# v1 stored ONE shared events array plus clients='Claude'|'Codex'|'Both'
# inferred from runtime-file existence, which cannot represent two clients
# installed with different events. Migration rebuilds per-client subrecords and
# prefers each client's LIVE settings file as the authority for its events -
# the actual registration is ground truth, the v1 shared array is only a
# fallback. When neither can be established the record is flagged for manual
# repair rather than guessed at.
function ConvertTo-InstallRecordV2 {
    param([Parameter(Mandatory = $true)]$Record)
    if ($null -ne $Record.PSObject.Properties['schema'] -and [int]$Record.schema -ge 2) { return $Record }

    $legacyEvents = @()
    if ($null -ne $Record.PSObject.Properties['events'] -and $null -ne $Record.events) { $legacyEvents = @($Record.events) }
    $legacyClients = ''
    if ($null -ne $Record.PSObject.Properties['clients'] -and $Record.clients -is [string]) { $legacyClients = [string]$Record.clients }
    $profileId = ''
    if ($null -ne $Record.PSObject.Properties['profile']) { $profileId = [string]$Record.profile }

    $clients = [pscustomobject][ordered]@{}
    $needsManualRepair = $false
    foreach ($client in @('claude', 'codex')) {
        $wasInstalled = switch ($legacyClients) {
            'Both' { $true }
            'Claude' { $client -eq 'claude' }
            'Codex' { $client -eq 'codex' }
            default { $false }
        }
        if (-not $wasInstalled) { continue }
        $runtimeScript = ''
        $settingsPath = ''
        if ($client -eq 'claude') {
            if ($null -ne $Record.PSObject.Properties['claudeRuntimeScript']) { $runtimeScript = [string]$Record.claudeRuntimeScript }
            if ($null -ne $Record.PSObject.Properties['claudeSettingsPath']) { $settingsPath = [string]$Record.claudeSettingsPath }
        }
        else {
            if ($null -ne $Record.PSObject.Properties['codexRuntimeScript']) { $runtimeScript = [string]$Record.codexRuntimeScript }
            if ($null -ne $Record.PSObject.Properties['codexHooksPath']) { $settingsPath = [string]$Record.codexHooksPath }
        }
        if ([string]::IsNullOrWhiteSpace($runtimeScript) -or [string]::IsNullOrWhiteSpace($settingsPath)) {
            $needsManualRepair = $true
            continue
        }
        # Live registrations win over the ambiguous shared v1 array.
        $liveEvents = @()
        foreach ($registration in @(Get-HookRegistrations -SettingsPath $settingsPath -RuntimeScript $runtimeScript -ProfileId $profileId)) {
            if (@($liveEvents) -notcontains [string]$registration.EventName) { $liveEvents += [string]$registration.EventName }
        }
        $events = if (@($liveEvents).Count -gt 0) { @($liveEvents) } else { @($legacyEvents) }
        if (@($events).Count -eq 0) { $needsManualRepair = $true; continue }
        $runtimeRoot = ''
        if (-not [string]::IsNullOrWhiteSpace($runtimeScript)) { $runtimeRoot = Split-Path -Parent (Split-Path -Parent $runtimeScript) }
        $subrecord = [pscustomobject][ordered]@{
            installed         = $true
            settingsPath      = $settingsPath
            runtimeRoot       = $runtimeRoot
            runtimeScript     = $runtimeScript
            events            = @($events)
            command           = ''
            statusMessage     = ''
            timeout           = 60
            installedManifest = @()
            lastInstalledUtc  = if ($null -ne $Record.PSObject.Properties['lastInstalledUtc']) { [string]$Record.lastInstalledUtc } else { '' }
            lastResult        = 'migrated'
            lastError         = ''
            migratedFromV1    = $true
            eventsFromLive    = (@($liveEvents).Count -gt 0)
        }
        Set-ObjectProperty -Object $clients -Name $client -Value $subrecord
    }

    Set-ObjectProperty -Object $Record -Name 'schema' -Value 2
    Set-ObjectProperty -Object $Record -Name 'clients' -Value $clients
    Set-ObjectProperty -Object $Record -Name 'sourceManifest' -Value @()
    Set-ObjectProperty -Object $Record -Name 'needsManualRepair' -Value $needsManualRepair
    if (@(Get-InstalledClientNames -Record $Record).Count -eq 0) {
        Set-ObjectProperty -Object $Record -Name 'needsManualRepair' -Value $true
    }
    return $Record
}

function ConvertTo-InstallRegistryCurrent {
    param([Parameter(Mandatory = $true)]$Registry)
    $migrated = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Registry.installs)) {
        [void]$migrated.Add((ConvertTo-InstallRecordV2 -Record $record))
    }
    Set-ObjectProperty -Object $Registry -Name 'installs' -Value @($migrated.ToArray())
    Set-ObjectProperty -Object $Registry -Name 'version' -Value $script:InstallRegistrySchemaVersion
    return $Registry
}

# ---- record upsert ---------------------------------------------------------

# Merges one install outcome into the registry. A record is keyed by id; an
# existing record keeps its createdUtc and its OTHER client's subrecord
# untouched - installing Claude-only must never rewrite or drop what Codex has
# registered. History is bounded and carries the per-client outcome.
function Set-InstallRecord {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)]$Record
    )
    $nowIso = [DateTime]::UtcNow.ToString('o')
    $existingList = @($Registry.installs)
    $existingIndex = -1
    for ($i = 0; $i -lt $existingList.Count; $i++) {
        if ([string]$existingList[$i].id -eq [string]$Record.id) { $existingIndex = $i; break }
    }
    $touchedClients = @(Get-InstalledClientNames -Record $Record)
    # Read defensively: StrictMode throws on a missing property, and a record
    # arriving from an older schema (or a partially-built one) must not be able
    # to abort the whole registry write.
    $recordResult = ''
    if ($null -ne $Record.PSObject.Properties['lastResult']) { $recordResult = [string]$Record.lastResult }
    $recordReason = ''
    if ($null -ne $Record.PSObject.Properties['lastReason']) { $recordReason = [string]$Record.lastReason }
    $historyEntry = [pscustomobject][ordered]@{
        ts      = $nowIso
        result  = $recordResult
        clients = ($touchedClients -join ',')
        reason  = $recordReason
    }
    if ($existingIndex -ge 0) {
        $existing = $existingList[$existingIndex]
        Set-ObjectProperty -Object $Record -Name 'createdUtc' -Value ([string]$existing.createdUtc)
        # Carry forward every client subrecord this invocation did NOT touch.
        foreach ($client in @('claude', 'codex')) {
            if (@($touchedClients) -contains $client) { continue }
            $previous = $null
            if ($null -ne $existing.PSObject.Properties['clients'] -and $null -ne $existing.clients -and $null -ne $existing.clients.PSObject.Properties[$client]) {
                $previous = $existing.clients.$client
            }
            if ($null -ne $previous) { Set-ObjectProperty -Object $Record.clients -Name $client -Value $previous }
        }
        # Same for a native-git subrecord an unrelated client-only reinstall did not rebuild.
        if (($null -eq $Record.PSObject.Properties['nativeGit'] -or $null -eq $Record.nativeGit) -and
            $null -ne $existing.PSObject.Properties['nativeGit'] -and $null -ne $existing.nativeGit) {
            Set-ObjectProperty -Object $Record -Name 'nativeGit' -Value $existing.nativeGit
        }
        $priorHistory = @()
        if ($null -ne $existing.PSObject.Properties['history'] -and $null -ne $existing.history) { $priorHistory = @($existing.history) }
        $newHistory = @(@($priorHistory) + @($historyEntry))
        if ($newHistory.Count -gt 10) { $newHistory = @($newHistory | Select-Object -Last 10) }
        Set-ObjectProperty -Object $Record -Name 'history' -Value $newHistory
        $existingList[$existingIndex] = $Record
    }
    else {
        Set-ObjectProperty -Object $Record -Name 'createdUtc' -Value $nowIso
        Set-ObjectProperty -Object $Record -Name 'history' -Value @($historyEntry)
        $existingList = @(@($existingList) + @($Record))
    }
    $Registry.installs = $existingList
}

# The single safe mutation entry point: takes the lock, validates, quarantines
# a corrupt registry BEFORE recovering into a fresh one, upserts, saves.
# Returns a result the caller must report honestly - tracking can fail while
# the hook itself is correctly installed, and that must never be reported as a
# fully tracked install.
function Update-InstallRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)]$Record
    )
    return (Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $state = Read-InstallRegistryState -ToolRoot $ToolRoot
        $quarantinePath = ''
        $warning = ''
        $registry = $null
        if ($state.State -eq 'corrupt') {
            try {
                $quarantinePath = Move-CorruptInstallRegistry -ToolRoot $ToolRoot
            }
            catch {
                return [pscustomobject]@{
                    Ok = $false
                    QuarantinePath = ''
                    Warning = ('The install registry is unreadable (' + $state.Reason + ') and could not be quarantined: ' + $_.Exception.Message + '. It was left untouched and this installation was NOT recorded.')
                }
            }
            $warning = 'The install registry was unreadable (' + $state.Reason + '). Its exact contents were preserved at: ' + $quarantinePath + ' - a new registry was started, so previously tracked installations are no longer listed.'
            $registry = New-EmptyInstallRegistry
        }
        else {
            $registry = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
        }
        Set-InstallRecord -Registry $registry -Record $Record
        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registry
        return [pscustomobject]@{ Ok = $true; QuarantinePath = $quarantinePath; Warning = $warning }
    })
}
