# McpUsageCheck - two events:
# - SessionStart: loads the compact MCP policy once (prefer live docs over
#   memory for fast-changing APIs; use tools only when they materially help).
# - UserPromptSubmit: reminds only when THIS task's prompt looks like it would
#   materially benefit from docs/browser/database/GitHub/other MCP use (e.g.
#   mentions a library/API, a URL/page, a database, a PR/issue, or similar) -
#   stays silent for prompts with no such signal, so it never nags on trivial
#   turns. The AI still decides; nothing is forced either way.
#
# Token-efficient by design:
# - SessionStart always fires once per session (matches the cheap 4-line
#   design; no state file needed there).
# - UserPromptSubmit is gated by BOTH a relevance check on the prompt text AND
#   a per-session fingerprint, so an unchanged reminder is not repeated.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

$note = @(
    'MCP USAGE CHECK - before working, consider the connected MCP servers and tools for this task:',
    '- Docs lookup (e.g. Context7) for any library/framework/API whose behavior may have changed - prefer live docs over memory.',
    '- Browser automation, database, GitHub, and other connectors when they materially help.',
    '- Use the smallest tool surface that completes and verifies the work; if no MCP fits, proceed without and that is fine.'
) -join "`n"

if ($eventName -eq 'SessionStart') {
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# UserPromptSubmit: only when the prompt itself suggests MCP tools would help.
$cwd = [string](Get-Field $hookInput 'cwd')
$prompt = [string](Get-Field $hookInput 'prompt')
$relevant = $prompt -match '(?i)\b(library|framework|sdk\b|api\b|package|dependency|dependencies|browser|screenshot|website|webpage|\burl\b|database|\bdb\b|\bsql\b|github|pull request|\bpr\b|issue\b|deploy|endpoint|documentation|\bdocs?\b|integrat|webhook|scrape|crawl)\b'
if (-not $relevant) { exit 0 }

$sessionId = [string](Get-Field $hookInput 'session_id')
$fingerprint = Get-ShortHash ($sessionId + '|mcp-relevant')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('McpUsageCheck-prompt-' + (Get-ShortHash ([string]$cwd).ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 }
    }
    catch { }
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, $fingerprint)

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
exit $emit.ExitCode
