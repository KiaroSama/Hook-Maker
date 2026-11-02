# Feature-Request-Check - a feature request runs the mattpocock chain.
#
# ROLE: detector/advisor on UserPromptSubmit/Stop/SubagentStop.
# Missing interview evidence is reported, never forced continuation.
# Skill Policy routes grilling + domain-modeling -> Spec Kit -> implement.
#
# Missing/partial transcripts stay silent, not all-clear. Complete evidence
# produces one passive reminder per prompt set; a new set re-arms it.
# "This was not a feature" plus a reason remains a valid answer.
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

# The feature-detection patterns and Test-FeatureRequestPrompt moved to
# ..\_scope.ps1 when Speckit-Check became their second caller - the exact
# condition the comment here used to name for keeping them local. Behaviour
# is unchanged: the patterns moved byte-for-byte.
. (Join-Path $PSScriptRoot '..\_scope.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
# Receipt for this Stop round (spec 007 RD-4): running now; pass, block or error
# when the gate finishes. A timeout kill leaves it running, never a pass.
$gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Feature-Request-Check' } else { $null }
try {
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'UserPromptSubmit' }
if ($eventName -ne 'UserPromptSubmit' -and $eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

# The closing carve-out line that used to sit here ("not a feature - a fix, a
# one-file change, a question? say so and carry on") was DELETED on
# 2026-09-19: the rules withdrew it. A bug fix now takes the spec-driven
# route too - diagnose first, then converge on a spec-bearing feature or the
# full chain - so telling the reader a fix is exempt would send them past the
# workflow the rules put them on. Speckit-Check names that route; this hook
# stays on the interview, which is the part a transcript can actually prove.
$chainNote = @(
    'FEATURE REQUEST CHECK - this prompt reads as a feature request, so run the chain instead of coding straight from it:',
    '1. Call the Skill tool twice: "grilling" (interrogate the request until the real requirement is known) and "domain-modeling".',
    '2. If docs/agents/issue-tracker.md is missing, run the setup procedure for those skills first.',
    '3. Then Spec Kit, in order: speckit-specify, speckit-clarify, speckit-plan, speckit-tasks, speckit-analyze, speckit-implement.',
    '4. Inside speckit-implement: tdd at the agreed seams, then code-review, then commit.',
    'Mid-task request delta: dated requirement IDs + acceptance criteria; amend active spec/plan/tasks (independent scope -> own feature), refresh skills/gates before dependent edits. Preserve original request order and stable IDs; resume earliest actionable unfinished work, record dependency exceptions, reconcile all at closure. Other project: exact permission or English Markdown owner handoff; never implicit source/staging/runner/provider repair. Read global-project-lifecycle-rules.md.',
    'Every question any step raises goes to the user - never a plausible default. Only the work that depends on the answer waits; independent work continues.'
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
    ('FEATURE REQUEST CHECK: first match "' + $firstPrompt + '"; no Skill call to ' + $missingNames + ' found in the complete transcript.'),
    'Advisory: run it now IN ORDER: grilling + domain-modeling, then Spec Kit in order: speckit-specify, clarify, plan, tasks, analyze, implement (exact installed keys).',
    'Or explain why this was not a feature. No forced continuation.'
) -join "`n"

# The prompt-set fingerprint above suppresses repeats without forcing continuation.
$emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $blockMessage
exit $emit.ExitCode
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
