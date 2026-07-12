# Smoke test for the GitHub-integration hooks: DependabotCheck, CiStatusCheck,
# and GithubBaselineCheck.
#
# Fully offline and account-free: git state is built in throwaway local repos
# (remote-tracking refs are simulated with git update-ref - no fetch/push), and
# the GitHub CLI is replaced by a PATH shim (gh.cmd -> gh-mock.ps1) that serves
# canned JSON from $env:GH_MOCK_DIR. Payloads are delivered through a real
# stdin file handle (see Test-Engine.ps1 for why pipes are not used).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-GitHubHooks.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$DependabotHook = Join-Path $HooksRoot 'DependabotCheck\DependabotCheck.ps1'
$CiHook = Join-Path $HooksRoot 'CiStatusCheck\CiStatusCheck.ps1'
$BaselineHook = Join-Path $HooksRoot 'GithubBaselineCheck\GithubBaselineCheck.ps1'
foreach ($hook in @($DependabotHook, $CiHook, $BaselineHook)) {
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        Write-Host "Hook not found: $hook" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Actual = $null)
    if ($Condition) {
        $script:Pass++
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($env:HOOKMAKER_TEST_DEBUG -eq '1' -and $null -ne $Actual) {
            $preview = $Actual
            if ($preview.Length -gt 200) { $preview = $preview.Substring(0, 200) }
            Write-Host ('       actual: [' + $preview + ']') -ForegroundColor DarkGray
        }
    }
}

$TestStart = [DateTime]::UtcNow
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-ghtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# ---- gh shim: intercepts every `gh` call in child processes ----
$ShimDir = Join-Path $Work 'ghshim'
$MockDir = Join-Path $Work 'ghmock'
New-Item -ItemType Directory -Path $ShimDir, $MockDir -Force | Out-Null
$ghCmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0gh-mock.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'gh.cmd'), $ghCmd)
$ghMock = @'
$mockDir = $env:GH_MOCK_DIR
if (-not $mockDir) { exit 1 }
$a = @($args)
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
        if ($received -ne $expected) { Write-Output '[]'; exit 0 }
    }
    $f = Join-Path $mockDir 'run_list.json'
    if (Test-Path $f) { Write-Output (Get-Content $f -Raw) } else { Write-Output '[]' }
    exit 0
}
exit 1
'@
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'gh-mock.ps1'), $ghMock)
$env:PATH = $ShimDir + ';' + $env:PATH
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
    param([string]$HookPath, [string]$Cwd, [string]$EventName = 'SessionStart', $Extra = $null, $RawStdin = $null, [string]$Exe = 'pwsh')
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
    if ($Exe -eq 'pwsh') {
        $file = 'pwsh'
        $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'
        $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
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
    param([string]$Name, [bool]$GithubRemote = $true, [string]$PushState = 'synced')
    $repo = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    Set-Content (Join-Path $repo 'file.txt') 'v1'
    & git -C $repo add .
    & git -C $repo commit -q -m c1
    if ($GithubRemote) {
        & git -C $repo remote add origin ('https://github.com/testowner/testrepo-' + $Name + '.git')
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
    return $repo
}

function Get-HeadSha {
    param([string]$Repo)
    return ((& git -C $Repo rev-parse HEAD) | Out-String).Trim()
}

try {
    # =====================================================================
    Write-Host '--- shared input handling ---' -ForegroundColor Cyan
    $plainDir = Join-Path $Work 'plain'; New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
    Set-Mock
    $r = Fire -HookPath $DependabotHook -Cwd $plainDir -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '')
    $r = Fire -HookPath $DependabotHook -Cwd $plainDir -RawStdin 'not json at all'
    Check 'garbage single-line stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '')
    $r = Fire -HookPath $DependabotHook -Cwd $plainDir
    Check 'non-git directory -> silent (multi-line JSON stdin)' ($r.Exit -eq 0 -and $r.Out -eq '')
    $noRemote = New-GitRepo 'noremote' -GithubRemote:$false
    $r = Fire -HookPath $DependabotHook -Cwd $noRemote
    Check 'git repo without GitHub remote -> silent' ($r.Exit -eq 0 -and $r.Out -eq '')

    # =====================================================================
    Write-Host '--- DependabotCheck ---' -ForegroundColor Cyan
    $repoA = New-GitRepo 'depa'

    # unauthenticated gh -> limitation note (not a "no updates" claim)
    Set-Mock -AuthExit 1
    $r = Fire -HookPath $DependabotHook -Cwd $repoA
    Check 'gh unauthenticated -> limitation reported, no claim' ($r.Out -match 'could NOT be verified' -and $r.Out -match 'not authenticated') ('out=' + $r.Out)
    $r = Fire -HookPath $DependabotHook -Cwd $repoA
    Check 'unchanged limitation -> silent (cooldown)' ($r.Out -eq '')

    # no dependabot work -> silent
    $repoB = New-GitRepo 'depb'
    Set-Mock -PrJson '[]'
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'no Dependabot PRs -> silent' ($r.Exit -eq 0 -and $r.Out -eq '')

    # fake author with dependabot-looking branch -> excluded -> silent
    $fakePr = '[{"number":9,"title":"Bump x from 1.0.0 to 9.9.9","author":{"login":"eviluser"},"headRefName":"dependabot/npm/x-9.9.9","baseRefName":"main","headRefOid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[]}]'
    Set-Mock -PrJson $fakePr
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'fake "dependabot" branch from wrong author -> silent' ($r.Out -eq '')

    # verified PR set: patch+security+major+prerelease+grouped, states and checks
    $prJson = @'
[
 {"number":11,"title":"Bump lodash from 4.17.20 to 4.17.21","author":{"login":"app/dependabot"},"headRefName":"dependabot/npm/lodash","baseRefName":"main","headRefOid":"1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","isDraft":false,"mergeStateStatus":"CLEAN","labels":[{"name":"dependencies"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"SUCCESS"}]},
 {"number":12,"title":"Bump django from 4.2.9 to 4.2.10","author":{"login":"app/dependabot"},"headRefName":"dependabot/pip/django","baseRefName":"main","headRefOid":"2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","isDraft":false,"mergeStateStatus":"BEHIND","labels":[{"name":"security"}],"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]},
 {"number":13,"title":"Bump react from 17.0.2 to 18.2.0","author":{"login":"app/dependabot"},"headRefName":"dependabot/npm/react","baseRefName":"main","headRefOid":"3333333ccccccccccccccccccccccccccccccccc","isDraft":false,"mergeStateStatus":"DIRTY","labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]},
 {"number":14,"title":"Bump pkg from 1.2.3 to 2.0.0-rc.1","author":{"login":"app/dependabot"},"headRefName":"dependabot/npm/pkg","baseRefName":"main","headRefOid":"4444444ddddddddddddddddddddddddddddddddd","isDraft":true,"mergeStateStatus":"BLOCKED","labels":[],"statusCheckRollup":[]},
 {"number":15,"title":"Bump the actions group with 3 updates","author":{"login":"app/dependabot"},"headRefName":"dependabot/github_actions/the-group","baseRefName":"main","headRefOid":"5555555eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}
]
'@
    Set-Mock -PrJson $prJson
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'pending PRs -> context injected with count' ($r.Out -match 'DEPENDABOT CHECK' -and $r.Out -match '5 pending')
    Check 'patch classified' ($r.Out -match '#11 .*\[patch')
    Check 'security prioritized + behind-base state' ($r.Out -match '#12 .*\[SECURITY' -and $r.Out -match 'behind base')
    Check 'major + merge conflict + failed check surfaced' ($r.Out -match '#13 .*\[MAJOR' -and $r.Out -match 'MERGE CONFLICT' -and $r.Out -match '1 FAILED')
    Check 'prerelease + draft flagged' ($r.Out -match '#14 \[draft\] .*\[PRERELEASE')
    Check 'grouped update classified' ($r.Out -match '#15 .*\[grouped')
    Check 'exact head SHA quoted' ($r.Out -match 'head sha 1111111')
    Check 'policy tail present, concise' ($r.Out -match 'never auto-merge MAJOR or PRERELEASE')

    # unchanged state -> silent; changed state -> reports again
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'unchanged PR state -> silent (fingerprint cooldown)' ($r.Out -eq '')
    $changed = $prJson.Replace('1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '9999999aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    Set-Mock -PrJson $changed
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'changed PR state -> reported again immediately' ($r.Out -match 'DEPENDABOT CHECK')

    # query failure -> limitation, not silence-as-no-updates
    $repoC = New-GitRepo 'depc'
    Set-Mock -PrExit 1
    $r = Fire -HookPath $DependabotHook -Cwd $repoC
    Check 'pr query failure -> limitation reported' ($r.Out -match 'could NOT be verified')

    # Stop event -> silent (context hook)
    Set-Mock -PrJson $prJson
    $r = Fire -HookPath $DependabotHook -Cwd $repoB -EventName 'Stop'
    Check 'Stop event -> silent' ($r.Out -eq '')

    # =====================================================================
    Write-Host '--- CiStatusCheck ---' -ForegroundColor Cyan
    $ci = New-GitRepo 'ci1'
    $sha = Get-HeadSha $ci

    $r = Fire -HookPath $CiHook -Cwd $plainDir -EventName 'Stop'
    Check 'non-git -> silent' ($r.Out -eq '')
    $r = Fire -HookPath $CiHook -Cwd $ci -EventName 'SessionStart'
    Check 'context event -> silent (Stop-only hook)' ($r.Out -eq '')
    $r = Fire -HookPath $CiHook -Cwd $ci -EventName 'Stop' -Extra @{ stop_hook_active = $true }
    Check 'stop_hook_active -> silent' ($r.Out -eq '')

    $aheadRepo = New-GitRepo 'ci-ahead' -PushState 'ahead'
    Set-Mock -RunJson '[{"databaseId":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]'
    $r = Fire -HookPath $CiHook -Cwd $aheadRepo -EventName 'Stop'
    Check 'unpushed HEAD (ahead) -> silent' ($r.Out -eq '')

    # success -> verified silently; second run also silent via state
    Set-Mock -RunJson '[{"databaseId":10,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $sha
    $r = Fire -HookPath $CiHook -Cwd $ci -EventName 'Stop'
    Check 'all checks green -> silent, commit verified' ($r.Out -eq '')
    $received = (Get-Content (Join-Path $MockDir 'received_sha.txt') -Raw).Trim()
    Check 'exact pushed SHA queried (not newest run)' ($received -eq $sha)
    Set-Mock -RunJson '[{"databaseId":11,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $sha
    $r = Fire -HookPath $CiHook -Cwd $ci -EventName 'Stop'
    Check 'already-verified commit -> silent (no re-query nag)' ($r.Out -eq '')

    # pending -> block
    $ci2 = New-GitRepo 'ci2'
    $sha2 = Get-HeadSha $ci2
    Set-Mock -RunJson '[{"databaseId":21,"name":"CI","workflowName":"CI","status":"in_progress","conclusion":null}]' -ExpectedSha $sha2
    $r = Fire -HookPath $CiHook -Cwd $ci2 -EventName 'Stop'
    Check 'pending checks -> block with wait guidance' ($r.Out -match '"decision":"block"' -and $r.Out -match 'still in progress' -and $r.Out -match 'gh run list --commit')
    $r = Fire -HookPath $CiHook -Cwd $ci2 -EventName 'Stop'
    Check 'pending again within cooldown -> silent' ($r.Out -eq '')

    # failure -> block with fix guidance; repeated -> cooldown silence
    $ci3 = New-GitRepo 'ci3'
    $sha3 = Get-HeadSha $ci3
    Set-Mock -RunJson '[{"databaseId":31,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $sha3
    $r = Fire -HookPath $CiHook -Cwd $ci3 -EventName 'Stop'
    Check 'failed checks -> block with real-fix guidance' ($r.Out -match 'FAILED' -and $r.Out -match '--log-failed' -and $r.Out -match 'Do not weaken or skip tests')
    $r = Fire -HookPath $CiHook -Cwd $ci3 -EventName 'Stop'
    Check 'same failed SHA -> silent within failure cooldown' ($r.Out -eq '')

    # new pushed commit resets the cycle
    Set-Content (Join-Path $ci3 'file.txt') 'v3'
    & git -C $ci3 add .
    & git -C $ci3 commit -q -m c3
    $sha3b = Get-HeadSha $ci3
    & git -C $ci3 update-ref refs/remotes/origin/main $sha3b
    Set-Mock -RunJson '[{"databaseId":32,"name":"CI","workflowName":"CI","status":"completed","conclusion":"timed_out"}]' -ExpectedSha $sha3b
    $r = Fire -HookPath $CiHook -Cwd $ci3 -EventName 'Stop'
    Check 'NEW pushed commit -> re-checked; timed_out classed as infra/flaky' ($r.Out -match '"decision":"block"' -and $r.Out -match 'timed_out' -and $r.Out -match 'infrastructure')

    # cancelled + stale also infra-classified
    $ci4 = New-GitRepo 'ci4'
    $sha4 = Get-HeadSha $ci4
    Set-Mock -RunJson '[{"databaseId":41,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"},{"databaseId":42,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"stale"}]' -ExpectedSha $sha4
    $r = Fire -HookPath $CiHook -Cwd $ci4 -EventName 'Stop'
    Check 'cancelled/stale -> infra wording, rerun-once guidance' ($r.Out -match 'cancelled' -and $r.Out -match 'stale' -and $r.Out -match 'rerun')

    # no runs yet but workflows exist -> block; no workflows at all -> verified silent
    $ci5 = New-GitRepo 'ci5'
    New-Item -ItemType Directory -Path (Join-Path $ci5 '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $ci5 '.github\workflows\ci.yml') 'name: CI'
    Set-Mock -ExpectedSha (Get-HeadSha $ci5)
    $r = Fire -HookPath $CiHook -Cwd $ci5 -EventName 'Stop'
    Check 'workflows exist, no runs yet -> block (wait)' ($r.Out -match 'no runs are registered yet')
    $ci6 = New-GitRepo 'ci6'
    Set-Mock -ExpectedSha (Get-HeadSha $ci6)
    $r = Fire -HookPath $CiHook -Cwd $ci6 -EventName 'Stop'
    Check 'no workflows configured -> silent verified' ($r.Out -eq '')

    # gh unauthenticated -> silent degradation (never claims verified)
    $ci7 = New-GitRepo 'ci7'
    Set-Mock -AuthExit 1
    $r = Fire -HookPath $CiHook -Cwd $ci7 -EventName 'Stop'
    Check 'gh unavailable -> silent degradation' ($r.Out -eq '')

    # =====================================================================
    Write-Host '--- GithubBaselineCheck ---' -ForegroundColor Cyan
    Set-Mock
    $r = Fire -HookPath $BaselineHook -Cwd $plainDir
    Check 'non-git -> silent' ($r.Out -eq '')
    $r = Fire -HookPath $BaselineHook -Cwd $noRemote
    Check 'no GitHub remote -> silent' ($r.Out -eq '')

    # missing .github entirely, npm project
    $b1 = New-GitRepo 'base1'
    Set-Content (Join-Path $b1 'package.json') '{}'
    $r = Fire -HookPath $BaselineHook -Cwd $b1
    Check 'missing .github -> CI + dependabot findings' ($r.Out -match 'GITHUB BASELINE CHECK' -and $r.Out -match 'No CI workflow' -and $r.Out -match 'No \.github/dependabot\.yml' -and $r.Out -match 'npm at /')
    Check 'CodeQL suggested for detected language' ($r.Out -match 'CodeQL')
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
    Set-Content (Join-Path $b4 '.github\workflows\ci.yml') 'name: CI'
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
    Check 'complete baseline -> silent' ($r.Out -eq '')

    # =====================================================================
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
        $ps51 = New-GitRepo 'ps51repo'
        Set-Content (Join-Path $ps51 'package.json') '{}'
        Set-Mock -PrJson $prJson
        $r = Fire -HookPath $DependabotHook -Cwd $ps51 -Exe 'powershell.exe'
        Check 'DependabotCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'DEPENDABOT CHECK')
        $r = Fire -HookPath $BaselineHook -Cwd $ps51 -Exe 'powershell.exe'
        Check 'GithubBaselineCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'GITHUB BASELINE CHECK')
        $ps51ci = New-GitRepo 'ps51ci'
        Set-Mock -RunJson '[{"databaseId":51,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha (Get-HeadSha $ps51ci)
        $r = Fire -HookPath $CiHook -Cwd $ps51ci -EventName 'Stop' -Exe 'powershell.exe'
        Check 'CiStatusCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match '"decision":"block"')
    }
    else {
        Write-Host '[SKIP] powershell.exe not available' -ForegroundColor Yellow
    }
}
finally {
    # remove only the cooldown state files this run created
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    if (Test-Path -LiteralPath $stateDir) {
        Get-ChildItem -LiteralPath $stateDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(DependabotCheck|CiStatusCheck|GithubBaselineCheck)-' -and $_.LastWriteTimeUtc -ge $TestStart } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        Get-ChildItem -LiteralPath $Work -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        [System.IO.Directory]::Delete($Work, $true)
    }
}

Write-Host ''
$resultColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ('Result: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed') -ForegroundColor $resultColor
exit $script:Fail
