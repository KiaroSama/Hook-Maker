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

# REPLY LANGUAGE (steering V45). Recorded from the prompt the user TYPED and
# repeated at the moments a reply tends to flip to English: every typed prompt,
# and SessionStart after a compaction or a resume. A skill expansion or other
# injected text is never detected from and gets no line. Outside the cooldown
# below on purpose: it is one line, and the flip it prevents happens mid-session.
$languageLine = ''
if ($null -ne (Get-Command Update-ReplyLanguage -ErrorAction SilentlyContinue)) {
    try {
        if ($eventName -eq 'UserPromptSubmit') {
            [void](Update-ReplyLanguage -HookInput $hookInput)
            if (-not (Test-InjectedPromptText ([string](Get-Field $hookInput 'prompt')))) { $languageLine = Get-ReplyLanguageLine -HookInput $hookInput }
        }
        elseif (@('compact', 'resume') -contains [string](Get-Field $hookInput 'source')) {
            $languageLine = Get-ReplyLanguageLine -HookInput $hookInput
        }
    }
    catch { $languageLine = '' }
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
if (-not $claim.Admitted) {
    if (-not [string]::IsNullOrEmpty($languageLine)) { exit (Write-HookResult -EventName $eventName -Kind 'context' -Message $languageLine).ExitCode }
    exit 0
}
$blocked = @(Get-BlockedGateNames -ProjectKey $projectKey -SessionId $sessionId)

$lines = New-Object System.Collections.ArrayList
if (-not [string]::IsNullOrEmpty($languageLine)) { [void]$lines.Add($languageLine); [void]$lines.Add('') }
[void]$lines.Add('SESSION SUMMARY: exactly one short DONE / REMAINING CLOSING section per task, LAST after MCP used:/Skills used:/Rules applied:, in the user''s language.')
[void]$lines.Add('- Only when handing back finished work; not during work, background waits or gate corrections. After publication, correct the named issue in one line; never repeat the wrap-up.')
[void]$lines.Add('- Before closing: meaningful memory updates, authorized Git sync + exact-SHA green CI, stale-doc acknowledgement, real tests, no owned process survivors, secrets/local-only hygiene. Verify, never guess.')
[void]$lines.Add('- DONE: verified completed work, successful checks and resolved gates (including repaired past failures). REMAINING: ONLY unresolved required work, unfinished/deferred items, blockers and untested paths, each with its reason.')
[void]$lines.Add('- Check every gate''s current state; distinguish verified/unverified. No invented work or informational nonblockers. Nothing left -> one line. Keep it scannable.')

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
