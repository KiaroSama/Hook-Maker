# Offline test suite for scripts\_installeventmigration.ps1 - the read-only
# effective-registration diagnostic and the versioned migration of RETIRED
# DEFAULT event bindings (36.md F11).
#
# WHAT IT PINS. "Update previously installed hooks" reuses each record's saved
# per-client events by design, so an installation registered long ago on a
# shipped default that has since been retired keeps receiving NEW CODE under the
# OLD registration for ever. The worked case is Session-Summary-Check: its
# default moved from @('Stop','SubagentStop') to
# @('SessionStart','UserPromptSubmit'), and its runtime exits 0 on every other
# event - so such an install is inert, with no benefit and no error.
#
# The two answers these assertions fix in place:
#   * the diagnostic REPORTS - source hashes, installed hashes, the registered
#     command, the events actually ACTIVE per client, duplicates in another
#     scope - and never writes, executes or dot-sources anything it finds. What
#     it could not read is PARTIAL coverage, never an all-clear.
#   * the migration moves ONLY a demonstrably managed historical default. A
#     custom binding, a hand-edited one, a foreign handler, a tampered runtime
#     and a moved source are each REPORTED and left exactly as they were.
#
# Cost: one workspace, one fixture hook source, a handful of small text files.
# No child process, no real install, no network, no sleep, no wait. Every case
# reuses the same fixture builder; the installer is a stub that records its
# arguments, so nothing is ever really installed.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstalledRuntimeMigration.ps1
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HookLib = Join-Path $ToolRoot 'hooks\_hooklib.ps1'

. (Join-Path $ScriptRoot '_testlib.ps1')
# Same load order every install-library suite uses: _hooklib.ps1 first
# (Read-JsonFile, Get-ShortHash), then the canonical plan the manifest builders
# delegate to, then _installlib.ps1 - which pulls in _installvalidate.ps1 and
# therefore _installeventmigration.ps1, the file under test.
. $HookLib
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray }
    }
}

$Work = New-TestWorkspace -Prefix 'hookmaker-bindingmigration'

# ---------------------------------------------------------------------------
# THE STUBS. Both are functions the wizard supplies and the install library
# does not, and both are resolved by name at CALL time - which is exactly how
# the module under test reaches them.
# ---------------------------------------------------------------------------

# The CANONICAL current default event set. The real one is
# Setup-SyncGroup.ps1's Get-HookRecommendedEvents reading $script:HookMeta;
# this stub answers for the fixture hooks only. 'Fixture-Unknown-Check' returns
# NOTHING on purpose, so the "destination unknown" refusal has a case.
$script:CurrentDefaults = @{
    'Session-Summary-Check' = @('SessionStart', 'UserPromptSubmit')
    'Git-Sync-Check'        = @('SessionStart', 'PreToolUse', 'Stop', 'SubagentStop')
    'Fixture-Unknown-Check' = @()
}
function Get-HookRecommendedEvents {
    param([Parameter(Mandatory = $true)]$Hook)
    $name = [string]$Hook.Name
    if ($script:CurrentDefaults.ContainsKey($name)) { return @($script:CurrentDefaults[$name]) }
    return @('SessionStart', 'UserPromptSubmit')
}

# The one structured-result install path. Records what it was asked to do and
# claims success, so the applier's arguments can be asserted without installing.
$script:InstallerCalls = New-Object System.Collections.Generic.List[object]
function Invoke-HookInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$InstallScript,
        [Parameter(Mandatory = $true)][hashtable]$InstallArgs
    )
    [void]$script:InstallerCalls.Add([pscustomobject]@{ InstallScript = $InstallScript; InstallArgs = $InstallArgs })
    return [pscustomobject]@{ Ok = $true; Status = 'ok'; Summary = 'ok'; Result = $null; Output = @() }
}

# ---------------------------------------------------------------------------
# THE FIXTURE. A miniature tool root holding a real package-shaped hook source,
# plus per-project installed runtimes and client settings files. Built once.
# ---------------------------------------------------------------------------
$FixtureToolRoot = Join-Path $Work 'tool'
$FixtureHooksDir = Join-Path $FixtureToolRoot 'hooks'
New-Item -ItemType Directory -Path $FixtureHooksDir -Force | Out-Null
Copy-TestRuntimeLibraries -SourceHookLib $HookLib -Destination (Join-Path $FixtureHooksDir '_hooklib.ps1')

# 'Session-Summary-Check' is the name the SHIPPED migration table is keyed by,
# so these assertions exercise the real entry rather than an invented one.
# Nothing real is touched: this is a stand-in package inside the throwaway
# workspace. 'Fixture-Unknown-Check' exists only to give one case a hook whose
# current default the resolver cannot answer for.
$HookName = 'Session-Summary-Check'
foreach ($fixtureHook in @($HookName, 'Fixture-Unknown-Check')) {
    $dir = Join-Path $FixtureHooksDir $fixtureHook
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir ($fixtureHook + '.ps1')) -Value "# fixture hook`nexit 0`n" -Encoding UTF8
    # An .env.example is what makes a hook folder a PACKAGE, which is the shape
    # every shipped hook has and the shape the install plan walks.
    Set-Content -LiteralPath (Join-Path $dir '.env.example') -Value "COOLDOWN_MINUTES=45`n" -Encoding UTF8
}

# Builds one complete installation: the managed runtime on disk, a client
# settings file registering it on $ActiveEvents, and a schema-2 record whose
# manifests are derived from what was actually written - so a healthy fixture
# passes Test-InstallRecordValid and the installed-hash check by construction,
# and every negative case below is produced by damaging exactly one thing.
function New-InstalledFixture {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string[]]$RecordedEvents,
        [string[]]$ActiveEvents = $null,
        [string]$Hook = 'Session-Summary-Check',
        [string]$Client = 'claude',
        [switch]$IncludeForeignHandler
    )
    if ($null -eq $ActiveEvents) { $ActiveEvents = $RecordedEvents }
    $projectRoot = Join-Path $Work $ProjectName
    $runtimeRoot = Join-Path $projectRoot '.claude\hooks\Hook-Maker'
    $hookDir = Join-Path $runtimeRoot $Hook
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
    $runtimeScript = Join-Path $hookDir ($Hook + '.ps1')
    Copy-Item -LiteralPath (Join-Path $FixtureHooksDir ($Hook + '\' + $Hook + '.ps1')) -Destination $runtimeScript -Force
    Copy-TestRuntimeLibraries -SourceHookLib $HookLib -Destination (Join-Path $hookDir '_hooklib.ps1')
    Set-Content -LiteralPath (Join-Path $hookDir '.hookmaker-runtime.json') `
        -Value ('{"schemaVersion":2,"friendlyName":"' + $Hook + '"}') -Encoding UTF8

    $settingsPath = Join-Path $projectRoot '.claude\settings.local.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    $command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runtimeScript + '"'
    $hooks = [ordered]@{}
    foreach ($eventName in @($ActiveEvents)) {
        $hooks[$eventName] = @(@{ matcher = ''; hooks = @(@{ type = 'command'; command = $command; timeout = 10 }) })
    }
    if ($IncludeForeignHandler) {
        # Somebody else's handler on an event this install also uses. It must be
        # invisible to every judgement here - it is not ours to classify or move.
        $hooks['Stop'] = @(@{ matcher = ''; hooks = @(@{ type = 'command'; command = 'pwsh -File "C:\Users\someone\MyOwnTools\Session-Summary-Check.ps1"'; timeout = 5 }) })
    }
    Set-Content -LiteralPath $settingsPath -Value (([pscustomobject]@{ hooks = $hooks }) | ConvertTo-Json -Depth 12) -Encoding UTF8

    $sourceManifest = @(Get-ManagedSourceManifest -ToolRoot $FixtureToolRoot -HookScript (Join-Path $FixtureHooksDir ($Hook + '\' + $Hook + '.ps1')) `
            -SourceDir (Join-Path $FixtureHooksDir $Hook) -FriendlyName $Hook -ProjectRoot $projectRoot)
    $installedManifest = @(Get-InstalledManifest -RuntimeRoot $runtimeRoot -FriendlyName $Hook)

    # Round-tripped through JSON: a hashtable is not the [pscustomobject] shape
    # the registry stores, and every property lookup in the code under test is
    # PSObject-based (a documented trap in this project's own lessons).
    $record = @{
        id = ('fix' + $ProjectName.ToLowerInvariant()); schema = 2
        internalName = $Hook; friendlyName = $Hook; hookType = 'CustomHook'
        sourceScript = (Join-Path $FixtureHooksDir ($Hook + '\' + $Hook + '.ps1'))
        sourceDir = (Join-Path $FixtureHooksDir $Hook)
        toolRoot = $FixtureToolRoot; scope = 'project'; targetProjectRoot = $projectRoot
        profile = ''; configPath = ''; recordType = 'managed'; origin = 'hookMaker'
        sourceManifest = $sourceManifest
        clients = @{
            $Client = @{
                installed = $true; settingsPath = $settingsPath
                registrationKind = 'sharedSettingsFile'; registrationPath = ''
                runtimeRoot = $runtimeRoot; runtimeScript = $runtimeScript
                events = @($RecordedEvents); enabled = $true
                command = $command; handlerType = 'command'; timeout = 10
                installedManifest = $installedManifest
            }
        }
    } | ConvertTo-Json -Depth 12 | ConvertFrom-Json

    return [pscustomobject]@{
        Record = $record; ProjectRoot = $projectRoot; SettingsPath = $settingsPath
        RuntimeRoot = $runtimeRoot; RuntimeScript = $runtimeScript; Command = $command
        HookDir = $hookDir; Client = $Client
    }
}

function Get-VerdictFor {
    param($Fixture, [string]$Client = 'claude')
    return (Get-ClientEventMigrationVerdict -Record $Fixture.Record -Client $Client)
}

# ---------------------------------------------------------------------------
Write-Host '--- a fresh install: on the current default, nothing to do ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$fresh = New-InstalledFixture -ProjectName 'fresh' -RecordedEvents @('SessionStart', 'UserPromptSubmit')
$freshValidity = Test-InstallRecordValid -Record $fresh.Record
Check 'the fixture record is a VALID managed record (so every negative below is caused by its own damage)' (
    $freshValidity.Ok) ($freshValidity.Reason)
$freshVerdict = Get-VerdictFor $fresh
Check 'a fresh install on the current default classifies as current' (
    $freshVerdict.Status -eq 'current') ($freshVerdict.Status + ' / ' + $freshVerdict.Detail)
Check 'a current binding is not in the migration plan' (
    @(Get-InstalledEventMigrationPlan -Records @($fresh.Record)).Count -eq 0) ''
$freshResolved = Resolve-UpdateEventsForClient -Record $fresh.Record -Client 'claude'
Check 'the updater reuses a current binding unchanged and says nothing' (
    (Test-EventSetEqual $freshResolved.Events @('SessionStart', 'UserPromptSubmit')) -and $freshResolved.Note -eq '') (
    (@($freshResolved.Events) -join '+') + ' note=' + $freshResolved.Note)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the retired shipped default: migrated, once, to the CURRENT default ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# @('Stop','SubagentStop') is the only other value this repository's history
# ever gave Session-Summary-Check, which is what makes it a DEFAULT rather than
# a user's choice - the distinction the whole migration turns on.
$retired = New-InstalledFixture -ProjectName 'retired' -RecordedEvents @('Stop', 'SubagentStop')
$retiredVerdict = Get-VerdictFor $retired
Check 'a retired shipped default classifies as migrate' (
    $retiredVerdict.Status -eq 'migrate') ($retiredVerdict.Status + ' / ' + $retiredVerdict.Detail)
Check 'the destination is the CURRENT default, not a second copy of it' (
    Test-EventSetEqual $retiredVerdict.Events @('SessionStart', 'UserPromptSubmit')) (@($retiredVerdict.Events) -join '+')
Check 'the migration is named by its VERSION, so a run can be identified later' (
    $retiredVerdict.Version -eq 1 -and $retiredVerdict.Detail -match 'migration v1') ($retiredVerdict.Detail)
Check 'the detail names both the old and the new binding' (
    $retiredVerdict.Detail -match 'Stop' -and $retiredVerdict.Detail -match 'SessionStart') ($retiredVerdict.Detail)
$retiredResolved = Resolve-UpdateEventsForClient -Record $retired.Record -Client 'claude'
Check 'the updater reinstalls a retired default on the NEW events' (
    Test-EventSetEqual $retiredResolved.Events @('SessionStart', 'UserPromptSubmit')) (@($retiredResolved.Events) -join '+')
Check 'the updater reports the move rather than doing it silently' (
    $retiredResolved.Note -match 'migration v1') ($retiredResolved.Note)
# Git-Sync-Check's prior shipped default had no PreToolUse, so the side-branch
# and push-once reminders (plan 012 step 2c) never ran on an existing install.
$gitSyncRetired = New-InstalledFixture -Hook 'Git-Sync-Check' -ProjectName 'gitsync-retired' -RecordedEvents @('SessionStart', 'Stop', 'SubagentStop')
$gitSyncVerdict = Get-VerdictFor $gitSyncRetired
Check 'Git-Sync-Check: the retired default without PreToolUse migrates by v3 to the current set' (
    $gitSyncVerdict.Status -eq 'migrate' -and $gitSyncVerdict.Version -eq 3 -and
    (Test-EventSetEqual $gitSyncVerdict.Events @('SessionStart', 'PreToolUse', 'Stop', 'SubagentStop'))) ($gitSyncVerdict.Status + ' / ' + $gitSyncVerdict.Detail)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- a CUSTOM binding is preserved and reported, never rewritten ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# Stop-only was never a shipped default for this hook, so it is a user choice.
# It is also inert for a hook that answers only on SessionStart and
# UserPromptSubmit - which must be REPORTED, not silently corrected.
$custom = New-InstalledFixture -ProjectName 'custom' -RecordedEvents @('Stop')
$customVerdict = Get-VerdictFor $custom
Check 'a Stop-only binding that was never a shipped default is custom, not migrate' (
    $customVerdict.Status -eq 'custom') ($customVerdict.Status + ' / ' + $customVerdict.Detail)
Check 'a custom binding keeps its own events untouched' (
    Test-EventSetEqual $customVerdict.Events @('Stop')) (@($customVerdict.Events) -join '+')
Check 'the events outside the hook''s declared set are named as possibly inert' (
    (@($customVerdict.Inert) -contains 'Stop') -and $customVerdict.Detail -match 'may deliver nothing') ($customVerdict.Detail)
$customResolved = Resolve-UpdateEventsForClient -Record $custom.Record -Client 'claude'
Check 'the updater reinstalls a custom binding on its OWN events' (
    Test-EventSetEqual $customResolved.Events @('Stop')) (@($customResolved.Events) -join '+')
Check 'the updater still surfaces the inert-binding warning' (
    $customResolved.Note -match 'may deliver nothing') ($customResolved.Note)

# An event the client capability table has no trigger for at all. Stronger than
# "outside the declared set": it cannot fire whatever the runtime does.
$incompatible = New-InstalledFixture -ProjectName 'incompatible' -RecordedEvents @('LegacyStopHook')
$incompatibleVerdict = Get-VerdictFor $incompatible
Check 'an event the client has no trigger for is reported as unsupported' (
    (@($incompatibleVerdict.Unsupported) -contains 'LegacyStopHook') -and $incompatibleVerdict.Detail -match 'no trigger') (
    $incompatibleVerdict.Detail)
Check 'an incompatible binding is still PRESERVED, not rewritten' (
    $incompatibleVerdict.Status -eq 'custom' -and (Test-EventSetEqual $incompatibleVerdict.Events @('LegacyStopHook'))) (
    $incompatibleVerdict.Status + ' ' + (@($incompatibleVerdict.Events) -join '+'))

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- unverifiable state BLOCKS the migration; it never guesses ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# A live registration that no longer matches the record means something outside
# Hook Maker moved this binding, so the record's events are no longer a
# statement about what is installed.
$handEdited = New-InstalledFixture -ProjectName 'handedited' -RecordedEvents @('Stop', 'SubagentStop') -ActiveEvents @('Stop')
$handEditedVerdict = Get-VerdictFor $handEdited
Check 'a hand-edited live registration blocks the migration' (
    $handEditedVerdict.Status -eq 'blocked' -and $handEditedVerdict.Detail -match 'does not match the recorded binding') (
    $handEditedVerdict.Status + ' / ' + $handEditedVerdict.Detail)
Check 'a blocked binding keeps its recorded events, so the update still runs as before' (
    Test-EventSetEqual (Resolve-UpdateEventsForClient -Record $handEdited.Record -Client 'claude').Events @('Stop', 'SubagentStop')) ''

# A tampered installed runtime: the installed-HASH check is what refuses here.
$tampered = New-InstalledFixture -ProjectName 'tampered' -RecordedEvents @('Stop', 'SubagentStop')
Add-Content -LiteralPath $tampered.RuntimeScript -Value '# tampered'
$tamperedVerdict = Get-VerdictFor $tampered
Check 'a tampered installed runtime blocks the migration on its installed hashes' (
    $tamperedVerdict.Status -eq 'blocked' -and $tamperedVerdict.Detail -match 'installed file modified') (
    $tamperedVerdict.Status + ' / ' + $tamperedVerdict.Detail)

# A moved/deleted target: nothing to verify, so nothing is rebound.
$moved = New-InstalledFixture -ProjectName 'moved' -RecordedEvents @('Stop', 'SubagentStop')
Remove-Item -LiteralPath $moved.RuntimeScript -Force
$movedVerdict = Get-VerdictFor $moved
Check 'a missing installed hook script blocks the migration' (
    $movedVerdict.Status -eq 'blocked' -and $movedVerdict.Detail -match 'installed hook script is missing') (
    $movedVerdict.Status + ' / ' + $movedVerdict.Detail)

# A record the registry marks as DISCOVERED is not a managed install and is
# never rebound by this path.
$discovered = New-InstalledFixture -ProjectName 'discovered' -RecordedEvents @('Stop', 'SubagentStop')
$discovered.Record.recordType = 'discovered'
$discoveredVerdict = Get-VerdictFor $discovered
Check 'a non-managed (discovered) record is never migrated' (
    $discoveredVerdict.Status -eq 'blocked') ($discoveredVerdict.Status + ' / ' + $discoveredVerdict.Detail)

# No resolvable current default (the state inside Install-Hook.ps1, where the
# wizard's resolver is not loaded): reuse the recorded binding, refuse to guess.
$unknown = New-InstalledFixture -ProjectName 'unknown' -RecordedEvents @('Stop', 'SubagentStop') -Hook 'Fixture-Unknown-Check'
$unknownVerdict = Get-VerdictFor $unknown
Check 'an unresolvable current default refuses to migrate and says why' (
    $unknownVerdict.Status -eq 'custom' -and $unknownVerdict.Detail -match 'resolved to nothing') (
    $unknownVerdict.Status + ' / ' + $unknownVerdict.Detail)
Check 'an unresolvable current default still yields the recorded events' (
    Test-EventSetEqual $unknownVerdict.Events @('Stop', 'SubagentStop')) (@($unknownVerdict.Events) -join '+')

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- foreign handlers are not ours to classify or move ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$foreign = New-InstalledFixture -ProjectName 'foreign' -RecordedEvents @('SessionStart', 'UserPromptSubmit') -IncludeForeignHandler
$foreignDiagnostic = Get-EffectiveRegistrationDiagnostic -Record $foreign.Record -ToolRoot $FixtureToolRoot
$foreignClient = @($foreignDiagnostic.Clients)[0]
Check 'a foreign handler on another event is NOT reported as one of our active events' (
    (Test-EventSetEqual $foreignClient.ActiveEvents @('SessionStart', 'UserPromptSubmit')) -and
    (@($foreignClient.ActiveEvents) -notcontains 'Stop')) (@($foreignClient.ActiveEvents) -join '+')
$foreignBefore = Get-FileSha256 $foreign.SettingsPath
[void](Get-InstalledEventMigrationPlan -Records @($foreign.Record))
[void](Get-EffectiveRegistrationDiagnostic -Record $foreign.Record -ToolRoot $FixtureToolRoot)
Check 'reporting on an installation modifies no settings file' (
    (Get-FileSha256 $foreign.SettingsPath) -eq $foreignBefore) ''

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- the read-only diagnostic: hashes, command, ACTIVE events, coverage ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$diagnostic = Get-EffectiveRegistrationDiagnostic -Record $fresh.Record -ToolRoot $FixtureToolRoot
$diagnosticClient = @($diagnostic.Clients)[0]
Check 'a healthy installation reports matching SOURCE hashes' ($diagnostic.SourceMatch) ($diagnostic.SourceDetail)
Check 'a healthy installation reports matching INSTALLED hashes' (
    $diagnosticClient.InstalledMatch) ($diagnosticClient.InstalledDetail)
Check 'the diagnostic reports the registered target command' (
    $diagnosticClient.Command -eq $fresh.Command) ($diagnosticClient.Command)
Check 'the diagnostic reports the events ACTUALLY registered, not only the recorded ones' (
    (Test-EventSetEqual $diagnosticClient.ActiveEvents @('SessionStart', 'UserPromptSubmit')) -and
    $diagnosticClient.ActiveReadable -and $diagnosticClient.EventsAgree) (@($diagnosticClient.ActiveEvents) -join '+')
Check 'a fully readable healthy installation reports COMPLETE coverage' (
    $diagnostic.Coverage.Complete -and @($diagnostic.Coverage.Notes).Count -eq 0) (@($diagnostic.Coverage.Notes) -join ' | ')

# Recorded and active can DISAGREE, and that is the diagnostic's whole point.
$drifted = New-InstalledFixture -ProjectName 'drifted' -RecordedEvents @('SessionStart', 'UserPromptSubmit') -ActiveEvents @('Stop')
$driftedClient = @((Get-EffectiveRegistrationDiagnostic -Record $drifted.Record -ToolRoot $FixtureToolRoot).Clients)[0]
Check 'recorded and ACTIVE events are reported separately when they disagree' (
    (Test-EventSetEqual $driftedClient.RecordedEvents @('SessionStart', 'UserPromptSubmit')) -and
    (Test-EventSetEqual $driftedClient.ActiveEvents @('Stop')) -and -not $driftedClient.EventsAgree) (
    (@($driftedClient.RecordedEvents) -join '+') + ' vs ' + (@($driftedClient.ActiveEvents) -join '+'))

# A changed source must show as a source-hash difference, never be smoothed over.
$changed = New-InstalledFixture -ProjectName 'changed' -RecordedEvents @('SessionStart', 'UserPromptSubmit')
$changed.Record.sourceManifest = @(@{ path = 'session-summary-check/session-summary-check.ps1'; hash = ('0' * 64) } | ConvertTo-Json | ConvertFrom-Json)
$changedDiagnostic = Get-EffectiveRegistrationDiagnostic -Record $changed.Record -ToolRoot $FixtureToolRoot
Check 'a source that no longer matches its recorded hashes is reported as changed' (
    -not $changedDiagnostic.SourceMatch -and $changedDiagnostic.SourceDetail -ne '') ($changedDiagnostic.SourceDetail)

# PARTIAL COVERAGE. An unreadable settings file must never read as "registered
# on nothing" - that is the false all-clear the whole file exists to avoid.
$unreadable = New-InstalledFixture -ProjectName 'unreadable' -RecordedEvents @('SessionStart', 'UserPromptSubmit')
Set-Content -LiteralPath $unreadable.SettingsPath -Value '{ this is not json' -Encoding UTF8
$unreadableDiagnostic = Get-EffectiveRegistrationDiagnostic -Record $unreadable.Record -ToolRoot $FixtureToolRoot
$unreadableClient = @($unreadableDiagnostic.Clients)[0]
Check 'an unreadable settings file is PARTIAL coverage, not an empty registration list' (
    (-not $unreadableDiagnostic.Coverage.Complete) -and (-not $unreadableClient.ActiveReadable) -and
    (@($unreadableDiagnostic.Coverage.Notes) -join ' ') -match 'could not be read') (
    (@($unreadableDiagnostic.Coverage.Notes) -join ' | '))
$missingSettings = New-InstalledFixture -ProjectName 'nosettings' -RecordedEvents @('SessionStart', 'UserPromptSubmit')
Remove-Item -LiteralPath $missingSettings.SettingsPath -Force
$missingDiagnostic = Get-EffectiveRegistrationDiagnostic -Record $missingSettings.Record -ToolRoot $FixtureToolRoot
Check 'a missing settings file is reported as partial coverage with its path' (
    (-not $missingDiagnostic.Coverage.Complete) -and
    (@($missingDiagnostic.Coverage.Notes) -join ' ') -match 'does not exist') (
    (@($missingDiagnostic.Coverage.Notes) -join ' | '))

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- duplicate copies of one hook across scopes are all accounted for ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$secondCopy = New-InstalledFixture -ProjectName 'secondcopy' -RecordedEvents @('Stop', 'SubagentStop')
$globalCopy = New-InstalledFixture -ProjectName 'globalcopy' -RecordedEvents @('Stop', 'SubagentStop')
$globalCopy.Record.scope = 'global'
$allRecords = @($retired.Record, $secondCopy.Record, $globalCopy.Record, $custom.Record)
$duplicateDiagnostic = Get-EffectiveRegistrationDiagnostic -Record $retired.Record -ToolRoot $FixtureToolRoot -AllRecords $allRecords
Check 'every other record naming the same hook is listed, whatever its scope' (
    @($duplicateDiagnostic.Duplicates).Count -eq 3) ('found ' + @($duplicateDiagnostic.Duplicates).Count)
Check 'a global copy is reported with its scope, beside the project copies' (
    (@($duplicateDiagnostic.Duplicates | Where-Object { $_.Scope -eq 'global' }).Count -eq 1) -and
    (@($duplicateDiagnostic.Duplicates | Where-Object { $_.Scope -eq 'project' }).Count -eq 2)) (
    (@($duplicateDiagnostic.Duplicates | ForEach-Object { $_.Scope }) -join ','))
Check 'each duplicate reports its own binding, so two copies on different events are visible' (
    (@($duplicateDiagnostic.Duplicates | Where-Object { (@($_.Bindings) -join '') -match 'Stop' }).Count -ge 2) -and
    (@($duplicateDiagnostic.Duplicates | Where-Object { (@($_.Bindings) -join '') -eq 'claude=Stop' }).Count -eq 1)) (
    (@($duplicateDiagnostic.Duplicates | ForEach-Object { $_.Bindings }) -join ' | '))
Check 'the record itself is never listed as its own duplicate' (
    @($duplicateDiagnostic.Duplicates | Where-Object { $_.RecordId -eq $duplicateDiagnostic.RecordId }).Count -eq 0) ''

# The PLAN spans every managed copy, so a second project's retired default is
# not missed because the first one was looked at.
$multiPlan = @(Get-InstalledEventMigrationPlan -Records @($retired.Record, $secondCopy.Record, $fresh.Record, $custom.Record))
Check 'the plan covers every copy that needs moving, and no copy that does not' (
    (@($multiPlan | Where-Object { $_.Verdict.Status -eq 'migrate' }).Count -eq 2) -and
    (@($multiPlan | Where-Object { $_.Verdict.Status -eq 'current' }).Count -eq 0)) (
    (@($multiPlan | ForEach-Object { $_.Verdict.Status }) -join ','))
Check 'IncludeUnchanged reports the untouched copies too, for a full picture' (
    @(Get-InstalledEventMigrationPlan -Records @($fresh.Record) -IncludeUnchanged).Count -eq 1) ''

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- applying the migration, and running it twice ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$script:InstallerCalls.Clear()
$applyPlan = @(Get-InstalledEventMigrationPlan -Records @($retired.Record, $custom.Record, $handEdited.Record, $fresh.Record))
$applyResults = @(Invoke-InstalledEventMigration -Plan $applyPlan -InstallScript 'C:\fake\Install-Hook.ps1')
Check 'only the migrate items are applied - custom, blocked and current are left alone' (
    $script:InstallerCalls.Count -eq 1 -and @($applyResults).Count -eq 1) (
    'installs=' + $script:InstallerCalls.Count + ' results=' + @($applyResults).Count)
$call = $script:InstallerCalls.ToArray()[0]
Check 'the install names exactly ONE client positively, never a -*Only shim' (
    (@($call.InstallArgs['Clients']).Count -eq 1) -and (@($call.InstallArgs['Clients'])[0] -eq 'claude')) (
    (@($call.InstallArgs['Clients']) -join ','))
Check 'the install carries the NEW events' (
    Test-EventSetEqual $call.InstallArgs['Events'] @('SessionStart', 'UserPromptSubmit')) (
    (@($call.InstallArgs['Events']) -join '+'))
Check 'a project-scoped record installs into its own project root' (
    $call.InstallArgs['TargetProject'] -eq $retired.ProjectRoot) ([string]$call.InstallArgs['TargetProject'])
Check 'a custom-hook record passes its source script, not an engine profile' (
    $call.InstallArgs.ContainsKey('CustomHook') -and (-not $call.InstallArgs.ContainsKey('Profile'))) ''

# IDEMPOTENCE. The installer is stubbed, so the real record is unchanged - the
# honest way to prove the second run is a no-op is to feed it the record the
# installer WOULD have written: same installation, now on the current default.
$migrated = New-InstalledFixture -ProjectName 'migrated' -RecordedEvents @('SessionStart', 'UserPromptSubmit')
$script:InstallerCalls.Clear()
[void](Invoke-InstalledEventMigration -Plan @(Get-InstalledEventMigrationPlan -Records @($migrated.Record)) -InstallScript 'C:\fake\Install-Hook.ps1')
Check 'running the migration again over an already-migrated install does nothing' (
    $script:InstallerCalls.Count -eq 0) ('installs=' + $script:InstallerCalls.Count)

# UNINSTALL THEN REINSTALL. After an uninstall the settings file holds no
# registration of ours; a record left behind must block, never be rebound.
$reinstalled = New-InstalledFixture -ProjectName 'reinstalled' -RecordedEvents @('Stop', 'SubagentStop')
Set-Content -LiteralPath $reinstalled.SettingsPath -Value '{ "hooks": {} }' -Encoding UTF8
$uninstalledVerdict = Get-VerdictFor $reinstalled
Check 'a record whose registration was uninstalled blocks rather than rebinding' (
    $uninstalledVerdict.Status -eq 'blocked') ($uninstalledVerdict.Status + ' / ' + $uninstalledVerdict.Detail)
# ...and a genuine reinstall on the current default is simply current again.
Set-Content -LiteralPath $reinstalled.SettingsPath `
    -Value (([pscustomobject]@{ hooks = [ordered]@{
        SessionStart     = @(@{ matcher = ''; hooks = @(@{ type = 'command'; command = $reinstalled.Command; timeout = 10 }) })
        UserPromptSubmit = @(@{ matcher = ''; hooks = @(@{ type = 'command'; command = $reinstalled.Command; timeout = 10 }) })
    } }) | ConvertTo-Json -Depth 12) -Encoding UTF8
$reinstalled.Record.clients.claude.events = @('SessionStart', 'UserPromptSubmit')
Check 'a reinstall on the current default reads as current again' (
    (Get-VerdictFor $reinstalled).Status -eq 'current') ((Get-VerdictFor $reinstalled).Status)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- robustness and the negative control ---' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# A migration must never be able to FAIL an update that would otherwise have
# worked, and a record with no events must keep the exact message the updater
# has always printed for it.
$noEvents = New-InstalledFixture -ProjectName 'noevents' -RecordedEvents @('SessionStart')
$noEvents.Record.clients.claude.events = @()
$noEventsResolved = Resolve-UpdateEventsForClient -Record $noEvents.Record -Client 'claude'
Check 'a record with no recorded events yields no events and the historical message' (
    @($noEventsResolved.Events).Count -eq 0 -and $noEventsResolved.Note -eq 'no recorded events') (
    $noEventsResolved.Note)
$garbage = [pscustomobject]@{ id = 'garbage' }
$garbageResolved = $null
$garbageThrew = $false
try { $garbageResolved = Resolve-UpdateEventsForClient -Record $garbage -Client 'claude' } catch { $garbageThrew = $true }
Check 'a malformed record never throws out of the updater''s event resolution' (
    (-not $garbageThrew) -and $null -ne $garbageResolved) ''

# Set equality is what tells a default from a custom binding, so it has to be
# right about order and case - not merely "returns $false a lot".
Check 'event set equality ignores order and case, and rejects a real difference' (
    (Test-EventSetEqual @('Stop', 'SubagentStop') @('subagentstop', 'stop')) -and
    (-not (Test-EventSetEqual @('Stop') @('Stop', 'SubagentStop')))) ''

# NEGATIVE CONTROL. Without this, a classifier that answered 'custom' (or
# 'blocked') for everything would satisfy most assertions above while doing
# nothing: "preserve everything" and "report nothing" both look like success.
$controlStatuses = @(@(
        $freshVerdict, $retiredVerdict, $customVerdict, $handEditedVerdict,
        $tamperedVerdict, $movedVerdict, $discoveredVerdict, $unknownVerdict
    ) | ForEach-Object { $_.Status })
Check 'negative control: the classifier really discriminates (current, migrate, custom AND blocked all occur)' (
    (@($controlStatuses | Sort-Object -Unique).Count -eq 4)) (($controlStatuses | Sort-Object -Unique) -join ',')
Check 'negative control: at least one case is migrated and at least four are refused' (
    (@($controlStatuses | Where-Object { $_ -eq 'migrate' }).Count -ge 1) -and
    (@($controlStatuses | Where-Object { $_ -eq 'blocked' }).Count -ge 4)) (($controlStatuses -join ','))

if (-not $KeepArtifacts) {
    if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++ ; Write-Host '[FAIL] workspace cleanup left files behind' -ForegroundColor Red }
}
else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
