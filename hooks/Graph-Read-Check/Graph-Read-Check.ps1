# GraphReadCheck - before work starts (SessionStart), reminds the agent to
# prefer scoped graphify queries over broad source browsing for codebase-
# oriented parts of the task, per the graphify rule. The AI decides whether
# THIS task actually needs it - skipping the graph entirely is a fine and
# expected outcome for non-codebase work (docs, config, a single isolated
# edit, ...); this hook only makes the option visible, it never queries or
# reads the graph itself.
#
# Token-efficient by design:
# - Silent when graphify-out\graph.json does not exist (nothing to point at) -
#   the common case for most projects costs zero tokens.
# - The note is 4 short lines; skipping the graph stays a valid outcome.

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

# Only projects that actually keep a graph - nothing to suggest otherwise.
$graphPath = Join-Path $cwd 'graphify-out\graph.json'
if (-not (Test-Path -LiteralPath $graphPath -PathType Leaf)) {
    exit 0
}

$note = @(
    'GRAPH READ CHECK - this project has a graphify knowledge graph (graphify-out/graph.json). If, and only if, this task needs codebase understanding (architecture, cross-file relationships, "where is X used", refactor scope, ...), prefer a scoped query over broad file browsing:',
    '- graphify query "<question>" for a specific question.',
    '- graphify path "<A>" "<B>" for a relationship; graphify explain "<concept>" for a focused concept.',
    '- Skip this entirely for tasks that do not need it (isolated edits, docs, config, secrets, small fixes) - that is a fine and expected outcome; do not query the graph just because it exists.'
) -join "`n"

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
