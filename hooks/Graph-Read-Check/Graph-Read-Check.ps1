# GraphReadCheck - two events, both gated on graphify-out\graph.json existing
# (nothing to point at otherwise - the common case costs zero tokens):
# - SessionStart: the compact graph-availability policy, once per session.
# - UserPromptSubmit: reminds only when THIS task's prompt looks like it needs
#   codebase structure/dependency/call-path/architecture/broad-impact
#   understanding - stays silent for docs-only, trivial text/config, isolated
#   literal, or clearly local changes. The AI still decides; this hook never
#   queries or reads the graph itself, and never forces Graphify.
#
# Token-efficient by design:
# - Silent when graphify-out\graph.json does not exist, for either event.
# - UserPromptSubmit is gated by BOTH a relevance check on the prompt text AND
#   a per-session fingerprint, so an unchanged reminder is not repeated.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

# Only projects that actually keep a graph - nothing to suggest otherwise.
$graphPath = Join-Path $cwd 'graphify-out\graph.json'
if (-not (Test-Path -LiteralPath $graphPath -PathType Leaf)) { exit 0 }

$note = @(
    'GRAPH READ CHECK - this project has a graphify knowledge graph (graphify-out/graph.json). If, and only if, this task needs codebase understanding (architecture, cross-file relationships, "where is X used", refactor scope, ...), prefer a scoped query over broad file browsing:',
    '- graphify query "<question>" for a specific question.',
    '- graphify path "<A>" "<B>" for a relationship; graphify explain "<concept>" for a focused concept.',
    '- Skip this entirely for tasks that do not need it (isolated edits, docs, config, secrets, small fixes) - that is a fine and expected outcome; do not query the graph just because it exists.'
) -join "`n"

if ($eventName -eq 'SessionStart') {
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# UserPromptSubmit: only when the prompt itself suggests codebase-structure work.
$prompt = [string](Get-Field $hookInput 'prompt')
$relevant = $prompt -match '(?i)\b(architecture|refactor|cross-file|cross file|call path|call graph|dependenc|where is|used by|impact|structure|entry point|module|integrat|codebase|call site|caller|callers|inherit)'
if (-not $relevant) { exit 0 }

$sessionId = [string](Get-Field $hookInput 'session_id')
$fingerprint = Get-ShortHash ($sessionId + '|graph-relevant')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('GraphReadCheck-prompt-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 }
    }
    catch { }
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, $fingerprint)

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
