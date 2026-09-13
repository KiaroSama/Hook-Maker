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
    # THE LEDGER IS THE PRODUCER NOW. A successful block registration writes the
    # shared stop ledger, not a StopBlock-*.txt marker, so reading markers alone
    # reported no gate history at all on any current runtime. The marker sweep
    # below is kept for a runtime installed before the ledger existed, and for
    # entries a legacy hook still leaves; the two sets are merged and deduped.
    if ($null -ne (Get-Command Get-StopSessionGateHistory -ErrorAction SilentlyContinue)) {
        try {
            foreach ($hook in @(Get-StopSessionGateHistory -ProjectRoot $cwd -SessionId $SessionId)) {
                $safe = [System.Text.RegularExpressions.Regex]::Replace([string]$hook, '[^A-Za-z0-9]+', '')
                if (-not [string]::IsNullOrWhiteSpace($safe)) { [void]$names.Add($safe) }
            }
        }
        catch { }
    }
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { return @($names | Sort-Object -Unique) }
    try {
        $markers = @(Get-ChildItem -LiteralPath $stateDir -Filter ('StopBlock-*-' + $ProjectKey + '.txt') -File -ErrorAction SilentlyContinue)
    }
    catch { return @($names | Sort-Object -Unique) }
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

# ONE STAMP PER SESSION, not one per project.
#
# The file used to hold a single "<sessionId>|<timestamp>", so two sessions
# working in the same project took turns overwriting it and each one read the
# OTHER's id, concluded "not mine" and delivered again: A/B/A was reminded three
# times inside a single cooldown. It is a small bounded map now - one line per
# session, newest kept - so a session's own cooldown survives another session
# speaking in between.
#
# SessionStart never consults it (every SessionStart is a rebuilt context) but
# does stamp it, so the first prompt after a start does not repeat what was just
# delivered.
$script:DeliveryMaxSessions = 12

function Get-DeliveryStamps {
    $map = @{}
    try {
        if (-not (Test-Path -LiteralPath $deliveryPath -PathType Leaf)) { return $map }
        foreach ($line in @([System.IO.File]::ReadAllLines($deliveryPath))) {
            $text = ([string]$line).Trim()
            if ($text -eq '') { continue }
            $parts = $text.Split('|')
            if ($parts.Count -lt 2) { continue }
            $map[[string]$parts[0]] = [string]$parts[1]
        }
    }
    catch { return @{} }
    return $map
}

function Test-WithinCooldown {
    param([AllowEmptyString()][string]$SessionId, [int]$CooldownMinutes)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
    $map = Get-DeliveryStamps
    if (-not $map.ContainsKey($SessionId)) { return $false }
    $lastUtc = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$map[$SessionId], [ref]$lastUtc)) { return $false }
    return (([DateTime]::UtcNow - $lastUtc.ToUniversalTime()).TotalMinutes -lt $CooldownMinutes)
}

function Write-DeliveryStamp {
    param([AllowEmptyString()][string]$SessionId)
    try {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $map = Get-DeliveryStamps
        $map[$SessionId] = [DateTime]::UtcNow.ToString('o')
        # Bounded: keep the most recent sessions and drop the rest, so a
        # long-lived project cannot grow this file without limit.
        $lines = @()
        foreach ($key in @($map.Keys | Sort-Object -Property @{ Expression = { $map[$_] }; Descending = $true } | Select-Object -First $script:DeliveryMaxSessions)) {
            $lines += ([string]$key + '|' + [string]$map[$key])
        }
        [System.IO.File]::WriteAllLines($deliveryPath, [string[]]$lines)
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
[void]$lines.Add('  DONE      - completed work, successful checks, and resolved blockers verified this session.')
[void]$lines.Add('  REMAINING - ONLY unresolved required work: unfinished items, current blockers, or deferred in-scope requirements.')
[void]$lines.Add('')
[void]$lines.Add('Rules for it:')
[void]$lines.Add('- A handful of scannable lines. Not a narrative, not a re-explanation of the work.')
[void]$lines.Add('- Verified and unverified are different claims. Say which is which; "the tests pass"')
[void]$lines.Add('  requires a run you actually saw, and a skipped required check belongs under REMAINING.')
[void]$lines.Add('- Never put completed work, successful checks, or resolved gates under REMAINING.')
[void]$lines.Add('- A past failure followed by verified success belongs in DONE. Only a failure that')
[void]$lines.Add('  still needs action, an unresolved blocker, or an untested required path belongs in REMAINING.')
[void]$lines.Add('- Every gate that blocked you during the task is accounted for in the correct section:')
[void]$lines.Add('  verified resolved gates go in DONE; still-open gates go in REMAINING with the reason.')
[void]$lines.Add('- Do not invent remaining work from unrequested actions or non-blocking informational limits.')
[void]$lines.Add('- If nothing remains, say that in one line instead of padding the section.')

if ($blocked.Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add('Gate(s) that already blocked earlier in this session: ' + ($blocked -join ', ') + '.')
    [void]$lines.Add('These markers are history only; they do not prove a gate is still open.')
    [void]$lines.Add('Account for each one after checking its current status: resolved in DONE, unresolved in REMAINING.')
}

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines -join "`n")
exit $emit.ExitCode
