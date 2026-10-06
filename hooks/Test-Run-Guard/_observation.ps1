# Hands Test-Completion-Check the one fact only this hook can know: a test
# command was seen for THIS repo state. The fingerprint is derived exactly as
# the consumer derives it. A non-Git workspace has explicit degraded provenance;
# a repository whose state cannot be read records nothing, never a path hash.
#
# WHY THERE IS NO MATCHING "active" RECORD: that record's `pid` must be a
# process the consumer can prove is alive. This hook cannot know one. At
# PreToolUse the guarded runner has not started; at PostToolUse it has already
# exited; and it runs as a child of the CLIENT, never of this hook, so its pid
# is never in scope here. A fabricated or guessed pid would be strictly worse
# than none: pids are recycled, so an unrelated live process would block
# completion forever. Only the runner knows its own pid - see the report.
#
# The record now carries the full run-identity contract (schema 2): the runId
# minted (raw) or preserved (guarded), whether this hook CONTROLS that runId
# (a raw run whose replacement injects it -> yes; a guarded run typed directly
# without -RunId -> no, so the consumer binds on command+project+time instead),
# the command fingerprint the runner will independently recompute, and the
# repository fingerprint. This is what lets the consumer reject a stale result
# from an earlier run/command/state instead of trusting file age.
function Get-StateFingerprintFor {
    param([string]$ProjectRoot)
    return (Get-RepositoryStateEvidence -ProjectRoot $ProjectRoot).BindingFingerprint
}
function Write-ObservedRecord {
    param(
        [string]$Path, [string]$ProjectRoot, [bool]$Guarded,
        [string]$RunId, [bool]$RunIdControlled, [string]$CommandFingerprint, [string]$ProjectFingerprint
    )
    $state = Get-RepositoryStateEvidence -ProjectRoot $ProjectRoot
    if ($state.State -eq 'unavailable') { return }
    if ([string]::IsNullOrWhiteSpace($ProjectFingerprint)) { $ProjectFingerprint = $state.BindingFingerprint }
    try {
        Write-JsonFileAtomic -Path $Path -Value ([pscustomobject][ordered]@{
                schema             = 2
                observedUtc        = [DateTime]::UtcNow.ToString('o')
                fingerprint        = $ProjectFingerprint
                projectFingerprint = $ProjectFingerprint
                projectKey         = $state.ProjectKey
                repositoryState    = $state.State
                repositoryStateFingerprint = $state.RepositoryStateFingerprint
                runId              = $RunId
                runIdControlled    = $RunIdControlled
                commandFingerprint = $CommandFingerprint
                guarded            = $Guarded
            })
    }
    catch { }    # coordination is best-effort: it must never break the gate
}
