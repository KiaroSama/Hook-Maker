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
    # The same project-wide ceiling scripts\Run-Tests.ps1 applies. "One rule,
    # two consumers" only holds if the override reaches BOTH - otherwise the
    # workerBudget reported in the result document would contradict the number
    # the local runner actually ran with.
    if (-not [string]::IsNullOrWhiteSpace($env:HOOKMAKER_MAX_TEST_WORKERS)) {
        $ceiling = 0
        if ([int]::TryParse($env:HOOKMAKER_MAX_TEST_WORKERS, [ref]$ceiling) -and $ceiling -ge 1) {
            $budget = [Math]::Min($budget, $ceiling)
        }
    }
    return $budget
}

# ---- run identity ----------------------------------------------------------

# SHA-256 prefix over the structured executable + argument ARRAY, joined by a NUL
# that cannot appear in a Windows argument, then lowercased. Computed from the
# real (FileName, ArgumentList), never from a re-joined shell string, so "what
# ran" has ONE canonical identity that the observing hook and this runner both
# derive the same way. Standalone SHA (this script does not dot-source _hooklib).
function Get-CommandFingerprint {
    param([string]$ExecutablePath, [string[]]$ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add(([string]$ExecutablePath).ToLowerInvariant())
    foreach ($a in @($ArgumentList)) { [void]$parts.Add([string]$a) }
    $joined = ($parts.ToArray() -join "`0")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 32)
    }
    finally { $sha.Dispose() }
}

# The canonical project key the hooks use: SHA-256 prefix of the lowercased cwd.
function Get-ProjectKey {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(([string]$Path).ToLowerInvariant()))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)
    }
    finally { $sha.Dispose() }
}

# The 10-char state-file key, byte-identical to hooks\_hooklib.ps1's Get-ShortHash
# (SHA-256 prefix of the lowercased cwd, 10 hex). The active-marker filename MUST
# use this length: the consumer (Test-Completion-Check) derives the key with
# Get-ShortHash and would never find a marker written under a different-length key.
function Get-StateKey {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(([string]$Path).ToLowerInvariant()))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally { $sha.Dispose() }
}

# Filename-safe form of a runId: lowercased, non [a-z0-9] stripped. runIds are
# 32-hex GUIDs (minted) or short injected tokens; this keeps the per-run state
# filename unambiguous. Never empty here - the caller resolves a runId first.
function Get-SafeRunId {
    param([string]$RunId)
    $safe = ([string]$RunId).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($safe -eq '') { $safe = (Get-StateKey ([string]$RunId)) }
    return $safe
}

# ---- Windows Job Object (crash-proof ownership of the whole tree) -----------
#
# A test parent can spawn a background child, exit 0, and leave the child alive -
# a normal-exit orphan the timeout path never sees. A Job Object with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE makes the OS itself the backstop: when the
# LAST handle to the job closes (this runner exiting, even on a crash), every
# process still in the job dies. The root is assigned to the job immediately
# after Start, and Windows auto-inherits job membership for its descendants.
#
# FAIL CLOSED: if the job cannot be created or the root cannot be assigned, this
# runner does NOT pretend to own the tree - it records processOwnership='degraded'
# and falls back to the ppid-walk kill, so the result never over-claims safety.
$script:JobTypeReady = $false
function Initialize-JobObjectType {
    if ($script:JobTypeReady) { return $true }
    if (-not [System.Environment]::OSVersion.Platform.ToString().StartsWith('Win')) { return $false }
    try {
        if (-not ('HookMaker.JobNative' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace HookMaker {
  public static class JobNative {
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
      public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
      public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
      public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
      public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLen);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLen, IntPtr returnLen);
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const int JobObjectExtendedLimitInformation = 9;
    const int JobObjectBasicProcessIdList = 3;
    const int ERROR_MORE_DATA = 234;
    public static IntPtr CreateKillOnClose() {
      IntPtr job = CreateJobObject(IntPtr.Zero, null);
      if (job == IntPtr.Zero) return IntPtr.Zero;
      var ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
      ext.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      int len = Marshal.SizeOf(ext);
      IntPtr p = Marshal.AllocHGlobal(len);
      try {
        Marshal.StructureToPtr(ext, p, false);
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, p, (uint)len)) { CloseHandle(job); return IntPtr.Zero; }
      } finally { Marshal.FreeHGlobal(p); }
      return job;
    }
    public static bool Assign(IntPtr job, IntPtr process) { return AssignProcessToJobObject(job, process); }
    public static bool Terminate(IntPtr job) { return TerminateJobObject(job, 1); }
    public static bool Close(IntPtr job) { return CloseHandle(job); }
    // The job's currently-assigned process ids - the PID-REUSE-PROOF ownership set.
    // A process that has exited is no longer in the list, and a recycled pid was
    // never assigned to THIS job, so a reused pid can never masquerade as a leaked
    // descendant the way a ppid walk over Win32_Process can. Returns null on any
    // query failure so the caller degrades to the ppid walk instead of trusting a
    // guess; returns a (possibly empty) array on success.
    public static int[] GetProcessIds(IntPtr job) {
      if (job == IntPtr.Zero) return null;
      int capacity = 512;
      for (int attempt = 0; attempt < 8; attempt++) {
        // Header is two DWORDs (8 bytes); ProcessIdList[] follows at offset 8 on
        // both x86 (ULONG_PTR=4, 4-aligned) and x64 (ULONG_PTR=8, already 8-aligned).
        int header = 8;
        int len = header + capacity * IntPtr.Size;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
          Marshal.WriteInt32(buf, 0, 0);
          Marshal.WriteInt32(buf, 4, 0);
          bool ok = QueryInformationJobObject(job, JobObjectBasicProcessIdList, buf, (uint)len, IntPtr.Zero);
          if (!ok) {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_MORE_DATA) {
              int assigned = Marshal.ReadInt32(buf, 0);
              capacity = (assigned > capacity) ? (assigned + 32) : (capacity * 2);
              continue;
            }
            return null;
          }
          int inList = Marshal.ReadInt32(buf, 4);
          if (inList < 0) return null;
          int[] ids = new int[inList];
          for (int i = 0; i < inList; i++) {
            IntPtr v = Marshal.ReadIntPtr(buf, header + i * IntPtr.Size);
            ids[i] = (int)v.ToInt64();
          }
          return ids;
        } finally { Marshal.FreeHGlobal(buf); }
      }
      return null;
    }
  }
}
'@
        }
        $script:JobTypeReady = $true
        return $true
    }
    catch { return $false }
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

# The pid-reuse-proof ownership set: the process ids the JOB OBJECT still owns.
# Unlike Get-OwnedProcessTree's ppid walk, a recycled pid can never appear here -
# it was never assigned to THIS job - so a child whose pid is reused after it
# exits cannot be mistaken for a leaked descendant. Returns a result whose
# .Available is $false when there is no job OR the query failed, so the caller
# falls back to the ppid walk rather than trusting an empty list it never got.
# (An empty .Ids under .Available=$true genuinely means "the job owns nothing
# alive", which is the normal clean exit.)
function Get-JobOwnedProcessIds {
    param([IntPtr]$JobHandle)
    if ($JobHandle -eq [IntPtr]::Zero) { return [pscustomobject]@{ Available = $false; Ids = @() } }
    try {
        $ids = [HookMaker.JobNative]::GetProcessIds($JobHandle)
        if ($null -eq $ids) { return [pscustomobject]@{ Available = $false; Ids = @() } }
        return [pscustomobject]@{ Available = $true; Ids = @(@($ids) | ForEach-Object { [int]$_ }) }
    }
    catch { return [pscustomobject]@{ Available = $false; Ids = @() } }
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
    param([int]$RootId, [IntPtr]$JobHandle = [IntPtr]::Zero)
    # When a Job Object owns the tree, TerminateJobObject kills every member
    # atomically - including any descendant that ppid-walking would miss - so it
    # goes first. The ppid walk and taskkill still run as belt-and-braces (and are
    # the whole story in the degraded, no-job case).
    if ($JobHandle -ne [IntPtr]::Zero) {
        try { [void][HookMaker.JobNative]::Terminate($JobHandle) } catch { }
    }
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
        return [pscustomobject]@{ Terminate = $true; Reason = 'noProgressTimeout'
            Detail = ('made no progress for ' + [Math]::Round($IdleSeconds) +
                's - no output, no CPU advance in the owned tree, no process-tree change, no heartbeat')
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
    schema             = 2
    overall            = 'unknown'
    fileName           = $FilePath
    argumentCount      = @($Arguments).Count
    workingDirectory   = ''
    runId              = ''
    projectKey         = ''
    projectFingerprint = ''
    commandFingerprint = ''
    processOwnership   = 'unknown'
    exitCode           = $null
    terminated         = $false
    terminateReason    = ''
    terminateDetail    = ''
    elapsedSeconds     = 0
    noProgressSeconds  = 0
    heartbeats         = 0
    peakMemoryMB       = 0
    cpuSeconds         = 0
    peakTreeSize       = 0
    leakedProcessIds   = @()
    lastProgress       = ''
    stdoutBytes        = 0
    stderrBytes        = 0
    workerBudget       = (Get-GuardedWorkerBudget)
    startedUtc         = ''
    endedUtc           = ''
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
# PER-RUN filename: TestRunGuard-active-<key>-<runId>.json. Keying it by runId
# (not just the project key) is what lets two guarded runs in ONE project each
# own their own marker - so run A's finally removes only run A's marker and never
# tears down a live run B. The key is the 10-char Get-StateKey the consumer uses.
$script:ActiveMarkerPath = ''
function Get-ActiveMarkerPath {
    param([string]$RunId)
    try {
        $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
        $key = Get-StateKey (((Get-Location).Path))
        return (Join-Path $stateDir ('TestRunGuard-active-' + $key + '-' + (Get-SafeRunId $RunId) + '.json'))
    }
    catch { return '' }
}

function Write-ActiveMarker {
    param([int]$OwnerPid, [string]$RunId, [string]$ProjectFingerprint)
    try {
        $path = Get-ActiveMarkerPath -RunId $RunId
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # PID reuse is the trap: a plain {pid} marker blocks completion on ANY
        # live process that later inherits that pid. So the marker also records
        # the OWNER PROCESS's own start time and executable path (read from the
        # live process now), plus the runId and project fingerprint. The consumer
        # accepts the marker as "active" only when the live process at ownerPid
        # STILL has this exact start time and executable - a recycled pid, a
        # different program, or a different project makes it stale, never active.
        # ISO-8601 'o', NOT ticks: the consumer parses with TryParse(RoundtripKind).
        $startUtc = ''
        $exePath = ''
        try {
            $me = Get-Process -Id $OwnerPid -ErrorAction Stop
            try { $startUtc = $me.StartTime.ToUniversalTime().ToString('o') } catch { $startUtc = '' }
            try { $exePath = [string]$me.Path } catch { $exePath = '' }
        }
        catch { }
        $marker = [pscustomobject][ordered]@{
            schema               = 2
            runId                = $RunId
            ownerPid             = $OwnerPid
            ownerProcessStartUtc = $startUtc
            ownerExecutablePath  = $exePath
            projectFingerprint   = $ProjectFingerprint
            markerCreatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        }
        # Atomic-ish write: temp + force-move, so a consumer never reads a
        # half-written marker. Single-writer per RUN (the filename carries this
        # run's id), so the force-replace cannot race another writer.
        $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
        [System.IO.File]::WriteAllText($tmp, ($marker | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
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
    Write-ActiveMarker -OwnerPid $PID -RunId $RunId -ProjectFingerprint $ProjectFingerprint
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
