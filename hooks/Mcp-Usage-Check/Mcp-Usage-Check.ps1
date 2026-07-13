# McpUsageCheck - before work starts (SessionStart), injects a compact
# reminder to consider the available MCP servers/tools for the task, per the
# user's rules (prefer live docs over memory for fast-changing APIs; use tools
# only when they materially help). The AI decides - nothing is forced.
#
# The note is 3 short lines; skipping MCPs stays a valid outcome.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
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

$note = @(
    'MCP USAGE CHECK - before working, consider the connected MCP servers and tools for this task:',
    '- Docs lookup (e.g. Context7) for any library/framework/API whose behavior may have changed - prefer live docs over memory.',
    '- Browser automation, database, GitHub, and other connectors when they materially help.',
    '- Use the smallest tool surface that completes and verifies the work; if no MCP fits, proceed without and that is fine.'
) -join "`n"

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
