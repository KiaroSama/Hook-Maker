# Offline test suite for the Kiro CONTRACTS that span more than one module:
# the client/event capability table (scripts\_clientcapability.ps1), the
# registration writer (scripts\_installkiro.ps1) and the shared output adapter
# (hooks\_hooklib.ps1).
#
# Test-InstallKiro.ps1 already covers the writer's own unit behaviour (schema,
# rejections, path shapes, merge) and Test-ContextHooks.ps1 covers
# Write-HookResult through real child hook processes. This suite deliberately
# does NOT repeat either; it covers what neither reaches:
#
#   * EVERY logical event, exhaustively. For each one Kiro must either map it
#     to a documented physical trigger or NAME it unsupported - never a silent
#     drop, never a remap onto Stop. The capability table had no test at all.
#   * The SINGLE-trigger document, where `hooks` must still be a JSON array.
#     That is the exact case _installkiro's `return ,$value` comma wrapper
#     exists for, and the one a two-trigger fixture cannot reach.
#   * Write-HookResult for kiro across all twelve logical events in ONE pass,
#     so a downgrade that fakes a gate is caught on every event rather than on
#     the three spot-checked elsewhere.
#   * Entry-identity FORGERY: a name that merely contains the managed id, an id
#     not terminated by the anchor dash, another installation's marker, and an
#     entry with no identity fields at all (a StrictMode crash risk).
#   * A foreign entry surviving a real WRITE - Merge -> ConvertTo-KiroHookJson
#     -> disk -> re-parse. In-memory preservation is already proven; this is
#     the link a serializer -Depth regression would break, and the one that
#     would silently destroy a user's nested agent action.
#
# Everything runs in-process against isolated temp roots. USERPROFILE / HOME /
# CLAUDE_PROJECT_DIR / HOOKMAKER_CLIENT are redirected for the whole run and
# restored in the finally block, so no real user profile, real .kiro directory
# or real hooks tree is ever read or written.
#
# In-process is also what keeps the output assertions stable: pwsh 7 randomises
# plain-hashtable key order PER PROCESS, so comparing emitted JSON across a
# process boundary flakes. Every byte comparison here happens under one seed.
#
# This entry file owns the harness, shared fixtures/helpers, the try/finally
# environment restoration and the summary. The scenario blocks themselves
# live in three dot-sourced companion files (run in this script's scope, in
# this order; none is a standalone suite):
#   _testkirointegrationcontracts.ps1 - capability table, per-event mapping,
#                                       the event plan, Write-HookResult
#                                       gates/context shapes
#   _testkirointegrationownership.ps1 - client identity, derived paths,
#                                       ownership forgery, the foreign-entry
#                                       disk round trip
#   _testkirointegrationwiring.ps1    - Install-Hook.ps1 wiring: real
#                                       installs, refusals, rollback, the
#                                       all-clients pass
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-KiroIntegration.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$KiroModule = Join-Path $ScriptRoot '_installkiro.ps1'
$CapabilityModule = Join-Path $ScriptRoot '_clientcapability.ps1'
$HookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'
foreach ($required in @($KiroModule, $CapabilityModule, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
. $KiroModule    # dot-sources _clientcapability.ps1 itself
. $HookLib
# The wiring block reads the install registry back; that lives here, and the
# registry is a directory of per-record files rather than one document.
. (Join-Path $PSScriptRoot '_installlib.ps1')
. (Join-Path $PSScriptRoot '_installregistry.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-kirointeg'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Read-Utf8 { param([string]$Path) return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Compact { param($Value) return ($Value | ConvertTo-Json -Depth 20 -Compress) }
function Get-Rejection { param([scriptblock]$Action) try { & $Action; return '' } catch { return [string]$_.Exception.Message } }

# Runs Write-HookResult with stdout AND stderr captured inside THIS process.
# Both channels matter: kiro puts advisory/context text on stdout and a real
# block's reason on stderr, and "nothing was emitted anywhere" is itself an
# assertable outcome for a degraded Stop gate.
function Invoke-KiroResult {
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Client = 'kiro'
    )
    $outWriter = New-Object System.IO.StringWriter
    $errWriter = New-Object System.IO.StringWriter
    $previousOut = [Console]::Out
    $previousError = [Console]::Error
    $outcome = $null
    try {
        [Console]::SetOut($outWriter)
        [Console]::SetError($errWriter)
        $outcome = Write-HookResult -EventName $EventName -Kind $Kind -Message $Text -Reason $Text -Client $Client
    }
    finally {
        [Console]::SetOut($previousOut)
        [Console]::SetError($previousError)
    }
    return [pscustomobject]@{
        Out            = $outWriter.ToString().Trim()
        Err            = $errWriter.ToString().Trim()
        Emitted        = [bool]$outcome.Emitted
        Shape          = [string]$outcome.Shape
        ExitCode       = [int]$outcome.ExitCode
        Degraded       = [bool]$outcome.Degraded
        DegradedReason = [string]$outcome.DegradedReason
    }
}

$SavedUserProfile = $env:USERPROFILE
$SavedHome = $env:HOME
$SavedClaudeProjectDir = $env:CLAUDE_PROJECT_DIR
$SavedHookMakerClient = $env:HOOKMAKER_CLIENT

try {
    $managedId = 'a1b2c3d4e5'
    $otherId = 'f9f9f9f9'
    $command = 'pwsh -NoLogo -NoProfile -File "C:\Proj\.kiro\hook-runtime\Hook-Maker\X\X.ps1" -Trigger Stop'

    # A hook must never inherit an ambient client signal from the machine that
    # happens to be running the suite.
    if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }

    $capability = Get-HookMakerClientCapability -ClientId 'kiro'
    $logicalEvents = @(Get-HookMakerLogicalEvents)
    $supportedEvents = @($capability.supportedEvents)
    # The ten triggers .ai\KIRO_PROTOCOL.md marks CONFIRMED, exact casing. A
    # physical name outside this set is a name Kiro never documented.
    $protocolTriggers = @(
        'SessionStart', 'Stop', 'PreToolUse', 'PostToolUse', 'PreTaskExec', 'PostTaskExec',
        'UserPromptSubmit', 'PostFileCreate', 'PostFileSave', 'PostFileDelete'
    )

    # Scenario blocks live in dot-sourced companion files. They run in THIS
    # script's scope (shared harness, helpers, fixtures, $script: counters,
    # the redirected environment) - execution ORDER is load-bearing, and the
    # finally below still owns all cleanup. None of them is a standalone
    # suite.
    . (Join-Path $ScriptRoot '_testkirointegrationcontracts.ps1')
    . (Join-Path $ScriptRoot '_testkirointegrationownership.ps1')
    . (Join-Path $ScriptRoot '_testkirointegrationwiring.ps1')
}
finally {
    $env:USERPROFILE = $SavedUserProfile
    $env:HOME = $SavedHome
    if ([string]::IsNullOrEmpty($SavedClaudeProjectDir)) {
        if (Test-Path Env:\CLAUDE_PROJECT_DIR) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue }
    }
    else { $env:CLAUDE_PROJECT_DIR = $SavedClaudeProjectDir }
    if ([string]::IsNullOrEmpty($SavedHookMakerClient)) {
        if (Test-Path Env:\HOOKMAKER_CLIENT) { Remove-Item Env:\HOOKMAKER_CLIENT -ErrorAction SilentlyContinue }
    }
    else { $env:HOOKMAKER_CLIENT = $SavedHookMakerClient }
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
