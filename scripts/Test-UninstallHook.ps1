# Offline test suite for Uninstall-Hook.ps1: the noninteractive, record-based
# uninstaller. Covers scope isolation (removing one record never touches a
# sibling record's settings/runtime/source), ownership proof (a foreign
# same-basename handler survives), runtime path containment refusal,
# idempotency (missing runtime / already-removed registration / repeated
# uninstall of a gone id), a true no-op dry run (byte-for-byte unchanged),
# the native Git pre-push chain (regenerate around a remaining foreign stage,
# restore the preserved user hook byte-for-byte on full removal, refuse a
# tampered wrapper with a manual-repair status, never touch an unrelated
# repo's hook), the ownership pre-flight (a wrapper file present but missing
# the Hook Maker marker is manualRepair - ownership unknown - never a silent
# "not managed anymore" success; a missing wrapper is only idempotent success
# once proven no owned native runtime remains, otherwise it is retained as
# manualRepair), and failure injection on the Claude settings write, the Codex
# settings write, and the final registry-removal persistence (no false
# success, no silent registry deletion, retained record reflects reality),
# plus the Kiro 'perHookFile' client: entry-level removal that preserves a
# hand-added hook, a foreign hookmaker-*.json left byte-identical, an entry
# that appeared since install refusing the whole component, and a
# registrationPath outside the record's own scope refused outright.
#
# Mirrors Test-InstallRegistry.ps1's conventions: throwaway ZZZ-* fixtures
# under the real hooks\ folder (removed in a finally), $env:HOOKMAKER_STATE_DIR
# isolation so the real registry is never touched, and a spawned process per
# invocation of the script under test (each reads $HOME/env once at start).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-UninstallHook.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$UninstallScript = Join-Path $ScriptRoot 'Uninstall-Hook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($InstallScript, $UninstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# _installplan.ps1 first: _installlib.ps1's manifest builders and native-git
# helpers delegate to it. _installlib.ps1 needs _hooklib.ps1 dot-sourced first
# (Get-ShortHash, Read-JsonFile, Write-JsonFileAtomic, Set-ObjectProperty).
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-uninstalltest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

# HOOKMAKER_STATE_DIR only redirects the INSTALL REGISTRY. Hook coordination
# state (Test-Temp-Cleanup's per-project record) lives under %LOCALAPPDATA%
# with no override, so the hook runtimes fired below and the uninstaller under
# test would otherwise read and DELETE from the real machine profile. Handed
# over by INHERITANCE, not Start-Process -Environment: that parameter does not
# exist on Windows PowerShell 5.1, so an -Environment-only harness silently
# lets the child use the real %LOCALAPPDATA% on that host - one code path for
# both hosts, restored in the finally.
$SavedLocalAppData = $env:LOCALAPPDATA
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null
$env:LOCALAPPDATA = $FakeLocalAppData

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function Get-HandlerFieldValue { param($Handler, [string]$Field) if ($null -ne $Handler.PSObject.Properties[$Field]) { return [string]$Handler.$Field } return '' }
function Get-BytesOrEmpty { param([string]$Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { return [System.IO.File]::ReadAllBytes($Path) } return [byte[]]@() }
function Test-BytesEqual { param([byte[]]$A, [byte[]]$B) return [System.Linq.Enumerable]::SequenceEqual([byte[]]$A, [byte[]]$B) }

function New-FixtureHook {
    param([string]$Name, [string]$Body = "exit 0`n")
    $dir = Join-Path $RealHooksDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Utf8 (Join-Path $dir ($Name + '.ps1')) $Body
    return (Join-Path $dir ($Name + '.ps1'))
}
function Remove-FixtureHook {
    param([string]$Name)
    $dir = Join-Path $RealHooksDir $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-Registry { return Read-InstallRegistry -ToolRoot $ToolRoot }
function Get-RecordsFor {
    param([string]$FriendlyName)
    return @((Get-Registry).installs | Where-Object { [string]$_.friendlyName -eq $FriendlyName })
}
function Get-RecordForScope {
    param([string]$FriendlyName, [string]$TargetProjectRoot)
    return @(Get-RecordsFor $FriendlyName | Where-Object { [string]$_.targetProjectRoot -eq $TargetProjectRoot })[0]
}
# Direct in-process registry mutation for test setup only (corrupting a field,
# injecting a synthetic native-git stage). The real script under test always
# goes through Invoke-WithInstallRegistryLock; this bypasses that deliberately
# because it is simulating a pre-existing on-disk state, not a live write race.
function Save-MutatedRecord {
    param([Parameter(Mandatory = $true)]$Record)
    $reg = Get-Registry
    $list = @($reg.installs)
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ([string]$list[$i].id -eq [string]$Record.id) { $list[$i] = $Record; break }
    }
    $reg.installs = $list
    Save-InstallRegistry -ToolRoot $ToolRoot -Registry $reg
}

# Spawns Uninstall-Hook.ps1 as a real process (matches Install-Hook.ps1's own
# $HOME-at-start-only caveat) and returns exit code, stdout/stderr, and the
# parsed -ResultPath document.
function Invoke-UninstallProcess {
    # -ScriptPath runs a DIFFERENT copy of the uninstaller (a `git show HEAD:`
    # export staged beside copies of its sibling _*.ps1 modules) so a historical
    # red-proof can execute the pre-change executor for real, without ever
    # reverting the shared working tree.
    param([string]$RecordId, [switch]$WhatIf, [string]$UninstallToolRoot = $ToolRoot, [string]$FakeHome = '',
        [string]$ScriptPath = '', [switch]$ForgetUnreadableRecord)
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = $UninstallScript }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "uninstout-$token.txt"; $errF = Join-Path $Work "uninsterr-$token.txt"
    $resultFile = Join-Path $Work "uninstresult-$token.json"
    $argLine = '-NoLogo -NoProfile -File "' + $ScriptPath + '" -RecordId "' + $RecordId + '" -ToolRoot "' + $UninstallToolRoot + '" -ResultPath "' + $resultFile + '"'
    if ($WhatIf) { $argLine += ' -WhatIf' }
    if ($ForgetUnreadableRecord) { $argLine += ' -ForgetUnreadableRecord' }
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    # See the same guard in Test-InstallRegistry.ps1: on a 5.1 host this block is
    # skipped, taking the USERPROFILE/HOME redirect with it, and a global-scope
    # test would then operate on the developer's real profile.
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $env = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
        if ($FakeHome -ne '') { $env['USERPROFILE'] = $FakeHome; $env['HOME'] = $FakeHome }
        $startArgs.Environment = $env
    }
    elseif ($FakeHome -ne '') {
        throw ('Refusing to run a global-scope test without process isolation: ' +
            'Start-Process -Environment is unavailable on this host (Windows PowerShell 5.1), ' +
            'so USERPROFILE cannot be redirected and the test would operate on the real user profile. ' +
            'Run this suite under pwsh 7.')
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    $doc = $null
    if (Test-Path -LiteralPath $resultFile) { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err; Result = $doc }
}
function Get-ComponentStatus {
    param($ResultDoc, [string]$Component)
    $found = @($ResultDoc.components | Where-Object { [string]$_.component -eq $Component })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].status
}
function Get-ComponentReason {
    param($ResultDoc, [string]$Component)
    $found = @($ResultDoc.components | Where-Object { [string]$_.component -eq $Component })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].reason
}
# An internally inconsistent record can legitimately be refused at EITHER layer:
# the record-wide validator (Test-InstallRecordValid, shared with menu 21) or the
# uninstaller's own per-client identity gate. Which one fires first is an
# implementation detail and has changed as the two gates were brought to parity -
# what must hold is that SOME component names a precise reason. Asserting on the
# outcome instead of on one component keeps these tests pinned to the guarantee
# rather than to the layer that currently happens to enforce it.
function Get-AnyRefusalReason {
    param($ResultDoc)
    $found = @($ResultDoc.components | Where-Object {
            @('manualRepair', 'failed') -contains [string]$_.status -and -not [string]::IsNullOrWhiteSpace([string]$_.reason)
        })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].reason
}

# Spawns Install-Hook.ps1 as a real process. Only needed for a GLOBAL-scope
# install: Install-Hook.ps1 reads $HOME once at process start, so a fake
# global home must be injected via a fresh process's environment - an
# in-process `&` call would still see THIS session's real $HOME and could
# write into the real user's Claude/Codex settings.
function Invoke-InstallProcess {
    param([string[]]$ScriptArgs, [string]$FakeHome = '')
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "instout-$token.txt"; $errF = Join-Path $Work "insterr-$token.txt"
    $quoted = $ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $argLine = '-NoLogo -NoProfile -File "' + $InstallScript + '" ' + ($quoted -join ' ')
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    # See the same guard in Test-InstallRegistry.ps1: on a 5.1 host this block is
    # skipped, taking the USERPROFILE/HOME redirect with it, and a global-scope
    # test would then operate on the developer's real profile.
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $env = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
        if ($FakeHome -ne '') { $env['USERPROFILE'] = $FakeHome; $env['HOME'] = $FakeHome }
        $startArgs.Environment = $env
    }
    elseif ($FakeHome -ne '') {
        throw ('Refusing to run a global-scope test without process isolation: ' +
            'Start-Process -Environment is unavailable on this host (Windows PowerShell 5.1), ' +
            'so USERPROFILE cannot be redirected and the test would operate on the real user profile. ' +
            'Run this suite under pwsh 7.')
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err }
}

# Fires an INSTALLED Test-Temp-Cleanup runtime copy on Stop so the HOOK ITSELF
# writes its coordination record. That is the whole point: a test that hand-built
# the record path from its own idea of the project key would pass while
# production missed the file, because the key is a hash of a path SPELLING. The
# record only ever appears here if the producer and the code under test agree
# byte-for-byte on the path. The Stop path writes the record unconditionally
# (its only earlier exit is stop_hook_active, which is not set here).
function Invoke-CleanupHookStop {
    param([string]$RuntimeScript, [string]$Cwd)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "cleanin-$token.json"
    Write-Utf8 $inF (@{ session_id = 'ttc'; cwd = $Cwd; hook_event_name = 'Stop' } | ConvertTo-Json)
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList ('-NoLogo -NoProfile -File "' + $RuntimeScript + '"') `
        -RedirectStandardInput $inF `
        -RedirectStandardOutput (Join-Path $Work "cleanout-$token.txt") `
        -RedirectStandardError (Join-Path $Work "cleanerr-$token.txt") `
        -Wait -NoNewWindow -PassThru
    return $p.ExitCode
}
# Every TestTempCleanup-result-*.json currently in the isolated state directory.
# Counted rather than path-matched, so "project B's record survived" is proven
# by the file set itself and never by recomputing a key here.
function Get-CleanupRecordFiles {
    return @(Get-ChildItem -LiteralPath (Join-Path $FakeLocalAppData 'HookMaker\state') `
            -Filter 'TestTempCleanup-result-*.json' -File -Force -ErrorAction SilentlyContinue)
}

try {
    # Scenario blocks, split by responsibility and dot-sourced in execution
    # order into THIS scope, so Check, $script:Pass/$script:Fail, the shared
    # fixtures and every helper above resolve in the caller. Order matters:
    # the native block defines $ignoreHook, which the ownership block reuses.
    # The finally below stays HERE so cleanup always runs whichever block
    # fails.
    . (Join-Path $ScriptRoot '_testuninstallhookscope.ps1')
    . (Join-Path $ScriptRoot '_testuninstallhooknative.ps1')
    . (Join-Path $ScriptRoot '_testuninstallhookownership.ps1')
    # Kiro last: it builds its own records rather than reusing the fixtures the
    # blocks above share, so it depends on none of them.
    . (Join-Path $ScriptRoot '_testuninstallhookkiro.ps1')
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    $env:LOCALAPPDATA = $SavedLocalAppData
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
