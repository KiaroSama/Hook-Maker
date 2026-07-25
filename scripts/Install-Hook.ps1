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
# and merges documents but never touches the filesystem, so every write below
# stays visible in this file where the locking and rollback live.
. (Join-Path $PSScriptRoot '_installkiro.ps1')

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

function Install-IgnorePrePush {
    if ($FriendlyName -ne 'Ignore-Rules-Check' -or [string]::IsNullOrWhiteSpace($TargetProject)) { return }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $hooksPath = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $projectRoot, 'rev-parse', '--git-path', 'hooks'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksPath)) { return }
    if (-not [System.IO.Path]::IsPathRooted($hooksPath)) { $hooksPath = Join-Path $projectRoot $hooksPath }
    $hooksPath = [System.IO.Path]::GetFullPath($hooksPath)

    $runtimeRoot = Join-Path $hooksPath 'Hook-Maker'
    $runtime = Copy-HookRuntime -ClientDir $hooksPath -RuntimeRootOverride $runtimeRoot
    $oldWrongRoot = Join-Path (Split-Path -Parent $hooksPath) 'hooks\Hook-Maker'
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($oldWrongRoot), [System.IO.Path]::GetFullPath($runtimeRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($name in @('Ignore-Rules-Check', 'Secrets-Check', 'Large-File-Check')) {
            $stale = Join-Path $oldWrongRoot $name
            if (Test-Path -LiteralPath $stale -PathType Container) { Remove-Item -LiteralPath $stale -Recurse -Force }
        }
        if ((Test-Path -LiteralPath $oldWrongRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $oldWrongRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $oldWrongRoot -Force
        }
    }
    # Native companions go through the SAME canonical plan and transactional
    # staging as any other managed runtime, so they get a private _hooklib.ps1
    # and the matching dot-source rewrite. Copying just the script by hand left
    # the companion with no library to load once the shared root copy was
    # retired, which broke the real pre-push chain.
    function Copy-PrePushCompanion {
        param([Parameter(Mandatory = $true)][string]$Name)
        $sourceScript = Join-Path $ToolRoot ('hooks\' + $Name + '\' + $Name + '.ps1')
        if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) { throw "Pre-push check not found: $sourceScript" }
        $destinationDir = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $Name))
        if (-not (Test-PathContainedIn -ChildPath $destinationDir -ParentPath $runtimeRoot)) {
            throw "Unsafe pre-push runtime path: $destinationDir"
        }
        $companionPlan = Get-InstallPlanFor -HookScript $sourceScript -ToolRoot $ToolRoot -FriendlyNameOverride $Name
        Install-PlannedRuntime -Plan $companionPlan -RuntimeRoot $runtimeRoot -FriendlyName $Name | Out-Null
        return (Join-Path $destinationDir ($Name + '.ps1'))
    }
    # The canonical chain-companion list (30.md Part C): the ONE place the
    # managed stage set is decided. Everything downstream (expectedStages,
    # companions, sourceManifest, updater integrity, status, uninstall) derives
    # from the record this writes, so extending the chain is exactly this list.
    $chainCompanions = @('Secrets-Check', 'Utf8-Encoding-Check')
    $secretsScript = Copy-PrePushCompanion 'Secrets-Check'
    $utf8Script = Copy-PrePushCompanion 'Utf8-Encoding-Check'
    $staleLargeFileCheck = Join-Path $runtimeRoot 'Large-File-Check'
    if (Test-Path -LiteralPath $staleLargeFileCheck) {
        Remove-Item -LiteralPath $staleLargeFileCheck -Recurse -Force
    }
    $prePush = Join-Path $hooksPath 'pre-push'
    $previous = $prePush + '.hookmaker-existing'
    $marker = $script:PrePushMarker
    if (Test-Path -LiteralPath $prePush -PathType Leaf) {
        $current = [System.IO.File]::ReadAllText($prePush)
        if (-not $current.Contains($marker)) {
            if (Test-Path -LiteralPath $previous) { throw "Cannot preserve the existing pre-push hook because '$previous' already exists." }
            # Move, never copy-and-rewrite: the user's hook is preserved as
            # opaque BYTES (it may be binary, or have no trailing newline).
            Move-Item -LiteralPath $prePush -Destination $previous
        }
    }
    # "Did a user hook ever exist here?" is STICKY. If we recorded one before
    # and the file has since vanished, we must not silently rewrite history to
    # previousHookPreserved=false - that would erase the fact that a user hook
    # is expected and let a rebuilt wrapper quietly drop the stage. It becomes
    # an unresolved state the updater reports for manual attention instead.
    $previousExistsNow = Test-Path -LiteralPath $previous -PathType Leaf
    $previousEverPreserved = $previousExistsNow
    $previousMissing = $false
    try {
        $existingRecord = Get-InstallRecordById -ToolRoot $ToolRoot -Id (Get-InstallRecordId -FriendlyName $FriendlyName -ScopeKey ($projectRoot.ToLowerInvariant()) -ProfileId ([string]$Profile))
        if ($null -ne $existingRecord -and
            $null -ne $existingRecord.PSObject.Properties['nativeGit'] -and $null -ne $existingRecord.nativeGit -and
            $null -ne $existingRecord.nativeGit.PSObject.Properties['previousHookPreserved'] -and
            $existingRecord.nativeGit.previousHookPreserved -eq $true) {
            $previousEverPreserved = $true
            $previousMissing = (-not $previousExistsNow)
        }
    }
    catch { }

    # ONE canonical generator (see New-PrePushWrapperBody) produces these bytes,
    # and the updater's integrity check rebuilds them with the same function to
    # compare exactly - so the wrapper's stdin buffering, stage order,
    # fail-closed `|| exit $?`, cleanup trap and previous-hook invocation can
    # never drift apart from what we verify.
    # Chain order is the canonical contract: Ignore -> Secrets -> Utf8 ->
    # preserved previous user hook (30.md Part C).
    $managedStages = @($runtime.Script, $secretsScript, $utf8Script)
    $body = New-PrePushWrapperBody -ManagedScripts $managedStages
    [System.IO.File]::WriteAllText($prePush, $body, $Utf8NoBom)
    Write-Host "Native git pre-push protection installed in: $prePush"

    # Record what this chain manages so the updater can detect a stale managed
    # companion (e.g. a changed Secrets-Check source) as drift of THIS logical
    # installation. The preserved previous hook is tracked by path/existence
    # only - it is user-owned and is never hashed or rewritten.
    $script:NativeGitState = [pscustomobject][ordered]@{
        managed               = $true
        hooksPath             = $hooksPath
        runtimeRoot           = $runtimeRoot
        wrapperPath           = $prePush
        previousHookPath      = $previous
        # Sticky: once true, stays true. previousHookMissing records that the
        # user's preserved hook has since disappeared, so the updater surfaces
        # it for manual attention instead of quietly forgetting it ever existed.
        previousHookPreserved = $previousEverPreserved
        previousHookMissing   = $previousMissing
        expectedStages        = @($managedStages)
        wrapperBodyHash       = (Get-ShortHash $body)
        companions            = @($chainCompanions)
        sourceManifest        = @(Get-NativePrePushSourceManifest -ToolRoot $ToolRoot -PrimaryFriendlyName $FriendlyName -PrimaryHookScript $HookScript -PrimarySourceDir $SourceDir -Companions $chainCompanions)
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
    $claudeRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $ClaudeSettings)
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
    $codexRuntime = Copy-HookRuntime -ClientDir (Split-Path -Parent $CodexHooks)
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
# Kiro is registrationKind 'perHookFile': one JSON document per hook under
# .kiro\hooks, NOT a shared settings file. So there is no Add-HookGroup /
# Remove-StaleHandlers path here - ownership is proved per ENTRY by the marker
# _installkiro.ps1 embeds, and foreign entries in the same document are carried
# across by reference and never rewritten.
#
# Every failure below fails ONE component and lets the other clients finish.
# Nothing here throws, because a Kiro problem must not discard a completed
# Claude or Codex install.
$kiroRegistrationPath = ''
$kiroManagedNames = @()
$kiroSupported = @()
$kiroUnsupported = @()
$kiroDegraded = @()
$kiroRuntime = $null
$kiroCommands = $null
# Initialized before the lock so a refusal inside it cannot leave this unset -
# reading an unassigned variable throws under StrictMode.
$script:KiroWrittenNames = @()
$script:KiroRegistrationWritten = $false
if ($InstallKiro) {
    $script:CurrentPhase = 'kiro'
    try {
        $kiroCapability = Get-HookMakerClientCapability -ClientId 'kiro'
        # Kiro documents 5 of the 12 logical events. An unsupported event is
        # reported by NAME rather than dropped silently, and is never remapped
        # onto a different trigger - a hook the user believes gates Stop, but
        # which was quietly moved to SessionStart, is worse than one that
        # openly did not install.
        foreach ($requested in @($Events)) {
            if (@($kiroCapability.supportedEvents | Where-Object { $_ -ceq $requested }).Count -gt 0) {
                $kiroSupported += $requested
            }
            else { $kiroUnsupported += $requested }
        }
        # Kiro cannot hard-block at Stop on EITHER targeted surface (see
        # .ai/KIRO_PROTOCOL.md). This is permanent for Kiro, not conditional, so
        # it is recorded as a degraded reason rather than presented as a gate.
        if (@($kiroSupported | Where-Object { $_ -ceq 'Stop' }).Count -gt 0) {
            $kiroDegraded += 'degraded-stop-gate'
        }

        if ($kiroSupported.Count -eq 0) {
            Set-ComponentResult -Component 'kiro' -Status 'failed' -ReasonCode 'noSupportedEvents' `
                -Message ('None of the requested events (' + (@($Events) -join ', ') +
                    ') has a documented Kiro trigger. Supported: ' + (@($kiroCapability.supportedEvents) -join ', ') + '.')
            Write-Host ('Kiro skipped - no requested event has a documented Kiro trigger. Supported: ' +
                (@($kiroCapability.supportedEvents) -join ', ') + '.')
        }
        else {
            $kiroRuntimeRoot = Get-KiroRuntimeRoot -Scope $ScopeLabel -TargetProjectRoot $KiroTargetRoot
            # RuntimeRootOverride, because Kiro's runtime must NOT live under
            # .kiro\hooks: that directory is Kiro's hook-config discovery root,
            # so a copied .ps1 tree inside it would be scanned as configuration.
            # -IncludeKiroLauncher: the launcher is part of the PLAN, so it is
            # staged transactionally, hash-verified and recorded in the install
            # manifest. Writing it here afterwards (the first version of this)
            # left a real file no artifact accounted for, so every later
            # evaluation reported "unexpected managed file" and the updater
            # reinstalled Kiro forever. See Get-ManagedInstallPlan.
            $kiroRuntime = Copy-HookRuntime -ClientDir $kiroRuntimeRoot -RuntimeRootOverride $kiroRuntimeRoot -IncludeKiroLauncher
            $kiroLauncherPath = Join-Path (Split-Path -Parent $kiroRuntime.Script) 'kiro-launch.ps1'
            if (-not (Test-Path -LiteralPath $kiroLauncherPath -PathType Leaf)) {
                throw ('The Kiro launcher was not produced by the install plan at ' + $kiroLauncherPath +
                    '. Nothing was registered.')
            }

            # Built from the launcher, not the hook script, and carrying the
            # same -ConfigPath/-Profile suffix the other clients use.
            $kiroLauncherRuntime = [pscustomobject]@{
                Script = $kiroLauncherPath
                Config = $kiroRuntime.Config
                Plan   = $kiroRuntime.Plan
            }
            $kiroCommands = New-HookCommands -Runtime $kiroLauncherRuntime

            $kiroRegistrationPath = Get-KiroRegistrationPath -Scope $ScopeLabel -FriendlyName $FriendlyName `
                -StableId $RecordId -TargetProjectRoot $KiroTargetRoot

            Invoke-WithResourceLock -ResourcePath $kiroRegistrationPath -Action {
                $existingDocument = $null
                if (Test-Path -LiteralPath $kiroRegistrationPath -PathType Leaf) {
                    $raw = [System.IO.File]::ReadAllText($kiroRegistrationPath, [System.Text.Encoding]::UTF8)
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        # Extra parentheses are load-bearing: @($x | ConvertFrom-Json)
                        # yields ONE opaque Object[] on Windows PowerShell 5.1
                        # whose PSObject.Properties is empty, so every field
                        # read below would silently return $null.
                        try { $existingDocument = (($raw | ConvertFrom-Json)) }
                        catch { $existingDocument = $null }
                    }
                }

                # ONE ENTRY AT A TIME, because each entry needs its OWN command:
                # KIRO_PROTOCOL requires the physical trigger to be passed
                # explicitly, and Kiro IDE documents no stdin JSON at all, so a
                # hook that is registered on three triggers with one shared
                # command line has no way to tell which one fired. Building the
                # whole document in a single call would produce exactly that.
                $builtEntries = @()
                foreach ($logicalEvent in @($kiroSupported)) {
                    $physicalTrigger = $logicalEvent
                    if ($kiroCapability.physicalEventMap.ContainsKey($logicalEvent)) {
                        $physicalTrigger = [string]$kiroCapability.physicalEventMap[$logicalEvent]
                    }
                    # -Trigger is a declared launcher parameter, so it is consumed
                    # there and the -ConfigPath/-Profile suffix still reaches the
                    # hook through @args untouched.
                    $perTriggerCommand = $kiroCommands.Windows + ' -Trigger ' + $physicalTrigger
                    $builtDocument = New-KiroHookDocument -FriendlyName $FriendlyName -Command $perTriggerCommand `
                        -Triggers @($logicalEvent) -TimeoutSeconds $script:EffectiveTimeout -ManagedId $RecordId
                    $builtEntries += @($builtDocument.hooks)
                }
                $merged = Merge-KiroManagedEntries -ExistingDocument $existingDocument `
                    -ManagedEntries @($builtEntries) -ManagedId $RecordId
                if (-not $merged.Ok) {
                    # 'foreign' / 'unexpected-schema': the file at our path holds
                    # entries that are not ours. Refuse it rather than overwrite
                    # someone else's registrations.
                    throw ('Kiro registration file ' + $kiroRegistrationPath + ' is not safe to write (' +
                        $merged.Reason + '). Nothing was changed.')
                }
                Backup-File $kiroRegistrationPath
                Write-JsonFile -Value $merged.Document -Path $kiroRegistrationPath
                $script:KiroWrittenNames = @($merged.ManagedEntries | ForEach-Object { [string]$_.name })
                # Set LAST, and only inside the lock: past this line the
                # registration file exists on disk, so no later failure may be
                # reported as 'registrationRefused' - that would tell a user
                # nothing was installed while their .kiro\hooks entry is live.
                $script:KiroRegistrationWritten = $true
            }
            $kiroManagedNames = @($script:KiroWrittenNames)

            # 'ok' with recorded degradation, NOT a 'partial' component status.
            # The component genuinely succeeded for every trigger Kiro supports;
            # what was reduced is captured durably in the record's
            # unsupportedEvents/degradedReasons, and 'partial' is the OVERALL
            # result's vocabulary, not a component's.
            $kiroNotes = @()
            if ($kiroUnsupported.Count -gt 0) { $kiroNotes += ('no Kiro trigger for: ' + ($kiroUnsupported -join ', ')) }
            if ($kiroDegraded.Count -gt 0) { $kiroNotes += ($kiroDegraded -join ', ') }
            if ($kiroNotes.Count -gt 0) {
                Set-ComponentResult -Component 'kiro' -Status 'ok' -ReasonCode 'degraded' `
                    -Message ('Kiro installed with reduced capability - ' + ($kiroNotes -join '; ') + '.')
                Write-Host ('Kiro hook (' + $ScopeLabel + ') installed with reduced capability: ' + ($kiroNotes -join '; ') + '.')
            }
            else {
                Set-ComponentResult -Component 'kiro' -Status 'ok'
            }
            Write-Host "Kiro hook ($ScopeLabel) registered in: $kiroRegistrationPath"
            Write-Host "Kiro runtime copy: $($kiroRuntime.Script)"
        }
    }
    catch {
        # Includes every New-KiroRejection this module raises (unknown trigger,
        # invalid matcher regex, unusable name, foreign file). The reason text
        # is preserved verbatim: it names the exact thing to fix.
        #
        # The two cases are reported differently ON PURPOSE. Before the write,
        # nothing was installed and 'registrationRefused' is the truth. AFTER
        # the write the registration is live, so reporting a refusal would send
        # the user looking for a hook that is in fact registered - it is
        # 'postRegistrationError' instead, and it names the file to inspect.
        if ($script:KiroRegistrationWritten) {
            Set-ComponentResult -Component 'kiro' -Status 'ok' -ReasonCode 'postRegistrationError' `
                -Message ('Kiro was registered in ' + $kiroRegistrationPath +
                    ', but a later step failed: ' + [string]$_.Exception.Message)
            Write-Host ('WARNING: Kiro was registered in ' + $kiroRegistrationPath +
                ', but a later step failed: ' + [string]$_.Exception.Message)
        }
        else {
            Set-ComponentResult -Component 'kiro' -Status 'failed' -ReasonCode 'registrationRefused' `
                -Message ([string]$_.Exception.Message)
            Write-Host ('Kiro registration refused: ' + [string]$_.Exception.Message)
        }
    }
}

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
        targetProjectRoot = if ($ScopeLabel -eq 'project') { $projectRoot } else { '' }
        profile           = [string]$Profile
        configPath        = if ($isEngine) { $ConfigPath } else { '' }
        sourceManifest    = $sourceManifest
        clients           = $clientSubrecords
        nativeGit         = $nativeGit
        lastUpdatedUtc    = [DateTime]::UtcNow.ToString('o')
        lastResult        = 'ok'
        lastReason        = 'installed'
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
# tracking failed is 'partial', not success.
$failedComponents = @($script:ComponentResults | Where-Object { $_.status -eq 'failed' })
$trackingFailed = @($script:ComponentResults | Where-Object { $_.status -eq 'trackingFailed' })
$okComponents = @($script:ComponentResults | Where-Object { $_.status -eq 'ok' })
# Components are INDEPENDENT, so a failure among them is only a total failure
# when nothing else landed. A request for three clients where two are installed
# and one is unsupported is 'partial' - reporting it 'failed' would tell the
# caller to discard two working installations, and reporting it 'ok' would
# claim an install that never happened. Both are wrong in opposite directions.
$overallResult = if ($failedComponents.Count -gt 0 -and $okComponents.Count -eq 0) { 'failed' }
elseif ($failedComponents.Count -gt 0 -or $trackingFailed.Count -gt 0) { 'partial' }
else { 'ok' }
Write-InstallResult -Overall $overallResult

Write-Host 'Restart the clients and review /hooks. Codex may require trusting the new command.'
