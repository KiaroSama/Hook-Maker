param(
    [string]$Profile,
    [string[]]$Events = @('SessionStart', 'UserPromptSubmit'),
    [string]$ConfigPath,
    # When set, install into this project's local settings instead of the user's
    # home directory: <project>/.claude/settings.local.json + <project>/.codex/hooks.json.
    [string]$TargetProject,
    # Path to a standalone hook script (from the hooks/ folder). Installs it plain,
    # without the sync engine's -ConfigPath/-Profile arguments.
    [string]$CustomHook,
    # The canonical, POSITIVE client selection: -Clients claude,codex,kiro.
    #
    # The two -*Only switches below are kept as backward-compatible shims for
    # existing scripts and tests, but they cannot be the core model: they were
    # consumed as DOUBLE NEGATIONS (`if (-not $CodexOnly)` meaning "install
    # Claude"), so a third client was silently IGNORED rather than rejected.
    # Three negative flags do not compose. Everything resolves into one explicit
    # set before any mutation.
    [string[]]$Clients,
    [switch]$ClaudeOnly,
    [switch]$CodexOnly,
    # Per-hook registration timeout in SECONDS, written into each client's own
    # handler entry (both clients document `timeout` per hook entry - see the
    # bounds comment in _installlib.ps1). OMIT IT for the historical behaviour:
    # an omitted value keeps whatever this installation already had, and 60 when
    # there is nothing recorded, so every existing install is byte-identical.
    # A value outside $script:MinHookTimeoutSeconds..$script:MaxHookTimeoutSeconds
    # is REJECTED before anything is written, never clamped.
    [Nullable[int]]$Timeout,
    # When set, a machine-readable result document is written here describing
    # the outcome of EACH component (validation, runtime, settings, native git,
    # registry). Programmatic callers - the updater - consume this instead of
    # inferring success from console text or from the mere absence of an
    # exception, which cannot distinguish "fully installed" from "installed but
    # tracking failed".
    [string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- structured outcome ----------------------------------------------------
# Component results are accumulated here and written to -ResultPath. States:
#   ok            - the component was applied and verified
#   failed        - the component could not be applied
#   skipped       - not applicable to this invocation (e.g. client not selected)
#   trackingFailed- runtime/settings succeeded but the registry write did not
$script:ComponentResults = New-Object System.Collections.Generic.List[object]
function Set-ComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'failed', 'skipped', 'trackingFailed')][string]$Status,
        [string]$ReasonCode = '',
        [string]$Message = ''
    )
    # Sanitized message only: never raw file contents, .env values or stdin.
    [void]$script:ComponentResults.Add([pscustomobject][ordered]@{
        component = $Component
        status    = $Status
        reason    = $ReasonCode
        message   = $Message
        atUtc     = [DateTime]::UtcNow.ToString('o')
    })
}
function Write-InstallResult {
    param([string]$Overall)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $document = [pscustomobject][ordered]@{
            schema     = 1
            overall    = $Overall
            components = @($script:ComponentResults.ToArray())
            atUtc      = [DateTime]::UtcNow.ToString('o')
        }
        $directory = Split-Path -Parent $ResultPath
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ResultPath, ($document | ConvertTo-Json -Depth 20), ([System.Text.UTF8Encoding]::new($false)))
    }
    catch {
        # A result-file failure must never fail the install itself.
    }
}

# THE one definition of the overall verdict. It used to be computed inline at
# the very end, while the install RECORD hardcoded lastResult='ok' 50 lines
# earlier - so a partial or failed outcome still persisted a record claiming
# success. Two places deciding the same thing is how they disagree; there is
# now one, called by both.
#
# States:
#   ok      every component landed exactly what was asked for
#   partial something landed, but less than was asked for (a failed component
#           alongside a working one, a degraded client, or tracking that failed)
#   failed  nothing the caller asked for is installed
function Get-OverallInstallResult {
    $failed = @($script:ComponentResults | Where-Object { $_.status -eq 'failed' })
    $trackingFailed = @($script:ComponentResults | Where-Object { $_.status -eq 'trackingFailed' })
    # A component that landed with LESS than it was asked for is still 'ok' at
    # the component level - component statuses are exactly ok/failed/skipped/
    # trackingFailed, and 'partial' is the OVERALL result's vocabulary, not a
    # component's. That distinction is deliberate, so degradation is read off the
    # REASON CODE instead:
    #   degraded              installed, but with unsupported events dropped and/or
    #                         a gate that can only ever be advisory (Kiro Stop)
    #   postRegistrationError the registration IS live, but a later step failed -
    #                         the one that must never read as a clean 'ok'
    $degraded = @($script:ComponentResults | Where-Object {
            $_.status -eq 'ok' -and @('degraded', 'postRegistrationError') -contains [string]$_.reason })
    # ONLY CLIENT components answer "did anything the caller asked for actually
    # land". 'registry' and 'nativeGit' are BOOKKEEPING, and counting them as
    # landed work inverted the verdict: a kiro-only install whose kiro component
    # FAILED still had an ok 'registry' component, so the total failure was
    # downgraded to 'partial' - telling the caller to keep an installation that
    # does not exist. The client set is derived from the capability table, never
    # a third hardcoded list beside the two this repo already keeps in sync.
    $clientIds = @(Get-HookMakerClientIds)
    $okClients = @($script:ComponentResults | Where-Object {
            $_.status -eq 'ok' -and @($clientIds) -contains [string]$_.component })
    # Components are INDEPENDENT, so a failure among them is only a total failure
    # when no client landed. A request for three clients where two are installed
    # and one is unsupported is 'partial' - reporting it 'failed' would tell the
    # caller to discard two working installations, and reporting it 'ok' would
    # claim an install that never happened. Both are wrong in opposite directions.
    if ($failed.Count -gt 0 -and $okClients.Count -eq 0) { return 'failed' }
    if ($failed.Count -gt 0 -or $trackingFailed.Count -gt 0 -or $degraded.Count -gt 0) { return 'partial' }
    return 'ok'
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$ToolRoot = Split-Path -Parent $PSScriptRoot
# Shared: Get-HookFriendlyName (folder/file naming). This is install-time only;
# the runtime hooks ignore it.
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
# Install-state registry (install-time only - deliberately NOT in _hooklib.ps1,
# which is copied into every self-contained runtime).
. (Join-Path $PSScriptRoot '_installlib.ps1')
# The ONE canonical client/event capability table. This file used to carry its
# own $ValidEvents list which had fallen 3 events behind the wizard's, so the
# wizard could offer an event this script then refused.
. (Join-Path $PSScriptRoot '_clientcapability.ps1')
# Canonical managed-install plan: safe source classification, transactional
# runtime replacement, and the single Hook Maker registration-ownership parser.
. (Join-Path $PSScriptRoot '_installplan.ps1')
# The self-contained runtime copy this install registers (and the command lines
# that point at it).
. (Join-Path $PSScriptRoot '_installruntime.ps1')
# The read-modify-write of one client settings file: stale-handler pruning,
# handler-group insertion, backup, and the transactional JSON replace.
. (Join-Path $PSScriptRoot '_installclientsettings.ps1')
# Kiro's per-hook-file registration format. A PURE module: it builds, classifies
# and merges documents but never touches the filesystem. The locking, rollback
# and every actual Kiro write live in _installkiroclient.ps1, which is
# dot-sourced further down AT the point the Kiro phase runs.
. (Join-Path $PSScriptRoot '_installkiro.ps1')
# The native Git pre-push chain (Install-IgnorePrePush), for the one hook that
# also manages a real .git/hooks/pre-push wrapper. Defines a function only; the
# phase that calls it runs near the end of this script.
. (Join-Path $PSScriptRoot '_installnativegit.ps1')

# ---- guarantee a structured result on ANY terminal outcome -----------------
# A validation/runtime/settings/native failure used to exit before
# Write-InstallResult was ever reached, so -ResultPath produced no document at
# all on the very failures callers most need to distinguish. `trap { ...;
# break }` runs on ANY terminating error from this point on (including ones
# thrown inside a called function), then `break` lets the error propagate
# exactly as it would have without the trap - same non-zero exit code, same
# printed exception text, same "do not swallow the original exception". This
# is deliberately NOT a script-wide try/catch/finally: that would require
# re-indenting the entire body, which is an unrelated, larger-blast-radius
# change than guaranteeing the result document.
$script:CurrentPhase = 'validation'
trap {
    $failedPhase = if ($null -ne $script:CurrentPhase -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentPhase)) { [string]$script:CurrentPhase } else { 'unknown' }
    # Only record a failure for a phase that hasn't already reported 'ok' -
    # a phase either completes and records its own result, or it throws; it
    # never does both, so this is defensive rather than load-bearing.
    $alreadyOk = @($script:ComponentResults | Where-Object { $_.component -eq $failedPhase -and $_.status -eq 'ok' })
    if ($alreadyOk.Count -eq 0) {
        $sanitizedMessage = [string]$_.Exception.Message
        if ($sanitizedMessage.Length -gt 500) { $sanitizedMessage = $sanitizedMessage.Substring(0, 500) + '...' }
        Set-ComponentResult -Component $failedPhase -Status 'failed' -ReasonCode 'exception' -Message $sanitizedMessage
    }
    # Write-InstallResult swallows its OWN internal errors, so a failure to
    # write the result file here can never suppress the original exception
    # that `break` is about to (re-)propagate.
    Write-InstallResult -Overall 'failed'
    break
}

# ---- input validation ------------------------------------------------------
# Everything is validated BEFORE any runtime, settings, registry or native git
# state is touched, so an invalid invocation leaves the machine untouched
# instead of half-applying (or recording a tracked install with no client).
if ($ClaudeOnly -and $CodexOnly) {
    throw '-ClaudeOnly and -CodexOnly are mutually exclusive. Omit both to install for both clients.'
}

# ---- resolve ONE canonical client set --------------------------------------
# Every later decision reads $InstallClaude/$InstallCodex/$InstallKiro. Nothing
# below re-derives the selection from a switch, so a client can no longer be
# silently skipped by a negation that does not know about it.
$legacyOnlySwitchUsed = ($ClaudeOnly -or $CodexOnly)
if ($PSBoundParameters.ContainsKey('Clients') -and $legacyOnlySwitchUsed) {
    throw '-Clients cannot be combined with -ClaudeOnly/-CodexOnly. Use -Clients on its own.'
}
$resolvedClients = $null
if ($PSBoundParameters.ContainsKey('Clients')) {
    $requested = @(@($Clients) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    if ($requested.Count -eq 0) {
        throw ('-Clients was empty. Accepted client ids: ' + ((Get-HookMakerClientIds) -join ', ') + '.')
    }
    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $requested) {
        # Get-HookMakerClientCapability throws on an unknown id, which is the
        # required fail-closed behaviour: an unrecognised client must never widen
        # or narrow the set silently.
        $capability = Get-HookMakerClientCapability -ClientId $candidate
        if (-not $normalized.Contains($capability.id)) { [void]$normalized.Add($capability.id) }
    }
    $resolvedClients = @($normalized.ToArray())
}
elseif ($ClaudeOnly) { $resolvedClients = @('claude') }
elseif ($CodexOnly) { $resolvedClients = @('codex') }
else {
    # Historical default, preserved EXACTLY: no switches meant Claude + Codex.
    # It deliberately does NOT become all three - that would start installing a
    # third client into every existing caller's projects without being asked.
    $resolvedClients = @('claude', 'codex')
}
$InstallClaude = ($resolvedClients -contains 'claude')
$InstallCodex = ($resolvedClients -contains 'codex')
$InstallKiro = ($resolvedClients -contains 'kiro')

# Components are independent: a request for three clients where two succeed is
# 'partial', not a total refusal. That rule is why an unsupported Kiro request
# fails ONE component instead of throwing - the client menu offers Claude,
# Codex, Kiro and All with no Claude+Codex entry, so throwing on kiro also broke
# 'All clients' and left no way to install two clients in one pass.
$ValidEvents = @(Get-HookMakerLogicalEvents)
$normalizedEvents = New-Object System.Collections.Generic.List[string]
foreach ($rawEvent in @($Events)) {
    $candidate = ([string]$rawEvent).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    # Case-insensitive match, canonical spelling written out - unchanged
    # behaviour, but the list now has exactly one definition repo-wide.
    $canonical = Resolve-HookMakerLogicalEvent $candidate
    if ($null -eq $canonical) {
        throw ("Unsupported hook event '" + $candidate + "'. Supported events: " + ($ValidEvents -join ', ') + '.')
    }
    if (-not $normalizedEvents.Contains($canonical)) { [void]$normalizedEvents.Add($canonical) }
}
if ($normalizedEvents.Count -eq 0) {
    throw 'At least one hook event is required (-Events).'
}
$Events = $normalizedEvents.ToArray()

# Bounds are checked HERE, in the pre-mutation validation block, so an
# out-of-range value can never half-apply: it is rejected before any runtime,
# settings, registry or native git file is touched. Rejected, not clamped - a
# silently-clamped timeout would register something the caller never asked for.
if ($null -ne $Timeout) {
    if ($Timeout -lt $script:MinHookTimeoutSeconds -or $Timeout -gt $script:MaxHookTimeoutSeconds) {
        throw ('Hook timeout ' + [string]$Timeout + ' is out of range. -Timeout must be between ' +
            [string]$script:MinHookTimeoutSeconds + ' and ' + [string]$script:MaxHookTimeoutSeconds +
            ' seconds, or omitted to use ' + [string]$script:DefaultHookTimeoutSeconds + '.')
    }
}

if (-not [string]::IsNullOrWhiteSpace($TargetProject)) {
    $resolvedTarget = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($TargetProject))
    if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
        throw ("Target project directory does not exist: " + $resolvedTarget)
    }
}

if (-not [string]::IsNullOrWhiteSpace($CustomHook)) {
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        throw '-CustomHook and -Profile cannot be combined.'
    }
    $HookScript = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CustomHook))
    if (-not (Test-Path -LiteralPath $HookScript -PathType Leaf)) {
        throw "Custom hook script not found: $HookScript"
    }
}
else {
    $HookScript = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'hooks\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'))
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath((Join-Path $ToolRoot 'sync-hooks.json'))
}
else {
    $ConfigPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
}

# A direct ENGINE install (-CustomHook absent) must prove its config exists,
# parses, is structurally valid, and - when a profile is requested - that the
# profile exists, BEFORE any directory, backup, settings, runtime, registry or
# native file is touched. Reuses the SAME structural rules Validate-Config.ps1
# enforces (Test-SyncConfigStructure in _installlib.ps1) rather than a second,
# potentially-drifting copy of that logic.
if ([string]::IsNullOrWhiteSpace($CustomHook)) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Sync config not found: $ConfigPath"
    }
    $rawSyncConfig = ''
    try { $rawSyncConfig = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) }
    catch { throw ("Could not read sync config '" + $ConfigPath + "': " + $_.Exception.Message) }
    $parsedSyncConfig = $null
    try { $parsedSyncConfig = $rawSyncConfig | ConvertFrom-Json }
    catch { throw ("Sync config '" + $ConfigPath + "' is not valid JSON: " + $_.Exception.Message) }
    $syncConfigStructure = Test-SyncConfigStructure -Config $parsedSyncConfig
    if (-not $syncConfigStructure.Ok) {
        throw ("Sync config '" + $ConfigPath + "' is invalid: " + $syncConfigStructure.Reason)
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        # Test-SyncConfigStructure already proved every profile id is unique,
        # so finding one match IS "exists exactly once" - a second match would
        # mean two profiles share an id, which structural validation above
        # would already have rejected.
        $matchingProfiles = @($parsedSyncConfig.profiles | Where-Object { [string]$_.id -eq $Profile })
        if ($matchingProfiles.Count -eq 0) {
            throw ("Profile '" + $Profile + "' was not found in sync config '" + $ConfigPath + "'.")
        }
        # Test-SyncConfigStructure already proved 'routes' exists and is a real
        # array for every profile; an EMPTY one is structurally valid there
        # (a whole-file validation must tolerate an emptied-out group it is not
        # installing). Installing THIS profile is different: a zero-route engine
        # install produces a hook that provably cannot sync anything plus an
        # empty generated SYNC-PROJECTS.txt - a silently useless installation.
        # Rejected here, before any directory, backup, settings, runtime,
        # registry or native file is touched.
        if (@($matchingProfiles[0].routes).Count -eq 0) {
            throw ("Profile '" + $Profile + "' in sync config '" + $ConfigPath + "' has no routes; an engine install requires at least one route.")
        }
    }
}

# How this source is installed. A folder counts as a hook PACKAGE only when it
# is a direct child of a recognized hooks root; any other script installs
# standalone (that one file), so pointing -CustomHook at a script inside an
# unrelated project can never copy that project's .git/.env/credentials/source
# into a settings-registered runtime directory.
$SourceInfo = Get-HookSourceInfo -HookScript $HookScript -PackageRoots @((Join-Path $ToolRoot 'hooks'))
$SourceDir = if ($SourceInfo.Kind -eq 'Package') { $SourceInfo.PackageRoot } else { Split-Path -Parent $SourceInfo.ScriptPath }
$SourceName = $SourceInfo.Name
$FriendlyName = Get-HookFriendlyName $SourceName

if (-not [string]::IsNullOrWhiteSpace($TargetProject)) {
    $projectRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($TargetProject))
    # settings.local.json (not settings.json): the command holds a machine-specific
    # absolute path, so it must stay out of source control.
    $ClaudeSettings = Join-Path $projectRoot '.claude\settings.local.json'
    $CodexHooks = Join-Path $projectRoot '.codex\hooks.json'
    $ScopeLabel = 'project'
    # Kiro resolves its own roots from the capability table, so it takes the
    # project root rather than a path assembled here.
    $KiroTargetRoot = $projectRoot
}
else {
    $ClaudeSettings = Join-Path $HOME '.claude\settings.json'
    $CodexHooks = Join-Path $HOME '.codex\hooks.json'
    $ScopeLabel = 'global'
    $KiroTargetRoot = ''
}
$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
# Hoisted above the client phases because Kiro needs it DURING its install, not
# only when the registry is written: it is the ManagedId that makes each Kiro
# entry provably ours, and the StableId its filename is derived from. The
# registry block below reuses this exact value - computing it twice would let
# the recorded id and the registered id drift apart, and ownership is the one
# thing uninstall cannot re-derive from anywhere else.
$ScopeKey = if ($ScopeLabel -eq 'project') { $projectRoot.ToLowerInvariant() } else { 'global' }
$RecordId = Get-InstallRecordId -FriendlyName $FriendlyName -ScopeKey $ScopeKey -ProfileId ([string]$Profile)
# Hoisted for the same reason as $RecordId: $projectRoot is assigned ONLY on the
# project branch above, so under StrictMode every later reader of it needs this
# one guarded derivation rather than repeating the scope test. It feeds each
# client's runtime-metadata identity AND the record's own targetProjectRoot, which
# must be the same value - the metadata's projectKey is what a runtime hook
# compares against the project it is running in.
$RecordProjectRoot = if ($ScopeLabel -eq 'project') { $projectRoot } else { '' }
# Resolved once: this tool root plus every tool root previously recorded in the
# registry. Only registrations provably rooted under one of these may be
# claimed as ours when they use the historical tool-folder layout.
$script:KnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)
# Set by Install-IgnorePrePush when this install also manages a native Git
# pre-push chain; stays $null for every other hook (StrictMode-safe default).
$script:NativeGitState = $null

# ---- effective per-hook timeout -------------------------------------------
# Resolution order, still BEFORE any file is touched:
#   1. an explicit -Timeout (already bounds-validated above);
#   2. otherwise the timeout this same installation ALREADY has recorded;
#   3. otherwise 60, exactly as every previously shipped version wrote.
#
# Step 2 is what makes repair correct. "Update previously installed hooks"
# re-invokes this script from the RECORD (events, scope, profile, config) and
# does not pass -Timeout, so without it, repairing any drift - even unrelated
# command drift - would silently reset a hook's own timeout back to 60 and call
# that "up to date". An out-of-range or non-numeric recorded value is ignored
# rather than propagated, so a hand-edited registry cannot install a value this
# script would refuse on the command line.
$script:EffectiveTimeout = $script:DefaultHookTimeoutSeconds
if ($null -ne $Timeout) {
    $script:EffectiveTimeout = [int]$Timeout
}
else {
    try {
        $priorScopeKey = if ($ScopeLabel -eq 'project') { $projectRoot.ToLowerInvariant() } else { 'global' }
        $priorRecord = Get-InstallRecordById -ToolRoot $ToolRoot `
            -Id (Get-InstallRecordId -FriendlyName $FriendlyName -ScopeKey $priorScopeKey -ProfileId ([string]$Profile))
        if ($null -ne $priorRecord) {
            # The client THIS invocation is installing decides, so a -CodexOnly
            # repair cannot inherit Claude's value (they are written identically,
            # but a partially-repaired record must never cross-contaminate).
            # Only the client(s) actually being installed are ever consulted -
            # never a fallback to the other client's subrecord.
            $priorClients = @($resolvedClients)
            foreach ($priorClientName in $priorClients) {
                $priorSubrecord = Get-ClientSubrecord -Record $priorRecord -Client $priorClientName
                if ($null -eq $priorSubrecord -or $null -eq $priorSubrecord.PSObject.Properties['timeout']) { continue }
                $priorTimeout = 0
                if (-not [int]::TryParse([string]$priorSubrecord.timeout, [ref]$priorTimeout)) { continue }
                if ($priorTimeout -lt $script:MinHookTimeoutSeconds -or $priorTimeout -gt $script:MaxHookTimeoutSeconds) { continue }
                $script:EffectiveTimeout = $priorTimeout
                break
            }
        }
    }
    catch {
        # An unreadable registry must never fail an install; the default stands.
    }
}

$status = if (-not [string]::IsNullOrWhiteSpace($CustomHook)) {
    'Running custom hook: ' + (Split-Path -Leaf $HookScript)
}
elseif ([string]::IsNullOrWhiteSpace($Profile)) {
    'Checking configured project sync hooks'
}
else {
    'Checking sync profile: ' + $Profile
}

if ($InstallClaude) {
    $script:CurrentPhase = 'claude'
    # Each client gets its own runtime copy so its command has zero dependency
    # on the Hook Maker folder (or on the other client's files).
    $claudeRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $ClaudeSettings) `
        -RuntimeIdentity (New-RuntimeIdentity -Client 'claude' -Scope $ScopeLabel -RecordId $RecordId -ProjectRoot $RecordProjectRoot)
    $claudeCommands = New-HookCommands -Runtime $claudeRuntime
    # The whole read-modify-write is held under a crash-aware lock on THIS
    # settings file, so two installs touching the same file cannot lose each
    # other's handlers. Locks are taken one at a time (Claude, then Codex,
    # then the registry) and never nested, so no deadlock cycle can form.
    Invoke-WithResourceLock -ResourcePath $ClaudeSettings -Action {
        $claude = Read-OrCreateJsonObject $ClaudeSettings
        $claudeHooks = Ensure-Property -Object $claude -Name 'hooks' -DefaultValue ([pscustomobject]@{})
        # Prune this hook's old registrations from EVERY event (a re-install may
        # use fewer events, and old entries can point into the old tool folder).
        # Member enumeration (.Properties.Name) throws under StrictMode when the
        # object has no properties yet, so collect the names explicitly.
        $existingEvents = @()
        foreach ($property in $claudeHooks.PSObject.Properties) { $existingEvents += $property.Name }
        foreach ($existingEvent in $existingEvents) {
            Remove-StaleHandlers -HooksObject $claudeHooks -EventName $existingEvent
        }
        foreach ($eventName in $Events) {
            $handler = [pscustomobject][ordered]@{ type = 'command'; command = $claudeCommands.Windows; timeout = $script:EffectiveTimeout }
            $group = if ($eventName -eq 'SessionStart') {
                [pscustomobject][ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @($handler) }
            }
            else {
                [pscustomobject][ordered]@{ hooks = @($handler) }
            }
            Add-HookGroup -HooksObject $claudeHooks -EventName $eventName -Group $group -ExactCommand $claudeCommands.Windows
        }
        Backup-File $ClaudeSettings
        Write-JsonFile -Value $claude -Path $ClaudeSettings
    }
    Set-ComponentResult -Component 'claude' -Status 'ok'
    Write-Host "Claude hook ($ScopeLabel) installed in: $ClaudeSettings"
    Write-Host "Claude runtime copy: $($claudeRuntime.Script)"
}

if ($InstallCodex) {
    $script:CurrentPhase = 'codex'
    $codexRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $CodexHooks) `
        -RuntimeIdentity (New-RuntimeIdentity -Client 'codex' -Scope $ScopeLabel -RecordId $RecordId -ProjectRoot $RecordProjectRoot)
    $codexCommands = New-HookCommands -Runtime $codexRuntime
    # The whole read-modify-write is held under a crash-aware lock on THIS
    # settings file, so two installs touching the same file cannot lose each
    # other's handlers. Locks are taken one at a time (Claude, then Codex,
    # then the registry) and never nested, so no deadlock cycle can form.
    Invoke-WithResourceLock -ResourcePath $CodexHooks -Action {
        $codex = Read-OrCreateJsonObject $CodexHooks
        $codexHooksObject = Ensure-Property -Object $codex -Name 'hooks' -DefaultValue ([pscustomobject]@{})
        $existingEvents = @()
        foreach ($property in $codexHooksObject.PSObject.Properties) { $existingEvents += $property.Name }
        foreach ($existingEvent in $existingEvents) {
            Remove-StaleHandlers -HooksObject $codexHooksObject -EventName $existingEvent
        }
        foreach ($eventName in $Events) {
            $handler = [pscustomobject][ordered]@{
                type = 'command'
                command = $codexCommands.Portable
                commandWindows = $codexCommands.Windows
                timeout = $script:EffectiveTimeout
                statusMessage = $status
            }
            $group = if ($eventName -eq 'SessionStart') {
                [pscustomobject][ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @($handler) }
            }
            else {
                [pscustomobject][ordered]@{ hooks = @($handler) }
            }
            Add-HookGroup -HooksObject $codexHooksObject -EventName $eventName -Group $group -ExactCommand $codexCommands.Windows
        }
        Backup-File $CodexHooks
        Write-JsonFile -Value $codex -Path $CodexHooks
    }
    Set-ComponentResult -Component 'codex' -Status 'ok'
    Write-Host "Codex hook ($ScopeLabel) installed in: $CodexHooks"
    Write-Host "Codex runtime copy: $($codexRuntime.Script)"
}

# ---- kiro -----------------------------------------------------------------
# Dot-sourced HERE rather than with the module group at the top, because this
# module is not only function definitions: it carries the whole `if
# ($InstallKiro)` phase, so this line is WHERE the Kiro install runs - between
# the Codex block above and the native-git phase below. It also defines the
# runtime rollback the phase depends on. See the file's own header for why it
# is separate from _installkiro.ps1.
. (Join-Path $PSScriptRoot '_installkiroclient.ps1')

$script:CurrentPhase = 'nativeGit'
Install-IgnorePrePush
# Native chain is only part of some installs; record which.
if ($null -ne $script:NativeGitState) { Set-ComponentResult -Component 'nativeGit' -Status 'ok' }
else { Set-ComponentResult -Component 'nativeGit' -Status 'skipped' -ReasonCode 'notApplicable' }

$script:CurrentPhase = 'registry'
# ---- install registry -----------------------------------------------------
# The hook/settings/native files above are already correctly written by this
# point, so a registry failure never fails the install itself - but it is NOT
# silent either: tracking failure is reported explicitly, because an untracked
# install cannot be refreshed by "Update previously installed hooks".
#
# ONLY the clients this invocation actually installed are recorded. Each keeps
# its own events/matcher/command/timeout/runtime paths, so a later -CodexOnly
# install can never rewrite what Claude has registered (and vice versa).
# Stores paths and content hashes only - never .env values, secrets, hook
# stdin, prompt text, tool input, or any copied file's contents.
try {
    # $ScopeKey/$RecordId are computed once near the top, because Kiro needs the
    # record id DURING its install as the ManagedId that proves entry ownership.
    # They are used directly here rather than copied into $scopeKey/$recordId:
    # PowerShell variable names are case-INSENSITIVE, so those would be the SAME
    # variables, and this project has already shipped one bug from exactly that
    # ($Clients vs $clients silently coercing the record to a String[]).
    $hookType = if ([string]::IsNullOrWhiteSpace($CustomHook)) { 'Engine' } else { 'CustomHook' }
    $isEngine = ($hookType -eq 'Engine')

    $sourceManifest = @(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $HookScript -SourceDir $SourceDir -FriendlyName $FriendlyName -ConfigPath $ConfigPath -IncludeConfig:$isEngine -ProfileId ([string]$Profile))

    # NOT named $clients. PowerShell variable names are case-INSENSITIVE, so a
    # local $clients is the SAME variable as the [string[]]$Clients parameter -
    # and a parameter's type constraint keeps applying to later assignments, so
    # `$clients = [pscustomobject]@{}` was silently COERCED into a String[].
    # Every subrecord written onto it then vanished, and the record shipped with
    # no clients at all. Verified on pwsh 7 and Windows PowerShell 5.1.
    $clientSubrecords = [pscustomobject][ordered]@{}
    if ($InstallClaude) {
        $claudeRoot = Split-Path -Parent $claudeRuntime.Script
        $claudeRuntimeRoot = Split-Path -Parent $claudeRoot
        Set-ObjectProperty -Object $clientSubrecords -Name 'claude' -Value (New-ClientSubrecord `
            -SettingsPath $ClaudeSettings `
            -RuntimeRoot $claudeRuntimeRoot `
            -RuntimeScript $claudeRuntime.Script `
            -Events @($Events) `
            -Command $claudeCommands.Windows `
            -HandlerType 'command' `
            -Timeout $script:EffectiveTimeout `
            -InstalledManifest @(Get-InstalledManifest -RuntimeRoot $claudeRuntimeRoot -FriendlyName $FriendlyName))
    }
    if ($InstallCodex) {
        $codexRoot = Split-Path -Parent $codexRuntime.Script
        $codexRuntimeRoot = Split-Path -Parent $codexRoot
        Set-ObjectProperty -Object $clientSubrecords -Name 'codex' -Value (New-ClientSubrecord `
            -SettingsPath $CodexHooks `
            -RuntimeRoot $codexRuntimeRoot `
            -RuntimeScript $codexRuntime.Script `
            -Events @($Events) `
            -Command $codexCommands.Portable `
            -CommandWindows $codexCommands.Windows `
            -HandlerType 'command' `
            -StatusMessage $status `
            -Timeout $script:EffectiveTimeout `
            -InstalledManifest @(Get-InstalledManifest -RuntimeRoot $codexRuntimeRoot -FriendlyName $FriendlyName))
    }
    # Recorded ONLY when the registration file was actually written. A failed or
    # refused Kiro component leaves $kiroRegistrationPath empty and writes no
    # subrecord, so uninstall can never be handed a path nothing was installed
    # at. registrationKind/registrationPath/managedEntryNames are what make a
    # per-hook-file client removable: there is no shared settings document to
    # scan, so the entry names ARE the ownership proof.
    if ($InstallKiro -and -not [string]::IsNullOrWhiteSpace($kiroRegistrationPath) -and $kiroManagedNames.Count -gt 0) {
        $kiroRuntimeRoot = Split-Path -Parent (Split-Path -Parent $kiroRuntime.Script)
        Set-ObjectProperty -Object $clientSubrecords -Name 'kiro' -Value (New-ClientSubrecord `
            -SettingsPath $kiroRegistrationPath `
            -RuntimeRoot $kiroRuntimeRoot `
            -RuntimeScript $kiroRuntime.Script `
            -Events @($kiroSupported) `
            -Command $kiroCommands.Windows `
            -HandlerType 'command' `
            -Timeout $script:EffectiveTimeout `
            -RegistrationKind 'perHookFile' `
            -RegistrationPath $kiroRegistrationPath `
            -ManagedEntryNames @($kiroManagedNames) `
            -UnsupportedEvents @($kiroUnsupported) `
            -DegradedReasons @($kiroDegraded) `
            -InstalledManifest @(Get-InstalledManifest -RuntimeRoot $kiroRuntimeRoot -FriendlyName $FriendlyName))
    }

    $nativeGit = $null
    if ($null -ne $script:NativeGitState) { $nativeGit = $script:NativeGitState }

    # The record's verdict is DERIVED, never hardcoded. It used to say
    # lastResult='ok'/lastReason='installed' unconditionally, 50 lines before
    # $overallResult was computed, so a record could persist "ok" for an install
    # whose only requested client had failed.
    #
    # 'registry' is deliberately not among the components consulted here: its
    # status is the outcome of the very write this record is the payload of, so
    # it cannot be known yet - and a registry failure means this record does not
    # land at all. Everything else already has its verdict, and the final
    # document below re-runs the same function once the registry does too.
    $recordResult = Get-OverallInstallResult
    $recordReason = switch ($recordResult) {
        'ok' { 'installed' }
        'failed' { 'no requested client was installed' }
        default { 'installed with reduced or failed components' }
    }

    $record = [pscustomobject][ordered]@{
        id                = $RecordId
        schema            = 2
        internalName      = $SourceName
        friendlyName      = $FriendlyName
        hookType          = $hookType
        sourceScript      = $HookScript
        sourceDir         = $SourceDir
        # The Hook Maker tool root this install came from. Recorded so a later
        # version can PROVE that a historical tool-folder registration belongs
        # to Hook Maker (rather than guessing from path shape) even after the
        # tool has been moved - see Get-KnownToolRoots.
        toolRoot          = $ToolRoot
        scope             = $ScopeLabel
        targetProjectRoot = $RecordProjectRoot
        profile           = [string]$Profile
        configPath        = if ($isEngine) { $ConfigPath } else { '' }
        sourceManifest    = $sourceManifest
        clients           = $clientSubrecords
        nativeGit         = $nativeGit
        lastUpdatedUtc    = [DateTime]::UtcNow.ToString('o')
        lastResult        = $recordResult
        lastReason        = $recordReason
        lastError         = ''
        # Sanitized per-component outcomes for this attempt; Set-InstallRecord
        # folds them into the record's bounded history.
        lastComponents    = @($script:ComponentResults.ToArray() | ForEach-Object {
            [pscustomobject][ordered]@{ component = [string]$_.component; status = [string]$_.status; reason = [string]$_.reason }
        })
        needsManualRepair = $false
    }
    $registryResult = Update-InstallRegistry -ToolRoot $ToolRoot -Record $record
    if (-not $registryResult.Ok) {
        Write-Host ('WARNING: the hook was installed, but tracking it FAILED - ' + $registryResult.Warning)
        Write-Host 'WARNING: "Update previously installed hooks" will not see this installation until it is reinstalled.'
        # Runtime and settings ARE applied; only tracking failed. The caller
        # must be able to tell those apart, so this is its own state.
        Set-ComponentResult -Component 'registry' -Status 'trackingFailed' -ReasonCode 'registryWriteFailed' -Message ([string]$registryResult.Warning)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($registryResult.Warning)) {
        Write-Host ('WARNING: ' + $registryResult.Warning)
        Set-ComponentResult -Component 'registry' -Status 'ok' -ReasonCode 'warning' -Message ([string]$registryResult.Warning)
    }
    else {
        Set-ComponentResult -Component 'registry' -Status 'ok'
    }
}
catch {
    Write-Host ('WARNING: the hook was installed, but the local install registry could not be updated: ' + $_.Exception.Message)
    Write-Host 'WARNING: "Update previously installed hooks" will not see this installation until it is reinstalled.'
    Set-ComponentResult -Component 'registry' -Status 'trackingFailed' -ReasonCode 'registryException' -Message $_.Exception.Message
}

# Overall state is derived from the component results, never from the absence
# of an exception: an install whose runtime and settings landed but whose
# tracking failed is 'partial', not success. Same function the record above
# used, now that the registry component has its verdict too - so the persisted
# record and this document cannot claim different outcomes for one install.
$overallResult = Get-OverallInstallResult
Write-InstallResult -Overall $overallResult

Write-Host 'Restart the clients and review /hooks. Codex may require trusting the new command.'
