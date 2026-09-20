# Test-TestRunGuard.ps1 scenario block: AN ASYNCHRONOUS RUN IS NOT A MISSING ONE
# (order 42, defects 2 and 3).
#
# THE DEFECT. PostToolUse treated the tool response as the end of the run. The
# installed Codex app's shell call is asynchronous - the initial `exec_command`
# response arrives while the child is still running - so the guarded result
# document does not exist yet, and the detector announced "a test command ran,
# but no guarded result document exists for it". A premature accusation about a
# run that is still going, and the fastest way to teach a reader to ignore the
# one message that means something.
#
# THE ENVELOPE, observed rather than assumed: that client normalizes shell
# events to `tool_name: Bash`, exposes only `tool_input.command`, and returns
# captured stdout as `tool_response`. No execution-session id, no exit metadata,
# and neither is recoverable from stdout. So the correlation runs on the
# RUNNER's own active marker, and deferral is granted only when that marker's
# recorded owner is provably the process running right now.
#
# Dot-sourced by Test-TestRunGuard.ps1 into its scope (uses its $Work, Check,
# New-IsolatedHookCopy, Fire, Get-Message, Write-Utf8 helpers) - not a
# standalone suite.

    # =====================================================================
    Write-Host '--- an asynchronous run that has not finished is DEFERRED, never accused (order 42) ---' -ForegroundColor Cyan

    # The observation is written by the hook itself at PreToolUse; the active
    # marker is written by the runner. Both are planted here so the case is the
    # exact state a live async run leaves behind: observed + active, no result.
    function New-ActiveMarker {
        param(
            [string]$LocalAppData, [string]$ProjectRoot, [int]$OwnerPid,
            [string]$StartUtc = '', [string]$ExePath = '', [string]$RunIdOverride = ''
        )
        $key = Get-ShortHash ($ProjectRoot.ToLowerInvariant())
        $dir = Join-Path $LocalAppData 'HookMaker\state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $runId = $RunIdOverride
        $projFp = ''
        $obsFiles = @(Get-ChildItem -LiteralPath $dir -Filter ('TestRunGuard-observed-' + $key + '-*.json') -File -ErrorAction SilentlyContinue)
        if ($obsFiles.Count -ge 1) {
            try {
                $obs = Get-Content -LiteralPath $obsFiles[0].FullName -Raw | ConvertFrom-Json
                if ($runId -eq '') { $runId = [string]$obs.runId }
                $projFp = if ($obs.PSObject.Properties['projectFingerprint']) { [string]$obs.projectFingerprint } else { [string]$obs.fingerprint }
            }
            catch { }
        }
        $marker = [ordered]@{
            schema = 2
            runId = $runId
            ownerPid = $OwnerPid
            ownerProcessStartUtc = $StartUtc
            ownerExecutablePath = $ExePath
            projectFingerprint = $projFp
            markerCreatedUtc = [DateTime]::UtcNow.ToString('o')
        }
        $path = Join-Path $dir ('TestRunGuard-active-' + $key + '-' + (Get-SafeRunId $runId) + '.json')
        Write-Utf8 $path (($marker | ConvertTo-Json -Depth 6))
        return $path
    }

    # THIS process is the live owner: its pid, its real start time, its real
    # executable. Nothing is faked, so what the hook proves is what it would
    # prove about a real runner.
    $self = Get-Process -Id $PID
    $selfStart = $self.StartTime.ToUniversalTime().ToString('o')
    $selfExe = [string]$self.Path

    # ---- a live owner defers ---------------------------------------------
    $hcAsync = New-IsolatedHookCopy
    $asyncProj = Join-Path $Work ('asyncproj-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $asyncProj -Force | Out-Null
    # PreToolUse writes the observation for this command.
    $null = Fire -HookPath $hcAsync.Script -Cwd $asyncProj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcAsync.LocalAppData
    $null = New-ActiveMarker -LocalAppData $hcAsync.LocalAppData -ProjectRoot $asyncProj -OwnerPid $PID -StartUtc $selfStart -ExePath $selfExe
    $r = Fire -HookPath $hcAsync.Script -Cwd $asyncProj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcAsync.LocalAppData
    $asyncMessage = Get-Message $r.Out
    Check 'a run whose owner is still alive is reported as STILL EXECUTING' (
        $asyncMessage -match 'STILL EXECUTING') $r.Out
    Check 'and it is NOT accused of leaving no result document' (
        $asyncMessage -notmatch 'no guarded result document exists') $r.Out
    Check 'deferral never claims the run passed' (
        $asyncMessage -notmatch 'passed' -and $asyncMessage -match 'not evidence of anything') $r.Out
    Check 'deferral is advisory: exit 0, no permission decision' (
        $r.Exit -eq 0 -and $r.Out -notmatch '"permissionDecision"') $r.Out

    # ---- an unpinnable marker is UNKNOWN, not live ------------------------
    # No start time: the recorded process cannot be told apart from whatever
    # inherited its pid, so this must fall through to the ordinary warning.
    $hcNoStart = New-IsolatedHookCopy
    $noStartProj = Join-Path $Work ('asyncnostart-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $noStartProj -Force | Out-Null
    $null = Fire -HookPath $hcNoStart.Script -Cwd $noStartProj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcNoStart.LocalAppData
    $null = New-ActiveMarker -LocalAppData $hcNoStart.LocalAppData -ProjectRoot $noStartProj -OwnerPid $PID -StartUtc '' -ExePath $selfExe
    $r = Fire -HookPath $hcNoStart.Script -Cwd $noStartProj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcNoStart.LocalAppData
    $noStartMessage = Get-Message $r.Out
    Check 'a marker with no owner start time does NOT defer (a recycled pid is indistinguishable)' (
        $noStartMessage -notmatch 'STILL EXECUTING') $r.Out
    Check 'and the honest missing-evidence warning is still given' (
        $noStartMessage -match 'no guarded result document exists') $r.Out

    # ---- a marker for a DIFFERENT run cannot answer for this one ----------
    $hcOther = New-IsolatedHookCopy
    $otherProj = Join-Path $Work ('asyncother-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $otherProj -Force | Out-Null
    $null = Fire -HookPath $hcOther.Script -Cwd $otherProj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcOther.LocalAppData
    $null = New-ActiveMarker -LocalAppData $hcOther.LocalAppData -ProjectRoot $otherProj -OwnerPid $PID -StartUtc $selfStart -ExePath $selfExe -RunIdOverride 'some-unrelated-run'
    $r = Fire -HookPath $hcOther.Script -Cwd $otherProj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcOther.LocalAppData
    Check 'a live marker belonging to a DIFFERENT run does not defer this one' (
        (Get-Message $r.Out) -notmatch 'STILL EXECUTING') $r.Out

    # ---- a dead owner is UNKNOWN -----------------------------------------
    # Pid 0 is never a real owner; an unusable owner id can never prove a run.
    $hcDead = New-IsolatedHookCopy
    $deadProj = Join-Path $Work ('asyncdead-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $deadProj -Force | Out-Null
    $null = Fire -HookPath $hcDead.Script -Cwd $deadProj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcDead.LocalAppData
    $null = New-ActiveMarker -LocalAppData $hcDead.LocalAppData -ProjectRoot $deadProj -OwnerPid 0 -StartUtc $selfStart -ExePath $selfExe
    $r = Fire -HookPath $hcDead.Script -Cwd $deadProj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcDead.LocalAppData
    Check 'a marker with no usable owner process does not defer' (
        (Get-Message $r.Out) -notmatch 'STILL EXECUTING') $r.Out

    # ---- the envelope: nothing is reconstructed from stdout ---------------
    . (Join-Path (Split-Path -Parent $Hook) '_activeowner.ps1')
    $codexEnvelope = [pscustomobject]@{
        session_id = 'sess-codex'
        hook_event_name = 'PostToolUse'
        tool_name = 'Bash'
        tool_input = [pscustomobject]@{ command = 'pytest -q' }
        tool_response = "session_id: 12345`nexec id: abcdef`n1 passed in 0.3s"
    }
    Check 'the observed Codex envelope yields NO execution session id (none exists in it)' (
        (Get-BoundExecutionSessionId -HookInput $codexEnvelope) -eq '') (Get-BoundExecutionSessionId -HookInput $codexEnvelope)
    $structured = [pscustomobject]@{
        session_id = 'sess-codex'
        tool_input = [pscustomobject]@{ command = 'pytest -q'; session_id = 'exec-99'; client_session_id = 'sess-codex' }
    }
    Check 'a structured envelope that agrees with its client session binds' (
        (Get-BoundExecutionSessionId -HookInput $structured) -eq 'exec-99') (Get-BoundExecutionSessionId -HookInput $structured)
    $foreign = [pscustomobject]@{
        session_id = 'sess-codex'
        tool_input = [pscustomobject]@{ command = 'pytest -q'; session_id = 'exec-99'; client_session_id = 'somebody-else' }
    }
    Check 'an execution session naming ANOTHER client session is refused, not followed' (
        (Get-BoundExecutionSessionId -HookInput $foreign) -eq '') (Get-BoundExecutionSessionId -HookInput $foreign)
    $sourceText = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $Hook) '_activeowner.ps1'))
    Check 'the correlation module never reads tool_response (stdout is output, not protocol)' (
        $sourceText -notmatch "Get-Field .*'tool_response'") 'tool_response is read somewhere in _activeowner.ps1'
    # The owner start time must not be stringified. ConvertFrom-Json on pwsh 7
    # returns a [DateTime] for the marker's 'o' stamp; [string] renders it in the
    # current culture WITHOUT a zone marker, TryParse then reads it as local, and
    # the pinning fails by the machine's UTC offset - so no asynchronous run is
    # ever deferred anywhere but UTC. The behaviour cannot be reproduced on a UTC
    # runner, which is why this is asserted against the source instead.
    $stringifiedStart = '[string](Get-Field $Doc ' + [char]39 + 'ownerProcessStartUtc' + [char]39 + ')'
    Check 'the owner start time is not read through [string] (it would be parsed as LOCAL time)' (
        $sourceText.IndexOf($stringifiedStart, [System.StringComparison]::Ordinal) -lt 0) $stringifiedStart
