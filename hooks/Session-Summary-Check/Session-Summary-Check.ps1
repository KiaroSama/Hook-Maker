# Session-Summary-Check - the closing "what shipped / what is left" report.
#
# ROLE: ADVISORY (global-hook-rules.md SS Hook Roles). It never blocks, never
# reads project content, and writes nothing outside its own state file.
#
# DELIVERED BEFORE THE TASK, NEVER AT STOP. What it asks for is that the
# agent's FINAL message ends with a DONE / REMAINING wrap-up. Two earlier
# revisions asked for that on Stop, and both looped in production, for a
# reason that decides the shape of every advisory in this set: on Claude Code
# a Stop hook's additionalContext is not a passive note - the client
# re-invokes the model with it. Asking at Stop therefore always costs one
# more assistant turn AFTER the turn that finished the work, and when nothing
# is left to say that turn is junk: the user watched "waiting." and "done.
# done." arrive one after another. A cooldown made it rarer; it could not
# make it right, because the timing was wrong, not the frequency.
#
# The sibling closing requirements ("MCP used:", "Skills used:") already do
# this the only way it works: they arrive at SessionStart and on the prompt,
# so the reply that ends the task carries them with no extra turn. This hook
# does the same. SessionStart always delivers (startup, resume, clear and
# compaction each rebuild the context); UserPromptSubmit re-delivers on a
# cooldown so a long session is reminded again before it ends.
#
# Stop and SubagentStop are silent. A registration that still names them (an
# installation predating this change) runs the hook and gets nothing, which
# is exactly right for a Stop advisory with nothing to act on. Nothing here
# keys on stop_hook_active: that flag belongs to the gates.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$deliveryPath = Join-Path $stateDir ('SessionSummary-' + $projectKey + '.txt')

# Which sibling GATES have blocked so far in this session. Every gate in this
# set records a marker immediately before it emits a block (Set-StopBlockMarker
# in _hooklib.ps1), so the markers are the only first-hand evidence available
# of what refused to let an earlier turn finish. Read them, never write them:
# this hook owns none of these files and clearing one would hide a real gate.
#
# The marker holds the session id, so a marker left by an EARLIER session in
# the same project is correctly ignored rather than reported as this session's
# blocker. A marker cannot say whether the condition is still unresolved -
# only that it was hit - which is why the wording below asks the agent to
# account for each one rather than asserting they are still open.
function Get-BlockedGateNames {
    param([AllowEmptyString()][string]$ProjectKey, [AllowEmptyString()][string]$SessionId)
    $names = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return @() }
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { return @() }
    try {
        $markers = @(Get-ChildItem -LiteralPath $stateDir -Filter ('StopBlock-*-' + $ProjectKey + '.txt') -File -ErrorAction SilentlyContinue)
    }
    catch { return @() }
    foreach ($marker in $markers) {
        $recorded = ''
        try { $recorded = ([System.IO.File]::ReadAllText($marker.FullName)).Trim() } catch { continue }
        if ($recorded -ne $SessionId) { continue }
        # StopBlock-<SafeHookName>-<projectKey>.txt -> <SafeHookName>
        $stem = $marker.BaseName
        if ($stem.Length -le ('StopBlock-'.Length + $ProjectKey.Length + 1)) { continue }
        $name = $stem.Substring('StopBlock-'.Length, $stem.Length - 'StopBlock-'.Length - $ProjectKey.Length - 1)
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$names.Add($name) }
    }
    return @($names | Sort-Object -Unique)
}

# The delivery stamp is "<sessionId>|<iso timestamp>". A DIFFERENT session is
# always told, however recently the last one was; the SAME session is told
# again on a prompt once COOLDOWN_MINUTES have passed. SessionStart never
# consults it - every SessionStart is a rebuilt context - but does stamp it,
# so the first prompt after a start does not repeat what was just delivered.
function Test-WithinCooldown {
    param([AllowEmptyString()][string]$SessionId, [int]$CooldownMinutes)
    $recorded = $null
    try { if (Test-Path -LiteralPath $deliveryPath -PathType Leaf) { $recorded = ([System.IO.File]::ReadAllText($deliveryPath)).Trim() } }
    catch { return $false }
    if ([string]::IsNullOrWhiteSpace($recorded)) { return $false }
    $parts = $recorded.Split('|')
    if ($parts.Count -lt 2 -or [string]$parts[0] -ne $SessionId) { return $false }
    $lastUtc = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$parts[1], [ref]$lastUtc)) { return $false }
    return (([DateTime]::UtcNow - $lastUtc.ToUniversalTime()).TotalMinutes -lt $CooldownMinutes)
}
function Write-DeliveryStamp {
    param([AllowEmptyString()][string]$SessionId)
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        [System.IO.File]::WriteAllText($deliveryPath, ($SessionId + '|' + [DateTime]::UtcNow.ToString('o')))
    }
    catch { }
}

$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 15
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    $parsedCooldown = 0
    if ([int]::TryParse([string]$config['COOLDOWN_MINUTES'], [ref]$parsedCooldown) -and
        $parsedCooldown -ge 0 -and $parsedCooldown -le 1440) { $cooldownMinutes = $parsedCooldown }
}
if ($eventName -eq 'UserPromptSubmit' -and (Test-WithinCooldown -SessionId $sessionId -CooldownMinutes $cooldownMinutes)) { exit 0 }
Write-DeliveryStamp -SessionId $sessionId
$blocked = @(Get-BlockedGateNames -ProjectKey $projectKey -SessionId $sessionId)

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('SESSION SUMMARY - the message that HANDS THE WORK BACK ends with a short DONE / REMAINING wrap-up. It is the CLOSING section of that message, in the user''s language.')
[void]$lines.Add('')
[void]$lines.Add('WHEN: only in the message that actually finishes the task. While you are still working,')
[void]$lines.Add('waiting on a background run, or answering a gate that sent you back, do NOT write it -')
[void]$lines.Add('say what you are doing and carry on. A summary written mid-work is wrong twice over: it')
[void]$lines.Add('reports work that has not happened, and it trains the reader to skip the real one.')
[void]$lines.Add('')
[void]$lines.Add('ONCE: one wrap-up per task, at its end. If you already gave it and nothing material')
[void]$lines.Add('changed since, do not restate it. Repeating it is not thoroughness, it is noise.')
[void]$lines.Add('')
[void]$lines.Add('It goes after every other closing requirement (the "MCP used:" line, the "Skills used:"')
[void]$lines.Add('line, the rules confirmation). Nothing of yours comes after it.')
[void]$lines.Add('')
[void]$lines.Add('  DONE      - what actually shipped AND was verified this session. One line each.')
[void]$lines.Add('  REMAINING - what is still open, blocked, or deliberately deferred, and why.')
[void]$lines.Add('')
[void]$lines.Add('Rules for it:')
[void]$lines.Add('- A handful of scannable lines. Not a narrative, not a re-explanation of the work.')
[void]$lines.Add('- Verified and unverified are different claims. Say which is which; "the tests pass"')
[void]$lines.Add('  requires a run you actually saw, and a skipped check belongs under REMAINING.')
[void]$lines.Add('- Failures, blocked steps and untested paths go IN, not out. An omission here is')
[void]$lines.Add('  what makes the next session redo the work or trust something that was never true.')
[void]$lines.Add('- Every gate that blocked you during the task is accounted for: resolved, or still')
[void]$lines.Add('  open with the reason. A gate worked around silently is a REMAINING item.')
[void]$lines.Add('- If nothing remains, say that in one line instead of padding the section.')

if ($blocked.Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add('Gate(s) that already blocked earlier in this session: ' + ($blocked -join ', ') + '.')
    [void]$lines.Add('Account for each one in the summary - resolved, or still open with the reason.')
}

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines -join "`n")
exit $emit.ExitCode
