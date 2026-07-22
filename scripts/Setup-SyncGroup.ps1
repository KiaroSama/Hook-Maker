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
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
# Install-state registry + installed-state integrity evaluation (install-time
# only - deliberately NOT in _hooklib.ps1, which ships inside every runtime).
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
. (Join-Path $ScriptRoot 'Setup-SyncGroupBuilder.ps1')
# Installed-hook management (the "Update installed hooks" / "Uninstall
# installed hooks" rows of the hook list) plus the ONE canonical
# numeric list/range parser both this menu and those screens use.
. (Join-Path $ScriptRoot 'Setup-SyncGroupInstalledHooks.ps1')
# Hook-status discovery wizard (the "Get hook status" row): the scan prompts and the
# grouped result screen. The scan itself lives in Get-HookStatus.ps1.
. (Join-Path $ScriptRoot 'Setup-SyncGroupHookStatus.ps1')
# Guided hook creation: the five starter hook-body templates, the custom-
# hook target-selection flow, and the Invoke-CreateHook stage machine.
. (Join-Path $ScriptRoot 'Setup-SyncGroupCreateHook.ps1')
$UninstallScript = Join-Path $ScriptRoot 'Uninstall-Hook.ps1'
$StatusScript = Join-Path $ScriptRoot 'Get-HookStatus.ps1'
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
    # Distinct hues for the two ACTION tags so they never read as a timing tag:
    # [all] (Orchid) must not be mistaken for [pre-task] (Mint), and [manage]
    # (Teal) must not be mistaken for [post-task] (Amber). Keep the five tag
    # colours in five different hues - Mint(green)/Amber(orange)/Aqua(cyan)/
    # Orchid(magenta)/Teal(teal).
    Orchid     = "$Esc[38;5;171m"
    Teal       = "$Esc[38;5;37m"
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

# Precomputed prompt suffixes - the two specs never vary, so colorize each once
# instead of splitting + regex-matching a spec string on every prompt render.
# Full: normal prompts (back one step + quit). Quit-only: the main menu (no back).
$script:BackTextFull = (Get-Painted '{' $C.White) + (Get-Painted 'back=0' $C.BackPrompt) + (Get-Painted ', ' $C.White) + (Get-Painted 'quit=exit' $C.ExitPrompt) + (Get-Painted '}' $C.White)
$script:BackTextQuit = (Get-Painted '{' $C.White) + (Get-Painted 'quit=exit' $C.ExitPrompt) + (Get-Painted '}' $C.White)

# Question prompt: "\nN. Title (hint) [default] {back=0, quit=exit}: " (FFmWiz question_prompt).
$script:QuestionNumber = 0
function New-QuestionPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Details,
        [string]$Default,
        [switch]$QuitOnly   # main menu: show {quit=exit} (there is no step to go back to)
    )

    $script:QuestionNumber++
    $prompt = "`n" + (Get-Painted ($script:QuestionNumber.ToString() + '. ' + $Title) $C.Bold)
    if (-not [string]::IsNullOrEmpty($Details)) {
        $prompt += ' (' + (Get-Painted $Details $C.HintYellow) + ')'
    }
    if (-not [string]::IsNullOrEmpty($Default)) {
        $prompt += ' ' + (Get-Painted ('[' + $Default + ']') $C.Green)
    }
    $suffix = if ($QuitOnly) { $script:BackTextQuit } else { $script:BackTextFull }
    return $prompt + ' ' + $suffix + ': '
}

# Reserves the NEXT top-level question number without rendering a prompt, for a
# caller that is about to ask a repeated CHILD question one or more times (e.g.
# a growing list of project paths). Call this ONCE per entry into the repeated
# flow, then render every repeat with New-NestedQuestionPrompt using that same
# reserved number - this is what keeps "13. Project root path" / "14. Project
# root path" / ... from each stealing a fresh top-level integer.
function Get-ReservedQuestionNumber {
    $script:QuestionNumber++
    return $script:QuestionNumber
}

# Child prompt of a repeated collection: "\nP-C. Title (hint) [default] {...}: "
# (e.g. "12-1. Project root path", "12-2. Project root path", ...). P is the
# number reserved once via Get-ReservedQuestionNumber; C is the caller's own
# slot counter (1-based, advances only on an accepted entry - see Read-ProjectList).
function New-NestedQuestionPrompt {
    param(
        [Parameter(Mandatory = $true)][int]$ParentNumber,
        [Parameter(Mandatory = $true)][int]$ChildNumber,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Details,
        [string]$Default,
        [switch]$QuitOnly
    )

    $label = $ParentNumber.ToString() + '-' + $ChildNumber.ToString()
    $prompt = "`n" + (Get-Painted ($label + '. ' + $Title) $C.Bold)
    if (-not [string]::IsNullOrEmpty($Details)) {
        $prompt += ' (' + (Get-Painted $Details $C.HintYellow) + ')'
    }
    if (-not [string]::IsNullOrEmpty($Default)) {
        $prompt += ' ' + (Get-Painted ('[' + $Default + ']') $C.Green)
    }
    $suffix = if ($QuitOnly) { $script:BackTextQuit } else { $script:BackTextFull }
    return $prompt + ' ' + $suffix + ': '
}

function Get-ExampleText {
    param([Parameter(Mandatory = $true)][string]$Text)
    # Example values keep their own color inside hints (FFmWiz example_text).
    return (Get-Painted $Text $C.LightBlue) + $C.HintYellow
}

# Per-hook menu metadata: display order/name, when it runs (pre / post /
# pre+post), and a one-line description. Unknown/custom hooks sort last and get
# a blank timing/description entry. The sync engine itself
# is excluded here too - Get-HookEntries never returns it (see EngineHookName),
# so it never reaches this lookup. (Get-HookFriendlyName, which turns the
# internal name into the hyphenated display name, lives in _hooklib.ps1 so the
# installer shares it.)
$script:HookMeta = @{
    'Ai-Memory-Check'                  = @{ Order = 2;  Label = 'Ai-Context-Check'; When = 'post'; Text = 'reminds to update the relevant .ai context files when stale' }
    'Ai-Memory-Load'                   = @{ Order = 3;  Label = 'Ai-Context-Load';  When = 'pre';  Text = 'loads the .ai context router and file index before work starts' }
    'Ci-Status-Check'                  = @{ Order = 4;  When = 'post'; Text = 'verifies GitHub checks of the exact pushed commit' }
    'Dependabot-Check'                 = @{ Order = 5;  When = 'pre';  Text = 'reports pending Dependabot pull requests' }
    'Github-Baseline-Check'            = @{ Order = 6;  When = 'pre';  Text = 'checks the .github CI/dependabot baseline' }
    'Git-Sync-Check'                   = @{ Order = 7;  When = 'both'; Text = 'warns when out of sync with the git remote' }
    # Text kept deliberately short: with the '[pre+post-task]' tag and the
    # separators, the longer wording wrapped so only the tail of the last word
    # landed on a second line. Test-Wizard.ps1 pins the exact concise wording,
    # the absence of an embedded newline, and the single-line budget.
    'Docs-Freshness-Check'             = @{ Order = 8;  When = 'both'; Text = 'checks tracked docs after changes; requires ack' }
    'Graph-Read-Check'                 = @{ Order = 9;  When = 'pre';  Text = 'suggests graphify queries when a graph exists and the task needs it' }
    'Graph-Update-Check'               = @{ Order = 10; When = 'post'; Text = 'suggests graphify update when the graph is stale' }
    'Large-File-Check'                 = @{ Order = 11; When = 'both'; Text = 'small-files policy + oversized-file scan' }
    'Mcp-Usage-Check'                  = @{ Order = 12; When = 'pre';  Text = 'reminder to consider MCP servers/tools' }
    'Rules-Check'                      = @{ Order = 13; When = 'pre';  Text = 'checks global + project rules were read' }
    # Skills-Check's real recommended EVENTS are SessionStart,UserPromptSubmit,Stop
    # (the Stop event carries the "Skills used:" summary requirement) - When must
    # be 'both', not 'pre' alone, or the menu tag disagrees with its actual timing.
    'Skills-Check'                     = @{ Order = 14; When = 'both'; Text = 'skill-policy reminder with the copied skills' }
    'Secrets-Check'                    = @{ Order = 15; When = 'both'; Text = 'keeps secrets.md accurate and checks for leaks' }
    # 'both' (not 'pre+post') - Get-HookTimingTag's switch only recognizes
    # pre/post/both; an unrecognized value silently rendered NO timing tag at all.
    'Ignore-Rules-Check'               = @{ Order = 16; When = 'both'; Text = 'auto-fixes required local/private gitignore rules before and after tasks' }
    'Dependency-Version-Check'         = @{ Order = 17; When = 'pre';  Text = 'advises on outdated dependencies and safe, incremental upgrades' }
    'Test-Temp-Cleanup'                = @{ Order = 18; When = 'both'; Text = 'cleans safe test cache/temp residue; keeps diagnostics' }
    # The three-stage test-health hooks (24.txt). Events/Timeout are the
    # CANONICAL per-hook values - Get-HookRecommendedEvents and the install call
    # read them from here, so name/order/timing/events/timeout cannot drift into
    # a second table. Text stays short for the same single-line reason as
    # Docs-Freshness-Check above.
    'Test-Plan-Check'                  = @{ Order = 19; When = 'pre';  Text = 'surfaces test-health policy before test or CI work'; Events = @('SessionStart', 'UserPromptSubmit'); Timeout = 15 }
    'Test-Run-Guard'                   = @{ Order = 20; When = 'both'; Text = 'requires a bounded runner for recognised test commands'; Events = @('PreToolUse', 'PostToolUse'); Timeout = 10 }
    'Test-Completion-Check'            = @{ Order = 21; When = 'post'; Text = 'verifies test evidence and cleanup before finishing'; Events = @('Stop', 'SubagentStop'); Timeout = 20 }
    # Cloudflare-Deploy is deliberately kept LAST among individual hook
    # entries (Order = highest value) per an explicit user requirement, not
    # filesystem/alphabetical order - see Test-Wizard.ps1 for the pinned order.
    'Cloudflare-Deploy'                = @{ Order = 22; When = 'post'; Text = 'suggests deploying in Cloudflare Workers projects, gated on release readiness' }
}
# The "[pre-task]" / "[post-task]" tag, colored by phase (a different color than
# the description, FFmWiz-style, so timing reads at a glance).
function Get-HookTimingTag {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:HookMeta.ContainsKey($Name)) { return '' }
    switch ($script:HookMeta[$Name].When) {
        'pre'  { return (Get-Painted '[pre-task]' $C.Mint) }
        'post' { return (Get-Painted '[post-task]' $C.Amber) }
        'both' { return (Get-Painted '[pre+post-task]' $C.Aqua) }
        default { return '' }
    }
}
function Get-HookDescriptionText {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:HookMeta.ContainsKey($Name)) {
        return $script:HookMeta[$Name].Text
    }
    return ''
}
function Get-HookMenuName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:HookMeta.ContainsKey($Name) -and $script:HookMeta[$Name].ContainsKey('Label')) {
        return $script:HookMeta[$Name].Label
    }
    return (Get-HookFriendlyName $Name)
}
# The " | " separator between menu-line parts (a light gray - visible, but
# still quieter than the parts it divides).
$script:MenuSep = "$Esc[38;5;248m | $($C.Reset)"

# A hook menu line: "N. Friendly-Name | [timing] | description", each part in
# its own color and separated by a pipe for readability.
function Write-HookMenuLine {
    param([int]$Number, [string]$Name, [string]$ExtraSuffix = '')
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add((Get-Painted (Get-HookMenuName $Name) $C.Bold))
    $tag = Get-HookTimingTag $Name
    if ($tag -ne '') { [void]$parts.Add($tag) }
    $desc = Get-HookDescriptionText $Name
    if ($desc -ne '') { [void]$parts.Add((Get-Painted $desc $C.HintYellow)) }
    if ($ExtraSuffix -ne '') { [void]$parts.Add((Get-Painted $ExtraSuffix $C.Gray)) }
    Write-Host ('  ' + (Get-Painted ($Number.ToString() + '.') $C.LightBlue) + ' ' + ($parts.ToArray() -join $script:MenuSep))
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
function Get-Slug {
    param([Parameter(Mandatory = $true)][string]$Name)

    $slug = [System.Text.RegularExpressions.Regex]::Replace($Name.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'project'
    }
    return $slug
}

# Name of the sync-engine hook folder. Excluded from Get-HookEntries: the
# engine only works when installed via "Create or update a sync group" (item
# 2 of the "Install an existing hook" list), which passes -Profile and copies
# sync-hooks.json alongside it.
# Installed as a generic custom hook (no -Profile, no config copy) it can never
# resolve its own routing config once copied into a project and silently does
# nothing forever - so it must not be selectable from the plain hook lists.
$script:EngineHookName = 'Cross-Project-.ai-Knowledge-Sync'

# Hooks live one folder per hook: hooks\<Name>\<Name>.ps1 (+ .env/.env.example).
# Loose .ps1 files directly in hooks\ are still accepted for compatibility.
function Get-HookEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    $hookDirs = Get-ChildItem -LiteralPath $HooksDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $script:EngineHookName } |
        Sort-Object @{ Expression = { if ($script:HookMeta.ContainsKey($_.Name)) { $script:HookMeta[$_.Name].Order } else { [int]::MaxValue } } }, Name
    foreach ($dir in @($hookDirs)) {
        $script = Join-Path $dir.FullName ($dir.Name + '.ps1')
        if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
            $firstScript = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -First 1
            if ($null -eq $firstScript) { continue }
            $script = $firstScript.FullName
        }
        [void]$entries.Add([pscustomobject]@{
            Name       = $dir.Name
            ScriptPath = $script
            EnvPath    = (Join-Path $dir.FullName '.env')
        })
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $HooksDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Where-Object { -not $_.BaseName.StartsWith('_') } | Sort-Object Name)) {
        [void]$entries.Add([pscustomobject]@{
            Name       = $file.BaseName
            ScriptPath = $file.FullName
            EnvPath    = ''
        })
    }
    return $entries.ToArray()
}

function Get-HookRecommendedEvents {
    param([Parameter(Mandatory = $true)]$Hook)
    # $script:HookMeta is the canonical source: a hook that declares Events
    # there wins over any .env.example, so the menu tag, the recommended events
    # and the installed registration can never disagree. Hooks without an
    # Events key keep the historical .env.example -> generic-default order
    # byte-for-byte.
    if ($script:HookMeta.ContainsKey($Hook.Name) -and $script:HookMeta[$Hook.Name].ContainsKey('Events')) {
        return @($script:HookMeta[$Hook.Name].Events)
    }
    if (-not [string]::IsNullOrWhiteSpace($Hook.EnvPath)) {
        $examplePath = Join-Path (Split-Path -Parent $Hook.EnvPath) '.env.example'
        $values = Read-HookEnv $examplePath
        if ($values.ContainsKey('EVENTS') -and -not [string]::IsNullOrWhiteSpace($values['EVENTS'])) {
            return @($values['EVENTS'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
    }
    return @('SessionStart', 'UserPromptSubmit')
}

# Asks which client(s) the hook is installed for. Returns 'Both', 'Claude',
# 'Codex', or $null when the user backs out.
function Read-ClientChoice {
    while ($true) {
        Write-MenuTitle 'Client:'
        Write-MenuLine 1 'Both' '(Claude + Codex)'
        Write-MenuLine 2 'Claude only' '(.claude\settings.local.json)'
        Write-MenuLine 3 'Codex only' '(.codex\hooks.json)'
        $value = Read-Answer (New-QuestionPrompt 'Select the client' $null '1') 'select client'
        if ($value -eq '0') {
            return $null
        }
        if ($value -eq '') {
            $value = '1'
        }
        switch ($value) {
            '1' { return 'Both' }
            '2' { return 'Claude' }
            '3' { return 'Codex' }
            default { Write-ErrorLine 'Enter 1, 2, 3 or 0.' }
        }
    }
}

# Maps a client choice to an Install-Hook.ps1 splat (empty hashtable = both).
# MUST be a hashtable, not an array: splatting @('-ClaudeOnly') mis-binds the
# bare "-ClaudeOnly" string as a positional value onto Install-Hook's first
# positional parameter ($Profile), which then collides with -CustomHook.
function Get-ClientInstallArgs {
    param([string]$Clients)
    switch ($Clients) {
        'Claude' { return @{ ClaudeOnly = $true } }
        'Codex' { return @{ CodexOnly = $true } }
        default { return @{} }
    }
}

# Per-hook registration timeout, from the canonical metadata. Returns an EMPTY
# splat for every hook without an explicit Timeout, so Install-Hook.ps1 keeps
# resolving those exactly as before (persisted record value, else 60) - passing
# an explicit 60 here would instead overwrite a deliberately repaired record.
function Get-HookTimeoutArgs {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($script:HookMeta.ContainsKey($Name) -and $script:HookMeta[$Name].ContainsKey('Timeout')) {
        return @{ Timeout = [int]$script:HookMeta[$Name].Timeout }
    }
    return @{}
}

# Human-readable "where does it land" label for summaries.
function Get-ClientInstallLabel {
    param([string]$Clients)
    switch ($Clients) {
        'Claude' { return 'per project: .claude\settings.local.json (Claude only)' }
        'Codex' { return 'per project: .codex\hooks.json (Codex only)' }
        default { return 'per project: .claude\settings.local.json + .codex\hooks.json' }
    }
}


# Reads an event selection (or a custom list). Returns an events array, or
# $null when the user backs out. When $RecommendedEvents is non-empty (the
# SPECIFIC hook's own recommended EVENTS, from Get-HookRecommendedEvents), it
# becomes choice 1 - a clear, correctly-defaulted option - instead of the
# single-hook flow silently defaulting to the generic "SessionStart,
# UserPromptSubmit" pair on a bare Enter, regardless of what the hook actually
# needs (e.g. a Stop-only hook like Cloudflare-Deploy/Ci-Status-Check, or a
# SessionStart+Stop hook like Docs-Freshness-Check). Nothing is removed - every
# other choice (including full custom) still follows.
function Read-EventSelection {
    param([string]$TitleSuffix = '', [string[]]$RecommendedEvents = @())
    $knownEvents = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop', 'PreCompact', 'SessionEnd', 'Notification', 'PermissionRequest', 'PostCompact', 'SubagentStart')
    $recommended = @($RecommendedEvents | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hasRecommended = $recommended.Count -gt 0

    $choices = New-Object System.Collections.Generic.List[object]
    if ($hasRecommended) {
        [void]$choices.Add(@{ Label = "This hook's recommended events"; Hint = '(' + ($recommended -join ', ') + ')'; Events = $recommended })
    }
    $sessionPromptHint = if ($hasRecommended) { '(context hooks)' } else { '(context hooks - recommended)' }
    [void]$choices.Add(@{ Label = 'Session Start + User Prompt Submit'; Hint = $sessionPromptHint; Events = @('SessionStart', 'UserPromptSubmit') })
    [void]$choices.Add(@{ Label = 'Session Start'; Hint = ''; Events = @('SessionStart') })
    [void]$choices.Add(@{ Label = 'User Prompt Submit'; Hint = ''; Events = @('UserPromptSubmit') })
    $customChoiceNumber = $choices.Count + 1

    while ($true) {
        Write-MenuTitle ('Events' + $TitleSuffix + ':')
        for ($i = 0; $i -lt $choices.Count; $i++) {
            Write-MenuLine ($i + 1) $choices[$i].Label $choices[$i].Hint
        }
        Write-MenuLine $customChoiceNumber 'Custom list' '(e.g. Pre Tool Use, Post Tool Use, Stop)'
        $value = Read-Answer (New-QuestionPrompt 'Select events' $null '1') 'select events'
        if ($value -eq '0') { return $null }
        if ($value -eq '') { $value = '1' }
        $picked = 0
        if ([int]::TryParse($value, [ref]$picked) -and $picked -ge 1 -and $picked -le $choices.Count) {
            return @($choices[$picked - 1].Events)
        }
        if ($picked -eq $customChoiceNumber) {
            $raw = Read-Answer (New-QuestionPrompt 'Event names' ('comma separated; example: ' + (Get-ExampleText 'PreToolUse,PostToolUse')) $null) 'custom event list'
            if ($raw -eq '0') { continue }
            $candidates = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            if ($candidates.Count -eq 0) { Write-ErrorLine 'Enter at least one event name.'; continue }
            $invalid = @($candidates | Where-Object { $_ -notmatch '^[A-Za-z]+$' })
            if ($invalid.Count -gt 0) { Write-ErrorLine ('Invalid event name(s): ' + ($invalid -join ', ')); continue }
            $unknown = @($candidates | Where-Object { $knownEvents -notcontains $_ })
            if ($unknown.Count -gt 0) { Write-NoteLine ('Not a known event (installing anyway): ' + ($unknown -join ', ')) }
            return $candidates
        }
        Write-ErrorLine ('Enter a number between 1 and ' + $customChoiceNumber + '.')
    }
}

# Gathers events + client + target projects for one hook as a mini stage machine
# (back steps one). Returns an object, or $null when backed out of the first step.
function Read-HookConfig {
    param([string]$TitleSuffix = '', [switch]$SkipEvents, [string[]]$RecommendedEvents = @(), [object[]]$InitialTargets = @())
    # When $InitialTargets is supplied (the project paths already collected by the
    # sync group in this same batch), the path prompt is skipped entirely - the
    # user typed those paths once and there is no reason to ask again. They stay
    # editable from the summary screen (Read-ProjectList -InitialProjects).
    $reuseTargets = (@($InitialTargets).Count -gt 0)
    $events = $null; $clients = $null; $stage = if ($SkipEvents) { 1 } else { 0 }
    while ($true) {
        switch ($stage) {
            0 {
                $events = Read-EventSelection $TitleSuffix $RecommendedEvents
                if ($null -eq $events) { return $null }
                $stage = 1
            }
            1 {
                $clients = Read-ClientChoice
                if ($null -eq $clients) {
                    if ($SkipEvents) { return $null }
                    $stage = 0
                    break
                }
                $stage = 2
            }
            2 {
                if ($reuseTargets) {
                    return [pscustomobject]@{ Events = @($events); Clients = $clients; Targets = @($InitialTargets) }
                }
                $targets = Read-ProjectList -MinimumCount 1
                if ($null -eq $targets) { $stage = 1; break }
                return [pscustomobject]@{ Events = @($events); Clients = $clients; Targets = @($targets) }
            }
        }
    }
}

# Install one or more existing hooks. A list/range (e.g. 2-5,8) selects several
# at once; for a batch you use each hook's recommended events with shared
# client/targets, or configure every hook independently. A precise summary then
# lists every hook's events/client/projects.
function Invoke-InstallExistingHook {
    Write-Log 'INFO' 'CUSTOM' 'Custom hook install started.'
    Write-PhaseHeader 'Install an Existing Hook' $C.Input '-'

    $hookFiles = @(Get-HookEntries)
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hooks found in: ' + $HooksDir)
        Write-NoteLine 'Create one first ("Create a new hook").'
        return 'back'
    }

    while ($true) {
        # ---- selection: a single number, comma list, or range ----
        # FIXED menu layout (the numbers are part of the documented UI):
        #   1                      Select all hooks (aggregate action)
        #   2                      the sync group (its own multi-project flow)
        #   3 .. 2+S               the S SHIPPED hooks, in $script:HookMeta.Order
        #   3+S                    Update installed hooks    (management action)
        #   4+S                    Get hook status           (management action)
        #   5+S                    Uninstall installed hooks (management action)
        #   6+S ..                 user-created/custom hooks, deterministic order
        # With all 21 shipped hooks present that renders as 3..23, 24, 25, 26,
        # 27+. The THREE management rows are placed AFTER the shipped block and
        # BEFORE the custom block deliberately: discovering a new custom hook
        # under hooks\ must never shift 24/25/26, because those numbers are
        # documented UI. Every index below is derived from $shippedHooks.Count -
        # adding a shipped hook renumbers the management rows, it never needs a
        # hand-edited constant.
        $shippedHooks = @($hookFiles | Where-Object { $script:HookMeta.ContainsKey($_.Name) })
        $customHooks = @($hookFiles | Where-Object { -not $script:HookMeta.ContainsKey($_.Name) })
        $updateIndex = $shippedHooks.Count + 3
        $statusIndex = $shippedHooks.Count + 4
        $uninstallIndex = $shippedHooks.Count + 5
        $customStartIndex = $shippedHooks.Count + 6
        $maxIndex = $customStartIndex + $customHooks.Count - 1

        Write-MenuTitle 'Available hooks (hooks\):'
        Write-Host ('  ' + (Get-Painted '1.' $C.LightBlue) + ' ' + (Get-Painted 'Select all hooks' $C.Bold) + $script:MenuSep + (Get-Painted '[all]' $C.Orchid) + $script:MenuSep + (Get-Painted ('run the sync group (2) and install every hook below (3-' + ($shippedHooks.Count + $customHooks.Count + 2) + ')') $C.HintYellow))
        Write-Host ('  ' + (Get-Painted '2.' $C.LightBlue) + ' ' + (Get-Painted 'Create or update a sync group' $C.Bold) + $script:MenuSep + (Get-Painted '[pre-task]' $C.Mint) + $script:MenuSep + (Get-Painted 'cross-project .ai knowledge sync' $C.HintYellow))
        for ($i = 0; $i -lt $shippedHooks.Count; $i++) {
            Write-HookMenuLine ($i + 3) $shippedHooks[$i].Name
        }
        Write-Host ('  ' + (Get-Painted ([string]$updateIndex + '.') $C.LightBlue) + ' ' + (Get-Painted 'Update installed hooks' $C.Bold) + $script:MenuSep + (Get-Painted '[manage]' $C.Teal) + $script:MenuSep + (Get-Painted 'refresh installed copies from their current source' $C.HintYellow))
        Write-Host ('  ' + (Get-Painted ([string]$statusIndex + '.') $C.LightBlue) + ' ' + (Get-Painted 'Get hook status' $C.Bold) + $script:MenuSep + (Get-Painted '[manage]' $C.Teal) + $script:MenuSep + (Get-Painted 'scan a path, detect installed hooks, and track verified results' $C.HintYellow))
        Write-Host ('  ' + (Get-Painted ([string]$uninstallIndex + '.') $C.LightBlue) + ' ' + (Get-Painted 'Uninstall installed hooks' $C.Bold) + $script:MenuSep + (Get-Painted '[manage]' $C.Teal) + $script:MenuSep + (Get-Painted 'list and remove installed hooks; never deletes hook sources' $C.HintYellow))
        for ($i = 0; $i -lt $customHooks.Count; $i++) {
            Write-HookMenuLine ($customStartIndex + $i) $customHooks[$i].Name
        }
        Write-NoteLine ('  Tip: use lists and ranges, e.g. 3-8 (1 alone runs everything: the sync group AND every hook). ' + $updateIndex + '/' + $statusIndex + '/' + $uninstallIndex + ' are management actions - pick one on its own.')
        $value = Read-Answer (New-QuestionPrompt 'Select a hook (number, list, or range)' $null '2') 'select custom hook'
        if ($value -eq '0') { return 'back' }
        if ($value -eq '') { $value = '2' }

        # ONE canonical numeric-selection parser, shared with the installed-hook
        # screens (Setup-SyncGroupInstalledHooks.ps1) so list/range semantics can
        # never drift between the install and uninstall flows.
        $parsed = Expand-MenuSelection -Value $value -MaxIndex $maxIndex
        if (-not $parsed.Ok) {
            Write-ErrorLine $parsed.Reason
            continue
        }
        $indices = New-Object System.Collections.Generic.List[int]
        foreach ($idx in @($parsed.Indices)) { [void]$indices.Add($idx) }

        # The management rows are actions, not hook selections: mixing them with
        # hooks (or with each other) has no coherent meaning, so it is rejected
        # explicitly rather than silently doing half of what was typed.
        $managementPicked = @($indices | Where-Object { $_ -eq $updateIndex -or $_ -eq $statusIndex -or $_ -eq $uninstallIndex })
        if ($managementPicked.Count -gt 0) {
            if ($indices.Count -ne 1) {
                Write-ErrorLine ('Select ' + $updateIndex + ' (update), ' + $statusIndex + ' (status) or ' + $uninstallIndex + ' (uninstall) on its own - it cannot be combined with hook selections or with each other.')
                continue
            }
            if ($indices[0] -eq $updateIndex) {
                if ((Invoke-UpdateInstalledHooks) -eq 'done') { return 'done' }
                continue
            }
            if ($indices[0] -eq $statusIndex) {
                if ((Invoke-GetHookStatus) -eq 'done') { return 'done' }
                continue
            }
            if ((Invoke-UninstallInstalledHooks) -eq 'done') { return 'done' }
            continue
        }
        # "Select all hooks" (item 1) is an aggregate action, not a hook: it
        # means the COMPLETE former full-list flow - the sync group AND every
        # individual hook index (3..N+2), dynamically derived from
        # $hookFiles (never a hard-coded count) - unconditionally, without
        # needing "2" also typed explicitly. It rebuilds the selection in
        # canonical order so combining it with explicit picks (e.g. "1,5" or
        # "1,2") can never run the sync group twice or install a hook twice.
        # It never re-includes itself as a hook.
        # It never re-includes itself as a hook, and it never triggers any of the
        # three management rows (update/status/uninstall) - "install everything"
        # must not be able to scan or uninstall anything. The rebuilt list is
        # literally 2 + the shipped range + the custom range, so the management
        # indices between them are structurally unreachable from item 1.
        if ($indices.Contains(1)) {
            $indices = New-Object System.Collections.Generic.List[int]
            [void]$indices.Add(2)
            for ($i = 0; $i -lt $shippedHooks.Count; $i++) { [void]$indices.Add($i + 3) }
            for ($i = 0; $i -lt $customHooks.Count; $i++) { [void]$indices.Add($customStartIndex + $i) }
        }
        # The sync group (item 2) is its own multi-project flow, not a plain
        # hook install - it can't be gathered into the same events/client/
        # projects batch below. When it's selected alongside other hooks, run
        # its wizard first, then fall through and install the rest right after
        # (no need to re-enter this menu a second time).
        $ranSyncGroup = $false
        # Project paths collected by the sync group, reused as the install targets
        # for any other hooks picked in the same batch (entered once, not per hook).
        # Empty unless item 2 ran and published its projects.
        $sharedGroupProjects = @()
        if ($indices.Contains(2)) {
            [void]$indices.Remove(2)
            if ($indices.Count -gt 0) {
                Write-NoteLine ('  Running the sync group first, then installing ' + $indices.Count + ' more hook(s)...')
            }
            $groupResult = Invoke-CreateGroup
            if ($groupResult -eq 'back') { continue }
            if ($groupResult -eq 'canceled') { return 'done' }
            $ranSyncGroup = $true
            if ($indices.Count -eq 0) { return 'done' }
            $sharedGroupProjects = @($script:LastGroupProjects)
            if ($sharedGroupProjects.Count -gt 0) {
                Write-NoteLine ('  Reusing the same ' + $sharedGroupProjects.Count + ' project path(s) from the sync group for the remaining hook(s) - edit them at the summary if needed.')
            }
            Write-PhaseHeader 'Install an Existing Hook' $C.Input '-'
        }
        # Resolve each remaining index back to its hook. Shipped and custom hooks
        # live in two separate ranges either side of the fixed management rows,
        # so the index maths differs per range - a single flat offset would map
        # custom picks onto the wrong hook.
        $selected = @($indices | ForEach-Object {
            if ($_ -ge $customStartIndex) { $customHooks[$_ - $customStartIndex] } else { $shippedHooks[$_ - 3] }
        })
        Write-Log 'INFO' 'CUSTOM' ('Selected ' + $selected.Count + ' hook(s): ' + (($selected | ForEach-Object { $_.Name }) -join ', '))

        # ---- gather config (same for all, or per hook) ----
        $plans = $null
        $sharedTargets = $false
        if ($selected.Count -eq 1) {
            $cfg = Read-HookConfig -RecommendedEvents @(Get-HookRecommendedEvents $selected[0]) -InitialTargets $sharedGroupProjects
            if ($null -eq $cfg) { continue }
            $plans = @([pscustomobject]@{ Hook = $selected[0]; Config = $cfg })
        }
        else {
            $selectedNames = ($selected | ForEach-Object { Get-HookFriendlyName $_.Name }) -join ', '
            Write-Host ((Get-Painted ('Configuring ' + $selected.Count + ' hooks:') $C.Input) + ' ' + (Get-Painted $selectedNames $C.White))
            Write-Host ''
            Write-MenuLine 1 'Recommended events per hook / same client / projects' '(one set of target answers)'
            Write-MenuLine 2 'Configure each hook separately' '(ask per hook)'
            $mode = Read-Answer (New-QuestionPrompt 'How should they be configured?' $null '1') 'multi-hook config mode'
            if ($mode -eq '0') { continue }
            if ($mode -eq '') { $mode = '1' }
            if ($mode -eq '1') {
                $cfg = Read-HookConfig ' (all selected hooks)' -SkipEvents -InitialTargets $sharedGroupProjects
                if ($null -eq $cfg) { continue }
                $sharedTargets = $true
                $plans = @($selected | ForEach-Object {
                    $hookConfig = [pscustomobject]@{ Events = @(Get-HookRecommendedEvents $_); Clients = $cfg.Clients; Targets = @($cfg.Targets) }
                    [pscustomobject]@{ Hook = $_; Config = $hookConfig }
                })
            }
            elseif ($mode -eq '2') {
                $collected = New-Object System.Collections.Generic.List[object]
                $aborted = $false
                foreach ($h in $selected) {
                    $cfg = Read-HookConfig (' for ' + (Get-HookFriendlyName $h.Name)) -RecommendedEvents @(Get-HookRecommendedEvents $h) -InitialTargets $sharedGroupProjects
                    if ($null -eq $cfg) { $aborted = $true; break }
                    [void]$collected.Add([pscustomobject]@{ Hook = $h; Config = $cfg })
                }
                if ($aborted) { continue }
                $plans = $collected.ToArray()
            }
            else {
                Write-ErrorLine 'Enter 1, 2 or 0.'
                continue
            }
        }

        # ---- summary ----
        while ($true) {
            Write-PhaseHeader 'Summary' $C.Summary '-'
            for ($i = 0; $i -lt $plans.Count; $i++) {
                $plan = $plans[$i]
                Write-MenuLine ($i + 1) (Get-HookFriendlyName $plan.Hook.Name)
                Write-Field '     events' ($plan.Config.Events -join ', ')
                Write-Field '     client' $plan.Config.Clients
                Write-Field '     projects' (@($plan.Config.Targets | ForEach-Object { $_.Name }) -join ', ')
            }
            Write-Host ''
            Write-Field 'install' 'self-contained copy per project (.claude/.codex hooks\Hook-Maker\<name>\)'
            Write-PhaseHeader 'Confirm' $C.Confirm '-'
            $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start multi hook install'
            if ($null -eq $confirm) {
                $lastPlan = $plans[$plans.Count - 1]
                $editedTargets = Read-ProjectList -MinimumCount 1 -InitialProjects @($lastPlan.Config.Targets)
                if ($null -eq $editedTargets) { continue }
                if ($sharedTargets) {
                    foreach ($plan in $plans) { $plan.Config.Targets = @($editedTargets) }
                }
                else {
                    $lastPlan.Config.Targets = @($editedTargets)
                }
                continue
            }
            if ($confirm -ne $true) {
                if ($ranSyncGroup) {
                    Write-NoteLine 'Canceled. The sync group was applied; the remaining hook(s) were not installed.'
                }
                else {
                    Write-NoteLine 'Canceled. Nothing was installed.'
                }
                Write-Log 'INFO' 'CUSTOM' 'User declined at confirmation; no install.'
                return 'done'
            }
            break
        }

        # ---- install ----
        Write-PhaseHeader 'Applying Changes' $C.Process '-'
        foreach ($plan in $plans) {
            $clientArgs = Get-ClientInstallArgs $plan.Config.Clients
            $timeoutArgs = Get-HookTimeoutArgs $plan.Hook.Name
            foreach ($target in $plan.Config.Targets) {
                $installOutput = & $InstallScript -CustomHook $plan.Hook.ScriptPath -Events @($plan.Config.Events) -TargetProject $target.Root @clientArgs @timeoutArgs *>&1
                foreach ($line in @($installOutput)) { Write-Log 'INFO' 'INSTALL' ([string]$line) }
                Write-Host ('  ' + (Get-Painted '+ installed' $C.Green) + ' ' + (Get-Painted (Get-HookFriendlyName $plan.Hook.Name) $C.Bold) + ' -> ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted ('(' + $plan.Config.Clients + ', ' + ($plan.Config.Events -join '+') + ')') $C.Gray))
            }
            Write-Log 'INFO' 'INSTALL' ('Installed ' + $plan.Hook.Name + ' | client=' + $plan.Config.Clients + ' | events=' + ($plan.Config.Events -join ',') + ' | projects=' + $plan.Config.Targets.Count)
        }
        Write-PhaseHeader 'Completed' $C.Done '='
        $doneMsg = if ($ranSyncGroup) { '  Sync group + ' + $plans.Count + ' hook(s) installed.' } else { '  Installed ' + $plans.Count + ' hook(s).' }
        Write-Host (Get-Painted ($doneMsg + ' Restart the Claude/Codex clients and review /hooks inside each project.') $C.White)
        Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
        Write-Log 'INFO' 'DONE' ('Multi-hook install complete: ' + $plans.Count + ' hook(s)' + $(if ($ranSyncGroup) { ' + sync group' } else { '' }) + '.')
        return 'done'
    }
}

# Install an existing hook using its .env (EVENTS + TARGET_PROJECTS): no
# questions besides the hook selection and one confirm.
function Invoke-InstallHookFromConfig {
    Write-Log 'INFO' 'CUSTOM' 'Config-based hook install started.'
    Write-PhaseHeader 'Install From Config (.env)' $C.Input '-'

    $hookFiles = @(Get-HookEntries | Where-Object { $_.EnvPath -ne '' })
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hooks found in: ' + $HooksDir)
        return 'back'
    }

    while ($true) {
        Write-MenuTitle 'Available hooks (hooks\):'
        for ($i = 0; $i -lt $hookFiles.Count; $i++) {
            $envState = '(no .env yet)'
            if (Test-Path -LiteralPath $hookFiles[$i].EnvPath -PathType Leaf) {
                $envState = '(.env found)'
            }
            Write-HookMenuLine ($i + 1) $hookFiles[$i].Name $envState
        }
        $value = Read-Answer (New-QuestionPrompt 'Select a hook' $null '1') 'select hook for config install'
        if ($value -eq '0') {
            return 'back'
        }
        if ($value -eq '') {
            $value = '1'
        }
        $index = 0
        if (-not ([int]::TryParse($value, [ref]$index) -and $index -ge 1 -and $index -le $hookFiles.Count)) {
            Write-ErrorLine ('Enter a number between 1 and ' + $hookFiles.Count + '.')
            continue
        }
        $hook = $hookFiles[$index - 1]

        if (-not (Test-Path -LiteralPath $hook.EnvPath -PathType Leaf)) {
            Write-ErrorLine ('No .env found for ' + $hook.Name + '.')
            Write-NoteLine ('Copy ' + (Join-Path (Split-Path -Parent $hook.EnvPath) '.env.example') + ' to .env and fill TARGET_PROJECTS.')
            continue
        }
        $envValues = Read-HookEnv $hook.EnvPath

        $events = @('SessionStart', 'UserPromptSubmit')
        if ($envValues.ContainsKey('EVENTS') -and $envValues['EVENTS'] -ne '') {
            $events = @($envValues['EVENTS'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
        $clients = 'Both'
        if ($envValues.ContainsKey('CLIENTS') -and $envValues['CLIENTS'] -ne '') {
            switch ($envValues['CLIENTS'].Trim().ToLowerInvariant()) {
                'claude' { $clients = 'Claude' }
                'codex' { $clients = 'Codex' }
                'both' { $clients = 'Both' }
                default { Write-NoteLine ('Unknown CLIENTS value "' + $envValues['CLIENTS'] + '" - installing for both.') }
            }
        }
        $targetsRaw = ''
        if ($envValues.ContainsKey('TARGET_PROJECTS')) {
            $targetsRaw = $envValues['TARGET_PROJECTS']
        }
        $targetPaths = @($targetsRaw.Split(';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
        if ($targetPaths.Count -eq 0) {
            Write-ErrorLine ('TARGET_PROJECTS is empty in ' + $hook.EnvPath + '.')
            Write-NoteLine 'Fill it with semicolon-separated project roots and retry.'
            continue
        }
        $targets = New-Object System.Collections.Generic.List[object]
        $invalid = $false
        foreach ($path in $targetPaths) {
            try {
                $root = Normalize-Path $path
            }
            catch {
                Write-ErrorLine ('Invalid path in TARGET_PROJECTS: ' + $path)
                $invalid = $true
                break
            }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-ErrorLine ('Directory not found (from TARGET_PROJECTS): ' + $root)
                $invalid = $true
                break
            }
            [void]$targets.Add([pscustomobject]@{ Name = (Split-Path -Leaf $root); Root = $root })
        }
        if ($invalid) {
            continue
        }

        # ---- summary + confirm ----
        Write-PhaseHeader 'Summary' $C.Summary '-'
        Write-Field 'hook script' $hook.ScriptPath $C.LightBlue
        Write-Field 'config' $hook.EnvPath $C.LightBlue
        Write-Field 'events' ($events -join ', ')
        Write-Field 'client' $clients
        Write-Field 'install' (Get-ClientInstallLabel $clients)
        Write-MenuTitle 'Target projects (from .env):'
        for ($i = 0; $i -lt $targets.Count; $i++) {
            Write-MenuLine ($i + 1) $targets[$i].Name $targets[$i].Root
        }
        Write-PhaseHeader 'Confirm' $C.Confirm '-'
        $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start config install'
        if ($null -eq $confirm) {
            continue
        }
        if ($confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was installed.'
            return 'done'
        }

        Write-PhaseHeader 'Applying Changes' $C.Process '-'
        $clientArgs = Get-ClientInstallArgs $clients
        $timeoutArgs = Get-HookTimeoutArgs $hook.Name
        foreach ($target in $targets) {
            $installOutput = & $InstallScript -CustomHook $hook.ScriptPath -Events @($events) -TargetProject $target.Root @clientArgs @timeoutArgs *>&1
            foreach ($line in @($installOutput)) {
                Write-Log 'INFO' 'INSTALL' ([string]$line)
            }
            Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted $target.Root $C.Gray))
        }
        Write-PhaseHeader 'Completed' $C.Done '='
        Write-Host (Get-Painted ('  ' + $hook.Name + ' installed for: ' + ($events -join ', ') + ' (' + $clients + ')') $C.White)
        Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
        Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
        Write-Log 'INFO' 'DONE' ('Config install: ' + $hook.ScriptPath + ' | events=' + ($events -join ',') + ' | clients=' + $clients + ' | projects=' + $targets.Count)
        return 'done'
    }
}


# Refreshes every valid tracked (or newly-discovered legacy) installation
# whose managed runtime no longer matches current source, reusing each
# record's saved parameters - a correct reinstall without re-asking any
# configuration question. Missing source/target/profile are reported and
# skipped, never destructively touched. One confirmation for the whole batch.
# Safe field read for registry records shown in the update plan. A malformed
# record must be DISPLAYABLE (so the user can see what needs manual repair)
# without StrictMode throwing on its missing properties.
function Get-RecordDisplayField {
    param($Record, [string]$Name, [string]$Fallback = '(unknown)')
    if ($null -eq $Record) { return $Fallback }
    if ($null -eq $Record.PSObject.Properties[$Name]) { return $Fallback }
    $value = [string]$Record.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    return $value
}

function Invoke-UpdateInstalledHooks {
    Write-Log 'INFO' 'UPDATE' 'Update previously installed hooks started.'
    Write-PhaseHeader 'Update Previously Installed Hooks' $C.Input '-'

    # A corrupt registry must never read back as a quiet "nothing tracked" -
    # that would hide real installations and let the summary imply everything
    # is fine. Report it loudly; the file itself is left untouched here (only
    # a real install quarantines and recovers it).
    $registryState = Read-InstallRegistryState -ToolRoot $ToolRoot
    if ($registryState.State -eq 'corrupt') {
        Write-NoteLine ('  WARNING: the install registry could not be used: ' + $registryState.Reason)
        Write-NoteLine ('  File: ' + $registryState.Path)
        Write-NoteLine '  Tracked installations cannot be listed or verified until it is repaired. It has NOT been modified or deleted.'
        Write-NoteLine '  Reinstalling any hook will preserve the unreadable file under a "install-registry.corrupt-<timestamp>-<hash>.json" name and start a new registry.'
        Write-Log 'ERROR' 'UPDATE' ('Registry unusable: ' + $registryState.Reason)
        return 'done'
    }
    $registry = Read-InstallRegistry -ToolRoot $ToolRoot
    $legacyCandidates = @(Get-LegacyHookCandidates -Registry $registry -ToolRoot $ToolRoot -HooksDir $HooksDir -ConfigPath $ConfigPath)
    $allRecords = @(@($registry.installs) + @($legacyCandidates))

    if ($allRecords.Count -eq 0) {
        Write-NoteLine '  No previously installed hooks are tracked yet, and none were found in the current project, the global scope, or projects referenced by the sync config.'
        Write-NoteLine '  Install a hook once (any method) to start tracking it; a hook installed in another, unreferenced project must be reinstalled once there to enter the registry.'
        Write-Log 'INFO' 'UPDATE' 'No tracked or discoverable installs.'
        return 'back'
    }

    # ---- evaluate each record: up to date / needs update / skip reason ----
    $plan = New-Object System.Collections.Generic.List[object]
    # PER-RECORD ISOLATION. Every record is validated before any of its fields
    # are read, and its whole evaluation runs inside try/catch. Under StrictMode
    # a single malformed record (e.g. one missing sourceScript) previously threw
    # and aborted the entire run, so every healthy record after it was never
    # evaluated. A bad record is now an isolated, precisely-reported entry and
    # nothing about it is modified or guessed at.
    foreach ($record in $allRecords) {
        $status = ''
        $components = @()
        $detail = ''
        try {
            $validation = Test-InstallRecordValid -Record $record
            if (-not $validation.Ok) {
                $status = 'skip'; $detail = 'invalid registry record (manual repair): ' + $validation.Reason
            }
            elseif (-not (Test-Path -LiteralPath $record.sourceScript -PathType Leaf)) {
                $status = 'skip'; $detail = 'source script no longer found: ' + $record.sourceScript
            }
            elseif (($record.scope -ne 'global') -and -not (Test-Path -LiteralPath $record.targetProjectRoot -PathType Container)) {
                $status = 'skip'; $detail = 'target project no longer found: ' + $record.targetProjectRoot
            }
            elseif ($record.hookType -eq 'Engine' -and -not (Test-Path -LiteralPath $record.configPath -PathType Leaf)) {
                $status = 'skip'; $detail = 'sync config no longer found: ' + $record.configPath
            }
            elseif ($record.hookType -eq 'Engine') {
                $engineConfig = Read-JsonFile $record.configPath
                $profileExists = ($null -ne $engineConfig) -and ($null -ne $engineConfig.PSObject.Properties['profiles']) -and (@($engineConfig.profiles | Where-Object { [string]$_.id -eq [string]$record.profile }).Count -gt 0)
                if (-not $profileExists) { $status = 'skip'; $detail = 'profile no longer exists in the sync config: ' + $record.profile }
            }
            if ($status -eq '') {
                $evaluation = Get-InstallIntegrity -Record $record -ToolRoot $ToolRoot
                $status = $evaluation.Status
                $detail = $evaluation.Detail
                # Per-component breakdown drives targeted repair below.
                if ($null -ne $evaluation.PSObject.Properties['Components']) { $components = @($evaluation.Components) }
            }
        }
        catch {
            # Never let one record's failure end the run.
            $status = 'skip'
            $detail = 'could not evaluate this record (manual repair): ' + $_.Exception.Message
        }
        [void]$plan.Add([pscustomobject]@{ Record = $record; Status = $status; Detail = $detail; Components = $components })
    }

    Write-MenuTitle 'Plan:'
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $item = $plan[$i]
        $scopeText = if ((Get-RecordDisplayField $item.Record 'scope') -eq 'global') { 'global' } else { Get-RecordDisplayField $item.Record 'targetProjectRoot' }
        $color = switch ($item.Status) { 'update' { $C.Amber }; 'skip' { $C.Red }; default { $C.Mint } }
        Write-Host ('  ' + (Get-Painted (($i + 1).ToString() + '.') $C.LightBlue) + ' ' + (Get-Painted (Get-HookFriendlyName (Get-RecordDisplayField $item.Record 'friendlyName' 'unknown-record')) $C.Bold) + $script:MenuSep + (Get-Painted $scopeText $C.Gray) + $script:MenuSep + (Get-Painted $item.Detail $color))
    }
    $toUpdate = @($plan | Where-Object { $_.Status -eq 'update' })
    $toSkip = @($plan | Where-Object { $_.Status -eq 'skip' })
    $current = @($plan | Where-Object { $_.Status -eq 'current' })
    Write-Host ''
    Write-Field 'already up to date' $current.Count.ToString()
    Write-Field 'will be updated' $toUpdate.Count.ToString()
    Write-Field 'skipped (missing source/target/profile)' $toSkip.Count.ToString()
    Write-Log 'INFO' 'UPDATE' ('Plan built: total=' + $allRecords.Count + ' current=' + $current.Count + ' update=' + $toUpdate.Count + ' skip=' + $toSkip.Count)

    if ($toUpdate.Count -eq 0) {
        Write-NoteLine '  Nothing to update - every valid tracked installation already matches the current source.'
        if ($toSkip.Count -gt 0) {
            Write-NoteLine '  Skipped (review and reinstall manually if still needed):'
            foreach ($item in $toSkip) { Write-NoteLine ('    ' + (Get-HookFriendlyName (Get-RecordDisplayField $item.Record 'friendlyName' 'unknown-record')) + ' - ' + $item.Detail) }
        }
        return 'done'
    }

    Write-PhaseHeader 'Confirm' $C.Confirm '-'
    $confirm = Read-YesNo (New-QuestionPrompt ('Update ' + $toUpdate.Count + ' installed hook(s) now?') 'y/n' 'y') $true 'confirm update installed hooks'
    if ($null -eq $confirm -or $confirm -ne $true) {
        Write-NoteLine 'Canceled. Nothing was changed.'
        Write-Log 'INFO' 'UPDATE' 'User declined at confirmation; no changes applied.'
        return 'done'
    }

    Write-PhaseHeader 'Applying Changes' $C.Process '-'
    $updated = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($item in $toUpdate) {
        $record = $item.Record
        $displayName = Get-HookFriendlyName $record.friendlyName
        $scopeText = if ($record.scope -eq 'global') { 'global' } else { $record.targetProjectRoot }

        # Repair EACH client separately with that client's own saved events.
        # A single shared invocation would force one client's semantics onto
        # the other whenever they differ (Claude on SessionStart, Codex on
        # Stop is a legitimate, supported combination).
        $clientsToRepair = @(Get-InstalledClientNames -Record $record)
        if ($clientsToRepair.Count -eq 0 -and $null -ne $record.PSObject.Properties['imported'] -and $record.imported -eq $true) {
            # A legacy import records the clients it actually found live.
            $clientsToRepair = @($record.importedClients)
        }
        $clientResults = New-Object System.Collections.Generic.List[string]
        $clientResultsSkipped = New-Object System.Collections.Generic.List[string]
        # COMPONENT-LEVEL REPAIR: reinstall only the clients the integrity check
        # actually reported as damaged. Reinstalling a healthy client would
        # rewrite its settings file, add another timestamped backup and bump its
        # runtime mtimes for no reason. A changed SOURCE is a shared dependency,
        # so the integrity check already marks every client damaged in that case
        # and they are all repaired together.
        if ($null -ne $item.PSObject.Properties['Components'] -and $null -ne $item.Components) {
            $damagedClients = @(@($item.Components) |
                Where-Object { $_.Status -eq 'update' -and $_.Name -ne 'source' -and $_.Name -ne 'nativeGit' } |
                ForEach-Object { [string]$_.Name })
            if ($damagedClients.Count -gt 0) {
                $healthy = @($clientsToRepair | Where-Object { $damagedClients -notcontains $_ })
                $clientsToRepair = @($clientsToRepair | Where-Object { $damagedClients -contains $_ })
                foreach ($untouched in $healthy) {
                    [void]$clientResultsSkipped.Add($untouched + ': already current (left untouched)')
                }
            }
        }
        $anyFailed = $false
        foreach ($client in $clientsToRepair) {
            $events = @()
            $subrecord = Get-ClientSubrecord -Record $record -Client $client
            if ($null -ne $subrecord) { $events = @($subrecord.events) }
            elseif ($null -ne $record.PSObject.Properties['events']) { $events = @($record.events) }
            if (@($events).Count -eq 0) {
                $anyFailed = $true
                [void]$clientResults.Add($client + ': no recorded events')
                continue
            }
            $installArgs = @{ Events = @($events) }
            if ($record.scope -eq 'project') { $installArgs['TargetProject'] = $record.targetProjectRoot }
            if ($record.hookType -eq 'Engine') {
                $installArgs['Profile'] = $record.profile
                $installArgs['ConfigPath'] = $record.configPath
            }
            else {
                $installArgs['CustomHook'] = $record.sourceScript
            }
            $clientArgs = if ($client -eq 'claude') { @{ ClaudeOnly = $true } } else { @{ CodexOnly = $true } }
            try {
                # STRUCTURED OUTCOME: the installer writes a machine-readable
                # result document. Success is read from that, never inferred
                # from console text or from "no exception was thrown" - an
                # install whose runtime and settings landed but whose tracking
                # failed must not be reported as fully updated.
                $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-install-result-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
                $installArgs['ResultPath'] = $resultFile
                $installOutput = & $InstallScript @installArgs @clientArgs *>&1
                foreach ($line in @($installOutput)) { Write-Log 'INFO' 'INSTALL' ([string]$line) }
                $installResult = $null
                if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
                    try { $installResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json } catch { $installResult = $null }
                    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
                }
                if ($null -eq $installResult) {
                    $anyFailed = $true
                    [void]$clientResults.Add($client + ': no structured result from the installer')
                }
                elseif ([string]$installResult.overall -eq 'failed') {
                    $anyFailed = $true
                    $failedNames = @(@($installResult.components) | Where-Object { $_.status -eq 'failed' } | ForEach-Object { [string]$_.component })
                    [void]$clientResults.Add($client + ': failed (' + ($failedNames -join ', ') + ')')
                }
                elseif ([string]$installResult.overall -eq 'partial') {
                    # Runtime/settings applied but tracking did not - report it
                    # honestly rather than calling the hook updated.
                    $anyFailed = $true
                    [void]$clientResults.Add($client + ': installed but tracking failed - reinstall to restore tracking')
                }
                else {
                    [void]$clientResults.Add($client + ': ok')
                }
            }
            catch {
                $anyFailed = $true
                [void]$clientResults.Add($client + ': ' + $_.Exception.Message)
                Write-Log 'ERROR' 'UPDATE' ('Failed to update ' + $record.friendlyName + ' for ' + $client + ': ' + $_.Exception.Message)
            }
        }

        # INDEPENDENT RE-VERIFICATION. The installer reporting success is not
        # sufficient evidence that the installation is now intact, so the
        # record is re-read and integrity re-evaluated before anything is
        # called "updated". Combined with the installer's structured result
        # (which distinguishes "installed but tracking failed" from success),
        # this is what stops a nominal success from being reported as a real one.
        if (-not $anyFailed) {
            try {
                $verifyRecord = Get-InstallRecordById -ToolRoot $ToolRoot -Id ([string]$record.id)
                if ($null -eq $verifyRecord) {
                    $anyFailed = $true
                    [void]$clientResults.Add('post-update verification: the installation is no longer tracked')
                }
                else {
                    $verifyResult = Get-InstallIntegrity -Record $verifyRecord -ToolRoot $ToolRoot
                    if ($verifyResult.Status -ne 'current') {
                        $anyFailed = $true
                        [void]$clientResults.Add('post-update verification: ' + $verifyResult.Detail)
                    }
                }
            }
            catch {
                $anyFailed = $true
                [void]$clientResults.Add('post-update verification failed: ' + $_.Exception.Message)
            }
        }

        if ($anyFailed) {
            [void]$failed.Add($displayName + ': ' + ($clientResults -join '; '))
            Write-Host ('  ' + (Get-Painted '! failed  ' $C.Red) + ' ' + (Get-Painted $displayName $C.Bold) + '  ' + (Get-Painted ($clientResults -join '; ') $C.Gray))
        }
        else {
            [void]$updated.Add($displayName)
            # Name the components actually repaired, and say plainly which were
            # left alone - "updated" must not imply every client was rewritten.
            $repairedText = if ($clientsToRepair.Count -gt 0) { $clientsToRepair -join ', ' } else { 'no client needed repair' }
            $untouchedText = ''
            if ($clientResultsSkipped.Count -gt 0) {
                $untouchedText = $script:MenuSep + 'untouched: ' + (@($clientResultsSkipped | ForEach-Object { ($_ -split ':')[0] }) -join ', ')
            }
            Write-Host ('  ' + (Get-Painted '+ updated' $C.Green) + ' ' + (Get-Painted $displayName $C.Bold) + '  ' + (Get-Painted ($scopeText + $script:MenuSep + $repairedText + $untouchedText) $C.Gray))
        }
    }

    Write-PhaseHeader 'Completed' $C.Done '='
    Write-Host (Get-Painted ('  Updated ' + $updated.Count + ' of ' + $toUpdate.Count + ' hook(s).') $C.White)
    if ($failed.Count -gt 0) {
        Write-ErrorLine ('  ' + $failed.Count + ' failed:')
        foreach ($f in $failed) { Write-NoteLine ('    ' + $f) }
    }
    if ($toSkip.Count -gt 0) {
        Write-NoteLine ('  ' + $toSkip.Count + ' skipped (missing source/target/profile) - review and reinstall manually if still needed:')
        foreach ($item in $toSkip) { Write-NoteLine ('    ' + (Get-HookFriendlyName (Get-RecordDisplayField $item.Record 'friendlyName' 'unknown-record')) + ' - ' + $item.Detail) }
    }
    Write-NoteLine '  Restart the Claude/Codex clients and review /hooks inside each affected project.'
    Write-Log 'INFO' 'DONE' ('Update installed hooks complete: updated=' + $updated.Count + ' failed=' + $failed.Count + ' skipped=' + $toSkip.Count + ' current=' + $current.Count)
    return 'done'
}

# The "Create or install a hook" sub-menu: create a new hook, install an
# existing one (item 1 of that list selects every individual hook at once,
# item 2 is the sync group), install from config, or update previously
# installed hooks (refresh existing installs from current source, no re-ask).
# Loops so that backing out of a sub-flow returns HERE (one step), not to the
# main menu. Returns 'done' after a completed sub-flow, or when the user backs
# out of this sub-menu.
function Invoke-CustomHookMenu {
    while ($true) {
        Write-PhaseHeader 'Create or Install a Hook' $C.Input '-'
        Write-MenuTitle 'Options:'
        Write-MenuLine 1 'Install an existing hook' '(sync group + hooks\ - interactive)'
        Write-MenuLine 2 'Create a new hook' '(guided templates)'
        Write-MenuLine 3 'Install from config' '(reads the hook''s .env - no questions)'
        # COMPATIBILITY ALIAS ONLY. The canonical, documented home for updating
        # installed hooks is the "Update installed hooks" management row in the
        # "Available hooks" list (followed there by hook status and uninstall).
        # That row's NUMBER moves whenever a shipped hook is added, so it is
        # derived here rather than written out - the alias may never claim a
        # stale index. This row is kept so existing muscle memory and scripted
        # answer sequences keep working - it calls exactly the same
        # Invoke-UpdateInstalledHooks implementation, never a second copy.
        $aliasUpdateIndex = @(@(Get-HookEntries) | Where-Object { $script:HookMeta.ContainsKey($_.Name) }).Count + 3
        Write-MenuLine 4 'Update installed hooks' ('(same as item ' + $aliasUpdateIndex + ' in the hook list)')
        $value = Read-Answer (New-QuestionPrompt 'Select an option' $null '1') 'custom hook menu'
        if ($value -eq '0') {
            Write-Log 'INFO' 'MENU' 'Create-or-install sub-menu -> 0. Back'
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        $subAction = @{ '1' = 'Install an existing hook'; '2' = 'Create a new hook'; '3' = 'Install from config'; '4' = 'Update previously installed hooks' }[$value]
        if ($subAction) { Write-Log 'INFO' 'MENU' ('Create-or-install sub-menu -> ' + $value + '. ' + $subAction) }
        switch ($value) {
            '1' { if ((Invoke-InstallExistingHook) -eq 'done') { return } }
            '2' { if ((Invoke-CreateHook) -eq 'done') { return } }
            '3' { if ((Invoke-InstallHookFromConfig) -eq 'done') { return } }
            '4' { if ((Invoke-UpdateInstalledHooks) -eq 'done') { return } }
            default { Write-ErrorLine 'Enter 1, 2, 3, 4 or 0.' }
        }
    }
}

# ------------------------------------------------------- info flows (2/3) ----
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
                if ($null -ne $route.source.PSObject.Properties['name']) { $sourceName = [string]$route.source.name } elseif ($null -ne $route.source.PSObject.Properties['root']) { $sourceName = [string]$route.source.root }
            }
            if ($null -ne $route.PSObject.Properties['destination'] -and $null -ne $route.destination) {
                if ($null -ne $route.destination.PSObject.Properties['name']) { $destinationName = [string]$route.destination.name } elseif ($null -ne $route.destination.PSObject.Properties['root']) { $destinationName = [string]$route.destination.root }
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
    Write-MenuLine 1 'Create or install a hook' '(sync group + hooks\ folder)'
    Write-MenuLine 2 'Show configured profiles'
    Write-MenuLine 3 'Validate configuration'
}

# ----------------------------------------------------------------- entry ----
Initialize-Log
Write-Log 'INFO' 'STARTUP' ('Execution id: ' + [guid]::NewGuid().ToString())
Write-Log 'INFO' 'STARTUP' ('Script: ' + $PSCommandPath)
# The real config is machine-local (git-ignored); seed it from the tracked
# example on first run so a fresh clone works out of the box.
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $examplePath = Join-Path $ToolRoot 'sync-hooks.example.json'
    if (Test-Path -LiteralPath $examplePath -PathType Leaf) {
        Copy-Item -LiteralPath $examplePath -Destination $ConfigPath -Force
        Write-Log 'INFO' 'STARTUP' ('Config seeded from example: ' + $examplePath + ' -> ' + $ConfigPath)
    }
}
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
        $menuPrompt = New-QuestionPrompt 'Select an option' $null '1' -QuitOnly
        while ($true) {
            $choice = Read-Answer $menuPrompt 'main menu'
            if ($choice -eq '') {
                $choice = '1'
            }
            $mainAction = @{ '1' = 'Create or install a hook'; '2' = 'Show configured profiles'; '3' = 'Validate configuration'; '0' = 'Exit' }[$choice]
            if ($mainAction) { Write-Log 'INFO' 'MENU' ('Main menu -> ' + $choice + '. ' + $mainAction) }
            switch ($choice) {
                '1' { Invoke-CustomHookMenu; continue menu }
                '2' { Show-Profiles; continue menu }
                '3' { Invoke-Validate; continue menu }
                '0' { break menu }
                default { Write-ErrorLine 'Enter 1, 2, 3 or 0.' }
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
