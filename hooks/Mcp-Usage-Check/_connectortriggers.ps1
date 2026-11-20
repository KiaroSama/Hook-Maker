# Mcp-Usage-Check - connector use triggers (steering V94-V95, orders 105 & 107).
# Dot-sourced; definitions only, no exit.
#
# global-mcp-server-contracts.md "Connector use triggers": every installed
# connector that fits the job is the FIRST route, and an unused fitting
# connector is a violation. The hook cannot see which connectors a client has
# exposed, so it names the conventional route per prompt class in ONE line and
# never lists the whole inventory. Order matters: the first two matches win.
# Matching is on the user's prompt text only; tool calls are matched later as
# JSONL tool-call records, never as prose mentions.

$script:FaRustPortPattern = '(?:' +
    (-join [char[]]@(0x0628,0x0627,0x0632,0x0646,0x0648,0x06CC,0x0633,0x06CC)) + '|' +
    (-join [char[]]@(0x067E,0x0648,0x0631,0x062A)) + '|' +
    (-join [char[]]@(0x062A,0x0628,0x062F,0x06CC,0x0644)) + '|' +
    (-join [char[]]@(0x0645,0x0647,0x0627,0x062C,0x0631,0x062A)) + '|' +
    (-join [char[]]@(0x0634,0x062A,0x0627,0x0628)) +
    ')[^\r\n]{0,80}' + (-join [char[]]@(0x0628,0x0647)) + '[ \t]+(?:' +
    (-join [char[]]@(0x0631,0x0627,0x0633,0x062A)) + '|rust\b)'

$script:ConnectorTriggers = @(
    @{ Key = 'rust-anything'; Connector = 'rust-anything'; Route = 'Rust port/rewrite -> rust-anything MCP + skill rust-anything:rust-anything (whole-app.md for full apps)'
       Pattern = ('(?i)(\brust-anything\b|\b(?:port\w*|rewrit\w*|migrat\w*|convert\w*|translat\w*|accelerat\w*|speed[ \t]+up)\b[^\r\n]{0,80}\b(?:to|in|into)[ \t]+rust\b|\brust[ \t]+(?:port|rewrite|migration)\b|' + $script:FaRustPortPattern + ')') }
    @{ Key = 'video'; Connector = ''; Route = 'video file -> rea-video:rea-video skill, then rea-video decompose (not ffmpeg first)'
       Pattern = '(?i)(\.(mp4|mkv|mov|avi|webm|m4v)\b|\bvideos?\b|\bclip\b|\u0648\u06cc\u062f\u06cc\u0648|\u0648\u06cc\u062f\u0626\u0648|\u0641\u06cc\u0644\u0645)' }
    @{ Key = 'cloudflare'; Connector = 'cloudflare'; Route = 'Cloudflare platform/Workers -> cloudflare MCP + matching cloudflare:* skill (cloudflare:turnstile-spin for Turnstile)'
       Pattern = '(?i)\b(cloudflare(?:\s+(?:workers?|dns|pages|api|zero\s+trust|d1|kv|r2))?|wrangler|durable\s+objects?|turnstile|zero\s+trust|d1\s+(?:db|database|migration|query|binding)|kv\s+(?:namespace|store|binding)|r2\s+(?:bucket|object|binding))\b' }
    @{ Key = 'page'; Connector = 'chrome-devtools'; Route = 'page debugging/perf/a11y -> chrome-devtools before Playwright'
       Pattern = '(?i)\b(console errors?|devtools|lighthouse|core web vitals|a11y|accessibility audit|page (?:perf|performance|load|debug\w*)|network tab)\b' }
    @{ Key = 'web'; Connector = 'Scrapling-Server'; Route = 'URL/web page -> Scrapling-Server + skill anthropic-skills:scrapling-official'
       Pattern = '(?i)(https?://|\bwww\.|\b(web ?page|website|scrape|scraping|crawl\w*)\b)' }
    @{ Key = 'dep'; Connector = 'Snyk'; Route = 'dependency/package change -> Snyk (snyk_package_health_check, SCA)'
       Pattern = '(?i)\b(add|install|upgrade|bump|update|remove|pin)\b[^.\n]{0,40}\b(dependenc\w*|package|crate|npm|pip|nuget|library)\b' }
    @{ Key = 'security'; Connector = 'Semgrep'; Route = 'security code -> Semgrep'
       Pattern = '(?i)\b(vulnerab\w*|security|injection|xss|csrf|ssrf|authentication|authorization|sanitiz\w*)\b' }
    @{ Key = 'library'; Connector = 'Context7'; Route = 'library/API docs -> Context7'
       Pattern = '(?i)\b(library|framework|sdk|api)\b' }
    @{ Key = 'memory'; Connector = 'Synapse'; Route = 'what you prefer / did we -> Synapse memory_retrieve'
       Pattern = '(?i)(\bdo (?:i|we) prefer\b|\bdid we\b|\bwhat do i (?:like|prefer|use)\b|\blast time\b|\bremember\b)' }
    @{ Key = 'desktop'; Connector = 'Vercel-Labs-Agent-Desktop'; Route = 'Windows app control -> Vercel-Labs-Agent-Desktop'
       Pattern = '(?i)\b(desktop app|windows app|click (?:the|on) (?:button|menu)|open (?:the )?app|notepad|explorer\.exe|ui automation)\b' }
    @{ Key = 'code'; Connector = 'Codebase-Memory-mcp'; Route = 'code question -> Codebase-Memory-mcp'
       Pattern = '(?i)\b(where is \w+ (?:defined|used|called)|who calls|call(?:er|ee)s of|call graph|codebase|how does (?:the )?\w+ (?:function|class|module|method) work)\b' }
)

$script:TriggerConnectorMap = @{}
foreach ($t in $script:ConnectorTriggers) {
    if (-not [string]::IsNullOrWhiteSpace($t.Connector)) { $script:TriggerConnectorMap[$t.Key] = $t.Connector }
}

function Test-TriggerDisabled {
    param($Trigger, $DisabledServers)
    if ($null -eq $DisabledServers -or [string]::IsNullOrWhiteSpace($Trigger.Connector)) { return $false }
    if (Get-Command Test-McpServerDisabled -ErrorAction SilentlyContinue) {
        return (Test-McpServerDisabled -DisabledSet $DisabledServers -Name $Trigger.Connector)
    }
    return $false
}

# One line, or '' when no class fits. At most two routes, named by class.
function Get-ConnectorTriggerLine {
    param([AllowEmptyString()][string]$Prompt, $DisabledServers = $null)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return '' }
    $routes = New-Object System.Collections.Generic.List[string]
    foreach ($t in $script:ConnectorTriggers) {
        if (Test-TriggerDisabled -Trigger $t -DisabledServers $DisabledServers) { continue }
        if ($Prompt -match $t.Pattern) { [void]$routes.Add($t.Route) }
        if ($routes.Count -ge 2) { break }
    }
    if ($routes.Count -eq 0) { return '' }
    return ('CONNECTORS first: ' + ($routes -join '; ') + '.')
}

# Classes matched, for the Stop half: comma list of keys, '' when none.
function Get-ConnectorTriggerKeys {
    param([AllowEmptyString()][string]$Prompt, $DisabledServers = $null)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return '' }
    $keys = @($script:ConnectorTriggers | Where-Object { (-not (Test-TriggerDisabled -Trigger $_ -DisabledServers $DisabledServers)) -and ($Prompt -match $_.Pattern) } | ForEach-Object { $_.Key })
    return ($keys -join ',')
}

# Non-blocking Standing Order 8 advisory when the prompt explicitly names a
# locally disabled MCP connector.
function Get-DisabledConnectorPromptAdvisory {
    param([AllowEmptyString()][string]$Prompt, $DisabledServers = $null)
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $null -eq $DisabledServers) { return '' }
    $named = New-Object System.Collections.Generic.List[string]
    foreach ($srv in @($DisabledServers)) {
        $name = [string]$srv
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $pat = '(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($name) + '(?![A-Za-z0-9_-])'
        if ($Prompt -match $pat) { [void]$named.Add($name) }
    }
    if ($named.Count -eq 0) { return '' }
    $uniq = @($named | Sort-Object -Unique)
    return ('Standing Order 8: connector disabled locally (' + ($uniq -join ', ') + '); ask the user before re-enabling.')
}

# Tool-call records only (the client's own "name": "<tool>" field).
$script:ScraplingCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__Scrapling[-_]?Server__'
$script:ScraplingSkillPattern = '(?i)("skill"[ \t]*:[ \t]*"[A-Za-z0-9_.\-]*:?scrapling-official"|"file_path"[ \t]*:[ \t]*"[^"]*scrapling-official[^"]*SKILL\.md")'
$script:PlaywrightCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__(?:plugin_[A-Za-z0-9_.\-]*_)?playwright__'
$script:DevtoolsCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__[A-Za-z0-9_.\-]*chrome[-_]?devtools[A-Za-z0-9_.\-]*__'
$script:ReaVideoCallPattern = '(?i)"command"[ \t]*:[ \t]*"(?:\\.|[^"\\])*\brea-video(?:\.exe)?\b(?:\\.|[^"\\])*"'
$script:RustAnythingCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__(?:plugin_[A-Za-z0-9_.\-]*_)?rust[-_]?anything__'
$script:RustAnythingSkillPattern = '(?i)("skill"[ \t]*:[ \t]*"[A-Za-z0-9_.\-]*:?rust-anything"|"file_path"[ \t]*:[ \t]*"(?:\\.|[^"\\])*rust-anything(?:\\.|[^"\\])*(?:SKILL|whole-app)\.md")'
$script:RustAnythingCliPattern = '(?i)"command"[ \t]*:[ \t]*"(?:\\.|[^"\\])*\brust-anything(?:\.exe)?\b(?!(?:\\.|[^"\\])*\b(?:setup|--help|-h)\b)(?:\\.|[^"\\])*"'
$script:CloudflareCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__(?:plugin_cloudflare_cloudflare|cloudflare)__'
$script:CloudflareSkillPattern = '(?i)("skill"[ \t]*:[ \t]*"cloudflare:[A-Za-z0-9_.\-]+"|"file_path"[ \t]*:[ \t]*"(?:\\.|[^"\\])*cloudflare(?:\\.|[^"\\])*SKILL\.md")'

$script:NoteScrapling = 'SCRAPLING: called before skill anthropic-skills:scrapling-official; load it first.'
$script:NotePlaywright = 'PLAYWRIGHT: no chrome-devtools call; devtools first, else state why.'
$script:NoteReaVideo = 'REA-VIDEO: shell lacks PYTHONIOENCODING=utf-8; set it or restart.'
$script:NoteRustAnything = 'RUST-ANYTHING: called before skill rust-anything:rust-anything; load it (whole-app.md for full apps) first.'
$script:NoteCloudflare = 'CLOUDFLARE: called before matching cloudflare:* skill; load it first (cloudflare:turnstile-spin for Turnstile).'

# Pairing / ordering advisories (orders 105 & 107). '' or lines.
function Get-ConnectorPairingNotes {
    param([AllowEmptyString()][string]$RawText)
    $notes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($RawText)) { return @() }
    $scr = [regex]::Match($RawText, $script:ScraplingCallPattern)
    if ($scr.Success) {
        $skill = [regex]::Match($RawText, $script:ScraplingSkillPattern)
        if (-not ($skill.Success -and $skill.Index -lt $scr.Index)) { [void]$notes.Add($script:NoteScrapling) }
    }
    $pw = [regex]::Match($RawText, $script:PlaywrightCallPattern)
    if ($pw.Success -and -not [regex]::IsMatch($RawText, $script:DevtoolsCallPattern)) { [void]$notes.Add($script:NotePlaywright) }
    $ra = [regex]::Match($RawText, $script:RustAnythingCallPattern)
    if ($ra.Success) {
        $raSkill = [regex]::Match($RawText, $script:RustAnythingSkillPattern)
        if (-not ($raSkill.Success -and $raSkill.Index -lt $ra.Index)) { [void]$notes.Add($script:NoteRustAnything) }
    }
    $cf = [regex]::Match($RawText, $script:CloudflareCallPattern)
    if ($cf.Success) {
        $cfSkill = [regex]::Match($RawText, $script:CloudflareSkillPattern)
        if (-not ($cfSkill.Success -and $cfSkill.Index -lt $cf.Index)) { [void]$notes.Add($script:NoteCloudflare) }
    }
    if ([regex]::IsMatch($RawText, $script:ReaVideoCallPattern) -and $env:PYTHONIOENCODING -notmatch '(?i)^utf-?8') {
        [void]$notes.Add($script:NoteReaVideo)
    }
    return @($notes)
}

# Mid-turn PreToolUse advisories so the model receives guidance before Stop.
function Get-ConnectorPreToolNotes {
    param([string]$ToolName, $ToolInput, [AllowEmptyString()][string]$RawText)
    $notes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($ToolName)) { return @() }
    if ($ToolName -match '(?i)^mcp__Scrapling[-_]?Server__' -and $RawText -notmatch $script:ScraplingSkillPattern) {
        [void]$notes.Add($script:NoteScrapling)
    }
    elseif ($ToolName -match '(?i)^mcp__(?:plugin_[A-Za-z0-9_.\-]*_)?playwright__' -and $RawText -notmatch $script:DevtoolsCallPattern) {
        [void]$notes.Add($script:NotePlaywright)
    }
    elseif ($ToolName -match '(?i)^mcp__(?:plugin_[A-Za-z0-9_.\-]*_)?rust[-_]?anything__' -and $RawText -notmatch $script:RustAnythingSkillPattern) {
        [void]$notes.Add($script:NoteRustAnything)
    }
    elseif ($ToolName -match '(?i)^mcp__(?:plugin_cloudflare_cloudflare|cloudflare)__' -and $RawText -notmatch $script:CloudflareSkillPattern) {
        [void]$notes.Add($script:NoteCloudflare)
    }
    elseif ($ToolName -match '(?i)^(?:mcp__[A-Za-z0-9_.\-]*computer[-_]?use[A-Za-z0-9_.\-]*__[A-Za-z0-9_.\-]+|computer)$' -and
            $RawText -notmatch $script:AgentDesktopPattern -and -not [string]::IsNullOrEmpty($script:DesktopRouteMessage)) {
        [void]$notes.Add($script:DesktopRouteMessage)
    }
    elseif ($ToolName -match '^(Edit|Write|MultiEdit)$') {
        $fp = [string](Get-Field $ToolInput 'file_path')
        if ($fp -ne '' -and $fp -notmatch '(?i)(?:^|[\\/])(?:\.ai|specs|\.specify|\.claude|\.codex|plans|\.ignoreme)(?:[\\/]|$)') {
            if ($fp -match '(?i)\.(md|mdx|txt|rst|html)$' -and $RawText -notmatch '(?i)"skill"[ \t]*:[ \t]*"[A-Za-z0-9_.\-]*:?(?:humanizer|persian|great-russian)"') {
                [void]$notes.Add('VOICE: prose edit before voice skill; load humanizer:humanizer, anthropic-skills:persian, or anthropic-skills:great-russian.')
            }
        }
    }
    return @($notes)
}
