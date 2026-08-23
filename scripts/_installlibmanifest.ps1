# ---------------------------------------------------------------------------
# Managed-runtime manifests and the native Git pre-push chain's state check:
# what SHOULD be installed for a hook (derived from the canonical install
# plan), what actually IS on disk, the comparison that yields precise drift
# reasons, and the pre-push wrapper/companion verification.
#
# Split out of _installlib.ps1 (the manifest / native-pre-push concern) so
# that file could stay a manageable size. _installlib.ps1 dot-sources this
# file itself, in the same scope, so every existing consumer keeps
# dot-sourcing ONLY _installlib.ps1 and needs zero changes.
#
# Load-order contract (this file is never dot-sourced standalone - it is
# always pulled in from inside _installlib.ps1, which enforces the order):
#   1. hooks\_hooklib.ps1        (shared JSON/path helpers)
#   2. scripts\_installplan.ps1  (Get-InstallPlanFor, Get-PlanManifest,
#                                  $script:PrePushMarker, New-PrePushWrapperBody,
#                                  Compare-PrePushWrapperBody - consumers
#                                  dot-source it before _installlib.ps1, and
#                                  everything resolves at CALL time)
#   3. scripts\_installlib.ps1   (defines $script:ManagedRuntimeMutablePaths
#                                  in its header, THEN dot-sources this file)
#
# Nothing here mutates anything: every function is a read-only judgement over
# paths, hashes and wrapper text. Manifests never contain file contents -
# path + hash only - and the preserved user pre-push hook is checked for
# existence only, never read, hashed or rewritten.
# ---------------------------------------------------------------------------

function Test-ManagedRuntimeFileTracked {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $normalized = ([string]$RelativePath).Replace('\', '/').TrimStart('/')
    foreach ($mutable in $script:ManagedRuntimeMutablePaths) {
        if ([string]::Equals($normalized, ([string]$mutable).Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    # User configuration is not a managed artifact. Matched by LEAF NAME, because
    # no fixed path list could name it: the caller passes a path relative to the
    # HOOK directory, so the hook's own config arrives as exactly '.env'. The
    # single-segment test keeps it narrow - a '.env' nested inside a packaged
    # subdirectory is a shipped file and stays tracked.
    $segments = @($normalized.Split('/') | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 1) {
        foreach ($userConfig in $script:ManagedRuntimeUserConfigNames) {
            if ([string]::Equals($segments[0], [string]$userConfig, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    return $true
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Normalizes a manifest entry list into a deterministic, comparable form:
# forward-slash relative paths, lower-cased for comparison stability on
# Windows, sorted by path. Never contains file contents - path + hash only.
function ConvertTo-ManifestArray {
    param($Entries)
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $relative = ([string]$entry.path).Replace('\', '/').TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        [void]$normalized.Add([pscustomobject][ordered]@{
            path = $relative.ToLowerInvariant()
            hash = ([string]$entry.hash).ToUpperInvariant()
        })
    }
    return @($normalized.ToArray() | Sort-Object -Property path)
}

# The manifest of SOURCE files that Copy-HookRuntime will place into this
# hook's managed runtime, keyed by their logical path RELATIVE TO THE RUNTIME
# ROOT (the Hook-Maker folder) so it compares directly against what is
# actually installed there.
#
# Mirrors Copy-HookRuntime exactly: _hooklib.ps1 at the runtime root, the main
# script renamed to <FriendlyName>.ps1, every other file in the hook's source
# folder (including a real .env - hashed whole, never read), and, for the sync
# engine, the routing config copied in as sync-hooks.json.
# Delegates to the CANONICAL install plan so the updater's expectation is
# derived from exactly the same description the installer builds from - a
# separate approximation here is what previously let the two drift apart.
function Get-ManagedSourceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$HookScript,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [string]$ConfigPath = '',
        [switch]$IncludeConfig,
        [string]$ProfileId = '',
        # Client-agnostic does NOT mean project-agnostic: a record belongs to one
        # project, and the generated SYNC-PROJECTS.txt is keyed by it. Omitting it
        # here would make this manifest describe that file differently from
        # Get-ManagedClientManifest, i.e. permanent disagreement about one path.
        [AllowEmptyString()][string]$ProjectRoot = ''
    )
    $plan = Get-InstallPlanFor -HookScript $HookScript -ToolRoot $ToolRoot -FriendlyNameOverride $FriendlyName `
        -ProfileId $ProfileId -ConfigPath $ConfigPath -IsEngine:$IncludeConfig -AllowMissing `
        -ProjectRoot $ProjectRoot
    return ConvertTo-ManifestArray (Get-PlanManifest -Plan $plan)
}

# What ONE CLIENT's managed runtime should contain: the client-agnostic source
# manifest above PLUS the two artifacts that only exist per client -
# kiro-launch.ps1 (Kiro only) and the .hookmaker-runtime.json ownership metadata
# (every client, with that client's own identity inside it).
#
# This is the manifest to compare against Get-InstalledManifest.
# Get-ManagedSourceManifest is NOT: it deliberately stays client-agnostic because
# it answers a different question ("did the hook's SOURCE change since install?"),
# and the answer to that must not flip depending on which client is asked. Using
# it for the on-disk comparison is what made every real Kiro install report
# "unexpected managed file: <hook>/kiro-launch.ps1" on every single evaluation -
# a permanent update loop, because the launcher IS installed and was describable
# by no expected manifest.
function Get-ManagedClientManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$Client,
        [Parameter(Mandatory = $true)][string]$HookScript,
        [Parameter(Mandatory = $true)][string]$FriendlyName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RecordId,
        [Parameter(Mandatory = $true)][string]$Scope,
        [AllowEmptyString()][string]$ProjectRoot = '',
        [string]$ConfigPath = '',
        [switch]$IncludeConfig,
        [string]$ProfileId = ''
    )
    # 'kiro' by NAME, not by registrationKind: the launcher exists because Kiro
    # supplies neither the client identity nor the physical trigger to the hook it
    # runs, which is a Kiro fact - not a property of per-hook-file registration in
    # general. New-RuntimeIdentity validates the client id, so an unknown one is a
    # refusal here rather than a silently launcher-less plan.
    $identity = New-RuntimeIdentity -Client $Client -Scope $Scope -RecordId $RecordId -ProjectRoot $ProjectRoot
    $plan = Get-InstallPlanFor -HookScript $HookScript -ToolRoot $ToolRoot -FriendlyNameOverride $FriendlyName `
        -ProfileId $ProfileId -ConfigPath $ConfigPath -IsEngine:$IncludeConfig -AllowMissing `
        -IncludeKiroLauncher:($Client -ceq 'kiro') -RuntimeIdentity $identity
    return ConvertTo-ManifestArray (Get-PlanManifest -Plan $plan)
}

# The manifest of what is ACTUALLY on disk inside a managed runtime root, in
# the same shape/keys as Get-ManagedSourceManifest so the two compare directly.
# Only this hook's own folder plus the shared _hooklib.ps1 are considered -
# other hooks' folders under the same runtime root belong to other records.
function Get-InstalledManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    $entries = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot) -or -not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        return @()
    }
    # The runtime-root _hooklib.ps1 is deliberately NOT part of any hook's
    # manifest: each hook owns a private copy inside its own directory. A root
    # copy left over from an older layout belongs to no record and is cleaned
    # up only after a successful install (see Remove-SharedRuntimeLibrary).
    $hookDir = Join-Path $RuntimeRoot $FriendlyName
    if (Test-Path -LiteralPath $hookDir -PathType Container) {
        $hookRoot = [System.IO.Path]::GetFullPath($hookDir).TrimEnd('\') + '\'
        foreach ($file in @(Get-ChildItem -LiteralPath $hookDir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($hookRoot.Length)
            if (-not (Test-ManagedRuntimeFileTracked -RelativePath $relative)) { continue }
            [void]$entries.Add([pscustomobject]@{ path = ($FriendlyName + '/' + $relative); hash = (Get-FileSha256 $file.FullName) })
        }
    }
    # .ToArray(): @($aListOfObject) throws "Argument types do not match" on
    # both PS hosts, even when empty - a documented trap in this project.
    return ConvertTo-ManifestArray $entries.ToArray()
}

# Compares two manifests and returns the concrete differences, so a caller can
# report a precise reason ("installed file modified: X") instead of a bare
# "stale". Never returns file contents.
function Compare-Manifest {
    param($Expected, $Actual)
    $expectedMap = @{}
    foreach ($entry in @($Expected)) { $expectedMap[[string]$entry.path] = [string]$entry.hash }
    $actualMap = @{}
    foreach ($entry in @($Actual)) { $actualMap[[string]$entry.path] = [string]$entry.hash }

    $missing = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $unexpected = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($expectedMap.Keys)) {
        if (-not $actualMap.ContainsKey($path)) { [void]$missing.Add($path); continue }
        if ($actualMap[$path] -ne $expectedMap[$path]) { [void]$modified.Add($path) }
    }
    foreach ($path in @($actualMap.Keys)) {
        if (-not $expectedMap.ContainsKey($path)) { [void]$unexpected.Add($path) }
    }
    return [pscustomobject]@{
        Missing    = @(@($missing.ToArray()) | Sort-Object)
        Modified   = @(@($modified.ToArray()) | Sort-Object)
        Unexpected = @(@($unexpected.ToArray()) | Sort-Object)
        IsMatch    = ($missing.Count -eq 0 -and $modified.Count -eq 0 -and $unexpected.Count -eq 0)
    }
}

# The native Git pre-push chain is part of the logical Ignore-Rules-Check
# installation, not a separate install: the same operation copies a managed
# runtime for the hook itself PLUS a managed copy of every bundled companion
# (currently Secrets-Check) under the repository's git hooks path. Its manifest
# must therefore include the companions' SOURCE hashes - otherwise a change to
# only Secrets-Check.ps1 leaves the native chain stale while the parent hook
# still looks current.
#
# Mirrors Copy-PrePushCompanion exactly: a companion contributes its own
# <Name>.ps1 and, when the source folder has one, its .env - not the whole
# folder (that is only true for the primary hook, via Copy-HookRuntime).
function Get-NativePrePushSourceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$PrimaryFriendlyName,
        [Parameter(Mandatory = $true)][string]$PrimaryHookScript,
        [Parameter(Mandatory = $true)][string]$PrimarySourceDir,
        [string[]]$Companions = @()
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $PrimaryHookScript -SourceDir $PrimarySourceDir -FriendlyName $PrimaryFriendlyName)) {
        [void]$entries.Add($entry)
    }
    # Companions are installed through the canonical plan (private library +
    # dot-source rewrite), so their expected hashes MUST come from that same
    # plan. Hashing the raw source files here was a second rule that no longer
    # describes what is actually installed.
    foreach ($companion in @($Companions)) {
        $companionScript = Join-Path $ToolRoot ('hooks\' + $companion + '\' + $companion + '.ps1')
        if (-not (Test-Path -LiteralPath $companionScript -PathType Leaf)) { continue }
        $companionPlan = Get-InstallPlanFor -HookScript $companionScript -ToolRoot $ToolRoot -FriendlyNameOverride $companion -AllowMissing
        foreach ($entry in @(Get-PlanManifest -Plan $companionPlan)) {
            [void]$entries.Add($entry)
        }
    }
    # .ToArray(): @($aListOfObject) throws "Argument types do not match" on
    # both PS hosts, even when empty - a documented trap in this project.
    return ConvertTo-ManifestArray $entries.ToArray()
}

# What is actually installed under the native git hooks runtime root, in the
# same shape as Get-NativePrePushSourceManifest.
function Get-NativePrePushInstalledManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$PrimaryFriendlyName,
        [string[]]$Companions = @()
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-InstalledManifest -RuntimeRoot $RuntimeRoot -FriendlyName $PrimaryFriendlyName)) {
        [void]$entries.Add($entry)
    }
    foreach ($companion in @($Companions)) {
        $companionDir = Join-Path $RuntimeRoot $companion
        if (-not (Test-Path -LiteralPath $companionDir -PathType Container)) { continue }
        $companionRoot = [System.IO.Path]::GetFullPath($companionDir).TrimEnd('\') + '\'
        foreach ($file in @(Get-ChildItem -LiteralPath $companionDir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($companionRoot.Length)
            if (-not (Test-ManagedRuntimeFileTracked -RelativePath $relative)) { continue }
            [void]$entries.Add([pscustomobject]@{ path = ($companion + '/' + $relative); hash = (Get-FileSha256 $file.FullName) })
        }
    }
    # .ToArray(): @($aListOfObject) throws "Argument types do not match" on
    # both PS hosts, even when empty - a documented trap in this project.
    return ConvertTo-ManifestArray $entries.ToArray()
}

# Verifies the managed wrapper itself: present, ours (marker), chains every
# managed stage exactly once, and still honours the preserved user hook. The
# preserved hook is USER-OWNED - its mere existence is checked, its content is
# never hashed, rewritten, or compared.
function Test-NativePrePushState {
    param(
        [Parameter(Mandatory = $true)]$NativeRecord,
        [Parameter(Mandatory = $true)][string]$PrimaryFriendlyName
    )
    $wrapper = [string]$NativeRecord.wrapperPath
    if ([string]::IsNullOrWhiteSpace($wrapper) -or -not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = 'managed pre-push wrapper is missing' }
    }
    $body = [System.IO.File]::ReadAllText($wrapper)
    if (-not $body.Contains($script:PrePushMarker)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = 'pre-push hook is no longer the Hook Maker managed wrapper' }
    }
    # Exact comparison against a wrapper REBUILT by the same generator the
    # installer uses. This proves stage order, single invocation per stage, the
    # mktemp stdin buffer, the cleanup trap, `|| exit $?` fail-closed behaviour,
    # argument forwarding and the previous-hook stage all at once - substring
    # probes could only ever approximate that.
    if ($null -ne $NativeRecord.PSObject.Properties['expectedStages'] -and $null -ne $NativeRecord.expectedStages) {
        $expectedStages = @($NativeRecord.expectedStages | ForEach-Object { [string]$_ })
        if ($expectedStages.Count -gt 0) {
            $expectedBody = New-PrePushWrapperBody -ManagedScripts $expectedStages
            if (-not (Compare-PrePushWrapperBody -Expected $expectedBody -Actual $body)) {
                return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = 'the managed pre-push wrapper does not match its expected content' }
            }
        }
    }
    else {
        # Records written before expectedStages existed: fall back to proving
        # each stage appears exactly once (the previous, weaker check).
        $stages = @($PrimaryFriendlyName)
        foreach ($companion in @($NativeRecord.companions)) { $stages += [string]$companion }
        foreach ($stage in $stages) {
            $marker = '/' + $stage + '/' + $stage + '.ps1"'
            $occurrences = ([regex]::Matches($body, [regex]::Escape($marker))).Count
            if ($occurrences -eq 0) {
                return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = ('pre-push chain no longer runs ' + $stage) }
            }
            if ($occurrences -gt 1) {
                return [pscustomobject]@{ Ok = $false; Reason = 'duplicate registration'; Detail = ('pre-push chain runs ' + $stage + ' more than once') }
            }
        }
    }
    # The preserved user hook is USER-OWNED: existence only, never hashed or
    # rewritten. Because previousHookPreserved is sticky, a hook that once
    # existed and has since vanished stays an unresolved state needing manual
    # attention - it is never silently forgotten.
    if ($null -ne $NativeRecord.PSObject.Properties['previousHookPath']) {
        $previous = [string]$NativeRecord.previousHookPath
        if (-not [string]::IsNullOrWhiteSpace($previous) -and
            $null -ne $NativeRecord.PSObject.Properties['previousHookPreserved'] -and $NativeRecord.previousHookPreserved -eq $true -and
            -not (Test-Path -LiteralPath $previous -PathType Leaf)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'manual repair required'; Detail = 'a previously preserved user pre-push hook is missing; Hook Maker will not recreate or overwrite a user-owned hook' }
        }
    }
    $expected = @($NativeRecord.sourceManifest)
    $actual = @(Get-NativePrePushInstalledManifest -RuntimeRoot ([string]$NativeRecord.runtimeRoot) -PrimaryFriendlyName $PrimaryFriendlyName -Companions @($NativeRecord.companions))
    $difference = Compare-Manifest -Expected $expected -Actual $actual
    if (-not $difference.IsMatch) {
        $detail = 'native managed files differ'
        if ($difference.Missing.Count -gt 0) { $detail = 'native managed file missing: ' + $difference.Missing[0] }
        elseif ($difference.Modified.Count -gt 0) { $detail = 'native managed file modified: ' + $difference.Modified[0] }
        return [pscustomobject]@{ Ok = $false; Reason = 'native integration stale'; Detail = $detail }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'current'; Detail = '' }
}
