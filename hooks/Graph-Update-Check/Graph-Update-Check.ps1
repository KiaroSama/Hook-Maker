# GraphUpdateCheck - after a task ends (Stop), checks whether the graphify
# knowledge graph is stale and, if so, asks the AI to decide whether updating
# it is worth it (graphify update . is AST-only, no API cost). The decision is
# based on STRUCTURAL impact (symbols, exports, imports, call/inheritance
# relationships, entry points, cross-file dependencies) - never on how many
# files changed: a single-file change can still be graph-relevant (a renamed
# export, a changed call relationship) while a multi-file change can be
# graph-irrelevant (docs-only, formatting-only, generated output).
#
# ROLE: GATE on Stop/SubagentStop (global-hook-rules.md SS Hook Roles). The
# integration matrix files it under "freshness" for WHAT IT ASKS ABOUT; the
# mechanism is a real decision:block, and the source says so here so the two
# descriptions cannot drift apart again. It blocks only on the documented,
# reproducible condition below: graphify-out\graph.json exists, this project
# has no Codebase Memory index (that graph supersedes graphify), and the
# newest project work is more than two minutes newer than graph.json.
# WHAT CLEARS IT: finishing the turn again - after `graphify update .`, or
# after one line saying the change was not structural. The block is recorded
# per session and per project BEFORE it is emitted, so the same state never
# blocks twice; a later session is additionally held off by COOLDOWN_MINUTES.
#
# Token-efficient by design:
# - Fires only when graphify-out\graph.json exists AND the latest project work
#   is newer than the graph (deterministic staleness via git times).
# - Respects stop_hook_active (never loops) and a per-project cooldown.
# - If the AI decides not to update, nothing happens; the reminder returns
#   after future changes (exactly once per cooldown window).
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between reminders per project (default 60)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
# Stand down only on THIS hook's own re-entry: `stop_hook_active` is set
# for ANY gate's block, and exiting on it alone let one block silence the
# other twelve on the same Stop.
if (Test-StopStandDown -HookInput $hookInput -HookName 'Graph-Update-Check') {
    exit 0
}
# Only used to shape the result (Write-HookResult below). This is a Stop-only
# hook, so an absent event name reads as 'Stop' rather than as "no event".
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
# Own only the completion events. Defaulting a blank name is not a filter:
# a custom-events install would otherwise run this whole body - git calls
# included - on UserPromptSubmit.
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

# COORDINATION, matching Graph-Read-Check: Codebase Memory is the primary
# code graph, so when this project is indexed there, do not ask for a
# graphify graph to be refreshed. Without this the read half would call
# graphify superseded while this half kept demanding its upkeep.
$cbmCwd = [string](Get-Field $hookInput 'cwd')
$cbmCacheDir = Get-CbmCacheDir -Config (Read-HookEnv (Join-Path $PSScriptRoot '.env')) -ProjectRoot $cbmCwd
if (Test-CbmInstalled -CacheDir $cbmCacheDir) {
    if (-not [string]::IsNullOrWhiteSpace($cbmCwd)) {
        try {
            if (Test-Path -LiteralPath (Get-CbmProjectDbPath -ProjectRoot $cbmCwd -CacheDir $cbmCacheDir) -PathType Leaf) { exit 0 }
        }
        catch { }
    }
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

# Only projects that actually keep a graph.
$graphPath = Join-Path $cwd 'graphify-out\graph.json'
if (-not (Test-Path -LiteralPath $graphPath -PathType Leaf)) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 60
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}

# ---- cooldown (per project) ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('GraphUpdateCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# ---- staleness: newest CODE work (git-based) vs graph.json ----
$workTime = Get-LatestWorkTimeUtc $cwd
if ($null -eq $workTime) {
    exit 0
}
$graphTime = (Get-Item -LiteralPath $graphPath -Force).LastWriteTimeUtc
if ($workTime -le $graphTime.AddMinutes(2)) {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reason = 'GRAPH UPDATE CHECK: graphify-out/graph.json predates the latest project changes. Decide for yourself based on STRUCTURAL impact, not the number of files changed - a single-file change can still be graph-relevant (e.g. an added/removed/renamed function or class, a changed export, import, call, or inheritance relationship, a new entry point, a changed cross-file dependency), while a multi-file change can be graph-irrelevant (prose/comments/formatting only, a literal or config value change, generated output, tests only unless test architecture is intentionally represented in the graph). If this task changed graph-relevant structure, run: graphify update .  (AST-only, no API cost). Otherwise finish now without updating and say so in one line. EITHER answer clears this block: it is recorded per session and per project before it is emitted, so this same state never blocks twice, and it returns only after future changes.'
# Record the block so THIS hook's own re-entry is recognised; another
# gate's block must not mute it, and its own must not repeat.
Set-StopBlockMarker -HookInput $hookInput -HookName 'Graph-Update-Check'
exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason).ExitCode
