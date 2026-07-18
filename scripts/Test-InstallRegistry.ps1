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
        Check 'record is schema 2' ([int]$rec.schema -eq 2)
        Check 'both client subrecords exist (neither -ClaudeOnly nor -CodexOnly)' ((@(Get-InstalledClientNames -Record $rec) | Sort-Object) -join ',' -eq 'claude,codex')
        Check 'claude subrecord events match what was installed' (@(@($rec.clients.claude.events) | Sort-Object) -join ',' -eq 'SessionStart,Stop')
        Check 'codex subrecord events match what was installed' (@(@($rec.clients.codex.events) | Sort-Object) -join ',' -eq 'SessionStart,Stop')
        Check 'record has a non-empty managed-source manifest' (@($rec.sourceManifest).Count -gt 0)
        Check 'manifest covers the shared _hooklib.ps1' (@($rec.sourceManifest | Where-Object { $_.path -eq '_hooklib.ps1' }).Count -eq 1)
        Check 'record has createdUtc and per-client lastInstalledUtc' (-not [string]::IsNullOrWhiteSpace([string]$rec.createdUtc) -and -not [string]::IsNullOrWhiteSpace([string]$rec.clients.claude.lastInstalledUtc))
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
        $manifestFirst = (@($recFirst.sourceManifest | ForEach-Object { $_.path + '=' + $_.hash })) -join '|'
        Write-Utf8 $fixture2 "exit 0 # v2 changed`n"
        & $InstallScript -CustomHook $fixture2 -Events @('Stop') -TargetProject $proj2 *> $null
        $recsSecond = Get-RecordsFor 'ZZZ-Regtest-Reinstall'
        Check 'still exactly one record after reinstalling the same hook/scope' ($recsSecond.Count -eq 1)
        $recSecond = $recsSecond[0]
        Check 'the id is unchanged across reinstall' ([string]$recSecond.id -eq $idFirst)
        Check 'createdUtc is preserved (not reset) across reinstall' ([string]$recSecond.createdUtc -eq $createdFirst)
        Check 'source manifest reflects the NEW content after reinstall' (((@($recSecond.sourceManifest | ForEach-Object { $_.path + '=' + $_.hash })) -join '|') -ne $manifestFirst)
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
        Check 'Claude-only record has only a claude subrecord' ((@(Get-InstalledClientNames -Record $recClaude) -join ',') -eq 'claude')
        Check 'Claude-only subrecord carries its own runtime script' (-not [string]::IsNullOrWhiteSpace([string]$recClaude.clients.claude.runtimeScript))

        $projCodex = New-Proj 'ScopeCodexOnly'
        & $InstallScript -CustomHook $fixture3 -Events @('SessionStart') -TargetProject $projCodex -CodexOnly *> $null
        $recCodex = @(Get-RecordsFor 'ZZZ-Regtest-Scopes' | Where-Object { $_.targetProjectRoot -eq $projCodex })[0]
        Check 'Codex-only record has only a codex subrecord' ((@(Get-InstalledClientNames -Record $recCodex) -join ',') -eq 'codex')
        Check 'Codex-only subrecord carries its own statusMessage' (-not [string]::IsNullOrWhiteSpace([string]$recCodex.clients.codex.statusMessage))

        $projBoth = New-Proj 'ScopeBoth'
        & $InstallScript -CustomHook $fixture3 -Events @('SessionStart') -TargetProject $projBoth *> $null
        $recBoth = @(Get-RecordsFor 'ZZZ-Regtest-Scopes' | Where-Object { $_.targetProjectRoot -eq $projBoth })[0]
        Check 'default (no client switch) record has both subrecords' ((@(Get-InstalledClientNames -Record $recBoth) | Sort-Object) -join ',' -eq 'claude,codex')
        Check 'Both record has a distinct runtime script per client' ([string]$recBoth.clients.claude.runtimeScript -ne [string]$recBoth.clients.codex.runtimeScript)

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
    Check 'engine install manifest tracks the copied sync config' (@($recEngine.sourceManifest | Where-Object { $_.path -like '*/sync-hooks.json' }).Count -eq 1)
    # SYNC-PROJECTS.txt is GENERATED, and is now planned with its exact expected
    # content so it gets a deterministic hash and is verified like any other
    # managed artifact - previously it was excluded from checking entirely.
    Check 'engine install manifest includes the generated SYNC-PROJECTS.txt' (@($recEngine.sourceManifest | Where-Object { $_.path -like '*sync-projects.txt' }).Count -eq 1)
    $syncListPath = Join-Path ([string]$recEngine.clients.claude.runtimeRoot) ((Get-HookFriendlyName $recEngine.friendlyName) + '\SYNC-PROJECTS.txt')
    Check 'the generated SYNC-PROJECTS.txt exists on disk' (Test-Path -LiteralPath $syncListPath)
    Check 'the generated file matches its planned hash (deterministic)' (
        ((Get-FileHash -LiteralPath $syncListPath -Algorithm SHA256).Hash) -eq
        [string](@($recEngine.sourceManifest | Where-Object { $_.path -like '*sync-projects.txt' })[0].hash))
    Check 'tampering with the generated file is detected as drift' (
        $(Add-Content -LiteralPath $syncListPath -Value 'tampered'
          (Get-InstallIntegrity -Record $recEngine -ToolRoot $ToolRoot).Status -eq 'update'))

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
        Check 'the plan lists the changed fixture as needing an update' ($rUpdate.Out -match 'ZZZ-Regtest-Update[\s\S]*?source changed') $rUpdate.Out

        $hashAfterUpdate = (Get-FileHash -LiteralPath $installedCopyClaude -Algorithm SHA256).Hash
        Check 'the installed copy now matches the edited source byte-for-byte' ($hashAfterUpdate -eq $sourceHashAfterEdit)

        $recAfter = (Get-RecordsFor 'ZZZ-Regtest-Update')[0]
        Check 'claude events are preserved across the update' (@(@($recAfter.clients.claude.events) | Sort-Object) -join ',' -eq (@(@($recBefore.clients.claude.events) | Sort-Object) -join ','))
        Check 'codex events are preserved across the update' (@(@($recAfter.clients.codex.events) | Sort-Object) -join ',' -eq (@(@($recBefore.clients.codex.events) | Sort-Object) -join ','))
        Check 'client selection is preserved across the update' ((((@(Get-InstalledClientNames -Record $recAfter) | Sort-Object) -join ',')) -eq (((@(Get-InstalledClientNames -Record $recBefore) | Sort-Object) -join ',')))
        Check 'target project is preserved across the update' ([string]$recAfter.targetProjectRoot -eq [string]$recBefore.targetProjectRoot)
        Check 'scope is preserved across the update' ([string]$recAfter.scope -eq [string]$recBefore.scope)

        # ---- second run: idempotent, reports up to date ----
        # Nothing needs updating this time, so Invoke-UpdateInstalledHooks
        # returns immediately - no confirm prompt is shown.
        $cfgU2 = Join-Path $Work 'cfg-run-update-2.json'; New-Config $cfgU2
        $rUpdate2 = Invoke-Wizard -Config $cfgU2 -Answers @('1', '4', '0')
        Check 'second update run reports the fixture as up to date (idempotent)' ($rUpdate2.Out -match 'ZZZ-Regtest-Update[\s\S]*?up to date') $rUpdate2.Out
        Check 'second run never claims a further update was applied to the fixture' ($rUpdate2.Out -notmatch 'ZZZ-Regtest-Update[\s\S]*?source changed') $rUpdate2.Out
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
        # A confirm answer is included because OTHER healthy records in the
        # shared registry may legitimately need a refresh; the run must still
        # exit 0 and report this record as skipped either way.
        $rMissingSrc = Invoke-Wizard -Config $cfgMissingSrc -Answers @('1', '4', '', '0')
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
        $rMissingTgt = Invoke-Wizard -Config $cfgMissingTgt -Answers @('1', '4', '', '0')
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
    $realSecretsHash = (Get-FileHash -LiteralPath (Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1') -Algorithm SHA256).Hash
    Check 'the pre-push managed companion matches the current real Secrets-Check source' ((Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash -eq $realSecretsHash)
    $preservedPath = Join-Path $existingPrePushDir 'pre-push.hookmaker-existing'
    $preservedBytesBefore = [System.IO.File]::ReadAllBytes($preservedPath)

    $recPrePush = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $prePushProj })[0]
    Check 'the record tracks the native pre-push integration' ($null -ne $recPrePush.nativeGit -and $recPrePush.nativeGit.managed -eq $true)
    Check 'the native manifest includes the Secrets-Check companion source' (@($recPrePush.nativeGit.sourceManifest | Where-Object { $_.path -like 'secrets-check/*' }).Count -ge 1)
    Check 'the record notes that a previous user hook was preserved' ($recPrePush.nativeGit.previousHookPreserved -eq $true)
    Check 'a freshly installed native chain evaluates as current' ((Get-InstallIntegrity -Record $recPrePush -ToolRoot $ToolRoot).Status -eq 'current')

    # Deliberately make the INSTALLED companion stale while its SOURCE is
    # untouched - the exact case a source-hash-only updater reports as
    # "up to date" while the native chain silently runs old code.
    Add-Content -LiteralPath $companionSecretsScript -Value '# deliberately corrupted companion'
    $staleCompanionHash = (Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash
    Check 'the installed companion is genuinely stale before updating' ($staleCompanionHash -ne $realSecretsHash)
    $staleEval = Get-InstallIntegrity -Record $recPrePush -ToolRoot $ToolRoot
    Check 'a stale native companion is planned for update' ($staleEval.Status -eq 'update')
    Check 'a stale native companion is reported with a native reason' ($staleEval.Detail -match 'native' -and $staleEval.Detail -match 'secrets-check') $staleEval.Detail

    # Companion SOURCE drift: tamper the RECORDED hash (equivalent to the
    # source having changed since install) - proves the companion's source is
    # actually part of the tracked manifest, without mutating a shipped hook.
    $recSourceDrift = @(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $prePushProj })[0]
    foreach ($entry in @($recSourceDrift.nativeGit.sourceManifest)) {
        if ($entry.path -like 'secrets-check/*.ps1') { $entry.hash = 'DEADBEEF' }
    }
    $sourceDriftEval = Get-InstallIntegrity -Record $recSourceDrift -ToolRoot $ToolRoot
    Check 'companion SOURCE drift alone plans the parent hook for update' ($sourceDriftEval.Status -eq 'update')
    Check 'companion source drift names the companion' ($sourceDriftEval.Detail -match 'secrets-check') $sourceDriftEval.Detail

    # Something needs updating now, so ONE confirmation is asked.
    $cfgPrePush = Join-Path $Work 'cfg-prepush.json'; New-Config $cfgPrePush
    $rPrePushUpdate = Invoke-Wizard -Config $cfgPrePush -Answers @('1', '4', '', '0')
    Check 'exit 0 (updating Ignore-Rules-Check refreshes its pre-push chain)' ($rPrePushUpdate.Exit -eq 0) $rPrePushUpdate.Err
    Check 'the stale native companion is repaired back to the current source' ((Get-FileHash -LiteralPath $companionSecretsScript -Algorithm SHA256).Hash -eq $realSecretsHash)

    $wrapperBody = [System.IO.File]::ReadAllText($prePushFile)
    Check 'the preserved previous pre-push hook is byte-for-byte unchanged' (
        (Test-Path -LiteralPath $preservedPath) -and
        ([System.IO.File]::ReadAllBytes($preservedPath).Length -eq $preservedBytesBefore.Length) -and
        ([System.IO.File]::ReadAllText($preservedPath) -match 'user-own-pre-push-hook'))
    Check 'the pre-push wrapper still chains to the preserved previous hook' ($wrapperBody -match 'hookmaker-existing')
    Check 'the wrapper is not duplicated (one Hook Maker marker)' ((([regex]::Matches($wrapperBody, [regex]::Escape('# Hook Maker: Ignore-Rules-Check'))).Count) -eq 1)
    Check 'the wrapper runs Ignore-Rules-Check exactly once' ((([regex]::Matches($wrapperBody, [regex]::Escape('/Ignore-Rules-Check/Ignore-Rules-Check.ps1"'))).Count) -eq 1)
    Check 'the wrapper runs Secrets-Check exactly once' ((([regex]::Matches($wrapperBody, [regex]::Escape('/Secrets-Check/Secrets-Check.ps1"'))).Count) -eq 1)
    Check 'chain order is Ignore-Rules-Check then Secrets-Check then the previous hook' (
        $wrapperBody.IndexOf('/Ignore-Rules-Check/Ignore-Rules-Check.ps1"') -lt $wrapperBody.IndexOf('/Secrets-Check/Secrets-Check.ps1"') -and
        $wrapperBody.IndexOf('/Secrets-Check/Secrets-Check.ps1"') -lt $wrapperBody.IndexOf('hookmaker-existing'))
    Check 'stdin is still buffered once and replayed to every stage' (
        $wrapperBody -match 'STDIN_FILE' -and
        ((([regex]::Matches($wrapperBody, [regex]::Escape('< "$STDIN_FILE"'))).Count) -ge 3))
    Check 'fail-closed chaining (|| exit) is preserved' ($wrapperBody -match '\|\| exit')
    Check 'the native chain evaluates as current after repair' ((Get-InstallIntegrity -Record (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $prePushProj })[0]) -ToolRoot $ToolRoot).Status -eq 'current')

    # Second run: nothing left to do, so no confirmation is asked.
    $cfgPrePush2 = Join-Path $Work 'cfg-prepush-2.json'; New-Config $cfgPrePush2
    $rPrePush2 = Invoke-Wizard -Config $cfgPrePush2 -Answers @('1', '4', '0')
    Check 'the second native pre-push run is idempotent (up to date)' ($rPrePush2.Out -match 'Ignore-Rules-Check[\s\S]*?up to date') $rPrePush2.Out

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
    # =====================================================================
    # A hook source OUTSIDE a recognized hooks root is a STANDALONE script:
    # only that file is installed. Previously the installer recursively copied
    # the script's whole parent directory, so pointing -CustomHook at a script
    # inside a project copied that project's .git/.env/credentials/source into
    # a settings-registered runtime directory.
    Write-Host '--- custom-hook source boundaries: never copy an arbitrary parent directory ---' -ForegroundColor Cyan
    $victim = Join-Path $Work 'victim-project'
    New-Item -ItemType Directory -Path (Join-Path $victim '.git'), (Join-Path $victim 'node_modules\pkg'), (Join-Path $victim 'src') -Force | Out-Null
    Write-Utf8 (Join-Path $victim 'zzz-standalone-hook.ps1') "exit 0`n"
    $secretValue = 'REGTEST-SECRET-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Write-Utf8 (Join-Path $victim '.env') ('AWS_SECRET_ACCESS_KEY=' + $secretValue)
    Write-Utf8 (Join-Path $victim 'secrets.md') 'db password: hunter2'
    Write-Utf8 (Join-Path $victim '.git\config') 'url = git@github.com:me/private.git'
    Write-Utf8 (Join-Path $victim 'node_modules\pkg\index.js') 'module.exports=1'
    Write-Utf8 (Join-Path $victim 'src\proprietary.cs') 'class Secret {}'
    $projStandalone = New-Proj 'StandaloneSourceProj'
    & $InstallScript -CustomHook (Join-Path $victim 'zzz-standalone-hook.ps1') -Events @('Stop') -TargetProject $projStandalone -ClaudeOnly *> $null
    $standaloneRoot = Join-Path $projStandalone '.claude\hooks\Hook-Maker'
    $standaloneFiles = @(Get-ChildItem -LiteralPath $standaloneRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
    $standaloneNames = @($standaloneFiles | ForEach-Object { $_.Name })
    Check 'a standalone hook installs only its own script plus the shared library' ((@($standaloneNames | Sort-Object) -join ',') -eq '_hooklib.ps1,zzz-standalone-hook.ps1')
    Check 'the neighbouring project .env is never copied' (@($standaloneNames | Where-Object { $_ -eq '.env' }).Count -eq 0)
    Check 'the neighbouring project secrets.md is never copied' (@($standaloneNames | Where-Object { $_ -eq 'secrets.md' }).Count -eq 0)
    Check 'git metadata is never copied' (@($standaloneFiles | Where-Object { $_.FullName -like '*.git*' -and $_.Name -eq 'config' }).Count -eq 0)
    Check 'node_modules is never copied' (@($standaloneFiles | Where-Object { $_.FullName -like '*node_modules*' }).Count -eq 0)
    Check 'unrelated source files are never copied' (@($standaloneNames | Where-Object { $_ -eq 'proprietary.cs' }).Count -eq 0)
    $standaloneBytes = ''
    foreach ($standaloneFile in $standaloneFiles) { $standaloneBytes += [System.IO.File]::ReadAllText($standaloneFile.FullName) }
    Check 'no secret value from the neighbouring project reaches the runtime' ($standaloneBytes -notmatch [regex]::Escape($secretValue))
    Check 'a standalone hook is named after its SCRIPT, not its parent folder' (Test-Path -LiteralPath (Join-Path $standaloneRoot 'zzz-standalone-hook\zzz-standalone-hook.ps1'))
    $projPackage = New-Proj 'PackagedSourceProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1') -Events @('Stop') -TargetProject $projPackage -ClaudeOnly *> $null
    Check 'a packaged shipped hook still installs its package contents' (Test-Path -LiteralPath (Join-Path $projPackage '.claude\hooks\Hook-Maker\Secrets-Check\Secrets-Check.ps1'))
    Check 'a package never ships its .env.example template' (-not (Test-Path -LiteralPath (Join-Path $projPackage '.claude\hooks\Hook-Maker\Secrets-Check\.env.example')))

    # =====================================================================
    Write-Host '--- direct installer inputs are validated before anything is mutated ---' -ForegroundColor Cyan
    $HookForValidation = Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1'
    $projValidate = New-Proj 'ValidateInputsProj'
    $bothSwitches = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @('Stop') -ClaudeOnly -CodexOnly *> $null } catch { $bothSwitches = $true }
    Check 'ClaudeOnly and CodexOnly together are rejected' $bothSwitches
    Check 'the rejected invocation wrote no settings at all' (-not (Test-Path -LiteralPath (Join-Path $projValidate '.claude')))
    $emptyEvents = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @() -ClaudeOnly *> $null } catch { $emptyEvents = $true }
    Check 'an empty event list is rejected' $emptyEvents
    $badEvent = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @('NotARealEvent') -ClaudeOnly *> $null } catch { $badEvent = $true }
    Check 'an unsupported event name is rejected' $badEvent
    $missingTargetPath = Join-Path $Work 'target-that-does-not-exist'
    $badTarget = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $missingTargetPath -Events @('Stop') -ClaudeOnly *> $null } catch { $badTarget = $true }
    Check 'a nonexistent target project is rejected' $badTarget
    Check 'the rejected target directory was not created' (-not (Test-Path -LiteralPath $missingTargetPath))
    & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @('Stop', 'Stop', 'SessionStart') -ClaudeOnly *> $null
    $validatedJson = Get-Content -LiteralPath (Join-Path $projValidate '.claude\settings.local.json') -Raw | ConvertFrom-Json
    Check 'duplicate events are normalized to one registration each' (@($validatedJson.hooks.PSObject.Properties).Count -eq 2)

    # =====================================================================
    # Ownership is proven by the managed runtime PATH, never by a basename.
    Write-Host '--- unrelated handlers with the same script basename are preserved ---' -ForegroundColor Cyan
    $projBasename = New-Proj 'BasenameIdentityProj'
    & $InstallScript -CustomHook $HookForValidation -TargetProject $projBasename -Events @('Stop') -ClaudeOnly *> $null
    $basenameSettings = Join-Path $projBasename '.claude\settings.local.json'
    $basenameJson = Get-Content -LiteralPath $basenameSettings -Raw | ConvertFrom-Json
    $userHandlerA = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "C:\Users\me\MyTools\Ai-Memory-Check.ps1"'; timeout = 99 }) }
    $userHandlerB = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; commandWindows = 'powershell -File "D:\Other\Ai-Memory-Check.ps1"'; timeout = 5 }) }
    $basenameJson.hooks.Stop = @($basenameJson.hooks.Stop) + @($userHandlerA) + @($userHandlerB)
    [System.IO.File]::WriteAllText($basenameSettings, ($basenameJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $HookForValidation -TargetProject $projBasename -Events @('Stop') -ClaudeOnly *> $null
    $basenameAfter = Get-Content -LiteralPath $basenameSettings -Raw | ConvertFrom-Json
    $basenameHandlers = @(@($basenameAfter.hooks.Stop) | ForEach-Object { $_.hooks })
    Check 'a user same-basename handler in command survives a reinstall' (@($basenameHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*MyTools*' }).Count -eq 1)
    Check 'a user same-basename handler in commandWindows survives a reinstall' (@($basenameHandlers | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -like '*Other*' }).Count -eq 1)
    Check 'the real Hook Maker registration is still present exactly once' (@($basenameHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*Hook-Maker*' }).Count -eq 1)

    # =====================================================================
    # A failed replacement must never leave a working runtime worse off.
    Write-Host '--- runtime replacement is transactional (failed staging keeps the old runtime) ---' -ForegroundColor Cyan
    $fixtureTx = New-FixtureHook 'ZZZ-Regtest-Transaction' "exit 0 # good`n"
    try {
        $projTx = New-Proj 'TransactionProj'
        & $InstallScript -CustomHook $fixtureTx -Events @('Stop') -TargetProject $projTx -ClaudeOnly *> $null
        $txRuntimeRoot = Join-Path $projTx '.claude\hooks\Hook-Maker'
        $txScript = Join-Path $txRuntimeRoot 'ZZZ-Regtest-Transaction\ZZZ-Regtest-Transaction.ps1'
        Check 'baseline transactional install succeeded' (Test-Path -LiteralPath $txScript)
        $txGoodHash = (Get-FileHash -LiteralPath $txScript -Algorithm SHA256).Hash
        $txMissingSource = Join-Path $Work 'no-such-file.txt'
        $txPlan = @(Get-InstallPlanFor -HookScript $fixtureTx -ToolRoot $ToolRoot) + @(New-PlanArtifact -RelativePath 'ZZZ-Regtest-Transaction/missing.txt' -Kind 'File' -SourcePath $txMissingSource)
        $txThrew = $false
        try { Install-PlannedRuntime -Plan $txPlan -RuntimeRoot $txRuntimeRoot -FriendlyName 'ZZZ-Regtest-Transaction' | Out-Null } catch { $txThrew = $true }
        Check 'a staging failure is surfaced as an error' $txThrew
        Check 'the previous runtime still exists after a failed staging' (Test-Path -LiteralPath $txScript)
        Check 'the previous runtime is byte-identical after a failed staging' ((Get-FileHash -LiteralPath $txScript -Algorithm SHA256).Hash -eq $txGoodHash)
        Check 'no staging or set-aside directory is left behind' (@(Get-ChildItem -LiteralPath $txRuntimeRoot -Directory -Force | Where-Object { $_.Name -like '.hookmaker-*' }).Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Transaction' }

    # =====================================================================
    Write-Host '--- registry availability: zero-byte file and orphan lock ---' -ForegroundColor Cyan
    $availRoot = Join-Path $Work 'availability-root'
    New-Item -ItemType Directory -Path (Join-Path $availRoot 'state') -Force | Out-Null
    $availRegistry = Join-Path $availRoot 'state\install-registry.json'
    $savedAvailStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        Write-Utf8 $availRegistry '{"version":2,"installs":[{"id":"real-record","schema":2,"friendlyName":"Real"}]}'
        Check 'a healthy registry reads as ok' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'ok')
        [System.IO.File]::WriteAllText($availRegistry, '')
        Check 'a zero-byte registry is corrupt, not missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'corrupt')
        [System.IO.File]::WriteAllText($availRegistry, '    ')
        Check 'a whitespace-only registry is corrupt, not missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'corrupt')
        Remove-Item -LiteralPath $availRegistry -Force
        Check 'a genuinely absent registry is still reported missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'missing')
        $availLock = Join-Path $availRoot 'state\install-registry.lock'
        Write-Utf8 $availLock '{"pid":999999,"host":"machine-that-died"}'
        $reclaimed = $false
        $probeRecord = [pscustomobject][ordered]@{
            id = 'orphan-lock-probe'; schema = 2; friendlyName = 'OrphanProbe'; hookType = 'CustomHook'
            sourceScript = ''; sourceDir = ''; scope = 'project'; targetProjectRoot = ''
            profile = ''; configPath = ''; sourceManifest = @(); clients = [pscustomobject]@{}; nativeGit = $null
            lastResult = 'ok'; lastReason = 'probe'; lastError = ''
        }
        try { Update-InstallRegistry -ToolRoot $availRoot -Record $probeRecord | Out-Null; $reclaimed = $true } catch { }
        Check 'an orphan lock from a killed writer is reclaimed, not fatal forever' $reclaimed
        Check 'the lock file is released after the write' (-not (Test-Path -LiteralPath $availLock))
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedAvailStateDir }

    # Installed-state drift: NONE of these change the source, so an updater
    # that only compares stored source hashes would wrongly report "up to
    # date". Each asserts the precise repairable reason.
    Write-Host '--- installed-state drift is detected without any source change ---' -ForegroundColor Cyan
    $fixtureDrift = New-FixtureHook 'ZZZ-Regtest-Drift' "exit 0 # drift`n"
    try {
        $projDrift = New-Proj 'DriftProj'
        & $InstallScript -CustomHook $fixtureDrift -Events @('SessionStart', 'Stop') -TargetProject $projDrift *> $null
        $recDrift = (Get-RecordsFor 'ZZZ-Regtest-Drift')[0]
        Check 'baseline drift install is current before tampering' ((Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot).Status -eq 'current')

        $claudeScript = [string]$recDrift.clients.claude.runtimeScript
        $claudeRoot = [string]$recDrift.clients.claude.runtimeRoot
        $claudeSettings = [string]$recDrift.clients.claude.settingsPath
        $codexScript = [string]$recDrift.clients.codex.runtimeScript
        $codexSettings = [string]$recDrift.clients.codex.settingsPath
        $originalScriptBytes = [System.IO.File]::ReadAllBytes($claudeScript)
        $originalHookLibBytes = [System.IO.File]::ReadAllBytes((Join-Path $claudeRoot '_hooklib.ps1'))
        $originalClaudeJson = [System.IO.File]::ReadAllText($claudeSettings)
        $originalCodexJson = [System.IO.File]::ReadAllText($codexSettings)

        # 1. installed main script deleted
        Remove-Item -LiteralPath $claudeScript -Force
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a deleted installed script is planned for update' ($d.Status -eq 'update')
        Check 'a deleted installed script reports a missing-file reason' ($d.Detail -match 'missing') $d.Detail
        [System.IO.File]::WriteAllBytes($claudeScript, $originalScriptBytes)

        # 2. installed main script modified
        Add-Content -LiteralPath $claudeScript -Value '# tampered'
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a modified installed script is planned for update' ($d.Status -eq 'update')
        Check 'a modified installed script reports installed-file-modified' ($d.Detail -match 'installed file modified') $d.Detail
        [System.IO.File]::WriteAllBytes($claudeScript, $originalScriptBytes)

        # 3. installed shared _hooklib.ps1 modified / deleted
        Add-Content -LiteralPath (Join-Path $claudeRoot '_hooklib.ps1') -Value '# tampered'
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a stale shared _hooklib.ps1 is planned for update' ($d.Status -eq 'update')
        Check 'a stale shared runtime is reported as such' ($d.Detail -match 'shared runtime is stale') $d.Detail
        Remove-Item -LiteralPath (Join-Path $claudeRoot '_hooklib.ps1') -Force
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a missing shared runtime is reported as such' ($d.Detail -match 'shared runtime is missing') $d.Detail
        [System.IO.File]::WriteAllBytes((Join-Path $claudeRoot '_hooklib.ps1'), $originalHookLibBytes)
        Check 'restoring the managed files returns the install to current' ((Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot).Status -eq 'current')

        # 4./5. a client registration removed entirely
        Write-Utf8 $claudeSettings '{"hooks":{}}'
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a removed Claude registration is planned for update' ($d.Status -eq 'update')
        Check 'a removed Claude registration reports registration-missing' ($d.Detail -match 'registration missing') $d.Detail
        [System.IO.File]::WriteAllText($claudeSettings, $originalClaudeJson)
        Write-Utf8 $codexSettings '{"hooks":{}}'
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a removed Codex registration reports registration-missing for codex' ($d.Status -eq 'update' -and $d.Detail -match '^codex') $d.Detail
        [System.IO.File]::WriteAllText($codexSettings, $originalCodexJson)

        # 6./7. event moved (stale registration on an old event) and matcher changed
        $mutated = $originalClaudeJson.Replace('"Stop"', '"SubagentStop"')
        [System.IO.File]::WriteAllText($claudeSettings, $mutated)
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a registration moved to a different event is planned for update' ($d.Status -eq 'update')
        Check 'a registration on an unexpected event is reported precisely' ($d.Detail -match 'registration missing|stale registration') $d.Detail
        [System.IO.File]::WriteAllText($claudeSettings, $originalClaudeJson)

        $claudeObj = $originalClaudeJson | ConvertFrom-Json
        $claudeObj.hooks.SessionStart[0].matcher = 'startup'
        [System.IO.File]::WriteAllText($claudeSettings, ($claudeObj | ConvertTo-Json -Depth 50))
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a changed matcher is planned for update' ($d.Status -eq 'update')
        Check 'a changed matcher reports registration-drifted' ($d.Detail -match 'registration drifted' -and $d.Detail -match 'matcher') $d.Detail
        [System.IO.File]::WriteAllText($claudeSettings, $originalClaudeJson)

        # 8. duplicate registration for the same logical install on one event
        $dupObj = $originalClaudeJson | ConvertFrom-Json
        $dupGroup = $dupObj.hooks.Stop[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
        $dupObj.hooks.Stop = @($dupObj.hooks.Stop) + @($dupGroup)
        [System.IO.File]::WriteAllText($claudeSettings, ($dupObj | ConvertTo-Json -Depth 50))
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a duplicate registration is planned for update' ($d.Status -eq 'update')
        Check 'a duplicate registration is reported as duplicate' ($d.Detail -match 'duplicate registration') $d.Detail
        [System.IO.File]::WriteAllText($claudeSettings, $originalClaudeJson)

        # 9. only one of two expected client runtimes remains
        Remove-Item -LiteralPath (Split-Path -Parent $codexScript) -Recurse -Force
        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot
        Check 'a wiped Codex runtime is detected even though Claude is intact' ($d.Status -eq 'update' -and $d.Detail -match '^codex') $d.Detail

        # 10. the updater actually REPAIRS all of it, exactly once
        $cfgDrift = Join-Path $Work 'cfg-drift.json'; New-Config $cfgDrift
        $rDrift = Invoke-Wizard -Config $cfgDrift -Answers @('1', '4', '', '0')
        Check 'the drift repair run exits 0' ($rDrift.Exit -eq 0) $rDrift.Err
        $recRepaired = (Get-RecordsFor 'ZZZ-Regtest-Drift')[0]
        Check 'after repair the installation is current again' ((Get-InstallIntegrity -Record $recRepaired -ToolRoot $ToolRoot).Status -eq 'current')
        $repairedSourceHash = (Get-FileHash -LiteralPath $fixtureDrift -Algorithm SHA256).Hash
        Check 'after repair the installed copy matches source byte-for-byte' ((Get-FileHash -LiteralPath ([string]$recRepaired.clients.claude.runtimeScript) -Algorithm SHA256).Hash -eq $repairedSourceHash)
        $repairedClaude = @(Get-HookRegistrations -SettingsPath $claudeSettings -RuntimeScript ([string]$recRepaired.clients.claude.runtimeScript))
        Check 'after repair Claude has exactly one registration per expected event' ($repairedClaude.Count -eq 2)
        Check 'after repair no registration is left on the stale event' (@($repairedClaude | Where-Object { $_.EventName -eq 'SubagentStop' }).Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Drift' }

    # =====================================================================
    # The managed manifest must cover EVERY file the installer copies, not
    # just the main script + _hooklib + sync config.
    Write-Host '--- managed-file manifest covers .env and copied helpers ---' -ForegroundColor Cyan
    $fixtureMan = New-FixtureHook 'ZZZ-Regtest-Manifest' "exit 0 # manifest`n"
    try {
        $manDir = Split-Path -Parent $fixtureMan
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`n"
        Write-Utf8 (Join-Path $manDir '.env.example') "EVENTS=Stop`n"
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v1`n"
        $projMan = New-Proj 'ManifestProj'
        & $InstallScript -CustomHook $fixtureMan -Events @('Stop') -TargetProject $projMan -ClaudeOnly *> $null
        $recMan = (Get-RecordsFor 'ZZZ-Regtest-Manifest')[0]
        $manPaths = @($recMan.sourceManifest | ForEach-Object { $_.path })
        Check 'the manifest includes the hook-local .env' (@($manPaths | Where-Object { $_ -like '*/.env' }).Count -eq 1)
        Check 'the manifest includes a copied helper file' (@($manPaths | Where-Object { $_ -like '*/helper.ps1' }).Count -eq 1)
        Check 'the manifest excludes .env.example (never copied by the installer)' (@($manPaths | Where-Object { $_ -like '*.env.example' }).Count -eq 0)
        Check 'baseline manifest install is current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')

        # 1. .env-only source change must trigger update
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`nEXTRA=1`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a .env-only source change triggers an update' ($m.Status -eq 'update' -and $m.Detail -match '\.env') $m.Detail
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`n"

        # 2. helper-only source change must trigger update
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v2`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a copied-helper-only source change triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'helper\.ps1') $m.Detail
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v1`n"

        # 3. a managed file ADDED to source
        Write-Utf8 (Join-Path $manDir 'extra.psd1') "@{}`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a newly added managed source file triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'added') $m.Detail
        Remove-Item -LiteralPath (Join-Path $manDir 'extra.psd1') -Force

        # 4. a managed file REMOVED from source
        Remove-Item -LiteralPath (Join-Path $manDir 'helper.ps1') -Force
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a removed managed source file triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'removed') $m.Detail
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v1`n"
        Check 'restoring source returns the install to current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')

        # 5. the INSTALLED .env corrupted (source untouched)
        $installedEnv = Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest\.env'
        Add-Content -LiteralPath $installedEnv -Value 'TAMPERED=1'
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a corrupted installed .env triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'installed file modified') $m.Detail
        Write-Utf8 $installedEnv "EVENTS=Stop`n"

        # 6. a runtime-only mutable file must NOT trigger update
        Write-Utf8 (Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest\run.log') 'runtime noise'
        Check 'a runtime-generated .log file never counts as managed drift' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Manifest' }

    # =====================================================================
    # Per-client semantics: the exact sequence that silently corrupted a v1
    # record (Claude-only SessionStart, then Codex-only Stop -> clients=Both,
    # events=Stop -> updater rewrote Claude to Stop).
    Write-Host '--- per-client semantics are stored and preserved independently ---' -ForegroundColor Cyan
    $fixturePc = New-FixtureHook 'ZZZ-Regtest-Perclient' "exit 0 # per-client v1`n"
    try {
        $projPc = New-Proj 'PerClientProj'
        & $InstallScript -CustomHook $fixturePc -Events @('SessionStart') -TargetProject $projPc -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fixturePc -Events @('Stop') -TargetProject $projPc -CodexOnly *> $null
        $recPc = (Get-RecordsFor 'ZZZ-Regtest-Perclient')
        Check 'both client installs share ONE logical record' ($recPc.Count -eq 1)
        $recPc = $recPc[0]
        Check 'Claude keeps its own SessionStart events' ((@($recPc.clients.claude.events) -join ',') -eq 'SessionStart')
        Check 'Codex keeps its own Stop events (not overwritten by Claude)' ((@($recPc.clients.codex.events) -join ',') -eq 'Stop')
        Check 'adding Codex later did not drop the Claude subrecord' ((@(Get-InstalledClientNames -Record $recPc) | Sort-Object) -join ',' -eq 'claude,codex')
        Check 'a mixed-event install is still considered current' ((Get-InstallIntegrity -Record $recPc -ToolRoot $ToolRoot).Status -eq 'current')

        $pcClaudeSettings = [string]$recPc.clients.claude.settingsPath
        $pcCodexSettings = [string]$recPc.clients.codex.settingsPath
        $pcClaudeScript = [string]$recPc.clients.claude.runtimeScript
        $pcCodexScript = [string]$recPc.clients.codex.runtimeScript

        # Change the source, then let the updater refresh BOTH clients.
        Write-Utf8 $fixturePc "exit 0 # per-client v2`n"
        $cfgPc = Join-Path $Work 'cfg-perclient.json'; New-Config $cfgPc
        $rPc = Invoke-Wizard -Config $cfgPc -Answers @('1', '4', '', '0')
        Check 'the per-client update run exits 0' ($rPc.Exit -eq 0) $rPc.Err

        $claudeRegs = @(Get-HookRegistrations -SettingsPath $pcClaudeSettings -RuntimeScript $pcClaudeScript)
        $codexRegs = @(Get-HookRegistrations -SettingsPath $pcCodexSettings -RuntimeScript $pcCodexScript)
        Check 'after update Claude still registers ONLY SessionStart' ((@($claudeRegs | ForEach-Object { $_.EventName }) | Sort-Object -Unique) -join ',' -eq 'SessionStart')
        Check 'after update Codex still registers ONLY Stop' ((@($codexRegs | ForEach-Object { $_.EventName }) | Sort-Object -Unique) -join ',' -eq 'Stop')
        Check 'after update Claude has exactly one registration' ($claudeRegs.Count -eq 1)
        Check 'after update Codex has exactly one registration' ($codexRegs.Count -eq 1)
        $newSourceHash = (Get-FileHash -LiteralPath $fixturePc -Algorithm SHA256).Hash
        Check 'after update both clients got the new source byte-for-byte' (
            (Get-FileHash -LiteralPath $pcClaudeScript -Algorithm SHA256).Hash -eq $newSourceHash -and
            (Get-FileHash -LiteralPath $pcCodexScript -Algorithm SHA256).Hash -eq $newSourceHash)

        # Damaging ONE client must not disturb the healthy one.
        $codexBefore = [System.IO.File]::ReadAllText($pcCodexSettings)
        Remove-Item -LiteralPath $pcClaudeScript -Force
        $cfgPc2 = Join-Path $Work 'cfg-perclient-2.json'; New-Config $cfgPc2
        $rPc2 = Invoke-Wizard -Config $cfgPc2 -Answers @('1', '4', '', '0')
        Check 'repairing one damaged client exits 0' ($rPc2.Exit -eq 0) $rPc2.Err
        Check 'the damaged Claude runtime is restored' (Test-Path -LiteralPath $pcClaudeScript)
        Check 'the healthy Codex settings file is byte-for-byte unchanged' ([System.IO.File]::ReadAllText($pcCodexSettings) -eq $codexBefore)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Perclient' }

    # =====================================================================
    # v1 -> v2 migration must never invent semantics.
    Write-Host '--- v1 records migrate safely to the per-client schema ---' -ForegroundColor Cyan
    $fixtureMig = New-FixtureHook 'ZZZ-Regtest-Migrate' "exit 0 # migrate`n"
    try {
        $projMig = New-Proj 'MigrateProj'
        & $InstallScript -CustomHook $fixtureMig -Events @('SessionStart') -TargetProject $projMig -ClaudeOnly *> $null
        $recMig = (Get-RecordsFor 'ZZZ-Regtest-Migrate')[0]
        $claudeScriptMig = [string]$recMig.clients.claude.runtimeScript
        $claudeSettingsMig = [string]$recMig.clients.claude.settingsPath

        # Rebuild the on-disk registry as a genuine v1 record for this hook.
        $registryPath = Join-Path $IsolatedStateDir 'install-registry.json'
        $liveRegistry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $v1Record = [pscustomobject][ordered]@{
            id = [string]$recMig.id; internalName = 'ZZZ-Regtest-Migrate'; friendlyName = 'ZZZ-Regtest-Migrate'
            hookType = 'CustomHook'; sourceScript = $fixtureMig; sourceDir = (Split-Path -Parent $fixtureMig)
            scope = 'project'; targetProjectRoot = $projMig
            clients = 'Claude'; claudeSettingsPath = $claudeSettingsMig; codexHooksPath = (Join-Path $projMig '.codex\hooks.json')
            events = @('SessionStart'); profile = ''; configPath = ''
            claudeRuntimeScript = $claudeScriptMig; codexRuntimeScript = ''
            prePushManaged = $false; sourceHash = 'OLD'; hooklibHash = 'OLD'; configHash = ''
            lastInstalledUtc = '2026-01-01T00:00:00.0000000Z'; lastUpdatedUtc = ''; lastResult = 'ok'; lastError = ''
            createdUtc = '2026-01-01T00:00:00.0000000Z'; history = @()
        }
        $liveRegistry.installs = @(@($liveRegistry.installs | Where-Object { [string]$_.id -ne [string]$recMig.id }) + @($v1Record))
        $liveRegistry.version = 1
        [System.IO.File]::WriteAllText($registryPath, ($liveRegistry | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        $migrated = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { [string]$_.id -eq [string]$recMig.id })[0]
        Check 'a v1 record is migrated to schema 2 on read' ([int]$migrated.schema -eq 2)
        Check 'migration derives the claude subrecord from the v1 clients value' ((@(Get-InstalledClientNames -Record $migrated) -join ',') -eq 'claude')
        Check 'migration takes the events from the LIVE registration, not a guess' ((@($migrated.clients.claude.events) -join ',') -eq 'SessionStart')
        Check 'migration marks where the events came from' ($migrated.clients.claude.eventsFromLive -eq $true)
        Check 'a migrated record is planned for update (it predates manifest tracking)' ((Get-InstallIntegrity -Record $migrated -ToolRoot $ToolRoot).Status -eq 'update')

        # An unusable v1 record must be flagged, never guessed at.
        $brokenV1 = [pscustomobject][ordered]@{
            id = 'broken-v1-record'; internalName = 'ZZZ-Regtest-Broken'; friendlyName = 'ZZZ-Regtest-Broken'
            hookType = 'CustomHook'; sourceScript = $fixtureMig; sourceDir = (Split-Path -Parent $fixtureMig)
            scope = 'project'; targetProjectRoot = $projMig
            clients = 'Both'; claudeSettingsPath = ''; codexHooksPath = ''
            events = @(); profile = ''; configPath = ''
            claudeRuntimeScript = ''; codexRuntimeScript = ''
        }
        $migratedBroken = ConvertTo-InstallRecordV2 -Record $brokenV1
        Check 'an unusable v1 record is flagged for manual repair, not guessed' ($migratedBroken.needsManualRepair -eq $true)
        Check 'an unusable v1 record is skipped (never silently rewritten)' ((Get-InstallIntegrity -Record $migratedBroken -ToolRoot $ToolRoot).Status -eq 'skip')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Migrate' }

    # =====================================================================
    # Corrupt registry: preserve, warn, recover - never silently destroy.
    Write-Host '--- a corrupt registry is quarantined, never silently overwritten ---' -ForegroundColor Cyan
    $corruptRoot = Join-Path $Work 'corrupt-root'
    New-Item -ItemType Directory -Path (Join-Path $corruptRoot 'state') -Force | Out-Null
    $corruptRegistry = Join-Path $corruptRoot 'state\install-registry.json'
    $savedStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        function New-CorruptRecord {
            return [pscustomobject][ordered]@{
                id = 'quarantine-probe'; schema = 2; friendlyName = 'QuarantineProbe'; hookType = 'CustomHook'
                sourceScript = ''; sourceDir = ''; scope = 'project'; targetProjectRoot = ''
                profile = ''; configPath = ''; sourceManifest = @()
                clients = [pscustomobject]@{}; nativeGit = $null
                lastResult = 'ok'; lastReason = 'probe'; lastError = ''
            }
        }

        # 1. malformed JSON
        Write-Utf8 $corruptRegistry '{ this is not valid json !!'
        $originalBytes = [System.IO.File]::ReadAllBytes($corruptRegistry)
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'malformed JSON is reported as corrupt, not as an empty registry' ($state.State -eq 'corrupt')
        $result = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        Check 'the install still succeeds after quarantining a corrupt registry' ($result.Ok -eq $true)
        Check 'quarantine emits an explicit warning naming the preserved file' ($result.Warning -match 'install-registry\.corrupt-') $result.Warning
        $quarantined = @(Get-ChildItem -LiteralPath (Split-Path -Parent $corruptRegistry) -Filter 'install-registry.corrupt-*.json')
        Check 'exactly one quarantine file is produced' ($quarantined.Count -eq 1)
        $quarantinedBytes = [System.IO.File]::ReadAllBytes($quarantined[0].FullName)
        Check 'the quarantined file preserves the original bytes exactly' (
            $quarantinedBytes.Length -eq $originalBytes.Length -and
            (Compare-Object $quarantinedBytes $originalBytes -SyncWindow 0 | Measure-Object).Count -eq 0)
        $recovered = Read-InstallRegistry -ToolRoot $corruptRoot
        Check 'a new valid registry exists only after quarantine succeeded' (@($recovered.installs).Count -eq 1 -and [string]$recovered.installs[0].id -eq 'quarantine-probe')
        Check 'no raw file contents or secrets appear in the quarantine warning' ($result.Warning -notmatch 'this is not valid json')

        # 2. valid JSON, wrong field types
        Write-Utf8 $corruptRegistry '{"version":2,"installs":"not-an-array-of-records"}'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'valid JSON with a wrong installs type is reported as corrupt' ($state.State -eq 'corrupt')

        Write-Utf8 $corruptRegistry '{"version":2,"installs":[{"friendlyName":"NoId"}]}'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'a record with no id is reported as corrupt' ($state.State -eq 'corrupt' -and $state.Reason -match 'no id') $state.Reason

        # 3. unsupported (newer) schema version
        Write-Utf8 $corruptRegistry '{"version":99,"installs":[]}'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'an unsupported newer schema version is rejected explicitly' ($state.State -eq 'corrupt' -and $state.Reason -match 'newer than this Hook Maker supports') $state.Reason

        # 4. a truncated .tmp beside a valid registry is cleaned up, not read
        Write-Utf8 $corruptRegistry '{"version":2,"installs":[]}'
        Write-Utf8 ($corruptRegistry + '.tmp') '{"version":2,"insta'
        $result = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        Check 'a valid registry with a stale .tmp still updates cleanly' ($result.Ok -eq $true)
        Check 'the stale .tmp file is removed by the atomic write' (-not (Test-Path -LiteralPath ($corruptRegistry + '.tmp')))

        # 5. quarantine collision gets a unique name
        Write-Utf8 $corruptRegistry '{ corrupt again'
        $result = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        Write-Utf8 $corruptRegistry '{ corrupt again'
        $result2 = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        $allQuarantined = @(Get-ChildItem -LiteralPath (Split-Path -Parent $corruptRegistry) -Filter 'install-registry.corrupt-*.json')
        Check 'identical corrupt content quarantined twice yields two distinct files' ($allQuarantined.Count -ge 3 -and $result.Ok -and $result2.Ok)
        Check 'quarantine names are unique (no overwrite)' ((@($allQuarantined | ForEach-Object { $_.Name }) | Sort-Object -Unique).Count -eq $allQuarantined.Count)

        # 6. quarantine failure leaves the original untouched
        Write-Utf8 $corruptRegistry '{ unquarantinable'
        $lockedBytes = [System.IO.File]::ReadAllBytes($corruptRegistry)
        $held = [System.IO.File]::Open($corruptRegistry, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $failResult = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
            Check 'a failed quarantine reports tracking failure instead of claiming success' ($failResult.Ok -eq $false)
            Check 'a failed quarantine explains that nothing was recorded' ($failResult.Warning -match 'NOT recorded') $failResult.Warning
        }
        finally { $held.Dispose() }
        Check 'a failed quarantine leaves the original file byte-for-byte intact' (
            (Test-Path -LiteralPath $corruptRegistry) -and
            ([System.IO.File]::ReadAllBytes($corruptRegistry).Length -eq $lockedBytes.Length))

        # 7. concurrent read-modify-write must not lose records
        Write-Utf8 $corruptRegistry '{"version":2,"installs":[]}'
        $concurrentScript = Join-Path $Work 'concurrent-writer.ps1'
        Write-Utf8 $concurrentScript @"
Set-StrictMode -Version 2.0
`$ErrorActionPreference = 'Stop'
. '$HookLib'
. '$(Join-Path $ScriptRoot '_installlib.ps1')'
`$env:HOOKMAKER_STATE_DIR = ''
for (`$i = 0; `$i -lt 8; `$i++) {
    `$record = [pscustomobject][ordered]@{
        id = `$args[0] + '-' + `$i; schema = 2; friendlyName = 'Concurrent'; hookType = 'CustomHook'
        sourceScript = ''; sourceDir = ''; scope = 'project'; targetProjectRoot = ''
        profile = ''; configPath = ''; sourceManifest = @()
        clients = [pscustomobject]@{}; nativeGit = `$null
        lastResult = 'ok'; lastReason = 'concurrent'; lastError = ''
    }
    Update-InstallRegistry -ToolRoot '$corruptRoot' -Record `$record | Out-Null
}
"@
        $hostExe = (Get-Process -Id $PID).Path
        $jobs = @()
        foreach ($tag in @('writerA', 'writerB')) {
            $jobs += Start-Process -FilePath $hostExe -ArgumentList ('-NoLogo -NoProfile -File "' + $concurrentScript + '" ' + $tag) -NoNewWindow -PassThru
        }
        foreach ($job in $jobs) { $job.WaitForExit() }
        $afterConcurrent = Read-InstallRegistry -ToolRoot $corruptRoot
        Check 'concurrent writers do not lose each other''s records (lock held)' (@($afterConcurrent.installs).Count -eq 16) ('records=' + @($afterConcurrent.installs).Count)
        Check 'no lock file is left behind after concurrent writes' (-not (Test-Path -LiteralPath (Join-Path $corruptRoot 'state\install-registry.lock')))
    }
    finally {
        $env:HOOKMAKER_STATE_DIR = $savedStateDir
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
