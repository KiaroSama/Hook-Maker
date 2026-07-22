# Offline test suite for the install registry (state\install-registry.json)
# and the "Update previously installed hooks" wizard menu action. Covers:
# a successful install creates/updates one record (never duplicated); Claude-
# only/Codex-only/Both, project/global scope, and CustomHook/Engine hook types
# are represented correctly; the updater refreshes a changed source byte-for-
# byte while preserving events/client/target/scope/profile; it never installs
# a hook that was never installed; missing source/target are reported and
# skipped without destructive changes; a second run is idempotent; the
# registry is atomic and tolerates malformed state; it never stores secret/
# .env/prompt content; unrelated JSON keys/handlers are preserved; the native
# pre-push chain's managed companion is refreshed while a preserved previous
# hook stays intact. Uses a throwaway custom-hook fixture under the real
# hooks\ folder (created and removed per test) instead of ever mutating a real
# shipped hook's source content. Fixture names avoid any lower-to-upper-case
# letter transition so Get-HookFriendlyName never rewrites them (it hyphenates
# PascalCase segments - e.g. "RegTest" would become "Reg-Test").
#
# This entry file owns the harness, shared fixtures/helpers, the try/finally
# cleanup and the summary. The scenario blocks themselves live in four
# dot-sourced companion files (run in this script's scope, in this order;
# none is a standalone suite):
#   _testinstallregistrycore.ps1        - record lifecycle, scopes/types,
#                                         engine records, updater decisions
#   _testinstallregistrysafety.ps1      - source boundaries, input validation,
#                                         transactional staging, manifests
#   _testinstallregistrydrift.ps1       - per-client semantics, migration,
#                                         corruption/locking, drift and repair
#   _testinstallregistryregressions.ps1 - D1-D4 defect regressions, per-hook
#                                         timeouts, handler preservation
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstallRegistry.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$Setup = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($InstallScript, $Setup, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Read-InstallRegistry/Save-InstallRegistry/Set-InstallRecord/Get-InstallRecordId,
# the manifest builders and Get-InstallIntegrity are called directly in this
# suite (not only via the wizard/installer). _installlib.ps1 needs _hooklib.ps1
# dot-sourced first (Get-ShortHash, Read-JsonFile, Write-JsonFileAtomic).
. $HookLib
# _installplan.ps1 first: _installlib.ps1's manifest builders delegate to the
# canonical plan defined there.
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-registrytest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Get-HandlerFieldValue { param($Handler, [string]$Field) if ($null -ne $Handler.PSObject.Properties[$Field]) { return [string]$Handler.$Field } return '' }
function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# Isolates every in-process & $InstallScript call and every spawned wizard
# process (via Invoke-Wizard's -Environment) away from this real checkout's
# own state\install-registry.json. ALL test blocks below share this one
# registry file (like a real machine would accumulate installs over time) -
# every assertion that counts records MUST filter by friendlyName, never
# assume the registry is otherwise empty.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

function Get-Registry {
    return Read-InstallRegistry -ToolRoot $ToolRoot
}
function Get-RecordsFor {
    param([string]$FriendlyName)
    return @((Get-Registry).installs | Where-Object { [string]$_.friendlyName -eq $FriendlyName })
}

$SafeCwd = Join-Path $Work 'safe-cwd'
New-Item -ItemType Directory -Path $SafeCwd -Force | Out-Null

function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config, [hashtable]$ExtraEnv = @{})
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "in-$token.txt"; $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $Setup + '" -ConfigPath "' + $Config + '"'
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        # The updater's legacy scan inspects (Get-Location)'s .claude/.codex as
        # one scope - WorkingDirectory MUST be an isolated dir with none of its
        # own, never this real checkout's own directory (which has real
        # dogfooded installs the test must never touch).
        FilePath = $hostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        WorkingDirectory = $SafeCwd
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $env = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
        foreach ($key in $ExtraEnv.Keys) { $env[$key] = $ExtraEnv[$key] }
        $startArgs.Environment = $env
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' | Set-Content -LiteralPath $Path -Encoding utf8
}

# Direct install/update via a NEW process (Install-Hook.ps1 or Setup-SyncGroup.ps1
# read $HOME/$env:USERPROFILE once at process start - an in-process & call
# cannot see a USERPROFILE override made after this session already started).
function Invoke-InstallProcess {
    param([string[]]$ScriptArgs, [string]$FakeHome = '')
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "instout-$token.txt"; $errF = Join-Path $Work "insterr-$token.txt"
    $quoted = $ScriptArgs | ForEach-Object { if ($_ -match '[\s]') { '"' + $_ + '"' } else { $_ } }
    $argLine = '-NoLogo -NoProfile -File "' + $InstallScript + '" ' + ($quoted -join ' ')
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $env = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
        if ($FakeHome -ne '') { $env['USERPROFILE'] = $FakeHome; $env['HOME'] = $FakeHome }
        $startArgs.Environment = $env
    }
    $p = Start-Process @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err }
}

# A throwaway custom hook under the REAL hooks\ folder (mirrors Test-Wizard.ps1's
# "synthetic hook" pattern) - swappable/deletable source content without ever
# mutating a real shipped hook. Caller MUST remove it in a finally block.
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

try {
    # Scenario blocks live in dot-sourced companion files. They run in THIS
    # script's scope (shared harness, helpers, fixtures, $script: counters,
    # one shared registry) - execution ORDER is load-bearing, and the finally
    # below still owns all cleanup. None of them is a standalone suite.
    . (Join-Path $ScriptRoot '_testinstallregistrycore.ps1')
    . (Join-Path $ScriptRoot '_testinstallregistrysafety.ps1')
    . (Join-Path $ScriptRoot '_testinstallregistrydrift.ps1')
    . (Join-Path $ScriptRoot '_testinstallregistryregressions.ps1')
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
    # Safety net: remove any ZZZ-Regtest-* fixture folders left behind by a
    # failed/interrupted run so the real hooks\ tree never stays polluted.
    foreach ($leftover in @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -Filter 'ZZZ-Regtest-*' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $leftover.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
