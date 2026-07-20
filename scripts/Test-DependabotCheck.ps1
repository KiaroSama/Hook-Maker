# Offline smoke test for the Dependabot-Check hook: shared stdin/input
# handling, pending-PR classification (patch/security/major/prerelease/
# grouped), state/fingerprint cooldown, and repository resolution to the
# current upstream.
#
# Fully offline and account-free: git state is built in throwaway local repos
# (remote-tracking refs are simulated with git update-ref - no fetch/push), and
# the GitHub CLI is replaced by a PATH shim (gh.ps1) that serves
# canned JSON from $env:GH_MOCK_DIR. Payloads are delivered through a real
# stdin file handle (see Test-Engine.ps1 for why pipes are not used).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-DependabotCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$DependabotHook = Join-Path $HooksRoot 'Dependabot-Check\Dependabot-Check.ps1'
if (-not (Test-Path -LiteralPath $DependabotHook -PathType Leaf)) {
    Write-Host "Hook not found: $DependabotHook" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 200
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-dependabottest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    # Scope: a PR marked SECURITY is described as classification only (never
    # "confirmed"); it is reviewed now only if directly relevant, explicitly
    # requested, or critically unsafe to defer - otherwise every pending PR,
    # SECURITY-marked or not, is deferred and never forced into or allowed to
    # block/delay the current, unrelated task.
    Check 'a SECURITY-marked PR is described as classification only, not confirmed' ($r.Out -match 'A PR above is marked SECURITY \(by title/label, not independently verified severity\)\.') $r.Out
    Check 'the old "confirmed security update - prioritize" wording is gone' ($r.Out -notmatch 'confirmed security update - prioritize') $r.Out
    Check 'unrelated/non-critical PRs (including SECURITY-marked) are explicitly deferred to a separate task' (
        $r.Out -match 'Do not review, merge, or remediate ANY of these during the current task - including a PR marked SECURITY - unless it is directly relevant to the current task, the user explicitly asked for dependency/security remediation, or reliable evidence shows it is critical enough that continuing the current work is unsafe') $r.Out
    Check 'pending Dependabot PRs are never a reason to block or delay unrelated work' ($r.Out -match 'Pending Dependabot PRs are never a reason to block or delay unrelated work') $r.Out
    Check 'the old "REST of these" wording is gone' ($r.Out -notmatch 'REST of these') $r.Out
    Check 'the old unconditional "review before unrelated work" wording is gone' ($r.Out -notmatch 'Review these BEFORE unrelated work') $r.Out
    Check 'still no auto-merge instruction exists' ($r.Out -notmatch '(?i)automatically merge' -and $r.Out -notmatch '(?i)merge (it|them|these) now')
    Check 'MAJOR and PRERELEASE remain explicitly non-automatic' ($r.Out -match 'never auto-merge MAJOR or PRERELEASE') $r.Out

    # unchanged state -> silent; changed state -> reports again
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'unchanged PR state -> silent (fingerprint cooldown)' ($r.Out -eq '')
    $changed = $prJson.Replace('1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '9999999aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    Set-Mock -PrJson $changed
    $r = Fire -HookPath $DependabotHook -Cwd $repoB
    Check 'changed PR state -> reported again immediately' ($r.Out -match 'DEPENDABOT CHECK')

    # No security PR pending -> the report says so explicitly rather than
    # silently omitting the priority note.
    $repoNoSecurity = New-GitRepo 'dep-no-security'
    $noSecurityPrJson = '[{"number":21,"title":"Bump lodash from 4.17.20 to 4.17.21","author":{"login":"app/dependabot"},"headRefName":"dependabot/npm/lodash","baseRefName":"main","headRefOid":"6666666fffffffffffffffffffffffffffffffff","isDraft":false,"mergeStateStatus":"CLEAN","labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}]'
    Set-Mock -PrJson $noSecurityPrJson
    $r = Fire -HookPath $DependabotHook -Cwd $repoNoSecurity
    Check 'no pending PR is SECURITY -> explicitly says so' ($r.Out -match 'None of these are marked SECURITY') $r.Out

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
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
        $ps51 = New-GitRepo 'ps51repo'
        Set-Content (Join-Path $ps51 'package.json') '{}'
        Set-Mock -PrJson $prJson
        $r = Fire -HookPath $DependabotHook -Cwd $ps51 -Exe 'powershell.exe'
        Check 'DependabotCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'DEPENDABOT CHECK')
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
