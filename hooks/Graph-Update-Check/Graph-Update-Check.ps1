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
# reproducible condition below: graphify-out\graph.json exists, and the newest
# project work is more than two minutes newer than graph.json.
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
# Optional sibling (a runtime installed before it existed keeps the git-only check).
$markdownWorkPath = Join-Path $PSScriptRoot '_markdownwork.ps1'
if (Test-Path -LiteralPath $markdownWorkPath -PathType Leaf) { . $markdownWorkPath }

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
# Receipt for this Stop round (spec 007 RD-4): running now; pass, block or error
# when the gate finishes. A timeout kill leaves it running, never a pass.
$gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Graph-Update-Check' } else { $null }
try {
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

# COORDINATION, matching Graph-Read-Check: every project carries BOTH graphs,
# so a Codebase Memory index does not supersede the graphify one and its upkeep
# is still asked for here. The read half keeps graphify for the material it
# alone covers and its cross-cutting views; this half keeps that graph current.
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
$lifecycleNote = ' BEFORE update/cleanup: graphify.md/graphify-markdown.md FULL. Loss: restore; retain active/evidence/unknown. Hook deletes nothing.'
$cooldownMinutes = 60
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    $parsedSetting = 0; if ([int]::TryParse([string]$config['COOLDOWN_MINUTES'], [ref]$parsedSetting) -and $parsedSetting -ge 0 -and $parsedSetting -le 10080) { $cooldownMinutes = $parsedSetting }
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

# ---- staleness: newest CODE work (git-based) and newest Markdown work vs graph.json ----
$workTime = Get-LatestWorkTimeUtc $cwd
$markdown = $null
if ($null -ne (Get-Command -Name 'Get-MarkdownWorkTime' -ErrorAction SilentlyContinue)) { $markdown = Get-MarkdownWorkTime -ProjectRoot $cwd }
$graphTime = (Get-Item -LiteralPath $graphPath -Force).LastWriteTimeUtc
$codeStale = ($null -ne $workTime -and $workTime -gt $graphTime.AddMinutes(2))
$markdownStale = ($null -ne $markdown -and $null -ne $markdown.TimeUtc -and $markdown.TimeUtc -gt $graphTime.AddMinutes(2))
if (-not $codeStale -and -not $markdownStale) { exit 0 } # R035: partial alone proves no stale state.

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$markdownNote = ''
if ($markdownStale -and (-not $codeStale -or $markdown.TimeUtc -gt $workTime)) {
    $markdownNote = 'Covered Markdown changed beyond Git: graphify update . (local); .ai/: host-agent semantic only, no external model. '
}
$reason = 'GRAPH UPDATE CHECK: graphify-out/graph.json predates changes. ' + $markdownNote + 'Graphed/structural impact: graphify update . (local AST); else explain. Advisory/cooldown.'
$reason += $lifecycleNote
# Record the block so THIS hook's own re-entry is recognised; another
# gate's block must not mute it, and its own must not repeat.
$emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Graph-Update-Check' -EventName $eventName -Reason $reason
exit $emit.ExitCode
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
