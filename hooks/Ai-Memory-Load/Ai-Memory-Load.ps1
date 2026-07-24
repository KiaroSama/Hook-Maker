# AiMemoryLoad - before work starts (SessionStart, UserPromptSubmit), loads
# .ai\memory.md (the AI Context Memory Policy's startup router) directly into
# context, per the policy's Mandatory Startup Gate: "read memory first." This
# saves the agent an explicit Read call and guarantees the router is actually
# seen before work begins. It also LISTS every other top-level .ai\*.md file
# that currently exists (name only, not content) so the agent has full
# visibility of the whole .ai folder - not just memory.md - without paying to
# load files the current task does not need; the router's own "Read Next"
# section decides which of them are actually relevant, that stays the AI's
# call, exactly per the policy's "route by task, do not load everything"
# rule. ARCHIVE\ and TARGETS\ are deliberately excluded (never loaded by
# default / local-only workspace, per the policy).
#
# Token-efficient by design:
# - Silent when .ai\memory.md does not exist (nothing to load).
# - CONTENT-fingerprinted, not time-cooled: shown once, then silent until
#   memory.md's content OR the set of other .ai\*.md files changes (e.g. a
#   prior AiMemoryCheck Stop updated memory.md, or added a new file) - never
#   repeats the same content across SessionStart/resume/compact events.
# - Capped size (MAX_CHARS) as a safety valve; if memory.md exceeds it, the
#   injected excerpt says so and points at the file for the rest.
#
# UTF-8 (E-06): memory.md is STRICT-decoded as UTF-8 (BOM or no BOM). A legacy
# non-UTF-8 file is surfaced by path + classification only - raw bytes are
# never printed, mojibake is never injected, and the hook never transcodes.
# ::deep-debug (E-06): a STANDALONE ::deep-debug token on UserPromptSubmit
# (prose "deep debug" never matches) adds the deep-debug routing set to the
# router note once per session - routing TEXT only; the hook never loads the
# whole .ai/ and never executes a codeword, slash command, or skill.
#
# Optional .env next to this script (copy .env.example):
#   MAX_CHARS  maximum characters of memory.md to inject (default 8000)

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

$memoryPath = Join-Path $cwd '.ai\memory.md'
if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) {
    exit 0
}

# ---- ::deep-debug routing (E-06; UserPromptSubmit only) ----
# CODEWORDS.md: only a STANDALONE ::-prefixed token activates a codeword -
# prose "deep debug" never does. Routing TEXT only: the loader names the
# deep-debug file set but never loads extra files itself and never executes a
# codeword/skill. Shown once per session (tiny own state file below); when due,
# it forces the router note out even if memory.md's content fingerprint is
# otherwise unchanged, so the routing is never silently swallowed by dedup.
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$sessionId = [string](Get-Field $hookInput 'session_id')
$deepDebug = $false
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ($prompt -match '(?i)(^|\s)::deep-debug([\s.,;:!?]|$)') { $deepDebug = $true }
}
$ddStatePath = Join-Path $stateDir ('AiMemoryLoad-dd-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if ($deepDebug -and $sessionId -ne '' -and (Test-Path -LiteralPath $ddStatePath -PathType Leaf)) {
    try {
        if (([System.IO.File]::ReadAllText($ddStatePath)).Trim() -eq $sessionId) { $deepDebug = $false }
    }
    catch { }
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$maxChars = 8000
if ($config.ContainsKey('MAX_CHARS')) {
    try { $maxChars = [int]$config['MAX_CHARS'] } catch { }
}

# STRICT UTF-8 decode (E-06). The old replacement-character decode would inject
# mojibake from a legacy-encoded memory.md straight into model context. Invalid
# bytes are NEVER printed: the file is surfaced by path + classification only,
# and the hook never silently transcodes it - an explicit reviewed conversion
# by the agent is the only path back to a loadable file.
$bytes = $null
try { $bytes = [System.IO.File]::ReadAllBytes($memoryPath) } catch { exit 0 }
$content = ''
$invalidUtf8 = $false
try {
    $content = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    # A UTF-8 BOM is still valid UTF-8; strip the decoded U+FEFF so it never
    # leaks into context (ReadAllText used to do this implicitly).
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
}
catch { $invalidUtf8 = $true }
if (-not $invalidUtf8 -and [string]::IsNullOrWhiteSpace($content)) {
    exit 0
}

# ---- the rest of .ai\: top-level *.md files besides memory.md itself.
# Non-recursive (the policy's helper files live directly in .ai\), and
# ARCHIVE\/TARGETS\ are subdirectories so a top-level listing already skips
# them - matches "never load archives by default" / "local-only workspace".
$aiDir = Join-Path $cwd '.ai'
$otherFiles = @(Get-ChildItem -LiteralPath $aiDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'memory.md' } |
    Sort-Object Name |
    Select-Object -ExpandProperty Name)

# ---- fingerprint the content + the set of other files present, so re-reads
# that find both unchanged stay silent, but a real edit OR a new file re-
# surfaces it. An invalid-UTF-8 file fingerprints its BYTES (classification
# advisory shown once, then silent until the file changes). A DUE ::deep-debug
# routing note bypasses the dedup exactly once per session. ----
$contentToken = if ($invalidUtf8) { 'invalid-utf8|' + (Get-ShortHash ([Convert]::ToBase64String($bytes))) } else { $content }
$fingerprint = Get-ShortHash ($contentToken + '|' + ($otherFiles -join ','))
$statePath = Join-Path $stateDir ('AiMemoryLoad-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (-not $deepDebug -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    try {
        if (([System.IO.File]::ReadAllText($statePath)).Trim() -eq $fingerprint) {
            exit 0
        }
    }
    catch { }
}

$truncated = $false
if (-not $invalidUtf8 -and $content.Length -gt $maxChars) {
    $content = $content.Substring(0, $maxChars)
    $truncated = $true
}

try {
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($statePath, $fingerprint)
    if ($deepDebug) { [System.IO.File]::WriteAllText($ddStatePath, $sessionId) }
}
catch { }

$lines = New-Object System.Collections.Generic.List[string]
if ($invalidUtf8) {
    # E-06: legacy non-UTF-8 memory is surfaced by path + classification ONLY.
    # No raw bytes, no replacement-character mojibake, no silent transcoding.
    [void]$lines.Add('AI MEMORY LOAD: .ai/memory.md exists but is NOT valid UTF-8 (legacy/unknown encoding). Its contents were NOT loaded and are not shown - raw bytes are never printed.')
    [void]$lines.Add('Every .ai/ file read or created must be UTF-8. Review and convert this file explicitly (a reviewed conversion by the agent - never a silent transcode by a hook); it will load normally once valid.')
}
else {
    [void]$lines.Add('AI MEMORY LOADED - .ai/memory.md (this project''s startup router):')
    [void]$lines.Add('')
    [void]$lines.Add($content)
    [void]$lines.Add('')
    if ($truncated) {
        [void]$lines.Add('(truncated at ' + $maxChars + ' chars - read .ai/memory.md directly for the rest.)')
    }
}
if ($otherFiles.Count -gt 0) {
    [void]$lines.Add('Other files present in .ai/ (not loaded here - read only the ones relevant to THIS task, per memory.md''s own routing above): ' + ($otherFiles -join ', '))
}
[void]$lines.Add('Use memory.md as the starting point; do not load every .ai file by default - only what this task actually needs. This note stays silent until memory.md or the .ai/ file list changes again.')
if ($deepDebug) {
    # E-06: routing text only for the standalone ::deep-debug codeword - the
    # loader names the set, the agent loads only what exists and is relevant.
    [void]$lines.Add('')
    [void]$lines.Add('::deep-debug memory routing: after memory.md, load ONLY the existing, task-relevant files from CONTEXT.md, REFERENCE.md, COMMANDS.md, BUGS.md, EDGE_CASES.md, TESTING_NOTES.md (+ SECURITY_NOTES.md when the work is security-sensitive), DECISIONS.md, LESSON.md, and the project-local WORKFLOWS.md/PLAYBOOKS.md when present. Never load the whole .ai/ directory, never copy global rules into .ai/, and a missing optional file is not a reason to create empty boilerplate.')
    [void]$lines.Add('Every .ai/ file read or created must be UTF-8; surface a legacy non-UTF-8 .ai file by path + classification only - never print raw bytes and never silently transcode it.')
}

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
