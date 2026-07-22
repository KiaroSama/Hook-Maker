# Offline suite for HM-07: the bounded rolling test-timing history.
#
# It exercises the REAL code on both sides, never a copy:
#   * WRITE side - Add-TimingSample / Remove-StaleTimingKeys are AST-extracted
#     from scripts\Run-Tests-Guarded.ps1 (the standalone runner) and written to a
#     tiny module the suite AND its concurrent child processes both dot-source.
#   * READ side  - Get-TimingBaseline math (Get-ComparableOkSeconds / Get-Median /
#     Test-TimingRegression) is dot-sourced from hooks\_hooklib.ps1.
#
# Covers the six required scenarios: concurrent writes, one outlier, repeated
# slowdown, worker-count change, bounded history size, and secret-free state.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TimingHistory.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $RepoRoot 'scripts\Run-Tests-Guarded.ps1'
$HookLib = Join-Path $RepoRoot 'hooks\_hooklib.ps1'
foreach ($required in @($Runner, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

# READ side: the real baseline/regression math + Read-JsonFile/Get-Field/Get-ShortHash.
. $HookLib

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-timingtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# WRITE side: extract the REAL functions from the runner into a shared module so
# the suite and every concurrent child call the SAME code (never a re-implementation).
$rAst = [System.Management.Automation.Language.Parser]::ParseFile($Runner, [ref]$null, [ref]$null)
$addFn = $rAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-TimingSample' }, $true)
$pruneFn = $rAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-StaleTimingKeys' }, $true)
if ($null -eq $addFn -or $null -eq $pruneFn) {
    Write-Host 'could not locate Add-TimingSample / Remove-StaleTimingKeys in Run-Tests-Guarded.ps1' -ForegroundColor Red
    exit 1
}
$writerModule = Join-Path $Work 'timingwriter.ps1'
Write-Utf8 $writerModule ("`$script:TimingMaxSamples = 30`r`n" + $addFn.Extent.Text + "`r`n" + $pruneFn.Extent.Text + "`r`n")
. $writerModule

$StateDir = Join-Path $Work 'state'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$PK = 'proj123abc'
$CMD = ('a' * 32)

function Add-Ok { param([double]$Seconds, [int]$Ceiling = 4, [string]$RunId = '', [string]$Outcome = 'ok')
    if ($RunId -eq '') { $RunId = [guid]::NewGuid().ToString('N') }
    Add-TimingSample -StateDir $StateDir -ProjectKey $PK -CommandFingerprint $CMD -RunId $RunId -ElapsedSeconds $Seconds -Outcome $Outcome -WorkerCeiling $Ceiling
    return $RunId
}
function Read-History { Read-JsonFile (Get-TimingHistoryPath -StateDir $StateDir -ProjectKey $PK -CommandFingerprint $CMD) }
function Reset-History { $p = Get-TimingHistoryPath -StateDir $StateDir -ProjectKey $PK -CommandFingerprint $CMD; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }

try {
    # =====================================================================
    Write-Host '--- 1/6 secret-free state: only the sanitized fields are ever stored ---' -ForegroundColor Cyan
    Reset-History
    [void](Add-Ok -Seconds 12.3 -Ceiling 4)
    $doc = Read-History
    Check 'a sample file is written' ($null -ne $doc -and $doc.PSObject.Properties['samples'] -and @($doc.samples).Count -eq 1)
    $allowed = @('runId', 'elapsedSeconds', 'outcome', 'utc', 'workerCeiling', 'suiteLabel')
    $s0 = @($doc.samples)[0]
    $extra = @($s0.PSObject.Properties.Name | Where-Object { $allowed -notcontains $_ })
    Check 'a sample carries ONLY the sanitized fields (no args/paths/secrets can be stored)' ($extra.Count -eq 0) ('unexpected: ' + ($extra -join ','))
    $rawText = [System.IO.File]::ReadAllText((Get-TimingHistoryPath -StateDir $StateDir -ProjectKey $PK -CommandFingerprint $CMD))
    Check 'the on-disk file exposes no argument/prompt/secret key' ($rawText -notmatch 'password|token|secret|argument|prompt|-File|C:\\\\') $rawText

    # =====================================================================
    Write-Host '--- 2/6 bounded history size: the rolling window keeps only the last N ---' -ForegroundColor Cyan
    Reset-History
    $lastIds = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le 40; $i++) {
        $id = Add-Ok -Seconds 10 -Ceiling 4 -RunId ('run{0:D3}' -f $i)
        if ($i -gt 10) { [void]$lastIds.Add($id) }   # the last 30 (11..40)
    }
    $doc = Read-History
    $kept = @($doc.samples)
    Check 'the window is bounded to 30 samples (40 written)' ($kept.Count -eq 30) ([string]$kept.Count)
    $keptIds = @($kept | ForEach-Object { [string]$_.runId })
    Check 'the window keeps the MOST RECENT 30, dropping the oldest 10' (
        $keptIds[0] -eq 'run011' -and $keptIds[-1] -eq 'run040') ($keptIds[0] + '..' + $keptIds[-1])

    # =====================================================================
    Write-Host '--- 3/6 repeated slowdown IS flagged; too-few-samples is NOT ---' -ForegroundColor Cyan
    Reset-History
    for ($i = 1; $i -le 8; $i++) { [void](Add-Ok -Seconds 10 -Ceiling 4) }
    $doc = Read-History
    $regSlow = Test-TimingRegression -History $doc -WorkerCeiling 4 -ElapsedSeconds 60
    Check 'a 60s run against a 10s median over 8 runs is a regression' ($regSlow.IsRegression -and $regSlow.Median -eq 10) ([string]$regSlow.Median + ' / reg=' + $regSlow.IsRegression)
    Reset-History
    for ($i = 1; $i -le 4; $i++) { [void](Add-Ok -Seconds 10 -Ceiling 4) }   # below the 5-sample minimum
    $regFew = Test-TimingRegression -History (Read-History) -WorkerCeiling 4 -ElapsedSeconds 60
    Check 'with too few comparable samples, nothing is called a regression yet' (-not $regFew.IsRegression -and $regFew.Samples -eq 4) ('samples=' + $regFew.Samples)

    # =====================================================================
    Write-Host '--- 4/6 one outlier neither redefines the baseline nor flags the next normal run ---' -ForegroundColor Cyan
    Reset-History
    for ($i = 1; $i -le 10; $i++) { [void](Add-Ok -Seconds 10 -Ceiling 4) }
    $regNormalBefore = Test-TimingRegression -History (Read-History) -WorkerCeiling 4 -ElapsedSeconds 11
    Check 'an 11s run against a 10s median is NOT a regression' (-not $regNormalBefore.IsRegression) ([string]$regNormalBefore.Median)
    [void](Add-Ok -Seconds 100 -Ceiling 4)   # a single noisy slow run is recorded too
    $docO = Read-History
    $regNormalAfter = Test-TimingRegression -History $docO -WorkerCeiling 4 -ElapsedSeconds 11
    Check 'the robust median is unmoved by one 100s outlier (still 10, not skewed up)' ($regNormalAfter.Median -eq 10) ([string]$regNormalAfter.Median)
    Check 'so the next normal 11s run is STILL not flagged (outlier did not redefine the baseline)' (-not $regNormalAfter.IsRegression) ('reg=' + $regNormalAfter.IsRegression)

    # =====================================================================
    Write-Host '--- 5/6 a worker-count change does not cause a false regression ---' -ForegroundColor Cyan
    Reset-History
    for ($i = 1; $i -le 6; $i++) { [void](Add-Ok -Seconds 10 -Ceiling 4) }   # baseline at ceiling 4
    $doc = Read-History
    $regDiffWorkers = Test-TimingRegression -History $doc -WorkerCeiling 1 -ElapsedSeconds 40
    Check 'a 40s run at a DIFFERENT worker ceiling (1) has no comparable baseline -> not a regression' (-not $regDiffWorkers.IsRegression -and $regDiffWorkers.Samples -eq 0) ('samples=' + $regDiffWorkers.Samples)
    $regSameWorkers = Test-TimingRegression -History $doc -WorkerCeiling 4 -ElapsedSeconds 40
    Check 'the SAME slow 40s run at the baseline ceiling (4) IS a regression' ($regSameWorkers.IsRegression) ('reg=' + $regSameWorkers.IsRegression)

    # ExcludeRunId: a run must never be compared against its own just-recorded sample.
    Reset-History
    for ($i = 1; $i -le 6; $i++) { [void](Add-Ok -Seconds 10 -Ceiling 4) }
    $selfId = Add-Ok -Seconds 90 -Ceiling 4   # this slow run is now IN the history
    $regSelf = Test-TimingRegression -History (Read-History) -WorkerCeiling 4 -ElapsedSeconds 90 -ExcludeRunId $selfId
    Check 'the run is compared against PRIOR history (its own 90s sample excluded), so it is flagged' ($regSelf.IsRegression -and $regSelf.Median -eq 10) ([string]$regSelf.Median)

    # =====================================================================
    Write-Host '--- 6/6 concurrent writes: a lock keeps every sample (none lost) ---' -ForegroundColor Cyan
    Reset-History
    $concChild = Join-Path $Work 'concchild.ps1'
    Write-Utf8 $concChild @'
param([string]$Module, [string]$StateDir, [string]$Key, [string]$Cmd, [string]$RunId)
Set-StrictMode -Version 2.0
. $Module
Add-TimingSample -StateDir $StateDir -ProjectKey $Key -CommandFingerprint $Cmd -RunId $RunId -ElapsedSeconds 10 -Outcome 'ok' -WorkerCeiling 4
'@
    $exe = (Get-Process -Id $PID).Path
    $procs = New-Object System.Collections.Generic.List[object]
    $n = 8
    for ($i = 1; $i -le $n; $i++) {
        $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoLogo', '-NoProfile', '-File', $concChild, '-Module', $writerModule, '-StateDir', $StateDir, '-Key', $PK, '-Cmd', $CMD, '-RunId', ('conc{0:D2}' -f $i))
        [void]$procs.Add($p)
    }
    foreach ($p in $procs) { [void]$p.WaitForExit(30000) }
    $docC = Read-History
    $ids = @(@($docC.samples) | ForEach-Object { [string]$_.runId } | Sort-Object -Unique)
    Check ('all ' + $n + ' concurrent samples survived the lock (none lost)') ($ids.Count -eq $n) ('kept ' + $ids.Count + ' of ' + $n + ': ' + ($ids -join ','))
    Check 'no lock file is left behind after concurrent writes' (@(Get-ChildItem -LiteralPath $StateDir -Filter 'TestTiming-*.lock' -File -ErrorAction SilentlyContinue).Count -eq 0)

    # =====================================================================
    Write-Host '--- prune: only stale TestTiming-* files are removed; incident notes are untouched ---' -ForegroundColor Cyan
    $incident = Join-Path $StateDir 'TestRunGuard-incident-note.json'
    Write-Utf8 $incident '{"unresolved":true}'
    $staleTiming = Join-Path $StateDir 'TestTiming-oldkey-oldcmd.json'
    Write-Utf8 $staleTiming '{"version":1,"samples":[]}'
    (Get-Item -LiteralPath $staleTiming).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-200)
    Remove-StaleTimingKeys -StateDir $StateDir -StaleDays 90
    Check 'a 200-day-old TestTiming file is pruned' (-not (Test-Path -LiteralPath $staleTiming))
    Check 'a fresh TestTiming file is preserved' (Test-Path -LiteralPath (Get-TimingHistoryPath -StateDir $StateDir -ProjectKey $PK -CommandFingerprint $CMD))
    Check 'an unresolved incident note is NEVER touched by timing pruning' (Test-Path -LiteralPath $incident)

    # =====================================================================
    Write-Host '--- stale-lock recovery: a crash leftover .lock is reclaimed; a LIVE lock never is ---' -ForegroundColor Cyan
    $histPath = Get-TimingHistoryPath -StateDir $StateDir -ProjectKey $PK -CommandFingerprint $CMD
    $lockPath = $histPath + '.lock'

    # (a) STALE: a .lock backdated 10 minutes simulates a holder that crashed
    # between CreateNew and its finally-delete. The writer must reclaim it, take
    # the lock, write the sample, and leave no .lock behind.
    Reset-History
    Write-Utf8 $lockPath ''
    (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    [void](Add-Ok -Seconds 10 -Ceiling 4 -RunId 'stalerec')
    $docS = Read-History
    $staleIds = if ($null -ne $docS -and $docS.PSObject.Properties['samples']) { @(@($docS.samples) | ForEach-Object { [string]$_.runId }) } else { @() }
    Check 'a stale (10-minute-old) crash leftover .lock is reclaimed and the sample IS written' ($staleIds -contains 'stalerec') ($staleIds -join ',')
    Check 'no .lock remains after stale recovery' (-not (Test-Path -LiteralPath $lockPath))

    # (b) LIVE: an OPEN FileShare::None handle on a backdated .lock proves the
    # safety property - liveness beats age. The delete is refused by the open
    # handle, so the writer waits out its 5s deadline and gives up best-effort:
    # no sample, no exception, and the held lock file is untouched.
    Reset-History
    Write-Utf8 $lockPath ''
    (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $holder = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $liveErr = $null
        try { [void](Add-Ok -Seconds 10 -Ceiling 4 -RunId 'liverec') } catch { $liveErr = $_ }
        Check 'a LIVE held lock (even stale-looking) is never stolen: no exception escapes' ($null -eq $liveErr) ([string]$liveErr)
        Check 'the sample is NOT written while the lock is held' (-not (Test-Path -LiteralPath $histPath))
        Check 'the held .lock file still exists' (Test-Path -LiteralPath $lockPath)
    }
    finally {
        try { $holder.Close() } catch { }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }

    # =====================================================================
    Write-Host '--- red-proof: the PRE-FIX writer is permanently blocked by a stale lock ---' -ForegroundColor Cyan
    # Extract the committed (HEAD) Add-TimingSample. While HEAD predates the
    # stale-lock fix this proves scenario (a) genuinely failed before it; once
    # the fix is committed the two extents become identical and this historical
    # proof retires itself (scenario (a) stays as the durable regression test).
    $oldText = ''
    try { $oldText = (& git -C $RepoRoot show 'HEAD:scripts/Run-Tests-Guarded.ps1' 2>$null) -join "`n" } catch { }
    if ([string]::IsNullOrWhiteSpace($oldText)) {
        Write-Host 'git show unavailable; skipping the historical red-proof.' -ForegroundColor DarkGray
    }
    else {
        $t = $null; $e = $null
        $oldAst = [System.Management.Automation.Language.Parser]::ParseInput($oldText, [ref]$t, [ref]$e)
        $oldFn = $oldAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-TimingSample' }, $true)
        if ($null -eq $oldFn) {
            Write-Host 'HEAD has no Add-TimingSample; skipping the historical red-proof.' -ForegroundColor DarkGray
        }
        elseif ($oldFn.Extent.Text -eq $addFn.Extent.Text) {
            Write-Host 'HEAD already contains the stale-lock fix; historical red-proof retired.' -ForegroundColor DarkGray
        }
        else {
            $redState = Join-Path $Work 'redstate'
            New-Item -ItemType Directory -Path $redState -Force | Out-Null
            $redHist = Get-TimingHistoryPath -StateDir $redState -ProjectKey $PK -CommandFingerprint $CMD
            $redLock = $redHist + '.lock'
            Write-Utf8 $redLock ''
            (Get-Item -LiteralPath $redLock).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
            $oldModule = Join-Path $Work 'timingwriter-prefix.ps1'
            Write-Utf8 $oldModule ("`$script:TimingMaxSamples = 30`r`n" + $oldFn.Extent.Text + "`r`n")
            # Dot-source inside a child scope so the OLD function never replaces
            # the fixed one this suite already loaded.
            & {
                . $oldModule
                Add-TimingSample -StateDir $redState -ProjectKey $PK -CommandFingerprint $CMD -RunId 'redproof' -ElapsedSeconds 10 -Outcome 'ok' -WorkerCeiling 4
            }
            Check 'PRE-FIX: the stale lock permanently blocks - the sample is NOT written' (-not (Test-Path -LiteralPath $redHist))
            Check 'PRE-FIX: the stale .lock is never reclaimed' (Test-Path -LiteralPath $redLock)
        }
    }
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
