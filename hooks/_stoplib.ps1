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

# One ledger document per PROJECT. Per-hook files were the original defect -
# they cannot express "these two sessions are both mid-correction".
function Get-StopLedgerPath {
    param([AllowEmptyString()][string]$ProjectRoot = '')
    $projectKey = Get-ShortHash ([string]$ProjectRoot).ToLowerInvariant()
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('StopLedger-' + $projectKey + '.json'))
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

function Read-StopLedger {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ version = 1; chains = [pscustomobject]@{}; entries = [pscustomobject]@{} }
    }
    try {
        $parsed = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['entries']) { throw 'shape' }
        if ($null -eq $parsed.PSObject.Properties['chains']) { Set-ObjectProperty -Object $parsed -Name 'chains' -Value ([pscustomobject]@{}) }
        return $parsed
    }
    catch {
        # A damaged ledger is rebuilt, never trusted. Losing suppression state
        # costs at most one extra block per gate; trusting a corrupt one could
        # mute a real finding.
        return [pscustomobject]@{ version = 1; chains = [pscustomobject]@{}; entries = [pscustomobject]@{} }
    }
}

# Read-modify-write under an exclusive handle so two Stops racing on the same
# project cannot lose each other's entry. Returns $false when persistence is
# unavailable - the caller must then degrade honestly, never fail open into an
# unbounded loop.
function Invoke-StopLedgerUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Mutate
    )
    try { New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null } catch { return $null }
    $lockPath = $Path + '.lock'
    $stream = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch { Start-Sleep -Milliseconds 25 }
    }
    if ($null -eq $stream) { return $null }
    try {
        $ledger = Read-StopLedger -Path $Path
        $result = & $Mutate $ledger
        $json = $ledger | ConvertTo-Json -Depth 10
        $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Copy($tmp, $Path, $true)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $result
    }
    catch { return $null }
    finally {
        try { $stream.Dispose() } catch { }
        try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# The chain this event belongs to, rotating on a genuine (non-continuation) Stop.
function Resolve-StopChain {
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)][string]$ChainKey, [bool]$IsContinuation)
    $existing = $null
    if ($null -ne $Ledger.chains.PSObject.Properties[$ChainKey]) { $existing = $Ledger.chains.$ChainKey }
    if ($IsContinuation -and $null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.id)) {
        return $existing
    }
    $fresh = [pscustomobject]@{ id = [guid]::NewGuid().ToString('N'); blocks = 0; startedUtc = [DateTime]::UtcNow.ToString('o') }
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
function Test-StopStandDownLedger {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        [bool]$IsContinuation
    )
    # A genuine Stop is the task boundary. Resolve-StopChain always mints a
    # FRESH chain (blocks = 0) for one, so the budget test cannot trip and the
    # verdict is always 'arm' - computable without reading anything. Returning
    # here keeps a QUERY from mutating: the old path took a lock and rewrote the
    # ledger in every gate on every Stop, which created Hook Maker state in
    # projects the gate had nothing to say about and put a locked
    # read-modify-write on the hottest path there is. Only a block writes now.
    if (-not $IsContinuation) { return $false }
    # READ-ONLY from here. One shared read, no lock, no write: a question must
    # not change the thing it asks about, and this one runs in every cooperating
    # gate on every continuation.
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    # Persistence has to be AVAILABLE before arming is safe. Not for the read -
    # Read-StopLedger degrades to an empty ledger by design - but for the write
    # that follows: a gate that arms, blocks, and then cannot RECORD the block
    # arms again on the next continuation and blocks again, for ever. Standing
    # DOWN is the only answer that cannot loop. Checked here, on the continuation
    # path only, so a genuine Stop still creates nothing anywhere.
    $ledgerDir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $ledgerDir -PathType Container)) {
        # -Force creates a deep NEW path happily, so 'does not exist' is not
        # 'unwritable'. But it also REPORTS SUCCESS AND CREATES NOTHING when an
        # ancestor is a file - measured: no throw, no directory, the blocking file
        # left intact. So neither the return value nor a catch proves anything;
        # only looking for the directory afterwards does.
        try { New-Item -ItemType Directory -Path $ledgerDir -Force -ErrorAction SilentlyContinue | Out-Null }
        catch { }
        if (-not (Test-Path -LiteralPath $ledgerDir -PathType Container)) { return $true }
    }
    $ledger = Read-StopLedger -Path $path
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName $HookName
    $chain = $null
    if ($null -ne $ledger.chains.PSObject.Properties[$keys.ChainKey]) { $chain = $ledger.chains.($keys.ChainKey) }
    # No chain yet means no prior block in it - nothing to stand down for. The old
    # path minted one here purely as a side effect of asking.
    if ($null -eq $chain) { return $false }
    # Budget spent: every cooperating gate stands down, so the chain ends instead
    # of forcing another answer for ever.
    if ([int]$chain.blocks -ge (Get-StopCorrectionBudget)) { return $true }
    $entry = $null
    # Parenthesised on purpose: $ledger.entries.$keys.EntryKey would read
    # ($ledger.entries.$keys).EntryKey, not the property NAMED by the key.
    if ($null -ne $ledger.entries.PSObject.Properties[$keys.EntryKey]) { $entry = $ledger.entries.($keys.EntryKey) }
    return ($null -ne $entry -and [string]$entry.chain -eq [string]$chain.id)
}

# Record this gate's block and spend one unit of the chain's shared budget.
function Register-StopBlockLedger {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        [bool]$IsContinuation
    )
    $keys = Get-StopLedgerKeys -HookInput $HookInput -HookName $HookName
    $path = Get-StopLedgerPath -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    $null = Invoke-StopLedgerUpdate -Path $path -Mutate {
        param($ledger)
        $chain = Resolve-StopChain -Ledger $ledger -ChainKey $keys.ChainKey -IsContinuation $IsContinuation
        Set-ObjectProperty -Object $chain -Name 'blocks' -Value ([int]$chain.blocks + 1)
        Set-ObjectProperty -Object $ledger.chains -Name $keys.ChainKey -Value $chain
        Set-ObjectProperty -Object $ledger.entries -Name $keys.EntryKey -Value ([pscustomobject]@{
                chain      = [string]$chain.id
                hook       = $HookName
                blockedUtc = [DateTime]::UtcNow.ToString('o')
            })
        return 'ok'
    }
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
