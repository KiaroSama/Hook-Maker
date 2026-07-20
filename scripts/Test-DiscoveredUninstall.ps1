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

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-disctest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
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

function Write-Utf8 { param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
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
function Invoke-DiscoveredUninstall {
    param([string]$RecordId, [switch]$WhatIf, [string]$UninstallToolRoot = $FakeToolRoot)
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
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
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
    # =======================================================================
    Write-Host '--- exact Claude handler fingerprint removal ---' -ForegroundColor Cyan
    $p1 = New-Proj 'P1Claude'
    $p1Mine = Join-Path $p1 '.claude\hooks\mine.ps1'
    $p1Foreign = Join-Path $p1 '.claude\hooks\foreign.ps1'
    Write-Utf8 $p1Mine "exit 0`n"
    Write-Utf8 $p1Foreign "exit 0`n"
    $p1Settings = Join-Path $p1 '.claude\settings.local.json'
    $p1Doc = [pscustomobject]@{
        permissions = [pscustomobject]@{ allow = @('Bash(git:*)') }
        hooks = [pscustomobject]@{
            SessionStart = @(
                [pscustomobject]@{ matcher = 'startup|resume'; hooks = @(
                    [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p1Mine); timeout = 60 },
                    [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p1Foreign); timeout = 30 }
                ) }
            )
            Stop = @([pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'echo done' }) })
        }
        someOtherTool = [pscustomobject]@{ keep = $true }
    }
    Write-Utf8 $p1Settings ($p1Doc | ConvertTo-Json -Depth 20)
    $p1Prints = Get-HandlerPrints -SettingsPath $p1Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-claude-1' -HookType 'ClaudeRegistration' -TargetProjectRoot $p1 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p1Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p1Prints.Handler) -MatcherFingerprints @($p1Prints.Matcher) -ParsedTargets @($p1Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p1Mine -ReferencedBy @('disc-claude-1'))))
    )
    $p1ShapeBefore = Get-SettingsShapeExcept -Path $p1Settings -ExceptEvent 'SessionStart'
    $p1ForeignBytes = Get-BytesOrEmpty $p1Foreign

    $r = Invoke-DiscoveredUninstall -RecordId 'disc-claude-1'
    Check 'claude: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'claude: the claude component is ok' ((Get-ComponentStatus $r.Result 'claude') -eq 'ok')
    $p1After = [System.IO.File]::ReadAllText($p1Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $p1Remaining = @(@($p1After.hooks.SessionStart)[0].hooks)
    Check 'claude: exactly one handler remains in the matcher group' ($p1Remaining.Count -eq 1)
    Check 'claude: the surviving handler is the FOREIGN one' ([string]$p1Remaining[0].command -eq (New-CommandFor $p1Foreign)) ([string]$p1Remaining[0].command)
    Check 'claude: the foreign handler kept its own timeout field' ([int]$p1Remaining[0].timeout -eq 30)
    Check 'claude: every unrelated part of the settings file is structurally identical' `
        ((Get-SettingsShapeExcept -Path $p1Settings -ExceptEvent 'SessionStart') -eq $p1ShapeBefore)
    Check 'claude: the foreign runtime file is byte-for-byte unchanged' (Test-BytesEqual $p1ForeignBytes (Get-BytesOrEmpty $p1Foreign))
    # Exclusive, verified, inside .claude\hooks -> this one IS removable.
    Check 'claude: the exclusive verified entrypoint under .claude\hooks was removed' (-not (Test-Path -LiteralPath $p1Mine))
    Check 'claude: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-claude-1'))

    # =======================================================================
    Write-Host '--- exact Codex handler fingerprint removal ---' -ForegroundColor Cyan
    $p2 = New-Proj 'P2Codex'
    $p2Mine = Join-Path $p2 '.codex\hooks\mine.ps1'
    Write-Utf8 $p2Mine "exit 0`n"
    $p2Settings = Join-Path $p2 '.codex\hooks.json'
    Write-Utf8 $p2Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            UserPromptSubmit = @([pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = (New-CommandFor $p2Mine) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p2Prints = Get-HandlerPrints -SettingsPath $p2Settings -EventName 'UserPromptSubmit'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-codex-1' -HookType 'CodexRegistration' -TargetProjectRoot $p2 `
            -Clients @((New-ClientEvidence -Client 'codex' -SettingsPath $p2Settings -Events @('UserPromptSubmit') `
                -HandlerFingerprints @($p2Prints.Handler) -MatcherFingerprints @($p2Prints.Matcher) -ParsedTargets @($p2Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p2Mine -ReferencedBy @('disc-codex-1'))))
    )
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-codex-1'
    Check 'codex: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    $p2After = [System.IO.File]::ReadAllText($p2Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'codex: the emptied event key was pruned' ($null -eq $p2After.hooks.PSObject.Properties['UserPromptSubmit'])
    Check 'codex: the exclusive verified entrypoint under .codex\hooks was removed' (-not (Test-Path -LiteralPath $p2Mine))
    Check 'codex: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-codex-1'))

    # =======================================================================
    Write-Host '--- a CHANGED handler fingerprint blocks everything ---' -ForegroundColor Cyan
    $p3 = New-Proj 'P3Changed'
    $p3Mine = Join-Path $p3 '.claude\hooks\mine.ps1'
    Write-Utf8 $p3Mine "exit 0`n"
    $p3Settings = Join-Path $p3 '.claude\settings.local.json'
    Write-Utf8 $p3Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p3Mine); timeout = 60 }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p3Prints = Get-HandlerPrints -SettingsPath $p3Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-changed' -HookType 'ClaudeRegistration' -TargetProjectRoot $p3 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p3Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p3Prints.Handler) -MatcherFingerprints @($p3Prints.Matcher) -ParsedTargets @($p3Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p3Mine -ReferencedBy @('disc-changed'))))
    )
    # The handler is edited AFTER the record was written - exactly the drift the
    # remover must refuse to act on.
    Write-Utf8 $p3Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p3Mine); timeout = 120 }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p3SettingsBytes = Get-BytesOrEmpty $p3Settings
    $p3MineBytes = Get-BytesOrEmpty $p3Mine

    $r = Invoke-DiscoveredUninstall -RecordId 'disc-changed'
    Check 'changed: the run reports manualRepair' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair') ($r.Out + $r.Err)
    Check 'changed: the claude component reports evidenceChanged' ((Get-ComponentReason $r.Result 'claude') -eq 'evidenceChanged')
    Check 'changed: the settings file is byte-for-byte unchanged' (Test-BytesEqual $p3SettingsBytes (Get-BytesOrEmpty $p3Settings))
    Check 'changed: the runtime file is byte-for-byte unchanged' (Test-BytesEqual $p3MineBytes (Get-BytesOrEmpty $p3Mine))
    $p3Record = Get-RegistryRecord 'disc-changed'
    Check 'changed: the registry record is retained' ($null -ne $p3Record)
    Check 'changed: the retained record is flagged for manual repair' ($null -ne $p3Record -and $p3Record.needsManualRepair -eq $true)

    # =======================================================================
    Write-Host '--- the same basename at a different path survives ---' -ForegroundColor Cyan
    $p4 = New-Proj 'P4Basename'
    $p4Mine = Join-Path $p4 '.claude\hooks\check.ps1'
    $p4Other = Join-Path $p4 '.claude\hooks\sub\check.ps1'
    Write-Utf8 $p4Mine "exit 0`n"
    Write-Utf8 $p4Other "exit 1`n"
    $p4Settings = Join-Path $p4 '.claude\settings.local.json'
    Write-Utf8 $p4Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p4Mine) },
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p4Other) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p4Prints = Get-HandlerPrints -SettingsPath $p4Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-basename' -HookType 'ClaudeRegistration' -TargetProjectRoot $p4 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p4Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p4Prints.Handler) -MatcherFingerprints @($p4Prints.Matcher) -ParsedTargets @($p4Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p4Mine -ReferencedBy @('disc-basename'))))
    )
    $p4OtherBytes = Get-BytesOrEmpty $p4Other
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-basename'
    Check 'basename: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    $p4After = [System.IO.File]::ReadAllText($p4Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $p4Remaining = @(@($p4After.hooks.SessionStart)[0].hooks)
    Check 'basename: the same-named handler at the other path survives' `
        ($p4Remaining.Count -eq 1 -and [string]$p4Remaining[0].command -eq (New-CommandFor $p4Other)) ([string]$p4Remaining[0].command)
    Check 'basename: the same-named file at the other path is byte-for-byte unchanged' (Test-BytesEqual $p4OtherBytes (Get-BytesOrEmpty $p4Other))
    Check 'basename: only the recorded target was removed' (-not (Test-Path -LiteralPath $p4Mine))

    # =======================================================================
    Write-Host '--- a shared runtime target is preserved ---' -ForegroundColor Cyan
    $p5 = New-Proj 'P5Shared'
    $p5Shared = Join-Path $p5 '.claude\hooks\shared.ps1'
    Write-Utf8 $p5Shared "exit 0`n"
    $p5Settings = Join-Path $p5 '.claude\settings.local.json'
    Write-Utf8 $p5Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p5Shared); timeout = 60 },
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p5Shared); timeout = 90 }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p5Prints = Get-HandlerPrints -SettingsPath $p5Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-shared' -HookType 'ClaudeRegistration' -TargetProjectRoot $p5 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p5Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p5Prints.Handler) -MatcherFingerprints @($p5Prints.Matcher) -ParsedTargets @($p5Shared))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p5Shared -ReferencedBy @('disc-shared'))))
    )
    $p5SharedBytes = Get-BytesOrEmpty $p5Shared
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-shared'
    Check 'shared: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'shared: the runtime component reports registration removed, runtime preserved' `
        ((Get-ComponentReason $r.Result 'runtime') -eq 'registrationRemovedRuntimePreserved') (Get-ComponentReason $r.Result 'runtime')
    Check 'shared: the still-referenced runtime file is byte-for-byte unchanged' (Test-BytesEqual $p5SharedBytes (Get-BytesOrEmpty $p5Shared))
    $p5After = [System.IO.File]::ReadAllText($p5Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'shared: the other registration of the same file survives' (@(@($p5After.hooks.SessionStart)[0].hooks).Count -eq 1)

    # =======================================================================
    Write-Host '--- a target outside any recognized hook root is registration-only ---' -ForegroundColor Cyan
    $p6 = New-Proj 'P6Outside'
    $p6Outside = Join-Path $p6 'tools\outside.ps1'
    Write-Utf8 $p6Outside "exit 0`n"
    $p6Settings = Join-Path $p6 '.claude\settings.local.json'
    Write-Utf8 $p6Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p6Outside) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p6Prints = Get-HandlerPrints -SettingsPath $p6Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-outside' -HookType 'ClaudeRegistration' -TargetProjectRoot $p6 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p6Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p6Prints.Handler) -MatcherFingerprints @($p6Prints.Matcher) -ParsedTargets @($p6Outside))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p6Outside -ReferencedBy @('disc-outside'))))
    )
    $p6OutsideBytes = Get-BytesOrEmpty $p6Outside
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-outside'
    Check 'outside: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'outside: the registration was removed but the runtime preserved' `
        ((Get-ComponentReason $r.Result 'runtime') -eq 'registrationRemovedRuntimePreserved')
    Check 'outside: the out-of-boundary file is byte-for-byte unchanged' (Test-BytesEqual $p6OutsideBytes (Get-BytesOrEmpty $p6Outside))
    $p6After = [System.IO.File]::ReadAllText($p6Settings, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Check 'outside: the registration really is gone' ($null -eq $p6After.hooks.PSObject.Properties['SessionStart'])
    Check 'outside: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-outside'))

    # =======================================================================
    Write-Host '--- an orphan helper is never deleted ---' -ForegroundColor Cyan
    $p7 = New-Proj 'P7Orphan'
    $p7Entry = Join-Path $p7 '.claude\hooks\entry.ps1'
    $p7Helper = Join-Path $p7 '.claude\hooks\helper.ps1'
    Write-Utf8 $p7Entry "exit 0`n"
    Write-Utf8 $p7Helper "exit 0`n"
    $p7Settings = Join-Path $p7 '.claude\settings.local.json'
    Write-Utf8 $p7Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p7Entry) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p7Prints = Get-HandlerPrints -SettingsPath $p7Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-orphan' -HookType 'ClaudeRegistration' -TargetProjectRoot $p7 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p7Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p7Prints.Handler) -MatcherFingerprints @($p7Prints.Matcher) -ParsedTargets @($p7Entry, $p7Helper))) `
            -RuntimeArtifacts @(
                (New-RuntimeArtifact -Path $p7Entry -ReferencedBy @('disc-orphan')),
                (New-RuntimeArtifact -Path $p7Helper -Kind 'helper' -Classification 'orphanRuntimeCandidate' -ReferencedBy @('disc-orphan'))
            ))
    )
    $p7HelperBytes = Get-BytesOrEmpty $p7Helper
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-orphan'
    Check 'orphan: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'orphan: the proven entrypoint was removed' (-not (Test-Path -LiteralPath $p7Entry))
    Check 'orphan: the non-entrypoint helper is byte-for-byte unchanged' (Test-BytesEqual $p7HelperBytes (Get-BytesOrEmpty $p7Helper))

    # =======================================================================
    Write-Host '--- Hook Maker tool-root sources are never removable ---' -ForegroundColor Cyan
    $p8 = New-Proj 'P8ToolRoot'
    $toolSource = Join-Path $FakeToolRoot 'hooks\Shipped\Shipped.ps1'
    Write-Utf8 $toolSource "exit 0`n"
    $p8Settings = Join-Path $p8 '.claude\settings.local.json'
    Write-Utf8 $p8Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $toolSource) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p8Prints = Get-HandlerPrints -SettingsPath $p8Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-toolroot' -HookType 'ClaudeRegistration' -TargetProjectRoot $p8 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p8Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p8Prints.Handler) -MatcherFingerprints @($p8Prints.Matcher) -ParsedTargets @($toolSource))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $toolSource -ReferencedBy @('disc-toolroot'))))
    )
    $toolSourceBytes = Get-BytesOrEmpty $toolSource
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-toolroot'
    Check 'toolroot: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'toolroot: the shipped source under <ToolRoot>\hooks is byte-for-byte unchanged' (Test-BytesEqual $toolSourceBytes (Get-BytesOrEmpty $toolSource))
    Check 'toolroot: the runtime was preserved, not deleted' ((Get-ComponentReason $r.Result 'runtime') -eq 'registrationRemovedRuntimePreserved')

    # =======================================================================
    Write-Host '--- an exact external native Git hook is removable ---' -ForegroundColor Cyan
    $repo1 = New-Proj 'Repo1Native'
    $repo1Hooks = Join-Path $repo1 '.git\hooks'
    New-Item -ItemType Directory -Path $repo1Hooks -Force | Out-Null
    $repo1Hook = Join-Path $repo1Hooks 'pre-commit'
    $repo1Sample = Join-Path $repo1Hooks 'pre-push.sample'
    Write-Utf8 $repo1Hook "#!/bin/sh`necho external`n"
    Write-Utf8 $repo1Sample "#!/bin/sh`nexit 0`n"
    $repo1SampleBytes = Get-BytesOrEmpty $repo1Sample
    $repo1Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo1; hooksPath = $repo1Hooks; hookName = 'pre-commit'; hookPath = $repo1Hook
        hookHash = (Get-FileSha256Hex -Path $repo1Hook); hookSize = 0; hookModifiedUtc = ''
        classification = 'externalNativeHook'; managedStages = @()
    }
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-native-ok' -HookType 'NativeGitHook' -TargetProjectRoot $repo1 `
            -NativeGit $repo1Native -RemovalPolicy 'nativeFileOnly')
    )
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-native-ok'
    Check 'native ok: the run reports overall ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'native ok: the external hook file was removed' (-not (Test-Path -LiteralPath $repo1Hook))
    Check 'native ok: the .sample hook beside it is byte-for-byte unchanged' (Test-BytesEqual $repo1SampleBytes (Get-BytesOrEmpty $repo1Sample))
    Check 'native ok: the registry record is gone' ($null -eq (Get-RegistryRecord 'disc-native-ok'))

    # =======================================================================
    Write-Host '--- a native hook changed since discovery survives ---' -ForegroundColor Cyan
    $repo2 = New-Proj 'Repo2Changed'
    $repo2Hooks = Join-Path $repo2 '.git\hooks'
    New-Item -ItemType Directory -Path $repo2Hooks -Force | Out-Null
    $repo2Hook = Join-Path $repo2Hooks 'pre-commit'
    Write-Utf8 $repo2Hook "#!/bin/sh`necho original`n"
    $repo2Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo2; hooksPath = $repo2Hooks; hookName = 'pre-commit'; hookPath = $repo2Hook
        hookHash = (Get-FileSha256Hex -Path $repo2Hook); hookSize = 0; hookModifiedUtc = ''
        classification = 'externalNativeHook'; managedStages = @()
    }
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-native-changed' -HookType 'NativeGitHook' -TargetProjectRoot $repo2 `
            -NativeGit $repo2Native -RemovalPolicy 'nativeFileOnly')
    )
    # Edited after the record was written.
    Write-Utf8 $repo2Hook "#!/bin/sh`necho edited by the user`n"
    $repo2Bytes = Get-BytesOrEmpty $repo2Hook
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-native-changed'
    Check 'native changed: the run reports manualRepair' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair') ($r.Out + $r.Err)
    Check 'native changed: the hook file is byte-for-byte unchanged' (Test-BytesEqual $repo2Bytes (Get-BytesOrEmpty $repo2Hook))
    Check 'native changed: the registry record is retained' ($null -ne (Get-RegistryRecord 'disc-native-changed'))

    # =======================================================================
    Write-Host '--- a Hook Maker wrapper routes through the managed uninstaller ---' -ForegroundColor Cyan
    $repo3 = New-Proj 'Repo3Wrapper'
    $repo3Hooks = Join-Path $repo3 '.git\hooks'
    New-Item -ItemType Directory -Path $repo3Hooks -Force | Out-Null
    $repo3Hook = Join-Path $repo3Hooks 'pre-push'
    # A wrapper carrying the marker but WITHOUT the exact managed content the
    # managed record would rebuild: the managed uninstaller must refuse it, and
    # the point of the assertion is that the refusal comes from THAT script.
    Write-Utf8 $repo3Hook ("#!/bin/sh`n" + $script:PrePushMarker + "`necho hand edited`n")
    $repo3Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo3; hooksPath = $repo3Hooks; hookName = 'pre-push'; hookPath = $repo3Hook
        hookHash = (Get-FileSha256Hex -Path $repo3Hook); hookSize = 0; hookModifiedUtc = ''
        classification = 'hookMakerWrapper'; managedStages = @()
    }
    $managedRecord = [pscustomobject][ordered]@{
        id = 'managed-wrapper-1'; schema = 3; recordType = 'managed'; origin = 'hookMaker'
        friendlyName = 'ZZZ-Disc-Wrapper'; hookType = 'CustomHook'; scope = 'project'
        targetProjectRoot = $repo3; profile = ''; sourceScript = (Join-Path $FakeToolRoot 'hooks\ZZZ-Disc-Wrapper\ZZZ-Disc-Wrapper.ps1')
        toolRoot = $FakeToolRoot; clients = [pscustomobject]@{}; sourceManifest = @(); needsManualRepair = $false
        nativeGit = [pscustomobject][ordered]@{
            managed = $true; wrapperPath = $repo3Hook; hooksPath = $repo3Hooks
            runtimeRoot = (Join-Path $repo3 '.git\hooks\Hook-Maker'); expectedStages = @()
            previousHookPath = ''; previousHookPreserved = $false
        }
    }
    Set-Registry @(
        $managedRecord,
        (New-DiscoveredRecord -Id 'disc-wrapper' -HookType 'NativeGitHook' -TargetProjectRoot $repo3 `
            -NativeGit $repo3Native -RemovalPolicy 'nativeFileOnly')
    )
    $repo3Bytes = Get-BytesOrEmpty $repo3Hook
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-wrapper'
    Check 'wrapper: the native component was delegated to the managed uninstaller' `
        ((Get-ComponentReason $r.Result 'nativeGit') -eq 'delegatedToManagedUninstaller') (Get-ComponentReason $r.Result 'nativeGit')
    Check 'wrapper: the discovered remover did not delete the wrapper itself' (Test-BytesEqual $repo3Bytes (Get-BytesOrEmpty $repo3Hook))
    Check 'wrapper: the discovered record is retained while the managed uninstall is unresolved' ($null -ne (Get-RegistryRecord 'disc-wrapper'))
    Check 'wrapper: the managed record was left for its own uninstaller to resolve' ($null -ne (Get-RegistryRecord 'managed-wrapper-1'))

    # =======================================================================
    Write-Host '--- a managed record is never routed into this script ---' -ForegroundColor Cyan
    $r = Invoke-DiscoveredUninstall -RecordId 'managed-wrapper-1'
    Check 'managed: the run refuses with manualRepair' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'manualRepair') ($r.Out + $r.Err)
    Check 'managed: the refusal names the wrong record type' ((Get-ComponentReason $r.Result 'registry') -eq 'wrongRecordType')
    Check 'managed: the managed record is untouched' ($null -ne (Get-RegistryRecord 'managed-wrapper-1'))

    # =======================================================================
    Write-Host '--- injected settings write failure rolls everything back ---' -ForegroundColor Cyan
    $p9 = New-Proj 'P9SettingsFail'
    $p9Mine = Join-Path $p9 '.claude\hooks\mine.ps1'
    Write-Utf8 $p9Mine "exit 0`n"
    $p9Settings = Join-Path $p9 '.claude\settings.local.json'
    Write-Utf8 $p9Settings (([pscustomobject]@{
        hooks = [pscustomobject]@{
            SessionStart = @([pscustomobject]@{ matcher = 'startup'; hooks = @(
                [pscustomobject]@{ type = 'command'; command = (New-CommandFor $p9Mine) }) })
        }
    }) | ConvertTo-Json -Depth 20)
    $p9Prints = Get-HandlerPrints -SettingsPath $p9Settings -EventName 'SessionStart'
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-settingsfail' -HookType 'ClaudeRegistration' -TargetProjectRoot $p9 `
            -Clients @((New-ClientEvidence -Client 'claude' -SettingsPath $p9Settings -Events @('SessionStart') `
                -HandlerFingerprints @($p9Prints.Handler) -MatcherFingerprints @($p9Prints.Matcher) -ParsedTargets @($p9Mine))) `
            -RuntimeArtifacts @((New-RuntimeArtifact -Path $p9Mine -ReferencedBy @('disc-settingsfail'))))
    )
    $p9SettingsBytes = Get-BytesOrEmpty $p9Settings
    $p9MineBytes = Get-BytesOrEmpty $p9Mine
    # Injection: a read-only settings file makes the atomic publish fail AFTER
    # the runtime has already been staged aside - the exact window the rollback
    # exists for.
    Set-ItemProperty -LiteralPath $p9Settings -Name IsReadOnly -Value $true
    try {
        $r = Invoke-DiscoveredUninstall -RecordId 'disc-settingsfail'
        Check 'settings fail: the run does NOT report success' ($null -ne $r.Result -and [string]$r.Result.overall -ne 'ok') ($r.Out + $r.Err)
        Check 'settings fail: the runtime file was restored byte-for-byte' (Test-BytesEqual $p9MineBytes (Get-BytesOrEmpty $p9Mine))
        Check 'settings fail: the settings file is byte-for-byte unchanged' (Test-BytesEqual $p9SettingsBytes (Get-BytesOrEmpty $p9Settings))
        Check 'settings fail: the registry record is retained' ($null -ne (Get-RegistryRecord 'disc-settingsfail'))
    }
    finally {
        Set-ItemProperty -LiteralPath $p9Settings -Name IsReadOnly -Value $false
        Get-ChildItem -LiteralPath (Split-Path -Parent $p9Settings) -Filter '*.backup-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # =======================================================================
    Write-Host '--- injected registry write failure rolls a native removal back ---' -ForegroundColor Cyan
    $repo4 = New-Proj 'Repo4RegFail'
    $repo4Hooks = Join-Path $repo4 '.git\hooks'
    New-Item -ItemType Directory -Path $repo4Hooks -Force | Out-Null
    $repo4Hook = Join-Path $repo4Hooks 'pre-commit'
    Write-Utf8 $repo4Hook "#!/bin/sh`necho external`n"
    $repo4Native = [pscustomobject][ordered]@{
        repositoryRoot = $repo4; hooksPath = $repo4Hooks; hookName = 'pre-commit'; hookPath = $repo4Hook
        hookHash = (Get-FileSha256Hex -Path $repo4Hook); hookSize = 0; hookModifiedUtc = ''
        classification = 'externalNativeHook'; managedStages = @()
    }
    Set-Registry @(
        (New-DiscoveredRecord -Id 'disc-regfail' -HookType 'NativeGitHook' -TargetProjectRoot $repo4 `
            -NativeGit $repo4Native -RemovalPolicy 'nativeFileOnly')
    )
    $repo4Bytes = Get-BytesOrEmpty $repo4Hook
    # Injection: hold the registry's own exclusive lock for the whole child run.
    # A read-only registry file would NOT do it - the atomic writer replaces the
    # file wholesale and overwrites the attribute - whereas an unavailable lock
    # is a real persistence failure, and it lands AFTER the native hook has
    # already been staged aside, which is the window the rollback exists for.
    $lockPath = Join-Path $IsolatedStateDir 'install-registry.lock'
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $r = Invoke-DiscoveredUninstall -RecordId 'disc-regfail'
        Check 'registry fail: the run does NOT report success' ($null -ne $r.Result -and [string]$r.Result.overall -ne 'ok') ($r.Out + $r.Err)
        Check 'registry fail: the native hook was restored byte-for-byte' (Test-BytesEqual $repo4Bytes (Get-BytesOrEmpty $repo4Hook))
    }
    finally {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    Check 'registry fail: the record is still tracked' ($null -ne (Get-RegistryRecord 'disc-regfail'))

    # =======================================================================
    Write-Host '--- the record is removed only AFTER the cleanup it authorized ---' -ForegroundColor Cyan
    # Proven by the -WhatIf path: every proof runs, the result says it WOULD
    # remove, and neither the artifact nor the record actually moves.
    $whatIfBytes = Get-BytesOrEmpty $repo4Hook
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-regfail' -WhatIf
    Check 'whatif: the run reports ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'whatif: the result is marked as a dry run' ($null -ne $r.Result -and $r.Result.dryRun -eq $true)
    Check 'whatif: the native hook is byte-for-byte unchanged' (Test-BytesEqual $whatIfBytes (Get-BytesOrEmpty $repo4Hook))
    Check 'whatif: the registry record still exists' ($null -ne (Get-RegistryRecord 'disc-regfail'))

    # A real run of the same record now succeeds, proving the ordering: the
    # record disappears only once the artifact it authorized really came off.
    $r = Invoke-DiscoveredUninstall -RecordId 'disc-regfail'
    Check 'ordering: the real run reports ok' ($null -ne $r.Result -and [string]$r.Result.overall -eq 'ok') ($r.Out + $r.Err)
    Check 'ordering: the artifact is gone' (-not (Test-Path -LiteralPath $repo4Hook))
    Check 'ordering: and only then is the record gone' ($null -eq (Get-RegistryRecord 'disc-regfail'))

    # =======================================================================
    Write-Host '--- the real hooks\ sources were never touched ---' -ForegroundColor Cyan
    Check 'the real <ToolRoot>\hooks tree is byte-identical to before the suite' ((Get-RealHooksManifest) -eq $RealHooksBefore)
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { } }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
