# Run-Tests-Guarded section: the Windows Job Object, the process tree and the
# termination decision - everything that can end a process.
#
# Dot-sourced by Run-Tests-Guarded.ps1 and kept together on purpose: ownership
# and killing are one responsibility, and separating them is how a runner ends
# up terminating something it never owned.
#
# READ BY scripts/Run-Tests.ps1 AS TEXT. It slices the C# below out by searching
# for the first using-directive and the here-string terminator, so every
# -Parallel runspace shares one AppDomain-loaded HookMaker.JobNative. Two rules
# follow from that, and the split broke both once before they were written down:
#   1. NOTHING above the here-string may contain that directive's literal text -
#      this comment originally spelled it out, the search matched the COMMENT,
#      and the extraction returned prose that could never compile.
#   2. If this block moves again, move that extraction with it. It fails
#      SILENTLY - its Add-Type sits in a catch - and the only symptom is parallel
#      suites quietly losing job ownership.

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
    # A non-positive root owns NOTHING. Rooted at 0 this BFS enqueues every
    # process whose ParentProcessId is 0 - System Idle (0) and System (4) and
    # their children - and reports them as leaked descendants of the test run.
    # Reproduced exactly: root 0 returns "0, 4, 236, 280, 928", the same list a
    # user saw reported as "left process(es) alive" when the child never started.
    # PID 4 is also not something this runner could ever own or terminate.
    if ($RootId -le 4) { return @() }
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
