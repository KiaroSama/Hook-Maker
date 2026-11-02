# Read-only confirmation rendering; selected IDs still use the existing executor.
function Show-UninstallConfirmation {
    param($Registry, [string[]]$RecordIds)
    Write-PhaseHeader 'Confirm Uninstall' $C.Confirm '-'
    foreach ($id in $RecordIds) {
        $matches = @($Registry.installs | Where-Object { (Get-RecordDisplayField $_ 'id' '') -eq $id })
        if ($matches.Count -ne 1) { throw 'Selected installation identity is ambiguous.' }
        $record = $matches[0]
        $recordType = Get-RecordType $record
        $hookType = Get-RecordDisplayField $record 'hookType' '(unknown type)'
        $profileId = Get-RecordDisplayField $record 'profile' ''
        $scopeText = if ((Get-RecordDisplayField $record 'scope') -eq 'global') { 'global' } else { Get-RecordDisplayField $record 'targetProjectRoot' '(unknown target)' }
        $label = Get-HookFriendlyName (Get-RecordDisplayField $record 'friendlyName' 'unknown-record')
        if (-not [string]::IsNullOrWhiteSpace($profileId)) { $label += ' [' + $profileId + ']' }
        Write-Host ('  ' + (Get-Painted $label $C.Bold) + $script:MenuSep + (Get-Painted $hookType $C.Aqua) + $script:MenuSep + (Get-Painted $scopeText $C.Gray))
        Write-Field '    record id' $id
        Write-Field '    record type' $recordType
        if ($recordType -eq 'discovered') {
            $capability = Get-DiscoveredRemovalCapability $record
            Write-Field '    removal' $capability.Capability $C.Amber
            $clientInfo = Get-DiscoveredClientEvents $record
            foreach ($client in @($clientInfo.Clients)) {
                $events = @($clientInfo.EventsByClient[$client])
                $eventsText = if ($events.Count -gt 0) { $events -join ', ' } else { '(none)' }
                Write-Field ('    ' + (Get-ClientDisplayName $client) + ' events') $eventsText
            }
            foreach ($evidence in @($record.clients)) {
                if ($null -eq $evidence -or $null -eq $evidence.PSObject.Properties['settingsPath']) { continue }
                Write-Field ('    ' + (Get-ClientDisplayName (Get-RecordDisplayField $evidence 'client' '')) + ' settings') ([string]$evidence.settingsPath)
            }
            $native = Get-Field $record 'nativeGit'
            if ($null -ne $native) {
                Write-Field '    native Git hook' (Get-RecordDisplayField $native 'hookPath' '(unknown path)') $C.Amber
                Write-Field '    native Git classification' (Get-RecordDisplayField $native 'classification' 'unknown')
            }
            else { Write-Field '    native Git' 'no' }
            continue
        }
        Write-Field '    source script' (Get-RecordDisplayField $record 'sourceScript' '(unknown source)')
        foreach ($client in @(Get-InstalledClientNames -Record $record)) {
            $subrecord = Get-ClientSubrecord -Record $record -Client $client
            $clientLabel = Get-ClientDisplayName $client
            $events = @($subrecord.events | ForEach-Object { [string]$_ })
            $eventsText = if ($events.Count -gt 0) { $events -join ', ' } else { '(none)' }
            Write-Field ('    ' + $clientLabel + ' events') $eventsText
            Write-Field ('    ' + $clientLabel + ' settings') ([string]$subrecord.settingsPath)
            Write-Field ('    ' + $clientLabel + ' runtime script') ([string]$subrecord.runtimeScript)
        }
        $native = Get-Field $record 'nativeGit'
        if ($null -ne $native -and (Get-Field $native 'managed') -eq $true) {
            Write-Field '    native Git' 'yes - the managed pre-push chain is part of this install' $C.Amber
        }
        else { Write-Field '    native Git' 'no' }
    }
    Write-Host ''
    Write-Field 'installations to remove' ([string]$RecordIds.Count)
    Write-NoteLine '  Hook SOURCE files under hooks\ are never deleted.'
    Write-NoteLine '  Canonical project hooks: complete owned-state removal; sync engines also retire selected membership.'
    Write-NoteLine '  Shared owners, applied knowledge and original audit/recovery evidence are preserved.'
}
