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

# Resolves any spelling of a Kiro trigger to Hook Maker's canonical logical
# event name, or '' when it is not one of the five Kiro documents.
#
# Case-INSENSITIVE in, canonical OUT - deliberately the same contract
# Resolve-HookMakerLogicalEvent already has in scripts\_clientcapability.ps1,
# and it is load-bearing rather than cosmetic. Kiro renamed every trigger
# between CLI v2 (camelCase 'preToolUse') and the v1 schema (PascalCase
# 'PreToolUse'), and CLI v3 sends stdin JSON WITHOUT re-publishing its field
# names or casing (.ai/KIRO_PROTOCOL.md, critical unknown 4). Comparing raw
# spellings instead of resolved events would call 'preToolUse' and 'PreToolUse'
# a contradiction and refuse every CLI v3 hook.
#
# One list resolves BOTH sides because Kiro's physicalEventMap is identity for
# all five triggers - the physical trigger name and the logical event name are
# the same string - so there is no second table to translate through.
# Test-ContextHooks asserts $script:HookKiroTriggers still equals the capability
# table's kiro supportedEvents, which is what keeps that true.
function Resolve-KiroTrigger {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    # -eq on strings is case-insensitive in PowerShell; the RETURNED value is
    # always the canonical spelling from the list, never the caller's.
    $match = @($script:HookKiroTriggers | Where-Object { $_ -eq ([string]$Name).Trim() })
    if ($match.Count -eq 0) { return '' }
    return $match[0]
}

# Makes an untrusted value safe to embed in a one-line user-visible diagnostic.
# Control characters (newlines included) become spaces and the length is
# capped, so a hostile or accidental multi-kilobyte event name can neither
# flood the warning nor smuggle line breaks into it that would let attacker
# text masquerade as separate diagnostic lines.
function Get-HookSafeDiagnosticText {
    param([string]$Text, [int]$MaxChars = 80)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = ([regex]::Replace($Text, '[\x00-\x1f\x7f]', ' ')).Trim()
    if ($clean.Length -gt $MaxChars) { return ($clean.Substring(0, $MaxChars) + '...') }
    return $clean
}

# Reads the hook event JSON from stdin. Returns the parsed object, or $null on
# genuinely EMPTY input (the caller then exits silently). Non-empty stdin that
# fails to parse is corrupt input; on Kiro it refuses visibly rather than
# collapsing into the same $null an empty stdin produces.
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
    $stdinParseFailed = $false
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
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            # The inner try exists so that "stdin carried bytes that are not
            # JSON" stays distinguishable from "stdin was empty". Collapsing
            # the two is harmless on Claude/Codex (both mean: nothing to do)
            # but NOT on Kiro, where an empty stdin is the documented IDE
            # normal and gets a synthesized event - a corrupt payload must
            # never be laundered into that healthy-looking shape.
            try { $parsed = ($raw | ConvertFrom-Json) }
            catch { $parsed = $null; $stdinParseFailed = $true }
        }
    }
    catch { $parsed = $null }

    if ((Get-HookClientId) -cne 'kiro') { return $parsed }

    if ($stdinParseFailed) {
        # Non-empty stdin that does not parse is corrupt input, and on Kiro the
        # $null it used to collapse into is exactly what the "IDE sent nothing"
        # branch below synthesizes a VALID event from - so corrupt input became
        # a seemingly healthy invocation. Refuse visibly instead: same channel
        # as the trigger contradiction below (stderr + exit 1, never 2), same
        # reason - nothing about this invocation can be trusted to pick a code
        # path, and only the user can fix what is sending broken JSON.
        [Console]::Error.WriteLine('Hook Maker: not running this hook. Kiro sent data on stdin that is not ' +
            'valid JSON, so this invocation cannot be trusted to select an event. If this repeats, ' +
            're-install the hook and check what is writing to its stdin.')
        exit 1
    }

    # Trust boundary: the trigger arrives through the environment, so it is
    # accepted ONLY when it resolves to one of the events Kiro actually
    # documents. An unrecognized value is dropped rather than passed to hooks as
    # an event name, which would let anything that can set an env var choose the
    # code path a hook takes.
    $kiroTrigger = Resolve-KiroTrigger ([string]$env:HOOKMAKER_KIRO_TRIGGER)
    if ($kiroTrigger -eq '') {
        # No trusted launcher trigger -> NOTHING runs, unconditionally.
        #
        # Every Hook Maker registration passes -Trigger, and kiro-launch.ps1 is
        # what sets the client identity this branch is gated on - so a Kiro
        # invocation with no resolvable trigger means the registration is not
        # ours, is half-copied, or the environment was tampered with. Round 30
        # let a payload event run here if it resolved inside the five-trigger
        # trust list; the review (and the user) rejected that: without the
        # registration's identity, stdin alone must never select the branch a
        # hook takes - a well-formed payload naming 'Stop' is exactly what a
        # spoofed invocation would carry. Fail closed, visibly (stderr + exit 1,
        # never 2), on the SAME channel as every other refusal here.
        $registrationlessEventRaw = ''
        if ($null -ne $parsed) { $registrationlessEventRaw = [string](Get-Field $parsed 'hook_event_name') }
        $registrationlessDetail = if ([string]::IsNullOrWhiteSpace($registrationlessEventRaw)) {
            'and stdin supplies no event identity to check it against'
        }
        else {
            'so the stdin payload''s event name "' + (Get-HookSafeDiagnosticText $registrationlessEventRaw) +
            '" cannot be trusted to select a code path'
        }
        [Console]::Error.WriteLine('Hook Maker: not running this hook. It is running under Kiro without a ' +
            '-Trigger from its registration, ' + $registrationlessDetail +
            '. Re-install the hook so its .kiro\hooks registration passes -Trigger.')
        exit 1
    }

    if ($null -eq $parsed) {
        # cwd from the process, canonicalized. Kiro launches the hook in the
        # workspace directory; there is no documented cwd field to read.
        $kiroCwd = ''
        try { $kiroCwd = [System.IO.Path]::GetFullPath((Get-Location).Path) } catch { $kiroCwd = '' }
        $synthesized = [pscustomobject]@{ hook_event_name = $kiroTrigger }
        if (-not [string]::IsNullOrWhiteSpace($kiroCwd)) {
            Set-ObjectProperty -Object $synthesized -Name 'cwd' -Value $kiroCwd
        }
        # USER_PROMPT is the ONE input channel Kiro documents, and omitting it
        # left every prompt-driven hook blind on Kiro IDE: Rules-Check,
        # Skills-Check and the ::deep-debug detection all read 'prompt', so they
        # silently did nothing there. Scoped to UserPromptSubmit because that is
        # the only trigger Kiro documents it for - carrying a stale prompt into
        # SessionStart or PreToolUse would be worse than having none.
        if ($kiroTrigger -ceq 'UserPromptSubmit') {
            $kiroPrompt = Get-KiroPromptFromEnvironment
            if (-not [string]::IsNullOrWhiteSpace($kiroPrompt)) {
                Set-ObjectProperty -Object $synthesized -Name 'prompt' -Value $kiroPrompt
            }
        }
        return $synthesized
    }

    # CLI v3 DOES send stdin JSON, but does not re-publish its field names or
    # casing, so a payload may arrive with no usable event name, with the same
    # event spelled differently, or - the case that matters - naming a
    # GENUINELY DIFFERENT event than the launcher.
    #
    # The launcher argument is written by Hook Maker's own installer into the
    # .kiro\hooks registration, so a real disagreement means the registration
    # and the client disagree about what fired, and NEITHER side can then be
    # trusted to select the code path a hook takes.
    $parsedEventRaw = [string](Get-Field $parsed 'hook_event_name')
    if ([string]::IsNullOrWhiteSpace($parsedEventRaw)) {
        # Nothing to contradict - fill in what the payload never carried.
        Set-ObjectProperty -Object $parsed -Name 'hook_event_name' -Value $kiroTrigger
    }
    elseif ((Resolve-KiroTrigger $parsedEventRaw) -ceq $kiroTrigger) {
        # The SAME event, possibly spelled differently. Normalize to the
        # canonical name so every hook's `-ceq 'PreToolUse'` branch keeps
        # working on a client whose casing is undocumented.
        Set-ObjectProperty -Object $parsed -Name 'hook_event_name' -Value $kiroTrigger
    }
    else {
        # Two genuinely different events. REFUSE to run rather than guess.
        #
        # This used to let the payload win and record 'hookmaker_trigger_mismatch'
        # on the object - a field NOTHING reads, which is the same as swallowing
        # it: a PreToolUse registration whose payload said Stop handed the hook a
        # Stop event, the hook ran its Stop branch, and nothing said so.
        #
        # The refusal has to be VISIBLE or it is that defect in a new place.
        # Returning $null would make every hook take its
        # `if ($null -eq $hookInput) { exit 0 }` path in total silence. Per the
        # CONFIRMED exit-code table in .ai/KIRO_PROTOCOL.md: exit 0 adds stdout
        # to context ONLY on SessionStart/UserPromptSubmit and discards it
        # everywhere else - so a stdout message would be silent on exactly the
        # PreToolUse/PostToolUse/Stop events where a wrong branch does damage -
        # exit 2 blocks on the block-capable events, and ANY OTHER non-zero exit
        # shows stderr to the user and lets execution proceed. That last channel
        # is right on the merits, not merely available: a registration/client
        # disagreement is a configuration fault only the USER can repair.
        #
        # Exit 1, NEVER 2. 2 is Kiro's refusal code; blocking the user's tool
        # call over a Hook Maker configuration fault is not this function's
        # decision to make, and Stop cannot block on either Kiro surface anyway.
        # The payload value is untrusted and goes into a user-visible line, so
        # it is sanitized and bounded - an unbounded print would let a huge or
        # newline-carrying event name flood or reshape the very diagnostic that
        # exists to explain the refusal.
        [Console]::Error.WriteLine('Hook Maker: not running this hook. Its Kiro registration says the trigger is "' +
            $kiroTrigger + '" but Kiro reported "' + (Get-HookSafeDiagnosticText $parsedEventRaw) + '". The two ' +
            'disagree about what fired, so the hook refused to guess which branch to run. Re-install the hook so ' +
            'its .kiro\hooks registration matches the trigger Kiro fires.')
        exit 1
    }

    # The byte bound applies to the prompt WHEREVER it arrived from. Capping
    # only USER_PROMPT left a hole the capability table itself predicts: CLI v3
    # DOES send stdin JSON, so the same oversized prompt arriving inside the
    # payload won ("payload wins") with no limit at all - the documented 64 KB
    # bound applied only to the channel that happened to be smaller. Truncation
    # stays REPORTED via the same in-text marker.
    # ONE resolution of which prompt this invocation carries, so no later reader
    # has to re-interpret an empty value. The environment is offered as a
    # fallback only on the trigger Kiro documents USER_PROMPT for - carrying a
    # leftover prompt into SessionStart or PreToolUse would be worse than none.
    $kiroPromptSource = Resolve-KiroPromptSource -Payload $parsed `
        -AllowEnvironmentFallback:($kiroTrigger -ceq 'UserPromptSubmit')
    # Written unconditionally: the resolved text is authoritative, and an
    # empty/oversized/invalid outcome must OVERWRITE whatever the raw payload
    # held so nothing downstream can read the unresolved value by accident.
    if ($kiroPromptSource.SourcePresent) {
        Set-ObjectProperty -Object $parsed -Name 'prompt' -Value ([string]$kiroPromptSource.Text)
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

# Ceiling on the prompt taken from Kiro's USER_PROMPT environment variable.
#
# Every other hook input arrives as stdin JSON, which the client frames; this
# one arrives as an environment variable whose size nothing bounds. A pasted
# file or a machine-generated prompt therefore lands in memory whole, in a hook
# process that runs on every submission. 64 KB is far above any real prompt and
# far below anything that matters for a short-lived process.
#
# The bound is UTF-8 BYTES, not characters - it exists to cap MEMORY, and this
# repo measures text in UTF-8 bytes everywhere else. A CHARACTER cap silently
# admits up to three times the stated limit (65536 CJK characters are ~192 KB).
#
# An OVERSIZED prompt is WITHHELD ENTIRELY, never truncated (review + user
# decision, round 31). Round 30 kept the prefix with an in-text marker, but a
# prefix is a prompt the user did not type, and every prompt-driven hook
# regex-matches on it as if it were - so semantic decisions (codeword routing,
# relevance gating) ran on fabricated text. With the prompt withheld, those
# hooks take their documented no-prompt degradation path instead, exactly as on
# Kiro IDE when USER_PROMPT is absent - and a one-line stderr notice says so,
# once, so the withholding is never silent.
$script:HookMaxPromptBytes = 65536
$script:HookPromptWithheldNoticed = $false

# The one prompt-bounding implementation, applied to EVERY channel a Kiro
# prompt can arrive on (USER_PROMPT env and a CLI v3 stdin payload alike) so
# the two channels cannot drift to different bounds.
function Limit-KiroPromptText {
    param([string]$Text)
    $raw = [string]$Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    if ([System.Text.Encoding]::UTF8.GetByteCount($raw) -le $script:HookMaxPromptBytes) { return $raw }
    if (-not $script:HookPromptWithheldNoticed) {
        $script:HookPromptWithheldNoticed = $true
        try {
            [Console]::Error.WriteLine('Hook Maker: the submitted prompt exceeds ' +
                [string]$script:HookMaxPromptBytes + ' UTF-8 bytes and was withheld from hooks; ' +
                'prompt-driven checks will not run for this submission.')
        }
        catch { }
    }
    return ''
}

function Get-KiroPromptFromEnvironment {
    return (Limit-KiroPromptText ([string]$env:USER_PROMPT))
}

# Resolves WHICH prompt a Kiro invocation carries, as an explicit decision
# rather than a value whose emptiness later has to be re-interpreted.
#
# Returns: SourcePresent (bool), Source (payload|environment|none),
#          Status (ok|empty|oversized|invalid|absent), Text (exact or '').
#
# The load-bearing rule is PROPERTY PRESENCE, not non-whitespace text. Payload
# precedence used to be decided with IsNullOrWhiteSpace, which cannot tell
# "the client sent no prompt" from "the client sent an empty, whitespace-only or
# null one" - so `{"prompt":""}`, `{"prompt":"   "}` and `{"prompt":null}` all
# fell through to USER_PROMPT and could be replaced by unrelated or STALE
# environment text (measured: a `::deep-debug` in the environment fired for all
# three). A client that sent a prompt has spoken, even when what it sent is
# empty; only a genuinely ABSENT property may fall back.
#
# A non-string value is `invalid`, not text: it never reaches a semantic matcher
# and never falls back either - substituting the environment for a payload the
# client did supply would be the same precedence break by another route.
function Resolve-KiroPromptSource {
    param($Payload, [switch]$AllowEnvironmentFallback)

    $result = [pscustomobject]@{
        SourcePresent = $false
        Source        = 'none'
        Status        = 'absent'
        Text          = ''
    }

    $property = $null
    if ($null -ne $Payload -and $null -ne $Payload.PSObject) { $property = $Payload.PSObject.Properties['prompt'] }
    if ($null -ne $property) {
        # Verified on both hosts: ConvertFrom-Json CREATES the property for a
        # JSON null, so presence is a real signal and not an artefact.
        $result.SourcePresent = $true
        $result.Source = 'payload'
        $value = $property.Value
        if ($null -eq $value) { $result.Status = 'empty' }
        elseif ($value -isnot [string]) { $result.Status = 'invalid' }
        elseif ([string]::IsNullOrWhiteSpace($value)) { $result.Status = 'empty' }
        else {
            $bounded = Limit-KiroPromptText $value
            if ([string]::IsNullOrEmpty($bounded)) { $result.Status = 'oversized' }
            else {
                $result.Status = 'ok'
                $result.Text = $bounded   # byte-exact when within the bound
            }
        }
        return $result
    }

    if (-not $AllowEnvironmentFallback) { return $result }

    $raw = [string]$env:USER_PROMPT
    if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
    $result.SourcePresent = $true
    $result.Source = 'environment'
    $bounded = Limit-KiroPromptText $raw
    if ([string]::IsNullOrEmpty($bounded)) { $result.Status = 'oversized' }
    else {
        $result.Status = 'ok'
        $result.Text = $bounded
    }
    return $result
}

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
# degraded; on Stop its advisory cannot reach model context either, so it is
# surfaced as a non-blocking stderr warning (exit 1, never the refusal code 2).
#
# Returns @{ Emitted; Shape; ExitCode; Degraded; DegradedReason } so a caller can
# honestly record 'degraded-stop-gate' instead of claiming enforcement it did not
# get. ExitCode is what the CALLER must exit with (0 everywhere except a real
# Kiro block, which needs 2); this function never exits on its own.
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
        # a refusal. Only the kiro branch is new.
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
            elseif ($clientId -eq 'kiro') {
                # Kiro documents exit 2 + stderr on its block-capable triggers.
                # There is no documented "allow with a reason", so an allow is a
                # plain advisory: it must never be emitted as a refusal.
                if ($Kind -eq 'deny' -and
                    $script:HookBlockCapableEvents.ContainsKey('kiro') -and
                    @($script:HookBlockCapableEvents['kiro'] | Where-Object { $_ -ceq $EventName }).Count -gt 0) {
                    [Console]::Error.WriteLine($text)
                    $emitted = $true; $shape = 'kiroExit2Stderr'; $exitCode = 2
                }
                elseif (@($script:HookKiroContextEvents | Where-Object { $_ -ceq $EventName }).Count -gt 0) {
                    [Console]::Out.WriteLine($text)
                    $emitted = $true; $shape = 'kiroStdout'
                    if ($Kind -eq 'deny') {
                        $degradedParts += ('kiro documents no refusal on ' + $EventName +
                            '; emitted as context instead - this is NOT an enforced gate')
                    }
                }
                else {
                    # This branch used to emit NOTHING, and that silently
                    # deleted every PreToolUse advisory on Kiro. An 'allow' is
                    # not block-capable and PreToolUse is not one of Kiro's two
                    # context triggers, so it fell straight through here.
                    # Test-Run-Guard routes its PreToolUse advisories through
                    # 'allow', so TEST_GUARD_ADVISORY_ONLY produced no output at
                    # all on Kiro - the guard announced it was in advisory mode
                    # to nobody.
                    #
                    # Kiro surfaces stderr as a warning for a non-zero exit other
                    # than 2, so the text reaches the user here. Exit 1, NEVER 2:
                    # an approval carrying the refusal code would enforce the
                    # exact opposite of what it says.
                    [Console]::Error.WriteLine($text)
                    $emitted = $true; $shape = 'kiroStderrWarning'; $exitCode = 1
                    $degradedParts += ('kiro neither refuses nor adds context on ' + $EventName +
                        '; surfaced as a non-blocking warning on stderr - visible to the user, ' +
                        'NOT injected into model context')
                }
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
                    # Kiro DISCARDS stdout here, but it is not silent: a non-zero
                    # exit code other than 2 surfaces stderr as a warning and
                    # lets execution proceed. This branch used to emit nothing at
                    # all, which threw away every Stop and PostToolUse message on
                    # Kiro - the hook ran and the user never learned why.
                    #
                    # Exit 1, NOT 2: 2 is the refusal code, and using it here
                    # would turn an advisory into a block on a block-capable
                    # trigger. The degradation is real and named: this reaches
                    # the user, not the model, so it is weaker than the context
                    # channel Claude and Codex get - never report it as parity.
                    [Console]::Error.WriteLine($text)
                    $emitted = $true; $shape = 'kiroStderrWarning'; $exitCode = 1
                    $degradedParts += ('kiro discards hook stdout on ' + $EventName +
                        ' (context is added only on ' + ($script:HookKiroContextEvents -join '/') +
                        '), so this was surfaced as a non-blocking warning on stderr - visible to the ' +
                        'user, NOT injected into model context')
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
    try {
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
        if (-not $process.WaitForExit([int]([Math]::Max(1, $TimeoutSeconds) * 1000))) {
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

# Resolution order, most specific first: the hook's own .env, then the
# environment the MCP server itself is configured with, then the binary's
# documented default.
function Get-CbmCacheDir {
    param($Config, [string[]]$ClientConfigPaths)
    if ($null -ne $Config -and $Config.ContainsKey('CBM_CACHE_DIR')) {
        $configured = [string]$Config['CBM_CACHE_DIR']
        if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured.Trim() }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CBM_CACHE_DIR)) { return ([string]$env:CBM_CACHE_DIR).Trim() }
    $fromClient = Get-CbmCacheDirFromClientConfig -ConfigPaths $ClientConfigPaths
    if (-not [string]::IsNullOrWhiteSpace($fromClient)) { return $fromClient }
    return (Join-Path $env:USERPROFILE '.cache\codebase-memory-mcp')
}

# The step the resolution order above always promised and did not implement.
# CBM_CACHE_DIR is normally set INSIDE the MCP server's own `env` block in the
# client config, which means the server process has it and a hook process never
# does. So the hook fell through to the binary default and watched the wrong
# directory for ever: on the machine where this was found the server wrote to
# G:\...\cache while the hook checked %USERPROFILE%\.cache, so "no index yet"
# was reported in every project no matter what was indexed, and the freshness
# half of Cbm-Update-Check could never fire at all.
#
# A REGEX over the raw text, deliberately not ConvertFrom-Json: the client
# config also holds other servers' env blocks, which can contain API keys, and
# the only value that may ever leave this function is this one path. It is also
# far cheaper than building the object graph of a large config on every event.
# First match wins; a second server defining the same key is not disambiguated.
#
# $ConfigPaths exists so the suite can point this at fabricated files: the real
# paths are the developer's own client config, and a test that read those would
# pass or fail depending on which MCP servers that developer happens to have.
function Get-CbmCacheDirFromClientConfig {
    param([string[]]$ConfigPaths)
    if ($null -eq $ConfigPaths -or @($ConfigPaths).Count -eq 0) {
        $ConfigPaths = @((Join-Path $env:USERPROFILE '.claude.json'), (Join-Path (Get-Location).Path '.mcp.json'))
    }
    foreach ($candidate in @($ConfigPaths)) {
        try {
            if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $raw = [System.IO.File]::ReadAllText($candidate)
            $match = [regex]::Match($raw, '"CBM_CACHE_DIR"\s*:\s*"((?:[^"\\]|\\.)*)"')
            if (-not $match.Success) { continue }
            # JSON string escapes: the value is a Windows path, so \\ is the one
            # that actually occurs. Unescape it rather than handing back "G:\\x".
            $value = $match.Groups[1].Value.Replace('\\', '\')
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        }
        catch { continue }
    }
    return ''
}

# The CBM executable as the CLIENT records it. Needed because the binary is NOT
# on PATH in a normal install - the refusal advice used to quote the tool's own
# "run codebase-memory-mcp allow-root ..." verbatim, and that command fails with
# "not recognized" for everyone. The server record already knows the full path,
# so the hook can hand over something that actually runs.
#
# Anchored on the server NAME so another server's command can never be picked
# up, and bounded so a malformed config cannot make this scan run away.
function Get-CbmServerCommandFromClientConfig {
    param([string[]]$ConfigPaths)
    if ($null -eq $ConfigPaths -or @($ConfigPaths).Count -eq 0) {
        $ConfigPaths = @((Join-Path $env:USERPROFILE '.claude.json'), (Join-Path (Get-Location).Path '.mcp.json'))
    }
    foreach ($candidate in @($ConfigPaths)) {
        try {
            if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $raw = [System.IO.File]::ReadAllText($candidate)
            $match = [regex]::Match($raw, '"codebase-memory-mcp"[\s\S]{0,400}?"command"\s*:\s*"((?:[^"\\]|\\.)*)"')
            if (-not $match.Success) { continue }
            $value = $match.Groups[1].Value.Replace('\\', '\')
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        }
        catch { continue }
    }
    return ''
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
