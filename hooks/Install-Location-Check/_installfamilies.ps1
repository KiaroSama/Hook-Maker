# Install-Location-Check: RECOGNITION AND TARGET SELECTION.
#
# One command SEGMENT (tokens, already split on separators by the shared
# tokenizer) in, zero or more findings out:
#   Family  - the installer family named in the advisory
#   Package - what is being installed, one finding per package
#   Target  - the directory the installer would write into, or $null
#   Query   - when Target is $null: @{ Kind; Program; Arguments } for a bounded
#             read-only query that answers it (_physicalpath.ps1)
#   ExtraTargets - further directories the same install writes (uv launchers)
#   Advice  - replaces the ask-for-a-path text when the fix is already known
# Recognition is conservative: a form not listed here returns nothing, and a
# nested shell string (`pwsh -Command '...'`) is one token and never parsed.
# The one exception is the CommandLine literal of Win32_Process.Create, which
# is tokenized as data because no shell stands between it and the installer.

function New-InstallFinding {
    param([string]$Family, [string]$Package, [string]$Target, $Query = $null, [string[]]$ExtraTargets = @(), [string]$Advice = $null)
    return [pscustomobject]@{ Family = $Family; Package = $Package; Target = $Target; Query = $Query; ExtraTargets = $ExtraTargets; Advice = $Advice }
}

# STALE ENVIRONMENT. A location variable the user set after this shell started
# lives in HKCU\Environment but not in this process, so the tool would fall
# back to its C: default although the user already chose a path. Every lookup
# of a listed variable that misses here is checked there (read-only) and
# recorded in $script:InstallStaleEnv as NAME=value; the caller clears the list
# per segment. Seam: $script:InstallLocationUserEnv = { param($Name) <value> }.
$script:InstallLocationUserEnv = $null
$script:InstallStaleEnv = New-Object System.Collections.Generic.List[string]
$script:InstallLocationVariables = @('UV_TOOL_DIR', 'UV_TOOL_BIN_DIR', 'UV_PYTHON_INSTALL_DIR', 'UV_PYTHON_BIN_DIR', 'XDG_BIN_HOME', 'XDG_DATA_HOME',
    'HF_HOME', 'HF_HUB_CACHE', 'OLLAMA_MODELS', 'PYTHONUSERBASE', 'PIP_TARGET', 'PIP_PREFIX', 'npm_config_prefix', 'NPM_CONFIG_PREFIX',
    'PNPM_HOME', 'PIPX_HOME', 'CARGO_HOME', 'GOBIN', 'GOPATH', 'SCOOP', 'SCOOP_GLOBAL')

function Get-InstallUserEnvValue {
    param([string]$Name)
    if ($null -ne $script:InstallLocationUserEnv) { return [string](& $script:InstallLocationUserEnv $Name) }
    try { return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::User) } catch { return $null }
}

function Get-InstallEnvPath {
    param([string[]]$Names, $Fallback)
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return ($value.Split(';')[0]).Trim() }
        if ($script:InstallLocationVariables -notcontains $name) { continue }
        $user = Get-InstallUserEnvValue $name
        if ([string]::IsNullOrWhiteSpace($user) -or @($script:InstallStaleEnv | Where-Object { $_ -like ($name + '=*') }).Count -gt 0) { continue }
        [void]$script:InstallStaleEnv.Add($name + '=' + ($user.Split(';')[0]).Trim())
    }
    return $Fallback
}

# uv's executable directory (https://docs.astral.sh/uv/reference/storage/):
# the tool's own override, else XDG_BIN_HOME, else XDG_DATA_HOME\..\bin, else
# %USERPROFILE%\.local\bin.
function Get-UvBinDirectory {
    param([string]$Override, [string]$UserHome)
    $bin = Get-InstallEnvPath @($Override, 'XDG_BIN_HOME') $null
    if ($null -ne $bin) { return $bin }
    $data = Get-InstallEnvPath @('XDG_DATA_HOME') $null
    if ($null -ne $data) { return (Join-Path (Split-Path -Parent $data) 'bin') }
    return (Join-Path $UserHome '.local\bin')
}

function Get-InstallHome { return (Get-InstallEnvPath @('USERPROFILE', 'HOME') 'C:\Users\Default') }

# Value of the first matching option, in `--opt value` or `--opt=value` form.
function Get-InstallOptionValue {
    param([string[]]$Tokens, [string[]]$Names)
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        $token = $Tokens[$index]
        foreach ($name in $Names) {
            if ($token -ieq $name -and ($index + 1) -lt $Tokens.Count) { return $Tokens[$index + 1] }
            if ($token.StartsWith($name + '=', [System.StringComparison]::OrdinalIgnoreCase)) { return $token.Substring($name.Length + 1) }
        }
    }
    return $null
}

function Test-InstallFlag {
    param([string[]]$Tokens, [string[]]$Names)
    foreach ($token in $Tokens) { foreach ($name in $Names) { if ($token -ieq $name) { return $true } } }
    return $false
}

# Positional arguments: tokens that are not options and not an option's value.
function Get-InstallPositionals {
    param([string[]]$Tokens, [string[]]$ValueOptions = @())
    $result = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        $token = $Tokens[$index]
        if ($token.StartsWith('-')) {
            if (-not $token.Contains('=') -and (@($ValueOptions | Where-Object { $_ -ieq $token }).Count -gt 0)) { $index++ }
            continue
        }
        [void]$result.Add($token)
    }
    return $result.ToArray()
}

# The segment rejoined, for Windows installer properties whose quoted values the
# shell tokenizer splits (`INSTALLDIR="G:\Program Files\X"`).
function Get-InstallerPropertyPath {
    param([string[]]$Tokens)
    $joined = ' ' + ($Tokens -join ' ')
    foreach ($pattern in @('(?i)\s(?:INSTALLDIR|TARGETDIR|INSTALLLOCATION|APPDIR)=(?:"([^"]+)"|(\S+))', '(?i)\s/DIR=(?:"([^"]+)"|(\S+))')) {
        $match = [regex]::Match($joined, $pattern)
        if ($match.Success) { return $(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }) }
    }
    # NSIS: /D= is last and unquoted, spaces included.
    $nsis = [regex]::Match($joined, '(?i)\s/D=(.+)$')
    if ($nsis.Success) { return $nsis.Groups[1].Value.Trim() }
    return $null
}

# The two installers the rule names whose file names say neither setup nor
# install: cuda_13.4.0_windows_network.exe, cuda_12.9.1_576.57_windows.exe and
# python-3.14.7-amd64.exe. NVIDIA driver packages (581.29-desktop-...exe) stay
# unrecognised: the driver on C: is an accepted exception.
$script:CudaInstallerPattern = '(?i)^cuda_(\d+\.\d+)[0-9.]*_(?:[0-9.]+_)?windows[a-z0-9_]*\.exe$'
$script:PythonInstallerPattern = '(?i)^python-(\d+)\.(\d+)[0-9a-z.]*(-amd64|-arm64)?\.exe$'

function Test-InstallerFileName {
    param([string]$Name)
    $leaf = $Name.Replace('/', '\').Split('\')[-1].ToLowerInvariant()
    if ($leaf.EndsWith('.msi')) { return $true }
    if (-not $leaf.EndsWith('.exe')) { return $false }
    if ($leaf.Contains('uninst')) { return $false }
    if ($leaf -match $script:CudaInstallerPattern -or $leaf -match $script:PythonInstallerPattern) { return $true }
    return ($leaf.Contains('setup') -or $leaf.Contains('install'))
}

function Get-InstallerFindings {
    param([string]$File, [string[]]$Arguments)
    $leaf = $File.Replace('/', '\').Split('\')[-1]
    $programFiles = Get-InstallEnvPath @('ProgramFiles') 'C:\Program Files'
    $target = Get-InstallerPropertyPath -Tokens $Arguments
    $advice = $null
    $cuda = [regex]::Match($leaf, $script:CudaInstallerPattern)
    $python = [regex]::Match($leaf, $script:PythonInstallerPattern)
    if ($cuda.Success) {
        # NVIDIA's documented default; the installer has no location option.
        $target = Join-Path $programFiles ('NVIDIA GPU Computing Toolkit\CUDA\v' + $cuda.Groups[1].Value)
        if (Test-InstallFlag -Tokens $Arguments -Names @('-s', '/s')) {
            $advice = 'CUDA silent mode (-s) always installs on the system drive, so asking for a path does not help. Working route: start the ' +
                'graphical Custom install through explorer.exe "<installer>", untick Driver and NVIDIA App, choose the location there, and take ' +
                'the toolkit major version that matches the PyTorch build (cu128 -> 12.x, cu130/cu132 -> 13.x); then verify where it landed. ' +
                'Rule: global-environment-rules.md -> Install Locations.'
        }
    }
    elseif ($null -eq $target -and $python.Success) {
        # DefaultJustForMeTargetDir / DefaultAllUsersTargetDir (InstallAllUsers=0 is the default).
        $xy = $python.Groups[1].Value + $python.Groups[2].Value
        if ((' ' + ($Arguments -join ' ')) -match '(?i)\sInstallAllUsers=1(\s|$)') { $target = Join-Path $programFiles ('Python' + $xy) }
        else {
            $suffix = $(if ($python.Groups[3].Value -ieq '-arm64') { '-arm64' } elseif ($python.Groups[3].Success) { '' } else { '-32' })
            $target = Join-Path (Get-InstallEnvPath @('LOCALAPPDATA') (Join-Path (Get-InstallHome) 'AppData\Local')) ('Programs\Python\Python' + $xy + $suffix)
        }
    }
    if ($null -eq $target) { $target = $programFiles }
    return @(New-InstallFinding -Family 'installer' -Package $leaf -Target $target -Advice $advice)
}

# The CommandLine string of `Invoke-CimMethod ... -Arguments @{ CommandLine = '...' }`,
# read as DATA: the hashtable is never evaluated. Spaced forms arrive as
# tokens; a glued `@{CommandLine='x y'}` is read from the rejoined segment.
function Get-CimCommandLine {
    param([string[]]$Tokens)
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        $token = $Tokens[$index]
        if ($token -match '(?i)^(@\{)?CommandLine$' -and ($index + 2) -lt $Tokens.Count -and $Tokens[$index + 1] -eq '=') { return $Tokens[$index + 2] }
        if ($token -match '(?i)^(@\{)?CommandLine=$' -and ($index + 1) -lt $Tokens.Count) { return $Tokens[$index + 1] }
    }
    $match = [regex]::Match((' ' + ($Tokens -join ' ')), '(?i)CommandLine\s*=\s*(?:''([^'']*)''|"([^"]*)")')
    if (-not $match.Success) { return $null }
    return $(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value })
}

function Get-PipFindings {
    param([string[]]$Rest, [string]$Interpreter, [string[]]$InterpreterArgs, [string]$ProjectRoot, [bool]$VenvActivated)
    if ($VenvActivated) { return @() }
    $valueOptions = @('-r', '--requirement', '-c', '--constraint', '-e', '--editable', '-i', '--index-url', '--extra-index-url',
        '-f', '--find-links', '-t', '--target', '--prefix', '--root', '--upgrade-strategy', '--python-version', '--platform',
        '--implementation', '--abi', '--src', '--cache-dir', '--log', '--proxy', '--retries', '--timeout', '--exists-action',
        '--trusted-host', '--cert', '--client-cert', '--config-settings', '-C', '--progress-bar', '--report')
    $packages = @(Get-InstallPositionals -Tokens $Rest -ValueOptions $valueOptions)
    foreach ($option in @('-r', '--requirement', '-e', '--editable')) {
        $value = Get-InstallOptionValue -Tokens $Rest -Names @($option)
        if ($null -ne $value) { $packages += $value }
    }
    if ($packages.Count -eq 0) { return @() }
    $explicit = Get-InstallOptionValue -Tokens $Rest -Names @('-t', '--target', '--prefix', '--root')
    # pip reads PIP_<OPTION> as the option itself.
    if ($null -eq $explicit) { $explicit = Get-InstallEnvPath @('PIP_TARGET', 'PIP_PREFIX') $null }
    $query = $null
    if ($null -eq $explicit) {
        # An interpreter named by PATH inside the project is the project's own.
        if ($Interpreter.Contains('\') -or $Interpreter.Contains('/')) {
            $full = $Interpreter
            if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $ProjectRoot $full }
            if (Test-PathInside -Candidate $full -Parent $ProjectRoot) { return @() }
            # An explicit interpreter path is DATA from a command the user has not
            # approved yet: never execute it. The install target is derivable from
            # where it lives - a base install's python.exe sits in the prefix, a
            # virtual environment's in <prefix>\Scripts - and the physical path of
            # that target decides the drive. --user goes to USER_BASE, whose
            # documented Windows default is %APPDATA%\Python whatever the interpreter.
            $exeDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($full))
            $target = $(if ((Split-Path -Leaf $exeDir) -ieq 'Scripts') { Split-Path -Parent $exeDir } else { $exeDir })
            if (Test-InstallFlag -Tokens $Rest -Names @('--user')) { $target = Get-InstallEnvPath @('PYTHONUSERBASE') (Join-Path (Get-InstallEnvPath @('APPDATA') '') 'Python') }
            return @($packages | ForEach-Object { New-InstallFinding -Family 'pip' -Package $_ -Target $target -Query $null })
        }
        $venv = [string]$env:VIRTUAL_ENV
        if (-not [string]::IsNullOrWhiteSpace($venv) -and (Test-PathInside -Candidate $venv -Parent $ProjectRoot)) { return @() }
        $kind = $(if (Test-InstallFlag -Tokens $Rest -Names @('--user')) { 'python-user' } else { 'python-prefix' })
        # Only for the stale-environment check: the query itself answers USER_BASE.
        if ($kind -eq 'python-user') { $null = Get-InstallEnvPath @('PYTHONUSERBASE') $null }
        $query = @{ Kind = $kind; Program = $Interpreter; Arguments = @($InterpreterArgs) }
    }
    return @($packages | ForEach-Object { New-InstallFinding -Family 'pip' -Package $_ -Target $explicit -Query $query })
}

# Every finding for one segment. $AllTokens is the whole command, used only to
# notice a venv activation earlier in the same command.
function Get-InstallFindings {
    param([string[]]$Tokens, [string[]]$AllTokens, [string]$ProjectRoot)
    $tokens = @($Tokens)
    if ($tokens.Count -eq 0) { return @() }
    $program = Get-ProgramName $tokens[0]
    if ($program -eq 'sudo' -or $program -eq 'call') { $tokens = @($tokens | Select-Object -Skip 1); if ($tokens.Count -eq 0) { return @() }; $program = Get-ProgramName $tokens[0] }
    $args1 = @($tokens | Select-Object -Skip 1)
    $sub = $(if ($args1.Count -gt 0) { $args1[0].ToLowerInvariant() } else { '' })
    $rest = @($args1 | Select-Object -Skip 1)
    $home1 = Get-InstallHome
    $venvActivated = (@($AllTokens | Where-Object { $_ -match '(?i)[\\/]activate(\.ps1|\.bat)?$' }).Count -gt 0)

    if ($program -eq 'winget' -and @('install', 'add', 'upgrade') -contains $sub) {
        if (Test-InstallFlag -Tokens $rest -Names @('--all', '-r', '--recurse')) { return @() }
        $valueOptions = @('-q', '--query', '-m', '--manifest', '--id', '--name', '--moniker', '-v', '--version', '-s', '--source', '--scope',
            '-a', '--architecture', '--installer-type', '--locale', '-o', '--log', '--custom', '--override', '-l', '--location', '--header',
            '--authentication-mode', '--authentication-account', '-r', '--rename', '--dependency-source', '--proxy')
        $packages = @()
        $named = Get-InstallOptionValue -Tokens $rest -Names @('--id', '-q', '--query', '--name', '--moniker', '-m', '--manifest')
        if ($null -ne $named) { $packages = @($named) } else { $packages = @(Get-InstallPositionals -Tokens $rest -ValueOptions $valueOptions) }
        $target = Get-InstallOptionValue -Tokens $rest -Names @('-l', '--location')
        if ($null -eq $target) {
            $scope = [string](Get-InstallOptionValue -Tokens $rest -Names @('--scope'))
            $target = $(if ($scope -ieq 'user') { Join-Path (Get-InstallEnvPath @('LOCALAPPDATA') (Join-Path $home1 'AppData\Local')) 'Programs' } else { Get-InstallEnvPath @('ProgramFiles') 'C:\Program Files' })
        }
        return @($packages | ForEach-Object { New-InstallFinding -Family 'winget' -Package $_ -Target $target })
    }
    if (($program -eq 'choco' -and $sub -eq 'install') -or $program -eq 'cinst') {
        $chocoArgs = $(if ($program -eq 'cinst') { $args1 } else { $rest })
        $valueOptions = @('-s', '--source', '--version', '--params', '--package-parameters', '--ia', '--install-arguments', '--dir', '--directory',
            '--installdir', '--installationdirectory', '--install-directory', '--cache-location', '--timeout', '-u', '--user', '-p', '--password')
        $target = Get-InstallOptionValue -Tokens $chocoArgs -Names @('--install-directory', '--installdir', '--installationdirectory', '--dir', '--directory')
        if ($null -eq $target) { $target = Get-InstallEnvPath @('ChocolateyInstall') (Join-Path (Get-InstallEnvPath @('ProgramData') 'C:\ProgramData') 'chocolatey') }
        return @(Get-InstallPositionals -Tokens $chocoArgs -ValueOptions $valueOptions | ForEach-Object { New-InstallFinding -Family 'choco' -Package $_ -Target $target })
    }
    if ($program -eq 'scoop' -and $sub -eq 'install') {
        $target = $(if (Test-InstallFlag -Tokens $rest -Names @('-g', '--global')) { Get-InstallEnvPath @('SCOOP_GLOBAL') (Join-Path (Get-InstallEnvPath @('ProgramData') 'C:\ProgramData') 'scoop') } else { Get-InstallEnvPath @('SCOOP') (Join-Path $home1 'scoop') })
        return @(Get-InstallPositionals -Tokens $rest -ValueOptions @('-a', '--arch') | ForEach-Object { New-InstallFinding -Family 'scoop' -Package $_ -Target $target })
    }
    if ($program -match '^pip[0-9.]*$' -and $sub -eq 'install') {
        return @(Get-PipFindings -Rest $rest -Interpreter 'python' -InterpreterArgs @() -ProjectRoot $ProjectRoot -VenvActivated $venvActivated)
    }
    if ($program -match '^(python[0-9.]*|py)$') {
        $moduleAt = [Array]::IndexOf([string[]]$args1, '-m')
        if ($moduleAt -ge 0 -and ($moduleAt + 2) -lt $args1.Count -and $args1[$moduleAt + 1] -eq 'pip' -and $args1[$moduleAt + 2] -ieq 'install') {
            $pipRest = @($args1 | Select-Object -Skip ($moduleAt + 3))
            $interpreterArgs = @($args1 | Select-Object -First $moduleAt)
            return @(Get-PipFindings -Rest $pipRest -Interpreter $tokens[0] -InterpreterArgs $interpreterArgs -ProjectRoot $ProjectRoot -VenvActivated $venvActivated)
        }
        return @()
    }
    if ($program -eq 'npm' -and @('install', 'i', 'add', 'in') -contains $sub -and (Test-InstallFlag -Tokens $rest -Names @('-g', '--global', '--location=global'))) {
        $prefix = Get-InstallEnvPath @('npm_config_prefix', 'NPM_CONFIG_PREFIX') $null
        $query = $(if ($null -eq $prefix) { @{ Kind = 'npm-prefix'; Program = 'npm'; Arguments = @() } } else { $null })
        return @(Get-InstallPositionals -Tokens $rest -ValueOptions @('--prefix', '--registry', '--tag') | ForEach-Object { New-InstallFinding -Family 'npm' -Package $_ -Target $prefix -Query $query })
    }
    if ($program -eq 'pnpm' -and @('add', 'install', 'i') -contains $sub -and (Test-InstallFlag -Tokens $rest -Names @('-g', '--global'))) {
        $target = Get-InstallEnvPath @('PNPM_HOME') (Join-Path (Get-InstallEnvPath @('LOCALAPPDATA') (Join-Path $home1 'AppData\Local')) 'pnpm')
        return @(Get-InstallPositionals -Tokens $rest | ForEach-Object { New-InstallFinding -Family 'pnpm' -Package $_ -Target $target })
    }
    if ($program -eq 'yarn' -and $sub -eq 'global' -and $rest.Count -gt 0 -and $rest[0] -ieq 'add') {
        $target = Join-Path (Get-InstallEnvPath @('LOCALAPPDATA') (Join-Path $home1 'AppData\Local')) 'Yarn'
        return @(Get-InstallPositionals -Tokens @($rest | Select-Object -Skip 1) | ForEach-Object { New-InstallFinding -Family 'yarn' -Package $_ -Target $target })
    }
    if ($program -eq 'pipx' -and $sub -eq 'install') {
        $target = Get-InstallEnvPath @('PIPX_HOME') (Join-Path $home1 'pipx')
        return @(Get-InstallPositionals -Tokens $rest -ValueOptions @('--python', '--pip-args', '--suffix', '--index-url', '--spec') | ForEach-Object { New-InstallFinding -Family 'pipx' -Package $_ -Target $target })
    }
    if ($program -eq 'uv' -and $sub -eq 'tool' -and $rest.Count -gt 0 -and $rest[0] -ieq 'install') {
        $target = Get-InstallEnvPath @('UV_TOOL_DIR') (Join-Path (Get-InstallEnvPath @('APPDATA') (Join-Path $home1 'AppData\Roaming')) 'uv\data\tools')
        $bin = Get-UvBinDirectory -Override 'UV_TOOL_BIN_DIR' -UserHome $home1
        return @(Get-InstallPositionals -Tokens @($rest | Select-Object -Skip 1) -ValueOptions @('--python', '-p', '--with', '--from', '--index-url', '--extra-index-url') | ForEach-Object { New-InstallFinding -Family 'uv' -Package $_ -Target $target -ExtraTargets @($bin) })
    }
    if ($program -eq 'uv' -and $sub -eq 'python' -and $rest.Count -gt 0 -and $rest[0] -ieq 'install') {
        $uvRest = @($rest | Select-Object -Skip 1)
        $target = Get-InstallOptionValue -Tokens $uvRest -Names @('--install-dir', '-i')
        if ($null -eq $target) { $target = Get-InstallEnvPath @('UV_PYTHON_INSTALL_DIR') (Join-Path (Get-InstallEnvPath @('APPDATA') (Join-Path $home1 'AppData\Roaming')) 'uv\data\python') }
        $versions = @(Get-InstallPositionals -Tokens $uvRest -ValueOptions @('--install-dir', '-i', '--mirror', '--pypy-mirror'))
        if ($versions.Count -eq 0) { $versions = @('python') }
        $bin = Get-UvBinDirectory -Override 'UV_PYTHON_BIN_DIR' -UserHome $home1
        return @($versions | ForEach-Object { New-InstallFinding -Family 'uv' -Package ('python ' + $_).Trim() -Target $target -ExtraTargets @($bin) })
    }
    if ($program -eq 'cargo' -and $sub -eq 'install') {
        $target = Get-InstallOptionValue -Tokens $rest -Names @('--root')
        if ($null -eq $target) { $target = Get-InstallEnvPath @('CARGO_HOME') (Join-Path $home1 '.cargo') }
        return @(Get-InstallPositionals -Tokens $rest -ValueOptions @('--root', '--version', '--git', '--branch', '--tag', '--rev', '--path', '--features', '-F', '--target', '--profile', '-j', '--jobs', '--registry', '--index') | ForEach-Object { New-InstallFinding -Family 'cargo' -Package $_ -Target $target })
    }
    if ($program -eq 'go' -and $sub -eq 'install') {
        $gobin = Get-InstallEnvPath @('GOBIN') $null
        if ($null -eq $gobin) { $gobin = Join-Path (Get-InstallEnvPath @('GOPATH') (Join-Path $home1 'go')) 'bin' }
        return @(Get-InstallPositionals -Tokens $rest | ForEach-Object { New-InstallFinding -Family 'go' -Package $_ -Target $gobin })
    }
    if ($program -eq 'dotnet' -and $sub -eq 'tool' -and $rest.Count -gt 0 -and $rest[0] -ieq 'install') {
        $toolRest = @($rest | Select-Object -Skip 1)
        $target = Get-InstallOptionValue -Tokens $toolRest -Names @('--tool-path')
        if ($null -eq $target) {
            if (-not (Test-InstallFlag -Tokens $toolRest -Names @('-g', '--global'))) { return @() }
            $target = Join-Path $home1 '.dotnet\tools'
        }
        return @(Get-InstallPositionals -Tokens $toolRest -ValueOptions @('--tool-path', '--version', '--add-source', '--configfile', '--framework', '-a', '--arch', '-v', '--verbosity') | ForEach-Object { New-InstallFinding -Family 'dotnet' -Package $_ -Target $target })
    }
    if (@('install-module', 'install-psresource', 'install-package') -contains $program) {
        $name = Get-InstallOptionValue -Tokens $args1 -Names @('-Name')
        if ($null -eq $name) { $name = [string](@(Get-InstallPositionals -Tokens $args1 -ValueOptions @('-Scope', '-RequiredVersion', '-MinimumVersion', '-MaximumVersion', '-Version', '-Repository', '-Source', '-ProviderName')) | Select-Object -First 1) }
        if ([string]::IsNullOrWhiteSpace($name)) { return @() }
        $scope = [string](Get-InstallOptionValue -Tokens $args1 -Names @('-Scope'))
        if ($scope -ieq 'AllUsers') { $target = Join-Path (Get-InstallEnvPath @('ProgramFiles') 'C:\Program Files') 'PowerShell\Modules' }
        else { $target = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules' }
        return @($name.Split(',') | Where-Object { $_.Trim() -ne '' } | ForEach-Object { New-InstallFinding -Family 'PowerShell' -Package $_.Trim() -Target $target })
    }
    if ($program -eq 'msiexec') {
        $package = Get-InstallOptionValue -Tokens $args1 -Names @('/i', '/package', '-i', '/I')
        if ($null -eq $package) { return @() }
        return @(Get-InstallerFindings -File $package -Arguments $args1)
    }
    if (@('start-process', 'start', 'saps') -contains $program) {
        $file = Get-InstallOptionValue -Tokens $args1 -Names @('-FilePath')
        if ($null -eq $file) { $file = [string](@(Get-InstallPositionals -Tokens $args1 -ValueOptions @('-ArgumentList', '-Args', '-WorkingDirectory', '-Verb', '-WindowStyle')) | Select-Object -First 1) }
        if ([string]::IsNullOrWhiteSpace($file) -or -not (Test-InstallerFileName $file)) { return @() }
        $installerArgs = [string](Get-InstallOptionValue -Tokens $args1 -Names @('-ArgumentList', '-Args'))
        return @(Get-InstallerFindings -File $file -Arguments @($installerArgs.Split([char[]]@(' ', ','), [System.StringSplitOptions]::RemoveEmptyEntries)))
    }
    # Launch routes that start an installer outside the agent's own process tree.
    if ($program -eq 'explorer') {
        $file = [string](@($args1 | Where-Object { -not $_.StartsWith('/') }) | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($file) -or -not (Test-InstallerFileName $file)) { return @() }
        return @(Get-InstallerFindings -File $file -Arguments @())
    }
    if ($program -eq 'invoke-cimmethod') {
        $commandLine = Get-CimCommandLine -Tokens $args1
        if ([string]::IsNullOrWhiteSpace($commandLine)) { return @() }
        return @(Get-InstallFindings -Tokens @(Split-CommandTokens -Text $commandLine) -AllTokens $AllTokens -ProjectRoot $ProjectRoot)
    }
    if (Test-InstallerFileName $tokens[0]) { return @(Get-InstallerFindings -File $tokens[0] -Arguments $args1) }
    if (($program -eq 'hf' -or $program -eq 'huggingface-cli') -and $sub -eq 'download') {
        if ($null -ne (Get-InstallOptionValue -Tokens $rest -Names @('--local-dir'))) { return @() }
        $target = Get-InstallOptionValue -Tokens $rest -Names @('--cache-dir')
        if ($null -eq $target) { $target = Get-InstallEnvPath @('HF_HUB_CACHE') $null }
        if ($null -eq $target) { $target = Join-Path (Get-InstallEnvPath @('HF_HOME') (Join-Path $home1 '.cache\huggingface')) 'hub' }
        $repo = [string](@(Get-InstallPositionals -Tokens $rest -ValueOptions @('--cache-dir', '--revision', '--repo-type', '--include', '--exclude', '--token', '--max-workers')) | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($repo)) { return @() }
        return @(New-InstallFinding -Family 'huggingface' -Package $repo -Target $target)
    }
    if ($program -eq 'ollama' -and $sub -eq 'pull' -and $rest.Count -gt 0) {
        $target = Get-InstallEnvPath @('OLLAMA_MODELS') (Join-Path $home1 '.ollama\models')
        return @(New-InstallFinding -Family 'ollama' -Package $rest[0] -Target $target)
    }
    return @()
}
