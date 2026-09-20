# Shared helpers for Hook Maker's shipped hooks. Each hook dot-sources this
# once ( . (Join-Path $PSScriptRoot '..\_hooklib.ps1') ) so the identical
# stdin / .env / hash / JSON boilerplate lives in exactly one place. The
# underscore prefix keeps it out of the wizard's hook discovery
# (Get-HookEntries skips '_'-prefixed names). StrictMode 2.0 clean; every
# function is self-contained so it works from any host or scope.

# Hook I/O is UTF-8 BY CONTRACT: Claude Code and Codex hand the event JSON to the
# hook as UTF-8 and read its output back as UTF-8. [Console]::In / ::Out do NOT
# honour that on their own - they decode with the CONSOLE code page, and a hook
# process that has no attached console (a GUI-hosted client, or any parent that
# spawns it with CreateNoWindow + redirected pipes) reports the machine's OEM
# page instead. Measured on this repo: such a child sees ibm437, so a prompt of
# 'معماری پروژه' arrives as box-drawing characters and every relevance regex,
# path, and filename containing non-ASCII silently misses.
#
# Pin BOTH directions explicitly rather than trusting the ambient page - the same
# fix Cross-Project-.ai-Knowledge-Sync already carries, which is exactly why that
# one hook was never affected. Each setter is guarded on its own: a host that
# refuses one must not cost us the other, and a hook must never die over this.
# This runs at dot-source time, before any hook reads stdin, so [Console]::In is
# materialised with the encoding already corrected.
$Utf8NoBomIo = [System.Text.UTF8Encoding]::new($false)
try { [Console]::InputEncoding = $Utf8NoBomIo } catch { }
try { [Console]::OutputEncoding = $Utf8NoBomIo } catch { }
try { $OutputEncoding = $Utf8NoBomIo } catch { }

# Field accessor tolerant of a missing property or a $null value.
function Get-Field {
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) {
        return $Obj.$Name
    }
    return $null
}

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $full = [System.IO.Path]::GetFullPath($expanded)
    return $full.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $candidatePath = Normalize-Path $Candidate
    $parentPath = Normalize-Path $Parent
    if ([string]::Equals($candidatePath, $parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $parentPath + [System.IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# A directory identified by what it CONTAINS, not by what it is called. Names are
# a convention: `python -m venv <anything>` is legal, so a virtualenv called
# 'spotdl-env' is invisible to a name list - a real one held 9,817 of a 13,562
# entry walk. The markers are authoritative instead:
#
#   pyvenv.cfg    PEP 405 puts it at the root of every virtualenv, any folder name.
#   CACHEDIR.TAG  the cross-tool "this directory is a regenerable cache" standard
#                 (Bazel, Cargo, borg, restic, rsnapshot...), which is exactly the
#                 class every walk here wants to skip.
#
# Deliberately NOT extended to '.git' or 'node_modules': those names are fixed by
# their own tools and cannot be renamed, so the name lists already catch them and
# a marker probe would only add a stat.
#
# A REPARSE POINT IS NEVER PROBED. Following a junction would stat outside the
# scanned tree, which every caller here promises not to do; callers skip links by
# their own rule immediately afterwards, so refusing here changes no outcome.
#
# Never throws - an invalid, too-long or unreadable path is simply $false, so a
# walk can never break here.
$script:PruneMarkerFiles = @('pyvenv.cfg', 'CACHEDIR.TAG')

function Test-IsMarkerPrunedDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    catch { return $false }
    foreach ($marker in $script:PruneMarkerFiles) {
        try { if ([System.IO.File]::Exists([System.IO.Path]::Combine($Path, $marker))) { return $true } }
        catch { }
    }
    return $false
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

# Reads the hook event JSON from stdin. Returns the parsed object, or $null when
# stdin carried nothing usable - genuinely empty, or bytes that are not JSON.
# Both mean the same thing to a hook: there is no event to act on.
function Read-HookInput {
    $parsed = $null
    try {
        $raw = [Console]::In.ReadToEnd()
        # A leading U+FEFF is a byte-order mark, not payload: a client that
        # writes UTF-8-with-BOM stdin (and any .NET Framework parent, whose
        # StreamWriter emits the encoding preamble into a redirected child
        # stdin) delivers it as the first character. pwsh 7's ConvertFrom-Json
        # tolerates it; Windows PowerShell 5.1's THROWS on it - so without this
        # trim the same healthy payload parses on one host and reads as
        # "corrupt" on the other. Semantically empty, so stripping is lossless.
        if ($null -ne $raw) { $raw = $raw.TrimStart([char]0xFEFF) }
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $parsed = ($raw | ConvertFrom-Json) }
    }
    catch { $parsed = $null }
    # THE TASK BOUNDARY IS MINTED HERE, and nowhere else. Every hook of every
    # client passes through this function on every event, so one call covers the
    # whole set without eighteen call sites to keep in step - and the write is
    # idempotent, so the first hook of a dispatch mints the task and the rest
    # read it back. Silent by contract: a hook must never fail because identity
    # bookkeeping could not be written (_taskidentity.ps1 explains why).
    if ($null -ne $parsed -and $script:TaskIdentityReady) {
        try { Register-UserTaskBoundary -HookInput $parsed } catch { }
    }
    return $parsed
}

# The clients a hook runtime can be running under.
#
# This duplicates the id list in scripts\_clientcapability.ps1, and that is
# structurally forced rather than an oversight: an installed runtime is
# self-contained, and the installer rewrites THIS file into each runtime but
# does not copy sibling files from scripts\. So the list cannot be shared by
# dot-sourcing. Test-ContextHooks asserts the two lists are identical, which is
# how the duplication is kept honest.
$script:HookClientIds = @('claude', 'codex')

# Which client is running this hook.
#
# Resolution order, and why:
#   1. An EXPLICIT id always wins - a caller that already knows which client it
#      is speaking for must not be overruled by a heuristic. An explicit id that
#      is NOT a known client returns 'unknown' rather than falling through to a
#      guess, because a wrong confident answer is worse than an admitted unknown.
#   2. CLAUDE_PROJECT_DIR is Claude's own documented signal - a positive test,
#      not an absence.
#   3. Codex remains the default ONLY for a runtime carrying no explicit id.
#      That is the pre-existing behaviour for every Claude/Codex install made
#      before this function existed, and preserving it is deliberate: changing
#      it would silently break working Codex installs.
function Get-HookClientId {
    param([string]$Explicit = '')
    $candidate = $Explicit
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = [string]$env:HOOKMAKER_CLIENT }
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $normalized = $candidate.Trim().ToLowerInvariant()
        if ($script:HookClientIds -contains $normalized) { return $normalized }
        return 'unknown'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) { return 'claude' }
    return 'codex'
}

# Which events each client documents a REAL block/deny mechanism for.
#
# This mirrors blockCapableEvents in scripts\_clientcapability.ps1, and it is
# duplicated for the same structural reason $script:HookClientIds is: an
# installed runtime is self-contained, the installer rewrites THIS file into it
# but copies no sibling from scripts\, so the table cannot be shared by
# dot-sourcing. Test-ContextHooks asserts this mirror agrees with
# Test-HookMakerEventBlocking for every client/event pair, which is how the
# duplication is kept honest.
$script:HookBlockCapableEvents = @{
    'claude' = @('UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop', 'PreCompact', 'PermissionRequest')
    'codex'  = @('UserPromptSubmit', 'PreToolUse', 'Stop', 'SubagentStop')
}

# The ONLY events where Codex takes systemMessage instead of
# hookSpecificOutput.additionalContext. Codex does not document
# additionalContext/hookSpecificOutput for Stop, but it honours them everywhere
# else - so this is a Stop-scoped exception, not a Codex-wide output shape.
# Getting that backwards silently rewrites every pre-task hook's Codex output.
$script:HookCodexSystemMessageEvents = @('Stop', 'SubagentStop')

# The ONE place a semantic hook result becomes a client-specific output shape.
#
# Kinds:
#   silent   - write nothing at all.
#   context  - model-visible context injection.
#   advisory - a non-blocking notice to the user/agent.
#   block    - a real gate decision, carrying a reason.
#
# Shapes, byte-for-byte identical to what the shipped hooks already emit. The
# JSON is deliberately built from the SAME plain @{} literals with the same
# ConvertTo-Json flags: a plain hashtable serialises its keys in a HOST-decided
# order (pwsh 7 and Windows PowerShell 5.1 disagree on hookSpecificOutput), so
# reproducing the existing bytes on both hosts means reproducing the existing
# construct. [ordered]@{} would be stable but would NOT match pwsh 7's output.
#   claude       context/advisory -> hookSpecificOutput.{hookEventName,additionalContext}
#   codex        context/advisory -> systemMessage (Codex documents no model-visible Stop context)
#   claude/codex block            -> {decision:'block', reason} - the shape every
#                                    existing block site emits for both clients
#   unknown      -> nothing at all, reported. Never guess a shape.
#
# A block on an event the client cannot block is DOWNGRADED to the strongest
# available advisory and reported - never emitted as a fake gate.
#
# Returns @{ Emitted; Shape; ExitCode; Degraded; DegradedReason } so a caller can
# honestly record 'degraded-stop-gate' instead of claiming enforcement it did not
# get. ExitCode is what the CALLER must exit with (0 everywhere except a Codex
# deny, which needs 2); this function never exits on its own.
function Write-HookResult {
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][ValidateSet('context', 'advisory', 'block', 'silent', 'deny', 'allow')][string]$Kind,
        [string]$Message = '',
        [string]$Reason = '',
        [string]$Client = ''
    )
    $emitted = $false
    $shape = 'none'
    $exitCode = 0
    $degradedParts = @()

    if ($Kind -ne 'silent') {
        # 'block' names its payload Reason and context/advisory name it Message;
        # accept either so a call site keeps the vocabulary it already uses.
        $text = $Message
        if ($Kind -eq 'block') { $text = $Reason }
        if ([string]::IsNullOrWhiteSpace($text)) { $text = $(if ($Kind -eq 'block') { $Message } else { $Reason }) }

        $clientId = Get-HookClientId -Explicit $Client

        # ---- the PreToolUse PERMISSION mechanism -------------------------
        # 'deny'/'allow' are NOT 'block'/'advisory' with a different name. A
        # PreToolUse permission decision is a separate documented mechanism:
        # Claude answers with permissionDecision, and Codex has no
        # permissionDecision at all - it denies by exiting 2 with the reason on
        # stderr. Folding them into 'block' would emit decision:block, which is
        # NOT how a Claude tool call is refused.
        #
        # Both branches reproduce the existing shipped bytes EXACTLY, including
        # the second top-level systemMessage key and Codex's systemMessage
        # payload. That Codex payload is deliberately NOT changed to
        # additionalContext: unlike a context emission, this pairs with exit 2,
        # and nothing in the sources documents the context shape as correct for
        # a refusal.
        if ($Kind -eq 'deny' -or $Kind -eq 'allow') {
            # These two guards are duplicated from the common path below on
            # purpose: this branch returns early, so it would otherwise fall
            # into the non-claude arm and emit a Codex-shaped refusal for an
            # UNKNOWN client - exactly the guessing this function exists to
            # prevent - or emit an empty reason.
            if ($clientId -eq 'unknown') {
                $degradedParts += 'the client is unknown and no output shape is documented for it, so nothing was emitted'
            }
            elseif ([string]::IsNullOrWhiteSpace($text)) {
                $degradedParts += ('no ' + $Kind + ' text was supplied, so nothing was emitted')
            }
            else {
                $decision = $(if ($Kind -eq 'deny') { 'deny' } else { 'allow' })
                if ($clientId -eq 'claude') {
                    $permissionPayload = @{
                        hookSpecificOutput = @{
                            hookEventName            = $EventName
                            permissionDecision       = $decision
                            permissionDecisionReason = $text
                        }
                        systemMessage      = $text
                    }
                    [Console]::Out.WriteLine(($permissionPayload | ConvertTo-Json -Depth 6 -Compress))
                    $emitted = $true; $shape = ('claudePermission' + $decision)
                }
                else {
                    [Console]::Out.WriteLine((@{ systemMessage = $text } | ConvertTo-Json -Depth 6 -Compress))
                    $emitted = $true; $shape = ('codexPermission' + $decision)
                    if ($Kind -eq 'deny') {
                        [Console]::Error.WriteLine($text)
                        $exitCode = 2
                    }
                }
            }
            return [pscustomobject]@{
                Emitted        = $emitted
                Shape          = $shape
                ExitCode       = $exitCode
                Degraded       = ($degradedParts.Count -gt 0)
                DegradedReason = ($degradedParts -join '; ')
            }
        }

        if ($clientId -eq 'unknown') {
            $degradedParts += 'the client is unknown and no output shape is documented for it, so nothing was emitted'
        }
        elseif ([string]::IsNullOrWhiteSpace($text)) {
            $degradedParts += ('no ' + $Kind + ' text was supplied, so nothing was emitted')
        }
        else {
            $effectiveKind = $Kind
            if ($Kind -eq 'block') {
                $blockable = $script:HookBlockCapableEvents.ContainsKey($clientId) -and
                    (@($script:HookBlockCapableEvents[$clientId] | Where-Object { $_ -ceq $EventName }).Count -gt 0)
                if (-not $blockable) {
                    $effectiveKind = 'advisory'
                    $degradedParts += ($clientId + ' documents no block mechanism on ' + $EventName +
                        '; downgraded to the strongest available advisory - this is NOT an enforced gate')
                }
            }
            if ($effectiveKind -eq 'block') {
                $payload = @{ decision = 'block'; reason = $text }
                $shape = 'decisionBlock'
            }
            elseif ($EventName -in @('Stop', 'SubagentStop')) {
                $payload = @{ systemMessage = $text }
                $shape = $clientId + 'SystemMessage'
            }
            elseif ($clientId -eq 'claude') {
                $payload = @{ hookSpecificOutput = @{ hookEventName = $EventName; additionalContext = $text } }
                $shape = 'claudeContext'
            }
            elseif (@($script:HookCodexSystemMessageEvents | Where-Object { $_ -ceq $EventName }).Count -gt 0) {
                # Codex Stop/SubagentStop ONLY. Codex does not document
                # additionalContext/hookSpecificOutput for Stop at all, so
                # systemMessage is the only common field there.
                $payload = @{ systemMessage = $text }
                $shape = 'codexSystemMessage'
            }
            else {
                # Codex on every OTHER event honours additionalContext, and
                # every shipped pre-task hook already emits exactly this -
                # verified in an earlier round as correct, NOT a bug.
                #
                # This branch used to be a bare else, so Codex got
                # systemMessage everywhere. Wiring the shipped hooks onto
                # this adapter with that in place would have silently
                # changed Codex output at ~47 call sites and dropped the
                # event name Claude's shape carries. The systemMessage rule
                # is Stop-scoped; it is not a Codex-wide rule.
                $payload = @{ hookSpecificOutput = @{ hookEventName = $EventName; additionalContext = $text } }
                $shape = 'codexContext'
            }
            [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 5 -Compress))
            $emitted = $true
        }
    }

    return [pscustomobject]@{
        Emitted        = $emitted
        Shape          = $shape
        ExitCode       = $exitCode
        Degraded       = ($degradedParts.Count -gt 0)
        DegradedReason = ($degradedParts -join '; ')
    }
}

# Parses a KEY=VALUE .env file ('#' comments allowed). Returns a hashtable;
# empty when the file is absent or blank.
function Read-HookEnv {
    param([string]$Path)
    $values = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -gt 0) {
            $values[$trimmed.Substring(0, $separator).Trim()] = $trimmed.Substring($separator + 1).Trim()
        }
    }
    return $values
}

# 10-char lowercase hex SHA-256 prefix — stable per-project state file keys.
function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant().Substring(0, 10)
    }
    finally {
        $sha.Dispose()
    }
}

# Reads a JSON file into an object, or $null when absent / blank.
function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

# Writes an object as UTF-8 (no BOM) JSON via a temp file + atomic move.
function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    # A directory occupying the target would fail the publish below in a way
    # the caller cannot tell apart from a write error.
    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw ('Cannot write JSON over a directory: ' + $Path)
    }
    # Each writer owns ITS OWN temporary. The shared '<target>.tmp' let two
    # unlocked concurrent writers trade bytes: A wrote its temp, B overwrote
    # that same file, A published B's bytes as its own, and B's publish then
    # failed on a file A had already moved away. Nothing reported an error.
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 50
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        # Only ever this writer's own temporary, never another writer's.
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- sections this library is split across ---------------------------------
#
# Loaded the same OPTIONAL way as the siblings below, and for the same reason:
# a runtime copied before one of these existed keeps working instead of failing
# to start. Every hook in every project loads this file, so a hard requirement
# here would take all of them down at once rather than degrade one capability.
#
# What each carries: the READ side of the rolling timing history; the Codebase
# Memory MCP helpers; and the Claude Code transcript reader. None of the three
# is reached before this point in the file, and only the timing section owns
# any $script: state - which moves with it.
foreach ($hookLibSection in @('_timingread.ps1', '_cbm.ps1', '_transcript.ps1')) {
    $hookLibSectionPath = Join-Path $PSScriptRoot $hookLibSection
    if (Test-Path -LiteralPath $hookLibSectionPath -PathType Leaf) { . $hookLibSectionPath }
}

# ---- Stop re-entry: whose block was it? ------------------------------------
# `stop_hook_active` means "a Stop hook blocked and the agent is coming back",
# NOT "YOU blocked". Many gates share that one flag, so a gate that exits on it
# alone stands down for somebody ELSE's block - measured, not theory: it is why
# a missing "Skills used:" line could wave a real secret leak through.
#
# Stand down only on ITS OWN re-entry, and only while the chain's shared
# correction budget lasts. The identity that decides "its own", the budget and
# _processtree.ps1 owns terminating an owned process tree: one bounded query
# instead of one per level, an identity check so a recycled id is not taken for
# a descendant, and a verdict. Optional like the siblings below; without it a
# runtime falls back to killing the root alone, which is all it managed before.
$processTreePath = Join-Path $PSScriptRoot '_processtree.ps1'
if (Test-Path -LiteralPath $processTreePath -PathType Leaf) { . $processTreePath }
else { function Stop-ProcessTree { param([int]$ProcessId, [int]$TimeoutMilliseconds = 0, [object]$RootCreated = $null) if ($ProcessId -ne $PID) { try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { } } } }

# the atomic claim live in _stoplib.ps1, which owns that design and records why
# one file per project+hook was the original defect. Gates only, never advisory
# hooks. _stoplib.ps1 loads OPTIONALLY so a runtime copied before it existed
# keeps the single-marker fallback below instead of failing to start.
$script:StopLedgerReady = $false
try {
    $stopLibPath = Join-Path $PSScriptRoot '_stoplib.ps1'
    if (Test-Path -LiteralPath $stopLibPath -PathType Leaf) { . $stopLibPath; $script:StopLedgerReady = $true }
}
catch { $script:StopLedgerReady = $false }

# _evidencelib.ps1 loads the same way and for the same reason: what a closing
# declaration has to contain before it counts as a claim is its own
# responsibility, and a runtime copied before it existed must degrade rather
# than fail to start. A gate checks $script:EvidenceLibReady before relying on
# it and keeps its older prefix test otherwise.
$script:EvidenceLibReady = $false
try {
    $evidenceLibPath = Join-Path $PSScriptRoot '_evidencelib.ps1'
    if (Test-Path -LiteralPath $evidenceLibPath -PathType Leaf) { . $evidenceLibPath; $script:EvidenceLibReady = $true }
}
catch { $script:EvidenceLibReady = $false }

# _taskidentity.ps1 owns WHICH USER TASK an event belongs to - the durable
# lifecycle boundary that replaced deriving identity from transcript statistics.
# Optional for the same reason as the two above: a runtime copied before it
# existed keeps the older derivation, which _stoplib.ps1 still carries as its
# bounded degraded path.
$script:TaskIdentityReady = $false
try {
    $taskIdentityPath = Join-Path $PSScriptRoot '_taskidentity.ps1'
    if (Test-Path -LiteralPath $taskIdentityPath -PathType Leaf) { . $taskIdentityPath; $script:TaskIdentityReady = $true }
}
catch { $script:TaskIdentityReady = $false }

function Test-StopStandDown {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$HookName)
    $stopActive = Get-Field $HookInput 'stop_hook_active'
    $isContinuation = ($null -ne $stopActive -and [bool]$stopActive)
    if ($script:StopLedgerReady) {
        return (Test-StopStandDownLedger -HookInput $HookInput -HookName $HookName -IsContinuation $isContinuation)
    }
    if (-not $isContinuation) { return $false }
    $markerPath = Get-StopBlockMarkerPath -HookName $HookName -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try {
        $recorded = ([System.IO.File]::ReadAllText($markerPath)).Trim()
        return ($recorded -ne '' -and $recorded -eq [string](Get-Field $HookInput 'session_id'))
    }
    catch { return $false }
}

# Called by a gate immediately before it blocks, so its own next re-entry is
# recognised and the chain's shared budget is spent.
# Claim the right to emit ONE continuation, and record the block that spends it.
#
# RETURNS A DECISION THE CALLER MUST CONSUME: emit the block only when
# .Admitted is $true. It used to return nothing, so a failed registration was
# indistinguishable from a successful one and the gate blocked anyway - which is
# exactly how an untracked continuation storm starts. .Reason says which refusal
# it was (already-claimed, budget-spent, persistence-failed, busy) and .Degraded
# marks the ones caused by the ledger being unusable rather than by policy.
function Set-StopBlockMarker {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        # What this gate is refusing about. Empty from a caller that does not
        # compute one, which keeps the older duplicate rule exactly as it was.
        [AllowEmptyString()][string]$FindingFingerprint = ''
    )
    $stopActive = Get-Field $HookInput 'stop_hook_active'
    if ($script:StopLedgerReady) {
        return (Register-StopBlockLedger -HookInput $HookInput -HookName $HookName -IsContinuation ($null -ne $stopActive -and [bool]$stopActive) -FindingFingerprint $FindingFingerprint)
    }
    # LEGACY RUNTIME, no _stoplib.ps1 beside this file. The single marker cannot
    # express a budget, so it cannot promise one either: admission is reported as
    # degraded, and the write failing is reported rather than swallowed.
    $markerPath = Get-StopBlockMarkerPath -HookName $HookName -ProjectRoot ([string](Get-Field $HookInput 'cwd'))
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($markerPath, [string](Get-Field $HookInput 'session_id'))
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'marker not written' }
        return [pscustomobject]@{ Admitted = $true; Reason = 'legacy-marker'; Degraded = $true }
    }
    catch {
        return [pscustomobject]@{ Admitted = $false; Reason = 'persistence-failed'; Degraded = $true }
    }
}

# The identity a hook's OWN "I already said this" fingerprint must carry.
#
# A fingerprint keyed on the session alone leaks across task boundaries: the
# same missing requirement on the NEXT genuine task reads the previous task's
# stamp and stays silent, and a parent and its subagent share one slot. Session
# plus agent plus the current continuation chain separates all three.
#
# Degrades to session+agent on a runtime with no ledger beside it - narrower
# than before, never wider.
function Get-HookSuppressionIdentity {
    param([Parameter(Mandatory = $true)]$HookInput)
    if ($script:StopLedgerReady) { return (Get-StopSuppressionIdentity -HookInput $HookInput) }
    return ([string](Get-Field $HookInput 'session_id') + '|main|')
}

# Claim admission and emit the block in ONE step, so no gate can emit a
# continuation it was not admitted for. That pairing used to be the caller's to
# remember, and every caller forgot it: the marker was written, its result
# dropped, and the block emitted regardless.
#
# A REFUSAL EMITS NOTHING. The finding is already recorded as unresolved in the
# ledger, and forcing another answer once the shared allowance is spent is the
# loop this whole mechanism exists to stop. .Emitted says which happened, so a
# caller that needs to know can tell a refusal from a delivered block.
function Write-StopBlockResult {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName,
        [Parameter(Mandatory = $true)][string]$EventName,
        [AllowEmptyString()][string]$Reason = '',
        [AllowEmptyString()][string]$Message = '',
        [AllowEmptyString()][string]$FindingFingerprint = ''
    )
    # The TEXT is composed before admission, because the text IS the finding: a
    # gate that refuses for a different reason is making a different claim and
    # must be allowed to make it, while the same words twice in one task are the
    # same request repeated. Composed without the finalization clause below, so
    # a clause that varies cannot make an unchanged finding look new.
    $text = $Reason
    if ([string]::IsNullOrEmpty($text)) { $text = $Message }
    if ([string]::IsNullOrWhiteSpace($text) -or (Get-HookClientId) -eq 'unknown') {
        return [pscustomobject]@{ ExitCode = 0; Emitted = $false; Admission = $null }
    }
    # Prefer the detector's semantic evidence identity. Equal message text is
    # not equal evidence: another edit can change bytes behind one dirty path.
    $finding = $FindingFingerprint
    if ([string]::IsNullOrWhiteSpace($finding)) { $finding = Get-ShortHash ($HookName + '|' + $text) }
    $admit = Set-StopBlockMarker -HookInput $HookInput -HookName $HookName -FindingFingerprint $finding
    if ($null -eq $admit -or -not $admit.Admitted) {
        if ($null -ne $admit -and $admit.Reason -ne 'already-claimed') {
            $notice = 'Hook Maker stopped automatic corrections (' + $admit.Reason + '). This finding is NOT resolved: ' + $text
            [Console]::Out.WriteLine((@{ continue = $false; stopReason = $notice; systemMessage = $notice } | ConvertTo-Json -Compress))
            return [pscustomobject]@{ ExitCode = 0; Emitted = $true; Admission = $admit }
        }
        return [pscustomobject]@{ ExitCode = 0; Emitted = $false; Admission = $admit }
    }
    if (-not $script:StopLedgerReady) {
        $notice = 'Hook Maker requires its installed Stop library to continue safely. Repair this runtime. Unresolved: ' + $text
        [Console]::Out.WriteLine((@{ continue = $false; stopReason = $notice; systemMessage = $notice } | ConvertTo-Json -Compress))
        return [pscustomobject]@{ ExitCode = 0; Emitted = $true; Admission = $admit; Degraded = $true }
    }
    # EVERY block carries the finalization clause, because every block is the
    # thing that turns one wrap-up into three: the agent answers, a gate sends it
    # back, it corrects, it writes another wrap-up, the next gate sends it back
    # again. The gate that interrupted is the only component that knows this is a
    # correction turn, so it is the one that has to say so.
    if ($script:StopLedgerReady) {
        try {
            $clause = Get-StopFinalizationClause -HookInput $HookInput
            if (-not [string]::IsNullOrWhiteSpace($clause)) { $text = $text + "`n" + $clause }
        }
        catch { }
    }
    # The text about to be emitted is recorded as this task's, so a client that
    # replays a refusal as the next user prompt (Codex does) is recognised as the
    # continuation it is rather than minting a task and refilling the allowance.
    if ($script:TaskIdentityReady) {
        $identity = Get-CurrentUserTaskIdentity -HookInput $HookInput
        if (-not $identity.Degraded) {
            $receipt = Register-TaskContinuation -HookInput $HookInput -Reason $text
            if (-not $receipt.Ok) {
                $notice = 'Hook Maker could not durably record the correction; completion is unverified. ' + $text
                [Console]::Out.WriteLine((@{ continue = $false; stopReason = $notice; systemMessage = $notice } | ConvertTo-Json -Compress))
                return [pscustomobject]@{ ExitCode = 0; Emitted = $true; Admission = $admit; Degraded = $true }
            }
            $text = $receipt.Text
        }
    }
    $emit = Write-HookResult -EventName $EventName -Kind 'block' -Reason $text -Message $text
    return [pscustomobject]@{ ExitCode = $emit.ExitCode; Emitted = $emit.Emitted; Admission = $admit }
}

# The fallback marker path, used by a runtime with no _stoplib.ps1 beside it.
function Get-StopBlockMarkerPath {
    param([Parameter(Mandatory = $true)][string]$HookName, [AllowEmptyString()][string]$ProjectRoot = '')
    $projectKey = Get-ShortHash ([string]$ProjectRoot).ToLowerInvariant()
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($HookName, '[^A-Za-z0-9]+', '')
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('StopBlock-' + $safeName + '-' + $projectKey + '.txt'))
}

# ---- shared prompt relevance ------------------------------------------------
# "Does this prompt need codebase-WIDE understanding?" - one definition for
# every hook that asks it, so a graph hook and a CBM hook can never disagree
# about whether the same prompt was structural. Lives here rather than in one
# hook because the second caller is what makes a shared definition necessary;
# the patterns are byte-for-byte the ones Graph-Read-Check used alone.
#
# Persian terms are \uXXXX escapes so the source stays ASCII. Whole meaningful
# terms/phrases only, conservative, so a lone common word never triggers. One
# alternative per request class, in order: architecture, structure, dependency,
# invocation / call path, "calling", "where used", impact (hamza + plain
# spelling), module, relation, entry point, rewrite, refactor, codebase,
# "whole project", "whole repo". \s+ tolerates any spacing inside phrases.
function Test-CodebaseStructurePrompt {
    param([string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return $false }
    if ($Prompt -match '(?i)\b(architecture|refactor|cross-file|cross file|call path|call graph|dependenc|where is|used by|impact|structure|entry point|module|integrat|codebase|call site|caller|callers|inherit)') { return $true }
    $persianPattern = @(
        '\u0645\u0639\u0645\u0627\u0631\u06cc',                             # architecture (memari)
        '\u0633\u0627\u062e\u062a\u0627\u0631',                             # structure (sakhtar)
        '\u0648\u0627\u0628\u0633\u062a\u06af\u06cc',                       # dependency (vabastegi)
        '\u0641\u0631\u0627\u062e\u0648\u0627\u0646\u06cc',                 # invocation / call path (farakhani)
        '\u0635\u062f\u0627\s+\u0632\u062f\u0646',                          # calling (seda zadan)
        '\u06a9\u062c\u0627\s+\u0627\u0633\u062a\u0641\u0627\u062f\u0647',   # where used (koja estefade)
        '\u062a\u0623\u062b\u06cc\u0631',                                   # impact - hamza (ta'sir)
        '\u062a\u0627\u062b\u06cc\u0631',                                   # impact - plain (tasir)
        '\u0645\u0627\u0698\u0648\u0644',                                   # module (mazhul)
        '\u0627\u0631\u062a\u0628\u0627\u0637',                             # relation (ertebat)
        '\u0646\u0642\u0637\u0647\s+\u0648\u0631\u0648\u062f',              # entry point (noghte-ye vorud)
        '\u0628\u0627\u0632\u0646\u0648\u06cc\u0633\u06cc',                 # rewrite (baznevisi)
        '\u0631\u06cc\u0641\u06a9\u062a\u0648\u0631',                       # refactor (refaktor)
        '\u06a9\u062f\u0628\u06cc\u0633',                                   # codebase
        '\u06a9\u0644\s+\u067e\u0631\u0648\u0698\u0647',                    # whole project (kol-e proje)
        '\u06a9\u0644\s+\u0645\u062e\u0632\u0646'                           # whole repo (kol-e makhzan)
    ) -join '|'
    return ($Prompt -match $persianPattern)
}
