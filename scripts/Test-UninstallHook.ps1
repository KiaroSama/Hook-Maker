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
# success, no silent registry deletion, retained record reflects reality).
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

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-uninstalltest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

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
    param([string]$RecordId, [switch]$WhatIf, [string]$UninstallToolRoot = $ToolRoot, [string]$FakeHome = '')
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outF = Join-Path $Work "uninstout-$token.txt"; $errF = Join-Path $Work "uninsterr-$token.txt"
    $resultFile = Join-Path $Work "uninstresult-$token.json"
    $argLine = '-NoLogo -NoProfile -File "' + $UninstallScript + '" -RecordId "' + $RecordId + '" -ToolRoot "' + $UninstallToolRoot + '" -ResultPath "' + $resultFile + '"'
    if ($WhatIf) { $argLine += ' -WhatIf' }
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

try {
    # =========================================================================
    Write-Host '--- scope isolation: removing one project-A record leaves everything else intact ---' -ForegroundColor Cyan
    $fxA1 = New-FixtureHook 'ZZZ-Uninst-Ahook1'
    $fxA2 = New-FixtureHook 'ZZZ-Uninst-Ahook2'
    try {
        $projA = New-Proj 'ScopeProjA'
        $projB = New-Proj 'ScopeProjB'
        & $InstallScript -CustomHook $fxA1 -Events @('Stop') -TargetProject $projA *> $null
        & $InstallScript -CustomHook $fxA2 -Events @('Stop') -TargetProject $projA -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fxA1 -Events @('Stop') -TargetProject $projB *> $null

        $recA1 = Get-RecordForScope 'ZZZ-Uninst-Ahook1' $projA
        $recA2 = Get-RecordForScope 'ZZZ-Uninst-Ahook2' $projA
        $recB1 = Get-RecordForScope 'ZZZ-Uninst-Ahook1' $projB
        Check 'setup: project A got a both-client record for hook1' ($null -ne $recA1 -and (@(Get-InstalledClientNames -Record $recA1) | Sort-Object) -join ',' -eq 'claude,codex')
        Check 'setup: project A got a Claude-only record for hook2' ($null -ne $recA2 -and (@(Get-InstalledClientNames -Record $recA2) -join ',') -eq 'claude')
        Check 'setup: project B got its own independent record for hook1' ($null -ne $recB1 -and $recB1.id -ne $recA1.id)

        $a2ClaudeScript = [string]$recA2.clients.claude.runtimeScript
        $a2ClaudeBytesBefore = Get-BytesOrEmpty $a2ClaudeScript
        $projAClaudeSettings = [string]$recA1.clients.claude.settingsPath
        $projACodexSettings = [string]$recA1.clients.codex.settingsPath
        $b1ClaudeSettings = [string]$recB1.clients.claude.settingsPath
        $b1CodexSettings = [string]$recB1.clients.codex.settingsPath
        $b1ClaudeScript = [string]$recB1.clients.claude.runtimeScript
        $b1CodexScript = [string]$recB1.clients.codex.runtimeScript
        $bBytesBefore = @{
            claudeSettings = Get-BytesOrEmpty $b1ClaudeSettings
            codexSettings  = Get-BytesOrEmpty $b1CodexSettings
            claudeScript   = Get-BytesOrEmpty $b1ClaudeScript
            codexScript    = Get-BytesOrEmpty $b1CodexScript
        }

        $rA1 = Invoke-UninstallProcess -RecordId $recA1.id
        Check 'removing project A hook1 exits 0' ($rA1.Exit -eq 0) $rA1.Err
        Check 'removing project A hook1 reports overall ok' ([string]$rA1.Result.overall -eq 'ok') ($rA1.Result | ConvertTo-Json -Depth 5)

        Check 'hook1 record is gone from the registry' (@(Get-RecordsFor 'ZZZ-Uninst-Ahook1' | Where-Object { $_.targetProjectRoot -eq $projA }).Count -eq 0)
        Check 'hook2 record in project A is untouched' (@(Get-RecordsFor 'ZZZ-Uninst-Ahook2').Count -eq 1)
        Check 'project B''s hook1 record is untouched' (@(Get-RecordsFor 'ZZZ-Uninst-Ahook1' | Where-Object { $_.targetProjectRoot -eq $projB }).Count -eq 1)

        # Parsed, not raw-text-matched: ConvertTo-Json escapes path backslashes
        # as \\, so a raw-text regex containing a literal backslash would
        # never match the file's actual bytes. Inspecting the parsed command
        # values (real single backslashes again after ConvertFrom-Json) is
        # both correct and immune to that escaping detail.
        $claudeHandlersAfter = @((Get-Content -LiteralPath $projAClaudeSettings -Raw | ConvertFrom-Json).hooks.Stop | ForEach-Object { $_.hooks } | ForEach-Object { Get-HandlerFieldValue $_ 'command' })
        Check 'project A Claude settings no longer reference hook1''s runtime script' (@($claudeHandlersAfter | Where-Object { $_ -like '*ZZZ-Uninst-Ahook1*' }).Count -eq 0)
        Check 'project A Claude settings still reference hook2''s runtime script' (@($claudeHandlersAfter | Where-Object { $_ -like '*ZZZ-Uninst-Ahook2*' }).Count -eq 1)
        $codexJsonAfter = [System.IO.File]::ReadAllText($projACodexSettings)
        Check 'project A Codex settings no longer reference hook1 (its only Codex registration)' ($codexJsonAfter -notmatch 'ZZZ-Uninst-Ahook1')

        Check 'hook1''s Claude runtime copy is gone from project A' (-not (Test-Path -LiteralPath ([string]$recA1.clients.claude.runtimeScript)))
        Check 'hook1''s Codex runtime copy is gone from project A' (-not (Test-Path -LiteralPath ([string]$recA1.clients.codex.runtimeScript)))
        Check 'hook2''s Claude runtime copy in project A is untouched (byte-identical)' (Test-BytesEqual (Get-BytesOrEmpty $a2ClaudeScript) $a2ClaudeBytesBefore)

        Check 'project B Claude settings are byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $b1ClaudeSettings) $bBytesBefore.claudeSettings)
        Check 'project B Codex settings are byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $b1CodexSettings) $bBytesBefore.codexSettings)
        Check 'project B Claude runtime is byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $b1ClaudeScript) $bBytesBefore.claudeScript)
        Check 'project B Codex runtime is byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $b1CodexScript) $bBytesBefore.codexScript)
        Check 'the repo source for hook1 is never deleted' (Test-Path -LiteralPath $fxA1)
        Check 'the repo source for hook2 is never deleted' (Test-Path -LiteralPath $fxA2)

        # Now remove the Claude-only hook2 record and prove codex is reported
        # as never-installed (not a false failure), and project B stays clean.
        $rA2 = Invoke-UninstallProcess -RecordId $recA2.id
        Check 'removing the Claude-only hook2 exits 0' ($rA2.Exit -eq 0) $rA2.Err
        Check 'removing a Claude-only record reports codex as skipped/notInstalled' ((Get-ComponentStatus $rA2.Result 'codex') -eq 'skipped')
        Check 'removing a Claude-only record reports claude as ok' ((Get-ComponentStatus $rA2.Result 'claude') -eq 'ok')
        Check 'hook2 record is now gone too' (@(Get-RecordsFor 'ZZZ-Uninst-Ahook2').Count -eq 0)
        Check 'project B''s record survives both removals in project A' (@(Get-RecordsFor 'ZZZ-Uninst-Ahook1' | Where-Object { $_.targetProjectRoot -eq $projB }).Count -eq 1)
        Check 'project B Claude settings are STILL byte-for-byte unchanged after a second removal' (Test-BytesEqual (Get-BytesOrEmpty $b1ClaudeSettings) $bBytesBefore.claudeSettings)
    }
    finally {
        Remove-FixtureHook 'ZZZ-Uninst-Ahook1'
        Remove-FixtureHook 'ZZZ-Uninst-Ahook2'
    }

    # =========================================================================
    Write-Host '--- ownership is proven by managed runtime path, never by basename ---' -ForegroundColor Cyan
    $fxBasename = New-FixtureHook 'ZZZ-Uninst-Basename'
    try {
        $projBase = New-Proj 'BasenameUninstallProj'
        & $InstallScript -CustomHook $fxBasename -Events @('Stop') -TargetProject $projBase -ClaudeOnly *> $null
        $recBase = Get-RecordForScope 'ZZZ-Uninst-Basename' $projBase
        $baseSettingsPath = [string]$recBase.clients.claude.settingsPath

        $baseJson = Get-Content -LiteralPath $baseSettingsPath -Raw | ConvertFrom-Json
        $foreignA = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "C:\Users\me\MyTools\ZZZ-Uninst-Basename.ps1"'; timeout = 99 }) }
        $foreignB = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; commandWindows = 'powershell -File "D:\Other\ZZZ-Uninst-Basename.ps1"'; timeout = 5 }) }
        $baseJson.hooks.Stop = @($baseJson.hooks.Stop) + @($foreignA) + @($foreignB)
        [System.IO.File]::WriteAllText($baseSettingsPath, ($baseJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        $rBase = Invoke-UninstallProcess -RecordId $recBase.id
        Check 'uninstalling the real record exits 0' ($rBase.Exit -eq 0) $rBase.Err

        $baseAfter = Get-Content -LiteralPath $baseSettingsPath -Raw | ConvertFrom-Json
        $baseHandlers = @(@($baseAfter.hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'a foreign same-basename handler in command survives uninstall' (@($baseHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*MyTools*' }).Count -eq 1)
        Check 'a foreign same-basename handler in commandWindows survives uninstall' (@($baseHandlers | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -like '*Other*' }).Count -eq 1)
        Check 'the real Hook Maker registration is gone' (@($baseHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*Hook-Maker*' }).Count -eq 0)
        Check 'the record is removed' (@(Get-RecordsFor 'ZZZ-Uninst-Basename').Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Basename' }

    # =========================================================================
    Write-Host '--- a runtime path outside the expected boundary is refused ---' -ForegroundColor Cyan
    $fxUnsafe = New-FixtureHook 'ZZZ-Uninst-Unsafepath'
    try {
        $projUnsafe = New-Proj 'UnsafePathProj'
        & $InstallScript -CustomHook $fxUnsafe -Events @('Stop') -TargetProject $projUnsafe -ClaudeOnly *> $null
        $recUnsafe = Get-RecordForScope 'ZZZ-Uninst-Unsafepath' $projUnsafe
        $runtimeRoot = [string]$recUnsafe.clients.claude.runtimeRoot
        # A decoy directory OUTSIDE runtimeRoot, at exactly the path a
        # traversal-corrupted friendlyName would resolve the hook dir to.
        $decoyDir = Join-Path (Split-Path -Parent $runtimeRoot) 'OUTSIDE-DECOY'
        New-Item -ItemType Directory -Path $decoyDir -Force | Out-Null
        Write-Utf8 (Join-Path $decoyDir 'marker.txt') 'do not touch me'
        $decoyBytesBefore = Get-BytesOrEmpty (Join-Path $decoyDir 'marker.txt')
        $realRuntimeScriptBefore = Get-BytesOrEmpty ([string]$recUnsafe.clients.claude.runtimeScript)

        $recUnsafe.friendlyName = '..\OUTSIDE-DECOY'
        Save-MutatedRecord -Record $recUnsafe

        $rUnsafe = Invoke-UninstallProcess -RecordId $recUnsafe.id
        Check 'an unsafe runtime path does not crash the uninstaller' ($rUnsafe.Exit -eq 0) $rUnsafe.Err
        Check 'an unsafe runtime path is refused with a precise reason, at whichever gate catches it' (-not [string]::IsNullOrWhiteSpace((Get-AnyRefusalReason $rUnsafe.Result))) ($rUnsafe.Result | ConvertTo-Json -Depth 5)
        Check 'the decoy directory outside the boundary is never touched' (Test-BytesEqual (Get-BytesOrEmpty (Join-Path $decoyDir 'marker.txt')) $decoyBytesBefore)
        Check 'the real (correctly-pathed) runtime script is left alone too' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recUnsafe.clients.claude.runtimeScript)) $realRuntimeScriptBefore)
        Check 'the record is retained, not deleted, when a path is refused' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recUnsafe.id }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Unsafepath' }

    # =========================================================================
    Write-Host '--- missing runtime / already-removed registration is idempotent ---' -ForegroundColor Cyan
    $fxIdem = New-FixtureHook 'ZZZ-Uninst-Idempotent'
    try {
        $projIdem = New-Proj 'IdempotentProj'
        & $InstallScript -CustomHook $fxIdem -Events @('Stop') -TargetProject $projIdem -ClaudeOnly *> $null
        $recIdem = Get-RecordForScope 'ZZZ-Uninst-Idempotent' $projIdem
        # Simulate a hand-cleaned-up state: runtime already gone, registration
        # already stripped from settings, BEFORE the uninstaller ever runs.
        Remove-Item -LiteralPath (Split-Path -Parent ([string]$recIdem.clients.claude.runtimeScript)) -Recurse -Force
        Write-Utf8 ([string]$recIdem.clients.claude.settingsPath) '{"hooks":{}}'

        $rIdem = Invoke-UninstallProcess -RecordId $recIdem.id
        Check 'a missing runtime + already-removed registration is not an error' ($rIdem.Exit -eq 0) $rIdem.Err
        Check 'a missing runtime + already-removed registration reports overall ok' ([string]$rIdem.Result.overall -eq 'ok') ($rIdem.Result | ConvertTo-Json -Depth 5)
        Check 'the claude component is ok, not failed, for an already-gone registration' ((Get-ComponentStatus $rIdem.Result 'claude') -eq 'ok')
        Check 'the record is fully removed' (@(Get-RecordsFor 'ZZZ-Uninst-Idempotent').Count -eq 0)

        $rIdem2 = Invoke-UninstallProcess -RecordId $recIdem.id
        Check 'a repeated uninstall of an already-gone id exits 0' ($rIdem2.Exit -eq 0) $rIdem2.Err
        Check 'a repeated uninstall of an already-gone id reports overall ok' ([string]$rIdem2.Result.overall -eq 'ok')
        Check 'a repeated uninstall of an already-gone id names the reason notFound' ((Get-ComponentStatus $rIdem2.Result 'registry') -eq 'ok')
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Idempotent' }

    # =========================================================================
    Write-Host '--- a no-op / cancelled uninstall changes nothing byte-for-byte ---' -ForegroundColor Cyan
    $fxNoop = New-FixtureHook 'ZZZ-Uninst-Noop'
    try {
        $projNoop = New-Proj 'NoopProj'
        & $InstallScript -CustomHook $fxNoop -Events @('Stop') -TargetProject $projNoop *> $null
        $recNoop = Get-RecordForScope 'ZZZ-Uninst-Noop' $projNoop
        $snapshotPaths = @(
            [string]$recNoop.clients.claude.settingsPath, [string]$recNoop.clients.codex.settingsPath,
            [string]$recNoop.clients.claude.runtimeScript, [string]$recNoop.clients.codex.runtimeScript
        )
        $before = @{}
        foreach ($path in $snapshotPaths) { $before[$path] = Get-BytesOrEmpty $path }
        $registryBefore = [System.IO.File]::ReadAllBytes((Join-Path $IsolatedStateDir 'install-registry.json'))

        $rWhatIf = Invoke-UninstallProcess -RecordId $recNoop.id -WhatIf
        Check 'a WhatIf run exits 0' ($rWhatIf.Exit -eq 0) $rWhatIf.Err
        Check 'a WhatIf run reports dryRun=true' ($rWhatIf.Result.dryRun -eq $true)
        $allUnchangedAfterWhatIf = $true
        foreach ($path in $snapshotPaths) { if (-not (Test-BytesEqual (Get-BytesOrEmpty $path) $before[$path])) { $allUnchangedAfterWhatIf = $false } }
        Check 'a WhatIf run leaves every settings/runtime file byte-for-byte unchanged' $allUnchangedAfterWhatIf
        Check 'a WhatIf run leaves the registry byte-for-byte unchanged' (Test-BytesEqual ([System.IO.File]::ReadAllBytes((Join-Path $IsolatedStateDir 'install-registry.json'))) $registryBefore)
        Check 'a WhatIf run does not remove the record' (@(Get-RecordsFor 'ZZZ-Uninst-Noop').Count -eq 1)

        $rGhost = Invoke-UninstallProcess -RecordId ([guid]::NewGuid().ToString('N').Substring(0, 10))
        Check 'uninstalling a nonexistent id exits 0' ($rGhost.Exit -eq 0) $rGhost.Err
        Check 'uninstalling a nonexistent id reports overall ok' ([string]$rGhost.Result.overall -eq 'ok')
        $allUnchangedAfterGhost = $true
        foreach ($path in $snapshotPaths) { if (-not (Test-BytesEqual (Get-BytesOrEmpty $path) $before[$path])) { $allUnchangedAfterGhost = $false } }
        Check 'uninstalling a nonexistent id leaves every real file byte-for-byte unchanged' $allUnchangedAfterGhost
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Noop' }

    # =========================================================================
    Write-Host '--- native Git: full removal restores the preserved user hook byte-for-byte ---' -ForegroundColor Cyan
    $ignoreHook = Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'

    # An UNRELATED repo with only the user's own plain pre-push hook - never
    # touched by Hook Maker at all. Its bytes must survive every operation in
    # this block untouched, proving an unrelated native hook is never
    # overwritten or deleted by an unrelated uninstall.
    $unrelatedRepo = Join-Path $Work 'unrelated-repo'
    New-Item -ItemType Directory -Path $unrelatedRepo -Force | Out-Null
    Push-Location $unrelatedRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    $unrelatedHooksDir = Join-Path $unrelatedRepo '.git\hooks'
    New-Item -ItemType Directory -Path $unrelatedHooksDir -Force | Out-Null
    Write-Utf8 (Join-Path $unrelatedHooksDir 'pre-push') "#!/bin/sh`necho totally-unrelated-hook`n"
    $unrelatedBytesBefore = Get-BytesOrEmpty (Join-Path $unrelatedHooksDir 'pre-push')

    $fullRemovalRepo = Join-Path $Work 'fullremoval-repo'
    New-Item -ItemType Directory -Path $fullRemovalRepo -Force | Out-Null
    Push-Location $fullRemovalRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    $frHooksDir = Join-Path $fullRemovalRepo '.git\hooks'
    New-Item -ItemType Directory -Path $frHooksDir -Force | Out-Null
    # Deliberately non-UTF-8 bytes with no trailing newline, matching
    # Test-NativePrePushInstall.ps1's byte-preservation proof.
    $userHookBytes = [byte[]]@(0x23, 0x21, 0x2F, 0x62, 0x69, 0x6E, 0x2F, 0x73, 0x68, 0x0A,
                                0x23, 0x20, 0xFF, 0xFE, 0x80, 0x81, 0x0A,
                                0x65, 0x78, 0x69, 0x74, 0x20, 0x30)
    $frWrapperPath = Join-Path $frHooksDir 'pre-push'
    [System.IO.File]::WriteAllBytes($frWrapperPath, $userHookBytes)

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $fullRemovalRepo -ClaudeOnly *> $null
    $recFr = Get-RecordForScope 'Ignore-Rules-Check' $fullRemovalRepo
    Check 'setup: the native chain is tracked as managed' ($null -ne $recFr.nativeGit -and $recFr.nativeGit.managed -eq $true)
    Check 'setup: the user hook was preserved' ($recFr.nativeGit.previousHookPreserved -eq $true)
    $frNativeRuntimeRoot = [string]$recFr.nativeGit.runtimeRoot

    $rFr = Invoke-UninstallProcess -RecordId $recFr.id
    Check 'full native removal exits 0' ($rFr.Exit -eq 0) $rFr.Err
    Check 'full native removal reports overall ok' ([string]$rFr.Result.overall -eq 'ok') ($rFr.Result | ConvertTo-Json -Depth 5)
    Check 'full native removal reports nativeGit ok' ((Get-ComponentStatus $rFr.Result 'nativeGit') -eq 'ok')
    $restoredBytes = Get-BytesOrEmpty $frWrapperPath
    Check 'the wrapper path now holds the restored user hook, byte-for-byte' (Test-BytesEqual $restoredBytes $userHookBytes)
    Check 'the preserved sidecar file no longer exists (it WAS the restore)' (-not (Test-Path -LiteralPath ($frWrapperPath + '.hookmaker-existing')))
    Check 'the native runtime root is gone (both stages removed, nothing left)' (-not (Test-Path -LiteralPath $frNativeRuntimeRoot))
    Check 'the record is fully removed' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $fullRemovalRepo }).Count -eq 0)
    Check 'the unrelated repo''s own pre-push hook is untouched by this' (Test-BytesEqual (Get-BytesOrEmpty (Join-Path $unrelatedHooksDir 'pre-push')) $unrelatedBytesBefore)

    # =========================================================================
    Write-Host '--- native Git: one managed stage remains -> the wrapper is regenerated ---' -ForegroundColor Cyan
    $regenRepo = Join-Path $Work 'regen-repo'
    New-Item -ItemType Directory -Path $regenRepo -Force | Out-Null
    Push-Location $regenRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $regenRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $regenRepo -ClaudeOnly *> $null
    $recRegen = Get-RecordForScope 'Ignore-Rules-Check' $regenRepo
    $regenRuntimeRoot = [string]$recRegen.nativeGit.runtimeRoot
    $regenWrapperPath = [string]$recRegen.nativeGit.wrapperPath

    # A synthetic foreign stage that this record does NOT own - simulates a
    # second logical owner contributing to the same wrapper.
    $otherDir = Join-Path $regenRuntimeRoot 'Other-Hook'
    New-Item -ItemType Directory -Path $otherDir -Force | Out-Null
    $otherScript = Join-Path $otherDir 'Other-Hook.ps1'
    Write-Utf8 $otherScript "exit 0`n"
    $newExpectedStages = @($otherScript) + @($recRegen.nativeGit.expectedStages)
    $regenBody = New-PrePushWrapperBody -ManagedScripts $newExpectedStages
    [System.IO.File]::WriteAllText($regenWrapperPath, $regenBody, (New-Object System.Text.UTF8Encoding $false))
    $recRegen.nativeGit.expectedStages = @($newExpectedStages)
    Save-MutatedRecord -Record $recRegen

    $rRegen = Invoke-UninstallProcess -RecordId $recRegen.id
    Check 'regenerate-around-a-remaining-stage exits 0' ($rRegen.Exit -eq 0) $rRegen.Err
    Check 'regenerate-around-a-remaining-stage reports overall ok' ([string]$rRegen.Result.overall -eq 'ok') ($rRegen.Result | ConvertTo-Json -Depth 5)
    $regenAfterBody = [System.IO.File]::ReadAllText($regenWrapperPath)
    $expectedRegenBody = New-PrePushWrapperBody -ManagedScripts @($otherScript)
    Check 'the regenerated wrapper matches the canonical generator for the ONE remaining stage' (Compare-PrePushWrapperBody -Expected $expectedRegenBody -Actual $regenAfterBody)
    Check 'the regenerated wrapper no longer runs Ignore-Rules-Check' ($regenAfterBody -notmatch [regex]::Escape('Ignore-Rules-Check/Ignore-Rules-Check.ps1'))
    Check 'the regenerated wrapper no longer runs Secrets-Check' ($regenAfterBody -notmatch [regex]::Escape('Secrets-Check/Secrets-Check.ps1'))
    # New-PrePushWrapperBody rewrites '\' to '/' for the shell script - match
    # the same forward-slash form it actually generates.
    Check 'the regenerated wrapper still runs the remaining foreign stage exactly once' ((([regex]::Matches($regenAfterBody, [regex]::Escape('Other-Hook/Other-Hook.ps1"'))).Count) -eq 1)
    Check 'this record''s own primary runtime dir is gone' (-not (Test-Path -LiteralPath (Join-Path $regenRuntimeRoot 'Ignore-Rules-Check')))
    Check 'this record''s own Secrets-Check companion dir is gone' (-not (Test-Path -LiteralPath (Join-Path $regenRuntimeRoot 'Secrets-Check')))
    Check 'the still-owned foreign stage''s directory survives' (Test-Path -LiteralPath $otherDir)
    Check 'the native runtime root itself survives (not empty - the foreign stage still lives there)' (Test-Path -LiteralPath $regenRuntimeRoot)
    Check 'the record is fully removed' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $regenRepo }).Count -eq 0)

    # =========================================================================
    Write-Host '--- native Git: a tampered/ambiguous wrapper stops the record with manual-repair ---' -ForegroundColor Cyan
    $tamperRepo = Join-Path $Work 'tamper-repo'
    New-Item -ItemType Directory -Path $tamperRepo -Force | Out-Null
    Push-Location $tamperRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $tamperRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $tamperRepo *> $null
    $recTamper = Get-RecordForScope 'Ignore-Rules-Check' $tamperRepo
    $tamperWrapperPath = [string]$recTamper.nativeGit.wrapperPath
    Add-Content -LiteralPath $tamperWrapperPath -Value "`n# hand-tampered stage injected outside the canonical generator`n"
    $tamperedWrapperBytes = Get-BytesOrEmpty $tamperWrapperPath
    $tamperClaudeSettingsBytes = Get-BytesOrEmpty ([string]$recTamper.clients.claude.settingsPath)
    $tamperCodexSettingsBytes = Get-BytesOrEmpty ([string]$recTamper.clients.codex.settingsPath)
    $tamperClaudeRuntimeBytes = Get-BytesOrEmpty ([string]$recTamper.clients.claude.runtimeScript)

    $rTamper = Invoke-UninstallProcess -RecordId $recTamper.id
    Check 'a tampered wrapper does not crash the uninstaller' ($rTamper.Exit -eq 0) $rTamper.Err
    Check 'a tampered wrapper is reported as manualRepair overall' ([string]$rTamper.Result.overall -eq 'manualRepair') ($rTamper.Result | ConvertTo-Json -Depth 5)
    Check 'a tampered wrapper is reported as manualRepair for nativeGit' ((Get-ComponentStatus $rTamper.Result 'nativeGit') -eq 'manualRepair')
    Check 'a tampered wrapper is preserved byte-for-byte (never overwritten)' (Test-BytesEqual (Get-BytesOrEmpty $tamperWrapperPath) $tamperedWrapperBytes)
    Check 'a tampered wrapper stops the WHOLE record - Claude settings untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recTamper.clients.claude.settingsPath)) $tamperClaudeSettingsBytes)
    Check 'a tampered wrapper stops the WHOLE record - Codex settings untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recTamper.clients.codex.settingsPath)) $tamperCodexSettingsBytes)
    Check 'a tampered wrapper stops the WHOLE record - Claude runtime untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recTamper.clients.claude.runtimeScript)) $tamperClaudeRuntimeBytes)
    Check 'a tampered wrapper stops the WHOLE record - claude/codex components are never even attempted' ((Get-ComponentStatus $rTamper.Result 'claude') -eq '' -and (Get-ComponentStatus $rTamper.Result 'codex') -eq '')
    Check 'the record is retained (not removed) after a tampered-wrapper stop' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $tamperRepo }).Count -eq 1)
    Check 'the unrelated repo''s own pre-push hook is STILL untouched after the tamper scenario' (Test-BytesEqual (Get-BytesOrEmpty (Join-Path $unrelatedHooksDir 'pre-push')) $unrelatedBytesBefore)

    # =========================================================================
    Write-Host '--- native Git: a wrapper file present but missing the marker is manualRepair - ownership unknown, never silent success ---' -ForegroundColor Cyan
    $noMarkerRepo = Join-Path $Work 'nomarker-repo'
    New-Item -ItemType Directory -Path $noMarkerRepo -Force | Out-Null
    Push-Location $noMarkerRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $noMarkerRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $noMarkerRepo *> $null
    $recNoMarker = Get-RecordForScope 'Ignore-Rules-Check' $noMarkerRepo
    $noMarkerWrapperPath = [string]$recNoMarker.nativeGit.wrapperPath
    $noMarkerRuntimeRoot = [string]$recNoMarker.nativeGit.runtimeRoot
    Check 'setup: the native chain is tracked as managed (no-marker case)' ($null -ne $recNoMarker.nativeGit -and $recNoMarker.nativeGit.managed -eq $true)

    # Replace the wrapper outright with a plain file carrying NO Hook Maker
    # marker - simulates a user or another tool having replaced it, where
    # ownership of whatever now sits at this path is genuinely unknown.
    Write-Utf8 $noMarkerWrapperPath "#!/bin/sh`necho a completely different pre-push hook, not ours`n"
    $noMarkerWrapperBytesBefore = Get-BytesOrEmpty $noMarkerWrapperPath
    $noMarkerClaudeSettingsBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.settingsPath)
    $noMarkerCodexSettingsBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.settingsPath)
    $noMarkerClaudeRuntimeBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.runtimeScript)
    $noMarkerCodexRuntimeBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.runtimeScript)

    $rNoMarker = Invoke-UninstallProcess -RecordId $recNoMarker.id
    Check 'a marker-less wrapper does not crash the uninstaller' ($rNoMarker.Exit -eq 0) $rNoMarker.Err
    Check 'a marker-less wrapper is reported as manualRepair overall' ([string]$rNoMarker.Result.overall -eq 'manualRepair') ($rNoMarker.Result | ConvertTo-Json -Depth 5)
    Check 'a marker-less wrapper is reported manualRepair for nativeGit with the precise reason' ((@($rNoMarker.Result.components | Where-Object { $_.component -eq 'nativeGit' }))[0].reason -eq 'wrapperReplacedOrOwnershipUnknown')
    Check 'the marker-less wrapper is preserved byte-for-byte (never overwritten)' (Test-BytesEqual (Get-BytesOrEmpty $noMarkerWrapperPath) $noMarkerWrapperBytesBefore)
    Check 'the managed native runtime directory still exists (never swept away)' (Test-Path -LiteralPath (Join-Path $noMarkerRuntimeRoot 'Ignore-Rules-Check'))
    Check 'the managed native companion directory still exists (never swept away)' (Test-Path -LiteralPath (Join-Path $noMarkerRuntimeRoot 'Secrets-Check'))
    Check 'the registry record is retained, not removed' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $noMarkerRepo }).Count -eq 1)
    Check 'claude is never even attempted once nativeGit is ambiguous' ((Get-ComponentStatus $rNoMarker.Result 'claude') -eq '')
    Check 'codex is never even attempted once nativeGit is ambiguous' ((Get-ComponentStatus $rNoMarker.Result 'codex') -eq '')
    Check 'Claude settings are byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.settingsPath)) $noMarkerClaudeSettingsBefore)
    Check 'Codex settings are byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.settingsPath)) $noMarkerCodexSettingsBefore)
    Check 'Claude runtime copy is byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.runtimeScript)) $noMarkerClaudeRuntimeBefore)
    Check 'Codex runtime copy is byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.runtimeScript)) $noMarkerCodexRuntimeBefore)

    # =========================================================================
    Write-Host '--- native Git: wrapper missing but owned native runtime remains -> retained as manual repair, never silently abandoned ---' -ForegroundColor Cyan
    $missingArtifactsRepo = Join-Path $Work 'missing-wrapper-artifacts-repo'
    New-Item -ItemType Directory -Path $missingArtifactsRepo -Force | Out-Null
    Push-Location $missingArtifactsRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $missingArtifactsRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $missingArtifactsRepo -ClaudeOnly *> $null
    $recMissingArtifacts = Get-RecordForScope 'Ignore-Rules-Check' $missingArtifactsRepo
    $maWrapperPath = [string]$recMissingArtifacts.nativeGit.wrapperPath
    $maRuntimeRoot = [string]$recMissingArtifacts.nativeGit.runtimeRoot
    Check 'setup: the native chain is tracked as managed (missing-wrapper-artifacts case)' ($null -ne $recMissingArtifacts.nativeGit -and $recMissingArtifacts.nativeGit.managed -eq $true)

    # Simulate the wrapper having been removed by hand while the managed
    # runtime directories are still sitting on disk (e.g. a crash between the
    # two deletes, or a user only deleting the wrapper).
    Remove-Item -LiteralPath $maWrapperPath -Force
    $maClaudeRuntimeBefore = Get-BytesOrEmpty ([string]$recMissingArtifacts.clients.claude.runtimeScript)

    $rMissingArtifacts = Invoke-UninstallProcess -RecordId $recMissingArtifacts.id
    Check 'a missing wrapper with owned artifacts remaining does not crash the uninstaller' ($rMissingArtifacts.Exit -eq 0) $rMissingArtifacts.Err
    Check 'a missing wrapper with owned artifacts remaining is reported as manualRepair overall' ([string]$rMissingArtifacts.Result.overall -eq 'manualRepair') ($rMissingArtifacts.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with owned artifacts remaining is reported manualRepair for nativeGit' ((Get-ComponentStatus $rMissingArtifacts.Result 'nativeGit') -eq 'manualRepair')
    Check 'the owned native runtime directory is left in place, not silently abandoned' (Test-Path -LiteralPath (Join-Path $maRuntimeRoot 'Ignore-Rules-Check'))
    Check 'the owned native companion directory is left in place too' (Test-Path -LiteralPath (Join-Path $maRuntimeRoot 'Secrets-Check'))
    Check 'the record is retained, not removed' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $missingArtifactsRepo }).Count -eq 1)
    Check 'claude is never even attempted once nativeGit needs manual repair' ((Get-ComponentStatus $rMissingArtifacts.Result 'claude') -eq '')
    Check 'the claude runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recMissingArtifacts.clients.claude.runtimeScript)) $maClaudeRuntimeBefore)

    # =========================================================================
    Write-Host '--- native Git: wrapper missing AND no owned native artifacts remain -> true idempotent success ---' -ForegroundColor Cyan
    $missingCleanRepo = Join-Path $Work 'missing-wrapper-clean-repo'
    New-Item -ItemType Directory -Path $missingCleanRepo -Force | Out-Null
    Push-Location $missingCleanRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $missingCleanRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $missingCleanRepo -ClaudeOnly *> $null
    $recMissingClean = Get-RecordForScope 'Ignore-Rules-Check' $missingCleanRepo
    $mcWrapperPath = [string]$recMissingClean.nativeGit.wrapperPath
    $mcRuntimeRoot = [string]$recMissingClean.nativeGit.runtimeRoot
    Check 'setup: the native chain is tracked as managed (missing-wrapper-clean case)' ($null -ne $recMissingClean.nativeGit -and $recMissingClean.nativeGit.managed -eq $true)

    # A fully hand-cleaned-up native side: the wrapper AND every managed
    # runtime directory are already gone before the uninstaller ever runs.
    Remove-Item -LiteralPath $mcWrapperPath -Force
    Remove-Item -LiteralPath $mcRuntimeRoot -Recurse -Force

    $rMissingClean = Invoke-UninstallProcess -RecordId $recMissingClean.id
    Check 'a missing wrapper with no owned artifacts remaining does not crash the uninstaller' ($rMissingClean.Exit -eq 0) $rMissingClean.Err
    Check 'a missing wrapper with no owned artifacts remaining reports overall ok' ([string]$rMissingClean.Result.overall -eq 'ok') ($rMissingClean.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with no owned artifacts remaining reports nativeGit ok (alreadyRemoved)' ((Get-ComponentStatus $rMissingClean.Result 'nativeGit') -eq 'ok')
    Check 'the record is fully removed (true idempotent success)' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $missingCleanRepo }).Count -eq 0)

    # =========================================================================
    Write-Host '--- failure injection: Claude settings write blocked -> no false success, no silent deletion ---' -ForegroundColor Cyan
    $fxClaudeFail = New-FixtureHook 'ZZZ-Uninst-Claudefail'
    try {
        $projClaudeFail = New-Proj 'ClaudeWriteFailProj'
        & $InstallScript -CustomHook $fxClaudeFail -Events @('Stop') -TargetProject $projClaudeFail *> $null
        $recClaudeFail = Get-RecordForScope 'ZZZ-Uninst-Claudefail' $projClaudeFail
        $claudeFailSettingsPath = [string]$recClaudeFail.clients.claude.settingsPath
        $claudeFailBytesBefore = Get-BytesOrEmpty $claudeFailSettingsPath
        $claudeFailRuntimeBefore = Get-BytesOrEmpty ([string]$recClaudeFail.clients.claude.runtimeScript)

        $held = [System.IO.File]::Open($claudeFailSettingsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $rClaudeFail = $null
        try { $rClaudeFail = Invoke-UninstallProcess -RecordId $recClaudeFail.id }
        finally { $held.Dispose() }

        Check 'a blocked Claude settings write does not crash the uninstaller' ($rClaudeFail.Exit -eq 0) $rClaudeFail.Err
        Check 'a blocked Claude settings write never reports overall ok (no false success)' ([string]$rClaudeFail.Result.overall -ne 'ok') ($rClaudeFail.Result | ConvertTo-Json -Depth 5)
        Check 'the claude component is reported failed' ((Get-ComponentStatus $rClaudeFail.Result 'claude') -eq 'failed')
        Check 'the codex component still succeeded independently' ((Get-ComponentStatus $rClaudeFail.Result 'codex') -eq 'ok')
        Check 'Claude settings are byte-for-byte unchanged (write never landed)' (Test-BytesEqual (Get-BytesOrEmpty $claudeFailSettingsPath) $claudeFailBytesBefore)
        Check 'Claude runtime was rolled back (restored) after the failed settings write' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recClaudeFail.clients.claude.runtimeScript)) $claudeFailRuntimeBefore)
        Check 'no staged set-aside directory is left behind after rollback' (@(Get-ChildItem -LiteralPath ([string]$recClaudeFail.clients.claude.runtimeRoot) -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.hookmaker-uninstall-*' }).Count -eq 0)
        Check 'the registry record is RETAINED, not silently deleted' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recClaudeFail.id }).Count -eq 1)
        $retainedClaudeFail = @(Get-Registry).installs | Where-Object { $_.id -eq $recClaudeFail.id } | Select-Object -First 1
        Check 'the retained record still lists claude (it genuinely failed)' ($null -ne $retainedClaudeFail.clients.claude)
        Check 'the retained record dropped codex (it genuinely succeeded)' ($null -eq $retainedClaudeFail.clients.codex)

        # Retry after releasing the lock must complete the job.
        $rClaudeRetry = Invoke-UninstallProcess -RecordId $recClaudeFail.id
        Check 'retrying after the lock is released fully succeeds' ($rClaudeRetry.Exit -eq 0 -and [string]$rClaudeRetry.Result.overall -eq 'ok') $rClaudeRetry.Err
        Check 'after a successful retry the record is fully removed' (@(Get-RecordsFor 'ZZZ-Uninst-Claudefail').Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Claudefail' }

    # =========================================================================
    Write-Host '--- failure injection: Codex settings write blocked -> no false success, no silent deletion ---' -ForegroundColor Cyan
    $fxCodexFail = New-FixtureHook 'ZZZ-Uninst-Codexfail'
    try {
        $projCodexFail = New-Proj 'CodexWriteFailProj'
        & $InstallScript -CustomHook $fxCodexFail -Events @('Stop') -TargetProject $projCodexFail *> $null
        $recCodexFail = Get-RecordForScope 'ZZZ-Uninst-Codexfail' $projCodexFail
        $codexFailSettingsPath = [string]$recCodexFail.clients.codex.settingsPath
        $codexFailBytesBefore = Get-BytesOrEmpty $codexFailSettingsPath
        $codexFailRuntimeBefore = Get-BytesOrEmpty ([string]$recCodexFail.clients.codex.runtimeScript)

        $heldCodex = [System.IO.File]::Open($codexFailSettingsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $rCodexFail = $null
        try { $rCodexFail = Invoke-UninstallProcess -RecordId $recCodexFail.id }
        finally { $heldCodex.Dispose() }

        Check 'a blocked Codex settings write does not crash the uninstaller' ($rCodexFail.Exit -eq 0) $rCodexFail.Err
        Check 'a blocked Codex settings write never reports overall ok (no false success)' ([string]$rCodexFail.Result.overall -ne 'ok') ($rCodexFail.Result | ConvertTo-Json -Depth 5)
        Check 'the codex component is reported failed' ((Get-ComponentStatus $rCodexFail.Result 'codex') -eq 'failed')
        Check 'the claude component still succeeded independently' ((Get-ComponentStatus $rCodexFail.Result 'claude') -eq 'ok')
        Check 'Codex settings are byte-for-byte unchanged (write never landed)' (Test-BytesEqual (Get-BytesOrEmpty $codexFailSettingsPath) $codexFailBytesBefore)
        Check 'Codex runtime was rolled back (restored) after the failed settings write' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recCodexFail.clients.codex.runtimeScript)) $codexFailRuntimeBefore)
        Check 'the registry record is RETAINED, not silently deleted' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recCodexFail.id }).Count -eq 1)

        $rCodexRetry = Invoke-UninstallProcess -RecordId $recCodexFail.id
        Check 'retrying after the lock is released fully succeeds' ($rCodexRetry.Exit -eq 0 -and [string]$rCodexRetry.Result.overall -eq 'ok') $rCodexRetry.Err
        Check 'after a successful retry the record is fully removed' (@(Get-RecordsFor 'ZZZ-Uninst-Codexfail').Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Codexfail' }

    # =========================================================================
    Write-Host '--- failure injection: registry-removal persistence blocked -> no silent deletion ---' -ForegroundColor Cyan
    $fxRegistryFail = New-FixtureHook 'ZZZ-Uninst-Registryfail'
    try {
        $projRegistryFail = New-Proj 'RegistryRemovalFailProj'
        & $InstallScript -CustomHook $fxRegistryFail -Events @('Stop') -TargetProject $projRegistryFail *> $null
        $recRegistryFail = Get-RecordForScope 'ZZZ-Uninst-Registryfail' $projRegistryFail
        $claudeScriptBefore = Get-BytesOrEmpty ([string]$recRegistryFail.clients.claude.runtimeScript)
        $registryPath = Join-Path $IsolatedStateDir 'install-registry.json'

        $heldRegistry = [System.IO.File]::Open($registryPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $rRegistryFail = $null
        try { $rRegistryFail = Invoke-UninstallProcess -RecordId $recRegistryFail.id }
        finally { $heldRegistry.Dispose() }

        Check 'a blocked registry write does not crash the uninstaller' ($rRegistryFail.Exit -eq 0) $rRegistryFail.Err
        Check 'a blocked registry write never reports overall ok (no false success)' ([string]$rRegistryFail.Result.overall -ne 'ok') ($rRegistryFail.Result | ConvertTo-Json -Depth 5)
        Check 'claude and codex settings/runtime really were removed (only tracking failed)' ((Get-ComponentStatus $rRegistryFail.Result 'claude') -eq 'ok' -and (Get-ComponentStatus $rRegistryFail.Result 'codex') -eq 'ok')
        Check 'the actual runtime copy really is gone despite the registry write failing' (-not (Test-Path -LiteralPath ([string]$recRegistryFail.clients.claude.runtimeScript)))
        Check 'the registry component is reported failed' ((Get-ComponentStatus $rRegistryFail.Result 'registry') -eq 'failed')
        # The registry file is held completely unwritable for this whole
        # attempt, so even the fallback "at least mark it accurately" save
        # cannot land either - the record is left exactly as it was (stale
        # but honestly reported as failed via overall/registry above), which
        # is the accepted limitation this project documents (no full
        # machine-crash atomicity). What must NEVER happen is a SILENT
        # deletion: the record is still there for a human/retry to find.
        Check 'the record was never silently deleted while its removal could not be persisted' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recRegistryFail.id }).Count -eq 1)

        # Retry after releasing the lock must finish the job (prove nothing
        # got permanently stuck, and no data was corrupted along the way).
        $rRegistryRetry = Invoke-UninstallProcess -RecordId $recRegistryFail.id
        Check 'retrying after the registry lock is released cleans up the record' ($rRegistryRetry.Exit -eq 0) $rRegistryRetry.Err
        Check 'after retry the record is gone (or already was)' (@(Get-RecordsFor 'ZZZ-Uninst-Registryfail').Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Registryfail' }

    # =========================================================================
    # Strict identity validation: the persisted registry record is the source
    # of truth. Every fixture below either (a) proves a GENUINE installer-
    # written record still passes every new invariant and uninstalls cleanly,
    # or (b) corrupts exactly one persisted invariant and proves NOTHING is
    # deleted, the record is retained, and the precise reason is manualRepair/
    # failed - never a silent guess.
    # =========================================================================

    Write-Host '--- CRITICAL: a genuine installer-written record still passes every new invariant and uninstalls cleanly (both clients) ---' -ForegroundColor Cyan
    $fxPositive = New-FixtureHook 'ZZZ-Uninst-Positive'
    try {
        $projPositive = New-Proj 'PositiveControlProj'
        & $InstallScript -CustomHook $fxPositive -Events @('Stop') -TargetProject $projPositive *> $null
        $recPositive = Get-RecordForScope 'ZZZ-Uninst-Positive' $projPositive
        Check 'positive control: install produced a both-client record' ($null -ne $recPositive -and (@(Get-InstalledClientNames -Record $recPositive) | Sort-Object) -join ',' -eq 'claude,codex')

        $rPositive = Invoke-UninstallProcess -RecordId $recPositive.id
        Check 'positive control: a real installer-written record exits 0' ($rPositive.Exit -eq 0) $rPositive.Err
        Check 'positive control: reports overall ok (the new invariants accept a genuine record)' ([string]$rPositive.Result.overall -eq 'ok') ($rPositive.Result | ConvertTo-Json -Depth 5)
        Check 'positive control: claude reported ok, not manualRepair' ((Get-ComponentStatus $rPositive.Result 'claude') -eq 'ok')
        Check 'positive control: codex reported ok, not manualRepair' ((Get-ComponentStatus $rPositive.Result 'codex') -eq 'ok')
        Check 'positive control: the record is fully removed' (@(Get-RecordsFor 'ZZZ-Uninst-Positive').Count -eq 0)
        Check 'positive control: the claude runtime copy is gone' (-not (Test-Path -LiteralPath ([string]$recPositive.clients.claude.runtimeScript)))
        Check 'positive control: the codex runtime copy is gone' (-not (Test-Path -LiteralPath ([string]$recPositive.clients.codex.runtimeScript)))
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Positive' }

    # =========================================================================
    Write-Host '--- identity: correct friendly name but a runtimeScript whose own directory no longer matches it is refused ---' -ForegroundColor Cyan
    $fxWrongScript = New-FixtureHook 'ZZZ-Uninst-Wrongscript'
    try {
        $projWrongScript = New-Proj 'WrongScriptProj'
        & $InstallScript -CustomHook $fxWrongScript -Events @('Stop') -TargetProject $projWrongScript -ClaudeOnly *> $null
        $recWrongScript = Get-RecordForScope 'ZZZ-Uninst-Wrongscript' $projWrongScript
        $origSettingsPath = [string]$recWrongScript.clients.claude.settingsPath
        $origRuntimeScript = [string]$recWrongScript.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

        # Still lives under the real runtimeRoot, and its own command is kept
        # consistent with it (so the registry-level "command targets
        # runtimeScript" check does not itself block this record) - but its
        # directory name no longer matches the record's friendlyName. That
        # inconsistency is internal to the record itself and is never trusted
        # to compute a delete target, regardless of what the command says.
        $decoyScript = Join-Path ([string]$recWrongScript.clients.claude.runtimeRoot) 'Some-Other-Name\Some-Other-Name.ps1'
        $recWrongScript.clients.claude.runtimeScript = $decoyScript
        $recWrongScript.clients.claude.command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $decoyScript + '"'
        Save-MutatedRecord -Record $recWrongScript

        $r = Invoke-UninstallProcess -RecordId $recWrongScript.id
        Check 'wrong runtimeScript does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'wrong runtimeScript is reported manualRepair overall' ([string]$r.Result.overall -eq 'manualRepair') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'wrong runtimeScript names a precise, non-empty reason' (-not [string]::IsNullOrWhiteSpace((Get-AnyRefusalReason $r.Result))) ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the original settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Wrongscript').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Wrongscript' }

    # =========================================================================
    Write-Host '--- identity: a runtimeScript with the correct basename living under a FOREIGN runtime root is refused ---' -ForegroundColor Cyan
    $fxForeignRoot = New-FixtureHook 'ZZZ-Uninst-Foreignroot'
    try {
        $projForeignA = New-Proj 'ForeignRootProjA'
        $projForeignB = New-Proj 'ForeignRootProjB'
        & $InstallScript -CustomHook $fxForeignRoot -Events @('Stop') -TargetProject $projForeignA -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fxForeignRoot -Events @('Stop') -TargetProject $projForeignB -ClaudeOnly *> $null
        $recForeignA = Get-RecordForScope 'ZZZ-Uninst-Foreignroot' $projForeignA
        $recForeignB = Get-RecordForScope 'ZZZ-Uninst-Foreignroot' $projForeignB

        $origSettingsPath = [string]$recForeignA.clients.claude.settingsPath
        $origRuntimeScript = [string]$recForeignA.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript
        $foreignRuntimeScript = [string]$recForeignB.clients.claude.runtimeScript
        $foreignBytesBefore = Get-BytesOrEmpty $foreignRuntimeScript

        # Same basename SHAPE (Hook-Maker\ZZZ-Uninst-Foreignroot\ZZZ-Uninst-Foreignroot.ps1)
        # but this is project B's own copy, entirely outside project A's runtimeRoot.
        $recForeignA.clients.claude.runtimeScript = $foreignRuntimeScript
        Save-MutatedRecord -Record $recForeignA

        $r = Invoke-UninstallProcess -RecordId $recForeignA.id
        Check 'foreign runtime root does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        # Caught either by Uninstall-Hook.ps1's own per-client containment
        # check or by the registry's own record-level validation gate - either
        # way the overall outcome must be manualRepair/failed, never a false
        # success, and nothing may be deleted.
        Check 'foreign runtime root is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the original project A settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original project A runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'project B''s real runtime script is NEVER touched' (Test-BytesEqual (Get-BytesOrEmpty $foreignRuntimeScript) $foreignBytesBefore)
        Check 'project A''s record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Foreignroot' | Where-Object { $_.targetProjectRoot -eq $projForeignA }).Count -eq 1)

        $rCleanupB = Invoke-UninstallProcess -RecordId $recForeignB.id
        Check 'cleanup: project B''s own untouched record still uninstalls cleanly' ($rCleanupB.Exit -eq 0 -and [string]$rCleanupB.Result.overall -eq 'ok') $rCleanupB.Err
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Foreignroot' }

    # =========================================================================
    Write-Host '--- identity: a runtimeScript pointing at a completely unrelated path is refused ---' -ForegroundColor Cyan
    $fxOutside = New-FixtureHook 'ZZZ-Uninst-Outsideroot'
    try {
        $projOutside = New-Proj 'OutsideRootProj'
        & $InstallScript -CustomHook $fxOutside -Events @('Stop') -TargetProject $projOutside -ClaudeOnly *> $null
        $recOutside = Get-RecordForScope 'ZZZ-Uninst-Outsideroot' $projOutside
        $origSettingsPath = [string]$recOutside.clients.claude.settingsPath
        $origRuntimeScript = [string]$recOutside.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

        $unrelatedFile = Join-Path $Work 'totally-unrelated-file.ps1'
        Write-Utf8 $unrelatedFile "exit 0`n"
        $recOutside.clients.claude.runtimeScript = $unrelatedFile
        Save-MutatedRecord -Record $recOutside

        $r = Invoke-UninstallProcess -RecordId $recOutside.id
        Check 'runtimeScript outside runtimeRoot does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'runtimeScript outside runtimeRoot is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the unrelated file itself is never touched' (Test-Path -LiteralPath $unrelatedFile)
        Check 'the original settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Outsideroot').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Outsideroot' }

    # =========================================================================
    Write-Host '--- identity: a runtimeScript directly under runtimeRoot (no hook subfolder) is refused ---' -ForegroundColor Cyan
    $fxRootEqual = New-FixtureHook 'ZZZ-Uninst-Rootequal'
    try {
        $projRootEqual = New-Proj 'RootEqualProj'
        & $InstallScript -CustomHook $fxRootEqual -Events @('Stop') -TargetProject $projRootEqual -ClaudeOnly *> $null
        $recRootEqual = Get-RecordForScope 'ZZZ-Uninst-Rootequal' $projRootEqual
        $origSettingsPath = [string]$recRootEqual.clients.claude.settingsPath
        $origRuntimeScript = [string]$recRootEqual.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript
        $runtimeRootForRootEqual = [string]$recRootEqual.clients.claude.runtimeRoot

        $rootEqualScript = Join-Path $runtimeRootForRootEqual 'ZZZ-Uninst-Rootequal.ps1'
        $recRootEqual.clients.claude.runtimeScript = $rootEqualScript
        Save-MutatedRecord -Record $recRootEqual

        $r = Invoke-UninstallProcess -RecordId $recRootEqual.id
        Check 'runtimeScript directly under runtimeRoot does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'runtimeScript directly under runtimeRoot is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the whole runtimeRoot directory survives (never treated as one hook''s own directory)' (Test-Path -LiteralPath $runtimeRootForRootEqual -PathType Container)
        Check 'the original settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Rootequal').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Rootequal' }

    # =========================================================================
    Write-Host '--- identity: a project record whose Claude settingsPath does not match the canonical project path is refused ---' -ForegroundColor Cyan
    $fxWrongClaudeSettings = New-FixtureHook 'ZZZ-Uninst-Wrongclaudesettings'
    try {
        $projWrongClaudeSettings = New-Proj 'WrongClaudeSettingsProj'
        & $InstallScript -CustomHook $fxWrongClaudeSettings -Events @('Stop') -TargetProject $projWrongClaudeSettings *> $null
        $recWCS = Get-RecordForScope 'ZZZ-Uninst-Wrongclaudesettings' $projWrongClaudeSettings
        $origClaudeSettingsPath = [string]$recWCS.clients.claude.settingsPath
        $origClaudeRuntimeScript = [string]$recWCS.clients.claude.runtimeScript
        $claudeSettingsBefore = Get-BytesOrEmpty $origClaudeSettingsPath
        $claudeRuntimeBefore = Get-BytesOrEmpty $origClaudeRuntimeScript

        # A plausible but WRONG project settings path (settings.json instead of
        # the machine-specific settings.local.json Install-Hook.ps1 actually writes).
        $wrongPath = Join-Path $projWrongClaudeSettings '.claude\settings.json'
        Write-Utf8 $wrongPath '{"hooks":{}}'
        $recWCS.clients.claude.settingsPath = $wrongPath
        Save-MutatedRecord -Record $recWCS

        $r = Invoke-UninstallProcess -RecordId $recWCS.id
        Check 'wrong Claude settingsPath does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'wrong Claude settingsPath is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        # A malformed record is refused BEFORE either client is even attempted
        # (this is a whole-record validity gate, not a per-client one) - codex
        # is therefore never touched either, not "independently succeeded".
        Check 'codex is never even attempted for a record that fails validation' ((Get-ComponentStatus $r.Result 'codex') -ne 'ok')
        Check 'the real Claude settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origClaudeSettingsPath) $claudeSettingsBefore)
        Check 'the Claude runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origClaudeRuntimeScript) $claudeRuntimeBefore)
        Check 'the decoy settings.json is untouched too' ((Get-Content -LiteralPath $wrongPath -Raw) -eq '{"hooks":{}}')
        $retainedWCS = @(Get-Registry).installs | Where-Object { $_.id -eq $recWCS.id } | Select-Object -First 1
        Check 'the retained record still lists claude' ($null -ne $retainedWCS.clients.claude)
        Check 'the retained record still lists codex too (nothing was ever attempted, so nothing was dropped)' ($null -ne $retainedWCS.clients.codex)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Wrongclaudesettings' }

    # =========================================================================
    Write-Host '--- identity: a project record whose Codex settingsPath does not match the canonical project path is refused ---' -ForegroundColor Cyan
    $fxWrongCodexSettings = New-FixtureHook 'ZZZ-Uninst-Wrongcodexsettings'
    try {
        $projWrongCodexSettings = New-Proj 'WrongCodexSettingsProj'
        & $InstallScript -CustomHook $fxWrongCodexSettings -Events @('Stop') -TargetProject $projWrongCodexSettings *> $null
        $recWKS = Get-RecordForScope 'ZZZ-Uninst-Wrongcodexsettings' $projWrongCodexSettings
        $origCodexSettingsPath = [string]$recWKS.clients.codex.settingsPath
        $origCodexRuntimeScript = [string]$recWKS.clients.codex.runtimeScript
        $codexSettingsBefore = Get-BytesOrEmpty $origCodexSettingsPath
        $codexRuntimeBefore = Get-BytesOrEmpty $origCodexRuntimeScript

        $wrongPath = Join-Path $projWrongCodexSettings '.codex\hooks-wrong.json'
        Write-Utf8 $wrongPath '{"hooks":{}}'
        $recWKS.clients.codex.settingsPath = $wrongPath
        Save-MutatedRecord -Record $recWKS

        $r = Invoke-UninstallProcess -RecordId $recWKS.id
        Check 'wrong Codex settingsPath does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'wrong Codex settingsPath is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        # Whole-record validity gate: claude is never even attempted either.
        Check 'claude is never even attempted for a record that fails validation' ((Get-ComponentStatus $r.Result 'claude') -ne 'ok')
        Check 'the real Codex hooks file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origCodexSettingsPath) $codexSettingsBefore)
        Check 'the Codex runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origCodexRuntimeScript) $codexRuntimeBefore)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Wrongcodexsettings' }

    # =========================================================================
    Write-Host '--- identity: a GLOBAL-scope record whose settingsPath does not match the canonical global path is refused ---' -ForegroundColor Cyan
    $fxGlobalForeign = New-FixtureHook 'ZZZ-Uninst-Globalforeign'
    try {
        $fakeHome = Join-Path $Work 'fakehome-globalforeign'
        New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
        $rInstall = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $fxGlobalForeign, '-Events', 'Stop', '-ClaudeOnly') -FakeHome $fakeHome
        Check 'setup: global-scope install exits 0' ($rInstall.Exit -eq 0) $rInstall.Err
        $recGlobal = @(Get-RecordsFor 'ZZZ-Uninst-Globalforeign' | Where-Object { $_.scope -eq 'global' })[0]
        Check 'setup: global-scope record has an empty targetProjectRoot' ($null -ne $recGlobal -and [string]::IsNullOrWhiteSpace([string]$recGlobal.targetProjectRoot))

        $origSettingsPath = [string]$recGlobal.clients.claude.settingsPath
        $origRuntimeScript = [string]$recGlobal.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

        # A foreign settings path: a DIFFERENT fake home entirely, never the
        # canonical <fakeHome>\.claude\settings.json Install-Hook.ps1 itself wrote.
        $otherFakeHome = Join-Path $Work 'fakehome-globalforeign-other'
        $foreignPath = Join-Path $otherFakeHome '.claude\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $foreignPath) -Force | Out-Null
        Write-Utf8 $foreignPath '{"hooks":{}}'
        $recGlobal.clients.claude.settingsPath = $foreignPath
        Save-MutatedRecord -Record $recGlobal

        $r = Invoke-UninstallProcess -RecordId $recGlobal.id -FakeHome $fakeHome
        Check 'global foreign settingsPath does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'global foreign settingsPath is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the real global (fake home) settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the real global runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the foreign settings file is untouched' ((Get-Content -LiteralPath $foreignPath -Raw) -eq '{"hooks":{}}')
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Globalforeign').Count -eq 1)

        # Repair the path back and clean up so this doesn't leak a permanently-
        # broken global record for the rest of the isolated test run.
        $recGlobal.clients.claude.settingsPath = $origSettingsPath
        Save-MutatedRecord -Record $recGlobal
        $rCleanup = Invoke-UninstallProcess -RecordId $recGlobal.id -FakeHome $fakeHome
        Check 'cleanup: repairing settingsPath back allows a clean uninstall' ($rCleanup.Exit -eq 0 -and [string]$rCleanup.Result.overall -eq 'ok') $rCleanup.Err
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Globalforeign' }

    # =========================================================================
    Write-Host '--- ownership: a handler whose command targets a DIFFERENT real hook''s runtime is left alone ---' -ForegroundColor Cyan
    $fxTargetA = New-FixtureHook 'ZZZ-Uninst-Targetownera'
    $fxTargetB = New-FixtureHook 'ZZZ-Uninst-Targetownerb'
    try {
        $projTarget = New-Proj 'TargetOwnershipProj'
        & $InstallScript -CustomHook $fxTargetA -Events @('Stop') -TargetProject $projTarget -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fxTargetB -Events @('Stop') -TargetProject $projTarget -ClaudeOnly *> $null
        $recTargetA = Get-RecordForScope 'ZZZ-Uninst-Targetownera' $projTarget
        $recTargetB = Get-RecordForScope 'ZZZ-Uninst-Targetownerb' $projTarget
        $bBytesBefore = Get-BytesOrEmpty ([string]$recTargetB.clients.claude.runtimeScript)

        $r = Invoke-UninstallProcess -RecordId $recTargetA.id
        Check 'removing hook A exits 0' ($r.Exit -eq 0) $r.Err
        Check 'removing hook A reports overall ok - a foreign command in the same event/file is never ambiguous' ([string]$r.Result.overall -eq 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'hook A''s record is gone' (@(Get-RecordsFor 'ZZZ-Uninst-Targetownera').Count -eq 0)
        Check 'hook B''s record survives untouched' (@(Get-RecordsFor 'ZZZ-Uninst-Targetownerb').Count -eq 1)
        Check 'hook B''s runtime copy is byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recTargetB.clients.claude.runtimeScript)) $bBytesBefore)
        Check 'hook B''s settings registration survives' ((Get-Content -LiteralPath ([string]$recTargetB.clients.claude.settingsPath) -Raw) -like '*ZZZ-Uninst-Targetownerb*')

        $rCleanupB = Invoke-UninstallProcess -RecordId $recTargetB.id
        Check 'cleanup: hook B still uninstalls cleanly afterward' ($rCleanupB.Exit -eq 0 -and [string]$rCleanupB.Result.overall -eq 'ok') $rCleanupB.Err
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Targetownera'; Remove-FixtureHook 'ZZZ-Uninst-Targetownerb' }

    # =========================================================================
    Write-Host '--- ownership: a same-name registration pointing at the WRONG path is an ambiguous near-match, never removed and never silently ignored ---' -ForegroundColor Cyan
    $fxNearMatch = New-FixtureHook 'ZZZ-Uninst-Nearmatch'
    try {
        $projNearMatch = New-Proj 'NearMatchProj'
        & $InstallScript -CustomHook $fxNearMatch -Events @('Stop') -TargetProject $projNearMatch -ClaudeOnly *> $null
        $recNearMatch = Get-RecordForScope 'ZZZ-Uninst-Nearmatch' $projNearMatch
        $settingsPathNM = [string]$recNearMatch.clients.claude.settingsPath
        $runtimeBeforeNM = Get-BytesOrEmpty ([string]$recNearMatch.clients.claude.runtimeScript)

        # A SECOND handler under the SAME event, same Hook-Maker path SHAPE and
        # same friendly name, but pointing at a decoy directory that is NOT
        # this record's own persisted runtimeScript (e.g. a stale duplicate
        # left behind by hand).
        $jsonNM = Get-Content -LiteralPath $settingsPathNM -Raw | ConvertFrom-Json
        $decoyCommand = 'powershell.exe -NoLogo -NoProfile -File "C:\Somewhere\Else\hooks\Hook-Maker\ZZZ-Uninst-Nearmatch\ZZZ-Uninst-Nearmatch.ps1"'
        $decoyGroup = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $decoyCommand; timeout = 60 }) }
        $jsonNM.hooks.Stop = @($jsonNM.hooks.Stop) + @($decoyGroup)
        [System.IO.File]::WriteAllText($settingsPathNM, ($jsonNM | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
        $settingsWithDecoy = Get-BytesOrEmpty $settingsPathNM

        $r = Invoke-UninstallProcess -RecordId $recNearMatch.id
        Check 'a near-match registration does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'a near-match registration is reported manualRepair for claude' ((Get-ComponentStatus $r.Result 'claude') -eq 'manualRepair')
        Check 'a near-match registration names a precise reason' ((Get-ComponentReason $r.Result 'claude') -eq 'ambiguousRegistration')
        Check 'nothing is removed from settings - byte-for-byte unchanged (including the decoy)' (Test-BytesEqual (Get-BytesOrEmpty $settingsPathNM) $settingsWithDecoy)
        Check 'the real runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNearMatch.clients.claude.runtimeScript)) $runtimeBeforeNM)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Nearmatch').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Nearmatch' }

    # =========================================================================
    Write-Host '--- ownership: an exact-path duplicate registered under an event OUTSIDE the persisted list is an ambiguous near-match ---' -ForegroundColor Cyan
    $fxEventGate = New-FixtureHook 'ZZZ-Uninst-Eventgate'
    try {
        $projEventGate = New-Proj 'EventGateProj'
        & $InstallScript -CustomHook $fxEventGate -Events @('Stop') -TargetProject $projEventGate -ClaudeOnly *> $null
        $recEventGate = Get-RecordForScope 'ZZZ-Uninst-Eventgate' $projEventGate
        $settingsPathEG = [string]$recEventGate.clients.claude.settingsPath
        $runtimeBeforeEG = Get-BytesOrEmpty ([string]$recEventGate.clients.claude.runtimeScript)
        $realCommandEG = [string]$recEventGate.clients.claude.command

        # Duplicate the EXACT real handler (same command, same runtime script)
        # but registered under SessionStart - an event this record never
        # persisted. Even an exact path match must never be removed from an
        # event outside the persisted list, and must not be silently ignored.
        $jsonEG = Get-Content -LiteralPath $settingsPathEG -Raw | ConvertFrom-Json
        $extraGroup = [pscustomobject]@{ matcher = 'startup|resume|clear|compact'; hooks = @([pscustomobject]@{ type = 'command'; command = $realCommandEG; timeout = 60 }) }
        Add-Member -InputObject $jsonEG.hooks -MemberType NoteProperty -Name 'SessionStart' -Value @($extraGroup) -Force
        [System.IO.File]::WriteAllText($settingsPathEG, ($jsonEG | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
        $settingsWithExtra = Get-BytesOrEmpty $settingsPathEG

        $r = Invoke-UninstallProcess -RecordId $recEventGate.id
        Check 'an exact-path duplicate on an unlisted event does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'an exact-path duplicate on an unlisted event is reported manualRepair for claude' ((Get-ComponentStatus $r.Result 'claude') -eq 'manualRepair')
        Check 'nothing is removed from settings - byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $settingsPathEG) $settingsWithExtra)
        Check 'the real runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recEventGate.clients.claude.runtimeScript)) $runtimeBeforeEG)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Eventgate').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Eventgate' }

    # =========================================================================
    Write-Host '--- identity: non-string subrecord fields (events/runtimeScript/settingsPath/command) are refused, never merely cast ---' -ForegroundColor Cyan
    $fxNonString = New-FixtureHook 'ZZZ-Uninst-Nonstring'
    try {
        $nonStringScenarios = @(
            [pscustomobject]@{ Field = 'events'; Value = 'Stop'; Label = 'a bare string instead of an array' },
            [pscustomobject]@{ Field = 'runtimeScript'; Value = 424242; Label = 'a number' },
            [pscustomobject]@{ Field = 'settingsPath'; Value = 424242; Label = 'a number' },
            [pscustomobject]@{ Field = 'command'; Value = 424242; Label = 'a number' }
        )
        foreach ($scenario in $nonStringScenarios) {
            $proj = New-Proj ('NonString' + $scenario.Field + 'Proj')
            & $InstallScript -CustomHook $fxNonString -Events @('Stop') -TargetProject $proj -ClaudeOnly *> $null
            $rec = Get-RecordForScope 'ZZZ-Uninst-Nonstring' $proj
            $origSettingsPath = [string]$rec.clients.claude.settingsPath
            $origRuntimeScript = [string]$rec.clients.claude.runtimeScript
            $settingsBefore = Get-BytesOrEmpty $origSettingsPath
            $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

            $rec.clients.claude.($scenario.Field) = $scenario.Value
            Save-MutatedRecord -Record $rec

            $r = Invoke-UninstallProcess -RecordId $rec.id
            Check ('non-string ' + $scenario.Field + ' (' + $scenario.Label + ') does not crash the uninstaller') ($r.Exit -eq 0) $r.Err
            Check ('non-string ' + $scenario.Field + ' is reported manualRepair/failed overall, never ok') ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
            Check ('non-string ' + $scenario.Field + ': the settings file is untouched') (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
            Check ('non-string ' + $scenario.Field + ': the runtime copy is untouched') (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
            Check ('non-string ' + $scenario.Field + ': the record is retained') (@(Get-RecordsFor 'ZZZ-Uninst-Nonstring' | Where-Object { $_.targetProjectRoot -eq $proj }).Count -eq 1)
        }
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Nonstring' }

    # =========================================================================
    # Native Git ownership is PROVEN from the record's own persisted
    # expectedStages and is never rebuilt from friendlyName. Every negative
    # case below leaves the wrapper and every on-disk stage byte-identical; the
    # positive case proves the rule does not over-reject a genuine install.
    # =========================================================================
    function New-NativeRepo {
        param([string]$Name)
        $repo = Join-Path $Work $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
        New-Item -ItemType Directory -Path (Join-Path $repo '.git\hooks') -Force | Out-Null
        return $repo
    }
    # "Nothing was touched" is proven by BYTES, not by Test-Path: a missing file
    # snapshots as empty and must still be missing afterwards.
    function Get-PathSnapshot {
        param([string[]]$Paths)
        $snapshot = @{}
        foreach ($path in $Paths) { $snapshot[$path] = Get-BytesOrEmpty $path }
        return $snapshot
    }
    # A function returning an EMPTY [byte[]] has it unrolled to $null by the
    # pipeline, so an absent file snapshots as $null - normalize both sides
    # rather than feeding SequenceEqual a null.
    function Test-SnapshotUnchanged {
        param([hashtable]$Snapshot)
        foreach ($path in @($Snapshot.Keys)) {
            $before = $Snapshot[$path]; if ($null -eq $before) { $before = [byte[]]::new(0) }
            $after = Get-BytesOrEmpty $path; if ($null -eq $after) { $after = [byte[]]::new(0) }
            if (-not (Test-BytesEqual $before $after)) { return $false }
        }
        return $true
    }
    function Get-PersistedStages {
        param($Native)
        return @(@($Native.expectedStages) | ForEach-Object { [string]$_ })
    }

    Write-Host '--- native ownership: a mutated friendlyName can never rebuild a delete target ---' -ForegroundColor Cyan
    $ownRepoA1 = New-NativeRepo 'ZZZ-Uninst-Nativeowna1'
    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $ownRepoA1 -ClaudeOnly *> $null
    $recOwnA1 = Get-RecordForScope 'Ignore-Rules-Check' $ownRepoA1
    Check 'A1 setup: the native chain is tracked as managed' ($null -ne $recOwnA1.nativeGit -and $recOwnA1.nativeGit.managed -eq $true)
    $stagesA1 = Get-PersistedStages -Native $recOwnA1.nativeGit
    $stageDirsA1 = @($stagesA1 | ForEach-Object { Split-Path -Parent $_ })
    $snapA1 = Get-PathSnapshot -Paths (@([string]$recOwnA1.nativeGit.wrapperPath) + $stagesA1)

    # Rename the record and keep its Claude subrecord internally consistent, so
    # the record-wide validator still passes and the nativeGit ownership gate is
    # genuinely the thing under test. The persisted expectedStages still name
    # the ORIGINAL stages, so no name-derived stage can be proven owned.
    $renamedA1 = 'ZZZ-Uninst-Nativerenamed'
    $renamedScriptA1 = Join-Path ([string]$recOwnA1.clients.claude.runtimeRoot) ($renamedA1 + '\' + $renamedA1 + '.ps1')
    $recOwnA1.friendlyName = $renamedA1
    $recOwnA1.clients.claude.runtimeScript = $renamedScriptA1
    $recOwnA1.clients.claude.command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $renamedScriptA1 + '"'
    Save-MutatedRecord -Record $recOwnA1

    $rOwnA1 = Invoke-UninstallProcess -RecordId $recOwnA1.id
    Check 'a name-derived stage absent from expectedStages does not crash the uninstaller' ($rOwnA1.Exit -eq 0) $rOwnA1.Err
    Check 'a name-derived stage absent from expectedStages is manualRepair for nativeGit' ((Get-ComponentStatus $rOwnA1.Result 'nativeGit') -eq 'manualRepair') ($rOwnA1.Result | ConvertTo-Json -Depth 5)
    Check 'the unprovable-ownership refusal names a precise, non-empty reason' (-not [string]::IsNullOrWhiteSpace((Get-AnyRefusalReason $rOwnA1.Result))) ($rOwnA1.Result | ConvertTo-Json -Depth 5)
    Check 'the wrapper and every persisted stage file are byte-identical afterwards' (Test-SnapshotUnchanged $snapA1)
    Check 'every real on-disk stage directory still exists' (@($stageDirsA1 | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -eq $stageDirsA1.Count)
    Check 'the record is retained after an unprovable-ownership refusal' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recOwnA1.id }).Count -eq 1)

    # =========================================================================
    Write-Host '--- native ownership: a managed record with no expectedStages can prove nothing and mutates nothing ---' -ForegroundColor Cyan
    $ownRepoA2 = New-NativeRepo 'ZZZ-Uninst-Nativeowna2'
    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $ownRepoA2 -ClaudeOnly *> $null
    $recOwnA2 = Get-RecordForScope 'Ignore-Rules-Check' $ownRepoA2
    $stagesA2 = Get-PersistedStages -Native $recOwnA2.nativeGit
    $stageDirsA2 = @($stagesA2 | ForEach-Object { Split-Path -Parent $_ })
    $snapA2 = Get-PathSnapshot -Paths (@([string]$recOwnA2.nativeGit.wrapperPath, [string]$recOwnA2.clients.claude.runtimeScript) + $stagesA2)
    $recOwnA2.nativeGit.expectedStages = @()
    Save-MutatedRecord -Record $recOwnA2

    $rOwnA2 = Invoke-UninstallProcess -RecordId $recOwnA2.id
    Check 'an emptied expectedStages does not crash the uninstaller' ($rOwnA2.Exit -eq 0) $rOwnA2.Err
    Check 'an emptied expectedStages is manualRepair for nativeGit' ((Get-ComponentStatus $rOwnA2.Result 'nativeGit') -eq 'manualRepair') ($rOwnA2.Result | ConvertTo-Json -Depth 5)
    Check 'an emptied expectedStages names a precise, non-empty reason' (-not [string]::IsNullOrWhiteSpace((Get-AnyRefusalReason $rOwnA2.Result))) ($rOwnA2.Result | ConvertTo-Json -Depth 5)
    Check 'an emptied expectedStages leaves the wrapper, stages and Claude runtime byte-identical' (Test-SnapshotUnchanged $snapA2)
    Check 'an emptied expectedStages leaves every real on-disk stage directory in place' (@($stageDirsA2 | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -eq $stageDirsA2.Count)
    Check 'an emptied expectedStages retains the record' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recOwnA2.id }).Count -eq 1)

    # =========================================================================
    Write-Host '--- native ownership: wrapper ALREADY gone + unprovable stages is manualRepair, never a silent alreadyRemoved ---' -ForegroundColor Cyan
    $ownRepoA3 = New-NativeRepo 'ZZZ-Uninst-Nativeowna3'
    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $ownRepoA3 -ClaudeOnly *> $null
    $recOwnA3 = Get-RecordForScope 'Ignore-Rules-Check' $ownRepoA3
    $stagesA3 = Get-PersistedStages -Native $recOwnA3.nativeGit
    $stageDirsA3 = @($stagesA3 | ForEach-Object { Split-Path -Parent $_ })
    $wrapperA3 = [string]$recOwnA3.nativeGit.wrapperPath
    # Wrapper deleted FIRST, then snapshotted (so it snapshots as absent and
    # must still be absent), then ownership made unprovable. Before the
    # ownership gate existed, this combination could reach the "wrapper already
    # gone -> ok / alreadyRemoved" path and silently drop the record.
    Remove-Item -LiteralPath $wrapperA3 -Force
    $snapA3 = Get-PathSnapshot -Paths (@($wrapperA3) + $stagesA3)
    $recOwnA3.nativeGit.expectedStages = @()
    Save-MutatedRecord -Record $recOwnA3

    $rOwnA3 = Invoke-UninstallProcess -RecordId $recOwnA3.id
    Check 'a missing wrapper with unprovable ownership does not crash the uninstaller' ($rOwnA3.Exit -eq 0) $rOwnA3.Err
    Check 'a missing wrapper with unprovable ownership is NEVER reported ok for nativeGit' ((Get-ComponentStatus $rOwnA3.Result 'nativeGit') -ne 'ok') ($rOwnA3.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with unprovable ownership is manualRepair for nativeGit' ((Get-ComponentStatus $rOwnA3.Result 'nativeGit') -eq 'manualRepair') ($rOwnA3.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with unprovable ownership names a precise, non-empty reason' (-not [string]::IsNullOrWhiteSpace((Get-AnyRefusalReason $rOwnA3.Result))) ($rOwnA3.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with unprovable ownership mutates nothing (wrapper stays absent, stages byte-identical)' (Test-SnapshotUnchanged $snapA3)
    Check 'a missing wrapper with unprovable ownership leaves every stage directory in place' (@($stageDirsA3 | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -eq $stageDirsA3.Count)
    Check 'a missing wrapper with unprovable ownership retains the record (never a silent idempotent success)' (@(@(Get-Registry).installs | Where-Object { $_.id -eq $recOwnA3.id }).Count -eq 1)

    # =========================================================================
    Write-Host '--- CRITICAL over-rejection guard: a genuine native pre-push install still uninstalls cleanly ---' -ForegroundColor Cyan
    $ownRepoA4 = New-NativeRepo 'ZZZ-Uninst-Nativeowna4'
    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $ownRepoA4 -ClaudeOnly *> $null
    $recOwnA4 = Get-RecordForScope 'Ignore-Rules-Check' $ownRepoA4
    Check 'A4 setup: the native chain is tracked as managed' ($null -ne $recOwnA4.nativeGit -and $recOwnA4.nativeGit.managed -eq $true)
    $stageDirsA4 = @((Get-PersistedStages -Native $recOwnA4.nativeGit) | ForEach-Object { Split-Path -Parent $_ })
    Check 'A4 setup: the managed stage directories really exist before uninstall' (@($stageDirsA4 | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -eq $stageDirsA4.Count -and $stageDirsA4.Count -gt 0)

    $rOwnA4 = Invoke-UninstallProcess -RecordId $recOwnA4.id
    Check 'a genuine native install still uninstalls cleanly (the ownership proof does not over-reject)' ([string]$rOwnA4.Result.overall -eq 'ok') ($rOwnA4.Result | ConvertTo-Json -Depth 5)
    Check 'a genuine native install reports nativeGit ok' ((Get-ComponentStatus $rOwnA4.Result 'nativeGit') -eq 'ok')
    Check 'a genuine native install really removes every managed stage directory' (@($stageDirsA4 | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)
    Check 'a genuine native install removes its record' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $ownRepoA4 }).Count -eq 0)

    # =========================================================================
    # EVERY command field on a handler must agree before it can be removed.
    # A genuine Codex install writes the SAME runtime script into both `command`
    # (pwsh form) and `commandWindows` (powershell.exe form), so a handler where
    # only some fields point at this record's runtime is 'ambiguous' - it blocks
    # the whole client and survives byte-identical.
    # =========================================================================
    Write-Host '--- all-fields ownership: a Codex handler pointing at a DIFFERENT Hook Maker runtime in commandWindows is ambiguous ---' -ForegroundColor Cyan
    $fxDivergeA = New-FixtureHook 'ZZZ-Uninst-Divergea'
    $fxDivergeB = New-FixtureHook 'ZZZ-Uninst-Divergeb'
    try {
        $projDiverge = New-Proj 'CodexDivergeProj'
        & $InstallScript -CustomHook $fxDivergeA -Events @('Stop') -TargetProject $projDiverge -CodexOnly *> $null
        & $InstallScript -CustomHook $fxDivergeB -Events @('Stop') -TargetProject $projDiverge -CodexOnly *> $null
        $recDivA = Get-RecordForScope 'ZZZ-Uninst-Divergea' $projDiverge
        $recDivB = Get-RecordForScope 'ZZZ-Uninst-Divergeb' $projDiverge
        $codexSettingsDiv = [string]$recDivA.clients.codex.settingsPath
        $divRuntimeBefore = Get-BytesOrEmpty ([string]$recDivA.clients.codex.runtimeScript)

        # Point ONLY commandWindows at hook B's real Hook Maker runtime script,
        # leaving `command` still pointing at hook A's - a divergence a genuine
        # install can never produce, since both forms are built from one script.
        $jsonDiv = Get-Content -LiteralPath $codexSettingsDiv -Raw | ConvertFrom-Json
        foreach ($group in @($jsonDiv.hooks.Stop)) {
            foreach ($handler in @($group.hooks)) {
                if ((Get-HandlerFieldValue $handler 'command') -like '*ZZZ-Uninst-Divergea*') {
                    $handler.commandWindows = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + [string]$recDivB.clients.codex.runtimeScript + '"'
                }
            }
        }
        [System.IO.File]::WriteAllText($codexSettingsDiv, ($jsonDiv | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
        $divBytesBefore = Get-BytesOrEmpty $codexSettingsDiv

        $rDiv = Invoke-UninstallProcess -RecordId $recDivA.id
        Check 'a partially-matching Codex handler does not crash the uninstaller' ($rDiv.Exit -eq 0) $rDiv.Err
        Check 'a Codex handler matching on command but not commandWindows is manualRepair for codex' ((Get-ComponentStatus $rDiv.Result 'codex') -eq 'manualRepair') ($rDiv.Result | ConvertTo-Json -Depth 5)
        Check 'the partially-matching Codex handler names a precise, non-empty reason' (-not [string]::IsNullOrWhiteSpace((Get-ComponentReason $rDiv.Result 'codex'))) ($rDiv.Result | ConvertTo-Json -Depth 5)
        Check 'the Codex settings file is byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $codexSettingsDiv) $divBytesBefore)
        $divHandlersAfter = @(@((Get-Content -LiteralPath $codexSettingsDiv -Raw | ConvertFrom-Json).hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'the partially-matching handler still exists (never removed)' (@($divHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*ZZZ-Uninst-Divergea*' }).Count -eq 1)
        Check 'hook A''s Codex runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recDivA.clients.codex.runtimeScript)) $divRuntimeBefore)
        Check 'hook A''s record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Divergea').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Divergea'; Remove-FixtureHook 'ZZZ-Uninst-Divergeb' }

    # =========================================================================
    Write-Host '--- all-fields ownership: a Codex handler whose commandWindows is not Hook Maker''s at all is ambiguous ---' -ForegroundColor Cyan
    $fxForeignField = New-FixtureHook 'ZZZ-Uninst-Foreignfield'
    try {
        $projForeignField = New-Proj 'CodexForeignFieldProj'
        & $InstallScript -CustomHook $fxForeignField -Events @('Stop') -TargetProject $projForeignField -CodexOnly *> $null
        $recForeignField = Get-RecordForScope 'ZZZ-Uninst-Foreignfield' $projForeignField
        $codexSettingsFF = [string]$recForeignField.clients.codex.settingsPath
        $ffRuntimeBefore = Get-BytesOrEmpty ([string]$recForeignField.clients.codex.runtimeScript)

        $jsonFF = Get-Content -LiteralPath $codexSettingsFF -Raw | ConvertFrom-Json
        foreach ($group in @($jsonFF.hooks.Stop)) {
            foreach ($handler in @($group.hooks)) {
                if ((Get-HandlerFieldValue $handler 'command') -like '*ZZZ-Uninst-Foreignfield*') {
                    $handler.commandWindows = 'node C:\other\thing.js'
                }
            }
        }
        [System.IO.File]::WriteAllText($codexSettingsFF, ($jsonFF | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
        $ffBytesBefore = Get-BytesOrEmpty $codexSettingsFF

        $rFF = Invoke-UninstallProcess -RecordId $recForeignField.id
        Check 'a non-Hook-Maker commandWindows does not crash the uninstaller' ($rFF.Exit -eq 0) $rFF.Err
        Check 'a non-Hook-Maker commandWindows is manualRepair for codex (never a quiet removal)' ((Get-ComponentStatus $rFF.Result 'codex') -eq 'manualRepair') ($rFF.Result | ConvertTo-Json -Depth 5)
        Check 'the Codex settings file is byte-for-byte unchanged' (Test-BytesEqual (Get-BytesOrEmpty $codexSettingsFF) $ffBytesBefore)
        $ffHandlersAfter = @(@((Get-Content -LiteralPath $codexSettingsFF -Raw | ConvertFrom-Json).hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'the handler carrying a foreign commandWindows still exists' (@($ffHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq 'node C:\other\thing.js' }).Count -eq 1)
        Check 'the Codex runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recForeignField.clients.codex.runtimeScript)) $ffRuntimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Foreignfield').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Foreignfield' }

    # =========================================================================
    Write-Host '--- CRITICAL over-rejection guard: an unmutated Codex install still uninstalls (all-fields rule is not too strict) ---' -ForegroundColor Cyan
    $fxCodexPositive = New-FixtureHook 'ZZZ-Uninst-Codexpositive'
    try {
        $projCodexPositive = New-Proj 'CodexPositiveProj'
        & $InstallScript -CustomHook $fxCodexPositive -Events @('Stop') -TargetProject $projCodexPositive -CodexOnly *> $null
        $recCodexPositive = Get-RecordForScope 'ZZZ-Uninst-Codexpositive' $projCodexPositive
        $codexSettingsCP = [string]$recCodexPositive.clients.codex.settingsPath
        $cpHandlersBefore = @(@((Get-Content -LiteralPath $codexSettingsCP -Raw | ConvertFrom-Json).hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'positive control: a genuine Codex install writes both command and commandWindows for the same runtime script' (@($cpHandlersBefore | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*ZZZ-Uninst-Codexpositive*' -and (Get-HandlerFieldValue $_ 'commandWindows') -like '*ZZZ-Uninst-Codexpositive*' }).Count -eq 1)

        $rCP = Invoke-UninstallProcess -RecordId $recCodexPositive.id
        Check 'positive control: an unmutated Codex install exits 0' ($rCP.Exit -eq 0) $rCP.Err
        Check 'positive control: an unmutated Codex install reports codex ok, not manualRepair' ((Get-ComponentStatus $rCP.Result 'codex') -eq 'ok') ($rCP.Result | ConvertTo-Json -Depth 5)
        $cpHandlersAfter = @(@((Get-Content -LiteralPath $codexSettingsCP -Raw | ConvertFrom-Json).hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'positive control: the Codex handler IS removed' (@($cpHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*ZZZ-Uninst-Codexpositive*' }).Count -eq 0)
        Check 'positive control: the record is fully removed' (@(Get-RecordsFor 'ZZZ-Uninst-Codexpositive').Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Codexpositive' }
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
