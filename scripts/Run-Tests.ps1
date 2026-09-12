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
    #
    # 900 s, the same number ci.yml uses, so local and CI cannot disagree about
    # what counts as too slow. It was 600 s until the slowest suite outgrew it:
    # measured 2026-09-12, Test-TestCompletionCheck takes 590.7 s ALONE on an
    # idle machine, leaving 1.6% margin - so the default run killed it even
    # with no contention at all. 900 s restores ~34% margin over that measured
    # worst case.
    #
    # This is NOT the answer to a suite that times out under PARALLEL load:
    # that is oversubscription, the cure is fewer workers, and TESTING_NOTES.md
    # records why raising the cap for it would only hide a real hang. Raise
    # this number only when a suite's cost MEASURED ALONE has genuinely grown.
    [int]$TimeoutSeconds = 900
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
# DO NOT empty this list because both suites now ignore `ZZZ-*` fixtures.
# Round 40 made them immune to LEFTOVER fixtures, which is a real fix for the
# residue flake - but immunity to residue is NOT immunity to concurrency, and
# the two were measured separately:
#   * Test-Wizard concurrent with Test-InstalledHooksMenu -> 254/8 (262/0 alone).
#   * Test-Wizard concurrent with ONLY Test-InstallRegistry, Test-UninstallHook
#     and Test-DiscoveredUninstall, menu suite absent  -> 258/4.
# The second run is the important one: the exclusivity is not about the menu
# suite, it is about ANY suite that creates or removes a fixture under the real
# hooks\ while a counting suite runs. `_testwizardselectall.ps1` deliberately
# counts EVERY hook including `ZZZ-*`, because the wizard genuinely configures
# them - so the count legitimately changes mid-run and no name filter can help.
# Fixing this for real means giving fixture-creating suites their own copy of
# hooks\ instead of the shared one. Until then, these two stay exclusive.
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
# Test-Run-Guard resolves TEST_GUARD_MAX_WORKERS and hands it to the guarded
# runner, which EXPORTS the resolved ceiling as HOOKMAKER_MAX_TEST_WORKERS into
# this child's environment (never rewriting the recognised command's own worker
# flag - every framework spells that differently: pytest -n, jest --maxWorkers,
# vitest --maxThreads, go -p, cargo -j, dotnet -m, here -ThrottleLimit - and the
# oversubscribing case usually carries no flag at all). This line is where the
# exported ceiling actually binds: it clamps $ThrottleLimit whether it was
# auto-detected (the default) or passed explicitly as -ThrottleLimit.
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

# The per-suite failure diagnostics written further down (logs\failed-<suite>-
# <stamp>_UTC.err/out.log) accumulated exactly like the wizard's own logs did -
# 124 had piled up and nothing ever removed them. Keep the newest 200 and prune
# the rest, once per invocation rather than per suite, and best-effort like
# Remove-SupersededBackups in _installlib.ps1: a file that cannot be deleted is
# left alone rather than failing the matrix. Ordered by LastWriteTime, NOT by
# name - these names start with the SUITE, so sorting by name sorts by suite.
# The StartsWith guard keeps this to this runner's own diagnostics: never the
# wizard's Setup-SyncGroup_*.log files sitting in the same directory.
try {
    $diagnosticsDir = Join-Path (Split-Path -Parent $ScriptRoot) 'logs'
    $oldDiagnostics = @(Get-ChildItem -LiteralPath $diagnosticsDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith('failed-', [System.StringComparison]::Ordinal) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 200)
    foreach ($diagnostic in $oldDiagnostics) {
        try { Remove-Item -LiteralPath $diagnostic.FullName -Force -ErrorAction Stop } catch { }
    }
}
catch { }

Write-Host ('Running ' + $all.Count + ' suite(s): ' + $isolatedSuites.Count + ' parallel + ' + $exclusiveSuites.Count + ' exclusive-first. Per-suite timeout ' + $TimeoutSeconds + 's.') -ForegroundColor Cyan
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$host7 = (Get-Process -Id $PID).Path

# The single source of truth for "did the owned process tree really go away" after
# a timeout kill. Fail CLOSED: cleanup counts as proven ONLY when the survivor
# query actually ran (EnumerationOk - a failed CIM/job query is UNPROVEN, never a
# silent all-clear), nothing owned is still alive (SurvivorCount), and the suite's
# own process has exited (RootAlive). The per-suite body carries an inline twin of
# this rule, because a -Parallel runspace does not inherit the caller's functions.
function Test-OwnedTreeCleared {
    param([bool]$EnumerationOk, [int]$SurvivorCount, [bool]$RootAlive)
    return ($EnumerationOk -and $SurvivorCount -le 0 -and -not $RootAlive)
}

# The Job Object gives the per-suite body crash-proof ownership of its whole child
# tree (KILL_ON_JOB_CLOSE), so a suite that spawns a background descendant and
# exits cannot leave it running, and a timeout kill can PROVE the tree is gone via
# the job's pid-reuse-proof assigned-pid list. The C# is read from the ONE place it
# already lives - Run-Tests-Guarded.ps1 - never duplicated here, and pre-loaded once
# so every -Parallel runspace shares the AppDomain-loaded type and a compile error
# surfaces here, not inside each runspace. The source string is threaded into each
# runspace as a body argument so the body is self-contained if the type is absent.
$guardedRunnerPath = Join-Path $ScriptRoot 'Run-Tests-Guarded.ps1'
$jobCSharp = ''
try {
    $guardedText = Get-Content -LiteralPath $guardedRunnerPath -Raw
    $csStart = $guardedText.IndexOf('using System;')
    $csEnd = $guardedText.IndexOf("'@", $csStart)
    if ($csStart -ge 0 -and $csEnd -gt $csStart) { $jobCSharp = $guardedText.Substring($csStart, $csEnd - $csStart) }
}
catch { }
if (-not [string]::IsNullOrWhiteSpace($jobCSharp) -and -not ('HookMaker.JobNative' -as [type])) {
    try { Add-Type -TypeDefinition $jobCSharp -ErrorAction Stop } catch { }
}

# Runs one suite as a real child process it OWNS through a Job Object, with stdin
# detached and a bounded wall timeout, so a suite that blocks on input, hangs, or
# leaves a background descendant behind cannot stall the run or leak a process.
#
# Mirrors Run-Tests-Guarded.ps1's proven core: a raw System.Diagnostics.Process +
# ArgumentList (no shell re-parse), stdout/stderr drained with CopyToAsync into
# temp files (never the parameterless WaitForExit() that a pipe-holding grandchild
# deadlocks), a Job Object with KILL_ON_JOB_CLOSE that ends the whole tree on a
# clean-exit orphan OR a timeout survivor, and a timeout branch that PROVES the
# tree is gone (pid-reuse-proof via the job's assigned-pid list) and fails CLOSED:
# proven-clean timeout -> 124, UNPROVEN cleanup -> a distinct 126. With NO Job
# Object (degraded), a clean exit gets an explicit orphan sweep instead - a
# pid+StartTime ppid walk that kills and re-verifies survivors - because the
# finally's backstops both miss that case (taskkill fires only while the root is
# alive, and there is no job to close). Leaked-but-killed-and-proven maps to the
# guarded runner's established orphanLeak code 125 (a clean exit that leaked is
# never a silent pass); an unprovable kill falls into the same fail-closed 126.
#
# Defined as a string and re-created inside each parallel runspace, because
# -Parallel does not inherit functions from the caller's scope; the Job Object C#
# source is passed in as $JobCSharp for the same reason.
$invokeSuiteBody = @'
param($SuitePath, $Exe, $TimeoutSeconds, $JobCSharp)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$name = Split-Path -Leaf $SuitePath
$outFile = [System.IO.Path]::GetTempFileName()
$errFile = [System.IO.Path]::GetTempFileName()
# Set by the degraded clean-exit orphan sweep below; prefixed onto the reported
# tail so a leak is visible in the suite table, not only in the exit code.
$leakNote = ''

# Inline TWIN of the top-level Test-OwnedTreeCleared (a -Parallel runspace does not
# inherit the caller's functions). Keep both in sync: proven-clean requires all
# three - the survivor query ran, nothing owned is still alive, and the root exited.
function Test-OwnedTreeClearedLocal { param([bool]$EnumerationOk, [int]$SurvivorCount, [bool]$RootAlive) return ($EnumerationOk -and $SurvivorCount -le 0 -and -not $RootAlive) }

# ppid-walk snapshot (pid + start time), taken BEFORE a kill, for the DEGRADED
# (no Job Object) proof: after the kill a survivor is a recorded pid still alive
# WITH the same start time - a recycled pid (different start) is not a survivor.
# Ok=$false means the CIM query failed, i.e. cleanup could not be proven.
function Get-TreeSnapshotLocal {
    param([int]$RootId)
    $ok = $true
    $procs = @()
    try { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, CreationDate) }
    catch { $ok = $false; $procs = @() }
    $members = New-Object System.Collections.Generic.List[object]
    $rootStart = [datetime]::MinValue
    try { $rootStart = (Get-Process -Id $RootId -ErrorAction Stop).StartTime } catch { }
    [void]$members.Add([pscustomobject]@{ Pid = $RootId; Start = $rootStart })
    $seen = @{ "$RootId" = $true }
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        foreach ($pr in $procs) {
            $cid = [int]$pr.ProcessId
            if ([int]$pr.ParentProcessId -eq $cur -and -not $seen.ContainsKey("$cid")) {
                $seen["$cid"] = $true
                [void]$members.Add([pscustomobject]@{ Pid = $cid; Start = $pr.CreationDate })
                $queue.Enqueue($cid)
            }
        }
    }
    return [pscustomobject]@{ Ok = $ok; Members = $members.ToArray() }
}

# Members of a pid+StartTime snapshot that are STILL alive with the SAME start
# time. The identity binding is the whole point: a recycled pid (same number,
# different start) is neither counted nor later killed. Shared by BOTH degraded
# proofs - the timeout-kill survivor count and the clean-exit orphan sweep. A
# live pid whose StartTime cannot be read counts as a survivor: fail closed,
# never assume a kill worked on a process that cannot be identity-checked.
function Get-SnapshotSurvivorsLocal {
    param([object[]]$Members)
    $alive = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Members)) {
        try {
            $live = Get-Process -Id $m.Pid -ErrorAction SilentlyContinue
            if ($live) {
                $sameStart = $true
                try { $sameStart = ([Math]::Abs(($live.StartTime - [datetime]$m.Start).TotalSeconds) -lt 2) } catch { $sameStart = $true }
                if ($sameStart) { [void]$alive.Add($m) }
            }
        }
        catch { }
    }
    return $alive.ToArray()
}

# The type is normally already AppDomain-loaded by the parent's pre-load; Add-Type
# from the passed source only if it is somehow absent (self-contained runspace).
$jobReady = $false
try {
    if (-not ('HookMaker.JobNative' -as [type]) -and -not [string]::IsNullOrWhiteSpace($JobCSharp)) { Add-Type -TypeDefinition $JobCSharp -ErrorAction Stop }
    if ('HookMaker.JobNative' -as [type]) { $jobReady = $true }
}
catch { $jobReady = $false }

$process = $null
$stdoutWriter = $null
$stderrWriter = $null
$job = [IntPtr]::Zero
try {
    if ($jobReady) { try { $job = [HookMaker.JobNative]::CreateKillOnClose() } catch { $job = [IntPtr]::Zero } }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    foreach ($a in @('-NoLogo', '-NoProfile', '-File', $SuitePath)) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    if ($job -ne [IntPtr]::Zero) {
        $assigned = $false
        try { $assigned = [HookMaker.JobNative]::Assign($job, $process.Handle) } catch { $assigned = $false }
        if (-not $assigned) { try { [void][HookMaker.JobNative]::Close($job) } catch { }; $job = [IntPtr]::Zero }
    }
    # Detach stdin: a suite that reads input gets EOF and fails fast instead of
    # blocking until the timeout hides the cause.
    try { $process.StandardInput.Close() } catch { }
    # Drain both pipes INSIDE .NET straight into files. The child stdout is a pipe,
    # so a descendant that inherits it cannot lock the temp FILE (only this
    # FileStream writes it), and the pumps are awaited WITH A BOUND below - never
    # the parameterless WaitForExit() that a pipe-holding grandchild deadlocked.
    $stdoutWriter = [System.IO.File]::Create($outFile)
    $stderrWriter = [System.IO.File]::Create($errFile)
    $stdoutPump = $process.StandardOutput.BaseStream.CopyToAsync($stdoutWriter)
    $stderrPump = $process.StandardError.BaseStream.CopyToAsync($stderrWriter)

    $exitCode = 0
    $timedOut = $false
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        # Degraded proof needs a BEFORE-kill snapshot; the job list is queried AFTER
        # the kill and is pid-reuse-proof on its own, so it needs none.
        $snap = $null
        if ($job -eq [IntPtr]::Zero) { $snap = Get-TreeSnapshotLocal -RootId $process.Id }
        if ($job -ne [IntPtr]::Zero) { try { [void][HookMaker.JobNative]::Terminate($job) } catch { } }
        try { & taskkill.exe /PID $process.Id /T /F *> $null } catch { }
        # BOUNDED grace after the kill - never an unbounded wait.
        try { [void]$process.WaitForExit(15000) } catch { }
        $rootAlive = $true
        try { $rootAlive = -not $process.HasExited } catch { $rootAlive = $false }
        # Prove the owned tree is gone. Prefer the Job Object's assigned-pid list
        # (a recycled pid was never assigned to THIS job, so it cannot masquerade as
        # a survivor); degrade to the pid+start snapshot; never trust pid alone.
        $enumOk = $false
        $survivors = 0
        if ($job -ne [IntPtr]::Zero) {
            $jobIds = $null
            try { $jobIds = [HookMaker.JobNative]::GetProcessIds($job) } catch { $jobIds = $null }
            $enumOk = ($null -ne $jobIds)
            if ($enumOk) { foreach ($jid in @($jobIds)) { try { $null = Get-Process -Id $jid -ErrorAction Stop; $survivors++ } catch { } } }
        }
        else {
            $enumOk = $snap.Ok
            $survivors = @(Get-SnapshotSurvivorsLocal -Members @($snap.Members)).Count
        }
        # Fail CLOSED: a proven-clean timeout is 124; an UNPROVEN cleanup (the query
        # failed, a survivor remains, or the root is still alive) is a DISTINCT 126,
        # so a leaked tree can never be reported as a clean timeout.
        if (Test-OwnedTreeClearedLocal -EnumerationOk $enumOk -SurvivorCount $survivors -RootAlive $rootAlive) { $exitCode = 124 }
        else { $exitCode = 126 }
    }
    else {
        $exitCode = $process.ExitCode
        # DEGRADED (no Job Object) clean-exit orphan sweep. With a job, the finally's
        # Terminate+Close (KILL_ON_JOB_CLOSE) ends anything the suite leaked even
        # after a clean root exit; with no job NOTHING did: the finally's taskkill
        # fires only while the root is still alive, so a dead root + live descendant
        # leaked silently. The ppid walk still finds those descendants (on Windows a
        # dead parent's children keep its pid in ParentProcessId), and the
        # pid+StartTime binding means a recycled pid is never counted or killed.
        # Mirrors the guarded runner's clean-exit orphan rule and its established
        # code: a clean exit that leaked descendants is NEVER a silent pass -
        # killed-and-proven-gone -> 125 (orphanLeak), a kill that cannot be proven
        # -> the existing fail-closed 126. A failed CIM walk detects nothing and,
        # like the guarded runner's degraded fallback, leaves the clean exit code
        # untouched: no kill happened, so there is no cleanup to prove.
        if ($job -eq [IntPtr]::Zero) {
            $cleanSnap = Get-TreeSnapshotLocal -RootId $process.Id
            if ($cleanSnap.Ok) {
                $orphans = @(Get-SnapshotSurvivorsLocal -Members @(@($cleanSnap.Members) | Where-Object { $_.Pid -ne $process.Id }))
                if ($orphans.Count -gt 0) {
                    foreach ($o in $orphans) { try { & taskkill.exe /PID $o.Pid /T /F *> $null } catch { } }
                    # BOUNDED re-verification with the same pid+StartTime binding, so
                    # pid reuse after the kill can fake neither a survivor nor a clear.
                    $deadline = [datetime]::UtcNow.AddSeconds(10)
                    $remaining = @(Get-SnapshotSurvivorsLocal -Members $orphans)
                    while ($remaining.Count -gt 0 -and [datetime]::UtcNow -lt $deadline) {
                        Start-Sleep -Milliseconds 150
                        $remaining = @(Get-SnapshotSurvivorsLocal -Members $orphans)
                    }
                    if ($remaining.Count -eq 0) {
                        $leakNote = 'LEAKED ' + $orphans.Count + ' descendant(s) after clean exit ' + $exitCode + ' (degraded, no Job Object; killed and proven terminated)'
                        $exitCode = 125
                    }
                    else {
                        $leakNote = 'LEAKED ' + $orphans.Count + ' descendant(s) after clean exit ' + $exitCode + ' (degraded, no Job Object; ' + $remaining.Count + ' NOT proven terminated)'
                        $exitCode = 126
                    }
                }
            }
        }
    }

    # Bounded flush of the pumps' tail; whatever a surviving grandchild still holds
    # open is not worth hanging for.
    foreach ($pump in @($stdoutPump, $stderrPump)) { try { [void]$pump.Wait(5000) } catch { } }
    try { $stdoutWriter.Flush(); $stdoutWriter.Dispose(); $stdoutWriter = $null } catch { }
    try { $stderrWriter.Flush(); $stderrWriter.Dispose(); $stderrWriter = $null } catch { }
    $sw.Stop()

    $text = ''
    try { $text = [System.IO.File]::ReadAllText($outFile) } catch { }
    $errText = ''
    try { $errText = [System.IO.File]::ReadAllText($errFile) } catch { }
    if ($timedOut) {
        $tail = 'TIMED OUT after ' + $TimeoutSeconds + 's (killed; ' + $(if ($exitCode -eq 124) { 'tree proven terminated' } else { 'cleanup NOT proven' }) + ')'
    }
    else {
        $tail = (@(($text -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -Last 3) -join ' | ')
        if (-not [string]::IsNullOrWhiteSpace($errText)) {
            # Keep the first few NON-EMPTY lines, not just [0]. A PowerShell
            # failure's first stderr line is always 'Exception: <file>:<line>' -
            # the least informative part - and the message a suite deliberately
            # threw lands AFTER it. Keeping only [0] discarded exactly the
            # evidence a suite was instrumented to produce: a real run of
            # Test-DiscoveredUninstall threw its workspace/parent-existence
            # detail and the table showed only the file and line number.
            $errLines = @(($errText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 3)
            $tail = $tail + ' || stderr: ' + ($errLines -join ' | ')
        }
        # A degraded clean-exit leak leads the tail: the 125/126 alone does not say why.
        if ($leakNote -ne '') { $tail = $leakNote + ' || ' + $tail }
    }
    # A failing suite's FULL output is the evidence; the one-line tail is only a
    # signpost. Both streams are written beside the project's other logs before
    # the finally deletes the temp copies, because the failures worth diagnosing
    # here are rare and load-dependent - by the time anyone reads the table, the
    # only run that reproduced it is over and its output is gone.
    if ($exitCode -ne 0) {
        try {
            $logDir = Join-Path (Split-Path -Parent (Split-Path -Parent $SuitePath)) 'logs'
            if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $keep = Join-Path $logDir ('failed-' + $name + '-' + [DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss') + '_UTC')
            # Strip the SGR colour escapes a child pwsh emits: this file exists to
            # be read by a human (or grepped) after the fact, and raw escapes bury
            # the message. [char]27 rather than `e - the latter is PS 6+ only and
            # this runner must also parse under Windows PowerShell 5.1.
            $ansiPattern = ([char]27) + '\[[0-9;]*m'
            [System.IO.File]::WriteAllText(($keep + '.err.log'), ([string]$errText -replace $ansiPattern, ''))
            [System.IO.File]::WriteAllText(($keep + '.out.log'), ([string]$text -replace $ansiPattern, ''))
            $tail = $tail + ' || full output: ' + $keep + '.err.log'
        }
        catch { }
    }
    return [pscustomobject]@{ Suite = $name; Exit = $exitCode; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Tail = $tail }
}
finally {
    # The owned child dies with us on EVERY path. The Job Object is the backstop
    # that catches a descendant the root leaked even after a CLEAN root exit (the
    # old clean path killed nothing); Terminate+Close with KILL_ON_JOB_CLOSE ends
    # the whole tree. taskkill is the degraded-mode fallback and belt-and-braces -
    # but only while the root is still ALIVE (an error path mid-run): once the
    # root has exited its pid may be recycled, so taskkill-by-root-pid here would
    # be a pid-reuse hazard. The degraded dead-root + live-descendant case is
    # therefore handled by the identity-bound clean-exit sweep in the try above.
    try {
        if ($null -ne $process -and -not $process.HasExited) { try { & taskkill.exe /PID $process.Id /T /F *> $null } catch { } }
    }
    catch { }
    try {
        if ($job -ne [IntPtr]::Zero) {
            [void][HookMaker.JobNative]::Terminate($job)
            [void][HookMaker.JobNative]::Close($job)
            $job = [IntPtr]::Zero
        }
    }
    catch { }
    try { if ($null -ne $stdoutWriter) { $stdoutWriter.Dispose() } } catch { }
    try { if ($null -ne $stderrWriter) { $stderrWriter.Dispose() } } catch { }
    try { if ($null -ne $process) { $process.Dispose() } } catch { }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
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
    $exclusiveResults += (& $invokeSuite $suite.FullName $host7 $TimeoutSeconds $jobCSharp)
}

if ($isolatedSuites.Count -gt 0) {
    Write-Host ('Phase 2 - ' + $isolatedSuites.Count + ' suite(s) in parallel.') -ForegroundColor DarkGray
}
$isolatedResults = @()
if ($isolatedSuites.Count -gt 0) {
    $isolatedResults = @($isolatedSuites | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $invoke = [scriptblock]::Create($using:invokeSuiteBody)
        & $invoke $_.FullName $using:host7 $using:TimeoutSeconds $using:jobCSharp
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
