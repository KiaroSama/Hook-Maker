# Speckit-Check - route the task through Spec Kit before writing code.
#
# ROLE: ADVISORY and DETECTOR (global-hook-rules.md SS Hook Roles). It never
# blocks. That is a deliberate choice, not a weaker first version: the route
# depends on project state AND on answers only the user can give, so a Stop
# gate here would refuse work it has no way to adjudicate. Feature-Request-Check
# stays the only shipped hook that gates on a skill chain, and it gates on the
# INTERVIEW - the one step whose evidence is visible in a transcript.
#
# EVENTS: SessionStart (orientation once) and UserPromptSubmit (relevance
# gated). Not Stop: routing is a before-the-work decision, and by Stop the
# choice has already been made or missed.
#
# WHAT IT READS, and nothing else: the presence of .specify\, the presence of
# its constitution, and one non-recursive listing of specs\ to find the newest
# feature. It never executes a skill, a binary, or git - the same reason
# Cbm-Read-Check tests for a file instead of running the CBM executable, which
# was measured at ~1.9 s per call.
#
# UNREADABLE IS NOT ABSENT. A specs\ directory that cannot be listed, or a
# tasks.md that cannot be read, is reported as unknown. Claiming "this project
# has no plan" because a read failed would send the agent to re-create work
# that already exists.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')
. (Join-Path $PSScriptRoot '..\_scope.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
try { if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 } } catch { exit 0 }

# A prompt that is plainly a question, or chat, is not work on the project.
# The definition is shared with Feature-Request-Check so the two can never
# disagree about whether the same prompt described a change.
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    if ([string]::IsNullOrWhiteSpace($prompt)) { $prompt = [string](Get-Field $hookInput 'user_prompt') }
    if (-not (Test-ProjectChangingPrompt -Prompt $prompt)) { exit 0 }
}

# ---- what this project already has -----------------------------------------
$specifyDir = Join-Path $cwd '.specify'
$hasInfrastructure = $false
try { $hasInfrastructure = Test-Path -LiteralPath $specifyDir -PathType Container } catch { $hasInfrastructure = $false }
$hasConstitution = $false
try { $hasConstitution = Test-Path -LiteralPath (Join-Path $specifyDir 'memory\constitution.md') -PathType Leaf } catch { $hasConstitution = $false }

# The newest FEATURE, by the write time of its task list. One level deep and
# one file read: a project with many features must not cost more than a project
# with one.
$newestFeature = ''
$newestTasksUtc = $null
$openTasks = -1
$specsDir = Join-Path $cwd 'specs'
$specsReadable = $true
try {
    if (Test-Path -LiteralPath $specsDir -PathType Container) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $specsDir -Directory -ErrorAction Stop)) {
            $specPath = Join-Path $candidate.FullName 'spec.md'
            if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) { continue }
            $tasksPath = Join-Path $candidate.FullName 'tasks.md'
            $stamp = $candidate.LastWriteTimeUtc
            if (Test-Path -LiteralPath $tasksPath -PathType Leaf) {
                try { $stamp = (Get-Item -LiteralPath $tasksPath -ErrorAction Stop).LastWriteTimeUtc } catch { }
            }
            if ($null -eq $newestTasksUtc -or $stamp -gt $newestTasksUtc) {
                $newestTasksUtc = $stamp
                $newestFeature = $candidate.Name
            }
        }
    }
}
catch { $specsReadable = $false; $newestFeature = ''; $newestTasksUtc = $null }

if ($newestFeature -ne '') {
    $tasksPath = Join-Path (Join-Path $specsDir $newestFeature) 'tasks.md'
    if (Test-Path -LiteralPath $tasksPath -PathType Leaf) {
        try {
            # Capped: a task list is a checklist, never a corpus.
            if ((New-Object System.IO.FileInfo($tasksPath)).Length -le 1048576) {
                $text = [System.IO.File]::ReadAllText($tasksPath, [System.Text.Encoding]::UTF8)
                $openTasks = ([System.Text.RegularExpressions.Regex]::Matches($text, '(?m)^\s*- \[ \]')).Count
            }
        }
        catch { $openTasks = -1 }
    }
    else { $openTasks = -1 }
}

# ---- the route ---------------------------------------------------------------
$lead = ''
if (-not $specsReadable) {
    $lead = '- This project''s specs directory could not be read, so the route is UNKNOWN - check it before assuming there is no plan.'
}
elseif (-not $hasInfrastructure) {
    $lead = '- No .specify/ here yet -> speckit-init, then speckit-constitution.'
}
elseif ($newestFeature -eq '') {
    $lead = '- .specify/ exists but no feature carries a spec yet -> the full chain from speckit-specify.'
    if (-not $hasConstitution) { $lead += ' The constitution is missing too -> speckit-constitution first.' }
}
elseif ($openTasks -lt 0) {
    $lead = '- Newest feature here: specs/' + $newestFeature + ' - its tasks.md could not be read, so how much is built is UNKNOWN -> speckit-converge before assuming either way.'
}
elseif ($openTasks -gt 0) {
    $lead = '- Newest feature here: specs/' + $newestFeature + ' - its tasks.md still has ' + [string]$openTasks + ' unchecked item(s) -> finish them with speckit-implement before starting something else.'
}
else {
    $lead = '- Newest feature here: specs/' + $newestFeature + ' - its tasks.md has no unchecked items. New work starts a new feature; resumed work or doubt about completeness -> speckit-converge.'
}

$note = @(
    'SPECKIT CHECK: Spec Kit carries the spec-driven workflow and one speckit-* skill runs on every task that changes the project.',
    'Route by where this project stands:',
    $lead,
    '- A feature or a behaviour change -> speckit-specify, speckit-clarify, speckit-plan, speckit-tasks, speckit-analyze, speckit-implement, in that order.',
    '- A bug or a regression -> diagnose first, then: the feature already has specs/<name>/ -> speckit-converge appends the unmet work to tasks.md and speckit-implement closes it; the fix changes specified behaviour or the area has no spec -> the full chain from speckit-specify.',
    'Run each skill to the letter: preflight, prerequisite script, extension hooks, gates, completion report.',
    'Every question any step raises goes to the user and the work waits for the answer - never a plausible default, never a guessed scope.',
    'Work that changes nothing - a question, an explanation, a review that writes no code - is answered directly, and so is a trivial edit (a typo, a one-line config value).'
) -join "`n"

# One message per (session, project, state, text). Initialising the project
# mid-session CHANGES the state, so the follow-up route is not suppressed by
# the "no .specify/ yet" note that preceded it.
$sessionId = [string](Get-Field $hookInput 'session_id')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stamp = ''
if ($null -ne $newestTasksUtc) { $stamp = $newestTasksUtc.ToString('o') }
$fingerprint = Get-ShortHash ($sessionId + '|' + $eventName + '|' + $cwd + '|' + [string]$hasInfrastructure + '|' +
    [string]$hasConstitution + '|' + $newestFeature + '|' + $stamp + '|' + [string]$openTasks + '|' + $note)
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('SpeckitCheck-' + $projectKey + '.txt')
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
}
try {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    [System.IO.File]::WriteAllText($statePath, $fingerprint)
}
catch { }

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
exit $emit.ExitCode
