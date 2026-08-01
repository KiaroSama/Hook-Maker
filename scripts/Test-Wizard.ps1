# Functional test for the interactive wizard (Setup-SyncGroup.ps1). The wizard
# has no unit surface, so it is driven end to end through stdin - this is the
# only layer that exercises the menu structure, prompt rendering, hook listing,
# the client (-ClaudeOnly/-CodexOnly) splat, and the real Install-Hook writes.
# Two bugs hid here before this suite existed: a dropped prompt param and an
# array-vs-hashtable splat that mis-bound -ClaudeOnly onto Install-Hook's first
# positional parameter. Everything runs against throwaway temp projects.
#
# The suite is split by scenario into dot-sourced helper blocks (they run in
# this script's scope; execution order is the file order below):
#   _testwizardharness.ps1   the stdin-driven wizard runner + settings readers
#   _testwizardmenu.ps1      menu structure, sync groups, real hook installs
#   _testwizardselectall.ps1 Select All + installer idempotency
#   _testwizardprompts.ps1   prompt robustness, numbering, malformed config
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-Wizard.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Setup = Join-Path $PSScriptRoot 'Setup-SyncGroup.ps1'
if (-not (Test-Path -LiteralPath $Setup -PathType Leaf)) {
    Write-Host "Wizard not found: $Setup" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Installed scripts are the source with their library dot-source rewritten to
# the private sibling copy, so expectations are derived from the canonical plan
# (Get-PrivateLibraryScriptContent / Get-PlanArtifactExpectedHash) rather than
# from raw source bytes.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\_hooklib.ps1')
. (Join-Path $PSScriptRoot '_installplan.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-wiztest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
# Isolates Install-Hook.ps1's install registry (state\install-registry.json,
# written whenever the wizard installs anything) away from this real
# checkout's own registry - shared for the whole file's Invoke-Wizard calls,
# same convention as an isolated LOCALAPPDATA elsewhere in this test suite.
$IsolatedStateDir = Join-Path $Work 'state'

. (Join-Path $PSScriptRoot '_testwizardharness.ps1')

try {
    # Menu structure, sync-group creation and merging, and real hook installs.
    . (Join-Path $PSScriptRoot '_testwizardmenu.ps1')

    # The Select All aggregate and the installer's idempotency guarantees.
    . (Join-Path $PSScriptRoot '_testwizardselectall.ps1')

    # Prompt robustness, hierarchical numbering, and malformed configuration.
    . (Join-Path $PSScriptRoot '_testwizardprompts.ps1')
}
finally {
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
