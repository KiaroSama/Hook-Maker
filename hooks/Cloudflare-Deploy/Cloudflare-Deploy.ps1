# CloudflareDeploy - after a task ends (Stop), reminds the agent to work
# through BOTH a deployment-worthiness decision and post-deployment
# verification. The AI decides; nothing is deployed or verified automatically
# by this script - it never deploys merely because a wrangler config exists.
#
# The decision is gated on actual RELEASE READINESS (deterministic repo/CI/
# cleanup state), never on menu position or hook registration order - Stop
# hooks for the same event may run concurrently, so this hook never assumes
# it runs "after" Git-Sync-Check, Ci-Status-Check, or Test-Temp-Cleanup. It
# stays completely silent (no reminder at all this Stop) when the working
# tree is dirty, the branch is ahead/unpushed, the exact release commit isn't
# known to be pushed, CI exists but is not verified green for that exact SHA,
# or Test-Temp-Cleanup (when installed for this project) has not reported a
# fresh `clean` result for the CURRENT repo state. If Test-Temp-Cleanup races
# on the same Stop and hasn't recorded yet, this hook simply stays silent and
# re-evaluates on the next Stop - it never loops or retries within one
# invocation.
#
# Token-efficient by design:
# - Fires only in projects with a wrangler config (wrangler.toml/.json/.jsonc)
#   AND only when release-readiness actually holds.
# - Respects stop_hook_active (never loops) and a per-project cooldown.
#
# Optional .env next to this script (copy .env.example):
#   DEPLOY_COMMAND    the deploy command to suggest (default: npx wrangler deploy)
#   COOLDOWN_MINUTES  minimum minutes between reminders per project (default 30)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}
# Only used to shape the result (Write-HookResult below). This is a Stop-only
# hook, so an absent event name reads as 'Stop' rather than as "no event".
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

# Only Cloudflare Workers projects.
$wranglerConfig = $null
foreach ($candidate in @('wrangler.toml', 'wrangler.jsonc', 'wrangler.json')) {
    $path = Join-Path $cwd $candidate
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $wranglerConfig = $candidate
        break
    }
}
if ($null -eq $wranglerConfig) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 30
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$deployCommand = 'npx wrangler deploy'
if ($config.ContainsKey('DEPLOY_COMMAND') -and $config['DEPLOY_COMMAND'] -ne '') {
    $deployCommand = $config['DEPLOY_COMMAND']
}

# ---- SHARED RESULT-CATEGORY CONTRACT -------------------------------------
# The complete vocabulary of the { fingerprint, category } handoff written to
# TestTempCleanup-result-<projectKey>.json.
# THE OTHER SIDE OF THIS CONTRACT IS hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1
# ($script:ResultCategories). Keep both lists identical, in the same commit - a
# past round shipped a dead gate because two components drifted on exactly this
# kind of shared state contract.
$script:CleanupCategories = @('clean', 'review-required', 'residue-confirmed', 'partial', 'unknown')
# Only a fully clean, complete scan is release-ready. `review-required`,
# `residue-confirmed`, `partial` and `unknown` each mean the workspace state is
# unresolved or unproven, so none of them may show a deployment decision. An
# unrecognized value (an older or newer producer) is treated the same way.
$script:CleanupReleaseReadyCategories = @('clean')

# (The former mirrored client runtime-root list lived here. Install evidence
# is REGISTRATION documents now - see Test-CleanupRegistrationEvidence below -
# because a runtime directory listing proved nothing: an orphaned folder
# satisfied it while nothing there could ever run.)

# The single definition of WHERE Test-Temp-Cleanup's coordination record lives,
# so "does a record exist at all" (install evidence) and "what does it currently
# say" (the gate itself) can never disagree about which file they mean.
#
# Normalize-Path is load-bearing, not decoration: the PRODUCER hashes
# Normalize-Path($cwd).ToLowerInvariant() (Test-Temp-Cleanup.ps1's $projectRoot),
# and ToLowerInvariant alone folds case only. A cwd carrying a trailing
# separator or a '.'/'..' segment therefore hashed to a key the producer never
# writes, so the record read as ABSENT: the gate concluded "cleanup not
# installed", skipped the cleanliness half of release readiness entirely, and
# showed a deploy decision for a workspace whose cleanliness was never proven -
# exactly the failure direction Test-CleanupInstalled below calls the worse one.
# Both sides must canonicalize with the same helper or the shared-state contract
# is only nominally shared.
function Get-CleanupResultPath {
    param([string]$Root)
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('TestTempCleanup-result-' + (Get-ShortHash (Normalize-Path $Root).ToLowerInvariant()) + '.json'))
}

# Where each client RECORDS its hook registrations, relative to a scope base
# (the project root, or the user profile for a global install). Mirrored from
# scripts\_clientcapability.ps1 for the same structural reason the runtime
# roots above are: an installed runtime is self-contained and cannot dot-source
# the capability table. Test-CloudflareDeploy.ps1 asserts this mirror equals the
# table's projectRegistration/globalRegistration values, which is what keeps the
# duplication honest instead of rotting into a stale hardcoded list.
$script:ClientRegistrationRelativeFiles = @(
    '.claude\settings.local.json',
    '.claude\settings.json',
    '.codex\hooks.json'
)
$script:KiroRegistrationRelativeDir = '.kiro\hooks'

# Does this scope base carry an ACTUAL Test-Temp-Cleanup registration - a hook
# entry a client will really fire? A name-drop is NOT enough: any document
# merely CONTAINING the substring 'Test-Temp-Cleanup' used to count, so a
# foreign .kiro\hooks\*.json mentioning the name satisfied this with no
# command and no runtime behind it - and because nothing there would ever
# write a coordination record, the gate then waited forever for a fresh
# 'clean' and the deployment reminder was permanently dead in that project.
#
# Evidence now means a COMMAND whose quoted -File target lives in this hook's
# own runtime directory (...\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1 for
# Claude/Codex, ...\Test-Temp-Cleanup\kiro-launch.ps1 for Kiro - the DIRECTORY
# segment is the identity, never the script name) AND whose target script
# still EXISTS on disk. Command shape + live runtime is the strongest evidence
# available in-process: the install REGISTRY (tool-root state\
# install-registry.json) is structurally unreachable from an installed runtime
# - runtimes are self-contained and do not know the tool root - so a
# registry/manifest cross-check is impossible here and must not be faked.
#
# Failure direction (unchanged, deliberate): a document that cannot be READ,
# or that names the hook but will not PARSE, still counts as installed -
# refusing to read is not proof of absence, and the conservative side here is
# "installed" (worst case: a missed reminder). Only a document that parses
# CLEANLY and still lacks a live command is PROVEN to be a name-drop, and only
# that case stopped counting.
function Test-CleanupRegistrationEvidence {
    param([string]$Base)
    if ([string]::IsNullOrWhiteSpace($Base)) { return $false }
    foreach ($relativeFile in $script:ClientRegistrationRelativeFiles) {
        $settingsPath = Join-Path $Base $relativeFile
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try { $settingsText = [System.IO.File]::ReadAllText($settingsPath) }
            catch { return $true }
            if (Test-RegistrationDocumentEvidence -Text $settingsText -Base $Base) { return $true }
        }
    }
    $kiroDir = Join-Path $Base $script:KiroRegistrationRelativeDir
    if (Test-Path -LiteralPath $kiroDir -PathType Container) {
        try { $kiroFiles = @(Get-ChildItem -LiteralPath $kiroDir -Filter '*.json' -File -ErrorAction Stop) }
        catch { return $true }
        foreach ($kiroFile in $kiroFiles) {
            try { $kiroText = [System.IO.File]::ReadAllText($kiroFile.FullName) }
            catch { return $true }
            if (Test-RegistrationDocumentEvidence -Text $kiroText -Base $Base) { return $true }
        }
    }
    return $false
}

# One registration document's verdict. Cheap substring first (no parse when
# the name never appears), then the parse/command/existence ladder described
# above Test-CleanupRegistrationEvidence.
function Test-RegistrationDocumentEvidence {
    param([string]$Text, [string]$Base)
    if ($Text -notmatch 'Test-Temp-Cleanup') { return $false }
    $document = $null
    # Inner parentheses are load-bearing on Windows PowerShell 5.1 - same
    # array-collection defect as the gh run-list decode below.
    try { $document = (($Text | ConvertFrom-Json)) }
    catch { return $true }
    return (Test-CleanupCommandEvidence -Document $document -Base $Base)
}

# Every string leaf of a parsed registration document. Walking ALL strings
# rather than named fields is deliberate: the three clients spell the command
# key differently (command / commandWindows / command_windows / Kiro's own
# schema), and recognizing a command by its SHAPE plus a live target instead
# of its key name covers all of them. The false-positive this admits - a
# non-command field carrying '-File "...\Test-Temp-Cleanup\..."' whose target
# really exists on disk - is materially a live install anyway, and it errs on
# the conservative (missed-reminder) side.
function Get-RegistrationStringValues {
    param($Node)
    if ($null -eq $Node) { return @() }
    if ($Node -is [string]) { return @(, $Node) }
    $collected = @()
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { $collected += @(Get-RegistrationStringValues $item) }
        return $collected
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Node.PSObject.Properties) { $collected += @(Get-RegistrationStringValues $property.Value) }
    }
    return $collected
}

# Does any string in the parsed document carry a quoted -File target inside
# this hook's runtime directory that still exists on disk? JSON parsing has
# already unescaped \\ to \ by the time these strings are inspected. A
# non-rooted target resolves against the scope base, the way a client
# resolves a relative command against the project.
function Test-CleanupCommandEvidence {
    param($Document, [string]$Base)
    foreach ($value in @(Get-RegistrationStringValues $Document)) {
        foreach ($match in [regex]::Matches($value, '-File\s+"([^"]+)"', 'IgnoreCase')) {
            $scriptPath = $match.Groups[1].Value
            if ($scriptPath -notmatch '[\\/]Test-Temp-Cleanup[\\/]') { continue }
            # try/catch because IsPathRooted/Join-Path THROW on illegal path
            # characters under .NET Framework (5.1); a path malformed enough
            # to throw cannot exist on disk, so "no evidence from this match"
            # is the faithful verdict, not a swallowed error.
            try {
                if (-not [System.IO.Path]::IsPathRooted($scriptPath)) { $scriptPath = Join-Path $Base $scriptPath }
                if (Test-Path -LiteralPath $scriptPath -PathType Leaf) { return $true }
            }
            catch { }
        }
    }
    return $false
}

# Is Test-Temp-Cleanup actually INSTALLED for this project? The two accepted
# signals:
#
#   1. A registration a client will really fire - project scope or user scope,
#      proven by a command targeting the hook's runtime directory whose script
#      still exists (see Test-CleanupRegistrationEvidence). This is what
#      "installed" MEANS; a directory listing never was, and a name-drop is
#      not either. An orphaned <runtimeRoot>\Test-Temp-Cleanup folder, or a
#      state file surviving from a manually-deleted install, used to satisfy
#      this check while nothing there could ever run again - and because the
#      gate then waited forever for a fresh 'clean' nothing would write, the
#      deployment reminder was permanently dead in that project.
#   2. A coordination record whose fingerprint matches the CURRENT repo state.
#      Only the hook itself writes one, and a fingerprint-current record means
#      the hook genuinely EXECUTED against this exact repo state - stronger
#      evidence than any registration text can be, which is why it stands
#      unchanged beside the command check: it covers an install registered
#      somewhere the mirrored registration list does not know about.
#
# A stale record (fingerprint mismatch) and a bare runtime directory prove
# nothing anymore: the uninstaller retires the record and deletes the runtime
# directory on the same success path, so what such residue actually evidences
# is an install that is GONE.
#
# NO signal here can SATISFY the cleanliness gate - only a FRESH 'clean'
# category does that. This decides only whether the gate APPLIES. Unreadable
# registration documents count as installed, the conservative side: a false
# "installed" costs at most a missed reminder, while a false "not installed"
# skips the cleanliness half of release readiness and shows a deploy decision
# this hook cannot support.
function Test-CleanupInstalled {
    param([string]$Root)
    if (Test-CleanupRegistrationEvidence -Base $Root) { return $true }
    if (Test-CleanupRegistrationEvidence -Base ([string]$env:USERPROFILE)) { return $true }
    if ($null -ne (Get-CleanupCoordinationState -Root $Root)) { return $true }
    return $false
}

# Reads Test-Temp-Cleanup's coordination state, only trusting it when its
# recorded repo-state fingerprint still matches the CURRENT state (never a
# stale/racing read from an earlier Stop).
function Get-CleanupCoordinationState {
    param([string]$Root)
    $record = Read-JsonFile -Path (Get-CleanupResultPath -Root $Root)
    if ($null -eq $record) { return $null }
    $recordedFingerprint = [string](Get-Field $record 'fingerprint')
    if ([string]::IsNullOrWhiteSpace($recordedFingerprint)) { return $null }
    if ($recordedFingerprint -ne (Get-RepoStateFingerprint -ProjectRoot $Root)) { return $null }
    return [string](Get-Field $record 'category')
}

# Deterministic release-readiness gate: only when this holds does the
# deployment-worthiness decision get shown at all.
function Test-ReleaseReady {
    param([string]$Root)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $false }

    # 1) no uncommitted task changes.
    $status = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'status', '--porcelain')) | Where-Object { $_ })
    if ($status.Count -gt 0) { return $false }

    $headSha = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headSha)) { return $false }

    # 2) the release commit must be known to be pushed - ANY configured
    # upstream (Cloudflare Workers projects need not be hosted on GitHub at
    # all); Get-GitHubRepository is reserved for the GitHub-specific CI query
    # below, not for this generic pushed/ahead check.
    $upstreamRef = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--abbrev-ref', '@{upstream}'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamRef)) { return $false }
    $aheadRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-list', '--count', ($upstreamRef + '..HEAD')))
    if ($LASTEXITCODE -ne 0) { return $false }
    $ahead = -1
    if (-not [int]::TryParse($aheadRaw, [ref]$ahead) -or $ahead -ne 0) { return $false }

    # 3) if this repo uses CI, the exact HEAD sha must be verified green.
    $workflowsDir = Join-Path $Root '.github\workflows'
    $usesCi = (Test-Path -LiteralPath $workflowsDir -PathType Container) -and
        (@(Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yml' -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yaml' -ErrorAction SilentlyContinue)).Count -gt 0
    if ($usesCi) {
        $repoInfo = Get-GitHubRepository -ProjectRoot $Root
        if ($null -eq $repoInfo) { return $false }
        if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
        $runsJson = [string](Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--repo', $repoInfo.Repository, '--commit', $headSha, '--json', 'status,conclusion', '--limit', '20'))
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($runsJson)) { return $false }
        $runs = $null
        # The INNER parentheses are load-bearing on Windows PowerShell 5.1.
        # `@($json | ConvertFrom-Json)` there collects the decoded array as ONE
        # element of type Object[] instead of enumerating it - at ANY array
        # length, including one. Get-Field reads $Object.PSObject.Properties,
        # which is empty on an Object[], so every field read returns $null, no
        # run ever looks 'completed'/'success', and this gate can never pass.
        #
        # What hides it: `$wrapped[0].status` DOES print the right value,
        # because PowerShell member-enumerates over the array. Only a real
        # property lookup exposes it, so the shape looks fine under casual
        # inspection and the failure is silent (never a wrong deploy prompt).
        #
        # `@((...))` enumerates identically on both hosts; same form as
        # Ci-Status-Check.ps1's annotation decode.
        try { $runs = @(($runsJson | ConvertFrom-Json)) } catch { return $false }
        if ($runs.Count -eq 0) { return $false }
        foreach ($run in $runs) {
            if ([string](Get-Field $run 'status') -ne 'completed' -or [string](Get-Field $run 'conclusion') -ne 'success') { return $false }
        }
    }

    # 4) Test-Temp-Cleanup coordination, only enforced when it is installed for
    # this project - and "installed" is proven by a registration command with a
    # live runtime script, or by a fingerprint-current coordination record
    # (see Test-CleanupInstalled).
    if (Test-CleanupInstalled -Root $Root) {
        $cleanupCategory = Get-CleanupCoordinationState -Root $Root
        # Missing/stale ($null), a non-ready category, and an unrecognized
        # category all keep this hook silent until a later Stop.
        if ($script:CleanupCategories -notcontains $cleanupCategory) { return $false }
        if ($script:CleanupReleaseReadyCategories -notcontains $cleanupCategory) { return $false }
    }

    return $true
}

# ---- cooldown (per project) ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('CloudflareDeploy-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$lastFire = [DateTime]::MinValue
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $lastFire = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([DateTime]::UtcNow - $lastFire).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# Only show the decision when the repository and release state are actually
# ready - never based on hook registration order (see header).
if (-not (Test-ReleaseReady $cwd)) {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reasonLines = New-Object System.Collections.Generic.List[string]
[void]$reasonLines.Add('CLOUDFLARE DEPLOY CHECK: this project deploys to Cloudflare Workers (' + $wranglerConfig + ' found). Deployment is NOT automatic just because this config exists - work through both steps below.')
[void]$reasonLines.Add('1) Deployment-worthiness: deploy ONLY if the task is complete (not partial/experimental/local-only diagnostic), relevant tests/typecheck/lint/build pass, the exact release commit is known, CI for that commit is green if this repo uses CI (or an explicit documented policy allows otherwise), no secrets/local-only/debug files, unrelated changes, or disposable test cache/temp residue are included, the target environment and any required bindings/migrations are understood, and project/user rules permit it. If any of that is not true - or the change is documentation-only, an experiment, or the release commit is not known - finish now WITHOUT deploying and briefly state why.')
[void]$reasonLines.Add('2) Environment: explicitly decide production / staging / preview-development / a named Wrangler environment before deploying - never silently default to production - and use the matching Wrangler config/command for it.')
[void]$reasonLines.Add('3) Cloudflare-specific pre-deploy review, only where relevant to this diff: Worker name and account/environment selection, environment-specific variables, bindings, D1 databases and migrations, KV namespaces, R2 buckets, Queues, Durable Objects and migrations, service bindings, routes/custom domains, cron triggers, compatibility date/flags, deployment CLI/version compatibility, and build output. Never print secret values.')
[void]$reasonLines.Add('4) If deployment is warranted, run: ' + $deployCommand)
[void]$reasonLines.Add('5) Post-deployment verification is REQUIRED - do not claim deployment succeeded solely because the command exited 0. Record the target environment, deployed Worker/project, exact source commit SHA, the deploy command used (excluding secrets), and the deployment/version identifier or URL. Then perform the smallest appropriate check: smoke-test the public/staging URL, call a health endpoint, verify the changed feature, inspect recent Cloudflare deployment output/logs, verify routes/bindings, or confirm migrations completed. If verification cannot be performed, state that limitation accurately instead of assuming success.')
[void]$reasonLines.Add('6) On failure: do not repeatedly redeploy blindly - inspect the actual failure, fix only confirmed deployment/configuration issues, rerun relevant local validation, retry only when safe, never hide a failed deployment, and never claim the task is live if it is not. This reminder respects a cooldown.')
$reason = $reasonLines.ToArray() -join "`n"
exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason).ExitCode
