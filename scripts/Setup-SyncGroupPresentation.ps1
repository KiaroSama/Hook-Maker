# ---------------------------------------------------------------------------
# Console presentation layer: the wizard's colour table, every helper that
# turns a value into a painted line (phase headers, labelled fields, menu rows
# and titles, error/note lines, numbered and nested question prompts), and the
# per-hook menu metadata the hook-menu renderers read.
#
# Split out of Setup-SyncGroup.ps1 (which had grown past the file-size review
# signal) because rendering is a distinct responsibility from driving the
# menus, install flows and hook authoring that render through it.
#
# Dot-sourced by Setup-SyncGroup.ps1 before the other wizard modules. That
# order is a readability convention, not a requirement: nothing reads $C or
# $script:HookMeta at load time. What DOES matter is that dot-sourcing splices
# both the functions AND the top-level state ($Esc, $C, $script:HookMeta,
# $script:MenuSep, $script:QuestionNumber, $script:BackText*) into the caller's
# scope - that is what makes $C visible to the wizard body and to every other
# Setup-SyncGroup* module. One outward dependency, resolved at call time:
# Get-HookFriendlyName from hooks\_hooklib.ps1.
#
# NOTE: $script:HookMeta is not presentation-only. It is the CANONICAL per-hook
# table - Order/Label/When/Text plus the optional Events/Timeout that
# Get-HookRecommendedEvents and Get-HookTimeoutArgs (still in
# Setup-SyncGroup.ps1) read, so those values cannot drift into a second table.
# It lives here because the menu renderers below are its densest consumers.
# ---------------------------------------------------------------------------

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
    # Menu 9-11, inserted above the documentation and graph hooks. The first
    # is a GATE at Stop (the only shipped hook that blocks on a skill chain);
    # the two Cbm-* hooks mirror the Graph-* pair for the Codebase Memory
    # index. Both pairs stay live: every project carries BOTH graphs, and the
    # Cbm-* pair answers for code structure while the Graph-* pair answers for
    # what graphify alone covers and its cross-cutting views.
    'Feature-Request-Check'            = @{ Order = 8;  When = 'both'; Text = 'a feature request runs the grilling chain, not straight to code'; Events = @('UserPromptSubmit', 'Stop', 'SubagentStop'); Timeout = 15 }
    'Cbm-Read-Check'                   = @{ Order = 9;  When = 'pre';  Text = 'query the Codebase Memory index before browsing files'; Events = @('SessionStart', 'UserPromptSubmit'); Timeout = 10 }
    'Cbm-Update-Check'                 = @{ Order = 10; When = 'post'; Text = 'reports a Codebase Memory index lagging behind the code'; Events = @('Stop', 'SubagentStop'); Timeout = 15 }
    'Docs-Freshness-Check'             = @{ Order = 11;  When = 'both'; Text = 'checks tracked docs after changes; requires ack' }
    'Graph-Read-Check'                 = @{ Order = 12;  When = 'pre';  Text = 'suggests graphify queries when a graph exists and the task needs it' }
    'Graph-Update-Check'               = @{ Order = 13; When = 'post'; Text = 'suggests graphify update when the graph is stale' }
    'Large-File-Check'                 = @{ Order = 14; When = 'both'; Text = 'small-files policy + oversized-file scan' }
    # 'both', not 'pre': these three now VERIFY at Stop as well as remind at
    # the start, and two of them block. A menu tag that still said pre-task
    # would promise a hook that cannot refuse anything.
    'Mcp-Usage-Check'                  = @{ Order = 15; When = 'both'; Text = 'MCP reminder, and an "MCP used:" line at the end'; Events = @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop'); Timeout = 10 }
    'Rules-Check'                      = @{ Order = 16; When = 'both'; Text = 'checks the rules were read, and confirmed at the end'; Events = @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop'); Timeout = 15 }
    # Skills-Check's real recommended EVENTS are SessionStart,UserPromptSubmit,Stop
    # (the Stop event carries the "Skills used:" summary requirement) - When must
    # be 'both', not 'pre' alone, or the menu tag disagrees with its actual timing.
    'Skills-Check'                     = @{ Order = 17; When = 'both'; Text = 'finds global/project/plugin skills, and names those used'; Events = @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop'); Timeout = 20 }
    'Secrets-Check'                    = @{ Order = 18; When = 'both'; Text = 'keeps secrets.md accurate and checks for leaks' }
    # 'both' (not 'pre+post') - Get-HookTimingTag's switch only recognizes
    # pre/post/both; an unrecognized value silently rendered NO timing tag at all.
    'Ignore-Rules-Check'               = @{ Order = 19; When = 'both'; Text = 'auto-fixes required local/private gitignore rules before and after tasks' }
    'Dependency-Version-Check'         = @{ Order = 20; When = 'both'; Text = 'flags outdated dependencies; requires a stated decision'; Events = @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop') }
    'Test-Temp-Cleanup'                = @{ Order = 21; When = 'both'; Text = 'cleans safe test cache/temp residue; keeps diagnostics' }
    # The three-stage test-health hooks (24.txt). Events/Timeout are the
    # CANONICAL per-hook values - Get-HookRecommendedEvents and the install call
    # read them from here, so name/order/timing/events/timeout cannot drift into
    # a second table. Text stays short for the same single-line reason as
    # Docs-Freshness-Check above.
    'Test-Plan-Check'                  = @{ Order = 22; When = 'pre';  Text = 'surfaces test-health policy before test or CI work'; Events = @('SessionStart', 'UserPromptSubmit'); Timeout = 15 }
    'Test-Run-Guard'                   = @{ Order = 23; When = 'both'; Text = 'requires a bounded runner for recognised test commands'; Events = @('PreToolUse', 'PostToolUse'); Timeout = 10 }
    'Test-Completion-Check'            = @{ Order = 24; When = 'post'; Text = 'verifies test evidence and cleanup before finishing'; Events = @('Stop', 'SubagentStop'); Timeout = 20 }
    # Utf8-Encoding-Check is also the third native pre-push chain stage
    # (Ignore -> Secrets -> Utf8 -> preserved user hook). Its position is
    # relative, not absolute - the numbers here went stale twice already.
    'Utf8-Encoding-Check'              = @{ Order = 25; When = 'both'; Text = 'blocks new/changed non-UTF-8 text; pre-push chain stage'; Events = @('SessionStart', 'Stop', 'SubagentStop'); Timeout = 30 }
    # Directly before Cloudflare-Deploy, per an explicit user requirement.
    # SessionStart loads the user's standing rules out of Synapse;
    # Stop/SubagentStop ask what this session should write back. NOT
    # UserPromptSubmit (the digest is a once-per-session read) and NOT
    # SessionEnd (by then the agent can no longer act on the answer).
    'Synapse-Rules-Check'              = @{ Order = 26; When = 'both'; Text = 'loads the user''s rules from Synapse; asks what to write back'; Events = @('SessionStart', 'Stop', 'SubagentStop'); Timeout = 10 }
    # Session-Summary-Check sits between Synapse-Rules-Check and
    # Cloudflare-Deploy per an explicit user requirement. That number is only
    # where it is LISTED. It is advisory and asks for the summary as the
    # closing section of the AGENT'S reply - and it asks BEFORE the task
    # (SessionStart, UserPromptSubmit), never at Stop: on Claude Code a Stop
    # additionalContext re-invokes the model, so a summary asked for at Stop
    # always arrived as one more turn after the work, which is the loop it
    # shipped with twice. See the hook header.
    'Session-Summary-Check'            = @{ Order = 27; When = 'pre'; Text = 'asks the closing reply for a done / still-open summary'; Events = @('SessionStart', 'UserPromptSubmit'); Timeout = 10 }
    # Cloudflare-Deploy is deliberately kept LAST among individual hook
    # entries (Order = highest value) per an explicit user requirement, not
    # filesystem/alphabetical order - see Test-Wizard.ps1 for the pinned order.
    'Cloudflare-Deploy'                = @{ Order = 28; When = 'post'; Text = 'suggests deploying in Cloudflare Workers projects, gated on release readiness' }
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

