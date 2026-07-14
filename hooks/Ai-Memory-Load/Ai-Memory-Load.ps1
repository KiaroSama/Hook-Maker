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

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$maxChars = 8000
if ($config.ContainsKey('MAX_CHARS')) {
    try { $maxChars = [int]$config['MAX_CHARS'] } catch { }
}

$content = ''
try {
    $content = [System.IO.File]::ReadAllText($memoryPath, [System.Text.Encoding]::UTF8)
}
catch {
    exit 0
}
if ([string]::IsNullOrWhiteSpace($content)) {
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
# surfaces it ----
$fingerprint = Get-ShortHash ($content + '|' + ($otherFiles -join ','))
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('AiMemoryLoad-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        if (([System.IO.File]::ReadAllText($statePath)).Trim() -eq $fingerprint) {
            exit 0
        }
    }
    catch { }
}

$truncated = $false
if ($content.Length -gt $maxChars) {
    $content = $content.Substring(0, $maxChars)
    $truncated = $true
}

try {
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($statePath, $fingerprint)
}
catch { }

$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('AI MEMORY LOADED - .ai/memory.md (this project''s startup router):')
[void]$lines.Add('')
[void]$lines.Add($content)
[void]$lines.Add('')
if ($truncated) {
    [void]$lines.Add('(truncated at ' + $maxChars + ' chars - read .ai/memory.md directly for the rest.)')
}
if ($otherFiles.Count -gt 0) {
    [void]$lines.Add('Other files present in .ai/ (not loaded here - read only the ones relevant to THIS task, per memory.md''s own routing above): ' + ($otherFiles -join ', '))
}
[void]$lines.Add('Use memory.md as the starting point; do not load every .ai file by default - only what this task actually needs. This note stays silent until memory.md or the .ai/ file list changes again.')

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
