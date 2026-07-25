param(
    [string]$ConfigPath,
    [switch]$NoInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom
}
catch { }

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$ValidateScript = Join-Path $ScriptRoot 'Validate-Config.ps1'
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
# Install-state registry + installed-state integrity evaluation (install-time
# only - deliberately NOT in _hooklib.ps1, which ships inside every runtime).
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
# Console presentation: the colour table and every painted-line helper (phase
# headers, fields, menu/hook-menu rows, question prompts), plus the canonical
# per-hook menu metadata. Dot-sourced first so the rest of this file and every
# module below it render through one set of primitives.
. (Join-Path $ScriptRoot 'Setup-SyncGroupPresentation.ps1')
. (Join-Path $ScriptRoot 'Setup-SyncGroupBuilder.ps1')
# Installed-hook management (the "Update installed hooks" / "Uninstall
# installed hooks" rows of the hook list) plus the ONE canonical
# numeric list/range parser both this menu and those screens use.
. (Join-Path $ScriptRoot 'Setup-SyncGroupInstalledHooks.ps1')
# Hook-status discovery wizard (the "Get hook status" row): the scan prompts and the
# grouped result screen. The scan itself lives in Get-HookStatus.ps1.
. (Join-Path $ScriptRoot 'Setup-SyncGroupHookStatus.ps1')
# Guided hook creation: the five starter hook-body templates, the custom-
# hook target-selection flow, and the Invoke-CreateHook stage machine.
. (Join-Path $ScriptRoot 'Setup-SyncGroupCreateHook.ps1')
# The create-or-install sub-menu flows: installing existing hooks, installing
# every hook a profile config names, updating previously installed hooks, and
# the sub-menu that dispatches them alongside "Create a new hook".
. (Join-Path $ScriptRoot 'Setup-SyncGroupInstallFlows.ps1')
$UninstallScript = Join-Path $ScriptRoot 'Uninstall-Hook.ps1'
$StatusScript = Join-Path $ScriptRoot 'Get-HookStatus.ps1'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ToolRoot 'sync-hooks.json'
}
else {
    $ConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
}

# --------------------------------------------------------------- logging ----
$script:LogPath = $null
$script:EmptyReads = 0

function Initialize-Log {
    try {
        $logDir = Join-Path $ToolRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss')
        $base = Join-Path $logDir ('Setup-SyncGroup_' + $stamp + '_UTC')
        $candidate = $base + '.log'
        $suffix = 1
        while (Test-Path -LiteralPath $candidate) {
            $candidate = $base + '_' + $suffix + '.log'
            $suffix++
        }
        [System.IO.File]::WriteAllText($candidate, '', $Utf8NoBom)
        $script:LogPath = $candidate
    }
    catch {
        $script:LogPath = $null
        Write-NoteLine ('Warning: file logging is unavailable: ' + $_.Exception.Message)
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($null -eq $script:LogPath) {
        return
    }
    $line = '[' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC] [' + $Level + '] [' + $Component + '] ' + $Message
    try {
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $Utf8NoBom)
    }
    catch { }
}

# ----------------------------------------------------------------- input ----
# Reads one answer. Logs it like FFmWiz ("User input: prompt=...; value=...").
# 'exit'/'quit' aborts the wizard; '0' is returned for the caller's back handling.
function Read-Answer {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$LogLabel
    )

    Write-Host -NoNewline $Prompt
    $line = Read-Host
    if ($null -eq $line) {
        throw 'Input stream ended unexpectedly.'
    }
    $value = $line.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $script:EmptyReads++
        if ($script:EmptyReads -gt 200) {
            throw 'Too many consecutive empty inputs; aborting.'
        }
    }
    else {
        $script:EmptyReads = 0
    }

    $lower = $value.ToLowerInvariant()
    $action = 'answer'
    if ($lower -eq 'exit' -or $lower -eq 'quit') {
        $action = 'quit'
    }
    elseif ($value -eq '0') {
        $action = 'back'
    }
    $defaultUsed = 'no'
    if ($value -eq '') {
        $defaultUsed = 'yes'
    }
    Write-Log 'DEBUG' 'INPUT' ('User input: prompt=' + $LogLabel + "; value='" + $value + "'; default_used=" + $defaultUsed + '; action=' + $action)

    if ($action -eq 'quit') {
        throw 'WIZ:EXIT'
    }
    return $value
}

# y/n question; Enter = default; returns $null when the user backs out with 0.
function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][bool]$Default,
        [Parameter(Mandatory = $true)][string]$LogLabel
    )

    $defaultText = 'n'
    if ($Default) {
        $defaultText = 'y'
    }
    while ($true) {
        $value = (Read-Answer $Prompt $LogLabel).ToLowerInvariant()
        if ($value -eq '0') {
            return $null
        }
        if ($value -eq '') {
            return $Default
        }
        if ($value -eq 'y' -or $value -eq 'yes') {
            return $true
        }
        if ($value -eq 'n' -or $value -eq 'no') {
            return $false
        }
        Write-ErrorLine ('Enter only y or n. Default on Enter: ' + $defaultText)
    }
}

# --------------------------------------------------------------- helpers ----
function Get-Slug {
    param([Parameter(Mandatory = $true)][string]$Name)

    $slug = [System.Text.RegularExpressions.Regex]::Replace($Name.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'project'
    }
    return $slug
}

# Name of the sync-engine hook folder. Excluded from Get-HookEntries: the
# engine only works when installed via "Create or update a sync group" (item
# 2 of the "Install an existing hook" list), which passes -Profile and copies
# sync-hooks.json alongside it.
# Installed as a generic custom hook (no -Profile, no config copy) it can never
# resolve its own routing config once copied into a project and silently does
# nothing forever - so it must not be selectable from the plain hook lists.
$script:EngineHookName = 'Cross-Project-.ai-Knowledge-Sync'

# Hooks live one folder per hook: hooks\<Name>\<Name>.ps1 (+ .env/.env.example).
# Loose .ps1 files directly in hooks\ are still accepted for compatibility.
function Get-HookEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    $hookDirs = Get-ChildItem -LiteralPath $HooksDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $script:EngineHookName } |
        Sort-Object @{ Expression = { if ($script:HookMeta.ContainsKey($_.Name)) { $script:HookMeta[$_.Name].Order } else { [int]::MaxValue } } }, Name
    foreach ($dir in @($hookDirs)) {
        $script = Join-Path $dir.FullName ($dir.Name + '.ps1')
        if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
            $firstScript = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -First 1
            if ($null -eq $firstScript) { continue }
            $script = $firstScript.FullName
        }
        [void]$entries.Add([pscustomobject]@{
            Name       = $dir.Name
            ScriptPath = $script
            EnvPath    = (Join-Path $dir.FullName '.env')
        })
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $HooksDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Where-Object { -not $_.BaseName.StartsWith('_') } | Sort-Object Name)) {
        [void]$entries.Add([pscustomobject]@{
            Name       = $file.BaseName
            ScriptPath = $file.FullName
            EnvPath    = ''
        })
    }
    return $entries.ToArray()
}

function Get-HookRecommendedEvents {
    param([Parameter(Mandatory = $true)]$Hook)
    # $script:HookMeta is the canonical source: a hook that declares Events
    # there wins over any .env.example, so the menu tag, the recommended events
    # and the installed registration can never disagree. Hooks without an
    # Events key keep the historical .env.example -> generic-default order
    # byte-for-byte.
    if ($script:HookMeta.ContainsKey($Hook.Name) -and $script:HookMeta[$Hook.Name].ContainsKey('Events')) {
        return @($script:HookMeta[$Hook.Name].Events)
    }
    if (-not [string]::IsNullOrWhiteSpace($Hook.EnvPath)) {
        $examplePath = Join-Path (Split-Path -Parent $Hook.EnvPath) '.env.example'
        $values = Read-HookEnv $examplePath
        if ($values.ContainsKey('EVENTS') -and -not [string]::IsNullOrWhiteSpace($values['EVENTS'])) {
            return @($values['EVENTS'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
    }
    return @('SessionStart', 'UserPromptSubmit')
}

# Asks which client(s) the hook is installed for. Returns 'Both', 'Claude',
# 'Codex', or $null when the user backs out.
function Read-ClientChoice {
    while ($true) {
        Write-MenuTitle 'Client:'
        Write-MenuLine 1 'Both' '(Claude + Codex)'
        Write-MenuLine 2 'Claude only' '(.claude\settings.local.json)'
        Write-MenuLine 3 'Codex only' '(.codex\hooks.json)'
        $value = Read-Answer (New-QuestionPrompt 'Select the client' $null '1') 'select client'
        if ($value -eq '0') {
            return $null
        }
        if ($value -eq '') {
            $value = '1'
        }
        switch ($value) {
            '1' { return 'Both' }
            '2' { return 'Claude' }
            '3' { return 'Codex' }
            default { Write-ErrorLine 'Enter 1, 2, 3 or 0.' }
        }
    }
}

# Maps a client choice to an Install-Hook.ps1 splat (empty hashtable = both).
# MUST be a hashtable, not an array: splatting @('-ClaudeOnly') mis-binds the
# bare "-ClaudeOnly" string as a positional value onto Install-Hook's first
# positional parameter ($Profile), which then collides with -CustomHook.
function Get-ClientInstallArgs {
    param([string]$Clients)
    switch ($Clients) {
        'Claude' { return @{ ClaudeOnly = $true } }
        'Codex' { return @{ CodexOnly = $true } }
        default { return @{} }
    }
}

# Per-hook registration timeout, from the canonical metadata. Returns an EMPTY
# splat for every hook without an explicit Timeout, so Install-Hook.ps1 keeps
# resolving those exactly as before (persisted record value, else 60) - passing
# an explicit 60 here would instead overwrite a deliberately repaired record.
function Get-HookTimeoutArgs {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:HookMeta.ContainsKey($Name) -and $script:HookMeta[$Name].ContainsKey('Timeout')) {
        return @{ Timeout = [int]$script:HookMeta[$Name].Timeout }
    }
    return @{}
}

# Human-readable "where does it land" label for summaries.
function Get-ClientInstallLabel {
    param([string]$Clients)
    switch ($Clients) {
        'Claude' { return 'per project: .claude\settings.local.json (Claude only)' }
        'Codex' { return 'per project: .codex\hooks.json (Codex only)' }
        default { return 'per project: .claude\settings.local.json + .codex\hooks.json' }
    }
}


# Reads an event selection (or a custom list). Returns an events array, or
# $null when the user backs out. When $RecommendedEvents is non-empty (the
# SPECIFIC hook's own recommended EVENTS, from Get-HookRecommendedEvents), it
# becomes choice 1 - a clear, correctly-defaulted option - instead of the
# single-hook flow silently defaulting to the generic "SessionStart,
# UserPromptSubmit" pair on a bare Enter, regardless of what the hook actually
# needs (e.g. a Stop-only hook like Cloudflare-Deploy/Ci-Status-Check, or a
# SessionStart+Stop hook like Docs-Freshness-Check). Nothing is removed - every
# other choice (including full custom) still follows.
function Read-EventSelection {
    param([string]$TitleSuffix = '', [string[]]$RecommendedEvents = @())
    $knownEvents = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop', 'PreCompact', 'SessionEnd', 'Notification', 'PermissionRequest', 'PostCompact', 'SubagentStart')
    $recommended = @($RecommendedEvents | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hasRecommended = $recommended.Count -gt 0

    $choices = New-Object System.Collections.Generic.List[object]
    if ($hasRecommended) {
        [void]$choices.Add(@{ Label = "This hook's recommended events"; Hint = '(' + ($recommended -join ', ') + ')'; Events = $recommended })
    }
    $sessionPromptHint = if ($hasRecommended) { '(context hooks)' } else { '(context hooks - recommended)' }
    [void]$choices.Add(@{ Label = 'Session Start + User Prompt Submit'; Hint = $sessionPromptHint; Events = @('SessionStart', 'UserPromptSubmit') })
    [void]$choices.Add(@{ Label = 'Session Start'; Hint = ''; Events = @('SessionStart') })
    [void]$choices.Add(@{ Label = 'User Prompt Submit'; Hint = ''; Events = @('UserPromptSubmit') })
    $customChoiceNumber = $choices.Count + 1

    while ($true) {
        Write-MenuTitle ('Events' + $TitleSuffix + ':')
        for ($i = 0; $i -lt $choices.Count; $i++) {
            Write-MenuLine ($i + 1) $choices[$i].Label $choices[$i].Hint
        }
        Write-MenuLine $customChoiceNumber 'Custom list' '(e.g. Pre Tool Use, Post Tool Use, Stop)'
        $value = Read-Answer (New-QuestionPrompt 'Select events' $null '1') 'select events'
        if ($value -eq '0') { return $null }
        if ($value -eq '') { $value = '1' }
        $picked = 0
        if ([int]::TryParse($value, [ref]$picked) -and $picked -ge 1 -and $picked -le $choices.Count) {
            return @($choices[$picked - 1].Events)
        }
        if ($picked -eq $customChoiceNumber) {
            $raw = Read-Answer (New-QuestionPrompt 'Event names' ('comma separated; example: ' + (Get-ExampleText 'PreToolUse,PostToolUse')) $null) 'custom event list'
            if ($raw -eq '0') { continue }
            $candidates = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            if ($candidates.Count -eq 0) { Write-ErrorLine 'Enter at least one event name.'; continue }
            $invalid = @($candidates | Where-Object { $_ -notmatch '^[A-Za-z]+$' })
            if ($invalid.Count -gt 0) { Write-ErrorLine ('Invalid event name(s): ' + ($invalid -join ', ')); continue }
            $unknown = @($candidates | Where-Object { $knownEvents -notcontains $_ })
            if ($unknown.Count -gt 0) { Write-NoteLine ('Not a known event (installing anyway): ' + ($unknown -join ', ')) }
            return $candidates
        }
        Write-ErrorLine ('Enter a number between 1 and ' + $customChoiceNumber + '.')
    }
}

# Gathers events + client + target projects for one hook as a mini stage machine
# (back steps one). Returns an object, or $null when backed out of the first step.
function Read-HookConfig {
    param([string]$TitleSuffix = '', [switch]$SkipEvents, [string[]]$RecommendedEvents = @(), [object[]]$InitialTargets = @())
    # When $InitialTargets is supplied (the project paths already collected by the
    # sync group in this same batch), the path prompt is skipped entirely - the
    # user typed those paths once and there is no reason to ask again. They stay
    # editable from the summary screen (Read-ProjectList -InitialProjects).
    $reuseTargets = (@($InitialTargets).Count -gt 0)
    $events = $null; $clients = $null; $stage = if ($SkipEvents) { 1 } else { 0 }
    while ($true) {
        switch ($stage) {
            0 {
                $events = Read-EventSelection $TitleSuffix $RecommendedEvents
                if ($null -eq $events) { return $null }
                $stage = 1
            }
            1 {
                $clients = Read-ClientChoice
                if ($null -eq $clients) {
                    if ($SkipEvents) { return $null }
                    $stage = 0
                    break
                }
                $stage = 2
            }
            2 {
                if ($reuseTargets) {
                    return [pscustomobject]@{ Events = @($events); Clients = $clients; Targets = @($InitialTargets) }
                }
                $targets = Read-ProjectList -MinimumCount 1
                if ($null -eq $targets) { $stage = 1; break }
                return [pscustomobject]@{ Events = @($events); Clients = $clients; Targets = @($targets) }
            }
        }
    }
}

# ------------------------------------------------------- info flows (2/3) ----
function Show-Profiles {
    Write-PhaseHeader 'Configured Profiles' $C.Input '-'
    $config = Read-JsonFile $ConfigPath
    if ($null -eq $config -or $null -eq $config.PSObject.Properties['profiles'] -or $null -eq $config.profiles -or @($config.profiles).Count -eq 0) {
        Write-NoteLine '  No profiles configured.'
        Write-Log 'INFO' 'MENU' 'Listed profiles: none.'
        return
    }
    foreach ($profileConfig in @($config.profiles)) {
        $id = ''
        if ($null -ne $profileConfig.PSObject.Properties['id']) {
            $id = [string]$profileConfig.id
        }
        $name = $id
        if ($null -ne $profileConfig.PSObject.Properties['name']) {
            $name = [string]$profileConfig.name
        }
        $enabled = $true
        if ($null -ne $profileConfig.PSObject.Properties['enabled']) {
            $enabled = [bool]$profileConfig.enabled
        }
        $stateText = Get-Painted 'disabled' $C.Red
        if ($enabled) {
            $stateText = Get-Painted 'enabled' $C.Green
        }
        $routes = @()
        if ($null -ne $profileConfig.PSObject.Properties['routes'] -and $null -ne $profileConfig.routes) {
            $routes = @($profileConfig.routes)
        }
        Write-Host ('  ' + (Get-Painted $id $C.Aqua) + '  ' + (Get-Painted $name $C.Gray) + '  ' + $stateText + (Get-Painted ('  (' + $routes.Count + ' routes)') $C.Dim))
        foreach ($route in $routes) {
            $sourceName = ''
            $destinationName = ''
            if ($null -ne $route.PSObject.Properties['source'] -and $null -ne $route.source) {
                if ($null -ne $route.source.PSObject.Properties['name']) { $sourceName = [string]$route.source.name } elseif ($null -ne $route.source.PSObject.Properties['root']) { $sourceName = [string]$route.source.root }
            }
            if ($null -ne $route.PSObject.Properties['destination'] -and $null -ne $route.destination) {
                if ($null -ne $route.destination.PSObject.Properties['name']) { $destinationName = [string]$route.destination.name } elseif ($null -ne $route.destination.PSObject.Properties['root']) { $destinationName = [string]$route.destination.root }
            }
            Write-Host ('      ' + (Get-Painted ($sourceName + ' -> ' + $destinationName) $C.Dim))
        }
    }
    Write-Log 'INFO' 'MENU' ('Listed profiles: ' + @($config.profiles).Count)
}

function Invoke-Validate {
    Write-PhaseHeader 'Validate Configuration' $C.Input '-'
    try {
        $output = & $ValidateScript -ConfigPath $ConfigPath *>&1
        foreach ($line in @($output)) {
            Write-Host ('  ' + (Get-Painted ([string]$line) $C.Green))
            Write-Log 'DEBUG' 'VALIDATE' ([string]$line)
        }
        Write-Log 'INFO' 'VALIDATE' 'Configuration valid.'
    }
    catch {
        Write-ErrorLine ('Validation failed: ' + $_.Exception.Message)
        Write-Log 'ERROR' 'VALIDATE' ('Validation failed: ' + $_.Exception.Message)
    }
}

# ------------------------------------------------------------- main menu ----
# Startup banner, printed once: centered bold title over a full-width bar,
# followed by the log-file note.
function Show-Banner {
    $title = 'Hook Maker'
    $width = Get-TermWidth
    $pad = [Math]::Max(0, [int](($width - $title.Length) / 2))
    Write-Host ((' ' * $pad) + (Get-Painted $title $C.Title))
    Write-Host (Get-Painted ('=' * $width) $C.TitleBar)
    if ($null -ne $script:LogPath) {
        Write-NoteLine ('Logging to: ' + $script:LogPath)
    }
    else {
        Write-NoteLine 'Logging to: (logging is disabled)'
    }
}

function Show-MainMenu {
    Write-Host ''
    Write-MenuTitle 'Main menu:'
    Write-MenuLine 1 'Create or install a hook' '(sync group + hooks\ folder)'
    Write-MenuLine 2 'Show configured profiles'
    Write-MenuLine 3 'Validate configuration'
}

# ----------------------------------------------------------------- entry ----
Initialize-Log
Write-Log 'INFO' 'STARTUP' ('Execution id: ' + [guid]::NewGuid().ToString())
Write-Log 'INFO' 'STARTUP' ('Script: ' + $PSCommandPath)
# The real config is machine-local (git-ignored); seed it from the tracked
# example on first run so a fresh clone works out of the box.
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $examplePath = Join-Path $ToolRoot 'sync-hooks.example.json'
    if (Test-Path -LiteralPath $examplePath -PathType Leaf) {
        Copy-Item -LiteralPath $examplePath -Destination $ConfigPath -Force
        Write-Log 'INFO' 'STARTUP' ('Config seeded from example: ' + $examplePath + ' -> ' + $ConfigPath)
    }
}
Write-Log 'INFO' 'STARTUP' ('Config: ' + $ConfigPath)
Write-Log 'INFO' 'STARTUP' ('Hooks dir: ' + $HooksDir)
Write-Log 'INFO' 'STARTUP' ('OS: ' + [Environment]::OSVersion.VersionString)
Write-Log 'INFO' 'STARTUP' ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
Write-Log 'INFO' 'STARTUP' ('NoInstall: ' + [bool]$NoInstall)

try {
    Show-Banner
    :menu while ($true) {
        $script:QuestionNumber = 0
        Show-MainMenu
        $menuPrompt = New-QuestionPrompt 'Select an option' $null '1' -QuitOnly
        while ($true) {
            $choice = Read-Answer $menuPrompt 'main menu'
            if ($choice -eq '') {
                $choice = '1'
            }
            $mainAction = @{ '1' = 'Create or install a hook'; '2' = 'Show configured profiles'; '3' = 'Validate configuration'; '0' = 'Exit' }[$choice]
            if ($mainAction) { Write-Log 'INFO' 'MENU' ('Main menu -> ' + $choice + '. ' + $mainAction) }
            switch ($choice) {
                '1' { Invoke-CustomHookMenu; continue menu }
                '2' { Show-Profiles; continue menu }
                '3' { Invoke-Validate; continue menu }
                '0' { break menu }
                default { Write-ErrorLine 'Enter 1, 2, 3 or 0.' }
            }
        }
    }
}
catch {
    if ($_.Exception.Message -eq 'WIZ:EXIT') {
        Write-NoteLine 'Exiting.'
        Write-Log 'INFO' 'DONE' 'User quit the wizard.'
        exit 0
    }
    Write-ErrorLine ('Fatal error: ' + $_.Exception.Message)
    Write-Host (Get-Painted $_.ScriptStackTrace $C.Dim)
    Write-Log 'CRITICAL' 'ERROR' ('Fatal: ' + $_.Exception.ToString() + ' | at: ' + $_.ScriptStackTrace)
    exit 1
}

Write-Log 'INFO' 'DONE' 'Wizard exited normally.'
exit 0
