# Real pipe-lifetime regression. Named events coordinate child readiness and
# release; every process has a deadline and a finally-owned cleanup handle.
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
    [void]$release.WaitOne(20000)
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
        $holderReady = $ready.WaitOne(10000)
        Check ($hostName + ': real descendant starts and holds inherited stdout/stderr') $holderReady
        if ($holderReady) {
            $holderProcess = [System.Diagnostics.Process]::GetProcessById([int][System.IO.File]::ReadAllText($holderPidFile))
            $null = $holderProcess.Handle
            try {
                $rootProcess = [System.Diagnostics.Process]::GetProcessById([int][System.IO.File]::ReadAllText($rootPidFile))
                $rootExited = $rootProcess.WaitForExit(3000)
            }
            catch [System.ArgumentException] { $rootExited = $true }
            Check ($hostName + ': direct child exits before its pipe-owning descendant') $rootExited
            $returned = $probe.WaitForExit(6000)
            Check ($hostName + ': inherited pipes cannot extend the command deadline') $returned
            $descendantTerminated = $returned -and $holderProcess.WaitForExit(2000)
            if (-not $returned) { [void]$release.Set(); [void]$probe.WaitForExit(5000) }
            $captureComplete = $outTask.Wait(2000) -and $errTask.Wait(2000)
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
                Check ($hostName + ': owned fixture process has exited') ($ownedProcess.WaitForExit(5000))
            }
            finally { $ownedProcess.Dispose() }
        }
        $ready.Dispose(); $release.Dispose()
    }
}
