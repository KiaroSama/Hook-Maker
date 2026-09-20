# Run-Tests-Guarded section: this run's identity, its result document and its
# live-run marker.
#
# Dot-sourced by Run-Tests-Guarded.ps1, so it runs in that script's scope:
# $script:Result is created here and the run section in the entry file keeps
# writing to the same object, and Write-GuardedResult still resolves the
# entry script's $ResultPath parameter from the caller's scope at call time.
#
# Standalone like its parent: the SHA helpers here are deliberately local so
# the runner never has to dot-source _hooklib.ps1 to know what ran.

# ---- run identity ----------------------------------------------------------

# SHA-256 prefix over the structured executable + argument ARRAY, joined by a NUL
# that cannot appear in a Windows argument, then lowercased. Computed from the
# real (FileName, ArgumentList), never from a re-joined shell string, so "what
# ran" has ONE canonical identity that the observing hook and this runner both
# derive the same way. Standalone SHA (this script does not dot-source _hooklib).
function Get-CommandFingerprint {
    param([string]$ExecutablePath, [string[]]$ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add(([string]$ExecutablePath).ToLowerInvariant())
    foreach ($a in @($ArgumentList)) { [void]$parts.Add([string]$a) }
    $joined = ($parts.ToArray() -join "`0")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 32)
    }
    finally { $sha.Dispose() }
}

# The canonical project key the hooks use: SHA-256 prefix of the lowercased cwd.
function Get-ProjectKey {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(([string]$Path).ToLowerInvariant()))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)
    }
    finally { $sha.Dispose() }
}

# The 10-char state-file key, byte-identical to hooks\_hooklib.ps1's Get-ShortHash
# (SHA-256 prefix of the lowercased cwd, 10 hex). The active-marker filename MUST
# use this length: the consumer (Test-Completion-Check) derives the key with
# Get-ShortHash and would never find a marker written under a different-length key.
function Get-StateKey {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(([string]$Path).ToLowerInvariant()))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally { $sha.Dispose() }
}

# Filename-safe form of a runId: lowercased, non [a-z0-9] stripped. runIds are
# 32-hex GUIDs (minted) or short injected tokens; this keeps the per-run state
# filename unambiguous. Never empty here - the caller resolves a runId first.
function Get-SafeRunId {
    param([string]$RunId)
    $safe = ([string]$RunId).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($safe -eq '') { $safe = (Get-StateKey ([string]$RunId)) }
    return $safe
}

# ---- result document -------------------------------------------------------

$script:Result = [pscustomobject][ordered]@{
    schema             = 2
    overall            = 'unknown'
    fileName           = $FilePath
    argumentCount      = @($Arguments).Count
    workingDirectory   = ''
    runId              = ''
    projectKey         = ''
    projectFingerprint = ''
    commandFingerprint = ''
    processOwnership   = 'unknown'
    exitCode           = $null
    terminated         = $false
    terminateReason    = ''
    terminateDetail    = ''
    elapsedSeconds     = 0
    noProgressSeconds  = 0
    heartbeats         = 0
    peakMemoryMB       = 0
    cpuSeconds         = 0
    peakTreeSize       = 0
    leakedProcessIds   = @()
    lastProgress       = ''
    stdoutBytes        = 0
    stderrBytes        = 0
    workerBudget       = (Get-GuardedWorkerBudget -Requested $MaxWorkers)
    startedUtc         = ''
    endedUtc           = ''
}

# The ARGUMENTS ARE NOT RECORDED. A test invocation can legitimately carry a
# token, a connection string, or a path holding a user name; the result document
# is written to disk and read by a hook, so it stays free of anything that could
# be a secret. The count is kept because "did it get the arguments I expected"
# is answerable without the values.
function Write-GuardedResultFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Json)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Same bytes, published atomically: a consumer must never read a half-written
    # result and conclude the run produced nothing.
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($tmp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# The result is published to the CALLER'S path and, always, to the canonical
# per-run evidence path.
#
# THE DEFECT THIS FIXES: a caller may choose its own -ResultPath (a suite's own
# r.json, a project's logs\a01-acceptance.json). The observing hook enumerates
# only %LOCALAPPDATA%\HookMaker\state\TestRunGuard-result-<key>-*.json, so a real
# completed run wrote its evidence somewhere the consumer never looks and the
# gate reported "no guarded result document exists" for a run that had finished
# cleanly. Producer and consumer disagreed about WHERE, not about what.
#
# Writing both keeps the caller's file exactly where it asked for it - nothing
# that reads it today breaks - while making every terminal result discoverable
# through the one path the hook knows. Same document, same schema, same run id.
function Write-GuardedResult {
    $json = $script:Result | ConvertTo-Json -Depth 6
    $written = @{}
    foreach ($target in @($ResultPath, $script:CanonicalResultPath)) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $key = $target.ToLowerInvariant()
        if ($written.ContainsKey($key)) { continue }
        $written[$key] = $true
        try { Write-GuardedResultFile -Path $target -Json $json }
        catch {
            Write-Warning ('the guarded result document could not be written to ' + $target + ': ' + $_.Exception.Message)
        }
    }
}

# ---- "a guarded run is live" marker ----------------------------------------
#
# Test-Completion-Check blocks completion while a guarded run is still active,
# and it proves that by checking the recorded pid is genuinely alive.
#
# ONLY THIS FILE CAN WRITE IT. Test-Run-Guard is a hook: at PreToolUse the child
# has not started, at PostToolUse it has already exited, and the run is a child
# of the CLIENT, never of the hook - so a hook could only ever guess. A guessed
# pid is worse than none, because pids are recycled and an unrelated live
# process would block completion forever. Here the pid is simply $PID.
#
# Written best-effort and removed in finally: if this file cannot be written the
# run still proceeds, and the consumer treats an absent marker as "not
# evaluated" (silence) rather than as proof that nothing is running.
# PER-RUN filename: TestRunGuard-active-<key>-<runId>.json. Keying it by runId
# (not just the project key) is what lets two guarded runs in ONE project each
# own their own marker - so run A's finally removes only run A's marker and never
# tears down a live run B. The key is the 10-char Get-StateKey the consumer uses.
$script:ActiveMarkerPath = ''
function Get-ActiveMarkerPath {
    # $ProjectPath is the EFFECTIVE working directory of the run (the canonical
    # -WorkingDirectory), NOT this process's Get-Location. The two differ when the
    # runner is launched from dir A with -WorkingDirectory B: the result belongs to
    # B, so the marker Test-Completion-Check looks for MUST be keyed to B as well.
    # Keying off Get-Location wrote it under A, where the check in B never saw it.
    param([string]$RunId, [string]$ProjectPath)
    try {
        $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
        $key = Get-StateKey $ProjectPath
        return (Join-Path $stateDir ('TestRunGuard-active-' + $key + '-' + (Get-SafeRunId $RunId) + '.json'))
    }
    catch { return '' }
}

function Write-ActiveMarker {
    param([int]$OwnerPid, [string]$RunId, [string]$ProjectFingerprint, [string]$ProjectPath)
    try {
        $path = Get-ActiveMarkerPath -RunId $RunId -ProjectPath $ProjectPath
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # PID reuse is the trap: a plain {pid} marker blocks completion on ANY
        # live process that later inherits that pid. So the marker also records
        # the OWNER PROCESS's own start time and executable path (read from the
        # live process now), plus the runId and project fingerprint. The consumer
        # accepts the marker as "active" only when the live process at ownerPid
        # STILL has this exact start time and executable - a recycled pid, a
        # different program, or a different project makes it stale, never active.
        # ISO-8601 'o', NOT ticks: the consumer parses with TryParse(RoundtripKind).
        $startUtc = ''
        $exePath = ''
        try {
            $me = Get-Process -Id $OwnerPid -ErrorAction Stop
            try { $startUtc = $me.StartTime.ToUniversalTime().ToString('o') } catch { $startUtc = '' }
            try { $exePath = [string]$me.Path } catch { $exePath = '' }
        }
        catch { }
        $marker = [pscustomobject][ordered]@{
            schema               = 2
            runId                = $RunId
            ownerPid             = $OwnerPid
            ownerProcessStartUtc = $startUtc
            ownerExecutablePath  = $exePath
            projectFingerprint   = $ProjectFingerprint
            markerCreatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        }
        # Atomic-ish write: temp + force-move, so a consumer never reads a
        # half-written marker. Single-writer per RUN (the filename carries this
        # run's id), so the force-replace cannot race another writer.
        $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
        [System.IO.File]::WriteAllText($tmp, ($marker | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
        $script:ActiveMarkerPath = $path
    }
    catch { }
}

function Remove-ActiveMarker {
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:ActiveMarkerPath)) {
            Remove-Item -LiteralPath $script:ActiveMarkerPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}
