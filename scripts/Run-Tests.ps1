# Parallel local test runner.
#
# The suites are NOT uniformly parallel-safe. Six of them create throwaway hook
# fixtures inside the REAL hooks\ directory, and some assertions count the hooks
# found there - so running two of those at once makes the count change mid-run
# and produces FALSE failures that look like flakiness. (That is not
# hypothetical: it was diagnosed exactly once, when concurrent agents ran suites
# against the same checkout.)
#
# So the suites are split into two groups:
#   * ISOLATED  - work only in their own temp workspace; run all at once.
#   * EXCLUSIVE - create fixtures under the real hooks\ dir; run one at a time.
# The two groups run CONCURRENTLY, so wall-clock is
# max(slowest isolated batch, serial exclusive chain) instead of the sum of all.
#
# CI does not need this split: there, each suite gets its own job on its own
# runner and therefore its own checkout, so nothing is shared (see ci.yml).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Run-Tests.ps1 [-ThrottleLimit N] [-Only <name,...>]
# Exit code is the number of FAILED SUITES (0 = all green).

param(
    [int]$ThrottleLimit = 0,
    [string]$Only = '',
    # Per-suite wall-clock ceiling. A suite that drives the interactive wizard
    # blocks on stdin if its scripted answers run out, which would otherwise
    # hang the whole run with no output. A timed-out suite is killed and
    # reported as a failure rather than being allowed to stall everything.
    [int]$TimeoutSeconds = 600
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'Run-Tests.ps1 needs PowerShell 7+ (ForEach-Object -Parallel). Use pwsh, not powershell.exe.' -ForegroundColor Red
    exit 1
}

$ScriptRoot = $PSScriptRoot

# Suites that create fixtures under the real hooks\ directory, or assert on the
# number of hooks discovered there. These must not overlap with each other.
$Exclusive = @(
    'Test-InstallRegistry.ps1'
    'Test-InstallRegistrySchema.ps1'
    'Test-LegacyDiscovery.ps1'
    'Test-NativePrePushInstall.ps1'
    'Test-UninstallHook.ps1'
    'Test-Wizard.ps1'
)

$all = @(Get-ChildItem -LiteralPath $ScriptRoot -Filter 'Test-*.ps1' -File | Sort-Object Name)
if (-not [string]::IsNullOrWhiteSpace($Only)) {
    $wanted = @($Only.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $all = @($all | Where-Object { $wanted -contains $_.Name -or $wanted -contains $_.BaseName })
    if ($all.Count -eq 0) { Write-Host ('No suite matched: ' + $Only) -ForegroundColor Red; exit 1 }
}

$exclusiveSuites = @($all | Where-Object { $Exclusive -contains $_.Name })
$isolatedSuites = @($all | Where-Object { $Exclusive -notcontains $_.Name })

if ($ThrottleLimit -le 0) {
    # Each suite spawns real child processes, so oversubscribing hurts more than
    # it helps. Leave headroom for the exclusive chain running alongside.
    $cores = [Environment]::ProcessorCount
    $ThrottleLimit = [Math]::Max(2, [Math]::Min(8, $cores - 2))
}

Write-Host ('Running ' + $all.Count + ' suite(s): ' + $isolatedSuites.Count + ' isolated (parallel, throttle ' + $ThrottleLimit + ') + ' + $exclusiveSuites.Count + ' exclusive (serial), both groups concurrently. Per-suite timeout ' + $TimeoutSeconds + 's.') -ForegroundColor Cyan
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$host7 = (Get-Process -Id $PID).Path

# Runs one suite as a real child process with stdin detached and a hard
# timeout, so a suite that blocks waiting for input cannot stall the run.
# Defined as a string and re-created inside each parallel runspace, because
# -Parallel does not inherit functions from the caller's scope.
$invokeSuiteBody = @'
param($SuitePath, $Exe, $TimeoutSeconds)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$outFile = [System.IO.Path]::GetTempFileName()
$errFile = [System.IO.Path]::GetTempFileName()
$name = Split-Path -Leaf $SuitePath
try {
    # Single quoted argument STRING, matching the convention used by every other
    # spawned-process call in this repo: suite paths contain spaces, and the
    # array form is not accepted consistently across hosts here.
    $p = Start-Process -FilePath $Exe -ArgumentList ('-NoLogo -NoProfile -File "' + $SuitePath + '"') `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -NoNewWindow -PassThru
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill($true) } catch { }
        try { $p.WaitForExit() } catch { }
        $sw.Stop()
        return [pscustomobject]@{ Suite = $name; Exit = 124; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Tail = ('TIMED OUT after ' + $TimeoutSeconds + 's (killed)') }
    }
    # The TIMED WaitForExit overload returns as soon as the process ends, but
    # the redirected stdout/stderr handles may not be flushed and released yet -
    # reading the temp file here then fails with "used by another process".
    # The PARAMETERLESS overload is documented to also wait for that flush, so
    # it is the required follow-up before touching the files.
    try { $p.WaitForExit() } catch { }
    $sw.Stop()
    $exitCode = $p.ExitCode
    # Dispose releases the redirect handles the parent Process object still
    # holds; without this the temp files read back as "used by another
    # process". Even then release can lag slightly, so reading retries briefly -
    # these files are only diagnostics, so a failed read must never fail a suite.
    try { $p.Dispose() } catch { }
    function Read-Released {
        param([string]$Path)
        for ($i = 0; $i -lt 20; $i++) {
            try { return [System.IO.File]::ReadAllText($Path) } catch { Start-Sleep -Milliseconds 50 }
        }
        return ''
    }
    $text = ''
    if (Test-Path -LiteralPath $outFile) { $text = Read-Released $outFile }
    $errText = ''
    if (Test-Path -LiteralPath $errFile) { $errText = Read-Released $errFile }
    $tail = (@(($text -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -Last 3) -join ' | ')
    if (-not [string]::IsNullOrWhiteSpace($errText)) { $tail = $tail + ' || stderr: ' + (($errText -split "`r?`n")[0]) }
    return [pscustomobject]@{ Suite = $name; Exit = $exitCode; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Tail = $tail }
}
finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
}
'@

# The exclusive chain starts first and runs alongside the parallel batch.
$exclusiveJob = $null
if ($exclusiveSuites.Count -gt 0) {
    $exclusiveJob = Start-ThreadJob -ArgumentList @(, @($exclusiveSuites | ForEach-Object { $_.FullName })), $host7, $TimeoutSeconds, $invokeSuiteBody -ScriptBlock {
        param($paths, $exe, $timeout, $body)
        $invoke = [scriptblock]::Create($body)
        $out = @()
        foreach ($p in @($paths)) { $out += (& $invoke $p $exe $timeout) }
        return $out
    }
}

$isolatedResults = @()
if ($isolatedSuites.Count -gt 0) {
    $isolatedResults = @($isolatedSuites | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $invoke = [scriptblock]::Create($using:invokeSuiteBody)
        & $invoke $_.FullName $using:host7 $using:TimeoutSeconds
    })
}

$exclusiveResults = @()
if ($null -ne $exclusiveJob) {
    $exclusiveResults = @(Receive-Job -Job $exclusiveJob -Wait -AutoRemoveJob)
}

$stopwatch.Stop()
$results = @($isolatedResults) + @($exclusiveResults) | Sort-Object Suite
Write-Host ''
$results | Format-Table Suite, Exit, Seconds -AutoSize

$failed = @($results | Where-Object { $_.Exit -ne 0 })
Write-Host ('Wall clock: ' + [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1) + 's for ' + $results.Count + ' suite(s).')
if ($failed.Count -gt 0) {
    Write-Host ('FAILED: ' + (($failed | ForEach-Object { $_.Suite }) -join ', ')) -ForegroundColor Red
    foreach ($f in $failed) { Write-Host ('  ' + $f.Suite + ' -> ' + $f.Tail) -ForegroundColor DarkGray }
}
else { Write-Host 'ALL SUITES PASSED' -ForegroundColor Green }
exit $failed.Count
