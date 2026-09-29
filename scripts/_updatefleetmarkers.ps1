# ---------------------------------------------------------------------------
# Update-Fleet.ps1: markers and the per-registration verdict.
#
# A REGISTRATION is one (record, client) pair. Its state comes from two places
# only - the wizard's own evaluation (Get-UpdateEvaluationPlan) and the files
# in its installed runtime (markers) - never from a bookkeeping file, so an
# interrupted -Apply resumes by simply running again.
#
# Dot-sourced by Update-Fleet.ps1 after the install libraries; relies on
# Get-InstalledClientNames, Get-ClientSubrecord and Resolve-UpdateEventsForClient
# from them.
# ---------------------------------------------------------------------------

# '<file>[:<pattern>]' -> { File; Pattern }. The file is relative to the hook's
# own runtime directory; an empty pattern means "the file exists".
function ConvertTo-FleetMarker {
    param([Parameter(Mandatory = $true)][string]$Spec)
    $text = $Spec.Trim()
    $file = $text
    $pattern = ''
    $colon = $text.IndexOf(':')
    if ($colon -ge 0) {
        $file = $text.Substring(0, $colon).Trim()
        $pattern = $text.Substring($colon + 1)
    }
    if ([string]::IsNullOrWhiteSpace($file)) { throw ('A -Marker needs a file name: ' + $Spec) }
    if ([System.IO.Path]::IsPathRooted($file) -or $file -match '(^|[\\/])\.\.([\\/]|$)') {
        throw ('A -Marker file must be relative to the hook runtime directory: ' + $Spec)
    }
    return [pscustomobject]@{ File = $file; Pattern = $pattern; Spec = $text }
}

# The first marker the runtime directory lacks, or '' when every one is present.
function Get-MissingFleetMarker {
    param([string]$RuntimeDir, [object[]]$Markers)
    foreach ($marker in @($Markers)) {
        if ($null -eq $marker) { continue }
        $path = Join-Path $RuntimeDir $marker.File
        if ([string]::IsNullOrWhiteSpace($RuntimeDir) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $marker.Spec }
        if ([string]::IsNullOrEmpty([string]$marker.Pattern)) { continue }
        $text = ''
        try { $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch { return $marker.Spec }
        if ($text.IndexOf([string]$marker.Pattern, [System.StringComparison]::Ordinal) -lt 0) { return $marker.Spec }
    }
    return ''
}

function Get-FleetRecordField {
    param($Record, [string]$Name)
    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties[$Name]) { return '' }
    return [string]$Record.$Name
}

# True when the record belongs to the -OnlyProject selection: the full project
# root or its folder name, case-insensitive. Global records never match.
function Test-FleetProjectSelected {
    param($Record, [string]$OnlyProject)
    if ([string]::IsNullOrWhiteSpace($OnlyProject)) { return $true }
    if ((Get-FleetRecordField $Record 'scope') -eq 'global') { return $false }
    $root = (Get-FleetRecordField $Record 'targetProjectRoot').TrimEnd([char]92, [char]47)
    if ($root -eq '') { return $false }
    $wanted = $OnlyProject.Trim().TrimEnd([char]92, [char]47)
    if ([string]::Equals($root, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    try {
        if ([System.IO.Path]::IsPathRooted($wanted) -and
            [string]::Equals($root, [System.IO.Path]::GetFullPath($wanted).TrimEnd([char]92), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    catch { }
    return [string]::Equals((Split-Path -Leaf $root), $wanted, [System.StringComparison]::OrdinalIgnoreCase)
}

# One entry per registration, in plan order. State is one of:
#   current | stale | pending-migration | unreachable | skipped
# 'unreachable' is a project folder that is gone; 'skipped' is any other reason
# the evaluation refused (invalid record, missing source or profile). Neither
# is a failure, and neither is ever touched.
function Get-FleetRegistrations {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Plan,
        [object[]]$Markers = @()
    )
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Plan)) {
        $record = $entry.Record
        $scope = Get-FleetRecordField $record 'scope'
        $target = Get-FleetRecordField $record 'targetProjectRoot'
        $label = if ($scope -eq 'global') { '<global>' } elseif ($target -ne '') { Split-Path -Leaf $target } else { '(unknown)' }
        $name = Get-FleetRecordField $record 'friendlyName'
        if ($name -eq '') { $name = 'unknown-record' }
        $clients = @()
        try { $clients = @(Get-InstalledClientNames -Record $record) } catch { $clients = @() }

        if ([string]$entry.Status -eq 'skip') {
            $state = if ([string]$entry.Detail -like 'target project no longer found*') { 'unreachable' } else { 'skipped' }
            $names = if ($clients.Count -gt 0) { $clients } else { @('-') }
            foreach ($client in $names) {
                [void]$items.Add([pscustomobject]@{
                        Record = $record; Client = $client; Project = $label; Hook = $name
                        State = $state; Detail = [string]$entry.Detail; EventPlan = $null
                    })
            }
            continue
        }

        # The wizard repairs only the clients the integrity check names; a
        # changed source or native chain names none, which means all of them.
        $damaged = @(@($entry.Components) | Where-Object {
                $null -ne $_ -and [string]$_.Status -eq 'update' -and [string]$_.Name -ne 'source' -and [string]$_.Name -ne 'nativeGit'
            } | ForEach-Object { [string]$_.Name })
        foreach ($client in $clients) {
            $state = 'current'
            $detail = ''
            if ([string]$entry.Status -eq 'update' -and ($damaged.Count -eq 0 -or $damaged -contains $client)) {
                $state = 'stale'
                $detail = [string]$entry.Detail
            }
            else {
                $subrecord = Get-ClientSubrecord -Record $record -Client $client
                $runtimeDir = ''
                if ($null -ne $subrecord -and $null -ne $subrecord.PSObject.Properties['runtimeScript'] -and
                    -not [string]::IsNullOrWhiteSpace([string]$subrecord.runtimeScript)) {
                    $runtimeDir = Split-Path -Parent ([string]$subrecord.runtimeScript)
                }
                $missing = Get-MissingFleetMarker -RuntimeDir $runtimeDir -Markers $Markers
                if ($missing -ne '') { $state = 'stale'; $detail = 'marker missing: ' + $missing }
            }
            $eventPlan = Resolve-UpdateEventsForClient -Record $record -Client $client
            # A binding with a pending migration is stale whatever its files say.
            if ($state -eq 'current' -and [string]$eventPlan.Note -match 'migration v\d') {
                $state = 'pending-migration'
                $detail = [string]$eventPlan.Note
            }
            [void]$items.Add([pscustomobject]@{
                    Record = $record; Client = $client; Project = $label; Hook = $name
                    State = $state; Detail = $detail; EventPlan = $eventPlan
                })
        }
    }
    return $items.ToArray()
}
