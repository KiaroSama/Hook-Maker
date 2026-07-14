# DependabotCheck - at the start of work in a GitHub repository, reports
# pending Dependabot pull requests so they are reviewed BEFORE unrelated
# implementation, per the user's dependency rules. Detection only: this hook
# never merges, approves, or modifies anything.
#
# Verification: PRs are queried and then filtered by the verified
# app/dependabot author; each is reported with its exact head SHA, base
# branch, merge state, and check rollup. A branch is never trusted merely
# because its name contains "dependabot".
#
# Silent when: not a git repo, no GitHub remote, no pending Dependabot PRs,
# or the same state was already reported within the cooldown. When gh is
# missing/unauthenticated or the query fails, it reports that limitation
# (once per cooldown) instead of claiming there is nothing to review.
#
# Optional .env next to this script (copy .env.example):
#   COOLDOWN_MINUTES  minimum minutes between identical reports per repo (default 120)
#   PR_LIMIT          maximum PRs detailed in the context note (default 5)

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
# Context injection only makes sense for context events.
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
$repoSlug = ''
foreach ($remoteName in @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'remote'))) {
    if ([string]::IsNullOrWhiteSpace([string]$remoteName)) { continue }
    $url = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $cwd, 'remote', 'get-url', $remoteName))
    if ($LASTEXITCODE -ne 0) { continue }
    if ($url -match 'github\.com[:/]([^/]+)/([^/\s]+?)(\.git)?/?$') {
        $repoSlug = $Matches[1] + '/' + $Matches[2]
        break
    }
}
if ($repoSlug -eq '') {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 120
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$prLimit = 5
if ($config.ContainsKey('PR_LIMIT')) {
    try { $prLimit = [int]$config['PR_LIMIT'] } catch { }
}

# ---- state (fingerprint + timestamp) so unchanged findings are not repeated ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('DependabotCheck-' + (Get-ShortHash ($cwd.ToLowerInvariant() + '|' + $repoSlug.ToLowerInvariant())) + '.txt')
$lastFingerprint = ''
$lastTime = [DateTime]::MinValue
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $stateLines = [System.IO.File]::ReadAllLines($statePath)
        if ($stateLines.Count -ge 2) {
            $lastFingerprint = $stateLines[0].Trim()
            $lastTime = [DateTime]::Parse($stateLines[1].Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
    }
    catch { }
}

function Write-ContextIfNew {
    param([Parameter(Mandatory = $true)][string]$Fingerprint, [Parameter(Mandatory = $true)][string]$Message)

    if ($Fingerprint -eq $script:lastFingerprint -and ([DateTime]::UtcNow - $script:lastTime).TotalMinutes -lt $script:cooldownMinutes) {
        exit 0
    }
    New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null
    [System.IO.File]::WriteAllLines($script:statePath, @($Fingerprint, [DateTime]::UtcNow.ToString('o')))
    @{ hookSpecificOutput = @{ hookEventName = $script:eventName; additionalContext = $Message } } |
        ConvertTo-Json -Depth 5 -Compress
    exit 0
}

# ---- gh availability ----
$limitReason = ''
if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
    $limitReason = 'the GitHub CLI (gh) is not installed'
}
else {
    $null = Invoke-QuietCommand -FilePath gh -ArgumentList @('auth', 'status')
    if ($LASTEXITCODE -ne 0) {
        $limitReason = 'gh is not authenticated (gh auth login)'
    }
}

$prs = @()
if ($limitReason -eq '') {
    $rawJson = Invoke-QuietCommand -FilePath gh -ArgumentList @('pr', 'list', '--author', 'app/dependabot', '--state', 'open', '--json', 'number,title,author,headRefName,baseRefName,headRefOid,isDraft,mergeStateStatus,labels,statusCheckRollup', '--limit', '30')
    if ($LASTEXITCODE -ne 0) {
        $limitReason = 'gh could not query pull requests (network or repository permissions)'
    }
    else {
        $parsed = $null
        try { $parsed = (@($rawJson) -join "`n") | ConvertFrom-Json } catch { $parsed = $null }
        foreach ($pr in @($parsed)) {
            if ($null -eq $pr) { continue }
            # Author verification: only the verified dependabot app counts.
            # Branch names are NEVER trusted.
            $login = ''
            $author = Get-Field $pr 'author'
            if ($null -ne $author) { $login = [string](Get-Field $author 'login') }
            if ($login -ne 'app/dependabot' -and $login -ne 'dependabot' -and $login -ne 'dependabot[bot]') { continue }
            $prs += $pr
        }
    }
}

if ($limitReason -ne '') {
    Write-ContextIfNew -Fingerprint ('limited:' + $limitReason) -Message ('DEPENDABOT CHECK (' + $repoSlug + '): pending Dependabot work could NOT be verified because ' + $limitReason + '. Do not claim dependency updates were checked; state this limitation if it is relevant to the task.')
}

if ($prs.Count -eq 0) {
    # Nothing pending: stay silent (and clear stale state so a future PR reports immediately).
    if ($lastFingerprint -ne '') {
        try { [System.IO.File]::Delete($statePath) } catch { }
    }
    exit 0
}

# ---- classify and summarize ----
function Get-UpdateKind {
    param($Pr)
    $title = [string](Get-Field $Pr 'title')
    $labelNames = @()
    foreach ($l in @(Get-Field $Pr 'labels')) {
        if ($null -ne $l) {
            $n = [string](Get-Field $l 'name')
            if ($n -ne '') { $labelNames += $n.ToLowerInvariant() }
        }
    }
    if ($labelNames -contains 'security' -or $title -match '(?i)security') { return 'SECURITY' }
    if ($title -match '(?i)\bthe\s+\S+.*\bgroup\b') { return 'grouped' }
    if ($title -match 'from\s+([0-9][\w.+-]*)\s+to\s+([0-9][\w.+-]*)') {
        $fromVersion = $Matches[1]
        $toVersion = $Matches[2]
        if ($toVersion -match '-') { return 'PRERELEASE' }
        $fromParts = $fromVersion -split '\.'
        $toParts = $toVersion -split '\.'
        if ($fromParts[0] -ne $toParts[0]) { return 'MAJOR' }
        $fromMinor = ''
        $toMinor = ''
        if ($fromParts.Count -ge 2) { $fromMinor = $fromParts[1] }
        if ($toParts.Count -ge 2) { $toMinor = $toParts[1] }
        if ($fromMinor -ne $toMinor) { return 'minor' }
        return 'patch'
    }
    return 'update'
}

function Get-CheckSummary {
    param($Pr)
    $pass = 0; $fail = 0; $pending = 0
    foreach ($check in @(Get-Field $Pr 'statusCheckRollup')) {
        if ($null -eq $check) { continue }
        $status = ([string](Get-Field $check 'status')).ToUpperInvariant()
        $conclusion = ([string](Get-Field $check 'conclusion')).ToUpperInvariant()
        if ($status -ne '' -and $status -ne 'COMPLETED') { $pending++ }
        elseif ($conclusion -in @('SUCCESS', 'NEUTRAL', 'SKIPPED')) { $pass++ }
        elseif ($conclusion -in @('FAILURE', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE', 'STALE', 'ACTION_REQUIRED')) { $fail++ }
        else { $pending++ }
    }
    if (($pass + $fail + $pending) -eq 0) { return 'no checks reported' }
    $parts = @()
    if ($pass -gt 0) { $parts += ($pass.ToString() + ' pass') }
    if ($fail -gt 0) { $parts += ($fail.ToString() + ' FAILED') }
    if ($pending -gt 0) { $parts += ($pending.ToString() + ' pending') }
    return ($parts -join ', ')
}

$fingerprintParts = @()
$prLines = @()
foreach ($pr in ($prs | Sort-Object { [int](Get-Field $_ 'number') })) {
    $number = [string](Get-Field $pr 'number')
    $sha = [string](Get-Field $pr 'headRefOid')
    $sha7 = $sha
    if ($sha7.Length -gt 7) { $sha7 = $sha7.Substring(0, 7) }
    $mergeState = ([string](Get-Field $pr 'mergeStateStatus')).ToUpperInvariant()
    $stateNote = switch ($mergeState) {
        'DIRTY' { 'MERGE CONFLICT' }
        'BEHIND' { 'behind base' }
        'BLOCKED' { 'blocked' }
        'CLEAN' { 'clean' }
        default { if ($mergeState -eq '') { 'state unknown' } else { $mergeState.ToLowerInvariant() } }
    }
    $checkSummary = Get-CheckSummary $pr
    $fingerprintParts += ($number + ':' + $sha + ':' + $mergeState + ':' + $checkSummary)

    if ($prLines.Count -lt $prLimit) {
        $title = [string](Get-Field $pr 'title')
        if ($title.Length -gt 70) { $title = $title.Substring(0, 67) + '...' }
        $draftTag = ''
        if ((Get-Field $pr 'isDraft') -eq $true) { $draftTag = '[draft] ' }
        $kind = Get-UpdateKind $pr
        $prLines += ('- #' + $number + ' ' + $draftTag + $title + ' [' + $kind + '; checks: ' + $checkSummary + '; ' + $stateNote + '] base ' + [string](Get-Field $pr 'baseRefName') + ', head sha ' + $sha7)
    }
}
$moreNote = ''
if ($prs.Count -gt $prLines.Count) {
    $moreNote = "`n- ... and " + ($prs.Count - $prLines.Count) + ' more'
}

$message = 'DEPENDABOT CHECK (' + $repoSlug + '): ' + $prs.Count + ' pending Dependabot PR(s) from the verified app/dependabot author:' + "`n" +
    (($prLines -join "`n") + $moreNote) + "`n" +
    'Review these BEFORE unrelated work, per the dependency rules: verify the exact head SHA, the actual diff, manifests and lockfiles, release notes and breaking changes, runtime compatibility, permissions, and supply-chain risk, plus the required checks for that exact commit. Merge only what the rules allow: security and patch first after full validation; minor only when low-risk and validated; never auto-merge MAJOR or PRERELEASE. After any merge, verify the resulting default-branch commit and its checks before continuing.'

Write-ContextIfNew -Fingerprint (($fingerprintParts | Sort-Object) -join '|') -Message $message
