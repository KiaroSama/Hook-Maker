# Test-Run-Guard\_activeowner.ps1 - IS THE RUN STILL EXECUTING? (order 42, 2-3)
#
# THE DEFECT. PostToolUse treated the tool response as the end of the run. On a
# client whose shell call is ASYNCHRONOUS - the installed Codex app returns an
# initial `exec_command` response while the child keeps running - the guarded
# result document does not exist yet, and the detector reported "a test command
# ran, but no guarded result document exists for it". That is a premature
# accusation about a run that is still going, and it trains the reader to
# distrust the one message that means something.
#
# THE ENVELOPE, as actually observed rather than assumed. That client normalizes
# shell events to `tool_name: Bash`, exposes only `tool_input.command`, and
# hands back captured stdout as `tool_response` text. There is NO execution
# session id and NO exit metadata in it, and neither can be reconstructed from
# arbitrary stdout - stdout is the program's output, not the client's protocol.
# So nothing here parses stdout for identity, and the correlation runs on what
# the RUNNER owns: its own per-run active marker.
#
# DEFER IS NOT PASS. A deferral says "still executing, no verdict yet". It is
# only ever reached when an owned active marker matches this run/command/
# repository AND its recorded owner is provably the process running right now. A
# missing field, a missing owner, a recycled pid or an unrelated process is
# UNKNOWN, and unknown keeps the existing warning.
#
# PID REUSE IS THE TRAP, so identity is pinned or the marker is not live: the
# pid must still carry the start time the marker recorded, and the executable
# when both sides know it. There is deliberately no pid-only path - whatever
# recycles a pwsh pid is almost always another pwsh.

# The marker's owner, or $null when it cannot be proven to be the process the
# marker was written for.
function Test-ActiveMarkerOwnerLive {
    param($Doc)
    if ($null -eq $Doc) { return $false }
    $ownerPidRaw = Get-Field $Doc 'ownerPid'
    if ($null -eq $ownerPidRaw) { $ownerPidRaw = Get-Field $Doc 'pid' }   # schema-1 field name
    $ownerPid = 0
    if (-not [int]::TryParse([string]$ownerPidRaw, [ref]$ownerPid)) { return $false }
    if ($ownerPid -le 0) { return $false }

    # A start time is the MINIMUM discriminator. Without one the recorded
    # process cannot be told apart from whatever inherited its pid.
    $recordedStart = $null
    $rawStart = [string](Get-Field $Doc 'ownerProcessStartUtc')
    if ([string]::IsNullOrWhiteSpace($rawStart)) { return $false }
    $parsedStart = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($rawStart, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedStart)) { return $false }
    $recordedStart = $parsedStart.ToUniversalTime()

    $process = $null
    try { $process = Get-Process -Id $ownerPid -ErrorAction Stop }
    catch { return $false }
    if ($null -eq $process) { return $false }

    $liveStart = $null
    try { $liveStart = $process.StartTime.ToUniversalTime() } catch { $liveStart = $null }
    if ($null -eq $liveStart) { return $false }
    # One second of tolerance: the two sides format through different clocks and
    # a sub-second difference is the same process, not a recycled pid.
    if ([Math]::Abs(($liveStart - $recordedStart).TotalSeconds) -gt 1.0) { return $false }

    # The executable is a confirmation, never the discriminator: it is compared
    # only when BOTH sides know it, so a marker written where the path could not
    # be read is not rejected for that alone.
    $recordedExe = [string](Get-Field $Doc 'ownerExecutablePath')
    $liveExe = ''
    try { $liveExe = [string]$process.Path } catch { $liveExe = '' }
    if (-not [string]::IsNullOrWhiteSpace($recordedExe) -and -not [string]::IsNullOrWhiteSpace($liveExe)) {
        if (-not [string]::Equals($recordedExe, $liveExe, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

# The live marker that belongs to THIS observation, or $null.
#
# Identity first, exactly as the result pairing does: a marker for another run,
# another command or another repository state says nothing about this one, and
# an arbitrary recent marker is never accepted.
function Get-DeferringActiveRun {
    param(
        $ActiveEntries,
        [AllowEmptyString()][string]$RunId = '',
        [AllowEmptyString()][string]$CommandFingerprint = '',
        [AllowEmptyString()][string]$StateFingerprint = '',
        $Observed = $null
    )
    $observedRunId = ''
    if ($null -ne $Observed) { $observedRunId = [string](Get-Field $Observed 'runId') }

    foreach ($entry in @($ActiveEntries)) {
        $doc = $entry.Doc
        if ($null -eq $doc) { continue }
        $markerRunId = [string](Get-Field $doc 'runId')

        # A runId known on either side must MATCH. Only when neither side knows
        # one may the command+repository pair stand in for it.
        $wanted = $RunId
        if ([string]::IsNullOrWhiteSpace($wanted)) { $wanted = $observedRunId }
        if (-not [string]::IsNullOrWhiteSpace($wanted)) {
            if (-not [string]::Equals($markerRunId, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        else {
            # No run identity anywhere: the repository state is then the only
            # binding left, and without it nothing may be claimed.
            if ([string]::IsNullOrWhiteSpace($StateFingerprint)) { continue }
            $markerFingerprint = [string](Get-Field $doc 'projectFingerprint')
            if (-not [string]::Equals($markerFingerprint, $StateFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        if (-not (Test-ActiveMarkerOwnerLive -Doc $doc)) { continue }
        return $doc
    }
    return $null
}

# A structured execution-session id, ONLY when the envelope binds it to this
# client session. The observed envelope carries none at all, so this normally
# returns '' - but a client that does supply one must not be able to redirect
# the correlation with a foreign or ambiguous value, and the value is never
# recovered from stdout.
function Get-BoundExecutionSessionId {
    param([Parameter(Mandatory = $true)]$HookInput)
    $clientSession = [string](Get-Field $HookInput 'session_id')
    if ([string]::IsNullOrWhiteSpace($clientSession)) { return '' }
    $toolInput = Get-Field $HookInput 'tool_input'
    if ($null -eq $toolInput) { return '' }
    foreach ($field in @('session_id', 'sessionId')) {
        $value = [string](Get-Field $toolInput $field)
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        # The envelope must agree with itself: an execution session that names a
        # DIFFERENT client session is another client's, and binding to it would
        # let a foreign run answer for this one.
        $envelopeClient = [string](Get-Field $toolInput 'client_session_id')
        if (-not [string]::IsNullOrWhiteSpace($envelopeClient) -and
            -not [string]::Equals($envelopeClient, $clientSession, [System.StringComparison]::Ordinal)) {
            return ''
        }
        return $value
    }
    return ''
}
