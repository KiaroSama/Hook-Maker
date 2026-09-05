# One verdict per install record, and the two schedulers that produce them.
#
# THE VERDICT IS READ-ONLY. Get-RecordUpdateState hashes files, parses client
# settings and compares manifests; it writes nothing, logs nothing, and touches
# no shared state - every `$script:` value in the install libraries is a
# constant fixed at dot-source time. That is the whole reason the parallel
# scheduler below is safe. If a future check needs to WRITE, it does not belong
# in this function; put it in the apply phase, which stays sequential.
#
# Dot-sourced by Setup-SyncGroup.ps1 before Setup-SyncGroupInstallFlows.ps1.

# The evaluation for ONE record: identical logic to the sequential loop this
# replaced, so both schedulers return the same verdict for the same input.
# Never throws - a record that cannot be evaluated becomes a 'skip' naming why,
# because one malformed record must not end a 600-record run.
function Get-RecordUpdateState {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$ToolRoot
    )
    $status = ''
    $components = @()
    $detail = ''
    try {
        $validation = Test-InstallRecordValid -Record $Record
        if (-not $validation.Ok) {
            $status = 'skip'; $detail = 'invalid registry record (manual repair): ' + $validation.Reason
        }
        elseif (-not (Test-Path -LiteralPath $Record.sourceScript -PathType Leaf)) {
            $status = 'skip'; $detail = 'source script no longer found: ' + $Record.sourceScript
        }
        elseif (($Record.scope -ne 'global') -and -not (Test-Path -LiteralPath $Record.targetProjectRoot -PathType Container)) {
            $status = 'skip'; $detail = 'target project no longer found: ' + $Record.targetProjectRoot
        }
        elseif ($Record.hookType -eq 'Engine' -and -not (Test-Path -LiteralPath $Record.configPath -PathType Leaf)) {
            $status = 'skip'; $detail = 'sync config no longer found: ' + $Record.configPath
        }
        elseif ($Record.hookType -eq 'Engine') {
            $engineConfig = Read-JsonFile $Record.configPath
            $profileExists = ($null -ne $engineConfig) -and ($null -ne $engineConfig.PSObject.Properties['profiles']) -and (@($engineConfig.profiles | Where-Object { [string]$_.id -eq [string]$Record.profile }).Count -gt 0)
            if (-not $profileExists) { $status = 'skip'; $detail = 'profile no longer exists in the sync config: ' + $Record.profile }
        }
        if ($status -eq '') {
            $evaluation = Get-InstallIntegrity -Record $Record -ToolRoot $ToolRoot
            $status = $evaluation.Status
            $detail = $evaluation.Detail
            # Per-component breakdown drives targeted repair later.
            if ($null -ne $evaluation.PSObject.Properties['Components']) { $components = @($evaluation.Components) }
        }
    }
    catch {
        $status = 'skip'
        $detail = 'could not evaluate this record (manual repair): ' + $_.Exception.Message
    }
    return [pscustomobject]@{ Status = $status; Detail = $detail; Components = $components }
}

# Resource-aware and deliberately conservative. The work is I/O-heavy rather
# than CPU-heavy, so more workers than cores buys nothing and competes with
# whatever else the machine is doing - including a test run in another window.
# HOOKMAKER_MAX_UPDATE_WORKERS overrides it for a machine that wants less.
function Get-UpdateEvaluationWorkerCount {
    $cores = 4
    try { $cores = [int][System.Environment]::ProcessorCount } catch { $cores = 4 }
    $count = [Math]::Max(2, [Math]::Min(8, $cores - 2))
    $override = [string]$env:HOOKMAKER_MAX_UPDATE_WORKERS
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $parsed = 0
        if ([int]::TryParse($override.Trim(), [ref]$parsed) -and $parsed -ge 1) {
            $count = [Math]::Min($count, $parsed)
        }
    }
    return $count
}

# Records in, one plan entry each, IN THE ORIGINAL ORDER - the printed plan is
# numbered and the user selects by that number, so order is part of the
# contract, not a detail.
#
# Below the threshold, or with one worker, this runs the same function inline:
# opening a pool and dot-sourcing the install libraries into each runspace costs
# a few hundred milliseconds per worker, which is not worth paying to evaluate a
# handful of records.
function Get-UpdateEvaluationPlan {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [int]$MinimumForParallel = 16,
        # A ceiling, not an expected duration: a single record measured ~0.2s on
        # a 600-record registry, so even a very slow machine finishes far inside
        # this. It exists so a wedged runspace reports instead of hanging the
        # wizard for ever.
        [int]$TimeoutSeconds = 1800
    )
    $plan = New-Object System.Collections.Generic.List[object]
    $records = @($Records)
    if ($records.Count -eq 0) { return $plan }

    $workers = Get-UpdateEvaluationWorkerCount
    if ($records.Count -lt $MinimumForParallel -or $workers -lt 2) {
        foreach ($record in $records) {
            $state = Get-RecordUpdateState -Record $record -ToolRoot $ToolRoot
            [void]$plan.Add([pscustomobject]@{ Record = $record; Status = $state.Status; Detail = $state.Detail; Components = $state.Components })
        }
        return $plan
    }

    # Round-robin, not contiguous blocks: records arrive grouped by nothing in
    # particular, but a contiguous slice can still land entirely on one slow
    # project and leave the other workers idle.
    $slices = New-Object 'System.Collections.Generic.List[System.Collections.Generic.List[int]]'
    for ($w = 0; $w -lt $workers; $w++) { [void]$slices.Add((New-Object System.Collections.Generic.List[int])) }
    for ($i = 0; $i -lt $records.Count; $i++) { [void]$slices[$i % $workers].Add($i) }

    # Mirrors what Setup-SyncGroup.ps1 itself loads; the rest cascade from these.
    $bootstrap = {
        param($ToolRoot, $Records, $Indexes)
        Set-StrictMode -Version 2.0
        $ErrorActionPreference = 'Stop'
        $scriptRoot = Join-Path $ToolRoot 'scripts'
        . (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
        . (Join-Path $scriptRoot '_installplan.ps1')
        . (Join-Path $scriptRoot '_installlib.ps1')
        . (Join-Path $scriptRoot '_clientcapability.ps1')
        . (Join-Path $scriptRoot '_installevaluate.ps1')
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($index in @($Indexes)) {
            $state = Get-RecordUpdateState -Record $Records[$index] -ToolRoot $ToolRoot
            [void]$out.Add([pscustomobject]@{ Index = $index; Status = $state.Status; Detail = $state.Detail; Components = $state.Components })
        }
        return $out.ToArray()
    }

    $pool = $null
    $running = New-Object System.Collections.Generic.List[object]
    $states = New-Object 'System.Collections.Generic.Dictionary[int,object]'
    try {
        $pool = [runspacefactory]::CreateRunspacePool(1, $workers)
        $pool.Open()
        foreach ($slice in $slices) {
            if ($slice.Count -eq 0) { continue }
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            [void]$shell.AddScript($bootstrap).AddArgument($ToolRoot).AddArgument($records).AddArgument($slice.ToArray())
            [void]$running.Add([pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke(); Slice = $slice })
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        foreach ($job in $running) {
            $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
            if (-not $job.Handle.AsyncWaitHandle.WaitOne($remaining)) {
                # Past the ceiling: stop this worker and let its records fall
                # through to the sequential retry below rather than hanging.
                try { $job.Shell.Stop() } catch { }
                continue
            }
            try {
                foreach ($entry in @($job.Shell.EndInvoke($job.Handle))) {
                    if ($null -eq $entry) { continue }
                    $states[[int]$entry.Index] = $entry
                }
            }
            catch {
                # A worker that died takes only its own slice with it.
            }
        }
    }
    catch {
        # No pool, no parallelism - every record still gets a verdict below.
    }
    finally {
        foreach ($job in $running) { try { $job.Shell.Dispose() } catch { } }
        if ($null -ne $pool) { try { $pool.Close(); $pool.Dispose() } catch { } }
    }

    # Anything a worker did not return is evaluated here, in this runspace. A
    # partial parallel result is therefore never a partial PLAN.
    for ($i = 0; $i -lt $records.Count; $i++) {
        if ($states.ContainsKey($i)) {
            $entry = $states[$i]
            [void]$plan.Add([pscustomobject]@{ Record = $records[$i]; Status = [string]$entry.Status; Detail = [string]$entry.Detail; Components = @($entry.Components) })
        }
        else {
            $state = Get-RecordUpdateState -Record $records[$i] -ToolRoot $ToolRoot
            [void]$plan.Add([pscustomobject]@{ Record = $records[$i]; Status = $state.Status; Detail = $state.Detail; Components = $state.Components })
        }
    }
    return $plan
}
