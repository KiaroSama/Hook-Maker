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

[CmdletBinding()]
param(
    # The executable. Passed to ProcessStartInfo.FileName verbatim - never
    # concatenated into a command line, so spaces and metacharacters in a path
    # cannot become separate tokens or shell operators.
    [Parameter(Mandatory = $true)][string]$FilePath,

    # Arguments as an ARRAY, one element per argument. Each is added to
    # ArgumentList individually and quoted by .NET, so an argument containing
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

    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- bounded, resource-aware worker budget ---------------------------------
# Exposed for callers that want the same cap the local runner uses, so hooks,
# test frameworks and agents do not each independently decide to use every
# core. Mirrors scripts\Run-Tests.ps1 deliberately - one rule, two consumers.
function Get-GuardedWorkerBudget {
    param([int]$Requested = 0)
    $cores = [Environment]::ProcessorCount
    # Leave headroom for the OS, this runner, and log/cleanup work.
    $budget = [Math]::Max(2, [Math]::Min(8, $cores - 2))
    if ($Requested -gt 0) { $budget = [Math]::Min($Requested, $budget) }
    return $budget
}

# ---- process tree ----------------------------------------------------------

# Every live descendant of $RootId, deepest-last. Used both for resource
# sampling and for termination, so the two can never disagree about what "the
# owned tree" means.
function Get-OwnedProcessTree {
    param([int]$RootId)
    $ids = New-Object System.Collections.Generic.List[int]
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    [void]$seen.Add($RootId)
    $all = @()
    try { $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop) }
    catch { return @($RootId) }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        [void]$ids.Add($current)
        foreach ($p in $all) {
            if ($p.ParentProcessId -ne $current) { continue }
            $childId = [int]$p.ProcessId
            if ($seen.Add($childId)) { $queue.Enqueue($childId) }
        }
    }
    # NO unary comma here. Every call site already wraps this in @(), and
    # `return , $array` emits the array as ONE object, so @() would then produce
    # a one-element array whose single element is the inner array - which showed
    # up as "cannot convert System.Object[] to Int32". The plain return unrolls
    # a single id to a scalar and @() at the call site re-wraps it correctly.
    return $ids.ToArray()
}

function Get-TreeResourceSample {
    param([int[]]$ProcessIds)
    $memoryMB = 0.0
    $cpuSeconds = 0.0
    $alive = 0
    foreach ($id in @($ProcessIds)) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $alive++
            $memoryMB += ($p.WorkingSet64 / 1MB)
            try { $cpuSeconds += $p.CPU } catch { }
        }
        catch { }
    }
    return [pscustomobject]@{
        MemoryMB   = [Math]::Round($memoryMB, 1)
        CpuSeconds = [Math]::Round($cpuSeconds, 1)
        Alive      = $alive
    }
}

# Kill the tree children-first so a parent cannot respawn a child mid-teardown.
# Process.Kill($true) is .NET Core only; Windows PowerShell 5.1 needs taskkill,
# so both paths exist and the result is verified either way.
function Stop-OwnedProcessTree {
    param([int]$RootId)
    $ids = @(Get-OwnedProcessTree -RootId $RootId)
    [array]::Reverse($ids)
    foreach ($id in $ids) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            try { $p.Kill($true) } catch { $p.Kill() }
        }
        catch { }
    }
    # Belt and braces for 5.1 and for anything that outlived the managed kill.
    try { & taskkill.exe /PID $RootId /T /F *> $null } catch { }
    Start-Sleep -Milliseconds 200
    $remaining = @(@(Get-OwnedProcessTree -RootId $RootId) | Where-Object {
            try { $null = Get-Process -Id $_ -ErrorAction Stop; $true } catch { $false }
        })
    return $remaining
}

# ---- termination decision --------------------------------------------------
#
# The whole point of the runner, in one function.
#
# CPU is evidence, never a verdict. A parallel suite legitimately pins the
# machine, and a test waiting on bounded I/O legitimately sits at zero. Neither
# proves anything on its own, so neither can end a run on its own. Only a
# crossed ceiling does: total wall time, no-progress time, or resident memory.
function Test-ShouldTerminate {
    param(
        [double]$ElapsedSeconds,
        [double]$IdleSeconds,
        [double]$MemoryMB,
        [int]$WallLimit,
        [int]$IdleLimit,
        [int]$MemoryLimitMB
    )
    if ($WallLimit -gt 0 -and $ElapsedSeconds -ge $WallLimit) {
        return [pscustomobject]@{ Terminate = $true; Reason = 'wallTimeout'
            Detail = ('exceeded the ' + $WallLimit + 's wall ceiling')
        }
    }
    if ($IdleLimit -gt 0 -and $IdleSeconds -ge $IdleLimit) {
        return [pscustomobject]@{ Terminate = $true; Reason = 'idleTimeout'
            Detail = ('produced no output or state change for ' + [Math]::Round($IdleSeconds) + 's')
        }
    }
    if ($MemoryLimitMB -gt 0 -and $MemoryMB -ge $MemoryLimitMB) {
        return [pscustomobject]@{ Terminate = $true; Reason = 'memoryLimit'
            Detail = ('owned process tree reached ' + $MemoryMB + 'MB')
        }
    }
    return [pscustomobject]@{ Terminate = $false; Reason = ''; Detail = '' }
}

# ---- result document -------------------------------------------------------

$script:Result = [pscustomobject][ordered]@{
    schema           = 1
    overall          = 'unknown'
    fileName         = $FilePath
    argumentCount    = @($Arguments).Count
    workingDirectory = ''
    exitCode         = $null
    terminated       = $false
    terminateReason  = ''
    terminateDetail  = ''
    elapsedSeconds   = 0
    idleSecondsAtEnd = 0
    heartbeats       = 0
    peakMemoryMB     = 0
    cpuSeconds       = 0
    peakTreeSize     = 0
    leakedProcessIds = @()
    lastProgress     = ''
    stdoutBytes      = 0
    stderrBytes      = 0
    workerBudget     = (Get-GuardedWorkerBudget)
    startedUtc       = ''
    endedUtc         = ''
}

# The ARGUMENTS ARE NOT RECORDED. A test invocation can legitimately carry a
# token, a connection string, or a path holding a user name; the result document
# is written to disk and read by a hook, so it stays free of anything that could
# be a secret. The count is kept because "did it get the arguments I expected"
# is answerable without the values.
function Write-GuardedResult {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $dir = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = $script:Result | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($ResultPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Warning ('the guarded result document could not be written: ' + $_.Exception.Message)
    }
}

# ---- "a guarded run is live" marker ----------------------------------------
#
# Test-Completion-Check blocks completion while a guarded run is still active,
# and it proves that by checking the recorded pid is genuinely alive.
#
# ONLY THIS FILE CAN WRITE IT. Test-Run-Guard is a hook: at PreToolUse the child
# has not started, at PostToolUse it has already exited, and the run is a child
# of the CLIENT, never of the hook - so a hook could only ever guess. A guessed
# pid is worse than none, because pids are recycled and an unrelated live
# process would block completion forever. Here the pid is simply $PID.
#
# Written best-effort and removed in finally: if this file cannot be written the
# run still proceeds, and the consumer treats an absent marker as "not
# evaluated" (silence) rather than as proof that nothing is running.
$script:ActiveMarkerPath = ''
function Get-ActiveMarkerPath {
    try {
        $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
        $key = ''
        $cwdLower = ((Get-Location).Path).ToLowerInvariant()
        # Same key the hooks use. Get-ShortHash lives in hooks\_hooklib.ps1; this
        # script is standalone, so fall back to an equivalent SHA-256 prefix
        # rather than taking a dependency just for one hash.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cwdLower))
            $key = ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)
        }
        finally { $sha.Dispose() }
        return (Join-Path $stateDir ('TestRunGuard-active-' + $key + '.json'))
    }
    catch { return '' }
}

function Write-ActiveMarker {
    param([int]$OwnerPid)
    try {
        $path = Get-ActiveMarkerPath
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # ISO-8601 'o', NOT ticks: the consumer parses with
        # DateTime::TryParse(..., RoundtripKind), which a ticks string fails,
        # yielding no timestamp at all. Verified against its ConvertTo-UtcTime.
        $marker = [pscustomobject][ordered]@{
            pid        = $OwnerPid
            startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        [System.IO.File]::WriteAllText($path, ($marker | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
        $script:ActiveMarkerPath = $path
    }
    catch { }
}

function Remove-ActiveMarker {
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:ActiveMarkerPath)) {
            Remove-Item -LiteralPath $script:ActiveMarkerPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

# ---- run -------------------------------------------------------------------

# -ArgumentsJson wins when supplied: it is the only channel a `pwsh -File`
# caller can use for an argument list that starts with a switch. Parsed, never
# evaluated - ConvertFrom-Json cannot execute what it reads.
if (-not [string]::IsNullOrWhiteSpace($ArgumentsJson)) {
    $parsed = $null
    try { $parsed = $ArgumentsJson | ConvertFrom-Json }
    catch { throw ('-ArgumentsJson is not valid JSON: ' + $_.Exception.Message) }
    if ($null -eq $parsed) { $parsed = @() }
    if ($parsed -is [string] -or -not ($parsed -is [System.Collections.IEnumerable])) {
        throw '-ArgumentsJson must be a JSON ARRAY of strings, e.g. ["-NoProfile","-File","x.ps1"]'
    }
    $Arguments = @(@($parsed) | ForEach-Object { [string]$_ })
}

if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
$script:Result.workingDirectory = $WorkingDirectory
# Recomputed HERE, after -ArgumentsJson has been resolved into $Arguments. The
# initializer above runs before that resolution, so it saw an empty list and
# every JSON-invoked run reported argumentCount 0.
$script:Result.argumentCount = @($Arguments).Count
$script:Result.startedUtc = (Get-Date).ToUniversalTime().ToString('o')

$stdoutFile = [System.IO.Path]::GetTempFileName()
$stderrFile = [System.IO.Path]::GetTempFileName()
$process = $null
$stdoutWriter = $null
$stderrWriter = $null

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($argument in @($Arguments)) { [void]$psi.ArgumentList.Add([string]$argument) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false          # no shell: nothing re-parses the args
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true     # then closed immediately => EOF
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    # The run is genuinely live from here on, so the marker goes up now and
    # comes down in finally - never earlier (nothing is running yet) and never
    # later (a crash between start and here would leave it unrecorded).
    Write-ActiveMarker -OwnerPid $PID
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

    # Progress = bytes written by the pumps. Polling the streams' own Position is
    # the incremental signal that BeginOutputReadLine was meant to give us, with
    # none of its runspace problems.
    $lastBytes = -1L
    $lastChangeTicks = [DateTime]::UtcNow.Ticks

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
        if ($bytes -ne $lastBytes) { $lastBytes = $bytes; $lastChangeTicks = [DateTime]::UtcNow.Ticks }
        $idleSeconds = ([DateTime]::UtcNow.Ticks - $lastChangeTicks) / 10000000.0
        $decision = Test-ShouldTerminate -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
            -IdleSeconds $idleSeconds -MemoryMB $sample.MemoryMB `
            -WallLimit $TimeoutSeconds -IdleLimit $IdleTimeoutSeconds -MemoryLimitMB $MaxMemoryMB

        if (-not $Quiet) {
            Write-Host ('  [guard] ' + [Math]::Round($stopwatch.Elapsed.TotalSeconds) + 's  idle ' +
                [Math]::Round($idleSeconds) + 's  tree ' + $tree.Count + '  mem ' + $sample.MemoryMB +
                'MB  cpu ' + $sample.CpuSeconds + 's') -ForegroundColor DarkGray
        }

        if ($decision.Terminate) {
            $script:Result.terminated = $true
            $script:Result.terminateReason = $decision.Reason
            $script:Result.terminateDetail = $decision.Detail
            $leaked = @(Stop-OwnedProcessTree -RootId $process.Id)
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
    $script:Result.idleSecondsAtEnd = [Math]::Round((([DateTime]::UtcNow.Ticks - $lastChangeTicks) / 10000000.0), 1)
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

    if ($script:Result.terminated) { $script:Result.overall = 'terminated' }
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

    if ($script:Result.terminated) {
        Write-Host ('GUARDED RUN TERMINATED (' + $script:Result.terminateReason + '): ' +
            $script:Result.terminateDetail) -ForegroundColor Red
        if (@($script:Result.leakedProcessIds).Count -gt 0) {
            Write-Host ('WARNING: process(es) survived termination: ' +
                (@($script:Result.leakedProcessIds) -join ', ')) -ForegroundColor Red
        }
        exit 124
    }
    exit $exitCode
}
finally {
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
            $survivors = @(Stop-OwnedProcessTree -RootId $process.Id)
            if (@($survivors).Count -gt 0) {
                Write-Warning ('guarded run left process(es) alive: ' + (@($survivors) -join ', '))
            }
        }
    }
    catch { }
    # A timeout must never also leak the capture files it was writing into.
    try { if ($null -ne $stdoutWriter) { $stdoutWriter.Dispose() } } catch { }
    try { if ($null -ne $stderrWriter) { $stderrWriter.Dispose() } } catch { }
    try { if ($null -ne $process) { $process.Dispose() } } catch { }
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
}
