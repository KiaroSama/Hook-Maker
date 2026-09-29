# Synapse-Rules-Check - the agent refreshes ITS OWN operating rules from the
# Synapse memory store at the start of a session, and writes back what the
# session taught before it ends.
#
# ROLE: ADVISORY (global-hook-rules.md SS Hook Roles). It reads nothing from
# Synapse and writes nothing to it - a PowerShell hook has no MCP client, and
# the memories are the AGENT's to fetch through `memory_digest` /
# `memory_retrieve`. This hook supplies the instruction and the measured
# settings, then checks at Stop whether the fetch actually happened. It never
# blocks: it cannot know whether a given session needed the store, and a memory
# reminder is not worth wedging a Stop over.
#
# WHY IT EXISTS, in the store's own words: a whole long session ran without a
# single Synapse query, and three rules already stored there were broken in
# that one session. The stored diagnosis is precise about the cause - "nothing
# in the session prompt reminds you, and hook reminders cover `.ai/` and not
# this. So it is exactly the step that gets skipped in a long working session
# that feels self-sufficient." This hook is that missing reminder.
#
# EVENTS: SessionStart (load), Stop/SubagentStop (write back), and
# UserPromptSubmit for ONE mid-session note: a Stop advisory reaches the user,
# not the model, so the only word that reaches the agent while it can still act
# is a prompt-time context note. It is said only when the transcript already
# shows a file-changing tool call and no Synapse read, and at most once per
# session - never per prompt. Deliberately NOT SessionEnd: by then the agent
# can no longer act, and the whole point of the closing half is that it still can.
#
# RELEVANCE GATE: silent unless this machine actually has a Synapse store, so
# a project on a host without one is never nagged.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')) { exit 0 }

# A Stop hook that re-fires on its own output is the classic hook loop; the
# client sets this flag on the re-entry and every Stop hook must honour it.
if ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop') {
    $stopActive = Get-Field $hookInput 'stop_hook_active'
    if ($null -ne $stopActive -and [bool]$stopActive) { exit 0 }
}

# ---- relevance gate: is Synapse actually set up on this machine? ------------
# Either signal is enough. SYNAPSE_HOME overrides the install path for a
# non-default layout; the store path is the one the memories themselves name.
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$synapseHome = ''
if ($config.ContainsKey('SYNAPSE_HOME')) { $synapseHome = [string]$config['SYNAPSE_HOME'] }
$storePath = Join-Path $env:USERPROFILE '.synapse\synapse.db'
$configured = $false
try { if (Test-Path -LiteralPath $storePath -PathType Leaf) { $configured = $true } } catch { }
if (-not $configured -and -not [string]::IsNullOrWhiteSpace($synapseHome)) {
    try { if (Test-Path -LiteralPath $synapseHome -PathType Container) { $configured = $true } } catch { }
}
if (-not $configured) { exit 0 }
$midSessionReminder = -not ($config.ContainsKey('MID_SESSION_REMINDER') -and [string]$config['MID_SESSION_REMINDER'] -eq '0')
if ($eventName -eq 'UserPromptSubmit' -and -not $midSessionReminder) { exit 0 }

# ---- SessionStart: load the rules, with the settings that make it work ------
if ($eventName -eq 'SessionStart') {
    $note = @(
        'SYNAPSE RULES CHECK - read the durable rules from Synapse BEFORE the first edit, not when someone tells you to.',
        'They are the user''s standing instructions and they change between sessions; a session that feels self-sufficient is exactly the one that skips this.',
        '',
        '1. Call `memory_digest` ONCE now, passing a `tokenBudget`. It is token-hungry - it returns each memory three times (items, text, sections).',
        '2. Do NOT read the result into context raw. Index it first (id | type | first ~110 chars), then read IN FULL only the few that match this task.',
        '3. For anything more specific, `memory_retrieve`: minScore 0.65 on an unfiltered query; filter by project with tags ["project:<slug>"].',
        '   NEVER pass minScore and tags together - the filter already did the relevance work and a correct result scores low behind it.',
        '   An empty result you expected to hit: re-query WITHOUT minScore and read scoreBreakdown. A 0.60-0.65 hit with real vector was clipped by the threshold; ~0.5 with vector near 0 is noise.',
        '   If the answer comes back ADJACENT rather than exact, re-query using the words the ANSWER would contain, not the words the question came in.',
        '4. A memory about the OUTSIDE WORLD''s current state - CI, deploy, billing, quota, a credential, whether a service is running - is an observation with a timestamp, never a property. Re-verify it before repeating it.'
    ) -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- was it read, and did the session change files? ------------------------
# Detected from this hook's own stdin transcript_path with a BOUNDED tail read.
# Only tool-call records are searched for; the text is never stored, printed or
# hashed, and a live writer is never blocked (shared read).
function Get-TranscriptTailText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $tailBytes = [int][Math]::Min([int64]262144, $stream.Length)
            if ($stream.Length -gt $tailBytes) { [void]$stream.Seek(-$tailBytes, [System.IO.SeekOrigin]::End) }
            $buffer = New-Object byte[] $tailBytes
            $read = $stream.Read($buffer, 0, $tailBytes)
            if ($read -le 0) { return '' }
            return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        }
        finally { $stream.Dispose() }
    }
    catch { return '' }
}

# A client-recorded file-mutating tool call, never prose (the same detector as
# Skills-Check's _skillstop.ps1). This hook's own notes never carry that record
# shape, so they cannot satisfy it.
function Test-SubstantiveWork {
    param([string]$RawTranscript)
    if ([string]::IsNullOrWhiteSpace($RawTranscript)) { return $false }
    return ($RawTranscript -match '"name"[ \t]*:[ \t]*"(Write|Edit|MultiEdit|NotebookEdit)"')
}

$tailText = Get-TranscriptTailText ([string](Get-Field $hookInput 'transcript_path'))
# MATCH THE CLIENT'S TOOL-CALL RECORD, NOT THE BARE TOKEN. This hook's own
# SessionStart note names memory_digest, memory_retrieve AND memory_write, and
# that note lands in the very transcript read here - a bare token search is
# satisfied by the hook's own words and reports "consulted" for a session that
# never queried anything, which makes the whole reminder unreachable. Only a
# "name": "mcp__synapse__memory_*" entry is evidence of a real call.
$consulted = ($tailText -match '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__[A-Za-z0-9_.\-]*synapse[A-Za-z0-9_.\-]*__memory_(digest|retrieve|write)"')
$worked = Test-SubstantiveWork $tailText

# A session-bound marker, because a long session pushes the SessionStart call
# out of the bounded tail: once seen, this session counts as having read it.
$sessionId = [string](Get-Field $hookInput 'session_id')
$cwd = [string](Get-Field $hookInput 'cwd')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$markerPath = Join-Path $stateDir ('SynapseRulesCheck-seen-' + $projectKey + '.json')
if ($consulted) {
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Write-JsonFileAtomic -Path $markerPath -Value ([pscustomobject]@{ schema = 1; sessionId = $sessionId; seenUtc = [DateTime]::UtcNow.ToString('o') })
    }
    catch { }
}
else {
    $marker = $null
    try { $marker = Read-JsonFile $markerPath } catch { $marker = $null }
    if ($null -ne $marker -and $sessionId -ne '' -and [string](Get-Field $marker 'sessionId') -eq $sessionId) { $consulted = $true }
}

# ---- UserPromptSubmit: one mid-session note, only with evidence ------------
if ($eventName -eq 'UserPromptSubmit') {
    if ($consulted -or -not $worked -or $sessionId -eq '') { exit 0 }
    $midPath = Join-Path $stateDir ('SynapseRulesCheck-mid-' + $projectKey + '.txt')
    $midKey = Get-ShortHash ($sessionId + '|mid|unread-after-work')
    try { if ((Test-Path -LiteralPath $midPath -PathType Leaf) -and ([System.IO.File]::ReadAllText($midPath).Trim()) -eq $midKey) { exit 0 } } catch { }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($midPath, $midKey)
    }
    catch { exit 0 }    # an undeliverable once-marker must not turn into a per-prompt note
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message 'SYNAPSE RULES CHECK: this session has already changed files and has not read the Synapse store. Call `memory_digest` once now (with a `tokenBudget`; index it, then read only what matches), then continue. This is said once per session.'
    exit $emit.ExitCode
}

if ($consulted) {
    $message = @(
        'SYNAPSE WRITE-BACK: the store was read this session. Before finishing, decide what it should now hold.',
        '- WRITE what is durable and reusable: a confirmed fact, a lesson with its reason, a decision and the rejected alternative, a verified command. Use `memory_write` with an `entityKey` so the new version SUPERSEDES the old one, plus a `project:<slug>` tag.',
        '- DO NOT write status snapshots, round history, closure evidence, a resolved bug with no transferable lesson, or anything an existing memory already covers.',
        '- If something in the store was CONTRADICTED this session - a cleared blocker, a renamed project, a changed environment fact - correct it in the SAME turn. A stale memory is more confident than no memory, which is what makes it expensive.',
        '- Never store secrets, credentials, tokens, or the contents of secrets.md / .env.',
        '- If nothing durable came out of this session, that is a normal answer; write nothing.'
    ) -join "`n"
}
else {
    $message = @(
        'SYNAPSE RULES CHECK: this session is ending and the Synapse store was never queried.',
        $(if ($worked) { 'This session changed files and never read the store: its standing rules governed that work unread - `memory_digest` once, with a `tokenBudget`, is the whole cost.' }
            else { 'If the session did real work, its standing rules governed that work and were not read - `memory_digest` once, with a `tokenBudget`, is the whole cost.' }),
        'If anything durable was learned, write it back with `memory_write` (entityKey + project tag) rather than leaving it only in `.ai/`.',
        'For a trivial turn this is nothing to act on.'
    ) -join "`n"
}

# Say it once per session-state: an unchanged answer does not repeat on every
# Stop of the same session, while a changed one is reported immediately.
$fingerprint = Get-ShortHash ($sessionId + '|' + $eventName + '|' + [string]$consulted + '|' + [string]$worked)
$gatePath = Join-Path $stateDir ('SynapseRulesCheck-gate-' + $projectKey + '.txt')
if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
    try { if (([System.IO.File]::ReadAllText($gatePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
}
try {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($gatePath, $fingerprint)
}
catch { }

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $message
exit $emit.ExitCode
