# RulesCheck - before work starts (SessionStart, UserPromptSubmit), verifies
# that the configured rules directories were read: the user's GLOBAL rules
# (~\.claude\rules or ~\.codex\rules) and the current project's LOCAL rules
# (<project>\.claude\rules or <project>\.codex\rules).
#
# Client awareness: Claude Code exports CLAUDE_PROJECT_DIR on every spawned
# hook process (official docs), Codex does not - so the hook auto-detects
# which client is running and checks that client's rules directories. An
# explicit -Client claude|codex parameter overrides the detection.
#
# Token-efficient by design:
# - First check of a project: lists ALL rules files once and asks the AI to
#   confirm they are read before starting.
# - Afterwards it stays completely silent until a rules file is ADDED,
#   CHANGED, or REMOVED (fingerprint per project + client); then it reports
#   exactly what moved and asks for a re-read of those files only.
#
# Canonical rule routing (E-01), appended to the same fingerprint-gated note:
# - the canonical rule set is named by its canonical INSTALLED filenames only
#   (custom-instructions.md, WORKFLOWS.md, CODEWORDS.md,
#   ai-context-memory-policy.md, global-hook-rules.md, global-test-rules.md,
#   global-github-automation-rules.md; global-mcp-rules.md only for MCP work;
#   graphify.md only for codebase navigation) - never an uploaded/
#   version-suffixed copy such as "custom-instructions (17).md" (those are
#   additionally flagged when they appear in a rules directory);
# - EXACTLY ONE skill policy by detected client (codex ->
#   skill-policy-codex-optimized.md, claude/non-codex -> skill-policy.md),
#   never both;
# - strict-UTF-8 guidance for all newly written/modified text (BOM and no-BOM
#   are both UTF-8; any non-UTF-8 exception needs narrow scope + exact
#   encoding + technical reason + forcing system + verification).
# A standalone `::deep-debug` codeword on UserPromptSubmit additionally gets
# the bounded composite-workflow guardrails (native /goal preserved,
# ::multi-agent = one integration + final verification, Ponytail exactly once,
# no post-Ponytail loops), once per session per project+client. Ordinary prose
# "deep debug" never triggers that path (CODEWORDS.md: standalone :: token).
# DETECTOR/ADVISORY only: the hook reminds and routes; it never executes a
# slash command, codeword, or skill.
#
# Optional .env next to this script (copy .env.example):
#   GLOBAL_RULES_DIR  overrides the global rules directory (default:
#                     <home>\.claude\rules or <home>\.codex\rules by client)

param(
    # 'claude', 'codex', or '' for auto-detection via CLAUDE_PROJECT_DIR.
    [string]$Client = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) {
    $eventName = 'SessionStart'
}
# Context injection only makes sense for context events.
if ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop') {
    exit 0
}

# ---- which client is running? ----
$Client = $Client.Trim().ToLowerInvariant()
if ($Client -ne 'claude' -and $Client -ne 'codex') {
    if ([string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) {
        $Client = 'codex'
    }
    else {
        $Client = 'claude'
    }
}
$clientDirName = '.' + $Client

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

# ---- rules directories: global (home) + local (project) ----
# USERPROFILE first: Windows PowerShell 5.1 derives $HOME from HOMEDRIVE/HOMEPATH,
# which can disagree with the profile the user actually means.
$homeDir = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($homeDir)) {
    $homeDir = [string]$HOME
}
$globalRulesDir = ''
if ($config.ContainsKey('GLOBAL_RULES_DIR') -and $config['GLOBAL_RULES_DIR'] -ne '') {
    $globalRulesDir = $config['GLOBAL_RULES_DIR']
}
elseif (-not [string]::IsNullOrWhiteSpace($homeDir)) {
    $globalRulesDir = Join-Path $homeDir (Join-Path $clientDirName 'rules')
}
$projectRulesDir = Join-Path $cwd (Join-Path $clientDirName 'rules')

$ruleSets = @(
    [pscustomobject]@{ Label = 'Global rules'; Dir = $globalRulesDir },
    [pscustomobject]@{ Label = 'Project rules'; Dir = $projectRulesDir }
)

# One line per rules file: <path>|<size>|<mtimeUtcTicks>. The joined lines ARE
# the fingerprint; a diff against the stored lines names what moved.
$currentEntries = @{}
foreach ($set in $ruleSets) {
    if ($set.Dir -eq '' -or -not (Test-Path -LiteralPath $set.Dir -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $set.Dir -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $currentEntries[$file.FullName] = $file.FullName + '|' + $file.Length + '|' + $file.LastWriteTimeUtc.Ticks
    }
}

# ---- state (per project + client) ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('RulesCheck-' + $Client + '-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$firstRun = -not (Test-Path -LiteralPath $statePath -PathType Leaf)
$previousEntries = @{}
if (-not $firstRun) {
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($statePath)) {
            if ($line.Trim() -eq '') { continue }
            $path = $line.Split('|')[0]
            $previousEntries[$path] = $line
        }
    }
    catch { $firstRun = $true }
}

# Nothing configured and nothing remembered -> silent, zero tokens.
if ($firstRun -and $currentEntries.Count -eq 0) {
    exit 0
}

# ---- diff ----
$newFiles = New-Object System.Collections.Generic.List[string]
$changedFiles = New-Object System.Collections.Generic.List[string]
$removedFiles = New-Object System.Collections.Generic.List[string]
foreach ($path in @($currentEntries.Keys | Sort-Object)) {
    if (-not $previousEntries.ContainsKey($path)) {
        [void]$newFiles.Add($path)
    }
    elseif ($previousEntries[$path] -ne $currentEntries[$path]) {
        [void]$changedFiles.Add($path)
    }
}
foreach ($path in @($previousEntries.Keys | Sort-Object)) {
    if (-not $currentEntries.ContainsKey($path)) {
        [void]$removedFiles.Add($path)
    }
}
# ---- ::deep-debug codeword (UserPromptSubmit only) ----
# CODEWORDS.md: a codeword activates only as a standalone ::-prefixed token;
# ordinary prose ("let's deep debug this") must never trigger the workflow
# path. Advisory only - the hook never executes /goal, a codeword, or Ponytail.
$sessionId = [string](Get-Field $hookInput 'session_id')
$deepDebug = $false
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ($prompt -match '(?i)(^|\s)::deep-debug([\s.,;:!?]|$)') { $deepDebug = $true }
}
# Unchanged ::deep-debug guidance is suppressed per session: a repeat in the
# SAME session stays silent, a new session re-reports. Rule-file changes are
# fingerprinted separately above, so changed rule state still re-reports.
$ddStatePath = Join-Path $stateDir ('RulesCheck-dd-' + $Client + '-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if ($deepDebug -and $sessionId -ne '' -and (Test-Path -LiteralPath $ddStatePath -PathType Leaf)) {
    try {
        if (([System.IO.File]::ReadAllText($ddStatePath)).Trim() -eq $sessionId) { $deepDebug = $false }
    }
    catch { }
}

$rulesMoved = ($firstRun -or $newFiles.Count -gt 0 -or $changedFiles.Count -gt 0 -or $removedFiles.Count -gt 0)
if (-not $rulesMoved -and -not $deepDebug) {
    exit 0
}

# ---- build the note ----
# Client-conditional NATIVE references and the single active skill policy.
# Both stay plain text in the note - this hook never executes them.
if ($Client -eq 'codex') {
    $policyName = 'skill-policy-codex-optimized.md'
    $goalRef = 'the client-native goal command'
    $ponytailRef = 'the verified installed ponytail-audit capability (via this client''s supported invocation)'
}
else {
    $policyName = 'skill-policy.md'
    $goalRef = '/goal'
    $ponytailRef = '/ponytail:ponytail-audit (native)'
}
$lines = New-Object System.Collections.Generic.List[string]
if ($rulesMoved) {
    if ($firstRun) {
        [void]$lines.Add('RULES CHECK (' + $Client + ') - first check of this project. Before starting the task, make sure EVERY configured rules file below has been read and is applied:')
    }
    else {
        [void]$lines.Add('RULES CHECK (' + $Client + ') - the configured rules changed since the last check of this project. Read the new/changed files BEFORE starting the task:')
        foreach ($path in $newFiles) { [void]$lines.Add('- NEW: ' + $path) }
        foreach ($path in $changedFiles) { [void]$lines.Add('- CHANGED: ' + $path) }
        foreach ($path in $removedFiles) { [void]$lines.Add('- REMOVED: ' + $path + ' (no longer applies)') }
        if ($currentEntries.Count -gt 0) {
            [void]$lines.Add('Then confirm the FULL rule set is still applied:')
        }
    }
    foreach ($set in $ruleSets) {
        if ($set.Dir -eq '') { continue }
        $names = @($currentEntries.Keys |
            Where-Object { $_.StartsWith($set.Dir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object |
            ForEach-Object { $_.Substring($set.Dir.TrimEnd('\').Length + 1) })
        if ($names.Count -gt 0) {
            [void]$lines.Add('- ' + $set.Label + ' (' + $set.Dir + '): ' + ($names -join ', '))
        }
    }
    # Canonical routing (E-01): canonical installed names, exactly one skill
    # policy for the detected client, and the strict-UTF-8 text default. These
    # ride the same fingerprint gate, so they never repeat on an unchanged set.
    [void]$lines.Add('Canonical rule set (always the canonical installed filenames - never an uploaded/version-suffixed copy such as "custom-instructions (17).md"): custom-instructions.md, WORKFLOWS.md, CODEWORDS.md, ai-context-memory-policy.md, global-hook-rules.md, global-test-rules.md, global-github-automation-rules.md; global-mcp-rules.md only when MCP work applies; graphify.md only when codebase navigation applies.')
    [void]$lines.Add('Skill policy routing: active client = ' + $Client + ' -> load ONLY ' + $policyName + ' as the skill policy; never load the other agent''s skill policy and never both together.')
    [void]$lines.Add('ENCODING: every newly written or modified text file defaults to STRICT UTF-8; never trust OS/shell/runtime default encodings. UTF-8 with a BOM and without a BOM are both valid UTF-8 - the BOM is a separate compatibility decision. A non-UTF-8 exception requires a narrow path/scope, the exact encoding, a technical reason, the forcing system, and compatibility verification.')
    # A " (N).md" filename is the browser-download shape of an uploaded copy -
    # canonical rule files never carry it, so flag it instead of trusting it.
    $suffixedNames = @($currentEntries.Keys | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { $_ -match '\s\(\d+\)\.md$' } | Sort-Object -Unique)
    if ($suffixedNames.Count -gt 0) {
        [void]$lines.Add('WARNING - version-suffixed rule filename(s) present (an uploaded copy is NOT canonical; follow the canonical installed name instead): ' + ($suffixedNames -join ', '))
    }
    [void]$lines.Add('Rules already loaded in context only need a confirmation, not a re-read. This check stays silent until a rules file changes again.')
}
if ($deepDebug) {
    [void]$lines.Add('RULES CHECK (' + $Client + ') - standalone ::deep-debug codeword detected. Workflow bounds (WORKFLOWS.md "Deep Debug Orchestrator" + CODEWORDS.md):')
    [void]$lines.Add('- ::deep-debug is a BOUNDED composite workflow: end as DEEP DEBUG: COMPLETE or DEEP DEBUG: BLOCKED - never an endless audit/refactor/fix loop.')
    [void]$lines.Add('- ' + $goalRef + ' is a NATIVE command: never shadowed, aliased, converted into a codeword, or synthetically executed by a hook.')
    [void]$lines.Add('- ::multi-agent is a workflow dependency: independent owned workstreams, ONE integration of all results, then final verification on the unified tree - no recursive re-runs, no nested agent trees.')
    [void]$lines.Add('- Run ' + $ponytailRef + ' exactly ONCE, only after debugging, testing, security/review work, and integrated verification have completed.')
    [void]$lines.Add('- After Ponytail: only safe accepted simplifications, their targeted regression repair if needed, and final verification - never a new audit/refactor/debug cycle.')
}

# ---- persist state, then report ----
try {
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    if ($rulesMoved) {
        [System.IO.File]::WriteAllLines($statePath, [string[]]@($currentEntries.Values | Sort-Object))
    }
    if ($deepDebug -and $sessionId -ne '') {
        [System.IO.File]::WriteAllText($ddStatePath, $sessionId)
    }
}
catch { }

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
