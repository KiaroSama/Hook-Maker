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
    # ANY non-ok outcome gets a key. It used to be minted only for a termination
    # or a leak, so a plain assertion failure blocked while the block's own
    # recovery text demanded an incident key that was never created - the
    # documented way out could not be taken. A key costs nothing when unused.
    if ($ov -eq 'ok' -and $lk.Count -eq 0) { return '' }
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

# Has a NEGATIVE result been SUPERSEDED by a strictly-newer clean run of the same
# COMMAND? A clean (overall=ok, no leak) result recorded after the negative one
# means the same work was re-run green, so the old incident's files are safe to
# prune (this is the C2/C4 supersede rule).
#
# Deliberately NOT also matched on projectFingerprint. That fingerprint is a hash
# of HEAD plus `git status --porcelain`, so it changes on every commit and every
# edit - and fixing the failure is itself an edit. Requiring it made the rule
# unsatisfiable for its own main case: a green run could never supersede the
# failure it had just repaired, and the gate cited that failure until the 24h
# prune horizon. "Same project" is not lost by dropping it: Get-CompletionStateEntries
# globs by projectKey, so $AllResults is already one project's runs and nothing
# else can appear here. See docs/adr/0001-supersede-by-project-not-tree-state.md.
#
# The commandFingerprint match is unchanged, and it covers the whole argument
# vector - so a run of three suites does not supersede a one-suite failure.
# ponytail: O(n*m) over one project's per-run files, which are 24h-bounded and few.
function Test-ResultSuperseded {
    param($NegDoc, $NegTime, $AllResults)
    if ($null -eq $NegDoc -or $null -eq $NegTime) { return $false }
    $cmd = [string](Get-Field $NegDoc 'commandFingerprint')
    if ($cmd -eq '') { return $false }
    foreach ($re in @($AllResults)) {
        $ov = ([string](Get-Field $re.Doc 'overall')).ToLowerInvariant()
        if ($ov -ne 'ok') { continue }
        $lk = @(@(Get-Field $re.Doc 'leakedProcessIds') | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($lk.Count -gt 0) { continue }
        if (([string](Get-Field $re.Doc 'commandFingerprint')) -ne $cmd) { continue }
        $t = Get-ResultRecordedTime -Doc $re.Doc -Path $re.Path
        if ($null -ne $t -and $t -gt $NegTime) { return $true }
    }
    return $false
}

# What state is the run behind THIS active marker in? Returns
# { State; OwnerPid; RunId; Detail } where State is one of:
#
#   live      the recorded owner is PROVABLY the process running right now, so a
#             test is genuinely executing. Blocks completion.
#   finished  the owner is gone and a result document exists for this runId - the
#             run ended and its outcome is on record. The marker is leftover.
#   died      the owner is gone (or cannot be proven to be the recorded one) and
#             NO result exists. The run was killed before it could record how it
#             ended: the outcome is unknown and unrecoverable. Blocks.
#   expired   the same, but the marker is older than the abandoned-record horizon,
#             so it belongs to a previous session and cannot describe this task.
#             Reconciled and dropped with a trace; never blocks the current work.
#
# IDENTITY MUST BE FULLY PINNED OR THE MARKER IS NEVER 'live'. Windows reuses
# pids freely, so "pid 38004 is alive" proves nothing on its own: what has to
# match is the PROCESS, i.e. the pid AND the start time it was recorded with
# (and the executable, when both sides know it). The older form of this check
# treated the start time as optional and fell back to the pid alone whenever the
# field was absent, empty or unparseable - and the executable is no
# discriminator, because whatever recycles a pwsh pid is almost always another
# pwsh. That is how a marker whose owner had long since died blocked completion
# on a brand-new guarded runner that merely inherited its pid. There is now no
# pid-only path: an unpinnable marker is not evidence that anything is running.
#
# The marker's projectFingerprint is DELIBERATELY not consulted - a test process
# is running regardless of what the working tree looks like now, so editing an
# unrelated file mid-run must never make a genuinely-live marker read as stale.
function Get-ActiveMarkerState {
    param($Doc, [string]$Path, [int]$MaxAgeHours, $ResultEntries)
    $runId = [string](Get-Field $Doc 'runId')

    # ---- is the recorded owner provably the process running right now? ----
    $ownerPidRaw = Get-Field $Doc 'ownerPid'
    if ($null -eq $ownerPidRaw) { $ownerPidRaw = Get-Field $Doc 'pid' }   # schema-1 field name
    $candidate = 0
    [void][int]::TryParse([string]$ownerPidRaw, [ref]$candidate)

    $detail = ''
    $isLive = $false
    if ($candidate -le 0) {
        $detail = 'the marker records no usable owner process id'
    }
    else {
        # PID + start time is the MINIMUM identity. No parseable start time means
        # the recorded process can never be told apart from whatever inherited
        # its pid, so the marker cannot prove a run is live - schema-1 markers
        # and markers whose owner lookup failed at write time included.
        $markerStartUtc = ConvertTo-UtcTime (Get-Field $Doc 'ownerProcessStartUtc')
        if ($null -eq $markerStartUtc) {
            $detail = 'the marker records no parseable owner start time, so process ' + $candidate +
                ' cannot be proven to be the process that started this run (a recycled pid is indistinguishable without it)'
        }
        else {
            $liveProcess = $null
            try { $liveProcess = Get-Process -Id $candidate -ErrorAction Stop } catch { $liveProcess = $null }
            if ($null -eq $liveProcess) {
                $detail = 'owner process ' + $candidate + ' is gone'
            }
            else {
                $liveStart = $null
                try { $liveStart = $liveProcess.StartTime.ToUniversalTime() } catch { $liveStart = $null }
                if ($null -eq $liveStart) {
                    $detail = 'process ' + $candidate + ' is alive but its start time cannot be read, so it cannot be confirmed to be the owner of this run'
                }
                elseif ([Math]::Abs(($liveStart - $markerStartUtc).TotalSeconds) -gt 2) {
                    $detail = 'process ' + $candidate + ' is alive but started at ' + $liveStart.ToString('o') +
                        ', not the recorded ' + $markerStartUtc.ToString('o') + ' - the pid was recycled by an unrelated process'
                }
                else {
                    $markerExe = [string](Get-Field $Doc 'ownerExecutablePath')
                    $liveExe = ''
                    try { $liveExe = [string]$liveProcess.Path } catch { $liveExe = '' }
                    if ($markerExe -ne '' -and $liveExe -ne '' -and -not [string]::Equals($liveExe, $markerExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $detail = 'process ' + $candidate + ' is alive but is running ' + $liveExe + ', not the recorded owner executable'
                    }
                    else { $isLive = $true }
                }
            }
        }
    }
    if ($isLive) { return [pscustomobject]@{ State = 'live'; OwnerPid = $candidate; RunId = $runId; Detail = '' } }

    # ---- the owner is not running. Did the run record how it ended? ----
    if ($runId -ne '') {
        # @() around an EMPTY array parameter still yields one $null element under
        # PowerShell's unrolling, and StrictMode then throws on $re.Doc - which is
        # exactly the no-results case this branch exists to answer. Skip nulls.
        foreach ($re in @($ResultEntries)) {
            if ($null -eq $re) { continue }
            if (([string](Get-Field $re.Doc 'runId')) -eq $runId) {
                return [pscustomobject]@{ State = 'finished'; OwnerPid = 0; RunId = $runId; Detail = $detail }
            }
        }
    }

    # ---- no result: killed. The bounded lifetime decides died vs expired ----
    # The runner writes a terminal result in `finally` on every path it can
    # intercept, so "no result" is not "not finished yet" - it is a process that
    # was terminated outright. That is a real finding while it can still belong
    # to the current work, and a previous session's leftover once it cannot.
    # An UNDATABLE record fails CLOSED (died): a record that cannot be placed in
    # time is genuine uncertainty, and its named recovery still resolves it.
    $created = ConvertTo-UtcTime (Get-Field $Doc 'markerCreatedUtc')
    if ($null -eq $created -and -not [string]::IsNullOrWhiteSpace($Path)) {
        try { $created = (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc } catch { $created = $null }
    }
    if ($null -ne $created -and $created -lt [DateTime]::UtcNow.AddHours(-[Math]::Abs($MaxAgeHours))) {
        $age = [int][Math]::Floor(([DateTime]::UtcNow - $created).TotalHours)
        return [pscustomobject]@{ State = 'expired'; OwnerPid = 0; RunId = $runId
            Detail = $detail + ', and the marker is ' + $age + 'h old (past the ' + [Math]::Abs($MaxAgeHours) + 'h abandoned-record horizon), so it belongs to an earlier session'
        }
    }
    return [pscustomobject]@{ State = 'died'; OwnerPid = $candidate; RunId = $runId; Detail = $detail }
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
