# Offline test suite for Uninstall-DiscoveredHook.ps1: the remover for
# DISCOVERED registry records (hooks a status scan found on disk, which Hook
# Maker did not install and cannot prove ownership of by construction).
#
# The whole safety story of that script is "act only on exact current evidence",
# so this suite is built around proving the negatives:
#
#   * exact canonical FINGERPRINT identity removes the right Claude/Codex
#     handler and nothing else - not the same basename at another path, not a
#     foreign handler in the same matcher group, not another event,
#   * a handler that CHANGED since the scan produces manualRepair and ZERO
#     mutation,
#   * runtime deletion is a separate decision from registration removal: a
#     shared target, an out-of-boundary target, a non-entrypoint helper and a
#     Hook Maker tool-root source are all PRESERVED while the registration
#     still comes off,
#   * native Git removal requires the exact hash, hooks directory and repository
#     identity; a Hook Maker wrapper routes to the EXISTING managed uninstaller
#     rather than getting a second deletion path,
#   * the registry record only disappears after the cleanup it authorized is
#     verified, and injected settings/registry write failures roll the machine
#     back or retain tracking honestly - never a false success.
#
# "Nothing was touched" is always proven by comparing BYTES before and after,
# never by Test-Path: a file that still exists but was rewritten is exactly the
# failure these assertions have to catch. Where a file legitimately changes
# (the settings file we are editing), the UNRELATED parts of it are compared as
# canonical structure strings so a reordering or a dropped sibling field fails.
#
# Mirrors Test-UninstallHook.ps1's conventions: temp-only fixtures under a
# unique prefix, $env:HOOKMAKER_STATE_DIR isolation so the real registry is
# never touched, a fake tool root so the real hooks\ folder is never a target,
# and a spawned process per invocation of the script under test.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-DiscoveredUninstall.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$DiscoveredUninstallScript = Join-Path $ScriptRoot 'Uninstall-DiscoveredHook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($DiscoveredUninstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
# Same chain as the other suites, plus the shared discovery identity layer so
# the fingerprints the fixtures persist are computed by exactly the same code
# the script under test recomputes them with.
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')
. (Join-Path $ScriptRoot '_hookdiscovery.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-disctest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir
New-Item -ItemType Directory -Path $IsolatedStateDir -Force | Out-Null

# A FAKE tool root is used for every run: the script resolves its "never touch
# Hook Maker's own sources" boundary from -ToolRoot, so pointing it at a
# throwaway tree lets that rule be tested without the real hooks\ folder ever
# being a candidate.
$FakeToolRoot = Join-Path $Work 'faketool'
New-Item -ItemType Directory -Path (Join-Path $FakeToolRoot 'hooks') -Force | Out-Null

# This exact line threw twice under the full matrix while the suite passed
# 106/0 standalone every time, and a scratchpad under %TEMP% was wiped in the
# same session - the working theory is an EXTERNAL deleter (Storage Sense, a
# scanner, a harness sweep) removing the directory between the check and the
# write. It is deliberately NOT retried: a silent retry would hide an
# environment that deletes live working directories, which would corrupt a real
# run just as easily. What it does instead is fail with the evidence needed to
# identify the deleter next time - whether the workspace root and the immediate
# directory still existed at the moment of the write.
function Write-Utf8 { param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    try { [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
    catch {
        throw ('Write-Utf8 failed for ' + $Path + ' :: ' + $_.Exception.Message +
            ' [workspace exists=' + (Test-Path -LiteralPath $Work -PathType Container) +
            '; parent exists=' + (Test-Path -LiteralPath $directory -PathType Container) +
            '; utc=' + [DateTime]::UtcNow.ToString('o') + ']')
    }
}
# Comma-wrapped: a bare `return [byte[]]@()` enumerates to $null, which would
# make the "unchanged" comparison throw instead of failing the assertion.
function Get-BytesOrEmpty { param([string]$Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { return , ([System.IO.File]::ReadAllBytes($Path)) } return , ([byte[]]@()) }
function Test-BytesEqual { param([byte[]]$A, [byte[]]$B) return [System.Linq.Enumerable]::SequenceEqual([byte[]]$A, [byte[]]$B) }
function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }

# Canonical structure of everything in a settings file EXCEPT one event, so
# "the rest of the file is untouched" is a single exact comparison rather than a
# handful of spot checks that would miss a dropped sibling field.
function Get-SettingsShapeExcept {
    param([string]$Path, [string]$ExceptEvent = '')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '(absent)' }
    $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($ExceptEvent -ne '' -and $null -ne $json.PSObject.Properties['hooks'] -and $null -ne $json.hooks -and
        $null -ne $json.hooks.PSObject.Properties[$ExceptEvent]) {
        $json.hooks.PSObject.Properties.Remove($ExceptEvent)
    }
    return (ConvertTo-CanonicalStructureString -Value $json)
}

function Get-HandlerPrints {
    param([string]$SettingsPath, [string]$EventName, [int]$GroupIndex = 0, [int]$HandlerIndex = 0)
    $json = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $group = @($json.hooks.$EventName)[$GroupIndex]
    $handler = @($group.hooks)[$HandlerIndex]
    return [pscustomobject]@{
        Handler = (Get-HandlerFingerprint -Handler $handler)
        Matcher = (Get-MatcherFingerprint -Group $group)
    }
}

# ---- registry fixtures ------------------------------------------------------
# Written as raw schema-3 JSON rather than through the installer: these records
# describe hooks Hook Maker never installed, so there is no install path that
# could produce them.
function Set-Registry {
    param([object[]]$Records)
    $registry = [pscustomobject][ordered]@{ version = 3; installs = @($Records) }
    Write-Utf8 (Join-Path $IsolatedStateDir 'install-registry.json') ($registry | ConvertTo-Json -Depth 40)
}
function Get-RegistryRecord {
    param([string]$Id)
    $path = Join-Path $IsolatedStateDir 'install-registry.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $registry = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    return @(@($registry.installs) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['id'] -and [string]$_.id -eq $Id })[0]
}

function New-ClientEvidence {
    param(
        [string]$Client, [string]$SettingsPath, [string[]]$Events,
        [string[]]$HandlerFingerprints, [string[]]$MatcherFingerprints, [string[]]$ParsedTargets
    )
    return [pscustomobject][ordered]@{
        client              = $Client
        settingsPath        = $SettingsPath
        events              = @($Events)
        handlerFingerprints = @($HandlerFingerprints)
        matcherFingerprints = @($MatcherFingerprints)
        handlerTypes        = @('command')
        commandFieldNames   = @('command')
        parsedTargets       = @($ParsedTargets)
        registrationStatus  = 'parsed'
    }
}
function New-RuntimeArtifact {
    param(
        [string]$Path, [string]$Kind = 'entrypoint',
        [string]$Classification = 'registeredRuntime', [string]$Hash = '',
        [string]$DeleteEligibility = 'eligible', [string[]]$ReferencedBy = @()
    )
    if ($Hash -eq '') { $Hash = Get-FileSha256Hex -Path $Path }
    return [pscustomobject][ordered]@{
        path              = $Path
        kind              = $Kind
        hash              = $Hash
        size              = 0
        classification    = $Classification
        referencedBy      = @($ReferencedBy)
        deleteEligibility = $DeleteEligibility
        deleteReason      = ''
    }
}
function New-DiscoveredRecord {
    param(
        [string]$Id, [string]$HookType, [string]$Scope = 'project', [string]$TargetProjectRoot = '',
        [object[]]$Clients = @(), $NativeGit = $null, [object[]]$RuntimeArtifacts = @(),
        [string]$RemovalPolicy = 'full', [string]$Status = 'active', [bool]$NeedsManualRepair = $false
    )
    return [pscustomobject][ordered]@{
        id                = $Id
        schema            = 3
        recordType        = 'discovered'
        origin            = 'statusScan'
        friendlyName      = $Id
        hookType          = $HookType
        scope             = $Scope
        targetProjectRoot = $TargetProjectRoot
        firstSeenUtc      = '2026-01-01T00:00:00.0000000Z'
        lastSeenUtc       = '2026-01-01T00:00:00.0000000Z'
        lastScanId        = 'scan-test'
        scanRoots         = @($TargetProjectRoot)
        status            = $Status
        statusReason      = ''
        managedBy         = 'external'
        clients           = @($Clients)
        nativeGit         = $NativeGit
        runtimeArtifacts  = @($RuntimeArtifacts)
        removalPolicy     = $RemovalPolicy
        needsManualRepair = $NeedsManualRepair
    }
}

# ---- the script under test, always in a fresh process ----------------------
# -WhileRunning runs a scriptblock in THIS process while the child is live, which
# is the only way to inject a change into the window between the child's
# read-only verification pass and its per-settings-file lock. It is never a bare
# sleep: the caller blocks on an observable marker the child itself creates.
function Invoke-DiscoveredUninstall {
    param([string]$RecordId, [switch]$WhatIf, [string]$UninstallToolRoot = $FakeToolRoot, [scriptblock]$WhileRunning = $null)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "out-$token.txt"; $errF = Join-Path $Work "err-$token.txt"
    $resultFile = Join-Path $Work "result-$token.json"
    $argLine = '-NoLogo -NoProfile -File "' + $DiscoveredUninstallScript + '" -RecordId "' + $RecordId +
        '" -ToolRoot "' + $UninstallToolRoot + '" -ResultPath "' + $resultFile + '"'
    if ($WhatIf) { $argLine += ' -WhatIf' }
    $hostExecutable = (Get-Process -Id $PID).Path
    $startArgs = @{
        FilePath = $hostExecutable; ArgumentList = $argLine
        RedirectStandardOutput = $outF; RedirectStandardError = $errF
        Wait = ($null -eq $WhileRunning); NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
    }
    $p = Start-Process @startArgs
    if ($null -ne $WhileRunning) {
        try { & $WhileRunning }
        finally { $p.WaitForExit(); $p.Refresh() }
    }
    $out = ''; if (Test-Path $outF) { $out = [System.IO.File]::ReadAllText($outF) }
    $err = ''; if (Test-Path $errF) { $err = ([System.IO.File]::ReadAllText($errF)).Trim() }
    $doc = $null
    if (Test-Path -LiteralPath $resultFile) { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ Exit = $p.ExitCode; Out = $out; Err = $err; Result = $doc }
}
function Get-ComponentStatus {
    param($ResultDoc, [string]$Component)
    if ($null -eq $ResultDoc) { return '' }
    $found = @($ResultDoc.components | Where-Object { [string]$_.component -eq $Component })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].status
}
function Get-ComponentReason {
    param($ResultDoc, [string]$Component)
    if ($null -eq $ResultDoc) { return '' }
    $found = @($ResultDoc.components | Where-Object { [string]$_.component -eq $Component })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].reason
}
function Get-ComponentMessage {
    param($ResultDoc, [string]$Component)
    if ($null -eq $ResultDoc) { return '' }
    $found = @($ResultDoc.components | Where-Object { [string]$_.component -eq $Component })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].message
}

# The child stages every runtime artifact aside with a sibling rename AFTER its
# read-only verification pass and BEFORE it takes the first settings lock, so
# the appearance of a set-aside file is an exact, observable marker for "phase 1
# is finished". Blocking on it - rather than sleeping a guessed interval - is
# what makes the between-verification-and-lock injection deterministic.
function Wait-ForSetAside {
    param([string]$Directory, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $staged = @(Get-ChildItem -LiteralPath $Directory -Filter '*.hookmaker-disc-setaside-*' -File -Force -ErrorAction SilentlyContinue)
        if ($staged.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 40
    }
    return $false
}

# Handler command text used everywhere below. -File is the shape
# Get-CommandTargetInfo resolves to an exact target.
function New-CommandFor { param([string]$Target) return ('pwsh -NoProfile -File "' + $Target + '"') }

# A manifest of the REAL hooks\ folder, captured before any test runs and
# compared after all of them: no path through this suite may alter a shipped
# source file.
#
# ZZZ-* directories are excluded because that is this project's throwaway-hook
# fixture convention: the suites run in parallel in CI, so a sibling suite's
# fixture appearing or disappearing mid-run would otherwise fail this assertion
# for a reason that has nothing to do with the code under test. Every SHIPPED
# source is still covered, which is what the guarantee is about.
function Get-RealHooksManifest {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $RealHooksDir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        if ($file.FullName -match '\\ZZZ-[^\\]*\\') { continue }
        [void]$lines.Add($file.FullName + '|' + (Get-FileSha256Hex -Path $file.FullName))
    }
    return ($lines.ToArray() -join "`n")
}
$RealHooksBefore = Get-RealHooksManifest

try {
    # Scenario blocks, split by responsibility and dot-sourced in execution
    # order into THIS scope, so Check, $script:Pass/$script:Fail, the shared
    # fixtures and every helper above resolve in the caller. The finally below
    # stays HERE so cleanup always runs whichever block fails.
    . (Join-Path $ScriptRoot '_testdiscovereduninstallidentity.ps1')
    . (Join-Path $ScriptRoot '_testdiscovereduninstallrollback.ps1')

    # =======================================================================
    Write-Host '--- the real hooks\ sources were never touched ---' -ForegroundColor Cyan
    Check 'the real <ToolRoot>\hooks tree is byte-identical to before the suite' ((Get-RealHooksManifest) -eq $RealHooksBefore)
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
