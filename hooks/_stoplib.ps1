# ---------------------------------------------------------------------------
# The Stop delivery/continuation LEDGER.
#
# WHY THIS EXISTS (F01): the old guard was one file per project+hook holding a
# single session id. Two sessions overwrote each other's marker, so alternating
# A/B defeated the guard in BOTH directions - each session's continuation Stop
# read the other's id, concluded "not mine", and blocked again. The audit model
# produced 60 consecutive blocks with the underlying findings never changing.
#
# WHY THE KEY IS WIDER (F02): a session id is not a task id and not an agent id.
# A later task in the same session inherited the earlier task's suppression, and
# a parent and its subagent share a session while needing separate evidence.
#
# The ledger is therefore keyed by project + hook + client + session + agent +
# continuation CHAIN, and it is claimed atomically so concurrent Stops cannot
# lose each other's entries.
#
# THE CHAIN IS WHAT MAKES A NEW TASK RE-ARM, and it is deliberately derived from
# `stop_hook_active` rather than from UserPromptSubmit or a turn id: on Codex a
# Stop block generates a continuation that ARRIVES AS A NEW USER PROMPT, so
# resetting on a new prompt would reset the budget the block just spent and
# restore the loop. A Stop with stop_hook_active=false is a genuine stop, and it
# rotates the chain; a continuation Stop keeps it.
#
# Loaded optionally by _hooklib.ps1: an installed runtime copied before this
# file existed has no _stoplib.ps1 beside it and falls back to the old
# single-marker behaviour, so a stale runtime degrades rather than breaking.
# ---------------------------------------------------------------------------

# PROJECT IDENTITY (R01). The same project has to produce the same key however
# the client spelled its path. A raw ToLowerInvariant() did not: a trailing
# separator, a forward slash, or a relative segment each produced a DIFFERENT
# ledger, so two handlers of one event could spend two separate budgets.
function Get-StopProjectKey {
    param([AllowEmptyString()][string]$ProjectRoot = '')
    $raw = [string]$ProjectRoot
    if ([string]::IsNullOrWhiteSpace($raw)) { return (Get-ShortHash '') }
    $norm = $raw.Replace('/', '\')
    try {
        $full = [System.IO.Path]::GetFullPath($norm)
        if (-not [string]::IsNullOrWhiteSpace($full)) { $norm = $full }
    }
    catch { }
    # A drive root keeps its separator; everything else loses a trailing one.
    $trimmed = $norm.TrimEnd('\')
    if ($trimmed.Length -ge 2 -and $trimmed.EndsWith(':')) { $trimmed = $trimmed + '\' }
    if ($trimmed -eq '') { $trimmed = $norm }
    return (Get-ShortHash $trimmed.ToLowerInvariant())
}

# One ledger document per PROJECT. Per-hook files were the original defect -
# they cannot express "these two sessions are both mid-correction".
function Get-StopLedgerPath {
    param([AllowEmptyString()][string]$ProjectRoot = '')
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('StopLedger-' + (Get-StopProjectKey -ProjectRoot $ProjectRoot) + '.json'))
}

# How many blocks one continuation chain may spend across ALL cooperating gates
# before they stop forcing another answer. Bounded and finite by construction:
# new output text, or another hook speaking, does not reset it - only a genuine
# stop does, by rotating the chain.
function Get-StopCorrectionBudget {
    $configured = [string]$env:HOOKMAKER_STOP_CORRECTION_BUDGET
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($configured) -and [int]::TryParse($configured, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 50) {
        return $parsed
    }
    return 6
}

# The agent this event belongs to. A SubagentStop carries its own transcript, so
# parent and child never share an entry even though they share a session.
function Get-StopAgentKey {
    param([Parameter(Mandatory = $true)]$HookInput)
    foreach ($field in @('agent_transcript_path', 'agent_id')) {
        $value = [string](Get-Field $HookInput $field)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return 'a:' + (Get-ShortHash $value.ToLowerInvariant()) }
    }
    $event = [string](Get-Field $HookInput 'hook_event_name')
    if ($event -eq 'SubagentStop') {
        # A subagent event with no child identity at all: degrade HONESTLY to a
        # distinct bucket rather than merging it into the parent's entry, which
        # would let a subagent's block mute the parent.
        return 'a:subagent-unidentified'
    }
    return 'main'
}

# EVENT IDENTITY (R01). Neither client supplies an event id, and without one two
# gates processing the SAME genuine Stop each minted a fresh chain - so the
# second rotation invalidated the first gate's reservation and the pair could
# block for ever. It is derived instead from the transcript the event points at:
# concurrent handlers of one event observe identical length and write time, and
# a genuinely later task observes a longer transcript.
#
# Returns '' when no transcript is readable. That is UNKNOWN, not "new": the
# caller degrades within a bounded window rather than guessing a reset.
function Get-StopEventId {
    param([Parameter(Mandatory = $true)]$HookInput)
    $path = ''
    try { $path = [string](Get-EvidenceTranscriptPath -HookInput $HookInput) } catch { $path = '' }
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string](Get-Field $HookInput 'transcript_path') }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        return (Get-ShortHash ($path.ToLowerInvariant() + '|' + [string]$item.Length + '|' + [string]$item.LastWriteTimeUtc.Ticks))
    }
    catch { return '' }
}

# How long two genuine Stops with NO usable event identity are treated as one
# event. Cooperating gates for one event are dispatched together; a new task is
# an answer away. Finite, stated, and never longer than one dispatch.
$script:StopEventDegradedWindowSeconds = 5

# PERSISTENCE STATE (R02). A writable-looking parent is not proof the ledger can
# be written: a directory occupying the ledger's own path, a denied ACL and a
# locked file all look identical from above, and in the reproduction twelve
# writes failed while twelve continuations stayed admissible. The only honest
# answer is to try.
function Test-StopLedgerWritable {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        # -Force REPORTS SUCCESS AND CREATES NOTHING when an ancestor is a file -
        # measured: no throw, no directory. So neither the return value nor a
        # catch proves anything; only looking afterwards does.
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    }
    # A DIRECTORY sitting on the ledger's own path is the reproduced case: every
    # write fails while the parent still looks perfectly writable.
    if (Test-Path -LiteralPath $Path -PathType Container) { return $false }
    # Probe a SIDECAR, never the ledger itself: File.Replace below needs the
    # destination to have no open handles, and a probe that opened it would race
    # every concurrent gate's publication for no extra information.
    $probePath = $Path + '.probe'
    try {
        [System.IO.File]::WriteAllText($probePath, 'x')
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

function New-StopLedgerDocument {
    return [pscustomobject]@{ version = 1; chains = [pscustomobject]@{}; entries = [pscustomobject]@{}; unresolved = [pscustomobject]@{} }
}

$script:StopLedgerVersion = 1

# THE STATE OF THE LEDGER, named rather than collapsed into a document (L03).
# Returns @{ Doc; State } with State one of: absent, valid, corrupt, unsupported.
#
# WHY IT MATTERS: every non-valid state used to return a FRESH EMPTY document,
# and a fresh document has blocks = 0. Corruption therefore refunded the
# correction allowance in the middle of a task - the exact loop the allowance
# exists to bound - and a ledger written by a NEWER build was read as current
# and mutated under this build's assumptions.
function Get-StopLedgerState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Doc = (New-StopLedgerDocument); State = 'absent' }
    }
    try {
        $parsed = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['entries']) { throw 'shape' }
        if ($null -ne $parsed.PSObject.Properties['version']) {
            $v = 0
            if (-not [int]::TryParse([string]$parsed.version, [ref]$v)) { throw 'version' }
            # A NEWER ledger is not corrupt and must not be rewritten under this
            # build's rules; an older one has no upgrade path yet, so both are
            # 'unsupported' and both fail closed rather than being reset.
            if ($v -ne $script:StopLedgerVersion) {
                return [pscustomobject]@{ Doc = (New-StopLedgerDocument); State = 'unsupported' }
            }
        }
        if ($null -eq $parsed.PSObject.Properties['chains']) { Set-ObjectProperty -Object $parsed -Name 'chains' -Value ([pscustomobject]@{}) }
        if ($null -eq $parsed.PSObject.Properties['unresolved']) { Set-ObjectProperty -Object $parsed -Name 'unresolved' -Value ([pscustomobject]@{}) }
        return [pscustomobject]@{ Doc = $parsed; State = 'valid' }
    }
    catch {
        # A TORN read cannot reach here any more - publication is atomic, so a
        # reader sees one whole version or the other, never the seam. Reaching
        # this means the file really is damaged.
        return [pscustomobject]@{ Doc = (New-StopLedgerDocument); State = 'corrupt' }
    }
}

# The document alone, for the read-only paths that only need suppression hints.
# A damaged or unsupported ledger yields an EMPTY document here on purpose: a
# hint that finds nothing simply arms the gate, which is the safe direction.
# The paths that can SPEND something use Get-StopLedgerState and refuse.
function Read-StopLedger {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-StopLedgerState -Path $Path).Doc
}

# Publish atomically. File.Copy(overwrite) is what let an unlocked reader see a
# half-written ledger and treat it as fresh, forgetting everything spent so far.
# Replace() is atomic on NTFS and exists on BOTH hosts; the three-argument
# File.Move overload does not exist on Windows PowerShell 5.1.
function Publish-StopLedgerFile {
    param([Parameter(Mandatory = $true)][string]$TempPath, [Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # [NullString]::Value, never $null: PowerShell converts $null to "" for a
        # .NET string parameter, and Replace then rejects the empty backup path -
        # measured on both hosts as "The path is empty (Parameter 'path')".
        [System.IO.File]::Replace($TempPath, $Path, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($TempPath, $Path)
    }
}

# Read-modify-write under an exclusive handle so two Stops racing on the same
# project cannot lose each other's entry. Returns a typed outcome: Ok carries
# the mutation's own result, and a failure is REPORTED rather than swallowed -
# a gate that blocks but cannot record the block re-arms on the next
# continuation and blocks again, for ever.
function Invoke-StopLedgerUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Mutate
    )
    if (-not (Test-StopLedgerWritable -Path $Path)) {
        return [pscustomobject]@{ Ok = $false; State = 'persistence-failed'; Result = $null }
    }
    $lockPath = $Path + '.lock'
    $stream = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch { Start-Sleep -Milliseconds 25 }
    }
    if ($null -eq $stream) { return [pscustomobject]@{ Ok = $false; State = 'busy'; Result = $null } }
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    try {
        $ledger = Read-StopLedger -Path $Path
        $result = & $Mutate $ledger
        $json = $ledger | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Publish-StopLedgerFile -TempPath $tmp -Path $Path
        return [pscustomobject]@{ Ok = $true; State = 'ok'; Result = $result }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; State = 'persistence-failed'; Result = $null }
    }
    finally {
        try { if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        try { $stream.Dispose() } catch { }
        try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# The chain this event belongs to. A continuation keeps its chain. A genuine
# Stop rotates it ONCE PER EVENT, not once per handler: rotating per handler is
# what invalidated the first gate's reservation when a second gate registered
# for the same event, and it is what let a duplicate delivery of one event walk
# straight past suppression.
function Resolve-StopChain {
    param(
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$ChainKey,
        [bool]$IsContinuation,
        [AllowEmptyString()][string]$EventId = ''
    )
    $existing = $null
    if ($null -ne $Ledger.chains.PSObject.Properties[$ChainKey]) { $existing = $Ledger.chains.$ChainKey }
    $hasExisting = ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.id))
    if ($IsContinuation -and $hasExisting) { return $existing }
    if ($hasExisting -and -not $IsContinuation) {
        if ($EventId -ne '' -and [string]$existing.event -eq $EventId) { return $existing }
        if ($EventId -eq '' -or [string]::IsNullOrWhiteSpace([string]$existing.event)) {
            # No usable identity on one side. Bounded degradation rather than a
            # guessed reset: inside the window this is another handler of the
            # same dispatch, outside it a new task.
            try {
                $age = ([DateTime]::UtcNow - [DateTime]::Parse([string]$existing.eventUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds
                if ($age -ge 0 -and $age -le $script:StopEventDegradedWindowSeconds) { return $existing }
            }
            catch { }
        }
    }
    $fresh = [pscustomobject]@{
        id        = [guid]::NewGuid().ToString('N')
        blocks    = 0
        event     = $EventId
        eventUtc  = [DateTime]::UtcNow.ToString('o')
        startedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Set-ObjectProperty -Object $Ledger.chains -Name $ChainKey -Value $fresh
    return $fresh
}

# The entry identity for one gate, and the continuation chain it belongs to.
function Get-StopLedgerKeys {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$HookName)
    $session = [string](Get-Field $HookInput 'session_id')
    $agent = Get-StopAgentKey -HookInput $HookInput
    $client = [string](Get-HookClientId -HookInput $HookInput)
    $chainKey = $client + '|' + $session + '|' + $agent
    # The hook's SEMANTIC name, so a global and a project registration of the
    # same hook share one entry instead of double-delivering.
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($HookName, '[^A-Za-z0-9]+', '')
    return [pscustomobject]@{ ChainKey = $chainKey; EntryKey = ($chainKey + '|' + $safeName) }
}

# $true when this gate must stay silent: either it already blocked in THIS
# chain, or the chain's shared correction budget is spent.
#
# THIS IS A HINT, NOT THE AUTHORITY. It is lock-free on purpose - it runs in
# every cooperating gate on every continuation - and the decision that actually
# counts is taken atomically in Invoke-StopAdmission when the gate has a finding
# to report. A lock-free read is safe here only because publication is atomic.
function Test-StopStandDownLedger {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        [bool]$IsContinuation
    )
    # A genuine Stop is the task boundary, and admission will mint or join a
    # chain there. Returning early keeps a QUERY from touching the filesystem at
    # all: the old path took a lock and rewrote the ledger in every gate on every
    # Stop, creating Hook Maker state in projects the gate had nothing to say
    # about. Only a block writes now.
    if (-not $IsContinuation) { return $false }
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    # Persistence has to be AVAILABLE before arming is safe: a gate that arms,
    # blocks, and then cannot RECORD the block arms again on the next
    # continuation and blocks again, for ever. Standing DOWN is the only answer
    # that cannot loop.
    if (-not (Test-StopLedgerWritable -Path $path)) { return $true }
    $ledger = Read-StopLedger -Path $path
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName $HookName
    $chain = $null
    if ($null -ne $ledger.chains.PSObject.Properties[$keys.ChainKey]) { $chain = $ledger.chains.($keys.ChainKey) }
    # No chain yet means no prior block in it - nothing to stand down for.
    if ($null -eq $chain) { return $false }
    if ([int]$chain.blocks -ge (Get-StopCorrectionBudget)) { return $true }
    $entry = $null
    # Parenthesised on purpose: $ledger.entries.$keys.EntryKey would read
    # ($ledger.entries.$keys).EntryKey, not the property NAMED by the key.
    if ($null -ne $ledger.entries.PSObject.Properties[$keys.EntryKey]) { $entry = $ledger.entries.($keys.EntryKey) }
    return ($null -ne $entry -and [string]$entry.chain -eq [string]$chain.id)
}

# ONE ADMISSION TRANSACTION (R01). Resolving the chain, rejecting a duplicate
# claim, checking the remaining allowance and RESERVING the admission all happen
# under the same lock. Separating them is what let ten contenders each read
# blocks=5 against a budget of 6 and every one of them proceed, leaving 15.
#
# The caller MUST consume the result: a continuation may only be emitted for
# Admitted=$true. Anything else is a refusal, and a refusal is recorded as an
# unresolved finding rather than being forgotten - spending the allowance ends
# the corrections, it does not make the finding clean.
function Invoke-StopAdmission {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        [bool]$IsContinuation
    )
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName $HookName
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    $eventId = Get-StopEventId -HookInput $HookInput

    # CORRUPT OR UNSUPPORTED IS NOT 'FRESH' (L03). An empty document has
    # blocks = 0, so mutating from one hands the chain a full allowance again -
    # a refund in the middle of a task, which is the loop the allowance exists
    # to bound.
    #
    # Recovery happens at a TASK BOUNDARY and nowhere else. A genuine Stop is
    # already entitled to a fresh chain, so quarantining a damaged file there
    # costs nothing and stops the project being wedged for ever; during a
    # continuation the same act would BE the refund, so it refuses instead. A
    # NEWER build's ledger is never quarantined at all - it is not damaged, it
    # is simply not ours to rewrite.
    $ledgerState = (Get-StopLedgerState -Path $path).State
    if ($ledgerState -eq 'unsupported') {
        return [pscustomobject]@{ Admitted = $false; Reason = 'ledger-unsupported'; Degraded = $true }
    }
    if ($ledgerState -eq 'corrupt') {
        if ($IsContinuation) {
            return [pscustomobject]@{ Admitted = $false; Reason = 'ledger-corrupt'; Degraded = $true }
        }
        try {
            $quarantine = $path + '.corrupt-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
            Move-Item -LiteralPath $path -Destination $quarantine -Force -ErrorAction SilentlyContinue
        }
        catch { }
        if ((Get-StopLedgerState -Path $path).State -eq 'corrupt') {
            return [pscustomobject]@{ Admitted = $false; Reason = 'ledger-corrupt'; Degraded = $true }
        }
    }
    $outcome = Invoke-StopLedgerUpdate -Path $path -Mutate {
        param($ledger)
        $chain = Resolve-StopChain -Ledger $ledger -ChainKey $keys.ChainKey -IsContinuation $IsContinuation -EventId $eventId
        $entry = $null
        if ($null -ne $ledger.entries.PSObject.Properties[$keys.EntryKey]) { $entry = $ledger.entries.($keys.EntryKey) }
        # A DUPLICATE CLAIM is the same gate claiming the SAME EVENT twice -
        # one event delivered twice, or a global and a project registration of
        # one hook both firing. It is NOT "this gate already spoke in this
        # chain": a gate whose evidence CHANGED must be evaluated immediately
        # and must be able to refuse again, and a standing safety refusal (a
        # tracked secret, CI still red, an unreconciled branch) has to survive
        # for as long as the condition does. Refusing those was measured as six
        # broken gates across three hooks - completion allowed while the finding
        # was still open, which is the opposite of what a budget is for.
        #
        # Requires a KNOWN event identity. Without one, two claims cannot be
        # told apart from one repeated claim, and the safe reading of an unknown
        # is to admit and spend budget rather than to drop a refusal.
        if ($null -ne $entry -and [string]$entry.chain -eq [string]$chain.id -and
            $eventId -ne '' -and [string]$entry.event -eq $eventId) {
            return [pscustomobject]@{ Admitted = $false; Reason = 'already-claimed' }
        }
        if ([int]$chain.blocks -ge (Get-StopCorrectionBudget)) {
            Set-ObjectProperty -Object $ledger.unresolved -Name $keys.EntryKey -Value ([pscustomobject]@{
                    hook    = $HookName
                    chain   = [string]$chain.id
                    session = [string](Get-Field $HookInput 'session_id')
                    reason  = 'budget-spent'
                    lastUtc = [DateTime]::UtcNow.ToString('o')
                })
            return [pscustomobject]@{ Admitted = $false; Reason = 'budget-spent' }
        }
        Set-ObjectProperty -Object $chain -Name 'blocks' -Value ([int]$chain.blocks + 1)
        Set-ObjectProperty -Object $ledger.chains -Name $keys.ChainKey -Value $chain
        Set-ObjectProperty -Object $ledger.entries -Name $keys.EntryKey -Value ([pscustomobject]@{
                chain      = [string]$chain.id
                hook       = $HookName
                event      = $eventId
                blockedUtc = [DateTime]::UtcNow.ToString('o')
            })
        # A gate that blocks is by definition reporting something unresolved.
        # The session is stored rather than parsed back out of the key, so the
        # summary hook can ask "what blocked in THIS session" without having to
        # know how an entry key is spelled.
        Set-ObjectProperty -Object $ledger.unresolved -Name $keys.EntryKey -Value ([pscustomobject]@{
                hook    = $HookName
                chain   = [string]$chain.id
                session = [string](Get-Field $HookInput 'session_id')
                reason  = 'blocked'
                lastUtc = [DateTime]::UtcNow.ToString('o')
            })
        return [pscustomobject]@{ Admitted = $true; Reason = 'admitted' }
    }
    if ($null -eq $outcome -or -not $outcome.Ok) {
        $state = 'persistence-failed'
        if ($null -ne $outcome) { $state = [string]$outcome.State }
        # Reserved nothing, so emitting a continuation here would be untracked
        # and could repeat without limit.
        return [pscustomobject]@{ Admitted = $false; Reason = $state; Degraded = $true }
    }
    $decision = $outcome.Result
    if ($null -eq $decision) { return [pscustomobject]@{ Admitted = $false; Reason = 'unknown'; Degraded = $true } }
    return [pscustomobject]@{ Admitted = [bool]$decision.Admitted; Reason = [string]$decision.Reason; Degraded = $false }
}

# Record this gate's block and spend one unit of the chain's shared budget.
# Kept as the name every hook already calls; it IS the admission transaction now
# and returns its decision, which the caller must consume.
function Register-StopBlockLedger {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        [bool]$IsContinuation
    )
    return (Invoke-StopAdmission -HookInput $HookInput -HookName $HookName -IsContinuation $IsContinuation)
}

# The gates that blocked or ran out of allowance in this project, for the
# pre-task summary advisory. History, not a live verdict: a recorded block is
# what HAPPENED, never proof that it is still unresolved now.
function Get-StopUnresolvedHistory {
    param([AllowEmptyString()][string]$ProjectRoot = '', [AllowEmptyString()][string]$SessionId = '')
    $path = Get-StopLedgerPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $ledger = Read-StopLedger -Path $path
    # A plain array, built and returned directly: a generic List does not survive
    # @() under StrictMode 2.0 here, and this runs inside hooks that set it.
    $out = @()
    foreach ($prop in @($ledger.unresolved.PSObject.Properties)) {
        $v = $prop.Value
        if ($null -eq $v) { continue }
        # FILTER BEFORE BOUNDING (L04). The cap used to be applied to every
        # entry in the project and the session filter afterwards, so a busy
        # project could fill all 40 rows with OLDER sessions and hide the live
        # one's gates entirely - the caller then reported no history at all for
        # the session that actually had some.
        if (-not [string]::IsNullOrWhiteSpace($SessionId) -and [string]$v.session -ne $SessionId) { continue }
        $out += [pscustomobject]@{ Hook = [string]$v.hook; Reason = [string]$v.reason; LastUtc = [string]$v.lastUtc; Session = [string]$v.session }
        if ($out.Count -ge 40) { break }
    }
    return $out
}

# The gates that blocked in ONE session, for that session's closing summary.
# History, never a live verdict: an entry says a gate DID block, not that the
# condition is still open now - which is why the summary asks the agent to
# account for each rather than asserting any of them is unresolved.
function Get-StopSessionGateHistory {
    param([AllowEmptyString()][string]$ProjectRoot = '', [AllowEmptyString()][string]$SessionId = '')
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return @() }
    $names = @()
    foreach ($row in @(Get-StopUnresolvedHistory -ProjectRoot $ProjectRoot -SessionId $SessionId)) {
        if ([string]::IsNullOrWhiteSpace([string]$row.Hook)) { continue }
        if ($names -contains [string]$row.Hook) { continue }
        $names += [string]$row.Hook
    }
    return ($names | Sort-Object)
}

# The continuation chain this event belongs to, or '' when there is none yet.
# TASK IDENTITY for a secondary guard: a per-hook fingerprint keyed on session
# alone let a PREVIOUS task suppress the same missing requirement on the next
# genuine one. Read-only - asking must not mint a chain.
function Get-StopChainId {
    param([Parameter(Mandatory = $true)]$HookInput)
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $ledger = Read-StopLedger -Path $path
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName 'chain-probe'
    if ($null -eq $ledger.chains.PSObject.Properties[$keys.ChainKey]) { return '' }
    return [string]$ledger.chains.($keys.ChainKey).id
}

# The identity a secondary (per-hook) suppression fingerprint must carry so it
# cannot leak across tasks or between a parent and its subagent. Safe on a
# runtime with no ledger: the chain is simply empty and the rest still applies.
function Get-StopSuppressionIdentity {
    param([Parameter(Mandatory = $true)]$HookInput)
    $session = [string](Get-Field $HookInput 'session_id')
    $agent = Get-StopAgentKey -HookInput $HookInput
    $chain = ''
    try { $chain = Get-StopChainId -HookInput $HookInput } catch { $chain = '' }
    return ($session + '|' + $agent + '|' + $chain)
}

# ---- Stop-time evidence: the CURRENT final assistant response --------------
#
# Returns [pscustomobject]@{ Text; Source; Known }.
#   Known = $false  -> UNKNOWN. Never an all-clear and never a fabricated
#                      failure; the caller must say it could not verify.
#   Source          -> 'event' | 'transcript' | '' (for the record/diagnostics)
#
# Preference order, and why:
#   1. the event's own last_assistant_message - it IS the final response, so no
#      parsing can drag in a previous task, a user example or hook output;
#   2. the LAST assistant entry parsed out of the transcript - still scoped to
#      one response, unlike the raw tail the old readers searched;
#   3. unknown.
#
# For a child event the transcript is agent_transcript_path: reading the parent
# transcript_path there answers about the wrong agent entirely.
function Get-EvidenceTranscriptPath {
    param([Parameter(Mandatory = $true)]$HookInput)
    $event = [string](Get-Field $HookInput 'hook_event_name')
    if ($event -eq 'SubagentStop') {
        # agent_transcript_path is NOT a documented client field - prefer it when a
        # client does supply one, but never require it. On a SubagentStop the
        # documented transcript_path IS the subagent's own transcript, so treating
        # its absence as UNKNOWN disabled every closing gate on every real subagent
        # stop: the evidence came back empty and nothing could ever block.
        $child = [string](Get-Field $HookInput 'agent_transcript_path')
        if (-not [string]::IsNullOrWhiteSpace($child)) { return $child }
    }
    return [string](Get-Field $HookInput 'transcript_path')
}

# The text of the last assistant entry in a JSONL transcript tail.
function Get-LastAssistantTextFromJsonl {
    param([string]$Tail, [switch]$Truncated)
    if ([string]::IsNullOrWhiteSpace($Tail)) { return $null }
    $lines = $Tail -split "`n"
    # Only a TRUNCATED tail has a half record at the front. Dropping the first
    # line unconditionally discarded the ONLY record of a transcript small
    # enough to be read whole - which is every subagent transcript.
    if ($Truncated -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = ([string]$lines[$i]).Trim()
        if ($line.Length -lt 2 -or $line[0] -ne '{') { continue }
        $record = $null
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $record -or $null -eq $record.PSObject.Properties['type']) { continue }
        if ([string]$record.type -ne 'assistant') { continue }
        if ($null -eq $record.PSObject.Properties['message'] -or $null -eq $record.message) { continue }
        $message = $record.message
        if ($null -eq $message.PSObject.Properties['content']) { continue }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($block in @($message.content)) {
            if ($null -eq $block) { continue }
            if ($block -is [string]) { [void]$parts.Add([string]$block); continue }
            if ($null -ne $block.PSObject.Properties['type'] -and [string]$block.type -ne 'text') { continue }
            if ($null -ne $block.PSObject.Properties['text']) { [void]$parts.Add([string]$block.text) }
        }
        if ($parts.Count -gt 0) { return ($parts.ToArray() -join "`n") }
    }
    return $null
}

function Get-ClosingAssistantText {
    param([Parameter(Mandatory = $true)]$HookInput, [int]$TailBytes = 262144)
    $direct = [string](Get-Field $HookInput 'last_assistant_message')
    if (-not [string]::IsNullOrWhiteSpace($direct)) {
        return [pscustomobject]@{ Text = $direct; Source = 'event'; Known = $true }
    }
    $path = Get-EvidenceTranscriptPath -HookInput $HookInput
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Text = ''; Source = ''; Known = $false }
    }
    $tail = $null
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $take = [int][Math]::Min([int64]$TailBytes, $stream.Length)
            if ($take -le 0) { return [pscustomobject]@{ Text = ''; Source = ''; Known = $false } }
            $wasTruncated = ($stream.Length -gt $take)
            if ($stream.Length -gt $take) { [void]$stream.Seek(-$take, [System.IO.SeekOrigin]::End) }
            $buffer = New-Object byte[] $take
            # Looped read: one Read may legally return fewer bytes than asked,
            # and a short read would look like a missing line - a FALSE BLOCK.
            $filled = 0
            while ($filled -lt $take) {
                $chunk = $stream.Read($buffer, $filled, $take - $filled)
                if ($chunk -le 0) { break }
                $filled += $chunk
            }
            if ($filled -le 0) { return [pscustomobject]@{ Text = ''; Source = ''; Known = $false } }
            $tail = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $filled)
        }
        finally { $stream.Dispose() }
    }
    catch { return [pscustomobject]@{ Text = ''; Source = ''; Known = $false } }

    $text = Get-LastAssistantTextFromJsonl -Tail $tail -Truncated:$wasTruncated
    if ($null -eq $text) { return [pscustomobject]@{ Text = ''; Source = ''; Known = $false } }
    return [pscustomobject]@{ Text = $text; Source = 'transcript'; Known = $true }
}

# ---- L01: the finalization barrier ----------------------------------------
#
# THE DEFECT THIS EXISTS FOR, in the user's words: the wrap-up "does not come at
# the very end - then a few more hooks arrive, and it repeats." Both halves are
# real and they have different causes.
#
# REPETITION is enforceable here and is what this code fixes. A gate blocks
# after the answer was written, the agent does the correction, writes a second
# wrap-up, another gate blocks, and the user sees three. Once a wrap-up has been
# observed for a task, every later block in that task says so, and says not to
# write another.
#
# ORDERING is NOT fully enforceable from a Stop hook, and claiming otherwise
# would be the dishonest fix this repair was told to avoid. On Claude Code the
# assistant's message is already displayed before Stop runs, so no Stop handler
# can retract it or move a later correction ahead of it. What IS enforceable is
# that the correction turn adds no second wrap-up, so exactly one is shown - and
# that the agent is told, before it writes, which gates must already be
# satisfied for its message to be the last one. The residual limit is stated in
# docs rather than papered over.

# Does this closing text carry a wrap-up? Deliberately structural rather than a
# keyword sweep: both section labels, each starting a line, in a text that is
# the agent's own final answer. A gate's own instruction text names DONE and
# REMAINING constantly, so a bare keyword search would see one everywhere.
function Test-ClosingSummaryPublished {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # A transcript line break is the two-character \n escape as often as a real
    # one - the same rule the other closing detectors follow.
    $anchor = '(?im)(?:^|\n)[ \t]{0,8}(?:[-*>#]+[ \t]{0,4})?(?:\*\*)?'
    $hasDone = ($Text -match ($anchor + 'DONE\b'))
    $hasRemaining = ($Text -match ($anchor + 'REMAINING\b'))
    return ($hasDone -and $hasRemaining)
}

# Record that this task published its wrap-up, so later blocks can refuse a
# second one. Keyed by the continuation chain, which is the task identity the
# admission ledger already maintains.
function Set-TaskSummaryPublished {
    param([Parameter(Mandatory = $true)]$HookInput)
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName 'summary-state'
    $stopActive = Get-Field $HookInput 'stop_hook_active'
    $isContinuation = ($null -ne $stopActive -and [bool]$stopActive)
    $eventId = Get-StopEventId -HookInput $HookInput
    $null = Invoke-StopLedgerUpdate -Path $path -Mutate {
        param($ledger)
        # RESOLVE, never "read and give up". The flag has to outlive the event that
        # observed the wrap-up: the gate that sees it may be the first to touch
        # this task, and a flag dropped because no chain existed yet is exactly how
        # the second wrap-up got through. Resolve-StopChain is the same task
        # identity admission uses, so the flag lands on the task it belongs to.
        $chain = Resolve-StopChain -Ledger $ledger -ChainKey $keys.ChainKey -IsContinuation $isContinuation -EventId $eventId
        Set-ObjectProperty -Object $chain -Name 'summaryPublishedUtc' -Value ([DateTime]::UtcNow.ToString('o'))
        Set-ObjectProperty -Object $ledger.chains -Name $keys.ChainKey -Value $chain
        return 'ok'
    }
}

function Test-TaskSummaryAlreadyPublished {
    param([Parameter(Mandatory = $true)]$HookInput)
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $ledger = Read-StopLedger -Path $path
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName 'summary-state'
    if ($null -eq $ledger.chains.PSObject.Properties[$keys.ChainKey]) { return $false }
    $chain = $ledger.chains.($keys.ChainKey)
    if ($null -eq $chain.PSObject.Properties['summaryPublishedUtc']) { return $false }
    return (-not [string]::IsNullOrWhiteSpace([string]$chain.summaryPublishedUtc))
}

# The clause every block carries. Two forms, because the two situations need
# opposite instructions and guessing between them is what produced the repeats.
function Get-StopFinalizationClause {
    param([Parameter(Mandatory = $true)]$HookInput)
    $published = $false
    try { $published = Test-TaskSummaryAlreadyPublished -HookInput $HookInput } catch { $published = $false }
    if (-not $published) {
        $evidence = $null
        try { $evidence = Get-ClosingAssistantText -HookInput $HookInput } catch { $evidence = $null }
        if ($null -ne $evidence -and $evidence.Known -and (Test-ClosingSummaryPublished -Text ([string]$evidence.Text))) {
            $published = $true
            try { Set-TaskSummaryPublished -HookInput $HookInput } catch { }
        }
    }
    if ($published) {
        return ('FINALIZATION: a DONE / REMAINING wrap-up was already published for this task. This is a CORRECTION turn - ' +
            'resolve what this block names and stop. Do NOT write a second wrap-up: one per task is the whole rule, and ' +
            'repeating it is what makes the real one unreadable. If the correction changes what the published wrap-up ' +
            'claimed, say only that, in one line.')
    }
    return ('FINALIZATION: do not write the DONE / REMAINING wrap-up in this correction turn. It belongs in the message ' +
        'after which nothing blocks - so satisfy the remaining gates first, then write it exactly once, last.')
}
