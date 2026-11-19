# Mcp-Usage-Check - connector use triggers (steering V94, order 105).
# Dot-sourced; definitions only, no exit.
#
# global-mcp-server-contracts.md "Connector use triggers": every installed
# connector that fits the job is the FIRST route, and an unused fitting
# connector is a violation. The hook cannot see which connectors a client has
# exposed, so it names the conventional route per prompt class in ONE line and
# never lists the whole inventory. Order matters: the first two matches win.
# Matching is on the user's prompt text only; tool calls are matched later as
# JSONL tool-call records, never as prose mentions.

$script:ConnectorTriggers = @(
    @{ Key = 'video';    Route = 'video file -> rea-video:rea-video skill, then rea-video decompose (not ffmpeg first)'
       Pattern = '(?i)(\.(mp4|mkv|mov|avi|webm|m4v)\b|\bvideos?\b|\bclip\b|\u0648\u06cc\u062f\u06cc\u0648|\u0648\u06cc\u062f\u0626\u0648|\u0641\u06cc\u0644\u0645)' }
    @{ Key = 'page';     Route = 'page debugging/perf/a11y -> chrome-devtools before Playwright'
       Pattern = '(?i)\b(console errors?|devtools|lighthouse|core web vitals|a11y|accessibility audit|page (?:perf|performance|load|debug\w*)|network tab)\b' }
    @{ Key = 'web';      Route = 'URL/web page -> Scrapling-Server + skill anthropic-skills:scrapling-official'
       Pattern = '(?i)(https?://|\bwww\.|\b(web ?page|website|scrape|scraping|crawl\w*)\b)' }
    @{ Key = 'dep';      Route = 'dependency/package change -> Snyk (snyk_package_health_check, SCA)'
       Pattern = '(?i)\b(add|install|upgrade|bump|update|remove|pin)\b[^.\n]{0,40}\b(dependenc\w*|package|crate|npm|pip|nuget|library)\b' }
    @{ Key = 'security'; Route = 'security code -> Semgrep'
       Pattern = '(?i)\b(vulnerab\w*|security|injection|xss|csrf|ssrf|authentication|authorization|sanitiz\w*)\b' }
    @{ Key = 'library';  Route = 'library/API docs -> Context7'
       Pattern = '(?i)\b(library|framework|sdk|api)\b' }
    @{ Key = 'memory';   Route = 'what you prefer / did we -> Synapse memory_retrieve'
       Pattern = '(?i)(\bdo (?:i|we) prefer\b|\bdid we\b|\bwhat do i (?:like|prefer|use)\b|\blast time\b|\bremember\b)' }
    @{ Key = 'desktop';  Route = 'Windows app control -> Vercel-Labs-Agent-Desktop'
       Pattern = '(?i)\b(desktop app|windows app|click (?:the|on) (?:button|menu)|open (?:the )?app|notepad|explorer\.exe|ui automation)\b' }
    @{ Key = 'code';     Route = 'code question -> Codebase-Memory-mcp'
       Pattern = '(?i)\b(where is \w+ (?:defined|used|called)|who calls|call(?:er|ee)s of|call graph|codebase|how does (?:the )?\w+ (?:function|class|module|method) work)\b' }
)

# One line, or '' when no class fits. At most two routes, named by class.
function Get-ConnectorTriggerLine {
    param([AllowEmptyString()][string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return '' }
    $routes = New-Object System.Collections.Generic.List[string]
    foreach ($t in $script:ConnectorTriggers) {
        if ($Prompt -match $t.Pattern) { [void]$routes.Add($t.Route) }
        if ($routes.Count -ge 2) { break }
    }
    if ($routes.Count -eq 0) { return '' }
    return ('CONNECTORS first: ' + ($routes -join '; ') + '.')
}

# Classes matched, for the Stop half: comma list of keys, '' when none.
function Get-ConnectorTriggerKeys {
    param([AllowEmptyString()][string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return '' }
    $keys = @($script:ConnectorTriggers | Where-Object { $Prompt -match $_.Pattern } | ForEach-Object { $_.Key })
    return ($keys -join ',')
}

# Tool-call records only (the client's own "name": "<tool>" field).
$script:ScraplingCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__Scrapling[-_]?Server__'
$script:ScraplingSkillPattern = '(?i)("skill"[ \t]*:[ \t]*"[A-Za-z0-9_.\-]*:?scrapling-official"|"file_path"[ \t]*:[ \t]*"[^"]*scrapling-official[^"]*SKILL\.md")'
$script:PlaywrightCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__(?:plugin_[A-Za-z0-9_.\-]*_)?playwright__'
$script:DevtoolsCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__[A-Za-z0-9_.\-]*chrome[-_]?devtools[A-Za-z0-9_.\-]*__'
$script:ReaVideoCallPattern = '(?i)"command"[ \t]*:[ \t]*"[^"]*\brea-video(?:\.exe)?\b[^"]*"'

# Pairing / ordering advisories (order 105 steps 1c, 1d, 4b). '' or lines.
function Get-ConnectorPairingNotes {
    param([AllowEmptyString()][string]$RawText)
    $notes = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($RawText)) { return @() }
    $scr = [regex]::Match($RawText, $script:ScraplingCallPattern)
    if ($scr.Success) {
        $skill = [regex]::Match($RawText, $script:ScraplingSkillPattern)
        if (-not ($skill.Success -and $skill.Index -lt $scr.Index)) {
            [void]$notes.Add('SCRAPLING: called before skill anthropic-skills:scrapling-official; load it first.')
        }
    }
    $pw = [regex]::Match($RawText, $script:PlaywrightCallPattern)
    if ($pw.Success -and -not [regex]::IsMatch($RawText, $script:DevtoolsCallPattern)) {
        [void]$notes.Add('PLAYWRIGHT: no chrome-devtools call; devtools first, else state why.')
    }
    if ([regex]::IsMatch($RawText, $script:ReaVideoCallPattern) -and $env:PYTHONIOENCODING -notmatch '(?i)^utf-?8') {
        [void]$notes.Add('REA-VIDEO: shell lacks PYTHONIOENCODING=utf-8; set it or restart.')
    }
    return @($notes)
}
