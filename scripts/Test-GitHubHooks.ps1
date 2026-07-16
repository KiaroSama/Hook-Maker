# Smoke test for the GitHub-integration hooks: DependabotCheck, CiStatusCheck,
# and GithubBaselineCheck.
#
# Fully offline and account-free: git state is built in throwaway local repos
# (remote-tracking refs are simulated with git update-ref - no fetch/push), and
# the GitHub CLI is replaced by a PATH shim (gh.ps1) that serves
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
$DependabotHook = Join-Path $HooksRoot 'Dependabot-Check\Dependabot-Check.ps1'
$CiHook = Join-Path $HooksRoot 'Ci-Status-Check\Ci-Status-Check.ps1'
$BaselineHook = Join-Path $HooksRoot 'Github-Baseline-Check\Github-Baseline-Check.ps1'
foreach ($hook in @($DependabotHook, $CiHook, $BaselineHook)) {
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        Write-Host "Hook not found: $hook" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 200
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-ghtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
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
    param([string]$HookPath, [string]$Cwd, [string]$EventName = 'SessionStart', $Extra = $null, $RawStdin = $null, [string]$Exe = '')
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
        $startArgs.Environment = @{ PATH = $env:PATH; GH_MOCK_DIR = $env:GH_MOCK_DIR; LOCALAPPDATA = $env:LOCALAPPDATA }
    }
    $proc = Start-Process @startArgs
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

function Get-HeadSha {
    param([string]$Repo)
    return ((& git -C $Repo rev-parse HEAD) | Out-String).Trim()
}

# Invokes Ci-Status-Check.ps1 -ReportExternalBlocker as a direct CLI action
# (not stdin-driven) with $Cwd as the process's actual working directory,
# mirroring how the agent would run it from inside the target repo.
function FireExternalBlocker {
    param([string]$Cwd, [string]$Classification = '', [string]$Reason = '', [string]$Exe = '', [string]$HookPath = $CiHook)
    $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '" -ReportExternalBlocker'
    if ($Classification -ne '') { $argLine += ' -Classification ' + $Classification }
    if ($Reason -ne '') { $argLine += ' -Reason "' + $Reason + '"' }
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $file = (Get-Process -Id $PID).Path
    }
    else {
        $file = 'powershell.exe'
        $argLine = $argLine.Replace('-NoLogo -NoProfile -File', '-NoLogo -NoProfile -ExecutionPolicy Bypass -File')
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; WorkingDirectory = $Cwd
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; GH_MOCK_DIR = $env:GH_MOCK_DIR; LOCALAPPDATA = $env:LOCALAPPDATA }
    }
    $proc = Start-Process @startArgs
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Copies Ci-Status-Check.ps1 + a custom .env (own _hooklib copy, since the
# hook dot-sources "..\_hooklib.ps1") - used to override EXTERNAL_BLOCKER_TTL_MINUTES.
function New-ConfiguredCiHookCopy {
    param([hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('cihookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $CiHook (Join-Path $dir 'Ci-Status-Check.ps1')
    Copy-Item (Join-Path $HooksRoot '_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
    Set-Content -Path (Join-Path $dir '.env') -Value ($lines.ToArray() -join "`r`n") -Encoding utf8
    return (Join-Path $dir 'Ci-Status-Check.ps1')
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

    $multi = New-GitRepo 'multi'
    & git -C $multi remote rename origin backup
    & git -C $multi remote add origin 'https://github.com/wrong/origin.git'
    & git -C $multi remote add upstream 'git@github.com:right/upstream-repo.git'
    & git -C $multi config branch.main.remote upstream
    & git -C $multi config branch.main.merge refs/heads/main
    & git -C $multi update-ref refs/remotes/upstream/main (Get-HeadSha $multi)
    Set-Mock -PrJson '[]'
    $r = Fire -HookPath $DependabotHook -Cwd $multi
    $calls = [System.IO.File]::ReadAllText((Join-Path $MockDir 'calls.txt'))
    Check 'Dependabot binds gh to current upstream repository' ($calls -match 'pr\|list\|--repo\|right/upstream-repo') $calls

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
    Check 'all checks green -> silent, commit verified' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)
    $received = (Get-Content (Join-Path $MockDir 'received_sha.txt') -Raw).Trim()
    Check 'exact pushed SHA queried (not newest run)' ($received -eq $sha)
    Set-Mock -RunJson '[{"databaseId":11,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $sha
    $r = Fire -HookPath $CiHook -Cwd $ci -EventName 'Stop'
    Check 'already-verified commit -> silent (no re-query nag)' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

    # pending -> block
    $ci2 = New-GitRepo 'ci2'
    $sha2 = Get-HeadSha $ci2
    Set-Mock -RunJson '[{"databaseId":21,"name":"CI","workflowName":"CI","status":"in_progress","conclusion":null}]' -ExpectedSha $sha2
    $r = Fire -HookPath $CiHook -Cwd $ci2 -EventName 'Stop'
    Check 'pending checks -> block with wait guidance' ($r.Out -match '"decision":"block"' -and $r.Out -match 'still in progress' -and $r.Out -match 'gh run list --commit')
    $r = Fire -HookPath $CiHook -Cwd $ci2 -EventName 'Stop'
    Check 'pending checks remain a completion block during cooldown' ($r.Out -match '"decision":"block"') $r.Out

    # failure -> block with fix guidance; repeated -> cooldown silence
    $ci3 = New-GitRepo 'ci3'
    $sha3 = Get-HeadSha $ci3
    Set-Mock -RunJson '[{"databaseId":31,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $sha3
    $r = Fire -HookPath $CiHook -Cwd $ci3 -EventName 'Stop'
    Check 'failed checks -> block with real-fix guidance' ($r.Out -match 'FAILED' -and $r.Out -match '--log-failed' -and $r.Out -match 'Do not weaken or skip tests')
    $r = Fire -HookPath $CiHook -Cwd $ci3 -EventName 'Stop'
    Check 'failed checks remain a completion block during cooldown' ($r.Out -match '"decision":"block"') $r.Out
    $calls = [System.IO.File]::ReadAllText((Join-Path $MockDir 'calls.txt'))
    Check 'CI binds exact-SHA query to repository' ($calls -match 'run\|list\|--repo\|testowner/testrepo-ci3\|--commit') $calls

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
    Check 'no workflows configured -> silent verified' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

    # gh unauthenticated -> silent degradation (never claims verified)
    $ci7 = New-GitRepo 'ci7'
    Set-Mock -AuthExit 1
    $r = Fire -HookPath $CiHook -Cwd $ci7 -EventName 'Stop'
    Check 'gh unavailable -> silent degradation' ($r.Out -eq '')

    # =====================================================================
    Write-Host '--- CiStatusCheck: repository/remote resolution correctness (issue 3) ---' -ForegroundColor Cyan

    # Branch upstream tracks a NON-GitHub remote while `origin` is GitHub and
    # its OWN tracking ref is up to date with HEAD - must still resolve and
    # verify against origin, not misuse the mirror's ahead-count.
    $mismatchOk = New-GitRepo 'mismatch-ok' -SkipUpstreamConfig
    & git -C $mismatchOk remote add mirror 'https://gitlab.example.com/testowner/mismatch-ok.git'
    & git -C $mismatchOk config branch.main.remote mirror
    & git -C $mismatchOk config branch.main.merge refs/heads/main
    $mmSha = Get-HeadSha $mismatchOk
    & git -C $mismatchOk update-ref refs/remotes/mirror/main $mmSha
    & git -C $mismatchOk update-ref refs/remotes/origin/main $mmSha
    Set-Mock -RunJson '[{"databaseId":70,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $mmSha
    $r = Fire -HookPath $CiHook -Cwd $mismatchOk -EventName 'Stop'
    Check 'non-GitHub upstream + up-to-date GitHub origin ref -> still verifies against origin' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)
    $calls = [System.IO.File]::ReadAllText((Join-Path $MockDir 'calls.txt'))
    Check 'queries the origin repository slug, not the mirror' ($calls -match 'testowner/testrepo-mismatch-ok') $calls

    # Same mismatched-upstream shape, but origin has NO matching tracking ref
    # at all - must stay silent, never claim pushed/verified off the mirror.
    $mismatchNoRef = New-GitRepo 'mismatch-noref' -SkipUpstreamConfig
    & git -C $mismatchNoRef remote add mirror 'https://gitlab.example.com/testowner/mismatch-noref.git'
    & git -C $mismatchNoRef config branch.main.remote mirror
    & git -C $mismatchNoRef config branch.main.merge refs/heads/main
    & git -C $mismatchNoRef update-ref refs/remotes/mirror/main (Get-HeadSha $mismatchNoRef)
    Set-Mock
    $r = Fire -HookPath $CiHook -Cwd $mismatchNoRef -EventName 'Stop'
    Check 'non-GitHub upstream + no origin tracking ref -> stays silent (no false pushed claim)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # Local branch tracks a DIFFERENTLY NAMED remote branch on the correct,
    # selected remote - @{upstream} must still resolve it correctly.
    $diffBranch = New-GitRepo 'diffbranch'
    & git -C $diffBranch config branch.main.merge refs/heads/release
    $dbSha = Get-HeadSha $diffBranch
    & git -C $diffBranch update-ref refs/remotes/origin/release $dbSha
    Set-Mock -RunJson '[{"databaseId":71,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $dbSha
    $r = Fire -HookPath $CiHook -Cwd $diffBranch -EventName 'Stop'
    Check 'differently-named remote branch still resolves via @{upstream}' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

    # Multiple GitHub remotes, no unambiguous target (neither is origin,
    # neither matches the branch's configured upstream) - must degrade silently.
    $ambiguous = New-GitRepo 'ambiguous' -SkipUpstreamConfig
    & git -C $ambiguous remote remove origin
    & git -C $ambiguous remote add alpha 'https://github.com/testowner/alpha-repo.git'
    & git -C $ambiguous remote add beta 'https://github.com/testowner/beta-repo.git'
    Set-Mock
    $r = Fire -HookPath $CiHook -Cwd $ambiguous -EventName 'Stop'
    Check 'multiple ambiguous GitHub remotes -> stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # Detached HEAD - no branch, must stay silent.
    $detached = New-GitRepo 'detached'
    $detSha = Get-HeadSha $detached
    & git -C $detached checkout -q --detach $detSha
    Set-Mock
    $r = Fire -HookPath $CiHook -Cwd $detached -EventName 'Stop'
    Check 'detached HEAD -> stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # No upstream config and no remote-tracking ref at all.
    $noRef = New-GitRepo 'norackingref' -SkipUpstreamConfig
    Set-Mock
    $r = Fire -HookPath $CiHook -Cwd $noRef -EventName 'Stop'
    Check 'no upstream config and no remote-tracking ref -> stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # Path containing spaces still resolves and verifies correctly.
    $spacedRepo = New-GitRepo 'repo with space'
    $spacedSha = Get-HeadSha $spacedRepo
    Set-Mock -RunJson '[{"databaseId":72,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $spacedSha
    $r = Fire -HookPath $CiHook -Cwd $spacedRepo -EventName 'Stop'
    Check 'project path containing spaces resolves and verifies' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

    # =====================================================================
    Write-Host '--- CiStatusCheck: -ReportExternalBlocker exception (issue 3, re-verified) ---' -ForegroundColor Cyan

    $ext1 = New-GitRepo 'ext1'
    $extSha1 = Get-HeadSha $ext1

    $r = FireExternalBlocker -Cwd $ext1 -Classification 'test-failure-not-really-external' -Reason 'ci is red, ci is red, ci is red'
    Check 'unknown classification is rejected (no bypass via free text)' ($r.Exit -eq 1 -and $r.Err -match 'requires -Classification') $r.Err
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason ''
    Check 'empty reason is rejected (bounded minimum-evidence rule)' ($r.Exit -eq 1 -and $r.Err -match 'requires -Reason') $r.Err
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'too short'
    Check 'a too-short reason is rejected (below the minimum-evidence length)' ($r.Exit -eq 1 -and $r.Err -match 'requires -Reason') $r.Err
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'other-external' -Reason 'weird one-off issue'
    Check '"other-external" requires a stronger (longer) reason than the named categories' ($r.Exit -eq 1 -and $r.Err -match 'stronger justification') $r.Err
    $r = FireExternalBlocker -Cwd $plainDir -Classification 'github-outage' -Reason 'github.com is down according to the status page'
    Check 'cannot record an exception outside a resolvable pushed GitHub commit' ($r.Exit -eq 1 -and $r.Err -match 'not a resolvable, pushed commit') $r.Err

    # No CI access at all -> recording is refused (never blind/unverified).
    Set-Mock -AuthExit 1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'cannot record without querying CI (gh unauthenticated)' ($r.Exit -eq 1 -and $r.Err -match 'could not query GitHub Actions') $r.Err

    # CI already green for this exact commit -> nothing to excuse.
    Set-Mock -RunJson '[{"databaseId":79,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $extSha1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'cannot record when CI for this commit is already green' ($r.Exit -eq 1 -and $r.Err -match 'already fully green') $r.Err

    # Normal failure still blocks BEFORE any exception is recorded, and a
    # genuine COMPLETED failure can never be excused as external - not even
    # with a nominally "valid" classification.
    Set-Mock -RunJson '[{"databaseId":80,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'failed CI still blocks completion before any exception exists' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'other-external' -Reason 'the build step failed so lets just call it external instead'
    Check 'a genuine completed failure cannot be reported as external, regardless of classification' ($r.Exit -eq 1 -and $r.Err -match 'genuine COMPLETED failure') $r.Err

    # An infra-consistent state (cancelled - not a completed code/test
    # failure) IS eligible, and recording captures that exact state.
    Set-Mock -RunJson '[{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"}]' -ExpectedSha $extSha1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'recording an evidenced external blocker succeeds for an infra-consistent CI state' ($r.Exit -eq 0 -and $r.Out -match 'EXTERNAL CI blocker' -and $r.Out -match 'does NOT mark CI verified') $r.Out
    # Item 5: completion allowed, but Stop surfaces a NON-BLOCKING "CI not green" notice.
    $r = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'active exception authorizes completion with a NON-BLOCKING context (not decision:block)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'additionalContext') $r.Out
    Check 'the completion context explicitly says CI is NOT verified green' ($r.Out -match 'CI NOT VERIFIED GREEN' -and $r.Out -match 'external' ) $r.Out
    Check 'the completion context names classification + short sha and leaks no secret' ($r.Out -match 'github-outage' -and $r.Out -notmatch 'status page reports a full outage.*token') $r.Out

    # Throttled re-check, same observed fingerprint -> still allowed (refreshed, not retired) + still non-blocking notice.
    $recheckHook = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_RECHECK_MINUTES = '0' }
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'recheck with the identical CI fingerprint keeps completion allowed with the notice' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out

    # Item 4: same run id/status/conclusion but a CHANGED attempt/updatedAt
    # (a rerun) produces a different fingerprint -> the old exception is
    # invalidated and the (still-infra) state blocks normally.
    Set-Mock -RunJson '[{"databaseId":81,"attempt":2,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T12:30:00Z"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'a rerun (changed attempt/updatedAt, same id/status/conclusion) invalidates the old exception' ($r.Out -match '"decision":"block"') $r.Out

    # Re-record, then recheck with the SAME runs in a DIFFERENT order -> the
    # normalized/sorted fingerprint is unchanged, so the exception is kept.
    Set-Mock -RunJson '[{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"},{"databaseId":70,"attempt":1,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"}]' -ExpectedSha $extSha1
    $r = FireExternalBlocker -Cwd $ext1 -Classification 'github-outage' -Reason 'GitHub Actions status page reports a full outage'
    Check 'records an exception over a two-run snapshot' ($r.Exit -eq 0) $r.Err
    Set-Mock -RunJson '[{"databaseId":70,"attempt":1,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"},{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled","updatedAt":"2026-07-16T10:00:00Z"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'reordered but identical snapshot keeps the exception (order-independent fingerprint)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out

    # Throttled re-check, CI turned GREEN -> exception retired, verified normally
    # (NO external wording).
    Set-Mock -RunJson '[{"databaseId":81,"attempt":1,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"},{"databaseId":70,"attempt":1,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"success"}]' -ExpectedSha $extSha1
    $r = Fire -HookPath $recheckHook -Cwd $ext1 -EventName 'Stop'
    Check 'CI turning green on recheck retires the exception and verifies normally (no external wording)' ($r.Out -notmatch 'CI NOT VERIFIED GREEN' -and [string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)
    $r2 = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'the commit now stays verified on a normal follow-up check too' ([string]::IsNullOrWhiteSpace([string]$r2.Out)) ([string]$r2.Out)

    # Throttled re-check, CI changed to a DIFFERENT failure -> exception
    # invalidated, blocks normally (also covers "pending cannot reuse a
    # stale exception": any different fingerprint invalidates it the same way).
    $ext1b = New-GitRepo 'ext1b'
    $extSha1bb = Get-HeadSha $ext1b
    Set-Mock -RunJson '[{"databaseId":90,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $extSha1bb
    $recheckHookB = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_RECHECK_MINUTES = '0' }
    $r = FireExternalBlocker -Cwd $ext1b -Classification 'runner-unavailable' -Reason 'no hosted runner picked up the job for over an hour'
    Check 'records an exception for ext1b under an infra-consistent state' ($r.Exit -eq 0) $r.Err
    Set-Mock -RunJson '[{"databaseId":91,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha1bb
    $r = Fire -HookPath $recheckHookB -Cwd $ext1b -EventName 'Stop'
    Check 'CI changing to a genuine failure on recheck invalidates the exception and blocks normally' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # Throttled re-check that cannot query gh at all -> keep tolerating the
    # existing, already-evidenced exception (never invent a new one).
    $ext1c = New-GitRepo 'ext1c'
    $extSha1c = Get-HeadSha $ext1c
    Set-Mock -RunJson '[{"databaseId":92,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $extSha1c
    $recheckHookC = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_RECHECK_MINUTES = '0' }
    $r = FireExternalBlocker -Cwd $ext1c -Classification 'external-service-outage' -Reason 'the external status-check service used by CI is down'
    Check 'records an exception for ext1c' ($r.Exit -eq 0) $r.Err
    Set-Mock -AuthExit 1
    $r = Fire -HookPath $recheckHookC -Cwd $ext1c -EventName 'Stop'
    Check 'a recheck that cannot query gh keeps tolerating the existing exception (with the notice)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out

    # A NEW pushed commit invalidates the old exception (also proves a wrong SHA cannot reuse it).
    Set-Mock -RunJson '[{"databaseId":81,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $extSha1
    Set-Content (Join-Path $ext1 'file.txt') 'v2'
    & git -C $ext1 add .
    & git -C $ext1 commit -q -m c2
    $extSha1d = Get-HeadSha $ext1
    & git -C $ext1 update-ref refs/remotes/origin/main $extSha1d
    Set-Mock -RunJson '[{"databaseId":82,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha1d
    $r = Fire -HookPath $CiHook -Cwd $ext1 -EventName 'Stop'
    Check 'a new pushed commit resets the state - the old exception does not carry over' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # Wrong repository cannot reuse an exception recorded for a different
    # resolved repository slug.
    $ext2 = New-GitRepo 'ext2'
    $extSha2 = Get-HeadSha $ext2
    Set-Mock -RunJson '[{"databaseId":83,"name":"CI","workflowName":"CI","status":"completed","conclusion":"action_required"}]' -ExpectedSha $extSha2
    $r = FireExternalBlocker -Cwd $ext2 -Classification 'runner-unavailable' -Reason 'no hosted runner available for this org'
    Check 'records an exception for ext2''s own repository' ($r.Exit -eq 0) $r.Err
    & git -C $ext2 remote set-url origin 'https://github.com/testowner/testrepo-ext2-renamed.git'
    Set-Mock -RunJson '[{"databaseId":84,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha2
    $r = Fire -HookPath $CiHook -Cwd $ext2 -EventName 'Stop'
    Check 'a different resolved repository cannot reuse a prior exception' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # Expired/stale exception is rejected: TTL=0 means the very next check
    # already treats it as expired and falls back to normal (blocking) evaluation.
    $ext3 = New-GitRepo 'ext3'
    $extSha3 = Get-HeadSha $ext3
    Set-Mock -RunJson '[{"databaseId":85,"name":"CI","workflowName":"CI","status":"completed","conclusion":"timed_out"}]' -ExpectedSha $extSha3
    $r = FireExternalBlocker -Cwd $ext3 -Classification 'permission-failure' -Reason 'org disabled Actions for this repo temporarily'
    Check 'records an exception for ext3' ($r.Exit -eq 0) $r.Err
    $shortTtlHook = New-ConfiguredCiHookCopy @{ EXTERNAL_BLOCKER_TTL_MINUTES = '0' }
    Set-Mock -RunJson '[{"databaseId":86,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $extSha3
    $r = Fire -HookPath $shortTtlHook -Cwd $ext3 -EventName 'Stop'
    Check 'expired exception is rejected - falls back to normal (blocking) evaluation' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # stop_hook_active still prevents recursion, even with a live exception on file.
    $ext4 = New-GitRepo 'ext4'
    $extSha4 = Get-HeadSha $ext4
    Set-Mock -RunJson '[{"databaseId":87,"name":"CI","workflowName":"CI","status":"completed","conclusion":"stale"}]' -ExpectedSha $extSha4
    $r = FireExternalBlocker -Cwd $ext4 -Classification 'manual-approval-required' -Reason 'awaiting a required environment approval the agent cannot grant'
    Check 'records an exception for ext4' ($r.Exit -eq 0) $r.Err
    $r = Fire -HookPath $CiHook -Cwd $ext4 -EventName 'Stop' -Extra @{ stop_hook_active = $true }
    Check 'stop_hook_active still short-circuits before any exception/gh logic' ($r.Out -eq '') $r.Out

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
    Check 'complete baseline -> silent' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check 'Dependabot directories list covers multiple package roots' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check 'flow-style trigger array (on: [push, pull_request]) is recognized' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

    # Quoted "on": key with block-style triggers underneath.
    $quotedOn = New-GitRepo 'quotedon'
    Set-Content (Join-Path $quotedOn 'package.json') '{}'
    New-Item -ItemType Directory -Path (Join-Path $quotedOn '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $quotedOn '.github\workflows\ci.yml') "`"on`":`n  push:`n  pull_request:`njobs:`n  test:`n    steps:`n      - run: npm test"
    Set-Content (Join-Path $quotedOn '.github\dependabot.yml') "version: 2`nupdates:`n  - package-ecosystem: npm`n    directory: /`n  - package-ecosystem: github-actions`n    directory: /"
    $r = Fire -HookPath $BaselineHook -Cwd $quotedOn
    Check 'quoted "on" key with block-style triggers is recognized' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check 'multiline run: | block with validation commands is recognized' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check 'a workflow_call reusable workflow CALLED by a directly-triggered local workflow counts as CI' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check "single-quoted 'on' key with block-style triggers is recognized" ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check '7.1 a real validation command after a comment line IS counted as CI' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
    Check '7.2 a direct-child push: (with nested branches:) is still a trigger; adequate baseline is silent' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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
        Set-Mock -PrJson $prJson
        $r = Fire -HookPath $DependabotHook -Cwd $ps51 -Exe 'powershell.exe'
        Check 'DependabotCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'DEPENDABOT CHECK')
        $r = Fire -HookPath $BaselineHook -Cwd $ps51 -Exe 'powershell.exe'
        Check 'GithubBaselineCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'GITHUB BASELINE CHECK')
        $ps51ci = New-GitRepo 'ps51ci'
        $ps51ciSha = Get-HeadSha $ps51ci
        Set-Mock -RunJson '[{"databaseId":51,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $ps51ciSha
        $r = Fire -HookPath $CiHook -Cwd $ps51ci -EventName 'Stop' -Exe 'powershell.exe'
        Check 'CiStatusCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match '"decision":"block"')
        Set-Mock -RunJson '[{"databaseId":52,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $ps51ciSha
        $r = FireExternalBlocker -Cwd $ps51ci -Classification 'github-outage' -Reason '5.1 host outage test, status page confirms it' -Exe 'powershell.exe'
        Check '-ReportExternalBlocker under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'EXTERNAL CI blocker')
        $r = Fire -HookPath $CiHook -Cwd $ps51ci -EventName 'Stop' -Exe 'powershell.exe'
        Check 'external-blocker exception honored under 5.1 (non-blocking notice, CI not green)' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN')
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
        Get-ChildItem -LiteralPath $Work -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
        [System.IO.Directory]::Delete($Work, $true)
    }
}

Write-Host ''
$resultColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ('Result: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed') -ForegroundColor $resultColor
exit $script:Fail
