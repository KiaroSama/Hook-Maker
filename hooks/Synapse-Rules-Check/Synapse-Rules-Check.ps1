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
    $note = 'Synapse-Rules-Check: advisory, read recall before first edit: memory_digest once with tokenBudget, index id/type/preview then full task matches; memory_retrieve minScore0.65 OR project:<slug> tags, never both. Empty expected: remove threshold/read scoreBreakdown (real vector0.60-0.65 vs near-zero vector noise); adjacent answer: query answer terms. Recall != canonical policy/project truth or operation/account consent; private local, no raw memory disclosure.'
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
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message 'SYNAPSE: files changed without store read. Once now: `memory_digest` + `tokenBudget`; index, read matches, continue. Once/session.'
    exit $emit.ExitCode
}

if ($consulted) {
    $message = 'Synapse-Rules-Check: advisory write-back of new durable facts/reasons/decisions/rejected alternatives/verified commands via memory_write + entityKey/project:<slug>; correct contradicted memory this turn. No status/history/closure-only/duplicate notes or secrets/.env/registry contents; no durable learning means no write.'
}
else {
    $message = @(
        'SYNAPSE RULES CHECK: store never queried this session.',
        $(if ($worked) { 'Files changed: read standing rules now; `memory_digest` ONCE + `tokenBudget`.' }
            else { 'Real work: read standing rules; `memory_digest` ONCE + `tokenBudget`.' }),
        'Durable learning: `memory_write` + entityKey/project tag; `.ai/` alone insufficient.',
        'Trivial turn: no action.'
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
