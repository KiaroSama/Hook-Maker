# GithubBaselineCheck - before work starts (SessionStart), checks whether a
# GitHub repository has an appropriate .github automation baseline for its
# REAL structure: a CI workflow, dependabot.yml with coverage for every
# detected ecosystem/directory (github-actions included when workflows exist),
# and - as secondary suggestions - CodeQL / dependency-review where supported.
#
# It inspects the local project only (manifests, lockfiles, monorepo package
# dirs, workflow files); no gh or network is needed. It reports concrete gaps
# and leaves the writing to the agent under the repository rules - it never
# copies a fixed template and never overwrites existing automation.
#
# Silent when: not a git repo, no GitHub remote, the baseline already covers
# the detected structure, or the same findings were reported within the
# cooldown.
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between identical reports per repo (default 240)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
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
if ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop') {
    exit 0
}

# ---- GitHub repository? ----
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    exit 0
}
$inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'rev-parse', '--is-inside-work-tree')
if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') {
    exit 0
}
$repository = Get-GitHubRepository -ProjectRoot $cwd
if ($null -eq $repository) { exit 0 }
$repoSlug = $repository.Repository

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 240
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}

# ---- inspect the real project structure (local only, pruned, depth-capped) ----
$manifestMap = @{
    'package.json'     = 'npm'
    'requirements.txt' = 'pip'
    'pyproject.toml'   = 'pip'
    'Pipfile'          = 'pip'
    'go.mod'           = 'gomod'
    'Cargo.toml'       = 'cargo'
    'composer.json'    = 'composer'
    'Gemfile'          = 'bundler'
    'Dockerfile'       = 'docker'
    'pom.xml'          = 'maven'
    'build.gradle'     = 'gradle'
    'build.gradle.kts' = 'gradle'
    'packages.config'  = 'nuget'
}
$sourceExtensions = @('.ps1', '.psm1', '.py', '.js', '.ts', '.jsx', '.tsx', '.mjs', '.cjs', '.cs', '.java', '.go', '.rb', '.php', '.rs', '.c', '.cpp', '.h', '.kt', '.swift')
$excludedDirs = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync', '.github')

# ecosystems: key "eco|/dir" -> present; sourceCount for manifest-less code repos
$ecosystems = @{}
$sourceCount = 0
$rootFull = (Get-Item -LiteralPath $cwd).FullName.TrimEnd('\', '/')
$stack = New-Object System.Collections.Generic.Stack[object]
$stack.Push(@($rootFull, 0))
while ($stack.Count -gt 0) {
    $frame = $stack.Pop()
    $currentDir = [string]$frame[0]
    $depth = [int]$frame[1]
    try {
        foreach ($childDir in [System.IO.Directory]::EnumerateDirectories($currentDir)) {
            $leaf = Split-Path -Leaf $childDir
            $item = Get-Item -LiteralPath $childDir -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and $excludedDirs -notcontains $leaf.ToLowerInvariant()) {
                $stack.Push(@($childDir, ($depth + 1)))
            }
        }
        foreach ($file in [System.IO.Directory]::EnumerateFiles($currentDir)) {
            $fileName = Split-Path -Leaf $file
            if ($manifestMap.ContainsKey($fileName)) {
                $relDir = $currentDir.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                if ($relDir -eq '') { $relDir = '/' } else { $relDir = '/' + $relDir }
                $ecosystems[($manifestMap[$fileName] + '|' + $relDir)] = $fileName
            }
            elseif ([System.IO.Path]::GetExtension($fileName) -in @('.csproj', '.fsproj', '.vbproj', '.sln')) {
                $relDir = $currentDir.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                if ($relDir -eq '') { $relDir = '/' } else { $relDir = '/' + $relDir }
                $ecosystems[('nuget|' + $relDir)] = $fileName
            }
            elseif ($sourceExtensions -contains [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()) {
                $sourceCount++
            }
        }
    }
    catch { }
}

# workflows + dependabot config
$workflowsDir = Join-Path $cwd '.github\workflows'
$workflowFiles = @()
if (Test-Path -LiteralPath $workflowsDir -PathType Container) {
    $workflowFiles = @(Get-ChildItem -LiteralPath $workflowsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml', '.yaml') })
}
$dependabotPath = Join-Path $cwd '.github\dependabot.yml'
if (-not (Test-Path -LiteralPath $dependabotPath -PathType Leaf)) {
    $alt = Join-Path $cwd '.github\dependabot.yaml'
    if (Test-Path -LiteralPath $alt -PathType Leaf) { $dependabotPath = $alt } else { $dependabotPath = '' }
}

# required dependabot coverage = detected ecosystems + github-actions when workflows exist
$required = @{}
foreach ($key in $ecosystems.Keys) { $required[$key] = $true }
if ($workflowFiles.Count -gt 0) { $required['github-actions|/'] = $true }

# covered pairs from the existing dependabot config (light block parse)
$covered = @{}
$dependabotMalformed = $false
if ($dependabotPath -ne '') {
    $dependabotText = [System.IO.File]::ReadAllText($dependabotPath)
    if ($dependabotText -notmatch '(?m)^\s*version:\s*["'']?2["'']?\s*$' -or $dependabotText -notmatch '(?m)^\s*updates:\s*$') { $dependabotMalformed = $true }
    $blocks = [regex]::Split($dependabotText, '(?m)^\s*-\s+package-ecosystem:')
    for ($i = 1; $i -lt $blocks.Count; $i++) {
        $block = $blocks[$i]
        $eco = ''
        if ($block -match '^\s*["'']?([a-z-]+)') { $eco = $Matches[1] }
        $dirs = @()
        if ($block -match '(?m)^\s*directory:\s*["'']?([^"''#\r\n]+)') { $dirs += $Matches[1].Trim() }
        $directoriesMatch = [regex]::Match($block, '(?ms)^\s*directories:\s*\r?\n(?<items>(?:\s*-\s*[^\r\n]+\r?\n?)+)')
        if ($directoriesMatch.Success) {
            foreach ($item in [regex]::Matches($directoriesMatch.Groups['items'].Value, '(?m)^\s*-\s*["'']?([^"''#\r\n]+)')) { $dirs += $item.Groups[1].Value.Trim() }
        }
        if ($dirs.Count -eq 0) { $dirs = @('/') }
        foreach ($dir in $dirs) {
            if ($dir -ne '/') { $dir = '/' + $dir.Trim('/') }
            if ($eco -ne '' -and -not $dependabotMalformed) { $covered[($eco + '|' + $dir)] = $true }
        }
    }
}

# ---- findings ----
$findings = @()
$hasCode = ($ecosystems.Count -gt 0 -or $sourceCount -ge 3)

$meaningfulCi = $false
$workflowProblems = @()
foreach ($workflow in $workflowFiles) {
    $text = [System.IO.File]::ReadAllText($workflow.FullName)
    $hasTrigger = $text -match '(?m)^\s*(push|pull_request)\s*:'
    $hasValidation = $text -match '(?im)^\s*-?\s*(run|uses)\s*:.*\b(test|lint|typecheck|type-check|build|verify|check)\b'
    $deployOnly = $text -match '(?i)\b(deploy|publish|release)\b' -and -not $hasValidation
    if ($hasTrigger -and $hasValidation -and -not $deployOnly) { $meaningfulCi = $true }
    if ($text -match '(?im)^\s*continue-on-error:\s*true\s*$' -and $hasValidation) { $workflowProblems += ($workflow.Name + ' makes validation non-blocking with continue-on-error') }
    if ($text -match '(?m)^\s*pull_request_target\s*:' -and $text -match 'actions/checkout' -and $text -match '(?i)(github\.event\.pull_request\.head|head\.sha)') { $workflowProblems += ($workflow.Name + ' uses pull_request_target with untrusted PR checkout') }
}

if (-not $meaningfulCi -and $hasCode) {
    $detected = @($ecosystems.Keys | Sort-Object | ForEach-Object { $_.Replace('|', ' at ') })
    $detectedText = 'source files only'
    if ($detected.Count -gt 0) { $detectedText = ($detected -join ', ') }
    $findingPrefix = if ($workflowFiles.Count -eq 0) { 'No CI workflow' } else { 'Workflow files exist, but none provides blocking project validation' }
    $findings += ('- ' + $findingPrefix + ' (.github/workflows). Detected: ' + $detectedText + '. Add CI on push/pull_request that runs the project''s real lint/test/type-check/build commands; keep failures blocking; use least-privilege permissions and avoid unsafe pull_request_target execution.')
}
foreach ($problem in $workflowProblems) { $findings += ('- Unsafe/non-blocking workflow: ' + $problem + '.') }

if ($dependabotPath -eq '') {
    if ($required.Count -gt 0) {
        $needed = @($required.Keys | Sort-Object | ForEach-Object { $_.Replace('|', ' at ') })
        $findings += ('- No .github/dependabot.yml. Needed entries: ' + ($needed -join ', ') + '.')
    }
}
else {
    if ($dependabotMalformed) { $findings += '- dependabot.yml is malformed or missing version: 2 / updates; coverage cannot be trusted.' }
    $missing = @()
    foreach ($key in ($required.Keys | Sort-Object)) {
        if (-not $covered.ContainsKey($key)) { $missing += $key.Replace('|', ' at ') }
    }
    if ($missing.Count -gt 0) {
        $findings += ('- dependabot.yml exists but lacks entries for: ' + ($missing -join ', ') + '. Do not remove or rewrite the working entries; add only what is missing.')
    }
}

# Secondary suggestions - only when a primary gap already exists (keeps an
# otherwise-adequate baseline silent).
if ($findings.Count -gt 0) {
    $codeqlLangs = @{}
    foreach ($key in $ecosystems.Keys) {
        switch (($key -split '\|')[0]) {
            'npm' { $codeqlLangs['javascript-typescript'] = $true }
            'pip' { $codeqlLangs['python'] = $true }
            'gomod' { $codeqlLangs['go'] = $true }
            'bundler' { $codeqlLangs['ruby'] = $true }
        }
    }
    if ($codeqlLangs.Count -gt 0) {
        $hasCodeql = $false
        foreach ($wf in $workflowFiles) {
            if ($wf.Name -match '(?i)codeql') { $hasCodeql = $true; break }
        }
        if (-not $hasCodeql) {
            $findings += ('- Optional: CodeQL scanning supports the detected language(s) (' + (@($codeqlLangs.Keys | Sort-Object) -join ', ') + ') and is not configured.')
        }
    }
}

if ($findings.Count -eq 0) {
    exit 0
}

# ---- fingerprint + cooldown so unchanged findings are not repeated ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('GithubBaselineCheck-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $repoSlug.ToLowerInvariant())) + '.txt')
$fingerprint = Get-ShortHash (($findings -join '~'))
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $stateLines = [System.IO.File]::ReadAllLines($statePath)
        if ($stateLines.Count -ge 2 -and $stateLines[0].Trim() -eq $fingerprint) {
            $lastTime = [DateTime]::Parse($stateLines[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            if (([DateTime]::UtcNow - $lastTime).TotalMinutes -lt $cooldownMinutes) {
                exit 0
            }
        }
    }
    catch { }
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllLines($statePath, @($fingerprint, [DateTime]::UtcNow.ToString('o')))

$message = 'GITHUB BASELINE CHECK (' + $repoSlug + '): the .github automation baseline does not match the project structure:' + "`n" +
    ($findings -join "`n") + "`n" +
    'Fix per the repository rules: inspect the real project first, use its actual commands, and never blindly copy templates or overwrite working project-specific automation.'
@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
