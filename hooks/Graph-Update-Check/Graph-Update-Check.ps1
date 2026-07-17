# GraphUpdateCheck - after a task ends (Stop), checks whether the graphify
# knowledge graph is stale and, if so, asks the AI to decide whether updating
# it is worth it (graphify update . is AST-only, no API cost). The decision is
# based on STRUCTURAL impact (symbols, exports, imports, call/inheritance
# relationships, entry points, cross-file dependencies) - never on how many
# files changed: a single-file change can still be graph-relevant (a renamed
# export, a changed call relationship) while a multi-file change can be
# graph-irrelevant (docs-only, formatting-only, generated output).
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
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
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

$reason = 'GRAPH UPDATE CHECK: graphify-out/graph.json predates the latest project changes. Decide for yourself based on STRUCTURAL impact, not the number of files changed - a single-file change can still be graph-relevant (e.g. an added/removed/renamed function or class, a changed export, import, call, or inheritance relationship, a new entry point, a changed cross-file dependency), while a multi-file change can be graph-irrelevant (prose/comments/formatting only, a literal or config value change, generated output, tests only unless test architecture is intentionally represented in the graph). If this task changed graph-relevant structure, run: graphify update .  (AST-only, no API cost). Otherwise finish now without updating; this reminder returns after future changes.'
@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
exit 0
