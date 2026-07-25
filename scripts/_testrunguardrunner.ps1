# Test-TestRunGuard.ps1 scenario block: the REAL Run-Tests-Guarded.ps1 runner
# driven end to end - orphan descendants after a clean exit reported as a
# leak (scope B), the Job Object process list as the pid-reuse-proof
# ownership set, a clean exit never reporting a false orphan across repeated
# runs, a silent CPU-busy run surviving the no-progress limit (scope F), and
# the per-run active marker keyed to -WorkingDirectory (Defect 1, scope C,
# HM-03).
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- runner: orphan descendants after a clean exit are a leak (scope B) ---' -ForegroundColor Cyan
    $orphanSuite = Join-Path $Work 'orphan-suite.ps1'
    Write-Utf8 $orphanSuite "`$c = Start-Process -FilePath 'ping.exe' -ArgumentList '-n','60','127.0.0.1' -PassThru -WindowStyle Hidden`nSet-Content -LiteralPath `$env:ORPHAN_PIDFILE -Value `$c.Id`nStart-Sleep -Milliseconds 300`nexit 0`n"
    $orphanPidFile = Join-Path $Work 'orphan-pid.txt'
    $orphanResult = Join-Path $Work 'orphan-result.json'
    # A wrapper script invokes the runner with the -Arguments ARRAY (built in
    # PowerShell), so no JSON/embedded-quote survives Start-Process arg mangling.
    $orphanWrapper = Join-Path $Work 'run-orphan.ps1'
    Write-Utf8 $orphanWrapper (
        "& '$Runner' -FilePath 'pwsh' -Arguments @('-NoProfile','-File','$orphanSuite') " +
        "-TimeoutSeconds 60 -IdleTimeoutSeconds 30 -HeartbeatSeconds 1 -ResultPath '$orphanResult' -Quiet`nexit `$LASTEXITCODE`n")
    $prevOrphanEnv = $env:ORPHAN_PIDFILE
    $env:ORPHAN_PIDFILE = $orphanPidFile
    try {
        $rp = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru -ArgumentList @(
            '-NoLogo', '-NoProfile', '-File', $orphanWrapper)
    }
    finally { $env:ORPHAN_PIDFILE = $prevOrphanEnv }
    $orphanDoc = $null
    try { $orphanDoc = Get-Content -LiteralPath $orphanResult -Raw | ConvertFrom-Json } catch { }
    Check 'the runner records the orphan as a leak and does not call the run ok' (
        $null -ne $orphanDoc -and $orphanDoc.overall -ne 'ok' -and @($orphanDoc.leakedProcessIds).Count -gt 0) (
        $(if ($null -ne $orphanDoc) { [string]$orphanDoc.overall + ' leaked=' + (@($orphanDoc.leakedProcessIds) -join ',') } else { 'no result' }))
    $orphanChild = ''
    try { $orphanChild = (Get-Content -LiteralPath $orphanPidFile -Raw).Trim() } catch { }
    $orphanAlive = $false
    if ($orphanChild -ne '') { try { $null = Get-Process -Id $orphanChild -ErrorAction Stop; $orphanAlive = $true } catch { } }
    Check 'the orphan child is actually gone after the run (terminated, not leaked forever)' (-not $orphanAlive) ('child ' + $orphanChild + ' alive=' + $orphanAlive)

    # =====================================================================
    Write-Host '--- runner: the Job Object process list is the pid-reuse-proof ownership set (scope B) ---' -ForegroundColor Cyan
    # Orphan detection after a CLEAN exit used to ppid-walk Win32_Process, which is
    # NOT pid-reuse-proof: once the child exits its pid can be recycled and an
    # unrelated process's children then look like "orphans of the child". The fix
    # asks the Job Object which pids it still owns instead. Load the EXACT shipping
    # C# from the runner (the same here-string it Add-Types at runtime) and prove
    # GetProcessIds lists a live assigned child and excludes an unrelated process -
    # the structural property that makes a recycled pid impossible to mistake for a
    # leak, because a recycled pid was never assigned to this job.
    if ([System.Environment]::OSVersion.Platform.ToString().StartsWith('Win')) {
        $jobTestOk = $false
        $jobTestDetail = 'not run'
        $runnerText = Get-Content -LiteralPath $Runner -Raw
        $csStart = $runnerText.IndexOf('using System;')
        $csEnd = $runnerText.IndexOf("'@", $csStart)
        if ($csStart -ge 0 -and $csEnd -gt $csStart -and -not ('HookMaker.JobNative' -as [type])) {
            try { Add-Type -TypeDefinition $runnerText.Substring($csStart, $csEnd - $csStart) } catch { $jobTestDetail = 'Add-Type failed: ' + $_.Exception.Message }
        }
        if ('HookMaker.JobNative' -as [type]) {
            $jobHandle = [IntPtr]::Zero
            $jobChild = $null
            try {
                $jobHandle = [HookMaker.JobNative]::CreateKillOnClose()
                if ($jobHandle -ne [IntPtr]::Zero) {
                    $emptyIds = @([HookMaker.JobNative]::GetProcessIds($jobHandle))
                    $jobChild = Start-Process -FilePath 'ping.exe' -ArgumentList @('-n', '30', '127.0.0.1') -PassThru -WindowStyle Hidden
                    [void][HookMaker.JobNative]::Assign($jobHandle, $jobChild.Handle)
                    Start-Sleep -Milliseconds 200
                    $liveIds = @([HookMaker.JobNative]::GetProcessIds($jobHandle))
                    $jobTestOk = ($emptyIds.Count -eq 0 -and ($liveIds -contains $jobChild.Id) -and (-not ($liveIds -contains $PID)))
                    $jobTestDetail = ('empty=' + $emptyIds.Count + ' live=[' + ($liveIds -join ',') + '] child=' + $jobChild.Id + ' me=' + $PID)
                }
                else { $jobTestDetail = 'CreateKillOnClose returned NULL' }
            }
            catch { $jobTestDetail = 'threw: ' + $_.Exception.Message }
            finally {
                try { if ($jobHandle -ne [IntPtr]::Zero) { [void][HookMaker.JobNative]::Terminate($jobHandle); [void][HookMaker.JobNative]::Close($jobHandle) } } catch { }
                try { if ($null -ne $jobChild -and -not $jobChild.HasExited) { & taskkill.exe /PID $jobChild.Id /T /F *> $null } } catch { }
            }
        }
        else { $jobTestDetail = 'HookMaker.JobNative type unavailable' }
        Check 'GetProcessIds lists a live assigned child and excludes an unrelated process (pid-reuse-proof)' $jobTestOk $jobTestDetail
    }

    # =====================================================================
    Write-Host '--- runner: a clean exit (7, no descendants) never reports a false orphan, repeatedly (pid-reuse regression) ---' -ForegroundColor Cyan
    # The flake: after the child exits, its pid could be recycled and the old
    # ppid-walk orphan check would find an unrelated process's children hanging off
    # the reused pid, flip overall to 'failed' and return 125 instead of the child's
    # real exit code. pid reuse cannot be forced deterministically, so prove
    # stability instead: a clean child (exit 7, no descendants) must propagate 7
    # with an EMPTY leak list on every one of many runs. cmd exits instantly, so
    # each iteration is bounded to well under a second.
    $cleanResult = Join-Path $Work 'clean-result.json'
    $cleanWrapper = Join-Path $Work 'run-clean.ps1'
    Write-Utf8 $cleanWrapper (
        "& '$Runner' -FilePath 'cmd.exe' -Arguments @('/c','exit','7') " +
        "-TimeoutSeconds 30 -IdleTimeoutSeconds 10 -HeartbeatSeconds 1 -ResultPath '$cleanResult' -Quiet`nexit `$LASTEXITCODE`n")
    $cleanIterations = 12
    $cleanStable = $true
    $cleanDetail = ('all ' + $cleanIterations + ' iterations propagated 7 with no false orphan')
    for ($ci = 1; $ci -le $cleanIterations; $ci++) {
        $rpClean = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru -ArgumentList @(
            '-NoLogo', '-NoProfile', '-File', $cleanWrapper)
        $cleanDoc = $null
        try { $cleanDoc = Get-Content -LiteralPath $cleanResult -Raw | ConvertFrom-Json } catch { }
        $iterOk = ($rpClean.ExitCode -eq 7 -and $null -ne $cleanDoc -and
            @($cleanDoc.leakedProcessIds).Count -eq 0 -and [string]$cleanDoc.terminateReason -ne 'orphanLeak')
        if (-not $iterOk) {
            $cleanStable = $false
            $cleanDetail = ('iteration ' + $ci + ': exit=' + $rpClean.ExitCode + ' ' + $(if ($null -ne $cleanDoc) {
                        'overall=' + [string]$cleanDoc.overall + ' leaked=[' + (@($cleanDoc.leakedProcessIds) -join ',') +
                        '] reason=' + [string]$cleanDoc.terminateReason + ' ownership=' + [string]$cleanDoc.processOwnership
                    } else { 'no result doc' }))
            break
        }
    }
    Check ('a clean exit propagates 7 with no false orphan across ' + $cleanIterations + ' iterations (flake gone)') $cleanStable $cleanDetail

    # =====================================================================
    Write-Host '--- runner: a silent CPU-busy run survives the no-progress limit (scope F) ---' -ForegroundColor Cyan
    $busySuite = Join-Path $Work 'busy-suite.ps1'
    Write-Utf8 $busySuite "`$sw=[System.Diagnostics.Stopwatch]::StartNew();`$x=0.0`nwhile(`$sw.Elapsed.TotalSeconds -lt 6){ for(`$i=0;`$i -lt 200000;`$i++){ `$x=[math]::Sqrt(`$i)+`$x } }`nexit 0`n"
    $busyResult = Join-Path $Work 'busy-result.json'
    $busyWrapper = Join-Path $Work 'run-busy.ps1'
    Write-Utf8 $busyWrapper (
        "& '$Runner' -FilePath 'pwsh' -Arguments @('-NoProfile','-File','$busySuite') " +
        "-TimeoutSeconds 30 -IdleTimeoutSeconds 2 -HeartbeatSeconds 1 -ResultPath '$busyResult' -Quiet`nexit `$LASTEXITCODE`n")
    $rp = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru -ArgumentList @(
        '-NoLogo', '-NoProfile', '-File', $busyWrapper)
    $busyDoc = $null
    try { $busyDoc = Get-Content -LiteralPath $busyResult -Raw | ConvertFrom-Json } catch { }
    Check 'a silent CPU-busy run is NOT killed by the 2s no-progress limit (CPU is progress)' (
        $null -ne $busyDoc -and $busyDoc.terminated -eq $false -and $busyDoc.overall -eq 'ok') (
        $(if ($null -ne $busyDoc) { [string]$busyDoc.overall + ' terminated=' + [string]$busyDoc.terminated + ' reason=' + [string]$busyDoc.terminateReason } else { 'no result' }))

    # =====================================================================
    Write-Host '--- runner: the active marker is PER-RUN (filename carries the runId) and is cleaned up (Defect 1, scope C) ---' -ForegroundColor Cyan
    # A guarded run of a suite that blocks on a sentinel file, so the marker is
    # provably present when we poll (no fixed sleep, no timing assumption). Its
    # LOCALAPPDATA is redirected to an isolated dir so the marker never lands in
    # the real shared state directory.
    $activeRunId = [guid]::NewGuid().ToString('N')
    $activeLocal = Join-Path $Work ('active-local-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $activeStateDir = Join-Path $activeLocal 'HookMaker\state'
    New-Item -ItemType Directory -Path $activeStateDir -Force | Out-Null
    $activeGo = Join-Path $Work ('active-go-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.flag')
    $activeSuite = Join-Path $Work 'active-suite.ps1'
    Write-Utf8 $activeSuite ("`$go = `$env:HOOKMAKER_ACTIVE_GO`n`$deadline = [DateTime]::UtcNow.AddSeconds(30)`nwhile (-not (Test-Path -LiteralPath `$go) -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 50 }`nexit 0`n")
    $activeResult = Join-Path $Work 'active-result.json'
    $activeWrapper = Join-Path $Work 'run-active.ps1'
    Write-Utf8 $activeWrapper (
        "& '$Runner' -FilePath 'pwsh' -Arguments @('-NoProfile','-File','$activeSuite') " +
        "-TimeoutSeconds 40 -IdleTimeoutSeconds 35 -HeartbeatSeconds 1 -ResultPath '$activeResult' -RunId '$activeRunId' -Quiet`nexit `$LASTEXITCODE`n")
    $prevActiveLocal = $env:LOCALAPPDATA
    $prevActiveGo = $env:HOOKMAKER_ACTIVE_GO
    $activeProc = $null
    $markerName = ''
    try {
        $env:LOCALAPPDATA = $activeLocal
        $env:HOOKMAKER_ACTIVE_GO = $activeGo
        $activeProc = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -PassThru -ArgumentList @('-NoLogo', '-NoProfile', '-File', $activeWrapper)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            $m = @(Get-ChildItem -LiteralPath $activeStateDir -Filter 'TestRunGuard-active-*.json' -File -ErrorAction SilentlyContinue)
            if ($m.Count -ge 1) { $markerName = $m[0].Name; break }
            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        # Release the suite so the runner exits cleanly and removes its own marker.
        try { New-Item -ItemType File -Path $activeGo -Force | Out-Null } catch { }
        if ($null -ne $activeProc) {
            try { [void]$activeProc.WaitForExit(10000) } catch { }
            if (-not $activeProc.HasExited) { try { & taskkill.exe /PID $activeProc.Id /T /F *> $null } catch { } }
        }
        $env:LOCALAPPDATA = $prevActiveLocal
        $env:HOOKMAKER_ACTIVE_GO = $prevActiveGo
    }
    Check 'while a guarded run is live its active marker exists and its filename carries the runId' (
        $markerName -match ('^TestRunGuard-active-[a-z0-9]+-' + [regex]::Escape($activeRunId) + '\.json$')) $markerName
    $markerLeft = @(Get-ChildItem -LiteralPath $activeStateDir -Filter 'TestRunGuard-active-*.json' -File -ErrorAction SilentlyContinue)
    Check 'the runner removes ONLY its own per-run active marker when it finishes (none left)' ($markerLeft.Count -eq 0) ([string]$markerLeft.Count)

    # =====================================================================
    Write-Host '--- runner: the active marker is keyed to -WorkingDirectory, not the launch cwd (HM-03) ---' -ForegroundColor Cyan
    # Launched from process cwd = A with -WorkingDirectory B, the RESULT belongs to
    # B (result.projectKey is B's), so a Test-Completion-Check running in B must find
    # the live marker. The pre-fix code keyed the marker off Get-Location (= A), so
    # the check in B never saw the run. Prove the marker lands under B's 10-char key,
    # NOT under A's, and is cleaned up. Reverting to Get-Location fails exactly these.
    function Get-TenCharKey {
        param([string]$Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 10) }
        finally { $sha.Dispose() }
    }
    $wdA = [System.IO.Path]::GetFullPath((Join-Path $Work ('wd-A-' + [guid]::NewGuid().ToString('N').Substring(0, 6))))
    $wdB = [System.IO.Path]::GetFullPath((Join-Path $Work ('wd-B-' + [guid]::NewGuid().ToString('N').Substring(0, 6))))
    New-Item -ItemType Directory -Path $wdA -Force | Out-Null
    New-Item -ItemType Directory -Path $wdB -Force | Out-Null
    # Keys derived from the SAME canonical form the runner keys off, so parity does
    # not depend on GetFullPath leaving the path untouched.
    $keyA = Get-TenCharKey $wdA
    $keyB = Get-TenCharKey $wdB
    Check 'the two working dirs have distinct state keys (the A/B discriminator is real)' ($keyA -ne $keyB) ($keyA + ' vs ' + $keyB)
    $wdRunId = [guid]::NewGuid().ToString('N')
    $wdLocal = Join-Path $Work ('wd-local-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $wdStateDir = Join-Path $wdLocal 'HookMaker\state'
    New-Item -ItemType Directory -Path $wdStateDir -Force | Out-Null
    $wdGo = Join-Path $Work ('wd-go-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.flag')
    $wdSuite = Join-Path $Work 'wd-suite.ps1'
    Write-Utf8 $wdSuite ("`$go = `$env:HOOKMAKER_WD_GO`n`$deadline = [DateTime]::UtcNow.AddSeconds(30)`nwhile (-not (Test-Path -LiteralPath `$go) -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 50 }`nexit 0`n")
    $wdResult = Join-Path $Work 'wd-result.json'
    $wdWrapper = Join-Path $Work 'run-wd.ps1'
    # The wrapper runs in cwd A (Start-Process -WorkingDirectory below), and passes
    # -WorkingDirectory B to the REAL repo runner, so inside it Get-Location != B.
    Write-Utf8 $wdWrapper (
        "& '$Runner' -FilePath 'pwsh' -Arguments @('-NoProfile','-File','$wdSuite') " +
        "-WorkingDirectory '$wdB' -TimeoutSeconds 40 -IdleTimeoutSeconds 35 -HeartbeatSeconds 1 -ResultPath '$wdResult' -RunId '$wdRunId' -Quiet`nexit `$LASTEXITCODE`n")
    $prevWdLocal = $env:LOCALAPPDATA
    $prevWdGo = $env:HOOKMAKER_WD_GO
    $wdProc = $null
    $wdMarkerName = ''
    try {
        $env:LOCALAPPDATA = $wdLocal
        $env:HOOKMAKER_WD_GO = $wdGo
        $wdProc = Start-Process -FilePath (Get-Process -Id $PID).Path -NoNewWindow -PassThru -WorkingDirectory $wdA -ArgumentList @('-NoLogo', '-NoProfile', '-File', $wdWrapper)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            $m = @(Get-ChildItem -LiteralPath $wdStateDir -Filter 'TestRunGuard-active-*.json' -File -ErrorAction SilentlyContinue)
            if ($m.Count -ge 1) { $wdMarkerName = $m[0].Name; break }
            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        try { New-Item -ItemType File -Path $wdGo -Force | Out-Null } catch { }
        if ($null -ne $wdProc) {
            try { [void]$wdProc.WaitForExit(10000) } catch { }
            if (-not $wdProc.HasExited) { try { & taskkill.exe /PID $wdProc.Id /T /F *> $null } catch { } }
        }
        $env:LOCALAPPDATA = $prevWdLocal
        $env:HOOKMAKER_WD_GO = $prevWdGo
    }
    Check 'the live marker is keyed to -WorkingDirectory B, not the launch cwd A' (
        $wdMarkerName -eq ('TestRunGuard-active-' + $keyB + '-' + (Get-SafeRunId $wdRunId) + '.json')) ($wdMarkerName + ' (want keyB=' + $keyB + ')')
    Check 'the marker is NOT written under the launch-cwd (A) key' (
        $wdMarkerName -ne '' -and $wdMarkerName -notmatch [regex]::Escape($keyA)) ($wdMarkerName + ' keyA=' + $keyA)
    $wdMarkerLeft = @(Get-ChildItem -LiteralPath $wdStateDir -Filter 'TestRunGuard-active-*.json' -File -ErrorAction SilentlyContinue)
    Check 'the runner removes its -WorkingDirectory-keyed marker on completion (none left)' ($wdMarkerLeft.Count -eq 0) ([string]$wdMarkerLeft.Count)

