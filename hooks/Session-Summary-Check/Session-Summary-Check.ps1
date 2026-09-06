# Session-Summary-Check - the closing "what shipped / what is left" report.
#
# ROLE: ADVISORY (global-hook-rules.md SS Hook Roles). It never blocks, never
# reads project content, and writes nothing outside its own state file.
#
# WHY ADVISORY, given it is meant to be the LAST thing that happens: a gate
# that blocks sends the agent back to work, and whatever it does next produces
# more output. A blocking summary hook is therefore self-defeating - it can
# never be the final word, because blocking guarantees something comes after
# it. Advisory is not a weaker version of this hook, it is the only shape that
# can do the job.
#
# WHAT "LAST" CAN AND CANNOT MEAN HERE. Hooks matching one event run
# CONCURRENTLY and their outputs are concatenated in an order this hook does
# not choose (global-hook-rules.md SS Lifecycle Events and Concurrency:
# "Registration/menu order is display-only"). So the position of this hook's
# own text among the other hooks' text is not controllable, by this hook or by
# any other. What IS controllable is the order of the AGENT'S reply, and that
# is the thing the reader actually sees last. This hook therefore asks for the
# summary as the CLOSING SECTION of the reply - after the "MCP used:",
# "Skills used:" and rules-confirmation lines the sibling hooks ask for.
#
# ONCE PER SESSION. An earlier revision emitted on every Stop, reasoning that
# the "unchanged" case is the one that must still be reported. That was wrong,
# and it produced a loop in practice: other gates block, the agent works and
# stops again, this hook re-asks for the summary, and the agent writes it
# again - the same DONE/REMAINING block appeared four times in one turn.
#
# The requirement only has to ARRIVE once. Repeating it does not improve
# compliance; it manufactures the repetition it exists to produce cleanly. So
# the first Stop of a session delivers it and every later Stop of that same
# session stays silent.
#
# It still does NOT exit on stop_hook_active: that flag is set for ANY gate's
# block, so honouring it would skip the very first Stop whenever some other
# gate happened to fire first. Session identity is the correct key, not the
# shared flag.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
if ($eventName -ne 'Stop' -and $eventName -ne 'SubagentStop') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')

# Which sibling GATES blocked during this session. Every gate in this set
# records a marker immediately before it emits a block (Set-StopBlockMarker in
# _hooklib.ps1), so the markers are the only first-hand evidence available of
# what refused to let the session finish. Read them, never write them: this
# hook owns none of these files and clearing one would hide a real gate.
#
# The marker holds the session id, so a marker left by an EARLIER session in
# the same project is correctly ignored rather than reported as this session's
# blocker. A marker cannot say whether the condition is still unresolved -
# only that it was hit - which is why the wording below asks the agent to
# account for each one rather than asserting they are still open.
function Get-BlockedGateNames {
    param([AllowEmptyString()][string]$ProjectRoot, [AllowEmptyString()][string]$SessionId)
    $names = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return @() }
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { return @() }
    $projectKey = Get-ShortHash ([string]$ProjectRoot).ToLowerInvariant()
    try {
        $markers = @(Get-ChildItem -LiteralPath $stateDir -Filter ('StopBlock-*-' + $projectKey + '.txt') -File -ErrorAction SilentlyContinue)
    }
    catch { return @() }
    foreach ($marker in $markers) {
        $recorded = ''
        try { $recorded = ([System.IO.File]::ReadAllText($marker.FullName)).Trim() } catch { continue }
        if ($recorded -ne $SessionId) { continue }
        # StopBlock-<SafeHookName>-<projectKey>.txt -> <SafeHookName>
        $stem = $marker.BaseName
        if ($stem.Length -le ('StopBlock-'.Length + $projectKey.Length + 1)) { continue }
        $name = $stem.Substring('StopBlock-'.Length, $stem.Length - 'StopBlock-'.Length - $projectKey.Length - 1)
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$names.Add($name) }
    }
    return @($names | Sort-Object -Unique)
}

# Speak once per session. Without this the hook re-asks on every Stop, and
# because other gates keep blocking, the agent restates the whole summary
# each time.
function Test-AlreadyDelivered {
    param([AllowEmptyString()][string]$ProjectRoot, [AllowEmptyString()][string]$SessionId)
    $stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
    $key = Get-ShortHash ([string]$ProjectRoot).ToLowerInvariant()
    $path = Join-Path $stateDir ('SessionSummary-' + $key + '.txt')
    $recorded = $null
    try { if (Test-Path -LiteralPath $path -PathType Leaf) { $recorded = ([System.IO.File]::ReadAllText($path)).Trim() } }
    catch { $recorded = $null }

    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        # Session identity is the reliable key: a new session must be told
        # again, the same session must not be.
        if ($null -ne $recorded -and $recorded -eq $SessionId) { return $true }
        try {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            [System.IO.File]::WriteAllText($path, $SessionId)
        }
        catch { }
        return $false
    }

    # No session id: dedup by identity is impossible, so fall back to a short
    # time window. An unbounded repeat is the worse failure of the two.
    $nowUtc = [DateTime]::UtcNow
    if ($null -ne $recorded) {
        $lastUtc = [DateTime]::MinValue
        if ([DateTime]::TryParse($recorded, [ref]$lastUtc)) {
            if (($nowUtc - $lastUtc.ToUniversalTime()).TotalMinutes -lt 60) { return $true }
        }
    }
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $nowUtc.ToString('o'))
    }
    catch { }
    return $false
}

if (Test-AlreadyDelivered -ProjectRoot $cwd -SessionId $sessionId) { exit 0 }
$blocked = @(Get-BlockedGateNames -ProjectRoot $cwd -SessionId $sessionId)

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('SESSION SUMMARY - the CLOSING section of your reply. It goes after every other')
[void]$lines.Add('hook requirement (the "MCP used:" line, the "Skills used:" line, the rules')
[void]$lines.Add('confirmation). Nothing of yours comes after it.')
[void]$lines.Add('')
[void]$lines.Add('End with a short, honest wrap-up in the user''s language, in two parts:')
[void]$lines.Add('  DONE      - what actually shipped AND was verified this session. One line each.')
[void]$lines.Add('  REMAINING - what is still open, blocked, or deliberately deferred, and why.')
[void]$lines.Add('')
[void]$lines.Add('Rules for it:')
[void]$lines.Add('- A handful of scannable lines. Not a narrative, not a re-explanation of the work.')
[void]$lines.Add('- Verified and unverified are different claims. Say which is which; "the tests pass"')
[void]$lines.Add('  requires a run you actually saw, and a skipped check belongs under REMAINING.')
[void]$lines.Add('- Failures, blocked steps and untested paths go IN, not out. An omission here is')
[void]$lines.Add('  what makes the next session redo the work or trust something that was never true.')
[void]$lines.Add('- If nothing remains, say that in one line instead of padding the section.')

if ($blocked.Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add('Gate(s) that blocked this session: ' + ($blocked -join ', ') + '.')
    [void]$lines.Add('Account for each one in the summary - resolved, or still open with the reason.')
    [void]$lines.Add('A gate that blocked and was then worked around silently is a REMAINING item.')
}

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines -join "`n")
exit $emit.ExitCode
