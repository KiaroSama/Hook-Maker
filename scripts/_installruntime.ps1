# ---------------------------------------------------------------------------
# Runtime materialization: turning a hook's SOURCE into the self-contained copy
# an installed registration points at, and the two command lines that invoke
# that copy.
#
# Split out of Install-Hook.ps1 (which had grown past the file-size review
# signal) because staging files on disk is a distinct responsibility from
# registering a command in a client's settings file
# (_installclientsettings.ps1).
#
# Dot-sourced by Install-Hook.ps1 only. These functions rely on that script's
# parameters and ambient script-scope state ($Profile, $ConfigPath,
# $CustomHook, $FriendlyName, $SourceName, $SourceInfo, $ToolRoot,
# $script:LegacyCleanupWarnings) and on _installplan.ps1
# (Get-ManagedInstallPlan, Install-PlannedRuntime, Remove-SharedRuntimeLibrary)
# - dot-sourcing splices these functions into the callers scope, and calls
# resolve at invocation time, so this is a normal one-directional dependency,
# not a layering violation.
# ---------------------------------------------------------------------------

# SYNC-PROJECTS.txt used to be generated HERE as well as in _installplan.ps1 -
# two copies of the same bytes, which a runtime is then hash-verified against.
# The installer now calls the planner's Get-SyncProjectListContentFor, so there
# is one generator and divergence is impossible rather than merely unlikely.

# Installs are SELF-CONTAINED: the hook runtime (script, shared _hooklib.ps1,
# its .env, and - for the sync engine - the routing config) is COPIED into the
# scope's client folder (<scope>\.claude|.codex\hooks\Hook-Maker\<Friendly-Name>\),
# and the registered command points at that copy. Moving or deleting the Hook
# Maker folder never breaks an installed hook; re-run the install to refresh.
# The copy's folder + script use the friendly hyphenated name for easy ID.
function Copy-HookRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ClientDir,
        [string]$RuntimeRootOverride,
        # Per-hook-file clients only - see Get-ManagedInstallPlan. Planning the launcher rather
        # than writing it afterwards is what keeps it inside the manifest and
        # out of the updater's "unexpected managed file" path.
        # Which install this runtime copy belongs to (New-RuntimeIdentity). Passed
        # per CLIENT, because that is what the metadata file records - the same
        # source installed for Claude and for Codex produces two runtimes whose
        # only difference is this identity. Omitted (the native Git pre-push
        # chain, which has no client identity) plans no metadata file.
        $RuntimeIdentity = $null
    )

    $runtimeRoot = if ([string]::IsNullOrWhiteSpace($RuntimeRootOverride)) {
        Join-Path $ClientDir 'hooks\Hook-Maker'
    }
    else {
        [System.IO.Path]::GetFullPath($RuntimeRootOverride)
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    # NOTE: the shared library is no longer written to the runtime root here.
    # Each hook receives a PRIVATE _hooklib.ps1 inside its own runtime
    # directory as part of the plan, installed transactionally with the rest of
    # that hook. Writing it to the root before the transaction was both an
    # unrollback-able side effect and a cross-hook coupling: it changed the
    # library other installed hooks load, before this install had committed.

    $destDir = Join-Path $runtimeRoot $FriendlyName

    # Build the canonical plan, then install it TRANSACTIONALLY: staged in a
    # sibling directory, hash-verified, and only then swapped into place. The
    # previous runtime survives any failure before the swap and is restored if
    # the swap itself fails - a failed update never leaves a working
    # installation less functional than it was.
    $isEngineInstall = [string]::IsNullOrWhiteSpace($CustomHook)
    $syncListContent = $null
    if ($isEngineInstall) {
        # $Profile comes from Install-Hook.ps1's parameters, which this file is
        # dot-sourced into. The project root keys the generated list, so a runtime
        # shared by several sync groups gets the same bytes no matter which record
        # installs it. Read defensively: the native Git pre-push chain calls this
        # function with no identity at all, and StrictMode throws on a property of
        # $null.
        $identityProjectRoot = ''
        if ($null -ne $RuntimeIdentity) { $identityProjectRoot = [string]$RuntimeIdentity.ProjectRoot }
        $syncListContent = Get-SyncProjectListContentFor -RoutingConfig $ConfigPath -ProfileId ([string]$Profile) `
            -ProjectRoot $identityProjectRoot
    }
    $plan = Get-ManagedInstallPlan -SourceInfo $SourceInfo -FriendlyName $FriendlyName -ToolRoot $ToolRoot `
        -ConfigPath $ConfigPath -IncludeConfig:$isEngineInstall -SyncProjectListContent $syncListContent `
        -RuntimeIdentity $RuntimeIdentity
    Install-PlannedRuntime -Plan $plan -RuntimeRoot $runtimeRoot -FriendlyName $FriendlyName | Out-Null

    # ---- POST-COMMIT CLEANUP ONLY, past this point -------------------------
    # The replacement runtime is now staged, hash-verified and swapped into
    # place, so nothing below can destroy a not-yet-committed replacement.
    # Removing these BEFORE the commit above (the previous ordering) meant a
    # staging/swap failure could delete a still-working legacy installation
    # and leave NEITHER the old nor the new runtime behind. Each cleanup is
    # independent and best-effort: a failure here is reported as a warning and
    # never allowed to fail the install or be mistaken for a completed cleanup.
    $script:LegacyCleanupWarnings = @()

    # Retires the legacy shared library once every hook under this root owns a
    # private copy (already correctly post-commit-only).
    try { Remove-SharedRuntimeLibrary -RuntimeRoot $runtimeRoot | Out-Null }
    catch { $script:LegacyCleanupWarnings += ('shared library cleanup: ' + $_.Exception.Message) }

    # Migrate this hook out of a legacy 'HookMaker' folder (older, un-hyphenated
    # runtime root). Only remove THIS hook's subfolder so other hooks still
    # registered there keep working; drop the whole legacy root once it holds no
    # more hook subfolders.
    if ([string]::IsNullOrWhiteSpace($RuntimeRootOverride)) {
        $legacyRoot = Join-Path $ClientDir 'hooks\HookMaker'
        if ((Test-Path -LiteralPath $legacyRoot) -and -not [string]::Equals($legacyRoot, $runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                $legacyHookDir = Join-Path $legacyRoot $FriendlyName
                if (Test-Path -LiteralPath $legacyHookDir) { Remove-Item -LiteralPath $legacyHookDir -Recurse -Force }
                if (@(Get-ChildItem -LiteralPath $legacyRoot -Directory -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $legacyRoot -Recurse -Force
                }
            }
            catch { $script:LegacyCleanupWarnings += ('legacy HookMaker root cleanup: ' + $_.Exception.Message) }
        }
    }

    $legacyDir = Join-Path $runtimeRoot $SourceName
    if ($SourceName -ne $FriendlyName -and (Test-Path -LiteralPath $legacyDir)) {
        try { Remove-Item -LiteralPath $legacyDir -Recurse -Force }
        catch { $script:LegacyCleanupWarnings += ('legacy same-runtime directory cleanup: ' + $_.Exception.Message) }
    }
    $legacyRootConfig = Join-Path $runtimeRoot 'sync-hooks.json'
    if (Test-Path -LiteralPath $legacyRootConfig) {
        try { Remove-Item -LiteralPath $legacyRootConfig -Force }
        catch { $script:LegacyCleanupWarnings += ('legacy root sync-hooks.json cleanup: ' + $_.Exception.Message) }
    }
    foreach ($cleanupWarning in @($script:LegacyCleanupWarnings)) {
        Write-Host ('WARNING: legacy cleanup incomplete (manual cleanup may be required) - ' + $cleanupWarning)
    }

    $friendlyScript = Join-Path $destDir ($FriendlyName + '.ps1')
    $localConfig = if ($isEngineInstall) { Join-Path $destDir 'sync-hooks.json' } else { '' }
    return [pscustomobject]@{
        Script = $friendlyScript
        Config = $localConfig
        Plan   = $plan
    }
}

# Builds the two command lines (Windows PowerShell / pwsh) for a runtime copy.
function New-HookCommands {
    param([Parameter(Mandatory = $true)]$Runtime)

    $suffix = ''
    if ([string]::IsNullOrWhiteSpace($CustomHook)) {
        $suffix = ' -ConfigPath "' + $Runtime.Config + '"'
        if (-not [string]::IsNullOrWhiteSpace($Profile)) {
            $suffix += ' -Profile "' + $Profile + '"'
        }
    }
    return [pscustomobject]@{
        Windows = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Runtime.Script + '"' + $suffix
        Portable = 'pwsh -NoLogo -NoProfile -NonInteractive -File "' + $Runtime.Script + '"' + $suffix
    }
}
