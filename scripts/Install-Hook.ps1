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
    $HookScript = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'hooks\CrossProjectSyncHook\CrossProjectSyncHook.ps1'))
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'sync-hooks.json'))
}
else {
    $ConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
}

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

# Installs are SELF-CONTAINED: the hook runtime (script, shared _hooklib.ps1,
# its .env, and - for the sync engine - the routing config) is COPIED into the
# scope's client folder (<scope>\.claude|.codex\hooks\HookMaker\), and the
# registered command points at that copy. Moving or deleting the Hook Maker
# folder never breaks an installed hook; re-run the install to refresh copies.
function Copy-HookRuntime {
    param([Parameter(Mandatory = $true)][string]$ClientDir)

    $runtimeRoot = Join-Path $ClientDir 'hooks\HookMaker'
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $hookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'
    if (Test-Path -LiteralPath $hookLib -PathType Leaf) {
        Copy-Item -LiteralPath $hookLib -Destination $runtimeRoot -Force
    }
    $sourceDir = Split-Path -Parent $HookScript
    if ((Split-Path -Leaf $sourceDir) -ieq 'hooks') {
        # Loose script directly in hooks\ - copy just the file into its own folder.
        $destDir = Join-Path $runtimeRoot ([System.IO.Path]::GetFileNameWithoutExtension($HookScript))
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $HookScript -Destination $destDir -Force
    }
    else {
        $destDir = Join-Path $runtimeRoot (Split-Path -Leaf $sourceDir)
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -Path (Join-Path $sourceDir '*') -Destination $destDir -Recurse -Force
        # The template only matters in the tool folder, not in the runtime copy.
        Remove-Item -LiteralPath (Join-Path $destDir '.env.example') -Force -ErrorAction SilentlyContinue
    }
    $localConfig = ''
    if ([string]::IsNullOrWhiteSpace($CustomHook)) {
        $localConfig = Join-Path $runtimeRoot 'sync-hooks.json'
        Copy-Item -LiteralPath $ConfigPath -Destination $localConfig -Force
    }
    return [pscustomobject]@{
        Script = Join-Path $destDir (Split-Path -Leaf $HookScript)
        Config = $localConfig
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

# Removes existing handlers for the SAME hook (same script leaf and, for the
# engine, the same -Profile) so a re-install replaces the old registration -
# including entries from older versions that pointed into the tool folder.
function Remove-StaleHandlers {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName
    )

    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) {
        return
    }
    $leafMarker = '\' + (Split-Path -Leaf $HookScript) + '"'
    $profileMarker = ''
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $profileMarker = '-Profile "' + $Profile + '"'
    }
    $keptGroups = @()
    foreach ($group in @($HooksObject.$EventName)) {
        $keptHandlers = @()
        foreach ($handler in @($group.hooks)) {
            $command = ''
            if ($null -ne $handler.PSObject.Properties['command']) {
                $command = [string]$handler.command
            }
            $sameHook = $command.Contains($leafMarker) -and ($profileMarker -eq '' -or $command.Contains($profileMarker))
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

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 50), $Utf8NoBom)
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

Write-Host 'Restart the clients and review /hooks. Codex may require trusting the new command.'
