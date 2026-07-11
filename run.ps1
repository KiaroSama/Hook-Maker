# Launcher for the cross-project sync wizard.
# - Resolves paths relative to its own location, so it works from any CWD.
# - Prefers PowerShell 7 (pwsh); falls back to Windows PowerShell.
# - Propagates the wizard's exit code.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    $ScriptArgs
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
}
else {
    $null
}

if (-not $scriptDir -or -not (Test-Path -LiteralPath $scriptDir)) {
    Write-Host 'run.ps1 could not determine its own directory. Run it as a file (not piped into PowerShell).' -ForegroundColor Red
    exit 1
}

$wizardPath = Join-Path $scriptDir 'scripts\Setup-SyncGroup.ps1'
if (-not (Test-Path -LiteralPath $wizardPath -PathType Leaf)) {
    Write-Host "The wizard script was not found. Expected at: $wizardPath" -ForegroundColor Red
    exit 1
}

$exe = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $exe = 'pwsh'
}
elseif (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
    $exe = 'powershell.exe'
}

if (-not $exe) {
    Write-Host 'Neither pwsh nor powershell.exe was found in PATH.' -ForegroundColor Red
    exit 9009
}

$forwarded = @()
if ($ScriptArgs) {
    $forwarded = @($ScriptArgs)
}

& $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wizardPath @forwarded
$exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
exit $exitCode
