# Mcp-Usage-Check - desktop control order (custom-instructions Section 6, spec 041).
# Dot-sourced; definitions only, no exit.
#
# "Desktop app control: agent-desktop MCP + skill FIRST; browser tools for web;
# computer-use only reported fallback." The hook cannot tell WHY computer-use
# was chosen, so it never blocks: it names the order once when a computer-use
# call appears with no earlier agent-desktop attempt (MCP call or skill load).
# Matched as tool-call records in the raw JSONL, never as prose mentions.

$script:ComputerUseCallPattern = '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"(?:mcp__[A-Za-z0-9_.\-]*computer[-_]?use[A-Za-z0-9_.\-]*__[A-Za-z0-9_.\-]+|computer)"'
$script:AgentDesktopPattern = '(?i)("(?:name|tool_name)"[ \t]*:[ \t]*"mcp__[A-Za-z0-9_.\-]*agent[-_]?desktop[A-Za-z0-9_.\-]*__|"skill"[ \t]*:[ \t]*"[A-Za-z0-9_.\-]*:?agent[-_]?desktop)'

# '' or the advisory text. $RawText is the session tail the hook already read.
function Get-DesktopRouteNote {
    param([AllowEmptyString()][string]$RawText)
    if ([string]::IsNullOrEmpty($RawText)) { return '' }
    $use = [regex]::Match($RawText, $script:ComputerUseCallPattern)
    if (-not $use.Success) { return '' }
    $desktop = [regex]::Match($RawText, $script:AgentDesktopPattern)
    if ($desktop.Success -and $desktop.Index -lt $use.Index) { return '' }
    return 'DESKTOP ROUTE: computer-use called with no earlier agent-desktop attempt. Order: agent-desktop MCP + skill FIRST, browser tools for web, computer-use only as a reported fallback with its reason.'
}
