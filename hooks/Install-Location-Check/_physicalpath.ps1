# Install-Location-Check: PHYSICAL PATH RESOLUTION AND BOUNDED QUERIES.
#
# Where an install target really lives. A C: path is not a C: install when a
# junction or symbolic link on it - or on ANY parent folder - leads to another
# drive (%LOCALAPPDATA%\Programs\Python here is a link to G:). So the path is
# walked from its root down, and each existing component that is a link
# re-roots the walk at its target with the rest of the path re-joined. A
# component that does not exist yet ends the walk: a target not created yet
# lives wherever its nearest existing ancestor lives.
#
# Only two kinds of process ever start here, both read-only and bounded:
# `npm config get prefix` and a `python -c` that prints a prefix. Nothing is
# installed, written, or evaluated from the command being inspected.
#
# Seams (tests replace them; production leaves them $null):
#   $script:InstallLocationSystemDrive - the drive that counts as the system drive
#   $script:InstallLocationResolver    - { param($Path) <physical path> }
#   $script:InstallLocationQuery       - { param($Kind, $Program, $Arguments) <line or $null> }

$script:InstallLocationSystemDrive = $null
$script:InstallLocationResolver = $null
$script:InstallLocationQuery = $null
$script:InstallLocationQueryTimeout = 5

function Get-InstallSystemDrive {
    $drive = $script:InstallLocationSystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = [string]$env:SystemDrive }
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    return $drive.TrimEnd('\').ToUpperInvariant()
}

# The next hop of ONE link, or $null when the path is not a symbolic link or a
# junction. Get-Item's LinkType/Target exist on Windows PowerShell 5.1 and on
# pwsh 7 alike, which [IO.Directory]::ResolveLinkTarget (.NET 6+) does not. A
# reparse point of another kind (a OneDrive placeholder, a dedup stub) is not a
# link and is not followed.
function Get-LinkTargetPath {
    param([string]$Path)
    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { return $null }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $linkType = [string]$item.LinkType
        if ($linkType -ne 'SymbolicLink' -and $linkType -ne 'Junction') { return $null }
        $target = [string](@($item.Target) | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($target)) { return $null }
        foreach ($prefix in @('\\?\', '\??\')) {
            if ($target.StartsWith($prefix)) { $target = $target.Substring($prefix.Length) }
        }
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Path) $target }
        return [System.IO.Path]::GetFullPath($target)
    }
    catch { return $null }
}

function Resolve-PhysicalPath {
    param([string]$Path)
    if ($null -ne $script:InstallLocationResolver) { return [string](& $script:InstallLocationResolver $Path) }
    try { $current = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)) }
    catch { return $Path }
    # 32 hops: a link chain that long is a loop in practice; the path reached so
    # far is returned rather than an error, so the advisory stays conservative.
    for ($hop = 0; $hop -lt 32; $hop++) {
        $root = [System.IO.Path]::GetPathRoot($current)
        $parts = @($current.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries))
        $probe = $root
        $moved = $false
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $probe = Join-Path $probe $parts[$index]
            if (-not (Test-Path -LiteralPath $probe)) { break }
            $target = Get-LinkTargetPath $probe
            if ($null -eq $target) { continue }
            $tail = @($parts | Select-Object -Skip ($index + 1))
            if ($tail.Count -gt 0) { $current = [System.IO.Path]::GetFullPath((Join-Path $target ($tail -join '\'))) }
            else { $current = $target }
            $moved = $true
            break
        }
        if (-not $moved) { return $current }
    }
    return $current
}

function Test-OnSystemDrive {
    param([string]$PhysicalPath)
    $drive = Get-InstallSystemDrive
    return $PhysicalPath.StartsWith($drive, [System.StringComparison]::OrdinalIgnoreCase)
}

# One bounded read-only query. Kinds: npm-prefix, python-prefix, python-user.
# $Arguments carries interpreter flags that precede `-m pip` (`py -3.12`).
# A timeout, a missing program or a non-zero exit is $null: the target is then
# unknown, and an unknown target is silence, never a guess.
function Invoke-InstallLocationQuery {
    param([string]$Kind, [string]$Program, [string[]]$Arguments = @())
    if ($null -ne $script:InstallLocationQuery) { return (& $script:InstallLocationQuery $Kind $Program $Arguments) }
    $output = $null
    switch ($Kind) {
        'npm-prefix' { $output = Invoke-QuietCommand -FilePath 'npm' -ArgumentList @('config', 'get', 'prefix') -TimeoutSeconds $script:InstallLocationQueryTimeout }
        'python-prefix' { $output = Invoke-QuietCommand -FilePath $Program -ArgumentList (@($Arguments) + @('-c', 'import sys; print(sys.prefix)')) -TimeoutSeconds $script:InstallLocationQueryTimeout }
        'python-user' { $output = Invoke-QuietCommand -FilePath $Program -ArgumentList (@($Arguments) + @('-c', 'import site; print(site.USER_BASE)')) -TimeoutSeconds $script:InstallLocationQueryTimeout }
        default { return $null }
    }
    if ($null -eq $output -or $LASTEXITCODE -ne 0) { return $null }
    $line = [string](@($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return $line.Trim()
}

# Per-session cache of query answers (a path, keyed by kind and interpreter), so
# `npm config get prefix` runs once per session, not once per command. Paths
# only; the command text is never stored.
function Get-CachedInstallQuery {
    param([string]$CachePath, [string]$Kind, [string]$Program, [string[]]$Arguments = @())
    $key = Get-ShortHash (($Kind + '|' + $Program + '|' + (@($Arguments) -join ' ')).ToLowerInvariant())
    try {
        if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($CachePath)) {
                $parts = $line.Split([char]9)
                if ($parts.Count -eq 2 -and $parts[0] -eq $key) { return $parts[1] }
            }
        }
    }
    catch { }
    $answer = Invoke-InstallLocationQuery -Kind $Kind -Program $Program -Arguments $Arguments
    if ($null -ne $answer) {
        try {
            $directory = Split-Path -Parent $CachePath
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            [System.IO.File]::AppendAllText($CachePath, ($key + [char]9 + $answer + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { }
    }
    return $answer
}
