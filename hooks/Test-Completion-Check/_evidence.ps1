# Test-Completion-Check: READING THE RECORDED EVIDENCE.
#
# result/observed/active records are PER-RUN, so two runs in one project own
# separate files and never overwrite each other. This file turns those files
# into answers: which run a record belongs to, when it was recorded, whether a
# negative was superseded by a later green run for the same command and state,
# whether an active marker still has a live owner, and how observed runs pair up
# with results. It reads and interprets; it decides nothing and writes nothing.
#
# Dot-sourced by Test-Completion-Check.ps1 via $PSScriptRoot.


# ---- read the recorded evidence (AGGREGATED across per-run files) ----------
# result/observed/active are PER-RUN (TestRunGuard-<kind>-<key>-<runId>.json), so
# two runs in one project each own their own files and never overwrite each other.
# Completion is accepted only when EVERY current-state observed run is satisfied
# and none is unfinished; it is BLOCKED when ANY run is active, terminated/leaked/
# failed, or observed-with-no-result. Older-STATE runs are not current evidence
# and never block. The single representative run selected below drives the exact
# same conditions 1-6 the single-file path used, so one-run behaviour is unchanged.

# All per-run files for one kind (+ a legacy non-suffixed file if an older build's
# run is still in flight), each with its parsed document.
function Get-CompletionStateEntries {
    param([string]$Kind)
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:stateDir -PathType Container)) { return @() }
    $files = New-Object System.Collections.Generic.List[object]
    try { foreach ($f in @(Get-ChildItem -LiteralPath $script:stateDir -Filter ('TestRunGuard-' + $Kind + '-' + $script:projectKey + '-*.json') -File -ErrorAction SilentlyContinue)) { [void]$files.Add($f) } } catch { }
    $legacy = Join-Path $script:stateDir ('TestRunGuard-' + $Kind + '-' + $script:projectKey + '.json')
    try { if (Test-Path -LiteralPath $legacy -PathType Leaf) { [void]$files.Add((Get-Item -LiteralPath $legacy -Force)) } } catch { }
    foreach ($file in $files) {
        $doc = $null
        try { $doc = Read-JsonFile $file.FullName } catch { $doc = $null }
        if ($null -eq $doc) { continue }
        [void]$entries.Add([pscustomobject]@{ Doc = $doc; Path = $file.FullName })
    }
    return @($entries.ToArray())
}

# The recorded time of a result: recordedUtc, else endedUtc, else file write time.
function Get-ResultRecordedTime {
    param($Doc, [string]$Path)
    $t = ConvertTo-UtcTime (Get-Field $Doc 'recordedUtc')
    if ($null -eq $t) { $t = ConvertTo-UtcTime (Get-Field $Doc 'endedUtc') }
    if ($null -eq $t -and -not [string]::IsNullOrWhiteSpace($Path)) {
        try { $t = (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc } catch { $t = $null }
    }
    return $t
}

function Get-ObservedFingerprint {
    param($Doc)
    $fp = [string](Get-Field $Doc 'projectFingerprint')
    if ([string]::IsNullOrWhiteSpace($fp)) { $fp = [string](Get-Field $Doc 'fingerprint') }
    return $fp
}

# The stable incident identity of a RESULT document, or '' when it is not an
# incident. Only a TERMINATED run or one carrying leaked process ids is an
# incident (a plain non-zero `failed` creates no durable-note obligation). The key
# is byte-identical to the one the main flow records into resolvedIncident, so a
# resolved incident can be recognised again per-run - used by the content-aware
# prune (C2) and the resolved-incident representative exclusion (C4).
function Get-ResultIncidentKey {
    param($Doc, [string]$Path)
    if ($null -eq $Doc) { return '' }
    $ov = ([string](Get-Field $Doc 'overall')).ToLowerInvariant()
    $tr = [string](Get-Field $Doc 'terminateReason')
    $lk = @(@(Get-Field $Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    if ($ov -ne 'terminated' -and $lk.Count -eq 0) { return '' }
    $t = Get-ResultRecordedTime -Doc $Doc -Path $Path
    $ticks = if ($null -ne $t) { [string]$t.Ticks } else { '0' }
    return (Get-ShortHash ($ticks + '|' + $ov + '|' + $tr + '|' + (@($lk) -join ',')))
}

# The human-readable incident reason for a RESULT document (byte-for-byte the
# text the main block path builds), or '' when the document is not an incident.
# Shared so the D2 first-sighting registration records the same reason the block
# would have used.
function Get-IncidentReasonFromDoc {
    param($Doc)
    if ($null -eq $Doc) { return '' }
    $ov = ([string](Get-Field $Doc 'overall')).ToLowerInvariant()
    $tr = [string](Get-Field $Doc 'terminateReason')
    $td = [string](Get-Field $Doc 'terminateDetail')
    $lk = @(@(Get-Field $Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    if ($ov -eq 'terminated') {
        return 'the guarded run was TERMINATED (' +
            $(if ($tr -ne '') { $tr } else { 'unknown reason' }) + ')' +
            $(if ($td -ne '') { ': ' + $td } else { '' })
    }
    if ($lk.Count -gt 0) {
        return 'the guarded run LEAKED process(es) ' + (@($lk) -join ', ') + ' that survived termination'
    }
    return ''
}

# Has a NEGATIVE result been SUPERSEDED by a strictly-newer clean run for the same
# command AND project state? A clean (overall=ok, no leak) result recorded after
# the negative one means the same work was re-run green, so the old incident's
# files are safe to prune (this is the C2/C4 supersede rule).
# ponytail: O(n*m) over one project's per-run files, which are 24h-bounded and few.
function Test-ResultSuperseded {
    param($NegDoc, $NegTime, $AllResults)
    if ($null -eq $NegDoc -or $null -eq $NegTime) { return $false }
    $cmd = [string](Get-Field $NegDoc 'commandFingerprint')
    $proj = [string](Get-Field $NegDoc 'projectFingerprint')
    if ($cmd -eq '' -or $proj -eq '') { return $false }
    foreach ($re in @($AllResults)) {
        $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
        if ($ov -ne 'ok') { continue }
        $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($lk.Count -gt 0) { continue }
        if (([string](Get-Field $re.Doc 'commandFingerprint')) -ne $cmd) { continue }
        if (([string](Get-Field $re.Doc 'projectFingerprint')) -ne $proj) { continue }
        $t = Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path
        if ($null -ne $t -and $t -gt $NegTime) { return $true }
    }
    return $false
}

# Is a live guarded run recorded by THIS active marker? Returns the owner pid, or
# 0. LIVENESS IS PROVEN BY PROCESS IDENTITY ONLY (C1): the owner pid must be alive
# AND still carry the recorded process start time AND executable path (the
# PID-REUSE-resistant check). The marker's projectFingerprint is DELIBERATELY not
# consulted here - a test process is running regardless of what the working tree
# looks like now, so editing an unrelated file mid-run (which moves the repo
# fingerprint) must never make a genuinely-live marker read as stale and be
# deleted. The fingerprint governs only whether a RESULT is current-state
# evidence, never whether a running process exists.
function Resolve-ActiveOwnerPid {
    param($Doc)
    $ownerPidRaw = Get-Field $Doc 'ownerPid'
    if ($null -eq $ownerPidRaw) { $ownerPidRaw = Get-Field $Doc 'pid' }   # schema-1 fallback
    $candidate = 0
    if (-not [int]::TryParse([string]$ownerPidRaw, [ref]$candidate) -or $candidate -le 0) { return 0 }
    $liveProcess = $null
    try { $liveProcess = Get-Process -Id $candidate -ErrorAction Stop } catch { $liveProcess = $null }
    if ($null -eq $liveProcess) { return 0 }
    $markerStartUtc = ConvertTo-UtcTime (Get-Field $Doc 'ownerProcessStartUtc')
    $markerExe = [string](Get-Field $Doc 'ownerExecutablePath')
    if ($null -eq $markerStartUtc -and $markerExe -eq '') { return $candidate }   # schema-1 marker: best-effort legacy
    $identityOk = $true
    if ($null -ne $markerStartUtc) {
        $liveStart = $null
        try { $liveStart = $liveProcess.StartTime.ToUniversalTime() } catch { $liveStart = $null }
        if ($null -eq $liveStart -or [Math]::Abs(($liveStart - $markerStartUtc).TotalSeconds) -gt 2) { $identityOk = $false }
    }
    if ($identityOk -and $markerExe -ne '') {
        $liveExe = ''
        try { $liveExe = [string]$liveProcess.Path } catch { $liveExe = '' }
        if ($liveExe -ne '' -and -not [string]::Equals($liveExe, $markerExe, [System.StringComparison]::OrdinalIgnoreCase)) { $identityOk = $false }
    }
    if ($identityOk) { return $candidate }
    return 0
}

# ONE-TO-ONE observed->result assignment (C3). Each guarded result may satisfy AT
# MOST ONE observed run. Exact-runId (runIdControlled) pairings are resolved FIRST
# so an uncontrolled run cannot steal a controlled run's result; the remaining
# uncontrolled runs then each take a DISTINCT leftover result. Returns the sorted
# observed list, the index->result map, and the set of assigned result paths. Used
# by BOTH the prune pre-pass (D3) and the main flow, so pruning can never treat one
# shared result as covering two observations.
function Get-ObservedResultAssignment {
    param($CurrentObserved, $ResultEntries, [string]$StateFp)
    $sortedObserved = @($CurrentObserved | Sort-Object `
        @{ Expression = { [string](Get-Field $_.Doc 'observedUtc') } }, `
        @{ Expression = { [string](Get-Field $_.Doc 'runId') } })
    $sortedResults = @($ResultEntries | Sort-Object `
        @{ Expression = { $t = Get-ResultRecordedTime -Doc $_.Doc -Path $_.Path; if ($null -ne $t) { $t.Ticks } else { [int64]0 } } }, `
        @{ Expression = { [string]$_.Path } })
    $assigned = New-Object System.Collections.Generic.HashSet[string]
    $map = @{}
    for ($pass = 0; $pass -lt 2; $pass++) {
        $controlledPass = ($pass -eq 0)
        for ($oi = 0; $oi -lt $sortedObserved.Count; $oi++) {
            if ($map.ContainsKey($oi)) { continue }
            $odoc = $sortedObserved[$oi].Doc
            $controlled = ((Get-Field $odoc 'runIdControlled') -eq $true)
            if ($controlled -ne $controlledPass) { continue }
            foreach ($re in $sortedResults) {
                if ($assigned.Contains($re.Path)) { continue }
                if (Test-ResultMatchesObserved -Result $re.Doc -Observed $odoc -CurrentStateFingerprint $StateFp) {
                    $map[$oi] = $re
                    [void]$assigned.Add($re.Path)
                    break
                }
            }
        }
    }
    return [pscustomobject]@{ SortedObserved = $sortedObserved; Map = $map; AssignedPaths = $assigned }
}
