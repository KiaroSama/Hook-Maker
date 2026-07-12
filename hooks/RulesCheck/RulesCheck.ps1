# RulesCheck - before work starts (SessionStart, UserPromptSubmit), verifies
# that the configured rules directories were read: the user's GLOBAL rules
# (~\.claude\rules or ~\.codex\rules) and the current project's LOCAL rules
# (<project>\.claude\rules or <project>\.codex\rules).
#
# Client awareness: Claude Code exports CLAUDE_PROJECT_DIR on every spawned
# hook process (official docs), Codex does not - so the hook auto-detects
# which client is running and checks that client's rules directories. An
# explicit -Client claude|codex parameter overrides the detection.
#
# Token-efficient by design:
# - First check of a project: lists ALL rules files once and asks the AI to
#   confirm they are read before starting.
# - Afterwards it stays completely silent until a rules file is ADDED,
#   CHANGED, or REMOVED (fingerprint per project + client); then it reports
#   exactly what moved and asks for a re-read of those files only.
#
# Optional .env next to this script (copy .env.example):
#   GLOBAL_RULES_DIR  overrides the global rules directory (default:
#                     <home>\.claude\rules or <home>\.codex\rules by client)

param(
    # 'claude', 'codex', or '' for auto-detection via CLAUDE_PROJECT_DIR.
    [string]$Client = ''
)

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

# ---- which client is running? ----
$Client = $Client.Trim().ToLowerInvariant()
if ($Client -ne 'claude' -and $Client -ne 'codex') {
    if ([string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) {
        $Client = 'codex'
    }
    else {
        $Client = 'claude'
    }
}
$clientDirName = '.' + $Client

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

# ---- rules directories: global (home) + local (project) ----
# USERPROFILE first: Windows PowerShell 5.1 derives $HOME from HOMEDRIVE/HOMEPATH,
# which can disagree with the profile the user actually means.
$homeDir = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($homeDir)) {
    $homeDir = [string]$HOME
}
$globalRulesDir = ''
if ($config.ContainsKey('GLOBAL_RULES_DIR') -and $config['GLOBAL_RULES_DIR'] -ne '') {
    $globalRulesDir = $config['GLOBAL_RULES_DIR']
}
elseif (-not [string]::IsNullOrWhiteSpace($homeDir)) {
    $globalRulesDir = Join-Path $homeDir (Join-Path $clientDirName 'rules')
}
$projectRulesDir = Join-Path $cwd (Join-Path $clientDirName 'rules')

$ruleSets = @(
    [pscustomobject]@{ Label = 'Global rules'; Dir = $globalRulesDir },
    [pscustomobject]@{ Label = 'Project rules'; Dir = $projectRulesDir }
)

# One line per rules file: <path>|<size>|<mtimeUtcTicks>. The joined lines ARE
# the fingerprint; a diff against the stored lines names what moved.
$currentEntries = @{}
foreach ($set in $ruleSets) {
    if ($set.Dir -eq '' -or -not (Test-Path -LiteralPath $set.Dir -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $set.Dir -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $currentEntries[$file.FullName] = $file.FullName + '|' + $file.Length + '|' + $file.LastWriteTimeUtc.Ticks
    }
}

# ---- state (per project + client) ----
function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally {
        $sha.Dispose()
    }
}
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('RulesCheck-' + $Client + '-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$firstRun = -not (Test-Path -LiteralPath $statePath -PathType Leaf)
$previousEntries = @{}
if (-not $firstRun) {
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($statePath)) {
            if ($line.Trim() -eq '') { continue }
            $path = $line.Split('|')[0]
            $previousEntries[$path] = $line
        }
    }
    catch { $firstRun = $true }
}

# Nothing configured and nothing remembered -> silent, zero tokens.
if ($firstRun -and $currentEntries.Count -eq 0) {
    exit 0
}

# ---- diff ----
$newFiles = New-Object System.Collections.Generic.List[string]
$changedFiles = New-Object System.Collections.Generic.List[string]
$removedFiles = New-Object System.Collections.Generic.List[string]
foreach ($path in @($currentEntries.Keys | Sort-Object)) {
    if (-not $previousEntries.ContainsKey($path)) {
        [void]$newFiles.Add($path)
    }
    elseif ($previousEntries[$path] -ne $currentEntries[$path]) {
        [void]$changedFiles.Add($path)
    }
}
foreach ($path in @($previousEntries.Keys | Sort-Object)) {
    if (-not $currentEntries.ContainsKey($path)) {
        [void]$removedFiles.Add($path)
    }
}
if (-not $firstRun -and $newFiles.Count -eq 0 -and $changedFiles.Count -eq 0 -and $removedFiles.Count -eq 0) {
    exit 0
}

# ---- build the note ----
$lines = New-Object System.Collections.Generic.List[string]
if ($firstRun) {
    [void]$lines.Add('RULES CHECK (' + $Client + ') - first check of this project. Before starting the task, make sure EVERY configured rules file below has been read and is applied:')
}
else {
    [void]$lines.Add('RULES CHECK (' + $Client + ') - the configured rules changed since the last check of this project. Read the new/changed files BEFORE starting the task:')
    foreach ($path in $newFiles) { [void]$lines.Add('- NEW: ' + $path) }
    foreach ($path in $changedFiles) { [void]$lines.Add('- CHANGED: ' + $path) }
    foreach ($path in $removedFiles) { [void]$lines.Add('- REMOVED: ' + $path + ' (no longer applies)') }
    if ($currentEntries.Count -gt 0) {
        [void]$lines.Add('Then confirm the FULL rule set is still applied:')
    }
}
foreach ($set in $ruleSets) {
    if ($set.Dir -eq '') { continue }
    $names = @($currentEntries.Keys |
        Where-Object { $_.StartsWith($set.Dir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object |
        ForEach-Object { $_.Substring($set.Dir.TrimEnd('\').Length + 1) })
    if ($names.Count -gt 0) {
        [void]$lines.Add('- ' + $set.Label + ' (' + $set.Dir + '): ' + ($names -join ', '))
    }
}
[void]$lines.Add('Rules already loaded in context only need a confirmation, not a re-read. This check stays silent until a rules file changes again.')

# ---- persist state, then report ----
try {
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllLines($statePath, [string[]]@($currentEntries.Values | Sort-Object))
}
catch { }

@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines.ToArray() -join "`n") } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
