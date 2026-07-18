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
    [switch]$CodexOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
    # _hooklib is shared by every hook in this scope; it sits at the Hook-Maker
    # root so each copied script's "..\_hooklib.ps1" dot-source resolves.
    $hookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'
    if (Test-Path -LiteralPath $hookLib -PathType Leaf) {
        Copy-Item -LiteralPath $hookLib -Destination $runtimeRoot -Force
    }

    # Migrate this hook out of a legacy 'HookMaker' folder (older, un-hyphenated
    # runtime root). Only remove THIS hook's subfolder so other hooks still
    # registered there keep working; drop the whole legacy root once it holds no
    # more hook subfolders.
    $legacyRoot = Join-Path $ClientDir 'hooks\HookMaker'
    if ([string]::IsNullOrWhiteSpace($RuntimeRootOverride) -and (Test-Path -LiteralPath $legacyRoot) -and -not [string]::Equals($legacyRoot, $runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $legacyHookDir = Join-Path $legacyRoot $FriendlyName
        if (Test-Path -LiteralPath $legacyHookDir) { Remove-Item -LiteralPath $legacyHookDir -Recurse -Force }
        if (@(Get-ChildItem -LiteralPath $legacyRoot -Directory -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $legacyRoot -Recurse -Force
        }
    }

    $destDir = Join-Path $runtimeRoot $FriendlyName
    $legacyDir = Join-Path $runtimeRoot $SourceName
    if ($SourceName -ne $FriendlyName -and (Test-Path -LiteralPath $legacyDir)) {
        Remove-Item -LiteralPath $legacyDir -Recurse -Force
    }
    $legacyRootConfig = Join-Path $runtimeRoot 'sync-hooks.json'
    if (Test-Path -LiteralPath $legacyRootConfig) { Remove-Item -LiteralPath $legacyRootConfig -Force }

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
            $sameHook = Test-HandlerBelongsToInstall -Handler $handler -FriendlyName $FriendlyName `
                -ProfileId ([string]$Profile) -AlsoMatchHookNames @($SourceName)
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
    function Copy-PrePushCompanion {
        param([Parameter(Mandatory = $true)][string]$Name)
        $sourceDir = Join-Path $ToolRoot ('hooks\' + $Name)
        $sourceScript = Join-Path $sourceDir ($Name + '.ps1')
        if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) { throw "Pre-push check not found: $sourceScript" }
        $destinationDir = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $Name))
        $safeRoot = [System.IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
        if (-not $destinationDir.StartsWith($safeRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe pre-push runtime path: $destinationDir" }
        if (Test-Path -LiteralPath $destinationDir) { Remove-Item -LiteralPath $destinationDir -Recurse -Force }
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        $destinationScript = Join-Path $destinationDir ($Name + '.ps1')
        Copy-Item -LiteralPath $sourceScript -Destination $destinationScript -Force
        $sourceEnv = Join-Path $sourceDir '.env'
        if (Test-Path -LiteralPath $sourceEnv -PathType Leaf) { Copy-Item -LiteralPath $sourceEnv -Destination (Join-Path $destinationDir '.env') -Force }
        return $destinationScript
    }
    $secretsScript = Copy-PrePushCompanion 'Secrets-Check'
    $staleLargeFileCheck = Join-Path $runtimeRoot 'Large-File-Check'
    if (Test-Path -LiteralPath $staleLargeFileCheck) {
        Remove-Item -LiteralPath $staleLargeFileCheck -Recurse -Force
    }
    $prePush = Join-Path $hooksPath 'pre-push'
    $previous = $prePush + '.hookmaker-existing'
    $marker = '# Hook Maker: Ignore-Rules-Check'
    if (Test-Path -LiteralPath $prePush -PathType Leaf) {
        $current = [System.IO.File]::ReadAllText($prePush)
        if (-not $current.Contains($marker)) {
            if (Test-Path -LiteralPath $previous) { throw "Cannot preserve the existing pre-push hook because '$previous' already exists." }
            Move-Item -LiteralPath $prePush -Destination $previous
        }
    }

    # Git delivers ref-update lines ("<local ref> <local sha> <remote ref>
    # <remote sha>") on the pre-push hook's STDIN - a stream that can only be
    # read once. Buffer it into a temp file up front and feed that SAME file
    # to every stage (each managed check, then the preserved previous hook),
    # so Secrets-Check can resolve the exact outgoing commits without
    # starving any later stage of the same data. `trap ... EXIT` guarantees
    # cleanup on every exit path, including the early `exit $?` on failure.
    $commands = @($runtime.Script, $secretsScript) | ForEach-Object {
        $scriptPath = $_.Replace('\', '/').Replace('$', '\$').Replace('`', '\`')
        'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -GitPrePush < "$STDIN_FILE" || exit $?'
    }
    $body = "#!/bin/sh`n$marker`n" +
        "STDIN_FILE=`$(mktemp `"`${TMPDIR:-/tmp}/hookmaker-prepush.XXXXXX`") || exit 1`n" +
        "trap 'rm -f `"`$STDIN_FILE`"' EXIT`n" +
        "cat > `"`$STDIN_FILE`"`n" +
        ($commands -join "`n") + "`n" +
        "if [ -f `"`$0.hookmaker-existing`" ]; then`n  `"`$0.hookmaker-existing`" `"`$@`" < `"`$STDIN_FILE`"`nfi`n"
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
        previousHookPreserved = (Test-Path -LiteralPath $previous -PathType Leaf)
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
    # Each client gets its own runtime copy so its command has zero dependency
    # on the Hook Maker folder (or on the other client's files).
    $claudeRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $ClaudeSettings)
    $claudeCommands = New-HookCommands -Runtime $claudeRuntime
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
    Write-Host "Claude hook ($ScopeLabel) installed in: $ClaudeSettings"
    Write-Host "Claude runtime copy: $($claudeRuntime.Script)"
}

if (-not $ClaudeOnly) {
    $codexRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $CodexHooks)
    $codexCommands = New-HookCommands -Runtime $codexRuntime
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
    Write-Host "Codex hook ($ScopeLabel) installed in: $CodexHooks"
    Write-Host "Codex runtime copy: $($codexRuntime.Script)"
}

Install-IgnorePrePush

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
        needsManualRepair = $false
    }
    $registryResult = Update-InstallRegistry -ToolRoot $ToolRoot -Record $record
    if (-not $registryResult.Ok) {
        Write-Host ('WARNING: the hook was installed, but tracking it FAILED - ' + $registryResult.Warning)
        Write-Host 'WARNING: "Update previously installed hooks" will not see this installation until it is reinstalled.'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($registryResult.Warning)) {
        Write-Host ('WARNING: ' + $registryResult.Warning)
    }
}
catch {
    Write-Host ('WARNING: the hook was installed, but the local install registry could not be updated: ' + $_.Exception.Message)
    Write-Host 'WARNING: "Update previously installed hooks" will not see this installation until it is reinstalled.'
}

Write-Host 'Restart the clients and review /hooks. Codex may require trusting the new command.'
