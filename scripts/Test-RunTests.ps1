# Offline test suite for the per-suite runner core in scripts\Run-Tests.ps1
# (HM-02). The centre of gravity is the bounded-after-exit + PROVEN cleanup
# guarantee of $invokeSuiteBody: a descendant that inherits the suite's stdout and
# outlives it must NOT hang the runner (the old parameterless WaitForExit did), a
# clean-exit orphan must be killed, a hang must be killed and PROVEN gone (124), an
# unproven cleanup must map to a distinct 126, a clean child exit code must
# propagate exactly, and no process or temp file may leak. The DEGRADED (no Job
# Object) paths are exercised for real by handing the body EMPTY C# so jobReady
# stays $false: a degraded clean-exit orphan must be swept via the pid+StartTime
# walk and reported with the guarded runner's orphanLeak code 125 - never a
# silent pass - while a degraded clean exit without orphans keeps its exact code.
#
# The REAL body is extracted from Run-Tests.ps1 via the AST (never a copy) and run
# against real ping-spawning fixtures inside a BOUNDED child, so a regression that
# reintroduces the unbounded wait shows up as the child overrunning its wall bound
# rather than hanging this suite. The Job Object C# is read from Run-Tests-Guarded.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-RunTests.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RunTests = Join-Path $RepoRoot 'scripts\Run-Tests.ps1'
$Guarded = Join-Path $RepoRoot 'scripts\Run-Tests-Guarded.ps1'
foreach ($required in @($RunTests, $Guarded)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-runteststest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# Every ping pid a fixture records, so cleanup can guarantee none is left alive.
$script:SpawnedPids = New-Object System.Collections.Generic.List[string]

# A PID IS NOT AN IDENTITY. Windows reuses pids aggressively, and the parallel
# matrix spawns thousands of processes across its workers, so a pid this suite
# recorded and then proved dead can belong to something else entirely by the time
# the end-of-suite sweep runs. Asking only "does this pid exist" produced a
# failure in 2 of 7 matrix runs while the guarded runner's own process-tree
# tracker reported leakedProcessIds=[] every single time - the check was wrong,
# not the world. Worse, the finally block taskkills whatever it believes is still
# alive, so a recycled pid meant killing an unrelated process.
#
# Same guard the crash-aware registry lock already uses: a recorded pid whose
# live process has a DIFFERENT start time is not the process we recorded.
$script:SpawnedStartTicks = @{}

function Test-IsRecordedProcess {
    param([int]$Target)
    $live = $null
    try { $live = Get-Process -Id $Target -ErrorAction Stop } catch { return $false }
    $key = [string]$Target
    if (-not $script:SpawnedStartTicks.ContainsKey($key)) { return $true }
    $recorded = [long]$script:SpawnedStartTicks[$key]
    if ($recorded -le 0) { return $true }
    # An unreadable StartTime (a process we no longer have rights to, or one
    # exiting right now) is NOT evidence that our process is still running.
    try { return ([long]$live.StartTime.Ticks -eq $recorded) } catch { return $false }
}

function Test-PidAlive {
    param([string]$ProcId, [int]$MaxWaitSeconds = 0)
    if ([string]::IsNullOrWhiteSpace($ProcId)) { return $false }
    $target = 0
    if (-not [int]::TryParse($ProcId, [ref]$target)) { return $false }
    if ($MaxWaitSeconds -le 0) {
        return (Test-IsRecordedProcess -Target $target)
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWaitSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-IsRecordedProcess -Target $target)) { return $false }
        Start-Sleep -Milliseconds 100
    }
    return $true
}

# The driver: extracts the REAL body + C# and runs it against one suite, writing the
# returned object as JSON. Executed inside a bounded child by Invoke-BodyInChild so
# the body under test can never hang this suite.
$driver = Join-Path $Work 'body-driver.ps1'
Write-Utf8 $driver @'
param([string]$RunTestsPath, [string]$GuardedPath, [string]$SuitePath, [int]$TimeoutSeconds, [string]$ResultPath, [switch]$DegradedJob)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RunTestsPath, [ref]$null, [ref]$null)
$assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$invokeSuiteBody' }, $true)
if ($null -eq $assign) { throw 'could not locate $invokeSuiteBody in Run-Tests.ps1' }
$strAst = $assign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
$bodyText = $strAst.Value
$guardText = [System.IO.File]::ReadAllText($GuardedPath)
$csStart = $guardText.IndexOf('using System;')
$csEnd = $guardText.IndexOf("'@", $csStart)
$cs = $guardText.Substring($csStart, $csEnd - $csStart)
# Degraded mode: hand the body NO C# at all. This driver is a fresh pwsh child,
# so HookMaker.JobNative is not AppDomain-loaded, the body's Add-Type is skipped,
# jobReady stays $false, and the body runs its no-Job-Object paths for real.
if ($DegradedJob) { $cs = '' }
$body = [scriptblock]::Create($bodyText)
$exe = (Get-Process -Id $PID).Path
$result = & $body $SuitePath $exe $TimeoutSeconds $cs
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@

# Runs the extracted body against $SuitePath in a bounded child. The child's TEMP is
# an isolated empty dir, so any GetTempFileName the body forgot to remove is a
# provable leak (TempLeftover). Bounded is $false when the body overran the outer
# wall - i.e. it was NOT bounded (the regression signature).
function Invoke-BodyInChild {
    param(
        [string]$SuitePath,
        [int]$TimeoutSeconds,
        [int]$OuterWallSeconds,
        # No Job Object: the driver passes empty C# so jobReady stays $false.
        [switch]$Degraded,
        # Run a DIFFERENT Run-Tests.ps1 (e.g. a materialized pre-fix HEAD copy for
        # a red-proof) instead of the working-tree file.
        [string]$BodySource = ''
    )
    $resultPath = Join-Path $Work ('bodyresult-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $tmpDir = Join-Path $Work ('bodytmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $bodyFile = $(if ([string]::IsNullOrWhiteSpace($BodySource)) { $RunTests } else { $BodySource })
    $exe = (Get-Process -Id $PID).Path
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $argList = @('-NoLogo', '-NoProfile', '-File', $driver, '-RunTestsPath', $bodyFile, '-GuardedPath', $Guarded, '-SuitePath', $SuitePath, '-TimeoutSeconds', [string]$TimeoutSeconds, '-ResultPath', $resultPath)
    if ($Degraded) { $argList += '-DegradedJob' }
    foreach ($a in $argList) {
        [void]$psi.ArgumentList.Add([string]$a)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    # Isolated TEMP so the body's own capture files are the only *.tmp here.
    $psi.EnvironmentVariables['TMP'] = $tmpDir
    $psi.EnvironmentVariables['TEMP'] = $tmpDir
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    try { $p.StandardInput.Close() } catch { }
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $bounded = $p.WaitForExit($OuterWallSeconds * 1000)
    if (-not $bounded) {
        try { & taskkill.exe /PID $p.Id /T /F *> $null } catch { }
        try { [void]$p.WaitForExit(10000) } catch { }
    }
    try { [void]$so.Wait(3000) } catch { }
    try { [void]$se.Wait(3000) } catch { }
    $result = $null
    if ($bounded -and (Test-Path -LiteralPath $resultPath)) {
        try { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } catch { }
    }
    $leftover = @(Get-ChildItem -LiteralPath $tmpDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue).Count
    # Read the drained stderr only if the task finished, so a diagnostic read can
    # never itself block (the pipe closes on driver exit or the kill above).
    $stderr = ''
    try { if ($se.IsCompleted) { $stderr = [string]$se.Result } } catch { }
    try { $p.Dispose() } catch { }
    return [pscustomobject]@{ Bounded = $bounded; Result = $result; TempLeftover = $leftover; Stderr = $stderr }
}

# A fixture that spawns a descendant which INHERITS this suite's stdout/stderr (a
# raw Process with UseShellExecute=false and no redirection inherits the parent's
# std handles), records its pid, then $Tail runs. The inherited pipe is exactly what
# made the old parameterless WaitForExit() hang.
function New-PingFixture {
    param([string]$Name, [int]$PingSeconds, [string]$Tail)
    $pidFile = Join-Path $Work ($Name + '-pid.txt')
    $suite = Join-Path $Work ($Name + '.ps1')
    $content = @'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'ping.exe'
foreach ($a in @('-n', '__N__', '127.0.0.1')) { [void]$psi.ArgumentList.Add($a) }
$psi.UseShellExecute = $false
$c = [System.Diagnostics.Process]::Start($psi)
$startTicks = 0
try { $startTicks = $c.StartTime.Ticks } catch { }
Set-Content -LiteralPath '__PIDFILE__' -Value ($c.Id.ToString() + '|' + $startTicks)
__TAIL__
'@
    $content = $content.Replace('__N__', [string]$PingSeconds).Replace('__PIDFILE__', $pidFile).Replace('__TAIL__', $Tail)
    Write-Utf8 $suite $content
    return [pscustomobject]@{ Suite = $suite; PidFile = $pidFile }
}

# Returns the BARE pid, as every caller expects, and records the (pid, start
# time) pair so Test-PidAlive can tell our process from a recycled pid. A file
# written by an older fixture shape carries no start time; that degrades to the
# old existence-only behaviour rather than failing.
function Get-RecordedPid {
    param([string]$PidFile)
    $raw = ''
    if (Test-Path -LiteralPath $PidFile) { try { $raw = (Get-Content -LiteralPath $PidFile -Raw).Trim() } catch { } }
    if ($raw -eq '') { return '' }
    $parts = $raw.Split('|')
    $procId = $parts[0].Trim()
    if ($procId -eq '') { return '' }
    if ($parts.Count -gt 1) {
        $ticks = 0L
        if ([long]::TryParse($parts[1].Trim(), [ref]$ticks) -and $ticks -gt 0) {
            $script:SpawnedStartTicks[$procId] = $ticks
        }
    }
    [void]$script:SpawnedPids.Add($procId)
    return $procId
}

try {
    # =====================================================================
    Write-Host '--- clean-exit orphan: an inherited-stdout descendant does NOT hang the runner and IS killed (HM-02 scope 1/5) ---' -ForegroundColor Cyan
    $fx1 = New-PingFixture -Name 'orphan' -PingSeconds 60 -Tail 'exit 0'
    $r1 = Invoke-BodyInChild -SuitePath $fx1.Suite -TimeoutSeconds 30 -OuterWallSeconds 60
    Check 'the body RETURNS bounded even though a descendant holds the inherited stdout (no parameterless-wait hang)' ($r1.Bounded) ([string]$r1.Stderr)
    Check 'the body reports the child exit code 0' ($null -ne $r1.Result -and [int]$r1.Result.Exit -eq 0) $(if ($null -ne $r1.Result) { [string]$r1.Result.Exit } else { 'no result' })
    $ping1 = Get-RecordedPid $fx1.PidFile
    Check 'the fixture actually recorded a descendant pid' ($ping1 -ne '') $ping1
    Check 'the clean-exit orphan descendant is terminated (Job Object backstop)' (-not (Test-PidAlive $ping1 5)) ('ping ' + $ping1)
    Check 'no temp capture file is left behind after a clean exit' ($r1.TempLeftover -eq 0) ([string]$r1.TempLeftover)

    # =====================================================================
    Write-Host '--- hang owning a child: killed, PROVEN gone, exit 124 (HM-02 scope 2/5) ---' -ForegroundColor Cyan
    $fx2 = New-PingFixture -Name 'hang' -PingSeconds 120 -Tail 'Start-Sleep -Seconds 120'
    $r2 = Invoke-BodyInChild -SuitePath $fx2.Suite -TimeoutSeconds 5 -OuterWallSeconds 60
    Check 'a hung suite is killed and the body stays bounded' ($r2.Bounded) ([string]$r2.Stderr)
    Check 'the timeout kill that PROVES the tree gone maps to 124' ($null -ne $r2.Result -and [int]$r2.Result.Exit -eq 124) $(if ($null -ne $r2.Result) { [string]$r2.Result.Exit + ' :: ' + [string]$r2.Result.Tail } else { 'no result' })
    $ping2 = Get-RecordedPid $fx2.PidFile
    Check 'the owned child of a hung suite is proven terminated' (-not (Test-PidAlive $ping2 5)) ('ping ' + $ping2)
    Check 'no temp capture file is left behind after a timeout kill' ($r2.TempLeftover -eq 0) ([string]$r2.TempLeftover)

    # =====================================================================
    Write-Host '--- a clean child exit code propagates EXACTLY (HM-02 scope 4/5) ---' -ForegroundColor Cyan
    $fx4 = Join-Path $Work 'exit7.ps1'
    Write-Utf8 $fx4 "Write-Host 'suite ran'`nexit 7`n"
    $r4 = Invoke-BodyInChild -SuitePath $fx4 -TimeoutSeconds 30 -OuterWallSeconds 60
    Check 'the exact child exit code 7 is propagated on a clean completion' ($null -ne $r4.Result -and [int]$r4.Result.Exit -eq 7) $(if ($null -ne $r4.Result) { [string]$r4.Result.Exit } else { 'no result' })
    Check 'a clean run is bounded and leaks no temp file' ($r4.Bounded -and $r4.TempLeftover -eq 0) ([string]$r4.Bounded + '/' + [string]$r4.TempLeftover)

    # =====================================================================
    Write-Host '--- DEGRADED mode (no Job Object): a clean-exit orphan is swept, proven gone, reported as 125 (HM-02 follow-up) ---' -ForegroundColor Cyan
    # The driver passes EMPTY C#, so jobReady stays $false and the body runs its
    # degraded paths for real. Pre-fix, a clean exit here killed nothing: the
    # finally's taskkill fires only while the root is alive and there is no job to
    # close, so the ping descendant silently outlived the runner (see the
    # red-proof below). The fix must sweep it via the pid+StartTime ppid walk and
    # report the leak with the guarded runner's established orphanLeak code 125.
    $fx6 = New-PingFixture -Name 'degorphan' -PingSeconds 60 -Tail 'exit 0'
    $r6 = Invoke-BodyInChild -SuitePath $fx6.Suite -TimeoutSeconds 30 -OuterWallSeconds 60 -Degraded
    Check 'the degraded body stays bounded with an inherited-stdout orphan' ($r6.Bounded) ([string]$r6.Stderr)
    $ping6 = Get-RecordedPid $fx6.PidFile
    Check 'the degraded fixture actually recorded a descendant pid' ($ping6 -ne '') $ping6
    Check 'the degraded clean-exit orphan IS terminated (snapshot sweep, no job)' (-not (Test-PidAlive $ping6 5)) ('ping ' + $ping6)
    Check 'a degraded clean exit that leaked is NOT a silent pass: exit 125 (guarded orphanLeak semantics)' ($null -ne $r6.Result -and [int]$r6.Result.Exit -eq 125) $(if ($null -ne $r6.Result) { [string]$r6.Result.Exit } else { 'no result' })
    # The count is >= 1 but environment-dependent: the ping usually drags a
    # conhost.exe descendant with it, so 2 is as legitimate as 1.
    Check 'the result reports the leak honestly (count + original clean exit code in Tail)' ($null -ne $r6.Result -and [string]$r6.Result.Tail -match 'LEAKED \d+ descendant' -and [string]$r6.Result.Tail -match 'clean exit 0') $(if ($null -ne $r6.Result) { [string]$r6.Result.Tail } else { 'no result' })
    Check 'no temp capture file is left behind by the degraded sweep' ($r6.TempLeftover -eq 0) ([string]$r6.TempLeftover)

    # The sweep must not corrupt the ordinary degraded clean exit: no orphans ->
    # the exact child code still propagates (fx4 is the exit-7 fixture above).
    $r7 = Invoke-BodyInChild -SuitePath $fx4 -TimeoutSeconds 30 -OuterWallSeconds 60 -Degraded
    Check 'a degraded clean exit WITHOUT orphans still propagates the exact child code (7)' ($null -ne $r7.Result -and [int]$r7.Result.Exit -eq 7) $(if ($null -ne $r7.Result) { [string]$r7.Result.Exit } else { 'no result' })
    Check 'the ordinary degraded clean run is bounded and leaks no temp file' ($r7.Bounded -and $r7.TempLeftover -eq 0) ([string]$r7.Bounded + '/' + [string]$r7.TempLeftover)

    # =====================================================================
    Write-Host '--- RED-PROOF: the PRE-FIX body (HEAD) leaks a degraded clean-exit orphan ---' -ForegroundColor Cyan
    # Materialize the pre-fix Run-Tests.ps1 from git and run the SAME degraded
    # scenario against its body: the orphan must SURVIVE, proving the fix (not the
    # harness) is what changed the behavior. Once the fix is committed, HEAD
    # contains the sweep and the pre-fix body no longer exists to prove red
    # against, so this section skips itself instead of faking a red.
    $preFixText = ''
    try {
        $preFixLines = & git -C $RepoRoot show 'HEAD:scripts/Run-Tests.ps1' 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $preFixLines) { $preFixText = (@($preFixLines) -join "`n") }
    }
    catch { }
    if ($preFixText -ne '' -and $preFixText -notmatch 'Get-SnapshotSurvivorsLocal') {
        $oldCopy = Join-Path $Work 'Run-Tests-prefix-HEAD.ps1'
        Write-Utf8 $oldCopy $preFixText
        $fx8 = New-PingFixture -Name 'red-orphan' -PingSeconds 60 -Tail 'exit 0'
        $r8 = Invoke-BodyInChild -SuitePath $fx8.Suite -TimeoutSeconds 30 -OuterWallSeconds 90 -Degraded -BodySource $oldCopy
        $ping8 = Get-RecordedPid $fx8.PidFile
        Check 'RED: the pre-fix body reports the clean exit 0 - a silent pass despite the leak' ($null -ne $r8.Result -and [int]$r8.Result.Exit -eq 0) $(if ($null -ne $r8.Result) { [string]$r8.Result.Exit } else { 'no result: ' + [string]$r8.Stderr })
        Check 'RED: the pre-fix degraded orphan SURVIVES the runner (the leak the fix closes)' ($ping8 -ne '' -and (Test-PidAlive $ping8 0)) ('ping ' + $ping8)
        # Kill the deliberately leaked red-proof ping NOW so the end-of-suite
        # no-leak sweep stays meaningful (the finally would catch it anyway).
        if ($ping8 -ne '') { try { & taskkill.exe /PID ([int]$ping8) /T /F *> $null } catch { } }
        Check 'the red-proof orphan is cleaned up by the suite' (-not (Test-PidAlive $ping8 5)) ('ping ' + $ping8)
    }
    else {
        Write-Host 'skipped: HEAD already contains the degraded sweep (or git is unavailable) - no pre-fix body to prove red against' -ForegroundColor DarkGray
    }

    # =====================================================================
    Write-Host '--- fail-closed truth table: Test-OwnedTreeCleared (HM-02 scope 3/5) ---' -ForegroundColor Cyan
    # Extract the REAL top-level function from Run-Tests.ps1 and prove the truth
    # table directly; a pre-fix Run-Tests.ps1 has no such function, so its absence
    # is itself a failure.
    $rtAst = [System.Management.Automation.Language.Parser]::ParseFile($RunTests, [ref]$null, [ref]$null)
    $fnAst = $rtAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-OwnedTreeCleared' }, $true)
    Check 'Run-Tests.ps1 defines a top-level Test-OwnedTreeCleared' ($null -ne $fnAst)
    if ($null -ne $fnAst) {
        . ([scriptblock]::Create($fnAst.Extent.Text))
        Check 'cleared: query ran, 0 survivors, root exited -> TRUE' (Test-OwnedTreeCleared -EnumerationOk $true -SurvivorCount 0 -RootAlive $false)
        Check 'unproven: the survivor query FAILED (even with 0 survivors) -> FALSE (fail-closed)' (-not (Test-OwnedTreeCleared -EnumerationOk $false -SurvivorCount 0 -RootAlive $false))
        Check 'unproven: a survivor remains -> FALSE' (-not (Test-OwnedTreeCleared -EnumerationOk $true -SurvivorCount 1 -RootAlive $false))
        Check 'unproven: the root is still alive -> FALSE' (-not (Test-OwnedTreeCleared -EnumerationOk $true -SurvivorCount 0 -RootAlive $true))
        Check 'unproven: enumeration failed AND a survivor remains -> FALSE' (-not (Test-OwnedTreeCleared -EnumerationOk $false -SurvivorCount 2 -RootAlive $false))
    }

    # The body must WIRE that rule to the fail-closed exit codes and use an inline
    # twin (a -Parallel runspace inherits no functions). Assert against the real
    # body text so a refactor that drops the 126 mapping or the twin is caught.
    $bodyAssign = $rtAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$invokeSuiteBody' }, $true)
    $bodyText = ($bodyAssign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)).Value
    Check 'the body carries an inline twin encoding the SAME fail-closed rule' (
        $bodyText -match '\$EnumerationOk\s+-and\s+\$SurvivorCount\s+-le\s+0\s+-and\s+-not\s+\$RootAlive') 'inline twin rule missing'
    Check 'the body maps proven-clean -> 124 and UNPROVEN -> a distinct 126' (
        $bodyText -match '=\s*124' -and $bodyText -match '=\s*126') 'exit-code mapping missing'
    Check 'the body maps a degraded clean-exit leak (killed + proven gone) -> the distinct 125' (
        $bodyText -match '=\s*125') 'degraded orphanLeak (125) mapping missing'
    # Comment lines are stripped first: the body's own prose deliberately names the
    # parameterless WaitForExit() it replaced.
    $bodyCode = (($bodyText -split "`n") | Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
    Check 'the body CODE no longer contains a parameterless WaitForExit()' ($bodyCode -notmatch 'WaitForExit\(\s*\)') 'parameterless WaitForExit still present in code'
    Check 'the body owns the tree through a Job Object (KILL_ON_JOB_CLOSE via CreateKillOnClose)' ($bodyText -match 'CreateKillOnClose') 'no Job Object ownership'

    # =====================================================================
    Write-Host '--- HM-05: the worker ceiling clamps BOTH auto-detected and explicit -ThrottleLimit ---' -ForegroundColor Cyan
    # Execute the REAL clamp statements from Run-Tests.ps1 (extracted via AST, never
    # copied). The auto-detect must run BEFORE the ceiling clamp, or a default (0)
    # run would compute its formula AFTER the clamp and never be limited. $rtAst is
    # the Run-Tests.ps1 AST parsed above.
    $autoIf = $rtAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '\$ThrottleLimit\s+-le\s+0' }, $true)
    $clampIf = $rtAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'HOOKMAKER_MAX_TEST_WORKERS' }, $true)
    Check 'Run-Tests.ps1 auto-detects a worker count (resource formula present)' ($null -ne $autoIf -and $autoIf.Extent.Text -match '\[Math\]::Max\(2') $(if ($null -ne $autoIf) { 'found' } else { 'missing' })
    Check 'Run-Tests.ps1 clamps to HOOKMAKER_MAX_TEST_WORKERS' ($null -ne $clampIf) $(if ($null -ne $clampIf) { 'found' } else { 'missing' })
    Check 'the auto-detect runs BEFORE the ceiling clamp (so default runs are limited too)' (
        $null -ne $autoIf -and $null -ne $clampIf -and $autoIf.Extent.StartOffset -lt $clampIf.Extent.StartOffset)
    if ($null -ne $autoIf -and $null -ne $clampIf) {
        # Dot-source into THIS scope so the real code mutates our own $ThrottleLimit.
        $clampBlock = [scriptblock]::Create($autoIf.Extent.Text + "`n" + $clampIf.Extent.Text)
        $prevCeil = $env:HOOKMAKER_MAX_TEST_WORKERS
        try {
            $env:HOOKMAKER_MAX_TEST_WORKERS = '1'
            $ThrottleLimit = 0        # the default: auto-detect -> formula (>=2) -> clamp
            . $clampBlock
            Check 'the auto-detected default is clamped to the ceiling (0 -> formula -> 1)' ($ThrottleLimit -eq 1) ([string]$ThrottleLimit)
            $ThrottleLimit = 8        # an explicit -ThrottleLimit above the ceiling
            . $clampBlock
            Check 'an explicit -ThrottleLimit above the ceiling is clamped (8 -> 1)' ($ThrottleLimit -eq 1) ([string]$ThrottleLimit)
            $env:HOOKMAKER_MAX_TEST_WORKERS = '8'
            $ThrottleLimit = 1        # a stricter existing value under a looser ceiling
            . $clampBlock
            Check 'a stricter existing value is NEVER raised (1 stays 1 under ceiling 8)' ($ThrottleLimit -eq 1) ([string]$ThrottleLimit)
        }
        finally { $env:HOOKMAKER_MAX_TEST_WORKERS = $prevCeil }
    }

    # =====================================================================
    Write-Host '--- _testlib New-TestWorkspace: the OWNING PROJECT by default, relocatable for diagnosis, never silently elsewhere ---' -ForegroundColor Cyan
    # The default is the owning project's own work root (global-environment-rules
    # .md). The env var stays as an EXPLICIT relocation for diagnosis - a full
    # matrix can be re-run out of the project to test whether the external
    # deleter that twice removed a live workspace is location-specific - and an
    # unusable value FAILS rather than quietly relocating the run, which is the
    # half that used to fall back to %TEMP%.
    $spaces = New-Object System.Collections.Generic.List[string]
    $prevRoot = $env:HOOKMAKER_TEST_TEMP_ROOT
    try {
        # [char] literals, not quoted strings: the separator written as a quoted
        # escape was lost once already and left TrimEnd('', '/') here - an empty
        # string is not a char, so the whole block threw at its first line.
        $tempRoot = ([System.IO.Path]::GetTempPath()).TrimEnd([char]92, [char]47)
        $projectWorkRoot = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) '.ci-work') 'windows'

        # THE DEFAULT IS THE OWNING PROJECT, not the machine's shared temp
        # (global-environment-rules.md). This assertion used to pin the
        # opposite, which is how the policy violation stayed invisible.
        $env:HOOKMAKER_TEST_TEMP_ROOT = $null
        $w1 = New-TestWorkspace -Prefix 'hookmaker-nwtest'
        [void]$spaces.Add($w1)
        Check 'unset: the workspace lands under the PROJECT work root, not %TEMP%' (
            (Split-Path -Parent $w1) -eq $projectWorkRoot) ($w1 + ' want-parent ' + $projectWorkRoot)
        Check 'unset: and it is nowhere under the machine-wide temp directory' (
            -not $w1.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) $w1
        Check 'unset: the returned path is an existing directory named for the prefix' (
            (Test-Path -LiteralPath $w1 -PathType Container) -and (Split-Path -Leaf $w1).StartsWith('hookmaker-nwtest-')) $w1

        $w1b = New-TestWorkspace -Prefix 'hookmaker-nwtest'
        [void]$spaces.Add($w1b)
        Check 'two calls with the SAME prefix return different paths (no collision between suites)' ($w1b -ne $w1) ($w1 + ' vs ' + $w1b)

        $env:HOOKMAKER_TEST_TEMP_ROOT = '   '
        $w2 = New-TestWorkspace -Prefix 'hookmaker-nwtest'
        [void]$spaces.Add($w2)
        Check 'blank: whitespace is treated as unset, so the project root is used' (
            (Split-Path -Parent $w2) -eq $projectWorkRoot) $w2

        $customRoot = Join-Path $Work 'relocated'
        New-Item -ItemType Directory -Path $customRoot -Force | Out-Null
        $env:HOOKMAKER_TEST_TEMP_ROOT = $customRoot
        $w3 = New-TestWorkspace -Prefix 'hookmaker-nwtest'
        [void]$spaces.Add($w3)
        Check 'configured: an explicit override relocates the workspace' (
            (Split-Path -Parent $w3) -eq $customRoot -and (Test-Path -LiteralPath $w3 -PathType Container)) $w3

        # A relocation root nobody created yet must not be a reason to fail.
        # 'relocated-auto' + separator + 'nested': written as an escape once, which
        # left a real newline INSIDE the string literal and a directory name that
        # cannot exist. [char]92 cannot be eaten by whatever writes this file.
        $autoRoot = Join-Path $Work ('relocated-auto' + [char]92 + 'nested')
        $env:HOOKMAKER_TEST_TEMP_ROOT = $autoRoot
        $w4 = New-TestWorkspace -Prefix 'hookmaker-nwtest'
        [void]$spaces.Add($w4)
        Check 'configured: a not-yet-existing root is created rather than rejected' (
            (Split-Path -Parent $w4) -eq $autoRoot -and (Test-Path -LiteralPath $w4 -PathType Container)) $w4

        # AN UNUSABLE ROOT FAILS. It used to fall back to %TEMP%, which is
        # exactly the silent relocation outside the owning project that the
        # policy forbids: a suite quietly writing somewhere else is the defect,
        # not the error message.
        $blocker = Join-Path $Work 'not-a-dir.txt'
        Write-Utf8 $blocker 'blocker'
        $env:HOOKMAKER_TEST_TEMP_ROOT = (Join-Path $blocker 'child')
        $threw = $false
        $w5 = ''
        try { $w5 = New-TestWorkspace -Prefix 'hookmaker-nwtest' } catch { $threw = $true }
        if ($w5 -ne '') { [void]$spaces.Add($w5) }
        Check 'unusable root: the helper FAILS instead of silently relocating the run' ($threw) $w5
        Check 'unusable root: and it never quietly returns a path under %TEMP%' (
            $w5 -eq '') $w5

        # CONTAINMENT. The leaf is built from the caller's prefix, so a prefix
        # that navigates puts the tree - and the recursive delete that follows
        # it - outside the root nobody named.
        $env:HOOKMAKER_TEST_TEMP_ROOT = $prevRoot
        foreach ($badPrefix in @('..', 'a..b', ('sub' + [char]92 + 'deep'), 'sub/deep', 'C:evil', '')) {
            $escaped = ''
            $refused = $false
            try { $escaped = New-TestWorkspace -Prefix $badPrefix } catch { $refused = $true }
            if ($escaped -ne '') { [void]$spaces.Add($escaped) }
            Check ('a prefix that could leave the root is refused: [' + $badPrefix + ']') ($refused -and $escaped -eq '') $escaped
        }
        # A SIBLING whose name merely starts with the root's name is not inside it.
        $siblingRoot = Join-Path $Work 'boundary'
        Check 'containment compares whole segments, so a sibling-prefix path is NOT contained' (
            -not (Test-TestWorkspaceContained -Root $siblingRoot -Path ($siblingRoot + '2' + [char]92 + 'x'))) $siblingRoot
        Check 'containment accepts a real child' (
            Test-TestWorkspaceContained -Root $siblingRoot -Path (Join-Path $siblingRoot 'x')) $siblingRoot
    }
    finally {
        $env:HOOKMAKER_TEST_TEMP_ROOT = $prevRoot
        if ($spaces.Count -gt 0) { if (-not (Remove-TestWorkspace $spaces.ToArray())) { $script:Fail++ } }
    }

    # =====================================================================
    Write-Host '--- New-TestWorkspace isolates the install registry, without overriding a suite that chose one ---' -ForegroundColor Cyan
    # A suite that installs a hook calls the REAL Install-Hook.ps1, so an
    # un-isolated state directory puts the record in the shared registry at the
    # tool root while -TargetProject is a throwaway directory. The directory is
    # cleaned up and the record is not, and it then surfaces in the user's own
    # "Fix a renamed or moved project" screen. That is not hypothetical: 8 such
    # records across 7 dead fixture roots were found there on 2026-09-19.
    $prevState = $env:HOOKMAKER_STATE_DIR
    $isoSpaces = New-Object System.Collections.Generic.List[string]
    try {
        $env:HOOKMAKER_STATE_DIR = ''
        $isoA = New-TestWorkspace -Prefix 'hookmaker-runtests-iso'
        [void]$isoSpaces.Add($isoA)
        Check 'an unset state dir is pointed INSIDE the new workspace' (
            -not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_STATE_DIR) -and
            (Test-TestWorkspaceContained -Root $isoA -Path $env:HOOKMAKER_STATE_DIR)) $env:HOOKMAKER_STATE_DIR
        Check 'that state directory actually exists' (
            Test-Path -LiteralPath $env:HOOKMAKER_STATE_DIR -PathType Container) $env:HOOKMAKER_STATE_DIR

        # The other half, and the reason this is conditional: 13 suites set the
        # variable themselves, some BEFORE creating their workspace. Overwriting
        # their choice would point them at the wrong state directory.
        $chosen = Join-Path $isoA 'chosen-state'
        New-Item -ItemType Directory -Path $chosen -Force | Out-Null
        $env:HOOKMAKER_STATE_DIR = $chosen
        $isoB = New-TestWorkspace -Prefix 'hookmaker-runtests-iso'
        [void]$isoSpaces.Add($isoB)
        Check "a suite's own state dir is left alone" (
            $env:HOOKMAKER_STATE_DIR -eq $chosen) $env:HOOKMAKER_STATE_DIR
    }
    finally {
        $env:HOOKMAKER_STATE_DIR = $prevState
        if ($isoSpaces.Count -gt 0) { if (-not (Remove-TestWorkspace $isoSpaces.ToArray())) { $script:Fail++ } }
    }

    # =====================================================================
    Write-Host '--- a recycled pid is not our process (HM-02 scope 4b/5) ---' -ForegroundColor Cyan
    # Deterministic stand-in for what the parallel matrix produced by accident:
    # a pid this suite recorded, still present, but now belonging to something
    # else. Forced by recording a start time that cannot match, rather than by
    # waiting for Windows to reuse a pid - which is not reproducible on demand.
    $selfId = [string]$PID
    $selfTicks = (Get-Process -Id $PID).StartTime.Ticks
    $savedSelf = $null
    if ($script:SpawnedStartTicks.ContainsKey($selfId)) { $savedSelf = $script:SpawnedStartTicks[$selfId] }
    try {
        $script:SpawnedStartTicks[$selfId] = [long]$selfTicks
        Check 'a live pid WITH the recorded start time is our process' (Test-PidAlive $selfId 0) $selfId
        $script:SpawnedStartTicks[$selfId] = [long]1
        Check 'a live pid with a DIFFERENT start time is NOT our process (pid reuse)' (
            -not (Test-PidAlive $selfId 0)) ($selfId + ' was reported alive despite a mismatched start time')
        # The waiting form must apply the same identity test, or the per-fixture
        # assertions would still be fooled by a pid recycled within their window.
        Check 'the waiting form also rejects a mismatched start time' (
            -not (Test-PidAlive $selfId 1)) ($selfId + ' was reported alive by the waiting form')
    }
    finally {
        if ($null -ne $savedSelf) { $script:SpawnedStartTicks[$selfId] = $savedSelf }
        else { [void]$script:SpawnedStartTicks.Remove($selfId) }
    }

    # =====================================================================
    Write-Host '--- no process or temp file leaked across the whole run (HM-02 scope 5/5) ---' -ForegroundColor Cyan
    $anyAlive = @($script:SpawnedPids | Where-Object { Test-PidAlive $_ 0 })
    # Printed unconditionally: Check only shows its Actual under
    # HOOKMAKER_TEST_DEBUG, so the two matrix failures that produced this
    # assertion left no record of WHICH pid, which is why it took a second
    # occurrence to diagnose.
    foreach ($aliveId in $anyAlive) {
        $liveName = '(unreadable)'
        try { $liveName = (Get-Process -Id ([int]$aliveId) -ErrorAction Stop).ProcessName } catch { }
        Write-Host ('  still alive: pid ' + $aliveId + ' is ' + $liveName +
            ' recordedStartTicks=' + [string]$script:SpawnedStartTicks[[string]$aliveId]) -ForegroundColor DarkYellow
    }
    Check 'every ping descendant a fixture spawned is gone' ($anyAlive.Count -eq 0) ('still alive: ' + ($anyAlive -join ','))
}
finally {
    # Guarantee no fixture descendant outlives the suite, whatever failed above.
    foreach ($procId in $script:SpawnedPids) {
        if (Test-PidAlive $procId 0) { try { & taskkill.exe /PID ([int]$procId) /T /F *> $null } catch { } }
    }
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
