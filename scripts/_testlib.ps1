function Check {
    param([string]$Name, [bool]$Condition, [string]$Actual = $null)
    if ($Condition) {
        $script:Pass++
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($env:HOOKMAKER_TEST_DEBUG -eq '1' -and $null -ne $Actual) {
            $preview = $Actual
            if ($preview.Length -gt $script:TestPreviewLength) {
                $preview = $preview.Substring(0, $script:TestPreviewLength)
            }
            Write-Host ('       actual: [' + $preview + ']') -ForegroundColor DarkGray
        }
    }
}

# Creates a suite's throwaway workspace. This is the line 37 suites each inlined
# - Join-Path (GetTempPath) (<prefix> + '-' + <8 hex chars>) - written once, plus
# one escape hatch.
#
# HOOKMAKER_TEST_TEMP_ROOT exists because a full-matrix run twice had a LIVE
# workspace deleted underneath it by something outside this repo (no code here
# sweeps %TEMP%; Storage Sense, a scanner and the harness are all still suspects)
# and the suite then crashed at its own file writer. Relocating the workspaces
# turns "is the deleter %TEMP%-specific?" into an experiment instead of a guess.
#
# It is a DIAGNOSTIC switch, never a new default: unset or blank keeps the old
# %TEMP% behaviour byte-for-byte. An unusable value - a path that cannot be
# created, a permission denial, garbage - falls back to %TEMP% rather than
# throwing, because a suite failing over a diagnostic setting would be a worse
# bug than the one it was set to diagnose. The returned path is always a
# directory that exists.
function New-TestWorkspace {
    param([Parameter(Mandatory)][string]$Prefix)

    $root = ''
    $configured = [string]$env:HOOKMAKER_TEST_TEMP_ROOT
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        try {
            $candidate = [System.IO.Path]::GetFullPath($configured)
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            }
            # Trust the filesystem, not the absence of an exception: New-Item
            # -Force is a SILENT no-op for some unusable targets (a path under a
            # FILE returns nothing and throws nothing), which would otherwise hand
            # back a workspace that does not exist - the very crash this helper is
            # meant to be diagnosing.
            if (Test-Path -LiteralPath $candidate -PathType Container) { $root = $candidate }
        }
        catch { $root = '' }
    }
    if ($root -eq '') { $root = [System.IO.Path]::GetTempPath() }

    $path = Join-Path $root ($Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    # Same reason as the root check above, applied to the workspace itself: this
    # helper must never hand back a directory that does not exist. Without it a
    # silent no-op here surfaces later as an unexplained failure at whatever
    # first writes into the workspace - which is exactly the signature of the
    # open Test-DiscoveredUninstall flake (see BUGS.md). Failing at the creation
    # site names the path instead, and tells the "never created" branch apart
    # from "deleted underneath us" without waiting for a rare reproduction.
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw ('Test workspace could not be created: ' + $path)
    }
    return $path
}

# Removes a suite's throwaway workspace and PROVES it is gone. A child hook
# process, a git invocation, or an antivirus scan of the freshly written .git
# tree can still hold a handle for a beat after the suite's work finishes; a
# plain `Remove-Item -ErrorAction SilentlyContinue` then fails and the suite
# exits 0 with the tree still on disk (see the leaked hookmaker-* dirs this was
# written to stop). So: retry with a short backoff - the handle almost always
# releases within a second or two - verify after each attempt, and if the tree
# still will not go, say so LOUDLY and return $false so the caller can fail the
# suite instead of leaking silently. Every operation is scoped strictly to the
# given path(s); there is no broad or recursive delete of anything else.
#
# Deliberately does NOT hunt down and kill git/pwsh children: that risks killing
# an unrelated process and cannot be scoped to $Work. GC + WaitForPendingFinalizers
# releases any handle THIS process still holds (an undisposed child Process object,
# a FileStream), and the backoff covers an external holder releasing its lock.
function Remove-TestWorkspace {
    param([Parameter(Mandatory)][string[]]$Path)

    $allGone = $true
    foreach ($target in $Path) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        if (-not (Test-Path -LiteralPath $target)) { continue }

        $removed = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { } }
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            }
            catch { }
            if (-not (Test-Path -LiteralPath $target)) { $removed = $true; break }
            if ($attempt -lt 10) {
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds ($attempt * 150)
            }
        }

        if (-not $removed) {
            $allGone = $false
            Write-Host ''
            Write-Host ('LEAKED WORKSPACE: could not remove ' + $target +
                ' after 10 attempts - a handle is still open (stray git/pwsh child or AV lock). Left on disk for inspection.') -ForegroundColor Red
        }
    }
    return $allGone
}
# An ACL fixture is worthless while the test process can bypass DACLs. A token
# holding SeBackupPrivilege / SeRestorePrivilege ENABLED is granted file access
# regardless of any deny ACE, so `icacls /deny` and Set-Acl report success, the
# denial is really in place, and the operation succeeds anyway. Those two are
# normally present-but-disabled; some launchers hand a shell a token with them
# already enabled, and every ACL-based fixture then silently stops denying -
# observed here as six Test-Wizard failures and three in Test-TestTempCleanup.
#
# Disabling them costs nothing when they are already off, and child processes
# inherit the token's privilege state, so a suite that spawns the wizard or a
# hook gets an enforced DACL too. Call this BEFORE building any ACL fixture.
function Disable-DaclBypassPrivilege {
    if (-not ('HookMakerTestPrivilege' -as [type])) {
        # Pack = 4 is load-bearing: LUID_AND_ATTRIBUTES packs the 8-byte LUID on
        # a 4-byte boundary. Default packing puts Attributes in the wrong place
        # and AdjustTokenPrivileges quietly refuses.
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HookMakerTestPrivilege {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int length, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    public static bool Disable(string name) {
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020u | 0x0008u, out token)) { return false; }
        try {
            long luid;
            if (!LookupPrivilegeValue(null, name, out luid)) { return false; }
            TOKEN_PRIVILEGES state = new TOKEN_PRIVILEGES();
            state.Count = 1; state.Luid = luid; state.Attributes = 0;
            if (!AdjustTokenPrivileges(token, false, ref state, Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), IntPtr.Zero, IntPtr.Zero)) { return false; }
            return Marshal.GetLastWin32Error() == 0;
        }
        finally { CloseHandle(token); }
    }
}
'@
    }
    $stubborn = @()
    foreach ($name in @('SeBackupPrivilege', 'SeRestorePrivilege')) {
        # A privilege the token does not hold cannot be disabled and does not
        # need to be - Disable() reporting false there is not a problem.
        if (-not [HookMakerTestPrivilege]::Disable($name)) { $stubborn += $name }
    }
    if ($stubborn.Count -gt 0) {
        $priv = & "$env:SystemRoot\System32\whoami.exe" /priv 2>$null
        $held = @($stubborn | Where-Object { $n = $_; @($priv) -match ($n + '.*Enabled') })
        if ($held.Count -gt 0) {
            Write-Host ('  (warning: could not disable ' + ($held -join ', ') +
                ' - ACL fixtures in this suite cannot deny anything)') -ForegroundColor DarkYellow
            return $false
        }
    }
    return $true
}
# The one UTF-8 (no BOM) writer every suite uses. Two things a bare
# WriteAllText does not do, and 28 hand-rolled copies disagreed about:
#
#   * create the parent directory - 8 copies did, 20 did not;
#   * survive a transient share violation. An external reader (AV, indexer,
#     search) can hold a just-written file for a few milliseconds, and a
#     single-shot write turns that into a failed suite. It cost one full
#     matrix a red `Test-DiscoveredUninstall` that passed on the re-run.
#
# Only IOException is retried: a bad path or a denied ACL raises something
# else and must surface immediately instead of being delayed five times.
function Write-Utf8 {
    # NOT [Parameter(Mandatory)]: a missing argument would make PowerShell
    # PROMPT, and a test process with no console is the worst place to wait for
    # one. Check it and throw instead.
    param([string]$Path, [string]$Content = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Write-Utf8 called without a path.' }
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($directory) -and
        -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($Path, $Content, $encoding)
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -eq 5) {
                throw ('Write-Utf8 failed for ' + $Path + ' after ' + $attempt + ' attempt(s) :: ' +
                    $_.Exception.Message + ' [parent exists=' +
                    (Test-Path -LiteralPath $directory -PathType Container) +
                    '; utc=' + [DateTime]::UtcNow.ToString('o') + ']')
            }
            # No signal exists for "the other process closed its handle", so a
            # short bounded back-off is the only option. Worst case 500 ms.
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}
