# Offline test suite for the hook-list management rows.
#
# The scenarios live in the dot-sourced blocks listed below; each block's own
# header states exactly what it proves. This file keeps only the harness, the
# helpers and the workspace lifecycle.
#
# Drives the real interactive wizard via Start-Process with a scripted stdin
# answer file (same pattern as Test-LegacyDiscovery.ps1's Invoke-Wizard):
# main menu 1 (Create or install a hook) -> submenu 1 (Install an existing
# hook) -> the hook list -> the flow under test.
#
# Scenario blocks, dot-sourced into this scope in order (same convention as
# Test-InstallRegistry.ps1 and the other large suites - this file keeps the
# harness, helpers and workspace; the blocks hold only scenarios):
#   _testinstalledmenulistandlayout.ps1   uninstall list/confirmation identity,
#                                         the fixed menu numbering, and the
#                                         hook-status root-folder prompt. These
#                                         share ONE fixture-scoped try/finally,
#                                         which is why they are one block:
#                                         separating them would duplicate the
#                                         fixture lifecycle.
#   _testinstalledmenustatusrender.ps1    the status result screen and its
#                                         totals/partial-coverage reporting.
#   _testinstalledmenuuninstallrows.ps1   uninstall row selection, the project
#                                         scope filter, and location text.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstalledHooksMenu.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$Setup = Join-Path $ScriptRoot 'Setup-SyncGroup.ps1'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($Setup, $InstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Same chain as Test-UninstallHook.ps1: _hooklib.ps1 first (Get-ShortHash,
# Read-JsonFile, ...), then _installplan.ps1, then _installlib.ps1 (which
# dot-sources _installregistry.ps1 itself, so Read-InstallRegistry /
# Get-ClientSubrecord / Get-InstalledClientNames all become available).
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
# _installlib.ps1 itself dot-sources _clientcapability.ps1 and _installvalidate.ps1,
# so Get-HookMakerClientIds / Get-HookMakerClientCapability / Get-CanonicalClientSettingsPath
# are already reachable here (and, being script scope, inside the & {} render
# harnesses below). Setup-SyncGroupInstalledHooks.ps1 is loaded for the REAL
# Get-ClientDisplayName: the result screen used to be asserted against a local
# stub of it, which cannot prove the shipped function names a client correctly.
. (Join-Path $ScriptRoot 'Setup-SyncGroupInstalledHooks.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-menu22'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir
$SavedHookMakerLogDir = $env:HOOKMAKER_LOG_DIR
$env:HOOKMAKER_LOG_DIR = Join-Path $Work 'logs'

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

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

# ---- immunity to OTHER suites' throwaway fixtures --------------------------
# ZZZ- is this project's reserved prefix for throwaway hook fixtures, and
# several suites create them directly inside the REAL hooks\ directory. Such a
# directory is a CUSTOM hook to the wizard (it is not in $script:HookMeta), so
# it takes an index in the custom block and pushes every later row down one - a
# leftover from an aborted run silently corrupted this suite's counts and row
# assertions. Every count and index taken off the real hooks\ directory below
# therefore goes through Remove-ForeignFixtureRows first.
#
# This suite's OWN fixtures are kept: they are what the custom-block assertions
# are about. Everything else starting with ZZZ- belongs to another suite.
$script:OwnFixtureHooks = @('ZZZ-Menusuite-Fixture')
function Test-ForeignFixtureRow {
    param([string]$Label)
    # -match is case-insensitive, which is the intent: zzz-, Zzz- and ZZZ- are
    # all the same reserved fixture prefix.
    if ($Label -notmatch '^ZZZ-') { return $false }
    foreach ($own in $script:OwnFixtureHooks) {
        if ($Label -match ('^' + [regex]::Escape($own) + '\b')) { return $false }
    }
    return $true
}
# Drops foreign fixture rows and shifts the rows after each one down by exactly
# the number dropped before it, so the surviving rows keep the numbers they
# would have had on a clean hooks\ directory. It shifts rather than renumbering
# 1..N on purpose: renumbering would manufacture contiguity and quietly defeat
# the "rows 3..24 all exist" assertion if a real row ever went missing.
function Remove-ForeignFixtureRows {
    param($Rows)
    if ($null -eq $Rows) { return $null }
    $dropped = @(@($Rows.Keys) | Where-Object { Test-ForeignFixtureRow ([string]$Rows[$_]) })
    $out = @{}
    foreach ($key in @($Rows.Keys)) {
        if ($dropped -contains $key) { continue }
        $shift = @($dropped | Where-Object { $_ -lt $key }).Count
        $out[$key - $shift] = [string]$Rows[$key]
    }
    return , $out
}
# One comparable string for a whole row map, so "nothing moved" is provable
# row-for-row instead of by spot-checking a few indices.
#
# Row 1 is excluded: it is the "Select all" aggregate, and its hint quotes the
# LIVE hook spans ("...install every hook below (3-30 and 36-36)"), so it
# legitimately changes when a hook exists that this suite filters out - that is
# the wizard counting correctly, not a row moving. Nothing here pins that hint's
# text; the assertion on row 1 matches its "Select all hooks" prefix only.
function Get-RowSignature {
    param($Rows)
    if ($null -eq $Rows) { return '<no rows>' }
    return ((@($Rows.Keys) | Sort-Object | Where-Object { $_ -ne 1 } | ForEach-Object { [string]$_ + '. ' + [string]$Rows[$_] }) -join "`n")
}

function New-Config {
    param([string]$Path)
    '{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[]}' | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-Registry { return Read-InstallRegistry -ToolRoot $ToolRoot }
function Get-RecordForScope {
    param([string]$FriendlyName, [string]$TargetProjectRoot)
    return @((Get-Registry).installs | Where-Object { [string]$_.friendlyName -eq $FriendlyName -and [string]$_.targetProjectRoot -eq $TargetProjectRoot })[0]
}

# Same spawned-process pattern as Test-LegacyDiscovery.ps1's Invoke-Wizard:
# writes the scripted answers to a stdin file, spawns the wizard as a real
# process (isolated by -WorkingDirectory and the HOOKMAKER_STATE_DIR
# environment override), and strips ANSI color codes from the captured output
# so assertions can match plain text.
function Invoke-Wizard {
    param([string[]]$Answers, [string]$Config, [string]$WorkingDirectory)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inF = Join-Path $Work "in-$token.txt"; $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    [System.IO.File]::WriteAllText($inF, (($Answers -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    $argLine = '-NoLogo -NoProfile -File "' + $Setup + '" -ConfigPath "' + $Config + '"'
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine; RedirectStandardInput = $inF
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        WorkingDirectory = $WorkingDirectory
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-BoundedProcess @startArgs
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = [regex]::Replace($out, "\x1b\[[0-9;]*m", ''); Err = $err }
}

# Pulls the numbered rows out of the LAST rendered "Available hooks (hooks\):"
# block and returns them as an ordered index -> label map. Anchoring on the last
# block matters: an answer sequence that re-displays the menu after an error
# leaves several copies in the captured output.
function Get-HookListRows {
    param([string]$Output)
    $header = 'Available hooks (hooks\):'
    $start = $Output.LastIndexOf($header)
    if ($start -lt 0) { return $null }
    $end = $Output.IndexOf('  Tip: use lists and ranges', $start)
    if ($end -lt 0) { $end = $Output.Length }
    # A plain hashtable, NOT [ordered]: an OrderedDictionary indexed with an
    # [int] treats it as a POSITIONAL index rather than a key, so $rows[21]
    # would silently mean "the 22nd row" instead of "the row numbered 21".
    $rows = @{}
    foreach ($line in ($Output.Substring($start, $end - $start) -split "`r?`n")) {
        $m = [regex]::Match($line, '^  (\d+)\. (.+?)\s*$')
        if ($m.Success) { $rows[[int]$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return , $rows
}

try {
    . (Join-Path $ScriptRoot '_testinstalledmenulistandlayout.ps1')
    . (Join-Path $ScriptRoot '_testinstalledmenustatusrender.ps1')
    . (Join-Path $ScriptRoot '_testinstalledmenuuninstallrows.ps1')

}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    $env:HOOKMAKER_LOG_DIR = $SavedHookMakerLogDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
