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
    Check 'budget: two Stops in one session ask gh auth status once' ((Get-GhCallCount 'auth|status*') -eq 1 -and (Get-GhCallCount 'run|list*') -eq 2) (
        'auth=' + (Get-GhCallCount 'auth|status*') + ' runlist=' + (Get-GhCallCount 'run|list*'))
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
        Set-Content (Join-Path $MockDir 'sleep.txt') 'run list*|30'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Fire -HookPath $slowHook -Cwd $slowRepo -EventName 'Stop' -Extra @{ session_id = 'budget-slow' }
        $watch.Stop()
        Check 'budget: a slow GitHub never outlives the budget (8 s + start-up grace)' ($watch.Elapsed.TotalSeconds -lt 16 -and $r.Exit -eq 0) (
            ('{0:N1} s, exit {1}' -f $watch.Elapsed.TotalSeconds, $r.Exit))
        Check 'budget: exhaustion is reported as not verified, naming the commit' (
            $r.Out -match 'systemMessage' -and $r.Out -match 'could not verify' -and $r.Out -match $slowSha.Substring(0, 7)) $r.Out
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
            $r.Out -notmatch 'CI NOT VERIFIED GREEN' -and $r.Out -ne '') $r.Out
    }
    finally {
        [System.IO.File]::WriteAllText($shimPath, $ghMock)
        Remove-Item -LiteralPath (Join-Path $MockDir 'sleep.txt') -Force -ErrorAction SilentlyContinue
    }

    # An installed runtime copied before the sibling existed keeps working.
    $oldRepo = New-GitRepo 'ci-budget-nosibling'
    $oldHook = New-ConfiguredCiHookCopy -EnvOverrides @{ PENDING_COOLDOWN_MINUTES = '3' }
    Set-Mock -RunJson '[{"databaseId":304,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]' -ExpectedSha (Get-HeadSha $oldRepo)
    $r = Fire -HookPath $oldHook -Cwd $oldRepo -EventName 'Stop'
    Check 'budget: without _ghbudget.ps1 a green commit still verifies silently' ($r.Exit -eq 0 -and [string]::IsNullOrWhiteSpace([string]$r.Out) -and (Get-GhCallCount 'run|list*') -eq 1) ([string]$r.Out)
