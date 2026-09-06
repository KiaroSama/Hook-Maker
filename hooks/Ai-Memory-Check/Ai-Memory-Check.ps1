# AiMemoryCheck - after a task ends (Stop), checks whether the project's .ai
# working memory was updated per the AI Context Memory Policy: memory.md first,
# then only the specialized files that gained value (LESSON, REFERENCE, ...).
#
# ROLE: GATE on Stop/SubagentStop (global-hook-rules.md SS Hook Roles). The
# integration matrix calls it a "completion advisory" for WHAT IT ASKS FOR;
# the mechanism is a real decision:block, and the source says so here so the
# two descriptions cannot drift apart again. It blocks only on the documented,
# reproducible condition below: .ai\ exists AND (.ai\memory.md is missing OR
# the newest project work is more than two minutes newer than it).
# WHAT CLEARS IT: finishing the turn again - after updating the files that
# gained value, or after one line saying nothing durable was learned. The
# block is recorded per session and per project BEFORE it is emitted, so the
# same state never blocks twice; a later session is additionally held off by
# COOLDOWN_MINUTES.
#
# Token-efficient by design:
# - Fires only when .ai\ exists AND the latest project work is newer than
#   .ai\memory.md (deterministic staleness via git commit/dirty-file times).
# - Respects stop_hook_active (never loops) and a per-project cooldown.
# - The decision stays with the AI: the reminder explicitly allows finishing
#   without updates when nothing durable was learned.
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between reminders per project (default 30)

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
if (Test-StopStandDown -HookInput $hookInput -HookName 'Ai-Memory-Check') {
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
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

# Only projects that actually keep .ai working memory.
$aiDir = Join-Path $cwd '.ai'
if (-not (Test-Path -LiteralPath $aiDir -PathType Container)) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 30
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}

# ---- cooldown (per project) ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('AiMemoryCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $last = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# ---- staleness: newest project work (git-based) vs .ai\memory.md ----
$workTime = Get-LatestWorkTimeUtc $cwd
if ($null -eq $workTime) {
    exit 0
}

$reasonWhy = ''
$memoryPath = Join-Path $aiDir 'memory.md'
if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) {
    $reasonWhy = '.ai exists but .ai/memory.md (the startup router) is missing'
}
else {
    $memoryTime = (Get-Item -LiteralPath $memoryPath -Force).LastWriteTimeUtc
    if ($workTime -gt $memoryTime.AddMinutes(2)) {
        $reasonWhy = '.ai/memory.md is older than the latest project changes'
    }
}
if ($reasonWhy -eq '') {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

# Concrete, not generic: list the specialized files that ACTUALLY exist right
# now, so "update only the ones that gained value" has real names to weigh
# instead of the policy's example list. A brand-new specialized file is just
# as valid an outcome as updating an existing one.
$existingFiles = @(Get-ChildItem -LiteralPath $aiDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'memory.md' } |
    Sort-Object Name |
    Select-Object -ExpandProperty Name)
$filesClause = if ($existingFiles.Count -gt 0) {
    'Other files currently in .ai/: ' + ($existingFiles -join ', ') + '.'
}
else {
    '.ai/ has no specialized files yet (only memory.md) - create one ONLY if this task produced something reusable enough to name (e.g. LESSON.md, REFERENCE.md).'
}

# E-07: the durable-value guidance names what a debugging/::deep-debug task
# records and what it never stores. Guidance text only - encoding of the files
# themselves is validated by Utf8-Encoding-Check through its own state (no
# repository rescan here, no dependence on same-event hook order).
$reason = 'AI MEMORY CHECK: the task is ending but ' + $reasonWhy + '. Per the AI Context Memory Policy, memory updates follow MEANINGFUL work only, in this order: (1) update .ai/memory.md first (index/router), (2) update ONLY the specialized files that gained reusable value this task - not every file, not on a schedule. ' + $filesClause + ' (3) never duplicate a lesson across files - full detail in the best file, links elsewhere. (4) Record only DURABLE value - for a debugging/::deep-debug task that means: the confirmed root cause, the fixed path, the permanent regression test/fixture, verified commands and their outcomes, unresolved blockers/remaining risk, stable timing/resource facts, Ponytail simplifications accepted/rejected when they affect future maintenance, and the exact next step when the workflow ended BLOCKED. Never store raw prompts, raw logs, scan dumps, full source, secrets, temporary hypotheses, routine passing output, or duplicated global policy text. (5) Write every new or modified .ai/ file as UTF-8 - never an OS-default encoding (Utf8-Encoding-Check validates the files via its own state; nothing is rescanned here). Keep entries factual and deduplicated. If this task was trivial or produced nothing reusable, finish now WITHOUT updating and say so in one line. EITHER answer clears this block: it is recorded per session and per project before it is emitted, so this same state never blocks twice.'
# Record the block so THIS hook's own re-entry is recognised; another
# gate's block must not mute it, and its own must not repeat.
Set-StopBlockMarker -HookInput $hookInput -HookName 'Ai-Memory-Check'
exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason).ExitCode
