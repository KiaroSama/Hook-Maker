# ---------------------------------------------------------------------------
# Update-Fleet.ps1 -Compare: read-only content compare of every managed
# runtime against the source it is installed from.
#
# For each managed record and installed client, the expected manifest is the
# one the installer builds from the CURRENT source (Get-ManagedClientManifest,
# the same plan the integrity check uses) and the actual manifest is a SHA-256
# of every file in the installed hook directory (Get-InstalledManifest). Files
# the expected manifest lists but the runtime lacks are "missing"; files whose
# bytes differ are "different". Nothing is written.
#
# Dot-sourced by Update-Fleet.ps1 after the install libraries.
# ---------------------------------------------------------------------------

function Invoke-FleetCompare {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$ToolRoot
    )
    $projects = [ordered]@{}
    $totals = [pscustomobject]@{ Registrations = 0; Files = 0; Missing = 0; Different = 0; Mismatched = 0; Errors = 0; Unreachable = 0 }
    foreach ($record in @($Records)) {
        $scope = Get-FleetRecordField $record 'scope'
        $target = Get-FleetRecordField $record 'targetProjectRoot'
        $name = Get-FleetRecordField $record 'friendlyName'
        $label = if ($scope -eq 'global') { '<global>' } else { $target }
        if (-not $projects.Contains($label)) {
            $projects[$label] = [pscustomobject]@{ Project = $label; Registrations = 0; Files = 0; Missing = 0; Different = 0; Errors = 0 }
        }
        $row = $projects[$label]
        if ($scope -ne 'global' -and ($target -eq '' -or -not (Test-Path -LiteralPath $target -PathType Container))) {
            $totals.Unreachable++
            continue
        }
        $isEngine = ((Get-FleetRecordField $record 'hookType') -eq 'Engine')
        foreach ($client in @(Get-InstalledClientNames -Record $record)) {
            $row.Registrations++
            $totals.Registrations++
            $subrecord = Get-ClientSubrecord -Record $record -Client $client
            $runtimeRoot = if ($null -ne $subrecord -and $null -ne $subrecord.PSObject.Properties['runtimeRoot']) { [string]$subrecord.runtimeRoot } else { '' }
            try {
                $expected = @(Get-ManagedClientManifest -ToolRoot $ToolRoot -Client $client `
                        -HookScript (Get-FleetRecordField $record 'sourceScript') -FriendlyName $name `
                        -RecordId (Get-FleetRecordField $record 'id') -Scope $scope -ProjectRoot $target `
                        -ConfigPath (Get-FleetRecordField $record 'configPath') -IncludeConfig:$isEngine `
                        -ProfileId (Get-FleetRecordField $record 'profile'))
                $actual = @(Get-InstalledManifest -RuntimeRoot $runtimeRoot -FriendlyName $name)
                $difference = Compare-Manifest -Expected $expected -Actual $actual
                $missingCount = @($difference.Missing).Count
                $differentCount = @($difference.Modified).Count
                # Several sync-group records share one runtime and only one can be
                # named in its ownership metadata; the integrity check accepts the
                # others, and so does this compare.
                if ($missingCount -eq 0 -and $differentCount -eq 1 -and
                    ([string]$difference.Modified[0]).EndsWith('/' + $script:RuntimeMetadataFileName, [System.StringComparison]::OrdinalIgnoreCase) -and
                    (Test-SiblingOwnedRuntime -ExpectedManifest $expected -RuntimeRoot $runtimeRoot -FriendlyName $name -Client $client `
                            -Scope $scope -ProjectRoot $target -RecordId (Get-FleetRecordField $record 'id'))) {
                    $differentCount = 0
                }
                $row.Files += $expected.Count
                $totals.Files += $expected.Count
                $row.Missing += $missingCount
                $row.Different += $differentCount
                $totals.Missing += $missingCount
                $totals.Different += $differentCount
                if ($missingCount -gt 0 -or $differentCount -gt 0) { $totals.Mismatched++ }
            }
            catch {
                $row.Errors++
                $totals.Errors++
                $totals.Mismatched++
            }
        }
    }
    return [pscustomobject]@{ Projects = @($projects.Values | Where-Object { $_.Registrations -gt 0 }); Totals = $totals }
}
