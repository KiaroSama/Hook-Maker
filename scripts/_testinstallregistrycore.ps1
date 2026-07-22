# Dot-sourced scenario block of Test-InstallRegistry.ps1: core registry record
# lifecycle - a successful install creates one schema-2 record (never
# duplicated); Claude-only/Codex-only/Both and project/global scopes are
# represented correctly; sync-engine installs are tracked as hookType=Engine
# with profile+configPath; the updater refreshes a changed source byte-for-
# byte, preserves registration semantics and is idempotent; a never-installed
# hook is never added; missing source/target are reported and skipped without
# destructive changes; unrelated JSON keys/handlers survive an update; the
# registry never stores secret/.env/prompt content.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-InstallRegistry.ps1 instead.

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
