# Test-StopLedger.ps1 scenario block: THE ORIGINATING USER TASK (L02).
#
# The defects, each reproducible before the fix:
#   1. Identity was a hash of the transcript's path, length and write time. Two
#      handlers of ONE dispatch could observe different stats while the file was
#      still flushing and mint two chains; a genuinely new task could observe
#      unchanged stats and inherit the old one.
#   2. A prompt that is the client REPLAYING a gate's refusal (Codex does this)
#      looked like a new user task, so every refusal refilled the allowance.
#   3. The duplicate rule compared only the delivery, so a gate whose evidence
#      had CHANGED was refused as a duplicate of its own earlier complaint.
#
# Dot-sourced by Test-StopLedger.ps1 into its scope (uses its Check,
# New-StopInput, $Work and the isolated LOCALAPPDATA it sets up) - not a
# standalone suite.

Check 'the task-identity module loaded' ($script:TaskIdentityReady -eq $true) ('TaskIdentityReady=' + [string]$script:TaskIdentityReady)

# A UserPromptSubmit carrying a real prompt: the only thing that starts a task.
function New-PromptInput {
    param([string]$Session, [string]$Prompt, [string]$Cwd = 'C:\proj\identity')
    return [pscustomobject]@{
        session_id      = $Session
        cwd             = $Cwd
        hook_event_name = 'UserPromptSubmit'
        prompt          = $Prompt
    }
}

$idCwd = 'C:\proj\identity'
$idSession = 'SESS-IDENTITY'

# ---- the boundary mints once, and every later handler reads the same one ----
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $idSession -Prompt 'first request')
$firstStop = New-StopInput -Session $idSession -Continuation $false -Cwd $idCwd
$firstId = Get-StopEventId -HookInput $firstStop
Check 'a Stop inside a task resolves to the TASK identity, not a transcript hash' (
    $firstId -like 't:*') $firstId

# The same prompt delivered again (the other seventeen hooks of one dispatch)
# must not mint a second task.
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $idSession -Prompt 'first request')
Check 'a second handler of the SAME dispatch reads the same task back' (
    (Get-StopEventId -HookInput $firstStop) -eq $firstId) (Get-StopEventId -HookInput $firstStop)

# Whitespace is not a new question.
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $idSession -Prompt "first request`n")
Check 'a trailing newline the client adds does not start a task' (
    (Get-StopEventId -HookInput $firstStop) -eq $firstId) (Get-StopEventId -HookInput $firstStop)

# ---- a genuinely new user request DOES rotate -------------------------------
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $idSession -Prompt 'second, different request')
$secondId = Get-StopEventId -HookInput $firstStop
Check 'a different user request is a different task' ($secondId -ne $firstId) ($firstId + ' vs ' + $secondId)

# ---- the client replaying a refusal is NOT a new task -----------------------
$refusal = 'RULES CHECK: the rules file changed and was not read. Read it, then finish.'
Add-TaskBlockFingerprint -HookInput $firstStop -Reason $refusal
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $idSession -Prompt $refusal)
Check 'a prompt that is the gate''s own refusal text does not mint a task (Codex continuation)' (
    (Get-StopEventId -HookInput $firstStop) -eq $secondId) (Get-StopEventId -HookInput $firstStop)
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $idSession -Prompt 'a real follow-up from the user')
Check 'but a real follow-up right after that refusal still starts a task' (
    (Get-StopEventId -HookInput $firstStop) -ne $secondId) (Get-StopEventId -HookInput $firstStop)

# ---- another session never inherits this one's task -------------------------
$otherStop = New-StopInput -Session 'SESS-OTHER' -Continuation $false -Cwd $idCwd
$otherId = Get-StopEventId -HookInput $otherStop
Check 'a different session does not read this session''s task identity' (
    $otherId -notlike 't:*') $otherId

# ---- changed evidence may speak; the same complaint may not -----------------
# One task, one gate. The first refusal is admitted; repeating the SAME words is
# not asked for again; different words are different evidence and are admitted.
$taskSession = 'SESS-FINDING'
Register-UserTaskBoundary -HookInput (New-PromptInput -Session $taskSession -Prompt 'work on the thing' -Cwd $idCwd)
$gateStop = New-StopInput -Session $taskSession -Continuation $false -Cwd $idCwd
$firstAdmit = Set-StopBlockMarker -HookInput $gateStop -HookName 'Ci-Status-Check' -FindingFingerprint 'finding-aaa'
Check 'a gate''s first refusal in a task is admitted' ($firstAdmit.Admitted) ([string]$firstAdmit.Reason)
$contStop = New-StopInput -Session $taskSession -Continuation $true -Cwd $idCwd
$repeatAdmit = Set-StopBlockMarker -HookInput $contStop -HookName 'Ci-Status-Check' -FindingFingerprint 'finding-aaa'
Check 'the SAME unchanged finding is not requested a second time' (-not $repeatAdmit.Admitted) ([string]$repeatAdmit.Reason)
Check 'and it is refused as a duplicate claim, not as a spent budget' (
    [string]$repeatAdmit.Reason -eq 'already-claimed') ([string]$repeatAdmit.Reason)
$changedAdmit = Set-StopBlockMarker -HookInput $contStop -HookName 'Ci-Status-Check' -FindingFingerprint 'finding-bbb'
Check 'CHANGED evidence from the same gate in the same task is admitted' ($changedAdmit.Admitted) ([string]$changedAdmit.Reason)
