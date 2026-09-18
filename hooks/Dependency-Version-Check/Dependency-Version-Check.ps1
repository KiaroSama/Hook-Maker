# DependencyVersionCheck - ADVISORY hook (SessionStart, UserPromptSubmit, Stop, SubagentStop) that
# helps the coding agent notice outdated dependencies/runtimes/build tools/CI actions/base images
# and prefer the latest STABLE, compatible version for new work. It never modifies manifests,
# lockfiles, workflows, Dockerfiles, or source code, never runs an upgrade, never auto-merges
# Dependabot PRs, and NEVER BLOCKS - it only provides evidence and instructs the agent to verify
# safety (release notes, breaking changes, peer/runtime constraints, security advisories) before
# updating, and to update in small verified batches rather than one large uncontrolled one. A newer
# version is never assumed safer or better; when no safe update is identified the agent may keep the
# current version.
#
# ROLE (global-hook-rules.md, "Hook Roles" + Integration Matrix): DETECTOR/ADVISORY, on every event
# including the closing ones. Whether to upgrade is the user's decision and a judgement the hook
# cannot make, so there is deliberately NO gate here - not on Stop, not anywhere. What changed is
# the OUTPUT CONTRACT, not the scanning: the report now states exactly what the agent must do with
# each finding (decide, and name the decision), and the closing half re-surfaces the findings once
# per session so the report cannot simply scroll out of context unanswered. The weakness this
# addresses was never detection - it was that a correct report was trivially ignorable.
#
# THE REQUESTED LINE: when findings exist, the closing summary should carry a line starting
# "Dependency decisions:" answering each reported finding with update / keep / defer and a reason.
# It is requested, never enforced - an unanswered finding is reported as an unreviewed risk rather
# than as a refusal to stop.
#
# Relationship to other hooks: Dependabot-Check reports EXISTING verified Dependabot PRs (this hook
# never duplicates that listing). Github-Baseline-Check verifies the CI/Dependabot BASELINE
# structure. This hook independently checks CURRENT VERSION FRESHNESS and only runs pre-task.
#
# What it inspects (only ecosystems actually detected in the project; commands verified against
# each tool's own documentation, not guessed):
# - npm (package.json + a lockfile): `npm outdated --json` - real npm command, stable across
#   versions; exits 1 when outdated packages are found (NOT a failure - only exit codes >1 or the
#   command being missing are treated as a real error).
# - Python pip (requirements*.txt / a bare pyproject.toml without uv.lock): `pip list --outdated
#   --format=json` - real pip command with stable JSON output. It runs THIS PROJECT's interpreter
#   (.venv/venv, or VIRTUAL_ENV when that points inside the project), never whatever `pip` resolves
#   to on PATH: the global environment's packages are not this project's dependencies. No project
#   environment means the check is reported INCOMPLETE, never answered from global. It reads INSTALLED
#   the versions declared in requirements.txt directly - if no venv is activated or nothing is
#   installed yet, there is nothing to report (not the same as "everything current").
# - Go (go.mod): `go list -u -m all` - real, built into the Go toolchain; a trailing `[newver]` on a
#   module line means an update is available.
# - GitHub Actions (`.github/workflows/*.yml`): static `uses:` scan against a small known-minimum-
#   major table for common official actions - flags CLEARLY old major versions (below the minimum),
#   never claims a pinned action IS the latest.
# - Runtime pins (`.nvmrc`/`.node-version`/`engines.node` in package.json; a Python version file or
#   `python_requires`): static comparison against a short known-EOL list.
# - Docker base images (`Dockerfile*` `FROM` lines): a floating `:latest` tag (or no tag at all) is
#   flagged as non-reproducible; a small known-EOL base-image/tag list is checked.
# - Other detected ecosystems (pnpm/yarn/bun, Poetry/uv, .NET, Java/Kotlin, Rust/Cargo, PHP
#   Composer, Ruby Bundler) are DETECTED but reported as an INCOMPLETE check with the command the
#   agent should run manually, rather than guessing at a fragile text-table parse or a subcommand
#   that may not be installed (e.g. Cargo has no built-in "outdated" - it requires the separate
#   `cargo-outdated` crate).
#
# Never fails the task and never reports "current" when a check could not run (missing tool,
# network/registry unavailable, unexpected output) - such gaps are listed as incomplete instead.
#
# Performance: SessionStart runs a full scan only when the per-project fingerprint (detected
# ecosystems + manifest/lockfile paths + content hashes, no secret values) changed or the cooldown
# expired; UserPromptSubmit reuses the cached findings and additionally injects "prefer latest
# stable compatible version" guidance when the prompt looks like it is adding a dependency,
# framework, runtime, build tool, GitHub Action, Docker image, SDK, or CLI, or starting a project
# from scratch. Stop/SubagentStop replay the cached report only, once per session per report state:
# they still do the local manifest walk that keys the cache (the same bounded, pruned traversal the
# pre-task events do), but they never invoke npm/pip/go and never re-derive findings.
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minutes between full scans when the project fingerprint is unchanged (default 10080 = 7 days)
#   MAX_FINDINGS      maximum findings included in one report (default 12)
#   CLOSING_REMINDER  1 (default) to replay unanswered findings at Stop, 0 to stay pre-task only

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')
# Interpreter selection and dependency scope live beside this hook: which
# environment speaks for the project, and which packages of it are the project's
# (an inherited global set is the machine's, not this project's). Loaded
# OPTIONALLY so a runtime copied before it existed still starts - the pip branch
# then degrades to declared-only scope and says so.
$script:PythonScopeReady = $false
try {
    $pythonScopePath = Join-Path $PSScriptRoot '_pythonscope.ps1'
    if (Test-Path -LiteralPath $pythonScopePath -PathType Leaf) { . $pythonScopePath; $script:PythonScopeReady = $true }
}
catch { $script:PythonScopeReady = $false }

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')) { exit 0 }
$closing = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
# This hook never blocks, so it can never provoke the re-entry itself - but a
# blocking hook on the same event can, and doing the work twice for one stop is
# waste. Every Stop handler honours the flag.
if ($closing) {
    $stopActive = Get-Field $hookInput 'stop_hook_active'
    if ($null -ne $stopActive -and [bool]$stopActive) { exit 0 }
}
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 10080
if ($config.ContainsKey('COOLDOWN_MINUTES')) { try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { } }
$maxFindings = 12
if ($config.ContainsKey('MAX_FINDINGS')) { try { $maxFindings = [int]$config['MAX_FINDINGS'] } catch { } }
$closingReminder = $true
if ($config.ContainsKey('CLOSING_REMINDER')) {
    $raw = ([string]$config['CLOSING_REMINDER']).Trim()
    if ($raw -eq '0') { $closingReminder = $false }
}
if ($closing -and -not $closingReminder) { exit 0 }

# The exact wording the closing summary is asked to carry. One definition, used
# by the report footer and by the closing reminder, so they cannot drift apart.
$script:DependencyDecisionLine = 'Dependency decisions: <name>=update|keep|defer (<reason>), ... (or "Dependency decisions: none - <one-line reason>")'

# ---- known-minimum-major table for common official GitHub Actions (conservative: only flags
# CLEARLY old majors; an action at/above the minimum is never asserted to be the latest) ----
$script:ActionMinimumMajor = @{
    'actions/checkout'          = 3
    'actions/setup-node'        = 3
    'actions/setup-python'      = 4
    'actions/setup-dotnet'      = 3
    'actions/cache'             = 3
    'actions/upload-artifact'   = 3
    'actions/download-artifact' = 3
    'docker/build-push-action'  = 5
    'docker/login-action'       = 2
    'docker/setup-buildx-action' = 2
    'cloudflare/wrangler-action' = 2
}
# Known end-of-life runtime majors/versions (conservative - only long-clearly-EOL entries).
$script:NodeEolMajors = @(10, 12, 14, 16)
$script:PythonEolVersions = @('2.7', '3.5', '3.6', '3.7', '3.8')
$script:DockerEolBaseImages = @(
    'node:14', 'node:16', 'node:18',
    'python:3.7', 'python:3.8',
    'ubuntu:18.04', 'ubuntu:16.04',
    'debian:9', 'debian:10', 'debian:stretch', 'debian:buster'
)

# ---- ecosystem + fixture detection (pruned local traversal, same convention as
# Github-Baseline-Check.ps1) ----
$excludedDirs = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync')
$rootFull = (Get-Item -LiteralPath $cwd).FullName.TrimEnd('\', '/')

function Get-RelDir {
    param([string]$Dir)
    $rel = $Dir.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
    if ($rel -eq '') { return '/' }
    return '/' + $rel
}

# manifestPaths: ecosystem key -> list of directories where its manifest was found (root-first).
# manifestFiles: every manifest/lockfile path actually found, used ONLY for the content
# fingerprint (so an edit to package.json - e.g. adding a dependency - invalidates the cache
# even though the manifest's directory/ecosystem didn't change).
$manifestPaths = @{}
$manifestFiles = New-Object System.Collections.Generic.List[string]
function Add-ManifestHit {
    param([string]$Ecosystem, [string]$Dir, [string]$FilePath)
    if (-not $manifestPaths.ContainsKey($Ecosystem)) { $manifestPaths[$Ecosystem] = New-Object System.Collections.Generic.List[string] }
    [void]$manifestPaths[$Ecosystem].Add($Dir)
    [void]$manifestFiles.Add($FilePath)
}

$dockerfiles = New-Object System.Collections.Generic.List[string]
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($rootFull)
$visited = 0
while ($stack.Count -gt 0 -and $visited -lt 4000) {
    $current = $stack.Pop()
    $visited++
    try {
        foreach ($dir in [System.IO.Directory]::EnumerateDirectories($current)) {
            $leaf = Split-Path -Leaf $dir
            if ($excludedDirs -contains $leaf) { continue }
            # A virtualenv is pruned by its PEP 405 marker, not its name (see _hooklib.ps1).
            if (Test-IsMarkerPrunedDirectory $dir) { continue }
            $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or $item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($dir)
        }
        foreach ($file in [System.IO.Directory]::EnumerateFiles($current)) {
            $name = Split-Path -Leaf $file
            switch -Regex ($name) {
                '^package\.json$' { Add-ManifestHit 'npm' $current $file; continue }
                '^pnpm-lock\.yaml$' { Add-ManifestHit 'pnpm' $current $file; continue }
                '^yarn\.lock$' { Add-ManifestHit 'yarn' $current $file; continue }
                '^bun\.lock(b)?$' { Add-ManifestHit 'bun' $current $file; continue }
                '^requirements.*\.txt$' { Add-ManifestHit 'pip' $current $file; continue }
                '^Pipfile$' { Add-ManifestHit 'pip' $current $file; continue }
                '^poetry\.lock$' { Add-ManifestHit 'poetry' $current $file; continue }
                '^uv\.lock$' { Add-ManifestHit 'uv' $current $file; continue }
                '^pyproject\.toml$' {
                    if (-not (Test-Path -LiteralPath (Join-Path $current 'poetry.lock')) -and -not (Test-Path -LiteralPath (Join-Path $current 'uv.lock'))) {
                        Add-ManifestHit 'pip' $current $file
                    }
                    continue
                }
                '^go\.mod$' { Add-ManifestHit 'go' $current $file; continue }
                '^Cargo\.toml$' { Add-ManifestHit 'cargo' $current $file; continue }
                '^(.*\.csproj|.*\.fsproj|.*\.vbproj|global\.json)$' { Add-ManifestHit 'nuget' $current $file; continue }
                '^(pom\.xml)$' { Add-ManifestHit 'maven' $current $file; continue }
                '^(build\.gradle|build\.gradle\.kts)$' { Add-ManifestHit 'gradle' $current $file; continue }
                '^composer\.json$' { Add-ManifestHit 'composer' $current $file; continue }
                '^Gemfile$' { Add-ManifestHit 'bundler' $current $file; continue }
                '^Dockerfile.*$' { [void]$dockerfiles.Add($file); continue }
            }
        }
    }
    catch { }
}

$workflowsDir = Join-Path $cwd '.github\workflows'
$workflowFiles = @()
if (Test-Path -LiteralPath $workflowsDir -PathType Container) {
    $workflowFiles = @(Get-ChildItem -LiteralPath $workflowsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yml', '.yaml') })
}

$runtimePinFiles = @(@('.nvmrc', '.node-version', '.python-version', 'runtime.txt') | ForEach-Object { Join-Path $cwd $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

$detectedEcosystems = @($manifestPaths.Keys | Sort-Object)
if ($detectedEcosystems.Count -eq 0 -and $workflowFiles.Count -eq 0 -and $dockerfiles.Count -eq 0 -and $runtimePinFiles.Count -eq 0) {
    exit 0    # nothing this hook has any evidence about
}

# ---- fingerprint (manifest/lockfile paths + content hash, ecosystems, workflow/Dockerfile paths -
# no secret values, no full file contents stored) ----
$fingerprintParts = New-Object System.Collections.Generic.List[string]
foreach ($eco in $detectedEcosystems) {
    foreach ($dir in @($manifestPaths[$eco] | Sort-Object)) {
        [void]$fingerprintParts.Add($eco + '|' + $dir)
    }
}
foreach ($mf in @($manifestFiles | Sort-Object -Unique)) {
    # Content hash, not just presence - editing a manifest (e.g. adding a dependency to
    # package.json) must invalidate the cache even though its directory/ecosystem is unchanged.
    try { [void]$fingerprintParts.Add('manifest|' + $mf + '|' + (Get-ShortHash ([System.IO.File]::ReadAllText($mf)))) } catch { }
}
foreach ($wf in @($workflowFiles | Sort-Object FullName)) {
    try { [void]$fingerprintParts.Add('workflow|' + $wf.FullName + '|' + (Get-ShortHash ([System.IO.File]::ReadAllText($wf.FullName)))) } catch { }
}
foreach ($rp in @($runtimePinFiles | Sort-Object)) {
    try { [void]$fingerprintParts.Add('runtimepin|' + $rp + '|' + (Get-ShortHash ([System.IO.File]::ReadAllText($rp)))) } catch { }
}
foreach ($df in @($dockerfiles | Sort-Object)) {
    try { [void]$fingerprintParts.Add('dockerfile|' + $df + '|' + (Get-ShortHash ([System.IO.File]::ReadAllText($df)))) } catch { }
}
$fingerprint = Get-ShortHash (($fingerprintParts.ToArray() -join '|'))

$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('DependencyVersionCheck-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')

function Read-CachedState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try {
        $lines = [System.IO.File]::ReadAllLines($statePath)
        if ($lines.Count -lt 3) { return $null }
        return [pscustomobject]@{ Fingerprint = $lines[0].Trim(); CheckedIso = $lines[1].Trim(); Report = ($lines[2..($lines.Count - 1)] -join "`n") }
    }
    catch { return $null }
}
function Save-CachedState {
    param([string]$Report)
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $lines = @($fingerprint, [DateTime]::UtcNow.ToString('o')) + @($Report -split "`n")
    [System.IO.File]::WriteAllLines($statePath, $lines)
}

# ---- Stop/SubagentStop: replay the cached findings once, never scan, never block ----
# The closing half exists because a correct pre-task report is trivially ignorable: it lands at the
# top of a session and is gone by the time anything is decided. This replays only what was already
# measured - no npm/go/pip invocation, no traversal - and only when there are real FINDINGS.
# An "incomplete checks" report alone is not replayed: there is nothing at the end of a task to
# decide about a check that could not run.
if ($closing) {
    $cached = Read-CachedState
    if ($null -eq $cached -or $cached.Fingerprint -ne $fingerprint -or [string]::IsNullOrWhiteSpace($cached.Report)) { exit 0 }
    $findingLines = @($cached.Report -split "`n" | Where-Object { $_ -match '^\- ' -and $_ -match '\[(patch|minor|major|prerelease|EOL|unknown)\]\s*$' })
    if ($findingLines.Count -eq 0) { exit 0 }

    # Say it once per session per report state: an unchanged report does not repeat on every Stop of
    # the same session, while a changed one is reported immediately.
    $sessionId = [string](Get-Field $hookInput 'session_id')
    $closeGatePath = Join-Path $stateDir ('DependencyVersionCheck-close-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
    $closeFingerprint = Get-ShortHash ($sessionId + '|' + $eventName + '|' + $fingerprint + '|' + $findingLines.Count)
    if (Test-Path -LiteralPath $closeGatePath -PathType Leaf) {
        try { if (([System.IO.File]::ReadAllText($closeGatePath)).Trim() -eq $closeFingerprint) { exit 0 } } catch { }
    }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($closeGatePath, $closeFingerprint, (New-Object System.Text.UTF8Encoding $false))
    }
    catch { }

    # End-of-life and clearly-old-major entries are separated out because they are the two classes
    # where "leave it" needs a stated reason rather than silence.
    $urgent = @($findingLines | Where-Object { $_ -match '\[(EOL|major)\]\s*$' })
    $closeLines = New-Object System.Collections.Generic.List[string]
    [void]$closeLines.Add('DEPENDENCY VERSION CHECK - ' + $findingLines.Count + ' finding(s) were reported for this project at the start of the session and are still on the table:')
    foreach ($f in @($findingLines | Select-Object -First $maxFindings)) { [void]$closeLines.Add($f) }
    if ($urgent.Count -gt 0) {
        [void]$closeLines.Add('Of those, ' + $urgent.Count + ' are end-of-life or a clearly old major version - those two classes need a stated reason to leave in place, not silence.')
    }
    [void]$closeLines.Add('Answer each one in the final summary on its own line: ' + $script:DependencyDecisionLine)
    [void]$closeLines.Add('An unanswered finding is an UNREVIEWED RISK, not an accepted one - if the task was unrelated to dependencies, say exactly that. This hook never upgrades anything and never blocks: the decision is the user''s.')
    $null = Write-HookResult -EventName $eventName -Kind 'advisory' -Message ($closeLines.ToArray() -join "`n")
    exit 0
}

# ---- UserPromptSubmit: new-dependency/new-feature guidance + cached findings, no fresh scan ----
if ($eventName -eq 'UserPromptSubmit') {
    $prompt = [string](Get-Field $hookInput 'prompt')
    $parts = New-Object System.Collections.Generic.List[string]
    if ($prompt -match '(?i)\b(add|introduce|adopt|install|upgrade|replace|modernize|switch to|migrate to)\b.{0,40}\b(dependency|dependencies|package|library|libraries|framework|runtime|sdk|build tool|cli|action|docker image|base image)\b' -or
        $prompt -match '(?i)\b(create|start|scaffold|bootstrap)\b.{0,20}\b(project|app|application|repo|repository)\b.{0,20}\bfrom scratch\b' -or
        $prompt -match '(?i)\b(new feature)\b') {
        [void]$parts.Add('Before selecting a version for a new/updated dependency, runtime, build tool, GitHub Action, or Docker image: check the current official documentation/release notes and choose the latest STABLE version supported by this project''s runtime and peer dependencies - not a prerelease/beta/RC/nightly/canary. Pin deterministically per this ecosystem''s convention rather than a floating tag, and update the lockfile.')
    }
    $cached = Read-CachedState
    if ($null -ne $cached -and $cached.Fingerprint -eq $fingerprint -and -not [string]::IsNullOrWhiteSpace($cached.Report)) {
        [void]$parts.Add($cached.Report)
    }
    if ($parts.Count -eq 0) { exit 0 }
    $null = Write-HookResult -EventName $eventName -Kind 'context' -Message ($parts.ToArray() -join "`n`n")
    exit 0
}

# ---- SessionStart: fingerprint/cooldown gate, then a full scan ----
$cached = Read-CachedState
if ($null -ne $cached -and $cached.Fingerprint -eq $fingerprint) {
    try {
        $checkedTime = [DateTime]::Parse($cached.CheckedIso, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([DateTime]::UtcNow - $checkedTime).TotalMinutes -lt $cooldownMinutes) {
            if ([string]::IsNullOrWhiteSpace($cached.Report)) { exit 0 }
            $null = Write-HookResult -EventName $eventName -Kind 'context' -Message ([string]$cached.Report)
            exit 0
        }
    }
    catch { }
}

# ---- version-freshness classification (semver-ish major/minor/patch compare) ----
function Get-VersionParts {
    param([string]$Version)
    $clean = $Version.TrimStart('v', 'V') -replace '[-+].*$', ''
    $segments = @($clean -split '\.' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    while ($segments.Count -lt 3) { $segments += 0 }
    return $segments
}
function Get-UpdateClassification {
    param([string]$Current, [string]$Latest)
    if ($Latest -match '(?i)(alpha|beta|rc|preview|canary|nightly|dev)') { return 'prerelease' }
    $c = Get-VersionParts $Current
    $l = Get-VersionParts $Latest
    if ($l[0] -gt $c[0]) { return 'major' }
    if ($l[1] -gt $c[1]) { return 'minor' }
    if ($l[2] -gt $c[2]) { return 'patch' }
    return 'unknown'
}

$findings = New-Object System.Collections.Generic.List[string]
$incomplete = New-Object System.Collections.Generic.List[string]

# ---- npm ----
# Invoke-QuietCommand has no working-directory parameter (it runs `& $FilePath` in the
# CURRENT process directory) - Push-Location/Pop-Location around each call, same as any
# other per-directory native-command invocation in this codebase.
if ($manifestPaths.ContainsKey('npm') -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    foreach ($dir in @($manifestPaths['npm'] | Select-Object -First 3)) {
        Push-Location -LiteralPath $dir
        try { $raw = Invoke-QuietCommand -FilePath npm -ArgumentList @('outdated', '--json') }
        finally { Pop-Location }
        # npm outdated exits 1 when outdated packages exist - that is success, not a failure.
        if ($LASTEXITCODE -gt 1) { [void]$incomplete.Add('npm at ' + (Get-RelDir $dir) + ' - `npm outdated --json` failed (exit ' + $LASTEXITCODE + ').'); continue }
        $text = ($raw -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        try {
            $obj = $text | ConvertFrom-Json
            $count = 0
            foreach ($prop in $obj.PSObject.Properties) {
                if ($count -ge $maxFindings) { break }
                $pkg = $prop.Value
                # `current` is ABSENT (not just empty) when the package has never been installed
                # (no node_modules yet) - a StrictMode direct property access would throw
                # "The property 'current' cannot be found on this object" in that case; Get-Field
                # is the established safe accessor used throughout this codebase for exactly this.
                $current = [string](Get-Field $pkg 'current')
                $latest = [string](Get-Field $pkg 'latest')
                if ($current -eq '') { $current = '(not installed)' }
                $cls = Get-UpdateClassification $current $latest
                [void]$findings.Add('npm ' + (Get-RelDir $dir) + ': ' + $prop.Name + ' ' + $current + ' -> ' + $latest + ' [' + $cls + ']')
                $count++
            }
        }
        catch { [void]$incomplete.Add('npm at ' + (Get-RelDir $dir) + ' - could not parse `npm outdated --json` output.') }
    }
}
elseif ($manifestPaths.ContainsKey('npm')) {
    [void]$incomplete.Add('npm detected but the `npm` CLI is not available - run `npm outdated` to check.')
}

# Resolve THIS PROJECT's Python interpreter. `pip` on PATH is the machine's
# global environment, whose packages are not this project's dependencies -
# reporting them is noise at best and wrong at worst (a project venv can be
# AHEAD of global, so a global read invents an "outdated" package that is
# actually newer here).
#
# Only a venv INSIDE the project counts. VIRTUAL_ENV is honoured just when it
# points into this project, so a shell that happens to have some other
# project's venv active cannot leak into this report.
function Get-ProjectPythonExecutable {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $candidates = New-Object System.Collections.ArrayList
    $active = [string]$env:VIRTUAL_ENV
    if (-not [string]::IsNullOrWhiteSpace($active)) {
        try {
            $activeFull = [System.IO.Path]::GetFullPath($active)
            $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
            # Physical containment, and on a real boundary - a sibling
            # directory sharing a name prefix is not "inside".
            if ($activeFull.StartsWith($rootFull.TrimEnd([char]92) + [char]92, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$candidates.Add($activeFull)
            }
        }
        catch { }
    }
    foreach ($name in @('.venv', 'venv', '.env', 'env')) { [void]$candidates.Add((Join-Path $ProjectRoot $name)) }
    # AN EXPLICITLY CONFIGURED SHARED BASE, last. A project may legitimately run
    # on a shared interpreter instead of owning a venv (global-environment-rules
    # .md allows a verified base with --system-site-packages), and refusing to
    # look at it made this hook silent for exactly those projects. It is honoured
    # only because the PROJECT named it in its own .env and the path verifies -
    # which is the whole difference from picking up `pip` off PATH, an
    # environment that belongs to the machine and not to this project.
    # Read defensively: this resolver is also extracted and exercised on its own
    # by the suite, where no hook config exists, and under StrictMode an absent
    # variable THROWS rather than reading as null.
    $configuredBase = ''
    $configTable = $null
    try { $configTable = $script:config } catch { $configTable = $null }
    if ($null -ne $configTable -and $configTable.ContainsKey('PYTHON_EXECUTABLE')) {
        $configuredBase = ([string]$configTable['PYTHON_EXECUTABLE']).Trim()
    }
    if ($configuredBase -ne '') {
        try {
            $configuredFull = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($configuredBase))
            if (Test-Path -LiteralPath $configuredFull -PathType Leaf) { return $configuredFull }
        }
        catch { }
    }
    foreach ($base in $candidates) {
        # .cmd/.bat are not a test convenience: pyenv-win installs shim batch
        # files and some managed layouts do the same, so a project interpreter
        # is legitimately not always a native .exe.
        foreach ($relative in @('Scripts\python.exe', 'Scripts\python.cmd', 'Scripts\python.bat', 'bin/python3', 'bin/python')) {
            $exe = Join-Path $base $relative
            try { if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe } } catch { }
        }
    }
    return $null
}
# ---- pip ----
# pip's exit code for "outdated packages found" is not documented (unlike npm/pnpm's confirmed
# exit 1) - never gate on exit code here, only on whether the output actually parses as JSON.
if ($manifestPaths.ContainsKey('pip')) {
    # PROJECT interpreter only - never the global one on PATH.
    $projectPython = Get-ProjectPythonExecutable -ProjectRoot $cwd
    $pipCmd = $projectPython
    if ($null -ne $pipCmd) {
        $raw = Invoke-QuietCommand -FilePath $pipCmd -ArgumentList @('-m', 'pip', 'list', '--outdated', '--format=json')
        $text = ($raw -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            if ($LASTEXITCODE -gt 1) { [void]$incomplete.Add('Python (pip) - `' + $pipCmd + ' list --outdated --format=json` failed (exit ' + $LASTEXITCODE + ').') }
        }
        else {
            try {
                # Inner parentheses required: on Windows PowerShell 5.1
                # `@($text | ConvertFrom-Json)` yields ONE Object[] element
                # rather than enumerating the array - at ANY length, including
                # one. Get-Field reads PSObject.Properties, which is empty on an
                # Object[], so every package is skipped as nameless and pip
                # findings are silently never reported. Direct member access like
                # $x.name still prints correctly via member enumeration, which is
                # what makes the wrapped shape look healthy.
                # `@((...))` enumerates on both hosts.
                $items = @(($text | ConvertFrom-Json))
                # THE SCOPE. An environment that inherits system site-packages
                # lists the MACHINE's packages, so an unfiltered report turns
                # every unrelated global into a project finding. Findings are
                # restricted to what this project DECLARES plus that set's
                # transitive closure; a scope that cannot be determined is
                # reported as incomplete, never widened back to everything.
                $inScope = $null
                if ($script:PythonScopeReady) {
                    $declared = Get-DeclaredPythonPackages -ProjectRoot $cwd
                    if (@($declared.Unreadable).Count -gt 0) {
                        [void]$incomplete.Add('Python (pip) - could not read the declared dependencies of: ' + (@($declared.Unreadable) -join ', ') + '; packages outside the readable set were not inspected.')
                    }
                    if (@($declared.Names).Count -gt 0) {
                        $closure = Expand-PythonDependencyClosure -PythonExecutable $pipCmd -Names @($declared.Names)
                        if ($null -eq $closure) {
                            [void]$incomplete.Add('Python (pip) - the installed metadata could not be read, so transitive dependencies were not inspected; only directly declared packages are reported.')
                            $inScope = @($declared.Names)
                        }
                        else { $inScope = @(@($declared.Names) + @($closure) | Sort-Object -Unique) }
                    }
                    elseif (@($declared.Unreadable).Count -eq 0) {
                        [void]$incomplete.Add('Python (pip) - Python manifests exist but declare no dependency this hook can parse, so the project scope is unknown and nothing was reported as outdated.')
                        $inScope = @()
                    }
                    else { $inScope = @() }
                }
                else {
                    [void]$incomplete.Add('Python (pip) - the dependency-scope module is missing from this runtime, so the report could not be restricted to this project''s own packages.')
                    $inScope = @()
                }
                $scopeIndex = @{}
                foreach ($scoped in @($inScope)) { $scopeIndex[[string]$scoped] = $true }
                $count = 0
                $outOfScope = 0
                foreach ($item in $items) {
                    if ($count -ge $maxFindings) { break }
                    $name = [string](Get-Field $item 'name')
                    $version = [string](Get-Field $item 'version')
                    $latestVersion = [string](Get-Field $item 'latest_version')
                    if ($name -eq '') { continue }
                    $normalized = ''
                    if ($script:PythonScopeReady) { $normalized = Get-NormalizedPythonName -Name $name }
                    if (-not $scopeIndex.ContainsKey($normalized)) { $outOfScope++; continue }
                    $cls = Get-UpdateClassification $version $latestVersion
                    [void]$findings.Add('pip: ' + $name + ' ' + $version + ' -> ' + $latestVersion + ' [' + $cls + ']')
                    $count++
                }
                # $outOfScope is deliberately NOT reported as incomplete: those
                # packages were inspected and consciously excluded as the
                # machine's rather than this project's, which is the opposite of
                # missing coverage. Silence about them is the correct report.
            }
            catch { [void]$incomplete.Add('Python (pip) - could not parse `pip list --outdated --format=json` output.') }
        }
    }
    else { [void]$incomplete.Add('Python (pip) - this project has Python manifests but no project environment (.venv/venv) was found, and an arbitrary interpreter on PATH is NOT this project''s dependency set. Either use the project venv, or - when this project deliberately runs on a shared base interpreter - name that interpreter in this hook''s .env as PYTHON_EXECUTABLE=<full path>; findings stay restricted to the declared dependencies either way.') }
}

# ---- Poetry / uv / pnpm / yarn / bun / .NET / Java / Rust / PHP / Ruby: detected, but not given a
# real JSON integration here - report as incomplete with the verified command instead of guessing
# at an unconfirmed JSON schema or a fragile text-table parse. Commands below were checked against
# each tool's own current documentation (not assumed from memory); several have exit-code behavior
# that would be misleading to gate on (dotnet/cargo-outdated/go/composer exit 0 even when updates
# are found, so success must never be inferred from a zero exit code alone for those). ----
$incompleteHints = [ordered]@{
    'poetry'  = 'poetry show --outdated --format=json'
    'uv'      = 'uv pip list --outdated --format json'
    'pnpm'    = 'pnpm outdated --format json (exits 1 when outdated packages are found, like npm)'
    'yarn'    = 'yarn outdated (Yarn Classic v1 only - no JSON output; Yarn Berry v2+ removed this command entirely, closest is the interactive `yarn upgrade-interactive` or the third-party plugin-outdated plugin)'
    'bun'     = 'bun outdated (no JSON output option; exit-code behavior when updates are found is undocumented)'
    'nuget'   = 'dotnet list package --outdated --format json --output-version 1 (always exits 0, even with updates found - never infer freshness from its exit code)'
    'maven'   = 'mvn versions:display-dependency-updates (requires the versions-maven-plugin)'
    'gradle'  = './gradlew dependencyUpdates (requires the versions Gradle plugin) or check each dependency manually'
    'cargo'   = 'cargo outdated --format json (requires installing the separate cargo-outdated crate first - Cargo has no built-in outdated command; exits 0 by default even with updates found unless --exit-code is passed)'
    'composer' = 'composer outdated --format=json (always exits 0 unless --strict is passed - never infer freshness from its exit code)'
    'bundler' = 'bundle outdated (no JSON output option; exits 1 when outdated gems are found)'
}
foreach ($eco in $detectedEcosystems) {
    if ($incompleteHints.Contains($eco)) {
        [void]$incomplete.Add($eco + ' detected - version freshness not automatically checked here; run `' + $incompleteHints[$eco] + '`.')
    }
}

# ---- Go (go list -u -m all is a real, built-in Go toolchain command) ----
if ($manifestPaths.ContainsKey('go') -and (Get-Command go -ErrorAction SilentlyContinue)) {
    foreach ($dir in @($manifestPaths['go'] | Select-Object -First 3)) {
        # Invoke-QuietCommand has no -WorkingDirectory parameter - Push-Location/Pop-Location
        # around the call instead, same as the npm block above.
        Push-Location -LiteralPath $dir
        try { $raw = Invoke-QuietCommand -FilePath go -ArgumentList @('list', '-u', '-m', 'all') }
        finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { [void]$incomplete.Add('Go at ' + (Get-RelDir $dir) + ' - `go list -u -m all` failed (exit ' + $LASTEXITCODE + ').'); continue }
        $count = 0
        foreach ($line in @($raw | Where-Object { $_ })) {
            if ($count -ge $maxFindings) { break }
            $m = [regex]::Match([string]$line, '^(\S+)\s+(\S+)\s+\[(\S+)\]$')
            if ($m.Success) {
                $cls = Get-UpdateClassification $m.Groups[2].Value $m.Groups[3].Value
                [void]$findings.Add('go ' + (Get-RelDir $dir) + ': ' + $m.Groups[1].Value + ' ' + $m.Groups[2].Value + ' -> ' + $m.Groups[3].Value + ' [' + $cls + ']')
                $count++
            }
        }
    }
}
elseif ($manifestPaths.ContainsKey('go')) {
    [void]$incomplete.Add('go.mod detected but the `go` CLI is not available - run `go list -u -m all` to check.')
}

# ---- GitHub Actions: static known-minimum-major check ----
foreach ($wf in $workflowFiles) {
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($wf.FullName) } catch { continue }
    foreach ($m in [regex]::Matches($text, '(?im)^\s*-?\s*uses\s*:\s*["'']?([^\s"''#@]+)@v?(\d+)')) {
        $action = $m.Groups[1].Value
        $major = 0
        if (-not [int]::TryParse($m.Groups[2].Value, [ref]$major)) { continue }
        if ($script:ActionMinimumMajor.ContainsKey($action) -and $major -lt $script:ActionMinimumMajor[$action]) {
            [void]$findings.Add('github-actions ' + $wf.Name + ': ' + $action + '@v' + $major + ' is a clearly old major version (verify the current latest) [major]')
        }
    }
}

# ---- runtime pins ----
foreach ($nvmFile in @('.nvmrc', '.node-version')) {
    $p = Join-Path $cwd $nvmFile
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $ver = ([System.IO.File]::ReadAllText($p)).Trim().TrimStart('v')
        $majorNum = 0
        if ([int]::TryParse(($ver -split '\.')[0], [ref]$majorNum) -and $script:NodeEolMajors -contains $majorNum) {
            [void]$findings.Add('runtime pin ' + $nvmFile + ': Node ' + $ver + ' is a known end-of-life major version [EOL]')
        }
    }
}
if ($manifestPaths.ContainsKey('npm')) {
    foreach ($dir in @($manifestPaths['npm'])) {
        $pkgPath = Join-Path $dir 'package.json'
        if (-not (Test-Path -LiteralPath $pkgPath -PathType Leaf)) { continue }
        try {
            $pkg = [System.IO.File]::ReadAllText($pkgPath) | ConvertFrom-Json
            # Get-Field (not direct property access) - StrictMode throws on a JSON object that
            # simply omits the "engines" key or "engines.node" sub-key, which is the common case.
            $engineNode = $null
            $engines = Get-Field $pkg 'engines'
            if ($null -ne $engines) {
                $engineNodeRaw = Get-Field $engines 'node'
                if ($null -ne $engineNodeRaw) { $engineNode = [string]$engineNodeRaw }
            }
            if ($null -ne $engineNode) {
                $m2 = [regex]::Match($engineNode, '(\d+)')
                if ($m2.Success) {
                    $en = [int]$m2.Groups[1].Value
                    if ($script:NodeEolMajors -contains $en) {
                        [void]$findings.Add('runtime pin ' + (Get-RelDir $dir) + '/package.json engines.node: ' + $engineNode + ' allows a known end-of-life Node major [EOL]')
                    }
                }
            }
        }
        catch { }
    }
}
foreach ($pyFile in @('.python-version', 'runtime.txt')) {
    $p = Join-Path $cwd $pyFile
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $ver = ([System.IO.File]::ReadAllText($p)).Trim()
        $m3 = [regex]::Match($ver, '(\d+\.\d+)')
        if ($m3.Success -and $script:PythonEolVersions -contains $m3.Groups[1].Value) {
            [void]$findings.Add('runtime pin ' + $pyFile + ': Python ' + $m3.Groups[1].Value + ' is a known end-of-life version [EOL]')
        }
    }
}

# ---- Docker base images ----
foreach ($df in $dockerfiles) {
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($df) } catch { continue }
    $relPath = $df.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
    foreach ($m in [regex]::Matches($text, '(?im)^\s*FROM\s+([^\s]+)')) {
        $image = $m.Groups[1].Value
        if ($image -match '(?i)^scratch$' -or $image -match '(?i)\bas\b') { continue }
        if ($image -match ':latest$' -or $image -notmatch ':') {
            [void]$findings.Add('docker ' + $relPath + ': ' + $image + ' uses a floating/untagged (effectively :latest) base image - not reproducible [unknown]')
            continue
        }
        foreach ($eol in $script:DockerEolBaseImages) {
            if ($image -eq $eol -or $image.StartsWith($eol + '-')) {
                [void]$findings.Add('docker ' + $relPath + ': ' + $image + ' is a known end-of-life base image tag [EOL]')
                break
            }
        }
    }
}

# ---- build the report ----
$reportLines = New-Object System.Collections.Generic.List[string]
if ($findings.Count -gt 0) {
    $capped = @($findings | Select-Object -First $maxFindings)
    [void]$reportLines.Add('DEPENDENCY VERSION CHECK (' + $cwd + '):')
    foreach ($f in $capped) { [void]$reportLines.Add('- ' + $f) }
    if ($findings.Count -gt $capped.Count) { [void]$reportLines.Add('- (' + ($findings.Count - $capped.Count) + ' more finding(s) not shown - MAX_FINDINGS=' + $maxFindings + ')') }
}
if ($incomplete.Count -gt 0) {
    if ($reportLines.Count -eq 0) { [void]$reportLines.Add('DEPENDENCY VERSION CHECK (' + $cwd + '):') }
    # Deliberately avoids the phrase this project's own guard greps for as a
    # currency claim: the line must forbid such a claim, not contain one.
    [void]$reportLines.Add('Incomplete checks - these are UNKNOWN, and UNKNOWN is not the same as fine. Do not describe this project as fully checked while any of these stand:')
    foreach ($i in @($incomplete | Sort-Object -Unique)) { [void]$reportLines.Add('- ' + $i) }
}
# The response contract. The scan above is evidence; these lines say what must be DONE with it,
# because a report with no stated obligation is the one that gets skimmed and dropped.
if ($reportLines.Count -gt 0) {
    [void]$reportLines.Add('WHAT TO DO WITH THIS - every finding above needs a DECISION, not agreement:')
    [void]$reportLines.Add('1. Verify before changing anything: release notes/changelog, breaking changes, runtime and peer constraints, security advisories. Prefer the latest STABLE compatible version - never a prerelease/beta/RC/nightly/canary by default.')
    [void]$reportLines.Add('2. Decide per finding: update (then update the lockfile and run the project''s real checks), keep (the current version is correct here), or defer (name what blocks it). "Keep" and "defer" are legitimate answers; silence is not.')
    [void]$reportLines.Add('3. Update in small verified batches with validation after each - never one large uncontrolled bump, and never a major version without a breaking-change review.')
    [void]$reportLines.Add('4. An [EOL] entry or a clearly old major needs an explicit stated reason to leave in place.')
    [void]$reportLines.Add('5. Report the outcome in the final summary on its own line: ' + $script:DependencyDecisionLine)
    [void]$reportLines.Add('This hook never edits a manifest, never runs an upgrade and never blocks completion - whether to upgrade is the user''s call. What it does require is that the call be made and stated rather than left unread.')
}
$report = $reportLines.ToArray() -join "`n"
Save-CachedState -Report $report

if ($reportLines.Count -eq 0) { exit 0 }
$null = Write-HookResult -EventName $eventName -Kind 'context' -Message $report
exit 0
