# Feature-Request-Check - a feature request runs the mattpocock chain.
#
# ROLE: ADVISORY on UserPromptSubmit, GATE (blocks once) on Stop/SubagentStop
# (global-hook-rules.md SS Hook Roles). Enforces the Skill Policy's
# "Installed Skill Families -> Feature requests": grilling + domain-modeling
# -> spec -> tickets -> implement, rather than jumping straight to code.
#
# WHY IT MAY BLOCK WHERE THE OTHER REMINDER HOOKS DO NOT: the cost is
# asymmetric and late. A skipped reminder about docs is a paragraph to write
# afterwards; a feature built without the grilling pass is a feature built to
# the wrong requirements, and that is only discovered once it is finished.
#
# WHAT IT WILL NOT DO, on purpose:
# - It never blocks without EVIDENCE. No transcript (Codex, an unknown client)
#   means no claim in either direction: silent, not an all-clear.
# - A partial transcript read never produces a block - it saw part of the
#   session and cannot know what the rest holds.
# - It blocks ONCE per set of feature prompts. The same unchanged set passes
#   silently on the next Stop; a NEW feature prompt re-arms it. A gate that
#   fires forever teaches people to work around it.
# - "This was not a feature" is a valid answer. The block text says so, and one
#   line of reasoning clears it.
#
# DETECTION IS DELIBERATELY CONSERVATIVE. A lone common verb never triggers:
# "add" needs an object within 60 characters, and any bug vocabulary in the
# prompt suppresses the verb path entirely, because "fix the crash by adding a
# guard" is a bug fix that happens to contain "adding". An explicit feature
# phrase ("feature request", "as a user", \u0641\u06cc\u0686\u0631) still wins on its own.
#
# ASCII source: Persian terms are \uXXXX escapes so the file reads identically
# under Windows PowerShell 5.1 and pwsh 7 with no BOM/encoding dependency.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

# ---- feature detection ------------------------------------------------------
# Kept in this hook rather than _hooklib.ps1: no second caller exists, and a
# shared definition earns its place when something else needs the same answer.
$script:FeatureBugPattern = @(
    '(?i)\b(fix|bug|error|crash|typo|broken|fails|failing|regression|stack ?trace)\b',
    '\u0628\u0627\u06af',                                       # bug (bag)
    '\u062e\u0637\u0627',                                       # error (khata)
    '\u0627\u0631\u0648\u0631',                                 # error, loan word (eror)
    '\u06a9\u0631\u0634',                                       # crash (kerash)
    '\u062e\u0631\u0627\u0628'                                  # broken (kharab)
) -join '|'

$script:FeatureExplicitPattern = @(
    '(?i)\bfeature\b',
    '(?i)\bfeature request\b',
    '(?i)\bnew capability\b',
    '(?i)\bas a user\b',
    '(?i)\bshould be able to\b',
    '(?i)\bmake it possible\b',
    '\u0641\u06cc\u0686\u0631',                                 # feature, loan word (ficher)
    '\u0642\u0627\u0628\u0644\u06cc\u062a',                     # capability (ghabeliyat)
    '\u067e\u06cc\u0627\u062f\u0647\u200c?\s?\u0633\u0627\u0632\u06cc'  # implementation (piade-sazi), ZWNJ or space
) -join '|'

# Verb + object within 60 characters. The window is what stops "add" in
# "add a comment explaining why" from reading as a feature request.
$script:FeatureVerbPattern = @(
    '(?i)\b(add|implement|build|create|introduce|support)\b[\s\S]{0,60}\b(feature|capability|command|button|page|screen|endpoint|api|option|setting|flag|mode|panel|menu|dialog|report|export|import|filter|search|login|auth|dashboard|hook|integration)\b',
    '\u0627\u0636\u0627\u0641\u0647\s+\u06a9\u0646',            # add (ezafe kon)
    '\u0627\u0636\u0627\u0641\u0647\s+\u06a9\u0646\u06cc\u0645', # let us add (ezafe konim)
    '\u0628\u0633\u0627\u0632',                                 # build (besaz)
    '\u0627\u06cc\u062c\u0627\u062f\s+\u06a9\u0646',            # create (ijad kon)
    '\u062f\u0631\u0633\u062a\s+\u06a9\u0646'                   # make (dorost kon)
) -join '|'

function Test-FeatureRequestPrompt {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $false }
    # An explicit phrase is decisive on its own - "the feature request is broken"
    # is still about a feature.
    if ($Prompt -match $script:FeatureExplicitPattern) { return $true }
    # Otherwise a build verb only counts when nothing says "this is a defect".
    if ($Prompt -match $script:FeatureBugPattern) { return $false }
    return ($Prompt -match $script:FeatureVerbPattern)
}

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'UserPromptSubmit' }
if ($eventName -ne 'UserPromptSubmit' -and $eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

$chainNote = @(
    'FEATURE REQUEST CHECK - this prompt reads as a feature request, so run the mattpocock chain instead of coding straight from it:',
    '1. Call the Skill tool twice: "grilling" (interrogate the request until the real requirement is known) and "domain-modeling".',
    '2. If docs/agents/issue-tracker.md is missing, run the setup procedure for those skills first.',
    '3. Write the spec, then split it into tickets.',
    '4. Implement ticket by ticket: tdd, then code-review, then commit.',
    'Not a feature - a fix, a one-file change, a question? Say so in one line and carry on; that is a complete answer.'
) -join "`n"

# ---- UserPromptSubmit: advise, once per prompt -------------------------------
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if (-not (Test-FeatureRequestPrompt -Prompt $prompt)) { exit 0 }
    $fingerprint = Get-ShortHash ($sessionId + '|' + $prompt)
    $statePath = Join-Path $stateDir ('FeatureRequestCheck-prompt-' + $projectKey + '.txt')
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
    }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($statePath, $fingerprint)
    }
    catch { }
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $chainNote
    exit $emit.ExitCode
}

# ---- Stop / SubagentStop: did the chain actually run? ------------------------
# Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
# for ANY gate's block, and exiting on it alone let one block silence the
# other twelve on the same Stop.
if (Test-StopStandDown -HookInput $hookInput -HookName 'Feature-Request-Check') { exit 0 }

# No transcript is NOT an all-clear and NOT a violation: it is no evidence.
# Codex does not supply one, so this half is Claude-only by nature.
$transcriptPath = [string](Get-Field $hookInput 'transcript_path')
if ([string]::IsNullOrWhiteSpace($transcriptPath)) { exit 0 }

$maxBytes = 20000000
if ($config.ContainsKey('MAX_TRANSCRIPT_BYTES')) {
    $parsed = 0
    if ([int]::TryParse([string]$config['MAX_TRANSCRIPT_BYTES'], [ref]$parsed) -and $parsed -ge 100000) { $maxBytes = $parsed }
}
$transcript = Read-ClaudeTranscript -Path $transcriptPath -MaxBytes $maxBytes
if (-not $transcript.Ok) { exit 0 }
# Partial means the beginning of the session was not read - exactly where the
# feature prompt and the grilling call would be.
if ($transcript.Partial) { exit 0 }

$featurePrompts = New-Object System.Collections.Generic.List[string]
$ranGrilling = $false
$ranDomainModeling = $false
foreach ($entry in @($transcript.Entries)) {
    if ($entry.Role -eq 'user') {
        # NEVER count this hook's own words. The advisory it emits says
        # "this prompt reads as a feature request", which matches the very
        # pattern searched for here - and injected hook context can reach
        # the transcript inside a user turn. A hook that finds evidence it
        # planted itself would arm its own gate in any session where it
        # once spoke, so anything carrying this hook's banner is skipped.
        $isOwnBanner = $entry.Text -match '(?im)^[ \t]*FEATURE REQUEST CHECK'
        if ((-not $isOwnBanner) -and (Test-FeatureRequestPrompt -Prompt $entry.Text)) {
            [void]$featurePrompts.Add($entry.Text)
        }
    }
    foreach ($skill in @($entry.SkillCalls)) {
        # Plugin-qualified or bare: "mattpocock-skills:grilling" and "grilling".
        # BOTH halves are the chain's opening: grilling finds the real requirement,
        # domain-modeling fixes the words it will be built in. One without the other
        # is half an interview, so each is tracked separately.
        if ($skill -match '(?i)(^|:)grilling$') { $ranGrilling = $true }
        if ($skill -match '(?i)(^|:)domain-modeling$') { $ranDomainModeling = $true }
    }
}

$chainRan = ($ranGrilling -and $ranDomainModeling)
if ($featurePrompts.Count -eq 0 -or $chainRan) { exit 0 }

# Fingerprint the SET of feature prompts: the same unfinished business must not
# block twice, but a new feature request must re-arm the gate.
$joined = (@($featurePrompts | ForEach-Object { Get-ShortHash $_ } | Sort-Object) -join ',')
$fingerprint = Get-ShortHash ($sessionId + '|' + $joined)
$gatePath = Join-Path $stateDir ('FeatureRequestCheck-gate-' + $projectKey + '.txt')
if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
    try { if (([System.IO.File]::ReadAllText($gatePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
}
try {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($gatePath, $fingerprint)
}
catch { }

$firstPrompt = [string]$featurePrompts[0]
if ($firstPrompt.Length -gt 120) { $firstPrompt = $firstPrompt.Substring(0, 120) + '...' }
$firstPrompt = $firstPrompt -replace '\s+', ' '

# Name the half that is actually absent, so the reply does not have to guess.
$missing = New-Object System.Collections.Generic.List[string]
if (-not $ranGrilling) { [void]$missing.Add('"grilling"') }
if (-not $ranDomainModeling) { [void]$missing.Add('"domain-modeling"') }
$missingNames = ($missing.ToArray() -join ' and ')

$blockMessage = @(
    ('FEATURE REQUEST CHECK - a feature request was detected in this session (first match: "' + $firstPrompt + '") but the mattpocock chain did not run: the transcript holds no Skill call to ' + $missingNames + '.'),
    'Either run it now IN ORDER - grilling + domain-modeling first, then to-spec, then to-tickets, then implement ticket by ticket (Skill tool, exact name:, e.g. mattpocock-skills:grilling) -',
    'or state in one line why this was not a feature, and finish. Both clear this.'
) -join "`n"

# Record the block so THIS hook's own re-entry is recognised; another
# gate's block must not mute it, and its own must not repeat.
$emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Feature-Request-Check' -FindingFingerprint $fingerprint -EventName $eventName -Message $blockMessage
exit $emit.ExitCode
