# Offline smoke test for the Ci-Status-Check hook: Stop-event CI verification,
# repository/remote resolution (including mismatched/ambiguous upstreams and
# detached HEAD), and the -ReportExternalBlocker exception path.
#
# The -ReportExternalBlocker exception scenario block is dot-sourced from
# _testcistatuscheckexternal.ps1 (it runs in this script's scope; execution
# order is unchanged).
#
# Fully offline and account-free: git state is built in throwaway local repos
# (remote-tracking refs are simulated with git update-ref - no fetch/push), and
# the GitHub CLI is replaced by a PATH shim (gh.ps1) that serves
# canned JSON from $env:GH_MOCK_DIR. Payloads are delivered through a real
# stdin file handle (see Test-Engine.ps1 for why pipes are not used).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-CiStatusCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$CiHook = Join-Path $HooksRoot 'Ci-Status-Check\Ci-Status-Check.ps1'
if (-not (Test-Path -LiteralPath $CiHook -PathType Leaf)) {
    Write-Host "Hook not found: $CiHook" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 200
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-cistatustest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
if ($a.Count -ge 2 -and $a[0] -eq 'api') {
    $endpoint = [string]$a[1]
    # extract the paginated page number (default 1); "per_page" never matches.
    $page = 1
    if ($endpoint -match '[?&]page=(\d+)') { $page = [int]$Matches[1] }
    # commit check-runs list: repos/<slug>/commits/<sha>/check-runs?per_page=100&page=N
    if ($endpoint -match '/commits/[^/]+/check-runs') {
        $pf = Join-Path $mockDir ('checkruns-page-' + $page + '.json')
        if (Test-Path $pf) { Write-Output (Get-Content $pf -Raw); exit 0 }
        if ($page -eq 1) {
            $f = Join-Path $mockDir 'checkruns.json'
            if (Test-Path $f) { Write-Output (Get-Content $f -Raw); exit 0 }
        }
        Write-Output '{"total_count":0,"check_runs":[]}'; exit 0
    }
    # per-check-run annotations: repos/<slug>/check-runs/<id>/annotations?per_page=100&page=N
    if ($endpoint -match '/check-runs/([^/]+)/annotations') {
        $crid = $Matches[1]
        $perPageErr = Join-Path $mockDir ('annexit-' + $crid + '-page-' + $page + '.txt')
        if (Test-Path $perPageErr) { [Console]::Error.WriteLine('api error'); exit ([int]((Get-Content $perPageErr -Raw).Trim())) }
        $errf = Join-Path $mockDir ('annexit-' + $crid + '.txt')
        if (Test-Path $errf) { [Console]::Error.WriteLine('api error'); exit ([int]((Get-Content $errf -Raw).Trim())) }
        $genErr = Join-Path $mockDir 'annexit.txt'
        if (Test-Path $genErr) { [Console]::Error.WriteLine('api error'); exit ([int]((Get-Content $genErr -Raw).Trim())) }
        $pf = Join-Path $mockDir ('annotations-' + $crid + '-page-' + $page + '.json')
        if (Test-Path $pf) { Write-Output (Get-Content $pf -Raw); exit 0 }
        if ($page -eq 1) {
            $f = Join-Path $mockDir ('annotations-' + $crid + '.json')
            if (Test-Path $f) { Write-Output (Get-Content $f -Raw); exit 0 }
        }
        Write-Output '[]'; exit 0
    }
    exit 1
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
    # $CheckRunsJson: single-page JSON body for repos/.../commits/<sha>/check-runs
    #   (served for page 1; used when total_count == the whole set fits one page).
    # $CheckRunPages: hashtable of page number -> check-runs JSON body, for the
    #   PAGINATED check-runs endpoint (e.g. @{ '1' = ...; '2' = ... }). A page with
    #   no entry falls back to the empty {"total_count":0,"check_runs":[]} body, so
    #   a total_count that is never reached exercises the truncation fail-closed.
    # $Annotations: hashtable of check_run id -> annotations JSON array string
    #   (served for annotation page 1 of that id).
    # $AnnotationPages: hashtable of '<id>-<page>' -> annotations JSON array, for
    #   paginated annotation bodies (e.g. @{ '241-1' = ...; '241-2' = ... }).
    # $AnnotationPageExits: hashtable of '<id>-<page>' -> exit code, to make one
    #   annotation page query error (fail-closed mid-pagination).
    # $AnnotationsExitAll: when > 0, every annotations query errors with that code
    #   (used to prove the billing detector fails CLOSED on a query error).
    param([int]$AuthExit = 0, [string]$PrJson = '', [int]$PrExit = -1, [string]$RunJson = '', [string]$ExpectedSha = '',
        [string]$CheckRunsJson = '', [hashtable]$CheckRunPages = $null, [hashtable]$Annotations = $null,
        [hashtable]$AnnotationPages = $null, [hashtable]$AnnotationPageExits = $null, [int]$AnnotationsExitAll = -1)
    Remove-Item (Join-Path $MockDir '*') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $MockDir 'auth_exit.txt') $AuthExit
    if ($PrJson -ne '') { Set-Content (Join-Path $MockDir 'pr_list.json') $PrJson -Encoding utf8 }
    if ($PrExit -ge 0) { Set-Content (Join-Path $MockDir 'pr_exit.txt') $PrExit }
    if ($RunJson -ne '') { Set-Content (Join-Path $MockDir 'run_list.json') $RunJson -Encoding utf8 }
    if ($ExpectedSha -ne '') { Set-Content (Join-Path $MockDir 'expected_sha.txt') $ExpectedSha }
    if ($CheckRunsJson -ne '') { Set-Content (Join-Path $MockDir 'checkruns.json') $CheckRunsJson -Encoding utf8 }
    if ($null -ne $CheckRunPages) {
        foreach ($pg in $CheckRunPages.Keys) { Set-Content (Join-Path $MockDir ('checkruns-page-' + $pg + '.json')) $CheckRunPages[$pg] -Encoding utf8 }
    }
    if ($null -ne $Annotations) {
        foreach ($id in $Annotations.Keys) { Set-Content (Join-Path $MockDir ('annotations-' + $id + '.json')) $Annotations[$id] -Encoding utf8 }
    }
    if ($null -ne $AnnotationPages) {
        foreach ($k in $AnnotationPages.Keys) {
            $i = ([string]$k).LastIndexOf('-'); $id = ([string]$k).Substring(0, $i); $pg = ([string]$k).Substring($i + 1)
            Set-Content (Join-Path $MockDir ('annotations-' + $id + '-page-' + $pg + '.json')) $AnnotationPages[$k] -Encoding utf8
        }
    }
    if ($null -ne $AnnotationPageExits) {
        foreach ($k in $AnnotationPageExits.Keys) {
            $i = ([string]$k).LastIndexOf('-'); $id = ([string]$k).Substring(0, $i); $pg = ([string]$k).Substring($i + 1)
            Set-Content (Join-Path $MockDir ('annexit-' + $id + '-page-' + $pg + '.txt')) $AnnotationPageExits[$k]
        }
    }
    if ($AnnotationsExitAll -ge 0) { Set-Content (Join-Path $MockDir 'annexit.txt') $AnnotationsExitAll }
}

# GitHub's exact billing annotation, plus a canned check-runs list builder so the
# billing tests read like the real API. A billing block annotates EVERY failing
# check-run identically.
$script:BillingMessage = "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings"
function New-CheckRunsJson {
    param([hashtable[]]$Runs)   # each: @{ id = '1'; conclusion = 'failure' }
    $items = @($Runs | ForEach-Object { '{"id":' + $_.id + ',"conclusion":"' + $_.conclusion + '"}' })
    return '{"total_count":' + $Runs.Count + ',"check_runs":[' + ($items -join ',') + ']}'
}
# Like New-CheckRunsJson but with an EXPLICIT total_count, so a page can carry a
# slice of a larger set (multi-page) or a deliberately-unreachable total_count
# (truncation / over-bound fail-closed tests).
function New-CheckRunsPageJson {
    param([int]$TotalCount, [hashtable[]]$Runs)
    $items = @($Runs | ForEach-Object { '{"id":' + $_.id + ',"conclusion":"' + $_.conclusion + '"}' })
    return '{"total_count":' + $TotalCount + ',"check_runs":[' + ($items -join ',') + ']}'
}
function New-BillingAnnotations {
    return '[{"annotation_level":"failure","path":".github","message":' + ($script:BillingMessage | ConvertTo-Json) + '}]'
}
function New-RealFailureAnnotations {
    return '[{"annotation_level":"failure","path":"scripts/x.ps1","message":"Process completed with exit code 1."}]'
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

# Invokes Ci-Status-Check.ps1 -ReportExternalBlocker as a direct CLI action
# (not stdin-driven) with $Cwd as the process's actual working directory,
# mirroring how the agent would run it from inside the target repo.
function FireExternalBlocker {
    param([string]$Cwd, [string]$Classification = '', [string]$Reason = '', [string]$Exe = '', [string]$HookPath = $CiHook, [string]$Client = 'codex')
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
        $claudeProjectDir = if ($Client -eq 'claude') { $Cwd } else { '' }
        $startArgs.Environment = @{ PATH = $env:PATH; GH_MOCK_DIR = $env:GH_MOCK_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; CLAUDE_PROJECT_DIR = $claudeProjectDir }
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
    Write-Host '--- CiStatusCheck ---' -ForegroundColor Cyan
    $plainDir = Join-Path $Work 'plain'; New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
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

    # ---- account billing / payment block ----
    # GitHub reports every run as conclusion=failure when Actions cannot start
    # for billing, yet its OWN check-run annotation proves no job ran. This must
    # be auto-detected (never a hard block), never confused with a real failure,
    # and always fail CLOSED when it cannot be proven.
    Write-Host '--- CiStatusCheck: account billing block (annotation-proven, auto-recorded) ---' -ForegroundColor Cyan
    $billStateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'

    # every failing check-run carries the billing annotation -> auto-recorded external blocker
    $ciBill = New-GitRepo 'ci-bill'
    $shaBill = Get-HeadSha $ciBill
    Set-Mock -RunJson '[{"databaseId":81,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"},{"databaseId":82,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaBill `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '81'; conclusion = 'failure' }, @{id = '82'; conclusion = 'failure' })) `
        -Annotations @{ '81' = (New-BillingAnnotations); '82' = (New-BillingAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop'
    Check 'billing block -> NOT a hard block' ($r.Out -notmatch '"decision":"block"') $r.Out
    Check 'billing block -> non-blocking CI-not-green context, classified account-billing' ($r.Out -match 'CI NOT VERIFIED GREEN' -and $r.Out -match 'account-billing') $r.Out
    Check 'billing block -> names the payment/spending-limit cause' ($r.Out -match 'payments have failed' -or $r.Out -match 'spending-limit') $r.Out
    $billStateFile = @(Get-ChildItem -LiteralPath $billStateDir -Filter 'CiStatusCheck-External-*.txt' -ErrorAction SilentlyContinue)
    $billRecorded = $false
    foreach ($f in $billStateFile) { if ([System.IO.File]::ReadAllText($f.FullName) -match 'account-billing') { $billRecorded = $true } }
    Check 'billing block -> an external blocker was auto-recorded as account-billing' $billRecorded
    # the recorded exception persists on the very next stop (throttled recheck), still non-blocking
    $r = Fire -HookPath $CiHook -Cwd $ciBill -EventName 'Stop'
    Check 'billing block -> recorded exception persists on the next stop (no re-block)' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN') $r.Out
    # same case surfaces correctly in the Claude client shape too
    $ciBillC = New-GitRepo 'ci-bill-claude'
    $shaBillC = Get-HeadSha $ciBillC
    Set-Mock -RunJson '[{"databaseId":83,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaBillC `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '83'; conclusion = 'failure' })) `
        -Annotations @{ '83' = (New-BillingAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciBillC -EventName 'Stop' -Client 'claude'
    Check 'billing block (Claude) -> model-visible additionalContext, not a block' ($r.Out -match 'additionalContext' -and $r.Out -match 'account-billing' -and $r.Out -notmatch '"decision":"block"') $r.Out

    # a genuine failure (check-run present, annotation is a real error) still hard-blocks
    $ciReal = New-GitRepo 'ci-real'
    $shaReal = Get-HeadSha $ciReal
    Set-Mock -RunJson '[{"databaseId":91,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaReal `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '91'; conclusion = 'failure' })) `
        -Annotations @{ '91' = (New-RealFailureAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciReal -EventName 'Stop'
    Check 'real failure (non-billing annotation) still hard-blocks' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # mixed: one failing check-run billing, one a real failure -> fail CLOSED (hard block)
    $ciMixed = New-GitRepo 'ci-mixed'
    $shaMixed = Get-HeadSha $ciMixed
    Set-Mock -RunJson '[{"databaseId":101,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"},{"databaseId":102,"name":"Lint","workflowName":"Lint","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaMixed `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '101'; conclusion = 'failure' }, @{id = '102'; conclusion = 'failure' })) `
        -Annotations @{ '101' = (New-BillingAnnotations); '102' = (New-RealFailureAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciMixed -EventName 'Stop'
    Check 'one failing run without the billing annotation -> hard block (fail closed)' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # the annotations query itself errors -> billing not claimed, hard block (fail closed)
    $ciAnnErr = New-GitRepo 'ci-annerr'
    $shaAnnErr = Get-HeadSha $ciAnnErr
    Set-Mock -RunJson '[{"databaseId":111,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaAnnErr `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '111'; conclusion = 'failure' })) `
        -AnnotationsExitAll 1
    $r = Fire -HookPath $CiHook -Cwd $ciAnnErr -EventName 'Stop'
    Check 'annotations query error -> billing not claimed, hard block (fail closed)' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # ---- account billing block: pagination safety (check-runs + annotations) ----
    # A commit can have MORE check-runs than one page, so billing is only claimed
    # after EVERY page is fetched (count == total_count) and EVERY failing run is
    # billing-annotated. Anything unverifiable within a strict page bound fails
    # CLOSED (hard block), never billing.
    Write-Host '--- CiStatusCheck: account billing block (pagination-safe) ---' -ForegroundColor Cyan

    # (A) two full pages, all failing runs billing-annotated -> billing only after
    # the complete set (count reaches total_count) is verified.
    $ciBillMP = New-GitRepo 'ci-bill-mp'
    $shaBillMP = Get-HeadSha $ciBillMP
    Set-Mock -RunJson '[{"databaseId":201,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaBillMP `
        -CheckRunPages @{
            '1' = (New-CheckRunsPageJson -TotalCount 4 -Runs @(@{id = '201'; conclusion = 'failure' }, @{id = '202'; conclusion = 'failure' }))
            '2' = (New-CheckRunsPageJson -TotalCount 4 -Runs @(@{id = '203'; conclusion = 'failure' }, @{id = '204'; conclusion = 'failure' }))
        } `
        -Annotations @{ '201' = (New-BillingAnnotations); '202' = (New-BillingAnnotations); '203' = (New-BillingAnnotations); '204' = (New-BillingAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciBillMP -EventName 'Stop'
    Check 'multi-page all-billing -> billing classification after full verification' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'CI NOT VERIFIED GREEN' -and $r.Out -match 'account-billing') $r.Out

    # (B) a real failure on check-run PAGE 2 (only page 1 was billing) -> the
    # complete set contains an unannotated failure, so billing is refused (block).
    $ciMPreal = New-GitRepo 'ci-mp-realfail'
    $shaMPreal = Get-HeadSha $ciMPreal
    Set-Mock -RunJson '[{"databaseId":211,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaMPreal `
        -CheckRunPages @{
            '1' = (New-CheckRunsPageJson -TotalCount 3 -Runs @(@{id = '211'; conclusion = 'failure' }, @{id = '212'; conclusion = 'failure' }))
            '2' = (New-CheckRunsPageJson -TotalCount 3 -Runs @(@{id = '213'; conclusion = 'failure' }))
        } `
        -Annotations @{ '211' = (New-BillingAnnotations); '212' = (New-BillingAnnotations); '213' = (New-RealFailureAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciMPreal -EventName 'Stop'
    Check 'a real failure on check-run page 2 prevents billing (hard block, fail closed)' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # (C) total_count above the strict bound (2000) -> cannot fully verify -> fail
    # closed BEFORE any annotation is trusted, even though the delivered runs are
    # billing-annotated.
    $ciBound = New-GitRepo 'ci-bound'
    $shaBound = Get-HeadSha $ciBound
    Set-Mock -RunJson '[{"databaseId":221,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaBound `
        -CheckRunPages @{ '1' = (New-CheckRunsPageJson -TotalCount 2001 -Runs @(@{id = '221'; conclusion = 'failure' })) } `
        -Annotations @{ '221' = (New-BillingAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciBound -EventName 'Stop'
    Check 'total_count above the safety bound -> fail closed (hard block)' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # (D) total_count is 5 but only 2 runs are ever delivered (page 2 empty) ->
    # fetched count never reaches total_count -> truncation -> fail closed.
    $ciTrunc = New-GitRepo 'ci-trunc'
    $shaTrunc = Get-HeadSha $ciTrunc
    Set-Mock -RunJson '[{"databaseId":231,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaTrunc `
        -CheckRunPages @{ '1' = (New-CheckRunsPageJson -TotalCount 5 -Runs @(@{id = '231'; conclusion = 'failure' }, @{id = '232'; conclusion = 'failure' })) } `
        -Annotations @{ '231' = (New-BillingAnnotations); '232' = (New-BillingAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciTrunc -EventName 'Stop'
    Check 'fetched check-run count below total_count -> fail closed (hard block)' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out

    # (E1) the billing annotation is only on annotation PAGE 2 (page 1 is a
    # different, non-billing annotation) -> the paginator must read page 2 to find
    # it and still classify billing. Proves annotation pagination is not a no-op.
    $ciAnnP2 = New-GitRepo 'ci-annp2'
    $shaAnnP2 = Get-HeadSha $ciAnnP2
    Set-Mock -RunJson '[{"databaseId":241,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaAnnP2 `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '241'; conclusion = 'failure' })) `
        -AnnotationPages @{ '241-1' = (New-RealFailureAnnotations); '241-2' = (New-BillingAnnotations) }
    $r = Fire -HookPath $CiHook -Cwd $ciAnnP2 -EventName 'Stop'
    Check 'billing annotation found on annotation page 2 -> billing classification' ($r.Out -notmatch '"decision":"block"' -and $r.Out -match 'account-billing') $r.Out

    # (E2) annotation pagination continues past page 1 (page 1 non-billing) and
    # the page-2 query ERRORS -> fail closed (hard block). Also asserts page 2 was
    # actually queried, so this cannot pass with a page-1-only reader.
    $ciAnnErr2 = New-GitRepo 'ci-annerr2'
    $shaAnnErr2 = Get-HeadSha $ciAnnErr2
    Set-Mock -RunJson '[{"databaseId":251,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' `
        -ExpectedSha $shaAnnErr2 `
        -CheckRunsJson (New-CheckRunsJson @(@{id = '251'; conclusion = 'failure' })) `
        -AnnotationPages @{ '251-1' = (New-RealFailureAnnotations) } `
        -AnnotationPageExits @{ '251-2' = 1 }
    $r = Fire -HookPath $CiHook -Cwd $ciAnnErr2 -EventName 'Stop'
    Check 'annotation pagination error on page 2 -> fail closed (hard block)' ($r.Out -match '"decision":"block"' -and $r.Out -match 'FAILED') $r.Out
    $annCalls = [System.IO.File]::ReadAllText((Join-Path $MockDir 'calls.txt'))
    Check 'annotation pagination actually queried page 2 before failing closed' ($annCalls -match 'check-runs/251/annotations\?per_page=100&page=2') $annCalls

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

    # ---- B5 regression: `gh run list` returning BLANK or literal `null` (exit
    # 0) must never be silently treated as a verified/all-success commit.
    # ConvertFrom-Json turns both into $null (no throw, so the catch path is
    # never hit); piping that single $null through ForEach-Object previously
    # produced a 1-element array containing $null, so $runs.Count was 1 (not
    # 0) and every per-run bucket stayed empty, making $allSuccess true on zero
    # real data. Both variants must fall to the same "no runs registered yet"
    # pending block as a real empty result set with workflows configured -
    # never a silent exit 0. A real `'[]'` response (no runs.json override,
    # the ci5/ci6 pair above) must keep behaving exactly as before.
    $ci5blank = New-GitRepo 'ci5blank'
    New-Item -ItemType Directory -Path (Join-Path $ci5blank '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $ci5blank '.github\workflows\ci.yml') 'name: CI'
    Set-Mock -ExpectedSha (Get-HeadSha $ci5blank)
    Set-Content -Path (Join-Path $MockDir 'run_list.json') -Value '' -NoNewline -Encoding utf8
    $r = Fire -HookPath $CiHook -Cwd $ci5blank -EventName 'Stop'
    Check 'B5: blank `gh run list` stdout -> pending block, never silently verified' ($r.Out -match '"decision":"block"' -and $r.Out -match 'no runs are registered yet') $r.Out

    $ci5null = New-GitRepo 'ci5null'
    New-Item -ItemType Directory -Path (Join-Path $ci5null '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $ci5null '.github\workflows\ci.yml') 'name: CI'
    Set-Mock -RunJson 'null' -ExpectedSha (Get-HeadSha $ci5null)
    $r = Fire -HookPath $CiHook -Cwd $ci5null -EventName 'Stop'
    Check 'B5: literal `null` `gh run list` stdout -> pending block, never silently verified' ($r.Out -match '"decision":"block"' -and $r.Out -match 'no runs are registered yet') $r.Out

    # control: a normal successful run set on the same workflows-configured
    # shape still verifies silently (the Where-Object null filter added for B5
    # never touches a real run object).
    $ci5ok = New-GitRepo 'ci5ok'
    New-Item -ItemType Directory -Path (Join-Path $ci5ok '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $ci5ok '.github\workflows\ci.yml') 'name: CI'
    Set-Mock -RunJson '[{"databaseId":95,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha (Get-HeadSha $ci5ok)
    $r = Fire -HookPath $CiHook -Cwd $ci5ok -EventName 'Stop'
    Check 'B5 control: a real successful run set still verifies silently' ([string]::IsNullOrWhiteSpace([string]$r.Out)) ([string]$r.Out)

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

    # -ReportExternalBlocker exception scenarios (recording, notices, invalidation).
    . (Join-Path $PSScriptRoot '_testcistatuscheckexternal.ps1')

    # =====================================================================
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
        $ps51ci = New-GitRepo 'ps51ci'
        $ps51ciSha = Get-HeadSha $ps51ci
        Set-Mock -RunJson '[{"databaseId":51,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $ps51ciSha
        $r = Fire -HookPath $CiHook -Cwd $ps51ci -EventName 'Stop' -Exe 'powershell.exe'
        Check 'CiStatusCheck under 5.1' ($r.Exit -eq 0 -and $r.Out -match '"decision":"block"')
        Set-Mock -RunJson '[{"databaseId":52,"name":"CI","workflowName":"CI","status":"completed","conclusion":"cancelled"}]' -ExpectedSha $ps51ciSha
        $r = FireExternalBlocker -Cwd $ps51ci -Classification 'github-outage' -Reason '5.1 host outage test, status page confirms it' -Exe 'powershell.exe'
        Check '-ReportExternalBlocker under 5.1' ($r.Exit -eq 0 -and $r.Out -match 'EXTERNAL CI blocker')
        $r = Fire -HookPath $CiHook -Cwd $ps51ci -EventName 'Stop' -Exe 'powershell.exe' -Client 'codex'
        Check 'external-blocker exception honored under 5.1 (Codex: non-blocking systemMessage, CI not green)' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision":"block"' -and $r.Out -match '"systemMessage"' -and $r.Out -match 'CI NOT VERIFIED GREEN')
        $r = Fire -HookPath $CiHook -Cwd $ps51ci -EventName 'Stop' -Exe 'powershell.exe' -Client 'claude'
        Check 'external-blocker exception honored under 5.1 (Claude: non-blocking additionalContext, CI not green)' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision":"block"' -and $r.Out -match 'additionalContext' -and $r.Out -match 'CI NOT VERIFIED GREEN')
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
