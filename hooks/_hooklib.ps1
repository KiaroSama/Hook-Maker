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
# Runs a child process quietly and, above all, BOUNDED.
#
# This is the only place a hook starts a process, and it carries every network
# call in the hook set (gh api, gh run list, npm outdated, pip list
# --outdated, go list -u -m all). Without a deadline a single stalled request
# held the whole Stop hostage for its timeout and left the child running after
# the client gave up on the hook - the exact "terminate owned child process
# trees, leave no orphaned workers" case in global-hook-rules.md.
#
# TimeoutSeconds is a CEILING, not an expected duration: a local git call
# returns in milliseconds. On expiry the whole process TREE is killed (a
# `gh` that spawned a helper leaves nothing behind), and the caller gets $null
# with a non-zero $LASTEXITCODE - which every caller already treats as "no
# answer", so a timeout degrades to silence rather than to a wrong claim.
# Build a Win32 command line the way CommandLineToArgvW parses it back.
#
# Only Windows PowerShell 5.1 needs this - pwsh 7 has
# ProcessStartInfo.ArgumentList and does it itself. Joining arguments with
# spaces is NOT equivalent: a repo path like
#   G:\Program Files\Portable\Scripts\Hook Maker
# would arrive as four separate arguments, which is exactly the situation
# every hook here runs in.
#
# The backslash rule is the non-obvious half: a run of backslashes is
# literal UNLESS it meets a quote, where each one must be doubled. So a
# trailing separator becomes "C:\dir\\" - doubling only the
# run that collides with the closing quote.
function ConvertTo-Win32ArgumentString {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList)
    $quote = [char]34
    $slash = [char]92
    $sb = New-Object System.Text.StringBuilder
    foreach ($argument in @($ArgumentList)) {
        $text = [string]$argument
        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
        # No space, tab or quote means no quoting needed - but an EMPTY
        # argument still needs quotes or it vanishes from the command line.
        if ($text.Length -gt 0 -and -not ($text.Contains(' ') -or $text.Contains([char]9) -or $text.Contains($quote))) {
            [void]$sb.Append($text)
            continue
        }
        [void]$sb.Append($quote)
        $pending = 0
        foreach ($ch in $text.ToCharArray()) {
            if ($ch -eq $slash) { $pending++; continue }
            if ($ch -eq $quote) {
                [void]$sb.Append([string]$slash * ($pending * 2 + 1))
                $pending = 0
            }
            elseif ($pending -gt 0) {
                [void]$sb.Append([string]$slash * $pending)
                $pending = 0
            }
            [void]$sb.Append($ch)
        }
        # Trailing backslashes meet the closing quote, so they double.
        if ($pending -gt 0) { [void]$sb.Append([string]$slash * ($pending * 2)) }
        [void]$sb.Append($quote)
    }
    return $sb.ToString()
}

function Invoke-QuietCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 20
    )
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $process = $null
    $commandTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $timeoutMs = [int]([Math]::Max(1, $TimeoutSeconds) * 1000)
        # Resolve the command the way `&` did before this function was made
        # bounded. Process.Start needs a real executable IMAGE: it cannot run
        # a .ps1 or .cmd, while `&` resolved both through PATH + PATHEXT. A
        # `gh.ps1` shim on PATH is exactly the shape the test suites use, and
        # a user wrapping git/gh would have hit the same wall in production.
        $targetPath = $FilePath
        $targetArgs = @($ArgumentList)
        try {
            $resolved = @(Get-Command -Name $FilePath -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandType -eq 'Application' -or $_.CommandType -eq 'ExternalScript' })
            if ($resolved.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$resolved[0].Source)) {
                $targetPath = [string]$resolved[0].Source
                $extension = [System.IO.Path]::GetExtension($targetPath).ToLowerInvariant()
                if ($extension -eq '.ps1') {
                    # Run it on the SAME host this hook is running on, so a 5.1
                    # hook does not silently get pwsh semantics or vice versa.
                    $targetArgs = @('-NoLogo', '-NoProfile', '-File', $targetPath) + $targetArgs
                    $targetPath = [string](Get-Process -Id $PID).Path
                }
                elseif ($extension -eq '.cmd' -or $extension -eq '.bat') {
                    $targetArgs = @('/c', $targetPath) + $targetArgs
                    $targetPath = (Join-Path $env:SystemRoot 'System32\cmd.exe')
                }
            }
        }
        catch { }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $targetPath
        # Inherit the CALLER's directory. Push-Location moves PowerShell's
        # provider location but NOT [Environment]::CurrentDirectory, which is
        # what ProcessStartInfo inherits - so without this a caller that did
        # Push-Location <module dir> to scope a `go list` or `npm outdated`
        # silently ran the child in the wrong directory and got the wrong
        # answer. Invoking through `&` never had this gap.
        try {
            $callerDir = (Get-Location -PSProvider FileSystem -ErrorAction SilentlyContinue)
            if ($null -ne $callerDir -and -not [string]::IsNullOrWhiteSpace([string]$callerDir.ProviderPath)) {
                $info.WorkingDirectory = [string]$callerDir.ProviderPath
            }
        }
        catch { }
        # ArgumentList (not a joined string) so a path with spaces survives -
        # but ONLY pwsh 7 has it. ProcessStartInfo.ArgumentList arrived in
        # .NET Core; on .NET Framework 4.x, which is what Windows PowerShell
        # 5.1 runs on, the property does not exist. Measured, not assumed:
        # $info.PSObject.Properties.Name -contains 'ArgumentList' is False on
        # 5.1 and True on pwsh 7. Under StrictMode the 5.1 call threw inside
        # this function's own try, which returned $null - so every git/gh
        # call a hook made on 5.1 failed SILENTLY and read as "no answer".
        # An earlier revision of this comment asserted the property existed
        # on both hosts. It does not, and that claim is what hid the bug.
        if ($info.PSObject.Properties.Name -contains 'ArgumentList') {
            foreach ($argument in @($targetArgs)) { [void]$info.ArgumentList.Add([string]$argument) }
        }
        else {
            $info.Arguments = ConvertTo-Win32ArgumentString -ArgumentList @($targetArgs)
        }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # No window, no inherited stdin: a child that decides to prompt would
        # otherwise wait for input nobody is there to give.
        $info.RedirectStandardInput = $true
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($info)
        if ($null -eq $process) { $global:LASTEXITCODE = 1; return $null }
        $process.StandardInput.Close()
        # Read stdout asynchronously BEFORE waiting: a child that fills the pipe
        # buffer while we block on WaitForExit deadlocks with us forever.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remainingMs = [int][Math]::Max(0, $timeoutMs - $commandTimer.ElapsedMilliseconds)
        if (-not $process.WaitForExit($remainingMs)) {
            try { Stop-ProcessTree -ProcessId $process.Id } catch { }
            $global:LASTEXITCODE = 124
            return $null
        }
        # A descendant can retain either pipe after the direct child exits.
        # Keep the process handle until cleanup (so its PID cannot be reused)
        # and spend only the remaining command budget waiting for both EOFs.
        $remainingMs = [int][Math]::Max(0, $timeoutMs - $commandTimer.ElapsedMilliseconds)
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $remainingMs)) {
            try { Stop-ProcessTree -ProcessId $process.Id } catch { }
            $global:LASTEXITCODE = 124
            return $null
        }
        $output = ''
        try { $output = $stdoutTask.GetAwaiter().GetResult() } catch { $output = '' }
        try { [void]$stderrTask.GetAwaiter().GetResult() } catch { }
        $global:LASTEXITCODE = $process.ExitCode
        if ([string]::IsNullOrEmpty($output)) { return @() }
        return ($output -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    catch {
        $global:LASTEXITCODE = 1
        return $null
    }
    finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
        $ErrorActionPreference = $savedPreference
    }
}

# Kill a process AND everything it started. A `gh` that spawned a helper, or a
# package manager that shelled out, leaves the real work running if only the
# parent is killed.
function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId=" + $ProcessId) -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if ($null -ne $child -and [int]$child.ProcessId -ne $ProcessId) { Stop-ProcessTree -ProcessId ([int]$child.ProcessId) }
        }
    }
    catch { }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
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
    if ($LASTEXITCODE -ne 0) { return '' }
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
    # -z, NOT plain --porcelain. With core.quotepath at its default git
    # OCTAL-ESCAPES any non-ASCII path in the human-readable form, so a modified
    # Persian or CJK filename arrived as "\331\276..." - a path that does not
    # exist, whose timestamp was therefore silently missed and the project looked
    # untouched since its last commit. Reproduced 2026-09-12: the hook reported the
    # commit time while a Persian file edited 2 s earlier sat on disk. -z emits the
    # real path bytes, NUL-separated and never quoted, so nothing needs unescaping.
    $status = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain', '-z')
    if ($LASTEXITCODE -eq 0) {
        # The helper drops empty lines, so rejoin before splitting on the real
        # separator; -z output carries no newlines of its own.
        $records = @((([string]::Join("`n", @($status))) -split [char]0) | Where-Object { $_ -ne '' })
        for ($recordIndex = 0; $recordIndex -lt $records.Count; $recordIndex++) {
            $lineText = [string]$records[$recordIndex]
            if ($lineText.Length -lt 4) { continue }
            # Under -z a rename/copy is TWO records: 'XY <new>' then '<old>'. Only
            # the destination exists on disk, so consume and discard the original
            # rather than testing a path that was moved away.
            $code = $lineText.Substring(0, 2)
            $relative = $lineText.Substring(3)
            if ($code.Contains('R') -or $code.Contains('C')) { $recordIndex++ }
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

# ---- Stop re-entry: whose block was it? ------------------------------------
# `stop_hook_active` means "a Stop hook blocked and the agent is coming back",
# NOT "YOU blocked". Thirteen gates share that one flag, so a gate that exits
# on it alone stands down for somebody else's block - and the next Stop runs
# with the secret-leak, UTF-8 and CI gates all silent. Measured consequence,
# not theory: it is why a missing "Skills used:" line could wave a real leak
# through.
#
# The rule each gate needs is narrower: stand down only on ITS OWN re-entry.
# A gate that has not spoken yet still gets its turn on a continuation Stop.
# Worst case is therefore one block per gate per session - bounded by the hook
# count, never a loop - and each is cleared the normal way, by fixing what it
# named.
#
# Deliberately NOT for advisory hooks: their message already went out, and
# repeating it on every continuation Stop is noise. Gates only.
function Test-StopStandDown {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName
    )
    $stopActive = Get-Field $HookInput 'stop_hook_active'
    if ($null -eq $stopActive -or -not [bool]$stopActive) { return $false }
    # A continuation Stop. Only the hook that blocked stands down.
    $sessionId = [string](Get-Field $HookInput 'session_id')
    $cwd = [string](Get-Field $HookInput 'cwd')
    $markerPath = Get-StopBlockMarkerPath -HookName $HookName -ProjectRoot $cwd
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try {
        $recorded = ([System.IO.File]::ReadAllText($markerPath)).Trim()
        # Session-scoped: a marker from an earlier session must not mute this one.
        return ($recorded -ne '' -and $recorded -eq $sessionId)
    }
    catch { return $false }
}

# Called by a gate immediately before it emits a block, so its own next
# re-entry is recognised.
function Set-StopBlockMarker {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][string]$HookName
    )
    $sessionId = [string](Get-Field $HookInput 'session_id')
    $cwd = [string](Get-Field $HookInput 'cwd')
    $markerPath = Get-StopBlockMarkerPath -HookName $HookName -ProjectRoot $cwd
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($markerPath, $sessionId)
    }
    catch { }
}

function Get-StopBlockMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$HookName,
        [AllowEmptyString()][string]$ProjectRoot = ''
    )
    $projectKey = Get-ShortHash ([string]$ProjectRoot).ToLowerInvariant()
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($HookName, '[^A-Za-z0-9]+', '')
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('StopBlock-' + $safeName + '-' + $projectKey + '.txt'))
}

# ---- Codebase Memory MCP (CBM) ---------------------------------------------
# CBM keeps ONE SQLite file per indexed project directly in its cache
# directory: <cache>\<project-name>.db, beside _config.db and logs\. These
# helpers only look at the filesystem - no hook ever runs the CBM binary
# (measured at ~1.9 s per call, which no hook budget can afford), exactly as
# the Graphify hooks only test for graphify-out\graph.json.

# Read only Codex's CMM table: basic/literal strings, string argument arrays,
# and the environment subtable. Unsupported or malformed selected values fail
# closed; this is deliberately not a general-purpose TOML implementation.
function ConvertFrom-CbmTomlServer {
    param([string]$Text)
    $stringPattern = '"(?:[^"\\\r\n]|\\.)*"|''[^''\r\n]*'''
    function Read-CbmTomlString {
        param([string]$Value)
        $match = [regex]::Match($Value, ('^\s*(' + $stringPattern + ')\s*(?:#.*)?$'))
        if (-not $match.Success) { throw 'Unsupported CMM TOML string.' }
        $literal = $match.Groups[1].Value
        if ($literal[0] -eq [char]39) { return $literal.Substring(1, $literal.Length - 2) }
        return ($literal | ConvertFrom-Json -ErrorAction Stop)
    }
    $record = @{ command = ''; args = @(); env = @{} }
    $section = ''; $found = $false; $seen = @{}
    $lines = $Text -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('[')) {
            $section = ''
            if ($line -match '^\[\s*mcp_servers\s*\.\s*(?:codebase-memory-mcp|"codebase-memory-mcp"|''codebase-memory-mcp'')\s*(?<env>\.\s*env)?\s*\]\s*(?:#.*)?$') {
                $section = if ($Matches['env']) { 'env' } else { 'server' }
                $found = $true
            }
            continue
        }
        if ($section -eq '') { continue }
        if ($line -notmatch '^([A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|''[A-Za-z0-9_-]+'')\s*=\s*(.*)$') { throw 'Malformed CMM TOML assignment.' }
        $key = $Matches[1].Trim([char[]]@([char]34, [char]39)); $value = $Matches[2]
        $identity = $section + '.' + $key
        if ($seen.ContainsKey($identity)) { throw 'Duplicate CMM TOML key.' }
        $seen[$identity] = $true
        if ($section -eq 'env') {
            if ($key -in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) { $record.env[$key] = Read-CbmTomlString $value }
        }
        elseif ($key -eq 'command') { $record.command = Read-CbmTomlString $value }
        elseif ($key -eq 'env') {
            if ($value -notmatch '^\{(?<body>.*)\}\s*(?:#.*)?$') { throw 'Unsupported CMM inline environment.' }
            $body = $Matches['body'].Trim(); $position = 0
            $pairPattern = '\G\s*(?<key>[A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|''[A-Za-z0-9_-]+'')\s*=\s*(?<value>' + $stringPattern + ')\s*(?<separator>,|$)'
            foreach ($pair in [regex]::Matches($body, $pairPattern)) {
                $envKey = $pair.Groups['key'].Value.Trim([char[]]@([char]34, [char]39))
                if ($seen.ContainsKey('env.' + $envKey)) { throw 'Duplicate CMM environment key.' }
                $seen['env.' + $envKey] = $true
                if ($envKey -in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) { $record.env[$envKey] = Read-CbmTomlString $pair.Groups['value'].Value }
                $position = $pair.Index + $pair.Length
                if ($position -eq $body.Length -and $pair.Groups['separator'].Value -eq ',') { throw 'Trailing CMM environment comma.' }
            }
            if ($position -ne $body.Length) { throw 'Malformed CMM inline environment.' }
        }
        elseif ($key -eq 'args') {
            if (-not $value.StartsWith('[')) { throw 'CMM args must be a string array.' }
            while (([regex]::Replace($value, ($stringPattern + '|#[^\r\n]*'), '')).TrimEnd() -notmatch '\]$') {
                if (++$i -ge $lines.Count) { throw 'Unclosed CMM argument array.' }
                $value += "`n" + $lines[$i]
            }
            $body = [regex]::Replace($value, ('(?<string>' + $stringPattern + ')|(?<comment>#[^\r\n]*)'), {
                param($m) if ($m.Groups['comment'].Success) { return '' }; return $m.Value
            }).Trim()
            $body = $body.Substring(1, $body.Length - 2)
            $argumentValues = New-Object System.Collections.Generic.List[string]
            $expectValue = $true
            foreach ($token in [regex]::Matches($body, ('(?<string>' + $stringPattern + ')|(?<comma>,)|(?<space>\s+)|(?<other>.)'))) {
                if ($token.Groups['space'].Success) { continue }
                if ($token.Groups['string'].Success -and $expectValue) {
                    [void]$argumentValues.Add((Read-CbmTomlString $token.Value)); $expectValue = $false
                }
                elseif ($token.Groups['comma'].Success -and -not $expectValue) { $expectValue = $true }
                else { throw 'Malformed CMM argument array.' }
            }
            $record.args = @($argumentValues.ToArray())
        }
        elseif ($key -eq 'enabled') {
            if ($value -cnotmatch '^(true|false)(?:\s*#.*)?$') { throw 'CMM enabled must be true or false.' }
            $record.enabled = ($Matches[1] -ceq 'true')
        }
    }
    if ($found) { return $record }
    return $null
}

# Select ONE CMM record, retaining only invocation data and four directory keys.
# Case-preserving deserialization matters: real Claude profiles can contain
# case-distinct project paths outside mcpServers, which PSCustomObject rejects.
function Get-CbmServerConfig {
    param([string[]]$ConfigPaths, [string]$ProjectRoot = '', [string]$Client = '')
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).Path }
    if ($null -eq $ConfigPaths -or @($ConfigPaths).Count -eq 0) {
        $codexRoot = [string]$env:CODEX_HOME
        if ([string]::IsNullOrWhiteSpace($codexRoot)) { $codexRoot = Join-Path $env:USERPROFILE '.codex' }
        # Claude stores both local and user scopes in one file, with the
        # project's .mcp.json between them in precedence.
        $claudeProfile = Join-Path $env:USERPROFILE '.claude.json'
        $claudeSources = @(
            @{Path=$claudeProfile;Scope='local'},
            @{Path=(Join-Path $ProjectRoot '.mcp.json');Scope='server'},
            @{Path=$claudeProfile;Scope='server'}
        )
        $codexSources = @(
            @{Path=(Join-Path $ProjectRoot '.codex\config.toml');Scope='server'},
            @{Path=(Join-Path $codexRoot 'config.toml');Scope='server'}
        )
        $sources = if ((Get-HookClientId -Explicit $Client) -eq 'codex') { $codexSources + $claudeSources } else { $claudeSources + $codexSources }
    }
    else { $sources = @($ConfigPaths | ForEach-Object { @{Path=$_;Scope='any'} }) }
    foreach ($source in $sources) {
        $candidate = [string]$source.Path
        try {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $file = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -gt 1MB) { continue }
            $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false, $true))
            $entry = $null
            if ([System.IO.Path]::GetExtension($candidate) -ieq '.toml') { $entry = ConvertFrom-CbmTomlServer $raw }
            else {
                if ($PSVersionTable.PSVersion.Major -ge 6) { $doc = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
                else {
                    [void][System.Reflection.Assembly]::Load('System.Web.Extensions, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35')
                    $reader = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                    $reader.MaxJsonLength = 1MB
                    $doc = $reader.DeserializeObject($raw)
                }
                if ($doc -is [System.Collections.IDictionary]) {
                    if ($source.Scope -ne 'server' -and $doc.ContainsKey('projects') -and $doc['projects'] -is [System.Collections.IDictionary]) {
                        $root = Normalize-Path $ProjectRoot
                        foreach ($key in $doc['projects'].Keys) {
                            try {
                                if (-not [System.IO.Path]::IsPathRooted([string]$key) -or
                                    -not [string]::Equals((Normalize-Path ([string]$key)), $root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                            }
                            catch { continue }
                            $project = $doc['projects'][$key]
                            if ($project -is [System.Collections.IDictionary] -and $project.ContainsKey('mcpServers')) {
                                $servers = $project['mcpServers']
                                if ($servers -is [System.Collections.IDictionary] -and $servers.ContainsKey('codebase-memory-mcp')) { $entry = $servers['codebase-memory-mcp'] }
                            }
                            break
                        }
                    }
                    if ($null -eq $entry -and $source.Scope -ne 'local' -and $doc.ContainsKey('mcpServers')) {
                        $servers = $doc['mcpServers']
                        if ($servers -is [System.Collections.IDictionary] -and $servers.ContainsKey('codebase-memory-mcp')) { $entry = $servers['codebase-memory-mcp'] }
                    }
                }
            }
            if ($entry -isnot [System.Collections.IDictionary]) { continue }
            if ($entry.ContainsKey('enabled')) {
                if ($entry['enabled'] -isnot [bool]) { continue }
                if (-not $entry['enabled']) {
                    # An explicit disable is a selected record, not absence:
                    # falling through would reactivate a lower-priority server.
                    return [pscustomobject]@{ Command = ''; Arguments = @(); Environment = @{}; ConfigPath = $candidate; Disabled = $true }
                }
            }
            $command = if ($entry.ContainsKey('command') -and $entry['command'] -is [string]) { [string]$entry['command'] } else { '' }
            $arguments = @()
            if ($entry.ContainsKey('args')) {
                if ($entry['args'] -is [string]) { continue }
                $arguments = @($entry['args'])
                if ($arguments.Count -gt 128 -or @($arguments | Where-Object { $_ -isnot [string] }).Count -gt 0) { continue }
            }
            $environment = @{}
            if ($entry.ContainsKey('env') -and $entry['env'] -is [System.Collections.IDictionary]) {
                foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
                    if ($entry['env'].ContainsKey($key) -and $entry['env'][$key] -is [string]) { $environment[$key] = [string]$entry['env'][$key] }
                }
            }
            return [pscustomobject]@{ Command = $command; Arguments = @($arguments); Environment = $environment; ConfigPath = $candidate; Disabled = $false }
        }
        catch { continue }
    }
    return $null
}

function Get-CbmServiceConfig {
    param($Config, [string[]]$ClientConfigPaths, [string]$ProjectRoot = '')
    $server = Get-CbmServerConfig -ConfigPaths $ClientConfigPaths -ProjectRoot $ProjectRoot
    if ($null -ne $server -and $server.Disabled) {
        return [pscustomobject]@{ Command = ''; Arguments = @(); Environment = @{CBM_CACHE_DIR = ''}; Disabled = $true }
    }
    $environment = @{}
    foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
        $value = ''
        if ($null -ne $Config -and $Config.ContainsKey($key)) { $value = [string]$Config[$key] }
        if ([string]::IsNullOrWhiteSpace($value) -and $key.StartsWith('CBM_')) { $value = [Environment]::GetEnvironmentVariable($key) }
        if ([string]::IsNullOrWhiteSpace($value) -and $null -ne $server -and $server.Environment.ContainsKey($key)) { $value = $server.Environment[$key] }
        # TEMP/TMP in a hook are usually the shell's defaults, not CMM overrides.
        if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($key) }
        if (-not [string]::IsNullOrWhiteSpace($value)) { $environment[$key] = $value.Trim() }
    }
    if (-not $environment.ContainsKey('CBM_CACHE_DIR')) { $environment['CBM_CACHE_DIR'] = Join-Path $env:USERPROFILE '.cache\codebase-memory-mcp' }
    return [pscustomobject]@{
        Command = $(if ($null -ne $server) { $server.Command } else { '' })
        Arguments = @($(if ($null -ne $server) { $server.Arguments }))
        Environment = $environment
        Disabled = $false
    }
}

function Get-CbmCacheDir {
    param($Config, [string[]]$ClientConfigPaths, [string]$ProjectRoot = '')
    return (Get-CbmServiceConfig -Config $Config -ClientConfigPaths $ClientConfigPaths -ProjectRoot $ProjectRoot).Environment['CBM_CACHE_DIR']
}
function Get-CbmCacheDirFromClientConfig {
    param([string[]]$ConfigPaths)
    $server = Get-CbmServerConfig -ConfigPaths $ConfigPaths
    if ($null -ne $server -and $server.Environment.ContainsKey('CBM_CACHE_DIR')) { return $server.Environment['CBM_CACHE_DIR'].Trim() }
    return ''
}
function Get-CbmServerCommandFromClientConfig {
    param([string[]]$ConfigPaths)
    $server = Get-CbmServerConfig -ConfigPaths $ConfigPaths
    if ($null -ne $server) { return $server.Command }
    return ''
}

function Get-CbmCliAdvice {
    param($Service, [string[]]$Arguments)
    if ($null -eq $Service -or [string]::IsNullOrWhiteSpace($Service.Command)) { return '' }
    # Only the identified raw CMM program has a known subcommand contract.
    # Interpreters and arbitrary executable wrappers need separate verification.
    $program = [System.IO.Path]::GetFileName($Service.Command)
    if ($program -notmatch '^codebase-memory-mcp(?:\.exe)?$') { return '' }
    $tokens = @($Service.Command) + @($Service.Arguments) + @($Arguments)
    if (@($tokens | Where-Object { $_ -match '[\r\n\x00]' -or $_ -match '(?i)^--?(?:token|password|secret|api[-_]key)(?:=|$)' }).Count -gt 0) { return '' }
    $prefix = @()
    foreach ($key in @('CBM_CACHE_DIR', 'CBM_RUNTIME_DIR', 'TEMP', 'TMP')) {
        if ($Service.Environment.ContainsKey($key)) {
            $value = [string]$Service.Environment[$key]
            if ($value -match '[\r\n\x00]') { return '' }
            $prefix += ('$env:' + $key + " = '" + $value.Replace("'", "''") + "'")
        }
    }
    $invocation = '& ' + ((@($tokens | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })) -join ' ')
    $advice = (@($prefix) + @($invocation)) -join '; '
    if ($advice.Length -gt 8192) { return '' }
    return $advice
}

# _config.db is CBM's own registry and exists as soon as the server has run
# once. Without it the server was never set up on this machine, and a hook
# that nags about a tool the user does not have is pure noise.
function Test-CbmInstalled {
    param([string]$CacheDir)
    if ([string]::IsNullOrWhiteSpace($CacheDir)) { return $false }
    try { return (Test-Path -LiteralPath (Join-Path $CacheDir '_config.db') -PathType Leaf) }
    catch { return $false }
}

# CBM derives the default project name from the FULL root path: every run of
# characters outside [A-Za-z0-9] collapses to a single '-', then the ends are
# trimmed. Verified 2026-09-06 against a real index: the root
# ...\G--Program-Files-Portable-Scripts-Hook-Maker\<id>\scratchpad\cbm name probe
# produced C-Users-...-G-Program-Files-Portable-Scripts-Hook-Maker-<id>-scratchpad-cbm-name-probe.db
# - note the doubled separator collapsing to one dash and the space becoming
# one. A caller CAN override this with index_repository(name=...); a hook
# cannot see that, so an overridden project reads as un-indexed here. That is
# the documented limitation, and it fails toward silence rather than a wrong
# claim.
function Get-CbmProjectName {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $collapsed = [System.Text.RegularExpressions.Regex]::Replace([string]$ProjectRoot, '[^A-Za-z0-9]+', '-')
    return $collapsed.Trim('-')
}

function Get-CbmProjectDbPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$CacheDir
    )
    return (Join-Path $CacheDir ((Get-CbmProjectName -ProjectRoot $ProjectRoot) + '.db'))
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

# ---- Claude Code transcript --------------------------------------------------
# Parses the JSONL a Stop hook is handed in `transcript_path` into an ordered
# list of @{ Role; Text; SkillCalls }.
#
# WHAT IT DELIBERATELY DROPS: <system-reminder> blocks and <command-...> local
# command echoes are stripped from user text. Both are injected BY the client,
# not typed by the user, and both routinely quote a hook's own reminder text -
# so a hook matching its own words in a reminder would find "evidence" it
# planted itself.
#
# BOUNDED, and honest about it: reading stops after $MaxBytes and the result
# reports Partial = $true. A caller must never turn a partial read into a
# block or an all-clear - it saw only part of the session.
function Read-ClaudeTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxBytes = 20000000
    )
    $result = [pscustomobject]@{ Entries = @(); Partial = $false; Ok = $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    # The cap is in BYTES and is applied to the file's length BEFORE anything is
    # read. A 47 MB live transcript used to be parsed line by line up to the cap
    # at every Stop - about ten seconds - only to be reported Partial and
    # discarded. Over the cap the answer is already known: Partial, nothing read.
    try {
        if ((New-Object System.IO.FileInfo($Path)).Length -gt $MaxBytes) {
            return [pscustomobject]@{ Entries = @(); Partial = $true; Ok = $true }
        }
    }
    catch { return $result }
    $entries = New-Object System.Collections.Generic.List[object]
    $consumed = 0
    $partial = $false
    try {
        # Shared read: a live client is still appending to this file.
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding $false))
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    $consumed += $line.Length + 1
                    if ($consumed -gt $MaxBytes) { $partial = $true; break }
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $doc = $null
                    try { $doc = $line | ConvertFrom-Json } catch { continue }
                    if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['message'] -or $null -eq $doc.message) { continue }
                    $role = ''
                    if ($null -ne $doc.message.PSObject.Properties['role']) { $role = [string]$doc.message.role }
                    if ($role -ne 'user' -and $role -ne 'assistant') { continue }
                    $content = $null
                    if ($null -ne $doc.message.PSObject.Properties['content']) { $content = $doc.message.content }
                    $text = ''
                    $skills = New-Object System.Collections.Generic.List[string]
                    if ($content -is [string]) {
                        $text = [string]$content
                    }
                    elseif ($null -ne $content) {
                        foreach ($part in @($content)) {
                            if ($null -eq $part -or $null -eq $part.PSObject.Properties['type']) { continue }
                            $partType = [string]$part.type
                            if ($partType -eq 'text' -and $null -ne $part.PSObject.Properties['text']) {
                                $text = $text + "`n" + [string]$part.text
                            }
                            elseif ($partType -eq 'tool_use' -and $null -ne $part.PSObject.Properties['name'] -and [string]$part.name -eq 'Skill') {
                                if ($null -ne $part.PSObject.Properties['input'] -and $null -ne $part.input -and
                                    $null -ne $part.input.PSObject.Properties['skill']) {
                                    $skillName = [string]$part.input.skill
                                    if (-not [string]::IsNullOrWhiteSpace($skillName)) { [void]$skills.Add($skillName) }
                                }
                            }
                        }
                    }
                    if ($role -eq 'user' -and $text -ne '') {
                        $text = [System.Text.RegularExpressions.Regex]::Replace($text, '(?is)<system-reminder>.*?</system-reminder>', ' ')
                        $text = [System.Text.RegularExpressions.Regex]::Replace($text, '(?is)<command-[a-z-]+>.*?</command-[a-z-]+>', ' ')
                    }
                    [void]$entries.Add([pscustomobject]@{ Role = $role; Text = $text.Trim(); SkillCalls = @($skills.ToArray()) })
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        # Unreadable transcript is NOT an all-clear: Ok stays false.
        return $result
    }
    return [pscustomobject]@{ Entries = @($entries.ToArray()); Partial = $partial; Ok = $true }
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
