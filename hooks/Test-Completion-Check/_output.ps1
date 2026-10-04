# Test-Completion-Check: output responsibility, extracted from the oversized entry.
# Once-per-session-per-state gate for the dd-specific outputs (anti-loop): an
# unchanged state token reports once; a changed token or a new session reports
# again immediately. Never consulted for the pre-existing condition-1..6 blocks.
function Test-DdGateShouldReport {
    param([string]$StateToken)
    $ddFp = Get-ShortHash ($StateToken + '|' + $script:sessionId)
    try {
        if (Test-Path -LiteralPath $script:ddGatePath -PathType Leaf) {
            if (([System.IO.File]::ReadAllText($script:ddGatePath)).Trim() -eq $ddFp) { return $false }
        }
    }
    catch { }
    try {
        if (-not (Test-Path -LiteralPath $script:stateDir -PathType Container)) { New-Item -ItemType Directory -Path $script:stateDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($script:ddGatePath, $ddFp, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
    return $true
}

# ---- output ---------------------------------------------------------------
# A real block uses `decision:block` for both clients (Ci-Status-Check's
# blocking paths do the same). An advisory is CLIENT-AWARE and never a block:
# on Codex `decision:block` at Stop forces a new prompt, which for an advisory
# would be an infinite loop.
# Abandoned active markers reconciled during THIS invocation. The durable trace
# lives in the ledger; this is the human-visible half, and it rides an output the
# hook is already emitting rather than breaking silence on its own - an earlier
# session's leftover is not an actionable signal for the current task.
$script:expiredNow = New-Object System.Collections.Generic.List[string]

function Write-Finding {
    param([string[]]$Lines, [bool]$Blocking)
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { [void]$all.Add($line) }
    # E-05: while ::deep-debug is active, every blocking finding also carries the
    # exact workflow verdict line with a concise reason derived from the first
    # finding line. Constant text riding an EXISTING block - it adds no new loop
    # path; the dd-specific outputs have their own once-per-session gate.
    if ($Blocking -and $script:DeepDebugActive) {
        $ddReason = ''
        if (@($Lines).Count -gt 0) {
            $ddReason = ([string]$Lines[0]) -replace '^TEST COMPLETION CHECK:\s*', ''
            $ddDot = $ddReason.IndexOf('. ')
            if ($ddDot -gt 0) { $ddReason = $ddReason.Substring(0, $ddDot) }
            if ($ddReason.Length -gt 160) { $ddReason = $ddReason.Substring(0, 160) }
        }
        if ($ddReason -eq '') { $ddReason = 'unresolved test-completion evidence' }
        [void]$all.Add('')
        [void]$all.Add('DEEP DEBUG: BLOCKED (' + $ddReason + ')')
    }
    if ($script:expiredNow.Count -gt 0) {
        [void]$all.Add('')
        [void]$all.Add('Also reconciled (not a block, and not part of this task): ' + $script:expiredNow.Count +
            ' abandoned guarded-run record(s) from an earlier session were expired and dropped - ' + (@($script:expiredNow) -join '; ') + '.')
    }
    if ($script:configWarnings.Count -gt 0) {
        [void]$all.Add('')
        foreach ($warning in $script:configWarnings) { [void]$all.Add('Test-Completion-Check .env: ' + $warning) }
    }
    $ledgerFailure = [string](Get-Variable -Name LedgerWriteFailed -Scope Script -ValueOnly -ErrorAction SilentlyContinue); if ($ledgerFailure -ne '') { [void]$all.Add('TEST COMPLETION CHECK: its incident ledger could not be written (' + $ledgerFailure + '); recorded notes may be asked for again.') }; $message = ($all.ToArray() -join "`n")
    # The gating DECISION is made above and is unchanged here; Write-HookResult
    # only turns it into the client's wire shape (claude/codex block ->
    # decision:block, claude advisory -> hookSpecificOutput.additionalContext,
    # codex Stop advisory -> systemMessage). A client that documents no Stop
    # gate has its block downgraded to the strongest advisory and reported as
    # degraded, which is what 'degraded-stop-gate' means - never a fake gate.
    $kind = 'advisory'
    # NEVER block a SUBAGENT. On Claude a Stop/SubagentStop `decision:block`
    # FORCES CONTINUATION: the reason arrives as the subagent's next
    # instruction, so it abandons the work it was dispatched to do and the
    # parent receives this gate's text instead of the result. Everything the
    # subagent had produced is lost. This gate's conditions are TASK-level -
    # guarded evidence for the whole task, which a subagent neither caused nor
    # can clear - so blocking one violates the rule that every block must name
    # the safe action that clears it. Reproduced 2026-09-12: a SubagentStop
    # payload emitted a byte-identical block to Stop, for a test command the
    # MAIN agent had run. The advisory is still shown (systemMessage at
    # SubagentStop) and the real gate still holds on the main Stop.
    if ($Blocking -and -not $script:advisoryOnly -and $script:eventName -ne 'SubagentStop') { $kind = 'block' }
    # A block must be ADMITTED before it is emitted: the claim is what gives the
    # gate a memory of having spoken, and it also spends one unit of the shared
    # correction allowance, so it cannot be taken without being granted. A
    # refusal emits nothing and leaves the finding recorded as unresolved. An
    # ADVISORY claims nothing, because it never stopped anything.
    if ($kind -eq 'block') {
        $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Test-Completion-Check' -EventName $script:eventName -Reason $message
        exit $emit.ExitCode
    }
    $emit = Write-HookResult -EventName $script:eventName -Kind $kind -Message $message -Reason $message
    exit $emit.ExitCode
}

