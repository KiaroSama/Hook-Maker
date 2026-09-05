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
#   _testinstallregistrykiro.ps1        - the perHookFile client: enumeration,
#                                         registration drift, update wiring
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
. (Join-Path $ScriptRoot '_installevaluate.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-registrytest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Get-HandlerFieldValue { param($Handler, [string]$Field) if ($null -ne $Handler.PSObject.Properties[$Field]) { return [string]$Handler.$Field } return '' }
function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

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
    # -Environment is pwsh-7 only. On Windows PowerShell 5.1 this block is simply
    # skipped - and skipping it does not just lose HOOKMAKER_STATE_DIR, it loses
    # the USERPROFILE/HOME redirect too, so a GLOBAL-scope install would write
    # into the developer's REAL %USERPROFILE%\.claude. Refuse instead: a test
    # that cannot isolate itself must not run at all.
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $env = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
        if ($FakeHome -ne '') { $env['USERPROFILE'] = $FakeHome; $env['HOME'] = $FakeHome }
        $startArgs.Environment = $env
    }
    elseif ($FakeHome -ne '') {
        throw ('Refusing to run a global-scope install test without process isolation: ' +
            'Start-Process -Environment is unavailable on this host (Windows PowerShell 5.1), ' +
            'so USERPROFILE cannot be redirected and the install would write to the real user profile. ' +
            'Run this suite under pwsh 7.')
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
    . (Join-Path $ScriptRoot '_testinstallregistrykiro.ps1')
    . (Join-Path $ScriptRoot '_testinstallevaluate.ps1')

    # =====================================================================
    # The persisted record's verdict must equal the install's actual outcome.
    #
    # It did not. The record hardcoded lastResult='ok'/lastReason='installed'
    # while $overallResult was computed 50 lines LATER, so the registry could
    # persist "ok" for an install that was degraded or that installed nothing at
    # all - and "Update previously installed hooks" reads that record, not the
    # result document. Each case below asserts the record and the result file
    # agree, which is the property a single derivation gives and two independent
    # ones cannot.
    Write-Host ''
    Write-Host '--- the install record records the outcome that actually happened ---' -ForegroundColor Cyan
    $verdictFixtureName = 'ZZZ-Regtest-Verdict'
    $verdictFixture = New-FixtureHook -Name $verdictFixtureName
    try {
        # Reads BOTH sides of one install: the result document's overall verdict
        # and the record the same run persisted.
        function Get-InstallVerdict {
            param([string]$ProjectName, [string[]]$Clients, [string[]]$Events)
            $project = New-Proj $ProjectName
            $resultPath = Join-Path $Work ($ProjectName + '-result.json')
            & $InstallScript -CustomHook $verdictFixture -TargetProject $project `
                -Clients $Clients -Events $Events -ResultPath $resultPath *> $null
            $document = ((Read-JsonFile $resultPath))
            $records = @(Get-RecordsFor $verdictFixtureName | Where-Object { [string]$_.targetProjectRoot -eq $project })
            $recorded = ''
            $reason = ''
            if ($records.Count -eq 1) {
                $recorded = [string]$records[0].lastResult
                $reason = [string]$records[0].lastReason
            }
            return [pscustomobject]@{
                Overall  = [string]$document.overall
                Recorded = $recorded
                Reason   = $reason
                Details  = ((@($document.components | ForEach-Object { [string]$_.component + ':' + [string]$_.status }) -join ' ') +
                    ' | overall=' + [string]$document.overall + ' record=' + $recorded)
            }
        }

        $verdictOk = Get-InstallVerdict -ProjectName 'verdict-ok' -Clients @('claude') -Events @('SessionStart')
        Check 'a clean install reports ok and records ok' (
            $verdictOk.Overall -ceq 'ok' -and $verdictOk.Recorded -ceq 'ok' -and
            $verdictOk.Reason -ceq 'installed') $verdictOk.Details

        # Kiro documents no PreCompact trigger, so that event is dropped and the
        # component lands 'ok' with reason 'degraded' - less than was asked for.
        $verdictPartial = Get-InstallVerdict -ProjectName 'verdict-partial' -Clients @('kiro') -Events @('SessionStart', 'PreCompact')
        Check 'a degraded install reports partial and records partial, never ok' (
            $verdictPartial.Overall -ceq 'partial' -and $verdictPartial.Recorded -ceq 'partial') $verdictPartial.Details

        # Kiro is the only client asked for and NO requested event has a Kiro
        # trigger, so the component fails outright and nothing is installed. The
        # bookkeeping 'registry' component is still ok - it tracked the failure
        # successfully - which is exactly what used to downgrade this to
        # 'partial' and let the record claim 'ok'.
        $verdictFailed = Get-InstallVerdict -ProjectName 'verdict-failed' -Clients @('kiro') -Events @('PreCompact')
        Check 'an install where the only requested client failed reports failed and records failed' (
            $verdictFailed.Overall -ceq 'failed' -and $verdictFailed.Recorded -ceq 'failed') $verdictFailed.Details
        Check 'the recorded reason states that nothing the caller asked for was installed' (
            $verdictFailed.Reason -match 'no requested client') $verdictFailed.Reason
        # The load-bearing property, stated once over all three: whatever the
        # verdict is, both sides of the install say the same thing.
        Check 'the record and the result document never disagree about the outcome' (
            $verdictOk.Overall -ceq $verdictOk.Recorded -and
            $verdictPartial.Overall -ceq $verdictPartial.Recorded -and
            $verdictFailed.Overall -ceq $verdictFailed.Recorded) (
            $verdictOk.Details + ' // ' + $verdictPartial.Details + ' // ' + $verdictFailed.Details)
    }
    finally {
        Remove-FixtureHook -Name $verdictFixtureName
    }
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
