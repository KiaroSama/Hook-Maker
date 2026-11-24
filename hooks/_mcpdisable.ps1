# Shared Standing Order 8 per-project MCP disable resolution.
# Read-only helper dot-sourced by _hooklib.ps1 and packaged with every hook.
#
# Collects locally disabled MCP server names (case-insensitive) across all three
# Claude Code 2.1.x layers:
#   1. ~/.claude.json -> projects (ALL normalized path matches, no early break):
#      disabledMcpServers[] and mcpServers.<name>.enabled -eq $false
#   2. Settings files (user -> project -> project-local, later wins):
#      deniedMcpServers[].serverName and permissions.deny matching ^mcp__([^_][^:]*)__\*$
#   3. Merged enabledPlugins ($false) for plugin-owned MCP connectors.

$script:PluginMcpConnectorMap = @{
    'rust-anything@rust-anything'               = 'rust-anything'
    'cloudflare@cloudflare'                     = 'cloudflare'
    'chrome-devtools-mcp@chrome-devtools-plugins' = 'chrome-devtools'
    'claude-bughunter@elementalsouls'           = 'hackerone'
    'context-mode@context-mode'                 = 'context-mode'
    'slint@slint'                               = @('slint-docs', 'slint-preview')
}

function ConvertFrom-McpDisableJson {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            return ($Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
        }
        [void][System.Reflection.Assembly]::Load('System.Web.Extensions, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35')
        $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $reader.MaxJsonLength = 2MB
        return $reader.DeserializeObject($Raw)
    }
    catch { return $null }
}

function Read-McpDisableJsonFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 2MB) { return $null }
        $raw = [System.IO.File]::ReadAllText($item.FullName, [System.Text.UTF8Encoding]::new($false, $true))
        return (ConvertFrom-McpDisableJson -Raw $raw)
    }
    catch { return $null }
}

function Get-ProjectDisabledMcpServers {
    param(
        [string]$ProjectRoot = '',
        [string]$UserClaudeJsonPath = '',
        [string[]]$SettingsPaths = @()
    )
    $disabled = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $normalizedRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        try { $normalizedRoot = Normalize-Path $ProjectRoot } catch { $normalizedRoot = $ProjectRoot.Trim() }
    }

    # Layer 1: ~/.claude.json projects (inspect EVERY normalized match, no early break).
    $claudeJson = $UserClaudeJsonPath
    if ([string]::IsNullOrWhiteSpace($claudeJson)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_USER_JSON_PATH)) { $claudeJson = $env:CLAUDE_USER_JSON_PATH }
        elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $claudeJson = Join-Path $env:USERPROFILE '.claude.json' }
    }
    if (-not [string]::IsNullOrWhiteSpace($normalizedRoot) -and -not [string]::IsNullOrWhiteSpace($claudeJson)) {
        $doc = Read-McpDisableJsonFile -Path $claudeJson
        if ($doc -is [System.Collections.IDictionary] -and $doc.ContainsKey('projects') -and $doc['projects'] -is [System.Collections.IDictionary]) {
            foreach ($key in $doc['projects'].Keys) {
                $keyText = [string]$key
                try {
                    if (-not [System.IO.Path]::IsPathRooted($keyText)) { continue }
                    if (-not [string]::Equals((Normalize-Path $keyText), $normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                }
                catch { continue }
                $proj = $doc['projects'][$key]
                if ($proj -isnot [System.Collections.IDictionary]) { continue }
                if ($proj.ContainsKey('disabledMcpServers') -and $null -ne $proj['disabledMcpServers'] -and $proj['disabledMcpServers'] -isnot [string]) {
                    foreach ($entry in @($proj['disabledMcpServers'])) {
                        $name = [string]$entry
                        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$disabled.Add($name.Trim()) }
                    }
                }
                if ($proj.ContainsKey('mcpServers') -and $proj['mcpServers'] -is [System.Collections.IDictionary]) {
                    foreach ($serverKey in $proj['mcpServers'].Keys) {
                        $srv = $proj['mcpServers'][$serverKey]
                        if ($srv -is [System.Collections.IDictionary] -and $srv.ContainsKey('enabled') -and ($srv['enabled'] -is [bool]) -and (-not $srv['enabled'])) {
                            $name = [string]$serverKey
                            if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$disabled.Add($name.Trim()) }
                        }
                    }
                }
            }
        }
    }

    # Layer 2 & 3: settings files (user -> project -> project-local, later wins for enabledPlugins).
    $files = @()
    if ($null -ne $SettingsPaths -and $SettingsPaths.Count -gt 0) {
        $files = @($SettingsPaths)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_SETTINGS_FILES)) {
        $files = @($env:CLAUDE_SETTINGS_FILES -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    else {
        $list = New-Object 'System.Collections.Generic.List[string]'
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            [void]$list.Add((Join-Path $env:USERPROFILE '.claude\settings.json'))
        }
        if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
            [void]$list.Add((Join-Path $ProjectRoot '.claude\settings.json'))
            [void]$list.Add((Join-Path $ProjectRoot '.claude\settings.local.json'))
        }
        $files = @($list.ToArray())
    }

    $pluginState = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($settingsFile in $files) {
        $sdoc = Read-McpDisableJsonFile -Path ([string]$settingsFile)
        if ($sdoc -isnot [System.Collections.IDictionary]) { continue }

        if ($sdoc.ContainsKey('deniedMcpServers') -and $null -ne $sdoc['deniedMcpServers'] -and $sdoc['deniedMcpServers'] -isnot [string]) {
            foreach ($denied in @($sdoc['deniedMcpServers'])) {
                if ($denied -is [System.Collections.IDictionary] -and $denied.ContainsKey('serverName')) {
                    $sn = [string]$denied['serverName']
                    if (-not [string]::IsNullOrWhiteSpace($sn)) { [void]$disabled.Add($sn.Trim()) }
                }
                elseif ($denied -is [string] -and -not [string]::IsNullOrWhiteSpace($denied)) {
                    [void]$disabled.Add($denied.Trim())
                }
            }
        }

        if ($sdoc.ContainsKey('permissions') -and $sdoc['permissions'] -is [System.Collections.IDictionary]) {
            $perms = $sdoc['permissions']
            if ($perms.ContainsKey('deny') -and $null -ne $perms['deny'] -and $perms['deny'] -isnot [string]) {
                foreach ($rule in @($perms['deny'])) {
                    $ruleText = [string]$rule
                    if ($ruleText -match '(?i)^mcp__([^_][^:]*)__\*$') {
                        [void]$disabled.Add($Matches[1].Trim())
                    }
                }
            }
        }

        if ($sdoc.ContainsKey('enabledPlugins') -and $sdoc['enabledPlugins'] -is [System.Collections.IDictionary]) {
            foreach ($pk in $sdoc['enabledPlugins'].Keys) {
                $val = $sdoc['enabledPlugins'][$pk]
                if ($val -is [bool]) {
                    $pluginState[[string]$pk] = [bool]$val
                }
            }
        }
    }

    foreach ($pk in $script:PluginMcpConnectorMap.Keys) {
        if ($pluginState.ContainsKey($pk) -and (-not $pluginState[$pk])) {
            foreach ($conn in @($script:PluginMcpConnectorMap[$pk])) {
                if (-not [string]::IsNullOrWhiteSpace([string]$conn)) {
                    [void]$disabled.Add(([string]$conn).Trim())
                }
            }
        }
    }

    return ,$disabled
}

function Test-McpServerDisabled {
    param($DisabledSet, [string]$Name)
    if ($null -eq $DisabledSet -or [string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($DisabledSet -is [System.Collections.Generic.HashSet[string]]) {
        return $DisabledSet.Contains($Name.Trim())
    }
    foreach ($item in @($DisabledSet)) {
        if ([string]::Equals([string]$item, $Name.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
