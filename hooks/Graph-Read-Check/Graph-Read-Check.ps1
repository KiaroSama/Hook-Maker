# GraphReadCheck - detector/advisory for graphify. Two events:
# - SessionStart: compact "a graph exists, prefer scoped queries" note, but
#   ONLY when graphify-out\graph.json exists (no prompt here to judge task
#   relevance, so it never nags about CREATING a graph at session start).
# - UserPromptSubmit: relevance-gated. When THIS task's prompt looks like it
#   needs codebase-wide understanding (architecture / dependency / call-path /
#   impact / module relations / entry point / broad refactor - detected in
#   English AND Persian), it advises:
#     * graph EXISTS  -> a SCOPED query instead of broad file browsing.
#     * graph MISSING -> whether graphify is available (a bounded, NON-executing
#       Get-Command check), then create-then-query, or a one-time fallback to
#       bounded source inspection when graphify is not on PATH.
#   It stays silent for docs-only, trivial text/config, isolated literals, or
#   clearly local changes. The AI still decides; this hook NEVER queries, reads,
#   creates, or otherwise runs graphify itself - it only emits guidance text.
#
# Coordination with Graph-Update-Check: that hook (Stop) handles a STALE graph
# after structural changes ("run graphify update ."). This hook is about READING
# an existing graph or CREATING a first one before broad browsing - distinct
# wording ("GRAPH READ CHECK" vs "GRAPH UPDATE CHECK"), non-overlapping states
# (create-guidance fires only when no graph exists; the update reminder only
# when one exists), so the two never duplicate or contradict.
#
# Token-efficient by design:
# - SessionStart is silent unless a graph exists.
# - UserPromptSubmit is gated by BOTH a relevance check AND a fingerprint of
#   session + project + graph existence/version, so an unchanged reminder is not
#   repeated, while a graph appearing or being regenerated re-enables it.
#
# ASCII source on purpose: the Persian relevance terms are \uXXXX regex escapes,
# not literal characters, so the file reads identically under Windows PowerShell
# 5.1 (legacy codepage) and pwsh 7 without any BOM/encoding dependency.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

# COORDINATION: every project carries BOTH graphs, so a Codebase Memory index
# does NOT supersede the graphify one and this hook keeps speaking in an
# indexed project. The two have distinct jobs on one prompt: Cbm-Read-Check
# answers for code structure, this one for the material graphify alone covers
# (docs, specs, papers, images, video) and its cross-cutting query/path/explain
# views. One graph per question - consult the one that fits, not both for one
# answer.

$graphPath = Join-Path $cwd 'graphify-out\graph.json'
$graphExists = Test-Path -LiteralPath $graphPath -PathType Leaf

# Reminder for the graph-EXISTS case (read the graph; do not re-browse the tree).
$haveGraphNote = @(
    'GRAPH READ CHECK - this project has a graphify knowledge graph (graphify-out/graph.json). If, and only if, this task needs codebase understanding (architecture, cross-file relationships, "where is X used", call paths, refactor scope, impact), prefer a scoped query over broad file browsing:',
    '- graphify query "<question>" for a specific question.',
    '- graphify path "<A>" "<B>" for a relationship; graphify explain "<concept>" for a focused concept.',
    '- Confirm important findings in the actual source before acting. Skip this entirely for isolated edits, docs, config, secrets, or small local fixes - not querying is a fine and expected outcome.',
    '- This project keeps BOTH graphs. A Codebase Memory index does not replace this one: ask Codebase Memory about code structure, and graphify about docs/specs/papers/images/video and whole-project query, path and explain views. A graph that is built and never read is a defect; keep it current with graphify update . whenever the material it covers has moved.'
) -join "`n"

# ---- SessionStart: only meaningful when a graph already exists. ----
if ($eventName -eq 'SessionStart') {
    if (-not $graphExists) { exit 0 }
    $null = Write-HookResult -EventName $eventName -Kind 'context' -Message $haveGraphNote
    exit 0
}

# ---- UserPromptSubmit: relevance-gated (English + Persian). ----
$prompt = [string](Get-Field $hookInput 'prompt')

# Relevance (English + Persian) now lives in Test-CodebaseStructurePrompt in
# _hooklib.ps1: Cbm-Read-Check asks the same question, and two copies of one
# definition are two answers waiting to disagree. The patterns moved
# byte-for-byte.
$relevant = Test-CodebaseStructurePrompt -Prompt $prompt

if (-not $relevant) { exit 0 }

# Choose the note and a graph token (part of the fingerprint) by graph state.
if ($graphExists) {
    $note = $haveGraphNote
    $graphToken = 'g:' + (Get-Item -LiteralPath $graphPath -Force).LastWriteTimeUtc.Ticks
}
else {
    # No graph yet, but the task needs codebase-wide understanding. Detect
    # graphify WITHOUT running it: Get-Command resolves the executable on PATH
    # (or reports absence) and never invokes it. This hook never launches it.
    $graphifyAvailable = $null -ne (Get-Command graphify -ErrorAction SilentlyContinue)
    if ($graphifyAvailable) {
        $note = @(
            'GRAPH READ CHECK - this task looks like it needs codebase-wide understanding (architecture, dependencies, call paths, impact, module relations, entry points, or a broad refactor), and no graphify knowledge graph exists yet (graphify-out/graph.json is absent). The graphify CLI IS available on PATH.',
            'If a graph is worth it for this task: verify the current commands from the installed CLI help/docs first (e.g. graphify --help), create the graph (typically: graphify .), then use a SCOPED query - graphify query "<question>", graphify path "<A>" "<B>", or graphify explain "<concept>" - instead of browsing the whole tree by hand. Confirm findings in the source. Skip all of this for isolated edits, docs, config, secrets, or small local fixes. This hook never runs graphify for you.'
        ) -join "`n"
    }
    else {
        $note = @(
            'GRAPH READ CHECK - this task looks like it needs codebase-wide understanding, but no graphify knowledge graph exists (graphify-out/graph.json is absent) and the graphify CLI was not found on PATH.',
            'Skip the graph and fall back to bounded, targeted source inspection - scoped search and reading only the files this task actually touches - rather than an unbounded whole-repo scan. This note will not repeat for this state.'
        ) -join "`n"
    }
    $graphToken = 'nograph'
}

# Fingerprint by session + project + graph existence/version. Same state in the
# same session -> silent; a graph appearing or being regenerated changes the
# token and re-enables the reminder immediately.
$sessionId = [string](Get-Field $hookInput 'session_id')
$fingerprint = Get-ShortHash ($sessionId + '|graphread|' + $graphToken)
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('GraphReadCheck-prompt-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 }
    }
    catch { }
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, $fingerprint)

$null = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
exit 0
