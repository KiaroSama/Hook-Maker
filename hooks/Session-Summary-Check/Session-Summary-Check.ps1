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
# Stop and SubagentStop are registered silent observers. They record only a
# genuine current summary, never infer publication from the event name. Nothing
# here keys on stop_hook_active: that flag belongs to the gates.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }

# THE STORE IS OPTIONAL, LIKE EVERY SIBLING LIBRARY. Without it every call
# below is absent and this hook behaves exactly as it did before - a runtime
# copied before the file existed degrades rather than failing to start.
$generationPath = Join-Path $PSScriptRoot '_generation.ps1'
if (Test-Path -LiteralPath $generationPath -PathType Leaf) { . $generationPath }

$isStopEvent = ($eventName -eq 'Stop' -or $eventName -eq 'SubagentStop')
if (-not $isStopEvent -and $eventName -ne 'SessionStart' -and $eventName -ne 'UserPromptSubmit') { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
# The LEGACY marker glob below must keep using this raw key: that is how
# Get-StopBlockMarkerPath spells the files it wrote, and changing it here would
# stop matching them.
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
# This hook's OWN state uses the canonical key (L04). A raw lowercased path gives
# a different key for "C:\p", "C:\p\" and "C:/p" - the same project arriving
# under a different spelling would keep its own separate cooldown and be
# reminded twice. Falls back to the raw key on a runtime with no ledger beside
# it, which is narrower than before, never wider.
$stateKey = $projectKey
if ($null -ne (Get-Command Get-StopProjectKey -ErrorAction SilentlyContinue)) {
    try { $stateKey = Get-StopProjectKey -ProjectRoot $cwd } catch { $stateKey = $projectKey }
}
$deliveryPath = Join-Path $stateDir ('SessionSummary-' + $stateKey + '.txt')

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

# RECORDING IS NOT SPEAKING. Stop stays SILENT - the header above explains at
# length why speaking there costs an extra assistant turn - but Stop is the only
# event where a completed response can be inspected. The response must actually
# contain a summary; the event name is not that proof. It is NAMED later,
# at the next delivery, which is the one place this hook already speaks without
# costing a turn. Nothing is emitted from this branch.
if ($isStopEvent) {
    if ($null -ne (Get-Command Observe-GenerationSummary -ErrorAction SilentlyContinue)) {
        try {
            Observe-GenerationSummary -HookInput $hookInput
        }
        catch { }
    }
    exit 0
}

# Client/session/actor reservations replace the old client-less text stamps.
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 15
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    $parsedCooldown = 0
    if ([int]::TryParse([string]$config['COOLDOWN_MINUTES'], [ref]$parsedCooldown) -and
        $parsedCooldown -ge 0 -and $parsedCooldown -le 1440) { $cooldownMinutes = $parsedCooldown }
}
$claim = Invoke-DeliveryClaim -Path ($deliveryPath + '.claims.json') -Identity (Get-DeliveryIdentity $hookInput) `
    -Fingerprint 'session-summary-policy-v2' -CooldownMinutes $cooldownMinutes -Force:($eventName -eq 'SessionStart')
if (-not $claim.Ok) {
    # No reservation means no claim that the policy was delivered. This display
    # warning is non-continuing; a later real event can retry the unchanged state.
    [Console]::Out.WriteLine((@{ systemMessage = ('SESSION SUMMARY: reminder reservation is unverified (' + $claim.Reason + '). No task completion was recorded.') } | ConvertTo-Json -Compress))
    exit 0
}
if (-not $claim.Admitted) { exit 0 }
$blocked = @(Get-BlockedGateNames -ProjectKey $projectKey -SessionId $sessionId)

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('SESSION SUMMARY - the message that HANDS THE WORK BACK ends with a short DONE / REMAINING wrap-up. It is the CLOSING section of that message, in the user''s language.')
[void]$lines.Add('')
[void]$lines.Add('WHEN: only in the message that actually finishes the task. While you are still working,')
[void]$lines.Add('waiting on a background run, or answering a gate that sent you back, do NOT write it -')
[void]$lines.Add('say what you are doing and carry on. A summary written mid-work is wrong twice over: it')
[void]$lines.Add('reports work that has not happened, and it trains the reader to skip the real one.')
[void]$lines.Add('')
[void]$lines.Add('ONCE, STRICTLY: exactly one wrap-up per task, and it is the LAST thing you write.')
[void]$lines.Add('Not once per message, not once per correction, not once per gate - once per TASK.')
[void]$lines.Add('If you have already written one, you do not write another for the rest of the task,')
[void]$lines.Add('however many times a gate sends you back. A gate that blocks after it is a CORRECTION')
[void]$lines.Add('turn: fix what it names, say in one line what changed, and stop. The blocking gate')
[void]$lines.Add('itself will remind you of this, and that reminder is not permission to restate it.')
[void]$lines.Add('')
[void]$lines.Add('BEFORE you write it, the message carrying it has to be one that nothing will interrupt.')
[void]$lines.Add('You cannot know that by guessing, so check it: memory updated if the task earned it,')
[void]$lines.Add('work committed and pushed with CI green on that exact SHA, docs acknowledged if the task')
[void]$lines.Add('made them stale, tests run and no process left alive, secrets and local-only files clean.')
[void]$lines.Add('Those are the gates that will otherwise send you back AFTER the wrap-up and make it')
[void]$lines.Add('a lie. Satisfy them first; then the wrap-up is both correct and last.')
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

# A summary that went out while a gate was still open. Stated ONCE, as a fact
# about what already happened, and never turned into a demand for a correction
# line: the client displays the summary before any hook runs, so such a demand
# necessarily arrives AFTER the summary and breaks the rule it enforces. That is
# precisely what the previous attempt at this got wrong.
if ($null -ne (Get-Command Read-GenerationFailureOnce -ErrorAction SilentlyContinue)) {
    $pastFailure = ''
    try { $pastFailure = Read-GenerationFailureOnce -HookInput $hookInput } catch { $pastFailure = '' }
    if (-not [string]::IsNullOrWhiteSpace($pastFailure)) {
        [void]$lines.Add('')
        [void]$lines.Add('NOTED ONCE, NO ACTION NEEDED: a wrap-up was observed, but its readiness was not verified (' + $pastFailure + ').')
        [void]$lines.Add('This is recorded, not a correction to make - the summary was already displayed by then.')
    }
}

if ($blocked.Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add('Gate(s) that already blocked earlier in this session: ' + ($blocked -join ', ') + '.')
    [void]$lines.Add('These markers are history only; they do not prove a gate is still open.')
    [void]$lines.Add('Account for each one after checking its current status: resolved in DONE, unresolved in REMAINING.')
}

$emit = Write-HookResult -EventName $eventName -Kind 'context' -Message ($lines -join "`n")
exit $emit.ExitCode
