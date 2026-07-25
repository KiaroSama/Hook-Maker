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

# Reads the hook event JSON from stdin. Returns the parsed object, or $null on
# empty / non-JSON input (the caller then exits silently).
#
# On Kiro it also NORMALIZES, and without that every hook is dead on arrival:
# Kiro IDE documents no stdin JSON at all (only USER_PROMPT, and only on
# UserPromptSubmit), so stdin is empty, this returned $null, and all 23 hooks
# took their `if ($null -eq $hookInput) { exit 0 }` path and did nothing. The
# installed Kiro launcher supplies the one thing that cannot be recovered from
# an empty stdin - which trigger fired - and the rest is read from the process.
#
# Deliberately NOT synthesized (see .ai/KIRO_PROTOCOL.md):
#   * session_id - inventing a persistent identity would silently mispair
#     session-keyed baselines. Absent means session-dependent dedup disables
#     itself, which is the documented degradation.
#   * stop_hook_active - absent reads as $false, the correct default; a
#     fabricated $true would suppress the hook entirely.
#   * tool_name / tool_input - Kiro documents no channel for them.
function Read-HookInput {
    $parsed = $null
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = ($raw | ConvertFrom-Json)
        }
    }
    catch { $parsed = $null }

    if ((Get-HookClientId) -cne 'kiro') { return $parsed }

    # Trust boundary: the trigger arrives through the environment, so it is
    # accepted ONLY when it is one of the events Kiro actually documents. An
    # unrecognized value is dropped rather than passed to hooks as an event
    # name, which would let anything that can set an env var choose the
    # code path a hook takes.
    $kiroTrigger = ''
    $rawTrigger = [string]$env:HOOKMAKER_KIRO_TRIGGER
    if (-not [string]::IsNullOrWhiteSpace($rawTrigger)) {
        $match = @($script:HookKiroTriggers | Where-Object { $_ -ceq $rawTrigger.Trim() })
        if ($match.Count -gt 0) { $kiroTrigger = $match[0] }
    }
    if ([string]::IsNullOrWhiteSpace($kiroTrigger)) { return $parsed }

    if ($null -eq $parsed) {
        # cwd from the process, canonicalized. Kiro launches the hook in the
        # workspace directory; there is no documented cwd field to read.
        $kiroCwd = ''
        try { $kiroCwd = [System.IO.Path]::GetFullPath((Get-Location).Path) } catch { $kiroCwd = '' }
        $synthesized = [pscustomobject]@{ hook_event_name = $kiroTrigger }
        if (-not [string]::IsNullOrWhiteSpace($kiroCwd)) {
            Set-ObjectProperty -Object $synthesized -Name 'cwd' -Value $kiroCwd
        }
        return $synthesized
    }

    # CLI v3 does send stdin JSON, but its field names/casing are not
    # re-published, so a payload may arrive without a usable event name. Fill
    # that in WITHOUT overwriting one the client did send - a real payload
    # always wins over the launcher's argument.
    if ([string]::IsNullOrWhiteSpace([string](Get-Field $parsed 'hook_event_name'))) {
        Set-ObjectProperty -Object $parsed -Name 'hook_event_name' -Value $kiroTrigger
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
$script:HookClientIds = @('claude', 'codex', 'kiro')

# Which client is running this hook.
#
# Hooks used to decide this inline as
#   CLAUDE_PROJECT_DIR present -> Claude, otherwise -> Codex
# which was fine while Codex was the only other client and becomes wrong the
# moment a third one exists: Kiro would be handed Codex's rules, skills, paths
# and output protocol with nothing reporting a problem.
#
# Resolution order, and why:
#   1. An EXPLICIT id always wins. Kiro is identified this way because Kiro IDE
#      documents no hook input at all beyond USER_PROMPT - there is nothing to
#      infer from - so its generated command carries the id. That costs no
#      compatibility: Kiro installs are new, so no existing command text or
#      ownership hash changes. An explicit id that is NOT a known client returns
#      'unknown' rather than falling through to a guess, because a wrong
#      confident answer is worse than an admitted unknown.
#   2. CLAUDE_PROJECT_DIR is Claude's own documented signal - a positive test,
#      not an absence.
#   3. Codex remains the default ONLY for a runtime carrying no explicit id.
#      That is the pre-existing behaviour for every Claude/Codex install made
#      before this function existed, and preserving it is deliberate: changing
#      it would silently break working Codex installs to satisfy a rule aimed at
#      a client that always identifies itself explicitly anyway.
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
    'kiro'   = @('PreToolUse', 'UserPromptSubmit')
}

# Kiro adds hook stdout to the model's context ONLY on these triggers; on every
# other one stdout is read and DISCARDED (.ai/KIRO_PROTOCOL.md, exit-code
# section). Writing context anywhere else is a silent no-op, so Write-HookResult
# reports it as degraded rather than pretending it landed.
$script:HookKiroContextEvents = @('SessionStart', 'UserPromptSubmit')

# The triggers Kiro documents, mirrored from the capability table's kiro
# supportedEvents for the same self-contained-runtime reason as
# $script:HookClientIds above. Read-HookInput accepts an environment-supplied
# trigger ONLY if it appears here, so this list is a trust boundary, not just a
# lookup. Kiro's physicalEventMap is identity for all five, which is why no
# physical-to-logical translation is needed. Test-ContextHooks asserts this
# matches the capability table.
$script:HookKiroTriggers = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop')

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
#   kiro         context/advisory -> plain stdout + exit 0, but ONLY on the
#                                    triggers Kiro documents for it; elsewhere
#                                    nothing is written and the result says so
#   kiro         block            -> exit 2 with the reason on stderr, and ONLY
#                                    on a block-capable trigger
#   unknown      -> nothing at all, reported. Never guess a shape.
#
# A block on an event the client cannot block is DOWNGRADED to the strongest
# available advisory and reported - never emitted as a fake gate. Kiro Stop can
# block on neither surface Hook Maker targets, so a Kiro Stop gate is permanently
# degraded; on Stop its advisory is discarded too, so nothing is emitted at all.
#
# Returns @{ Emitted; Shape; ExitCode; Degraded; DegradedReason } so a caller can
# honestly record 'degraded-stop-gate' instead of claiming enforcement it did not
# get. ExitCode is what the CALLER must exit with (0 everywhere except a real
# Kiro block, which needs 2); this function never exits on its own.
function Write-HookResult {
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][ValidateSet('context', 'advisory', 'block', 'silent')][string]$Kind,
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
            if ($clientId -eq 'kiro') {
                if ($effectiveKind -eq 'block') {
                    [Console]::Error.WriteLine($text)    # exit 2 returns stderr to the agent
                    $emitted = $true; $shape = 'kiroExit2Stderr'; $exitCode = 2
                }
                elseif (@($script:HookKiroContextEvents | Where-Object { $_ -ceq $EventName }).Count -gt 0) {
                    [Console]::Out.WriteLine($text)
                    $emitted = $true; $shape = 'kiroStdout'
                }
                else {
                    $degradedParts += ('kiro adds hook stdout to context only on ' +
                        ($script:HookKiroContextEvents -join '/') + '; on ' + $EventName +
                        ' it is discarded, so nothing was emitted')
                }
            }
            else {
                if ($effectiveKind -eq 'block') {
                    $payload = @{ decision = 'block'; reason = $text }
                    $shape = 'decisionBlock'
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
    $temporaryPath = $Path + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

# ---- HM-07: bounded rolling test-timing history (READ side) -----------------
# Samples live ONLY in local Hook-Maker state (%LOCALAPPDATA%\HookMaker\state),
# one file per (canonical project key + command/suite fingerprint), never in the
# project. Each sample is sanitized: runId, elapsed seconds, outcome, UTC, the
# effective worker ceiling and an optional safe suite label - never an argument,
# path, prompt, secret, user name or token. The standalone guarded runner WRITES
# them (Run-Tests-Guarded.ps1); these helpers READ them so Test-Plan-Check can
# surface a baseline and Test-Completion-Check can report a meaningful regression.
# The WRITER mirrors TimingMaxSamples exactly - keep the two in lockstep.
$script:TimingMaxSamples = 30
$script:TimingMinBaseline = 5        # this many COMPARABLE ok runs before judging
$script:TimingRelFactor = 1.5        # >= 50% slower than the median, AND ...
$script:TimingAbsSeconds = 30        # ... >= 30s slower in absolute terms

function Get-TimingHistoryPath {
    param([string]$StateDir, [string]$ProjectKey, [string]$CommandFingerprint)
    return (Join-Path $StateDir ('TestTiming-' + $ProjectKey + '-' + $CommandFingerprint + '.json'))
}

# The ok-only, worker-comparable elapsed samples. A run taken with a DIFFERENT
# worker ceiling is not comparable (more workers => faster), so a worker-count
# change yields too few comparable samples rather than a false regression.
function Get-ComparableOkSeconds {
    param($History, [int]$WorkerCeiling, [string]$ExcludeRunId = '')
    $out = New-Object System.Collections.Generic.List[double]
    if ($null -eq $History -or -not $History.PSObject.Properties['samples']) { return $out }
    foreach ($s in @($History.samples)) {
        if ($null -eq $s) { continue }
        # The run being judged has already been recorded by the runner, so exclude
        # it: a run must be compared against PRIOR history, never against itself.
        if ($ExcludeRunId -ne '' -and ([string](Get-Field $s 'runId')) -eq $ExcludeRunId) { continue }
        if (([string](Get-Field $s 'outcome')) -ne 'ok') { continue }
        $wc = -1; [void][int]::TryParse([string](Get-Field $s 'workerCeiling'), [ref]$wc)
        if ($wc -ne $WorkerCeiling) { continue }
        $sec = 0.0
        if ([double]::TryParse([string](Get-Field $s 'elapsedSeconds'), [ref]$sec) -and $sec -ge 0) { [void]$out.Add($sec) }
    }
    return $out
}

function Get-Median {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    $n = $v.Count
    if ($n -eq 0) { return 0.0 }
    if ($n % 2 -eq 1) { return [double]$v[($n - 1) / 2] }
    return ([double]$v[$n / 2 - 1] + [double]$v[$n / 2]) / 2.0
}

# A meaningful regression needs enough comparable ok history AND this run being
# both >= TimingRelFactor x and >= TimingAbsSeconds slower than the ROBUST median
# (so one earlier outlier neither redefines the baseline nor gets flagged). It is
# advisory by design - the caller decides how to surface it.
function Test-TimingRegression {
    param($History, [int]$WorkerCeiling, [double]$ElapsedSeconds, [string]$ExcludeRunId = '')
    # @() around the call: returning a List[double] unrolls to a bare double when it
    # holds one element, so re-wrap to a stable array before Count/Get-Median.
    $ok = @(Get-ComparableOkSeconds -History $History -WorkerCeiling $WorkerCeiling -ExcludeRunId $ExcludeRunId)
    $median = Get-Median -Values $ok
    $isReg = $false
    if ($ok.Count -ge $script:TimingMinBaseline -and $median -gt 0) {
        if ($ElapsedSeconds -ge ($median * $script:TimingRelFactor) -and ($ElapsedSeconds - $median) -ge $script:TimingAbsSeconds) { $isReg = $true }
    }
    return [pscustomobject]@{
        IsRegression   = $isReg
        Median         = [Math]::Round($median, 1)
        Samples        = $ok.Count
        ElapsedSeconds = [Math]::Round($ElapsedSeconds, 1)
        MinBaseline    = $script:TimingMinBaseline
    }
}

# Runs an external command (git, gh, ...) whose stderr must NEVER become a
# terminating error, even when the command exits non-zero. Windows PowerShell
# 5.1 promotes ANY stderr line from a native command into a NativeCommandError
# under $ErrorActionPreference='Stop' - and, verified empirically, `2>$null`,
# `2>&1 | Out-Null`, and `*>$null` all fail to prevent that promotion under 5.1
# (pwsh 7 is unaffected, which is why this only shows up against the real
# Claude client). Only relaxing $ErrorActionPreference around the call works.
# Returns stdout lines (redirecting stderr away); $LASTEXITCODE is left intact
# for the caller exactly as a raw `&` call would leave it.
function Invoke-QuietCommand {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return & $FilePath @ArgumentList 2>$null
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Get-GitHubRepository {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $null }

    $remoteNames = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'remote') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $valid = @{}
    foreach ($remoteName in $remoteNames) {
        $url = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'remote', 'get-url', [string]$remoteName))
        if ($LASTEXITCODE -ne 0) { continue }
        if ($url -match '^(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$') {
            $valid[[string]$remoteName] = ($Matches[1] + '/' + $Matches[2])
        }
    }
    if ($valid.Count -eq 0) { return $null }

    $branchName = ''
    $branchRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', 'HEAD'))
    if ($LASTEXITCODE -eq 0 -and $branchRaw -ne '' -and $branchRaw -ne 'HEAD') { $branchName = $branchRaw }

    $branchRemote = ''
    if ($branchName -ne '') {
        $configuredRemote = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'config', '--get', ('branch.' + $branchName + '.remote')))
        if ($LASTEXITCODE -eq 0) { $branchRemote = $configuredRemote }
    }

    $selected = ''
    if ($branchRemote -ne '' -and $valid.ContainsKey($branchRemote)) { $selected = $branchRemote }
    if ($selected -eq '' -and $valid.ContainsKey('origin')) { $selected = 'origin' }
    if ($selected -eq '' -and $valid.Count -eq 1) { $selected = [string]@($valid.Keys)[0] }
    if ($selected -eq '') { return $null }

    # TrackingRef is the remote-tracking ref a caller may safely diff HEAD
    # against to decide "is HEAD pushed to the repository just selected". It is
    # populated ONLY when it is guaranteed to belong to $selected:
    # - the branch's own configured upstream, but only when that upstream's
    #   remote IS $selected (so @{upstream} cannot silently point at a
    #   different, possibly non-GitHub, remote than the repository resolved
    #   above); or
    # - a same-named remote-tracking branch under $selected, when the branch
    #   upstream doesn't match (or isn't configured at all).
    # Left empty when neither can be trusted - callers must then degrade
    # without claiming a pushed/verified state.
    $trackingRef = ''
    if ($branchName -ne '') {
        if ($branchRemote -eq $selected) {
            $upstreamRef = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', '@{upstream}'))
            if ($LASTEXITCODE -eq 0 -and $upstreamRef -ne '') { $trackingRef = $upstreamRef }
        }
        if ($trackingRef -eq '') {
            $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--verify', '--quiet', ('refs/remotes/' + $selected + '/' + $branchName))
            if ($LASTEXITCODE -eq 0) { $trackingRef = $selected + '/' + $branchName }
        }
    }

    return [pscustomobject]@{ Remote = $selected; Repository = [string]$valid[$selected]; Branch = $branchName; TrackingRef = $trackingRef }
}

# Deterministic per-project state fingerprint (HEAD sha + sorted status lines,
# hashed - never raw paths/content). Used to bind one hook's Stop-time result
# to the EXACT repository state another hook observes on a later Stop, so
# lifecycle hooks that fire concurrently on the same event (registration order
# is display-only, never execution order) can hand off state safely without
# racing: a consumer only trusts a producer's recorded state when this
# fingerprint still matches what the consumer observes right now.
function Get-RepoStateFingerprint {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return '' }
    $head = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) { return '' }
    $status = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')) | Where-Object { $_ } | Sort-Object)
    return Get-ShortHash ($head + '|' + ($status -join '|'))
}

function Get-LatestWorkTimeUtc {
    param([string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return $null
    }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') {
        return $null
    }
    $latest = [DateTime]::MinValue
    $commitUnix = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'log', '-1', '--format=%ct')
    if ($LASTEXITCODE -eq 0 -and $commitUnix) {
        $latest = [DateTimeOffset]::FromUnixTimeSeconds([int64]([string]$commitUnix)).UtcDateTime
    }
    $status = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($status)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            $lineText = [string]$line
            # A rename/copy line is "XY old -> new" (X or Y = R/C) instead of "XY path" -
            # only the destination half exists on disk. Treating the raw "old -> new" text
            # as one literal path embeds the arrow's '>' via Join-Path below, and
            # Test-Path -LiteralPath then throws on PS 5.1 ('>' is an illegal path char).
            $code = $lineText.Substring(0, 2)
            $relative = $lineText.Substring(3)
            if ($code.Contains('R') -or $code.Contains('C')) {
                $arrowIndex = $relative.IndexOf(' -> ')
                if ($arrowIndex -ge 0) { $relative = $relative.Substring($arrowIndex + 4) }
            }
            $relative = $relative.Trim('"')
            if ($relative -like '.ai/*' -or $relative -like 'graphify-out/*' -or $relative -like 'logs/*') { continue }
            try {
                $full = Join-Path $ProjectRoot ($relative.Replace('/', '\'))
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $modified = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
                    if ($modified -gt $latest) { $latest = $modified }
                }
            }
            catch { }
        }
    }
    if ($latest -eq [DateTime]::MinValue) {
        return $null
    }
    return $latest
}

# Friendly, hyphen-separated hook name. The shipped hook folders are already
# hyphenated (Cross-Project-.ai-Knowledge-Sync, Mcp-Usage-Check, ...), so this
# is a no-op for them; it still tidies a user's PascalCase custom-hook name
# (MyContextHook -> My-Context-Hook) for the menu + the installed copy folder.
function Get-HookFriendlyName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($Name, '([A-Z]+)([A-Z][a-z])', '$1-$2')
    $hyphenated = [System.Text.RegularExpressions.Regex]::Replace($hyphenated, '([a-z0-9])([A-Z])', '$1-$2')
    return $hyphenated
}
