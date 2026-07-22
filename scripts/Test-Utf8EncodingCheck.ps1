# Offline test suite for Utf8-Encoding-Check - the strict-UTF-8 detector +
# gate (SessionStart baseline advisory, Stop/SubagentStop changed-file gate,
# native -GitPrePush outgoing-blob mode). New hook, no prior coverage.
#
# The suite is split by scenario into dot-sourced helper blocks (they run in
# this script's scope; execution order is the file order below):
#   _testutf8harness.ps1  shared fixture builders + process runners
#   _testutf8classify.ps1 byte classification + exception-registry validation
#   _testutf8events.ps1   SessionStart baseline + the Stop gate
#   _testutf8prepush.ps1  the native pre-push mode (real repos + bare remotes)
#
# Red-before-green note: the hook is brand-new, so "red" is proven by (a) a
# NEGATIVE CONTROL for each core block - the identical scenario with valid
# bytes passes, so the block depends on the invalid bytes - and (b) a STUB
# control - one Stop scenario and one pre-push scenario are run against an
# exit-0 stub hook and the suite asserts the stub does NOT satisfy the block
# expectations, proving the assertions are load-bearing.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-Utf8EncodingCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Utf8-Encoding-Check\Utf8-Encoding-Check.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$EnvExample = Join-Path $HooksRoot 'Utf8-Encoding-Check\.env.example'
foreach ($required in @($Hook, $HookLib, $EnvExample)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-utf8test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# GetTempPath() sits UNDER the real user profile on Windows, so a fixture here
# is nested inside $HOME. Nothing below may reach real ~\.claude / ~\.codex
# state: every child gets a FAKE LOCALAPPDATA, and the client-detection env
# var is cleared for this process so Start-Process -Environment (which MERGES,
# not replaces) cannot leak it into a child.
$SavedClaudeProjectDir = $env:CLAUDE_PROJECT_DIR
$env:CLAUDE_PROJECT_DIR = ''

. (Join-Path $PSScriptRoot '_testutf8harness.ps1')

try {
    # Byte classification + exception-registry validation.
    . (Join-Path $PSScriptRoot '_testutf8classify.ps1')

    # SessionStart baseline + the Stop/SubagentStop gate.
    . (Join-Path $PSScriptRoot '_testutf8events.ps1')

    # The native pre-push mode against real repos + bare remotes.
    . (Join-Path $PSScriptRoot '_testutf8prepush.ps1')
}
finally {
    $env:CLAUDE_PROJECT_DIR = $SavedClaudeProjectDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
