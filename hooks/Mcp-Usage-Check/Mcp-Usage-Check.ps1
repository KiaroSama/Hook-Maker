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
#   MCP_SUMMARY_ENFORCEMENT  advisory (default) | block | off

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')
# The shared "is this work" classifier, so the research reminder and the
# Spec Kit hooks can never disagree about whether a prompt described work.
. (Join-Path $PSScriptRoot '..\_scope.ps1')
# Desktop control order advisory (spec 041).
. (Join-Path $PSScriptRoot '_desktoproute.ps1')
. (Join-Path $PSScriptRoot '_connectortriggers.ps1')

# RESEARCH BEFORE EVERY TASK (global-research-rules.md, order 55 step 5). The
# text is fixed by the order; the hook browses nothing, writes no note and can
# never tell whether research happened, so it only ever REMINDS - per request,
# because a new topic in the same session must never be silenced by an earlier
# one. The single exemption is the one the rule makes: a typo or text-only edit.
$script:ResearchReminder = @(
    'RESEARCH: each substantive request: global-research-rules.md FULL; live official + three GitHub passes -> .ai/RESEARCH/ sources+digest BEFORE dependents.',
    '- Calls/old notes != research; source failure blocks dependents only. Hook proves nothing.'
) -join "`n"
# ponytail: a keyword test, not a parser - "fix the typo and add a feature" is
# treated as text-only. Tighten it if that shape is ever seen for real.
$script:TextOnlyPromptPattern = '(?i)\b(typos?|spelling|misspell\w*|punctuation|wording|rephrase|reword)\b'

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
# Receipt for this Stop round (spec 007 RD-4): running now; pass, block or error
# when the gate finishes. A timeout kill leaves it running, never a pass.
$gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Mcp-Usage-Check' } else { $null }
try {
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'Stop', 'SubagentStop')) { exit 0 }
if ($eventName -eq 'PreToolUse') {
    $preToolName = [string](Get-Field $hookInput 'tool_name')
    if ($preToolName -notmatch '(?i)^(?:mcp__(?:Scrapling[-_]?Server|(?:plugin_[A-Za-z0-9_.\-]*_)?(?:playwright|rust[-_]?anything)|[A-Za-z0-9_.\-]*computer[-_]?use)|computer$|Edit$|Write$|MultiEdit$)') { exit 0 }
}

# A Stop hook that re-fires on its own block is the classic hook loop; the
# client sets this flag on the re-entry and every Stop handler must honour it.
if ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop') {
    # Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
    # for ANY gate's block, and exiting on it alone let one block silence the
    # other twelve on the same Stop.
    if (Test-StopStandDown -HookInput $hookInput -HookName 'Mcp-Usage-Check') { exit 0 }
}

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$enforcement = 'advisory'
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
$triggerPath = Join-Path $stateDir ('McpUsageCheck-trigger-' + $projectKey + '.json')

# The exact wording the closing summary must carry. Kept in one place so the
# instruction, the block message and the detector can never drift apart.
$requiredLine = 'MCP used: <servers> OR MCP used: none - <reason>'
$requirement = 'Close: "MCP used: <servers>" or "MCP used: none - <reason>"; available != used.'

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

# Which transcript the FALLBACK reader should open when _stoplib.ps1 is absent.
# A subagent event must never be answered from the parent's transcript.
function Get-EvidenceTranscriptFallbackPath {
    param($HookInput)
    return (Get-EvidenceTranscriptPath -HookInput $HookInput)
}


# Anchored at the start of a transcript line so this hook's own instruction
# text (where the token never begins a line) can never satisfy it. A short
# markdown prefix - bullet, quote, heading, bold - is tolerated.
$summaryLinePattern = '(?im)(?:^|\\n)[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?MCP[ \t]+(?:servers?[ \t]+|tools?[ \t]+)?used[ \t]*:'

# Reports once per session per STATE token: an unchanged answer stays silent on
# the next Stop of the same session, a changed one is reported immediately.
function Test-ShouldReport {
    param([string]$StateToken)
    $scopeEvent = $(if ($StateToken -match '^(pairing\||desktop-route$)') { 'session' } else { $eventName })
    $fingerprint = (Get-HookSuppressionIdentity -HookInput $hookInput) + '|' + $scopeEvent + '|' + $StateToken
    $claim = Invoke-DeliveryClaim -Path ($gatePath + '.claims.json') -Identity (Get-DeliveryIdentity $hookInput) -Fingerprint $fingerprint
    if (-not $claim.Ok) {
            $null=$claim.Reason # R035 unknown reservation: silent.
    }
    return $claim.Admitted
}

# ---- SessionStart: the policy AND the closing requirement -------------------
if ($eventName -eq 'SessionStart') {
    $carry = Get-CarryoverText $hookInput
    $note = @(
        'Mcp-Usage-Check: advisory connector review:',
        '- BEFORE selection: global-mcp-rules.md/global-mcp-server-contracts.md FULL; research owner FULL, live docs/GitHub -> .ai/RESEARCH/.',
        '- Material browser/DB/GitHub/memory connectors only.',
        '- Smallest verifying tool; no fit: proceed/explain none.',
        $requirement
    ) -join "`n"
    if ($carry -ne '') { $note += "`n" + $carry }
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- PreToolUse: mid-turn pairing, desktop-route, and carryover notices -----
if ($eventName -eq 'PreToolUse') {
    if ($enforcement -eq 'off') { exit 0 }
    $preNotes = New-Object System.Collections.Generic.List[string]
    $carry = Get-CarryoverText $hookInput
    if ($carry -ne '') { [void]$preNotes.Add($carry) }
    if (Get-Command Get-ConnectorPreToolNotes -ErrorAction SilentlyContinue) {
        $preTail = [string](Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput))
        foreach ($pn in @(Get-ConnectorPreToolNotes -ToolName $preToolName -ToolInput (Get-Field $hookInput 'tool_input') -RawText $preTail)) {
            $tok = $(if ($pn.StartsWith('DESKTOP ROUTE:')) { 'desktop-route' } else { 'pairing|' + $pn.Split(':')[0] })
            if (Test-ShouldReport $tok) { [void]$preNotes.Add($pn) }
        }
    }
    if ($preNotes.Count -eq 0) { exit 0 }
    $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message ($preNotes -join "`n")
    exit $emit.ExitCode
}

# ---- UserPromptSubmit: relevance gate + record it for the closing half ------
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    $operationNote = Get-OperationMcpReminder -HookInput $hookInput -Client (Get-HookClientId) -ProjectRoot $cwd -StateDir $stateDir
    # V94-V95 connector triggers: per-session map (bounded to 16 sessions) so
    # concurrent sessions retain their triggers for Stop while an unchanged
    # (sessionId, prompt) repeat stays quiet.
    $triggerPrompt = $(if ($prompt -match $script:TextOnlyPromptPattern) { '' } else { $prompt })
    $rawTriggerLine = Get-ConnectorTriggerLine -Prompt $triggerPrompt
    $curTriggers = Get-ConnectorTriggerKeys -Prompt $triggerPrompt
    $promptHash = Get-ShortHash ($sessionId + '|' + $prompt)
    $sameTriggerPrompt = $false
    try {
        $sessMap = [ordered]@{}
        $oldTr = Read-JsonFile $triggerPath
        if ($null -ne $oldTr -and $null -ne $oldTr.PSObject.Properties['sessions'] -and $null -ne $oldTr.sessions) {
            foreach ($p in @($oldTr.sessions.PSObject.Properties)) {
                if ($p.Name -ne $sessionId) { $sessMap[$p.Name] = $p.Value }
                elseif ([string](Get-Field $p.Value 'promptHash') -eq $promptHash) { $sameTriggerPrompt = $true }
            }
        }
        if ($sessionId -ne '') {
            while ($sessMap.Count -ge 16) { $sessMap.RemoveAt(0) }
            $sessMap[$sessionId] = [pscustomobject]@{ triggers = $curTriggers; promptHash = $promptHash }
        }
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Write-JsonFileAtomic -Path $triggerPath -Value ([pscustomobject]@{ schema = 2; sessionId = $sessionId; triggers = $curTriggers; sessions = [pscustomobject]$sessMap })
    }
    catch { }
    $triggerLine = $(if ($sameTriggerPrompt) { '' } else { $rawTriggerLine })
    $relevant = $operationNote -ne '' -or $rawTriggerLine -ne '' -or $prompt -match '(?i)\b(library|framework|sdk\b|api\b|package|dependency|dependencies|browser|screenshot|website|webpage|\burl\b|database|\bdb\b|\bsql\b|github|pull request|\bpr\b|issue\b|deploy|endpoint|documentation|\bdocs?\b|integrat|webhook|scrape|crawl)\b'

    # Research is due on every SUBSTANTIVE prompt - work on the project, or a
    # technical question - not only on dependency words. Keyed by the request:
    # the same prompt repeated is said once, a different one is always said.
    $researchDue = $false
    if (-not [string]::IsNullOrWhiteSpace($prompt) -and $prompt -notmatch $script:TextOnlyPromptPattern -and
        ($relevant -or (Test-ProjectChangingPrompt -Prompt $prompt))) {
        $researchPath = Join-Path $stateDir ('McpUsageCheck-research-' + $projectKey + '.txt')
        $researchKey = Get-ShortHash ($sessionId + '|' + $prompt)
        $seen = ''
        try { if (Test-Path -LiteralPath $researchPath -PathType Leaf) { $seen = ([System.IO.File]::ReadAllText($researchPath)).Trim() } } catch { $seen = '' }
        if ($seen -ne $researchKey) {
            $researchDue = $true
            try {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
                [System.IO.File]::WriteAllText($researchPath, $researchKey)
            }
            catch { }
        }
    }
    # Stop advisories of the previous turn reached only the user (systemMessage);
    # this hook runs on every prompt in every package, so it re-delivers them
    # to the model here, ahead of anything else it says (order 105 item 2).
    $carry = Get-CarryoverText $hookInput
    if (-not $relevant) {
        if ($carry -ne '') {
            $msg = $(if ($researchDue) { $carry + "`n" + $script:ResearchReminder } else { $carry })
            exit (Write-HookResult -EventName $eventName -Kind 'context' -Message ('Mcp-Usage-Check: ' + $msg)).ExitCode
        }
        if ($researchDue) {
            $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $script:ResearchReminder -HookInput $hookInput -HookName 'Mcp-Usage-Check' -FindingFingerprint $researchKey
            exit $emit.ExitCode
        }
        exit 0
    }

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
    if ($alreadyReminded) {
        $notes = @()
        if ($carry -ne '') { $notes += $carry }
        if ($triggerLine -ne '') { $notes += $triggerLine }
        if ($researchDue) { $notes += $script:ResearchReminder }
        if ($operationNote -ne '') { $notes += $operationNote }
        if ($notes.Count -gt 0) {
            $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($notes -join "`n")
            exit $emit.ExitCode
        }
        exit 0
    }

    $noteLines = @(
        'Mcp-Usage-Check: advisory library/API/docs/URL/DB/GitHub/deploy/memory connector match.',
        '- BEFORE selection: global-mcp-rules.md/global-mcp-server-contracts.md FULL; live docs, not recalled API/guess.',
        '- Smallest complete verifying tool.',
        $requirement
    )
    if ($triggerLine -ne '') { $noteLines += $triggerLine }
    if ($researchDue) { $noteLines += $script:ResearchReminder }
    if ($operationNote -ne '') { $noteLines += $operationNote }
    if ($carry -ne '') { $noteLines = @($noteLines[0], $carry) + @($noteLines | Select-Object -Skip 1) }
    $note = $noteLines -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- Stop / SubagentStop: verify, then require -----------------------------
if ($enforcement -eq 'off') { exit 0 }

# EVIDENCE SOURCE (F03). The raw session tail is not this task's answer: a user
# example, a previous task's line, or this hook's own injected text all live in
# it, and the old regex also required a preceding newline so a valid line at the
# very start of the response was missed. Get-ClosingAssistantText returns the
# CURRENT final assistant response - from the event when the client supplies it,
# otherwise the last assistant entry parsed out of the transcript (the CHILD
# transcript for a subagent event). Unknown stays unknown.
$evidence = $null
if ($null -ne (Get-Command Get-ClosingAssistantText -ErrorAction SilentlyContinue)) {
    $evidence = if (Get-Command Get-TaskClosingEvidence -ErrorAction SilentlyContinue) { Get-TaskClosingEvidence -HookInput $hookInput } else { Get-ClosingAssistantText -HookInput $hookInput }    # a published wrap-up counts for its task
}
if ($null -ne $evidence -and $evidence.Known) { $tail = [string]$evidence.Text }
else { $tail = $null } # UNKNOWN is not permission to search raw transcript text.

# Was this session recorded as MCP-relevant by the pre-task half?
$sessionRelevant = $false
$marker = $null
try { $marker = Read-JsonFile $sessionPath } catch { $marker = $null }
if ($null -ne $marker -and $sessionId -ne '' -and [string](Get-Field $marker 'sessionId') -eq $sessionId) {
    $sessionRelevant = ([bool](Get-Field $marker 'relevant'))
}

if ($null -eq $tail) { exit 0 } # R035: unavailable state is silent, never approved.

# SUBSTANTIVE, not merely present (L05). 'MCP used:' with nothing after it, a
# bare 'none', or the line inside a fenced example the agent wrote to SHOW the
# format all satisfied a prefix test. A prefix is a shape; a claim needs
# content. Falls back to the prefix test on a runtime with no _evidencelib.
$hasSummaryLine = ($tail -match $summaryLinePattern)
if ($script:EvidenceLibReady) {
    $mcpDeclaration = Test-ClosingDeclaration -Text $tail -LabelPattern 'MCP[ 	]+(?:servers?[ 	]+|tools?[ 	]+)?used'
    $hasSummaryLine = [bool]$mcpDeclaration.Substantive
}

# Desktop control order (spec 041): advisory, once per session, independent of
# the MCP line. Reads the raw tail only when computer-use could matter.
$desktopNote = ''
$rawTailCache = $null
if (Get-Command Get-DesktopRouteNote -ErrorAction SilentlyContinue) {
    $rawTailCache = [string](Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput))
    $desktopNote = Get-DesktopRouteNote -RawText $rawTailCache
    if ($desktopNote -ne '' -and -not (Test-ShouldReport 'desktop-route')) { $desktopNote = '' }
}
# V94 pairing/order advisories (Scrapling skill, chrome-devtools before
# Playwright, rea-video encoding): never a block, once per session per kind.
if (Get-Command Get-ConnectorPairingNotes -ErrorAction SilentlyContinue) {
    if ($null -eq $rawTailCache) { $rawTailCache = [string](Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput)) }
    foreach ($pn in @(Get-ConnectorPairingNotes -RawText $rawTailCache)) {
        if (-not (Test-ShouldReport ('pairing|' + $pn.Split(':')[0]))) { continue }
        $desktopNote = $(if ($desktopNote -ne '') { $desktopNote + "`n" + $pn } else { $pn })
    }
}
# Connector classes the newest prompt of THIS session matched (UserPromptSubmit).
$triggerKeys = ''
try {
    $tr = Read-JsonFile $triggerPath
    if ($null -ne $tr -and $sessionId -ne '') {
        $sessObj = Get-Field $tr 'sessions'
        $sessEntry = if ($null -ne $sessObj) { Get-Field $sessObj $sessionId } else { $null }
        if ($null -ne $sessEntry) { $triggerKeys = [string](Get-Field $sessEntry 'triggers') }
        elseif ([string](Get-Field $tr 'sessionId') -eq $sessionId) { $triggerKeys = [string](Get-Field $tr 'triggers') }
    }
}
catch { $triggerKeys = '' }

# The requirement is met. Nothing to say - and nothing to repeat.
# Every quiet exit below still owes a pending desktop-route note.
function Exit-WithDesktopNote {
    if ($desktopNote -ne '') { exit (Write-HookResult -EventName $eventName -Kind 'advisory' -Message $desktopNote).ExitCode }
    exit 0
}

# V95 Standing Order 7: a Rust-port prompt must call rust-anything MCP (or CLI
# before MCP attaches) or state "MCP used: none - <reason>"; an unrelated MCP
# call + summary line cannot bypass it, while a CLI run satisfies it.
$rawTail = if ($null -ne $rawTailCache) { $rawTailCache } else { [string](Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput)) }
$triggerList = @($triggerKeys -split ',' | Where-Object { $_ -ne '' })
if ($triggerList -contains 'rust-anything') {
    $declVal = if ($script:EvidenceLibReady -and $null -ne $mcpDeclaration) { [string]$mcpDeclaration.Value } else { [string]$tail }
    $raOk = ([regex]::IsMatch([string]$rawTail, $script:RustAnythingCallPattern) -or
             [regex]::IsMatch([string]$rawTail, $script:RustAnythingCliPattern) -or
             ($hasSummaryLine -and $declVal -match '(?i)(?:^none\b|\brust-anything\b[^.\n]*\bnone[ \t]*[-:][ \t]*\S)'))
    if (-not $raOk) {
        $fp = Get-ShortHash ('trigger-rust-anything|' + $sessionId)
        $reason = @(
            'Connector trigger matched (rust-anything); no rust-anything MCP/CLI call or opt-out.',
            'Load rust-anything:rust-anything and call rust-anything MCP (or CLI), or close "MCP used: none - <reason>".'
        ) -join "`n"
        if ($desktopNote -ne '') { $reason += "`n" + $desktopNote }
        $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Mcp-Usage-Check' -EventName $eventName -Reason $reason -FindingFingerprint $fp -Condition 'required-workflow'
        exit $emit.ExitCode
    }
    $triggerKeys = (@($triggerList | Where-Object { $_ -ne 'rust-anything' }) -join ',')
}
if ($hasSummaryLine) { Exit-WithDesktopNote }

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
# RAW transcript, not $tail: a tool CALL is a JSONL record and the closing
# assistant response $tail holds carries none, so scanning $tail here saw no
# servers at all and silently disarmed this gate.
$servers = New-Object System.Collections.Generic.List[string]
foreach ($m in [regex]::Matches($rawTail, '"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__([A-Za-z0-9_.\-]+?)__')) {
    $id = $m.Groups[1].Value
    if ($id -ne '' -and -not $servers.Contains($id)) { [void]$servers.Add($id) }
    if ($servers.Count -ge 8) { break }
}
$usedMcp = ($servers.Count -gt 0)

if ($usedMcp) {
    $names = (@($servers) | Sort-Object) -join ', '
    if (-not (Test-ShouldReport ('missing|' + $names))) { Exit-WithDesktopNote }
    $reason = @(
        'MCP calls; final server names missing.',
        ('Servers observed in this session: ' + $names + '.'),
        # The example is deliberately kept INLINE and quoted rather than shown on
        # a line of its own: this message lands in the same transcript the next
        # Stop reads, and an example at the start of a line would satisfy the
        # detector - the hook would then clear its own block.
        ('Final standalone actual servers: "MCP used: ' + $names + '".'),
        'Only material actual calls, not availability.'
    ) -join "`n"
    if ($desktopNote -ne '') { $reason += "`n" + $desktopNote }
    if ($enforcement -eq 'advisory') {
        $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $reason
        exit $emit.ExitCode
    }
    # Record the block so THIS hook's own re-entry is recognised; another
    # gate's block must not mute it, and its own must not repeat.
    $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Mcp-Usage-Check' -EventName $eventName -Reason $reason
    exit $emit.ExitCode
}

# No MCP tool was called. The hook cannot prove one was needed, so this is an
# advisory even in block mode - and it is raised only for a session the pre-task
# half already recorded as MCP-relevant.
# V94: a connector trigger matched this prompt, no MCP tool was called and the
# closing carries no "MCP used: none - <reason>". That is an observed fact pair
# (prompt class + absent call + absent line), so it is a once-per-finding gate
# under 'required-workflow'; MCP_SUMMARY_ENFORCEMENT=advisory|off still downgrades.
if ($triggerKeys -ne '') {
    $fp = Get-ShortHash ('trigger-none|' + $sessionId + '|' + $triggerKeys)
    $reason = @(
        ('Connector trigger matched (' + $triggerKeys + '); no MCP call or line.'),
        'Use it, or close "MCP used: none - <reason>".'
    ) -join "`n"
    if ($desktopNote -ne '') { $reason += "`n" + $desktopNote }
    $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Mcp-Usage-Check' -EventName $eventName -Reason $reason -FindingFingerprint $fp -Condition 'required-workflow'
    exit $emit.ExitCode
}
if (-not $sessionRelevant) { Exit-WithDesktopNote }
if (-not (Test-ShouldReport 'none-used')) { Exit-WithDesktopNote }
$note = @(
    'MCP task; no connected tool called.',
    'BEFORE answering: global-mcp-rules.md/global-research-rules.md FULL; check omissions.',
    ('Final: ' + $requiredLine)
) -join "`n"
if ($desktopNote -ne '') { $note += "`n" + $desktopNote }
$emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
exit $emit.ExitCode
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
