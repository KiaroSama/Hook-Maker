# SkillsCheck - covers the whole skill lifecycle across three events, routed
# to the ACTIVE agent's skill locations (never both policies at once):
# - SessionStart: compact inventory naming each available skill (deduped by the
#   name: in its SKILL.md, not the folder name) and its source, once per session
#   (a fresh SessionStart, e.g. after /clear, re-lists on purpose).
# - UserPromptSubmit: a short reminder to search global + shared sources and
#   select only the minimal relevant set for THIS task, fingerprint-gated
#   (session + current skill set) so it does not repeat noisily on every prompt.
#   A standalone `::deep-debug` codeword (CODEWORDS.md: standalone :: token,
#   never ordinary prose "deep debug") instead surfaces the composite
#   capability graph from the active skill policy's "Composite ::deep-debug
#   Routing": phase-routed goal/orchestration, understanding/planning, known
#   bug, existing plan, security, test-strengthening, and finalization
#   guidance, plus which core capabilities are NOT visible in the enumerated
#   sources (reported as missing/verify-elsewhere, never silently skipped).
#   Fingerprint = session + client + installed skill set, so unchanged
#   guidance shows once per session while a skill-set change re-reports.
#   Skill identity is always the exact name: in each installed SKILL.md;
#   Claude and Codex invocation syntax stay separate (only the native
#   goal/ponytail references differ per client). The hook still never
#   executes, installs, copies, refreshes, or removes anything.
# - Stop: requires the final task summary to report exactly which skills were
#   ACTUALLY invoked/materially followed - never merely installed, available,
#   discovered, copied, considered, or read but not followed. Non-blocking only.
#
# Client routing (matches Rules-Check / Ci-Status-Check): Claude Code exports
# CLAUDE_PROJECT_DIR on every spawned hook process, Codex does not.
# - Claude / non-Codex -> non-Codex Skill Policy (skill-policy.md); project
#   skills in <project>\.claude\skills, global in <home>\.claude\skills.
# - Codex -> Codex Skill Policy (skill-policy-codex-optimized.md); project
#   skills in <project>\.agents\skills, user in <home>\.agents\skills.
# The two policies are never referenced simultaneously.
#
# DETECTOR / ADVISORY only: it discovers skills and ADVISES on import; it never
# copies, overwrites, or mutates skills, and never writes inside the scanned
# repo. The .ai/SKILLS.md record is updated by the AGENT per policy, not here.
#
# Token-efficient by design:
# - Completely silent when no skill source exists (no library, no project/global
#   skills, no .ai/SKILLS.md record) - checked once, applies to all three events.
# - The shared library is pointed at, not enumerated (it can be huge); per-skill
#   discovery/dedup/conflict detection runs only over the small, curated
#   project and global skill directories.
# - UserPromptSubmit re-shows only when the available skill set changes.
#
# Optional .env next to this script (copy .env.example):
#   SKILLS_DIR         overrides the skill library location (else AI_SKILLS_DIR
#                      env var, else the machine default from the Skill Policy).
#   GLOBAL_SKILLS_DIR  overrides the client's global skills directory (else
#                      <home>\.claude\skills or <home>\.agents\skills by client).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -eq 'SubagentStop') { exit 0 }

# ---- which client is running? (same signal the rest of the project uses) ----
$client = Get-HookClientId
# Policy selection is keyed on 'codex' POSITIVELY, not on "not claude", so any
# non-Codex client correctly lands on the non-Codex policy. That is exactly what
# the Skill Policy requires for a third client, and it is why this line needs no
# per-client special case - only the identity above had to stop guessing.
$policyFile = if ($client -eq 'codex') { 'skill-policy-codex-optimized.md' } else { 'skill-policy.md' }

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

# ---- shared skill library (pointed at, never enumerated) ----
$libraryDir = ''
if ($config.ContainsKey('SKILLS_DIR') -and $config['SKILLS_DIR'] -ne '') {
    $libraryDir = $config['SKILLS_DIR']
}
elseif ($env:AI_SKILLS_DIR) {
    $libraryDir = $env:AI_SKILLS_DIR
}
else {
    $libraryDir = 'G:\Program Files\Portable\Scripts\.SKILLS'
}
$hasLibrary = Test-Path -LiteralPath $libraryDir -PathType Container

# ---- client-routed project + global skill directories ----
if ($client -eq 'codex') {
    $projectSkillsDir = Join-Path $cwd '.agents\skills'
}
else {
    $projectSkillsDir = Join-Path $cwd '.claude\skills'
}

# USERPROFILE first: Windows PowerShell 5.1 derives $HOME from HOMEDRIVE/HOMEPATH,
# which can disagree with the profile the user actually means.
$homeDir = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = [string]$HOME }

$globalSkillsDirs = New-Object System.Collections.Generic.List[string]
if ($config.ContainsKey('GLOBAL_SKILLS_DIR') -and $config['GLOBAL_SKILLS_DIR'] -ne '') {
    [void]$globalSkillsDirs.Add($config['GLOBAL_SKILLS_DIR'])
}
else {
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        if ($client -eq 'codex') { [void]$globalSkillsDirs.Add((Join-Path $homeDir '.agents\skills')) }
        else { [void]$globalSkillsDirs.Add((Join-Path $homeDir '.claude\skills')) }
    }
    # Codex also has an admin location; absent on Windows -> filtered by Test-Path.
    if ($client -eq 'codex') { [void]$globalSkillsDirs.Add('/etc/codex/skills') }
}

$skillsRecord = Join-Path $cwd '.ai\SKILLS.md'
$hasRecord = Test-Path -LiteralPath $skillsRecord -PathType Leaf

# ---- enumerate the (small, curated) project + global skill folders ----
# Immediate children only; reparse points are skipped, never followed.
$maxSkills = 200
$skillFolders = New-Object System.Collections.Generic.List[object]
$enumSources = New-Object System.Collections.Generic.List[object]
[void]$enumSources.Add([pscustomobject]@{ Label = 'project'; Dir = $projectSkillsDir })
foreach ($g in $globalSkillsDirs) { [void]$enumSources.Add([pscustomobject]@{ Label = 'global'; Dir = $g }) }
foreach ($src in $enumSources) {
    if ([string]::IsNullOrWhiteSpace($src.Dir) -or -not (Test-Path -LiteralPath $src.Dir -PathType Container)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $src.Dir -Directory -ErrorAction SilentlyContinue)) {
        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) { continue }
        [void]$skillFolders.Add([pscustomobject]@{ Label = $src.Label; Path = $d.FullName; Leaf = $d.Name })
        if ($skillFolders.Count -ge $maxSkills) { break }
    }
    if ($skillFolders.Count -ge $maxSkills) { break }
}

# Nothing to point at, for any event -> stay silent, zero tokens.
if (-not $hasLibrary -and -not $hasRecord -and $skillFolders.Count -eq 0) { exit 0 }

if ($eventName -eq 'Stop') {
    if ((Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }
    $note = 'SKILL POLICY CHECK - in the final task summary, add a concise "Skills used: <name1>, <name2>" line listing ONLY the exact skill names actually invoked or materially followed during this task - never a skill that was merely installed, available, discovered, copied, considered, or read but not used, and never the whole library. Omit the line entirely if no skill was actually used; do not force a skill for trivial tasks just to produce it.'
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---- build the deduped inventory (name: from SKILL.md, not folder name) ----
# Dedup key: exact skill name (case-insensitive). A single name appearing in
# more than one source with DIFFERENT content (SKILL.md hash) is a conflict the
# agent must reconcile - never a silent overwrite.
$byName = @{}
$seenPaths = @{}
foreach ($fe in $skillFolders) {
    $canon = (Normalize-Path $fe.Path).ToLowerInvariant()
    if ($seenPaths.ContainsKey($canon)) { continue }
    $seenPaths[$canon] = $true
    $name = $fe.Leaf
    # ponytail: SKILL.md hash is the skill identity; deepen to a full-folder
    # hash only if SKILL.md-identical-but-body-different conflicts ever matter.
    $hash = 'no-skillmd'
    $skillMd = Join-Path $fe.Path 'SKILL.md'
    if (Test-Path -LiteralPath $skillMd -PathType Leaf) {
        try {
            $text = [System.IO.File]::ReadAllText($skillMd)
            if ($text.Length -gt 65536) { $text = $text.Substring(0, 65536) }
            $hash = Get-ShortHash $text
            if ($text -match '(?im)^\s*name\s*:\s*(.+?)\s*$') {
                $candidate = $Matches[1].Trim().Trim('"').Trim("'")
                if ($candidate -ne '') { $name = $candidate }
            }
        }
        catch { }
    }
    $key = $name.ToLowerInvariant()
    if (-not $byName.ContainsKey($key)) {
        $byName[$key] = [pscustomobject]@{
            Name    = $name
            Sources = (New-Object System.Collections.Generic.List[string])
            Hashes  = (New-Object System.Collections.Generic.List[string])
        }
    }
    $entry = $byName[$key]
    if (-not $entry.Sources.Contains($fe.Label)) { [void]$entry.Sources.Add($fe.Label) }
    if (-not $entry.Hashes.Contains($hash)) { [void]$entry.Hashes.Add($hash) }
}

$skillLines = New-Object System.Collections.Generic.List[string]
$conflictLines = New-Object System.Collections.Generic.List[string]
foreach ($key in @($byName.Keys | Sort-Object)) {
    $e = $byName[$key]
    [void]$skillLines.Add('- ' + $e.Name + ' [' + ((@($e.Sources) | Sort-Object) -join '+') + ']')
    if ($e.Hashes.Count -gt 1) {
        [void]$conflictLines.Add('CONFLICT (repair before use): "' + $e.Name + '" differs between ' + ((@($e.Sources) | Sort-Object) -join ' and ') + ' - do NOT overwrite silently; diff the two copies, reconcile, and record the chosen version in .ai/SKILLS.md.')
    }
}

if ($eventName -eq 'UserPromptSubmit') {
    $sessionId = [string](Get-Field $hookInput 'session_id')
    $sig = ''
    foreach ($key in @($byName.Keys | Sort-Object)) {
        $sig += $key + ':' + ((@($byName[$key].Hashes) | Sort-Object) -join ',') + ';'
    }
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'

    # ---- standalone ::deep-debug codeword -> phase-routed capability graph ----
    # CODEWORDS.md: only a standalone ::-prefixed token activates the composite
    # workflow; ordinary prose "deep debug" falls through to the generic nudge.
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ($prompt -match '(?i)(^|\s)::deep-debug([\s.,;:!?]|$)') {
        # Fingerprint = session + client + installed skill set: unchanged
        # guidance shows once per session; a skill-set change re-reports at once.
        $ddFingerprint = Get-ShortHash ($sessionId + '|deepdebug|' + $client + '|' + $sig)
        $ddStatePath = Join-Path $stateDir ('SkillsCheck-deepdebug-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
        if (Test-Path -LiteralPath $ddStatePath -PathType Leaf) {
            try {
                if (([System.IO.File]::ReadAllText($ddStatePath)).Trim() -eq $ddFingerprint) { exit 0 }
            }
            catch { }
        }
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($ddStatePath, $ddFingerprint)

        # Only the NATIVE invocation references differ per client; the graph and
        # the skill identities (exact name: in each installed SKILL.md) are the
        # same. Neither client's syntax is authoritative for the other, and the
        # references stay plain text - this hook never executes them.
        if ($client -eq 'codex') {
            $goalRef = 'the client-native goal command (this client''s own syntax, never another client''s slash form)'
            $ponytailRef = 'the verified installed ponytail-audit capability via this client''s supported invocation'
        }
        else {
            $goalRef = 'native /goal'
            $ponytailRef = 'native /ponytail:ponytail-audit'
        }

        # Core capabilities every ::deep-debug pass relies on: report what the
        # enumerated sources do NOT show instead of silently skipping it. The
        # scan sees only the project+global skill dirs (partial coverage by
        # design), so absence means "verify elsewhere / report as missing",
        # never a silent all-clear and never an install.
        $notVisible = New-Object System.Collections.Generic.List[string]
        foreach ($cap in @('systematic-debugging', 'test-driven-development', 'requesting-code-review', 'verification-before-completion')) {
            $found = $false
            foreach ($key in $byName.Keys) {
                if ($key -eq $cap -or $key.EndsWith(':' + $cap)) { $found = $true; break }
            }
            if (-not $found) { [void]$notVisible.Add($cap) }
        }

        $dd = New-Object System.Collections.Generic.List[string]
        [void]$dd.Add('SKILL POLICY CHECK (' + $client + ') - ::deep-debug capability routing. Activate by PHASE, never everything at once; skill identity is the exact name: in each installed SKILL.md (never a folder, plugin, marketplace, or category label). Inspect installed/loadable skills FIRST; never silently install/copy/refresh/overwrite/remove/enable a skill.')
        [void]$dd.Add('- Goal/orchestration: ' + $goalRef + ' first; ::multi-agent is a codeword dependency, not a skill; superpowers:dispatching-parallel-agents for independent discovery/debug workstreams; superpowers:subagent-driven-development for a prepared plan with substantially independent tasks. Flatten dependencies once, deduplicate, detect cycles - never recursive re-runs, never nested agent trees.')
        [void]$dd.Add('- Understanding/planning: audit-context-building for medium/large/unfamiliar/architecture-heavy/security-heavy scope; Graphify only under its own policy; superpowers:brainstorming only for genuine behavior/design ambiguity; superpowers:writing-plans only when a complex repair lacks an executable plan.')
        [void]$dd.Add('- Known bug: systematic-debugging, test-driven-development, verification-before-completion; runtime evidence -> CHOOSE debugging-code (DAP) OR debug-live (trusted DebugMCP/VS Code), not normally both for one question.')
        [void]$dd.Add('- Existing plan: executing-plans (only when a real plan exists), test-driven-development, requesting-code-review, verification-before-completion.')
        [void]$dd.Add('- Security-sensitive: smallest applicable subset of differential-review, insecure-defaults, requesting-code-review, verification-before-completion, semgrep and/or codeql, sarif-parsing (when SARIF output exists), fp-check before treating automated findings as confirmed, variant-analysis after a proven root cause, supply-chain-risk-auditor (dependency/supply-chain scope), c-review (C/C++ only), rust-review (Rust only). "static-analysis" is a plugin/category LABEL, not an invokable skill, unless an installed SKILL.md declares that exact name:. Active security testing still requires ownership/authorization and matching scope.')
        [void]$dd.Add('- Test strengthening: property-based-testing only where a meaningful invariant exists (round trips, validators, state machines, path containment, idempotency, boundaries) - never manufacture low-value properties to claim skill use.')
        [void]$dd.Add('- Finalization: superpowers:using-git-worktrees only when authorized isolation materially reduces collision risk; after integration requesting-code-review + verification-before-completion; superpowers:finishing-a-development-branch only when work really occurred on an independent branch and all checks are green; THEN run ' + $ponytailRef + ' exactly ONCE - afterwards only safe accepted simplifications + targeted tests + final verification, never a second pass.')
        if ($notVisible.Count -gt 0) {
            [void]$dd.Add('- NOT VISIBLE in the enumerated project/global skill sources: ' + ($notVisible.ToArray() -join ', ') + '. Verify each is installed/loadable elsewhere before relying on it; a genuinely missing required capability must be REPORTED as missing and the workflow marked blocked/partial - never silently skipped.')
        }
        [void]$dd.Add('- Select only the task-relevant subset; keep Claude and Codex invocation syntax separate - neither client''s syntax is authoritative for the other. This hook routes only: it never executes a skill, slash command, or codeword.')
        @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($dd.ToArray() -join "`n") } } |
            ConvertTo-Json -Depth 5 -Compress
        exit 0
    }

    # ---- generic once-per-session relevance nudge ----
    $fingerprintSource = $sessionId + '|' + $client + '|' + $hasLibrary + '|' + $libraryDir + '|' + $hasRecord + '|' + $sig
    $fingerprint = Get-ShortHash $fingerprintSource
    $statePath = Join-Path $stateDir ('SkillsCheck-prompt-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 }
        }
        catch { }
    }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($statePath, $fingerprint)
    $note = 'SKILL POLICY CHECK - before continuing, decide whether an available skill materially helps THIS task; search both global and shared sources, use only the minimal relevant set (1-5), and copy/import into the project only when project-local use is genuinely needed. Skip entirely for trivial edits.'
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---- SessionStart: compact routed inventory ----
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('SKILL POLICY CHECK (' + $client + ') - before working, decide whether a skill materially helps this task (skip trivial edits).')
if ($skillLines.Count -gt 0) {
    [void]$lines.Add('Available skills (deduped by name:):')
    foreach ($sl in $skillLines) { [void]$lines.Add($sl) }
    foreach ($cl in $conflictLines) { [void]$lines.Add($cl) }
    [void]$lines.Add('- Activate the relevant ones by the exact name: in each SKILL.md.')
}
if ($hasRecord) {
    [void]$lines.Add('- Read .ai/SKILLS.md for the active-skill record; keep it updated (local-only, secret-free) when skills change.')
}
if ($hasLibrary) {
    [void]$lines.Add('- Skill library: ' + $libraryDir + '. If a relevant skill is missing, import the minimal set (1-5) into ' + $projectSkillsDir + ': copy real folders (never reparse points), exclude secrets/caches/VCS metadata, never overwrite a modified project skill silently, and record source/destination/hash/agent/reason in .ai/SKILLS.md.')
}
[void]$lines.Add('- Select only the minimal relevant set; search global and shared sources first. The final task summary must report which skills were actually used (see the Stop reminder) - never the whole library. Follows ' + $policyFile + '.')

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
