# Run-Tests-Guarded section: the worker budget and the rolling timing history.
#
# Dot-sourced by Run-Tests-Guarded.ps1, so it runs in that script's scope and
# its $script: state ($script:TimingRecorded, $script:TimingMaxSamples) lands
# where it always did. Split out because the runner had passed the size band
# that closes a file to new code; the boundary is a real one - nothing here
# owns a process, and nothing here decides whether to kill one.
#
# Standalone like its parent: this file does NOT dot-source _hooklib.ps1, so
# the sample shape and the TestTiming-* path stay byte-compatible with the
# READ side in hooks\_hooklib.ps1.

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

# ---- HM-07: bounded rolling test-timing history (WRITE side) ----------------
# Standalone (this runner does not dot-source _hooklib), so the sanitized sample
# shape, the TestTiming-<projectKey>-<commandFp>.json path and the 30-sample
# rolling window MUST stay byte-compatible with hooks\_hooklib.ps1's READ side.
# Only runId/elapsed/outcome/UTC/workerCeiling/suiteLabel are stored - never an
# argument, path, prompt, secret, user name or token. Best-effort: a timing
# failure NEVER changes the run's real outcome or exit code.
$script:TimingRecorded = $false
$script:TimingMaxSamples = 30

function Add-TimingSample {
    param([string]$StateDir, [string]$ProjectKey, [string]$CommandFingerprint, [string]$RunId,
        [double]$ElapsedSeconds, [string]$Outcome, [int]$WorkerCeiling, [string]$SuiteLabel = '')
    if ([string]::IsNullOrWhiteSpace($ProjectKey) -or [string]::IsNullOrWhiteSpace($CommandFingerprint)) { return }
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
        try { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null } catch { return }
    }
    $path = Join-Path $StateDir ('TestTiming-' + $ProjectKey + '-' + $CommandFingerprint + '.json')
    $lock = $path + '.lock'
    # Exclusive-create lock with a bounded retry: two concurrent runs in one
    # project each do a real read-modify-write and neither loses the other sample.
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $fs = $null
    while ($null -eq $fs) {
        try { $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { return }   # best-effort; never block the run
            # Stale-lock recovery: a real write holds the lock for milliseconds, so a
            # .lock older than 60s can only be a crash leftover between CreateNew and
            # the finally-delete. FileShare::None is the safety property: a LIVE
            # holder's open handle makes File.Delete FAIL, so a successful delete is
            # itself proof the holder is dead - reclaim and retry CreateNew at once.
            # A refused delete means the holder is alive: keep waiting to the deadline.
            try {
                if ([System.IO.File]::Exists($lock) -and
                    ([DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($lock)).TotalSeconds -gt 60) {
                    [System.IO.File]::Delete($lock)
                    continue
                }
            }
            catch { }   # holder alive (or lock vanished); fall through to the bounded wait
            Start-Sleep -Milliseconds 50
        }
    }
    try {
        $samples = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $existing = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($null -ne $existing -and $existing.PSObject.Properties['samples']) {
                    foreach ($s in @($existing.samples)) { if ($null -ne $s) { [void]$samples.Add($s) } }
                }
            }
            catch { }   # a corrupt file starts fresh rather than crash the runner
        }
        [void]$samples.Add([pscustomobject]@{
                runId          = $RunId
                elapsedSeconds = [Math]::Round($ElapsedSeconds, 1)
                outcome        = $Outcome
                utc            = (Get-Date).ToUniversalTime().ToString('o')
                workerCeiling  = $WorkerCeiling
                suiteLabel     = $SuiteLabel
            })
        # Bounded rolling window: keep only the most recent TimingMaxSamples.
        # .ToArray(), never @($list): @() on a List[object] holding PSCustomObjects
        # throws "Argument types do not match" under PowerShell.
        $keep = $samples.ToArray()
        if ($keep.Count -gt $script:TimingMaxSamples) { $keep = $keep[($keep.Count - $script:TimingMaxSamples)..($keep.Count - 1)] }
        $doc = [pscustomobject]@{ version = 1; projectKey = $ProjectKey; commandFingerprint = $CommandFingerprint; samples = $keep }
        $tmp = $path + '.tmp'
        [System.IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    finally {
        try { $fs.Close() } catch { }
        try { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# Prune only TestTiming-* files older than StaleDays. Incident notes use other
# prefixes and are NEVER touched, so pruning cannot drop an unresolved incident.
function Remove-StaleTimingKeys {
    param([string]$StateDir, [int]$StaleDays = 90)
    try {
        if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { return }
        $cut = (Get-Date).ToUniversalTime().AddDays(-1 * [Math]::Abs($StaleDays))
        foreach ($f in @(Get-ChildItem -LiteralPath $StateDir -Filter 'TestTiming-*.json' -File -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTimeUtc -lt $cut) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    catch { }
}

# Records THIS run's sample from $script:Result. Called on every terminal path,
# guarded so it runs once and never alters the real outcome or exit code.
function Save-TimingSample {
    if ($script:TimingRecorded) { return }
    $script:TimingRecorded = $true
    try {
        $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
        Add-TimingSample -StateDir $stateDir -ProjectKey ([string]$script:Result.projectKey) `
            -CommandFingerprint ([string]$script:Result.commandFingerprint) -RunId ([string]$script:Result.runId) `
            -ElapsedSeconds ([double]$script:Result.elapsedSeconds) -Outcome ([string]$script:Result.overall) `
            -WorkerCeiling ([int]$script:Result.workerBudget)
        Remove-StaleTimingKeys -StateDir $stateDir
    }
    catch { }
}
