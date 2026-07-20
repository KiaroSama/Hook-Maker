param(
    [string]$Profile,
    [string[]]$Events = @('SessionStart', 'UserPromptSubmit'),
    [string]$ConfigPath,
    # When set, install into this project's local settings instead of the user's
    # home directory: <project>/.claude/settings.local.json + <project>/.codex/hooks.json.
    [string]$TargetProject,
    # Path to a standalone hook script (from the hooks/ folder). Installs it plain,
    # without the sync engine's -ConfigPath/-Profile arguments.
    [string]$CustomHook,
    [switch]$ClaudeOnly,
    [switch]$CodexOnly,
    # When set, a machine-readable result document is written here describing
    # the outcome of EACH component (validation, runtime, settings, native git,
    # registry). Programmatic callers - the updater - consume this instead of
    # inferring success from console text or from the mere absence of an
    # exception, which cannot distinguish "fully installed" from "installed but
    # tracking failed".
    [string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- structured outcome ----------------------------------------------------
# Component results are accumulated here and written to -ResultPath. States:
#   ok            - the component was applied and verified
#   failed        - the component could not be applied
#   skipped       - not applicable to this invocation (e.g. client not selected)
#   trackingFailed- runtime/settings succeeded but the registry write did not
$script:ComponentResults = New-Object System.Collections.Generic.List[object]
function Set-ComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'failed', 'skipped', 'trackingFailed')][string]$Status,
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
function Write-InstallResult {
    param([string]$Overall)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $document = [pscustomobject][ordered]@{
            schema     = 1
            overall    = $Overall
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
        # A result-file failure must never fail the install itself.
    }
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ToolRoot = Split-Path -Parent $PSScriptRoot
# Shared: Get-HookFriendlyName (folder/file naming). This is install-time only;
# the runtime hooks ignore it.
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
# Install-state registry (install-time only - deliberately NOT in _hooklib.ps1,
# which is copied into every self-contained runtime).
. (Join-Path $PSScriptRoot '_installlib.ps1')
# Canonical managed-install plan: safe source classification, transactional
# runtime replacement, and the single Hook Maker registration-ownership parser.
. (Join-Path $PSScriptRoot '_installplan.ps1')

# ---- guarantee a structured result on ANY terminal outcome -----------------
# A validation/runtime/settings/native failure used to exit before
# Write-InstallResult was ever reached, so -ResultPath produced no document at
# all on the very failures callers most need to distinguish. `trap { ...;
# break }` runs on ANY terminating error from this point on (including ones
# thrown inside a called function), then `break` lets the error propagate
# exactly as it would have without the trap - same non-zero exit code, same
# printed exception text, same "do not swallow the original exception". This
# is deliberately NOT a script-wide try/catch/finally: that would require
# re-indenting the entire body, which is an unrelated, larger-blast-radius
# change than guaranteeing the result document.
$script:CurrentPhase = 'validation'
trap {
    $failedPhase = if ($null -ne $script:CurrentPhase -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentPhase)) { [string]$script:CurrentPhase } else { 'unknown' }
    # Only record a failure for a phase that hasn't already reported 'ok' -
    # a phase either completes and records its own result, or it throws; it
    # never does both, so this is defensive rather than load-bearing.
    $alreadyOk = @($script:ComponentResults | Where-Object { $_.component -eq $failedPhase -and $_.status -eq 'ok' })
    if ($alreadyOk.Count -eq 0) {
        $sanitizedMessage = [string]$_.Exception.Message
        if ($sanitizedMessage.Length -gt 500) { $sanitizedMessage = $sanitizedMessage.Substring(0, 500) + '...' }
        Set-ComponentResult -Component $failedPhase -Status 'failed' -ReasonCode 'exception' -Message $sanitizedMessage
    }
    # Write-InstallResult swallows its OWN internal errors, so a failure to
    # write the result file here can never suppress the original exception
    # that `break` is about to (re-)propagate.
    Write-InstallResult -Overall 'failed'
    break
}

# ---- input validation ------------------------------------------------------
# Everything is validated BEFORE any runtime, settings, registry or native git
# state is touched, so an invalid invocation leaves the machine untouched
# instead of half-applying (or recording a tracked install with no client).
if ($ClaudeOnly -and $CodexOnly) {
    throw '-ClaudeOnly and -CodexOnly are mutually exclusive. Omit both to install for both clients.'
}
$ValidEvents = @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop', 'PreToolUse', 'PostToolUse', 'SessionEnd', 'PreCompact', 'Notification')
$normalizedEvents = New-Object System.Collections.Generic.List[string]
foreach ($rawEvent in @($Events)) {
    $candidate = ([string]$rawEvent).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $canonical = @($ValidEvents | Where-Object { $_ -eq $candidate })
    if ($canonical.Count -eq 0) {
        throw ("Unsupported hook event '" + $candidate + "'. Supported events: " + ($ValidEvents -join ', ') + '.')
    }
    if (-not $normalizedEvents.Contains($canonical[0])) { [void]$normalizedEvents.Add($canonical[0]) }
}
if ($normalizedEvents.Count -eq 0) {
    throw 'At least one hook event is required (-Events).'
}
$Events = $normalizedEvents.ToArray()

if (-not [string]::IsNullOrWhiteSpace($TargetProject)) {
    $resolvedTarget = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($TargetProject))
    if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
        throw ("Target project directory does not exist: " + $resolvedTarget)
    }
}

if (-not [string]::IsNullOrWhiteSpace($CustomHook)) {
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        throw '-CustomHook and -Profile cannot be combined.'
    }
    $HookScript = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CustomHook))
    if (-not (Test-Path -LiteralPath $HookScript -PathType Leaf)) {
        throw "Custom hook script not found: $HookScript"
    }
}
else {
    $HookScript = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'hooks\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'))
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'sync-hooks.json'))
}
else {
    $ConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
}

# A direct ENGINE install (-CustomHook absent) must prove its config exists,
# parses, is structurally valid, and - when a profile is requested - that the
# profile exists, BEFORE any directory, backup, settings, runtime, registry or
# native file is touched. Reuses the SAME structural rules Validate-Config.ps1
# enforces (Test-SyncConfigStructure in _installlib.ps1) rather than a second,
# potentially-drifting copy of that logic.
if ([string]::IsNullOrWhiteSpace($CustomHook)) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Sync config not found: $ConfigPath"
    }
    $rawSyncConfig = ''
    try { $rawSyncConfig = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) }
    catch { throw ("Could not read sync config '" + $ConfigPath + "': " + $_.Exception.Message) }
    $parsedSyncConfig = $null
    try { $parsedSyncConfig = $rawSyncConfig | ConvertFrom-Json }
    catch { throw ("Sync config '" + $ConfigPath + "' is not valid JSON: " + $_.Exception.Message) }
    $syncConfigStructure = Test-SyncConfigStructure -Config $parsedSyncConfig
    if (-not $syncConfigStructure.Ok) {
        throw ("Sync config '" + $ConfigPath + "' is invalid: " + $syncConfigStructure.Reason)
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        # Test-SyncConfigStructure already proved every profile id is unique,
        # so finding one match IS "exists exactly once" - a second match would
        # mean two profiles share an id, which structural validation above
        # would already have rejected.
        $matchingProfiles = @($parsedSyncConfig.profiles | Where-Object { [string]$_.id -eq $Profile })
        if ($matchingProfiles.Count -eq 0) {
            throw ("Profile '" + $Profile + "' was not found in sync config '" + $ConfigPath + "'.")
        }
        # Test-SyncConfigStructure already proved 'routes' exists and is a real
        # array for every profile; an EMPTY one is structurally valid there
        # (a whole-file validation must tolerate an emptied-out group it is not
        # installing). Installing THIS profile is different: a zero-route engine
        # install produces a hook that provably cannot sync anything plus an
        # empty generated SYNC-PROJECTS.txt - a silently useless installation.
        # Rejected here, before any directory, backup, settings, runtime,
        # registry or native file is touched.
        if (@($matchingProfiles[0].routes).Count -eq 0) {
            throw ("Profile '" + $Profile + "' in sync config '" + $ConfigPath + "' has no routes; an engine install requires at least one route.")
        }
    }
}

# How this source is installed. A folder counts as a hook PACKAGE only when it
# is a direct child of a recognized hooks root; any other script installs
# standalone (that one file), so pointing -CustomHook at a script inside an
# unrelated project can never copy that project's .git/.env/credentials/source
# into a settings-registered runtime directory.
$SourceInfo = Get-HookSourceInfo -HookScript $HookScript -PackageRoots @((Join-Path $ToolRoot 'hooks'))
$SourceDir = if ($SourceInfo.Kind -eq 'Package') { $SourceInfo.PackageRoot } else { Split-Path -Parent $SourceInfo.ScriptPath }
$SourceName = $SourceInfo.Name
$FriendlyName = Get-HookFriendlyName $SourceName

if (-not [string]::IsNullOrWhiteSpace($TargetProject)) {
    $projectRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($TargetProject))
    # settings.local.json (not settings.json): the command holds a machine-specific
    # absolute path, so it must stay out of source control.
    $ClaudeSettings = Join-Path $projectRoot '.claude\settings.local.json'
    $CodexHooks = Join-Path $projectRoot '.codex\hooks.json'
    $ScopeLabel = 'project'
}
else {
    $ClaudeSettings = Join-Path $HOME '.claude\settings.json'
    $CodexHooks = Join-Path $HOME '.codex\hooks.json'
    $ScopeLabel = 'global'
}
$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
# Resolved once: this tool root plus every tool root previously recorded in the
# registry. Only registrations provably rooted under one of these may be
# claimed as ours when they use the historical tool-folder layout.
$script:KnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)
# Set by Install-IgnorePrePush when this install also manages a native Git
# pre-push chain; stays $null for every other hook (StrictMode-safe default).
$script:NativeGitState = $null

# Produces SYNC-PROJECTS.txt's exact content (rather than writing it directly)
# so the install plan can give this GENERATED artifact a deterministic expected
# hash and verify it like any other managed file.
function Get-SyncProjectListContent {
    param([Parameter(Mandatory = $true)][string]$RoutingConfig)

    if ([string]::IsNullOrWhiteSpace($Profile)) { return $null }
    if (-not (Test-Path -LiteralPath $RoutingConfig -PathType Leaf)) { return $null }
    $config = Get-Content -LiteralPath $RoutingConfig -Raw | ConvertFrom-Json
    $matchingProfile = @($config.profiles | Where-Object { $_.id -eq $Profile } | Select-Object -First 1)
    if ($matchingProfile.Count -eq 0) { return $null }

    $projectsByRoot = @{}
    foreach ($route in @($matchingProfile[0].routes)) {
        foreach ($endpoint in @($route.source, $route.destination)) {
            $root = [string]$endpoint.root
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $key = $root.ToLowerInvariant()
            if (-not $projectsByRoot.ContainsKey($key)) {
                $projectsByRoot[$key] = [pscustomobject]@{ Name = [string]$endpoint.name; Root = $root }
            }
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Cross-project AI knowledge sync')
    [void]$lines.Add(('Profile: ' + [string]$matchingProfile[0].name))
    [void]$lines.Add('')
    [void]$lines.Add('Synchronized projects:')
    foreach ($project in @($projectsByRoot.Values | Sort-Object -Property Root)) {
        [void]$lines.Add(('- ' + $project.Name + ' | ' + $project.Root))
    }
    # WriteAllLines appends a trailing newline after the last line; match that
    # exactly so the planned hash equals what lands on disk.
    return (($lines.ToArray() -join "`r`n") + "`r`n")
}

# Installs are SELF-CONTAINED: the hook runtime (script, shared _hooklib.ps1,
# its .env, and - for the sync engine - the routing config) is COPIED into the
# scope's client folder (<scope>\.claude|.codex\hooks\Hook-Maker\<Friendly-Name>\),
# and the registered command points at that copy. Moving or deleting the Hook
# Maker folder never breaks an installed hook; re-run the install to refresh.
# The copy's folder + script use the friendly hyphenated name for easy ID.
function Copy-HookRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ClientDir,
        [string]$RuntimeRootOverride
    )

    $runtimeRoot = if ([string]::IsNullOrWhiteSpace($RuntimeRootOverride)) {
        Join-Path $ClientDir 'hooks\Hook-Maker'
    }
    else {
        [System.IO.Path]::GetFullPath($RuntimeRootOverride)
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    # NOTE: the shared library is no longer written to the runtime root here.
    # Each hook receives a PRIVATE _hooklib.ps1 inside its own runtime
    # directory as part of the plan, installed transactionally with the rest of
    # that hook. Writing it to the root before the transaction was both an
    # unrollback-able side effect and a cross-hook coupling: it changed the
    # library other installed hooks load, before this install had committed.

    $destDir = Join-Path $runtimeRoot $FriendlyName

    # Build the canonical plan, then install it TRANSACTIONALLY: staged in a
    # sibling directory, hash-verified, and only then swapped into place. The
    # previous runtime survives any failure before the swap and is restored if
    # the swap itself fails - a failed update never leaves a working
    # installation less functional than it was.
    $isEngineInstall = [string]::IsNullOrWhiteSpace($CustomHook)
    $syncListContent = $null
    if ($isEngineInstall) { $syncListContent = Get-SyncProjectListContent -RoutingConfig $ConfigPath }
    $plan = Get-ManagedInstallPlan -SourceInfo $SourceInfo -FriendlyName $FriendlyName -ToolRoot $ToolRoot `
        -ConfigPath $ConfigPath -IncludeConfig:$isEngineInstall -SyncProjectListContent $syncListContent
    Install-PlannedRuntime -Plan $plan -RuntimeRoot $runtimeRoot -FriendlyName $FriendlyName | Out-Null

    # ---- POST-COMMIT CLEANUP ONLY, past this point -------------------------
    # The replacement runtime is now staged, hash-verified and swapped into
    # place, so nothing below can destroy a not-yet-committed replacement.
    # Removing these BEFORE the commit above (the previous ordering) meant a
    # staging/swap failure could delete a still-working legacy installation
    # and leave NEITHER the old nor the new runtime behind. Each cleanup is
    # independent and best-effort: a failure here is reported as a warning and
    # never allowed to fail the install or be mistaken for a completed cleanup.
    $script:LegacyCleanupWarnings = @()

    # Retires the legacy shared library once every hook under this root owns a
    # private copy (already correctly post-commit-only).
    try { Remove-SharedRuntimeLibrary -RuntimeRoot $runtimeRoot | Out-Null }
    catch { $script:LegacyCleanupWarnings += ('shared library cleanup: ' + $_.Exception.Message) }

    # Migrate this hook out of a legacy 'HookMaker' folder (older, un-hyphenated
    # runtime root). Only remove THIS hook's subfolder so other hooks still
    # registered there keep working; drop the whole legacy root once it holds no
    # more hook subfolders.
    if ([string]::IsNullOrWhiteSpace($RuntimeRootOverride)) {
        $legacyRoot = Join-Path $ClientDir 'hooks\HookMaker'
        if ((Test-Path -LiteralPath $legacyRoot) -and -not [string]::Equals($legacyRoot, $runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $legacyHookDir = Join-Path $legacyRoot $FriendlyName
                if (Test-Path -LiteralPath $legacyHookDir) { Remove-Item -LiteralPath $legacyHookDir -Recurse -Force }
                if (@(Get-ChildItem -LiteralPath $legacyRoot -Directory -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $legacyRoot -Recurse -Force
                }
            }
            catch { $script:LegacyCleanupWarnings += ('legacy HookMaker root cleanup: ' + $_.Exception.Message) }
        }
    }

    $legacyDir = Join-Path $runtimeRoot $SourceName
    if ($SourceName -ne $FriendlyName -and (Test-Path -LiteralPath $legacyDir)) {
        try { Remove-Item -LiteralPath $legacyDir -Recurse -Force }
        catch { $script:LegacyCleanupWarnings += ('legacy same-runtime directory cleanup: ' + $_.Exception.Message) }
    }
    $legacyRootConfig = Join-Path $runtimeRoot 'sync-hooks.json'
    if (Test-Path -LiteralPath $legacyRootConfig) {
        try { Remove-Item -LiteralPath $legacyRootConfig -Force }
        catch { $script:LegacyCleanupWarnings += ('legacy root sync-hooks.json cleanup: ' + $_.Exception.Message) }
    }
    foreach ($cleanupWarning in @($script:LegacyCleanupWarnings)) {
        Write-Host ('WARNING: legacy cleanup incomplete (manual cleanup may be required) - ' + $cleanupWarning)
    }

    $friendlyScript = Join-Path $destDir ($FriendlyName + '.ps1')
    $localConfig = if ($isEngineInstall) { Join-Path $destDir 'sync-hooks.json' } else { '' }
    return [pscustomobject]@{
        Script = $friendlyScript
        Config = $localConfig
        Plan   = $plan
    }
}

# Builds the two command lines (Windows PowerShell / pwsh) for a runtime copy.
function New-HookCommands {
    param([Parameter(Mandatory = $true)]$Runtime)

    $suffix = ''
    if ([string]::IsNullOrWhiteSpace($CustomHook)) {
        $suffix = ' -ConfigPath "' + $Runtime.Config + '"'
        if (-not [string]::IsNullOrWhiteSpace($Profile)) {
            $suffix += ' -Profile "' + $Profile + '"'
        }
    }
    return [pscustomobject]@{
        Windows = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Runtime.Script + '"' + $suffix
        Portable = 'pwsh -NoLogo -NoProfile -NonInteractive -File "' + $Runtime.Script + '"' + $suffix
    }
}

# Removes existing handlers for the SAME hook so a re-install replaces the old
# registration instead of duplicating it. Matches the command by either the new
# friendly script leaf or the legacy internal-name leaf (so entries from older
# versions - including the flat tool-folder layout - are migrated), and, for the
# engine, the same -Profile.
function Remove-StaleHandlers {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName
    )

    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) {
        return
    }
    # Ownership is proven by the managed runtime PATH SHAPE
    # (...\hooks\Hook-Maker\<Name>\<file>.ps1, or the legacy HookMaker layout),
    # checked across command / commandWindows / command_windows - never by a
    # bare script basename. A user's own unrelated handler that happens to
    # point at a script with the same filename is NOT ours and is preserved.
    $keptGroups = @()
    foreach ($group in @($HooksObject.$EventName)) {
        $keptHandlers = @()
        foreach ($handler in @($group.hooks)) {
            # KnownToolRoots is what makes the historical tool-folder layout
            # provable rather than a shape guess: only a command rooted under a
            # KNOWN Hook Maker tool root can be claimed. Anything else that
            # merely looks similar is left untouched.
            $sameHook = Test-HandlerBelongsToInstall -Handler $handler -FriendlyName $FriendlyName `
                -ProfileId ([string]$Profile) -AlsoMatchHookNames @($SourceName) `
                -KnownToolRoots $script:KnownToolRoots
            if (-not $sameHook) {
                $keptHandlers += $handler
            }
        }
        if ($keptHandlers.Count -gt 0) {
            $group.hooks = $keptHandlers
            $keptGroups += $group
        }
    }
    $HooksObject.$EventName = $keptGroups
}

function Read-OrCreateJsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{}
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }
    return ($raw | ConvertFrom-Json)
}

function Ensure-Property {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $DefaultValue
    }
    return $Object.$Name
}

function Backup-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination ($Path + '.backup-' + $Timestamp) -Force
    }
}

# Settings are replaced transactionally: serialize to a sibling temp file,
# re-parse that temp file to prove it is valid JSON, and only then atomically
# replace the real file. A failure at any step leaves the original settings
# exactly as they were - never truncated or half-written.
function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 50
    $temporaryPath = $Path + '.hookmaker-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, $Utf8NoBom)
        # Re-parse from disk: proves what we are about to publish is loadable.
        $verify = [System.IO.File]::ReadAllText($temporaryPath, [System.Text.Encoding]::UTF8)
        $null = $verify | ConvertFrom-Json
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # [NullString]::Value, not $null: PowerShell coerces a bare $null
            # to '' for a [string] parameter, and Replace rejects an empty
            # backup path.
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

function Install-IgnorePrePush {
    if ($FriendlyName -ne 'Ignore-Rules-Check' -or [string]::IsNullOrWhiteSpace($TargetProject)) { return }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $hooksPath = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $projectRoot, 'rev-parse', '--git-path', 'hooks'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksPath)) { return }
    if (-not [System.IO.Path]::IsPathRooted($hooksPath)) { $hooksPath = Join-Path $projectRoot $hooksPath }
    $hooksPath = [System.IO.Path]::GetFullPath($hooksPath)

    $runtimeRoot = Join-Path $hooksPath 'Hook-Maker'
    $runtime = Copy-HookRuntime -ClientDir $hooksPath -RuntimeRootOverride $runtimeRoot
    $oldWrongRoot = Join-Path (Split-Path -Parent $hooksPath) 'hooks\Hook-Maker'
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($oldWrongRoot), [System.IO.Path]::GetFullPath($runtimeRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($name in @('Ignore-Rules-Check', 'Secrets-Check', 'Large-File-Check')) {
            $stale = Join-Path $oldWrongRoot $name
            if (Test-Path -LiteralPath $stale -PathType Container) { Remove-Item -LiteralPath $stale -Recurse -Force }
        }
        if ((Test-Path -LiteralPath $oldWrongRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $oldWrongRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $oldWrongRoot -Force
        }
    }
    # Native companions go through the SAME canonical plan and transactional
    # staging as any other managed runtime, so they get a private _hooklib.ps1
    # and the matching dot-source rewrite. Copying just the script by hand left
    # the companion with no library to load once the shared root copy was
    # retired, which broke the real pre-push chain.
    function Copy-PrePushCompanion {
        param([Parameter(Mandatory = $true)][string]$Name)
        $sourceScript = Join-Path $ToolRoot ('hooks\' + $Name + '\' + $Name + '.ps1')
        if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) { throw "Pre-push check not found: $sourceScript" }
        $destinationDir = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $Name))
        if (-not (Test-PathContainedIn -ChildPath $destinationDir -ParentPath $runtimeRoot)) {
            throw "Unsafe pre-push runtime path: $destinationDir"
        }
        $companionPlan = Get-InstallPlanFor -HookScript $sourceScript -ToolRoot $ToolRoot -FriendlyNameOverride $Name
        Install-PlannedRuntime -Plan $companionPlan -RuntimeRoot $runtimeRoot -FriendlyName $Name | Out-Null
        return (Join-Path $destinationDir ($Name + '.ps1'))
    }
    $secretsScript = Copy-PrePushCompanion 'Secrets-Check'
    $staleLargeFileCheck = Join-Path $runtimeRoot 'Large-File-Check'
    if (Test-Path -LiteralPath $staleLargeFileCheck) {
        Remove-Item -LiteralPath $staleLargeFileCheck -Recurse -Force
    }
    $prePush = Join-Path $hooksPath 'pre-push'
    $previous = $prePush + '.hookmaker-existing'
    $marker = $script:PrePushMarker
    if (Test-Path -LiteralPath $prePush -PathType Leaf) {
        $current = [System.IO.File]::ReadAllText($prePush)
        if (-not $current.Contains($marker)) {
            if (Test-Path -LiteralPath $previous) { throw "Cannot preserve the existing pre-push hook because '$previous' already exists." }
            # Move, never copy-and-rewrite: the user's hook is preserved as
            # opaque BYTES (it may be binary, or have no trailing newline).
            Move-Item -LiteralPath $prePush -Destination $previous
        }
    }
    # "Did a user hook ever exist here?" is STICKY. If we recorded one before
    # and the file has since vanished, we must not silently rewrite history to
    # previousHookPreserved=false - that would erase the fact that a user hook
    # is expected and let a rebuilt wrapper quietly drop the stage. It becomes
    # an unresolved state the updater reports for manual attention instead.
    $previousExistsNow = Test-Path -LiteralPath $previous -PathType Leaf
    $previousEverPreserved = $previousExistsNow
    $previousMissing = $false
    try {
        $existingRecord = Get-InstallRecordById -ToolRoot $ToolRoot -Id (Get-InstallRecordId -FriendlyName $FriendlyName -ScopeKey ($projectRoot.ToLowerInvariant()) -ProfileId ([string]$Profile))
        if ($null -ne $existingRecord -and
            $null -ne $existingRecord.PSObject.Properties['nativeGit'] -and $null -ne $existingRecord.nativeGit -and
            $null -ne $existingRecord.nativeGit.PSObject.Properties['previousHookPreserved'] -and
            $existingRecord.nativeGit.previousHookPreserved -eq $true) {
            $previousEverPreserved = $true
            $previousMissing = (-not $previousExistsNow)
        }
    }
    catch { }

    # ONE canonical generator (see New-PrePushWrapperBody) produces these bytes,
    # and the updater's integrity check rebuilds them with the same function to
    # compare exactly - so the wrapper's stdin buffering, stage order,
    # fail-closed `|| exit $?`, cleanup trap and previous-hook invocation can
    # never drift apart from what we verify.
    $managedStages = @($runtime.Script, $secretsScript)
    $body = New-PrePushWrapperBody -ManagedScripts $managedStages
    [System.IO.File]::WriteAllText($prePush, $body, $Utf8NoBom)
    Write-Host "Native git pre-push protection installed in: $prePush"

    # Record what this chain manages so the updater can detect a stale managed
    # companion (e.g. a changed Secrets-Check source) as drift of THIS logical
    # installation. The preserved previous hook is tracked by path/existence
    # only - it is user-owned and is never hashed or rewritten.
    $script:NativeGitState = [pscustomobject][ordered]@{
        managed               = $true
        hooksPath             = $hooksPath
        runtimeRoot           = $runtimeRoot
        wrapperPath           = $prePush
        previousHookPath      = $previous
        # Sticky: once true, stays true. previousHookMissing records that the
        # user's preserved hook has since disappeared, so the updater surfaces
        # it for manual attention instead of quietly forgetting it ever existed.
        previousHookPreserved = $previousEverPreserved
        previousHookMissing   = $previousMissing
        expectedStages        = @($managedStages)
        wrapperBodyHash       = (Get-ShortHash $body)
        companions            = @('Secrets-Check')
        sourceManifest        = @(Get-NativePrePushSourceManifest -ToolRoot $ToolRoot -PrimaryFriendlyName $FriendlyName -PrimaryHookScript $HookScript -PrimarySourceDir $SourceDir -Companions @('Secrets-Check'))
    }
}

function Add-HookGroup {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][string]$ExactCommand
    )

    $groups = @()
    if ($null -ne $HooksObject.PSObject.Properties[$EventName]) {
        $groups = @($HooksObject.$EventName)
    }

    foreach ($existingGroup in $groups) {
        foreach ($handler in @($existingGroup.hooks)) {
            foreach ($propertyName in @('command', 'commandWindows', 'command_windows')) {
                if ($null -ne $handler.PSObject.Properties[$propertyName] -and [string]$handler.$propertyName -eq $ExactCommand) {
                    return
                }
            }
        }
    }

    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) {
        $HooksObject | Add-Member -MemberType NoteProperty -Name $EventName -Value @($Group)
    }
    else {
        $HooksObject.$EventName = @($HooksObject.$EventName) + @($Group)
    }
}

$status = if (-not [string]::IsNullOrWhiteSpace($CustomHook)) {
    'Running custom hook: ' + (Split-Path -Leaf $HookScript)
}
elseif ([string]::IsNullOrWhiteSpace($Profile)) {
    'Checking configured project sync hooks'
}
else {
    'Checking sync profile: ' + $Profile
}

if (-not $CodexOnly) {
    $script:CurrentPhase = 'claude'
    # Each client gets its own runtime copy so its command has zero dependency
    # on the Hook Maker folder (or on the other client's files).
    $claudeRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $ClaudeSettings)
    $claudeCommands = New-HookCommands -Runtime $claudeRuntime
    # The whole read-modify-write is held under a crash-aware lock on THIS
    # settings file, so two installs touching the same file cannot lose each
    # other's handlers. Locks are taken one at a time (Claude, then Codex,
    # then the registry) and never nested, so no deadlock cycle can form.
    Invoke-WithResourceLock -ResourcePath $ClaudeSettings -Action {
        $claude = Read-OrCreateJsonObject $ClaudeSettings
        $claudeHooks = Ensure-Property -Object $claude -Name 'hooks' -DefaultValue ([pscustomobject]@{})
        # Prune this hook's old registrations from EVERY event (a re-install may
        # use fewer events, and old entries can point into the old tool folder).
        # Member enumeration (.Properties.Name) throws under StrictMode when the
        # object has no properties yet, so collect the names explicitly.
        $existingEvents = @()
        foreach ($property in $claudeHooks.PSObject.Properties) { $existingEvents += $property.Name }
        foreach ($existingEvent in $existingEvents) {
            Remove-StaleHandlers -HooksObject $claudeHooks -EventName $existingEvent
        }
        foreach ($eventName in $Events) {
            $handler = [pscustomobject][ordered]@{ type = 'command'; command = $claudeCommands.Windows; timeout = 60 }
            $group = if ($eventName -eq 'SessionStart') {
                [pscustomobject][ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @($handler) }
            }
            else {
                [pscustomobject][ordered]@{ hooks = @($handler) }
            }
            Add-HookGroup -HooksObject $claudeHooks -EventName $eventName -Group $group -ExactCommand $claudeCommands.Windows
        }
        Backup-File $ClaudeSettings
        Write-JsonFile -Value $claude -Path $ClaudeSettings
    }
    Set-ComponentResult -Component 'claude' -Status 'ok'
    Write-Host "Claude hook ($ScopeLabel) installed in: $ClaudeSettings"
    Write-Host "Claude runtime copy: $($claudeRuntime.Script)"
}

if (-not $ClaudeOnly) {
    $script:CurrentPhase = 'codex'
    $codexRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $CodexHooks)
    $codexCommands = New-HookCommands -Runtime $codexRuntime
    # The whole read-modify-write is held under a crash-aware lock on THIS
    # settings file, so two installs touching the same file cannot lose each
    # other's handlers. Locks are taken one at a time (Claude, then Codex,
    # then the registry) and never nested, so no deadlock cycle can form.
    Invoke-WithResourceLock -ResourcePath $CodexHooks -Action {
        $codex = Read-OrCreateJsonObject $CodexHooks
        $codexHooksObject = Ensure-Property -Object $codex -Name 'hooks' -DefaultValue ([pscustomobject]@{})
        $existingEvents = @()
        foreach ($property in $codexHooksObject.PSObject.Properties) { $existingEvents += $property.Name }
        foreach ($existingEvent in $existingEvents) {
            Remove-StaleHandlers -HooksObject $codexHooksObject -EventName $existingEvent
        }
        foreach ($eventName in $Events) {
            $handler = [pscustomobject][ordered]@{
                type = 'command'
                command = $codexCommands.Portable
                commandWindows = $codexCommands.Windows
                timeout = 60
                statusMessage = $status
            }
            $group = if ($eventName -eq 'SessionStart') {
                [pscustomobject][ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @($handler) }
            }
            else {
                [pscustomobject][ordered]@{ hooks = @($handler) }
            }
            Add-HookGroup -HooksObject $codexHooksObject -EventName $eventName -Group $group -ExactCommand $codexCommands.Windows
        }
        Backup-File $CodexHooks
        Write-JsonFile -Value $codex -Path $CodexHooks
    }
    Set-ComponentResult -Component 'codex' -Status 'ok'
    Write-Host "Codex hook ($ScopeLabel) installed in: $CodexHooks"
    Write-Host "Codex runtime copy: $($codexRuntime.Script)"
}

$script:CurrentPhase = 'nativeGit'
Install-IgnorePrePush
# Native chain is only part of some installs; record which.
if ($null -ne $script:NativeGitState) { Set-ComponentResult -Component 'nativeGit' -Status 'ok' }
else { Set-ComponentResult -Component 'nativeGit' -Status 'skipped' -ReasonCode 'notApplicable' }

$script:CurrentPhase = 'registry'
# ---- install registry -----------------------------------------------------
# The hook/settings/native files above are already correctly written by this
# point, so a registry failure never fails the install itself - but it is NOT
# silent either: tracking failure is reported explicitly, because an untracked
# install cannot be refreshed by "Update previously installed hooks".
#
# ONLY the clients this invocation actually installed are recorded. Each keeps
# its own events/matcher/command/timeout/runtime paths, so a later -CodexOnly
# install can never rewrite what Claude has registered (and vice versa).
# Stores paths and content hashes only - never .env values, secrets, hook
# stdin, prompt text, tool input, or any copied file's contents.
try {
    $scopeKey = if ($ScopeLabel -eq 'project') { $projectRoot.ToLowerInvariant() } else { 'global' }
    $recordId = Get-InstallRecordId -FriendlyName $FriendlyName -ScopeKey $scopeKey -ProfileId ([string]$Profile)
    $hookType = if ([string]::IsNullOrWhiteSpace($CustomHook)) { 'Engine' } else { 'CustomHook' }
    $isEngine = ($hookType -eq 'Engine')

    $sourceManifest = @(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $HookScript -SourceDir $SourceDir -FriendlyName $FriendlyName -ConfigPath $ConfigPath -IncludeConfig:$isEngine -ProfileId ([string]$Profile))

    $clients = [pscustomobject][ordered]@{}
    if (-not $CodexOnly) {
        $claudeRoot = Split-Path -Parent $claudeRuntime.Script
        $claudeRuntimeRoot = Split-Path -Parent $claudeRoot
        Set-ObjectProperty -Object $clients -Name 'claude' -Value (New-ClientSubrecord `
            -SettingsPath $ClaudeSettings `
            -RuntimeRoot $claudeRuntimeRoot `
            -RuntimeScript $claudeRuntime.Script `
            -Events @($Events) `
            -Command $claudeCommands.Windows `
            -HandlerType 'command' `
            -Timeout 60 `
            -InstalledManifest @(Get-InstalledManifest -RuntimeRoot $claudeRuntimeRoot -FriendlyName $FriendlyName))
    }
    if (-not $ClaudeOnly) {
        $codexRoot = Split-Path -Parent $codexRuntime.Script
        $codexRuntimeRoot = Split-Path -Parent $codexRoot
        Set-ObjectProperty -Object $clients -Name 'codex' -Value (New-ClientSubrecord `
            -SettingsPath $CodexHooks `
            -RuntimeRoot $codexRuntimeRoot `
            -RuntimeScript $codexRuntime.Script `
            -Events @($Events) `
            -Command $codexCommands.Portable `
            -CommandWindows $codexCommands.Windows `
            -HandlerType 'command' `
            -StatusMessage $status `
            -Timeout 60 `
            -InstalledManifest @(Get-InstalledManifest -RuntimeRoot $codexRuntimeRoot -FriendlyName $FriendlyName))
    }

    $nativeGit = $null
    if ($null -ne $script:NativeGitState) { $nativeGit = $script:NativeGitState }

    $record = [pscustomobject][ordered]@{
        id                = $recordId
        schema            = 2
        internalName      = $SourceName
        friendlyName      = $FriendlyName
        hookType          = $hookType
        sourceScript      = $HookScript
        sourceDir         = $SourceDir
        # The Hook Maker tool root this install came from. Recorded so a later
        # version can PROVE that a historical tool-folder registration belongs
        # to Hook Maker (rather than guessing from path shape) even after the
        # tool has been moved - see Get-KnownToolRoots.
        toolRoot          = $ToolRoot
        scope             = $ScopeLabel
        targetProjectRoot = if ($ScopeLabel -eq 'project') { $projectRoot } else { '' }
        profile           = [string]$Profile
        configPath        = if ($isEngine) { $ConfigPath } else { '' }
        sourceManifest    = $sourceManifest
        clients           = $clients
        nativeGit         = $nativeGit
        lastUpdatedUtc    = [DateTime]::UtcNow.ToString('o')
        lastResult        = 'ok'
        lastReason        = 'installed'
        lastError         = ''
        # Sanitized per-component outcomes for this attempt; Set-InstallRecord
        # folds them into the record's bounded history.
        lastComponents    = @($script:ComponentResults.ToArray() | ForEach-Object {
            [pscustomobject][ordered]@{ component = [string]$_.component; status = [string]$_.status; reason = [string]$_.reason }
        })
        needsManualRepair = $false
    }
    $registryResult = Update-InstallRegistry -ToolRoot $ToolRoot -Record $record
    if (-not $registryResult.Ok) {
        Write-Host ('WARNING: the hook was installed, but tracking it FAILED - ' + $registryResult.Warning)
        Write-Host 'WARNING: "Update previously installed hooks" will not see this installation until it is reinstalled.'
        # Runtime and settings ARE applied; only tracking failed. The caller
        # must be able to tell those apart, so this is its own state.
        Set-ComponentResult -Component 'registry' -Status 'trackingFailed' -ReasonCode 'registryWriteFailed' -Message ([string]$registryResult.Warning)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($registryResult.Warning)) {
        Write-Host ('WARNING: ' + $registryResult.Warning)
        Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'warning' -Message ([string]$registryResult.Warning)
    }
    else {
        Set-ComponentResult -Component 'registry' -Status 'ok'
    }
}
catch {
    Write-Host ('WARNING: the hook was installed, but the local install registry could not be updated: ' + $_.Exception.Message)
    Write-Host 'WARNING: "Update previously installed hooks" will not see this installation until it is reinstalled.'
    Set-ComponentResult -Component 'registry' -Status 'trackingFailed' -ReasonCode 'registryException' -Message $_.Exception.Message
}

# Overall state is derived from the component results, never from the absence
# of an exception: an install whose runtime and settings landed but whose
# tracking failed is 'partial', not success.
$failedComponents = @($script:ComponentResults | Where-Object { $_.status -eq 'failed' })
$trackingFailed = @($script:ComponentResults | Where-Object { $_.status -eq 'trackingFailed' })
$overallResult = if ($failedComponents.Count -gt 0) { 'failed' } elseif ($trackingFailed.Count -gt 0) { 'partial' } else { 'ok' }
Write-InstallResult -Overall $overallResult

Write-Host 'Restart the clients and review /hooks. Codex may require trusting the new command.'
