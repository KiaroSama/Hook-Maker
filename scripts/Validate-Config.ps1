param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'sync-hooks.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Shared structural rules (Test-SyncConfigStructure): single source of truth
# also used by Install-Hook.ps1 to validate a direct engine install's config
# BEFORE any mutation. _installlib.ps1 requires hooks\_hooklib.ps1 dot-sourced
# first (its own documented load-order contract).
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installlib.ps1')

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$result = Test-SyncConfigStructure -Config $config
if (-not $result.Ok) {
    throw ($result.Reason.Substring(0, 1).ToUpperInvariant() + $result.Reason.Substring(1) + '.')
}

Write-Host 'Configuration is valid.'
