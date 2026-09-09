# ---------------------------------------------------------------------------
# Managed install plan: the ONE canonical description of every artifact a hook
# installation owns, plus the safe primitives that act on it.
#
# Everything that touches a managed runtime - staging, copying, manifest
# building, integrity verification, cleanup - is derived from the same plan, so
# the installer and the updater can never drift apart in their idea of what an
# installation consists of.
#
# Dot-sourced by Install-Hook.ps1 and Setup-SyncGroup.ps1 AFTER
# hooks\_hooklib.ps1 (needs Get-HookFriendlyName / Get-ShortHash /
# Normalize-Path). The runtime-metadata block below additionally resolves
# _installkiro.ps1's Get-KiroManagedNamePrefix / ConvertTo-KiroSlug at CALL time,
# and only for a Kiro identity - deliberately reusing the real producer of the
# managed entry name rather than re-deriving it here, because two sites deriving
# one identity differently is this project's most repeated defect
# (see .ai/LESSON_INSTALL.md).
#
# Security boundary: a hook source is either a PACKAGE (a folder that is a
# direct child of a recognized hooks root, whose contents are intentionally
# shipped together) or a STANDALONE script (only that one file is installed).
# An arbitrary parent directory is NEVER treated as a hook package - that would
# copy .git, .env, credentials, node_modules and unrelated source into a
# settings-registered runtime directory.
#
# This file BUILDS the plan. Two sibling concerns live beside it and are loaded
# here so every existing caller keeps dot-sourcing one file:
#   _installplanruntime.ps1    executes a plan - staging, verification, commit,
#                              rollback - plus the pre-push wrapper generator.
#   _installplanownership.ps1  decides whether a registered command is ours.
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot '_installplanruntime.ps1')
. (Join-Path $PSScriptRoot '_installplanownership.ps1')

# ---- path safety -----------------------------------------------------------

# Root-aware containment test. Never trims a filesystem root away (`C:\` must
# stay `C:\`, a UNC share root must stay intact) and always compares on a
# separator boundary so a sibling whose name merely starts with the parent's
# name (C:\Hook-Maker-Evil vs C:\Hook-Maker) is not treated as contained.
function Test-PathContainedIn {
    param(
        # AllowEmptyString: [Parameter(Mandatory)] otherwise rejects '' at bind
        # time, so the "empty is never contained" guard below is unreachable and
        # a caller passing an unset path gets a hard error instead of $false.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ChildPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ParentPath
    )
    if ([string]::IsNullOrWhiteSpace($ChildPath) -or [string]::IsNullOrWhiteSpace($ParentPath)) { return $false }
    $child = [System.IO.Path]::GetFullPath($ChildPath)
    $parent = [System.IO.Path]::GetFullPath($ParentPath)
    $parentRoot = [System.IO.Path]::GetPathRoot($parent)
    # Only strip trailing separators that are NOT part of the root itself.
    $parentNormalized = $parent
    if ($parentNormalized.Length -gt $parentRoot.Length) {
        $parentNormalized = $parentNormalized.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    if ([string]::Equals($child, $parentNormalized, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $parentNormalized
    if (-not $prefix.EndsWith([string][System.IO.Path]::DirectorySeparatorChar) -and
        -not $prefix.EndsWith([string][System.IO.Path]::AltDirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }
    return $child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# A reparse point (symlink/junction) inside a source folder can point anywhere;
# following it would copy content from outside the declared package boundary.
function Test-IsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
    }
    catch { return $true }  # unreadable -> treat as unsafe
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

# ---- source classification -------------------------------------------------

# Directory names that must never be copied into a managed runtime even when
# they appear inside a legitimate package folder.
$script:PlanForbiddenDirectoryNames = @('.git', '.svn', '.hg', '.ai', '.claude', '.codex', '.agents', 'node_modules', '.venv', 'venv', '__pycache__', 'dist', 'build', 'out', 'target', 'bin', 'obj', '.cross-project-sync')
# Files a package never ships into its runtime.
# '.env' is the USER's local, git-ignored configuration (README: ".env.example
# (tracked) + .env (your local copy)"), not something a package ships - all 23
# shipped hooks carry a .env.example and none carries a .env. Packaging one
# would overwrite the target project's own configuration on every install, and
# would contradict the installed-manifest rule that never tracks it.
$script:PlanExcludedFileNames = @('.env', '.env.example', '.env.sample', '.env.template', '.env.dist', 'secrets.md')

# Decides how a hook source is installed.
#   Package    - the script lives in <hooksRoot>\<Name>\<Name>.ps1; the folder
#                is a deliberate package and its (bounded, filtered) contents
#                are installed alongside the script.
#   Standalone - anything else, including a loose script directly in a hooks
#                root: ONLY that single script file is installed.
# $PackageRoots are the directories under which a folder may be considered a
# package (normally <ToolRoot>\hooks). A folder anywhere else is never a
# package, no matter what it contains.
# -AllowMissing is for VERIFICATION callers (the updater builds an expected
# manifest for a record whose source may since have been deleted, and must
# report that as a skip rather than crash the whole run). Install callers leave
# it off so a missing/unsafe source is a hard error before anything is touched.
function Get-HookSourceInfo {
    param(
        [Parameter(Mandatory = $true)][string]$HookScript,
        [Parameter(Mandatory = $true)][string[]]$PackageRoots,
        [switch]$AllowMissing
    )
    $scriptPath = [System.IO.Path]::GetFullPath($HookScript)
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        if (-not $AllowMissing) { throw "Hook script not found: $scriptPath" }
        return [pscustomobject]@{
            Kind = 'Standalone'; ScriptPath = $scriptPath; PackageRoot = ''
            Name = [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)
        }
    }
    if (Test-IsReparsePoint -Path $scriptPath) {
        throw "Hook script is a reparse point (symlink/junction), which cannot be installed safely: $scriptPath"
    }
    $parentDir = Split-Path -Parent $scriptPath
    $scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)

    foreach ($root in @($PackageRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $rootFull = [System.IO.Path]::GetFullPath($root)
        # A loose script sitting directly in the hooks root is standalone.
        if ([string]::Equals($parentDir, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Kind = 'Standalone'; ScriptPath = $scriptPath; PackageRoot = ''
                Name = $scriptBaseName
            }
        }
        # A package is a DIRECT child of the hooks root - never a deeper path,
        # and never some unrelated directory that merely contains a .ps1.
        $parentOfParent = Split-Path -Parent $parentDir
        if ([string]::Equals($parentOfParent, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (Test-IsReparsePoint -Path $parentDir) {
                throw "Hook package directory is a reparse point, which cannot be installed safely: $parentDir"
            }
            return [pscustomobject]@{
                Kind = 'Package'; ScriptPath = $scriptPath; PackageRoot = $parentDir
                Name = (Split-Path -Leaf $parentDir)
            }
        }
    }
    # Anything outside a recognized hooks root installs ONLY the script itself,
    # and is named after the SCRIPT (not its parent directory - naming a hook
    # after an arbitrary containing folder was part of the same defect).
    return [pscustomobject]@{
        Kind = 'Standalone'; ScriptPath = $scriptPath; PackageRoot = ''
        Name = $scriptBaseName
    }
}

# ---- the plan --------------------------------------------------------------

# Rewrites a hook script's shared-library dot-source to its PRIVATE sibling
# copy. Deterministic and byte-exact: the only change is the relative path
# inside the dot-source expression, so the transformed content has a stable
# hash the plan can verify. Repository sources are never touched.
#
# Both root-variable spellings used by shipped hooks are handled; a script that
# uses neither is returned unchanged (nothing to rewrite).
$script:PrivateLibraryRewrites = @(
    @{ From = ". (Join-Path `$PSScriptRoot '..\_hooklib.ps1')"; To = ". (Join-Path `$PSScriptRoot '_hooklib.ps1')" },
    @{ From = ". (Join-Path `$ScriptRoot '..\_hooklib.ps1')";   To = ". (Join-Path `$ScriptRoot '_hooklib.ps1')" }
)

function Get-PrivateLibraryScriptContent {
    param([Parameter(Mandatory = $true)][string]$SourceScriptPath)
    if (-not (Test-Path -LiteralPath $SourceScriptPath -PathType Leaf)) { return '' }
    $text = [System.IO.File]::ReadAllText($SourceScriptPath)
    foreach ($rewrite in $script:PrivateLibraryRewrites) {
        $text = $text.Replace([string]$rewrite.From, [string]$rewrite.To)
    }
    return $text
}

function New-PlanArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Generated')][string]$Kind,
        [string]$SourcePath = '',
        [string]$GeneratedContent = $null,
        [ValidateSet('Immutable', 'Mutable')][string]$Ownership = 'Immutable'
    )
    return [pscustomobject][ordered]@{
        relativePath     = $RelativePath.Replace('\', '/')
        kind             = $Kind
        sourcePath       = $SourcePath
        generatedContent = $GeneratedContent
        ownership        = $Ownership
    }
}

# Builds the complete artifact list for ONE hook's managed runtime directory,
# with paths relative to the runtime ROOT (the Hook-Maker folder), so the same
# plan drives copying, manifests, verification and cleanup.
#
# Ownership:
#   Immutable - Hook Maker owns the exact bytes; drift is a repairable defect.
#   Mutable   - written once at install and allowed to change afterwards
#               (nothing is currently mutable; the field exists so a future
#               runtime-written file is declared explicitly rather than
#               excluded by a broad extension rule).
# The Kiro launcher's exact bytes. Deterministic for a given hook name, because
# it is hashed into the install manifest and compared on every later evaluation.
#
# It exists because of two constraints no command string can satisfy:
#   1. KIRO_PROTOCOL requires the physical trigger to be passed EXPLICITLY -
#      Kiro IDE documents no stdin JSON, so a hook cannot infer which event
#      fired.
#   2. Only 2 of the shipped hooks accept a -Client parameter, so client
#      identity cannot travel as an argument without breaking the other 21. It
#      travels in the environment instead.
# It runs the hook IN-PROCESS (& operator, not a nested powershell), so stdin
# still reaches the hook when Kiro supplies it and the real exit code is what
# Kiro observes.
function Get-KiroLauncherContent {
    param([Parameter(Mandatory = $true)][string]$HookScriptLeaf)
    $body = @'
# Generated by Hook Maker. Do not edit - reinstall to regenerate.
# Gives a Kiro-launched hook the two things Kiro itself does not supply:
# which client it is running under, and which trigger fired.
param([string]$Trigger = '')
$ErrorActionPreference = 'Stop'
$env:HOOKMAKER_CLIENT = 'kiro'
if (-not [string]::IsNullOrWhiteSpace($Trigger)) { $env:HOOKMAKER_KIRO_TRIGGER = $Trigger }
$target = Join-Path $PSScriptRoot 'HOOKMAKER_TARGET_SCRIPT'
& $target @args
exit $LASTEXITCODE
'@
    return $body.Replace('HOOKMAKER_TARGET_SCRIPT', $HookScriptLeaf)
}

# ---- managed-runtime ownership metadata ------------------------------------
#
# ONE bounded JSON document inside every managed runtime, stating which install
# owns that directory.
#
# It exists because a managed runtime is SELF-CONTAINED: a hook executing from it
# cannot reach the tool root's state\install-registry.json (it does not know the
# tool root - see .ai/DECISIONS.md, "Cloudflare-Deploy install evidence"). So the
# only ownership evidence a runtime hook had was the SHAPE of the path it happens
# to sit at, which cannot tell an install belonging to THIS project from a runtime
# directory copied in from another one. projectKey answers exactly that: it is
# recomputed from the project root with the SAME helpers the hooks use, so a
# mismatch is proof of a foreign copy.
#
# It is a PLANNED 'Generated' artifact, exactly like the Kiro launcher: staged
# transactionally, hash-verified before the swap, restored on rollback, covered by
# the source-vs-installed manifest comparison, and therefore drift-detectable when
# it is edited or deleted.
#
# CONTENT RULES (asserted by Test-InstallRegistry.ps1): identity only. No command
# lines, no absolute paths, no prompt or tool input, no secrets, no source
# content, no user data, no log text. projectKey is a HASH of the project root and
# never the root itself, so no user directory name reaches an installed runtime.
#
# NOT planned for the native Git pre-push chain. That chain is not a client
# registration - it has no claude/codex/kiro identity to record - so
# Install-IgnorePrePush passes no identity, its runtimes carry no metadata file,
# and Get-NativePrePushSourceManifest/Get-NativePrePushInstalledManifest stay in
# agreement without any change.
$script:RuntimeMetadataFileName = '.hookmaker-runtime.json'
$script:RuntimeMetadataSchemaVersion = 2
# runtimeManifest is BOUNDED at this many entries. Every shipped hook plans 3-6
# artifacts, so the cap is unreachable in practice; it exists so a pathological
# custom-hook package cannot grow this file without limit. The artifact named by
# runtimeScriptRelativePath is always entry 0, so the cap can never drop the one
# entry the contract requires.
$script:RuntimeMetadataManifestCap = 64

# The install identity a runtime metadata file describes. One constructor so the
# installer and the updater cannot assemble it differently.
#
# The client ValidateSet must be a literal, so it cannot be derived from
# _clientcapability.ps1's table. A FOURTH client therefore has to be added here
# too - it fails CLOSED if it is not (Get-InstallIntegrity turns the bind error
# into a per-client 'skip' naming the reason), never silently writing metadata
# with no client identity.
function New-RuntimeIdentity {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'kiro')][string]$Client,
        [Parameter(Mandatory = $true)][ValidateSet('project', 'global')][string]$Scope,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RecordId,
        [AllowEmptyString()][string]$ProjectRoot = ''
    )
    return [pscustomobject]@{
        Client      = $Client
        Scope       = $Scope
        RecordId    = $RecordId
        ProjectRoot = $ProjectRoot
    }
}

# The project key a runtime hook can RECOMPUTE from the project root it is running
# in. Normalize-Path then Get-ShortHash, both from hooks\_hooklib.ps1 - the exact
# pair every hook already uses to key its own shared state, because the whole
# point of this field is that the two sides agree. Do not "simplify" it to
# GetFullPath or a bare ToLowerInvariant: neither trims a trailing separator, and
# that mismatch is a defect this project has already shipped once.
# '' for a global install, which has no project to be keyed to.
function Get-RuntimeMetadataProjectKey {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('project', 'global')][string]$Scope,
        [AllowEmptyString()][string]$ProjectRoot = ''
    )
    if ($Scope -ceq 'global' -or [string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
    return (Get-ShortHash ((Normalize-Path $ProjectRoot).ToLowerInvariant()))
}

# The registration identity this install wrote, per client.
#   kiro   - the managed entry-name PREFIX every entry this install registered
#            shares. A Kiro install writes ONE entry per physical trigger, so no
#            single entry name identifies the install; the prefix does, and it is
#            exactly what Test-KiroOwnership and _installvalidate.ps1 already
#            prove ownership with. Taken from the real producers so it cannot
#            drift from the names actually written.
#   claude / codex - these clients have no entry NAME: their handler identity is
#            the command, which must never be copied into this file. The marker
#            the installer already writes instead is the managed runtime segment
#            pair, '<Hook-Maker root>/<hook>', which is what
#            Get-HookMakerCommandInfo proves ownership from.
function Get-RuntimeMetadataRegistrationName {
    param(
        [Parameter(Mandatory = $true)][string]$Client,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RecordId
    )
    if ($Client -ceq 'kiro') {
        return ((Get-KiroManagedNamePrefix -ManagedId $RecordId) + (ConvertTo-KiroSlug -Text $FriendlyName))
    }
    return ('Hook-Maker/' + $FriendlyName)
}

# JSON string literal, written by hand rather than through ConvertTo-Json.
#
# These bytes are HASHED into the install manifest and re-derived later to detect
# drift, so they must be identical on Windows PowerShell 5.1 and pwsh 7 forever.
# The two hosts use different serializers with different escaping rules (5.1's
# JavaScriptSerializer escapes '<', '>' and non-ASCII; 7's does not), and a
# host-dependent byte would make every cross-host evaluation report permanent
# drift and reinstall the hook for ever. Escaping exactly the characters RFC 8259
# requires removes the question entirely.
function ConvertTo-PlanJsonStringLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        if ($character -eq '"') { [void]$builder.Append('\"') }
        elseif ($character -eq '\') { [void]$builder.Append('\\') }
        elseif ($code -eq 8) { [void]$builder.Append('\b') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 12) { [void]$builder.Append('\f') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -lt 32) { [void]$builder.Append('\u' + $code.ToString('x4')) }
        else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# The exact bytes of one managed runtime's ownership metadata.
#
# -Artifacts is the plan built SO FAR, which is why this is planned last: the
# document hashes the other artifacts, so it cannot exist before they do. It also
# cannot contain itself - a file cannot hash its own bytes - and excluding it is
# automatic here because it has not been added to the plan yet.
function Get-RuntimeMetadataContent {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)]$RuntimeIdentity,
        [Parameter(Mandatory = $true)][string]$RuntimeScriptRelativePath
    )
    $client = [string]$RuntimeIdentity.Client
    # Entry 0 is the runtime script the registration actually invokes, so the cap
    # below can never drop it. Everything else follows in ORDINAL path order -
    # Sort-Object compares culture-sensitively, which is not a safe basis for
    # bytes that get hashed.
    $ordered = New-Object System.Collections.Generic.List[object]
    $rest = New-Object System.Collections.Generic.List[object]
    foreach ($artifact in @($Artifacts)) {
        if ([string]$artifact.ownership -ne 'Immutable') { continue }
        $relative = [string]$artifact.relativePath
        if ([string]::Equals($relative, $RuntimeScriptRelativePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$ordered.Add($artifact)
        }
        else { [void]$rest.Add($artifact) }
    }
    $restArray = $rest.ToArray()
    [System.Array]::Sort($restArray, [System.Comparison[object]] {
            param($left, $right)
            return [System.StringComparer]::OrdinalIgnoreCase.Compare([string]$left.relativePath, [string]$right.relativePath)
        })
    foreach ($artifact in $restArray) { [void]$ordered.Add($artifact) }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('{')
    [void]$lines.Add('  "schemaVersion": ' + [string]$script:RuntimeMetadataSchemaVersion + ',')
    [void]$lines.Add('  "recordId": ' + (ConvertTo-PlanJsonStringLiteral ([string]$RuntimeIdentity.RecordId)) + ',')
    [void]$lines.Add('  "friendlyName": ' + (ConvertTo-PlanJsonStringLiteral $FriendlyName) + ',')
    [void]$lines.Add('  "client": ' + (ConvertTo-PlanJsonStringLiteral $client) + ',')
    [void]$lines.Add('  "scope": ' + (ConvertTo-PlanJsonStringLiteral ([string]$RuntimeIdentity.Scope)) + ',')
    [void]$lines.Add('  "projectKey": ' + (ConvertTo-PlanJsonStringLiteral (Get-RuntimeMetadataProjectKey `
                    -Scope ([string]$RuntimeIdentity.Scope) -ProjectRoot ([string]$RuntimeIdentity.ProjectRoot))) + ',')
    [void]$lines.Add('  "registrationName": ' + (ConvertTo-PlanJsonStringLiteral (Get-RuntimeMetadataRegistrationName `
                    -Client $client -FriendlyName $FriendlyName -RecordId ([string]$RuntimeIdentity.RecordId))) + ',')
    [void]$lines.Add('  "runtimeScriptRelativePath": ' + (ConvertTo-PlanJsonStringLiteral $RuntimeScriptRelativePath) + ',')
    [void]$lines.Add('  "runtimeManifest": [')
    $entryLines = New-Object System.Collections.Generic.List[string]
    foreach ($artifact in @($ordered.ToArray())) {
        if ($entryLines.Count -ge $script:RuntimeMetadataManifestCap) { break }
        # Lower-case hex: Get-PlanArtifactExpectedHash / Get-FileHash return
        # upper-case, and the contract fixes one casing so a consumer never has
        # to normalize before comparing.
        $hash = ([string](Get-PlanArtifactExpectedHash -Artifact $artifact)).ToLowerInvariant()
        [void]$entryLines.Add('    { "path": ' + (ConvertTo-PlanJsonStringLiteral ([string]$artifact.relativePath)) +
            ', "sha256": ' + (ConvertTo-PlanJsonStringLiteral $hash) + ' }')
    }
    for ($index = 0; $index -lt $entryLines.Count; $index++) {
        $suffix = if ($index -lt $entryLines.Count - 1) { ',' } else { '' }
        [void]$lines.Add($entryLines[$index] + $suffix)
    }
    [void]$lines.Add('  ],')
    # Named here because this document is where a reader goes to ask "what does
    # an update do to this directory?", and the honest answer has two halves.
    # runtimeManifest above is what the update REPLACES; these are what it
    # CARRIES ACROSS. A user's .env is deliberately absent from the manifest -
    # listing it there would make every configured hook read as drift - so
    # without this field the guarantee is invisible exactly where it is looked
    # for, and its absence reads as "not protected". It was reported that way
    # three times.
    [void]$lines.Add('  "preservedUserConfig": [')
    $preservedLines = New-Object System.Collections.Generic.List[string]
    foreach ($configName in @($script:ManagedRuntimeUserConfigNames)) {
        [void]$preservedLines.Add('    ' + (ConvertTo-PlanJsonStringLiteral ([string]$configName)))
    }
    for ($index = 0; $index -lt $preservedLines.Count; $index++) {
        $suffix = if ($index -lt $preservedLines.Count - 1) { ',' } else { '' }
        [void]$lines.Add($preservedLines[$index] + $suffix)
    }
    [void]$lines.Add('  ]')
    [void]$lines.Add('}')
    # LF, chosen once: these bytes are hashed, so the line ending must not depend
    # on the host or on a checkout's autocrlf setting.
    return (($lines.ToArray() -join "`n") + "`n")
}

function Get-ManagedInstallPlan {
    param(
        [Parameter(Mandatory = $true)]$SourceInfo,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$ConfigPath = '',
        [switch]$IncludeConfig,
        # Deliberately UNTYPED: a [string] parameter coerces $null to '', which
        # would make "no generated list" indistinguishable from "empty list"
        # and plan a bogus empty SYNC-PROJECTS.txt for every custom hook.
        $SyncProjectListContent = $null,
        # Kiro ONLY. Deliberately opt-in rather than always-on: adding this file
        # to every runtime would change the manifest of every already-installed
        # Claude and Codex hook, and the updater would then see all of them as
        # drifted and reinstall the lot.
        [switch]$IncludeKiroLauncher,
        # The install identity the runtime metadata file describes, or $null for
        # no metadata artifact at all.
        #
        # Supplied ONLY by the client-specific callers: the installer for the
        # client it is installing, and Get-ManagedClientManifest when the updater
        # asks "does THIS client's runtime still match?". Omitted, the plan is
        # byte-for-byte the client-agnostic description it has always been, which
        # is exactly what the SOURCE manifest needs - "did the hook's SOURCE
        # change?" must not depend on which client is asked, and an installed
        # identity is not a source change.
        #
        # UNLIKE -IncludeKiroLauncher this artifact is not opt-in per client: it
        # lands in EVERY managed runtime, so the first evaluation after this ships
        # reports every already-installed hook as missing one expected file. That
        # is one idempotent repair per client per hook (measured, see the round
        # report) and is the accepted price of manifest coverage.
        $RuntimeIdentity = $null
    )
    $artifacts = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    function Add-Artifact {
        param($Artifact)
        if (-not $seen.Add($Artifact.relativePath)) {
            throw ("The install plan produced two artifacts for the same destination: " + $Artifact.relativePath)
        }
        [void]$artifacts.Add($Artifact)
    }

    # Each hook gets its OWN PRIVATE copy of the shared library inside its
    # runtime directory, and its installed script is rewritten to dot-source
    # that private copy. A single shared library at the runtime root meant
    # updating one hook silently swapped the library every OTHER already
    # installed hook loads - a cross-hook version skew with no version boundary.
    $hookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'
    if (Test-Path -LiteralPath $hookLib -PathType Leaf) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/_hooklib.ps1') -Kind 'File' -SourcePath $hookLib)
    }

    # The installed main script is GENERATED (source bytes + a deterministic
    # dot-source rewrite), so it is hashed and verified exactly like any other
    # planned artifact. Repository sources are never modified.
    $mainScriptContent = Get-PrivateLibraryScriptContent -SourceScriptPath $SourceInfo.ScriptPath
    Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/' + $FriendlyName + '.ps1') -Kind 'Generated' -GeneratedContent $mainScriptContent)

    # Kiro's launcher is PLANNED, not written beside the runtime afterwards.
    #
    # It was originally written directly by Install-Hook.ps1 after the plan had
    # already been committed. That put a real file in the managed hook directory
    # that no artifact accounted for, so Get-InstalledManifest saw it,
    # Compare-Manifest reported "unexpected managed file" on EVERY evaluation,
    # and the updater reinstalled the hook forever - the permanent-update-loop
    # failure this file's header warns about. Planning it fixes the loop and
    # buys the same guarantees every other artifact has: staged transactionally,
    # hash-verified, restored on rollback, and drift-detectable if edited.
    #
    # The alternative - excluding it via $script:ManagedRuntimeMutablePaths -
    # was rejected: that list is for files the RUNTIME rewrites at execution
    # time, and using it here would permanently blind drift detection for a file
    # that must never change on its own.
    if ($IncludeKiroLauncher) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/kiro-launch.ps1') -Kind 'Generated' `
                -GeneratedContent (Get-KiroLauncherContent -HookScriptLeaf ($FriendlyName + '.ps1')))
    }

    # Test-Run-Guard's gate is only real if scripts\Run-Tests-Guarded.ps1 travels
    # WITH it. In a freshly-set-up target project the runner exists nowhere else,
    # and Test-Run-Guard's Find-GuardedRunner then finds nothing and silently
    # downgrades the gate to advisory - the exact defect. Ship the CANONICAL
    # runner (single source of truth in scripts\, never a committed duplicate)
    # into the installed hook's own scripts\ subdir, which is candidate[0] of
    # Find-GuardedRunner ($PSScriptRoot\scripts\Run-Tests-Guarded.ps1). It is a
    # standalone script (no _hooklib dependency), so it is copied verbatim and
    # becomes an Immutable managed artifact - editing the source runner is then
    # drift the updater repairs, keeping the shipped copy in lockstep.
    if ([string]::Equals($FriendlyName, 'Test-Run-Guard', [System.StringComparison]::OrdinalIgnoreCase)) {
        $guardedRunnerSource = Join-Path $ToolRoot 'scripts\Run-Tests-Guarded.ps1'
        if (Test-Path -LiteralPath $guardedRunnerSource -PathType Leaf) {
            Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/scripts/Run-Tests-Guarded.ps1') -Kind 'File' -SourcePath $guardedRunnerSource)
        }
    }

    if ($SourceInfo.Kind -eq 'Package') {
        $packageRoot = [System.IO.Path]::GetFullPath($SourceInfo.PackageRoot)
        $mainLeaf = Split-Path -Leaf $SourceInfo.ScriptPath
        $venvAncestorCache = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ([string]::Equals($file.Name, $mainLeaf, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals($file.DirectoryName, $packageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue  # the main script, already planned under its friendly name
            }
            $excluded = $false
            foreach ($name in $script:PlanExcludedFileNames) {
                if ([string]::Equals($file.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            if (-not (Test-PathContainedIn -ChildPath $file.FullName -ParentPath $packageRoot)) { continue }
            $relative = $file.FullName.Substring($packageRoot.Length).TrimStart('\', '/')
            $segments = $relative.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
            $inForbidden = $false
            for ($i = 0; $i -lt $segments.Length - 1; $i++) {
                foreach ($forbidden in $script:PlanForbiddenDirectoryNames) {
                    if ([string]::Equals($segments[$i], $forbidden, [System.StringComparison]::OrdinalIgnoreCase)) { $inForbidden = $true; break }
                }
                if ($inForbidden) { break }
                # An oddly named virtualenv inside a package would otherwise be
                # copied WHOLESALE into every managed runtime - large, and broken
                # on arrival, because a venv stores absolute paths to the
                # interpreter that created it. Answered per ANCESTOR DIRECTORY and
                # cached, so this costs one stat per package directory rather than
                # one per file underneath it.
                $ancestor = [System.IO.Path]::Combine($packageRoot, ($segments[0..$i] -join [System.IO.Path]::DirectorySeparatorChar))
                if (-not $venvAncestorCache.ContainsKey($ancestor)) {
                    $venvAncestorCache[$ancestor] = (Test-IsMarkerPrunedDirectory -Path $ancestor)
                }
                if ($venvAncestorCache[$ancestor]) { $inForbidden = $true; break }
            }
            if ($inForbidden) { continue }
            if (Test-IsReparsePoint -Path $file.FullName) { continue }
            # Any packaged .ps1 that dot-sources the shared library needs the
            # same private-copy rewrite as the main script, or it would look for
            # a library one directory up that no longer exists. Non-script files
            # (and scripts that don't reference it) are copied verbatim.
            if ([string]::Equals($file.Extension, '.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
                $rewritten = Get-PrivateLibraryScriptContent -SourceScriptPath $file.FullName
                if ($rewritten -ne [System.IO.File]::ReadAllText($file.FullName)) {
                    Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/' + $relative) -Kind 'Generated' -GeneratedContent $rewritten)
                    continue
                }
            }
            Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/' + $relative) -Kind 'File' -SourcePath $file.FullName)
        }
    }

    if ($IncludeConfig -and -not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/sync-hooks.json') -Kind 'File' -SourcePath $ConfigPath)
    }
    # SYNC-PROJECTS.txt is GENERATED, so it is planned with its exact expected
    # content: it gets a deterministic hash and is verified like any other
    # managed artifact instead of being excluded from checking.
    if (-not [string]::IsNullOrEmpty($SyncProjectListContent)) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/SYNC-PROJECTS.txt') -Kind 'Generated' -GeneratedContent $SyncProjectListContent)
    }

    # LAST, deliberately: the metadata document hashes every other planned
    # artifact, so it cannot be built until they are all known.
    #
    # runtimeScriptRelativePath is read off the plan rather than off the client id
    # (`if kiro then kiro-launch.ps1`). Deriving it from what the plan ACTUALLY
    # contains makes it impossible for this file to name a runtime script the same
    # plan never produces - the two would otherwise drift the moment the launcher
    # switch and the identity disagreed.
    if ($null -ne $RuntimeIdentity) {
        $launcherRelative = $FriendlyName + '/kiro-launch.ps1'
        $runtimeScriptRelative = if ($seen.Contains($launcherRelative)) { $launcherRelative } else { $FriendlyName + '/' + $FriendlyName + '.ps1' }
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/' + $script:RuntimeMetadataFileName) -Kind 'Generated' `
                -GeneratedContent (Get-RuntimeMetadataContent -Artifacts @($artifacts.ToArray()) -FriendlyName $FriendlyName `
                    -RuntimeIdentity $RuntimeIdentity -RuntimeScriptRelativePath $runtimeScriptRelative))
    }

    return @($artifacts.ToArray())
}

# The projects one sync-group profile connects, keyed by lower-cased root so the
# same project named twice in a mesh is listed once.
function Get-SyncProfileProjects {
    param([Parameter(Mandatory = $true)]$Profile)
    $projectsByRoot = @{}
    foreach ($route in @($Profile.routes)) {
        foreach ($endpoint in @($route.source, $route.destination)) {
            if ($null -eq $endpoint) { continue }
            $root = [string]$endpoint.root
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $key = $root.ToLowerInvariant()
            if (-not $projectsByRoot.ContainsKey($key)) {
                $projectsByRoot[$key] = [pscustomobject]@{ Name = [string]$endpoint.name; Root = $root }
            }
        }
    }
    return $projectsByRoot
}

# Exact content of the generated SYNC-PROJECTS.txt for a sync-engine install.
#
# THE ONE generator. The installer used to carry a second copy that had to stay
# byte-identical with this one for ever; a runtime directory is verified against
# this hash, so any divergence would have been permanent drift.
#
# Content is keyed by the PROJECT, not by the installing record's profile. One
# runtime directory is shared by every record with the same (project, client), so
# a project in three sync groups had three records generating three different
# files at one path: whichever installed last won, the other two read as stale,
# and the next update flipped which. Listing every group this project belongs to
# makes all of them generate identical bytes - and describes the directory
# honestly, since its sync-hooks.json carries every profile anyway.
#
# A project in exactly ONE group produces byte-for-byte what it always did, so
# the common case does not churn.
function Get-SyncProjectListContentFor {
    param(
        [Parameter(Mandatory = $true)][string]$RoutingConfig,
        [string]$ProfileId = '',
        # '' for a global install, which is not tied to one project: then every
        # profile in the config is listed, because the shared runtime serves all
        # of them.
        [AllowEmptyString()][string]$ProjectRoot = ''
    )
    # An empty profile id is how a CUSTOM hook install says "not the engine" -
    # it plans no list at all. Kept as the gate even though the id no longer
    # selects the content.
    if ([string]::IsNullOrWhiteSpace($ProfileId)) { return $null }
    if (-not (Test-Path -LiteralPath $RoutingConfig -PathType Leaf)) { return $null }
    $config = $null
    try { $config = Get-Content -LiteralPath $RoutingConfig -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $config -or $null -eq $config.PSObject.Properties['profiles']) { return $null }

    $projectKey = ''
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $projectKey = (Normalize-Path $ProjectRoot).ToLowerInvariant() }

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($profile in @($config.profiles)) {
        $projects = Get-SyncProfileProjects -Profile $profile
        if ($projectKey -ne '') {
            $belongs = $false
            foreach ($project in @($projects.Values)) {
                if ((Normalize-Path ([string]$project.Root)).ToLowerInvariant() -ceq $projectKey) { $belongs = $true; break }
            }
            if (-not $belongs) { continue }
        }
        [void]$selected.Add([pscustomobject]@{ Profile = $profile; Projects = $projects })
    }
    # A project the config no longer mentions (hand-edited between installs)
    # still gets its own profile described rather than an empty file.
    if ($selected.Count -eq 0) {
        $own = @(@($config.profiles) | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1)
        if ($own.Count -eq 0) { return $null }
        [void]$selected.Add([pscustomobject]@{ Profile = $own[0]; Projects = (Get-SyncProfileProjects -Profile $own[0]) })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Cross-project AI knowledge sync')
    $first = $true
    foreach ($entry in @($selected.ToArray())) {
        if (-not $first) { [void]$lines.Add('') }
        $first = $false
        [void]$lines.Add(('Profile: ' + [string]$entry.Profile.name))
        [void]$lines.Add('')
        [void]$lines.Add('Synchronized projects:')
        foreach ($project in @($entry.Projects.Values | Sort-Object -Property Root)) {
            [void]$lines.Add(('- ' + $project.Name + ' | ' + $project.Root))
        }
    }
    return (($lines.ToArray() -join "`r`n") + "`r`n")
}

# The single entry point both the installer and the updater use to obtain a
# plan, so they can never disagree about what an installation consists of.
function Get-InstallPlanFor {
    param(
        [Parameter(Mandatory = $true)][string]$HookScript,
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$FriendlyNameOverride = '',
        [string]$ProfileId = '',
        [string]$ConfigPath = '',
        [switch]$IsEngine,
        [switch]$AllowMissing,
        # Both forwarded straight through, so a VERIFICATION caller can ask for the
        # exact same plan a client install produced. Before this existed the
        # updater's expected manifest could not describe kiro-launch.ps1 at all, so
        # every real Kiro install reported "unexpected managed file" for ever.
        [switch]$IncludeKiroLauncher,
        # Which project this plan is FOR. The generated SYNC-PROJECTS.txt is keyed
        # by it, and the source and client manifests must therefore both supply
        # it or they would describe the same file differently. Taken from the
        # runtime identity when a client-specific caller already carries one.
        [AllowEmptyString()][string]$ProjectRoot = '',
        $RuntimeIdentity = $null
    )
    $sourceInfo = Get-HookSourceInfo -HookScript $HookScript -PackageRoots @((Join-Path $ToolRoot 'hooks')) -AllowMissing:$AllowMissing
    $friendlyName = if (-not [string]::IsNullOrWhiteSpace($FriendlyNameOverride)) { $FriendlyNameOverride } else { Get-HookFriendlyName $sourceInfo.Name }
    $effectiveProjectRoot = $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($effectiveProjectRoot) -and $null -ne $RuntimeIdentity) {
        $effectiveProjectRoot = [string]$RuntimeIdentity.ProjectRoot
    }
    $syncList = $null
    if ($IsEngine) { $syncList = Get-SyncProjectListContentFor -RoutingConfig $ConfigPath -ProfileId $ProfileId -ProjectRoot $effectiveProjectRoot }
    return (Get-ManagedInstallPlan -SourceInfo $sourceInfo -FriendlyName $friendlyName -ToolRoot $ToolRoot `
            -ConfigPath $ConfigPath -IncludeConfig:$IsEngine -SyncProjectListContent $syncList `
            -IncludeKiroLauncher:$IncludeKiroLauncher -RuntimeIdentity $RuntimeIdentity)
}

# ---- hashing / manifests ---------------------------------------------------

function Get-PlanArtifactExpectedHash {
    param([Parameter(Mandatory = $true)]$Artifact)
    if ($Artifact.kind -eq 'Generated') {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$Artifact.generatedContent)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant() }
        finally { $sha.Dispose() }
    }
    if (-not (Test-Path -LiteralPath $Artifact.sourcePath -PathType Leaf)) { return '' }
    # .NET, NOT Get-FileHash. That cmdlet lives in the Microsoft.PowerShell.Utility
    # MODULE, and a Windows PowerShell 5.1 process started underneath a pwsh 7
    # parent can come up unable to resolve it - "The term 'Get-FileHash' is not
    # recognized" - which made EVERY 5.1 run of the install path die here. It was
    # invisible because the suites run under pwsh 7, where the cmdlet resolves.
    # The Generated branch above already hashes with .NET; this returns the same
    # upper-case SHA-256 hex Get-FileHash did, so no stored manifest changes.
    # Shared read: hashing must not fail on a file something else has open.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Artifact.sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToUpperInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

# path+hash manifest derived from the plan (never file contents).
function Get-PlanManifest {
    param([Parameter(Mandatory = $true)]$Plan)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($artifact in @($Plan)) {
        if ($artifact.ownership -ne 'Immutable') { continue }
        [void]$entries.Add([pscustomobject][ordered]@{
            path = ([string]$artifact.relativePath).ToLowerInvariant()
            hash = (Get-PlanArtifactExpectedHash -Artifact $artifact)
        })
    }
    return @($entries.ToArray() | Sort-Object -Property path)
}
