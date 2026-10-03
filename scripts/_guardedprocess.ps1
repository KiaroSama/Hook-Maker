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

# Reuse the same bounded birth/parent-edge and pinned-handle cleanup as hooks.
# The installer/fixture copier places this dependency beside the runner; only
# the canonical checkout may load it from hooks instead.
$processTreePath = Join-Path $PSScriptRoot '_processtree.ps1'
if (-not (Test-Path -LiteralPath $processTreePath -PathType Leaf)) {
    $processTreePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks/_processtree.ps1'
}
. $processTreePath
$script:GuardedRootCreated = $null

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
# and uses bounded birth-checked fallback cleanup, never a numeric-PPID kill.
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
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
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
    public static bool Contains(IntPtr job, IntPtr process) {
      bool result;
      if (!IsProcessInJob(process, job, out result)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      return result;
    }
    // The job's currently-assigned process ids - the PID-REUSE-PROOF ownership set.
    // A process that has exited is no longer in the list, and a recycled pid was
    // never assigned to THIS job, so a reused pid can never masquerade as a leaked
    // descendant the way a ppid walk over Win32_Process can. Returns null on any
    // query failure so the caller fails closed instead of inventing ownership;
    // returns a (possibly empty) array on success.
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

# One ownership selector for accounting AND completion. Once a Job exists,
# query failure is unknown, never permission to resurrect a PPID-only tree.
function Get-OwnedProcessTree {
    param([int]$RootId, [IntPtr]$JobHandle = [IntPtr]::Zero, [object]$RootCreated = $script:GuardedRootCreated)
    # System roots cannot be owned, even if a caller omitted the birth stamp.
    if ($RootId -le 4 -or $RootId -eq $PID) { return @() }
    if ($JobHandle -ne [IntPtr]::Zero) {
        $owned = Get-JobOwnedProcessIds -JobHandle $JobHandle
        if (-not $owned.Available) { throw 'Run-Tests-Guarded: Job membership query failed; ownership is unproven (no PPID fallback).' }
        return [pscustomobject]@{ Ids = @($owned.Ids); Identities = @() }
    }
    if ($null -eq (ConvertTo-ProcessCreatedUtc $RootCreated)) { throw 'Run-Tests-Guarded: missing root birth stamp; ownership is unproven.' }
    $snapshot = Get-ProcessSnapshot
    if ($null -eq $snapshot) { throw 'Run-Tests-Guarded: process snapshot unavailable; ownership is unproven.' }
    $walk = Get-OwnedDescendantId -RootId $RootId -RootCreated $RootCreated -Snapshot $snapshot
    if ($walk.Truncated) { throw 'Run-Tests-Guarded: process identity or traversal coverage is incomplete; ownership is unproven.' }
    $root = @($snapshot | Where-Object { [int]$_.ProcessId -eq $RootId })
    $identities = @($walk.Identities)
    if ($root.Count -gt 0) { $identities = @([pscustomobject]@{ Id = $RootId; Created = $RootCreated }) + $identities }
    return [pscustomobject]@{ Ids = @($identities | ForEach-Object { $_.Id }); Identities = $identities }
}

# The pid-reuse-proof ownership set: the process ids the JOB OBJECT still owns.
# Unlike Get-OwnedProcessTree's ppid walk, a recycled pid can never appear here -
# it was never assigned to THIS job - so a child whose pid is reused after it
# exits cannot be mistaken for a leaked descendant. Returns a result whose
# .Available is $false when there is no job OR the query failed, so the caller
# fails closed when a Job exists rather than trusting an empty list it never got.
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
    param([int[]]$ProcessIds, [IntPtr]$JobHandle = [IntPtr]::Zero, [object[]]$Identities = @())
    $memoryMB = 0.0; $cpuSeconds = 0.0; $alive = 0
    $births = @{}
    foreach ($identity in $Identities) { $births[[int]$identity.Id] = $identity.Created }
    foreach ($id in @($ProcessIds)) {
        $p = $null
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            # Pin before validation/resources: a Job-list PID can exit and be
            # recycled between the query and Get-Process too.
            $null = $p.Handle
            if ($p.HasExited) { continue }
            if ($JobHandle -ne [IntPtr]::Zero) {
                if (-not [HookMaker.JobNative]::Contains($JobHandle, $p.Handle)) { continue }
            }
            elseif (-not $births.ContainsKey($id) -or -not (Test-ProcessCreationMatch $p.StartTime $births[$id])) { continue }
            $alive++
            $memoryMB += ($p.WorkingSet64 / 1MB)
            try { $cpuSeconds += $p.CPU } catch { }
        }
        catch {
            $failure = $_
            $exited = $false
            try { if ($null -ne $p) { $exited = $p.HasExited } } catch { }
            if ($exited -or $failure.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*') { continue }
            throw ('Run-Tests-Guarded: resource ownership could not be verified for PID ' + $id + ': ' + $failure.Exception.Message)
        }
        finally { if ($null -ne $p) { $p.Dispose() } }
    }
    return [pscustomobject]@{ MemoryMB = [Math]::Round($memoryMB, 1); CpuSeconds = [Math]::Round($cpuSeconds, 1); Alive = $alive }
}

# Never mix native Job ownership with PPID teardown. Kill-on-close remains the
# crash backstop, but only an observed empty membership proves cleanup here.
function Stop-OwnedProcessTree {
    param([int]$RootId, [IntPtr]$JobHandle = [IntPtr]::Zero, [object]$RootCreated = $script:GuardedRootCreated)
    if ($RootId -le 4 -or $RootId -eq $PID) { throw 'Run-Tests-Guarded: refusing cleanup of a protected root.' }
    if ($JobHandle -ne [IntPtr]::Zero) {
        if (-not [HookMaker.JobNative]::Terminate($JobHandle)) { throw 'Run-Tests-Guarded: Job termination failed; cleanup is unproven.' }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        do {
            $owned = Get-JobOwnedProcessIds -JobHandle $JobHandle
            if (-not $owned.Available) { throw 'Run-Tests-Guarded: Job cleanup query failed; cleanup is unproven (no PPID fallback).' }
            if ($owned.Ids.Count -eq 0) { return @() }
            if ($deadline.ElapsedMilliseconds -ge 5000) { return $owned.Ids }
            Start-Sleep -Milliseconds 25 # bounded membership polling, not a blind teardown delay
        } while ($true)
    }
    if ($null -eq (ConvertTo-ProcessCreatedUtc $RootCreated)) { throw 'Run-Tests-Guarded: missing root birth stamp; cleanup is unproven.' }
    $cleanup = Stop-ProcessTree -ProcessId $RootId -RootCreated $RootCreated
    if (-not $cleanup.Cleared -and $cleanup.Survivors.Count -eq 0) { throw 'Run-Tests-Guarded: process cleanup coverage is incomplete; cleanup is unproven.' }
    return $cleanup.Survivors
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
