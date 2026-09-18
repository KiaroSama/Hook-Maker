# RulesCheck - the configured rules at BOTH ends of the task.
#
# BEFORE work starts (SessionStart, UserPromptSubmit) it lists the rules that
# govern this project: the user's GLOBAL rules (~\.claude\rules or
# ~\.codex\rules) and the current project's LOCAL rules
# (<project>\.claude\rules or <project>\.codex\rules).
#
# AFTER the work (Stop, SubagentStop) it checks that the closing summary
# actually CONFIRMS which of those rules were read and applied. Listing rules at
# the start is a request; this half is the verification, and it is the reason
# the hook exists at all - the pre-task note alone was routinely acknowledged
# and then ignored.
#
# ROLE (global-hook-rules.md, "Hook Roles"): DETECTOR/ADVISORY before, GATE
# after - and the gate is narrow on purpose. It blocks on one confirmed,
# reproducible condition: rule files exist for this project, the session
# transcript shows this session actually EDITED files, and the closing summary
# carries no line starting "Rules applied:". All three are facts the hook read.
# A read-only or advice-only session gets a non-blocking advisory instead,
# because the hook cannot prove the rules were load-bearing there.
#
# The required line names WHICH rule files governed the work (the block message
# lists the exact candidates), so it is evidence, not the bare "done"
# acknowledgement the rules forbid. "Rules applied: none - <reason>" is a valid
# answer when nothing applied.
#
# WHY THE MATCH IS ANCHORED: this hook's own output lands in the transcript it
# later reads, so an unanchored search would be satisfied by the hook's own
# instruction text. The pattern requires the token at the START of a transcript
# line (a literal \n escape inside a JSONL string, or a real line break), and no
# line this hook emits ever starts with it.
#
# Client awareness: Claude Code exports CLAUDE_PROJECT_DIR on every spawned
# hook process (official docs), Codex does not - so the hook auto-detects
# which client is running and checks that client's rules directories. An
# explicit -Client claude|codex parameter overrides the detection.
#
# Token-efficient by design:
# - First check of a project: lists ALL rules files once and asks the AI to
#   confirm they are read before starting.
# - Afterwards it stays completely silent until a rules file is ADDED,
#   CHANGED, or REMOVED (fingerprint per project + client); then it reports
#   exactly what moved and asks for a re-read of those files only.
#
# Canonical rule routing (E-01), appended to the same fingerprint-gated note:
# - the canonical rule set is named by its canonical INSTALLED filenames only
#   (custom-instructions.md, WORKFLOWS.md, CODEWORDS.md,
#   ai-context-memory-policy.md, global-hook-rules.md, global-test-rules.md,
#   global-github-automation-rules.md; global-mcp-rules.md only for MCP work;
#   graphify.md only for codebase navigation) - never an uploaded/
#   version-suffixed copy such as "custom-instructions (17).md" (those are
#   additionally flagged when they appear in a rules directory);
# - EXACTLY ONE skill policy by detected client (codex ->
#   skill-policy-codex-optimized.md, claude/non-codex -> skill-policy.md),
#   never both;
# - strict-UTF-8 guidance for all newly written/modified text (BOM and no-BOM
#   are both UTF-8; any non-UTF-8 exception needs narrow scope + exact
#   encoding + technical reason + forcing system + verification).
# A standalone `::deep-debug` codeword on UserPromptSubmit additionally gets
# the bounded composite-workflow guardrails (native /goal preserved,
# ::multi-agent = one integration + final verification, Ponytail exactly once,
# no post-Ponytail loops), once per session per project+client. Ordinary prose
# "deep debug" never triggers that path (CODEWORDS.md: standalone :: token).
# DETECTOR/ADVISORY only: the hook reminds and routes; it never executes a
# slash command, codeword, or skill.
#
# FAIL-OPEN / UNKNOWN: an absent or unreadable transcript is UNKNOWN, never an
# all-clear and never a block - the requirement is then stated as a plain
# advisory that says so. Same for a client whose transcript this hook cannot
# parse: no edit evidence means advisory, never a gate.
#
# Optional .env next to this script (copy .env.example):
#   GLOBAL_RULES_DIR  overrides the global rules directory (default:
#                     <home>\.claude\rules or <home>\.codex\rules by client)
#   RULES_CONFIRMATION_ENFORCEMENT  block (default) | advisory | off

param(
    # 'claude', 'codex', or '' for auto-detection via CLAUDE_PROJECT_DIR.
    [string]$Client = ''
)

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
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')) {
    exit 0
}
$closing = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
# A Stop hook that re-fires on its own block is the classic hook loop; the
# client sets this flag on the re-entry and every Stop handler must honour it.
if ($closing) {
    # Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
    # for ANY gate's block, and exiting on it alone let one block silence the
    # other twelve on the same Stop.
    if (Test-StopStandDown -HookInput $hookInput -HookName 'Rules-Check') { exit 0 }
}

# ---- which client is running? ----
# Resolved by the ONE shared function in _hooklib.ps1 rather than inline here.
# The old inline form treated ABSENCE of CLAUDE_PROJECT_DIR as proof of Codex,
# which silently handed any third client Codex's rules directory.
$Client = Get-HookClientId -Explicit $Client
if ($Client -eq 'unknown') {
    # An explicit -Client value that is not a known client. This hook cannot
    # guess whose rules to check, and guessing is exactly the defect being
    # fixed, so it stays silent rather than checking the wrong client's rules.
    exit 0
}
$clientDirName = '.' + $Client

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

# ---- rules directories: global (home) + local (project) ----
# USERPROFILE first: Windows PowerShell 5.1 derives $HOME from HOMEDRIVE/HOMEPATH,
# which can disagree with the profile the user actually means.
$homeDir = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($homeDir)) {
    $homeDir = [string]$HOME
}
$globalRulesDir = ''
if ($config.ContainsKey('GLOBAL_RULES_DIR') -and $config['GLOBAL_RULES_DIR'] -ne '') {
    $globalRulesDir = $config['GLOBAL_RULES_DIR']
}
elseif (-not [string]::IsNullOrWhiteSpace($homeDir)) {
    $globalRulesDir = Join-Path $homeDir (Join-Path $clientDirName 'rules')
}
$projectRulesDir = Join-Path $cwd (Join-Path $clientDirName 'rules')

$ruleSets = @(
    [pscustomobject]@{ Label = 'Global rules'; Dir = $globalRulesDir },
    [pscustomobject]@{ Label = 'Project rules'; Dir = $projectRulesDir }
)

# One line per rules file: <path>|<size>|<mtimeUtcTicks>. The joined lines ARE
# the fingerprint; a diff against the stored lines names what moved.
$currentEntries = @{}
foreach ($set in $ruleSets) {
    if ($set.Dir -eq '' -or -not (Test-Path -LiteralPath $set.Dir -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $set.Dir -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $currentEntries[$file.FullName] = $file.FullName + '|' + $file.Length + '|' + $file.LastWriteTimeUtc.Ticks
    }
}

# ---- state (per project + client) ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'

# The exact wording the closing summary must carry. One definition, shared by
# the pre-task instruction, the closing block message and the detector, so they
# cannot drift apart.
$script:RulesRequiredLine = 'Rules applied: <rule files that governed this task>   (or exactly "Rules applied: none - <one-line reason>")'
$script:RulesRequirement = 'CLOSING REQUIREMENT - end the final task summary with its own line starting "Rules applied:" naming the rule files above that actually governed this work and, in a few words, how. If none applied, write "Rules applied: none - <one-line reason>". Listing a rule that was not read or not followed is worse than admitting it was skipped.'

# ============================ CLOSING HALF ==================================
# Stop / SubagentStop: was the rule set actually read and applied, and does the
# summary say so? Everything below is read-only; nothing here writes into the
# scanned project.
if ($closing) {
    $sessionId = [string](Get-Field $hookInput 'session_id')
    $projectKey = Get-ShortHash $cwd.ToLowerInvariant()
    $gatePath = Join-Path $stateDir ('RulesCheck-close-' + $Client + '-' + $projectKey + '.txt')

    $enforcement = 'block'
    if ($config.ContainsKey('RULES_CONFIRMATION_ENFORCEMENT')) {
        $raw = ([string]$config['RULES_CONFIRMATION_ENFORCEMENT']).Trim().ToLowerInvariant()
        if ($raw -eq 'block' -or $raw -eq 'advisory' -or $raw -eq 'off') { $enforcement = $raw }
    }
    if ($enforcement -eq 'off') { exit 0 }

    # Relevance gate: no rule files anywhere means nothing governed this task,
    # so there is nothing to confirm and nothing to say.
    if ($currentEntries.Count -eq 0) { exit 0 }

    # ---- bounded transcript probe -----------------------------------------
    # A private copy rather than a shared helper: hooks\_hooklib.ps1 is owned
    # elsewhere in this change. Shared read (a live writer is never blocked),
    # bounded tail; the text is only searched - never stored, printed or hashed.
    # $null means UNKNOWN, which must never become an all-clear.
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
                # Read in a LOOP: a single Read may legally return fewer bytes
                # than asked for, and a short read would look like a missing
                # confirmation line - i.e. it would produce a FALSE BLOCK.
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
    if ([string](Get-Field $HookInput 'hook_event_name') -eq 'SubagentStop') {
        # Prefer a client-supplied child path, but never require it: on a
        # SubagentStop the documented transcript_path is the subagent's own.
        $child = [string](Get-Field $HookInput 'agent_transcript_path')
        if (-not [string]::IsNullOrWhiteSpace($child)) { return $child }
    }
    return [string](Get-Field $HookInput 'transcript_path')
}


    # Once per session per STATE token: an unchanged answer stays silent on the
    # next Stop of the same session; a changed one reports immediately.
    function Test-ShouldReportClosing {
        param([string]$StateToken)
        # Session ALONE let a previous task's stamp mute the same finding on
        # the next genuine task, and merged a parent with its subagent. The
        # identity carries the agent and the continuation chain too.
        $fp = Get-ShortHash ((Get-HookSuppressionIdentity -HookInput $hookInput) + '|' + $eventName + '|' + $StateToken)
        try {
            if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
                if (([System.IO.File]::ReadAllText($gatePath)).Trim() -eq $fp) { return $false }
            }
        }
        catch { }
        try {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            [System.IO.File]::WriteAllText($gatePath, $fp, (New-Object System.Text.UTF8Encoding $false))
        }
        catch { }
        return $true
    }

    # The candidate menu the confirmation must be drawn from: rule FILE NAMES,
    # capped, so the message stays one screen even with a large rules directory.
    $ruleNames = @($currentEntries.Keys | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object -Unique)
    $shownRules = @($ruleNames | Select-Object -First 14)
    $ruleMenu = ($shownRules -join ', ')
    if ($ruleNames.Count -gt $shownRules.Count) {
        $ruleMenu += ', +' + ($ruleNames.Count - $shownRules.Count) + ' more'
    }

    # EVIDENCE SOURCE (F03). The raw session tail is not this task's answer: a user
    # example, a previous task's line, or this hook's own injected text all live in
    # it, and the old regex also required a preceding newline so a valid line at the
    # very start of the response was missed. Get-ClosingAssistantText returns the
    # CURRENT final assistant response - from the event when the client supplies it,
    # otherwise the last assistant entry parsed out of the transcript (the CHILD
    # transcript for a subagent event). Unknown stays unknown.
    $evidence = $null
    if ($null -ne (Get-Command Get-ClosingAssistantText -ErrorAction SilentlyContinue)) {
        $evidence = Get-ClosingAssistantText -HookInput $hookInput
    }
    if ($null -ne $evidence -and $evidence.Known) { $tail = [string]$evidence.Text }
    else { $tail = Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput) }
    if ($null -eq $tail) {
        # UNKNOWN - no transcript, unreadable, or a client that supplies none.
        if (-not (Test-ShouldReportClosing 'unverified')) { exit 0 }
        $note = @(
            ('RULES CHECK (' + $Client + ') - the session transcript was not available to this hook, so rule compliance could NOT be verified (this is not an all-clear).'),
            ('Governing rule files: ' + $ruleMenu + '.'),
            $script:RulesRequirement,
            ('Required line: ' + $script:RulesRequiredLine)
        ) -join "`n"
        $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
        exit $emit.ExitCode
    }

    # Anchored at the start of a transcript line, so this hook's own instruction
    # text can never satisfy it. A short markdown prefix is tolerated.
    $confirmPattern = '(?im)(?:^|\\n)[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?Rules[ \t]+(?:applied|followed|read)[ \t]*:'
    # SUBSTANTIVE, not merely present (L05): an empty 'Rules applied:' line
    # used to clear this gate, as did one inside a fenced example.
    if ($script:EvidenceLibReady) {
        $rulesDeclaration = Test-ClosingDeclaration -Text $tail -LabelPattern 'Rules[ 	]+(?:applied|followed|read)'
        if ($rulesDeclaration.Substantive) { exit 0 }
    }
    elseif ($tail -match $confirmPattern) { exit 0 }

    # Did this session actually change files? That is what makes the rules
    # load-bearing and is the ONLY condition this hook gates on. The pattern is
    # the client's own tool-call record; a client whose transcript does not
    # carry it simply yields no evidence, and the branch below degrades to an
    # advisory rather than guessing.
    # RAW transcript, not $tail. A tool CALL is a JSONL record, and the closing
    # assistant response $tail now holds carries none - reading $tail here is what
    # silently disarmed this gate: it observed nothing and so never blocked.
    $rawTail = [string](Get-TranscriptTailText (Get-EvidenceTranscriptFallbackPath $hookInput))
    $editEvidence = ($rawTail -match '"name"[ \t]*:[ \t]*"(Edit|Write|MultiEdit|NotebookEdit|str_replace[A-Za-z_]*)"')

    if ($editEvidence) {
        if (-not (Test-ShouldReportClosing 'missing-after-edit')) { exit 0 }
        $reason = @(
            ('RULES CHECK (' + $Client + ') - this session edited files and the closing summary does not confirm which rules governed the change.'),
            ('Governing rule files: ' + $ruleMenu + '.'),
            # The example is deliberately kept INLINE and quoted rather than on a
            # line of its own: this message lands in the same transcript the next
            # Stop reads, and an example at the start of a line would satisfy the
            # detector - the hook would then clear its own block.
            'TO CLEAR THIS: add one line to the final summary, on its own line, starting exactly with "Rules applied:" and naming the rule files that actually governed this work - e.g. "Rules applied: global-hook-rules.md (hook roles, gate conditions), global-test-rules.md (bounded test runs)".',
            'If a listed rule was genuinely not read, say so instead of naming it. "Rules applied: none - <one-line reason>" is a valid answer.'
        ) -join "`n"
        if ($enforcement -eq 'advisory') {
            $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $reason
            exit $emit.ExitCode
        }
        # Record the block so THIS hook's own re-entry is recognised; another
        # gate's block must not mute it, and its own must not repeat.
        $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Rules-Check' -EventName $eventName -Reason $reason
        exit $emit.ExitCode
    }

    # No file changes observed: the hook cannot show the rules were load-bearing
    # here, so it advises and never blocks.
    if (-not (Test-ShouldReportClosing 'missing-no-edit')) { exit 0 }
    $note = @(
        ('RULES CHECK (' + $Client + ') - no rule-compliance confirmation found in this session.'),
        ('Governing rule files: ' + $ruleMenu + '.'),
        $script:RulesRequirement
    ) -join "`n"
    $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message $note
    exit $emit.ExitCode
}
# ========================== end CLOSING HALF ================================

$statePath = Join-Path $stateDir ('RulesCheck-' + $Client + '-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$firstRun = -not (Test-Path -LiteralPath $statePath -PathType Leaf)
$previousEntries = @{}
if (-not $firstRun) {
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($statePath)) {
            if ($line.Trim() -eq '') { continue }
            $path = $line.Split('|')[0]
            $previousEntries[$path] = $line
        }
    }
    catch { $firstRun = $true }
}

# Nothing configured and nothing remembered -> silent, zero tokens.
if ($firstRun -and $currentEntries.Count -eq 0) {
    exit 0
}

# ---- diff ----
$newFiles = New-Object System.Collections.Generic.List[string]
$changedFiles = New-Object System.Collections.Generic.List[string]
$removedFiles = New-Object System.Collections.Generic.List[string]
foreach ($path in @($currentEntries.Keys | Sort-Object)) {
    if (-not $previousEntries.ContainsKey($path)) {
        [void]$newFiles.Add($path)
    }
    elseif ($previousEntries[$path] -ne $currentEntries[$path]) {
        [void]$changedFiles.Add($path)
    }
}
foreach ($path in @($previousEntries.Keys | Sort-Object)) {
    if (-not $currentEntries.ContainsKey($path)) {
        [void]$removedFiles.Add($path)
    }
}
# ---- ::deep-debug codeword (UserPromptSubmit only) ----
# CODEWORDS.md: a codeword activates only as a standalone ::-prefixed token;
# ordinary prose ("let's deep debug this") must never trigger the workflow
# path. Advisory only - the hook never executes /goal, a codeword, or Ponytail.
$sessionId = [string](Get-Field $hookInput 'session_id')
$deepDebug = $false
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ($prompt -match '(?i)(^|\s)::deep-debug([\s.,;:!?]|$)') { $deepDebug = $true }
}
# Unchanged ::deep-debug guidance is suppressed per session: a repeat in the
# SAME session stays silent, a new session re-reports. Rule-file changes are
# fingerprinted separately above, so changed rule state still re-reports.
$ddStatePath = Join-Path $stateDir ('RulesCheck-dd-' + $Client + '-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if ($deepDebug -and $sessionId -ne '' -and (Test-Path -LiteralPath $ddStatePath -PathType Leaf)) {
    try {
        if (([System.IO.File]::ReadAllText($ddStatePath)).Trim() -eq $sessionId) { $deepDebug = $false }
    }
    catch { }
}

$rulesMoved = ($firstRun -or $newFiles.Count -gt 0 -or $changedFiles.Count -gt 0 -or $removedFiles.Count -gt 0)
if (-not $rulesMoved -and -not $deepDebug) {
    exit 0
}

# ---- build the note ----
# Client-conditional NATIVE references and the single active skill policy.
# Both stay plain text in the note - this hook never executes them.
if ($Client -eq 'codex') {
    $policyName = 'skill-policy-codex-optimized.md'
    $goalRef = 'the client-native goal command'
    $ponytailRef = 'the verified installed ponytail-audit capability (via this client''s supported invocation)'
}
else {
    $policyName = 'skill-policy.md'
    $goalRef = '/goal'
    $ponytailRef = '/ponytail:ponytail-audit (native)'
}
$lines = New-Object System.Collections.Generic.List[string]
if ($rulesMoved) {
    if ($firstRun) {
        [void]$lines.Add('RULES CHECK (' + $Client + ') - first check of this project. Before starting the task, make sure EVERY configured rules file below has been read and is applied:')
    }
    else {
        [void]$lines.Add('RULES CHECK (' + $Client + ') - the configured rules changed since the last check of this project. Read the new/changed files BEFORE starting the task:')
        foreach ($path in $newFiles) { [void]$lines.Add('- NEW: ' + $path) }
        foreach ($path in $changedFiles) { [void]$lines.Add('- CHANGED: ' + $path) }
        foreach ($path in $removedFiles) { [void]$lines.Add('- REMOVED: ' + $path + ' (no longer applies)') }
        if ($currentEntries.Count -gt 0) {
            [void]$lines.Add('Then confirm the FULL rule set is still applied:')
        }
    }
    foreach ($set in $ruleSets) {
        if ($set.Dir -eq '') { continue }
        $names = @($currentEntries.Keys |
            Where-Object { $_.StartsWith($set.Dir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object |
            ForEach-Object { $_.Substring($set.Dir.TrimEnd('\').Length + 1) })
        if ($names.Count -gt 0) {
            [void]$lines.Add('- ' + $set.Label + ' (' + $set.Dir + '): ' + ($names -join ', '))
        }
    }
    # Canonical routing (E-01): canonical installed names, exactly one skill
    # policy for the detected client, and the strict-UTF-8 text default. These
    # ride the same fingerprint gate, so they never repeat on an unchanged set.
    [void]$lines.Add('Canonical rule set (always the canonical installed filenames - never an uploaded/version-suffixed copy such as "custom-instructions (17).md"): custom-instructions.md, WORKFLOWS.md, CODEWORDS.md, ai-context-memory-policy.md, global-hook-rules.md, global-test-rules.md, global-github-automation-rules.md; global-mcp-rules.md only when MCP work applies; graphify.md only when codebase navigation applies.')
    [void]$lines.Add('Skill policy routing: active client = ' + $Client + ' -> load ONLY ' + $policyName + ' as the skill policy; never load the other agent''s skill policy and never both together.')
    [void]$lines.Add('ENCODING: every newly written or modified text file defaults to STRICT UTF-8; never trust OS/shell/runtime default encodings. UTF-8 with a BOM and without a BOM are both valid UTF-8 - the BOM is a separate compatibility decision. A non-UTF-8 exception requires a narrow path/scope, the exact encoding, a technical reason, the forcing system, and compatibility verification.')
    # A " (N).md" filename is the browser-download shape of an uploaded copy -
    # canonical rule files never carry it, so flag it instead of trusting it.
    $suffixedNames = @($currentEntries.Keys | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { $_ -match '\s\(\d+\)\.md$' } | Sort-Object -Unique)
    if ($suffixedNames.Count -gt 0) {
        [void]$lines.Add('WARNING - version-suffixed rule filename(s) present (an uploaded copy is NOT canonical; follow the canonical installed name instead): ' + ($suffixedNames -join ', '))
    }
    [void]$lines.Add('Rules already loaded in context only need a confirmation, not a re-read. This check stays silent until a rules file changes again.')
    # Stated up front so the closing gate is never a surprise at Stop.
    [void]$lines.Add($script:RulesRequirement)
}
if ($deepDebug) {
    [void]$lines.Add('RULES CHECK (' + $Client + ') - standalone ::deep-debug codeword detected. Workflow bounds (WORKFLOWS.md "Deep Debug Orchestrator" + CODEWORDS.md):')
    [void]$lines.Add('- ::deep-debug is a BOUNDED composite workflow: end as DEEP DEBUG: COMPLETE or DEEP DEBUG: BLOCKED - never an endless audit/refactor/fix loop.')
    [void]$lines.Add('- ' + $goalRef + ' is a NATIVE command: never shadowed, aliased, converted into a codeword, or synthetically executed by a hook.')
    [void]$lines.Add('- ::multi-agent is a workflow dependency: independent owned workstreams, ONE integration of all results, then final verification on the unified tree - no recursive re-runs, no nested agent trees.')
    [void]$lines.Add('- Run ' + $ponytailRef + ' exactly ONCE, only after debugging, testing, security/review work, and integrated verification have completed.')
    [void]$lines.Add('- After Ponytail: only safe accepted simplifications, their targeted regression repair if needed, and final verification - never a new audit/refactor/debug cycle.')
}

# ---- persist state, then report ----
try {
    # Create the directory only when something is actually going to be written.
    # Creating it first meant a project with no rule files - which writes nothing
    # and says nothing - still left Hook Maker state on the machine.
    $writesState = $rulesMoved -or ($deepDebug -and $sessionId -ne '')
    if ($writesState -and -not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    if ($rulesMoved) {
        [System.IO.File]::WriteAllLines($statePath, [string[]]@($currentEntries.Values | Sort-Object))
    }
    if ($deepDebug -and $sessionId -ne '') {
        [System.IO.File]::WriteAllText($ddStatePath, $sessionId)
    }
}
catch { }

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines.ToArray() -join "`n")
exit $emit.ExitCode
