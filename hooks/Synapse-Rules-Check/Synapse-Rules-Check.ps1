# Synapse-Rules-Check - the agent reads ITS OWN standing rules from the Synapse
# memory store before it edits the project, and decides about write-back before
# it closes.
#
# ROLE: ADVISORY on SessionStart/UserPromptSubmit, GATE (blocks once) on Stop
# (global-hook-rules.md SS Hook Roles; spec 037). A PowerShell hook has no MCP
# client, so it never reads or writes the store itself; it judges only what the
# COMPLETE transcript proves - client-recorded tool calls, never prose:
#   - project edits and no memory_digest/memory_retrieve/memory_write call
#     -> refused once (read duty, FR-037-01);
#   - project edits, no memory_write call and no closing line
#     `Synapse: none - <reason>` (or the older `no durable learning`) -> refused once (write duty,
#     FR-037-02). The reasoned opt-out keeps trivial edits from forcing junk
#     notes; an empty reason does not clear it;
#   - a read that came only after the first edit -> one advisory (FR-037-03).
# Never refused (FR-037-04): no project edit, SubagentStop (the subagent works
# under its parent's duties), no/partial/unreadable transcript, or a machine
# without a Synapse store. HOOK_ENFORCEMENT=advisory|off softens or disables it.
#
# WHY IT BLOCKS NOW: the advisory version was ignored. Whole sessions ran without
# a single Synapse query while rules stored there were broken in that same
# session; a reminder the agent can skip is exactly the step that gets skipped.
#
# Project edits exclude .ai/, .claude/, plans/, specs/, .specify/ and anything
# outside the project root, the same filter as Speckit-Check.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) { exit 0 }
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'SessionStart' }
if ($eventName -notin @('SessionStart', 'UserPromptSubmit', 'Stop', 'SubagentStop')) { exit 0 }
# A subagent works under the parent's duties; refusing it would wedge delegation.
if ($eventName -eq 'SubagentStop') { exit 0 }
if ($eventName -eq 'Stop') {
    $stopActive = Get-Field $hookInput 'stop_hook_active'
    if ($null -ne $stopActive -and [bool]$stopActive) { exit 0 }
}

# ---- relevance gate: is Synapse actually set up on this machine? ------------
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$synapseHome = ''
if ($config.ContainsKey('SYNAPSE_HOME')) { $synapseHome = [string]$config['SYNAPSE_HOME'] }
$storePath = Join-Path $env:USERPROFILE '.synapse\synapse.db'
$configured = $false
try { if (Test-Path -LiteralPath $storePath -PathType Leaf) { $configured = $true } } catch { }
if (-not $configured -and -not [string]::IsNullOrWhiteSpace($synapseHome)) {
    try { if (Test-Path -LiteralPath $synapseHome -PathType Container) { $configured = $true } } catch { }
}
if (-not $configured) { exit 0 }

$cwd = [string](Get-Field $hookInput 'cwd')
$sessionId = [string](Get-Field $hookInput 'session_id')
$projectKey = Get-ShortHash ([string]$cwd).ToLowerInvariant()
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'

# ---- SessionStart: state both duties up front (FR-037-05) -------------------
if ($eventName -eq 'SessionStart') {
    $note = 'Synapse-Rules-Check: ENFORCED at Stop. (1) Before the first project edit: memory_digest once with tokenBudget, index id/type/preview then full task matches; memory_retrieve minScore0.65 OR project:<slug> tags, never both. (2) Before closing: memory_write durable facts/decisions/verified commands (entityKey/project tag), or end with `Synapse: none - <reason>`. Recall != canonical policy or consent; no secrets, no raw memory disclosure.'
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message $note
    exit $emit.ExitCode
}

# ---- UserPromptSubmit: one mid-session note, only with evidence ------------
# A bounded tail read keeps this per-prompt path cheap; the Stop gate below is
# the one that reads the complete transcript.
if ($eventName -eq 'UserPromptSubmit') {
    if ($config.ContainsKey('MID_SESSION_REMINDER') -and [string]$config['MID_SESSION_REMINDER'] -eq '0') { exit 0 }
    if ($sessionId -eq '') { exit 0 }
    $tailText = ''
    $path = [string](Get-Field $hookInput 'transcript_path')
    try {
        if ($path -ne '' -and [IO.File]::Exists($path)) {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $take = [int][Math]::Min([int64]262144, $stream.Length)
                if ($stream.Length -gt $take) { [void]$stream.Seek(-$take, [IO.SeekOrigin]::End) }
                $buffer = New-Object byte[] $take
                $read = $stream.Read($buffer, 0, $take)
                if ($read -gt 0) { $tailText = [Text.Encoding]::UTF8.GetString($buffer, 0, $read) }
            }
            finally { $stream.Dispose() }
        }
    }
    catch { $tailText = '' }
    # Tool-call record shape only: this hook's own notes name the tools too.
    $consulted = ($tailText -match '(?i)"(?:name|tool_name)"[ \t]*:[ \t]*"mcp__[A-Za-z0-9_.\-]*synapse[A-Za-z0-9_.\-]*__memory_(digest|retrieve|write)"')
    $worked = ($tailText -match '"name"[ \t]*:[ \t]*"(Write|Edit|MultiEdit|NotebookEdit)"')
    if ($consulted -or -not $worked) { exit 0 }
    $midPath = Join-Path $stateDir ('SynapseRulesCheck-mid-' + $projectKey + '.txt')
    $midKey = Get-ShortHash ($sessionId + '|mid|unread-after-work')
    try { if ([IO.File]::Exists($midPath) -and ([IO.File]::ReadAllText($midPath).Trim()) -eq $midKey) { exit 0 } } catch { }
    try { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null; [IO.File]::WriteAllText($midPath, $midKey) }
    catch { exit 0 }    # an undeliverable once-marker must not turn into a per-prompt note
    $emit = Write-HookResult -EventName $eventName -Kind 'context' -Message 'SYNAPSE: files changed without store read; Stop will refuse. Now: `memory_digest` + `tokenBudget`, read matches, continue.'
    exit $emit.ExitCode
}

# ---- Stop: read and write duties over the complete transcript ---------------
$gateReceipt = if (Get-Command Start-StopGateReceipt -ErrorAction SilentlyContinue) { Start-StopGateReceipt -HookInput $hookInput -HookName 'Synapse-Rules-Check' } else { $null }
try {
    if ((Get-Command Test-StopStandDown -ErrorAction SilentlyContinue) -and (Test-StopStandDown -HookInput $hookInput -HookName 'Synapse-Rules-Check')) { exit 0 }
    if (-not $script:EvidenceLibReady -or [string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
    $maxBytes = 20000000
    if ($config.ContainsKey('MAX_TRANSCRIPT_BYTES')) {
        $parsed = 0
        if ([int]::TryParse([string]$config['MAX_TRANSCRIPT_BYTES'], [ref]$parsed) -and $parsed -ge 100000) { $maxBytes = $parsed }
    }
    $evidence = Get-TranscriptToolEvidence -Path ([string](Get-Field $hookInput 'transcript_path')) -MaxBytes $maxBytes
    # Partial means the read or the edit may sit in the unread part: unknown, silent.
    if (-not $evidence.Ok -or $evidence.Partial) { exit 0 }

    $root = [IO.Path]::GetFullPath($cwd).TrimEnd('\', '/') + '\'
    $index = 0; $firstEdit = -1; $firstRead = -1; $editCount = 0; $wrote = $false
    foreach ($item in @($evidence.Events)) {
        $index++
        if ($item.Kind -eq 'synapse') {
            # A write needs the store too, so it also counts as a read.
            if ($firstRead -lt 0) { $firstRead = $index }
            if ($item.Value -eq 'write') { $wrote = $true }
        }
        elseif ($item.Kind -eq 'write') {
            $full = ''
            try { $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($item.Value)) { $item.Value } else { Join-Path $cwd $item.Value })) } catch { continue }
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($full.Substring($root.Length) -match '^(?i)(\.ai|\.claude|plans|specs|\.specify)[\\/]') { continue }
            $editCount++
            if ($firstEdit -lt 0) { $firstEdit = $index }
        }
    }
    if ($editCount -eq 0) { exit 0 }

    $optOut = $false
    if (-not $wrote) {
        $closing = $null
        if (Get-Command Get-TaskClosingEvidence -ErrorAction SilentlyContinue) { $closing = Get-TaskClosingEvidence -HookInput $hookInput }
        elseif (Get-Command Get-ClosingAssistantText -ErrorAction SilentlyContinue) { $closing = Get-ClosingAssistantText -HookInput $hookInput }
        if ($null -ne $closing -and $closing.Known) {
            $declaration = Test-ClosingDeclaration -Text ([string]$closing.Text) -LabelPattern 'Synapse'
            # The reason must be real words after the dash, not "-" or "n/a".
            if ($declaration.Present -and ([string]$declaration.Value).Trim() -match '^(?i)(?:none|no[ \t]+durable[ \t]+learning)[ \t]*[-:][ \t]*(?<reason>.*\S.*)$' -and $Matches['reason'].Trim().Length -ge 6) { $optOut = $true }
        }
    }

    $missingRead = ($firstRead -lt 0)
    $missingWrite = (-not $wrote -and -not $optOut)
    $late = (-not $missingRead -and $firstRead -gt $firstEdit)
    if (-not $missingRead -and -not $missingWrite -and -not $late) { exit 0 }

    # Once per (session, outcome): an unchanged answer stays silent on repeat Stops.
    $fingerprint = Get-ShortHash ($sessionId + '|' + [string]$missingRead + '|' + [string]$missingWrite + '|' + [string]$late)
    $gatePath = Join-Path $stateDir ('SynapseRulesCheck-gate-' + $projectKey + '.txt')
    try { if ([IO.File]::Exists($gatePath) -and ([IO.File]::ReadAllText($gatePath).Trim()) -eq $fingerprint) { exit 0 } } catch { }
    try { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null; [IO.File]::WriteAllText($gatePath, $fingerprint) } catch { }

    if (-not $missingRead -and -not $missingWrite) {
        $emit = Write-HookResult -EventName $eventName -Kind 'advisory' -Message ('Synapse-Rules-Check: read after first of ' + [string]$editCount + ' edits. Next session: memory_digest first.')
        exit $emit.ExitCode
    }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('SYNAPSE RULES CHECK: ' + [string]$editCount + ' project edits.')
    if ($missingRead) { [void]$lines.Add('Read duty: no memory_digest/memory_retrieve. Run `memory_digest` with `tokenBudget`, check matches.') }
    if ($missingWrite) { [void]$lines.Add('Write duty: no memory_write. Save durable facts/decisions (entityKey + project tag; no secrets), or end with `Synapse: none - <reason>`.') }
    $emit = Write-StopBlockResult -HookInput $hookInput -HookName 'Synapse-Rules-Check' -FindingFingerprint $fingerprint -EventName $eventName -Message ($lines.ToArray() -join "`n") -Condition 'required-workflow'
    exit $emit.ExitCode
}
catch { if ($null -ne $gateReceipt) { $gateReceipt.Crashed = $true }; throw }
finally { if ($null -ne $gateReceipt) { Complete-StopGateReceipt $gateReceipt } }
