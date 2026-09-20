# Guarded test runner - owns ONE child process for the whole of its life and
# proves how it ended.
#
# WHY THIS EXISTS: a hook is short-lived. Test-Run-Guard fires on PreToolUse,
# returns in milliseconds, and is gone long before the test it authorised has
# finished. Nothing in that model can notice a run that hangs at minute nine.
# So the watchdog cannot live in the hook - it lives here, in the process that
# actually holds the child.
#
# What it guarantees (global-test-rules.md "Subprocess and Cleanup Contract"):
#   - executable and arguments are passed as DATA, never through a shell, never
#     through Invoke-Expression;
#   - stdin is detached, so a test that reads input gets EOF instead of hanging;
#   - stdout/stderr are drained asynchronously, so a chatty test cannot deadlock
#     on a full pipe buffer;
#   - the REAL exit code is propagated;
#   - the whole owned process tree is terminated on timeout or cancellation;
#   - output handles are flushed before diagnostics are read;
#   - temporary capture files are removed in finally;
#   - the structured result is sanitized - no secret values, no raw stdin.
#
# WHAT IT REFUSES TO DO: kill a healthy test for being busy. High CPU is what a
# working parallel suite looks like. A kill requires a wall/idle/memory ceiling
# to be crossed, never CPU alone. See Test-ShouldTerminate.
#
# Usage:
#   .\scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -Arguments '-File','.\scripts\Run-Tests.ps1'
#   .\scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -Arguments '-File','x.ps1' -ResultPath r.json
#
# Exit code: the child's own exit code, or 124 when this runner terminated it.
#
# HookMaker-Guarded-Runner-Contract: v2
# Stable identity marker. Test-Run-Guard's Find-GuardedRunner reads a candidate
# file and returns it ONLY when this exact line is present, so an unrelated
# script that merely shares the name scripts\Run-Tests-Guarded.ps1 can never be
# invoked as the bounded runner. Keep the string byte-for-byte.

[CmdletBinding()]
param(
    # The executable. Passed to ProcessStartInfo.FileName verbatim - never
    # concatenated into a command line, so spaces and metacharacters in a path
    # cannot become separate tokens or shell operators.
    [Parameter(Mandatory = $true)][string]$FilePath,

    # Arguments as an ARRAY, one element per argument. Each is added to
    # ArgumentList individually and quoted by .NET (or equivalent Win32
    # quoting on Windows PowerShell 5.1), so an argument containing
    # spaces, quotes, &, |, ; or > stays exactly one argument.
    #
    # Usable from PowerShell callers. NOT usable from a `pwsh -File` command
    # line whose first argument starts with '-': PowerShell's -File parser reads
    # the value as the next PARAMETER NAME and reports "Missing an argument for
    # parameter 'Arguments'". Since virtually every real test command begins
    # with a switch (`-NoProfile`, `--filter`, `-m`), a CLI caller - which is
    # exactly what Test-Run-Guard is - must use -ArgumentsJson instead.
    [string[]]$Arguments = @(),

    # The same list as a JSON array, e.g. '["-NoProfile","-File","x.ps1"]'.
    # Unambiguous across every invocation style: it starts with '[', so no
    # parser mistakes it for a parameter name, and JSON quoting survives spaces,
    # quotes and metacharacters without any shell involvement. Parsed with
    # ConvertFrom-Json - never evaluated. Wins over -Arguments when both appear.
    [string]$ArgumentsJson = '',

    [string]$WorkingDirectory = '',

    # The resource-aware worker ceiling the OBSERVING hook resolved (its
    # TEST_GUARD_MAX_WORKERS). 0 = the hook set no cap. It is folded through
    # Get-GuardedWorkerBudget together with the local formula and any ambient
    # HOOKMAKER_MAX_TEST_WORKERS, so the number can only TIGHTEN, never raise a
    # stricter pre-existing value; the result is exported to the child so an
    # env-aware runner (scripts\Run-Tests.ps1) clamps itself to the same ceiling
    # this runner reports. Frameworks that ignore the variable stay advisory.
    [int]$MaxWorkers = 0,

    # Total wall ceiling. A ceiling, not an expected duration.
    [int]$TimeoutSeconds = 1800,

    # No output AND no state change for this long => treated as no progress.
    # Only meaningful together with the health evidence in Test-ShouldTerminate.
    [int]$IdleTimeoutSeconds = 300,

    # How often to sample. Also the resolution of the heartbeat.
    [int]$HeartbeatSeconds = 10,

    # Resident memory ceiling for the whole owned tree. 0 disables it: there is
    # no universal correct value, and a wrong one kills valid work.
    [int]$MaxMemoryMB = 0,

    # Written as JSON. MUST NOT be inside a directory the test itself writes to.
    [string]$ResultPath = '',

    # ---- run-identity contract (Test-Run-Guard passes these as DATA) ----------
    # A cryptographically random id minted by Test-Run-Guard at PreToolUse for
    # the recognised test intent, echoed here so the consumer can prove THIS
    # result belongs to THAT observation and not a stale one. Empty when the
    # runner was invoked directly (no hook), in which case one is generated so
    # the result still carries a stable identity.
    [string]$RunId = '',

    # The observing hook's repository-state fingerprint, persisted verbatim so the
    # consumer can reject a result produced for a different repository/state. Not
    # recomputed here: the hook owns the git-state derivation.
    # Absent, the receipt records an empty one and is not usable as recovery
    # evidence (_recovery.ps1 requires it and now says so by name). The guard's
    # own replacement command always supplies it; a hand-typed run must too.
    [string]$ProjectFingerprint = '',

    # Optional, for audit only. The command fingerprint is RECOMPUTED below from
    # the real -FilePath/-Arguments (a passed value cannot be trusted to identify
    # what actually ran); if a value is supplied and disagrees, the run fails
    # closed rather than persisting a spoofable identity.
    [string]$CommandFingerprint = '',

    # Optional heartbeat/progress file. Its last-write time advancing counts as
    # progress, so a silent long-running step can prove liveness without printing.
    [string]$ProgressFile = '',

    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- the three siblings this runner is split across ------------------------
#
# FAIL CLOSED, AND THAT IS THE WHOLE POINT OF THIS STANZA. This runner exists
# to OWN a test process for its entire life; a copy of it that cannot load its
# own siblings must refuse to run rather than run something it cannot watch.
# Degrading to an unguarded run would be the one failure this file must never
# produce - the caller would get a green exit code for a run with no wall
# ceiling, no idle ceiling and no process-tree cleanup.
#
# The three carry, in order: the worker budget and the rolling timing history;
# the run's identity helpers, its result document and its live-run marker; and
# the Job Object, the process tree and the termination decision.
$script:GuardedRunnerRoot = Split-Path -Parent $PSCommandPath
foreach ($sibling in @('_guardedtiming.ps1', '_guardedstate.ps1', '_guardedprocess.ps1')) {
    $siblingPath = Join-Path $script:GuardedRunnerRoot $sibling
    if (-not (Test-Path -LiteralPath $siblingPath -PathType Leaf)) {
        [Console]::Error.WriteLine('Run-Tests-Guarded: missing required sibling ' + $sibling + ' - refusing to run unguarded.')
        exit 3
    }
    . $siblingPath
}

# ---- run -------------------------------------------------------------------

# -ArgumentsJson wins when supplied: it is the only channel a `pwsh -File`
# caller can use for an argument list that starts with a switch. Parsed, never
# evaluated - ConvertFrom-Json cannot execute what it reads.
if (-not [string]::IsNullOrWhiteSpace($ArgumentsJson)) {
    # "Is it an array?" is answered from the TEXT, not from the deserialized
    # object, because the pipeline ENUMERATES: '["x"]' | ConvertFrom-Json yields
    # the bare string "x", indistinguishable from the scalar '"x"'. Testing the
    # object therefore rejected every SINGLE-argument list - `node test.js`, the
    # most ordinary case there is - while accepting two or more. Verified on
    # pwsh 7: one element -> String, two -> Object[].
    #
    # -NoEnumerate would answer it directly but does not exist on Windows
    # PowerShell 5.1, and this runner deliberately keeps 5.1 parity (see the
    # taskkill and GetFullPath notes above), so the check stays textual.
    $jsonText = $ArgumentsJson.TrimStart([char[]]@(' ', "`t", "`r", "`n", [char]0xFEFF))
    if (-not $jsonText.StartsWith('[')) {
        throw '-ArgumentsJson must be a JSON ARRAY of strings, e.g. ["-NoProfile","-File","x.ps1"] (a single argument is still an array: ["x"])'
    }
    $parsed = $null
    try { $parsed = $ArgumentsJson | ConvertFrom-Json }
    catch { throw ('-ArgumentsJson is not valid JSON: ' + $_.Exception.Message) }
    if ($null -eq $parsed) { $parsed = @() }
    # An element that is not a JSON primitive would stringify to something like
    # "System.Management.Automation.PSCustomObject" and be handed to the child as
    # a real argument - silent garbage rather than a refusal.
    foreach ($element in @($parsed)) {
        if ($null -ne $element -and ($element -is [System.Collections.IEnumerable]) -and -not ($element -is [string])) {
            throw '-ArgumentsJson elements must be strings, numbers or booleans - not arrays or objects'
        }
        if ($null -ne $element -and $element.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject') {
            throw '-ArgumentsJson elements must be strings, numbers or booleans - not arrays or objects'
        }
    }
    $Arguments = @(@($parsed) | ForEach-Object { [string]$_ })
}

if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
# Canonicalize ONCE so the marker key, the child's cwd, and result.projectKey all
# derive from the same absolute path. A relative -WorkingDirectory is resolved
# against Get-Location first (GetFullPath alone would use the stale process
# CurrentDirectory, which PowerShell does not keep in sync). 2-arg GetFullPath is
# .NET-Core-only, so the rooted-guard + Combine form is used for 5.1 parity.
try {
    if (-not [System.IO.Path]::IsPathRooted($WorkingDirectory)) {
        $WorkingDirectory = [System.IO.Path]::Combine((Get-Location).Path, $WorkingDirectory)
    }
    $WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    # TrimEnd, because GetFullPath PRESERVES a trailing separator: "C:\p\" and
    # "C:\p" are the same directory but hash to different keys, which splits one
    # project's timing history and result identity in two. Same canonical form
    # as hooks\_hooklib.ps1's Normalize-Path, which the hooks use to key the
    # files this runner's results are paired with. Inlined rather than shared:
    # this runner is deliberately standalone (it never dot-sources _hooklib).
    $WorkingDirectory = $WorkingDirectory.TrimEnd([char[]]@(
            [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}
catch { }
$script:Result.workingDirectory = $WorkingDirectory
# Recomputed HERE, after -ArgumentsJson has been resolved into $Arguments. The
# initializer above runs before that resolution, so it saw an empty list and
# every JSON-invoked run reported argumentCount 0.
$script:Result.argumentCount = @($Arguments).Count

# ---- run identity: minted or echoed, computed once the args are resolved ----
# runId: echo the hook's id when given, else generate one so a direct/manual run
# still carries a stable identity. A hook-controlled id lets the consumer demand
# an EXACT match; a self-generated one still binds the result to this run.
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
$script:Result.runId = $RunId
$script:Result.projectKey = (Get-ProjectKey $WorkingDirectory)

# PER-RUN result document. The observing hook already builds a per-run -ResultPath
# (TestRunGuard-result-<key>-<runId>.json); a managed path handed in WITHOUT the
# runId (a legacy/base path) is upgraded here so two concurrent guarded runs in
# one project can never overwrite each other's result. A caller-chosen path that
# is not a managed state file (e.g. a test's own r.json) is left untouched - the
# caller owns its uniqueness.
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $safeRunId = Get-SafeRunId $RunId
    $resultDir = Split-Path -Parent $ResultPath
    $resultName = Split-Path -Leaf $ResultPath
    if ($resultName -like 'TestRunGuard-result-*.json' -and $resultName -notlike ('*-' + $safeRunId + '.json')) {
        $resultName = $resultName.Substring(0, $resultName.Length - 5) + '-' + $safeRunId + '.json'
        $ResultPath = if ([string]::IsNullOrWhiteSpace($resultDir)) { $resultName } else { Join-Path $resultDir $resultName }
    }
}

# THE CANONICAL EVIDENCE PATH, computed with the same key and naming the
# observing hook uses to enumerate results. Every terminal result is published
# here as well as to whatever path the caller chose, so a caller-selected file
# stops being invisible to the gate that has to read it.
$script:CanonicalResultPath = ''
try {
    $stateDir = [string]$env:HOOKMAKER_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($stateDir)) { $stateDir = (Join-Path $env:LOCALAPPDATA 'HookMaker\state') }
    if (-not [string]::IsNullOrWhiteSpace($stateDir)) {
        # Get-StateKey (10 chars), NOT $script:Result.projectKey (12). Both are
        # intentional and they are NOT interchangeable: the result document's
        # metadata key is 12, while every coordination FILENAME the consumer
        # enumerates is keyed by Get-ShortHash's 10. Publishing under the metadata
        # key would put the canonical copy somewhere the hook still never looks -
        # the original bug wearing a different hat.
        $script:CanonicalResultPath = Join-Path $stateDir (
            'TestRunGuard-result-' + (Get-StateKey $WorkingDirectory) + '-' + (Get-SafeRunId $RunId) + '.json')
    }
}
catch { $script:CanonicalResultPath = '' }
$script:Result.projectFingerprint = $ProjectFingerprint
# Command fingerprint is RECOMPUTED from what actually runs. If a value was
# passed and disagrees, fail closed rather than persist a spoofable identity.
$computedCommandFp = Get-CommandFingerprint -ExecutablePath $FilePath -ArgumentList $Arguments
if (-not [string]::IsNullOrWhiteSpace($CommandFingerprint) -and $CommandFingerprint -ne $computedCommandFp) {
    throw ('-CommandFingerprint (' + $CommandFingerprint + ') does not match the fingerprint of the executable + arguments actually being run (' + $computedCommandFp + '); refusing to run under a mismatched identity.')
}
$script:Result.commandFingerprint = $computedCommandFp

$script:Result.startedUtc = (Get-Date).ToUniversalTime().ToString('o')

$stdoutFile = [System.IO.Path]::GetTempFileName()
$stderrFile = [System.IO.Path]::GetTempFileName()
$process = $null
$stdoutWriter = $null
$stderrWriter = $null
$script:JobHandle = [IntPtr]::Zero
$script:ResultWritten = $false

try {
    # Establish the Job Object BEFORE the child starts so the root can be assigned
    # to it the instant it exists. If this fails, ownership degrades to the
    # ppid-walk kill and the result says so - it never claims a safety it lacks.
    $jobReady = Initialize-JobObjectType
    if ($jobReady) {
        try { $script:JobHandle = [HookMaker.JobNative]::CreateKillOnClose() } catch { $script:JobHandle = [IntPtr]::Zero }
    }
    $script:Result.processOwnership = if ($script:JobHandle -ne [IntPtr]::Zero) { 'jobObject' } else { 'degraded' }

    # A PATH-LIKE -FilePath is resolved HERE, because .NET will not resolve it
    # against WorkingDirectory and will silently fall back to PATH instead.
    #
    # With UseShellExecute = $false a relative FileName is resolved against the
    # CALLING process's current directory and then PATH; WorkingDirectory only
    # sets the child's cwd and takes no part in finding the executable. Verified:
    # a file that exists inside WorkingDirectory still fails to start.
    #
    # So `-FilePath .venv/Scripts/python.exe -WorkingDirectory <project>` did not
    # fail - it found the SYSTEM python on PATH and ran the tests with the wrong
    # interpreter, reporting ModuleNotFoundError for the project's dependencies.
    # A guarded run that silently executes a different program than the one named
    # is worse than one that refuses. Reported from real use.
    #
    # A BARE NAME still means "use PATH" - but we do the PATH lookup ourselves,
    # because .NET's does not apply PATHEXT. Process.Start('npm') throws "The
    # system cannot find the file specified" on Windows, since npm ships as
    # npm.cmd, not npm.exe. That made the guard emit `-FilePath "npm"` - a
    # command that could never start, so no result document was ever written and
    # the completion gate could never be closed. Reported from real use, and
    # reproduced directly: bare 'npm' throws, 'npm.cmd' starts.
    #
    # .ps1 is deliberately NOT a candidate: PATHEXT lists it, but with
    # UseShellExecute = $false there is no interpreter attached, so starting it
    # fails the same way. (On this machine `Get-Command npm` even resolves to
    # npm.ps1 - which is exactly the wrong answer for Process.Start.)
    #
    # Unresolvable names are passed through UNCHANGED rather than refused: this
    # is a convenience lookup, and .NET may still find something we did not model.
    $resolvedFilePath = $FilePath
    if ($FilePath.IndexOfAny([char[]]@('\', '/')) -lt 0) {
        $startable = @('.COM', '.EXE', '.BAT', '.CMD')
        $pathExt = @(([string]$env:PATHEXT -split ';') | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and ($startable -contains $_.ToUpperInvariant()) })
        if ($pathExt.Count -eq 0) { $pathExt = @('.EXE', '.CMD', '.BAT') }
        # @() around the pipeline: under StrictMode a single result has no .Count.
        $hasKnownExt = @($pathExt | Where-Object { $FilePath.EndsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        foreach ($dir in @(([string]$env:PATH -split ';') | Where-Object { $_ -ne '' })) {
            $hit = ''
            try {
                if ($hasKnownExt) {
                    $direct = [System.IO.Path]::Combine($dir, $FilePath)
                    if (Test-Path -LiteralPath $direct -PathType Leaf) { $hit = $direct }
                }
                else {
                    foreach ($ext in $pathExt) {
                        $candidate = [System.IO.Path]::Combine($dir, $FilePath + $ext)
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $hit = $candidate; break }
                    }
                }
            }
            catch { }      # an unusable PATH entry is skipped, never fatal
            if ($hit -ne '') { $resolvedFilePath = $hit; break }
        }
    }
    elseif ($FilePath.IndexOfAny([char[]]@('\', '/')) -ge 0) {
        $candidates = New-Object System.Collections.Generic.List[string]
        if ([System.IO.Path]::IsPathRooted($FilePath)) { [void]$candidates.Add($FilePath) }
        else {
            [void]$candidates.Add([System.IO.Path]::Combine($WorkingDirectory, $FilePath))
            [void]$candidates.Add([System.IO.Path]::Combine((Get-Location).Path, $FilePath))
        }
        $found = ''
        foreach ($candidate in $candidates) {
            $full = $candidate
            try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { }
            if (Test-Path -LiteralPath $full -PathType Leaf) { $found = $full; break }
        }
        if ($found -eq '') {
            throw ('-FilePath "' + $FilePath + '" does not exist. A path-like -FilePath is NOT resolved against ' +
                '-WorkingDirectory by the OS, and falling back to PATH would run a different program than the one ' +
                'named. Looked in: ' + (@($candidates) -join ' ; ') + '. Pass an absolute -FilePath, or a bare ' +
                'command name to use PATH deliberately.')
        }
        $resolvedFilePath = $found
    }
    # Record what was actually started, not what was asked for, so the result
    # document names the exact executable if this ever has to be diagnosed again.
    $script:Result.fileName = $resolvedFilePath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolvedFilePath
    if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
        foreach ($argument in @($Arguments)) { [void]$psi.ArgumentList.Add([string]$argument) }
    }
    else {
        # .NET Framework has only Arguments. Preserve the standalone runner
        # contract with the same Win32 escaping as ConvertTo-Win32ArgumentString:
        # double backslashes before quotes and before the closing quote.
        $psi.Arguments = (@(foreach ($argument in @($Arguments)) {
            $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
            '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
        }) -join ' ')
    }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false          # no shell: nothing re-parses the args
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true     # then closed immediately => EOF
    $psi.CreateNoWindow = $true
    # Hand the resolved ceiling down to the child. UseShellExecute=$false means
    # EnvironmentVariables is seeded from THIS process, so the child inherits it;
    # we overwrite just this one key with the already-min'd budget (line ~474),
    # which is <= any ambient value, so a stricter pre-existing ceiling is never
    # raised. A runner that reads HOOKMAKER_MAX_TEST_WORKERS clamps to it; one
    # that does not simply ignores it. Reported as workerBudget, so "what the
    # child was told" and "what the result claims" are the same number.
    $psi.EnvironmentVariables['HOOKMAKER_MAX_TEST_WORKERS'] = [string]$script:Result.workerBudget

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    # Assign the root to the job the instant it exists, before it can spawn a
    # descendant that escapes ownership. (A CREATE_SUSPENDED start would close the
    # tiny remaining window entirely, but ProcessStartInfo does not expose it; the
    # KILL_ON_JOB_CLOSE backstop still catches anything the root itself spawns.)
    if ($script:JobHandle -ne [IntPtr]::Zero) {
        $assigned = $false
        try { $assigned = [HookMaker.JobNative]::Assign($script:JobHandle, $process.Handle) } catch { $assigned = $false }
        if (-not $assigned) {
            # Could not take ownership - do NOT claim we did.
            try { [void][HookMaker.JobNative]::Close($script:JobHandle) } catch { }
            $script:JobHandle = [IntPtr]::Zero
            $script:Result.processOwnership = 'degraded'
        }
    }
    # The run is genuinely live from here on, so the marker goes up now and
    # comes down in finally - never earlier (nothing is running yet) and never
    # later (a crash between start and here would leave it unrecorded).
    Write-ActiveMarker -OwnerPid $PID -RunId $RunId -ProjectFingerprint $ProjectFingerprint -ProjectPath $WorkingDirectory
    # Detach stdin NOW: an interactive prompt then reads EOF and the test fails
    # fast and honestly, instead of blocking until a timeout hides the cause.
    try { $process.StandardInput.Close() } catch { }

    # Drain both pipes continuously, INSIDE .NET, straight into files.
    #
    # Deliberately not Register-ObjectEvent: a PowerShell -Action handler runs in
    # its own runspace, so `$script:` writes inside it never reach this scope,
    # and concurrent StreamWriter access from that runspace deadlocked a real
    # test run of this very file. CopyToAsync has no PowerShell involvement at
    # all - the runtime pumps both streams, so a chatty test can never fill a
    # pipe buffer and stall, and the file length gives a progress signal to poll.
    $stdoutWriter = [System.IO.File]::Create($stdoutFile)
    $stderrWriter = [System.IO.File]::Create($stderrFile)
    $stdoutPump = $process.StandardOutput.BaseStream.CopyToAsync($stdoutWriter)
    $stderrPump = $process.StandardError.BaseStream.CopyToAsync($stderrWriter)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $peakMemory = 0.0
    $peakTree = 0
    $cpuSeconds = 0.0
    $heartbeats = 0
    $decision = [pscustomobject]@{ Terminate = $false; Reason = ''; Detail = '' }

    # NO-PROGRESS, not output-idle. The old model reset the timer only on OUTPUT
    # bytes, so a silent CPU-bound computation - legitimate, just not chatty - got
    # killed at the idle ceiling despite making real progress. Progress is now ANY
    # of: output-byte growth, a meaningful cumulative-CPU advance in the owned
    # tree, an owned process-tree membership change, or (optional) a heartbeat/
    # progress file's write time advancing. High CPU is progress EVIDENCE, never a
    # kill reason; only sustained no-progress (or the wall/memory ceilings) ends a
    # run. A silent BUSY computation keeps advancing CPU and is never idle-killed;
    # a silent SLEEPING/waiting process advances none of these and eventually is.
    $cpuProgressEpsilon = 0.1     # CPU-seconds of tree advance that counts as progress
    $lastBytes = -1L
    $lastCpu = -1.0
    $lastTreeCount = -1
    $lastProgressFileTicks = 0L
    $lastProgressTicks = [DateTime]::UtcNow.Ticks

    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds ([Math]::Max(250, $HeartbeatSeconds * 1000))
        if ($process.HasExited) { break }
        $heartbeats++

        $tree = @(Get-OwnedProcessTree -RootId $process.Id)
        $sample = Get-TreeResourceSample -ProcessIds $tree
        if ($sample.MemoryMB -gt $peakMemory) { $peakMemory = $sample.MemoryMB }
        if ($tree.Count -gt $peakTree) { $peakTree = $tree.Count }
        $cpuSeconds = $sample.CpuSeconds

        $bytes = 0L
        try { $bytes = $stdoutWriter.Position + $stderrWriter.Position } catch { }

        $progressFileTicks = 0L
        if (-not [string]::IsNullOrWhiteSpace($ProgressFile)) {
            try { if (Test-Path -LiteralPath $ProgressFile -PathType Leaf) { $progressFileTicks = (Get-Item -LiteralPath $ProgressFile -Force).LastWriteTimeUtc.Ticks } } catch { }
        }

        # Any one signal advancing resets the no-progress clock.
        $madeProgress = $false
        if ($bytes -ne $lastBytes) { $madeProgress = $true }
        if ($lastCpu -ge 0 -and ($sample.CpuSeconds - $lastCpu) -ge $cpuProgressEpsilon) { $madeProgress = $true }
        if ($lastTreeCount -ge 0 -and $tree.Count -ne $lastTreeCount) { $madeProgress = $true }
        if ($progressFileTicks -gt $lastProgressFileTicks) { $madeProgress = $true }
        # First sample establishes the baselines without counting as progress.
        if ($lastBytes -lt 0 -or $lastCpu -lt 0 -or $lastTreeCount -lt 0) { $madeProgress = $true }
        $lastBytes = $bytes; $lastCpu = $sample.CpuSeconds; $lastTreeCount = $tree.Count; $lastProgressFileTicks = $progressFileTicks
        if ($madeProgress) { $lastProgressTicks = [DateTime]::UtcNow.Ticks }

        $noProgressSeconds = ([DateTime]::UtcNow.Ticks - $lastProgressTicks) / 10000000.0
        $decision = Test-ShouldTerminate -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
            -IdleSeconds $noProgressSeconds -MemoryMB $sample.MemoryMB `
            -WallLimit $TimeoutSeconds -IdleLimit $IdleTimeoutSeconds -MemoryLimitMB $MaxMemoryMB

        if (-not $Quiet) {
            Write-Host ('  [guard] ' + [Math]::Round($stopwatch.Elapsed.TotalSeconds) + 's  no-progress ' +
                [Math]::Round($noProgressSeconds) + 's  tree ' + $tree.Count + '  mem ' + $sample.MemoryMB +
                'MB  cpu ' + $sample.CpuSeconds + 's') -ForegroundColor DarkGray
        }

        if ($decision.Terminate) {
            $script:Result.terminated = $true
            $script:Result.terminateReason = $decision.Reason
            $script:Result.terminateDetail = $decision.Detail
            $leaked = @(Stop-OwnedProcessTree -RootId $process.Id -JobHandle $script:JobHandle)
            $script:Result.leakedProcessIds = @($leaked)
            break
        }
    }

    # BOUNDED wait. The parameterless overload also waits for the output pipes to
    # close, and a grandchild that inherited those handles keeps them open after
    # its parent dies - which is a hang in the one file whose entire job is to
    # not hang. A ceiling here cannot deadlock; the pumps are awaited separately
    # below, also bounded.
    try { [void]$process.WaitForExit(15000) } catch { }
    $stopwatch.Stop()

    # Give the pumps a bounded moment to flush the tail of the output. Whatever
    # has not arrived by then is genuinely stuck behind a surviving grandchild
    # and is not worth hanging for.
    foreach ($pump in @($stdoutPump, $stderrPump)) {
        try { [void]$pump.Wait(5000) } catch { }
    }
    try { $stdoutWriter.Flush(); $stdoutWriter.Dispose(); $stdoutWriter = $null } catch { }
    try { $stderrWriter.Flush(); $stderrWriter.Dispose(); $stderrWriter = $null } catch { }

    $exitCode = 0
    try { $exitCode = $process.ExitCode } catch { $exitCode = 124 }

    $script:Result.exitCode = $exitCode
    $script:Result.elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    $script:Result.noProgressSeconds = [Math]::Round((([DateTime]::UtcNow.Ticks - $lastProgressTicks) / 10000000.0), 1)
    $script:Result.heartbeats = $heartbeats
    $script:Result.peakMemoryMB = $peakMemory
    $script:Result.cpuSeconds = $cpuSeconds
    $script:Result.peakTreeSize = $peakTree
    # Last meaningful line the run produced - what someone actually wants to see
    # when asking "where was it when it stopped". Read from the captured file now
    # that the pumps have flushed, rather than tracked live.
    #
    # NOTE ON CONTENT: this is text the TEST chose to print, not anything this
    # runner was given. The runner's own inputs - the command line and its
    # argument values - are never recorded (see argumentCount above), because
    # those are where a token or connection string would realistically appear.
    # Test output is bounded here rather than dropped: the rules require the
    # last known progress, and it already reaches the console and CI logs.
    try {
        $tail = @([System.IO.File]::ReadAllLines($stdoutFile) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tail.Count -gt 0) {
            $line = [string]$tail[$tail.Count - 1]
            if ($line.Length -gt 300) { $line = $line.Substring(0, 300) + '...' }
            $script:Result.lastProgress = $line
        }
    }
    catch { }
    try { $script:Result.stdoutBytes = (Get-Item -LiteralPath $stdoutFile).Length } catch { }
    try { $script:Result.stderrBytes = (Get-Item -LiteralPath $stderrFile).Length } catch { }
    $script:Result.endedUtc = (Get-Date).ToUniversalTime().ToString('o')

    # ORPHAN DESCENDANTS AFTER A NORMAL EXIT. The timeout path already records
    # what survived a forced kill; this is the other leak - the root exits (often
    # 0) but leaves a background child alive. Any found are a leak: record them,
    # then kill the owned tree/job so nothing outlives this runner. overall can
    # never be 'ok' while a descendant the parent leaked is still alive, so a
    # found orphan forces overall away from 'ok' even on exit 0.
    #
    # OWNERSHIP IS PROVEN BY THE JOB OBJECT, NOT A PPID WALK. Once the root exits
    # its pid can be recycled; a ppid walk over Win32_Process would then find an
    # UNRELATED process's children hanging off the reused pid and call them
    # "orphans of the child" - a pid-reuse false leak that flipped a clean exit to
    # 'failed' and made the exit-code assertion flake. The job's assigned-process
    # list cannot do that: a recycled pid was never assigned to THIS job, so it is
    # structurally excluded, while a genuine leaked descendant is still in the job
    # and still alive and is still reported. The ppid walk survives ONLY as the
    # degraded fallback when there is no job (processOwnership='degraded'), where it
    # remains pid-reuse-vulnerable - the reason the job list is preferred.
    if (-not $script:Result.terminated) {
        $jobOwned = Get-JobOwnedProcessIds -JobHandle $script:JobHandle
        if ($jobOwned.Available) {
            $orphans = @(@($jobOwned.Ids) |
                Where-Object { $_ -ne $process.Id } |
                Where-Object { try { $null = Get-Process -Id $_ -ErrorAction Stop; $true } catch { $false } })
        }
        else {
            $orphans = @(@(Get-OwnedProcessTree -RootId $process.Id) |
                Where-Object { $_ -ne $process.Id } |
                Where-Object { try { $null = Get-Process -Id $_ -ErrorAction Stop; $true } catch { $false } })
        }
        if ($orphans.Count -gt 0) {
            $script:Result.leakedProcessIds = @($orphans)
            $survivors = @(Stop-OwnedProcessTree -RootId $process.Id -JobHandle $script:JobHandle)
            $script:Result.terminateReason = 'orphanLeak'
            $script:Result.terminateDetail = ('the test process exited but left ' + $orphans.Count +
                ' descendant process(es) alive (' + (@($orphans) -join ', ') + '); a guarded run must own its whole tree' +
                $(if (@($survivors).Count -gt 0) { ' - ' + @($survivors).Count + ' could not be terminated and remain leaked' } else { ' - all were terminated' }))
        }
    }

    if ($script:Result.terminated) { $script:Result.overall = 'terminated' }
    elseif (@($script:Result.leakedProcessIds).Count -gt 0) { $script:Result.overall = 'failed' }
    elseif ($exitCode -eq 0) { $script:Result.overall = 'ok' }
    else { $script:Result.overall = 'failed' }

    # Diagnostics belong on the console, not only in a temp file that is about
    # to be deleted.
    if (-not $Quiet) {
        try {
            $text = [System.IO.File]::ReadAllText($stdoutFile)
            if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host $text }
        }
        catch { }
        try {
            $errText = [System.IO.File]::ReadAllText($stderrFile)
            if (-not [string]::IsNullOrWhiteSpace($errText)) { Write-Host $errText -ForegroundColor Red }
        }
        catch { }
    }

    Write-GuardedResult
    $script:ResultWritten = $true
    # HM-07: record this run's sanitized timing sample (best-effort, never alters
    # the outcome). All outcomes are stored; only ok runs become baseline samples.
    Save-TimingSample

    if ($script:Result.terminated) {
        Write-Host ('GUARDED RUN TERMINATED (' + $script:Result.terminateReason + '): ' +
            $script:Result.terminateDetail) -ForegroundColor Red
        if (@($script:Result.leakedProcessIds).Count -gt 0) {
            Write-Host ('WARNING: process(es) survived termination: ' +
                (@($script:Result.leakedProcessIds) -join ', ')) -ForegroundColor Red
        }
        exit 124
    }
    # A run that exited on its own but leaked descendants is NOT a pass: surface a
    # distinct non-zero code (125) so a direct caller sees it, while the result
    # document's overall='failed' + leakedProcessIds tell the hooks the full story.
    if (@($script:Result.leakedProcessIds).Count -gt 0) {
        Write-Host ('GUARDED RUN LEAKED process(es) after a clean exit: ' +
            (@($script:Result.leakedProcessIds) -join ', ')) -ForegroundColor Red
        exit 125
    }
    exit $exitCode
}
finally {
    # A result document must exist on EVERY terminal path. If an unexpected error
    # above skipped the normal write, persist what is known now (overall stays
    # 'unknown' / whatever was set) so the consumer sees an honest incomplete
    # record rather than nothing - silence would read as "no run happened".
    if (-not $script:ResultWritten) {
        if ($script:Result.overall -eq 'unknown') { $script:Result.overall = 'error' }
        if ([string]::IsNullOrWhiteSpace([string]$script:Result.endedUtc)) {
            $script:Result.endedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        try { Write-GuardedResult } catch { }
        try { Save-TimingSample } catch { }
    }
    # The marker must never outlive this process: a stale one would make
    # Test-Completion-Check block completion on a run that ended long ago.
    Remove-ActiveMarker
    # THE OWNED CHILD DIES WITH US. Disposing the Process object only releases a
    # handle - it does not stop anything, so any unexpected error above used to
    # leave the test running with no parent. A real orphaned `hang.ps1` was
    # found this way: its guard had exited and it was still spinning. The kill
    # therefore lives here, on every path out, not only in the timeout branch.
    try {
        if ($null -ne $process -and -not $process.HasExited) {
            $survivors = @(Stop-OwnedProcessTree -RootId $process.Id -JobHandle $script:JobHandle)
            if (@($survivors).Count -gt 0) {
                Write-Warning ('guarded run left process(es) alive: ' + (@($survivors) -join ', '))
            }
        }
    }
    catch { }
    # Close the Job Object handle LAST. With KILL_ON_JOB_CLOSE, closing the final
    # handle makes the OS terminate anything still in the job - the crash-proof
    # backstop that catches whatever an exception above skipped, even a descendant
    # the ppid walk could not see.
    try {
        if ($script:JobHandle -ne [IntPtr]::Zero) {
            [void][HookMaker.JobNative]::Terminate($script:JobHandle)
            [void][HookMaker.JobNative]::Close($script:JobHandle)
            $script:JobHandle = [IntPtr]::Zero
        }
    }
    catch { }
    # A timeout must never also leak the capture files it was writing into.
    try { if ($null -ne $stdoutWriter) { $stdoutWriter.Dispose() } } catch { }
    try { if ($null -ne $stderrWriter) { $stderrWriter.Dispose() } } catch { }
    try { if ($null -ne $process) { $process.Dispose() } } catch { }
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
}
