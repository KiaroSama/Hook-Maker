# Read back the materialized runtime and registration before emitting client=ok.
# Expectations come from the install plan and requested commands, never from
# hashes of the newly installed files used as their own baseline.
# Called while the corresponding settings resource lock remains held.
function Assert-InstalledClientReadback {
    param(
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex')][string]$Client,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)]$Commands,
        [Parameter(Mandatory = $true)][string[]]$Events,
        [Parameter(Mandatory = $true)][int]$Timeout,
        [string]$StatusMessage = '', [string]$ProfileId = ''
    )
    $directory = Split-Path -Parent ([string]$Runtime.Script)
    $name = Split-Path -Leaf $directory
    $expected = @(Get-PlanManifest -Plan $Runtime.Plan)
    if ($expected.Count -eq 0) { throw 'Client verification failed: empty planned runtime manifest.' }
    $actual = @(Get-InstalledManifest -RuntimeRoot (Split-Path -Parent $directory) -FriendlyName $name)
    $difference = Compare-Manifest -Expected $expected -Actual $actual
    if (-not $difference.IsMatch) { throw ('Client verification failed: ' + $Client + ' runtime does not match the install plan.') }
    $parameters = @{
        SettingsPath = $SettingsPath; RuntimeScript = [string]$Runtime.Script
        ExpectedEvents = $Events; ProfileId = $ProfileId; ExpectedTimeout = $Timeout
        ExpectedHandlerType = 'command'; ExpectedCommand = [string]$Commands.Windows
    }
    if ($Client -eq 'codex') {
        $parameters.ExpectedCommand = [string]$Commands.Portable
        $parameters.ExpectedCommandWindows = [string]$Commands.Windows
        $parameters.ExpectedStatusMessage = $StatusMessage
        $parameters.ExpectedStatusMessageKnown = $true
    }
    $registration = Test-ClientRegistrationState @parameters
    if (-not $registration.Ok) { throw ('Client verification failed: ' + $Client + ' ' + $registration.Reason + '. ' + $registration.Detail) }
}
