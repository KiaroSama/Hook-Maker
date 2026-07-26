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
# ---------------------------------------------------------------------------

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

# ---- source classification -------------------------------------------------

# Directory names that must never be copied into a managed runtime even when
# they appear inside a legitimate package folder.
$script:PlanForbiddenDirectoryNames = @('.git', '.svn', '.hg', '.ai', '.claude', '.codex', '.agents', 'node_modules', '.venv', 'venv', '__pycache__', 'dist', 'build', 'out', 'target', 'bin', 'obj', '.cross-project-sync')
# Files a package never ships into its runtime.
$script:PlanExcludedFileNames = @('.env.example', '.env.sample', '.env.template', '.env.dist', 'secrets.md')

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
$script:RuntimeMetadataSchemaVersion = 1
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

# Exact content of the generated SYNC-PROJECTS.txt for a sync-engine install.
# Lives here (not in the installer) so the installer and the updater's
# integrity check derive the same deterministic bytes from the same code.
function Get-SyncProjectListContentFor {
    param(
        [Parameter(Mandatory = $true)][string]$RoutingConfig,
        [string]$ProfileId = ''
    )
    if ([string]::IsNullOrWhiteSpace($ProfileId)) { return $null }
    if (-not (Test-Path -LiteralPath $RoutingConfig -PathType Leaf)) { return $null }
    $config = $null
    try { $config = Get-Content -LiteralPath $RoutingConfig -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $config -or $null -eq $config.PSObject.Properties['profiles']) { return $null }
    $matchingProfile = @($config.profiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1)
    if ($matchingProfile.Count -eq 0) { return $null }

    $projectsByRoot = @{}
    foreach ($route in @($matchingProfile[0].routes)) {
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
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Cross-project AI knowledge sync')
    [void]$lines.Add(('Profile: ' + [string]$matchingProfile[0].name))
    [void]$lines.Add('')
    [void]$lines.Add('Synchronized projects:')
    foreach ($project in @($projectsByRoot.Values | Sort-Object -Property Root)) {
        [void]$lines.Add(('- ' + $project.Name + ' | ' + $project.Root))
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
        $RuntimeIdentity = $null
    )
    $sourceInfo = Get-HookSourceInfo -HookScript $HookScript -PackageRoots @((Join-Path $ToolRoot 'hooks')) -AllowMissing:$AllowMissing
    $friendlyName = if (-not [string]::IsNullOrWhiteSpace($FriendlyNameOverride)) { $FriendlyNameOverride } else { Get-HookFriendlyName $sourceInfo.Name }
    $syncList = $null
    if ($IsEngine) { $syncList = Get-SyncProjectListContentFor -RoutingConfig $ConfigPath -ProfileId $ProfileId }
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
    return (Get-FileHash -LiteralPath $Artifact.sourcePath -Algorithm SHA256).Hash
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

# ---- transactional runtime installation ------------------------------------

# Installs a plan into <RuntimeRoot>\<FriendlyName> WITHOUT destroying the
# existing runtime unless the replacement is fully built and verified:
#   1. build everything in a sibling staging directory,
#   2. verify every planned artifact exists with the expected hash,
#   3. move the live directory aside,
#   4. move staging into place,
#   5. delete the set-aside directory.
# Any failure before step 4 leaves the previous runtime untouched; a failure
# during step 4 restores it. Abandoned staging/backup directories from an
# interrupted run are cleaned on the next install.
function Install-PlannedRuntime {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null
    }
    $destination = Join-Path $RuntimeRoot $FriendlyName
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $staging = Join-Path $RuntimeRoot ('.hookmaker-staging-' + $FriendlyName + '-' + $token)
    $setAside = Join-Path $RuntimeRoot ('.hookmaker-previous-' + $FriendlyName + '-' + $token)

    # Clean what an earlier INTERRUPTED run abandoned for this hook. Only
    # directories older than the threshold are removed: a concurrent install of
    # the same hook has its own freshly-created staging directory that matches
    # the same name pattern, and deleting it out from under that process would
    # turn a survivable race into a failed install.
    $abandonedBefore = [DateTime]::UtcNow.AddMinutes(-30)
    foreach ($prefix in @(('.hookmaker-staging-' + $FriendlyName + '-'), ('.hookmaker-previous-' + $FriendlyName + '-'))) {
        foreach ($candidate in @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not $candidate.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($candidate.CreationTimeUtc -gt $abandonedBefore) { continue }
            Remove-Item -LiteralPath $candidate.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $swapped = $false
    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $stagingHookDir = Join-Path $staging $FriendlyName
        New-Item -ItemType Directory -Path $stagingHookDir -Force | Out-Null

        foreach ($artifact in @($Plan)) {
            $relative = ([string]$artifact.relativePath)
            $targetPath = Join-Path $staging ($relative.Replace('/', '\'))
            if (-not (Test-PathContainedIn -ChildPath $targetPath -ParentPath $staging)) {
                throw ("Planned artifact escapes the staging directory: " + $relative)
            }
            $targetDir = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            if ($artifact.kind -eq 'Generated') {
                [System.IO.File]::WriteAllText($targetPath, [string]$artifact.generatedContent, [System.Text.UTF8Encoding]::new($false))
            }
            else {
                if (-not (Test-Path -LiteralPath $artifact.sourcePath -PathType Leaf)) {
                    throw ("Planned source file is missing: " + $artifact.sourcePath)
                }
                Copy-Item -LiteralPath $artifact.sourcePath -Destination $targetPath -Force
            }
        }

        # Verify the staged tree BEFORE touching the live runtime.
        foreach ($artifact in @($Plan)) {
            if ($artifact.ownership -ne 'Immutable') { continue }
            $targetPath = Join-Path $staging (([string]$artifact.relativePath).Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw ("Staged artifact missing after copy: " + $artifact.relativePath)
            }
            $expected = Get-PlanArtifactExpectedHash -Artifact $artifact
            $actual = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
            if ($expected -ne $actual) {
                throw ("Staged artifact does not match its source: " + $artifact.relativePath)
            }
        }

        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination -Destination $setAside -Force
        }
        try {
            Move-Item -LiteralPath $stagingHookDir -Destination $destination -Force
            $swapped = $true
        }
        catch {
            # Put the previous runtime back so the installation keeps working.
            if ((Test-Path -LiteralPath $setAside) -and -not (Test-Path -LiteralPath $destination)) {
                Move-Item -LiteralPath $setAside -Destination $destination -Force
            }
            throw
        }
        # Root-level artifacts (currently only the shared _hooklib.ps1) live
        # beside every hook rather than inside this one, so they are placed
        # after the per-hook swap. They are copied from the verified staging
        # tree, never straight from source.
        foreach ($artifact in @($Plan)) {
            $relative = [string]$artifact.relativePath
            if ($relative.Contains('/')) { continue }
            $stagedPath = Join-Path $staging $relative
            if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) { continue }
            Copy-Item -LiteralPath $stagedPath -Destination (Join-Path $RuntimeRoot $relative) -Force
        }
        return [pscustomobject]@{ Ok = $true; Destination = $destination }
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        if ($swapped -and (Test-Path -LiteralPath $setAside)) {
            Remove-Item -LiteralPath $setAside -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- native pre-push wrapper (ONE canonical generator) ---------------------

$script:PrePushMarker = '# Hook Maker: Ignore-Rules-Check'

# The single source of truth for the managed pre-push wrapper's bytes. The
# installer WRITES this and the updater's integrity check REBUILDS it to
# compare - so "is the wrapper current?" is an exact-content question, not a
# collection of substring guesses that can drift from what we actually write.
#
# Semantics that must survive any edit here (each is asserted by the suite):
#   * mktemp-backed single stdin buffer (git delivers ref lines once),
#   * `trap ... EXIT` cleanup on every exit path,
#   * every managed stage fed that SAME buffer, in the given order,
#   * `|| exit $?` after each stage => fail-closed,
#   * the preserved previous hook runs last, with "$@" forwarded and the
#     same buffered stdin.
function New-PrePushWrapperBody {
    param([Parameter(Mandatory = $true)][string[]]$ManagedScripts)

    $stages = @($ManagedScripts) | ForEach-Object {
        $scriptPath = $_.Replace('\', '/').Replace('$', '\$').Replace('`', '\`')
        'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -GitPrePush < "$STDIN_FILE" || exit $?'
    }
    return "#!/bin/sh`n" + $script:PrePushMarker + "`n" +
        "STDIN_FILE=`$(mktemp `"`${TMPDIR:-/tmp}/hookmaker-prepush.XXXXXX`") || exit 1`n" +
        "trap 'rm -f `"`$STDIN_FILE`"' EXIT`n" +
        "cat > `"`$STDIN_FILE`"`n" +
        (($stages) -join "`n") + "`n" +
        "if [ -f `"`$0.hookmaker-existing`" ]; then`n  `"`$0.hookmaker-existing`" `"`$@`" < `"`$STDIN_FILE`"`nfi`n"
}

# Line-ending normalization is the ONLY difference tolerated between the
# expected and installed wrapper (a checkout or editor may rewrite CRLF/LF).
function Compare-PrePushWrapperBody {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual
    )
    $normalize = { param($t) ($t -replace "`r`n", "`n") }
    return ([string](& $normalize $Expected) -ceq [string](& $normalize $Actual))
}

# Retires the legacy shared runtime-root _hooklib.ps1.
#
# This runs ONLY as a post-commit cleanup phase, and only when it is provably
# unreferenced: every hook directory under the runtime root must already carry
# its own private copy. A hook installed by an older version still dot-sources
# '..\_hooklib.ps1', so removing the shared file while any such hook remains
# would break it - the check is what makes the removal safe rather than a
# hopeful cleanup.
function Remove-SharedRuntimeLibrary {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $shared = Join-Path $RuntimeRoot '_hooklib.ps1'
    if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'no shared library present' }
    }
    $hookDirs = @(Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('.hookmaker-', [System.StringComparison]::OrdinalIgnoreCase) })
    foreach ($hookDir in $hookDirs) {
        if (-not (Test-Path -LiteralPath (Join-Path $hookDir.FullName '_hooklib.ps1') -PathType Leaf)) {
            return [pscustomobject]@{ Removed = $false; Reason = ('still referenced by ' + $hookDir.Name) }
        }
    }
    try {
        Remove-Item -LiteralPath $shared -Force
        return [pscustomobject]@{ Removed = $true; Reason = 'every hook now has a private library copy' }
    }
    catch {
        return [pscustomobject]@{ Removed = $false; Reason = ('could not remove: ' + $_.Exception.Message) }
    }
}

# ---- Hook Maker registration ownership -------------------------------------

# The ONE place that decides "is this registered command a Hook Maker command,
# and if so which installation does it belong to?".
#
# Ownership is proven by the managed runtime PATH SHAPE
# (...\hooks\Hook-Maker\<Name>\<file>.ps1, or the legacy ...\hooks\HookMaker\...),
# never by a bare script basename - a user's own unrelated script that happens
# to share a filename must never be treated as ours.
function Get-HookMakerCommandInfo {
    param(
        [string]$Command,
        # Tool roots whose own hooks\ folder is KNOWN to be Hook Maker's. Only
        # these make the ambiguous historical tool-folder shape provable.
        [string[]]$KnownToolRoots = @()
    )
    $result = [pscustomobject]@{
        IsHookMaker   = $false
        # Looks like a Hook Maker layout but ownership cannot be proven.
        # Such entries are PRESERVED and reported, never removed.
        IsAmbiguous   = $false
        RuntimeScript = ''
        HookName      = ''
        Profile       = ''
        ConfigPath    = ''
        Layout        = ''
    }
    if ([string]::IsNullOrWhiteSpace($Command)) { return $result }

    # Form 1 (current + the renamed-folder legacy): a self-contained managed
    # runtime under ...\hooks\Hook-Maker\<Name>\<file>.ps1 (or the older
    # un-hyphenated HookMaker root). This shape is unambiguous - only Hook
    # Maker creates it.
    $match = [regex]::Match($Command, '(?<full>[^"]*[\\/]hooks[\\/](?<root>Hook-Maker|HookMaker)[\\/](?<name>[^\\/"]+)[\\/](?<leaf>[^\\/"]+\.ps1))')
    if ($match.Success) {
        $result.IsHookMaker = $true
        $result.RuntimeScript = $match.Groups['full'].Value
        $result.HookName = $match.Groups['name'].Value
        $result.Layout = if ($match.Groups['root'].Value -eq 'HookMaker') { 'legacy-root' } else { 'current' }
    }
    else {
        # Form 2 (proven historical): before self-contained installs, the
        # registered command pointed straight at a Hook Maker TOOL FOLDER's own
        # source layout, <toolRoot>\hooks\<Name>\<Name>.ps1.
        #
        # That path SHAPE alone is not proof of ownership - any project can have
        # hooks/Foo/Foo.ps1 - so it is only accepted when the path is rooted
        # under a KNOWN Hook Maker tool root supplied by the caller
        # (-KnownToolRoots: this installation plus any tool root recorded in the
        # registry's own history). Without that proof the entry is reported as
        # AMBIGUOUS: preserved, never removed.
        $legacy = [regex]::Match($Command, '(?<full>[^"]*[\\/]hooks[\\/](?<name>[^\\/"]+)[\\/](?<leaf>[^\\/"]+)\.ps1)')
        if (-not ($legacy.Success -and [string]::Equals($legacy.Groups['name'].Value, $legacy.Groups['leaf'].Value, [System.StringComparison]::OrdinalIgnoreCase))) {
            return $result
        }
        $candidatePath = $legacy.Groups['full'].Value
        $provenRoot = $false
        foreach ($knownRoot in @($KnownToolRoots)) {
            if ([string]::IsNullOrWhiteSpace($knownRoot)) { continue }
            $hooksRoot = Join-Path $knownRoot 'hooks'
            if (Test-PathContainedIn -ChildPath $candidatePath -ParentPath $hooksRoot) { $provenRoot = $true; break }
        }
        if (-not $provenRoot) {
            $result.IsAmbiguous = $true
            $result.RuntimeScript = $candidatePath
            $result.HookName = $legacy.Groups['name'].Value
            $result.Layout = 'ambiguous-toolfolder'
            return $result
        }
        $result.IsHookMaker = $true
        $result.RuntimeScript = $candidatePath
        $result.HookName = $legacy.Groups['name'].Value
        $result.Layout = 'legacy-toolfolder'
    }
    $profileMatch = [regex]::Match($Command, '-Profile\s+"([^"]*)"')
    if ($profileMatch.Success) { $result.Profile = $profileMatch.Groups[1].Value }
    $configMatch = [regex]::Match($Command, '-ConfigPath\s+"([^"]*)"')
    if ($configMatch.Success) { $result.ConfigPath = $configMatch.Groups[1].Value }
    return $result
}

# Every command-bearing field a client may use. Checked consistently everywhere
# so a handler registered only under commandWindows/command_windows is neither
# missed during discovery nor orphaned during stale removal.
$script:HookCommandFieldNames = @('command', 'commandWindows', 'command_windows')

function Get-HandlerCommandValues {
    param([Parameter(Mandatory = $true)]$Handler)
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($field in $script:HookCommandFieldNames) {
        if ($null -ne $Handler.PSObject.Properties[$field]) {
            $value = [string]$Handler.$field
            if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$values.Add($value) }
        }
    }
    return $values.ToArray()
}

# Does this handler belong to the given logical installation? Requires a real
# managed-runtime path match on at least one command field, the same hook name,
# and - for the sync engine - the same profile.
#
# A handler commonly carries the SAME logical command in more than one field
# (portable + Windows form). Ownership requires EVERY present field to
# positively agree with this install's target (mirroring _hookdiscovery.ps1's
# Get-HandlerTargetAgreement "all agree" philosophy for the read-only
# scanner). Get-HandlerCommandValues only returns fields that are actually
# present, so anything reaching this loop is real content - a plain user
# command, a DIFFERENT hook, a different profile, or an ambiguous unproven
# legacy shape all mean the handler is not fully ours, and removing it would
# silence whatever that other field pointed at.
function Test-HandlerBelongsToInstall {
    param(
        [Parameter(Mandatory = $true)]$Handler,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [string]$ProfileId = '',
        [string[]]$AlsoMatchHookNames = @(),
        [string[]]$KnownToolRoots = @()
    )
    $names = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    [void]$names.Add($FriendlyName)
    foreach ($alias in @($AlsoMatchHookNames)) {
        if (-not [string]::IsNullOrWhiteSpace($alias)) { [void]$names.Add($alias) }
    }
    $anyAgreed = $false
    foreach ($command in @(Get-HandlerCommandValues -Handler $Handler)) {
        $info = Get-HookMakerCommandInfo -Command $command -KnownToolRoots $KnownToolRoots
        if ($info.IsHookMaker -and $names.Contains($info.HookName) -and
            ([string]::IsNullOrWhiteSpace($ProfileId) -or $info.Profile -eq $ProfileId)) {
            $anyAgreed = $true
            continue
        }
        return $false
    }
    return $anyAgreed
}
