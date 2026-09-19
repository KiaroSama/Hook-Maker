# THE ORIGINATING USER TASK (L02).
#
# WHAT WAS WRONG. Event identity was a hash of the transcript's path, length and
# write time. Both directions failed. Two gates handling the SAME dispatch could
# observe different stats while the transcript was still flushing, so one event
# minted two chains and the pair could block each other for ever; and a
# genuinely NEW task could observe unchanged or lagging stats and be treated as
# the old one. Twelve deliveries with no new user request were admitted as
# twelve new chains in the source-derived replay. Atomic reservation cannot
# repair a wrong identity - it only makes the wrong answer consistent.
#
# WHAT IDENTITY ACTUALLY IS. A task begins when the USER says something. That is
# an explicit lifecycle boundary the client already reports - UserPromptSubmit -
# and it is the only event that means "a new thing was asked for". So the task
# id is minted THERE, once, into a durable record, and every later handler READS
# it instead of deriving one. Transcript growth, hook text, tool output, elapsed
# time, a retry, compaction and a changed turn id all leave it untouched,
# because none of them is a user asking for something new.
#
# CODEX. On Codex a Stop continuation arrives as a new user prompt: the client
# replays the gate's own refusal text as the next input. Rotating there would
# hand every refusal a fresh chain and a fresh allowance, which is the loop the
# allowance exists to bound. Each emitted block therefore records the
# fingerprint of its own text, and a prompt matching one of those fingerprints
# is recognised as the continuation it is. An exact match is the whole rule: if
# a client ever wraps the text, the prompt does not match, a new task starts,
# and that is the SAFE direction - a fresh bounded chain, exactly as today.
#
# DEGRADATION IS VISIBLE, NEVER GUESSED. With no record (hooks installed
# mid-session, a client that sends no UserPromptSubmit), the caller is told the
# identity is degraded and falls back to the older, weaker derivation inside its
# own bounded window. Nothing here invents a task id.

$script:TaskIdentitySchema = 1
$script:TaskIdentityMaxBlockFingerprints = 16   # bounded: a chain cannot grow this record without limit

function Get-TaskIdentityPath {
    param([AllowEmptyString()][string]$ProjectRoot = '')
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('TaskIdentity-' + (Get-StopProjectKey -ProjectRoot $ProjectRoot) + '.json'))
}

function Get-TaskPromptFingerprint {
    param([AllowEmptyString()][string]$Prompt)
    $text = ([string]$Prompt)
    # Whitespace-normalised so a trailing newline the client adds is not a
    # different question. Nothing else is touched: two prompts that differ by a
    # single word are two different tasks.
    $text = [System.Text.RegularExpressions.Regex]::Replace($text, '\s+', ' ').Trim()
    if ($text -eq '') { return '' }
    return (Get-ShortHash $text)
}

function Read-TaskIdentityRecord {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $doc = Read-JsonFile -Path $Path
        if ($null -eq $doc) { return $null }
        if ([int](Get-Field $doc 'schema') -ne $script:TaskIdentitySchema) { return $null }
        return $doc
    }
    catch { return $null }
}

# Called on UserPromptSubmit by every hook, through Read-HookInput, and
# IDEMPOTENT on purpose: the first hook of a dispatch mints the task, the other
# seventeen read the same one back. That is what "shared once per dispatch"
# means - the alternative, each handler deriving its own, is the defect.
function Register-UserTaskBoundary {
    param([Parameter(Mandatory = $true)]$HookInput)
    $event = [string](Get-Field $HookInput 'hook_event_name')
    if (-not [string]::Equals($event, 'UserPromptSubmit', [System.StringComparison]::OrdinalIgnoreCase)) { return }
    $prompt = [string](Get-Field $HookInput 'prompt')
    if ([string]::IsNullOrWhiteSpace($prompt)) { $prompt = [string](Get-Field $HookInput 'user_prompt') }
    $fingerprint = Get-TaskPromptFingerprint -Prompt $prompt
    # A prompt this hook cannot see is not evidence that a task started. Silence
    # here leaves the previous record standing, which degrades to the old
    # behaviour instead of rotating on nothing.
    if ($fingerprint -eq '') { return }

    $sessionId = [string](Get-Field $HookInput 'session_id')
    $projectRoot = [string](Get-Field $HookInput 'cwd')
    $path = Get-TaskIdentityPath -ProjectRoot $projectRoot
    $existing = Read-TaskIdentityRecord -Path $path

    if ($null -ne $existing -and
        [string]::Equals([string](Get-Field $existing 'sessionId'), $sessionId, [System.StringComparison]::Ordinal)) {
        # Same dispatch: the task is already minted, nothing to do.
        if ([string]::Equals([string](Get-Field $existing 'promptFingerprint'), $fingerprint, [System.StringComparison]::Ordinal)) { return }
        # The client replaying a gate's own refusal is NOT a new task.
        $blockFingerprints = @()
        try { $blockFingerprints = @(Get-Field $existing 'blockFingerprints') } catch { $blockFingerprints = @() }
        if (@($blockFingerprints) -contains $fingerprint) { return }
    }

    $sequence = 0
    if ($null -ne $existing) { try { $sequence = [int](Get-Field $existing 'taskSeq') } catch { $sequence = 0 } }
    $sequence++
    $record = [pscustomobject][ordered]@{
        schema            = $script:TaskIdentitySchema
        sessionId         = $sessionId
        taskSeq           = $sequence
        taskId            = ('t' + [string]$sequence + '-' + (Get-ShortHash ($sessionId + '|' + [string]$sequence + '|' + $fingerprint)))
        startedUtc        = [DateTime]::UtcNow.ToString('o')
        promptFingerprint = $fingerprint
        blockFingerprints = @()
    }
    try {
        $directory = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Write-JsonFileAtomic -Value $record -Path $path
    }
    catch { }
}

# The identity every Stop handler of this task must agree on.
# Degraded=$true means "no provenance", never "a new task".
function Get-CurrentUserTaskIdentity {
    param([Parameter(Mandatory = $true)]$HookInput)
    $projectRoot = [string](Get-Field $HookInput 'cwd')
    $record = Read-TaskIdentityRecord -Path (Get-TaskIdentityPath -ProjectRoot $projectRoot)
    if ($null -eq $record) { return [pscustomobject]@{ TaskId = ''; Degraded = $true } }
    $sessionId = [string](Get-Field $HookInput 'session_id')
    $recordSession = [string](Get-Field $record 'sessionId')
    # A record from ANOTHER session says nothing about this one. Reporting it
    # would bind two sessions into one chain and one shared allowance.
    if (-not [string]::IsNullOrEmpty($sessionId) -and -not [string]::Equals($recordSession, $sessionId, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ TaskId = ''; Degraded = $true }
    }
    $taskId = [string](Get-Field $record 'taskId')
    if ([string]::IsNullOrWhiteSpace($taskId)) { return [pscustomobject]@{ TaskId = ''; Degraded = $true } }
    return [pscustomobject]@{ TaskId = $taskId; Degraded = $false }
}

# Record the text a gate just refused with, so the client replaying it as the
# next prompt is recognised instead of starting a task. Bounded, and a failure
# to write is silent by design: the worst case is one extra task boundary, which
# is the behaviour before this file existed.
function Add-TaskBlockFingerprint {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Reason
    )
    $fingerprint = Get-TaskPromptFingerprint -Prompt $Reason
    if ($fingerprint -eq '') { return }
    $path = Get-TaskIdentityPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    $record = Read-TaskIdentityRecord -Path $path
    if ($null -eq $record) { return }
    $existing = @()
    try { $existing = @(Get-Field $record 'blockFingerprints') } catch { $existing = @() }
    if (@($existing) -contains $fingerprint) { return }
    $updated = @(@($existing) + @($fingerprint))
    if ($updated.Count -gt $script:TaskIdentityMaxBlockFingerprints) {
        $updated = @($updated[($updated.Count - $script:TaskIdentityMaxBlockFingerprints)..($updated.Count - 1)])
    }
    Set-ObjectProperty -Object $record -Name 'blockFingerprints' -Value $updated
    try { Write-JsonFileAtomic -Value $record -Path $path } catch { }
}
