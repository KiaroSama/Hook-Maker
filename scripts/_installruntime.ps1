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

# Produces SYNC-PROJECTS.txt's exact content (rather than writing it directly)
# so the install plan can give this GENERATED artifact a deterministic expected
# hash and verify it like any other managed file.
function Get-SyncProjectListContent {
    param([Parameter(Mandatory = $true)][string]$RoutingConfig)

    if ([string]::IsNullOrWhiteSpace($Profile)) { return $null }
    if (-not (Test-Path -LiteralPath $RoutingConfig -PathType Leaf)) { return $null }
    $config = Get-Content -LiteralPath $RoutingConfig -Raw | ConvertFrom-Json
    $matchingProfile = @($config.profiles | Where-Object { $_.id -eq $Profile } | Select-Object -First 1)
    if ($matchingProfile.Count -eq 0) { return $null }

    $projectsByRoot = @{}
    foreach ($route in @($matchingProfile[0].routes)) {
        foreach ($endpoint in @($route.source, $route.destination)) {
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
    # WriteAllLines appends a trailing newline after the last line; match that
    # exactly so the planned hash equals what lands on disk.
    return (($lines.ToArray() -join "`r`n") + "`r`n")
}

# Installs are SELF-CONTAINED: the hook runtime (script, shared _hooklib.ps1,
# its .env, and - for the sync engine - the routing config) is COPIED into the
# scope's client folder (<scope>\.claude|.codex\hooks\Hook-Maker\<Friendly-Name>\),
# and the registered command points at that copy. Moving or deleting the Hook
# Maker folder never breaks an installed hook; re-run the install to refresh.
# The copy's folder + script use the friendly hyphenated name for easy ID.
function Copy-HookRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ClientDir,
        [string]$RuntimeRootOverride
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
    if ($isEngineInstall) { $syncListContent = Get-SyncProjectListContent -RoutingConfig $ConfigPath }
    $plan = Get-ManagedInstallPlan -SourceInfo $SourceInfo -FriendlyName $FriendlyName -ToolRoot $ToolRoot `
        -ConfigPath $ConfigPath -IncludeConfig:$isEngineInstall -SyncProjectListContent $syncListContent
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
