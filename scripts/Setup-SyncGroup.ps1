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
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ToolRoot 'sync-hooks.json'
}
else {
    $ConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
}

# ---------------------------------------------------------------- colors ----
$Esc = [char]27
$C = @{
    Reset      = "$Esc[0m"
    Bold       = "$Esc[1m"
    Red        = "$Esc[91m"
    Green      = "$Esc[92m"
    White      = "$Esc[97m"
    Gray       = "$Esc[38;5;252m"
    Dim        = "$Esc[38;5;250m"
    LightBlue  = "$Esc[38;5;117m"
    HintYellow = "$Esc[38;5;221m"
    NoteYellow = "$Esc[38;5;227m"
    BackPrompt = "$Esc[38;5;166m"
    ExitPrompt = "$Esc[38;5;32m"
    Aqua       = "$Esc[38;5;159m"
    Amber      = "$Esc[38;5;214m"
    Mint       = "$Esc[38;5;121m"
    TitleBar   = "$Esc[38;2;255;50;115m"
    Title      = "$Esc[1m$Esc[38;2;255;50;115m"
    Input      = "$Esc[1m$Esc[38;2;68;221;255m"
    Summary    = "$Esc[1m$Esc[38;2;170;255;82m"
    Confirm    = "$Esc[1m$Esc[38;2;255;155;60m"
    Process    = "$Esc[1m$Esc[38;2;80;255;205m"
    Done       = "$Esc[1m$Esc[38;2;145;255;95m"
}

function Get-Painted {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$Color)
    return $Color + $Text + $C.Reset
}

function Get-TermWidth {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -ge 20) {
            return [Math]::Min([int]$width, 120)
        }
    }
    catch { }
    return 80
}

function Write-PhaseHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Color,
        [string]$Char = '='
    )

    $width = Get-TermWidth
    $pad = [Math]::Max(0, [int](($width - $Text.Length) / 2))
    Write-Host ''
    Write-Host ($Color + (' ' * $pad) + $Text + $C.Reset)
    Write-Host ($Color + ($Char * $width) + $C.Reset)
}

# Field line: gray "label:" + colored value (FFmWiz field_text).
function Write-Field {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [string]$ValueColor = ''
    )

    if ([string]::IsNullOrEmpty($ValueColor)) {
        $ValueColor = $C.White
    }
    Write-Host ('  ' + (Get-Painted ($Name + ':') $C.Gray) + ' ' + (Get-Painted $Value $ValueColor))
}

# Numbered menu option: sky-blue "N." + bold label (FFmWiz selection_menu_line).
function Write-MenuLine {
    param([Parameter(Mandatory = $true)][int]$Number, [Parameter(Mandatory = $true)][string]$Label, [string]$Suffix = '')

    $line = '  ' + (Get-Painted ($Number.ToString() + '.') $C.LightBlue) + ' ' + (Get-Painted $Label $C.Bold)
    if ($Suffix) {
        $line += ' ' + (Get-Painted $Suffix $C.Gray)
    }
    Write-Host $line
}

function Write-MenuTitle {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host (Get-Painted $Text ($C.Bold + $C.LightBlue))
}

function Write-ErrorLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host (Get-Painted $Message $C.Red)
}

function Write-NoteLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host (Get-Painted $Message $C.NoteYellow)
}

# Precomputed prompt suffixes - the two specs never vary, so colorize each once
# instead of splitting + regex-matching a spec string on every prompt render.
# Full: normal prompts (back one step + quit). Quit-only: the main menu (no back).
$script:BackTextFull = (Get-Painted '{' $C.White) + (Get-Painted 'back=0' $C.BackPrompt) + (Get-Painted ', ' $C.White) + (Get-Painted 'quit=exit' $C.ExitPrompt) + (Get-Painted '}' $C.White)
$script:BackTextQuit = (Get-Painted '{' $C.White) + (Get-Painted 'quit=exit' $C.ExitPrompt) + (Get-Painted '}' $C.White)

# Question prompt: "\nN. Title (hint) [default] {back=0, quit=exit}: " (FFmWiz question_prompt).
$script:QuestionNumber = 0
function New-QuestionPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Details,
        [string]$Default,
        [switch]$QuitOnly   # main menu: show {quit=exit} (there is no step to go back to)
    )

    $script:QuestionNumber++
    $prompt = "`n" + (Get-Painted ($script:QuestionNumber.ToString() + '. ' + $Title) $C.Bold)
    if (-not [string]::IsNullOrEmpty($Details)) {
        $prompt += ' (' + (Get-Painted $Details $C.HintYellow) + ')'
    }
    if (-not [string]::IsNullOrEmpty($Default)) {
        $prompt += ' ' + (Get-Painted ('[' + $Default + ']') $C.Green)
    }
    $suffix = if ($QuitOnly) { $script:BackTextQuit } else { $script:BackTextFull }
    return $prompt + ' ' + $suffix + ': '
}

function Get-ExampleText {
    param([Parameter(Mandatory = $true)][string]$Text)
    # Example values keep their own color inside hints (FFmWiz example_text).
    return (Get-Painted $Text $C.LightBlue) + $C.HintYellow
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
function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $full = [System.IO.Path]::GetFullPath($expanded)
    return $full.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    if ([string]::Equals($Candidate, $Parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $Parent + [System.IO.Path]::DirectorySeparatorChar
    return $Candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-Slug {
    param([Parameter(Mandatory = $true)][string]$Name)

    $slug = [System.Text.RegularExpressions.Regex]::Replace($Name.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'project'
    }
    return $slug
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

# Simple KEY=VALUE .env parser ('#' comments allowed). Returns a hashtable.
function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -gt 0) {
            $values[$trimmed.Substring(0, $separator).Trim()] = $trimmed.Substring($separator + 1).Trim()
        }
    }
    return $values
}

# Hooks live one folder per hook: hooks\<Name>\<Name>.ps1 (+ .env/.env.example).
# Loose .ps1 files directly in hooks\ are still accepted for compatibility.
function Get-HookEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($dir in @(Get-ChildItem -LiteralPath $HooksDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
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

# Maps a client choice to Install-Hook.ps1 switches (empty array = both).
function Get-ClientInstallArgs {
    param([string]$Clients)
    switch ($Clients) {
        'Claude' { return @('-ClaudeOnly') }
        'Codex' { return @('-CodexOnly') }
        default { return @() }
    }
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

# ----------------------------------------------------------- input phase ----
# Collects project root paths. Returns an array, or $null when the user backs out.
function Read-ProjectList {
    param(
        [int]$MinimumCount = 2,
        [switch]$ShowAiNote
    )

    Write-PhaseHeader 'Add Projects' $C.Input '-'
    Write-MenuTitle 'Target projects:'
    Write-Host (Get-Painted ('  Enter each project root path, one per line (at least ' + $MinimumCount + ').') $C.Gray)

    $example = Get-ExampleText 'G:\Projects\My Bot'
    $prompt = New-QuestionPrompt 'Project root path' ('done=finish, undo=remove last; example: ' + $example) $null

    $projects = New-Object System.Collections.Generic.List[object]
    while ($true) {
        $value = Read-Answer $prompt 'project root path'
        if ($value -eq '0') {
            Write-Log 'INFO' 'INPUT' 'User backed out of project entry.'
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-ErrorLine 'This value cannot be empty. Enter a path, or done to finish.'
            continue
        }
        $lower = $value.ToLowerInvariant()

        if ($lower -eq 'undo') {
            if ($projects.Count -gt 0) {
                $removed = $projects[$projects.Count - 1]
                $projects.RemoveAt($projects.Count - 1)
                Write-Host ('  ' + (Get-Painted ('- removed ' + $removed.Name + '  ' + $removed.Root) $C.Dim))
                Write-Log 'INFO' 'INPUT' ('Removed project: ' + $removed.Root)
            }
            else {
                Write-NoteLine 'Nothing to undo.'
            }
            continue
        }
        if ($lower -eq 'done') {
            if ($projects.Count -ge $MinimumCount) {
                break
            }
            Write-ErrorLine ('At least ' + $MinimumCount + ' project(s) required (currently ' + $projects.Count + ').')
            continue
        }

        try {
            $root = Normalize-Path $value
        }
        catch {
            Write-ErrorLine ('Invalid path: ' + $value)
            Write-Log 'WARNING' 'INPUT' ('Invalid path rejected: ' + $value)
            continue
        }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-ErrorLine ('Directory not found: ' + $root)
            Write-Log 'WARNING' 'INPUT' ('Missing directory rejected: ' + $root)
            continue
        }

        $isDuplicate = $false
        foreach ($existing in $projects) {
            if ([string]::Equals($existing.Root, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isDuplicate = $true
                break
            }
        }
        if ($isDuplicate) {
            Write-NoteLine ('Already added: ' + $root)
            Write-Log 'WARNING' 'INPUT' ('Duplicate rejected: ' + $root)
            continue
        }

        $overlap = $null
        foreach ($existing in $projects) {
            if ((Test-PathInside -Candidate $root -Parent $existing.Root) -or (Test-PathInside -Candidate $existing.Root -Parent $root)) {
                $overlap = $existing
                break
            }
        }
        if ($null -ne $overlap) {
            Write-ErrorLine ('Path overlaps an already added project: ' + $overlap.Root)
            Write-Log 'WARNING' 'INPUT' ('Nested path rejected: ' + $root + ' vs ' + $overlap.Root)
            continue
        }

        $aiPath = Join-Path $root '.ai'
        $entry = [pscustomobject][ordered]@{
            Name     = Split-Path -Leaf $root
            Root     = $root
            AiPath   = $aiPath
            AiExists = (Test-Path -LiteralPath $aiPath -PathType Container)
        }
        [void]$projects.Add($entry)

        $note = ''
        if ($ShowAiNote) {
            if ($entry.AiExists) {
                $note = ' ' + (Get-Painted '(.ai exists)' $C.Mint)
            }
            else {
                $note = ' ' + (Get-Painted '(.ai will be created)' $C.Amber)
            }
        }
        Write-Host ('  ' + (Get-Painted '+ added' $C.Green) + ' ' + (Get-Painted $entry.Name $C.Bold) + '  ' + (Get-Painted $entry.Root $C.Gray) + $note)
        Write-Log 'INFO' 'INPUT' ('Added project: ' + $root + ' | aiExists=' + $entry.AiExists)
    }

    return $projects.ToArray()
}

# --------------------------------------------------------- profile build ----
function New-GroupProfile {
    param([Parameter(Mandatory = $true)]$Projects)

    $canonical = (@($Projects | ForEach-Object { $_.Root.ToLowerInvariant() }) | Sort-Object) -join '|'
    $profileId = 'sync-group-' + (Get-ShortHash -Text $canonical)

    # Deterministic slugs: assign in sorted-root order so re-runs keep the same route ids.
    $slugMap = @{}
    $usedSlugs = @{}
    foreach ($project in @($Projects | Sort-Object -Property Root)) {
        $slug = Get-Slug -Name $project.Name
        $candidate = $slug
        $counter = 2
        while ($usedSlugs.ContainsKey($candidate)) {
            $candidate = $slug + '-' + $counter
            $counter++
        }
        $usedSlugs[$candidate] = $true
        $slugMap[$project.Root] = $candidate
    }

    $routes = New-Object System.Collections.Generic.List[object]
    foreach ($source in $Projects) {
        foreach ($destination in $Projects) {
            if ([string]::Equals($source.Root, $destination.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            [void]$routes.Add([pscustomobject][ordered]@{
                id          = $slugMap[$source.Root] + '-to-' + $slugMap[$destination.Root]
                enabled     = $true
                source      = [pscustomobject][ordered]@{
                    name      = $source.Name
                    root      = $source.Root
                    directory = '.ai'
                    aliases   = @()
                }
                destination = [pscustomobject][ordered]@{
                    name      = $destination.Name
                    root      = $destination.Root
                    directory = '.ai'
                    aliases   = @()
                }
            })
        }
    }

    return [pscustomobject][ordered]@{
        id      = $profileId
        name    = 'Sync group: ' + ((@($Projects | ForEach-Object { $_.Name })) -join ' + ')
        enabled = $true
        routes  = $routes.ToArray()
    }
}

# --------------------------------------------------- sync group flow (1) ----
function Invoke-CreateGroup {
    Write-Log 'INFO' 'GROUP' 'Create/update sync group started.'

    $config = Read-JsonFile $ConfigPath
    if ($null -eq $config) {
        Write-ErrorLine ('Config file not found or empty: ' + $ConfigPath)
        Write-Log 'ERROR' 'CONFIG' ('Config missing or empty: ' + $ConfigPath)
        return
    }

    $events = @('SessionStart', 'UserPromptSubmit')
    if ($null -ne $config.PSObject.Properties['defaults'] -and $null -ne $config.defaults -and
        $null -ne $config.defaults.PSObject.Properties['events'] -and $null -ne $config.defaults.events) {
        $events = @($config.defaults.events)
    }

    # Optional config mode: hooks\CrossProjectSyncHook\.env can predefine the
    # group's project paths (SYNC_PROJECTS) so nothing has to be typed.
    $configProjects = @()
    $engineEnv = Read-EnvFile (Join-Path $HooksDir 'CrossProjectSyncHook\.env')
    if ($engineEnv.ContainsKey('SYNC_PROJECTS') -and $engineEnv['SYNC_PROJECTS'] -ne '') {
        foreach ($path in @($engineEnv['SYNC_PROJECTS'].Split(';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })) {
            try {
                $root = Normalize-Path $path
            }
            catch {
                Write-NoteLine ('Ignoring invalid path in SYNC_PROJECTS: ' + $path)
                continue
            }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-NoteLine ('Ignoring missing directory in SYNC_PROJECTS: ' + $root)
                continue
            }
            $aiPath = Join-Path $root '.ai'
            $configProjects += [pscustomobject][ordered]@{
                Name     = Split-Path -Leaf $root
                Root     = $root
                AiPath   = $aiPath
                AiExists = (Test-Path -LiteralPath $aiPath -PathType Container)
            }
        }
    }

    # Stage machine: project entry (0) <-> client (1) <-> confirm (2). Back steps
    # one stage; back at project entry returns to the main menu.
    $projects = $null
    $groupProfile = $null
    $clients = 'Both'
    $routeCount = 0
    $stage = 0
    while ($true) {
        if ($stage -eq 0) {
            $projects = $null
            if ($configProjects.Count -ge 2) {
                $useConfig = Read-YesNo (New-QuestionPrompt 'Use the project paths from the config?' ($configProjects.Count.ToString() + ' path(s) in hooks\CrossProjectSyncHook\.env') 'y') $true 'use sync config'
                if ($null -eq $useConfig) {
                    return
                }
                if ($useConfig -eq $true) {
                    $projects = @($configProjects)
                }
            }
            if ($null -eq $projects) {
                $projects = Read-ProjectList -MinimumCount 2 -ShowAiNote
                if ($null -eq $projects) {
                    return
                }
            }
            $groupProfile = New-GroupProfile -Projects $projects
            $routeCount = @($groupProfile.routes).Count
            $stage = 1
            continue
        }
        if ($stage -eq 1) {
            # Which client(s) gets the sync hook (Claude / Codex / both).
            $clients = Read-ClientChoice
            if ($null -eq $clients) {
                $stage = 0
                continue
            }
            $stage = 2
            continue
        }

        # stage 2: summary + confirm
        Write-PhaseHeader 'Summary' $C.Summary '-'
        Write-MenuTitle 'Sync group:'
        for ($i = 0; $i -lt $projects.Count; $i++) {
            $project = $projects[$i]
            $note = '(.ai will be created)'
            $noteColor = $C.Amber
            if ($project.AiExists) {
                $note = '(.ai exists)'
                $noteColor = $C.Mint
            }
            Write-MenuLine ($i + 1) $project.Name ($project.Root + '  ')
            Write-Host ('     ' + (Get-Painted $note $noteColor))
        }
        Write-Host ''
        Write-Field 'profile id' $groupProfile.id $C.Aqua
        Write-Field 'profile name' $groupProfile.name
        Write-Field 'routes' ($routeCount.ToString() + ' (full mesh)')
        Write-Field 'events' ($events -join ', ')
        Write-Field 'config file' $ConfigPath $C.LightBlue
        if ($NoInstall) {
            Write-Field 'hook install' 'skipped (-NoInstall)' $C.Amber
        }
        else {
            Write-Field 'client' $clients
            Write-Field 'hook install' (Get-ClientInstallLabel $clients)
        }
        Write-Host ''
        Write-Host (Get-Painted '  Routes:' $C.Gray)
        foreach ($route in @($groupProfile.routes)) {
            Write-Host ('    ' + (Get-Painted ($route.source.name + ' -> ' + $route.destination.name) $C.Dim))
        }

        Write-PhaseHeader 'Confirm' $C.Confirm '-'
        $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start sync group'
        if ($null -eq $confirm) {
            $stage = 1
            continue
        }
        if ($confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was changed.'
            Write-Log 'INFO' 'GROUP' 'User declined at confirmation; no changes applied.'
            return
        }
        break
    }
    Write-Log 'INFO' 'GROUP' ('Confirmed. Applying profile ' + $groupProfile.id + ' with ' + $routeCount + ' routes.')

    # ---- apply ----
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-PhaseHeader 'Applying Changes' $C.Process '-'

    foreach ($project in $projects) {
        if (-not $project.AiExists) {
            New-Item -ItemType Directory -Path $project.AiPath -Force | Out-Null
            Write-Host ('  ' + (Get-Painted '+ created' $C.Green) + ' ' + (Get-Painted $project.AiPath $C.LightBlue))
            Write-Log 'INFO' 'CONFIG' ('Created knowledge directory: ' + $project.AiPath)
        }
        else {
            Write-Host ('  ' + (Get-Painted ('= exists  ' + $project.AiPath) $C.Dim))
            Write-Log 'DEBUG' 'CONFIG' ('Knowledge directory exists: ' + $project.AiPath)
        }
    }

    $existingProfiles = @()
    if ($null -ne $config.PSObject.Properties['profiles'] -and $null -ne $config.profiles) {
        $existingProfiles = @($config.profiles)
    }
    $replaced = $false
    $newProfiles = New-Object System.Collections.Generic.List[object]
    foreach ($existing in $existingProfiles) {
        if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['id'] -and [string]$existing.id -eq $groupProfile.id) {
            [void]$newProfiles.Add($groupProfile)
            $replaced = $true
        }
        else {
            [void]$newProfiles.Add($existing)
        }
    }
    if (-not $replaced) {
        [void]$newProfiles.Add($groupProfile)
    }
    Set-ObjectProperty -Object $config -Name 'profiles' -Value $newProfiles.ToArray()
    if ($null -eq $config.PSObject.Properties['version']) {
        Set-ObjectProperty -Object $config -Name 'version' -Value 2
    }

    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $backupPath = $ConfigPath + '.backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        Write-Log 'INFO' 'CONFIG' ('Config backup created: ' + $backupPath)
    }
    Write-JsonFileAtomic -Value $config -Path $ConfigPath
    $action = 'added'
    if ($replaced) {
        $action = 'updated'
    }
    Write-Host ('  ' + (Get-Painted ('+ profile ' + $action) $C.Green) + ' ' + (Get-Painted $groupProfile.id $C.Aqua) + (Get-Painted (' (' + $routeCount + ' routes)') $C.Dim))
    Write-Log 'INFO' 'CONFIG' ('Profile ' + $action + ': ' + $groupProfile.id + ' | routes=' + $routeCount + ' | config=' + $ConfigPath)

    $validateOutput = & $ValidateScript -ConfigPath $ConfigPath *>&1
    foreach ($line in @($validateOutput)) {
        Write-Log 'DEBUG' 'VALIDATE' ([string]$line)
    }
    Write-Host ('  ' + (Get-Painted '+ configuration validated' $C.Green))
    Write-Log 'INFO' 'VALIDATE' 'Configuration validated after write.'

    if ($NoInstall) {
        Write-NoteLine '  hook install skipped (-NoInstall)'
        Write-Log 'INFO' 'INSTALL' 'Hook install skipped by -NoInstall.'
    }
    else {
        # Install the hook locally in each project, not in the user's home settings,
        # so only these projects carry the hook and nothing else on the machine is touched.
        $clientArgs = @(Get-ClientInstallArgs $clients)
        foreach ($project in $projects) {
            $installOutput = & $InstallScript -Profile $groupProfile.id -ConfigPath $ConfigPath -TargetProject $project.Root @clientArgs *>&1
            foreach ($line in @($installOutput)) {
                Write-Log 'INFO' 'INSTALL' ([string]$line)
            }
            Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $project.Name $C.Bold) + '  ' + (Get-Painted $project.Root $C.Gray))
        }
    }

    $stopwatch.Stop()
    Write-PhaseHeader 'Completed' $C.Done '='
    Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
    Write-Host (Get-Painted '  Opening any of these projects now reviews the other projects'' knowledge first.' $C.White)
    Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
    if ($null -ne $script:LogPath) {
        Write-Host (Get-Painted ('  Log: ' + $script:LogPath) $C.Dim)
    }
    Write-Log 'INFO' 'DONE' ('Sync group applied: ' + $groupProfile.id + ' | durationMs=' + $stopwatch.ElapsedMilliseconds)
}

# -------------------------------------------------- custom hook flow (2) ----
# Hook body templates. Each returns the full .ps1 text for a generated hook.
# Backticks escape $ so those tokens land literally in the generated file.
function Get-HookBody-ContextNote {
    param([string]$HookName, [string]$Message)
    $escaped = $Message.Replace("'", "''")
    return @"
# $HookName - injects a fixed context note into every matched event.
# Generated by Hook Maker. Edit freely; reinstall is not needed after edits.
`$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$note = '$escaped'
@{ hookSpecificOutput = @{ hookEventName = `$hookInput.hook_event_name; additionalContext = `$note } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
"@
}

function Get-HookBody-PromptGuard {
    param([string]$HookName, [string[]]$Words)
    $wordList = (@($Words | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })) -join ', '
    return @"
# $HookName - blocks prompts that contain forbidden words (UserPromptSubmit).
# Generated by Hook Maker. Edit the list freely; reinstall is not needed after edits.
`$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$forbidden = @($wordList)
`$prompt = ''
if (`$null -ne `$hookInput.PSObject.Properties['prompt']) { `$prompt = [string]`$hookInput.prompt }
elseif (`$null -ne `$hookInput.PSObject.Properties['user_prompt']) { `$prompt = [string]`$hookInput.user_prompt }
foreach (`$word in `$forbidden) {
    if (`$prompt -match [regex]::Escape(`$word)) {
        @{ decision = 'block'; reason = ('Prompt contains a forbidden word: ' + `$word) } | ConvertTo-Json -Compress
        exit 0
    }
}
exit 0
"@
}

function Get-HookBody-ToolLogger {
    param([string]$HookName)
    return @"
# $HookName - appends one line per tool call to a log file next to this hook.
# Generated by Hook Maker. Edit freely; reinstall is not needed after edits.
`$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$logFile = Join-Path (Split-Path -Parent `$MyInvocation.MyCommand.Path) '$HookName.log'
`$toolName = ''
if (`$null -ne `$hookInput.PSObject.Properties['tool_name']) { `$toolName = [string]`$hookInput.tool_name }
`$line = '[' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC] ' + `$hookInput.hook_event_name + ' ' + `$toolName + ' cwd=' + `$hookInput.cwd
[System.IO.File]::AppendAllText(`$logFile, `$line + "``r``n", [System.Text.UTF8Encoding]::new(`$false))
exit 0
"@
}

function Get-HookBody-Skeleton {
    param([string]$HookName)
    return @"
# $HookName - custom hook skeleton. Generated by Hook Maker.
# The client sends ONE JSON event on stdin. Common fields:
#   hook_event_name, session_id, cwd
# Event-specific fields:
#   UserPromptSubmit: prompt   |   PreToolUse/PostToolUse: tool_name, tool_input
`$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json

# TODO: your logic here.

# Stay silent:
exit 0

# Or inject context for the agent (SessionStart / UserPromptSubmit):
# @{ hookSpecificOutput = @{ hookEventName = `$hookInput.hook_event_name; additionalContext = 'note' } } |
#     ConvertTo-Json -Depth 5 -Compress
# exit 0
"@
}

function Get-HookBody-GitSync {
    param([string]$HookName)

    # Reuse the shipped GitSyncCheck hook verbatim (renamed) so the template
    # never drifts from the maintained implementation.
    $shipped = Join-Path $HooksDir 'GitSyncCheck\GitSyncCheck.ps1'
    $content = [System.IO.File]::ReadAllText($shipped)
    return $content.Replace('GitSyncCheck', $HookName).Replace("`r`n", "`n")
}

# The five guided templates. Details=$true means one question is asked.
$script:HookTemplates = @(
    [pscustomobject]@{ Key = '1'; Label = 'Context note'; Hint = 'injects a fixed note into every session/prompt'; Details = $true; DefaultEvents = @('SessionStart', 'UserPromptSubmit') }
    [pscustomobject]@{ Key = '2'; Label = 'Prompt guard'; Hint = 'blocks prompts containing forbidden words'; Details = $true; DefaultEvents = @('UserPromptSubmit') }
    [pscustomobject]@{ Key = '3'; Label = 'Tool logger'; Hint = 'logs every tool call to a file'; Details = $false; DefaultEvents = @('PreToolUse') }
    [pscustomobject]@{ Key = '4'; Label = 'Git sync check'; Hint = 'warns when the project is out of sync with its git remote'; Details = $false; DefaultEvents = @('SessionStart') }
    [pscustomobject]@{ Key = '5'; Label = 'Empty skeleton'; Hint = 'commented template for your own logic'; Details = $false; DefaultEvents = @('SessionStart', 'UserPromptSubmit') }
)

# Ask target projects, confirm, and install a hook into each. Returns 'done'
# (installed or user declined) or 'back' (user backed out at the first prompt).
function Invoke-CustomHookTargets {
    param(
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)]$Events
    )

    $hookName = Split-Path -Leaf $HookPath
    $stage = 0
    $clients = $null
    $targets = $null
    while ($true) {
        if ($stage -eq 0) {
            # Which client(s) gets this hook (Claude / Codex / both).
            $clients = Read-ClientChoice
            if ($null -eq $clients) {
                return 'back'
            }
            $stage = 1
            continue
        }
        if ($stage -eq 1) {
            $targets = Read-ProjectList -MinimumCount 1
            if ($null -eq $targets) {
                $stage = 0
                continue
            }
            $stage = 2
            continue
        }

        # stage 2: confirm
        Write-PhaseHeader 'Summary' $C.Summary '-'
        Write-Field 'hook script' $HookPath $C.LightBlue
        Write-Field 'events' (@($Events) -join ', ')
        Write-Field 'client' $clients
        Write-Field 'install' (Get-ClientInstallLabel $clients)
        Write-MenuTitle 'Target projects:'
        for ($i = 0; $i -lt $targets.Count; $i++) {
            Write-MenuLine ($i + 1) $targets[$i].Name $targets[$i].Root
        }
        Write-PhaseHeader 'Confirm' $C.Confirm '-'
        $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start custom hook install'
        if ($null -eq $confirm) {
            $stage = 1
            continue
        }
        if ($confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was installed.'
            Write-Log 'INFO' 'CUSTOM' 'User declined at confirmation; no install.'
            return 'done'
        }

        Write-PhaseHeader 'Applying Changes' $C.Process '-'
        $clientArgs = @(Get-ClientInstallArgs $clients)
        foreach ($target in $targets) {
            $installOutput = & $InstallScript -CustomHook $HookPath -Events @($Events) -TargetProject $target.Root @clientArgs *>&1
            foreach ($line in @($installOutput)) {
                Write-Log 'INFO' 'INSTALL' ([string]$line)
            }
            Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted $target.Root $C.Gray))
        }
        Write-PhaseHeader 'Completed' $C.Done '='
        Write-Host (Get-Painted ('  ' + $hookName + ' installed for: ' + (@($Events) -join ', ')) $C.White)
        Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
        Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
        Write-Log 'INFO' 'DONE' ('Custom hook installed: ' + $HookPath + ' | events=' + (@($Events) -join ',') + ' | clients=' + $clients + ' | projects=' + $targets.Count)
        return 'done'
    }
}

# Guided hook creation as a stage machine. Back (0) steps ONE stage back; back
# at the first stage returns 'back' so the caller redisplays its menu.
function Invoke-CreateHook {
    Write-Log 'INFO' 'CUSTOM' 'Guided hook creation started.'
    Write-PhaseHeader 'Create a New Hook' $C.Input '-'

    $hookName = ''
    $template = $null
    $details = ''
    $stage = 0

    while ($true) {
        switch ($stage) {
            0 {
                # Hook name
                $namePrompt = New-QuestionPrompt 'Hook name' ('letters, digits and dashes; example: ' + (Get-ExampleText 'MyContextHook')) $null
                $value = Read-Answer $namePrompt 'new hook name'
                if ($value -eq '0') {
                    return 'back'
                }
                if ($value -notmatch '^[A-Za-z][A-Za-z0-9-]*$') {
                    Write-ErrorLine 'Use only letters, digits and dashes, starting with a letter.'
                    break
                }
                if (Test-Path -LiteralPath (Join-Path $HooksDir $value)) {
                    Write-ErrorLine ('A hook with this name already exists: ' + (Join-Path $HooksDir $value))
                    break
                }
                $hookName = $value
                $stage = 1
            }
            1 {
                # Template
                Write-MenuTitle 'Template:'
                foreach ($t in $script:HookTemplates) {
                    Write-MenuLine ([int]$t.Key) $t.Label ('(' + $t.Hint + ')')
                }
                $value = Read-Answer (New-QuestionPrompt 'Select a template' $null '1') 'hook template'
                if ($value -eq '0') {
                    $stage = 0
                    break
                }
                if ($value -eq '') {
                    $value = '1'
                }
                $picked = $script:HookTemplates | Where-Object { $_.Key -eq $value }
                if ($null -eq $picked) {
                    Write-ErrorLine 'Enter 1, 2, 3, 4 or 5.'
                    break
                }
                $template = $picked
                $details = ''
                if ($template.Details) {
                    $stage = 2
                }
                else {
                    $stage = 3
                }
            }
            2 {
                # Template-specific question (only for Details templates)
                if ($template.Key -eq '1') {
                    $value = Read-Answer (New-QuestionPrompt 'Context note text' ('shown to the agent on every matched event; example: ' + (Get-ExampleText 'Always answer in Persian.')) $null) 'context note text'
                    if ($value -eq '0') {
                        $stage = 1
                        break
                    }
                    if ($value -eq '') {
                        Write-ErrorLine 'This value cannot be empty. Try again.'
                        break
                    }
                    $details = $value
                    $stage = 3
                }
                elseif ($template.Key -eq '2') {
                    $value = Read-Answer (New-QuestionPrompt 'Forbidden words' ('comma separated; example: ' + (Get-ExampleText 'password,api key')) $null) 'forbidden words'
                    if ($value -eq '0') {
                        $stage = 1
                        break
                    }
                    $words = @($value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                    if ($words.Count -eq 0) {
                        Write-ErrorLine 'Enter at least one word.'
                        break
                    }
                    $details = $words -join ','
                    $stage = 3
                }
                else {
                    $stage = 3
                }
            }
            3 {
                # Build + write the hook folder (script + .env.example), then
                # ask whether to install now.
                $hookFolder = Join-Path $HooksDir $hookName
                $hookPath = Join-Path $hookFolder ($hookName + '.ps1')
                switch ($template.Key) {
                    '1' { $body = Get-HookBody-ContextNote -HookName $hookName -Message $details }
                    '2' { $body = Get-HookBody-PromptGuard -HookName $hookName -Words @($details.Split(',')) }
                    '3' { $body = Get-HookBody-ToolLogger -HookName $hookName }
                    '4' { $body = Get-HookBody-GitSync -HookName $hookName }
                    '5' { $body = Get-HookBody-Skeleton -HookName $hookName }
                }
                New-Item -ItemType Directory -Path $hookFolder -Force | Out-Null
                [System.IO.File]::WriteAllText($hookPath, $body.Replace("`n", "`r`n"), $Utf8NoBom)
                $envExample = '# ' + $hookName + " configuration.`n" +
                    "# Copy this file to `".env`" (same folder) and edit. `".env`" is git-ignored.`n`n" +
                    "# Events to register on (comma separated).`n" +
                    'EVENTS=' + ($template.DefaultEvents -join ',') + "`n`n" +
                    "# Project roots for config-based install from the Hook Maker menu (semicolon separated).`n" +
                    "TARGET_PROJECTS=`n`n" +
                    "# Which client(s) to install for from the Hook Maker menu: Both, Claude, or Codex.`n" +
                    "CLIENTS=Both`n"
                [System.IO.File]::WriteAllText((Join-Path $hookFolder '.env.example'), $envExample.Replace("`n", "`r`n"), $Utf8NoBom)
                Write-Host ('  ' + (Get-Painted '+ created' $C.Green) + ' ' + (Get-Painted $hookPath $C.LightBlue))
                Write-Host ('  ' + (Get-Painted '+ created' $C.Green) + ' ' + (Get-Painted (Join-Path $hookFolder '.env.example') $C.LightBlue))
                Write-Field 'template' $template.Label
                Write-Field 'default events' ($template.DefaultEvents -join ', ')
                Write-Log 'INFO' 'CUSTOM' ('Hook created: ' + $hookPath + ' | template=' + $template.Key)

                $install = Read-YesNo (New-QuestionPrompt 'Install it into projects now?' 'y/n' 'y') $true 'install created hook'
                if ($null -eq $install) {
                    if ($template.Details) { $stage = 2 } else { $stage = 1 }
                    break
                }
                if ($install -ne $true) {
                    Write-NoteLine ('Saved in hooks\. Install later via menu option 2 -> install an existing hook.')
                    return 'done'
                }
                $result = Invoke-CustomHookTargets -HookPath $hookPath -Events $template.DefaultEvents
                if ($result -eq 'back') {
                    break   # re-show the install question
                }
                return 'done'
            }
        }
    }
}

# Install an existing hook (one folder per hook) as a stage machine.
function Invoke-InstallExistingHook {
    Write-Log 'INFO' 'CUSTOM' 'Custom hook install started.'
    Write-PhaseHeader 'Install an Existing Hook' $C.Input '-'

    $hookFiles = @(Get-HookEntries)
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hooks found in: ' + $HooksDir)
        Write-NoteLine 'Create one first (menu option 2 -> create a new hook).'
        return 'back'
    }

    $knownEvents = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop', 'PreCompact', 'SessionEnd', 'Notification', 'PermissionRequest', 'PostCompact', 'SubagentStart')
    $selectedHook = $null
    $events = $null
    $stage = 0

    while ($true) {
        switch ($stage) {
            0 {
                # Select hook
                Write-MenuTitle 'Available hooks (hooks\):'
                for ($i = 0; $i -lt $hookFiles.Count; $i++) {
                    $suffix = ''
                    if ($hookFiles[$i].Name -eq 'CrossProjectSyncHook') {
                        $suffix = '(sync engine - normally configured via option 1)'
                    }
                    Write-MenuLine ($i + 1) $hookFiles[$i].Name $suffix
                }
                $value = Read-Answer (New-QuestionPrompt 'Select a hook' $null '1') 'select custom hook'
                if ($value -eq '0') {
                    return 'back'
                }
                if ($value -eq '') {
                    $value = '1'
                }
                $index = 0
                if ([int]::TryParse($value, [ref]$index) -and $index -ge 1 -and $index -le $hookFiles.Count) {
                    $selectedHook = $hookFiles[$index - 1]
                    $stage = 1
                }
                else {
                    Write-ErrorLine ('Enter a number between 1 and ' + $hookFiles.Count + '.')
                }
            }
            1 {
                # Select events
                Write-MenuTitle 'Events:'
                Write-MenuLine 1 'SessionStart + UserPromptSubmit' '(context hooks - recommended)'
                Write-MenuLine 2 'SessionStart'
                Write-MenuLine 3 'UserPromptSubmit'
                Write-MenuLine 4 'Custom list' '(e.g. PreToolUse,PostToolUse,Stop)'
                $value = Read-Answer (New-QuestionPrompt 'Select events' $null '1') 'select events'
                if ($value -eq '0') {
                    $stage = 0
                    break
                }
                if ($value -eq '') {
                    $value = '1'
                }
                switch ($value) {
                    '1' { $events = @('SessionStart', 'UserPromptSubmit'); $stage = 2 }
                    '2' { $events = @('SessionStart'); $stage = 2 }
                    '3' { $events = @('UserPromptSubmit'); $stage = 2 }
                    '4' {
                        $raw = Read-Answer (New-QuestionPrompt 'Event names' ('comma separated; example: ' + (Get-ExampleText 'PreToolUse,PostToolUse')) $null) 'custom event list'
                        if ($raw -eq '0') {
                            break
                        }
                        $candidates = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                        if ($candidates.Count -eq 0) {
                            Write-ErrorLine 'Enter at least one event name.'
                            break
                        }
                        $invalid = @($candidates | Where-Object { $_ -notmatch '^[A-Za-z]+$' })
                        if ($invalid.Count -gt 0) {
                            Write-ErrorLine ('Invalid event name(s): ' + ($invalid -join ', '))
                            break
                        }
                        $unknown = @($candidates | Where-Object { $knownEvents -notcontains $_ })
                        if ($unknown.Count -gt 0) {
                            Write-NoteLine ('Not a known event (installing anyway): ' + ($unknown -join ', '))
                        }
                        $events = $candidates
                        $stage = 2
                    }
                    default { Write-ErrorLine 'Enter 1, 2, 3 or 4.' }
                }
            }
            2 {
                # Targets + confirm + install
                $result = Invoke-CustomHookTargets -HookPath $selectedHook.ScriptPath -Events $events
                if ($result -eq 'back') {
                    $stage = 1
                    break
                }
                return 'done'
            }
        }
    }
}

# Install an existing hook using its .env (EVENTS + TARGET_PROJECTS): no
# questions besides the hook selection and one confirm.
function Invoke-InstallHookFromConfig {
    Write-Log 'INFO' 'CUSTOM' 'Config-based hook install started.'
    Write-PhaseHeader 'Install From Config (.env)' $C.Input '-'

    $hookFiles = @(Get-HookEntries | Where-Object { $_.EnvPath -ne '' })
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hooks found in: ' + $HooksDir)
        return 'back'
    }

    while ($true) {
        Write-MenuTitle 'Available hooks (hooks\):'
        for ($i = 0; $i -lt $hookFiles.Count; $i++) {
            $suffix = '(no .env yet)'
            if (Test-Path -LiteralPath $hookFiles[$i].EnvPath -PathType Leaf) {
                $suffix = '(.env found)'
            }
            Write-MenuLine ($i + 1) $hookFiles[$i].Name $suffix
        }
        $value = Read-Answer (New-QuestionPrompt 'Select a hook' $null '1') 'select hook for config install'
        if ($value -eq '0') {
            return 'back'
        }
        if ($value -eq '') {
            $value = '1'
        }
        $index = 0
        if (-not ([int]::TryParse($value, [ref]$index) -and $index -ge 1 -and $index -le $hookFiles.Count)) {
            Write-ErrorLine ('Enter a number between 1 and ' + $hookFiles.Count + '.')
            continue
        }
        $hook = $hookFiles[$index - 1]

        if (-not (Test-Path -LiteralPath $hook.EnvPath -PathType Leaf)) {
            Write-ErrorLine ('No .env found for ' + $hook.Name + '.')
            Write-NoteLine ('Copy ' + (Join-Path (Split-Path -Parent $hook.EnvPath) '.env.example') + ' to .env and fill TARGET_PROJECTS.')
            continue
        }
        $envValues = Read-EnvFile $hook.EnvPath

        $events = @('SessionStart', 'UserPromptSubmit')
        if ($envValues.ContainsKey('EVENTS') -and $envValues['EVENTS'] -ne '') {
            $events = @($envValues['EVENTS'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
        $clients = 'Both'
        if ($envValues.ContainsKey('CLIENTS') -and $envValues['CLIENTS'] -ne '') {
            switch ($envValues['CLIENTS'].Trim().ToLowerInvariant()) {
                'claude' { $clients = 'Claude' }
                'codex' { $clients = 'Codex' }
                'both' { $clients = 'Both' }
                default { Write-NoteLine ('Unknown CLIENTS value "' + $envValues['CLIENTS'] + '" - installing for both.') }
            }
        }
        $targetsRaw = ''
        if ($envValues.ContainsKey('TARGET_PROJECTS')) {
            $targetsRaw = $envValues['TARGET_PROJECTS']
        }
        $targetPaths = @($targetsRaw.Split(';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
        if ($targetPaths.Count -eq 0) {
            Write-ErrorLine ('TARGET_PROJECTS is empty in ' + $hook.EnvPath + '.')
            Write-NoteLine 'Fill it with semicolon-separated project roots and retry.'
            continue
        }
        $targets = New-Object System.Collections.Generic.List[object]
        $invalid = $false
        foreach ($path in $targetPaths) {
            try {
                $root = Normalize-Path $path
            }
            catch {
                Write-ErrorLine ('Invalid path in TARGET_PROJECTS: ' + $path)
                $invalid = $true
                break
            }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-ErrorLine ('Directory not found (from TARGET_PROJECTS): ' + $root)
                $invalid = $true
                break
            }
            [void]$targets.Add([pscustomobject]@{ Name = (Split-Path -Leaf $root); Root = $root })
        }
        if ($invalid) {
            continue
        }

        # ---- summary + confirm ----
        Write-PhaseHeader 'Summary' $C.Summary '-'
        Write-Field 'hook script' $hook.ScriptPath $C.LightBlue
        Write-Field 'config' $hook.EnvPath $C.LightBlue
        Write-Field 'events' ($events -join ', ')
        Write-Field 'client' $clients
        Write-Field 'install' (Get-ClientInstallLabel $clients)
        Write-MenuTitle 'Target projects (from .env):'
        for ($i = 0; $i -lt $targets.Count; $i++) {
            Write-MenuLine ($i + 1) $targets[$i].Name $targets[$i].Root
        }
        Write-PhaseHeader 'Confirm' $C.Confirm '-'
        $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start config install'
        if ($null -eq $confirm) {
            continue
        }
        if ($confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was installed.'
            return 'done'
        }

        Write-PhaseHeader 'Applying Changes' $C.Process '-'
        $clientArgs = @(Get-ClientInstallArgs $clients)
        foreach ($target in $targets) {
            $installOutput = & $InstallScript -CustomHook $hook.ScriptPath -Events @($events) -TargetProject $target.Root @clientArgs *>&1
            foreach ($line in @($installOutput)) {
                Write-Log 'INFO' 'INSTALL' ([string]$line)
            }
            Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted $target.Root $C.Gray))
        }
        Write-PhaseHeader 'Completed' $C.Done '='
        Write-Host (Get-Painted ('  ' + $hook.Name + ' installed for: ' + ($events -join ', ') + ' (' + $clients + ')') $C.White)
        Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
        Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
        Write-Log 'INFO' 'DONE' ('Config install: ' + $hook.ScriptPath + ' | events=' + ($events -join ',') + ' | clients=' + $clients + ' | projects=' + $targets.Count)
        return 'done'
    }
}

# Sub-menu for option 2: create a new hook or install an existing one.
# Loops so that backing out of a sub-flow returns HERE (one step), not to the
# main menu. Returns 'done' after a completed sub-flow, or when the user backs
# out of this sub-menu.
function Invoke-CustomHookMenu {
    while ($true) {
        Write-PhaseHeader 'Custom Hooks' $C.Input '-'
        Write-MenuTitle 'Custom hooks:'
        Write-MenuLine 1 'Create a new hook' '(guided templates)'
        Write-MenuLine 2 'Install an existing hook' '(interactive questions)'
        Write-MenuLine 3 'Install from config' '(reads the hook''s .env - no questions)'
        $value = Read-Answer (New-QuestionPrompt 'Select an option' $null '1') 'custom hook menu'
        if ($value -eq '0') {
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        switch ($value) {
            '1' { if ((Invoke-CreateHook) -eq 'done') { return } }
            '2' { if ((Invoke-InstallExistingHook) -eq 'done') { return } }
            '3' { if ((Invoke-InstallHookFromConfig) -eq 'done') { return } }
            default { Write-ErrorLine 'Enter 1, 2, 3 or 0.' }
        }
    }
}

# ------------------------------------------------------- info flows (3/4) ----
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
                if ($null -ne $route.source.PSObject.Properties['name']) { $sourceName = [string]$route.source.name } else { $sourceName = [string]$route.source.root }
            }
            if ($null -ne $route.PSObject.Properties['destination'] -and $null -ne $route.destination) {
                if ($null -ne $route.destination.PSObject.Properties['name']) { $destinationName = [string]$route.destination.name } else { $destinationName = [string]$route.destination.root }
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
    Write-MenuLine 1 'Create or update a sync group'
    Write-MenuLine 2 'Create or install a custom hook' '(hooks\ folder)'
    Write-MenuLine 3 'Show configured profiles'
    Write-MenuLine 4 'Validate configuration'
}

# ----------------------------------------------------------------- entry ----
Initialize-Log
Write-Log 'INFO' 'STARTUP' ('Execution id: ' + [guid]::NewGuid().ToString())
Write-Log 'INFO' 'STARTUP' ('Script: ' + $PSCommandPath)
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
            switch ($choice) {
                '1' { Invoke-CreateGroup; continue menu }
                '2' { Invoke-CustomHookMenu; continue menu }
                '3' { Show-Profiles; continue menu }
                '4' { Invoke-Validate; continue menu }
                '0' { break menu }
                default { Write-ErrorLine 'Enter 1, 2, 3, 4 or 0.' }
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
