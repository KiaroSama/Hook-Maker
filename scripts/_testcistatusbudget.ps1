# Test-CiStatusCheck.ps1 scenario block: ONE GitHub budget per Stop.
# Sequential gh calls used to get 20 s each inside a 60 s hook; three slow ones
# and the client killed the hook, which then said nothing at all. Every gh call
# now shares GH_BUDGET_SECONDS and `gh auth status` is asked once per session.
#
# Dot-sourced by Test-CiStatusCheck.ps1 into the caller's scope (uses its Fire,
# Check, Set-Mock, New-GitRepo, $ShimDir, $MockDir, $ghMock) - not a standalone
# suite.

    Write-Host '--- one GitHub budget per Stop; auth asked once per session ---' -ForegroundColor Cyan
    $budgetSibling = Join-Path (Split-Path -Parent $CiHook) '_ghbudget.ps1'
    function New-BudgetHookCopy {
        param([hashtable]$EnvOverrides)
        $copy = New-ConfiguredCiHookCopy -EnvOverrides $EnvOverrides
        Copy-Item -LiteralPath $budgetSibling -Destination (Join-Path (Split-Path -Parent $copy) '_ghbudget.ps1')
        return $copy
    }
    function Get-GhCallCount {
        param([string]$Pattern)
        $log = Join-Path $MockDir 'calls.txt'
        if (-not (Test-Path -LiteralPath $log)) { return 0 }
        return @(Get-Content -LiteralPath $log | Where-Object { $_ -like $Pattern }).Count
    }

    # A pending run with no cooldown re-queries on every Stop, so the auth count
    # below is the only thing that can differ between the Stops.
    $authRepo = New-GitRepo 'ci-budget-auth'
    $authHook = New-BudgetHookCopy @{ PENDING_COOLDOWN_MINUTES = '0' }
    Set-Mock -RunJson '[{"databaseId":301,"name":"CI","workflowName":"CI","status":"in_progress","conclusion":null}]' -ExpectedSha (Get-HeadSha $authRepo)
    $null = Fire -HookPath $authHook -Cwd $authRepo -EventName 'Stop' -Extra @{ session_id = 'budget-a' }
    $null = Fire -HookPath $authHook -Cwd $authRepo -EventName 'Stop' -Extra @{ session_id = 'budget-a' }
    Check 'budget: two Stops in one session ask gh auth status once' ((Get-GhCallCount 'auth|status*') -eq 1 -and (Get-GhCallCount 'api|repos/*/actions/runs?head_sha=*') -eq 2) (
        'auth=' + (Get-GhCallCount 'auth|status*') + ' runlist=' + (Get-GhCallCount 'api|repos/*/actions/runs?head_sha=*'))
    $null = Fire -HookPath $authHook -Cwd $authRepo -EventName 'Stop' -Extra @{ session_id = 'budget-b' }
    Check 'budget: a new session asks again' ((Get-GhCallCount 'auth|status*') -eq 2) ('auth=' + (Get-GhCallCount 'auth|status*'))

    # A slow GitHub: the shim sleeps before answering, far past the budget.
    $slowShim = '$sleepFile = Join-Path $env:GH_MOCK_DIR ''sleep.txt''' + "`r`n" +
        'if (Test-Path -LiteralPath $sleepFile) { $parts = (Get-Content -LiteralPath $sleepFile -Raw).Trim().Split(''|''); if (@($args).Count -ge 1 -and ((@($args) -join '' '') -like $parts[0])) { Start-Sleep -Seconds ([int]$parts[1]) } }' + "`r`n" + $ghMock
    $shimPath = Join-Path $ShimDir 'gh.ps1'
    try {
        [System.IO.File]::WriteAllText($shimPath, $slowShim)
        $slowRepo = New-GitRepo 'ci-budget-slow'
        $slowSha = Get-HeadSha $slowRepo
        $slowHook = New-BudgetHookCopy @{ GH_BUDGET_SECONDS = '8' }
        Set-Mock -RunJson '[{"databaseId":302,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $slowSha
        Set-Content (Join-Path $MockDir 'sleep.txt') 'api repos/*/actions/runs?head_sha=*|30'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Fire -HookPath $slowHook -Cwd $slowRepo -EventName 'Stop' -Extra @{ session_id = 'budget-slow' }
        $watch.Stop()
        Check 'budget: a slow GitHub never outlives the budget (8 s + start-up grace)' ($watch.Elapsed.TotalSeconds -lt 16 -and $r.Exit -eq 0) (
            ('{0:N1} s, exit {1}' -f $watch.Elapsed.TotalSeconds, $r.Exit))
        Check 'budget: exhaustion is reported as not verified, naming the commit' (
            $r.Out -match 'systemMessage' -and $r.Out -match 'UNVERIFIED' -and $r.Out -match 'budget.*exhausted' -and $r.Out -match 'NOT green' -and $r.Out -match $slowSha.Substring(0, 7)) $r.Out
        Check 'budget: exhaustion never blocks' ($r.Out -notmatch '"decision":"block"') $r.Out
        $slowState = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'HookMaker\state') -Filter 'CiStatusCheck-*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'CiStatusCheck-External-*' -and $_.Name -notlike 'CiStatusCheck-Notice-*' } |
            Where-Object { ([System.IO.File]::ReadAllText($_.FullName)) -match [regex]::Escape($slowSha) })
        Check 'budget: exhaustion writes no verified state for the commit' ($slowState.Count -eq 0) (($slowState | ForEach-Object { $_.Name }) -join ', ')

        # Paginated check-run queries stop at the same deadline.
        $pageRepo = New-GitRepo 'ci-budget-pages'
        $pageHook = New-BudgetHookCopy @{ GH_BUDGET_SECONDS = '12' }
        Set-Mock -RunJson '[{"databaseId":303,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha (Get-HeadSha $pageRepo) `
            -CheckRunPages @{ '1' = (New-CheckRunsPageJson -TotalCount 500 -Runs @(@{ id = '1'; conclusion = 'failure' })) }
        Set-Content (Join-Path $MockDir 'sleep.txt') 'api repos/*|5'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Fire -HookPath $pageHook -Cwd $pageRepo -EventName 'Stop' -Extra @{ session_id = 'budget-pages' }
        $watch.Stop()
        Check 'budget: paginated queries stop at the deadline (12 s + start-up grace)' ($watch.Elapsed.TotalSeconds -lt 20 -and $r.Exit -eq 0) (
            ('{0:N1} s, exit {1}' -f $watch.Elapsed.TotalSeconds, $r.Exit))
        Check 'budget: a failed run whose billing check ran out of time still fails closed, never green' (
            $r.Out -notmatch 'CI UNVERIFIED' -and $r.Out -ne '') $r.Out
    }
    finally {
        [System.IO.File]::WriteAllText($shimPath, $ghMock)
        Remove-Item -LiteralPath (Join-Path $MockDir 'sleep.txt') -Force -ErrorAction SilentlyContinue
    }

    # An installed runtime copied before the sibling existed keeps working.
    $oldRepo = New-GitRepo 'ci-budget-nosibling'
    $oldHook = New-ConfiguredCiHookCopy -EnvOverrides @{ PENDING_COOLDOWN_MINUTES = '3' }
    $oldBudget=Join-Path (Split-Path -Parent $oldHook) '_ghbudget.ps1'
    if(Test-Path -LiteralPath $oldBudget){Remove-Item -LiteralPath $oldBudget -Force}
    $oldSha=Get-HeadSha $oldRepo
    Set-Mock -RunJson '[{"databaseId":304,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha $oldSha
    $r = Fire -HookPath $oldHook -Cwd $oldRepo -EventName 'Stop'
    Check 'budget: missing optional sibling retains execution proof and explicit report/UI gap' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -match 'CI execution verified' -and $r.Out -match 'Reports/UI UNVERIFIED' -and $r.Out -match $oldSha -and $r.Out -notmatch '"decision"' -and (Get-GhCallCount 'api|repos/*/actions/runs?head_sha=*') -eq 1) ([string]$r.Out)
    $failedRepo=New-GitRepo 'ci-budget-nosibling-failed';$failedSha=Get-HeadSha $failedRepo
    $failedChecks='{"total_count":1,"check_runs":[{"id":1,"head_sha":"'+$failedSha+'","status":"completed","conclusion":"failure"}]}'
    Set-Mock -RunJson '[{"databaseId":305,"name":"CI","workflowName":"CI","status":"completed","conclusion":"failure"}]' -ExpectedSha $failedSha -CheckRunsJson $failedChecks -Annotations @{ '1'='[{"annotation_level":"failure","message":"billing/payment"}]' }
    $r=Fire -HookPath $oldHook -Cwd $failedRepo -EventName 'Stop'
    Check 'budget: missing billing reader keeps actual failure advisory, never billing or green' ($r.Exit-eq0-and$r.Err-eq''-and$r.Out-match'"systemMessage"'-and$r.Out-notmatch'"decision"'-and$r.Out-match'FAILED:'-and$r.Out-notmatch'account-billing|CI execution verified'-and(Get-GhCallCount 'api|*/annotations*')-eq0) ([string]$r.Out)
    # Every entry fallback must share ONE deadline, including auth; expiry never
    # launches another command and never becomes a successful zero-result set.
    $entryAst=[Management.Automation.Language.Parser]::ParseFile($oldHook,[ref]$null,[ref]$null)
    $fallback=$entryAst.Find({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.Text-match"Get-Command -Name 'Invoke-GhBounded'"},$true)
    $fallbackText=$fallback.Clauses[0].Item2.Extent.Text
    $fallbackText=$fallbackText.Substring(1,$fallbackText.Length-2)
    foreach($hostExe in @('pwsh','powershell.exe')){
        $probe=Join-Path $Work 'missing-budget-deadline.ps1'
        $probeText="param([string]`$BatchPath)`n. `$BatchPath`n"+@'
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:Calls=0;$script:HookLeft=7
function Invoke-QuietCommand {param($FilePath,$ArgumentList,$TimeoutSeconds) $script:Calls++;if($TimeoutSeconds-lt1-or$TimeoutSeconds-gt$script:HookLeft){throw 'Command exceeds hook remainder'};$global:LASTEXITCODE=0;return 'ok'}
function Get-HookRemainingSeconds {return $script:HookLeft}
'@ + "`n" + $fallbackText + @'
Initialize-GhBudget 8
if((Get-GhRemainingSeconds)-gt7){throw 'Fallback ignores hook deadline'}
$deadline=$script:GhDeadlineUtc
if(-not(Test-GhAuthenticated)-or$script:Calls-ne1-or$script:GhDeadlineUtc-ne$deadline){throw 'Auth is not in original shared budget'}
$script:CiApiScopeKey='fallback-fixture';$base='repos/testowner/testrepo/check-runs/'
foreach($id in 1..32){[void]$script:CiApiBatchState.Seen.Add($base+$id+'/annotations')}
$answer=@(Invoke-GhBounded @('api',($base+'33/annotations')))
if($LASTEXITCODE-eq0-or$answer.Count-ne0-or$script:Calls-ne1-or$script:CiApiBatchState.Seen.Count-ne32){throw 'Fallback bypassed shared endpoint cap'}
$script:CiApiBatchState.Seen.Clear();$script:CiApiBatchState.Bytes=4194304
$answer=@(Invoke-GhBounded @('api',($base+'1/annotations')))
if($LASTEXITCODE-eq0-or$answer.Count-ne0-or$script:Calls-ne1-or-not$script:CiApiBatchState.Exhausted){throw 'Fallback bypassed aggregate byte cap'}
$script:HookLeft=0
$null=Invoke-GhBounded @('api','fixture')
if($script:Calls-ne1-or$LASTEXITCODE-ne124-or-not$script:GhBudgetExhausted-or$script:GhDeadlineUtc-ne$deadline){throw 'Expired budget launched/reset or claimed success'}
Write-Host 'Missing-budget shared deadline controls passed; endpoint=32; aggregateBytes=4194304; launches=1; expiry=124'
'@
        [IO.File]::WriteAllText($probe,$probeText,[Text.UTF8Encoding]::new($false))
        $out=Join-Path $Work ($hostExe+'-missing-budget.out');$err=Join-Path $Work ($hostExe+'-missing-budget.err')
        $process=Start-BoundedProcess -FilePath $hostExe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$probe,'-BatchPath',(Join-Path (Split-Path -Parent $CiHook) '_cibatch.ps1')) -TimeoutMs 10000 -RedirectStandardOutput $out -RedirectStandardError $err
        Check ($hostExe+': missing optional budget retains shared deadline, endpoint/byte caps, bounded auth and no launch after expiry') ($process.ExitCode-eq0-and[IO.File]::ReadAllText($out).Contains('Missing-budget shared deadline controls passed')-and[IO.File]::ReadAllText($err)-eq'') ([IO.File]::ReadAllText($err))
    }
