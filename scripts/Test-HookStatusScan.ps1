# Offline test suite for Get-HookStatus.ps1's TRAVERSAL and PERSISTENCE: how the
# walk reaches hooks, what it refuses to follow, what it survives, and what it
# writes.
#
# Parsing is covered by Test-HookStatusDiscovery.ps1; everything here is about
# getting to the evidence and recording it safely.
#
# Covers: an arbitrary ancestor root finds nested hooks; a direct runtime subtree
# finds the NEAREST related settings by bounded upward lookup; a deeply nested
# tree; access-denied isolated to one directory; a disappearing directory
# isolated; a reparse/junction loop never followed; canonical duplicate paths
# deduplicated; NO default depth cap (and -MaxDepth proving the knob is the only
# thing that caps it); and a full-drive-shaped fixture - hundreds of unrelated
# folders, nested projects, a permission hole, Claude/Codex/Git hooks at
# different depths - scanned from its root with no depth hint.
#
# Refusals (checked BEFORE anything is scanned): a -ResultPath that resolves
# inside a scan root - directly or nested - is refused rather than written, and a
# scan root that IS a reparse point is refused rather than followed.
#
# Persistence: -NoPersist writes nothing; a successful scan persists and updates
# in place on rescan; a failed scan leaves the registry byte-identical; managed
# records are never touched; partial coverage persists but never claims
# completeness.
#
# NEVER scans a real drive or a real user home - temp fixtures only.
#
# This entry file owns the harness, shared fixtures/helpers, the try/finally
# cleanup and the summary. The scenario blocks themselves live in four
# dot-sourced companion files (run in this script's scope, in this order;
# none is a standalone suite):
#   _testhookstatusscantraversal.ps1   - how the walk reaches hooks, what it
#                                        refuses to follow, what it survives
#   _testhookstatusscanpersistence.ps1 - what a scan persists, updates,
#                                        demotes and never touches
#   _testhookstatusscanrefusals.ps1    - what is refused BEFORE anything is
#                                        scanned, and that refusals leave no
#                                        trace
#   _testhookstatusscanglobal.ps1      - -IncludeGlobal honored (and
#                                        declined) on every code path
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-HookStatusScan.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$Scanner = Join-Path $ScriptRoot 'Get-HookStatus.ps1'
if (-not (Test-Path -LiteralPath $Scanner -PathType Leaf)) {
    Write-Host "Required script not found: $Scanner" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 800
. (Join-Path $ScriptRoot '_testlib.ps1')
[void](Disable-DaclBypassPrivilege)
# The persistence block reads the registry back in THIS scope; it is a
# directory of per-record files, and these helpers are what read it.
# _hooklib first: _installregistry.ps1 uses Set-ObjectProperty and
# Write-JsonFileAtomic from it.
. (Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\_hooklib.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
. (Join-Path $ScriptRoot '_installregistry.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-statusscan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# Sweep workspaces an INTERRUPTED earlier run left behind, before making a new
# one. The finally block below undoes every deny ACL it created, but a run that
# is killed never reaches it - and Deny-Directory denies the CURRENT user, so
# what is left cannot be deleted by an ordinary recursive remove, and not by
# `icacls /reset` either. Only the same undo used at teardown clears it, so it
# is applied here too rather than leaving the tree to accumulate forever. Only
# this suite's own workspaces are touched, and only ones no longer in use.
# -Except guards the LIVE workspace: this same sweep is exercised mid-run by a
# test, and without it that call would delete the tree the suite is standing on.
function Clear-StaleStatusScanWorkspaces {
    param([string]$Except = '')
    $swept = 0
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    foreach ($stale in @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'hookmaker-statusscan-*' -ErrorAction SilentlyContinue)) {
        if ($Except -ne '' -and [string]::Equals($stale.FullName, $Except, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($directory in (@($stale) + @(Get-ChildItem -LiteralPath $stale.FullName -Recurse -Directory -Force -ErrorAction SilentlyContinue))) {
            try {
                & icacls $directory.FullName /remove:d $identity *> $null
                & icacls $directory.FullName /grant ($identity + ':(OI)(CI)F') *> $null
            }
            catch { }
        }
        try { Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop; $swept++ }
        catch { Write-Host ('  stale workspace could not be swept (in use?): ' + $stale.Name) -ForegroundColor DarkYellow }
    }
    return $swept
}

$script:SweptWorkspaces = Clear-StaleStatusScanWorkspaces
if ($script:SweptWorkspaces -gt 0) {
    Write-Host ("Swept $script:SweptWorkspaces stale workspace(s) from an interrupted run") -ForegroundColor DarkGray
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedStateDir = $env:HOOKMAKER_STATE_DIR
$StateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $StateDir
$RegistryPath = Join-Path $StateDir 'install-registry.json'

# Tracked so cleanup can always undo them, even on an early failure.
$script:DeniedDirectories = New-Object System.Collections.Generic.List[string]
$script:Junctions = New-Object System.Collections.Generic.List[string]

function New-Dir { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path }

# One Claude registration pointing at a real script inside the given project.
function New-ClaudeHook {
    param([string]$ProjectRoot, [string]$HookName, [string]$SettingsLeaf = 'settings.local.json')
    $target = Join-Path (New-Dir (Join-Path $ProjectRoot 'hookscripts')) ($HookName + '.ps1')
    Write-Utf8 -Path $target -Content ('# ' + $HookName)
    $settings = Join-Path $ProjectRoot ('.claude\' + $SettingsLeaf)
    Write-Utf8 -Path $settings -Content (@{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $target + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    return $target
}
function New-CodexHook {
    param([string]$ProjectRoot, [string]$HookName)
    $target = Join-Path (New-Dir (Join-Path $ProjectRoot 'hookscripts')) ($HookName + '.ps1')
    Write-Utf8 -Path $target -Content ('# ' + $HookName)
    Write-Utf8 -Path (Join-Path $ProjectRoot '.codex\hooks.json') -Content (@{
        hooks = @{ Stop = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $target + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    return $target
}
function New-GitHookRepo {
    param([string]$RepositoryRoot, [string]$HookName = 'pre-push')
    Write-Utf8 -Path (Join-Path $RepositoryRoot ('.git\hooks\' + $HookName)) -Content "#!/bin/sh`necho hook`n"
    return $RepositoryRoot
}

function Invoke-Scan {
    param([string]$Root, [switch]$IncludeGlobal, [switch]$Persist, [int]$MaxDepth = 0, [switch]$Async, [hashtable]$Environment,
        # Only the refusal tests pass this; every other scan writes its result
        # document to the workspace, safely outside the root being scanned.
        [string]$ResultPath)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = $(if ([string]::IsNullOrWhiteSpace($ResultPath)) { Join-Path $Work ("result-$token.json") } else { $ResultPath })
    $outFile = Join-Path $Work ("out-$token.txt")
    $errFile = Join-Path $Work ("err-$token.txt")
    $argLine = '-NoLogo -NoProfile -File "' + $Scanner + '" -ScanRoot "' + $Root + '" -ToolRoot "' + $ToolRoot +
        '" -ResultPath "' + $resultPath + '"'
    if (-not $Persist) { $argLine += ' -NoPersist' }
    if ($IncludeGlobal) { $argLine += ' -IncludeGlobal' }
    if ($MaxDepth -gt 0) { $argLine += ' -MaxDepth ' + $MaxDepth }
    $startArgs = @{
        FilePath = (Get-Process -Id $PID).Path; ArgumentList = $argLine
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        NoNewWindow = $true; PassThru = $true; WorkingDirectory = $Work
    }
    if (-not $Async) { $startArgs.Wait = $true }
    $environmentToUse = @{ HOOKMAKER_STATE_DIR = $env:HOOKMAKER_STATE_DIR }
    if ($null -ne $Environment) { foreach ($k in $Environment.Keys) { $environmentToUse[$k] = $Environment[$k] } }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) { $startArgs.Environment = $environmentToUse }
    $process = Start-BoundedProcess @startArgs
    if ($Async) { return [pscustomobject]@{ Process = $process; ResultPath = $resultPath; ErrFile = $errFile } }
    $document = $null
    if (Test-Path -LiteralPath $resultPath) { $document = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    return [pscustomobject]@{ Exit = $process.ExitCode; Result = $document; Err = $err; ResultPath = $resultPath }
}

function Test-FoundTarget {
    param($Result, [string]$Fragment)
    if ($null -eq $Result) { return $false }
    foreach ($finding in @($Result.findings)) {
        foreach ($client in @($finding.clients)) {
            foreach ($target in @($client.parsedTargets)) { if ([string]$target -like ('*' + $Fragment + '*')) { return $true } }
        }
        if ($null -ne $finding.nativeGit -and [string]$finding.nativeGit.hookPath -like ('*' + $Fragment + '*')) { return $true }
    }
    return $false
}

function Deny-Directory {
    param([string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    try { & icacls $Path /deny ($identity + ':(OI)(CI)(RX)') *> $null } catch { return $false }
    [void]$script:DeniedDirectories.Add($Path)
    try { [void][System.IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator().MoveNext(); return $false }
    catch { return $true }
}

try {
    # Scenario blocks live in dot-sourced companion files. They run in THIS
    # script's scope (shared harness, helpers, fixtures, $script: counters,
    # one shared workspace and registry) - execution ORDER is load-bearing
    # (later blocks rescan fixture trees built by earlier ones), and the
    # finally below still owns all cleanup. None of them is a standalone
    # suite.
    . (Join-Path $ScriptRoot '_testhookstatusscantraversal.ps1')
    . (Join-Path $ScriptRoot '_testhookstatusscanpersistence.ps1')
    . (Join-Path $ScriptRoot '_testhookstatusscanrefusals.ps1')
    . (Join-Path $ScriptRoot '_testhookstatusscanglobal.ps1')
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedStateDir
    # Undo permission and reparse fixtures FIRST, or the workspace cannot be
    # removed and the next run inherits the mess.
    foreach ($path in $script:DeniedDirectories) {
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            & icacls $path /remove:d $identity *> $null
            & icacls $path /grant ($identity + ':(OI)(CI)F') *> $null
        }
        catch { }
    }
    foreach ($path in $script:Junctions) {
        # Delete the LINK, never its contents.
        try { [System.IO.Directory]::Delete($path) } catch { }
    }
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
