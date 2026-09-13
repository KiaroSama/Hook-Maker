# Dot-sourced scenario block of Test-InstallRegistry.ps1: resilience, drift
# detection and repair - per-client semantics stored and preserved
# independently; v1->v2 migration never invents semantics; a corrupt registry
# is quarantined (locking, concurrent writers, unique quarantine names);
# component-level repair touches only the damaged component; every owned
# registration field drifts independently; the installer emits a structured
# machine-readable result (ok vs partial); concurrent installs into one
# settings file keep both handlers; per-component history stays bounded;
# installed-state drift is detected without any source change and repaired.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-InstallRegistry.ps1 instead.

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
        # The registry is per-record files, so the fixture is written as this
        # record's own file plus a v1 marker in the set metadata - the same
        # thing a genuinely old state directory would contain.
        $liveRegistry = Read-InstallRegistry -ToolRoot $ToolRoot
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
        $registryPath = Get-InstallRecordPath -ToolRoot $ToolRoot -Id ([string]$recMig.id)
        [System.IO.File]::WriteAllText($registryPath, ($v1Record | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
        [System.IO.File]::WriteAllText(
            (Join-Path (Get-InstallRegistryDirectory -ToolRoot $ToolRoot) '_meta.json'),
            ('{"version":1}'), (New-Object System.Text.UTF8Encoding $false))

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

        # From here on the registry is the PER-RECORD directory that step 1 just
        # created, so every case below damages what is actually read: a record
        # file, or the set's own metadata. Writing a corrupt single document
        # would prove nothing - it is no longer the file anything consults.
        $corruptDir = Get-InstallRegistryDirectory -ToolRoot $corruptRoot
        $probePath = Get-InstallRecordPath -ToolRoot $corruptRoot -Id 'quarantine-probe'
        $corruptMeta = Join-Path $corruptDir '_meta.json'

        # 2. a record file that parses but is not a record
        Write-Utf8 $probePath '"not-a-record-object"'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'valid JSON that is not a record object is reported as corrupt' ($state.State -eq 'corrupt') $state.Reason
        Check 'the corrupt-record reason names the offending file' ($state.Reason -match 'quarantine-probe') $state.Reason

        Write-Utf8 $probePath '{"friendlyName":"NoId"}'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'a record with no id is reported as corrupt' ($state.State -eq 'corrupt' -and $state.Reason -match 'no id') $state.Reason

        # 3. unsupported (newer) schema version, now carried by the set metadata
        Write-Utf8 $probePath ((New-CorruptRecord) | ConvertTo-Json -Depth 50)
        Write-Utf8 $corruptMeta '{"version":99}'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'an unsupported newer schema version is rejected explicitly' ($state.State -eq 'corrupt' -and $state.Reason -match 'newer than this Hook Maker supports') $state.Reason
        Write-Utf8 $corruptMeta '{"version":3}'

        # 3b. unparsable set metadata is corrupt too - never "no version, assume ours"
        Write-Utf8 $corruptMeta '{ not json'
        $state = Read-InstallRegistryState -ToolRoot $corruptRoot
        Check 'unparsable set metadata is reported as corrupt' ($state.State -eq 'corrupt') $state.Reason
        Write-Utf8 $corruptMeta '{"version":3}'

        # 4. a truncated .tmp beside a valid record is cleaned up, not read
        Write-Utf8 ($probePath + '.tmp') '{"id":"quarantine-pro'
        $result = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        Check 'a valid registry with a stale .tmp still updates cleanly' ($result.Ok -eq $true) $result.Warning
        Check 'the stale .tmp file is removed by the atomic write' (-not (Test-Path -LiteralPath ($probePath + '.tmp')))

        # 5. ONE damaged record is quarantined per-record - the other records
        #    are not touched, which the single-document form could not do.
        $bystander = New-CorruptRecord
        Set-ObjectProperty -Object $bystander -Name 'id' -Value 'bystander1'
        [void](Update-InstallRegistry -ToolRoot $corruptRoot -Record $bystander)
        $bystanderPath = Get-InstallRecordPath -ToolRoot $corruptRoot -Id 'bystander1'
        $bystanderBytes = [System.IO.File]::ReadAllBytes($bystanderPath)

        Write-Utf8 $probePath '{ corrupt again'
        $result = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        Write-Utf8 $probePath '{ corrupt again'
        $result2 = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
        $recordQuarantined = @(Get-ChildItem -LiteralPath (Split-Path -Parent $corruptRegistry) -Filter 'install-record-*.corrupt-*.json')
        Check 'a damaged record is quarantined per record, not by scrapping the set' (
            $recordQuarantined.Count -ge 2 -and $result.Ok -and $result2.Ok) (
            [string]$recordQuarantined.Count + '|' + [string]$result.Warning)
        Check 'record quarantine names are unique (no overwrite)' (
            (@($recordQuarantined | ForEach-Object { $_.Name }) | Sort-Object -Unique).Count -eq $recordQuarantined.Count)
        Check 'an unrelated record is byte-for-byte untouched by another record''s quarantine' (
            (Test-Path -LiteralPath $bystanderPath) -and
            ([System.IO.File]::ReadAllBytes($bystanderPath).Length -eq $bystanderBytes.Length))
        Check 'the set is readable again after a per-record quarantine' (
            (Read-InstallRegistryState -ToolRoot $corruptRoot).State -eq 'ok')

        # 6. quarantine failure leaves the original untouched
        Write-Utf8 $probePath '{ unquarantinable'
        $lockedBytes = [System.IO.File]::ReadAllBytes($probePath)
        $held = [System.IO.File]::Open($probePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $failResult = Update-InstallRegistry -ToolRoot $corruptRoot -Record (New-CorruptRecord)
            Check 'a failed quarantine reports tracking failure instead of claiming success' ($failResult.Ok -eq $false) $failResult.Warning
            Check 'a failed quarantine explains that nothing was recorded' ($failResult.Warning -match 'NOT recorded') $failResult.Warning
        }
        finally { $held.Dispose() }
        Check 'a failed quarantine leaves the original file byte-for-byte intact' (
            (Test-Path -LiteralPath $probePath) -and
            ([System.IO.File]::ReadAllBytes($probePath).Length -eq $lockedBytes.Length))
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue

        # 7. concurrent writers must not lose each other's records.
        # "Start from empty" now means an empty record DIRECTORY - writing an
        # empty single document would leave every file from the cases above in
        # place and the count below would be measuring the wrong thing.
        Get-ChildItem -LiteralPath $corruptDir -Filter '*.json' -File | Remove-Item -Force
        Write-Utf8 $corruptMeta '{"version":3}'
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
        # Lock contention is exactly what this case provokes, so an unbounded wait
        # here would hang on the defect it exists to catch.
        foreach ($job in $jobs) {
            if (-not $job.WaitForExit(120000)) {
                try { Stop-Process -Id $job.Id -Force -ErrorAction SilentlyContinue } catch { }
                throw ('concurrent registry writer ' + $job.Id + ' did not exit within 120s (terminated) - suspect a lock never released')
            }
        }
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
    # A FILE where the per-record registry DIRECTORY must be makes the registry
    # write fail while runtime and settings still succeed. (It used to be a
    # directory where the single registry file went; the shape moved, the point
    # did not - a write that cannot land must be reported, never assumed.)
    [System.IO.File]::WriteAllText((Join-Path $blockedStateDir 'install-registry.d'), 'not a directory',
        (New-Object System.Text.UTF8Encoding $false))
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
        # Same reason as the concurrent writers above: these two overlap on purpose,
        # so the wait that proves they finished must itself be bounded.
        foreach ($proc in @(@{ N = 'A'; P = $procA }, @{ N = 'B'; P = $procB })) {
            if (-not $proc.P.WaitForExit(120000)) {
                try { Stop-Process -Id $proc.P.Id -Force -ErrorAction SilentlyContinue } catch { }
                throw ('concurrent install ' + $proc.N + ' did not exit within 120s (terminated)')
            }
        }

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
