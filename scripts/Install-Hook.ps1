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
    $HookScript = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'hooks\CrossProjectSyncHook.ps1'))
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

if (-not [string]::IsNullOrWhiteSpace($CustomHook)) {
    # Custom hooks receive only the hook event on stdin; no extra arguments.
    $windowsCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $HookScript + '"'
    $portableCommand = 'pwsh -NoLogo -NoProfile -NonInteractive -File "' + $HookScript + '"'
    $status = 'Running custom hook: ' + (Split-Path -Leaf $HookScript)
}
else {
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $HookScript + '" -ConfigPath "' + $ConfigPath + '"'
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $arguments += ' -Profile "' + $Profile + '"'
    }
    $windowsCommand = 'powershell.exe ' + $arguments
    $portableCommand = 'pwsh -NoLogo -NoProfile -NonInteractive -File "' + $HookScript + '" -ConfigPath "' + $ConfigPath + '"'
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $portableCommand += ' -Profile "' + $Profile + '"'
    }
    $status = if ([string]::IsNullOrWhiteSpace($Profile)) { 'Checking configured project sync hooks' } else { 'Checking sync profile: ' + $Profile }
}

if (-not $CodexOnly) {
    $claude = Read-OrCreateJsonObject $ClaudeSettings
    $claudeHooks = Ensure-Property -Object $claude -Name 'hooks' -DefaultValue ([pscustomobject]@{})
    foreach ($eventName in $Events) {
        $handler = [pscustomobject][ordered]@{ type = 'command'; command = $windowsCommand; timeout = 60 }
        $group = if ($eventName -eq 'SessionStart') {
            [pscustomobject][ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @($handler) }
        }
        else {
            [pscustomobject][ordered]@{ hooks = @($handler) }
        }
        Add-HookGroup -HooksObject $claudeHooks -EventName $eventName -Group $group -ExactCommand $windowsCommand
    }
    Backup-File $ClaudeSettings
    Write-JsonFile -Value $claude -Path $ClaudeSettings
    Write-Host "Claude hook ($ScopeLabel) installed in: $ClaudeSettings"
}

if (-not $ClaudeOnly) {
    $codex = Read-OrCreateJsonObject $CodexHooks
    $codexHooksObject = Ensure-Property -Object $codex -Name 'hooks' -DefaultValue ([pscustomobject]@{})
    foreach ($eventName in $Events) {
        $handler = [pscustomobject][ordered]@{
            type = 'command'
            command = $portableCommand
            commandWindows = $windowsCommand
            timeout = 60
            statusMessage = $status
        }
        $group = if ($eventName -eq 'SessionStart') {
            [pscustomobject][ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @($handler) }
        }
        else {
            [pscustomobject][ordered]@{ hooks = @($handler) }
        }
        Add-HookGroup -HooksObject $codexHooksObject -EventName $eventName -Group $group -ExactCommand $windowsCommand
    }
    Backup-File $CodexHooks
    Write-JsonFile -Value $codex -Path $CodexHooks
    Write-Host "Codex hook ($ScopeLabel) installed in: $CodexHooks"
}

Write-Host 'Restart the clients and review /hooks. Codex may require trusting the new command.'
