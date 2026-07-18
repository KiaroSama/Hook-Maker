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
# Read-InstallRegistry/Save-InstallRegistry/Set-InstallRecord/Get-InstallRecordId
# are called directly in this suite (not only via the wizard/installer).
. $HookLib

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-registrytest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

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
    # =====================================================================
    Write-Host '--- a successful install creates a valid registry entry ---' -ForegroundColor Cyan
    $fixture1 = New-FixtureHook 'ZZZ-Regtest-Basic'
    try {
        $proj1 = New-Proj 'BasicInstall'
        & $InstallScript -CustomHook $fixture1 -Events @('SessionStart', 'Stop') -TargetProject $proj1 *> $null
        $recs1 = Get-RecordsFor 'ZZZ-Regtest-Basic'
        Check 'exactly one install record exists for this fixture' ($recs1.Count -eq 1)
        $rec = $recs1[0]
        Check 'record has a non-empty id' (-not [string]::IsNullOrWhiteSpace([string]$rec.id))
        Check 'record friendlyName matches the fixture' ([string]$rec.friendlyName -eq 'ZZZ-Regtest-Basic')
        Check 'record hookType is CustomHook' ([string]$rec.hookType -eq 'CustomHook')
        Check 'record scope is project' ([string]$rec.scope -eq 'project')
        Check 'record targetProjectRoot matches' ([string]$rec.targetProjectRoot -eq $proj1)
        Check 'record events match what was installed' (@(@($rec.events) | Sort-Object) -join ',' -eq 'SessionStart,Stop')
        Check 'record clients is Both (neither -ClaudeOnly nor -CodexOnly)' ([string]$rec.clients -eq 'Both')
        Check 'record has a non-empty sourceHash' (-not [string]::IsNullOrWhiteSpace([string]$rec.sourceHash))
        Check 'record has createdUtc and lastInstalledUtc' (-not [string]::IsNullOrWhiteSpace([string]$rec.createdUtc) -and -not [string]::IsNullOrWhiteSpace([string]$rec.lastInstalledUtc))
        Check 'record has a bounded history with one entry' (@($rec.history).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Basic' }

    # =====================================================================
    Write-Host '--- reinstalling the same logical hook updates, never duplicates ---' -ForegroundColor Cyan
    $fixture2 = New-FixtureHook 'ZZZ-Regtest-Reinstall' "exit 0 # v1`n"
    try {
        $proj2 = New-Proj 'ReinstallSame'
        & $InstallScript -CustomHook $fixture2 -Events @('Stop') -TargetProject $proj2 *> $null
        $recFirst = (Get-RecordsFor 'ZZZ-Regtest-Reinstall')[0]
        $idFirst = [string]$recFirst.id
        $createdFirst = [string]$recFirst.createdUtc
        $hashFirst = [string]$recFirst.sourceHash
        Write-Utf8 $fixture2 "exit 0 # v2 changed`n"
        & $InstallScript -CustomHook $fixture2 -Events @('Stop') -TargetProject $proj2 *> $null
        $recsSecond = Get-RecordsFor 'ZZZ-Regtest-Reinstall'
        Check 'still exactly one record after reinstalling the same hook/scope' ($recsSecond.Count -eq 1)
        $recSecond = $recsSecond[0]
        Check 'the id is unchanged across reinstall' ([string]$recSecond.id -eq $idFirst)
        Check 'createdUtc is preserved (not reset) across reinstall' ([string]$recSecond.createdUtc -eq $createdFirst)
        Check 'sourceHash reflects the NEW content after reinstall' ([string]$recSecond.sourceHash -ne $hashFirst)
        Check 'history grew to two entries (bounded, not unbounded)' (@($recSecond.history).Count -eq 2)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Reinstall' }

    # =====================================================================
    Write-Host '--- Claude-only / Codex-only / Both / project / global are represented correctly ---' -ForegroundColor Cyan
    $fixture3 = New-FixtureHook 'ZZZ-Regtest-Scopes'
    try {
        $projClaude = New-Proj 'ScopeClaudeOnly'
        & $InstallScript -CustomHook $fixture3 -Events @('SessionStart') -TargetProject $projClaude -ClaudeOnly *> $null
        $recClaude = @(Get-RecordsFor 'ZZZ-Regtest-Scopes' | Where-Object { $_.targetProjectRoot -eq $projClaude })[0]
        Check 'Claude-only record reports clients=Claude' ([string]$recClaude.clients -eq 'Claude')
        Check 'Claude-only record has a claudeRuntimeScript, no codexRuntimeScript' (-not [string]::IsNullOrWhiteSpace([string]$recClaude.claudeRuntimeScript) -and [string]::IsNullOrWhiteSpace([string]$recClaude.codexRuntimeScript))

        $projCodex = New-Proj 'ScopeCodexOnly'
        & $InstallScript -CustomHook $fixture3 -Events @('SessionStart') -TargetProject $projCodex -CodexOnly *> $null
        $recCodex = @(Get-RecordsFor 'ZZZ-Regtest-Scopes' | Where-Object { $_.targetProjectRoot -eq $projCodex })[0]
        Check 'Codex-only record reports clients=Codex' ([string]$recCodex.clients -eq 'Codex')
        Check 'Codex-only record has a codexRuntimeScript, no claudeRuntimeScript' (-not [string]::IsNullOrWhiteSpace([string]$recCodex.codexRuntimeScript) -and [string]::IsNullOrWhiteSpace([string]$recCodex.claudeRuntimeScript))

        $projBoth = New-Proj 'ScopeBoth'
        & $InstallScript -CustomHook $fixture3 -Events @('SessionStart') -TargetProject $projBoth *> $null
        $recBoth = @(Get-RecordsFor 'ZZZ-Regtest-Scopes' | Where-Object { $_.targetProjectRoot -eq $projBoth })[0]
        Check 'default (no client switch) record reports clients=Both' ([string]$recBoth.clients -eq 'Both')
        Check 'Both record has both runtime script paths' (-not [string]::IsNullOrWhiteSpace([string]$recBoth.claudeRuntimeScript) -and -not [string]::IsNullOrWhiteSpace([string]$recBoth.codexRuntimeScript))

        # Global scope (-no TargetProject) reads $HOME once at process start, so
        # it must be a real spawned process with USERPROFILE overridden for it.
        $fakeHome = Join-Path $Work 'fakehome'
        New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
        $rGlobal = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $fixture3, '-Events', 'SessionStart', '-ClaudeOnly') -FakeHome $fakeHome
        Check 'global-scope install process exits 0' ($rGlobal.Exit -eq 0) $rGlobal.Err
        $recGlobal = @(Get-RecordsFor 'ZZZ-Regtest-Scopes' | Where-Object { $_.scope -eq 'global' })[0]
        Check 'global-scope install (-no TargetProject) records scope=global with an empty targetProjectRoot' ($null -ne $recGlobal -and [string]$recGlobal.scope -eq 'global' -and [string]::IsNullOrWhiteSpace([string]$recGlobal.targetProjectRoot))
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Scopes' }

    # =====================================================================
    Write-Host '--- sync-engine installs are tracked as hookType=Engine with profile+configPath ---' -ForegroundColor Cyan
    $engineProj1 = New-Proj 'EngineA'; $engineProj2 = New-Proj 'EngineB'
    New-Item -ItemType Directory -Path (Join-Path $engineProj1 '.ai'), (Join-Path $engineProj2 '.ai') -Force | Out-Null
    $engineCfg = Join-Path $Work 'engine-sync-hooks.json'
    $engineProfileId = 'sync-group-registrytest01'
    $engineConfigObj = [pscustomobject]@{
        version  = 2
        defaults = [pscustomobject]@{ events = @('SessionStart', 'UserPromptSubmit') }
        profiles = @([pscustomobject]@{
            id = $engineProfileId; name = 'Test engine profile'; enabled = $true
            routes = @([pscustomobject]@{
                id = 'a-to-b'; enabled = $true
                source = [pscustomobject]@{ name = 'A'; root = $engineProj1; directory = '.ai'; aliases = @() }
                destination = [pscustomobject]@{ name = 'B'; root = $engineProj2; directory = '.ai'; aliases = @() }
            })
        })
    }
    ($engineConfigObj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $engineCfg -Encoding utf8
    & $InstallScript -Profile $engineProfileId -ConfigPath $engineCfg -TargetProject $engineProj1 -Events @('SessionStart', 'UserPromptSubmit') *> $null
    $recEngine = @((Get-Registry).installs | Where-Object { $_.targetProjectRoot -eq $engineProj1 })[0]
    Check 'engine install record has hookType=Engine' ($null -ne $recEngine -and [string]$recEngine.hookType -eq 'Engine')
    Check 'engine install record stores the profile id' ([string]$recEngine.profile -eq $engineProfileId)
    Check 'engine install record stores the configPath' ([string]$recEngine.configPath -eq $engineCfg)
    Check 'engine install record has a non-empty configHash' (-not [string]::IsNullOrWhiteSpace([string]$recEngine.configHash))

    # =====================================================================
    Write-Host '--- the updater refreshes a changed source byte-for-byte and preserves registration semantics ---' -ForegroundColor Cyan
    $fixture4 = New-FixtureHook 'ZZZ-Regtest-Update' "exit 0 # original`n"
    try {
        $proj4 = New-Proj 'UpdateRefresh'
        & $InstallScript -CustomHook $fixture4 -Events @('SessionStart', 'Stop') -TargetProject $proj4 *> $null
        $recBefore = (Get-RecordsFor 'ZZZ-Regtest-Update')[0]
        Check 'baseline install for the update test is tracked' ($null -ne $recBefore)

        Write-Utf8 $fixture4 "exit 0 # changed-content`n"
        $installedCopyClaude = Join-Path $proj4 '.claude\hooks\Hook-Maker\ZZZ-Regtest-Update\ZZZ-Regtest-Update.ps1'
        $hashBeforeUpdate = (Get-FileHash -LiteralPath $installedCopyClaude -Algorithm SHA256).Hash
        $sourceHashAfterEdit = (Get-FileHash -LiteralPath $fixture4 -Algorithm SHA256).Hash
        Check 'installed copy differs from the newly-edited source before updating' ($hashBeforeUpdate -ne $sourceHashAfterEdit)

        # main '1' -> "Create or install a hook" -> submenu '4' -> Update
        # previously installed hooks -> something needs updating, so ONE
        # confirm is asked (blank = default y) -> back to main menu -> '0' exits.
        $cfgU = Join-Path $Work 'cfg-run-update.json'; New-Config $cfgU
        $rUpdate = Invoke-Wizard -Config $cfgU -Answers @('1', '4', '', '0')
        Check 'exit 0 (update previously installed hooks)' ($rUpdate.Exit -eq 0) $rUpdate.Err
        Check 'the plan lists the changed fixture as needing an update' ($rUpdate.Out -match 'ZZZ-Regtest-Update[\s\S]*?source changed since last install') $rUpdate.Out

        $hashAfterUpdate = (Get-FileHash -LiteralPath $installedCopyClaude -Algorithm SHA256).Hash
        Check 'the installed copy now matches the edited source byte-for-byte' ($hashAfterUpdate -eq $sourceHashAfterEdit)

        $recAfter = (Get-RecordsFor 'ZZZ-Regtest-Update')[0]
        Check 'events are preserved across the update' (@(@($recAfter.events) | Sort-Object) -join ',' -eq (@(@($recBefore.events) | Sort-Object) -join ','))
        Check 'client selection is preserved across the update' ([string]$recAfter.clients -eq [string]$recBefore.clients)
        Check 'target project is preserved across the update' ([string]$recAfter.targetProjectRoot -eq [string]$recBefore.targetProjectRoot)
        Check 'scope is preserved across the update' ([string]$recAfter.scope -eq [string]$recBefore.scope)

        # ---- second run: idempotent, reports up to date ----
        # Nothing needs updating this time, so Invoke-UpdateInstalledHooks
        # returns immediately - no confirm prompt is shown.
        $cfgU2 = Join-Path $Work 'cfg-run-update-2.json'; New-Config $cfgU2
        $rUpdate2 = Invoke-Wizard -Config $cfgU2 -Answers @('1', '4', '0')
        Check 'second update run reports the fixture as up to date (idempotent)' ($rUpdate2.Out -match 'ZZZ-Regtest-Update[\s\S]*?up to date') $rUpdate2.Out
        Check 'second run never claims a further update was applied to the fixture' ($rUpdate2.Out -notmatch 'ZZZ-Regtest-Update[\s\S]*?source changed since last install') $rUpdate2.Out
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Update' }

    # =====================================================================
    Write-Host '--- a hook that was never installed is never added by the updater ---' -ForegroundColor Cyan
    $fixtureNever = New-FixtureHook 'ZZZ-Regtest-Neverinstalled'
    $fixtureInstalled = New-FixtureHook 'ZZZ-Regtest-Onlythisinstalled'
    try {
        $projNever = New-Proj 'NeverInstalledProj'
        & $InstallScript -CustomHook $fixtureInstalled -Events @('SessionStart') -TargetProject $projNever *> $null
        $cfgNever = Join-Path $Work 'cfg-never.json'; New-Config $cfgNever
        $rNever = Invoke-Wizard -Config $cfgNever -Answers @('1', '4', '0')
        Check 'the never-installed fixture never appears in the update plan' ($rNever.Out -notmatch 'ZZZ-Regtest-Neverinstalled') $rNever.Out
        $claudeNeverJson = ''
        if (Test-Path (Join-Path $projNever '.claude\settings.local.json')) { $claudeNeverJson = [System.IO.File]::ReadAllText((Join-Path $projNever '.claude\settings.local.json')) }
        Check 'the never-installed fixture was never written into any settings file' ($claudeNeverJson -notmatch 'ZZZ-Regtest-Neverinstalled')
    }
    finally {
        Remove-FixtureHook 'ZZZ-Regtest-Neverinstalled'
        Remove-FixtureHook 'ZZZ-Regtest-Onlythisinstalled'
    }

    # =====================================================================
    Write-Host '--- missing source / missing target are reported and skipped, never destructive ---' -ForegroundColor Cyan
    $fixtureMissingSrc = New-FixtureHook 'ZZZ-Regtest-Missingsource'
    $missingSrcInstalled = $false
    try {
        $projMissingSrc = New-Proj 'MissingSourceProj'
        & $InstallScript -CustomHook $fixtureMissingSrc -Events @('SessionStart') -TargetProject $projMissingSrc *> $null
        $missingSrcInstalled = $true
        Remove-FixtureHook 'ZZZ-Regtest-Missingsource'
        $missingSrcInstalled = $false
        $cfgMissingSrc = Join-Path $Work 'cfg-missing-src.json'; New-Config $cfgMissingSrc
        $rMissingSrc = Invoke-Wizard -Config $cfgMissingSrc -Answers @('1', '4', '0')
        Check 'exit 0 (missing source is reported, not a crash)' ($rMissingSrc.Exit -eq 0) $rMissingSrc.Err
        Check 'missing source is reported by name' ($rMissingSrc.Out -match 'ZZZ-Regtest-Missingsource[\s\S]*?source script no longer found') $rMissingSrc.Out
    }
    finally { if ($missingSrcInstalled) { Remove-FixtureHook 'ZZZ-Regtest-Missingsource' } }

    $fixtureMissingTgt = New-FixtureHook 'ZZZ-Regtest-Missingtarget'
    try {
        $projMissingTgt = New-Proj 'MissingTargetProj'
        & $InstallScript -CustomHook $fixtureMissingTgt -Events @('SessionStart') -TargetProject $projMissingTgt *> $null
        Remove-Item -LiteralPath $projMissingTgt -Recurse -Force -ErrorAction SilentlyContinue
        $cfgMissingTgt = Join-Path $Work 'cfg-missing-tgt.json'; New-Config $cfgMissingTgt
        $rMissingTgt = Invoke-Wizard -Config $cfgMissingTgt -Answers @('1', '4', '0')
        Check 'exit 0 (missing target is reported, not a crash)' ($rMissingTgt.Exit -eq 0) $rMissingTgt.Err
        Check 'missing target is reported by name' ($rMissingTgt.Out -match 'ZZZ-Regtest-Missingtarget[\s\S]*?target project no longer found') $rMissingTgt.Out
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Missingtarget' }

    # =====================================================================
    Write-Host '--- unrelated JSON keys/handlers are preserved by an update ---' -ForegroundColor Cyan
    $fixtureUnrelated = New-FixtureHook 'ZZZ-Regtest-Unrelatedpreserve'
    try {
        $projUnrelated = New-Proj 'UnrelatedPreserveProj'
        & $InstallScript -CustomHook $fixtureUnrelated -Events @('SessionStart') -TargetProject $projUnrelated *> $null
        $claudeSettingsPath = Join-Path $projUnrelated '.claude\settings.local.json'
        $settingsObj = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
        $settingsObj | Add-Member -MemberType NoteProperty -Name 'unrelatedTopLevelKey' -Value 'keep-me' -Force
        $settingsObj.hooks | Add-Member -MemberType NoteProperty -Name 'PreCompact' -Value @(@{ hooks = @(@{ type = 'command'; command = 'echo unrelated-handler' }) }) -Force
        ($settingsObj | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $claudeSettingsPath -Encoding utf8

        Write-Utf8 $fixtureUnrelated "exit 0 # changed`n"
        $cfgUnrelated = Join-Path $Work 'cfg-unrelated.json'; New-Config $cfgUnrelated
        Invoke-Wizard -Config $cfgUnrelated -Answers @('1', '4', '', '0') | Out-Null

        $afterJson = [System.IO.File]::ReadAllText($claudeSettingsPath)
        Check 'an unrelated top-level settings key survives the update' ($afterJson -match 'unrelatedTopLevelKey')
        Check 'an unrelated event handler (PreCompact) survives the update' ($afterJson -match 'unrelated-handler')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Unrelatedpreserve' }

    # =====================================================================
    Write-Host '--- native pre-push companion is refreshed; a preserved previous hook stays intact ---' -ForegroundColor Cyan
    $prePushProj = New-Proj 'PrePushCompanionProj'
    & git -C $prePushProj init -q -b main
    & git -C $prePushProj config user.email 't@t'
    & git -C $prePushProj config user.name 't'
    $existingPrePushDir = Join-Path $prePushProj '.git\hooks'
    New-Item -ItemType Directory -Path $existingPrePushDir -Force | Out-Null
    Write-Utf8 (Join-Path $existingPrePushDir 'pre-push') "#!/bin/sh`necho user-own-pre-push-hook`n"
    $ignoreHook = Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'
    & $InstallScript -CustomHook $ignoreHook -Events @('SessionStart', 'Stop') -TargetProject $prePushProj *> $null
    $prePushFile = Join-Path $existingPrePushDir 'pre-push'
    Check 'installing Ignore-Rules-Check preserves the existing pre-push hook as .hookmaker-existing' (Test-Path (Join-Path $existingPrePushDir 'pre-push.hookmaker-existing'))
    $companionSecretsScript = Join-Path $existingPrePushDir 'Hook-Maker\Secrets-Check\Secrets-Check.ps1'
    Check 'the pre-push managed companion (Secrets-Check) copy exists' (Test-Path $companionSecretsScript)
    $companionHashBefore = (Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash
    $realSecretsHash = (Get-FileHash -LiteralPath (Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1') -Algorithm SHA256).Hash
    Check 'the pre-push managed companion matches the current real Secrets-Check source' ($companionHashBefore -eq $realSecretsHash)

    $cfgPrePush = Join-Path $Work 'cfg-prepush.json'; New-Config $cfgPrePush
    $rPrePushUpdate = Invoke-Wizard -Config $cfgPrePush -Answers @('1', '4', '0')
    Check 'exit 0 (updating Ignore-Rules-Check refreshes its pre-push chain)' ($rPrePushUpdate.Exit -eq 0) $rPrePushUpdate.Err
    Check 'the pre-push managed companion still matches current source after the update' ((Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash -eq $realSecretsHash)
    Check 'the preserved previous pre-push hook is still intact after the update' ((Test-Path (Join-Path $existingPrePushDir 'pre-push.hookmaker-existing')) -and ([System.IO.File]::ReadAllText((Join-Path $existingPrePushDir 'pre-push.hookmaker-existing')) -match 'user-own-pre-push-hook'))
    Check 'the pre-push wrapper still chains to the preserved previous hook' ([System.IO.File]::ReadAllText($prePushFile) -match 'hookmaker-existing')

    # =====================================================================
    Write-Host '--- registry never stores secret/.env/prompt content ---' -ForegroundColor Cyan
    $fixtureSecret = New-FixtureHook 'ZZZ-Regtest-Secretsafety'
    try {
        $secretMarker = 'sk-live-totallyRealSecretValue1234567890'
        Write-Utf8 (Join-Path (Split-Path -Parent $fixtureSecret) '.env') ('FAKE_SECRET=' + $secretMarker + "`r`n")
        $projSecret = New-Proj 'SecretSafetyProj'
        & $InstallScript -CustomHook $fixtureSecret -Events @('SessionStart') -TargetProject $projSecret *> $null
        $registryRaw = [System.IO.File]::ReadAllText((Join-Path $IsolatedStateDir 'install-registry.json'))
        Check 'the registry file never contains a value from the hook''s own .env' ($registryRaw -notmatch [regex]::Escape($secretMarker))
        Check 'the registry file never contains the literal .env content marker' ($registryRaw -notmatch 'FAKE_SECRET')
    }
    finally {
        Remove-FixtureHook 'ZZZ-Regtest-Secretsafety'
    }

    # =====================================================================
    Write-Host '--- registry read/write: atomic write + malformed state fails safe ---' -ForegroundColor Cyan
    $atomicToolRoot = Join-Path $Work 'atomic-root'
    New-Item -ItemType Directory -Path $atomicToolRoot -Force | Out-Null
    $atomicRegistryPath = Join-Path $atomicToolRoot 'state\install-registry.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $atomicRegistryPath) -Force | Out-Null
    Write-Utf8 $atomicRegistryPath '{ this is not valid json !!'
    $savedEnvForAtomic = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        $malformedRegistry = Read-InstallRegistry -ToolRoot $atomicToolRoot
        Check 'a malformed registry file reads back as an empty, valid skeleton (no crash)' ($null -ne $malformedRegistry -and @($malformedRegistry.installs).Count -eq 0 -and [int]$malformedRegistry.version -eq 1)

        $rec1 = [pscustomobject][ordered]@{ id = 'atomic-test-1'; friendlyName = 'AtomicOne'; sourceHash = 'h1'; lastResult = 'ok' }
        Set-InstallRecord -Registry $malformedRegistry -Record $rec1
        Save-InstallRegistry -ToolRoot $atomicToolRoot -Registry $malformedRegistry
        $parsedAfterSave = Get-Content -LiteralPath $atomicRegistryPath -Raw | ConvertFrom-Json
        Check 'saving after recovering from malformed state produces valid JSON' ($null -ne $parsedAfterSave)
        Check 'no leftover .tmp file remains after an atomic write' (-not (Test-Path -LiteralPath ($atomicRegistryPath + '.tmp')))

        $reReadRegistry = Read-InstallRegistry -ToolRoot $atomicToolRoot
        Check 'the recovered + saved record round-trips correctly' (@($reReadRegistry.installs).Count -eq 1 -and [string]$reReadRegistry.installs[0].id -eq 'atomic-test-1')
    }
    finally {
        $env:HOOKMAKER_STATE_DIR = $savedEnvForAtomic
    }
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
    # Safety net: remove any ZZZ-Regtest-* fixture folders left behind by a
    # failed/interrupted run so the real hooks\ tree never stays polluted.
    foreach ($leftover in @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -Filter 'ZZZ-Regtest-*' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $leftover.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
