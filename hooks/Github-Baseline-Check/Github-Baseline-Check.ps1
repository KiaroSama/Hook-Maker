# GithubBaselineCheck - before work starts (SessionStart), checks whether a
# GitHub repository has an appropriate .github automation baseline for its
# REAL structure: a CI workflow, dependabot.yml with coverage for every
# detected ecosystem/directory (github-actions included when workflows exist),
# and - as secondary suggestions - CodeQL / dependency-review where supported.
#
# It inspects the local project only (manifests, lockfiles, monorepo package
# dirs, workflow files); no gh or network is needed. It reports concrete gaps
# and leaves the writing to the agent - it never copies a fixed template and
# never overwrites existing automation. The response is scope-aware: ordinary
# gaps (missing/weak CI, incomplete Dependabot coverage, optional CodeQL) are
# advisory for an unrelated task - fixed now only when the user asked for CI/
# repository/security/release work, the current task directly requires the
# missing baseline, or a workflow poses a confirmed unsafe risk. A confirmed
# unsafe workflow (pull_request_target + untrusted checkout) is called out as
# urgent regardless, though remediation still stays scoped and evidence-based.
#
# Silent when: not a git repo, no GitHub remote, the baseline already covers
# the detected structure, or the same findings were reported within the
# cooldown.
#
# No YAML parser is guaranteed in this environment, so workflow/Dependabot
# inspection stays a deliberate, bounded regex heuristic (Test-HasWorkflowTrigger,
# Test-HasValidationCommand) rather than a full parser - this is intentionally
# lightweight, not a general-purpose static analyzer. `on:` trigger detection
# recognizes block-style, flow-style ([a, b]), bare-value, and block-sequence
# forms, strictly SCOPED to the DIRECT children of the top-level `on:` block
# (only keys/sequence entries at the first-child indentation level) - an
# unrelated same-named key elsewhere in the file (a step's own `push: true`
# input, e.g. docker/build-push-action) or a trigger word nested DEEPER as an
# option (a `push` key under `workflow_dispatch: inputs:`) is never mistaken
# for a trigger.
# A `workflow_call`-only workflow with real validation counts as CI only when
# another local workflow (`uses: ./.github/workflows/<file>`) actually calls
# it AND that caller is itself directly triggered (push/pull_request/
# pull_request_target) - an uncalled reusable workflow is never counted as
# proof on its own. Multiline `run: |`/`run: >` blocks are scanned (bounded
# lookahead) for validation keywords, skipping full-line shell comments so a
# keyword that appears only in a comment (`# TODO: run npm test`) is not
# counted as real validation; a bare pyproject.toml defaults to the `pip`
# Dependabot ecosystem (also correct for Poetry, which has no separate
# ecosystem value), and is reclassified as `uv` only when a uv.lock sits beside it.
# Known, intentional limitations (would require real YAML/expression
# evaluation to close, which this hook deliberately does not add): a
# validation step disabled via an `if:` condition is not detected as disabled,
# there is no dedicated least-privilege `permissions:` check, and a reusable
# workflow called only from OUTSIDE this repository cannot be confirmed
# locally (reported as a gap, not falsely assumed complete).
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
# pyproject.toml is handled separately (not via $manifestMap): it is shared by
# plain pip/PEP 621 projects, Poetry, AND uv, but only uv has its OWN
# Dependabot package-ecosystem value ('uv') - Poetry has none and is correctly
# reported under 'pip' too. Distinguish by the presence of uv's lockfile.
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
            if ($fileName -eq 'pyproject.toml') {
                $relDir = $currentDir.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                if ($relDir -eq '') { $relDir = '/' } else { $relDir = '/' + $relDir }
                $pyEco = 'pip'
                if (Test-Path -LiteralPath (Join-Path $currentDir 'uv.lock') -PathType Leaf) { $pyEco = 'uv' }
                $ecosystems[($pyEco + '|' + $relDir)] = $fileName
            }
            elseif ($manifestMap.ContainsKey($fileName)) {
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

# Matches a YAML trigger keyword across the shapes real workflows use: a
# block-mapping key (`push:`), a flow-style list on the `on:` line
# (`on: [push, pull_request]`), a bare single value (`on: push`), or a
# block-sequence item (`on:` then `  - push`). Strictly scoped to the
# TOP-LEVEL `on:` block (its own line at column 0, keyword-'d or quoted;
# children indented strictly deeper than it, until indentation drops back)
# so an unrelated key elsewhere in the file - most commonly a step's own
# `push: true`/`push: false` input (e.g. docker/build-push-action) - is never
# mistaken for a trigger. No YAML parser is guaranteed in this environment
# (see README/.ai notes) - this stays a deliberate, bounded regex heuristic
# rather than a full parser.
function Test-HasWorkflowTrigger {
    param([string]$Text, [string[]]$Keywords)
    $union = ($Keywords -join '|')
    $lines = $Text -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(?<indent>\s*)["'']?on["'']?\s*:\s*(?<rest>.*)$') { continue }
        $indent = $Matches['indent'].Length
        if ($indent -ne 0) { continue }    # `on:` is only meaningful at the top level
        $rest = $Matches['rest'].Trim()
        if ($rest -ne '') {
            if ($rest -match ('^\[[^\]]*\b(' + $union + ')\b')) { return $true }             # flow-style list
            if ($rest -match ('^["'']?(' + $union + ')["'']?\s*(#.*)?$')) { return $true }    # bare single value
            continue    # a non-matching inline value - no block children to scan for this "on:"
        }
        # Block-style children of "on:" - but only the DIRECT children (the
        # first child's indentation level). A trigger key/sequence entry must
        # sit exactly at that level; anything deeper (e.g. a `push:` key nested
        # under `workflow_dispatch: inputs:`) is an input/option, not a
        # trigger, and must be ignored. The block ends when indentation drops
        # back to `on:`'s level or shallower.
        $childIndent = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $next = $lines[$j]
            if ($next.Trim() -eq '' -or $next.Trim().StartsWith('#')) { continue }
            $nextIndent = $next.Length - $next.TrimStart(' ').Length
            if ($nextIndent -le $indent) { break }
            if ($childIndent -lt 0) { $childIndent = $nextIndent }
            if ($nextIndent -ne $childIndent) { continue }    # deeper nested key - not a direct trigger
            if ($next -match ('^\s*["'']?(' + $union + ')["'']?\s*:')) { return $true }
            if ($next -match ('^\s*-\s*["'']?(' + $union + ')["'']?\s*$')) { return $true }
        }
    }
    return $false
}

# Whether any `run:`/`uses:` step contains a validation keyword - inline
# (`run: npm test`) or on the following, more-indented lines of a block
# scalar (`run: |` / `run: >` followed by the real shell commands, the most
# common real-world shape). Full-line shell comments are ignored so a keyword
# that appears ONLY in a comment (e.g. `# TODO: run npm test later`) is not
# counted as real validation; a genuine command on a later line still counts.
# A bounded lookahead keeps this a single deterministic pass rather than a
# full YAML/shell parse (no inline-comment stripping, which would need real
# shell parsing).
function Test-HasValidationCommand {
    param([string]$Text)
    $keywordPattern = '(?i)\b(test|lint|typecheck|type-check|build|verify|check)\b'
    $lines = $Text -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(?<indent>\s*)-?\s*(run|uses)\s*:\s*(?<rest>.*)$') { continue }
        $indent = $Matches['indent'].Length
        $rest = $Matches['rest'].TrimEnd()
        $restTrimmed = $rest.TrimStart()
        $isBlockScalar = ($restTrimmed -eq '' -or $restTrimmed -match '^[|>][+-]?\d*\s*$')
        # Inline command value on the run:/uses: line - but not when that value
        # is itself a comment (`run: # TODO test`).
        if (-not $isBlockScalar -and -not $restTrimmed.StartsWith('#') -and $rest -match $keywordPattern) { return $true }
        if ($isBlockScalar) {
            $limit = [Math]::Min($lines.Count, $i + 40)
            for ($j = $i + 1; $j -lt $limit; $j++) {
                $next = $lines[$j]
                if ($next.Trim() -eq '') { continue }
                $nextIndent = $next.Length - $next.TrimStart(' ').Length
                if ($nextIndent -le $indent) { break }    # block scalar ended
                if ($next.TrimStart().StartsWith('#')) { continue }    # full-line shell comment
                if ($next -match $keywordPattern) { return $true }
            }
        }
    }
    return $false
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

# ---- per-workflow signals + local reusable-workflow call graph ----
# A `workflow_call`-only workflow is never proof of CI on its own - it only
# runs when something else invokes it. It counts toward the baseline ONLY
# when either (a) it is ALSO directly triggered (push/pull_request/
# pull_request_target), or (b) another workflow in this repo actually calls
# it locally (`uses: ./.github/workflows/<file>` or `.github/workflows/<file>`)
# AND that caller is itself directly triggered. An uncalled reusable workflow
# is not counted as proof - this is the safe default (report a gap) rather
# than assuming a relationship that cannot be confirmed locally.
$workflowInfos = New-Object System.Collections.Generic.List[object]
$callersByCalledFile = @{}
foreach ($workflow in $workflowFiles) {
    $text = [System.IO.File]::ReadAllText($workflow.FullName)
    $hasDirectTrigger = Test-HasWorkflowTrigger -Text $text -Keywords @('push', 'pull_request', 'pull_request_target')
    $hasWorkflowCallTrigger = Test-HasWorkflowTrigger -Text $text -Keywords @('workflow_call')
    $hasValidation = Test-HasValidationCommand -Text $text
    $deployOnly = ($text -match '(?i)\b(deploy|publish|release)\b') -and -not $hasValidation
    [void]$workflowInfos.Add([pscustomobject]@{
        Name = $workflow.Name; Text = $text; HasDirectTrigger = $hasDirectTrigger
        HasWorkflowCallTrigger = $hasWorkflowCallTrigger; HasValidation = $hasValidation; DeployOnly = $deployOnly
    })
    foreach ($m in [regex]::Matches($text, '(?im)^\s*-?\s*uses\s*:\s*["'']?(\./[^\s"''#@]+|\.github[/\\]workflows[/\\][^\s"''#@]+)')) {
        $calledLeaf = (Split-Path -Leaf $m.Groups[1].Value.Trim()).ToLowerInvariant()
        if ($calledLeaf -eq '') { continue }
        if (-not $callersByCalledFile.ContainsKey($calledLeaf)) { $callersByCalledFile[$calledLeaf] = New-Object System.Collections.Generic.List[string] }
        [void]$callersByCalledFile[$calledLeaf].Add($workflow.Name)
    }
}

$meaningfulCi = $false
$workflowProblems = @()
$hasImmediateUnsafeRisk = $false
foreach ($info in $workflowInfos) {
    if ($info.HasValidation -and -not $info.DeployOnly) {
        if ($info.HasDirectTrigger) {
            $meaningfulCi = $true
        }
        elseif ($info.HasWorkflowCallTrigger) {
            $calledLeaf = $info.Name.ToLowerInvariant()
            if ($callersByCalledFile.ContainsKey($calledLeaf)) {
                foreach ($callerName in $callersByCalledFile[$calledLeaf]) {
                    $callerInfo = @($workflowInfos | Where-Object { $_.Name -eq $callerName }) | Select-Object -First 1
                    if ($null -ne $callerInfo -and $callerInfo.HasDirectTrigger) { $meaningfulCi = $true; break }
                }
            }
        }
    }
    $text = $info.Text
    if ($text -match '(?im)^\s*continue-on-error:\s*["'']?true["'']?\s*$' -and $info.HasValidation) { $workflowProblems += ($info.Name + ' makes validation non-blocking with continue-on-error') }
    if ((Test-HasWorkflowTrigger -Text $text -Keywords @('pull_request_target')) -and $text -match 'actions/checkout' -and $text -match '(?i)(github\.event\.pull_request\.head|head\.sha)') {
        $workflowProblems += ($info.Name + ' uses pull_request_target with untrusted PR checkout')
        $hasImmediateUnsafeRisk = $true    # confirmed unsafe workflow, an immediate security risk
    }
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
            'uv' { $codeqlLangs['python'] = $true }
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

$scopeNote = if ($hasImmediateUnsafeRisk) {
    'The pull_request_target + untrusted-checkout finding above is an immediate security risk (a fork PR can run with repository-level permissions) - treat it as urgent even in an otherwise unrelated task, but keep the fix itself scoped and evidence-based (inspect the real workflow first, change only what is actually unsafe).'
}
else {
    'These are advisory for an unrelated task: fix now only when the user asked for CI/repository/security/release setup, the current task directly requires the missing baseline, or a workflow poses a confirmed unsafe risk (see above) - otherwise preserve this finding for a separate task and continue the requested work. Never create or rewrite workflows during an unrelated task, and never treat the optional CodeQL suggestion as mandatory.'
}
$message = 'GITHUB BASELINE CHECK (' + $repoSlug + '): the .github automation baseline does not match the project structure:' + "`n" +
    ($findings -join "`n") + "`n" +
    $scopeNote + ' When a fix does go ahead: inspect the real project first, use its actual commands, and never blindly copy templates or overwrite working project-specific automation.'
@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $message } } |
    ConvertTo-Json -Depth 5 -Compress
exit 0
