# ---------------------------------------------------------------------------
# Legacy (pre-registry) install discovery: finding Hook-Maker-managed
# registrations that exist live in a reachable scope's settings files but that
# the install registry has never recorded.
#
# Split out of _installlib.ps1 (the legacy-discovery concern) so that file
# could stay a manageable size. _installlib.ps1 dot-sources this file itself,
# near its top, in the required load order - every existing consumer
# (Setup-SyncGroup.ps1 and the test suites) keeps dot-sourcing ONLY
# _installlib.ps1 and needs zero changes.
#
# Load-order contract (this file is never dot-sourced standalone - it is
# always pulled in from inside _installlib.ps1, which enforces the order):
#   1. hooks\_hooklib.ps1        (Read-JsonFile, Set-ObjectProperty)
#   2. scripts\_installplan.ps1  (Get-HandlerCommandValues,
#                                  Get-HookMakerCommandInfo)
#   3. scripts\_installlib.ps1   (Get-KnownToolRoots, and it dot-sources
#                                  _installregistry.ps1 for Get-InstallRecordId,
#                                  THEN dot-sources this file)
#
# Every cross-file call above resolves at CALL time inside the single shared
# script scope dot-sourcing creates, so no function here depends on being
# DEFINED after anything - only on _installlib.ps1 having pulled in the files
# listed above by the time one of these functions is actually invoked.
#
# Read-only: this builds candidate records and returns them. Persisting a
# candidate is the caller's decision (Setup-SyncGroup.ps1), never this file's.
# ---------------------------------------------------------------------------

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
