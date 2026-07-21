# Parallel local test runner.
#
# Suites run in parallel, with ONE exception handled in a first phase - see the
# `$Exclusive list below for exactly why. Wall clock becomes
# (that one suite) + (slowest of everything else) instead of the sum of them all.
#
# The suite list is GLOBBED from disk, so a newly added Test-*.ps1 runs here
# automatically. CI cannot do that (its buckets are hand-written in ci.yml), so
# ci.yml carries a step that fails when a suite on disk is in no bucket.
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

# The suites that COUNT the real hooks\ directory must run alone.
#
# Several suites create throwaway fixtures under the real hooks\ directory, but
# each uses its own unique prefix (ZZZ-Regtest, ZZZ-Ld, ZZZ-Uninst, ...), so they
# never collide with one another by name. The real constraint is different:
# these two suites ASSERT ON THE NUMBER of hooks discovered in hooks\, because
# the menu's index math is derived from it. If anything else adds or removes a
# fixture while they count, their assertions fail for a reason that has nothing
# to do with the code under test - Test-InstalledHooksMenu was observed at 76/1
# in a parallel run and 77/0 alone, purely from that.
#
# So these run alone and everything else runs in parallel. An earlier version of
# this file serialised all six fixture-creating suites, which was over-cautious
# in the worst possible way: those six are the slowest suites, so serialising
# them threw away most of the available speedup.
#
# CI does not need this: each bucket is its own runner with its own checkout,
# and suites inside a bucket run one after another (see ci.yml).
$Exclusive = @(
    'Test-Wizard.ps1',
    'Test-InstalledHooksMenu.ps1'
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

# Project-wide ceiling, applied to BOTH the auto-detected number and an explicit
# -ThrottleLimit. This is where a worker cap can actually be enforced: it is the
# only place that knows the real number.
#
# Test-Run-Guard deliberately does NOT enforce its TEST_GUARD_MAX_WORKERS - it
# would have to rewrite the worker flag of whatever runner it just recognised,
# and every framework spells that differently (pytest -n, jest --maxWorkers,
# vitest --maxThreads, go -p, cargo -j, dotnet -m, here -ThrottleLimit).
# Guessing wrong breaks the run, and the common oversubscribing case carries no
# flag at all - it auto-detects - so there would be nothing to rewrite anyway.
# The hook advises the number; this line is what makes it bind.
if (-not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_MAX_TEST_WORKERS)) {
    $ceiling = 0
    if ([int]::TryParse($env:HOOKMAKER_MAX_TEST_WORKERS, [ref]$ceiling) -and $ceiling -ge 1) {
        if ($ThrottleLimit -gt $ceiling) {
            Write-Host ('Worker ceiling HOOKMAKER_MAX_TEST_WORKERS=' + $ceiling + ' applied (was ' + $ThrottleLimit + ').') -ForegroundColor DarkGray
            $ThrottleLimit = $ceiling
        }
    }
    else {
        Write-Host ('Ignoring HOOKMAKER_MAX_TEST_WORKERS: not a positive integer.') -ForegroundColor Yellow
    }
}

Write-Host ('Running ' + $all.Count + ' suite(s): ' + $isolatedSuites.Count + ' parallel + ' + $exclusiveSuites.Count + ' exclusive-first. Per-suite timeout ' + $TimeoutSeconds + 's.') -ForegroundColor Cyan
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
# An EMPTY file as stdin, so a suite that reads input gets EOF immediately
# instead of inheriting this console's stdin and blocking. Without this the
# only protection is the timeout below, which turns a 1-second bug into a
# full 600-second stall - and in CI, into a job that burns its whole budget.
# An empty real file is used rather than the NUL device because it gives a
# deterministic EOF on every host this runs under.
$inFile = [System.IO.Path]::GetTempFileName()
$name = Split-Path -Leaf $SuitePath
try {
    # Single quoted argument STRING, matching the convention used by every other
    # spawned-process call in this repo: suite paths contain spaces, and the
    # array form is not accepted consistently across hosts here.
    $p = Start-Process -FilePath $Exe -ArgumentList ('-NoLogo -NoProfile -File "' + $SuitePath + '"') `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -RedirectStandardInput $inFile `
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
    Remove-Item -LiteralPath $outFile, $errFile, $inFile -Force -ErrorAction SilentlyContinue
}
'@

# The exclusive suite must NOT overlap with the parallel batch: it counts the
# hooks in the real hooks\ directory, and the parallel batch creates and removes
# fixtures there. So it runs first, on its own, and only then does the batch
# start. (Running them concurrently is what produces the "flaky" count failures.)
if ($exclusiveSuites.Count -gt 0) {
    Write-Host ('Phase 1 - exclusive (counts real hooks\, must run alone): ' + (($exclusiveSuites | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
}
$invokeSuite = [scriptblock]::Create($invokeSuiteBody)
$exclusiveResults = @()
foreach ($suite in $exclusiveSuites) {
    $exclusiveResults += (& $invokeSuite $suite.FullName $host7 $TimeoutSeconds)
}

if ($isolatedSuites.Count -gt 0) {
    Write-Host ('Phase 2 - ' + $isolatedSuites.Count + ' suite(s) in parallel.') -ForegroundColor DarkGray
}
$isolatedResults = @()
if ($isolatedSuites.Count -gt 0) {
    $isolatedResults = @($isolatedSuites | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $invoke = [scriptblock]::Create($using:invokeSuiteBody)
        & $invoke $_.FullName $using:host7 $using:TimeoutSeconds
    })
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
