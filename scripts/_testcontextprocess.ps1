# Real pipe-lifetime regression. Named events coordinate child readiness and
# release; every process has a deadline and a finally-owned cleanup handle.
#
# NO ASSERTION HERE DEPENDS ON A WALL-CLOCK MARGIN. It used to: the holder
# lived 20s on its own, the command budget was 4s, and the test asserted the
# probe returned inside a ceiling BETWEEN the two - so "the deadline fired"
# was really "the deadline beat the holder's own lifetime", a race that a
# loaded CI runner lost (three assertions went red on a commit that changed one
# markdown file and green on a rerun of the same tree, 2026-09-20). The same
# design could also go green for the wrong reason: past 20s the holder exits by
# itself and "the cleanup terminated it" is satisfied by a holder nobody killed.
#
# So the holder no longer ends on its own inside any time this test can reach:
# it waits on the release event, which ONLY the cleanup block sets. The probe
# can therefore return for exactly one reason - its own command deadline - and
# the holder can exit for exactly one reason - the timeout cleanup killing it.
# Every remaining wait is a HANG CEILING, not a margin: no correct run comes
# near it, and reaching one is a real failure to report, never a lost race.
# 60s is ~11x the measured kill-and-teardown cost (5.2-5.5s) and 5x the bound
# that lost the race, while a genuine regression still costs at most three of
# these per host - inside the 900s per-suite CI ceiling.
$PipeHangCeilingMs = 60000
. $HookLib
$pipeHolder = Join-Path $Work 'pipe-holder.ps1'
$pipeRoot = Join-Path $Work 'pipe-root.ps1'
$pipeProbe = Join-Path $Work 'pipe-probe.ps1'
Write-Utf8 $pipeHolder @'
param($ReadyName, $ReleaseName, $PidFile)
$ready = [System.Threading.EventWaitHandle]::OpenExisting($ReadyName)
$release = [System.Threading.EventWaitHandle]::OpenExisting($ReleaseName)
try {
    [System.IO.File]::WriteAllText($PidFile, [string]$PID, [System.Text.Encoding]::UTF8)
    [Console]::Out.WriteLine('holder stdout')
    [Console]::Error.WriteLine('holder stderr')
    [void]$ready.Set()
    # Released only by the test's cleanup block. The long bound is an orphan
    # safety net for a test that dies before its finally runs - never a
    # lifetime the assertions race against.
    [void]$release.WaitOne(300000)
}
finally { $ready.Dispose(); $release.Dispose() }
'@
Write-Utf8 $pipeRoot @'
param($Library, $HostExe, $Holder, $ReadyName, $ReleaseName, $PidFile, $HolderPidFile)
. $Library
[System.IO.File]::WriteAllText($PidFile, [string]$PID, [System.Text.Encoding]::UTF8)
$info = New-Object System.Diagnostics.ProcessStartInfo
$info.FileName = $HostExe
$info.Arguments = ConvertTo-Win32ArgumentString @('-NoLogo', '-NoProfile', '-File', $Holder,
    '-ReadyName', $ReadyName, '-ReleaseName', $ReleaseName, '-PidFile', $HolderPidFile)
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$child = [System.Diagnostics.Process]::Start($info)
$ready = [System.Threading.EventWaitHandle]::OpenExisting($ReadyName)
try { if (-not $ready.WaitOne(10000)) { exit 3 } }
finally { $ready.Dispose(); $child.Dispose() }
exit 0
'@
Write-Utf8 $pipeProbe @'
param($Library, $HostExe, $RootScript, $Holder, $ReadyName, $ReleaseName, $PidFile, $HolderPidFile)
. $Library
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$output = @(Invoke-QuietCommand -FilePath $HostExe -ArgumentList @('-NoLogo', '-NoProfile', '-File', $RootScript,
    '-Library', $Library, '-HostExe', $HostExe, '-Holder', $Holder, '-ReadyName', $ReadyName,
    '-ReleaseName', $ReleaseName, '-PidFile', $PidFile, '-HolderPidFile', $HolderPidFile) -TimeoutSeconds 4)
$code = $LASTEXITCODE
[pscustomobject]@{ ExitCode = $code; ElapsedMs = $timer.ElapsedMilliseconds; OutputCount = $output.Count } | ConvertTo-Json -Compress
'@
foreach ($hostName in @('pwsh', 'powershell.exe')) {
    Write-Host ('--- inherited pipe deadline: ' + $hostName + ' ---') -ForegroundColor Cyan
    $hostExe = [string]@(Get-Command $hostName -CommandType Application)[0].Source
    $token = [guid]::NewGuid().ToString('N')
    $readyName = 'Local\HookMakerPipeReady' + $token
    $releaseName = 'Local\HookMakerPipeRelease' + $token
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyName)
    $release = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $releaseName)
    $rootPidFile = Join-Path $Work ($token + '-root.pid')
    $holderPidFile = Join-Path $Work ($token + '-holder.pid')
    $probe = $null; $rootProcess = $null; $holderProcess = $null
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $hostExe
        $info.Arguments = ConvertTo-Win32ArgumentString @('-NoLogo', '-NoProfile', '-File', $pipeProbe,
            '-Library', $HookLib, '-HostExe', $hostExe, '-RootScript', $pipeRoot, '-Holder', $pipeHolder,
            '-ReadyName', $readyName, '-ReleaseName', $releaseName, '-PidFile', $rootPidFile, '-HolderPidFile', $holderPidFile)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $probe = [System.Diagnostics.Process]::Start($info)
        $outTask = $probe.StandardOutput.ReadToEndAsync()
        $errTask = $probe.StandardError.ReadToEndAsync()
        # The holder signals when it holds both inherited pipes. An event, not a
        # sleep: the ceiling is only there so a child that never starts fails
        # instead of hanging the suite.
        $holderReady = $ready.WaitOne($PipeHangCeilingMs)
        Check ($hostName + ': real descendant starts and holds inherited stdout/stderr') $holderReady
        if ($holderReady) {
            $holderProcess = [System.Diagnostics.Process]::GetProcessById([int][System.IO.File]::ReadAllText($holderPidFile))
            $null = $holderProcess.Handle
            try {
                $rootProcess = [System.Diagnostics.Process]::GetProcessById([int][System.IO.File]::ReadAllText($rootPidFile))
                # The root's own wait on the ready event has already returned, so
                # it is on its way out; this waits for that exit, it does not
                # require it to happen inside some margin.
                $rootExited = $rootProcess.WaitForExit($PipeHangCeilingMs)
            }
            catch [System.ArgumentException] { $rootExited = $true }
            Check ($hostName + ': direct child exits before its pipe-owning descendant') $rootExited
            # The holder is still holding both pipes and nothing has released it,
            # so the ONLY thing that can end the probe is the command deadline it
            # was given. Returning at all is therefore the proof - no ceiling
            # between the budget and a holder lifetime, because the holder has no
            # lifetime of its own any more.
            $returned = $probe.WaitForExit($PipeHangCeilingMs)
            Check ($hostName + ': inherited pipes cannot extend the command deadline') $returned
            # Likewise: the holder cannot exit on its own, so an exit here is the
            # timeout cleanup killing the process tree and nothing else.
            $descendantTerminated = $returned -and $holderProcess.WaitForExit($PipeHangCeilingMs)
            if (-not $returned) { [void]$release.Set(); [void]$probe.WaitForExit($PipeHangCeilingMs) }
            # Only now can the reads finish: the holder owned the write ends, so
            # EOF arrives with its death, not after some interval.
            $captureComplete = $outTask.Wait($PipeHangCeilingMs) -and $errTask.Wait($PipeHangCeilingMs)
            $result = $null
            if ($captureComplete) {
                try { $result = $outTask.GetAwaiter().GetResult() | ConvertFrom-Json } catch { }
            }
            Check ($hostName + ': expired pipe drain returns timeout 124') (
                $null -ne $result -and $result.ExitCode -eq 124) $(if ($captureComplete) { $outTask.GetAwaiter().GetResult() } else { 'Output capture did not complete.' })
            Check ($hostName + ': timeout cleanup terminates the pipe-owning descendant') $descendantTerminated
        }
    }
    finally {
        [void]$release.Set()
        foreach ($ownedProcess in @($holderProcess, $rootProcess, $probe)) {
            if ($null -eq $ownedProcess) { continue }
            try {
                if (-not $ownedProcess.HasExited) { $ownedProcess.Kill() }
                Check ($hostName + ': owned fixture process has exited') ($ownedProcess.WaitForExit($PipeHangCeilingMs))
            }
            finally { $ownedProcess.Dispose() }
        }
        $ready.Dispose(); $release.Dispose()
    }
}
