# Offline test suite for the per-suite runner core in scripts\Run-Tests.ps1
# (HM-02). The centre of gravity is the bounded-after-exit + PROVEN cleanup
# guarantee of $invokeSuiteBody: a descendant that inherits the suite's stdout and
# outlives it must NOT hang the runner (the old parameterless WaitForExit did), a
# clean-exit orphan must be killed, a hang must be killed and PROVEN gone (124), an
# unproven cleanup must map to a distinct 126, a clean child exit code must
# propagate exactly, and no process or temp file may leak.
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

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-runteststest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# Every ping pid a fixture records, so cleanup can guarantee none is left alive.
$script:SpawnedPids = New-Object System.Collections.Generic.List[string]

function Test-PidAlive {
    param([string]$ProcId, [int]$MaxWaitSeconds = 0)
    if ([string]::IsNullOrWhiteSpace($ProcId)) { return $false }
    $target = 0
    if (-not [int]::TryParse($ProcId, [ref]$target)) { return $false }
    if ($MaxWaitSeconds -le 0) {
        try { $null = Get-Process -Id $target -ErrorAction Stop; return $true } catch { return $false }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($MaxWaitSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $null = Get-Process -Id $target -ErrorAction Stop } catch { return $false }
        Start-Sleep -Milliseconds 100
    }
    return $true
}

# The driver: extracts the REAL body + C# and runs it against one suite, writing the
# returned object as JSON. Executed inside a bounded child by Invoke-BodyInChild so
# the body under test can never hang this suite.
$driver = Join-Path $Work 'body-driver.ps1'
Write-Utf8 $driver @'
param([string]$RunTestsPath, [string]$GuardedPath, [string]$SuitePath, [int]$TimeoutSeconds, [string]$ResultPath)
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
    param([string]$SuitePath, [int]$TimeoutSeconds, [int]$OuterWallSeconds)
    $resultPath = Join-Path $Work ('bodyresult-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $tmpDir = Join-Path $Work ('bodytmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $exe = (Get-Process -Id $PID).Path
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    foreach ($a in @('-NoLogo', '-NoProfile', '-File', $driver, '-RunTestsPath', $RunTests, '-GuardedPath', $Guarded, '-SuitePath', $SuitePath, '-TimeoutSeconds', [string]$TimeoutSeconds, '-ResultPath', $resultPath)) {
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
Set-Content -LiteralPath '__PIDFILE__' -Value $c.Id
__TAIL__
'@
    $content = $content.Replace('__N__', [string]$PingSeconds).Replace('__PIDFILE__', $pidFile).Replace('__TAIL__', $Tail)
    Write-Utf8 $suite $content
    return [pscustomobject]@{ Suite = $suite; PidFile = $pidFile }
}

function Get-RecordedPid {
    param([string]$PidFile)
    $procId = ''
    if (Test-Path -LiteralPath $PidFile) { try { $procId = (Get-Content -LiteralPath $PidFile -Raw).Trim() } catch { } }
    if ($procId -ne '') { [void]$script:SpawnedPids.Add($procId) }
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
    Write-Host '--- no process or temp file leaked across the whole run (HM-02 scope 5/5) ---' -ForegroundColor Cyan
    $anyAlive = @($script:SpawnedPids | Where-Object { Test-PidAlive $_ 0 })
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
