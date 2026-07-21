# SkillsCheck - covers the whole skill lifecycle across three events, routed
# to the ACTIVE agent's skill locations (never both policies at once):
# - SessionStart: compact inventory naming each available skill (deduped by the
#   name: in its SKILL.md, not the folder name) and its source, once per session
#   (a fresh SessionStart, e.g. after /clear, re-lists on purpose).
# - UserPromptSubmit: a short reminder to search global + shared sources and
#   select only the minimal relevant set for THIS task, fingerprint-gated
#   (session + current skill set) so it does not repeat noisily on every prompt.
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
if ([string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) { $client = 'codex' } else { $client = 'claude' }
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
    $fingerprintSource = $sessionId + '|' + $client + '|' + $hasLibrary + '|' + $libraryDir + '|' + $hasRecord + '|' + $sig
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
