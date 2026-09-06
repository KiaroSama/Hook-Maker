# McpUsageCheck - MCP tool usage, checked at BOTH ends of the task.
#
# ROLE (global-hook-rules.md, "Hook Roles"): ADVISORY on the pre-task events,
# GATE on Stop/SubagentStop - and the gate is deliberately narrow. It blocks on
# exactly ONE confirmed, reproducible condition: this session really did call a
# connected MCP server tool (the hook read the tool names out of the session
# transcript) and the closing summary carries no line naming which ones. Both
# halves are facts the hook observed, not a judgement about whether MCP *should*
# have been used - which is why the reverse case (no MCP tool called at all)
# stays a NON-BLOCKING advisory. The hook cannot prove a tool was needed, and
# "Output, Blocking, and Recovery" forbids a gate that fires on suspicion.
#
# EVENTS: SessionStart, UserPromptSubmit (open), Stop, SubagentStop (close).
# - SessionStart      states the policy AND the closing requirement up front, so
#                     the requirement is never a surprise at Stop.
# - UserPromptSubmit  reminds only when THIS prompt looks like it would
#                     materially benefit from docs/browser/database/GitHub/other
#                     MCP use, once per session, and records that the session was
#                     MCP-relevant so the closing half can tell "nothing was
#                     needed" from "something was needed and skipped".
# - Stop/SubagentStop verifies the summary line. Honours stop_hook_active.
#
# THE REQUIRED LINE: the closing summary must carry a line that STARTS with
# "MCP used:" - either naming the servers actually called, or the explicit
# "MCP used: none - <one-line reason>". That is not a meaningless "done"
# acknowledgement (which the rules forbid): the names are checkable against what
# the hook itself saw, and the "none" form must carry its reason.
#
# WHY THE MATCH IS ANCHORED: this hook's own output lands in the same transcript
# it later reads. An unanchored search for the token would therefore be
# satisfied by the hook's OWN instruction text. The pattern requires the token
# at the start of a transcript line (a literal \n escape inside a JSONL string,
# or a real line break), and no line of this hook's output ever starts with it.
# For the same reason this hook NEVER prints the tool-name prefix it searches
# for - printing it would make the next Stop detect "MCP was used" from nothing
# but this hook's own message.
#
# FAIL-OPEN / UNKNOWN: an absent or unreadable transcript is UNKNOWN, never an
# all-clear and never a block. The requirement is then stated as a plain
# advisory that says it could not be verified. That is also the permanent state
# on a client that supplies no transcript path.
#
# Optional .env next to this script (copy .env.example):
#   MCP_SUMMARY_ENFORCEMENT  block (default) | advisory | off

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')) { exit 0 }

# A Stop hook that re-fires on its own block is the classic hook loop; the
# client sets this flag on the re-entry and every Stop handler must honour it.
if ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop') {
    # Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
    # for ANY gate's block, and exiting on it alone let one block silence the
    # other twelve on the same Stop.
    if (Test-StopStandDown -HookInput $hookInput -HookName 'Mcp-Usage-Check') { exit 0 }
}

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$enforcement = 'block'
if ($config.ContainsKey('MCP_SUMMARY_ENFORCEMENT')) {
    $raw = ([string]$config['MCP_SUMMARY_ENFORCEMENT']).Trim().ToLowerInvariant()
    if ($raw -eq 'block' -or $raw -eq 'advisory' -or $raw -eq 'off') { $enforcement = $raw }
}

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$sessionPath = Join-Path $stateDir ('McpUsageCheck-session-' + $projectKey + '.json')
$gatePath = Join-Path $stateDir ('McpUsageCheck-gate-' + $projectKey + '.txt')

# The exact wording the closing summary must carry. Kept in one place so the
# instruction, the block message and the detector can never drift apart.
$requiredLine = 'MCP used: <server names>   (or exactly "MCP used: none - <one-line reason>")'
$requirement = 'CLOSING REQUIREMENT - end the final task summary with its own line starting "MCP used:" naming every connected MCP server actually called this task; if none were called, write "MCP used: none - <one-line reason>". Never list a server that was merely available.'

# ---- bounded transcript probe ---------------------------------------------
# A private copy rather than a shared helper: hooks\_hooklib.ps1 is owned
# elsewhere in this change, so this hook carries its own. Shared read (a live
# writer is never blocked), bounded tail, and the text is never stored,
# printed, hashed or forwarded - only searched.
#
# Returns $null when the transcript could not be read at all: UNKNOWN is a
# distinct answer from "not found" and must never become an all-clear.
function Get-TranscriptTailText {
    param([string]$Path, [int]$TailBytes = 262144)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $take = [int][Math]::Min([int64]$TailBytes, $stream.Length)
            if ($take -le 0) { return $null }
            if ($stream.Length -gt $take) { [void]$stream.Seek(-$take, [System.IO.SeekOrigin]::End) }
            $buffer = New-Object byte[] $take
            # Read in a LOOP: a single Read may legally return fewer bytes than
            # asked for, and a short read here would look like a missing summary
            # line - i.e. it would produce a FALSE BLOCK.
            $filled = 0
            while ($filled -lt $take) {
                $chunk = $stream.Read($buffer, $filled, $take - $filled)
                if ($chunk -le 0) { break }
                $filled += $chunk
            }
            if ($filled -le 0) { return $null }
            return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $filled)
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
}

# Anchored at the start of a transcript line so this hook's own instruction
# text (where the token never begins a line) can never satisfy it. A short
# markdown prefix - bullet, quote, heading, bold - is tolerated.
$summaryLinePattern = '(?i)(\\n|[\r\n])[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?MCP[ \t]+(?:servers?[ \t]+|tools?[ \t]+)?used[ \t]*:'

# Reports once per session per STATE token: an unchanged answer stays silent on
# the next Stop of the same session, a changed one is reported immediately.
function Test-ShouldReport {
    param([string]$StateToken)
    $fingerprint = Get-ShortHash ($sessionId + '|' + $eventName + '|' + $StateToken)
    try {
        if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
            if (([System.IO.File]::ReadAllText($gatePath)).Trim() -eq $fingerprint) { return $false }
        }
    }
    catch { }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($gatePath, $fingerprint, (New-Object System.Text.UTF8Encoding $false))
    }
    catch { }
    return $true
}

# ---- SessionStart: the policy AND the closing requirement -------------------
if ($eventName -eq 'SessionStart') {
    $note = @(
        'MCP USAGE CHECK - before working, consider the connected MCP servers and tools for this task:',
        '- Docs lookup (e.g. Context7) for any library/framework/API whose behavior may have changed - prefer live docs over memory.',
        '- Browser automation, database, GitHub, memory and other connectors when they materially help.',
        '- Use the smallest tool surface that completes and verifies the work; if no MCP fits, proceed without and say so.',
        $requirement
    ) -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- UserPromptSubmit: relevance gate + record it for the closing half ------
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    $relevant = $prompt -match '(?i)\b(library|framework|sdk\b|api\b|package|dependency|dependencies|browser|screenshot|website|webpage|\burl\b|database|\bdb\b|\bsql\b|github|pull request|\bpr\b|issue\b|deploy|endpoint|documentation|\bdocs?\b|integrat|webhook|scrape|crawl)\b'
    if (-not $relevant) { exit 0 }

    # One marker file carries BOTH jobs: the once-per-session anti-repeat, and
    # the record the Stop half reads to tell "no MCP was needed" apart from
    # "MCP was needed and skipped".
    $marker = $null
    try { $marker = Read-JsonFile $sessionPath } catch { $marker = $null }
    $alreadyReminded = ($null -ne $marker -and $sessionId -ne '' -and [string](Get-Field $marker 'sessionId') -eq $sessionId)
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Write-JsonFileAtomic -Path $sessionPath -Value ([pscustomobject]@{
                schema      = 1
                sessionId   = $sessionId
                relevant    = $true
                recordedUtc = [DateTime]::UtcNow.ToString('o')
            })
    }
    catch { }
    if ($alreadyReminded) { exit 0 }

    $note = @(
        'MCP USAGE CHECK - this task looks like connected MCP tools would materially help (library/API/docs, a page or URL, a database, GitHub, a deployment, durable memory).',
        '- Prefer live docs over recalled versions/APIs; prefer a first-party connector over guessing.',
        '- Use the smallest tool surface that completes AND verifies the work.',
        $requirement
    ) -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- Stop / SubagentStop: verify, then require -----------------------------
if ($enforcement -eq 'off') { exit 0 }

$tail = Get-TranscriptTailText ([string](Get-Field $hookInput 'transcript_path'))

# Was this session recorded as MCP-relevant by the pre-task half?
$sessionRelevant = $false
$marker = $null
try { $marker = Read-JsonFile $sessionPath } catch { $marker = $null }
if ($null -ne $marker -and $sessionId -ne '' -and [string](Get-Field $marker 'sessionId') -eq $sessionId) {
    $sessionRelevant = ([bool](Get-Field $marker 'relevant'))
}

if ($null -eq $tail) {
    # UNKNOWN: no transcript, unreadable, or a client that supplies none. State
    # the requirement, say plainly that it was not verified, never claim either
    # outcome. Once per session.
    if (-not $sessionRelevant) { exit 0 }
    if (-not (Test-ShouldReport 'unverified')) { exit 0 }
    $note = @(
        'MCP USAGE CHECK - the session transcript was not available to this hook, so MCP use could NOT be verified (this is not an all-clear).',
        $requirement,
        ('Required line: ' + $requiredLine)
    ) -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
    exit $emit.ExitCode
}

$hasSummaryLine = ($tail -match $summaryLinePattern)

# Server ids actually seen. Matched as a tool CALL - the client's own
# "name": "<tool>" record - not as a bare token anywhere in the text. A prompt
# or a code comment that merely MENTIONS a tool name must never be read as
# having called it: that would be a false positive, and a gate that fires on one
# is worse than no gate at all. A client whose transcript uses a different shape
# yields no match here and falls through to the advisory branch below, which is
# the correct degradation - never a fabricated block.
#
# Deliberately reported WITHOUT the tool-name prefix this hook searched for, so
# the next Stop cannot detect "MCP was used" from this hook's own message.
$servers = New-Object System.Collections.Generic.List[string]
foreach ($m in [regex]::Matches($tail, '"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__([A-Za-z0-9_.\-]+?)__')) {
    $id = $m.Groups[1].Value
    if ($id -ne '' -and -not $servers.Contains($id)) { [void]$servers.Add($id) }
    if ($servers.Count -ge 8) { break }
}
$usedMcp = ($servers.Count -gt 0)

# The requirement is met. Nothing to say - and nothing to repeat.
if ($hasSummaryLine) { exit 0 }

if ($usedMcp) {
    $names = (@($servers) | Sort-Object) -join ', '
    if (-not (Test-ShouldReport ('missing|' + $names))) { exit 0 }
    $reason = @(
        'MCP USAGE CHECK - this session called MCP server tool(s) and the closing summary does not report them.',
        ('Servers observed in this session: ' + $names + '.'),
        # The example is deliberately kept INLINE and quoted rather than shown on
        # a line of its own: this message lands in the same transcript the next
        # Stop reads, and an example at the start of a line would satisfy the
        # detector - the hook would then clear its own block.
        ('TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "MCP used:" and naming the servers actually used - e.g. "MCP used: ' + $names + '".'),
        'Name only servers whose tools were really called; drop any of the above that were not material to the result.'
    ) -join "`n"
    if ($enforcement -eq 'advisory') {
        $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $reason
        exit $emit.ExitCode
    }
    # Record the block so THIS hook's own re-entry is recognised; another
    # gate's block must not mute it, and its own must not repeat.
    Set-StopBlockMarker -HookInput $hookInput -HookName 'Mcp-Usage-Check'
    $emit = Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason
    exit $emit.ExitCode
}

# No MCP tool was called. The hook cannot prove one was needed, so this is an
# advisory even in block mode - and it is raised only for a session the pre-task
# half already recorded as MCP-relevant.
if (-not $sessionRelevant) { exit 0 }
if (-not (Test-ShouldReport 'none-used')) { exit 0 }
$note = @(
    'MCP USAGE CHECK - this task was flagged MCP-relevant at the prompt, and no connected MCP server tool was called all session.',
    'If a library/API/version fact, a page, a database, a repository, a deployment or durable memory was involved, that was very likely a missed check - verify it now rather than shipping a recalled answer.',
    ('Either way the summary must carry the line: ' + $requiredLine)
) -join "`n"
$emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
exit $emit.ExitCode
