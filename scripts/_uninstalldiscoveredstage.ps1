# ---------------------------------------------------------------------------
# Discovered-uninstall result plumbing and staging/rollback machinery - split
# out of Uninstall-DiscoveredHook.ps1.
#
# ONE responsibility: the mutation-side helpers the discovered remover acts
# WITH once the evidence proofs (in _uninstalldiscoveredscan.ps1) have passed -
# the structured -ResultPath outcome document, the compensating sibling-rename
# set-asides, the pre-publish settings snapshots, and the verified registry
# record removal. The decisions about WHAT may be removed never live here.
#
# DOT-SOURCED, not imported: Uninstall-DiscoveredHook.ps1 dot-sources this into
# its own scope, so these functions read the following variables from the
# including scope at CALL time exactly as they did when they lived inline. This
# file is not standalone and must not be dot-sourced anywhere else:
#   $RecordId                    - the id being removed
#   $ResultPath                  - machine-readable outcome document destination
#   $WhatIf                      - dry-run switch
#   $ToolRoot                    - the installation whose registry is mutated
#   $script:ComponentResults     - per-component outcome list
#   $script:SetAsides            - staged sibling renames awaiting commit/rollback
#   $script:SettingsSnapshots    - pre-publish settings copies awaiting cleanup
#
# It also uses Get-RecordString from _uninstalldiscoveredscan.ps1 and the
# registry lock/read/save helpers from _installlib.ps1, which
# Uninstall-DiscoveredHook.ps1 dot-sources first.
# ---------------------------------------------------------------------------

# ---- structured outcome (same contract as Uninstall-Hook.ps1) --------------
function Set-ComponentResult {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'failed', 'skipped', 'manualRepair')][string]$Status,
        [string]$ReasonCode = '',
        [string]$Message = ''
    )
    # Sanitized message only: never raw file contents, command strings, .env
    # values or stdin. A discovered command line can embed a secret, so nothing
    # derived from one ever reaches this document.
    [void]$script:ComponentResults.Add([pscustomobject][ordered]@{
        component = $Component
        status    = $Status
        reason    = $ReasonCode
        message   = $Message
        atUtc     = [DateTime]::UtcNow.ToString('o')
    })
}
function Write-UninstallResult {
    param([string]$Overall)
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    try {
        $document = [pscustomobject][ordered]@{
            schema     = 1
            overall    = $Overall
            dryRun     = [bool]$WhatIf
            recordId   = $RecordId
            recordType = 'discovered'
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
        # A result-file failure must never fail the uninstall itself.
    }
}

# ---- staged sibling renames -------------------------------------------------
# Nothing is destroyed until every required commit has succeeded, so any
# failure mid-run restores the machine exactly as it was.
function Add-SetAside {
    param([Parameter(Mandatory = $true)][string]$Path)
    $setAside = $Path + '.hookmaker-disc-setaside-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Move-Item -LiteralPath $Path -Destination $setAside -Force
    [void]$script:SetAsides.Add([pscustomobject]@{ Original = $Path; SetAside = $setAside })
}
function Restore-SetAsides {
    foreach ($entry in @($script:SetAsides.ToArray())) {
        try {
            if (Test-Path -LiteralPath $entry.SetAside) { Move-Item -LiteralPath $entry.SetAside -Destination $entry.Original -Force }
        }
        catch { }
    }
    $script:SetAsides.Clear()
}
function Complete-SetAsides {
    $incomplete = $false
    foreach ($entry in @($script:SetAsides.ToArray())) {
        try {
            if (Test-Path -LiteralPath $entry.SetAside) { Remove-Item -LiteralPath $entry.SetAside -Recurse -Force }
        }
        catch { $incomplete = $true }
    }
    $script:SetAsides.Clear()
    return $incomplete
}

# ---- pre-publish settings snapshots -----------------------------------------
function Restore-PublishedSettings {
    # Returns the client names whose published settings file could NOT be put
    # back. Only PUBLISHED files are touched: restoring a file this run never
    # wrote would be a mutation dressed up as a rollback.
    $unrestored = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($script:SettingsSnapshots.ToArray())) {
        if (-not $entry.Published) { continue }
        try { Copy-Item -LiteralPath $entry.Snapshot -Destination $entry.Original -Force }
        catch { [void]$unrestored.Add([string]$entry.ClientName) }
    }
    return , $unrestored
}
function Complete-SettingsSnapshots {
    foreach ($entry in @($script:SettingsSnapshots.ToArray())) {
        try { Remove-Item -LiteralPath $entry.Snapshot -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:SettingsSnapshots.Clear()
}

# ---- verified registry record removal ---------------------------------------
function Remove-DiscoveredRecord {
    try {
        return Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $state = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($state.State -eq 'corrupt') { return [pscustomobject]@{ Ok = $false; Warning = ('registry is unreadable: ' + [string]$state.Reason) } }
            $live = ConvertTo-InstallRegistryCurrent -Registry $state.Registry
            $live.installs = @(@($live.installs) | Where-Object { $null -eq $_ -or (Get-RecordString $_ 'id') -ne $RecordId })
            Save-InstallRegistry -ToolRoot $ToolRoot -Registry $live
            # Verified, not assumed.
            $verify = Read-InstallRegistryState -ToolRoot $ToolRoot
            if ($verify.State -ne 'ok') { return [pscustomobject]@{ Ok = $false; Warning = ('registry did not read back cleanly: ' + [string]$verify.Reason) } }
            $stillPresent = @(@($verify.Registry.installs) | Where-Object { $null -ne $_ -and (Get-RecordString $_ 'id') -eq $RecordId }).Count
            if ($stillPresent -ne 0) { return [pscustomobject]@{ Ok = $false; Warning = 'the record was still present after a removal attempt' } }
            return [pscustomobject]@{ Ok = $true; Warning = '' }
        }
    }
    catch { return [pscustomobject]@{ Ok = $false; Warning = $_.Exception.Message } }
}
