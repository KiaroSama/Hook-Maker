# _hooklib section: the Codebase Memory MCP helpers.
#
# Dot-sourced by _hooklib.ps1. Split out because the library had passed the
# size band that closes a file to new code, and this was the cleanest seam:
# these functions own no $script: state and nothing else in the library calls
# into them - they answer 'is this project indexed, and is the index current'
# by reading files, never by executing the server binary.

# ---- Codebase Memory MCP (CBM) ---------------------------------------------
# CBM keeps ONE SQLite file per indexed project directly in its cache
# directory: <cache>\<project-name>.db, beside _config.db and logs\. These
# helpers only look at the filesystem - no hook ever runs the CBM binary
# (measured at ~1.9 s per call, which no hook budget can afford), exactly as
# the Graphify hooks only test for graphify-out\graph.json.

# Read only Codex's CMM table: basic/literal strings, string argument arrays,
# and the environment subtable. Unsupported or malformed selected values fail
# closed; this is deliberately not a general-purpose TOML implementation.
function ConvertFrom-CbmTomlServer {
    param([string]$Text)
    $stringPattern = '"(?:[^"\\\r\n]|\\.)*"|''[^''\r\n]*'''
    function Read-CbmTomlString {
        param([string]$Value)
        $match = [regex]::Match($Value, ('^\s*(' + $stringPattern + ')\s*(?:#.*)?$'))
        if (-not $match.Success) { throw 'Unsupported CMM TOML string.' }
        $literal = $match.Groups[1].Value
        if ($literal[0] -eq [char]39) { return $literal.Substring(1, $literal.Length - 2) }
        return ($literal | ConvertFrom-Json -ErrorAction Stop)
    }
    $record = @{ command = ''; args = @(); env = @{} }
    $section = ''; $found = $false; $seen = @{}
    $lines = $Text -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('[')) {
            $section = ''
            if ($line -match '^\[\s*mcp_servers\s*\.\s*(?:codebase-memory-mcp|"codebase-memory-mcp"|''codebase-memory-mcp'')\s*(?<env>\.\s*env)?\s*\]\s*(?:#.*)?$') {
                $section = if ($Matches['env']) { 'env' } else { 'server' }
                $found = $true
            }
            continue
        }
        if ($section -eq '') { continue }
        if ($line -notmatch '^([A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|''[A-Za-z0-9_-]+'')\s*=\s*(.*)$') { throw 'Malformed CMM TOML assignment.' }
        $key = $Matches[1].Trim([char[]]@([char]34, [char]39)); $value = $Matches[2]
        $identity = $section + '.' + $key
        if ($seen.ContainsKey($identity)) { throw 'Duplicate CMM TOML key.' }
        $seen[$identity] = $true
        if ($section -eq 'env') {
            if ($key -in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) { $record.env[$key] = Read-CbmTomlString $value }
        }
        elseif ($key -eq 'command') { $record.command = Read-CbmTomlString $value }
        elseif ($key -eq 'env') {
            if ($value -notmatch '^\{(?<body>.*)\}\s*(?:#.*)?$') { throw 'Unsupported CMM inline environment.' }
            $body = $Matches['body'].Trim(); $position = 0
            $pairPattern = '\G\s*(?<key>[A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|''[A-Za-z0-9_-]+'')\s*=\s*(?<value>' + $stringPattern + ')\s*(?<separator>,|$)'
            foreach ($pair in [regex]::Matches($body, $pairPattern)) {
                $envKey = $pair.Groups['key'].Value.Trim([char[]]@([char]34, [char]39))
                if ($seen.ContainsKey('env.' + $envKey)) { throw 'Duplicate CMM environment key.' }
                $seen['env.' + $envKey] = $true
                if ($envKey -in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) { $record.env[$envKey] = Read-CbmTomlString $pair.Groups['value'].Value }
                $position = $pair.Index + $pair.Length
                if ($position -eq $body.Length -and $pair.Groups['separator'].Value -eq ',') { throw 'Trailing CMM environment comma.' }
            }
            if ($position -ne $body.Length) { throw 'Malformed CMM inline environment.' }
        }
        elseif ($key -eq 'args') {
            if (-not $value.StartsWith('[')) { throw 'CMM args must be a string array.' }
            while (([regex]::Replace($value, ($stringPattern + '|#[^\r\n]*'), '')).TrimEnd() -notmatch '\]$') {
                if (++$i -ge $lines.Count) { throw 'Unclosed CMM argument array.' }
                $value += "`n" + $lines[$i]
            }
            $body = [regex]::Replace($value, ('(?<string>' + $stringPattern + ')|(?<comment>#[^\r\n]*)'), {
                param($m) if ($m.Groups['comment'].Success) { return '' }; return $m.Value
            }).Trim()
            $body = $body.Substring(1, $body.Length - 2)
            $argumentValues = New-Object System.Collections.Generic.List[string]
            $expectValue = $true
            foreach ($token in [regex]::Matches($body, ('(?<string>' + $stringPattern + ')|(?<comma>,)|(?<space>\s+)|(?<other>.)'))) {
                if ($token.Groups['space'].Success) { continue }
                if ($token.Groups['string'].Success -and $expectValue) {
                    [void]$argumentValues.Add((Read-CbmTomlString $token.Value)); $expectValue = $false
                }
                elseif ($token.Groups['comma'].Success -and -not $expectValue) { $expectValue = $true }
                else { throw 'Malformed CMM argument array.' }
            }
            $record.args = @($argumentValues.ToArray())
        }
        elseif ($key -eq 'enabled') {
            if ($value -cnotmatch '^(true|false)(?:\s*#.*)?$') { throw 'CMM enabled must be true or false.' }
            $record.enabled = ($Matches[1] -ceq 'true')
        }
    }
    if ($found) { return $record }
    return $null
}

# Select ONE CMM record, retaining only invocation data and four directory keys.
# Case-preserving deserialization matters: real Claude profiles can contain
# case-distinct project paths outside mcpServers, which PSCustomObject rejects.
function Get-CbmServerConfig {
    param([string[]]$ConfigPaths, [string]$ProjectRoot = '', [string]$Client = '')
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).Path }
    if ($null -eq $ConfigPaths -or @($ConfigPaths).Count -eq 0) {
        $codexRoot = [string]$env:CODEX_HOME
        if ([string]::IsNullOrWhiteSpace($codexRoot)) { $codexRoot = Join-Path $env:USERPROFILE '.codex' }
        # Claude stores both local and user scopes in one file, with the
        # project's .mcp.json between them in precedence.
        $claudeProfile = Join-Path $env:USERPROFILE '.claude.json'
        $claudeSources = @(
            @{Path=$claudeProfile;Scope='local'},
            @{Path=(Join-Path $ProjectRoot '.mcp.json');Scope='server'},
            @{Path=$claudeProfile;Scope='server'}
        )
        $codexSources = @(
            @{Path=(Join-Path $ProjectRoot '.codex\config.toml');Scope='server'},
            @{Path=(Join-Path $codexRoot 'config.toml');Scope='server'}
        )
        $sources = if ((Get-HookClientId -Explicit $Client) -eq 'codex') { $codexSources + $claudeSources } else { $claudeSources + $codexSources }
    }
    else { $sources = @($ConfigPaths | ForEach-Object { @{Path=$_;Scope='any'} }) }
    foreach ($source in $sources) {
        $candidate = [string]$source.Path
        try {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $file = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -gt 1MB) { continue }
            $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false, $true))
            $entry = $null
            if ([System.IO.Path]::GetExtension($candidate) -ieq '.toml') { $entry = ConvertFrom-CbmTomlServer $raw }
            else {
                if ($PSVersionTable.PSVersion.Major -ge 6) { $doc = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
                else {
                    [void][System.Reflection.Assembly]::Load('System.Web.Extensions, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35')
                    $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                    $reader.MaxJsonLength = 1MB
                    $doc = $reader.DeserializeObject($raw)
                }
                if ($doc -is [System.Collections.IDictionary]) {
                    if ($source.Scope -ne 'server' -and $doc.ContainsKey('projects') -and $doc['projects'] -is [System.Collections.IDictionary]) {
                        $root = Normalize-Path $ProjectRoot
                        foreach ($key in $doc['projects'].Keys) {
                            try {
                                if (-not [System.IO.Path]::IsPathRooted([string]$key) -or
                                    -not [string]::Equals((Normalize-Path ([string]$key)), $root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                            }
                            catch { continue }
                            $project = $doc['projects'][$key]
                            if ($project -is [System.Collections.IDictionary] -and $project.ContainsKey('mcpServers')) {
                                $servers = $project['mcpServers']
                                if ($servers -is [System.Collections.IDictionary] -and $servers.ContainsKey('codebase-memory-mcp')) { $entry = $servers['codebase-memory-mcp'] }
                            }
                            break
                        }
                    }
                    if ($null -eq $entry -and $source.Scope -ne 'local' -and $doc.ContainsKey('mcpServers')) {
                        $servers = $doc['mcpServers']
                        if ($servers -is [System.Collections.IDictionary] -and $servers.ContainsKey('codebase-memory-mcp')) { $entry = $servers['codebase-memory-mcp'] }
                    }
                }
            }
            if ($entry -isnot [System.Collections.IDictionary]) { continue }
            if ($entry.ContainsKey('enabled')) {
                if ($entry['enabled'] -isnot [bool]) { continue }
                if (-not $entry['enabled']) {
                    # An explicit disable is a selected record, not absence:
                    # falling through would reactivate a lower-priority server.
                    return [pscustomobject]@{ Command = ''; Arguments = @(); Environment = @{}; ConfigPath = $candidate; Disabled = $true }
                }
            }
            $command = if ($entry.ContainsKey('command') -and $entry['command'] -is [string]) { [string]$entry['command'] } else { '' }
            $arguments = @()
            if ($entry.ContainsKey('args')) {
                if ($entry['args'] -is [string]) { continue }
                $arguments = @($entry['args'])
                if ($arguments.Count -gt 128 -or @($arguments | Where-Object { $_ -isnot [string] }).Count -gt 0) { continue }
            }
            $environment = @{}
            if ($entry.ContainsKey('env') -and $entry['env'] -is [System.Collections.IDictionary]) {
                foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
                    if ($entry['env'].ContainsKey($key) -and $entry['env'][$key] -is [string]) { $environment[$key] = [string]$entry['env'][$key] }
                }
            }
            return [pscustomobject]@{ Command = $command; Arguments = @($arguments); Environment = $environment; ConfigPath = $candidate; Disabled = $false }
        }
        catch { continue }
    }
    return $null
}

function Get-CbmServiceConfig {
    param($Config, [string[]]$ClientConfigPaths, [string]$ProjectRoot = '')
    $server = Get-CbmServerConfig -ConfigPaths $ClientConfigPaths -ProjectRoot $ProjectRoot
    if ($null -ne $server -and $server.Disabled) {
        return [pscustomobject]@{ Command = ''; Arguments = @(); Environment = @{CBM_CACHE_DIR = ''}; Disabled = $true }
    }
    $environment = @{}
    foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
        $value = ''
        if ($null -ne $Config -and $Config.ContainsKey($key)) { $value = [string]$Config[$key] }
        if ([string]::IsNullOrWhiteSpace($value) -and $key.StartsWith('CBM_')) { $value = [Environment]::GetEnvironmentVariable($key) }
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $server -and $server.Environment.ContainsKey($key)) { $value = $server.Environment[$key] }
        # TEMP/TMP in a hook are usually the shell's defaults, not CMM overrides.
        if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($key) }
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$key] = $value.Trim() }
    }
    if (-not $environment.ContainsKey('CBM_CACHE_DIR')) { $environment['CBM_CACHE_DIR'] = Join-Path $env:USERPROFILE '.cache\codebase-memory-mcp' }
    return [pscustomobject]@{
        Command = $(if ($null -ne $server) { $server.Command } else { '' })
        Arguments = @($(if ($null -ne $server) { $server.Arguments }))
        Environment = $environment
        Disabled = $false
    }
}

function Get-CbmCacheDir {
    param($Config, [string[]]$ClientConfigPaths, [string]$ProjectRoot = '')
    return (Get-CbmServiceConfig -Config $Config -ClientConfigPaths $ClientConfigPaths -ProjectRoot $ProjectRoot).Environment['CBM_CACHE_DIR']
}
function Get-CbmCacheDirFromClientConfig {
    param([string[]]$ConfigPaths)
    $server = Get-CbmServerConfig -ConfigPaths $ConfigPaths
    if ($null -ne $server -and $server.Environment.ContainsKey('CBM_CACHE_DIR')) { return $server.Environment['CBM_CACHE_DIR'].Trim() }
    return ''
}
function Get-CbmServerCommandFromClientConfig {
    param([string[]]$ConfigPaths)
    $server = Get-CbmServerConfig -ConfigPaths $ConfigPaths
    if ($null -ne $server) { return $server.Command }
    return ''
}

function Get-CbmCliAdvice {
    param($Service, [string[]]$Arguments)
    if ($null -eq $Service -or [string]::IsNullOrWhiteSpace($Service.Command)) { return '' }
    # Only the identified raw CMM program has a known subcommand contract.
    # Interpreters and arbitrary executable wrappers need separate verification.
    $program = [System.IO.Path]::GetFileName($Service.Command)
    if ($program -notmatch '^codebase-memory-mcp(?:\.exe)?$') { return '' }
    $tokens = @($Service.Command) + @($Service.Arguments) + @($Arguments)
    if (@($tokens | Where-Object { $_ -match '[\r\n\x00]' -or $_ -match '(?i)^--?(?:token|password|secret|api[-_]key)(?:=|$)' }).Count -gt 0) { return '' }
    $prefix = @()
    foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
        if ($Service.Environment.ContainsKey($key)) {
            $value = [string]$Service.Environment[$key]
            if ($value -match '[\r\n\x00]') { return '' }
            $prefix += ('$env:' + $key + " = '" + $value.Replace("'", "''") + "'")
        }
    }
    $invocation = '& ' + ((@($tokens | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })) -join ' ')
    $advice = (@($prefix) + @($invocation)) -join '; '
    if ($advice.Length -gt 8192) { return '' }
    return $advice
}

# _config.db is CBM's own registry and exists as soon as the server has run
# once. Without it the server was never set up on this machine, and a hook
# that nags about a tool the user does not have is pure noise.
function Test-CbmInstalled {
    param([string]$CacheDir)
    if ([string]::IsNullOrWhiteSpace($CacheDir)) { return $false }
    try { return (Test-Path -LiteralPath (Join-Path $CacheDir '_config.db') -PathType Leaf) }
    catch { return $false }
}

# CBM derives the default project name from the FULL root path: every run of
# characters outside [A-Za-z0-9] collapses to a single '-', then the ends are
# trimmed. Verified 2026-09-06 against a real index: the root
# ...\G--Program-Files-Portable-Scripts-Hook-Maker\<id>\scratchpad\cbm name probe
# produced C-Users-...-G-Program-Files-Portable-Scripts-Hook-Maker-<id>-scratchpad-cbm-name-probe.db
# - note the doubled separator collapsing to one dash and the space becoming
# one. A caller CAN override this with index_repository(name=...); a hook
# cannot see that, so an overridden project reads as un-indexed here. That is
# the documented limitation, and it fails toward silence rather than a wrong
# claim.
function Get-CbmProjectName {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $collapsed = [System.Text.RegularExpressions.Regex]::Replace([string]$ProjectRoot, '[^A-Za-z0-9]+', '-')
    return $collapsed.Trim('-')
}

function Get-CbmProjectDbPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$CacheDir
    )
    return (Join-Path $CacheDir ((Get-CbmProjectName -ProjectRoot $ProjectRoot) + '.db'))
}
