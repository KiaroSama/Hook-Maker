# SkillsCheck - covers the whole skill lifecycle across three events:
# - SessionStart: discover/list available project skills + policy, once per
#   session (a fresh SessionStart, e.g. after /clear, re-lists on purpose -
#   context was wiped).
# - UserPromptSubmit: a short reminder to select only skills relevant to THIS
#   task, fingerprint-gated (session + current skill set) so it does not repeat
#   noisily on every prompt.
# - Stop: requires the final task summary to report exactly which skills were
#   ACTUALLY invoked/materially followed - never merely installed, available,
#   discovered, copied, considered, or read but not followed - so a trivial
#   task is never forced to invent skill usage just to produce that line. This
#   is a non-blocking reminder only; no skill used is never treated as failure.
#
# Token-efficient by design:
# - Completely silent when no skill source exists (no library, no copied
#   project skills, no .ai/SKILLS.md record) - checked once, applies to all
#   three events.
# - UserPromptSubmit re-shows only when the available skill set changes.
#
# Optional .env next to this script (copy .env.example):
#   SKILLS_DIR  overrides the skill library location (else AI_SKILLS_DIR env
#               var, else the machine default from the Skill Policy).

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

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')

# Skill sources, most specific first.
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
$projectSkillsDir = Join-Path $cwd '.claude\skills'
$copiedSkills = @()
if (Test-Path -LiteralPath $projectSkillsDir -PathType Container) {
    $copiedSkills = @(Get-ChildItem -LiteralPath $projectSkillsDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}
$skillsRecord = Join-Path $cwd '.ai\SKILLS.md'
$hasRecord = Test-Path -LiteralPath $skillsRecord -PathType Leaf

# Nothing to point at, for any event -> stay silent, zero tokens.
if (-not $hasLibrary -and $copiedSkills.Count -eq 0 -and -not $hasRecord) { exit 0 }

if ($eventName -eq 'Stop') {
    if ((Get-Field $hookInput 'stop_hook_active') -eq $true) { exit 0 }
    $note = 'SKILL POLICY CHECK - in the final task summary, add a concise "Skills used: <name1>, <name2>" line listing ONLY the exact skill names actually invoked or materially followed during this task - never a skill that was merely installed, available, discovered, copied, considered, or read but not used, and never the whole library. Omit the line entirely if no skill was actually used; do not force a skill for trivial tasks just to produce it.'
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

if ($eventName -eq 'UserPromptSubmit') {
    $sessionId = [string](Get-Field $hookInput 'session_id')
    $fingerprintSource = $sessionId + '|' + $hasLibrary + '|' + $libraryDir + '|' + (($copiedSkills | Sort-Object) -join ',') + '|' + $hasRecord
    $fingerprint = Get-ShortHash $fingerprintSource
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    $statePath = Join-Path $stateDir ('SkillsCheck-prompt-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 }
        }
        catch { }
    }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($statePath, $fingerprint)
    $note = 'SKILL POLICY CHECK - before continuing, decide whether an available skill materially helps THIS task; use only what is relevant, skip entirely for trivial edits. Re-check .ai/SKILLS.md or the library only if nothing already covers it.'
    @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $note } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# SessionStart: full discovery listing.
$lines = New-Object System.Collections.Generic.List[string]
[void]$lines.Add('SKILL POLICY CHECK - before working, decide whether a skill materially helps this task (skip for trivial edits):')
if ($copiedSkills.Count -gt 0) {
    [void]$lines.Add('- Copied skills already in this project: ' + ($copiedSkills -join ', ') + '. Activate the relevant ones by the exact name: in each SKILL.md.')
}
if ($hasRecord) {
    [void]$lines.Add('- Read .ai/SKILLS.md for the active-skill record; keep it updated when skills change.')
}
if ($hasLibrary) {
    [void]$lines.Add('- Skill library: ' + $libraryDir + '. If a relevant skill is missing here, copy the minimal set (1-5) into .claude\skills and record it.')
}
[void]$lines.Add('- The final task summary must report which skills were actually used (see the Stop reminder) - never the whole library.')

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
