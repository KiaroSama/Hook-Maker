# New installations require the complete runtime. Optional loading exists only
# for already-installed legacy copies, not for a damaged current checkout.
# This file describes payloads in memory; it never edits a target installation.

function Assert-RuntimeSourcesAvailable {
    param([string]$ToolRoot, [string[]]$RelativePaths)
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($relative in $RelativePaths) {
        $handle = $null
        try {
            $path = Join-Path $ToolRoot $relative
            $handle = [IO.File]::Open($path, 'Open', 'Read', 'Read')
            if ($handle.Length -eq 0) { throw 'empty runtime source' }
        }
        catch { [void]$failures.Add($relative) }
        finally { if ($null -ne $handle) { $handle.Dispose() } }
    }
    if ($failures.Count -gt 0) {
        throw ('Runtime source preflight failed. Restore the missing, unreadable or empty required files before installation: ' + ($failures.ToArray() -join ', '))
    }
}

function Add-SharedRuntimeLibraryArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    $required = @('_hooklib.ps1', '_stoplib.ps1', '_evidencelib.ps1', '_taskidentity.ps1', '_processtree.ps1', '_deliverylib.ps1', '_scope.ps1')
    Assert-RuntimeSourcesAvailable -ToolRoot $ToolRoot -RelativePaths @($required | ForEach-Object { 'hooks/' + $_ })
    # Validate the whole shared set BEFORE contributing even one artifact.
    foreach ($leaf in $required) {
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/' + $leaf) -Kind 'File' -SourcePath (Join-Path $ToolRoot ('hooks/' + $leaf)))
    }
}

function Add-CompanionRuntimeArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )
    if ([string]::Equals($FriendlyName, 'Test-Run-Guard', [StringComparison]::OrdinalIgnoreCase)) {
        $relative = 'scripts/Run-Tests-Guarded.ps1'
        Assert-RuntimeSourcesAvailable -ToolRoot $ToolRoot -RelativePaths @($relative)
        Add-Artifact (New-PlanArtifact -RelativePath ($FriendlyName + '/' + $relative) -Kind 'File' -SourcePath (Join-Path $ToolRoot $relative))
    }
}
