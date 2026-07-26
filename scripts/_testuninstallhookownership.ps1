# Dot-sourced scenario block of Test-UninstallHook.ps1: ownership proofs and
# shared-root cleanup - a handler targeting a DIFFERENT real hook's runtime
# survives; same-name / exact-path-wrong-event registrations are ambiguous
# near-matches that remove nothing; native ownership comes only from the
# record's persisted expectedStages (a mutated friendlyName can never rebuild
# a delete target, and an over-rejection guard proves a genuine install still
# uninstalls); every command field on a Codex handler must agree before
# removal; the orphaned shared _hooklib.ps1 / empty Hook-Maker root are
# retired only once the LAST sibling hook is gone (project and global scope),
# never sweeping unknown files; and the runtime ownership metadata goes only with
# an ownership-proven removal, never on an ambiguous near-match and never from a
# sibling record's directory.
# Relies on $ignoreHook from _testuninstallhooknative.ps1, which the entry
# suite dot-sources first.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-UninstallHook.ps1 instead.

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
        # The ownership metadata is removed by the SAME directory removal as the
        # rest of the runtime - it needs no separate delete path, which is the
        # point: it can only be removed once identity and handler ownership have
        # both been proven for this record.
        $metaTargetA = Join-Path (Split-Path -Parent ([string]$recTargetA.clients.claude.runtimeScript)) '.hookmaker-runtime.json'
        $metaTargetB = Join-Path (Split-Path -Parent ([string]$recTargetB.clients.claude.runtimeScript)) '.hookmaker-runtime.json'
        Check 'both installed runtimes carry ownership metadata before removal' (
            (Test-Path -LiteralPath $metaTargetA -PathType Leaf) -and (Test-Path -LiteralPath $metaTargetB -PathType Leaf))

        $r = Invoke-UninstallProcess -RecordId $recTargetA.id
        Check 'removing hook A exits 0' ($r.Exit -eq 0) $r.Err
        Check 'hook A''s ownership metadata is gone with its runtime directory' (-not (Test-Path -LiteralPath $metaTargetA))
        Check 'hook B''s ownership metadata survives - one record''s removal never touches a sibling''s' (Test-Path -LiteralPath $metaTargetB -PathType Leaf)
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
        # Ownership metadata is removed ONLY by an ownership-proven uninstall. An
        # ambiguous near-match removes nothing, so the file that states who owns
        # this directory must still be there for the human who reviews it.
        Check 'the ownership metadata survives an ambiguous, un-proven uninstall' (
            Test-Path -LiteralPath (Join-Path (Split-Path -Parent ([string]$recNearMatch.clients.claude.runtimeScript)) '.hookmaker-runtime.json') -PathType Leaf)
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

    # =========================================================================
    # Bug: a pre-private-copy install left a SHARED _hooklib.ps1 sitting
    # directly in the Hook-Maker runtime root (one level above every hook's own
    # directory - see _installplan.ps1's Get-ManagedInstallPlan comment for why
    # a fresh install no longer writes it there). Uninstalling a hook only ever
    # removed that hook's OWN directory, so once the LAST sibling hook was
    # removed, the shared file - and the now-empty Hook-Maker folder itself -
    # were orphaned forever. Fixed in Remove-EmptyManagedRoot (Uninstall-
    # Hook.ps1) + Get-RemovableSharedRuntimeRootFiles (_uninstallownership.ps1).
    Write-Host '--- shared runtime-root cleanup: an orphaned shared _hooklib.ps1 is retired only once the LAST sibling hook is gone ---' -ForegroundColor Cyan
    $fxOrphanA = New-FixtureHook 'ZZZ-Uninst-Orphanliba'
    $fxOrphanB = New-FixtureHook 'ZZZ-Uninst-Orphanlibb'
    try {
        $projOrphan = New-Proj 'OrphanLibProj'
        & $InstallScript -CustomHook $fxOrphanA -Events @('Stop') -TargetProject $projOrphan -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fxOrphanB -Events @('Stop') -TargetProject $projOrphan -ClaudeOnly *> $null
        $recOrphanA = Get-RecordForScope 'ZZZ-Uninst-Orphanliba' $projOrphan
        $recOrphanB = Get-RecordForScope 'ZZZ-Uninst-Orphanlibb' $projOrphan
        Check 'setup: both sibling hooks installed' ($null -ne $recOrphanA -and $null -ne $recOrphanB)

        $orphanHookDirA = Split-Path -Parent ([string]$recOrphanA.clients.claude.runtimeScript)
        $orphanRuntimeRoot = Split-Path -Parent $orphanHookDirA
        Check 'setup: runtime root leaf is Hook-Maker' ((Split-Path -Leaf $orphanRuntimeRoot) -eq 'Hook-Maker')
        Check 'setup: both sibling hooks share the same runtime root' ((Split-Path -Parent (Split-Path -Parent ([string]$recOrphanB.clients.claude.runtimeScript))) -eq $orphanRuntimeRoot)

        # Simulate the pre-private-copy legacy leftover: a fresh install never
        # writes this anymore (each hook gets its own private copy inside its
        # own directory), so this reproduces what an OLDER Hook Maker version
        # left behind at the shared runtime root.
        $orphanLib = Join-Path $orphanRuntimeRoot '_hooklib.ps1'
        Write-Utf8 $orphanLib "# legacy shared library`n"
        Check 'setup: the legacy shared _hooklib.ps1 exists at the runtime root' (Test-Path -LiteralPath $orphanLib -PathType Leaf)

        # Canary BESIDE the root (a sibling inside hooks\, never inside
        # Hook-Maker\ itself): proves containment - the cleanup never reaches
        # beyond the proven Hook-Maker runtime root.
        $orphanCanary = Join-Path (Split-Path -Parent $orphanRuntimeRoot) 'CANARY.txt'
        Write-Utf8 $orphanCanary 'do not touch'

        $rOrphanA = Invoke-UninstallProcess -RecordId $recOrphanA.id
        Check 'removing the first of two sibling hooks exits 0' ($rOrphanA.Exit -eq 0) $rOrphanA.Err
        Check 'removing the first sibling reports overall ok' ([string]$rOrphanA.Result.overall -eq 'ok') ($rOrphanA.Result | ConvertTo-Json -Depth 5)
        Check 'a sibling hook still remains: the shared lib REMAINS' (Test-Path -LiteralPath $orphanLib -PathType Leaf)
        Check 'a sibling hook still remains: the Hook-Maker root REMAINS' (Test-Path -LiteralPath $orphanRuntimeRoot -PathType Container)
        Check 'the surviving sibling''s own runtime is untouched' (Test-Path -LiteralPath ([string]$recOrphanB.clients.claude.runtimeScript) -PathType Leaf)
        Check 'the canary beside the root survives the first removal' (Test-Path -LiteralPath $orphanCanary -PathType Leaf)

        $rOrphanB = Invoke-UninstallProcess -RecordId $recOrphanB.id
        Check 'removing the LAST sibling hook exits 0' ($rOrphanB.Exit -eq 0) $rOrphanB.Err
        Check 'removing the last sibling reports overall ok' ([string]$rOrphanB.Result.overall -eq 'ok') ($rOrphanB.Result | ConvertTo-Json -Depth 5)
        Check 'no sibling hook remains: the orphaned shared lib IS removed' (-not (Test-Path -LiteralPath $orphanLib))
        Check 'no sibling hook remains: the now-empty Hook-Maker root IS removed' (-not (Test-Path -LiteralPath $orphanRuntimeRoot))
        Check 'the canary beside the root survives the last removal too' (Test-Path -LiteralPath $orphanCanary -PathType Leaf)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Orphanliba'; Remove-FixtureHook 'ZZZ-Uninst-Orphanlibb' }

    # =========================================================================
    # Negative control: an unrelated file directly in the runtime root must
    # NEVER be swept just because the root becomes hook-dir-empty - only a
    # KNOWN shared filename is ever a deletion candidate - and the root itself
    # must survive too, because with that file still present it is genuinely
    # not empty.
    Write-Host '--- shared runtime-root cleanup negative control: an unknown root-level file is never swept, root stays non-empty ---' -ForegroundColor Cyan
    $fxUnknownA = New-FixtureHook 'ZZZ-Uninst-Orphanunknowna'
    $fxUnknownB = New-FixtureHook 'ZZZ-Uninst-Orphanunknownb'
    try {
        $projUnknown = New-Proj 'OrphanUnknownProj'
        & $InstallScript -CustomHook $fxUnknownA -Events @('Stop') -TargetProject $projUnknown -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fxUnknownB -Events @('Stop') -TargetProject $projUnknown -ClaudeOnly *> $null
        $recUnknownA = Get-RecordForScope 'ZZZ-Uninst-Orphanunknowna' $projUnknown
        $recUnknownB = Get-RecordForScope 'ZZZ-Uninst-Orphanunknownb' $projUnknown
        $unknownRuntimeRoot = Split-Path -Parent (Split-Path -Parent ([string]$recUnknownA.clients.claude.runtimeScript))

        $unknownLib = Join-Path $unknownRuntimeRoot '_hooklib.ps1'
        Write-Utf8 $unknownLib "# legacy shared library`n"
        $unknownRootFile = Join-Path $unknownRuntimeRoot 'NotAKnownSharedFile.txt'
        Write-Utf8 $unknownRootFile 'unrelated content'

        [void](Invoke-UninstallProcess -RecordId $recUnknownA.id)
        $rUnknownB = Invoke-UninstallProcess -RecordId $recUnknownB.id
        Check 'removing the last sibling (with an unknown root file present) exits 0' ($rUnknownB.Exit -eq 0) $rUnknownB.Err
        Check 'negative control: the KNOWN shared lib is still removed' (-not (Test-Path -LiteralPath $unknownLib))
        Check 'negative control: the UNKNOWN root file is never swept' (Test-Path -LiteralPath $unknownRootFile -PathType Leaf)
        Check 'negative control: the root survives because it is genuinely not empty' (Test-Path -LiteralPath $unknownRuntimeRoot -PathType Container)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Orphanunknowna'; Remove-FixtureHook 'ZZZ-Uninst-Orphanunknownb' }

    # =========================================================================
    Write-Host '--- shared runtime-root cleanup also applies to a GLOBAL-scope runtime root ---' -ForegroundColor Cyan
    $fxOrphanGlobalA = New-FixtureHook 'ZZZ-Uninst-Orphanglobala'
    $fxOrphanGlobalB = New-FixtureHook 'ZZZ-Uninst-Orphanglobalb'
    try {
        $fakeHomeOrphan = Join-Path $Work 'fakehome-orphanlib'
        New-Item -ItemType Directory -Path $fakeHomeOrphan -Force | Out-Null
        $rInstA = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $fxOrphanGlobalA, '-Events', 'Stop', '-ClaudeOnly') -FakeHome $fakeHomeOrphan
        Check 'setup: global sibling A installs' ($rInstA.Exit -eq 0) $rInstA.Err
        $rInstB = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $fxOrphanGlobalB, '-Events', 'Stop', '-ClaudeOnly') -FakeHome $fakeHomeOrphan
        Check 'setup: global sibling B installs' ($rInstB.Exit -eq 0) $rInstB.Err

        $recGlobalA = @(Get-RecordsFor 'ZZZ-Uninst-Orphanglobala' | Where-Object { $_.scope -eq 'global' })[0]
        $recGlobalB = @(Get-RecordsFor 'ZZZ-Uninst-Orphanglobalb' | Where-Object { $_.scope -eq 'global' })[0]
        Check 'setup: both global-scope records exist' ($null -ne $recGlobalA -and $null -ne $recGlobalB)

        $globalRuntimeRoot = Split-Path -Parent (Split-Path -Parent ([string]$recGlobalA.clients.claude.runtimeScript))
        Check 'setup: global runtime root leaf is Hook-Maker' ((Split-Path -Leaf $globalRuntimeRoot) -eq 'Hook-Maker')

        $globalOrphanLib = Join-Path $globalRuntimeRoot '_hooklib.ps1'
        Write-Utf8 $globalOrphanLib "# legacy shared library`n"

        $rGlobalA = Invoke-UninstallProcess -RecordId $recGlobalA.id -FakeHome $fakeHomeOrphan
        Check 'removing the first global sibling exits 0' ($rGlobalA.Exit -eq 0) $rGlobalA.Err
        Check 'global: a sibling remains -> the shared lib REMAINS' (Test-Path -LiteralPath $globalOrphanLib -PathType Leaf)
        Check 'global: a sibling remains -> the Hook-Maker root REMAINS' (Test-Path -LiteralPath $globalRuntimeRoot -PathType Container)

        $rGlobalB = Invoke-UninstallProcess -RecordId $recGlobalB.id -FakeHome $fakeHomeOrphan
        Check 'removing the LAST global sibling exits 0' ($rGlobalB.Exit -eq 0) $rGlobalB.Err
        Check 'global: no sibling remains -> the orphaned shared lib IS removed' (-not (Test-Path -LiteralPath $globalOrphanLib))
        Check 'global: no sibling remains -> the now-empty Hook-Maker root IS removed' (-not (Test-Path -LiteralPath $globalRuntimeRoot))
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Orphanglobala'; Remove-FixtureHook 'ZZZ-Uninst-Orphanglobalb' }
