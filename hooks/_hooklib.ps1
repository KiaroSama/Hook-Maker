# Shared helpers for Hook Maker's shipped hooks. Each hook dot-sources this
# once ( . (Join-Path $PSScriptRoot '..\_hooklib.ps1') ) so the identical
# stdin / .env / hash / JSON boilerplate lives in exactly one place. The
# underscore prefix keeps it out of the wizard's hook discovery
# (Get-HookEntries skips '_'-prefixed names). StrictMode 2.0 clean; every
# function is self-contained so it works from any host or scope.

# Field accessor tolerant of a missing property or a $null value.
function Get-Field {
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) {
        return $Obj.$Name
    }
    return $null
}

# Reads the hook event JSON from stdin. Returns the parsed object, or $null on
# empty / non-JSON input (the caller then exits silently).
function Read-HookInput {
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return ($raw | ConvertFrom-Json)
        }
    }
    catch { }
    return $null
}

# Parses a KEY=VALUE .env file ('#' comments allowed). Returns a hashtable;
# empty when the file is absent or blank.
function Read-HookEnv {
    param([string]$Path)
    $values = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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

# 10-char lowercase hex SHA-256 prefix — stable per-project state file keys.
function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally {
        $sha.Dispose()
    }
}

# Reads a JSON file into an object, or $null when absent / blank.
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

# Writes an object as UTF-8 (no BOM) JSON via a temp file + atomic move.
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
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

# Runs an external command (git, gh, ...) whose stderr must NEVER become a
# terminating error, even when the command exits non-zero. Windows PowerShell
# 5.1 promotes ANY stderr line from a native command into a NativeCommandError
# under $ErrorActionPreference='Stop' - and, verified empirically, `2>$null`,
# `2>&1 | Out-Null`, and `*>$null` all fail to prevent that promotion under 5.1
# (pwsh 7 is unaffected, which is why this only shows up against the real
# Claude client). Only relaxing $ErrorActionPreference around the call works.
# Returns stdout lines (redirecting stderr away); $LASTEXITCODE is left intact
# for the caller exactly as a raw `&` call would leave it.
function Invoke-QuietCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return & $FilePath @ArgumentList 2>$null
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
}

# Friendly, hyphen-separated hook name. The shipped hook folders are already
# hyphenated (Cross-Project-.ai-Knowledge-Sync, Mcp-Usage-Check, ...), so this
# is a no-op for them; it still tidies a user's PascalCase custom-hook name
# (MyContextHook -> My-Context-Hook) for the menu + the installed copy folder.
# Explicit overrides can rename a folder to a nicer label if ever needed.
$script:HookFriendlyOverrides = @{}
function Get-HookFriendlyName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:HookFriendlyOverrides.ContainsKey($Name)) {
        return $script:HookFriendlyOverrides[$Name]
    }
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($Name, '([A-Z]+)([A-Z][a-z])', '$1-$2')
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($hyphenated, '([a-z0-9])([A-Z])', '$1-$2')
    return $hyphenated
}
