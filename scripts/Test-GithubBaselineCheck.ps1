# Offline smoke test for the Github-Baseline-Check hook: missing CI/Dependabot
# baseline detection, monorepo/package-ecosystem discovery, and workflow-
# trigger/validation parsing false-positive/negative regressions.
#
# Fully offline and account-free: git state is built in throwaway local repos
# (remote-tracking refs are simulated with git update-ref - no fetch/push), and
# the GitHub CLI is replaced by a PATH shim (gh.ps1) that serves
# canned JSON from $env:GH_MOCK_DIR. Payloads are delivered through a real
# stdin file handle (see Test-Engine.ps1 for why pipes are not used).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-GithubBaselineCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$BaselineHook = Join-Path $HooksRoot 'Github-Baseline-Check\Github-Baseline-Check.ps1'
if (-not (Test-Path -LiteralPath $BaselineHook -PathType Leaf)) {
    Write-Host "Hook not found: $BaselineHook" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 200
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-baselinetest'
$OriginalLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $Work 'localappdata'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# ---- gh shim: intercepts every `gh` call in child processes ----
$ShimDir = Join-Path $Work 'ghshim'
$MockDir = Join-Path $Work 'ghmock'
New-Item -ItemType Directory -Path $ShimDir, $MockDir -Force | Out-Null
$ghMock = @'
$mockDir = $env:GH_MOCK_DIR
if (-not $mockDir) { exit 1 }
$a = @($args)
Add-Content -LiteralPath (Join-Path $mockDir 'calls.txt') -Value ($a -join '|')
if ($a.Count -ge 2 -and $a[0] -eq 'auth' -and $a[1] -eq 'status') {
    $f = Join-Path $mockDir 'auth_exit.txt'
    $code = 0
    if (Test-Path $f) { $code = [int]((Get-Content $f -Raw).Trim()) }
    if ($code -ne 0) { [Console]::Error.WriteLine('You are not logged into any GitHub hosts.') }
    exit $code
}
if ($a.Count -ge 2 -and $a[0] -eq 'pr' -and $a[1] -eq 'list') {
    $e = Join-Path $mockDir 'pr_exit.txt'
    if (Test-Path $e) { [Console]::Error.WriteLine('api error'); exit ([int]((Get-Content $e -Raw).Trim())) }
    $f = Join-Path $mockDir 'pr_list.json'
    if (Test-Path $f) { Write-Output (Get-Content $f -Raw) } else { Write-Output '[]' }
    exit 0
}
if ($a.Count -ge 2 -and $a[0] -eq 'run' -and $a[1] -eq 'list') {
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -eq '--commit' -and ($i + 1) -lt $a.Count) {
            Set-Content -Path (Join-Path $mockDir 'received_sha.txt') -Value $a[$i + 1]
        }
    }
    $expectedFile = Join-Path $mockDir 'expected_sha.txt'
    if (Test-Path $expectedFile) {
        $expected = (Get-Content $expectedFile -Raw).Trim()
        $receivedFile = Join-Path $mockDir 'received_sha.txt'
        $received = ''
        if (Test-Path $receivedFile) { $received = (Get-Content $receivedFile -Raw).Trim() }
        if ($received -ne $expected) { Set-Content -Path (Join-Path $mockDir 'sha_mismatch.txt') -Value ($received + ' != ' + $expected) }
    }
    $f = Join-Path $mockDir 'run_list.json'
    if (Test-Path $f) { Write-Output (Get-Content $f -Raw) } else { Write-Output '[]' }
    exit 0
}
exit 1
'@
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'gh.ps1'), $ghMock)
$pathWithoutRealGh = @($env:PATH -split ';' | Where-Object {
    $_ -ne '' -and -not (Test-Path -LiteralPath (Join-Path $_ 'gh.exe') -PathType Leaf)
})
$env:PATH = (@($ShimDir) + $pathWithoutRealGh) -join ';'
$env:GH_MOCK_DIR = $MockDir

function Set-Mock {
    param([int]$AuthExit = 0, [string]$PrJson = '', [int]$PrExit = -1, [string]$RunJson = '', [string]$ExpectedSha = '')
    Remove-Item (Join-Path $MockDir '*') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $MockDir 'auth_exit.txt') $AuthExit
    if ($PrJson -ne '') { Set-Content (Join-Path $MockDir 'pr_list.json') $PrJson -Encoding utf8 }
    if ($PrExit -ge 0) { Set-Content (Join-Path $MockDir 'pr_exit.txt') $PrExit }
    if ($RunJson -ne '') { Set-Content (Join-Path $MockDir 'run_list.json') $RunJson -Encoding utf8 }
    if ($ExpectedSha -ne '') { Set-Content (Join-Path $MockDir 'expected_sha.txt') $ExpectedSha }
}

# ---- helpers ----
function Fire {
    # $RawStdin is intentionally UNTYPED: a [string] param coerces a $null
    # default to '', which would make the "$null -eq $payload" guard below false
    # and send empty stdin. Keep it untyped so an omitted RawStdin stays $null.
    # $Client controls the child's CLAUDE_PROJECT_DIR, the signal hooks use to
    # tell Claude Code from Codex. Start-Process -Environment MERGES with the
    # inherited environment, so a CLAUDE_PROJECT_DIR set in the parent (running
    # the suite from inside Claude Code) would otherwise leak in and make
    # client-dependent assertions pass locally but differ in CI. Always set it
    # explicitly: 'claude' -> a path, anything else -> empty (Codex).
    param([string]$HookPath, [string]$Cwd, [string]$EventName = 'SessionStart', $Extra = $null, $RawStdin = $null, [string]$Exe = '', [string]$Client = 'codex')
    $payload = $RawStdin
    if ($null -eq $payload) {
        $obj = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName }
        if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
        $payload = $obj | ConvertTo-Json    # multi-line JSON on purpose
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $file = (Get-Process -Id $PID).Path
        $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'
        $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $claudeProjectDir = if ($Client -eq 'claude') { $Cwd } else { '' }
        $startArgs.Environment = @{ PATH = $env:PATH; GH_MOCK_DIR = $env:GH_MOCK_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; CLAUDE_PROJECT_DIR = $claudeProjectDir }
    }
    $proc = Start-BoundedProcess @startArgs
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    if ($err -ne '' -and $env:HOOKMAKER_TEST_DEBUG -eq '1') {
        Write-Host ('  [stderr] ' + $err.Split("`n")[0]) -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

function New-GitRepo {
    param([string]$Name, [bool]$GithubRemote = $true, [string]$PushState = 'synced', [switch]$SkipUpstreamConfig)
    $repo = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    & git -C $repo config core.autocrlf false
    Set-Content (Join-Path $repo 'file.txt') 'v1'
    & git -C $repo add .
    & git -C $repo commit -q -m c1
    if ($GithubRemote) {
        & git -C $repo remote add origin ('https://github.com/testowner/testrepo-' + $Name + '.git')
        # SkipUpstreamConfig leaves the remote added but skips the upstream
        # config + tracking ref, so a test can wire up its own (mismatched,
        # ambiguous, or missing) remote-tracking shape.
        if (-not $SkipUpstreamConfig) {
            # Simulate pushed state locally: remote-tracking ref + upstream config,
            # no network involved.
            & git -C $repo config branch.main.remote origin
            & git -C $repo config branch.main.merge refs/heads/main
            $head = (& git -C $repo rev-parse HEAD).Trim()
            & git -C $repo update-ref refs/remotes/origin/main $head
            if ($PushState -eq 'ahead') {
                Set-Content (Join-Path $repo 'file.txt') 'v2'
                & git -C $repo add .
                & git -C $repo commit -q -m c2
            }
        }
    }
    return $repo
}

# A recognized baseline is silent about the BASELINE; the README badge note
# (order 55 step 6) binds every repository and may still arrive once. Only
# that note is allowed - any other text, and any baseline finding, fails.
function Test-NoBaselineFinding {
    param([AllowNull()][string]$Out)
    if ([string]::IsNullOrWhiteSpace($Out)) { return $true }
    return ($Out -notmatch 'GITHUB BASELINE CHECK' -and $Out -match 'README badges: at least 12 verified badges')
}

function Get-HeadSha {
    param([string]$Repo)
    return ((& git -C $Repo rev-parse HEAD) | Out-String).Trim()
}

try {
    # =====================================================================
    Write-Host '--- GithubBaselineCheck ---' -ForegroundColor Cyan
    $plainDir = Join-Path $Work 'plain'; New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
    $noRemote = New-GitRepo 'noremote' -GithubRemote:$false
    Set-Mock
    $r = Fire -HookPath $BaselineHook -Cwd $plainDir
    Check 'non-git -> silent' ($r.Out -eq '')
    $r = Fire -HookPath $BaselineHook -Cwd $noRemote
    # The workflow baseline stays silent without a GitHub remote; the README
    # badge reminder does NOT - the badge rule binds every repository.
    Check 'no GitHub remote -> no baseline findings' ($r.Out -notmatch 'GITHUB BASELINE CHECK') $r.Out
    Check 'no GitHub remote, no CI -> the badge guidance still arrives' ($r.Out -match 'README badges: at least 12 verified badges') $r.Out

    # =====================================================================
    Write-Host '--- README badges: at least 12, the donation badge always (steering V40) ---' -ForegroundColor Cyan
    function New-BadgeReadme {
        param([string]$Repo, [int]$Shields, [switch]$WithWorkflowBadge, [switch]$WithDonate)
        $row = @(1..$Shields | ForEach-Object { '![b' + $_ + '](https://img.shields.io/badge/fact' + $_ + '-value-blue)' }) -join ' '
        if ($WithWorkflowBadge) { $row += ' [![ci](https://github.com/o/r/actions/workflows/ci.yml/badge.svg)](https://github.com/o/r/actions)' }
        if ($WithDonate) { $row += ' [![Support donations](https://img.shields.io/badge/Support-donations-d04a9a)](#donate)' }
        $tail = if ($WithDonate) { "`n## Donate`n`nFixture section.`n" } else { '' }
        # A plain image near the title is NOT a badge and must not be counted.
        Set-Content -LiteralPath (Join-Path $Repo 'README.md') -Value ($row + "`n![logo](https://example.com/logo.png)`n`n# Title`n" + $tail) -Encoding utf8
    }
    $bd3 = New-GitRepo 'badges3' -GithubRemote:$false
    New-BadgeReadme -Repo $bd3 -Shields 3
    $r = Fire -HookPath $BaselineHook -Cwd $bd3
    Check 'badges: a 3-badge README gets the below-12 prompt' ($r.Out -match 'shows 3 badge image\(s\)[^"]*below 12' -and $r.Out -match 'a prompt, not a defect') $r.Out
    Check 'badges: the guidance carries the priority order, the donation badge and the truth floors' (
        $r.Out -match 'CI status, license, version/release' -and $r.Out -match 'built-with stack, repository facts' -and
        $r.Out -match 'Support-donations-d04a9a' -and $r.Out -match 'Never padded or fabricated' -and $r.Out -match 'No private data in badge URLs') $r.Out
    Check 'badges: a missing donation badge and Donate section are each named' (
        $r.Out -match 'Support-donations badge is missing' -and $r.Out -match 'no \\"## Donate\\" section' -and $r.Out -match 'never invent or alter a wallet address') $r.Out
    Check 'badges: advisory only - never a decision' ($r.Out -notmatch '"decision"') $r.Out
    $bd14 = New-GitRepo 'badges14' -GithubRemote:$false
    New-BadgeReadme -Repo $bd14 -Shields 14
    $r = Fire -HookPath $BaselineHook -Cwd $bd14
    Check 'badges: 14 badges get NO count advisory (no upper limit), still no block' (
        $r.Out -match 'at least 12 verified badges' -and $r.Out -notmatch 'badge image\(s\) near' -and $r.Out -notmatch 'above' -and $r.Out -notmatch '"decision"') $r.Out
    $bd7 = New-GitRepo 'badges7' -GithubRemote:$false
    New-BadgeReadme -Repo $bd7 -Shields 10 -WithWorkflowBadge -WithDonate
    $r = Fire -HookPath $BaselineHook -Cwd $bd7
    Check 'badges: 10 static + workflow + donation = 12 with its Donate section -> guidance only; the plain logo is not counted' (
        $r.Out -match 'at least 12 verified badges' -and $r.Out -notmatch 'badge image\(s\) near' -and
        $r.Out -notmatch 'badge is missing' -and $r.Out -notmatch 'no \\"## Donate\\" section') $r.Out
    $bd11 = New-GitRepo 'badges11' -GithubRemote:$false
    New-BadgeReadme -Repo $bd11 -Shields 9 -WithWorkflowBadge -WithDonate
    $r = Fire -HookPath $BaselineHook -Cwd $bd11
    Check 'badges: 11 real badges (logo excluded) still get the below-12 prompt' ($r.Out -match 'shows 11 badge image\(s\)[^"]*below 12') $r.Out
    $r = Fire -HookPath $BaselineHook -Cwd $bd7
    Check 'badges: the same README state in the same session is said once' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)
    $r = Fire -HookPath $BaselineHook -Cwd $bd3 -Client 'claude'
    Check 'badges: an unchanged state stays quiet for the Claude client too' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)
    $bdClaude = New-GitRepo 'badgesclaude' -GithubRemote:$false
    $r = Fire -HookPath $BaselineHook -Cwd $bdClaude -Client 'claude'
    Check 'badges: Claude gets hookSpecificOutput.additionalContext with the guidance' (
        $r.Out -match '"hookSpecificOutput"' -and $r.Out -match 'additionalContext' -and $r.Out -match 'no root README') $r.Out

    Write-Host '--- self-hosted runners stay manual (plan 012 step 6b) ---' -ForegroundColor Cyan
    $shRepo = New-GitRepo 'selfhostedpush' -GithubRemote:$false
    New-Item -ItemType Directory -Path (Join-Path $shRepo '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $shRepo '.github\workflows\ci.yml') "on:`n  push:`n  workflow_dispatch:`njobs:`n  t:`n    runs-on: [self-hosted, windows]`n    steps:`n      - run: echo test"
    $r = Fire -HookPath $BaselineHook -Cwd $shRepo
    Check 'self-hosted: a push-triggered self-hosted workflow is named, advisory only' (
        $r.Out -match 'SELF-HOSTED RUNNERS STAY MANUAL' -and $r.Out -match 'ci\.yml: a self-hosted job is triggered by push' -and $r.Out -notmatch '"decision"') $r.Out
    $shManual = New-GitRepo 'selfhostedmanual' -GithubRemote:$false
    New-Item -ItemType Directory -Path (Join-Path $shManual '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $shManual '.github\workflows\ci.yml') "on:`n  workflow_dispatch:`njobs:`n  t:`n    runs-on: self-hosted`n    steps:`n      - run: echo test"
    $r = Fire -HookPath $BaselineHook -Cwd $shManual
    Check 'self-hosted: a dispatch-only self-hosted workflow gets no runner note (twin)' ($r.Out -notmatch 'SELF-HOSTED RUNNERS') $r.Out

    # missing .github entirely, npm project
    $b1 = New-GitRepo 'base1'
    Set-Content (Join-Path $b1 'package.json') '{}'
    $r = Fire -HookPath $BaselineHook -Cwd $b1
    Check 'missing .github -> CI + dependabot findings' ($r.Out -match 'GITHUB BASELINE CHECK' -and $r.Out -match 'No CI workflow' -and $r.Out -match 'No \.github/dependabot\.yml' -and $r.Out -match 'npm at /' -and $r.Out -match 'global-github-automation-rules\.md governs it and loads on demand, so read it in full before this work')
    Check 'CodeQL suggested for detected language' ($r.Out -match 'CodeQL')
    Check 'CodeQL is explicitly optional, never mandatory' ($r.Out -match '- Optional: CodeQL') $r.Out
    # Scope: ordinary gaps (missing/weak CI, incomplete Dependabot, optional
    # CodeQL) are advisory for an unrelated task - fix now only when the user
    # asked, the task directly needs it, or a workflow is confirmed unsafe.
    Check 'ordinary gaps are advisory for an unrelated task' (
        $r.Out -match 'These are advisory for an unrelated task: fix now only when the user asked') $r.Out
    Check 'current-task expansion is explicitly prohibited' ($r.Out -match 'Never create or rewrite workflows during an unrelated task') $r.Out
    Check 'the old unconditional "fix per the repository rules" wording is gone' ($r.Out -notmatch 'Fix per the repository rules:') $r.Out
    $r = Fire -HookPath $BaselineHook -Cwd $b1
    Check 'unchanged findings -> silent (cooldown)' ($r.Out -eq '')

    # workflows exist, dependabot missing github-actions entry
    $b2 = New-GitRepo 'base2'
    New-Item -ItemType Directory -Path (Join-Path $b2 '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $b2 '.github\workflows\ci.yml') 'name: CI'
    Set-Content (Join-Path $b2 'package.json') '{}'
    Set-Content (Join-Path $b2 '.github\dependabot.yml') @'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
'@
    $r = Fire -HookPath $BaselineHook -Cwd $b2
    Check 'dependabot lacks github-actions -> reported, npm preserved' ($r.Out -match 'lacks entries for: github-actions at /' -and $r.Out -notmatch 'npm at /,')

    # monorepo: packages/a + packages/b npm, pip at root
    $b3 = New-GitRepo 'base3'
    New-Item -ItemType Directory -Path (Join-Path $b3 'packages\appa'), (Join-Path $b3 'packages\appb') -Force | Out-Null
    Set-Content (Join-Path $b3 'packages\appa\package.json') '{}'
    Set-Content (Join-Path $b3 'packages\appb\package.json') '{}'
    Set-Content (Join-Path $b3 'requirements.txt') 'requests'
    $r = Fire -HookPath $BaselineHook -Cwd $b3
    Check 'monorepo dirs each detected' ($r.Out -match 'npm at /packages/appa' -and $r.Out -match 'npm at /packages/appb' -and $r.Out -match 'pip at /')

    # complete baseline -> silent
    $b4 = New-GitRepo 'base4'
    New-Item -ItemType Directory -Path (Join-Path $b4 '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $b4 '.github\workflows\ci.yml') "on:`n  push:`njobs:`n  test:`n    steps:`n      - run: npm test"
    Set-Content (Join-Path $b4 'package.json') '{}'
    Set-Content (Join-Path $b4 '.github\dependabot.yml') @'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
  - package-ecosystem: "github-actions"
    directory: "/"
'@
    $r = Fire -HookPath $BaselineHook -Cwd $b4
    Check 'complete baseline -> no baseline findings' ([string]$r.Out -notmatch 'GITHUB BASELINE CHECK') ([string]$r.Out)

    $deployOnly = New-GitRepo 'deployonly'
    New-Item -ItemType Directory -Path (Join-Path $deployOnly '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $deployOnly 'package.json') '{}'
    Set-Content (Join-Path $deployOnly '.github\workflows\deploy.yml') "on:`n  push:`njobs:`n  deploy:`n    steps:`n      - run: npm run deploy"
    $r = Fire -HookPath $BaselineHook -Cwd $deployOnly
    Check 'deploy-only workflow does not count as CI' ($r.Out -match 'none provides blocking project validation') $r.Out

    $deep = New-GitRepo 'deepmono'
    $deepDir = Join-Path $deep 'services\platform\backend\billing\worker'
    New-Item -ItemType Directory -Path $deepDir -Force | Out-Null
    Set-Content (Join-Path $deepDir 'pom.xml') '<project />'
    $r = Fire -HookPath $BaselineHook -Cwd $deep
    Check 'deep Maven monorepo directory is detected' ($r.Out -match 'maven at /services/platform/backend/billing/worker') $r.Out

    $dirsRepo = New-GitRepo 'dependabotdirs'
    New-Item -ItemType Directory -Path (Join-Path $dirsRepo '.github\workflows'), (Join-Path $dirsRepo 'apps\a'), (Join-Path $dirsRepo 'apps\b') -Force | Out-Null
    Set-Content (Join-Path $dirsRepo '.github\workflows\ci.yml') "on:`n  pull_request:`njobs:`n  test:`n    steps:`n      - run: npm test"
    Set-Content (Join-Path $dirsRepo 'apps\a\package.json') '{}'
    Set-Content (Join-Path $dirsRepo 'apps\b\package.json') '{}'
    Set-Content (Join-Path $dirsRepo '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directories:`n      - /apps/a`n      - /apps/b`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $dirsRepo
    Check 'Dependabot directories list covers multiple package roots' (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # =====================================================================
    Write-Host '--- GithubBaselineCheck: false positive/negative audit (issue 4) ---' -ForegroundColor Cyan

    # Flow-style trigger array on the `on:` line - a confirmed false negative
    # (the old line-anchored regex only matched block-style `push:`/`pull_request:`).
    $flowTrigger = New-GitRepo 'flowtrigger'
    Set-Content (Join-Path $flowTrigger 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $flowTrigger '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $flowTrigger '.github\workflows\ci.yml') "on: [push, pull_request]`njobs:`n  test:`n    steps:`n      - run: npm test"
    Set-Content (Join-Path $flowTrigger '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $flowTrigger
    Check 'flow-style trigger array (on: [push, pull_request]) is recognized' (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # Quoted "on": key with block-style triggers underneath.
    $quotedOn = New-GitRepo 'quotedon'
    Set-Content (Join-Path $quotedOn 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $quotedOn '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $quotedOn '.github\workflows\ci.yml') "`"on`":`n  push:`n  pull_request:`njobs:`n  test:`n    steps:`n      - run: npm test"
    Set-Content (Join-Path $quotedOn '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $quotedOn
    Check 'quoted "on" key with block-style triggers is recognized' (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # Multiline `run: |` block scalar with the real validation command on a
    # SUBSEQUENT, more-indented line - a confirmed false negative (the old
    # regex only looked for the keyword on the same line as `run:`).
    $multilineRun = New-GitRepo 'multilinerun'
    Set-Content (Join-Path $multilineRun 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $multilineRun '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $multilineRun '.github\workflows\ci.yml') @'
on:
  push:
  pull_request:
jobs:
  test:
    steps:
      - run: |
          npm ci
          npm run build
          npm test
'@
    Set-Content (Join-Path $multilineRun '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $multilineRun
    Check 'multiline run: | block with validation commands is recognized' (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # pyproject.toml classification: Poetry has no distinct Dependabot
    # ecosystem value (stays `pip`); uv DOES (only when uv.lock is present).
    $poetryRepo = New-GitRepo 'poetryproj'
    Set-Content (Join-Path $poetryRepo 'pyproject.toml') "[tool.poetry]`nname = `"x`""
    $r = Fire -HookPath $BaselineHook -Cwd $poetryRepo
    Check 'pyproject.toml without uv.lock classifies as pip (covers Poetry too)' ($r.Out -match 'pip at /') $r.Out

    $uvRepo = New-GitRepo 'uvproj'
    Set-Content (Join-Path $uvRepo 'pyproject.toml') "[project]`nname = `"x`""
    Set-Content (Join-Path $uvRepo 'uv.lock') 'version = 1'
    $r = Fire -HookPath $BaselineHook -Cwd $uvRepo
    Check 'pyproject.toml WITH uv.lock classifies as uv, not pip' ($r.Out -match 'uv at /' -and $r.Out -notmatch 'pip at /') $r.Out

    # Reusable workflow triggered only by `workflow_call`, with real
    # validation, but with NO caller anywhere in the repo - a confirmed false
    # positive fixed: this must NOT count as sufficient CI on its own
    # (nothing locally confirms it is ever actually invoked).
    $uncalledReusable = New-GitRepo 'reusablewf-uncalled'
    Set-Content (Join-Path $uncalledReusable 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $uncalledReusable '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $uncalledReusable '.github\workflows\reusable.yml') @'
on:
  workflow_call:
jobs:
  test:
    steps:
      - run: npm test
'@
    Set-Content (Join-Path $uncalledReusable '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $uncalledReusable
    Check 'an UNCALLED workflow_call-only reusable workflow does not count as CI' ($r.Out -match 'none provides blocking project validation') $r.Out

    # Same reusable workflow, but now a SECOND workflow in the repo actually
    # calls it locally AND is itself directly triggered - now it counts.
    $calledReusable = New-GitRepo 'reusablewf-called'
    Set-Content (Join-Path $calledReusable 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $calledReusable '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $calledReusable '.github\workflows\reusable.yml') @'
on:
  workflow_call:
jobs:
  test:
    steps:
      - run: npm test
'@
    Set-Content (Join-Path $calledReusable '.github\workflows\caller.yml') @'
on:
  push:
jobs:
  call-tests:
    uses: ./.github/workflows/reusable.yml
'@
    Set-Content (Join-Path $calledReusable '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $calledReusable
    Check 'a workflow_call reusable workflow CALLED by a directly-triggered local workflow counts as CI' (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # Unrelated nested key named `push:` (a step's own input, e.g.
    # docker/build-push-action's `push: true`) outside the top-level `on:`
    # block must never be mistaken for a push trigger - a confirmed false
    # positive: the workflow here is really only triggered manually.
    $nestedPushKey = New-GitRepo 'nestedpushkey'
    Set-Content (Join-Path $nestedPushKey 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $nestedPushKey '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $nestedPushKey '.github\workflows\deploy.yml') @'
on:
  workflow_dispatch:
jobs:
  deploy:
    steps:
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: myimage:latest
'@
    $r = Fire -HookPath $BaselineHook -Cwd $nestedPushKey
    Check 'an unrelated nested "push:" key (step input) is not mistaken for a push trigger' ($r.Out -match 'none provides blocking project validation') $r.Out

    # Single-quoted top-level 'on': key (the double-quoted form is already covered above).
    $singleQuotedOn = New-GitRepo 'singlequotedon'
    Set-Content (Join-Path $singleQuotedOn 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $singleQuotedOn '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $singleQuotedOn '.github\workflows\ci.yml') "'on':`n  push:`n  pull_request:`njobs:`n  test:`n    steps:`n      - run: npm test"
    Set-Content (Join-Path $singleQuotedOn '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $singleQuotedOn
    Check "single-quoted 'on' key with block-style triggers is recognized" (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # A comment mentioning trigger words, and a run: command whose text
    # contains "push:", must never be mistaken for a real trigger.
    $commentsAndText = New-GitRepo 'triggerwordsincomments'
    Set-Content (Join-Path $commentsAndText 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $commentsAndText '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $commentsAndText '.github\workflows\deploy.yml') @'
# This workflow intentionally does NOT run on push: or pull_request:, only manually.
on:
  workflow_dispatch:
jobs:
  deploy:
    steps:
      - run: echo "reminder- push: deploys are manual only" && ./deploy.sh
'@
    $r = Fire -HookPath $BaselineHook -Cwd $commentsAndText
    Check 'comments and run-command text mentioning "push:" are not mistaken for a trigger' ($r.Out -match 'none provides blocking project validation') $r.Out

    # Item 7.1: a validation keyword that appears ONLY in a full-line shell
    # comment inside a run: | block is not real validation.
    $commentValidation = New-GitRepo 'commentvalidation'
    Set-Content (Join-Path $commentValidation 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $commentValidation '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $commentValidation '.github\workflows\ci.yml') @'
on:
  push:
  pull_request:
jobs:
  test:
    steps:
      - run: |
          # TODO: run npm test later
          echo "not implemented"
'@
    $r = Fire -HookPath $BaselineHook -Cwd $commentValidation
    Check '7.1 validation keyword only in a shell comment is NOT counted as CI' ($r.Out -match 'none provides blocking project validation') $r.Out

    # Item 7.1 positive: a real validation command AFTER a comment line counts.
    $realAfterComment = New-GitRepo 'realaftercomment'
    Set-Content (Join-Path $realAfterComment 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $realAfterComment '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $realAfterComment '.github\workflows\ci.yml') @'
on:
  push:
  pull_request:
jobs:
  test:
    steps:
      - run: |
          # install dependencies first
          npm ci
          npm test
'@
    Set-Content (Join-Path $realAfterComment '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $realAfterComment
    Check '7.1 a real validation command after a comment line IS counted as CI' (Test-NoBaselineFinding $r.Out) ([string]$r.Out)

    # Item 7.2: a `push` key nested as a workflow_dispatch INPUT (deeper than
    # the direct children of on:) is not a push trigger. Discriminating: the
    # workflow has REAL validation and complete dependabot, so if the nested
    # `push` were wrongly treated as a trigger the baseline would be silent;
    # correctly ignoring it leaves the workflow only manually triggered ->
    # "none provides blocking project validation" surfaces.
    $nestedInputPush = New-GitRepo 'nestedinputpush'
    Set-Content (Join-Path $nestedInputPush 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $nestedInputPush '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $nestedInputPush '.github\workflows\manual.yml') @'
on:
  workflow_dispatch:
    inputs:
      push:
        required: false
        type: boolean
jobs:
  build:
    steps:
      - run: npm test
'@
    Set-Content (Join-Path $nestedInputPush '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $nestedInputPush
    Check '7.2 a push key nested as a workflow_dispatch input is not a push trigger' ($r.Out -match 'none provides blocking project validation') $r.Out

    # Item 7.2 positive: a direct-child push: under on: still triggers, and with
    # real validation this is a complete, silent baseline.
    $directChildPush = New-GitRepo 'directchildpush'
    Set-Content (Join-Path $directChildPush 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $directChildPush '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $directChildPush '.github\workflows\ci.yml') @'
on:
  push:
    branches: [main]
jobs:
  test:
    steps:
      - run: npm test
'@
    Set-Content (Join-Path $directChildPush '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $directChildPush
    Check '7.2 a direct-child push: (with nested branches:) is still a trigger; adequate baseline reports no findings' ([string]$r.Out -notmatch 'GITHUB BASELINE CHECK') ([string]$r.Out)

    # Quoted continue-on-error value.
    $quotedCoe = New-GitRepo 'quotedcoe'
    Set-Content (Join-Path $quotedCoe 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $quotedCoe '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $quotedCoe '.github\workflows\ci.yml') @'
on:
  push:
jobs:
  test:
    steps:
      - run: npm test
        continue-on-error: "true"
'@
    $r = Fire -HookPath $BaselineHook -Cwd $quotedCoe
    Check 'quoted continue-on-error: "true" is still detected as non-blocking' ($r.Out -match 'continue-on-error') $r.Out

    # Flow-style pull_request_target trigger with untrusted checkout - the
    # unsafe-pattern check has the SAME flow-style gap as the main trigger check.
    $prtFlow = New-GitRepo 'prtflow'
    Set-Content (Join-Path $prtFlow 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $prtFlow '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $prtFlow '.github\workflows\ci.yml') @'
on: [pull_request_target]
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - run: npm test
'@
    $r = Fire -HookPath $BaselineHook -Cwd $prtFlow
    Check 'flow-style pull_request_target with untrusted checkout is flagged unsafe' ($r.Out -match 'pull_request_target with untrusted PR checkout') $r.Out
    # A confirmed unsafe workflow is called out as urgent EVEN for an
    # unrelated task, unlike ordinary advisory gaps.
    Check 'a confirmed unsafe workflow is called out as urgent regardless of task relation' (
        $r.Out -match 'is an immediate security risk' -and $r.Out -match 'treat it as urgent even in an otherwise unrelated task') $r.Out

    # Empty workflow file - must not crash, and correctly counts as "no validation".
    $emptyWf = New-GitRepo 'emptywf'
    Set-Content (Join-Path $emptyWf 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $emptyWf '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $emptyWf '.github\workflows\ci.yml') ''
    $r = Fire -HookPath $BaselineHook -Cwd $emptyWf
    Check 'empty workflow file does not crash and is reported as missing validation' ($r.Exit -eq 0 -and $r.Out -match 'none provides blocking project validation') $r.Out

    # Unparseable/garbage workflow content - must degrade gracefully, never crash.
    $garbageWf = New-GitRepo 'garbagewf'
    Set-Content (Join-Path $garbageWf 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $garbageWf '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $garbageWf '.github\workflows\ci.yml') '{{{ not: valid: yaml :::: [[['
    $r = Fire -HookPath $BaselineHook -Cwd $garbageWf
    Check 'unparseable workflow content does not crash the hook' ($r.Exit -eq 0) ($r.Out + '|exit=' + $r.Exit)

    # =====================================================================
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
        $ps51 = New-GitRepo 'ps51repo'
        Set-Content (Join-Path $ps51 'package.json') '{}'
        $r = Fire -HookPath $BaselineHook -Cwd $ps51 -Exe 'powershell.exe'
        Check 'GithubBaselineCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'GITHUB BASELINE CHECK')
    }
    else {
        Write-Host '[SKIP] powershell.exe not available' -ForegroundColor Yellow
    }
}
finally {
    $env:LOCALAPPDATA = $OriginalLocalAppData
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
$resultColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ('Result: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed') -ForegroundColor $resultColor
exit $script:Fail
