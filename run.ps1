# Hook Maker launcher.
# Runs the wizard in the CURRENT terminal window using the best available
# PowerShell (PowerShell 7 first, then Windows PowerShell).
#
# It deliberately does NOT spawn a new window. On Windows 11 the terminal that
# hosts a double-clicked script is chosen by the OS "Default terminal
# application" setting - set that to Windows Terminal once (Settings > Privacy &
# security > For developers, or Windows Terminal > Settings) and double-clicking
# opens here in Windows Terminal automatically. Relaunching into wt.exe from here
# would only ever produce a second window, which is exactly what we avoid.

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

$forwarded = @()
if ($ScriptArgs) {
    $forwarded = @($ScriptArgs)
}

# If we are already running under PowerShell 7 (the launcher itself was started
# with pwsh), just dot-source-run the wizard in-process - no child, no window.
if ($PSVersionTable.PSVersion.Major -ge 6) {
    & $wizardPath @forwarded
    exit $LASTEXITCODE
}

# Otherwise we are under Windows PowerShell 5.x (the .ps1 double-click host).
# Prefer to hand off to pwsh in the SAME window; fall back to running here.
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wizardPath @forwarded
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    exit $exitCode
}

& $wizardPath @forwarded
exit $LASTEXITCODE
