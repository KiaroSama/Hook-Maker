# SkillsCheck - before work starts (SessionStart), injects a compact Skill
# Policy reminder: check whether a relevant skill exists BEFORE doing the work
# manually, activate the minimal set, and record it. The AI decides; trivial
# edits need no skills.
#
# Token-efficient by design:
# - Completely silent when no skill source exists (no library, no copied
#   project skills, no .ai/SKILLS.md record).
# - The injected note is a few short lines listing only what actually exists.
#
# Optional .env next to this script (copy .env.example):
#   SKILLS_DIR  overrides the skill library location (else AI_SKILLS_DIR env
#               var, else the machine default from the Skill Policy).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Field {
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) {
        return $Obj.$Name
    }
    return $null
}

$hookInput = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $hookInput = $raw | ConvertFrom-Json
    }
}
catch { }
if ($null -eq $hookInput) {
    exit 0
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) {
    $eventName = 'SessionStart'
}
# Context injection only makes sense for context events.
if ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop') {
    exit 0
}

# ---- optional .env ----
$config = @{}
$envPath = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    foreach ($line in [System.IO.File]::ReadAllLines($envPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -gt 0) {
            $config[$trimmed.Substring(0, $separator).Trim()] = $trimmed.Substring($separator + 1).Trim()
        }
    }
}

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

# Nothing to point at -> stay silent, zero tokens.
if (-not $hasLibrary -and $copiedSkills.Count -eq 0 -and -not $hasRecord) {
    exit 0
}

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

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
