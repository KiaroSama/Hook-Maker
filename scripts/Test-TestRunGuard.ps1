# Offline test suite for Test-Run-Guard - new hook, no prior coverage.
#
# The centre of gravity is the FALSE-POSITIVE GUARD: a gate that blocks a
# command it merely suspects is worse than no gate at all, so most of the
# assertions here prove total silence on ordinary work (git, builds, file
# copies, paths that merely contain the word "test").
#
# Also covered: a recognised raw command is denied and the returned replacement
# is a VALID guarded invocation using -ArgumentsJson (asserted by actually
# running the real runner with it); an already-guarded command is never
# double-wrapped; spaces and shell metacharacters survive into the replacement
# without being evaluated; the hook starts no process at all;
# TEST_GUARD_ADVISORY_ONLY=1 advises instead of blocking; PostToolUse names the
# terminate reason and last progress, stays silent on a clean result, and never
# claims success on a missing/stale one; invalid .env values fall back once;
# both Claude and Codex shapes emit exactly one parseable JSON document.
#
# The suite is split by scenario into dot-sourced helper blocks (they run in
# this script's scope; execution order is the file order below):
#   _testrunguardharness.ps1      shared fixture builders + the process runner
#   _testrunguardrecognition.ps1  PreToolUse recognition + the replacement
#   _testrunguardposttool.ps1     PostToolUse reporting + runner discovery
#   _testrunguardcoordination.ps1 the observed-record handoff + run identity
#   _testrunguardrunner.ps1       the real guarded runner, end to end
#   _testrunguardpolicy.ps1       deny-text guidance, static safety, 5.1
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestRunGuard.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HooksRoot = Join-Path $RepoRoot 'hooks'
$Hook = Join-Path $HooksRoot 'Test-Run-Guard\Test-Run-Guard.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$Runner = Join-Path $RepoRoot 'scripts\Run-Tests-Guarded.ps1'
foreach ($required in @($Hook, $HookLib, $Runner)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-runguardtest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

. (Join-Path $PSScriptRoot '_testrunguardharness.ps1')

$Proj = Join-Path $Work 'Project'
New-Item -ItemType Directory -Path $Proj -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Proj 'scripts') -Force | Out-Null
Copy-Item $Runner (Join-Path $Proj 'scripts\Run-Tests-Guarded.ps1')

try {
    # PreToolUse recognition, the false-positive guard, and the replacement.
    . (Join-Path $PSScriptRoot '_testrunguardrecognition.ps1')

    # PostToolUse reporting, the client shapes, and runner discovery.
    . (Join-Path $PSScriptRoot '_testrunguardposttool.ps1')

    # The observed-record handoff and the run-identity contract.
    . (Join-Path $PSScriptRoot '_testrunguardcoordination.ps1')

    # The real Run-Tests-Guarded.ps1 runner, driven end to end.
    . (Join-Path $PSScriptRoot '_testrunguardrunner.ps1')

    # Deny-text guidance, static safety, and the Windows PowerShell 5.1 host.
    . (Join-Path $PSScriptRoot '_testrunguardpolicy.ps1')
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
