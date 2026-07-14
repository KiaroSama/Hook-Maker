# AiMemoryLoad - before work starts (SessionStart, UserPromptSubmit), loads
# .ai\memory.md (the AI Context Memory Policy's startup router) directly into
# context, per the policy's Mandatory Startup Gate: "read memory first." This
# saves the agent an explicit Read call and guarantees the router is actually
# seen before work begins - the router itself then points at only the
# specialized .ai\*.md files the CURRENT task needs (LESSON, REFERENCE, ...);
# this hook does not guess which ones, that stays the AI's call.
#
# Token-efficient by design:
# - Silent when .ai\memory.md does not exist (nothing to load).
# - CONTENT-fingerprinted, not time-cooled: shown once, then silent until
#   memory.md actually changes (e.g. a prior AiMemoryCheck Stop updated it) -
#   never repeats the same content across SessionStart/resume/compact events.
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

# ---- fingerprint the content (not the reminder text) so re-reads that find
# the file unchanged stay silent, but any real edit re-surfaces it ----
$fingerprint = Get-ShortHash $content
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
[void]$lines.Add('Use this as the starting point; per its own "Read Next" section, read only the specialized .ai/*.md files THIS task actually needs - do not load every file by default. This note stays silent until memory.md changes again.')

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
