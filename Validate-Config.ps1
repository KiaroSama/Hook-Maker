param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'sync-hooks.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $config.profiles) {
    throw 'The config must contain a profiles array.'
}

$profileIds = @{}
foreach ($profile in @($config.profiles)) {
    $profileId = [string]$profile.id
    if ([string]::IsNullOrWhiteSpace($profileId)) {
        throw 'Every profile requires a non-empty id.'
    }
    if ($profileIds.ContainsKey($profileId)) {
        throw "Duplicate profile id: $profileId"
    }
    $profileIds[$profileId] = $true

    $routeIds = @{}
    foreach ($route in @($profile.routes)) {
        $routeId = [string]$route.id
        if ([string]::IsNullOrWhiteSpace($routeId)) {
            throw "Every route in profile '$profileId' requires a non-empty id."
        }
        if ($routeIds.ContainsKey($routeId)) {
            throw "Duplicate route id '$routeId' in profile '$profileId'."
        }
        $routeIds[$routeId] = $true

        foreach ($side in @('source', 'destination')) {
            $endpoint = $route.$side
            if ($null -eq $endpoint -or [string]::IsNullOrWhiteSpace([string]$endpoint.root)) {
                throw "Route '$routeId' in profile '$profileId' requires $side.root."
            }
        }
    }
}

Write-Host 'Configuration is valid.'
