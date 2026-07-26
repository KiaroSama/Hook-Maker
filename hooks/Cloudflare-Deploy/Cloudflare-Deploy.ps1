# CloudflareDeploy - after a task ends (Stop), reminds the agent to work
# through BOTH a deployment-worthiness decision and post-deployment
# verification. The AI decides; nothing is deployed or verified automatically
# by this script - it never deploys merely because a wrangler config exists.
#
# The decision is gated on actual RELEASE READINESS (deterministic repo/CI/
# cleanup state), never on menu position or hook registration order - Stop
# hooks for the same event may run concurrently, so this hook never assumes
# it runs "after" Git-Sync-Check, Ci-Status-Check, or Test-Temp-Cleanup. It
# stays completely silent (no reminder at all this Stop) when the working
# tree is dirty, the branch is ahead/unpushed, the exact release commit isn't
# known to be pushed, CI exists but is not verified green for that exact SHA,
# or Test-Temp-Cleanup (when installed for this project) has not reported a
# fresh `clean` result for the CURRENT repo state. If Test-Temp-Cleanup races
# on the same Stop and hasn't recorded yet, this hook simply stays silent and
# re-evaluates on the next Stop - it never loops or retries within one
# invocation.
#
# Token-efficient by design:
# - Fires only in projects with a wrangler config (wrangler.toml/.json/.jsonc)
#   AND only when release-readiness actually holds.
# - Respects stop_hook_active (never loops) and a per-project cooldown.
#
# Optional .env next to this script (copy .env.example):
#   DEPLOY_COMMAND    the deploy command to suggest (default: npx wrangler deploy)
#   COOLDOWN_MINUTES  minimum minutes between reminders per project (default 30)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\_hooklib.ps1')

$hookInput = Read-HookInput
if ($null -eq $hookInput) {
    exit 0
}
if ((Get-Field $hookInput 'stop_hook_active') -eq $true) {
    exit 0
}
# Only used to shape the result (Write-HookResult below). This is a Stop-only
# hook, so an absent event name reads as 'Stop' rather than as "no event".
$eventName = [string](Get-Field $hookInput 'hook_event_name')
if ([string]::IsNullOrWhiteSpace($eventName)) { $eventName = 'Stop' }
$cwd = [string](Get-Field $hookInput 'cwd')
if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) {
    exit 0
}

# Only Cloudflare Workers projects.
$wranglerConfig = $null
foreach ($candidate in @('wrangler.toml', 'wrangler.jsonc', 'wrangler.json')) {
    $path = Join-Path $cwd $candidate
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $wranglerConfig = $candidate
        break
    }
}
if ($null -eq $wranglerConfig) {
    exit 0
}

# ---- optional .env ----
$config = Read-HookEnv (Join-Path $PSScriptRoot '.env')
$cooldownMinutes = 30
if ($config.ContainsKey('COOLDOWN_MINUTES')) {
    try { $cooldownMinutes = [int]$config['COOLDOWN_MINUTES'] } catch { }
}
$deployCommand = 'npx wrangler deploy'
if ($config.ContainsKey('DEPLOY_COMMAND') -and $config['DEPLOY_COMMAND'] -ne '') {
    $deployCommand = $config['DEPLOY_COMMAND']
}

# ---- SHARED RESULT-CATEGORY CONTRACT -------------------------------------
# The complete vocabulary of the { fingerprint, category } handoff written to
# TestTempCleanup-result-<projectKey>.json.
# THE OTHER SIDE OF THIS CONTRACT IS hooks\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1
# ($script:ResultCategories). Keep both lists identical, in the same commit - a
# past round shipped a dead gate because two components drifted on exactly this
# kind of shared state contract.
$script:CleanupCategories = @('clean', 'review-required', 'residue-confirmed', 'partial', 'unknown')
# Only a fully clean, complete scan is release-ready. `review-required`,
# `residue-confirmed`, `partial` and `unknown` each mean the workspace state is
# unresolved or unproven, so none of them may show a deployment decision. An
# unrecognized value (an older or newer producer) is treated the same way.
$script:CleanupReleaseReadyCategories = @('clean')

# (Install evidence is exact managed OWNERSHIP - see Test-CleanupInstalled and
# the ownership header below. A runtime directory listing never was evidence and
# still is not: an orphaned folder satisfied a listing while nothing there could
# ever run. What came back is a runtime-root mirror used purely as a containment
# bound for a registered command's target.)

# THE canonical project key, and the only place it is spelled.
#
# Normalize-Path is load-bearing, not decoration: the PRODUCER hashes
# Normalize-Path($cwd).ToLowerInvariant() (Test-Temp-Cleanup.ps1's $projectRoot),
# and ToLowerInvariant alone folds case only. A cwd carrying a trailing
# separator or a '.'/'..' segment therefore hashed to a key the producer never
# writes, so the record read as ABSENT: the gate concluded "cleanup not
# installed", skipped the cleanliness half of release readiness entirely, and
# showed a deploy decision for a workspace whose cleanliness was never proven.
# Both sides must canonicalize with the same helper or the shared-state contract
# is only nominally shared.
#
# Two consumers now share this one definition - the coordination-record filename
# below, and the projectKey an installed runtime's ownership metadata records -
# so "which project is this" cannot mean two different things in one hook.
function Get-CleanupProjectKey {
    param([string]$Root)
    return (Get-ShortHash (Normalize-Path $Root).ToLowerInvariant())
}

# The single definition of WHERE Test-Temp-Cleanup's coordination record lives,
# so the gate and any diagnostic can never disagree about which file they mean.
function Get-CleanupResultPath {
    param([string]$Root)
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ('TestTempCleanup-result-' + (Get-CleanupProjectKey -Root $Root) + '.json'))
}

# ---- WHAT "INSTALLED" MEANS: EXACT MANAGED OWNERSHIP ----------------------
# One thing only: an ACTIVE, Hook-Maker-MANAGED *Stop* registration whose
# command runs a runtime THIS project owns, proven end to end - where "runs" is
# the whole runtime, not just the file the registration names. The previous
# round's five heuristics are gone, and each was individually load-bearing for a
# real false verdict:
#
#   unreadable registration document   -> counted as installed ("conservative").
#   malformed document naming the hook -> counted as installed.
#   command-bearing key at ANY depth   -> a nested foreign object counted.
#   \Hook-Maker\ + \Test-Temp-Cleanup\ -> any path SPELLING satisfied it, so a
#                                         runtime hand-copied in from another
#                                         project, or simply fabricated, counted.
#   fingerprint-current record ALONE   -> a state file was installation proof.
#
# The chain below replaces all five. Per (client, scope):
#   0. locate the client's Stop registration specifically - the hooks.<Event> key
#      for Claude/Codex, the entry's own trigger for Kiro - because only a Stop
#      handler can produce the result this gate then waits for;
#   1. parse the client's REAL schema and read only real command/action fields -
#      never a recursive walk looking for command-SHAPED strings;
#   2. take that command's quoted -File target, canonicalize it, and require
#      PHYSICAL containment under the client's expected runtime root for the
#      DECLARED scope - no '..' escape, no reparse-point escape;
#   3. load <runtimeRoot>\Test-Temp-Cleanup\.hookmaker-runtime.json and require
#      schemaVersion, friendlyName, client, scope, the RECOMPUTED projectKey and
#      runtimeScriptRelativePath to agree with where that file was found and
#      which document referenced it;
#   4. require the registered target to BE the recorded runtime script;
#   5. verify EVERY recorded manifest entry's sha256 against disk, the registered
#      script among them - the entry point is not the whole runtime.
#
# Unreadable, malformed, foreign, mismatched and missing-metadata evidence are
# all NEGATIVE now. That deliberately reverses the old "refusing to read is not
# proof of absence, so treat it as installed" rule for exactly those cases, and
# nothing is lost by reversing it: a negative SKIPS the cleanup gate, so the
# deployment decision is SHOWN and the agent still has to work through step 1's
# "no disposable test cache/temp residue" requirement itself. The old direction
# parked the reminder indefinitely behind a fresh 'clean' that nothing would
# write - a permanently dead gate is the worse and more persistent failure.
#
# WHAT THIS CANNOT DO, stated instead of faked: the tool-root
# state\install-registry.json is unreachable from a self-contained installed
# runtime - a runtime is copied out of the tool folder and does not know where
# it came from - so recordId is NOT cross-checked against the registry. It is
# carried in the ownership metadata and checked for INTERNAL agreement only:
# non-empty for every client, and for Kiro additionally proven by the managed
# entry's own [hookmaker:<recordId>] description marker, the only client
# document that carries a managed identity at all. Claude and Codex handler
# entries have neither a name nor an id, so there recordId stays
# recorded-but-unverifiable in-process (registrationName is still checked - see
# its two shapes below); what binds those installs to THIS project is the
# recomputed projectKey, the containment check and the manifest hash.
$script:CleanupHookName = 'Test-Temp-Cleanup'
$script:CleanupRuntimeMetadataFile = '.hookmaker-runtime.json'
$script:CleanupMetadataSchemaVersion = '1'
# The ONLY event whose registration can satisfy this gate. Ownership alone was
# not enough: a proven managed runtime registered on SessionStart (or on any
# other event) never runs at Stop, so it never writes the fresh 'clean' the gate
# waits for - and the reminder parks forever behind a result that registration
# is structurally incapable of producing. That is the same permanently-dead gate
# the ownership rewrite set out to eliminate, reached by a different route.
# Case-EXACT on both clients: Claude/Codex match the hooks.<Event> key literally,
# and .ai\KIRO_PROTOCOL.md records Kiro's triggers as confirmed exact casing, so
# a 'stop' key fires nothing and must not count as an active gate.
#
# SubagentStop is deliberately NOT accepted, though the producer can write a
# record there too: it only does so when its own ENABLE_SUBAGENT_STOP is true,
# which defaults to false and lives in the INSTALLED hook's environment - not
# something this separate hook can read. Accepting it would mean betting the
# gate on an opt-in flag we cannot observe, and losing that bet is the
# permanently dead gate again. Rejecting it costs a shown reminder on an
# unusual SubagentStop-only install, which is the recoverable direction.
$script:CleanupGateEvent = 'Stop'
# Mirrors $script:RuntimeMetadataManifestCap in scripts\_installplan.ps1. A
# manifest longer than the writer can emit did not come from an install, and
# refusing it also bounds the hashing work a Stop hook will do.
$script:CleanupManifestCap = 64
# Mirrors Test-KiroManagedFileName in scripts\_installkiro.ps1: Hook Maker owns
# ONLY .kiro\hooks\hookmaker-<slug>.json. Anything else in that directory -
# above all a shared hooks.json - belongs to someone else and is never parsed
# for ownership at all.
$script:CleanupKiroManagedFilePattern = '^hookmaker-[a-z0-9-]+\.json$'

# Mirrored from scripts\_clientcapability.ps1 for the same structural reason as
# ever: an installed runtime is self-contained and cannot dot-source the
# capability table. Test-CloudflareDeploy.ps1 asserts all three mirrors still
# EQUAL the table - registration files, the Kiro registration directory, and the
# per-client runtime roots - which is what keeps the duplication honest instead
# of rotting into a stale hardcoded list. A runtime-root mirror is back here on
# purpose: it is a CONTAINMENT bound now, never evidence on its own, so the
# reason the previous one was deleted (a directory listing proving nothing) does
# not apply - but the reason it ROTTED does, hence the equality test.
$script:CleanupRegistrationFiles = @{
    'claude' = @{ 'project' = '.claude\settings.local.json'; 'global' = '.claude\settings.json' }
    'codex'  = @{ 'project' = '.codex\hooks.json'; 'global' = '.codex\hooks.json' }
}
$script:CleanupKiroRegistrationDir = '.kiro\hooks'
$script:CleanupRuntimeRoots = @{
    'claude' = '.claude\hooks\Hook-Maker'
    'codex'  = '.codex\hooks\Hook-Maker'
    'kiro'   = '.kiro\hook-runtime\Hook-Maker'
}
# The property names a Claude/Codex handler entry actually carries a command in.
# Read on the HANDLER, never searched for at arbitrary depth.
$script:CleanupCommandFields = @('command', 'commandWindows', 'command_windows')

# The quoted -File target of a registered command, or '' when it has none. JSON
# parsing has already unescaped \\ to \ by the time this sees the string.
function Get-RegisteredFileTarget {
    param([string]$Command)
    $match = [regex]::Match([string]$Command, '-File\s+"([^"]+)"', 'IgnoreCase')
    if (-not $match.Success) { return '' }
    return $match.Groups[1].Value
}

# Physical containment. Is any element of the chain from $Path up to and
# including $Root a reparse point? A junction anywhere in that chain means the
# bytes that actually execute live outside the root the lexical containment test
# just approved. Bounded to the chain INSIDE the root deliberately: a user whose
# whole project sits under a junction is not escaping anything, and walking to
# the volume root would reject that legitimate layout.
function Test-CleanupReparseEscape {
    param([string]$Path, [string]$Root)
    $rootNormalized = ''
    try { $rootNormalized = Normalize-Path $Root }
    catch { return $true }
    $current = $Path
    # Bounded, so a pathological loop cannot hang a Stop hook. Containment was
    # already proven, so a real chain is far shorter than this.
    for ($depth = 0; $depth -lt 64; $depth++) {
        if ([string]::IsNullOrWhiteSpace($current)) { return $true }
        try {
            if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            if ([string]::Equals((Normalize-Path $current), $rootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            $current = Split-Path -Parent $current
        }
        catch { return $true }
    }
    return $true
}

# EVERY immutable artifact the install recorded must still hash to its recorded
# value - not merely the one file the registration happens to name.
#
# The registered target is only the ENTRY POINT of the runtime, never the whole
# of it. Claude and Codex register <hook>\<hook>.ps1, which dot-sources
# <hook>\_hooklib.ps1; Kiro registers <hook>\kiro-launch.ps1, which runs the main
# hook, which dot-sources that same library. Hashing the entry point alone left
# everything BEHIND it unverified, so a tampered _hooklib.ps1 - or, under Kiro, a
# tampered main hook, the entire body of what executes - still read as proven
# ownership. The install plan already stages all of them as Immutable artifacts
# and records all of them here, so verify all of them.
function Test-CleanupRuntimeManifest {
    param($Metadata, [string]$RuntimeRoot, [string]$RegisteredRelativePath)
    $manifest = Get-Field $Metadata 'runtimeManifest'
    if ($null -eq $manifest) { return $false }
    $entries = @($manifest)
    if ($entries.Count -eq 0 -or $entries.Count -gt $script:CleanupManifestCap) { return $false }
    $wanted = $RegisteredRelativePath.Replace('/', '\').TrimStart('\')
    $sawRegistered = $false
    foreach ($entry in $entries) {
        $relative = ([string](Get-Field $entry 'path')).Replace('/', '\').TrimStart('\')
        if ([string]::IsNullOrWhiteSpace($relative)) { return $false }
        # A value that is not a sha256 at all is a manifest that cannot vouch for
        # anything, so one bad entry fails the whole runtime rather than being
        # skipped past.
        $expectedHash = ([string](Get-Field $entry 'sha256')).Trim()
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') { return $false }
        $full = ''
        try { $full = Normalize-Path (Join-Path $RuntimeRoot $relative) }
        catch { return $false }
        # A '..' entry must not let a manifest vouch for a file outside the
        # runtime it claims to describe.
        if (-not (Test-PathInside -Candidate $full -Parent $RuntimeRoot)) { return $false }
        $actualHash = ''
        try { $actualHash = [string](Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
        catch { return $false }
        if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ([string]::Equals($relative, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) { $sawRegistered = $true }
    }
    # ...and the script that actually runs has to be one of the files just
    # verified, so a manifest covering only bystanders proves nothing.
    return $sawRegistered
}

# Does an ownership-proven managed runtime back this exact registered command?
#
# $Base is the SCOPE base the registration was found under (the project root, or
# the user profile for a global install) and $ExpectedProjectKey the key that
# base must claim - recomputed here, never read from the metadata, which is what
# catches a runtime copied in from another project. $RegistrationName and
# $IdentityText carry the managed identity for the one client whose document has
# one (Kiro); both are '' for Claude/Codex.
function Test-CleanupManagedCommand {
    param(
        [string]$Command, [string]$Client, [string]$Scope, [string]$Base,
        [string]$ExpectedProjectKey, [string]$RegistrationName = '', [string]$IdentityText = ''
    )
    $target = Get-RegisteredFileTarget -Command $Command
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }

    $runtimeRoot = ''
    $resolvedTarget = ''
    # try/catch because IsPathRooted/Join-Path/GetFullPath THROW on illegal path
    # characters under .NET Framework (5.1); a path malformed enough to throw
    # cannot be a live managed runtime, so "no evidence here" is the faithful
    # verdict rather than a swallowed error.
    try {
        $runtimeRoot = Normalize-Path (Join-Path $Base $script:CleanupRuntimeRoots[$Client])
        # A non-rooted command path resolves against the scope base, the way a
        # client resolves a relative command against the project.
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $Base $target }
        $resolvedTarget = Normalize-Path $target
    }
    catch { return $false }

    # Containment is tested BEFORE existence on purpose: a '..' escape must be
    # rejected as an escape, not accidentally by the escaped file not existing.
    if (-not (Test-PathInside -Candidate $resolvedTarget -Parent $runtimeRoot)) { return $false }
    if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Leaf)) { return $false }
    if (Test-CleanupReparseEscape -Path $resolvedTarget -Root $runtimeRoot) { return $false }

    $metadata = $null
    try { $metadata = Read-JsonFile -Path (Join-Path (Join-Path $runtimeRoot $script:CleanupHookName) $script:CleanupRuntimeMetadataFile) }
    catch { return $false }
    if ($null -eq $metadata) { return $false }

    # Every field is compared AS A STRING: metadata carrying an unexpected type
    # (an object where a string belongs) must read as disagreement, never throw a
    # cast error inside a Stop hook.
    if ([string](Get-Field $metadata 'schemaVersion') -ne $script:CleanupMetadataSchemaVersion) { return $false }
    if ([string](Get-Field $metadata 'friendlyName') -ne $script:CleanupHookName) { return $false }
    if ([string](Get-Field $metadata 'client') -ne $Client) { return $false }
    if ([string](Get-Field $metadata 'scope') -ne $Scope) { return $false }
    # A global install serves every project and therefore records no project
    # key; a project install must claim exactly THIS project's key.
    if ([string](Get-Field $metadata 'projectKey') -ne $ExpectedProjectKey) { return $false }
    $recordId = [string](Get-Field $metadata 'recordId')
    if ([string]::IsNullOrWhiteSpace($recordId)) { return $false }
    # registrationName has TWO shapes, because the two registration kinds have two
    # kinds of identity, and getting this wrong is not theoretical - an exact
    # equality check here would have rejected every real Kiro install:
    #
    #   kiro  - the managed entry-name PREFIX shared by every entry the install
    #           wrote (hookmaker-<recordIdSlug>-<friendlySlug>). A Kiro install
    #           registers ONE entry per physical trigger, so no single entry name
    #           identifies the install; only the prefix does. The located entry's
    #           name must therefore START WITH the recorded value, not equal it.
    #   claude/codex - a handler entry has no name at all; its identity is the
    #           command, which must never be copied into the metadata. The
    #           installer records the managed runtime SEGMENT PAIR instead
    #           ('Hook-Maker/<hook>'), derived below from the same runtime-root
    #           mirror the containment check uses, so there is no fourth literal.
    $recordedRegistrationName = [string](Get-Field $metadata 'registrationName')
    if ([string]::IsNullOrWhiteSpace($recordedRegistrationName)) { return $false }
    if ([string]::IsNullOrWhiteSpace($RegistrationName)) {
        if ($recordedRegistrationName -ne ((Split-Path -Leaf $script:CleanupRuntimeRoots[$Client]) + '/' + $script:CleanupHookName)) { return $false }
    }
    else {
        # A bare or truncated prefix must not match every managed entry, so the
        # recorded value has to be a managed prefix in the first place.
        if ($recordedRegistrationName -notlike 'hookmaker-*') { return $false }
        if (-not $RegistrationName.StartsWith($recordedRegistrationName, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        # ...and the entry must independently prove the same recordId. Mirrors
        # Get-KiroManagedMarker in scripts\_installkiro.ps1 - one of the two
        # ownership proofs the Kiro writer embeds in every managed entry. A
        # hand-edited description therefore degrades VISIBLY (the decision is
        # shown), which is the safe direction; it never silences the reminder.
        if ($IdentityText -notmatch [regex]::Escape('[hookmaker:' + $recordId + ']')) { return $false }
    }

    # The registered target must BE the runtime script the metadata names -
    # relative to the runtime root, exactly as the metadata records it.
    $recordedRelative = ([string](Get-Field $metadata 'runtimeScriptRelativePath')).Trim().Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($recordedRelative)) { return $false }
    $recordedFull = ''
    try { $recordedFull = Normalize-Path (Join-Path $runtimeRoot $recordedRelative) }
    catch { return $false }
    if (-not [string]::Equals($recordedFull, $resolvedTarget, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

    return (Test-CleanupRuntimeManifest -Metadata $metadata -RuntimeRoot $runtimeRoot -RegisteredRelativePath $recordedRelative)
}

# Claude and Codex each keep ONE settings document per client, whose real shape
# is hooks.<Event>[].hooks[] with type='command' and the command in one of
# $script:CleanupCommandFields. Only the exact handler entry is read - never
# "some string somewhere in the document", which is how a description field that
# merely quoted a plausible command used to count.
function Test-CleanupSettingsRegistration {
    param([string]$Client, [string]$Scope, [string]$Base, [string]$ExpectedProjectKey)
    $path = ''
    try { $path = Join-Path $Base $script:CleanupRegistrationFiles[$Client][$Scope] }
    catch { return $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $document = $null
    # Unreadable AND malformed are both negative now - see the header. The inner
    # parentheses are load-bearing on Windows PowerShell 5.1, the same
    # array-collection defect as the gh run-list decode further down.
    try { $document = (([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)) }
    catch { return $false }
    $hooks = Get-Field $document 'hooks'
    if ($null -eq $hooks) { return $false }
    foreach ($eventProperty in $hooks.PSObject.Properties) {
        # The event key IS the event for these two clients, so a handler under
        # any other one is not a Stop registration no matter how well its runtime
        # proves ownership. See $script:CleanupGateEvent.
        if ($eventProperty.Name -cne $script:CleanupGateEvent) { continue }
        foreach ($group in @($eventProperty.Value)) {
            $handlers = Get-Field $group 'hooks'
            if ($null -eq $handlers) { continue }
            foreach ($handler in @($handlers)) {
                if ([string](Get-Field $handler 'type') -ne 'command') { continue }
                foreach ($field in @($script:CleanupCommandFields)) {
                    $command = [string](Get-Field $handler $field)
                    if ([string]::IsNullOrWhiteSpace($command)) { continue }
                    if (Test-CleanupManagedCommand -Command $command -Client $Client -Scope $Scope `
                            -Base $Base -ExpectedProjectKey $ExpectedProjectKey) { return $true }
                }
            }
        }
    }
    return $false
}

# Kiro registers one managed FILE per logical install under .kiro\hooks, in the
# v1 shape { version:'v1', hooks:[ { name, description, trigger,
# action:{type,command}, timeout, enabled } ] }. The managed entry is located by
# its NAME, and that name must be the one the ownership metadata records - a
# foreign entry sitting in the same file cannot borrow it.
function Test-CleanupKiroRegistration {
    param([string]$Scope, [string]$Base, [string]$ExpectedProjectKey)
    $dir = ''
    try { $dir = Join-Path $Base $script:CleanupKiroRegistrationDir }
    catch { return $false }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction Stop) }
    catch { return $false }
    foreach ($file in $files) {
        if ($file.Name -notmatch $script:CleanupKiroManagedFilePattern) { continue }
        $document = $null
        try { $document = (([System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)) }
        catch { continue }
        # The v1 document shape is REQUIRED. A legacy .kiro.hook / 0.x document
        # is not something this hook can reason about, so it is not evidence.
        if ([string](Get-Field $document 'version') -ne 'v1') { continue }
        $entries = Get-Field $document 'hooks'
        if ($null -eq $entries) { continue }
        foreach ($entry in @($entries)) {
            if ((Get-Field $entry 'enabled') -eq $false) { continue }
            # A Kiro install writes one entry PER trigger into this one file, so
            # the file existing says nothing about which events are registered -
            # only this field does. See $script:CleanupGateEvent.
            if ([string](Get-Field $entry 'trigger') -cne $script:CleanupGateEvent) { continue }
            $entryName = [string](Get-Field $entry 'name')
            if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
            $action = Get-Field $entry 'action'
            # 'command' only: an 'agent' action spawns no subprocess, so a
            # runtime registered that way would never run.
            if ([string](Get-Field $action 'type') -ne 'command') { continue }
            $command = [string](Get-Field $action 'command')
            if ([string]::IsNullOrWhiteSpace($command)) { continue }
            if (Test-CleanupManagedCommand -Command $command -Client 'kiro' -Scope $Scope -Base $Base `
                    -ExpectedProjectKey $ExpectedProjectKey -RegistrationName $entryName `
                    -IdentityText ([string](Get-Field $entry 'description'))) { return $true }
        }
    }
    return $false
}

# Is Test-Temp-Cleanup ACTIVELY installed, with proven Hook Maker ownership, for
# this project? Evaluated per (client, scope): project scope against the project
# root, global scope against the user profile.
#
# The scope PAIRING is part of the check, not a shortcut. Each client's
# registration FILE is scope-specific (Claude writes settings.local.json for a
# project install and settings.json for a global one), the runtime root is
# resolved from that same scope base, and the metadata's declared scope must
# match - so a document cannot be read at one scope and vouched for by a runtime
# installed at the other. The retired flat list checked every file at every base,
# which is precisely what let unrelated evidence be paired up.
#
# NO evidence here can SATISFY the cleanliness gate - only a FRESH 'clean'
# category does that. This decides only whether the gate APPLIES, and it is
# evaluated BEFORE any coordination state is read (see Test-ReleaseReady): a
# coordination record is never installation evidence on its own.
function Test-CleanupInstalled {
    param([string]$Root)
    $projectKey = ''
    try { $projectKey = Get-CleanupProjectKey -Root $Root }
    catch { return $false }
    foreach ($scope in @('project', 'global')) {
        $base = if ($scope -eq 'project') { $Root } else { [string]$env:USERPROFILE }
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        $expectedProjectKey = if ($scope -eq 'project') { $projectKey } else { '' }
        foreach ($client in @('claude', 'codex')) {
            if (Test-CleanupSettingsRegistration -Client $client -Scope $scope -Base $base `
                    -ExpectedProjectKey $expectedProjectKey) { return $true }
        }
        if (Test-CleanupKiroRegistration -Scope $scope -Base $base -ExpectedProjectKey $expectedProjectKey) { return $true }
    }
    return $false
}

# Reads Test-Temp-Cleanup's coordination state, only trusting it when its
# recorded repo-state fingerprint still matches the CURRENT state (never a
# stale/racing read from an earlier Stop).
function Get-CleanupCoordinationState {
    param([string]$Root)
    $record = Read-JsonFile -Path (Get-CleanupResultPath -Root $Root)
    if ($null -eq $record) { return $null }
    $recordedFingerprint = [string](Get-Field $record 'fingerprint')
    if ([string]::IsNullOrWhiteSpace($recordedFingerprint)) { return $null }
    if ($recordedFingerprint -ne (Get-RepoStateFingerprint -ProjectRoot $Root)) { return $null }
    return [string](Get-Field $record 'category')
}

# Deterministic release-readiness gate: only when this holds does the
# deployment-worthiness decision get shown at all.
function Test-ReleaseReady {
    param([string]$Root)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $false }

    # 1) no uncommitted task changes.
    $status = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'status', '--porcelain')) | Where-Object { $_ })
    if ($status.Count -gt 0) { return $false }

    $headSha = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headSha)) { return $false }

    # 2) the release commit must be known to be pushed - ANY configured
    # upstream (Cloudflare Workers projects need not be hosted on GitHub at
    # all); Get-GitHubRepository is reserved for the GitHub-specific CI query
    # below, not for this generic pushed/ahead check.
    $upstreamRef = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-parse', '--abbrev-ref', '@{upstream}'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamRef)) { return $false }
    $aheadRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $Root, 'rev-list', '--count', ($upstreamRef + '..HEAD')))
    if ($LASTEXITCODE -ne 0) { return $false }
    $ahead = -1
    if (-not [int]::TryParse($aheadRaw, [ref]$ahead) -or $ahead -ne 0) { return $false }

    # 3) if this repo uses CI, the exact HEAD sha must be verified green.
    $workflowsDir = Join-Path $Root '.github\workflows'
    $usesCi = (Test-Path -LiteralPath $workflowsDir -PathType Container) -and
        (@(Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yml' -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yaml' -ErrorAction SilentlyContinue)).Count -gt 0
    if ($usesCi) {
        $repoInfo = Get-GitHubRepository -ProjectRoot $Root
        if ($null -eq $repoInfo) { return $false }
        if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
        $runsJson = [string](Invoke-QuietCommand -FilePath gh -ArgumentList @('run', 'list', '--repo', $repoInfo.Repository, '--commit', $headSha, '--json', 'status,conclusion', '--limit', '20'))
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($runsJson)) { return $false }
        $runs = $null
        # The INNER parentheses are load-bearing on Windows PowerShell 5.1.
        # `@($json | ConvertFrom-Json)` there collects the decoded array as ONE
        # element of type Object[] instead of enumerating it - at ANY array
        # length, including one. Get-Field reads $Object.PSObject.Properties,
        # which is empty on an Object[], so every field read returns $null, no
        # run ever looks 'completed'/'success', and this gate can never pass.
        #
        # What hides it: `$wrapped[0].status` DOES print the right value,
        # because PowerShell member-enumerates over the array. Only a real
        # property lookup exposes it, so the shape looks fine under casual
        # inspection and the failure is silent (never a wrong deploy prompt).
        #
        # `@((...))` enumerates identically on both hosts; same form as
        # Ci-Status-Check.ps1's annotation decode.
        try { $runs = @(($runsJson | ConvertFrom-Json)) } catch { return $false }
        if ($runs.Count -eq 0) { return $false }
        foreach ($run in $runs) {
            if ([string](Get-Field $run 'status') -ne 'completed' -or [string](Get-Field $run 'conclusion') -ne 'success') { return $false }
        }
    }

    # 4) Test-Temp-Cleanup coordination. THE ORDER BELOW IS THE CONTRACT, not an
    # implementation detail:
    #
    #     prove an ACTIVE MANAGED installation
    #       -> only then read coordination state
    #       -> require its fingerprint to match the CURRENT repo state
    #       -> require category 'clean'
    #
    # A coordination record is NEVER installation evidence on its own. It used to
    # be (a fingerprint-current record alone applied the gate) on the argument
    # that only the hook writes one, so it proved execution; but that made the
    # gate self-justifying - a leftover state file could apply a gate for a hook
    # that no longer exists. Ownership is proven first, from the client's own
    # registration and the installed runtime, and the record is then read only to
    # answer WHAT it currently says.
    if (Test-CleanupInstalled -Root $Root) {
        $cleanupCategory = Get-CleanupCoordinationState -Root $Root
        # Missing/stale ($null), a non-ready category, and an unrecognized
        # category all keep this hook silent until a later Stop.
        if ($script:CleanupCategories -notcontains $cleanupCategory) { return $false }
        if ($script:CleanupReleaseReadyCategories -notcontains $cleanupCategory) { return $false }
    }

    return $true
}

# ---- cooldown (per project) ----
$stateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$statePath = Join-Path $stateDir ('CloudflareDeploy-' + (Get-ShortHash $cwd.ToLowerInvariant()) + '.txt')
$lastFire = [DateTime]::MinValue
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $lastFire = [DateTime]::Parse([System.IO.File]::ReadAllText($statePath).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([DateTime]::UtcNow - $lastFire).TotalMinutes -lt $cooldownMinutes) {
            exit 0
        }
    }
    catch { }
}

# Only show the decision when the repository and release state are actually
# ready - never based on hook registration order (see header).
if (-not (Test-ReleaseReady $cwd)) {
    exit 0
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
[System.IO.File]::WriteAllText($statePath, [DateTime]::UtcNow.ToString('o'))

$reasonLines = New-Object System.Collections.Generic.List[string]
[void]$reasonLines.Add('CLOUDFLARE DEPLOY CHECK: this project deploys to Cloudflare Workers (' + $wranglerConfig + ' found). Deployment is NOT automatic just because this config exists - work through both steps below.')
[void]$reasonLines.Add('1) Deployment-worthiness: deploy ONLY if the task is complete (not partial/experimental/local-only diagnostic), relevant tests/typecheck/lint/build pass, the exact release commit is known, CI for that commit is green if this repo uses CI (or an explicit documented policy allows otherwise), no secrets/local-only/debug files, unrelated changes, or disposable test cache/temp residue are included, the target environment and any required bindings/migrations are understood, and project/user rules permit it. If any of that is not true - or the change is documentation-only, an experiment, or the release commit is not known - finish now WITHOUT deploying and briefly state why.')
[void]$reasonLines.Add('2) Environment: explicitly decide production / staging / preview-development / a named Wrangler environment before deploying - never silently default to production - and use the matching Wrangler config/command for it.')
[void]$reasonLines.Add('3) Cloudflare-specific pre-deploy review, only where relevant to this diff: Worker name and account/environment selection, environment-specific variables, bindings, D1 databases and migrations, KV namespaces, R2 buckets, Queues, Durable Objects and migrations, service bindings, routes/custom domains, cron triggers, compatibility date/flags, deployment CLI/version compatibility, and build output. Never print secret values.')
[void]$reasonLines.Add('4) If deployment is warranted, run: ' + $deployCommand)
[void]$reasonLines.Add('5) Post-deployment verification is REQUIRED - do not claim deployment succeeded solely because the command exited 0. Record the target environment, deployed Worker/project, exact source commit SHA, the deploy command used (excluding secrets), and the deployment/version identifier or URL. Then perform the smallest appropriate check: smoke-test the public/staging URL, call a health endpoint, verify the changed feature, inspect recent Cloudflare deployment output/logs, verify routes/bindings, or confirm migrations completed. If verification cannot be performed, state that limitation accurately instead of assuming success.')
[void]$reasonLines.Add('6) On failure: do not repeatedly redeploy blindly - inspect the actual failure, fix only confirmed deployment/configuration issues, rerun relevant local validation, retry only when safe, never hide a failed deployment, and never claim the task is live if it is not. This reminder respects a cooldown.')
$reason = $reasonLines.ToArray() -join "`n"
exit (Write-HookResult -EventName $eventName -Kind 'block' -Reason $reason).ExitCode
