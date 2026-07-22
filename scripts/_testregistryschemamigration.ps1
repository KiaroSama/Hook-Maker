# Dot-sourced scenario block of Test-InstallRegistrySchema.ps1: genuine
# installer-written records (CustomHook, managed native-git, both-clients,
# Engine/profile) validate directly and after a JSON round-trip and never
# crash Get-InstallIntegrity; the v2 -> v3 registry migration is additive
# only (stamps recordType/origin), deterministic, lossless and idempotent,
# and a newer-than-supported registry version is still refused.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions - later blocks also read fixtures defined by
# earlier blocks. Run scripts\Test-InstallRegistrySchema.ps1 instead.

    # =====================================================================
    # GENUINE-RECORD PROOF: the stricter validation above must never reject a
    # record Install-Hook.ps1 actually writes. Every genuine record is checked
    # both directly and after a real JSON round-trip (ConvertTo-Json |
    # ConvertFrom-Json), since that is exactly how a record persists and is
    # read back by every real caller.
    Write-Host '--- genuine installer-written records still validate ---' -ForegroundColor Cyan

    function Assert-GenuineRecordValidates {
        param([string]$Label, $Record)
        Check ("setup: " + $Label + " record was found") ($null -ne $Record)
        if ($null -eq $Record) { return }
        $direct = Test-InstallRecordValid -Record $Record
        Check ($Label + ' validates directly') $direct.Ok $direct.Reason
        $roundTripped = $Record | ConvertTo-Json -Depth 50 | ConvertFrom-Json
        $afterRoundTrip = Test-InstallRecordValid -Record $roundTripped
        Check ($Label + ' still validates after a JSON round-trip') $afterRoundTrip.Ok $afterRoundTrip.Reason
    }

    # Reuse the two real records already installed above rather than
    # reinstalling: a plain CustomHook install and a managed native-git
    # (Ignore-Rules-Check) install, both genuinely written by Install-Hook.ps1.
    Assert-GenuineRecordValidates 'a real CustomHook install' $nmiHealthyNormal
    Assert-GenuineRecordValidates 'a real NATIVE-git managed install' $nmiHealthyNative

    # A fresh install for BOTH clients (no -ClaudeOnly/-CodexOnly): the only
    # way to prove a genuine CODEX subrecord (real commandWindows) validates,
    # since every fixture above used -ClaudeOnly.
    $bothClientsProj = New-Proj 'GenuineBothClientsProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $bothClientsProj *> $null
    $bothClientsRecord = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { $_.friendlyName -eq 'Ai-Memory-Check' -and $_.targetProjectRoot -eq $bothClientsProj })[0]
    Check 'setup: the both-clients record has a codex subrecord' ($null -ne $bothClientsRecord -and $null -ne $bothClientsRecord.clients.codex)
    Assert-GenuineRecordValidates 'a real install for both Claude and Codex' $bothClientsRecord

    # A fresh ENGINE/profile install (sync-hooks.json + -Profile), the third
    # required-to-prove genuine shape.
    $engineProj = New-Proj 'GenuineEngineProj'
    $engineCfgPath = Join-Path $Work 'genuine-engine-cfg.json'
    $engineConfigJson = @{
        version  = 2
        defaults = @{ events = @('SessionStart', 'UserPromptSubmit') }
        profiles = @(@{
            id     = 'genuine-profile'
            name   = 'Genuine Profile'
            routes = @(@{
                id          = 'genuine-route'
                source      = @{ root = (Join-Path $Work 'GenuineSyncSrc'); name = 'Src' }
                destination = @{ root = (Join-Path $Work 'GenuineSyncDst'); name = 'Dst' }
            })
        })
    }
    ($engineConfigJson | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $engineCfgPath -Encoding utf8
    & $InstallScript -Profile 'genuine-profile' -ConfigPath $engineCfgPath -TargetProject $engineProj -Events @('SessionStart') *> $null
    $engineRecord = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { $_.hookType -eq 'Engine' -and $_.targetProjectRoot -eq $engineProj })[0]
    Assert-GenuineRecordValidates 'a real ENGINE/profile install' $engineRecord

    # Get-InstallIntegrity must still accept every one of these without
    # throwing under StrictMode - a record that validates must never then
    # crash the updater it feeds into.
    $integrityThrew = $false
    foreach ($genuineRecord in @($nmiHealthyNormal, $nmiHealthyNative, $bothClientsRecord, $engineRecord)) {
        try { $null = Get-InstallIntegrity -Record $genuineRecord -ToolRoot $ToolRoot } catch { $integrityThrew = $true }
    }
    Check 'Get-InstallIntegrity accepts every genuine record without throwing' (-not $integrityThrew)

    # =====================================================================
    # SCHEMA 3: v2 -> v3 migration must be additive only. It stamps recordType
    # and origin and touches nothing else - not a value, not an id, not one
    # history entry. Anything more would silently rewrite install history the
    # uninstaller and updater both act on.
    Write-Host '--- v2 -> v3 migration is deterministic, lossless and idempotent ---' -ForegroundColor Cyan

    # Every property of a record, serialized, so a comparison covers VALUES and
    # not merely which names are present.
    function Get-RecordPropertyMap {
        param($Record)
        $map = @{}
        foreach ($property in $Record.PSObject.Properties) {
            $map[$property.Name] = ($property.Value | ConvertTo-Json -Depth 40 -Compress)
        }
        return $map
    }

    # A genuine multi-record v2 registry: real installer-written records (one
    # plain, one managed-native, one engine, one both-clients) with their real
    # history, put back into pre-v3 shape by removing the two fields migration
    # is supposed to add.
    function New-V2RegistryFixture {
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($source in @($nmiHealthyNormal, $nmiHealthyNative, $bothClientsRecord, $engineRecord)) {
            $copy = Copy-Record $source
            $copy.PSObject.Properties.Remove('recordType')
            $copy.PSObject.Properties.Remove('origin')
            [void]$records.Add($copy)
        }
        return [pscustomobject][ordered]@{ version = 2; installs = @($records.ToArray()) }
    }

    $v2Registry = New-V2RegistryFixture
    Check 'setup: the v2 fixture holds several records' (@($v2Registry.installs).Count -eq 4)
    Check 'setup: no v2 fixture record carries recordType yet' (@(@($v2Registry.installs) | Where-Object { $null -ne $_.PSObject.Properties['recordType'] }).Count -eq 0)

    $beforeMaps = @(@($v2Registry.installs) | ForEach-Object { Get-RecordPropertyMap $_ })
    $beforeIds = @(@($v2Registry.installs) | ForEach-Object { [string]$_.id })

    $v3Registry = ConvertTo-InstallRegistryCurrent -Registry $v2Registry

    Check 'migration raises the REGISTRY version to 3' ([int]$v3Registry.version -eq 3)
    Check 'migration keeps every record (none dropped, none invented)' (@($v3Registry.installs).Count -eq 4)

    $migratedRecords = @($v3Registry.installs)
    $allStampedManaged = $true
    $allOriginHookMaker = $true
    $allIdsSurvived = $true
    $allValuesSurvived = $true
    $onlyTwoFieldsAdded = $true
    $allSchemaStillTwo = $true
    for ($m = 0; $m -lt $migratedRecords.Count; $m++) {
        $after = $migratedRecords[$m]
        if ([string]$after.recordType -ne 'managed') { $allStampedManaged = $false }
        if ([string]$after.origin -ne 'hookMaker') { $allOriginHookMaker = $false }
        if ([string]$after.id -ne $beforeIds[$m]) { $allIdsSurvived = $false }
        # A managed record's own shape did not change in v3, so its schema must
        # still read 2 - bumping it would declare every installed record stale.
        if ([int]$after.schema -ne 2) { $allSchemaStillTwo = $false }

        $afterMap = Get-RecordPropertyMap $after
        foreach ($name in @($beforeMaps[$m].Keys)) {
            if (-not $afterMap.ContainsKey($name)) { $allValuesSurvived = $false; continue }
            if ($afterMap[$name] -ne $beforeMaps[$m][$name]) { $allValuesSurvived = $false }
        }
        $added = @(@($afterMap.Keys) | Where-Object { -not $beforeMaps[$m].ContainsKey($_) } | Sort-Object)
        if (($added -join ',') -ne 'origin,recordType') { $onlyTwoFieldsAdded = $false }
    }
    Check 'every migrated record is stamped recordType=managed' $allStampedManaged
    Check 'every migrated record is stamped origin=hookMaker' $allOriginHookMaker
    Check 'migration preserves every record id exactly' $allIdsSurvived
    Check 'migration preserves every other field and value byte-for-byte (history included)' $allValuesSurvived
    Check 'migration adds ONLY recordType and origin' $onlyTwoFieldsAdded
    Check 'a managed record stays schema 2 across migration' $allSchemaStillTwo

    # Deterministic: two independent runs over identical input agree exactly.
    $determinismA = (ConvertTo-InstallRegistryCurrent -Registry (New-V2RegistryFixture)) | ConvertTo-Json -Depth 60
    $determinismB = (ConvertTo-InstallRegistryCurrent -Registry (New-V2RegistryFixture)) | ConvertTo-Json -Depth 60
    Check 'migrating the same v2 registry twice produces identical output' ($determinismA -eq $determinismB)

    # Idempotent: migrating an ALREADY-v3 registry changes nothing at all.
    $idempotentBefore = $v3Registry | ConvertTo-Json -Depth 60
    $idempotentAfter = (ConvertTo-InstallRegistryCurrent -Registry $v3Registry) | ConvertTo-Json -Depth 60
    Check 'migrating an already-v3 registry is a no-op' ($idempotentBefore -eq $idempotentAfter)

    # A migrated record must still satisfy the UNCHANGED managed rules - the
    # regression guard for "do not weaken a single existing managed rule".
    $migratedStillValid = $true
    $migratedReason = ''
    foreach ($migratedRecord in $migratedRecords) {
        $migratedValidation = Test-InstallRecordValid -Record $migratedRecord
        if (-not $migratedValidation.Ok) { $migratedStillValid = $false; $migratedReason = $migratedValidation.Reason }
    }
    Check 'every migrated record still validates under the managed rules' $migratedStillValid $migratedReason

    # A record with NO recordType at all (a registry written before v3, read
    # without going through migration) is still treated as managed.
    $unstampedManaged = Copy-Record $goodRecord
    Check 'a record with no recordType is treated as managed' (Test-IsManagedRecord -Record $unstampedManaged)
    Check 'a record with no recordType is not treated as discovered' (-not (Test-IsDiscoveredRecord -Record $unstampedManaged))
    $unstampedResult = Test-InstallRecordValid -Record $unstampedManaged
    Check 'a record with no recordType still validates exactly as before' $unstampedResult.Ok $unstampedResult.Reason

    $explicitManaged = Copy-Record $goodRecord
    $explicitManaged | Add-Member -MemberType NoteProperty -Name recordType -Value 'managed' -Force
    $explicitManaged | Add-Member -MemberType NoteProperty -Name origin -Value 'hookMaker' -Force
    $explicitManagedResult = Test-InstallRecordValid -Record $explicitManaged
    Check 'an explicitly managed record validates identically' $explicitManagedResult.Ok $explicitManagedResult.Reason

    # A newer-than-supported REGISTRY is still refused rather than partially
    # understood - v3 did not relax that.
    $futureRoot = Join-Path $Work 'future-registry-root'
    New-Item -ItemType Directory -Path (Join-Path $futureRoot 'state') -Force | Out-Null
    $futureRegistryPath = Join-Path $futureRoot 'state\install-registry.json'
    $savedFutureStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        Write-Utf8 $futureRegistryPath '{"version":4,"installs":[{"id":"future","schema":4,"friendlyName":"Future"}]}'
        $futureState = Read-InstallRegistryState -ToolRoot $futureRoot
        Check 'a v4 registry is still rejected as newer than supported' (($futureState.State -eq 'corrupt') -and ($futureState.Reason -match 'newer than this Hook Maker supports')) $futureState.Reason

        Write-Utf8 $futureRegistryPath '{"version":3,"installs":[]}'
        Check 'a v3 registry reads as ok' ((Read-InstallRegistryState -ToolRoot $futureRoot).State -eq 'ok')
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedFutureStateDir }
