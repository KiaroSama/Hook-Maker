# Route resolution and serialization shared by events and acknowledgement.
function Enter-RouteStateLock {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    $key = Get-StringHash -Text (Normalize-Path $StatePath).ToUpperInvariant()
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new($false, ('Global\HookMakerSync-' + $key))
        try { $acquired = $mutex.WaitOne(5000) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'The sync route is busy. Retry after its current operation finishes.' }
        return $mutex
    }
    catch {
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw ('Could not acquire the sync route lock: ' + $_.Exception.Message)
    }
}

function Get-MatchingRoutes {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$EventName,
        [string]$ProfileFilter,
        [string]$RouteFilter
    )
    $workingPath = Normalize-Path $WorkingDirectory
    $defaults = if ($null -ne $Config.PSObject.Properties['defaults']) { $Config.defaults } else { [pscustomobject]@{} }
    $routeMatches = New-Object System.Collections.Generic.List[object]
    foreach ($profileConfig in @($Config.profiles)) {
        $profileId = [string]$profileConfig.id
        if ([string]::IsNullOrWhiteSpace($profileId)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($ProfileFilter) -and -not [string]::Equals($profileId, $ProfileFilter, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($null -ne $profileConfig.PSObject.Properties['enabled'] -and -not [bool]$profileConfig.enabled) { continue }
        foreach ($routeConfig in @($profileConfig.routes)) {
            $routeId = [string]$routeConfig.id
            if ([string]::IsNullOrWhiteSpace($routeId)) { continue }
            if (-not [string]::IsNullOrWhiteSpace($RouteFilter) -and -not [string]::Equals($routeId, $RouteFilter, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($null -ne $routeConfig.PSObject.Properties['enabled'] -and -not [bool]$routeConfig.enabled) { continue }
            if (-not [string]::IsNullOrWhiteSpace($EventName)) {
                $allowedEvents = @(Get-PropertyValue -Primary $routeConfig -Secondary $profileConfig -Tertiary $defaults -Name 'events' -Fallback @('SessionStart', 'UserPromptSubmit'))
                if (-not ($allowedEvents -contains $EventName)) { continue }
            }
            if ($null -eq $routeConfig.source -or $null -eq $routeConfig.destination) { continue }
            $destinationRoots = Get-EndpointRoots -Endpoint $routeConfig.destination
            $matchedDestinationRoot = $null
            foreach ($candidateRoot in $destinationRoots) {
                if (Test-PathInside -Candidate $workingPath -Parent $candidateRoot) {
                    $matchedDestinationRoot = $candidateRoot
                    break
                }
            }
            if ($null -eq $matchedDestinationRoot) { continue }
            $sourceRoot = Normalize-Path ([string]$routeConfig.source.root)
            $destinationRoot = Normalize-Path ([string]$routeConfig.destination.root)
            $sourceDirectoryName = if ($null -ne $routeConfig.source.PSObject.Properties['directory']) { [string]$routeConfig.source.directory } else { '.ai' }
            $destinationDirectoryName = if ($null -ne $routeConfig.destination.PSObject.Properties['directory']) { [string]$routeConfig.destination.directory } else { '.ai' }
            [void]$routeMatches.Add([pscustomobject][ordered]@{
                profile = $profileConfig
                route = $routeConfig
                defaults = $defaults
                profileId = $profileId
                routeId = $routeId
                sourceRoot = $sourceRoot
                destinationRoot = $destinationRoot
                matchedDestinationRoot = $matchedDestinationRoot
                sourceDirectory = Join-Path $sourceRoot $sourceDirectoryName
                destinationDirectory = Join-Path $destinationRoot $destinationDirectoryName
            })
        }
    }
    return $routeMatches.ToArray()
}

function Test-SyncRouteCurrent {
    param($Context)
    # Called only while holding the route mutex, before any state read/write.
    # A waiter may have resolved a route before uninstall retired its config.
    $current = Read-JsonFile $ConfigPath
    if ($null -eq $current -or $null -eq $current.PSObject.Properties['profiles']) { return $false }
    $resolved = @(Get-MatchingRoutes -Config $current -WorkingDirectory $Context.matchedDestinationRoot -ProfileFilter $Context.profileId -RouteFilter $Context.routeId)
    if ($resolved.Count -ne 1) { return $false }
    return (($resolved[0].route | ConvertTo-Json -Depth 50 -Compress) -ceq ($Context.route | ConvertTo-Json -Depth 50 -Compress))
}
