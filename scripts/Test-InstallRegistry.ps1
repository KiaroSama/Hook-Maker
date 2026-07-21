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
        Check 'manifest covers the hook-PRIVATE _hooklib.ps1' (@($rec.sourceManifest | Where-Object { $_.path -eq ((Get-HookFriendlyName $rec.friendlyName).ToLowerInvariant() + '/_hooklib.ps1') }).Count -eq 1)
        Check 'no shared runtime-root library is tracked any more' (@($rec.sourceManifest | Where-Object { $_.path -eq '_hooklib.ps1' }).Count -eq 0)
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
        $rMissingSrc = Invoke-Wizard -Config $cfgMissingSrc -Answers @('1', '4', '', 'exit')
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
        $rMissingTgt = Invoke-Wizard -Config $cfgMissingTgt -Answers @('1', '4', '', 'exit')
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
    # The managed manifest must cover EVERY file the installer copies, not
    # just the main script + _hooklib + sync config.
    # =====================================================================
    Write-Host '--- Test-Run-Guard ships its guarded runner beside the hook (Review-1) ---' -ForegroundColor Cyan
    $trgHook = Join-Path $RealHooksDir 'Test-Run-Guard\Test-Run-Guard.ps1'
    if (Test-Path -LiteralPath $trgHook -PathType Leaf) {
        $trgPlan = @(Get-InstallPlanFor -HookScript $trgHook -ToolRoot $ToolRoot)
        $trgRunner = @($trgPlan | Where-Object { $_.relativePath -eq 'Test-Run-Guard/scripts/Run-Tests-Guarded.ps1' })
        Check 'the install plan ships scripts/Run-Tests-Guarded.ps1 inside the Test-Run-Guard runtime' ($trgRunner.Count -eq 1) (($trgPlan | ForEach-Object { $_.relativePath }) -join ', ')
        Check 'the shipped runner is an Immutable managed artifact (drift-repairable)' ($trgRunner.Count -eq 1 -and $trgRunner[0].ownership -eq 'Immutable') ([string]$trgRunner[0].ownership)
        # No OTHER hook drags the runner along.
        $secHook = Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1'
        if (Test-Path -LiteralPath $secHook -PathType Leaf) {
            $secPlan = @(Get-InstallPlanFor -HookScript $secHook -ToolRoot $ToolRoot)
            Check 'an unrelated hook does NOT ship the guarded runner' (@($secPlan | Where-Object { $_.relativePath -match 'Run-Tests-Guarded' }).Count -eq 0)
        }
    }

    # =====================================================================
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

        # 6. An UNEXPECTED file inside a managed runtime directory is drift.
        # The old behaviour excluded .log/.tmp/.bak by extension - a second
        # source of truth that disagreed with the install plan (it also excluded
        # the generated SYNC-PROJECTS.txt, which made every sync-engine install
        # permanently stale). Mutable artifacts are now declared by exact path
        # via $script:ManagedRuntimeMutablePaths, intentionally empty because no
        # shipped hook writes into its own runtime directory.
        $strayFile = Join-Path (Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest') 'run.log'
        Write-Utf8 $strayFile 'runtime noise'
        $strayResult = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'an unexpected file in a managed runtime directory is detected as drift' ($strayResult.Status -eq 'update') $strayResult.Detail
        Remove-Item -LiteralPath $strayFile -Force
        Check 'removing the unexpected file restores current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')
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
    # =====================================================================
    # COMPONENT-LEVEL REPAIR: only the damaged component is reinstalled.
    # Repairing a healthy client would rewrite its settings, add another
    # timestamped backup and bump its runtime mtimes for no reason.
    Write-Host '--- only the damaged component is repaired; healthy ones are untouched ---' -ForegroundColor Cyan
    $compProj = New-Proj 'ComponentRepairProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $compProj *> $null
    $compRec = @(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $compProj })[0]
    Check 'the fixture is installed for both clients' ((@(Get-InstalledClientNames -Record $compRec) -join ',') -eq 'claude,codex')

    $compEval = Get-InstallIntegrity -Record $compRec -ToolRoot $ToolRoot
    Check 'a clean install is current' ($compEval.Status -eq 'current') $compEval.Detail
    Check 'integrity returns a per-component breakdown' ($null -ne $compEval.PSObject.Properties['Components'] -and @($compEval.Components).Count -ge 3)
    Check 'every component reports current' (@($compEval.Components | Where-Object { $_.Status -ne 'current' }).Count -eq 0)

    # Damage ONLY the Claude runtime.
    $compClaudeScript = [string]$compRec.clients.claude.runtimeScript
    $compCodexScript = [string]$compRec.clients.codex.runtimeScript
    $compCodexSettings = [string]$compRec.clients.codex.settingsPath
    Add-Content -LiteralPath $compClaudeScript -Value '# tampered'
    $compEval2 = Get-InstallIntegrity -Record $compRec -ToolRoot $ToolRoot
    $compClaude = @($compEval2.Components | Where-Object { $_.Name -eq 'claude' })[0]
    $compCodex = @($compEval2.Components | Where-Object { $_.Name -eq 'codex' })[0]
    $compSource = @($compEval2.Components | Where-Object { $_.Name -eq 'source' })[0]
    Check 'the damaged client is reported as needing update' ($compClaude.Status -eq 'update') $compClaude.Detail
    Check 'the healthy client is still reported current' ($compCodex.Status -eq 'current')
    Check 'source is still current (only the installed copy drifted)' ($compSource.Status -eq 'current')

    # Snapshot the healthy client, then repair only what is damaged.
    $compCodexHash = (Get-FileHash -LiteralPath $compCodexScript -Algorithm SHA256).Hash
    $compCodexMtime = (Get-Item -LiteralPath $compCodexScript).LastWriteTimeUtc
    $compCodexJson = [System.IO.File]::ReadAllText($compCodexSettings)
    $compCodexSettingsMtime = (Get-Item -LiteralPath $compCodexSettings).LastWriteTimeUtc
    $compCodexBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $compCodexSettings) -Filter '*.backup-*' -ErrorAction SilentlyContinue).Count
    Start-Sleep -Milliseconds 1200

    $compDamaged = @($compEval2.Components |
        Where-Object { $_.Status -eq 'update' -and $_.Name -ne 'source' -and $_.Name -ne 'nativeGit' } |
        ForEach-Object { [string]$_.Name })
    Check 'only the damaged client is selected for repair' ((@($compDamaged) -join ',') -eq 'claude')
    foreach ($compClient in $compDamaged) {
        $compClientArgs = if ($compClient -eq 'claude') { @{ ClaudeOnly = $true } } else { @{ CodexOnly = $true } }
        & $InstallScript -CustomHook ([string]$compRec.sourceScript) -TargetProject ([string]$compRec.targetProjectRoot) -Events @($compRec.clients.$compClient.events) @compClientArgs *> $null
    }
    $compRecAfter = @(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $compProj })[0]
    Check 'the damaged client is repaired back to current' ((Get-InstallIntegrity -Record $compRecAfter -ToolRoot $ToolRoot).Status -eq 'current')
    Check 'the healthy runtime bytes are unchanged' ((Get-FileHash -LiteralPath $compCodexScript -Algorithm SHA256).Hash -eq $compCodexHash)
    Check 'the healthy runtime mtime is unchanged' ((Get-Item -LiteralPath $compCodexScript).LastWriteTimeUtc -eq $compCodexMtime)
    Check 'the healthy settings content is unchanged' ([System.IO.File]::ReadAllText($compCodexSettings) -eq $compCodexJson)
    Check 'the healthy settings file was not rewritten (mtime unchanged)' ((Get-Item -LiteralPath $compCodexSettings).LastWriteTimeUtc -eq $compCodexSettingsMtime)
    Check 'no extra backup was created for the healthy client' (@(Get-ChildItem -LiteralPath (Split-Path -Parent $compCodexSettings) -Filter '*.backup-*' -ErrorAction SilentlyContinue).Count -eq $compCodexBackups)

    # A SOURCE change is a shared dependency: every client is stale by
    # definition and they must be repaired together.
    $fixtureShared = New-FixtureHook 'ZZZ-Regtest-Sharedsource' "exit 0`n"
    try {
        $sharedProj = New-Proj 'SharedSourceProj'
        & $InstallScript -CustomHook $fixtureShared -Events @('Stop') -TargetProject $sharedProj *> $null
        $sharedRec = @(Get-RecordsFor 'ZZZ-Regtest-Sharedsource')[0]
        Write-Utf8 $fixtureShared "exit 0 # changed`n"
        $sharedEval = Get-InstallIntegrity -Record $sharedRec -ToolRoot $ToolRoot
        $sharedDamaged = @($sharedEval.Components | Where-Object { $_.Status -eq 'update' } | ForEach-Object { [string]$_.Name })
        Check 'a source change marks the source component damaged' ($sharedDamaged -contains 'source')
        Check 'a source change marks BOTH clients damaged (shared dependency)' (($sharedDamaged -contains 'claude') -and ($sharedDamaged -contains 'codex'))
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Sharedsource' }
    # =====================================================================
    # Every installer-OWNED registration field is verified independently.
    # The previous check accepted a handler when EITHER command form matched,
    # so a corrupted Windows command stayed hidden behind a still-correct
    # portable one (Codex handlers carry both).
    Write-Host '--- every owned registration field drifts independently ---' -ForegroundColor Cyan
    $fieldProj = New-Proj 'OwnedFieldsProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $fieldProj *> $null
    function Get-FieldRecord { return @(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $fieldProj })[0] }
    $fieldRec = Get-FieldRecord
    Check 'baseline owned-field install is current' ((Get-InstallIntegrity -Record $fieldRec -ToolRoot $ToolRoot).Status -eq 'current')
    Check 'the codex subrecord records BOTH command forms' (
        (-not [string]::IsNullOrWhiteSpace([string]$fieldRec.clients.codex.command)) -and
        (-not [string]::IsNullOrWhiteSpace([string]$fieldRec.clients.codex.commandWindows)))
    Check 'the subrecord records the handler type' ([string]$fieldRec.clients.codex.handlerType -eq 'command')

    $fieldCodexSettings = [string]$fieldRec.clients.codex.settingsPath
    $fieldClaudeSettings = [string]$fieldRec.clients.claude.settingsPath
    $savedCodexJson = [System.IO.File]::ReadAllText($fieldCodexSettings)
    $savedClaudeJson = [System.IO.File]::ReadAllText($fieldClaudeSettings)
    function Set-StopHandlerField {
        param([string]$Path, [string]$Field, $Value)
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $handler = @(@($json.hooks.Stop) | ForEach-Object { $_.hooks })[0]
        if ($null -eq $handler.PSObject.Properties[$Field]) { $handler | Add-Member -MemberType NoteProperty -Name $Field -Value $Value }
        else { $handler.$Field = $Value }
        [System.IO.File]::WriteAllText($Path, ($json | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
    }
    function Restore-Settings { param([string]$Path, [string]$Saved) [System.IO.File]::WriteAllText($Path, $Saved, (New-Object System.Text.UTF8Encoding $false)) }

    Set-StopHandlerField $fieldCodexSettings 'commandWindows' 'powershell.exe -File "C:\elsewhere\other.ps1"'
    $driftWindows = Get-InstallIntegrity -Record (Get-FieldRecord) -ToolRoot $ToolRoot
    Check 'a corrupted commandWindows is caught even though command still matches' (($driftWindows.Status -eq 'update') -and ($driftWindows.Detail -match 'commandWindows')) $driftWindows.Detail
    Restore-Settings $fieldCodexSettings $savedCodexJson

    Set-StopHandlerField $fieldCodexSettings 'command' 'pwsh -File "C:\elsewhere\other.ps1"'
    $driftCommand = Get-InstallIntegrity -Record (Get-FieldRecord) -ToolRoot $ToolRoot
    Check 'a corrupted portable command is caught' (($driftCommand.Status -eq 'update') -and ($driftCommand.Detail -match 'command changed')) $driftCommand.Detail
    Restore-Settings $fieldCodexSettings $savedCodexJson

    Set-StopHandlerField $fieldCodexSettings 'statusMessage' 'totally different'
    $driftStatus = Get-InstallIntegrity -Record (Get-FieldRecord) -ToolRoot $ToolRoot
    Check 'a changed statusMessage is caught' (($driftStatus.Status -eq 'update') -and ($driftStatus.Detail -match 'statusMessage')) $driftStatus.Detail
    Restore-Settings $fieldCodexSettings $savedCodexJson

    Set-StopHandlerField $fieldCodexSettings 'type' 'prompt'
    $driftType = Get-InstallIntegrity -Record (Get-FieldRecord) -ToolRoot $ToolRoot
    Check 'a changed handler type is caught' (($driftType.Status -eq 'update') -and ($driftType.Detail -match 'handler type')) $driftType.Detail
    Restore-Settings $fieldCodexSettings $savedCodexJson

    Set-StopHandlerField $fieldClaudeSettings 'timeout' 999
    $driftTimeout = Get-InstallIntegrity -Record (Get-FieldRecord) -ToolRoot $ToolRoot
    Check 'a changed timeout is caught' (($driftTimeout.Status -eq 'update') -and ($driftTimeout.Detail -match 'timeout')) $driftTimeout.Detail
    Restore-Settings $fieldClaudeSettings $savedClaudeJson

    Check 'restoring every field returns the install to current' ((Get-InstallIntegrity -Record (Get-FieldRecord) -ToolRoot $ToolRoot).Status -eq 'current')

    # matcher drift needs a SessionStart registration (only that event carries one)
    $matcherProj = New-Proj 'MatcherDriftProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('SessionStart') -TargetProject $matcherProj -ClaudeOnly *> $null
    $matcherRec = @(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $matcherProj })[0]
    $matcherSettings = [string]$matcherRec.clients.claude.settingsPath
    $matcherJson = Get-Content -LiteralPath $matcherSettings -Raw | ConvertFrom-Json
    @($matcherJson.hooks.SessionStart)[0].matcher = 'startup'
    [System.IO.File]::WriteAllText($matcherSettings, ($matcherJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
    $driftMatcher = Get-InstallIntegrity -Record (@(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $matcherProj })[0]) -ToolRoot $ToolRoot
    Check 'a changed matcher is caught' (($driftMatcher.Status -eq 'update') -and ($driftMatcher.Detail -match 'matcher')) $driftMatcher.Detail
    # =====================================================================
    # STRUCTURED OUTCOME CONTRACT: programmatic callers must never infer
    # success from console text or from "no exception was thrown". The
    # installer emits a machine-readable document describing each component,
    # and distinguishes "installed but tracking failed" from real success.
    Write-Host '--- the installer emits a structured, machine-readable result ---' -ForegroundColor Cyan
    $resultProj = New-Proj 'StructuredResultProj'
    $resultFile = Join-Path $Work 'install-result.json'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $resultProj -ResultPath $resultFile *> $null
    Check 'a result document is written when -ResultPath is given' (Test-Path -LiteralPath $resultFile)
    $resultDoc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    Check 'the result document is versioned' ([int]$resultDoc.schema -ge 1)
    Check 'a fully successful install reports overall=ok' ([string]$resultDoc.overall -eq 'ok')
    $resultComponents = @($resultDoc.components | ForEach-Object { [string]$_.component })
    Check 'per-component results are reported for both clients' (($resultComponents -contains 'claude') -and ($resultComponents -contains 'codex'))
    Check 'the registry component is reported' ($resultComponents -contains 'registry')
    Check 'the native-git component is reported (skipped for a plain hook)' ($resultComponents -contains 'nativeGit')
    $nativeComp = @($resultDoc.components | Where-Object { $_.component -eq 'nativeGit' })[0]
    Check 'a non-applicable component is skipped, not failed' ([string]$nativeComp.status -eq 'skipped')
    Check 'every component carries a timestamp' (@($resultDoc.components | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.atUtc) }).Count -eq 0)
    $resultRaw = [System.IO.File]::ReadAllText($resultFile)
    Check 'the result document contains no .env values or secrets' (($resultRaw -notmatch 'EVENTS=') -and ($resultRaw -notmatch 'SECRET'))

    # Tracking failure must be reported as PARTIAL, never as success: the
    # runtime and settings did land, but the install is no longer trackable.
    $partialProj = New-Proj 'PartialResultProj'
    $partialResultFile = Join-Path $Work 'install-result-partial.json'
    $savedStateDir = $env:HOOKMAKER_STATE_DIR
    $blockedStateDir = Join-Path $Work 'blocked-state'
    New-Item -ItemType Directory -Path $blockedStateDir -Force | Out-Null
    # A DIRECTORY where the registry file must be makes the registry write fail
    # while runtime and settings still succeed.
    New-Item -ItemType Directory -Path (Join-Path $blockedStateDir 'install-registry.json') -Force | Out-Null
    try {
        $env:HOOKMAKER_STATE_DIR = $blockedStateDir
        & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $partialProj -ClaudeOnly -ResultPath $partialResultFile *> $null
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedStateDir }
    Check 'a result document is still written when tracking fails' (Test-Path -LiteralPath $partialResultFile)
    $partialDoc = Get-Content -LiteralPath $partialResultFile -Raw | ConvertFrom-Json
    Check 'a tracking failure is reported as partial, NOT ok' ([string]$partialDoc.overall -eq 'partial')
    $registryComp = @($partialDoc.components | Where-Object { $_.component -eq 'registry' })[0]
    Check 'the registry component is marked trackingFailed' ([string]$registryComp.status -eq 'trackingFailed')
    Check 'the client component still reports ok (settings really were written)' (@($partialDoc.components | Where-Object { $_.component -eq 'claude' -and $_.status -eq 'ok' }).Count -eq 1)
    Check 'the hook really was installed despite the tracking failure' (Test-Path -LiteralPath (Join-Path $partialProj '.claude\settings.local.json'))
    # =====================================================================
    # CONCURRENCY: two REAL processes installing DIFFERENT hooks into the same
    # settings file must not lose each other's handlers. Every read-modify-write
    # of a settings file is held under a crash-aware lock on that file.
    Write-Host '--- concurrent installs into one settings file keep both handlers ---' -ForegroundColor Cyan
    $concProj = New-Proj 'ConcurrencyProj'
    $fixtureA = New-FixtureHook 'ZZZ-Regtest-Concurrenta' "exit 0`n"
    $fixtureB = New-FixtureHook 'ZZZ-Regtest-Concurrentb' "exit 0`n"
    try {
        $hostExe = (Get-Process -Id $PID).Path
        $concOutA = Join-Path $Work 'conc-a.out'; $concErrA = Join-Path $Work 'conc-a.err'
        $concOutB = Join-Path $Work 'conc-b.out'; $concErrB = Join-Path $Work 'conc-b.err'
        function Start-ConcurrentInstall {
            param([string]$HookPath, [string]$OutFile, [string]$ErrFile)
            $argLine = '-NoLogo -NoProfile -File "' + $InstallScript + '" -CustomHook "' + $HookPath + '" -Events Stop -TargetProject "' + $concProj + '" -ClaudeOnly'
            $startArgs = @{
                FilePath = $hostExe; ArgumentList = $argLine
                RedirectStandardOutput = $OutFile; RedirectStandardError = $ErrFile
                WorkingDirectory = $SafeCwd; NoNewWindow = $true; PassThru = $true
            }
            if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
                $startArgs.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir }
            }
            return (Start-Process @startArgs)
        }
        # Launch both, THEN wait: they must genuinely overlap.
        $procA = Start-ConcurrentInstall -HookPath $fixtureA -OutFile $concOutA -ErrFile $concErrA
        $procB = Start-ConcurrentInstall -HookPath $fixtureB -OutFile $concOutB -ErrFile $concErrB
        $procA.WaitForExit()
        $procB.WaitForExit()

        Check 'concurrent install A exited 0' ($procA.ExitCode -eq 0) ([System.IO.File]::ReadAllText($concErrA))
        Check 'concurrent install B exited 0' ($procB.ExitCode -eq 0) ([System.IO.File]::ReadAllText($concErrB))
        Check 'concurrent install A produced no stderr' ([string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($concErrA))) ([System.IO.File]::ReadAllText($concErrA))
        Check 'concurrent install B produced no stderr' ([string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($concErrB))) ([System.IO.File]::ReadAllText($concErrB))

        $concSettings = Join-Path $concProj '.claude\settings.local.json'
        Check 'the shared settings file is still valid JSON' ($null -ne (Get-Content -LiteralPath $concSettings -Raw | ConvertFrom-Json))
        $concJson = Get-Content -LiteralPath $concSettings -Raw | ConvertFrom-Json
        $concHandlers = @(@($concJson.hooks.Stop) | ForEach-Object { $_.hooks })
        $hasA = @($concHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*ZZZ-Regtest-Concurrenta*' }).Count
        $hasB = @($concHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*ZZZ-Regtest-Concurrentb*' }).Count
        Check 'hook A survived the concurrent write' ($hasA -eq 1)
        Check 'hook B survived the concurrent write (neither lost the other)' ($hasB -eq 1)
        Check 'both records were tracked in the registry' ((@(Get-RecordsFor 'ZZZ-Regtest-Concurrenta').Count -eq 1) -and (@(Get-RecordsFor 'ZZZ-Regtest-Concurrentb').Count -eq 1))
        Check 'no settings lock file is left behind' (-not (Test-Path -LiteralPath ($concSettings + '.hookmaker-lock')))
    }
    finally {
        Remove-FixtureHook 'ZZZ-Regtest-Concurrenta'
        Remove-FixtureHook 'ZZZ-Regtest-Concurrentb'
    }
    # =====================================================================
    # PER-COMPONENT HISTORY: a partial failure must stay visible afterwards
    # instead of being flattened into one overall "ok".
    Write-Host '--- per-component outcomes are persisted in bounded history ---' -ForegroundColor Cyan
    $histProj = New-Proj 'ComponentHistoryProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $histProj -ClaudeOnly *> $null
    $histRec = @(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $histProj })[0]
    Check 'the record carries per-component outcomes for the last attempt' (@($histRec.lastComponents).Count -ge 2)
    $histNames = @($histRec.lastComponents | ForEach-Object { [string]$_.component })
    Check 'the client component is recorded' ($histNames -contains 'claude')
    # The registry's own outcome cannot be inside the record it is writing;
    # it is reported in the structured result document instead (tested above).
    Check 'the native-git component is recorded' ($histNames -contains 'nativeGit')
    Check 'history entries carry the component breakdown' (@(@($histRec.history)[-1].components).Count -ge 2)
    Check 'history entries are timestamped' (-not [string]::IsNullOrWhiteSpace([string](@($histRec.history)[-1].ts)))

    # Reinstall a few times: history must stay bounded, never grow forever.
    for ($histRun = 0; $histRun -lt 3; $histRun++) {
        & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $histProj -ClaudeOnly *> $null
    }
    $histRec2 = @(Get-RecordsFor 'Ai-Memory-Check' | Where-Object { $_.targetProjectRoot -eq $histProj })[0]
    Check 'history grows across attempts' (@($histRec2.history).Count -gt 1)
    Check 'history stays bounded (never unbounded growth)' (@($histRec2.history).Count -le 10)
    $histRaw = ($histRec2 | ConvertTo-Json -Depth 30)
    Check 'history stores no .env values or file contents' (($histRaw -notmatch 'EVENTS=') -and ($histRaw -notmatch 'COOLDOWN_MINUTES='))
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

        $originalHookLibBytes = [System.IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $claudeScript) '_hooklib.ps1'))

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

        Add-Content -LiteralPath (Join-Path (Split-Path -Parent $claudeScript) '_hooklib.ps1') -Value '# tampered'

        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot

        Check 'a stale private _hooklib.ps1 is planned for update' ($d.Status -eq 'update')

        Check 'a stale private runtime library is reported by path' ($d.Detail -match 'private runtime library is stale') $d.Detail

        Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $claudeScript) '_hooklib.ps1') -Force

        $d = Get-InstallIntegrity -Record $recDrift -ToolRoot $ToolRoot

        Check 'a missing private runtime library is reported by path' ($d.Detail -match 'private runtime library is missing') $d.Detail

        [System.IO.File]::WriteAllBytes((Join-Path (Split-Path -Parent $claudeScript) '_hooklib.ps1'), $originalHookLibBytes)

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
    # DEFECT 1: a structured result document is guaranteed for every terminal
    # outcome, not only the happy path. Validation, runtime-phase and
    # native-git-phase failures all THROW (preserving prior behavior for
    # callers that don't pass -ResultPath) but must still land a valid,
    # correctly-attributed result document when -ResultPath is given, via
    # Install-Hook.ps1's top-level trap.
    Write-Host '--- a structured result is written for every terminal outcome, not only success ---' -ForegroundColor Cyan
    $d1Hook = Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1'

    # 1a. validation failure (pre-mutation, phase=validation)
    $d1ValProj = New-Proj 'D1ValidationFail'
    $d1ValResult = Join-Path $Work 'd1-validation.json'
    $d1ValThrew = $false
    try { & $InstallScript -CustomHook $d1Hook -TargetProject $d1ValProj -Events @('Stop') -ClaudeOnly -CodexOnly -ResultPath $d1ValResult *> $null } catch { $d1ValThrew = $true }
    Check 'validation failure still throws (original behavior preserved)' $d1ValThrew
    Check 'validation failure still writes a result document' (Test-Path -LiteralPath $d1ValResult)
    $d1ValDoc = Get-Content -LiteralPath $d1ValResult -Raw | ConvertFrom-Json
    Check 'validation failure result document is valid JSON with overall=failed' ([string]$d1ValDoc.overall -eq 'failed')
    $d1ValComp = @($d1ValDoc.components | Where-Object { $_.component -eq 'validation' })[0]
    Check 'validation failure is attributed to the validation component' ($null -ne $d1ValComp -and [string]$d1ValComp.status -eq 'failed')
    Check 'validation failure mutated nothing' (-not (Test-Path -LiteralPath (Join-Path $d1ValProj '.claude')))

    # 1b. runtime-phase failure (mid-pipeline, phase=claude): the source
    # script is exclusively locked so plan-building/staging cannot read it,
    # forcing a genuine throw AFTER validation has already passed.
    $d1RtDir = Join-Path $RealHooksDir 'ZZZ-Regtest-Runtimefail'
    New-Item -ItemType Directory -Path $d1RtDir -Force | Out-Null
    $d1RtHook = Join-Path $d1RtDir 'ZZZ-Regtest-Runtimefail.ps1'
    Write-Utf8 $d1RtHook "exit 0`n"
    try {
        $d1RtProj = New-Proj 'D1RuntimeFail'
        $d1RtResult = Join-Path $Work 'd1-runtime.json'
        $d1RtHeld = [System.IO.File]::Open($d1RtHook, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $d1RtThrew = $false
        try {
            try { & $InstallScript -CustomHook $d1RtHook -TargetProject $d1RtProj -Events @('Stop') -ResultPath $d1RtResult *> $null } catch { $d1RtThrew = $true }
        }
        finally { $d1RtHeld.Dispose() }
        Check 'a mid-pipeline runtime failure throws' $d1RtThrew
        Check 'a mid-pipeline runtime failure still writes a result document' (Test-Path -LiteralPath $d1RtResult)
        $d1RtDoc = Get-Content -LiteralPath $d1RtResult -Raw | ConvertFrom-Json
        Check 'a runtime failure result document reports overall=failed' ([string]$d1RtDoc.overall -eq 'failed')
        $d1RtComp = @($d1RtDoc.components | Where-Object { $_.component -eq 'claude' })[0]
        Check 'a runtime failure is attributed to the claude component' ($null -ne $d1RtComp -and [string]$d1RtComp.status -eq 'failed')
    }
    finally { Remove-Item -LiteralPath $d1RtDir -Recurse -Force -ErrorAction SilentlyContinue }

    # 1c. native-git-phase failure (phase=nativeGit): a stale
    # pre-push.hookmaker-existing collides with a real (non-marker) pre-push
    # hook, which Install-IgnorePrePush already refuses to silently overwrite.
    $d1NatProj = New-Proj 'D1NativeFail'
    & git -C $d1NatProj init -q -b main 2>$null
    & git -C $d1NatProj config user.email 't@t' 2>$null
    & git -C $d1NatProj config user.name 't' 2>$null
    $d1NatGitHooks = Join-Path $d1NatProj '.git\hooks'
    New-Item -ItemType Directory -Path $d1NatGitHooks -Force | Out-Null
    Write-Utf8 (Join-Path $d1NatGitHooks 'pre-push') "#!/bin/sh`necho user-hook`n"
    Write-Utf8 (Join-Path $d1NatGitHooks 'pre-push.hookmaker-existing') "#!/bin/sh`necho stale-leftover`n"
    $d1NatResult = Join-Path $Work 'd1-native.json'
    $d1NatThrew = $false
    try { & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -TargetProject $d1NatProj -Events @('Stop') -ResultPath $d1NatResult *> $null } catch { $d1NatThrew = $true }
    Check 'a native pre-push conflict throws' $d1NatThrew
    Check 'a native pre-push conflict still writes a result document' (Test-Path -LiteralPath $d1NatResult)
    $d1NatDoc = Get-Content -LiteralPath $d1NatResult -Raw | ConvertFrom-Json
    Check 'a native failure result document reports overall=failed' ([string]$d1NatDoc.overall -eq 'failed')
    $d1NatComp = @($d1NatDoc.components | Where-Object { $_.component -eq 'nativeGit' })[0]
    Check 'a native failure is attributed to the nativeGit component' ($null -ne $d1NatComp -and [string]$d1NatComp.status -eq 'failed')
    Check 'the claude component still reports ok (it committed before native failed)' (@($d1NatDoc.components | Where-Object { $_.component -eq 'claude' -and $_.status -eq 'ok' }).Count -eq 1)

    # 1d. real spawned process: exit code and stderr are preserved, and the
    # in-process test above cannot prove genuine end-user/CI process behavior.
    $d1SpProj = New-Proj 'D1SpawnedFail'
    $d1SpResult = Join-Path $Work 'd1-spawned.json'
    $d1SpArgLine = '-NoLogo -NoProfile -File "' + $InstallScript + '" -CustomHook "' + $d1Hook + '" -TargetProject "' + $d1SpProj + '" -Events Stop -ClaudeOnly -CodexOnly -ResultPath "' + $d1SpResult + '"'
    $d1SpOut = Join-Path $Work 'd1-spawned.out'; $d1SpErr = Join-Path $Work 'd1-spawned.err'
    $d1SpStart = @{
        FilePath = (Get-Process -Id $PID).Path; ArgumentList = $d1SpArgLine
        RedirectStandardOutput = $d1SpOut; RedirectStandardError = $d1SpErr
        NoNewWindow = $true; PassThru = $true; Wait = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) { $d1SpStart.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir } }
    $d1SpProc = Start-Process @d1SpStart
    Check 'a spawned failing install exits non-zero' ($d1SpProc.ExitCode -ne 0)
    Check 'a spawned failing install still writes a result document' (Test-Path -LiteralPath $d1SpResult)
    Check 'a spawned failing install does not swallow the original error text' ((Get-Content -LiteralPath $d1SpErr -Raw) -match 'ClaudeOnly.*CodexOnly|mutually exclusive|both.*Claude.*Codex')

    # 1e. success still reports overall=ok (the baseline this all must not break)
    $d1OkProj = New-Proj 'D1Success'
    $d1OkResult = Join-Path $Work 'd1-ok.json'
    & $InstallScript -CustomHook $d1Hook -TargetProject $d1OkProj -Events @('Stop') -ResultPath $d1OkResult *> $null
    $d1OkDoc = Get-Content -LiteralPath $d1OkResult -Raw | ConvertFrom-Json
    Check 'a fully successful install still reports overall=ok' ([string]$d1OkDoc.overall -eq 'ok')

    # =====================================================================
    # DEFECT 2: legacy runtime/config cleanup must happen only AFTER the
    # replacement runtime has staged, hash-verified and swapped - never
    # before. A failed replacement must never destroy a working legacy
    # artifact, and a successful replacement must still clean up afterward.
    Write-Host '--- legacy cleanup happens only after the replacement runtime commits ---' -ForegroundColor Cyan
    $d2Fixture = New-FixtureHook 'ZZZ-Regtest-Legacycleanup' "exit 0 # good`n"
    try {
        $d2Proj = New-Proj 'D2LegacyCleanup'
        & $InstallScript -CustomHook $d2Fixture -Events @('Stop') -TargetProject $d2Proj -ClaudeOnly *> $null
        $d2RuntimeRoot = Join-Path $d2Proj '.claude\hooks\Hook-Maker'
        $d2Script = Join-Path $d2RuntimeRoot 'ZZZ-Regtest-Legacycleanup\ZZZ-Regtest-Legacycleanup.ps1'
        Check 'baseline D2 install succeeded' (Test-Path -LiteralPath $d2Script)

        # Plant a fake legacy root-level sync-hooks.json - one of the three
        # artifacts Copy-HookRuntime cleans up post-commit.
        $d2LegacyConfig = Join-Path $d2RuntimeRoot 'sync-hooks.json'
        Write-Utf8 $d2LegacyConfig '{"legacy":true}'
        $d2LegacyBytesBefore = [System.IO.File]::ReadAllBytes($d2LegacyConfig)
        $d2GoodHash = (Get-FileHash -LiteralPath $d2Script -Algorithm SHA256).Hash

        # Force a staging failure (source locked exclusively) on a REINSTALL of
        # the SAME hook, so Copy-HookRuntime runs but Install-PlannedRuntime
        # throws before the swap - legacy cleanup must never be reached.
        $d2Held = [System.IO.File]::Open($d2Fixture, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $d2Threw = $false
        try {
            try { & $InstallScript -CustomHook $d2Fixture -Events @('Stop') -TargetProject $d2Proj -ClaudeOnly *> $null } catch { $d2Threw = $true }
        }
        finally { $d2Held.Dispose() }
        Check 'a forced staging failure on reinstall throws' $d2Threw
        Check 'the previous runtime survives a failed staging' (Test-Path -LiteralPath $d2Script)
        Check 'the previous runtime is byte-identical after a failed staging' ((Get-FileHash -LiteralPath $d2Script -Algorithm SHA256).Hash -eq $d2GoodHash)
        Check 'the legacy artifact still exists after a failed staging (cleanup never reached)' (Test-Path -LiteralPath $d2LegacyConfig)
        $d2LegacyBytesAfterFail = [System.IO.File]::ReadAllBytes($d2LegacyConfig)
        Check 'the legacy artifact is byte-identical after a failed staging' (
            ($d2LegacyBytesAfterFail.Length -eq $d2LegacyBytesBefore.Length) -and
            ((Compare-Object $d2LegacyBytesAfterFail $d2LegacyBytesBefore -SyncWindow 0 | Measure-Object).Count -eq 0))

        # Now a normal (unlocked) reinstall: staging/swap succeeds, and ONLY
        # after that does the legacy artifact get cleaned up.
        & $InstallScript -CustomHook $d2Fixture -Events @('Stop') -TargetProject $d2Proj -ClaudeOnly *> $null
        Check 'a successful reinstall keeps the runtime present' (Test-Path -LiteralPath $d2Script)
        Check 'a successful reinstall cleans up the legacy artifact afterward' (-not (Test-Path -LiteralPath $d2LegacyConfig))
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Legacycleanup' }

    # =====================================================================
    # DEFECT 3: a direct engine install fully validates its config/profile
    # BEFORE any mutation - missing file, malformed JSON, missing profiles,
    # unknown profile, duplicate profile id, malformed route, missing
    # endpoint root/name are all rejected with nothing touched.
    Write-Host '--- engine config/profile is fully validated before any mutation ---' -ForegroundColor Cyan
    function New-D3Proj { param([string]$Name) return (New-Proj ('D3' + $Name)) }
    function Assert-D3Rejected {
        param([string]$Label, [string]$ConfigPath, [string]$ProfileId = 'p', [string]$ProjSuffix)
        $proj = New-D3Proj $ProjSuffix
        $threw = $false
        try { & $InstallScript -Profile $ProfileId -ConfigPath $ConfigPath -TargetProject $proj -Events @('Stop') *> $null } catch { $threw = $true }
        Check ($Label + ' throws') $threw
        Check ($Label + ': nothing mutated') (-not (Test-Path -LiteralPath (Join-Path $proj '.claude')))
    }
    $d3MissingCfg = Join-Path $Work 'd3-missing.json'
    Assert-D3Rejected 'missing config file' $d3MissingCfg -ProjSuffix 'MissingCfg'

    $d3BadJson = Join-Path $Work 'd3-badjson.json'
    Write-Utf8 $d3BadJson '{ not json'
    Assert-D3Rejected 'malformed JSON config' $d3BadJson -ProjSuffix 'BadJson'

    $d3NoProfiles = Join-Path $Work 'd3-noprofiles.json'
    Write-Utf8 $d3NoProfiles '{"version":1}'
    Assert-D3Rejected 'config missing profiles array' $d3NoProfiles -ProjSuffix 'NoProfiles'

    $d3Real = Join-Path $Work 'd3-real.json'
    Write-Utf8 $d3Real '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"id":"r1","source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'unknown profile id' $d3Real -ProfileId 'no-such-profile' -ProjSuffix 'UnknownProfile'

    $d3Dup = Join-Path $Work 'd3-dup.json'
    Write-Utf8 $d3Dup '{"version":1,"profiles":[{"id":"p","name":"P1","routes":[]},{"id":"p","name":"P2","routes":[]}]}'
    Assert-D3Rejected 'duplicate profile id' $d3Dup -ProjSuffix 'DupProfile'

    $d3NoRouteId = Join-Path $Work 'd3-norouteid.json'
    Write-Utf8 $d3NoRouteId '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'malformed route (missing id)' $d3NoRouteId -ProjSuffix 'NoRouteId'

    $d3NoRoot = Join-Path $Work 'd3-noroot.json'
    Write-Utf8 $d3NoRoot '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"id":"r1","source":{"name":"A"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'missing endpoint root' $d3NoRoot -ProjSuffix 'NoRoot'

    $d3NoName = Join-Path $Work 'd3-noname.json'
    Write-Utf8 $d3NoName '{"version":1,"profiles":[{"id":"p","routes":[{"id":"r1","source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'profile missing name (SYNC-PROJECTS.txt needs it)' $d3NoName -ProjSuffix 'NoName'

    # A structurally valid config still installs successfully end-to-end.
    $d3GoodProj = New-D3Proj 'Good'
    & $InstallScript -Profile 'p' -ConfigPath $d3Real -TargetProject $d3GoodProj -Events @('SessionStart') -ClaudeOnly *> $null
    Check 'a valid engine config/profile still installs successfully' (Test-Path -LiteralPath (Join-Path $d3GoodProj '.claude\settings.local.json'))

    # =====================================================================
    # REGRESSION: Test-SyncConfigStructure used to default a MISSING 'routes'
    # property to @(), silently treating "no routes property at all" as a
    # valid profile with an empty route list. It now REQUIRES 'routes' to be
    # present and a genuine array. An EMPTY array ("routes":[]) is deliberately
    # still STRUCTURALLY valid (Validate-Config.ps1 validates every profile in
    # a whole file, including ones not being installed, and an emptied-out
    # placeholder group is a legitimate file state) - the stricter "the
    # profile being installed needs at least one route" rule is enforced only
    # in Install-Hook.ps1's pre-mutation engine block, tested separately below.
    Write-Host '--- Test-SyncConfigStructure requires a genuine routes array (both directions) ---' -ForegroundColor Cyan
    function New-RoutesTestConfig { param($ProfileObj) return [pscustomobject]@{ profiles = @($ProfileObj) } }

    $profMissingRoutes = [pscustomobject]@{ id = 'p'; name = 'P' }
    $rtMissing = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profMissingRoutes)
    Check 'a profile missing routes entirely is rejected' (-not $rtMissing.Ok)
    Check 'the rejection reason names the profile and the missing routes array' ($rtMissing.Reason -match "profile 'p' requires a routes array") $rtMissing.Reason

    $profNullRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = $null }
    $rtNull = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profNullRoutes)
    Check 'routes: null is rejected' (-not $rtNull.Ok) $rtNull.Reason

    $profStringRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = 'not-an-array' }
    $rtString = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profStringRoutes)
    Check 'routes as a string is rejected' (-not $rtString.Ok) $rtString.Reason

    $profObjectRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = [pscustomobject]@{ note = 'not an array' } }
    $rtObject = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profObjectRoutes)
    Check 'routes as an object (not an array) is rejected' (-not $rtObject.Ok) $rtObject.Reason

    $profNumberRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = 5 }
    $rtNumber = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profNumberRoutes)
    Check 'routes as a number is rejected' (-not $rtNumber.Ok) $rtNumber.Reason

    $profEmptyRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = @() }
    $rtEmpty = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profEmptyRoutes)
    Check 'routes: [] (empty array) is still accepted - a legitimate emptied/placeholder profile' ($rtEmpty.Ok -eq $true) $rtEmpty.Reason

    $profOneRoute = [pscustomobject]@{
        id     = 'p'; name = 'P'
        routes = @([pscustomobject]@{
                id          = 'r1'
                source      = [pscustomobject]@{ name = 'A'; root = 'C:\x' }
                destination = [pscustomobject]@{ name = 'B'; root = 'C:\y' }
            })
    }
    $rtOneRoute = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profOneRoute)
    Check 'a valid one-route profile is still accepted' ($rtOneRoute.Ok -eq $true) $rtOneRoute.Reason

    # REGRESSION: the real shipped sync-hooks.example.json still validates.
    $exampleSyncConfigPath = Join-Path $ToolRoot 'sync-hooks.example.json'
    $exampleSyncConfig = Get-Content -LiteralPath $exampleSyncConfigPath -Raw | ConvertFrom-Json
    $rtExample = Test-SyncConfigStructure -Config $exampleSyncConfig
    Check 'the shipped sync-hooks.example.json still validates' ($rtExample.Ok -eq $true) $rtExample.Reason

    # =====================================================================
    # REGRESSION: at ENGINE INSTALL time the specific profile being installed
    # must have at least one route - a zero-route install would produce a
    # hook that provably cannot sync anything plus an empty generated
    # SYNC-PROJECTS.txt. Extends Assert-D3Rejected (which only checks
    # throw + ".claude never created") with the full structured-result,
    # validation-attribution, registry and leftover-artifact assertions this
    # defect specifically requires.
    Write-Host '--- a zero-route (or routeless) profile is rejected before any engine install mutation ---' -ForegroundColor Cyan
    function Assert-EngineValidationRejected {
        param([string]$Label, [string]$ConfigPath, [string]$ProfileId, [string]$ProjSuffix)
        $proj = New-D3Proj $ProjSuffix
        $resultFile = Join-Path $Work ('routes-reject-' + $ProjSuffix + '.json')
        $threw = $false
        try { & $InstallScript -Profile $ProfileId -ConfigPath $ConfigPath -TargetProject $proj -Events @('Stop') -ResultPath $resultFile *> $null } catch { $threw = $true }
        Check ($Label + ': invocation throws') $threw

        Check ($Label + ': a structured result document is written') (Test-Path -LiteralPath $resultFile)
        $docOk = $false; $doc = $null
        try { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json; $docOk = $true } catch { }
        Check ($Label + ': the result document is valid JSON') $docOk
        Check ($Label + ': the result document reports overall=failed') ($docOk -and [string]$doc.overall -eq 'failed')

        $validationComp = $null
        if ($docOk) { $validationComp = @($doc.components | Where-Object { $_.component -eq 'validation' })[0] }
        Check ($Label + ': the failure is attributed to the validation component') ($null -ne $validationComp -and [string]$validationComp.status -eq 'failed')

        Check ($Label + ': no .claude directory was created') (-not (Test-Path -LiteralPath (Join-Path $proj '.claude')))
        Check ($Label + ': no .codex directory was created') (-not (Test-Path -LiteralPath (Join-Path $proj '.codex')))

        $recs = @((Get-Registry).installs | Where-Object { [string]$_.targetProjectRoot -eq $proj })
        Check ($Label + ': no registry record was created for this target') ($recs.Count -eq 0)

        $leftovers = @(Get-ChildItem -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue)
        Check ($Label + ': no backup/temp/staging/result-lock artifact was left in the target project') ($leftovers.Count -eq 0)
    }

    $d4ZeroRoutesCfg = Join-Path $Work 'd4-zeroroutes.json'
    Write-Utf8 $d4ZeroRoutesCfg '{"version":1,"profiles":[{"id":"p","name":"P","routes":[]}]}'
    Assert-EngineValidationRejected 'zero-route profile being installed' $d4ZeroRoutesCfg -ProfileId 'p' -ProjSuffix 'ZeroRoutes'

    $d4NoRoutesCfg = Join-Path $Work 'd4-noroutes.json'
    Write-Utf8 $d4NoRoutesCfg '{"version":1,"profiles":[{"id":"p","name":"P"}]}'
    Assert-EngineValidationRejected 'profile missing routes entirely' $d4NoRoutesCfg -ProfileId 'p' -ProjSuffix 'NoRoutesEntirely'

    # (C) The new checks must not break the happy path: a valid one-route
    # engine install still succeeds end-to-end.
    $d4GoodRoutesCfg = Join-Path $Work 'd4-goodroutes.json'
    Write-Utf8 $d4GoodRoutesCfg '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"id":"r1","source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    $d4GoodProj = New-D3Proj 'RoutesGood'
    & $InstallScript -Profile 'p' -ConfigPath $d4GoodRoutesCfg -TargetProject $d4GoodProj -Events @('SessionStart') -ClaudeOnly *> $null
    Check 'a valid one-route engine install still succeeds end-to-end (routes checks do not break the happy path)' (Test-Path -LiteralPath (Join-Path $d4GoodProj '.claude\settings.local.json'))

    # =====================================================================
    # PER-HOOK REGISTRATION TIMEOUT.
    # Both clients document `timeout` on the INDIVIDUAL hook entry, so a
    # per-hook value is registrable; the universal 60 stays the default for
    # every hook that does not ask for its own. These blocks pin the
    # compatibility guard, the bounds, per-client persistence, drift detection
    # and repair-without-collateral-damage.
    Write-Host '--- an install with no explicit timeout still writes 60 for both clients ---' -ForegroundColor Cyan
    $fixtureT1 = New-FixtureHook 'ZZZ-Regtest-Timeoutdefault'
    try {
        $projT1 = New-Proj 'TimeoutDefault'
        & $InstallScript -CustomHook $fixtureT1 -Events @('Stop') -TargetProject $projT1 *> $null
        $t1Claude = Get-Content -LiteralPath (Join-Path $projT1 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        $t1Codex = Get-Content -LiteralPath (Join-Path $projT1 '.codex\hooks.json') -Raw | ConvertFrom-Json
        Check 'claude handler timeout is 60 when -Timeout is omitted' ([int]$t1Claude.hooks.Stop[0].hooks[0].timeout -eq 60)
        Check 'codex handler timeout is 60 when -Timeout is omitted' ([int]$t1Codex.hooks.Stop[0].hooks[0].timeout -eq 60)
        $recT1 = (Get-RecordsFor 'ZZZ-Regtest-Timeoutdefault')[0]
        Check 'claude subrecord persists timeout 60 when -Timeout is omitted' ([int]$recT1.clients.claude.timeout -eq 60)
        Check 'codex subrecord persists timeout 60 when -Timeout is omitted' ([int]$recT1.clients.codex.timeout -eq 60)
        Check 'a default-timeout install is reported as current (no false drift)' ((Get-InstallIntegrity -Record $recT1 -ToolRoot $ToolRoot).Status -eq 'current')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutdefault' }

    # =====================================================================
    Write-Host '--- an explicit in-range timeout is written and persisted per client ---' -ForegroundColor Cyan
    $fixtureT2 = New-FixtureHook 'ZZZ-Regtest-Timeoutexplicit'
    try {
        $projT2 = New-Proj 'TimeoutExplicit'
        & $InstallScript -CustomHook $fixtureT2 -Events @('Stop', 'SessionStart') -TargetProject $projT2 -Timeout 180 *> $null
        $t2Claude = Get-Content -LiteralPath (Join-Path $projT2 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        $t2Codex = Get-Content -LiteralPath (Join-Path $projT2 '.codex\hooks.json') -Raw | ConvertFrom-Json
        Check 'claude handler carries the explicit timeout' ([int]$t2Claude.hooks.Stop[0].hooks[0].timeout -eq 180)
        Check 'codex handler carries the explicit timeout' ([int]$t2Codex.hooks.Stop[0].hooks[0].timeout -eq 180)
        Check 'the explicit timeout is written on EVERY registered event, not just the first' (
            [int]$t2Claude.hooks.SessionStart[0].hooks[0].timeout -eq 180 -and [int]$t2Codex.hooks.SessionStart[0].hooks[0].timeout -eq 180)
        $recT2 = (Get-RecordsFor 'ZZZ-Regtest-Timeoutexplicit')[0]
        Check 'claude subrecord persists the explicit timeout' ([int]$recT2.clients.claude.timeout -eq 180)
        Check 'codex subrecord persists the explicit timeout' ([int]$recT2.clients.codex.timeout -eq 180)
        Check 'a record with a non-default timeout still validates' ((Test-InstallRecordValid -Record $recT2).Ok)
        Check 'an explicit-timeout install is reported as current (asserted against 180, not 60)' ((Get-InstallIntegrity -Record $recT2 -ToolRoot $ToolRoot).Status -eq 'current')

        # A repair invocation (what the updater issues) carries no -Timeout, so
        # the hook's OWN value must survive rather than silently reset to 60.
        & $InstallScript -CustomHook $fixtureT2 -Events @('Stop', 'SessionStart') -TargetProject $projT2 *> $null
        $t2Again = Get-Content -LiteralPath (Join-Path $projT2 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        Check 'reinstalling without -Timeout keeps the recorded per-hook value' ([int]$t2Again.hooks.Stop[0].hooks[0].timeout -eq 180)
        Check 'the persisted per-hook value is unchanged by a no-Timeout reinstall' ([int]((Get-RecordsFor 'ZZZ-Regtest-Timeoutexplicit')[0]).clients.claude.timeout -eq 180)
        # ...and it is still explicitly overridable in both directions.
        & $InstallScript -CustomHook $fixtureT2 -Events @('Stop', 'SessionStart') -TargetProject $projT2 -Timeout 60 *> $null
        $t2Back = Get-Content -LiteralPath (Join-Path $projT2 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        Check 'an explicit -Timeout 60 returns the hook to the default' ([int]$t2Back.hooks.Stop[0].hooks[0].timeout -eq 60)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutexplicit' }

    # =====================================================================
    Write-Host '--- an out-of-range timeout is refused with a precise reason and nothing is written ---' -ForegroundColor Cyan
    $fixtureT3 = New-FixtureHook 'ZZZ-Regtest-Timeoutbounds'
    try {
        function Assert-TimeoutRejected {
            param([string]$Label, [int]$Value, [string]$ProjSuffix)
            $projReject = New-Proj ('TimeoutReject' + $ProjSuffix)
            $resultFile = Join-Path $Work ('timeout-reject-' + $ProjSuffix + '.json')
            $rejectMessage = ''
            $threw = $false
            try { & $InstallScript -CustomHook $fixtureT3 -Events @('Stop') -TargetProject $projReject -Timeout $Value -ResultPath $resultFile *> $null }
            catch { $threw = $true; $rejectMessage = [string]$_.Exception.Message }
            Check ($Label + ': the invocation is refused') $threw
            Check ($Label + ': the reason names the timeout and the allowed range') (
                $rejectMessage -match 'timeout' -and $rejectMessage -match [regex]::Escape([string]$Value) -and $rejectMessage -match '5' -and $rejectMessage -match '600') $rejectMessage
            # Refused, never clamped: a clamped value would have installed
            # something the caller never asked for.
            Check ($Label + ': no .claude registration was written') (-not (Test-Path -LiteralPath (Join-Path $projReject '.claude')))
            Check ($Label + ': no .codex registration was written') (-not (Test-Path -LiteralPath (Join-Path $projReject '.codex')))
            Check ($Label + ': nothing at all was left in the target project') (@(Get-ChildItem -LiteralPath $projReject -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0)
            Check ($Label + ': no registry record was created') (@((Get-Registry).installs | Where-Object { [string]$_.targetProjectRoot -eq $projReject }).Count -eq 0)
            $docOk = $false; $doc = $null
            if (Test-Path -LiteralPath $resultFile) { try { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json; $docOk = $true } catch { } }
            Check ($Label + ': the failure is attributed to the validation component') (
                $docOk -and [string]$doc.overall -eq 'failed' -and @($doc.components | Where-Object { $_.component -eq 'validation' -and $_.status -eq 'failed' }).Count -eq 1)
        }
        Assert-TimeoutRejected 'above the maximum' 5000 'High'
        Assert-TimeoutRejected 'below the minimum' 1 'Low'
        Assert-TimeoutRejected 'zero' 0 'Zero'
        Assert-TimeoutRejected 'negative' -30 'Negative'

        # The boundary values themselves are IN range - an off-by-one in the
        # bounds check would make the documented range a lie.
        $projEdgeLow = New-Proj 'TimeoutEdgeLow'
        & $InstallScript -CustomHook $fixtureT3 -Events @('Stop') -TargetProject $projEdgeLow -Timeout 5 -ClaudeOnly *> $null
        $projEdgeHigh = New-Proj 'TimeoutEdgeHigh'
        & $InstallScript -CustomHook $fixtureT3 -Events @('Stop') -TargetProject $projEdgeHigh -Timeout 600 -ClaudeOnly *> $null
        Check 'the minimum bound (5) is accepted' (
            [int]((Get-Content -LiteralPath (Join-Path $projEdgeLow '.claude\settings.local.json') -Raw | ConvertFrom-Json).hooks.Stop[0].hooks[0].timeout) -eq 5)
        Check 'the maximum bound (600) is accepted' (
            [int]((Get-Content -LiteralPath (Join-Path $projEdgeHigh '.claude\settings.local.json') -Raw | ConvertFrom-Json).hooks.Stop[0].hooks[0].timeout) -eq 600)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutbounds' }

    # =====================================================================
    Write-Host '--- an edited live registration timeout is drift, and update repairs ONLY it ---' -ForegroundColor Cyan
    $fixtureT4 = New-FixtureHook 'ZZZ-Regtest-Timeoutdrift'
    try {
        $projT4 = New-Proj 'TimeoutDrift'
        & $InstallScript -CustomHook $fixtureT4 -Events @('Stop') -TargetProject $projT4 -Timeout 240 -ClaudeOnly *> $null
        $t4Settings = Join-Path $projT4 '.claude\settings.local.json'
        $recT4 = (Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]
        Check 'the drift fixture starts out current' ((Get-InstallIntegrity -Record $recT4 -ToolRoot $ToolRoot).Status -eq 'current')

        # A FOREIGN handler in the SAME settings file, on its own event. It is
        # not Hook Maker's, so repairing the timeout must not touch one byte of
        # it. The installed source is left alone so the ONLY thing needing
        # repair is the timeout.
        $t4Json = Get-Content -LiteralPath $t4Settings -Raw | ConvertFrom-Json
        $t4Json.hooks | Add-Member -MemberType NoteProperty -Name 'PreCompact' -Value @(
            [pscustomobject]@{ matcher = 'manual'; hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "D:\Foreign\Watcher.ps1"'; timeout = 17; statusMessage = 'foreign watcher' }) }) -Force
        # Live drift: someone edited the registered timeout by hand.
        $t4Json.hooks.Stop[0].hooks[0].timeout = 9
        [System.IO.File]::WriteAllText($t4Settings, ($t4Json | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        # BYTE baseline of the foreign subtree, captured after it is on disk.
        $t4ForeignBefore = ((Get-Content -LiteralPath $t4Settings -Raw | ConvertFrom-Json).hooks.PreCompact | ConvertTo-Json -Depth 50)
        $t4ForeignBeforeBytes = [System.Text.Encoding]::UTF8.GetBytes($t4ForeignBefore)

        $recT4Drifted = (Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]
        $integrityT4 = Get-InstallIntegrity -Record $recT4Drifted -ToolRoot $ToolRoot
        Check 'an edited registration timeout is detected as needing an update' ($integrityT4.Status -eq 'update')
        Check 'the drift detail names the timeout, not some other field' ([string]$integrityT4.Detail -match 'timeout') ([string]$integrityT4.Detail)

        $cfgT4 = Join-Path $Work 'cfg-timeout-drift.json'; New-Config $cfgT4
        $rT4 = Invoke-Wizard -Config $cfgT4 -Answers @('1', '4', '', '0')
        Check 'the update run exits 0' ($rT4.Exit -eq 0) $rT4.Err
        $t4After = Get-Content -LiteralPath $t4Settings -Raw | ConvertFrom-Json
        Check 'update restored the recorded per-hook timeout (240, not the default 60)' ([int]$t4After.hooks.Stop[0].hooks[0].timeout -eq 240)
        Check 'the record still carries the per-hook timeout after the repair' ([int]((Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]).clients.claude.timeout -eq 240)
        Check 'the repaired installation is reported as current again' ((Get-InstallIntegrity -Record ((Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]) -ToolRoot $ToolRoot).Status -eq 'current')

        $t4ForeignAfterBytes = [System.Text.Encoding]::UTF8.GetBytes(($t4After.hooks.PreCompact | ConvertTo-Json -Depth 50))
        Check 'the foreign handler in the same settings file is byte-identical after the repair' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$t4ForeignBeforeBytes, [byte[]]$t4ForeignAfterBytes)) ($t4After.hooks.PreCompact | ConvertTo-Json -Depth 50)
        Check 'the foreign handler still appears exactly once' (
            @([regex]::Matches((Get-Content -LiteralPath $t4Settings -Raw), [regex]::Escape('D:\\Foreign\\Watcher.ps1'))).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutdrift' }

    # =====================================================================
    # Records written before timeouts were per-hook carry no `timeout` field at
    # all. They must keep validating, keep evaluating against the historical
    # 60, and keep updating - never be reported as drifted for lacking one.
    Write-Host '--- a pre-per-hook-timeout record still validates and still updates cleanly ---' -ForegroundColor Cyan
    $fixtureT5 = New-FixtureHook 'ZZZ-Regtest-Timeoutlegacy' "exit 0 # legacy v1`n"
    try {
        $projT5 = New-Proj 'TimeoutLegacy'
        & $InstallScript -CustomHook $fixtureT5 -Events @('Stop') -TargetProject $projT5 *> $null
        $legacyId = [string]((Get-RecordsFor 'ZZZ-Regtest-Timeoutlegacy')[0]).id

        # Strip the field the old writer never wrote.
        $registryT5 = Get-Registry
        foreach ($candidate in @($registryT5.installs | Where-Object { [string]$_.id -eq $legacyId })) {
            foreach ($clientName in @('claude', 'codex')) {
                $sub = Get-ClientSubrecord -Record $candidate -Client $clientName
                if ($null -ne $sub -and $null -ne $sub.PSObject.Properties['timeout']) { $sub.PSObject.Properties.Remove('timeout') }
            }
        }
        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registryT5
        $recT5 = @((Get-Registry).installs | Where-Object { [string]$_.id -eq $legacyId })[0]
        Check 'the legacy-shaped record really has no timeout field' (
            $null -eq (Get-ClientSubrecord -Record $recT5 -Client 'claude').PSObject.Properties['timeout'])
        Check 'a record with no timeout field still validates' ((Test-InstallRecordValid -Record $recT5).Ok) ([string](Test-InstallRecordValid -Record $recT5).Reason)
        Check 'a record with no timeout field is still schema 2 (id/shape compatible)' ([int]$recT5.schema -eq 2 -and [string]$recT5.id -eq $legacyId)
        Check 'a record with no timeout field is reported as current, not drifted' (
            (Get-InstallIntegrity -Record $recT5 -ToolRoot $ToolRoot).Status -eq 'current')

        # ...and it updates cleanly, gaining the historical 60 rather than
        # anything new, with its id preserved.
        Write-Utf8 $fixtureT5 "exit 0 # legacy v2 changed`n"
        $cfgT5 = Join-Path $Work 'cfg-timeout-legacy.json'; New-Config $cfgT5
        $rT5 = Invoke-Wizard -Config $cfgT5 -Answers @('1', '4', '', '0')
        Check 'the legacy-record update run exits 0' ($rT5.Exit -eq 0) $rT5.Err
        $recT5After = @((Get-Registry).installs | Where-Object { [string]$_.id -eq $legacyId })[0]
        Check 'the legacy record survives the update under the same id' ($null -ne $recT5After)
        Check 'the updated legacy record now carries the historical 60' ([int]$recT5After.clients.claude.timeout -eq 60)
        Check 'the updated legacy registration is still 60 on disk' (
            [int]((Get-Content -LiteralPath (Join-Path $projT5 '.claude\settings.local.json') -Raw | ConvertFrom-Json).hooks.Stop[0].hooks[0].timeout) -eq 60)
        Check 'the legacy record is current after the update' ((Get-InstallIntegrity -Record $recT5After -ToolRoot $ToolRoot).Status -eq 'current')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutlegacy' }

    # =====================================================================
    # D2 (StrictMode crash): a group object with NO `hooks` key at all (a
    # foreign/hand-edited entry - not a legitimate "hooks": [] group) must
    # never crash install/update under StrictMode, and must pass through
    # untouched since there is nothing on it to prove ownership over.
    Write-Host '--- a foreign event-group missing `hooks` never crashes install/update and is preserved ---' -ForegroundColor Cyan
    $fixtureForeignGroup = New-FixtureHook 'ZZZ-Regtest-Foreignnohooks'
    try {
        $projForeignGroup = New-Proj 'ForeignNoHooksProj'
        & $InstallScript -CustomHook $fixtureForeignGroup -Events @('Stop') -TargetProject $projForeignGroup -ClaudeOnly *> $null
        $foreignGroupSettings = Join-Path $projForeignGroup '.claude\settings.local.json'
        $foreignGroupJson = Get-Content -LiteralPath $foreignGroupSettings -Raw | ConvertFrom-Json
        # Hand-edit in a group with no `hooks` property at all, alongside the
        # real Hook Maker group, under the SAME event this install manages.
        $foreignGroupJson.hooks.Stop = @($foreignGroupJson.hooks.Stop) + @([pscustomobject]@{ matcher = 'foreign-no-hooks-key' })
        [System.IO.File]::WriteAllText($foreignGroupSettings, ($foreignGroupJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        $foreignGroupThrew = $false
        try { & $InstallScript -CustomHook $fixtureForeignGroup -Events @('Stop') -TargetProject $projForeignGroup -ClaudeOnly *> $null }
        catch { $foreignGroupThrew = $true }
        Check 'a settings file with a hooks-less foreign group does not crash reinstall (StrictMode)' (-not $foreignGroupThrew)

        $foreignGroupAfter = Get-Content -LiteralPath $foreignGroupSettings -Raw | ConvertFrom-Json
        $foreignGroupStopGroups = @($foreignGroupAfter.hooks.Stop)
        Check 'the foreign hooks-less group is preserved (not dropped) across the reinstall' (
            @($foreignGroupStopGroups | Where-Object { $null -eq $_.PSObject.Properties['hooks'] -and [string]$_.matcher -eq 'foreign-no-hooks-key' }).Count -eq 1)
        $foreignGroupHandlers = @($foreignGroupStopGroups | Where-Object { $null -ne $_.PSObject.Properties['hooks'] } | ForEach-Object { $_.hooks })
        Check 'the real Hook Maker registration is still present exactly once' (
            @($foreignGroupHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*Hook-Maker*' }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Foreignnohooks' }

    # =====================================================================
    # D1 (cross-client contamination): the prior-timeout lookup must consider
    # ONLY the client(s) THIS invocation is installing - a first-ever
    # -CodexOnly install must never inherit an existing -ClaudeOnly install's
    # custom timeout.
    Write-Host '--- a first-ever -CodexOnly install never inherits a prior -ClaudeOnly timeout ---' -ForegroundColor Cyan
    $fixtureCrossClient = New-FixtureHook 'ZZZ-Regtest-Crossclienttimeout'
    try {
        $projCrossClient = New-Proj 'CrossClientTimeoutProj'
        & $InstallScript -CustomHook $fixtureCrossClient -Events @('Stop') -TargetProject $projCrossClient -ClaudeOnly -Timeout 240 *> $null
        $recCrossClientClaude = (Get-RecordsFor 'ZZZ-Regtest-Crossclienttimeout')[0]
        Check 'the claude-only baseline install recorded the custom timeout' ([int]$recCrossClientClaude.clients.claude.timeout -eq 240)
        Check 'the claude-only baseline install has no codex subrecord yet' ($null -eq (Get-ClientSubrecord -Record $recCrossClientClaude -Client 'codex'))

        # First-ever CODEX install of the SAME logical hook (same friendly
        # name/scope/profile => same record id), with NO -Timeout given.
        & $InstallScript -CustomHook $fixtureCrossClient -Events @('Stop') -TargetProject $projCrossClient -CodexOnly *> $null
        Check 'still exactly one logical record after adding codex' ((Get-RecordsFor 'ZZZ-Regtest-Crossclienttimeout').Count -eq 1)
        $recCrossClientBoth = (Get-RecordsFor 'ZZZ-Regtest-Crossclienttimeout')[0]
        Check 'the first-ever codex subrecord gets the DEFAULT timeout, never the claude value' ([int]$recCrossClientBoth.clients.codex.timeout -eq 60)
        Check 'the existing claude subrecord timeout is unaffected' ([int]$recCrossClientBoth.clients.claude.timeout -eq 240)
        $crossClientCodexSettings = Get-Content -LiteralPath (Join-Path $projCrossClient '.codex\hooks.json') -Raw | ConvertFrom-Json
        Check 'the codex handler on disk carries the default timeout, not 240' ([int]$crossClientCodexSettings.hooks.Stop[0].hooks[0].timeout -eq 60)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Crossclienttimeout' }

    # =====================================================================
    # D4 (wrong-handler deletion): a handler whose command fields DISAGREE
    # (one matches THIS install, the other resolves to a DIFFERENT Hook Maker
    # hook) is not fully owned - deleting it would silence whatever the other
    # field pointed at, so a reinstall must leave it in place rather than
    # pruning it as stale.
    Write-Host '--- a handler with disagreeing command fields is preserved, never treated as stale ---' -ForegroundColor Cyan
    $fixtureDisagree = New-FixtureHook 'ZZZ-Regtest-Disagreefields'
    try {
        $projDisagree = New-Proj 'DisagreeFieldsProj'
        & $InstallScript -CustomHook $fixtureDisagree -Events @('Stop') -TargetProject $projDisagree -ClaudeOnly *> $null
        $disagreeSettings = Join-Path $projDisagree '.claude\settings.local.json'
        $disagreeJson = Get-Content -LiteralPath $disagreeSettings -Raw | ConvertFrom-Json
        $disagreeHandler = @(@($disagreeJson.hooks.Stop) | ForEach-Object { $_.hooks })[0]
        $disagreeRealCommand = [string]$disagreeHandler.command
        Check 'the baseline handler carries the real Hook Maker command' ($disagreeRealCommand -like '*Hook-Maker*ZZZ-Regtest-Disagreefields*')

        # Hand-edit in a SECOND command field that resolves to a DIFFERENT
        # hook - the same handler now disagrees with itself.
        $disagreeForeignTarget = 'powershell.exe -NoLogo -NoProfile -File "C:\Somewhere\.claude\hooks\Hook-Maker\ZZZ-Regtest-Otherhook\ZZZ-Regtest-Otherhook.ps1"'
        $disagreeHandler | Add-Member -MemberType NoteProperty -Name commandWindows -Value $disagreeForeignTarget -Force
        [System.IO.File]::WriteAllText($disagreeSettings, ($disagreeJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        # A reinstall (repair) of the SAME hook must not delete this
        # now-ambiguous handler.
        & $InstallScript -CustomHook $fixtureDisagree -Events @('Stop') -TargetProject $projDisagree -ClaudeOnly *> $null
        $disagreeAfter = Get-Content -LiteralPath $disagreeSettings -Raw | ConvertFrom-Json
        $disagreeHandlersAfter = @(@($disagreeAfter.hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'the disagreeing handler is still present after reinstall (not removed)' (
            @($disagreeHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreeForeignTarget }).Count -eq 1)
        Check 'the disagreeing handler still carries its original real command' (
            @($disagreeHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreeForeignTarget -and (Get-HandlerFieldValue $_ 'command') -eq $disagreeRealCommand }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Disagreefields' }

    # =====================================================================
    # D4 (plain user command variant): Get-HandlerCommandValues only returns
    # fields that are actually PRESENT, so a second field that is a plain,
    # non-Hook-Maker-shaped user command is still real content, not "nothing
    # to disagree with" - it must block removal exactly like a different-hook
    # field does, or the user's own script gets silently deleted.
    Write-Host '--- a handler with a plain user command in the other field is preserved ---' -ForegroundColor Cyan
    $fixtureDisagreePlain = New-FixtureHook 'ZZZ-Regtest-Disagreeplaincmd'
    try {
        $projDisagreePlain = New-Proj 'DisagreePlainCmdProj'
        & $InstallScript -CustomHook $fixtureDisagreePlain -Events @('Stop') -TargetProject $projDisagreePlain -ClaudeOnly *> $null
        $disagreePlainSettings = Join-Path $projDisagreePlain '.claude\settings.local.json'
        $disagreePlainJson = Get-Content -LiteralPath $disagreePlainSettings -Raw | ConvertFrom-Json
        $disagreePlainHandler = @(@($disagreePlainJson.hooks.Stop) | ForEach-Object { $_.hooks })[0]
        $disagreePlainRealCommand = [string]$disagreePlainHandler.command

        # Hand-add a SECOND field carrying a plain, real, non-Hook-Maker user
        # command - not a different hook, just the user's own unrelated script.
        $disagreePlainUserCommand = 'powershell.exe -File "C:\Users\me\MyOwnTools\whatever.ps1"'
        $disagreePlainHandler | Add-Member -MemberType NoteProperty -Name commandWindows -Value $disagreePlainUserCommand -Force
        [System.IO.File]::WriteAllText($disagreePlainSettings, ($disagreePlainJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        # A reinstall (repair) of the SAME hook must not delete this handler.
        & $InstallScript -CustomHook $fixtureDisagreePlain -Events @('Stop') -TargetProject $projDisagreePlain -ClaudeOnly *> $null
        $disagreePlainAfter = Get-Content -LiteralPath $disagreePlainSettings -Raw | ConvertFrom-Json
        $disagreePlainHandlersAfter = @(@($disagreePlainAfter.hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'a handler with a plain user command in the other field is still present after reinstall (not removed)' (
            @($disagreePlainHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreePlainUserCommand }).Count -eq 1)
        Check 'that preserved handler still carries its original real command' (
            @($disagreePlainHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreePlainUserCommand -and (Get-HandlerFieldValue $_ 'command') -eq $disagreePlainRealCommand }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Disagreeplaincmd' }

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
