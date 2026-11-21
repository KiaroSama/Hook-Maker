# Speckit-Check - route the task through Spec Kit before writing code.
#
# ROLE: ADVISORY on SessionStart/UserPromptSubmit, GATE (blocks once) on Stop
# (global-hook-rules.md SS Hook Roles; spec 036). The pre-task note names the
# route. The Stop gate only judges what a transcript CAN prove: a change request,
# 3+ distinct edited files outside specs/ .specify/ .ai/ .claude/ plans/, and
# neither a speckit-* Skill call nor a write under specs/ or .specify/. One or
# two files is a small task and never refused (user decision, 2026-11-16).
# Unknown evidence (no, partial or unreadable transcript) is never a refusal,
# and "this work was exempt" with a reason clears it. Before that, the
# classification gate (_speckitclass.ps1, spec 041) refuses once per turn when
# edits have no `Spec Kit:` line, EXEMPT is contradicted (2+ files, CI, manifest,
# lockfile, rule file) or CHAIN has no speckit evidence. Not SubagentStop: a
# subagent works under its parent's chain.
#
# WHAT IT READS, and nothing else: the presence of .specify\, the presence of
# its constitution, the ACTIVE-FEATURE POINTER .specify\feature.json, the
# last Spec Kit refresh date recorded in .ai\COMMANDS.md, and one
# non-recursive listing of specs\ as the fallback when there is no usable
# pointer. The pointer wins because folder recency is not ownership: an agent
# that touched an unrelated feature's notes would otherwise re-route the whole
# project to it. It never executes a skill, a binary, or git - the same reason
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
. (Join-Path $PSScriptRoot '_speckitclass.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop')) { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
try { if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 } } catch { exit 0 }

# ---- Stop: did a multi-file change run the chain? (spec 036) -----------------
if ($eventName -eq 'Stop') {
    $gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Speckit-Check' } else { $null }
    try {
        if (Test-StopStandDown -HookInput $hookInput -HookName 'Speckit-Check') { exit 0 }
        $transcriptPath = [string](Get-Field $hookInput 'transcript_path')
        if ([string]::IsNullOrWhiteSpace($transcriptPath)) { exit 0 }
        $config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
        $maxBytes = 20000000
        if ($config.ContainsKey('MAX_TRANSCRIPT_BYTES')) {
            $parsed = 0
            if ([int]::TryParse([string]$config['MAX_TRANSCRIPT_BYTES'], [ref]$parsed) -and $parsed -ge 100000) { $maxBytes = $parsed }
        }
        $evidence = Get-TranscriptToolEvidence -Path $transcriptPath -MaxBytes $maxBytes
        # Partial means the request or the chain may sit in the unread part.
        if (-not $evidence.Ok -or $evidence.Partial) { exit 0 }
        # Classification first (spec 041/042): every edited turn names its class, an EXEMPT line has to be true, and CHAIN edits start in speckit-implement.
        $classFinding = if (Get-Command Get-SpecKitClassFinding -ErrorAction SilentlyContinue) { Get-SpecKitClassFinding -HookInput $hookInput -Events @($evidence.Events) -Cwd $cwd } else { $null }
        if ($null -ne $classFinding -and $classFinding.Kind -eq 'order') {
            if (Test-NewGateFingerprint -Name 'SpeckitOrder' -Cwd $cwd -Fingerprint $classFinding.Fingerprint) {
                $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Speckit-Check' -FindingFingerprint $classFinding.Fingerprint -EventName $eventName -Message ('SPECKIT CHECK: ' + $classFinding.Detail + ' edited before speckit-implement; start edits there.') -Condition 'advisory'
                exit $emit.ExitCode
            }
        }
        elseif ($null -ne $classFinding -and (Test-NewGateFingerprint -Name 'SpeckitClass' -Cwd $cwd -Fingerprint $classFinding.Fingerprint)) {
            $classMessage = switch ($classFinding.Kind) {
                'missing' { 'SPECKIT CHECK: ' + [string]$classFinding.EditCount + ' edited file(s), no Spec Kit line. Add "Spec Kit: CHAIN (<route>)" or "Spec Kit: EXEMPT (question | review | small)".' }
                'exempt' { 'SPECKIT CHECK: EXEMPT contradicted (' + $classFinding.Detail + '). Reclassify as CHAIN and run chain, or fix line.' }
                default { 'SPECKIT CHECK: CHAIN has no speckit-* step or specs/ write. Run chain or fix line.' }
            }
            $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Speckit-Check' -FindingFingerprint $classFinding.Fingerprint -EventName $eventName -Message $classMessage -Condition 'required-workflow'
            exit $emit.ExitCode
        }
        $root =[IO.Path]::GetFullPath($cwd).TrimEnd('\', '/') + '\'
        $changePrompts = New-Object System.Collections.Generic.List[string]
        $edited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $chainRan = $false
        foreach ($item in @($evidence.Events)) {
            if ($item.Kind -eq 'prompt') {
                # Never count this hook's own words as a request.
                if ($item.Value -notmatch '(?im)^[ \t-]*(?:SPECKIT CHECK|Speckit-Check:)' -and (Test-ProjectChangingPrompt -Prompt $item.Value)) { [void]$changePrompts.Add($item.Value) }
            }
            elseif ($item.Kind -eq 'skill') { if ($item.Value -match '(?i)(^|:)speckit-') { $chainRan = $true } }
            elseif ($item.Kind -eq 'write') {
                $full = ''
                try { $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($item.Value)) { $item.Value } else { Join-Path $cwd $item.Value })) } catch { continue }
                # Files outside the project (memory, other repos) are not this task's edits.
                if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $relative = $full.Substring($root.Length)
                if ($relative -match '^(?i)(specs|\.specify)[\\/]') { $chainRan = $true }
                elseif ($relative -notmatch '^(?i)(\.ai|\.claude|plans)[\\/]') { [void]$edited.Add($full) }
            }
        }
        if ($changePrompts.Count -eq 0 -or $chainRan -or $edited.Count -lt 3) { exit 0 }

        # Once per (session, set of change prompts); a new request re-arms it.
        $sessionId = [string](Get-Field $hookInput 'session_id')
        $joined = (@($changePrompts | ForEach-Object { Get-ShortHash $_ } | Sort-Object) -join ',')
        $fingerprint = Get-ShortHash ($sessionId + '|' + $joined)
        $gateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
        $gatePath = Join-Path $gateDir ('SpeckitCheck-gate-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
        if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
            try { if (([IO.File]::ReadAllText($gatePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
        }
        try { New-Item -ItemType Directory -Path $gateDir -Force | Out-Null; [IO.File]::WriteAllText($gatePath, $fingerprint) } catch { }
        $firstPrompt = ([string]$changePrompts[0]) -replace '\s+', ' '
        if ($firstPrompt.Length -gt 120) { $firstPrompt = $firstPrompt.Substring(0, 120) + '...' }
        $blockMessage = @(
            ('SPECKIT CHECK: request "' + $firstPrompt + '" edited ' + [string]$edited.Count + ' files; no speckit-* step or specs/ write in transcript.'),
            'Run the Spec Kit chain (global-spec-kit-rules.md FULL) or state the exemption.'
        ) -join "`n"
        $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Speckit-Check' -FindingFingerprint $fingerprint -EventName $eventName -Message $blockMessage -Condition 'required-workflow'
        exit $emit.ExitCode
    }
    catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
    finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
}

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

# The ACTIVE feature: .specify\feature.json when it names a spec-bearing
# folder directly under specs\, otherwise the newest feature by the write time
# of its task list. One level deep and one file read: a project with many
# features must not cost more than a project with one.
$newestFeature = ''
$newestTasksUtc = $null
$openTasks = -1
$featureFromPointer = $false
$specsDir = Join-Path $cwd 'specs'
$specsReadable = $true
try {
    $pointerPath = Join-Path $specifyDir 'feature.json'
    if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
        $pointer = [System.IO.File]::ReadAllText($pointerPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $named = [string]$pointer.feature_directory
        if (-not [string]::IsNullOrWhiteSpace($named)) {
            if (-not [System.IO.Path]::IsPathRooted($named)) { $named = Join-Path $cwd $named }
            $named = [System.IO.Path]::GetFullPath($named)
            $parent = [System.IO.Path]::GetDirectoryName($named.TrimEnd('\', '/'))
            if ([string]::Equals($parent, [System.IO.Path]::GetFullPath($specsDir), [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath (Join-Path $named 'spec.md') -PathType Leaf)) {
                $newestFeature = Split-Path -Leaf $named.TrimEnd('\', '/')
                $featureFromPointer = $true
                $tasksPointer = Join-Path $named 'tasks.md'
                $newestTasksUtc = (Get-Item -LiteralPath $named).LastWriteTimeUtc
                if (Test-Path -LiteralPath $tasksPointer -PathType Leaf) { $newestTasksUtc = (Get-Item -LiteralPath $tasksPointer).LastWriteTimeUtc }
            }
        }
    }
}
catch { $newestFeature = ''; $newestTasksUtc = $null; $featureFromPointer = $false }
try {
    if (-not $featureFromPointer -and (Test-Path -LiteralPath $specsDir -PathType Container)) {
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
$featureLabel = 'Newest feature here (navigation only, no active-feature pointer or ownership claim)'
if ($featureFromPointer) { $featureLabel = 'Active feature (.specify/feature.json)' }
$lead = ''
if (-not $specsReadable) {
    $lead = '- Specs unreadable: route UNKNOWN; inspect.'
}
elseif (-not $hasInfrastructure) {
    $lead = '- No .specify/: speckit-init -> speckit-constitution.'
}
elseif ($newestFeature -eq '') {
    $lead = '- .specify/ without feature spec: full chain from speckit-specify.'
    if (-not $hasConstitution) { $lead += ' Missing constitution: speckit-constitution FIRST.' }
}
elseif ($openTasks -lt 0) {
    $lead = '- ' + $featureLabel + ': specs/' + $newestFeature + ' tasks.md unreadable -> speckit-converge.'
}
elseif ($openTasks -gt 0) {
    $lead = '- ' + $featureLabel + ': specs/' + $newestFeature + ' - its tasks.md still has ' + [string]$openTasks + ' unchecked -> speckit-implement; NEW requests: intake first.'
}
else {
    $lead = '- ' + $featureLabel + ': specs/' + $newestFeature + ' tasks checked. New work: new feature; doubt: speckit-converge.'
}

# Keep the detected feature/init route; a generic workflow cannot replace project evidence.
$note = $lead + "`n" + 'Speckit-Check: advisory; behavior: specify->clarify->plan->tasks->analyze->implement; bug: diagnose->converge->implement. Delta: IDs/AC, amend artifacts, refresh gates. Follow scripts/gates; ask unknowns. Newest!=owner; other-project needs consent. global-spec-kit-rules.md/global-project-lifecycle-rules.md FULL; read-only/typo exempt.'

# One message per (session, project, state, text, REQUEST). Initialising the
# project mid-session CHANGES the state, so the follow-up route is not
# suppressed by the "no .specify/ yet" note that preceded it. The prompt is part
# of the key because a new request is exactly the case the intake line exists
# for: with the task counts unchanged it used to be silenced by the earlier,
# identical-looking state. The SAME prompt repeated is still said once.
$sessionId = [string](Get-Field $hookInput 'session_id')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stamp = ''
if ($null -ne $newestTasksUtc) { $stamp = $newestTasksUtc.ToString('o') }
$requestKey = ''
if ($eventName -eq 'UserPromptSubmit') { $requestKey = Get-ShortHash $prompt }
$fingerprint = Get-ShortHash ($sessionId + '|' + $eventName + '|' + $cwd + '|' + [string]$hasInfrastructure + '|' +
    [string]$hasConstitution + '|' + $newestFeature + '|' + $stamp + '|' + [string]$openTasks + '|' + $requestKey + '|' + $note)
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('SpeckitCheck-' + $projectKey + '.txt')
$routeDue = $true
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { if (([System.IO.File]::ReadAllText($statePath).Trim()) -eq $fingerprint) { $routeDue = $false } } catch { }
}

# ---- monthly Spec Kit refresh (global-spec-kit-rules.md, Monthly project
# refresh) ----------------------------------------------------------------------
# The skills update globally, so a project's .specify/ falls behind them. The
# last refresh is the newest YYYY-MM-DD on a .ai/COMMANDS.md line that names
# the Spec Kit refresh or `specify integration upgrade`. FILES ONLY: this hook
# never runs `specify`, never passes --force, never touches .specify/. Said once
# per project per recorded date (a missing record is the date 'none'); an
# unreadable COMMANDS.md is unknown, not missing, and says nothing.
$refreshLine = ''
$refreshKey = ''
if ($hasInfrastructure) {
    $commandsPath = Join-Path $cwd '.ai\COMMANDS.md'
    $lastRefresh = $null
    $commandsKnown = $true
    try {
        if (Test-Path -LiteralPath $commandsPath -PathType Leaf) {
            if ((New-Object System.IO.FileInfo($commandsPath)).Length -le 1048576) {
                foreach ($commandLine in [System.IO.File]::ReadAllLines($commandsPath, [System.Text.Encoding]::UTF8)) {
                    if ($commandLine -notmatch '(?i)spec[ -]?kit refresh|specify integration upgrade') { continue }
                    foreach ($m in [System.Text.RegularExpressions.Regex]::Matches($commandLine, '\b(\d{4}-\d{2}-\d{2})\b')) {
                        $parsed = [datetime]::MinValue
                        if ([datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
                            if ($null -eq $lastRefresh -or $parsed -gt $lastRefresh) { $lastRefresh = $parsed }
                        }
                    }
                }
            }
            else { $commandsKnown = $false }
        }
    }
    catch { $commandsKnown = $false }
    if ($commandsKnown -and ($null -eq $lastRefresh -or ([DateTime]::UtcNow.Date - $lastRefresh.Date).TotalDays -ge 30)) {
        $recorded = 'none'
        if ($null -ne $lastRefresh) { $recorded = $lastRefresh.ToString('yyyy-MM-dd') }
        $refreshKey = Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $recorded)
        $refreshStatePath = Join-Path $stateDir ('SpeckitCheck-refresh-' + $projectKey + '.txt')
        $refreshSaid = $false
        if (Test-Path -LiteralPath $refreshStatePath -PathType Leaf) {
            try { $refreshSaid = (([System.IO.File]::ReadAllText($refreshStatePath).Trim()) -eq $refreshKey) } catch { }
        }
        if (-not $refreshSaid) {
            $refreshLine = 'Refresh: `specify integration status` -> `specify integration upgrade <key>` EACH -> `specify extension update`; date .ai/COMMANDS.md.'
            try {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
                [System.IO.File]::WriteAllText($refreshStatePath, $refreshKey)
            }
            catch { }
        }
    }
}

if (-not $routeDue -and $refreshLine -eq '') { exit 0 }
if ($routeDue) {
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($statePath, $fingerprint)
    }
    catch { }
}
$message = $note
if (-not $routeDue) { $message = 'SPECKIT CHECK:' }
if ($refreshLine -ne '') { $message += "`n" + $refreshLine }

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $message
exit $emit.ExitCode
