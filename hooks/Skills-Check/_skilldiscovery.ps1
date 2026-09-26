# Per-skill discovery for Skills-Check, on the client that is actually running.
#
# THE DEFECT THIS EXISTS FOR. The index used to glob
# <cache>\<marketplace>\<plugin>\<version>\skills\* and nothing else. That walk
# read plugins that were no longer installed and every stale cached version,
# counted a category folder (skills\engineering) as one skill, and never saw a
# plugin that declares its skills elsewhere (a "skills" field in plugin.json) or
# ships ONE skill at its root - which is how the Kiaro template and scientific
# plugins are built. An agent sees SKILLS, not plugins, so a routing hint that
# names only packages cannot say what to invoke.
#
# What is read, per client (never both, never the other client's paths):
#   Claude  installed_plugins.json records (user scope and this project's
#           scope), each plugin's .claude-plugin\plugin.json "skills" field
#           (absent -> skills\, a string, or an array of folders), a root
#           SKILL.md, enabledPlugins from the settings files (later wins; no
#           entry = enabled, the documented defaultEnabled default), and the
#           Desktop skills-plugin roots with their manifest "enabled" flag.
#   Codex   [plugins."name@market"] tables in config.toml at the newest cached
#           version, manifests plugin.json > .codex-plugin > .claude-plugin,
#           the Codex skills folder (incl. .system) and SharedAgentSkills\skills,
#           and [[skills.config]] entries that disable a SKILL.md.
# The user-level ~\.claude\skills and ~\.agents\skills folders stay with the
# live project/global enumeration in Skills-Check.ps1.
#
# Read-only and bounded. Nothing here copies, installs, enables or edits a
# skill. Anything unreadable, malformed or over a ceiling is recorded as a
# PARTIAL reason so the output can never present a truncated scan as complete.
#
# Reads from the caller: $config, $client, $homeDir, $cwd (Skills-Check.ps1),
# and Get-SkillIdentity (_skillindex.ps1), which must be loaded first.

$script:DiscoveryMaxSkills = 1200
$script:DiscoveryMaxJsonBytes = 4194304

function Get-DiscoverySetting {
    param([string]$Key, [string]$Default)
    if ($config.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$config[$Key])) { return [string]$config[$Key] }
    return $Default
}

# Every location discovery reads, resolved once. Overridable in .env so the
# test suite never reads the real machine and an unusual install can be pointed at.
function New-SkillDiscoveryConfig {
    $claudeDir = Join-Path $homeDir '.claude'
    $codexHome = Get-DiscoverySetting 'CODEX_HOME_DIR' ([string]$env:CODEX_HOME)
    if ([string]::IsNullOrWhiteSpace($codexHome)) { $codexHome = Join-Path $homeDir '.codex' }
    # SharedAgentSkills sits beside the REAL Codex home; ~\.codex is often a
    # link to it, so the link target (not the link's parent) decides.
    $sharedDefault = ''
    try {
        $homeItem = Get-Item -LiteralPath $codexHome -Force -ErrorAction Stop
        $realHome = $homeItem.FullName
        if (($homeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $null -ne $homeItem.PSObject.Properties['Target'] -and @($homeItem.Target).Count -gt 0) {
            $realHome = [string]@($homeItem.Target)[0]
        }
        $sharedDefault = Join-Path (Join-Path (Split-Path -Parent $realHome) 'SharedAgentSkills') 'skills'
    }
    catch { $sharedDefault = '' }
    $settings = Get-DiscoverySetting 'CLAUDE_SETTINGS_FILES' ((Join-Path $claudeDir 'settings.json') + ';' + (Join-Path $cwd '.claude\settings.json') + ';' + (Join-Path $cwd '.claude\settings.local.json'))
    return [pscustomobject]@{
        Client          = $client
        PluginsFile     = Get-DiscoverySetting 'CLAUDE_PLUGINS_FILE' (Join-Path $claudeDir 'plugins\installed_plugins.json')
        SettingsFiles   = @($settings.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        DesktopRoot     = Get-DiscoverySetting 'CLAUDE_DESKTOP_SKILLS_ROOT' $(if ($env:APPDATA) { Join-Path $env:APPDATA 'Claude\local-agent-mode-sessions\skills-plugin' } else { '' })
        CodexHome       = $codexHome
        CodexConfig     = Join-Path $codexHome 'config.toml'
        CodexSharedDir  = Get-DiscoverySetting 'CODEX_SHARED_SKILLS_DIR' $sharedDefault
    }
}

# Cheap change detector: length + write time of every record file. Folded into
# the index key, so installing, removing or toggling a plugin rebuilds the
# index at once instead of waiting out the TTL.
function Get-SkillSourceStamp {
    param($Discovery)
    $files = if ($Discovery.Client -eq 'codex') { @($Discovery.CodexConfig) } else { @($Discovery.PluginsFile) + @($Discovery.SettingsFiles) }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        try {
            $i = Get-Item -LiteralPath $f -ErrorAction Stop
            [void]$parts.Add($f + '=' + $i.Length + '@' + $i.LastWriteTimeUtc.Ticks)
        }
        catch { [void]$parts.Add($f + '=absent') }
    }
    foreach ($d in @($Discovery.DesktopRoot, $Discovery.CodexSharedDir)) {
        if (-not [string]::IsNullOrWhiteSpace($d) -and (Test-Path -LiteralPath $d -PathType Container)) {
            [void]$parts.Add($d + '@' + (Get-Item -LiteralPath $d).LastWriteTimeUtc.Ticks)
        }
    }
    return ($parts.ToArray() -join '|')
}

function Read-DiscoveryJson {
    param([string]$Path, $Partial, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt $script:DiscoveryMaxJsonBytes) { [void]$Partial.Add($Label + ' too large to read'); return $null }
        return (Read-JsonFile -Path $Path)
    }
    catch { [void]$Partial.Add($Label + ' unreadable'); return $null }
}

# A plain function, not a scriptblock: the package's static-safety check forbids
# every call operator on a variable, so nothing here can execute data.
function Add-UniqueFolder {
    param($List, [string]$Path)
    if (-not $List.Contains($Path)) { [void]$List.Add($Path) }
}

# The skill folders one plugin exposes, exactly as the documented loader scans
# them: a folder holding SKILL.md is a skill; any other folder is a directory
# of <name>\SKILL.md folders, one level deep. A category folder (mattpocock's
# skills\engineering) is NOT searched below that level - the loader does not,
# so only the folders the manifest declares from inside it are skills.
function Get-PluginSkillFolders {
    param([string]$Root, $Declared, $Partial, [string]$Label)
    $found = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath (Join-Path $Root 'SKILL.md') -PathType Leaf) { Add-UniqueFolder $found $Root }
    $dirs = New-Object System.Collections.Generic.List[string]
    [void]$dirs.Add((Join-Path $Root 'skills'))
    foreach ($entry in @($Declared)) {
        if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) { continue }
        $full = [IO.Path]::GetFullPath((Join-Path $Root $entry))
        # A declared path may not leave the plugin: the documented loader
        # rejects it, so counting it would invent a skill the client never loads.
        if (-not (Test-PathInside -Candidate $full -Parent $Root)) { [void]$Partial.Add($Label + ' declares a path outside the plugin'); continue }
        [void]$dirs.Add($full)
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        if (Test-Path -LiteralPath (Join-Path $dir 'SKILL.md') -PathType Leaf) { Add-UniqueFolder $found ((Get-Item -LiteralPath $dir).FullName); continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md') -PathType Leaf) { Add-UniqueFolder $found $child.FullName }
        }
    }
    return @($found.ToArray())
}

function Get-ManifestSkillsField {
    param([string]$Root, [string[]]$Candidates, $Partial, [string]$Label)
    foreach ($rel in $Candidates) {
        $path = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $doc = Read-DiscoveryJson -Path $path -Partial $Partial -Label ($Label + ' manifest')
        if ($null -eq $doc) { return @() }
        if ($null -eq $doc.PSObject.Properties['skills']) { return @() }
        return @($doc.skills)
    }
    return @()
}

function New-DiscoveredSkill {
    param([string]$Plugin, [string]$Folder, [string]$Source, [string]$Version, [bool]$Enabled, [string]$Client, [bool]$ExplicitHint = $false)
    $identity = Get-SkillIdentity (Join-Path $Folder 'SKILL.md')
    $name = if ([string]::IsNullOrWhiteSpace($identity.Name)) { Split-Path -Leaf $Folder } else { $identity.Name }
    # Each client has its OWN "only when the user names it" switch: Claude reads
    # disable-model-invocation from the frontmatter, Codex reads
    # agents\openai.yaml. Neither honours the other's, so neither is borrowed.
    $explicit = $ExplicitHint -or ($Client -ne 'codex' -and $identity.Explicit)
    $yaml = Join-Path $Folder 'agents\openai.yaml'
    if ($Client -eq 'codex' -and -not $explicit -and (Test-Path -LiteralPath $yaml -PathType Leaf)) {
        try { $explicit = ([IO.File]::ReadAllText($yaml) -match '(?im)^[ \t]*allow_implicit_invocation[ \t]*:[ \t]*false\b') } catch { }
    }
    # Claude addresses a plugin skill as <plugin>:<name> with spaces as hyphens
    # (the Desktop surface as anthropic-skills:<name>); Codex resolves the bare name.
    $invocation = if ($Client -eq 'codex' -or [string]::IsNullOrWhiteSpace($Plugin)) { $name } else { $Plugin + ':' + ($name -replace '\s+', '-') }
    return [pscustomobject]@{
        Plugin = $Plugin; Leaf = (Split-Path -Leaf $Folder); Name = $name; Description = $identity.Description; Path = $Folder
        Source = $Source; Version = $Version; Status = $(if ($Enabled) { 'enabled' } else { 'disabled' })
        Explicit = $(if ($explicit) { '1' } else { '0' }); Invocation = $invocation
    }
}

function ConvertTo-DiscoveryTicks {
    param($Value)
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().Ticks }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed.ToUniversalTime().Ticks }
    return 0L
}

function Get-ClaudeDiscovery {
    param($Discovery, $Result)
    $records = Read-DiscoveryJson -Path $Discovery.PluginsFile -Partial $Result.Partial -Label 'installed_plugins.json'
    if ($null -ne $records -and $null -ne $records.PSObject.Properties['plugins']) {
        $Result.InstallKnown = $true
        $enabled = @{}
        foreach ($settingsFile in $Discovery.SettingsFiles) {
            $s = Read-DiscoveryJson -Path $settingsFile -Partial $Result.Partial -Label 'settings file'
            if ($null -eq $s -or $null -eq $s.PSObject.Properties['enabledPlugins']) { continue }
            foreach ($p in $s.enabledPlugins.PSObject.Properties) { $enabled[$p.Name] = [bool]$p.Value }
        }
        $cwdFull = Normalize-Path $cwd
        foreach ($prop in $records.plugins.PSObject.Properties) {
            [void]$Result.InstallKeys.Add($prop.Name)
            $best = $null; $bestTicks = -1L
            foreach ($rec in @($prop.Value)) {
                $scope = [string](Get-Field $rec 'scope'); $projectPath = [string](Get-Field $rec 'projectPath')
                if ($scope -ne 'user' -and ([string]::IsNullOrWhiteSpace($projectPath) -or (Normalize-Path $projectPath) -ne $cwdFull)) { continue }
                $ticks = ConvertTo-DiscoveryTicks (Get-Field $rec 'lastUpdated')
                if ($ticks -gt $bestTicks) { $best = $rec; $bestTicks = $ticks }
            }
            if ($null -eq $best) { continue }
            $root = [string](Get-Field $best 'installPath')
            if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { [void]$Result.Partial.Add($prop.Name + ' install path missing'); continue }
            $plugin = $prop.Name.Split('@')[0]
            $isEnabled = -not ($enabled.ContainsKey($prop.Name) -and -not $enabled[$prop.Name])
            $declared = Get-ManifestSkillsField -Root $root -Candidates @('.claude-plugin\plugin.json') -Partial $Result.Partial -Label $prop.Name
            foreach ($folder in (Get-PluginSkillFolders -Root $root -Declared $declared -Partial $Result.Partial -Label $prop.Name)) {
                Add-DiscoveredSkill $Result (New-DiscoveredSkill -Plugin $plugin -Folder $folder -Source 'claude-plugin' -Version ([string](Get-Field $best 'version')) -Enabled $isEnabled -Client 'claude')
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Discovery.PluginsFile) -and -not (Test-Path -LiteralPath $Discovery.PluginsFile)) { $Result.InstallKnown = $false }
    if (-not [string]::IsNullOrWhiteSpace($Discovery.DesktopRoot) -and (Test-Path -LiteralPath $Discovery.DesktopRoot -PathType Container)) {
        foreach ($skillsDir in @(Get-ChildItem -Path (Join-Path $Discovery.DesktopRoot '*\*\skills') -Directory -ErrorAction SilentlyContinue | Select-Object -First 4)) {
            $flags = @{}
            $manifest = Read-DiscoveryJson -Path (Join-Path (Split-Path -Parent $skillsDir.FullName) 'manifest.json') -Partial $Result.Partial -Label 'Desktop manifest'
            if ($null -ne $manifest -and $null -ne $manifest.PSObject.Properties['skills']) {
                foreach ($m in @($manifest.skills)) { $flags[[string](Get-Field $m 'name')] = ((Get-Field $m 'enabled') -ne $false) }
            }
            foreach ($d in @(Get-ChildItem -LiteralPath $skillsDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $skill = New-DiscoveredSkill -Plugin 'anthropic-skills' -Folder $d.FullName -Source 'claude-desktop' -Version '' -Enabled $true -Client 'claude'
                if ($flags.ContainsKey($skill.Name) -and -not $flags[$skill.Name]) { $skill.Status = 'disabled' }
                Add-DiscoveredSkill $Result $skill
            }
        }
    }
}

# A bounded line scan of the two TOML table shapes Codex writes for this. A
# library would be exact, but none ships with Windows PowerShell and a hook
# must not install one; anything this scan cannot read is reported as partial.
function Read-CodexConfig {
    param([string]$Path, $Partial)
    $answer = [pscustomobject]@{ Known = $false; Plugins = [ordered]@{}; DisabledSkills = @{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $answer }
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt $script:DiscoveryMaxJsonBytes) { [void]$Partial.Add('config.toml too large to read'); return $answer }
        $lines = [IO.File]::ReadAllLines($Path)
    }
    catch { [void]$Partial.Add('config.toml unreadable'); return $answer }
    $answer.Known = $true
    $section = ''; $key = ''; $skillPath = ''
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -match '^\[plugins\.["'']([^"'']+)["'']\]$') { $section = 'plugin'; $key = $Matches[1]; $answer.Plugins[$key] = $true; continue }
        if ($line -eq '[[skills.config]]') { $section = 'skill'; $skillPath = ''; continue }
        if ($line.StartsWith('[')) { $section = ''; continue }
        if ($section -eq 'plugin' -and $line -match '^enabled\s*=\s*(true|false)\b') { $answer.Plugins[$key] = ($Matches[1] -eq 'true') }
        elseif ($section -eq 'skill' -and $line -match '^path\s*=\s*["''](.+)["'']') { $skillPath = $Matches[1].Replace('\\', '\') }
        elseif ($section -eq 'skill' -and $line -match '^enabled\s*=\s*false\b' -and $skillPath -ne '') {
            try { $answer.DisabledSkills[(Normalize-Path (Split-Path -Parent $skillPath)).ToLowerInvariant()] = $true } catch { }
        }
    }
    return $answer
}

function Get-CodexDiscovery {
    param($Discovery, $Result)
    $cfg = Read-CodexConfig -Path $Discovery.CodexConfig -Partial $Result.Partial
    $Result.InstallKnown = $cfg.Known
    foreach ($key in $cfg.Plugins.Keys) {
        [void]$Result.InstallKeys.Add($key)
        $parts = $key.Split('@')
        if ($parts.Count -ne 2) { continue }
        $pluginDir = Join-Path $Discovery.CodexHome ('plugins\cache\' + $parts[1] + '\' + $parts[0])
        $versions = @(Get-ChildItem -LiteralPath $pluginDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        if ($versions.Count -eq 0) { continue }
        # ponytail: newest write time picks the "current" version; Codex keeps no
        # pointer to it on disk here. Several candidates are reported, not hidden.
        if ($versions.Count -gt 1) { [void]$Result.Partial.Add($key + ' has ' + $versions.Count + ' cached versions; newest used') }
        $root = $versions[0].FullName
        $declared = Get-ManifestSkillsField -Root $root -Candidates @('plugin.json', '.codex-plugin\plugin.json', '.claude-plugin\plugin.json') -Partial $Result.Partial -Label $key
        foreach ($folder in (Get-PluginSkillFolders -Root $root -Declared $declared -Partial $Result.Partial -Label $key)) {
            Add-DiscoveredSkill $Result (New-DiscoveredSkill -Plugin $parts[0] -Folder $folder -Source 'codex-plugin' -Version $versions[0].Name -Enabled ([bool]$cfg.Plugins[$key]) -Client 'codex')
        }
    }
    foreach ($src in @(@{ Dir = (Join-Path $Discovery.CodexHome 'skills'); Source = 'codex-skills'; Depth = 2 }, @{ Dir = $Discovery.CodexSharedDir; Source = 'codex-shared'; Depth = 1 })) {
        if ([string]::IsNullOrWhiteSpace($src.Dir) -or -not (Test-Path -LiteralPath $src.Dir -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $src.Dir -Recurse -Depth $src.Depth -Filter 'SKILL.md' -File -Force -ErrorAction SilentlyContinue)) {
            $folder = Split-Path -Parent $f.FullName
            $on = -not $cfg.DisabledSkills.ContainsKey((Normalize-Path $folder).ToLowerInvariant())
            Add-DiscoveredSkill $Result (New-DiscoveredSkill -Plugin '' -Folder $folder -Source $src.Source -Version '' -Enabled $on -Client 'codex')
        }
    }
}

function Add-DiscoveredSkill {
    param($Result, $Skill)
    if ($Result.Skills.Count -ge $script:DiscoveryMaxSkills) {
        if (-not $Result.Partial.Contains('skill ceiling reached')) { [void]$Result.Partial.Add('skill ceiling reached') }
        return
    }
    [void]$Result.Skills.Add($Skill)
}

function Invoke-SkillDiscovery {
    param($Discovery)
    $result = [pscustomobject]@{
        Skills = (New-Object System.Collections.Generic.List[object]); Partial = (New-Object System.Collections.Generic.List[string])
        InstallKeys = (New-Object System.Collections.Generic.List[string]); InstallKnown = $false
    }
    try {
        if ($Discovery.Client -eq 'codex') { Get-CodexDiscovery -Discovery $Discovery -Result $result }
        else { Get-ClaudeDiscovery -Discovery $Discovery -Result $result }
    }
    catch { [void]$result.Partial.Add('discovery stopped early: ' + $_.Exception.Message) }
    return $result
}
