# ONE canonical description of every client Hook Maker installs for.
#
# WHY THIS FILE EXISTS
# There used to be two independent lists of hook event names:
#   Setup-SyncGroup.ps1   $knownEvents  - 12 events, what the wizard OFFERS
#   Install-Hook.ps1      $ValidEvents  -  9 events, what the installer ACCEPTS
# So the UI could call an event known, hand it to the installer, and the
# installer would throw. PermissionRequest, PostCompact and SubagentStart were
# each reachable through the wizard's custom-list path and each fatal on
# install. All three are REAL, currently-documented Claude Code events (verified
# against code.claude.com/docs/en/hooks.md), so the 9-entry list was the stale
# side of that pair, not the 12-entry one.
#
# Everything that needs to know about a client or an event derives from here:
# menu/event selection, installer validation, per-client event mapping, status,
# update, registry validation, docs and tests. A second copy of any of this data
# is a defect, not an optimization.
#
# Dot-source it; do not Import-Module. Callers read $script:-scoped tables
# through the functions below rather than touching them directly.

# ---- canonical client identity ---------------------------------------------
# Two spellings exist on purpose and must not be mixed up:
#   ID        lowercase ('claude') - persisted in the install registry, used for
#             record subkeys and path derivation. Changing one breaks records.
#   SELECTION PascalCase ('Claude') - what the wizard menu returns and what a
#             CLIENTS= config value holds. User-facing.
$script:HookMakerClientIds = @('claude', 'codex', 'kiro')

# ---- canonical logical events ----------------------------------------------
# Hook Maker's OWN event vocabulary. A client maps these to its physical names.
# Deliberately the 12 the wizard already offered: Claude Code currently
# documents 30 events, but supporting the other 18 would mean encoding a
# per-event output contract for each (WorktreeCreate must return worktreePath,
# MessageDisplay only honours displayContent, ...). That is a separate piece of
# work; widening this list without those contracts would install handlers that
# silently never do anything useful.
$script:HookMakerLogicalEvents = @(
    'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop',
    'SubagentStop', 'PreCompact', 'SessionEnd', 'Notification',
    'PermissionRequest', 'PostCompact', 'SubagentStart'
)

# ---- per-client capability records -----------------------------------------
# registrationKind is the field that stops Kiro being forced into a
# Claude/Codex shape:
#   sharedSettingsFile - ONE settings file holds every hook for that client, so
#                        installing is a read-modify-write of a shared document
#                        and ownership is per-handler-entry.
#   perHookFile        - each logical install owns its OWN file, so ownership is
#                        per-file plus per-entry, and a generic shared filename
#                        would risk owning the user's entries.
$script:HookMakerClientCapabilities = @{

    'claude' = [ordered]@{
        id                    = 'claude'
        selectionValue        = 'Claude'
        displayName           = 'Claude'
        registrationKind      = 'sharedSettingsFile'
        projectRegistration   = '.claude\settings.local.json'
        globalRegistration    = '.claude\settings.json'
        runtimeRelativeRoot   = '.claude\hooks\Hook-Maker'
        timeoutField          = 'timeout'
        timeoutUnits          = 'seconds'
        matcherSupported      = $true
        actionTypes           = @('command')
        inputProtocol         = 'stdinJson'
        outputProtocol        = 'claudeHookSpecificOutput'
        # Present so a future round can add events without touching call sites.
        physicalEventMap      = @{}
        # No drift: this is exactly the set the installer accepts today once its
        # stale 9-entry list is replaced by the canonical one.
        supportedEvents       = $script:HookMakerLogicalEvents
        blockCapableEvents    = @(
            'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop',
            'SubagentStop', 'PreCompact', 'PermissionRequest'
        )
        capabilityNotes       = @()
    }

    'codex' = [ordered]@{
        id                    = 'codex'
        selectionValue        = 'Codex'
        displayName           = 'Codex'
        registrationKind      = 'sharedSettingsFile'
        projectRegistration   = '.codex\hooks.json'
        globalRegistration    = '.codex\hooks.json'
        runtimeRelativeRoot   = '.codex\hooks\Hook-Maker'
        timeoutField          = 'timeout'
        timeoutUnits          = 'seconds'
        matcherSupported      = $true
        actionTypes           = @('command')
        inputProtocol         = 'stdinJson'
        outputProtocol        = 'codexSystemMessage'
        physicalEventMap      = @{}
        # Held at the full canonical set DELIBERATELY. Codex's public hook
        # reference is fragmented, and the one survey available suggests its
        # event set may omit SessionEnd and Notification - but that evidence is
        # explicitly uncertain, and Hook Maker writes handlers for both today.
        # Narrowing this on uncertain evidence would be silent behaviour drift
        # for existing installs, which this round forbids. Recorded as a note
        # instead so a later round can settle it with primary documentation.
        supportedEvents       = $script:HookMakerLogicalEvents
        blockCapableEvents    = @('UserPromptSubmit', 'PreToolUse', 'Stop', 'SubagentStop')
        capabilityNotes       = @(
            'SessionEnd and Notification support is not confirmed by primary Codex documentation.'
        )
    }

    'kiro' = [ordered]@{
        id                    = 'kiro'
        selectionValue        = 'Kiro'
        displayName           = 'Kiro'
        # One managed JSON file per logical install under .kiro/hooks/. The
        # runtime must NOT live there: that directory is Kiro's hook-config
        # discovery root, so a copied .ps1 tree inside it would be scanned as
        # configuration.
        registrationKind      = 'perHookFile'
        projectRegistration   = '.kiro\hooks'
        globalRegistration    = '.kiro\hooks'
        runtimeRelativeRoot   = '.kiro\hook-runtime\Hook-Maker'
        timeoutField          = 'timeout'
        timeoutUnits          = 'seconds'
        matcherSupported      = $true
        # A bare matcherSupported=$true is TRUE BUT MISLEADING for Kiro, and a
        # caller acting on it alone would attach a matcher where Kiro silently
        # ignores it - a filter that does nothing reads as a restriction that is
        # in force. Kiro evaluates a matcher only on these triggers; everywhere
        # else it is not consulted. Documented in .ai/KIRO_PROTOCOL.md.
        #
        # This lives in the table rather than only inside the Kiro writer
        # because that is the drift this table exists to prevent: the writer
        # already enforced it, but a second caller reading the table would not
        # have known.
        matcherEvaluatingEvents = @('PreToolUse', 'PostToolUse')
        actionTypes           = @('command', 'agent')
        # Kiro IDE documents NO stdin JSON and no cwd/session_id/tool_name for
        # shell-command hooks - only USER_PROMPT, and only on UserPromptSubmit.
        # CLI v3 does send stdin JSON but does not publish its field names. So
        # event identity is passed EXPLICITLY on the launcher command line and
        # stdin is strict-decoded only when present. See .ai/KIRO_PROTOCOL.md.
        inputProtocol         = 'explicitTriggerArgument'
        outputProtocol        = 'kiroExitCodeAndStdout'
        # Logical -> physical. Identity mappings today, but the indirection is
        # load-bearing: Kiro renamed every trigger between CLI v2 (camelCase)
        # and the current v1 schema (PascalCase).
        physicalEventMap      = @{
            'SessionStart'     = 'SessionStart'
            'UserPromptSubmit' = 'UserPromptSubmit'
            'PreToolUse'       = 'PreToolUse'
            'PostToolUse'      = 'PostToolUse'
            'Stop'             = 'Stop'
        }
        # Only these five have a documented Kiro equivalent. The other seven are
        # NOT silently dropped and NOT remapped onto Stop - callers must report
        # them as an explicit degraded component result.
        supportedEvents       = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop')
        # Stop is ABSENT on purpose and it is the most consequential entry in
        # this file. Kiro IDE's trigger table says Stop cannot block, and CLI v3
        # dropped v2's stdout decision JSON entirely. Only the legacy CLI v2
        # embedded format could block at Stop, and Hook Maker does not target
        # it. Every Stop-gate hook must therefore record degraded-stop-gate for
        # Kiro permanently rather than conditionally.
        blockCapableEvents    = @('PreToolUse', 'UserPromptSubmit')
        capabilityNotes       = @(
            'Stop is advisory only: Kiro IDE and CLI v3 both document Stop as non-blocking.',
            'Kiro IDE hook input is undocumented beyond USER_PROMPT; session id is normally absent, so session-keyed deduplication degrades instead of pairing wrongly.',
            'The global hooks path ~/.kiro/hooks is inferred from CLI v3 plus the ~/.kiro/skills and ~/.kiro/steering pattern; it is not confirmed by primary IDE documentation.',
            'Kiro-only triggers PreTaskExec, PostTaskExec, PostFileCreate, PostFileSave and PostFileDelete have no Hook Maker logical equivalent and are not installed.',
            'The Manual trigger is never emitted: Kiro documentation contradicts itself on whether the IDE still accepts it.'
        )
    }
}

function Get-HookMakerClientIds {
    return @($script:HookMakerClientIds)
}

function Get-HookMakerLogicalEvents {
    return @($script:HookMakerLogicalEvents)
}

# Returns the CANONICAL spelling of an event name, or $null when it is not a
# Hook Maker logical event.
#
# Matching is case-INSENSITIVE but the return value is always canonical. That
# combination is deliberate and preserves the installer's existing contract: a
# user may type 'sessionstart', and what gets written into a client config is
# 'SessionStart'. Client configs ARE case-sensitive about trigger names, so
# writing the user's spelling through unchanged would install a handler that
# never fires. Callers test the result for $null rather than pre-validating.
function Resolve-HookMakerLogicalEvent {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $match = @($script:HookMakerLogicalEvents | Where-Object { $_ -eq ([string]$Name).Trim() })
    if ($match.Count -eq 0) { return $null }
    return $match[0]
}

# Throws on an unknown id rather than returning $null: every caller uses the
# result immediately, and under StrictMode a $null here surfaces as a confusing
# property-not-found error far from the real mistake.
function Get-HookMakerClientCapability {
    param([Parameter(Mandatory = $true)][string]$ClientId)
    $key = ([string]$ClientId).Trim().ToLowerInvariant()
    if (-not $script:HookMakerClientCapabilities.ContainsKey($key)) {
        throw ("Unknown client '" + $ClientId + "'. Known clients: " + (($script:HookMakerClientIds) -join ', ') + '.')
    }
    return $script:HookMakerClientCapabilities[$key]
}

# Resolves any client selection to an explicit, ordered, de-duplicated id set.
#
# FAILS CLOSED. The config path used to treat an unrecognised CLIENTS= value as
# "both", so a typo like CLIENTS=Cluade installed MORE clients than asked for.
# An unknown value now throws before anything is written.
#
# 'Both' keeps its historical meaning - Claude + Codex, never Kiro - because
# existing .env files and recorded installs contain it. 'All' is the new value
# that includes Kiro.
function Resolve-HookMakerClientSet {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $raw = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'A client selection is required. Accepted values: Claude, Codex, Kiro, All (legacy: Both = Claude + Codex).'
    }
    switch ($raw.ToLowerInvariant()) {
        'claude' { return @('claude') }
        'codex' { return @('codex') }
        'kiro' { return @('kiro') }
        'all' { return @('claude', 'codex', 'kiro') }
        'both' { return @('claude', 'codex') }
        default {
            throw ("Unknown client selection '" + $raw + "'. Accepted values: Claude, Codex, Kiro, All (legacy: Both = Claude + Codex).")
        }
    }
}

function Get-HookMakerClientSelectionValues {
    return @('Claude', 'Codex', 'Kiro', 'All')
}

# Per-client breakdown of a requested event list.
#
# Returns one entry per client with Supported/Unsupported arrays plus the
# physical trigger names, and an overall Degraded flag. Callers use Degraded to
# decide 'partial' instead of 'ok': installing 3 of 5 requested events is not a
# success, and reporting it as one is how a missing gate goes unnoticed.
#
# Unknown event names are rejected by the caller BEFORE this is used - this
# function assumes every name already passed Test-HookMakerLogicalEvent.
function Resolve-HookMakerEventPlan {
    param(
        [Parameter(Mandatory = $true)][string[]]$Events,
        [Parameter(Mandatory = $true)][string[]]$ClientIds
    )
    $perClient = New-Object System.Collections.Generic.List[object]
    $degraded = $false
    foreach ($clientId in @($ClientIds)) {
        $capability = Get-HookMakerClientCapability -ClientId $clientId
        $supported = New-Object System.Collections.Generic.List[string]
        $unsupported = New-Object System.Collections.Generic.List[string]
        $physical = New-Object System.Collections.Generic.List[object]
        foreach ($eventName in @($Events)) {
            if (@($capability.supportedEvents | Where-Object { $_ -ceq $eventName }).Count -gt 0) {
                [void]$supported.Add($eventName)
                $physicalName = $eventName
                if ($capability.physicalEventMap.ContainsKey($eventName)) {
                    $physicalName = [string]$capability.physicalEventMap[$eventName]
                }
                [void]$physical.Add([pscustomobject][ordered]@{ logical = $eventName; physical = $physicalName })
            }
            else {
                [void]$unsupported.Add($eventName)
                $degraded = $true
            }
        }
        [void]$perClient.Add([pscustomobject][ordered]@{
            clientId    = $capability.id
            displayName = $capability.displayName
            supported   = @($supported.ToArray())
            unsupported = @($unsupported.ToArray())
            physical    = @($physical.ToArray())
        })
    }
    return [pscustomobject][ordered]@{
        perClient = @($perClient.ToArray())
        degraded  = $degraded
    }
}

# True only when the client actually EVALUATES a matcher on that event.
#
# `matcherSupported` alone is not enough to act on: a client can support
# matchers in general and still ignore one on a specific event, and attaching a
# filter that is never consulted reads as a restriction that is in force when it
# is not. A client that declares no per-event restriction keeps its previous
# behaviour - the matcher applies wherever the event itself is supported.
function Test-HookMakerEventMatcher {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$EventName
    )
    $capability = Get-HookMakerClientCapability -ClientId $ClientId
    if (-not $capability.matcherSupported) { return $false }
    if (@($capability.supportedEvents | Where-Object { $_ -ceq $EventName }).Count -eq 0) { return $false }
    if (-not $capability.Contains('matcherEvaluatingEvents')) { return $true }
    return (@($capability.matcherEvaluatingEvents | Where-Object { $_ -ceq $EventName }).Count -gt 0)
}

# True only when the client documents a real block/deny mechanism for that
# event. A Stop-gate hook asks this before claiming enforcement: answering
# optimistically would advertise a hard gate that the platform ignores.
function Test-HookMakerEventBlocking {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$EventName
    )
    $capability = Get-HookMakerClientCapability -ClientId $ClientId
    return (@($capability.blockCapableEvents | Where-Object { $_ -ceq $EventName }).Count -gt 0)
}
