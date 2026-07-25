# ---------------------------------------------------------------------------
# Kiro registration documents, paths and ownership (IDE 1.0+ / CLI v3 only).
#
# WHY THIS FILE EXISTS
# Claude and Codex are 'sharedSettingsFile' clients: ONE document holds every
# hook, so ownership is per-handler-entry inside a file nobody owns. Kiro is
# 'perHookFile': each logical installation owns its OWN file under .kiro\hooks.
# That difference is not cosmetic - it introduces two failure modes the shared
# writers never had:
#
#   1. A file Hook Maker names can still be somebody else's. Kiro users write
#      hooks by hand, and .kiro\hooks is a plain directory. So ownership must
#      be proven from an identity INSIDE the entries, never from the filename.
#   2. A managed file can be hand-edited to hold extra hooks. Rewriting it
#      wholesale would silently delete a user's work. So every write is a
#      read-modify-write that preserves foreign entries exactly.
#
# Everything Kiro-specific about paths and trigger names is read from
# _clientcapability.ps1 (Get-HookMakerClientCapability -ClientId 'kiro'); this
# file re-declares none of it. The schema facts come from .ai\KIRO_PROTOCOL.md
# and nothing here is inferred beyond what that file establishes.
#
# This module is PURE: it defines functions, touches no disk state at
# dot-source time, and performs exactly one read (Test-KiroManagedFile). It
# never writes a file - the caller owns the write, so the caller can make it
# transactional in the same way the shared-settings writers already do.
#
# Serialize with ConvertTo-KiroHookJson, not a bare ConvertTo-Json: Windows
# PowerShell defaults to -Depth 2, which silently renders `action` as the
# string "System.Management.Automation.PSCustomObject" and installs a hook
# Kiro cannot run.
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot '_clientcapability.ps1')

# ---- internal helpers ------------------------------------------------------

# Every rejection carries a STABLE reason token as its first word so callers
# (and tests) can branch on the cause instead of pattern-matching prose.
function New-KiroRejection {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    return ('Kiro registration rejected: ' + $Reason + ' - ' + $Detail)
}

# Lowercase [a-z0-9-] only. Used for filenames and managed entry names, both
# of which are compared case-insensitively later, so anything outside that set
# would make an identity that cannot be matched back reliably.
function ConvertTo-KiroSlug {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return ([System.Text.RegularExpressions.Regex]::Replace(
            ([string]$Text).ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
}

function Get-KiroCapability {
    return (Get-HookMakerClientCapability -ClientId 'kiro')
}

# The two independent ownership proofs Hook Maker embeds in every managed
# entry. Either one alone is sufficient, so a user who rewrites a description
# in Kiro's UI does not cost us the file (and vice versa).
#
#   name        hookmaker-<managedIdSlug>-<friendlySlug>-<triggerlower>
#   description ... [hookmaker:<ManagedId>]
#
# The id sits immediately after the fixed 'hookmaker-' prefix so the check is
# position-anchored: a friendly name that happens to contain the id cannot
# forge a match.
function Get-KiroManagedNamePrefix {
    param([Parameter(Mandatory = $true)][string]$ManagedId)
    $idSlug = ConvertTo-KiroSlug -Text $ManagedId
    if ([string]::IsNullOrWhiteSpace($idSlug)) {
        throw (New-KiroRejection -Reason 'managed-id-unusable' -Detail (
                "ManagedId '" + $ManagedId + "' contains no [a-z0-9] characters, so no provable entry identity can be derived from it."))
    }
    return ('hookmaker-' + $idSlug + '-')
}

function Get-KiroManagedMarker {
    param([Parameter(Mandatory = $true)][string]$ManagedId)
    return ('[hookmaker:' + ([string]$ManagedId).Trim() + ']')
}

# Reads one field from either a PSCustomObject (parsed JSON, or an entry this
# module built) or a hashtable (an entry a caller assembled by hand). Returns
# $null when absent - never a StrictMode property-not-found crash on a
# hand-edited file that is missing a key.
#
# `return ,$value` is load-bearing, not noise: PowerShell enumerates a
# function's output, so a plain `return $value` hands back a ONE-entry `hooks`
# array as the bare entry object. Every single-trigger document would then
# fail the "hooks is an array" schema check and be misreported as
# unexpected-schema. The comma wrapper survives that enumeration intact.
function Get-KiroEntryField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Entry,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return , $Entry[$Name] }
        return $null
    }
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return , $property.Value
}

# True only when THIS installation owns the entry. An entry marked with a
# DIFFERENT Hook Maker id belongs to another installation and is foreign here:
# claiming it would let one hook delete another hook's registration.
function Test-KiroManagedEntry {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Entry,
        [Parameter(Mandatory = $true)][string]$ManagedId
    )
    if ($null -eq $Entry) { return $false }
    $prefix = Get-KiroManagedNamePrefix -ManagedId $ManagedId
    $marker = Get-KiroManagedMarker -ManagedId $ManagedId

    $entryName = [string](Get-KiroEntryField -Entry $Entry -Name 'name')
    if ($entryName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

    $entryDescription = [string](Get-KiroEntryField -Entry $Entry -Name 'description')
    if ($entryDescription.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }

    return $false
}

# Triggers whose `matcher` the protocol file CONFIRMS is evaluated on both
# surfaces Hook Maker targets. UserPromptSubmit is deliberately absent: the
# protocol records it as CLI v3 only, with the IDE table blank - unknown, not
# confirmed - and attaching a filter that one surface ignores would make the
# hook fire on prompts the caller believed it had excluded. SessionStart and
# Stop are confirmed NOT to evaluate it.
function Get-KiroMatcherEvaluatingTriggers {
    return @('PreToolUse', 'PostToolUse')
}

function Resolve-KiroScopeRoot {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('project', 'global')][string]$Scope,
        [AllowEmptyString()][string]$TargetProjectRoot = ''
    )
    if ($Scope -eq 'project') {
        if ([string]::IsNullOrWhiteSpace($TargetProjectRoot)) {
            throw (New-KiroRejection -Reason 'target-project-root-required' -Detail (
                    'Project scope needs -TargetProjectRoot; there is no safe default, and guessing the current directory would register the hook in whatever folder the installer happened to run from.'))
        }
        return $TargetProjectRoot
    }
    # Global scope. KIRO_PROTOCOL.md marks ~/.kiro/hooks as INFERRED from the
    # confirmed CLI v3 path plus the ~/.kiro/skills and ~/.kiro/steering
    # pattern - implement it, but never document it as confirmed.
    foreach ($candidate in @($env:USERPROFILE, $env:HOME)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
    $profileRoot = [System.Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($profileRoot)) { return $profileRoot }
    throw (New-KiroRejection -Reason 'home-root-unresolved' -Detail (
            'Global scope needs a home directory, and neither USERPROFILE, HOME nor the UserProfile special folder resolved to one.'))
}

# ---- public: the managed document -----------------------------------------

# Builds the document for ONE logical installation. One entry per trigger, all
# in the single `hooks` array of one file.
#
# Rejects rather than degrades. An unsupported trigger throws with a named
# reason and produces NOTHING: silently dropping it would install a hook that
# is missing the gate the caller asked for, and remapping it onto Stop would
# be worse still, because Kiro documents Stop as non-blocking on both targeted
# surfaces (see capabilityNotes in _clientcapability.ps1).
#
# TimeoutSeconds is only checked for >= 1 here. Hook Maker's 5..600 policy
# lives in Install-Hook.ps1 with $script:MinHookTimeoutSeconds; a second copy
# would be a second policy that can drift. 0 is refused because Kiro reads it
# as "no timeout at all", which is never what a caller means by a timeout.
function New-KiroHookDocument {
    # AllowEmptyString/AllowEmptyCollection on mandatory parameters is
    # deliberate: without them PowerShell's binder rejects empty input with a
    # generic message, and the caller loses the named reason this module
    # exists to give them.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FriendlyName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Triggers,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ManagedId,
        [AllowEmptyString()][string]$Matcher = '',
        [bool]$Enabled = $true
    )

    if ([string]::IsNullOrWhiteSpace($FriendlyName)) {
        throw (New-KiroRejection -Reason 'friendly-name-empty' -Detail 'A hook needs a name Kiro can display.')
    }
    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw (New-KiroRejection -Reason 'command-empty' -Detail 'A command action with no command would register a hook that runs nothing.')
    }
    $friendlySlug = ConvertTo-KiroSlug -Text $FriendlyName
    if ([string]::IsNullOrWhiteSpace($friendlySlug)) {
        throw (New-KiroRejection -Reason 'friendly-name-unusable' -Detail (
                "FriendlyName '" + $FriendlyName + "' contains no [a-z0-9] characters, so no stable entry name can be derived from it."))
    }
    # Throws managed-id-unusable when the id cannot yield a provable identity.
    $namePrefix = Get-KiroManagedNamePrefix -ManagedId $ManagedId

    if ($TimeoutSeconds -lt 1) {
        throw (New-KiroRejection -Reason 'timeout-out-of-range' -Detail (
                'Timeout ' + [string]$TimeoutSeconds + ' is not a positive number of seconds; Kiro treats 0 as "no timeout".'))
    }

    $requested = @($Triggers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requested.Count -eq 0) {
        throw (New-KiroRejection -Reason 'triggers-empty' -Detail 'A hook with no trigger can never fire.')
    }

    if (-not [string]::IsNullOrWhiteSpace($Matcher)) {
        # v1 matchers are REGEX. The legacy 0.x format used globs, so the most
        # likely mistake here is a glob like *.ts - which is also an invalid
        # regex, and is caught by exactly this check rather than shipping to
        # Kiro as a pattern that never compiles.
        try {
            $null = New-Object System.Text.RegularExpressions.Regex -ArgumentList $Matcher
        }
        catch {
            throw (New-KiroRejection -Reason 'matcher-invalid-regex' -Detail (
                    "Matcher '" + $Matcher + "' is not a valid regex. v1 matchers are regular expressions, not the globs the legacy .kiro.hook format used."))
        }
    }

    $capability = Get-KiroCapability
    $matcherTriggers = Get-KiroMatcherEvaluatingTriggers
    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.List[string]

    foreach ($requestedTrigger in $requested) {
        $trimmed = ([string]$requestedTrigger).Trim()

        # Named separately from the generic unknown case on purpose: Kiro's own
        # pages contradict each other about whether the IDE still accepts
        # Manual, so a caller asking for it deserves that reason, not a bland
        # "unknown trigger".
        if ($trimmed -ieq 'Manual') {
            throw (New-KiroRejection -Reason 'trigger-manual-never-emitted' -Detail (
                    'Kiro documentation contradicts itself on whether the IDE still accepts a Manual trigger, so Hook Maker never emits one.'))
        }

        $logical = Resolve-HookMakerLogicalEvent -Name $trimmed
        if ($null -eq $logical) {
            throw (New-KiroRejection -Reason 'trigger-unknown' -Detail (
                    "'" + $trimmed + "' is not a Hook Maker logical event. Kiro-only triggers such as PostFileSave, PostFileCreate, PostFileDelete, PreTaskExec and PostTaskExec have no Hook Maker equivalent and are not installed."))
        }
        if (@($capability.supportedEvents | Where-Object { $_ -ceq $logical }).Count -eq 0) {
            throw (New-KiroRejection -Reason 'trigger-unsupported-by-kiro' -Detail (
                    "'" + $logical + "' has no documented Kiro trigger. Supported: " + (@($capability.supportedEvents) -join ', ') +
                    '. It is not silently dropped and never remapped onto Stop.'))
        }
        if (@($seen | Where-Object { $_ -ceq $logical }).Count -gt 0) {
            throw (New-KiroRejection -Reason 'trigger-duplicate' -Detail (
                    "'" + $logical + "' was requested more than once; two entries for one trigger in one file would run the hook twice."))
        }
        [void]$seen.Add($logical)

        $physical = $logical
        if ($capability.physicalEventMap.ContainsKey($logical)) {
            $physical = [string]$capability.physicalEventMap[$logical]
        }

        $entry = [ordered]@{
            name        = ($namePrefix + $friendlySlug + '-' + $physical.ToLowerInvariant())
            description = ($FriendlyName + ' - managed by Hook Maker; edit through Hook Maker, not by hand. ' + (Get-KiroManagedMarker -ManagedId $ManagedId))
            trigger     = $physical
        }
        # Rule: attach a matcher ONLY where the protocol confirms it is
        # evaluated. On the other triggers Kiro ignores it, and an ignored
        # filter reads to a maintainer as a restriction that is in force.
        if (-not [string]::IsNullOrWhiteSpace($Matcher) -and
            @($matcherTriggers | Where-Object { $_ -ceq $physical }).Count -gt 0) {
            $entry['matcher'] = $Matcher
        }
        # 'command' only. An 'agent' action appends a prompt to model context
        # and spawns no subprocess, so no exit code or stdout contract applies
        # to it - a Hook Maker runtime registered that way would never run.
        $entry['action'] = [pscustomobject][ordered]@{ type = 'command'; command = $Command }
        $entry['timeout'] = [int]$TimeoutSeconds
        $entry['enabled'] = [bool]$Enabled

        [void]$entries.Add(([pscustomobject]$entry))
    }

    return [pscustomobject][ordered]@{
        version = 'v1'
        hooks   = @($entries.ToArray())
    }
}

# The one safe way to serialize a Kiro document. -Depth is the whole point:
# Windows PowerShell defaults to 2, which turns `action` into the literal
# string "System.Management.Automation.PSCustomObject" without any error.
function ConvertTo-KiroHookJson {
    param([Parameter(Mandatory = $true)]$Document)
    return ($Document | ConvertTo-Json -Depth 12)
}

# ---- public: paths ---------------------------------------------------------

# <root>\.kiro\hooks\hookmaker-<friendly-slug>-<stable-short-id>.json
#
# StableId feeds the FILENAME only. It is deliberately independent of the
# ManagedId that proves ownership: a filename is a hint, and this module never
# treats it as evidence.
function Get-KiroRegistrationPath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('project', 'global')][string]$Scope,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FriendlyName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StableId,
        [AllowEmptyString()][string]$TargetProjectRoot = ''
    )
    $friendlySlug = ConvertTo-KiroSlug -Text $FriendlyName
    if ([string]::IsNullOrWhiteSpace($friendlySlug)) {
        throw (New-KiroRejection -Reason 'friendly-name-unusable' -Detail (
                "FriendlyName '" + $FriendlyName + "' contains no [a-z0-9] characters, so no stable filename can be derived from it."))
    }
    $shortId = ConvertTo-KiroSlug -Text $StableId
    if ([string]::IsNullOrWhiteSpace($shortId)) {
        throw (New-KiroRejection -Reason 'stable-id-unusable' -Detail (
                "StableId '" + $StableId + "' contains no [a-z0-9] characters, so no stable filename can be derived from it."))
    }
    # Truncated for a readable filename. A collision is not a correctness
    # problem: Test-KiroManagedFile proves ownership from the entries, so a
    # collided file reports foreign and is refused rather than overwritten.
    if ($shortId.Length -gt 12) { $shortId = $shortId.Substring(0, 12).Trim('-') }

    $capability = Get-KiroCapability
    $relative = if ($Scope -eq 'project') { [string]$capability.projectRegistration } else { [string]$capability.globalRegistration }
    $root = Resolve-KiroScopeRoot -Scope $Scope -TargetProjectRoot $TargetProjectRoot
    return (Join-Path (Join-Path $root $relative) ('hookmaker-' + $friendlySlug + '-' + $shortId + '.json'))
}

# <root>\.kiro\hook-runtime\Hook-Maker
#
# NOT under .kiro\hooks. That directory is Kiro's hook-config discovery root,
# so a copied .ps1 tree inside it would be scanned as configuration. The path
# comes from the capability table's runtimeRelativeRoot so there is exactly one
# place it is decided.
function Get-KiroRuntimeRoot {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('project', 'global')][string]$Scope,
        [AllowEmptyString()][string]$TargetProjectRoot = ''
    )
    $capability = Get-KiroCapability
    $root = Resolve-KiroScopeRoot -Scope $Scope -TargetProjectRoot $TargetProjectRoot
    return (Join-Path $root ([string]$capability.runtimeRelativeRoot))
}

# ---- public: ownership -----------------------------------------------------

# The managed filename pattern. Anything else - above all the shared
# .kiro\hooks\hooks.json, and any .hook / .kiro.hook legacy file - is refused
# outright, because Hook Maker must never become the owner of a document other
# hooks also live in.
function Test-KiroManagedFileName {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ((Split-Path -Leaf $Path) -match '^hookmaker-[a-z0-9-]+\.json$')
}

# Is this path safe for Hook Maker to write for this ManagedId?
#
# Ok is exactly that question, NOT "does Hook Maker already own it" - the
# caller needs to distinguish "our file", "brand new file" and "someone
# else's file", and Reason is what separates them:
#
#   Ok  Reason
#   --  ------
#   1   managed             at least one entry proven ours (may also hold foreign entries)
#   1   empty               valid v1 document with no entries at all - nothing to destroy
#   1   missing             no file yet
#   0   unmanaged-filename  not the managed pattern (hooks.json, *.kiro.hook, ...)
#   0   not-a-file          a directory sits at that path
#   0   foreign             entries exist, none of them ours - never claimed, never rewritten
#   0   invalid-json        unreadable as JSON
#   0   unexpected-schema   not a v1 document with a hooks array
#   0   unreadable          the file could not be read
#
# ManagedEntries/ForeignEntries hold the ORIGINAL parsed entry objects, so the
# caller can hand them straight to Merge-KiroManagedEntries without a
# re-serialization that could perturb foreign content.
function Test-KiroManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ManagedId
    )

    $result = [ordered]@{ Ok = $false; Reason = 'unreadable'; ManagedEntries = @(); ForeignEntries = @() }

    if (-not (Test-KiroManagedFileName -Path $Path)) {
        $result.Reason = 'unmanaged-filename'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Ok = $true
        $result.Reason = 'missing'
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Reason = 'not-a-file'
        return [pscustomobject]$result
    }

    try {
        # Explicit UTF-8. ReadAllText also strips a BOM if one is present,
        # which ConvertFrom-Json on Windows PowerShell would otherwise choke on.
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }
    catch {
        $result.Reason = 'unreadable'
        return [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.Reason = 'invalid-json'
        return [pscustomobject]$result
    }
    try {
        # Doubled parentheses: @($x | ConvertFrom-Json) does not enumerate on
        # Windows PowerShell, it yields one Object[].
        $document = ($raw | ConvertFrom-Json)
    }
    catch {
        $result.Reason = 'invalid-json'
        return [pscustomobject]$result
    }

    $classified = Split-KiroDocumentEntries -Document $document -ManagedId $ManagedId
    $result.Reason = $classified.Reason
    $result.ManagedEntries = @($classified.ManagedEntries)
    $result.ForeignEntries = @($classified.ForeignEntries)
    $result.Ok = ($classified.Reason -eq 'managed' -or $classified.Reason -eq 'empty')
    return [pscustomobject]$result
}

# Shared classifier for Test-KiroManagedFile and Merge-KiroManagedEntries, so
# "is this ours" is decided in exactly one place. Reason is one of
# managed / empty / foreign / unexpected-schema.
function Split-KiroDocumentEntries {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Document,
        [Parameter(Mandatory = $true)][string]$ManagedId
    )

    $owned = New-Object System.Collections.Generic.List[object]
    $foreign = New-Object System.Collections.Generic.List[object]

    if ($null -eq $Document) {
        return [pscustomobject]@{ Reason = 'empty'; ManagedEntries = @(); ForeignEntries = @() }
    }

    $version = Get-KiroEntryField -Entry $Document -Name 'version'
    # Legacy 0.x used version "1" with when/then/askAgent. Refusing anything
    # that is not exactly "v1" is what stops this module rewriting a legacy
    # file into a shape the IDE would then have to migrate again.
    if ($null -eq $version -or [string]$version -cne 'v1') {
        return [pscustomobject]@{ Reason = 'unexpected-schema'; ManagedEntries = @(); ForeignEntries = @() }
    }

    $hooksValue = Get-KiroEntryField -Entry $Document -Name 'hooks'
    if ($null -eq $hooksValue) {
        return [pscustomobject]@{ Reason = 'unexpected-schema'; ManagedEntries = @(); ForeignEntries = @() }
    }
    # `hooks` is an ARRAY in v1. A single object here is a hand-edit, not a
    # document this module may rewrite.
    if (-not ($hooksValue -is [System.Array])) {
        return [pscustomobject]@{ Reason = 'unexpected-schema'; ManagedEntries = @(); ForeignEntries = @() }
    }

    foreach ($entry in $hooksValue) {
        if (Test-KiroManagedEntry -Entry $entry -ManagedId $ManagedId) { [void]$owned.Add($entry) }
        else { [void]$foreign.Add($entry) }
    }

    $reason = 'empty'
    if ($owned.Count -gt 0) { $reason = 'managed' }
    elseif ($foreign.Count -gt 0) { $reason = 'foreign' }

    return [pscustomobject]@{
        Reason         = $reason
        ManagedEntries = @($owned.ToArray())
        ForeignEntries = @($foreign.ToArray())
    }
}

# Read-modify-write that preserves everything Hook Maker does not own.
#
# Returns a RESULT, not a bare document, because "ownership could not be
# proven" has to be expressible without an exception: it is an ordinary state
# of the user's disk, not a caller bug.
#
#   Ok  Reason
#   --  ------
#   1   created             no existing document (or an empty one) - fresh content
#   1   merged              managed entries replaced in place, foreign entries preserved
#   0   foreign             the document holds entries and none are ours - Document is $null
#   0   unexpected-schema   not a v1 document with a hooks array - Document is $null
#
# Foreign entries are carried across as the SAME OBJECT INSTANCES that were
# parsed, in their original relative order, so their ordering, enabled state,
# matcher, command, prompt and timeout cannot be perturbed by this function -
# there is no code path that reads them, let alone rewrites them.
#
# Managed entries are matched by entry `name`. A managed entry that is no
# longer in ManagedEntries is dropped: a re-install with fewer triggers must
# remove the trigger it dropped, and that entry is provably ours to remove.
function Merge-KiroManagedEntries {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$ExistingDocument,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ManagedEntries,
        [Parameter(Mandatory = $true)][string]$ManagedId
    )

    # Trust boundary: every incoming entry must already carry this
    # installation's identity. Writing one that does not would create a
    # registration no later run could prove it owns - an orphan that update
    # and uninstall would both have to leave behind forever.
    foreach ($incoming in @($ManagedEntries)) {
        if (-not (Test-KiroManagedEntry -Entry $incoming -ManagedId $ManagedId)) {
            throw (New-KiroRejection -Reason 'managed-entries-unidentified' -Detail (
                    "Entry '" + [string](Get-KiroEntryField -Entry $incoming -Name 'name') +
                    "' does not carry the identity for ManagedId '" + $ManagedId +
                    "'. Build entries with New-KiroHookDocument so ownership stays provable."))
        }
    }

    $classified = Split-KiroDocumentEntries -Document $ExistingDocument -ManagedId $ManagedId
    if ($classified.Reason -eq 'unexpected-schema' -or $classified.Reason -eq 'foreign') {
        return [pscustomobject][ordered]@{
            Ok             = $false
            Reason         = $classified.Reason
            Document       = $null
            ManagedEntries = @($classified.ManagedEntries)
            ForeignEntries = @($classified.ForeignEntries)
        }
    }

    $existingHooks = @()
    if ($null -ne $ExistingDocument) {
        $hooksValue = Get-KiroEntryField -Entry $ExistingDocument -Name 'hooks'
        if ($null -ne $hooksValue) { $existingHooks = @($hooksValue) }
    }

    $merged = New-Object System.Collections.Generic.List[object]
    $keptForeign = New-Object System.Collections.Generic.List[object]
    $consumed = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $existingHooks) {
        if (-not (Test-KiroManagedEntry -Entry $entry -ManagedId $ManagedId)) {
            # Untouched, by reference, at its original position.
            [void]$merged.Add($entry)
            [void]$keptForeign.Add($entry)
            continue
        }
        $existingName = [string](Get-KiroEntryField -Entry $entry -Name 'name')
        $replacement = @($ManagedEntries | Where-Object {
                [string](Get-KiroEntryField -Entry $_ -Name 'name') -ieq $existingName
            })
        if ($replacement.Count -gt 0) {
            [void]$merged.Add($replacement[0])
            [void]$consumed.Add($existingName)
        }
        # else: ours, but no longer requested - dropped.
    }

    $ownedOut = New-Object System.Collections.Generic.List[object]
    foreach ($incoming in @($ManagedEntries)) {
        $incomingName = [string](Get-KiroEntryField -Entry $incoming -Name 'name')
        if (@($consumed | Where-Object { $_ -ieq $incomingName }).Count -eq 0) {
            [void]$merged.Add($incoming)
        }
        [void]$ownedOut.Add($incoming)
    }

    $reason = 'created'
    if ($classified.Reason -eq 'managed') { $reason = 'merged' }

    return [pscustomobject][ordered]@{
        Ok             = $true
        Reason         = $reason
        Document       = [pscustomobject][ordered]@{ version = 'v1'; hooks = @($merged.ToArray()) }
        ManagedEntries = @($ownedOut.ToArray())
        ForeignEntries = @($keptForeign.ToArray())
    }
}
