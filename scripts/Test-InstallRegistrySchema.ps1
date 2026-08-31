# Offline test suite for REGISTRY INTEGRITY: schema validation, per-record
# isolation, corruption/availability handling, and the path-safety primitives
# the installer relies on.
#
# Split out of Test-InstallRegistry.ps1 (which covers install/update FLOWS) so
# each suite has one responsibility: this file exercises the registry and path
# layer directly, without depending on install-flow fixtures beyond a single
# real install used to prove batch isolation.
#
# This entry file owns the harness, shared helpers, the try/finally cleanup and
# the summary. The scenario blocks themselves live in four dot-sourced
# companion files (run in this script's scope, in this order - later blocks
# read fixtures defined by earlier ones; none is a standalone suite):
#   _testregistryschemaavailability.ps1 - zero-byte/orphan-lock availability,
#                                         path containment and staging escapes
#   _testregistryschemamanaged.ps1      - managed record field validation,
#                                         nativeGit shape, batch isolation
#   _testregistryschemamigration.ps1    - genuine-record proof, v2 -> v3
#                                         registry migration
#   _testregistryschemadiscovered.ps1   - discovered record validation, ids,
#                                         secret safety, merge rules
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstallRegistrySchema.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($InstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
. $HookLib
# _installplan.ps1 first: _installlib.ps1's manifest builders delegate to the
# canonical plan defined there.
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-regschema'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

# Keeps every install and registry write inside this workspace, away from the
# real checkout's own state\install-registry.json.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

try {
    # Scenario blocks live in dot-sourced companion files. They run in THIS
    # script's scope (shared harness, helpers, workspace, $script: counters),
    # and later files read fixtures defined by earlier ones - execution ORDER
    # is load-bearing. The finally below still owns all cleanup. None of them
    # is a standalone suite.
    . (Join-Path $ScriptRoot '_testregistryschemaavailability.ps1')
    . (Join-Path $ScriptRoot '_testregistryschemamanaged.ps1')
    . (Join-Path $ScriptRoot '_testregistryschemamigration.ps1')
    . (Join-Path $ScriptRoot '_testregistryschemadiscovered.ps1')
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
