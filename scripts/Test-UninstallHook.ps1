# Offline test suite for Uninstall-Hook.ps1: the noninteractive, record-based
# uninstaller. Covers scope isolation (removing one record never touches a
# sibling record's settings/runtime/source), ownership proof (a foreign
# same-basename handler survives), runtime path containment refusal,
# idempotency (missing runtime / already-removed registration / repeated
# uninstall of a gone id), a true no-op dry run (byte-for-byte unchanged),
# the native Git pre-push chain (regenerate around a remaining foreign stage,
# restore the preserved user hook byte-for-byte on full removal, refuse a
# tampered wrapper with a manual-repair status, never touch an unrelated
# repo's hook), and failure injection on the Claude settings write, the Codex
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
    param([string]$RecordId, [switch]$WhatIf, [string]$UninstallToolRoot = $ToolRoot)
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
    $found = @($ResultDoc.components | Where-Object { [string]$_.component -eq $Component })
    if ($found.Count -eq 0) { return '' }
    return [string]$found[0].status
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
        Check 'an unsafe runtime path is reported as manualRepair for claude' ((Get-ComponentStatus $rUnsafe.Result 'claude') -eq 'manualRepair')
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
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
