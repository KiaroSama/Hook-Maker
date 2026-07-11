# Launcher for the cross-project sync wizard.
# Host priority: Windows Terminal > PowerShell 7 (pwsh) > Windows PowerShell.
# - Double-clicked (not already inside Windows Terminal): opens the wizard in a
#   new Windows Terminal window when wt.exe is available.
# - Already inside Windows Terminal (WT_SESSION set) or wt.exe missing: runs the
#   wizard in the current console with the best available PowerShell.
# - Resolves paths relative to its own location; propagates the wizard exit code
#   when running in place.

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

# Best available PowerShell: 7 (pwsh) first, then Windows PowerShell.
$shell = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $shell = 'pwsh'
}
elseif (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
    $shell = 'powershell.exe'
}

if (-not $shell) {
    Write-Host 'Neither pwsh nor powershell.exe was found in PATH.' -ForegroundColor Red
    exit 9009
}

$forwarded = @()
if ($ScriptArgs) {
    $forwarded = @($ScriptArgs)
}
$shellArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wizardPath) + $forwarded

# Prefer a Windows Terminal window unless we are already inside one.
$insideWindowsTerminal = -not [string]::IsNullOrEmpty($env:WT_SESSION)
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if (-not $insideWindowsTerminal -and $wt) {
    try {
        $quoted = foreach ($arg in $shellArgs) {
            if ($arg -match '\s') { '"' + $arg + '"' } else { $arg }
        }
        Start-Process -FilePath $wt.Source -ArgumentList (@($shell) + $quoted)
        exit 0
    }
    catch {
        Write-Host "Windows Terminal could not be started ($($_.Exception.Message)); continuing in the current console." -ForegroundColor Yellow
    }
}

& $shell @shellArgs
$exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
exit $exitCode
