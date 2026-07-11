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
    Reset   = "$Esc[0m"
    Red     = "$Esc[91m"
    Green   = "$Esc[92m"
    Yellow  = "$Esc[93m"
    Dim     = "$Esc[38;5;250m"
    Gray    = "$Esc[38;5;252m"
    Title   = "$Esc[1m$Esc[38;2;255;50;115m"
    Input   = "$Esc[1m$Esc[38;2;68;221;255m"
    Summary = "$Esc[1m$Esc[38;2;170;255;82m"
    Confirm = "$Esc[1m$Esc[38;2;255;155;60m"
    Process = "$Esc[1m$Esc[38;2;80;255;205m"
    Done    = "$Esc[1m$Esc[38;2;145;255;95m"
    Label   = "$Esc[1m$Esc[38;2;110;210;255m"
    Value   = "$Esc[38;2;245;245;245m"
    Path    = "$Esc[38;2;70;255;210m"
    True    = "$Esc[1m$Esc[38;2;95;255;120m"
    False   = "$Esc[1m$Esc[38;2;255;95;95m"
    Key     = "$Esc[38;5;154m"
    Num     = "$Esc[38;5;209m"
    Aqua    = "$Esc[38;5;159m"
    Amber   = "$Esc[38;5;214m"
    Mint    = "$Esc[38;5;121m"
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

function Write-Setting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$ValueColor = ''
    )

    if ([string]::IsNullOrEmpty($ValueColor)) {
        $ValueColor = $C.Value
    }
    Write-Host ('  ' + $C.Label + $Name + ':' + $C.Reset + ' ' + $ValueColor + $Value + $C.Reset)
}

function Write-ErrorLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('  ' + $C.Red + 'x ' + $Message + $C.Reset)
}

function Write-WarnLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('  ' + $C.Yellow + '! ' + $Message + $C.Reset)
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
        Write-Host ($C.Yellow + 'Warning: file logging is unavailable: ' + $_.Exception.Message + $C.Reset)
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

# --------------------------------------------------------------- helpers ----
function Read-InputLine {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    Write-Host -NoNewline $Prompt
    $line = Read-Host
    if ($null -eq $line) {
        throw 'Input stream ended unexpectedly.'
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
        $script:EmptyReads++
        if ($script:EmptyReads -gt 200) {
            throw 'Too many consecutive empty inputs; aborting.'
        }
    }
    else {
        $script:EmptyReads = 0
    }
    return $line
}

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
    param([Parameter(Mandatory = $true)][string]$Text)

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
function Read-ProjectList {
    Write-PhaseHeader 'Add Projects' $C.Input '-'
    Write-Host ($C.Dim + '  Enter each project root path, one per line (at least 2 projects).' + $C.Reset)
    Write-Host ($C.Dim + '  Commands: ' + $C.Key + 'done' + $C.Dim + ' = finish   ' + $C.Key + 'undo' + $C.Dim + ' = remove last   ' + $C.Key + 'cancel' + $C.Dim + ' = back to menu' + $C.Reset)
    Write-Host ''

    $projects = New-Object System.Collections.Generic.List[object]
    while ($true) {
        $prompt = '  ' + $C.Num + '[' + ($projects.Count + 1) + ']' + $C.Reset + ' ' + $C.Aqua + 'project path>' + $C.Reset + ' '
        $raw = Read-InputLine $prompt
        $value = $raw.Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $lower = $value.ToLowerInvariant()

        if ($lower -eq 'cancel') {
            Write-Log 'INFO' 'INPUT' 'User canceled project entry.'
            return $null
        }
        if ($lower -eq 'undo') {
            if ($projects.Count -gt 0) {
                $removed = $projects[$projects.Count - 1]
                $projects.RemoveAt($projects.Count - 1)
                Write-Host ('  ' + $C.Dim + '- removed ' + $removed.Name + '  ' + $removed.Root + $C.Reset)
                Write-Log 'INFO' 'INPUT' ('Removed project: ' + $removed.Root)
            }
            else {
                Write-WarnLine 'Nothing to undo.'
            }
            continue
        }
        if ($lower -eq 'done') {
            if ($projects.Count -ge 2) {
                break
            }
            Write-ErrorLine ('At least 2 projects are required (currently ' + $projects.Count + ').')
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
            Write-WarnLine ('Already added: ' + $root)
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

        $aiNote = if ($entry.AiExists) { $C.Mint + ' (.ai exists)' } else { $C.Amber + ' (.ai will be created)' }
        Write-Host ('  ' + $C.Green + '+ added ' + $C.Reset + $C.Value + $entry.Name + $C.Reset + $C.Dim + '  ' + $entry.Root + $C.Reset + $aiNote + $C.Reset)
        Write-Log 'INFO' 'INPUT' ('Added project: ' + $root + ' | aiExists=' + $entry.AiExists)
    }

    # ToArray instead of @(): wrapping a generic List with @() fails on some
    # PowerShell hosts with "Argument types do not match".
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

# ------------------------------------------------------------- main flow ----
function Invoke-CreateGroup {
    Write-Log 'INFO' 'GROUP' 'Create/update sync group started.'

    $config = Read-JsonFile $ConfigPath
    if ($null -eq $config) {
        Write-ErrorLine ('Config file not found or empty: ' + $ConfigPath)
        Write-Log 'ERROR' 'CONFIG' ('Config missing or empty: ' + $ConfigPath)
        return
    }

    $projects = Read-ProjectList
    if ($null -eq $projects) {
        Write-Host ($C.Dim + '  Canceled.' + $C.Reset)
        return
    }

    $groupProfile = New-GroupProfile -Projects $projects
    $routeCount = @($groupProfile.routes).Count

    $events = @('SessionStart', 'UserPromptSubmit')
    if ($null -ne $config.PSObject.Properties['defaults'] -and $null -ne $config.defaults -and
        $null -ne $config.defaults.PSObject.Properties['events'] -and $null -ne $config.defaults.events) {
        $events = @($config.defaults.events)
    }
    $claudeSettings = Join-Path $HOME '.claude\settings.json'
    $codexHooks = Join-Path $HOME '.codex\hooks.json'

    # ---- summary ----
    Write-PhaseHeader 'Summary' $C.Summary '-'
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $project = $projects[$i]
        $aiNote = if ($project.AiExists) { $C.Mint + '.ai exists' } else { $C.Amber + '.ai will be created' }
        Write-Host ('  ' + $C.Num + '[' + ($i + 1) + ']' + $C.Reset + ' ' + $C.Value + $project.Name + $C.Reset + '  ' + $C.Path + $project.Root + $C.Reset + '  ' + $aiNote + $C.Reset)
    }
    Write-Host ''
    Write-Setting 'Profile id' $groupProfile.id $C.Aqua
    Write-Setting 'Profile name' $groupProfile.name
    Write-Setting 'Routes' ([string]$routeCount + ' (full mesh)')
    Write-Setting 'Events' ($events -join ', ')
    Write-Setting 'Config file' $ConfigPath $C.Path
    if ($NoInstall) {
        Write-Setting 'Hook install' 'skipped (-NoInstall)' $C.Amber
    }
    else {
        Write-Setting 'Hook install' 'Claude + Codex'
        Write-Setting 'Claude settings' $claudeSettings $C.Path
        Write-Setting 'Codex hooks' $codexHooks $C.Path
    }
    Write-Host ''
    Write-Host ($C.Dim + '  Routes:' + $C.Reset)
    foreach ($route in @($groupProfile.routes)) {
        Write-Host ('    ' + $C.Dim + $route.source.name + ' -> ' + $route.destination.name + $C.Reset)
    }

    # ---- confirm ----
    Write-PhaseHeader 'Confirm' $C.Confirm '-'
    $answer = (Read-InputLine ('  Start? [' + $C.Key + 'Y' + $C.Reset + '/n] ' + $C.Dim + '(Enter = Y)' + $C.Reset + ' > ')).Trim().ToLowerInvariant()
    if ($answer -ne '' -and $answer -ne 'y' -and $answer -ne 'yes') {
        Write-Host ($C.Dim + '  Canceled. Nothing was changed.' + $C.Reset)
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
            Write-Host ('  ' + $C.Green + '+ created ' + $C.Reset + $C.Path + $project.AiPath + $C.Reset)
            Write-Log 'INFO' 'CONFIG' ('Created knowledge directory: ' + $project.AiPath)
        }
        else {
            Write-Host ('  ' + $C.Dim + '= exists  ' + $project.AiPath + $C.Reset)
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
    $action = if ($replaced) { 'updated' } else { 'added' }
    Write-Host ('  ' + $C.Green + '+ profile ' + $action + ' ' + $C.Reset + $C.Aqua + $groupProfile.id + $C.Reset + $C.Dim + ' (' + $routeCount + ' routes)' + $C.Reset)
    Write-Log 'INFO' 'CONFIG' ('Profile ' + $action + ': ' + $groupProfile.id + ' | routes=' + $routeCount + ' | config=' + $ConfigPath)

    $validateOutput = & $ValidateScript -ConfigPath $ConfigPath *>&1
    foreach ($line in @($validateOutput)) {
        Write-Log 'DEBUG' 'VALIDATE' ([string]$line)
    }
    Write-Host ('  ' + $C.Green + '+ configuration validated' + $C.Reset)
    Write-Log 'INFO' 'VALIDATE' 'Configuration validated after write.'

    if ($NoInstall) {
        Write-Host ('  ' + $C.Amber + '! hook install skipped (-NoInstall)' + $C.Reset)
        Write-Log 'INFO' 'INSTALL' 'Hook install skipped by -NoInstall.'
    }
    else {
        $installOutput = & $InstallScript -Profile $groupProfile.id -ConfigPath $ConfigPath *>&1
        foreach ($line in @($installOutput)) {
            Write-Host ('    ' + $C.Dim + [string]$line + $C.Reset)
            Write-Log 'INFO' 'INSTALL' ([string]$line)
        }
        Write-Host ('  ' + $C.Green + '+ hook installed for profile ' + $C.Reset + $C.Aqua + $groupProfile.id + $C.Reset)
    }

    $stopwatch.Stop()
    Write-PhaseHeader 'Completed' $C.Done '='
    Write-Host ('  ' + $C.Value + 'Restart the Claude/Codex clients and review /hooks.' + $C.Reset)
    Write-Host ('  ' + $C.Value + 'Opening any of these projects now reviews the other projects'' knowledge first.' + $C.Reset)
    if ($null -ne $script:LogPath) {
        Write-Host ('  ' + $C.Dim + 'Log: ' + $script:LogPath + $C.Reset)
    }
    Write-Log 'INFO' 'DONE' ('Sync group applied: ' + $groupProfile.id + ' | durationMs=' + $stopwatch.ElapsedMilliseconds)
}

function Show-Profiles {
    Write-PhaseHeader 'Configured Profiles' $C.Input '-'
    $config = Read-JsonFile $ConfigPath
    if ($null -eq $config -or $null -eq $config.PSObject.Properties['profiles'] -or $null -eq $config.profiles -or @($config.profiles).Count -eq 0) {
        Write-Host ($C.Dim + '  No profiles configured.' + $C.Reset)
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
        $stateText = if ($enabled) { $C['True'] + 'enabled' } else { $C['False'] + 'disabled' }
        $routes = @()
        if ($null -ne $profileConfig.PSObject.Properties['routes'] -and $null -ne $profileConfig.routes) {
            $routes = @($profileConfig.routes)
        }
        Write-Host ('  ' + $C.Aqua + $id + $C.Reset + '  ' + $C.Gray + $name + $C.Reset + '  ' + $stateText + $C.Reset + $C.Dim + '  (' + $routes.Count + ' routes)' + $C.Reset)
        foreach ($route in $routes) {
            $sourceName = ''
            $destinationName = ''
            if ($null -ne $route.PSObject.Properties['source'] -and $null -ne $route.source) {
                $sourceName = if ($null -ne $route.source.PSObject.Properties['name']) { [string]$route.source.name } else { [string]$route.source.root }
            }
            if ($null -ne $route.PSObject.Properties['destination'] -and $null -ne $route.destination) {
                $destinationName = if ($null -ne $route.destination.PSObject.Properties['name']) { [string]$route.destination.name } else { [string]$route.destination.root }
            }
            Write-Host ('      ' + $C.Dim + $sourceName + ' -> ' + $destinationName + $C.Reset)
        }
    }
    Write-Log 'INFO' 'MENU' ('Listed profiles: ' + @($config.profiles).Count)
}

function Invoke-Validate {
    Write-PhaseHeader 'Validate Configuration' $C.Input '-'
    try {
        $output = & $ValidateScript -ConfigPath $ConfigPath *>&1
        foreach ($line in @($output)) {
            Write-Host ('  ' + $C.Green + [string]$line + $C.Reset)
            Write-Log 'DEBUG' 'VALIDATE' ([string]$line)
        }
        Write-Log 'INFO' 'VALIDATE' 'Configuration valid.'
    }
    catch {
        Write-ErrorLine ('Validation failed: ' + $_.Exception.Message)
        Write-Log 'ERROR' 'VALIDATE' ('Validation failed: ' + $_.Exception.Message)
    }
}

function Show-MainMenu {
    Write-PhaseHeader 'CROSS-PROJECT SYNC WIZARD' $C.Title '='
    Write-Host ($C.Dim + '  Keeps the .ai knowledge of multiple projects in sync via agent hooks.' + $C.Reset)
    Write-Host ''
    Write-Host ('  ' + $C.Num + '[1]' + $C.Reset + ' ' + $C.Value + 'Create or update a sync group' + $C.Reset)
    Write-Host ('  ' + $C.Num + '[2]' + $C.Reset + ' ' + $C.Value + 'Show configured profiles' + $C.Reset)
    Write-Host ('  ' + $C.Num + '[3]' + $C.Reset + ' ' + $C.Value + 'Validate configuration' + $C.Reset)
    Write-Host ('  ' + $C.Num + '[0]' + $C.Reset + ' ' + $C.Value + 'Exit' + $C.Reset)
    Write-Host ''
}

function Wait-MenuReturn {
    $null = Read-InputLine ($C.Dim + '  press Enter to return to the menu... ' + $C.Reset)
}

# ----------------------------------------------------------------- entry ----
Initialize-Log
Write-Log 'INFO' 'STARTUP' ('Execution id: ' + [guid]::NewGuid().ToString())
Write-Log 'INFO' 'STARTUP' ('Script: ' + $PSCommandPath)
Write-Log 'INFO' 'STARTUP' ('Config: ' + $ConfigPath)
Write-Log 'INFO' 'STARTUP' ('OS: ' + [Environment]::OSVersion.VersionString)
Write-Log 'INFO' 'STARTUP' ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
Write-Log 'INFO' 'STARTUP' ('NoInstall: ' + [bool]$NoInstall)

try {
    $redraw = $true
    :menu while ($true) {
        if ($redraw) {
            Show-MainMenu
            $redraw = $false
        }
        $choice = (Read-InputLine ('  ' + $C.Aqua + 'select>' + $C.Reset + ' ')).Trim()
        switch ($choice) {
            '1' { Invoke-CreateGroup; Wait-MenuReturn; $redraw = $true }
            '2' { Show-Profiles; Wait-MenuReturn; $redraw = $true }
            '3' { Invoke-Validate; Wait-MenuReturn; $redraw = $true }
            '0' { break menu }
            default {
                if ($choice -ne '') {
                    Write-WarnLine 'Enter 1, 2, 3 or 0.'
                }
            }
        }
    }
}
catch {
    Write-ErrorLine ('Fatal error: ' + $_.Exception.Message)
    Write-Host ($C.Dim + $_.ScriptStackTrace + $C.Reset)
    Write-Log 'CRITICAL' 'ERROR' ('Fatal: ' + $_.Exception.ToString() + ' | at: ' + $_.ScriptStackTrace)
    exit 1
}

Write-Log 'INFO' 'DONE' 'Wizard exited normally.'
exit 0
