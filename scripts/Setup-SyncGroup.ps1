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

# "{back=0, quit=exit}" suffix with FFmWiz's per-part colors.
function Get-BackText {
    param([string]$Spec = 'back=0, quit=exit')

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($part in $Spec.Split(',')) {
        $part = $part.Trim()
        if ($part -match 'back') {
            [void]$parts.Add((Get-Painted $part $C.BackPrompt))
        }
        elseif ($part -match 'exit|quit') {
            [void]$parts.Add((Get-Painted $part $C.ExitPrompt))
        }
        else {
            [void]$parts.Add((Get-Painted $part $C.White))
        }
    }
    return (Get-Painted '{' $C.White) + ($parts.ToArray() -join (Get-Painted ', ' $C.White)) + (Get-Painted '}' $C.White)
}

# Question prompt: "\nN. Title (hint) [default] {back=0, quit=exit}: " (FFmWiz question_prompt).
$script:QuestionNumber = 0
function New-QuestionPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Details,
        [string]$Default,
        [string]$Back = 'back=0, quit=exit'
    )

    $script:QuestionNumber++
    $prompt = "`n" + (Get-Painted ($script:QuestionNumber.ToString() + '. ' + $Title) $C.Bold)
    if (-not [string]::IsNullOrEmpty($Details)) {
        $prompt += ' (' + (Get-Painted $Details $C.HintYellow) + ')'
    }
    if (-not [string]::IsNullOrEmpty($Default)) {
        $prompt += ' ' + (Get-Painted ('[' + $Default + ']') $C.Green)
    }
    if (-not [string]::IsNullOrEmpty($Back)) {
        $prompt += ' ' + (Get-BackText $Back)
    }
    return $prompt + ': '
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

function Get-StringHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-Slug {
    param([Parameter(Mandatory = $true)][string]$Name)

    $slug = [System.Text.RegularExpressions.Regex]::Replace($Name.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'project'
    }
    return $slug
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = $Path + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($temporaryPath, $json, $Utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
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
    $profileId = 'sync-group-' + (Get-StringHash -Text $canonical).Substring(0, 10)

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

    $projects = Read-ProjectList -MinimumCount 2 -ShowAiNote
    if ($null -eq $projects) {
        Write-NoteLine 'Returning to main menu.'
        return
    }

    $groupProfile = New-GroupProfile -Projects $projects
    $routeCount = @($groupProfile.routes).Count

    $events = @('SessionStart', 'UserPromptSubmit')
    if ($null -ne $config.PSObject.Properties['defaults'] -and $null -ne $config.defaults -and
        $null -ne $config.defaults.PSObject.Properties['events'] -and $null -ne $config.defaults.events) {
        $events = @($config.defaults.events)
    }

    # ---- summary ----
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
        Write-Field 'hook install' 'per project: .claude\settings.local.json + .codex\hooks.json'
    }
    Write-Host ''
    Write-Host (Get-Painted '  Routes:' $C.Gray)
    foreach ($route in @($groupProfile.routes)) {
        Write-Host ('    ' + (Get-Painted ($route.source.name + ' -> ' + $route.destination.name) $C.Dim))
    }

    # ---- confirm ----
    Write-PhaseHeader 'Confirm' $C.Confirm '-'
    $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start sync group'
    if ($confirm -ne $true) {
        Write-NoteLine 'Canceled. Nothing was changed.'
        Write-Log 'INFO' 'GROUP' 'User declined at confirmation; no changes applied.'
        return
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
        foreach ($project in $projects) {
            $installOutput = & $InstallScript -Profile $groupProfile.id -ConfigPath $ConfigPath -TargetProject $project.Root *>&1
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
# Shared tail of both custom-hook paths: ask target projects, confirm, install.
function Invoke-InstallHookTargets {
    param(
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)]$Events
    )

    $hookName = Split-Path -Leaf $HookPath

    $targets = Read-ProjectList -MinimumCount 1
    if ($null -eq $targets) {
        Write-NoteLine 'Returning to main menu.'
        return
    }

    # ---- summary ----
    Write-PhaseHeader 'Summary' $C.Summary '-'
    Write-Field 'hook script' $HookPath $C.LightBlue
    Write-Field 'events' (@($Events) -join ', ')
    Write-Field 'install' 'per project: .claude\settings.local.json + .codex\hooks.json'
    Write-MenuTitle 'Target projects:'
    for ($i = 0; $i -lt $targets.Count; $i++) {
        Write-MenuLine ($i + 1) $targets[$i].Name $targets[$i].Root
    }

    # ---- confirm ----
    Write-PhaseHeader 'Confirm' $C.Confirm '-'
    $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start custom hook install'
    if ($confirm -ne $true) {
        Write-NoteLine 'Canceled. Nothing was changed.'
        Write-Log 'INFO' 'CUSTOM' 'User declined at confirmation; no changes applied.'
        return
    }

    # ---- apply ----
    Write-PhaseHeader 'Applying Changes' $C.Process '-'
    foreach ($target in $targets) {
        $installOutput = & $InstallScript -CustomHook $HookPath -Events @($Events) -TargetProject $target.Root *>&1
        foreach ($line in @($installOutput)) {
            Write-Log 'INFO' 'INSTALL' ([string]$line)
        }
        Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted $target.Root $C.Gray))
    }

    Write-PhaseHeader 'Completed' $C.Done '='
    Write-Host (Get-Painted ('  ' + $hookName + ' installed for: ' + (@($Events) -join ', ')) $C.White)
    Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
    Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
    if ($null -ne $script:LogPath) {
        Write-Host (Get-Painted ('  Log: ' + $script:LogPath) $C.Dim)
    }
    Write-Log 'INFO' 'DONE' ('Custom hook installed: ' + $HookPath + ' | events=' + (@($Events) -join ',') + ' | projects=' + $targets.Count)
}

# Guided hook creation: pick a template, answer one or two questions, get a
# working .ps1 in hooks\ (optionally installed right away).
function Invoke-CreateHook {
    Write-Log 'INFO' 'CUSTOM' 'Guided hook creation started.'
    Write-PhaseHeader 'Create a New Hook' $C.Input '-'

    $nameExample = Get-ExampleText 'MyContextHook'
    $namePrompt = New-QuestionPrompt 'Hook name' ('letters, digits and dashes; example: ' + $nameExample) $null
    $hookName = $null
    while ($null -eq $hookName) {
        $value = Read-Answer $namePrompt 'new hook name'
        if ($value -eq '0') {
            Write-NoteLine 'Returning to main menu.'
            return
        }
        if ($value -notmatch '^[A-Za-z][A-Za-z0-9-]*$') {
            Write-ErrorLine 'Use only letters, digits and dashes, starting with a letter.'
            continue
        }
        $candidatePath = Join-Path $HooksDir ($value + '.ps1')
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            Write-ErrorLine ('A hook with this name already exists: ' + $candidatePath)
            continue
        }
        $hookName = $value
    }
    $hookPath = Join-Path $HooksDir ($hookName + '.ps1')

    Write-MenuTitle 'Template:'
    Write-MenuLine 1 'Context note' '(injects a fixed note into every session/prompt)'
    Write-MenuLine 2 'Prompt guard' '(blocks prompts containing forbidden words)'
    Write-MenuLine 3 'Tool logger' '(logs every tool call to a file)'
    Write-MenuLine 4 'Empty skeleton' '(commented template for your own logic)'

    $templatePrompt = New-QuestionPrompt 'Select a template' $null '1'
    $template = $null
    while ($null -eq $template) {
        $value = Read-Answer $templatePrompt 'hook template'
        if ($value -eq '0') {
            Write-NoteLine 'Returning to main menu.'
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        if ($value -match '^[1-4]$') {
            $template = $value
        }
        else {
            Write-ErrorLine 'Enter 1, 2, 3 or 4.'
        }
    }

    $defaultEvents = @('SessionStart', 'UserPromptSubmit')
    $body = ''
    switch ($template) {
        '1' {
            $messagePrompt = New-QuestionPrompt 'Context note text' ('shown to the agent on every matched event; example: ' + (Get-ExampleText 'Always answer in Persian.')) $null
            $message = ''
            while ($message -eq '') {
                $message = Read-Answer $messagePrompt 'context note text'
                if ($message -eq '0') {
                    Write-NoteLine 'Returning to main menu.'
                    return
                }
                if ($message -eq '') {
                    Write-ErrorLine 'This value cannot be empty. Try again.'
                }
            }
            $escaped = $message.Replace("'", "''")
            $body = @"
# $hookName - injects a fixed context note into every matched event.
# Generated by Hook Maker. Edit freely; reinstall is not needed after edits.
`$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$note = '$escaped'
@{ hookSpecificOutput = @{ hookEventName = `$hookInput.hook_event_name; additionalContext = `$note } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
"@
        }
        '2' {
            $defaultEvents = @('UserPromptSubmit')
            $wordsPrompt = New-QuestionPrompt 'Forbidden words' ('comma separated; example: ' + (Get-ExampleText 'password,api key')) $null
            $words = @()
            while ($words.Count -eq 0) {
                $raw = Read-Answer $wordsPrompt 'forbidden words'
                if ($raw -eq '0') {
                    Write-NoteLine 'Returning to main menu.'
                    return
                }
                $words = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                if ($words.Count -eq 0) {
                    Write-ErrorLine 'Enter at least one word.'
                }
            }
            $wordList = (@($words | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })) -join ', '
            $body = @"
# $hookName - blocks prompts that contain forbidden words (UserPromptSubmit).
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
        '3' {
            $defaultEvents = @('PreToolUse')
            $body = @"
# $hookName - appends one line per tool call to a log file next to this hook.
# Generated by Hook Maker. Edit freely; reinstall is not needed after edits.
`$hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$logFile = Join-Path (Split-Path -Parent `$MyInvocation.MyCommand.Path) '$hookName.log'
`$toolName = ''
if (`$null -ne `$hookInput.PSObject.Properties['tool_name']) { `$toolName = [string]`$hookInput.tool_name }
`$line = '[' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC] ' + `$hookInput.hook_event_name + ' ' + `$toolName + ' cwd=' + `$hookInput.cwd
[System.IO.File]::AppendAllText(`$logFile, `$line + "``r``n", [System.Text.UTF8Encoding]::new(`$false))
exit 0
"@
        }
        '4' {
            $body = @"
# $hookName - custom hook skeleton. Generated by Hook Maker.
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
    }

    [System.IO.File]::WriteAllText($hookPath, $body.Replace("`n", "`r`n"), $Utf8NoBom)
    Write-Host ('  ' + (Get-Painted '+ created' $C.Green) + ' ' + (Get-Painted $hookPath $C.LightBlue))
    Write-Field 'default events' ($defaultEvents -join ', ')
    Write-Log 'INFO' 'CUSTOM' ('Hook created: ' + $hookPath + ' | template=' + $template)

    $install = Read-YesNo (New-QuestionPrompt 'Install it into projects now?' 'y/n' 'y') $true 'install created hook'
    if ($install -ne $true) {
        Write-NoteLine ('Skipped. Install later via menu option 2 -> install existing hook.')
        return
    }
    Invoke-InstallHookTargets -HookPath $hookPath -Events $defaultEvents
}

function Invoke-InstallExistingHook {
    Write-Log 'INFO' 'CUSTOM' 'Custom hook install started.'
    Write-PhaseHeader 'Install Custom Hook' $C.Input '-'

    $hookFiles = @(Get-ChildItem -LiteralPath $HooksDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hook scripts found in: ' + $HooksDir)
        Write-NoteLine 'Create one first (menu option 2 -> create a new hook).'
        return
    }

    Write-MenuTitle 'Available hooks (hooks\):'
    for ($i = 0; $i -lt $hookFiles.Count; $i++) {
        $suffix = ''
        if ($hookFiles[$i].Name -eq 'CrossProjectSyncHook.ps1') {
            $suffix = '(sync engine - normally configured via option 1)'
        }
        Write-MenuLine ($i + 1) $hookFiles[$i].Name $suffix
    }

    $hookPrompt = New-QuestionPrompt 'Select a hook' $null '1'
    $selectedHook = $null
    while ($true) {
        $value = Read-Answer $hookPrompt 'select custom hook'
        if ($value -eq '0') {
            Write-NoteLine 'Returning to main menu.'
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        $index = 0
        if ([int]::TryParse($value, [ref]$index) -and $index -ge 1 -and $index -le $hookFiles.Count) {
            $selectedHook = $hookFiles[$index - 1]
            break
        }
        Write-ErrorLine ('Enter a number between 1 and ' + $hookFiles.Count + '.')
    }

    Write-MenuTitle 'Events:'
    Write-MenuLine 1 'SessionStart + UserPromptSubmit' '(context hooks - recommended)'
    Write-MenuLine 2 'SessionStart'
    Write-MenuLine 3 'UserPromptSubmit'
    Write-MenuLine 4 'Custom list' '(e.g. PreToolUse,PostToolUse,Stop)'

    $eventsPrompt = New-QuestionPrompt 'Select events' $null '1'
    $knownEvents = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop', 'PreCompact', 'SessionEnd', 'Notification', 'PermissionRequest', 'PostCompact', 'SubagentStart')
    $events = $null
    while ($null -eq $events) {
        $value = Read-Answer $eventsPrompt 'select events'
        if ($value -eq '0') {
            Write-NoteLine 'Returning to main menu.'
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        switch ($value) {
            '1' { $events = @('SessionStart', 'UserPromptSubmit') }
            '2' { $events = @('SessionStart') }
            '3' { $events = @('UserPromptSubmit') }
            '4' {
                $example = Get-ExampleText 'PreToolUse,PostToolUse'
                $listPrompt = New-QuestionPrompt 'Event names' ('comma separated; example: ' + $example) $null
                while ($null -eq $events) {
                    $raw = Read-Answer $listPrompt 'custom event list'
                    if ($raw -eq '0') {
                        Write-NoteLine 'Returning to main menu.'
                        return
                    }
                    $candidates = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                    if ($candidates.Count -eq 0) {
                        Write-ErrorLine 'Enter at least one event name.'
                        continue
                    }
                    $invalid = @($candidates | Where-Object { $_ -notmatch '^[A-Za-z]+$' })
                    if ($invalid.Count -gt 0) {
                        Write-ErrorLine ('Invalid event name(s): ' + ($invalid -join ', '))
                        continue
                    }
                    $unknown = @($candidates | Where-Object { $knownEvents -notcontains $_ })
                    if ($unknown.Count -gt 0) {
                        Write-NoteLine ('Not a known event (installing anyway): ' + ($unknown -join ', '))
                    }
                    $events = $candidates
                }
            }
            default { Write-ErrorLine 'Enter 1, 2, 3 or 4.' }
        }
    }

    Invoke-InstallHookTargets -HookPath $selectedHook.FullName -Events $events
}

# Sub-menu for option 2: create a new hook or install an existing one.
function Invoke-CustomHookMenu {
    Write-PhaseHeader 'Custom Hooks' $C.Input '-'
    Write-MenuTitle 'Custom hooks:'
    Write-MenuLine 1 'Create a new hook' '(guided templates: context note, prompt guard, tool logger, skeleton)'
    Write-MenuLine 2 'Install an existing hook' '(any .ps1 already in hooks\)'

    $prompt = New-QuestionPrompt 'Select an option' $null '1'
    while ($true) {
        $value = Read-Answer $prompt 'custom hook menu'
        if ($value -eq '0') {
            Write-NoteLine 'Returning to main menu.'
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        switch ($value) {
            '1' { Invoke-CreateHook; return }
            '2' { Invoke-InstallExistingHook; return }
            default { Write-ErrorLine 'Enter 1, 2 or 0.' }
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

function Wait-MenuReturn {
    $null = Read-Answer ("`n" + (Get-Painted 'press Enter to return to the menu...' $C.Dim) + ' ') 'return to menu'
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
        $menuPrompt = New-QuestionPrompt 'Select an option' $null '1' 'quit=exit'
        while ($true) {
            $choice = Read-Answer $menuPrompt 'main menu'
            if ($choice -eq '') {
                $choice = '1'
            }
            switch ($choice) {
                '1' { Invoke-CreateGroup; Wait-MenuReturn; continue menu }
                '2' { Invoke-CustomHookMenu; Wait-MenuReturn; continue menu }
                '3' { Show-Profiles; Wait-MenuReturn; continue menu }
                '4' { Invoke-Validate; Wait-MenuReturn; continue menu }
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
