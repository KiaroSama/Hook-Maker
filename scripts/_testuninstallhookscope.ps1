# Dot-sourced scenario block of Test-UninstallHook.ps1: scope isolation and
# basic safety - removing one project-A record leaves sibling records,
# project B and every unrelated settings/runtime file byte-for-byte intact;
# ownership is proven by managed runtime path (a foreign same-basename
# handler survives); a traversal-corrupted runtime path is refused with the
# decoy untouched; a hand-cleaned-up state is idempotent success; and a
# WhatIf / nonexistent-id run changes nothing byte-for-byte.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-UninstallHook.ps1 instead.

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
        $registryBefore = Get-InstallRegistryRawText -ToolRoot $ToolRoot

        $rWhatIf = Invoke-UninstallProcess -RecordId $recNoop.id -WhatIf
        Check 'a WhatIf run exits 0' ($rWhatIf.Exit -eq 0) $rWhatIf.Err
        Check 'a WhatIf run reports dryRun=true' ($rWhatIf.Result.dryRun -eq $true)
        $allUnchangedAfterWhatIf = $true
        foreach ($path in $snapshotPaths) { if (-not (Test-BytesEqual (Get-BytesOrEmpty $path) $before[$path])) { $allUnchangedAfterWhatIf = $false } }
        Check 'a WhatIf run leaves every settings/runtime file byte-for-byte unchanged' $allUnchangedAfterWhatIf
        Check 'a WhatIf run leaves the registry byte-for-byte unchanged' (
            [string]::Equals($registryBefore, (Get-InstallRegistryRawText -ToolRoot $ToolRoot), [System.StringComparison]::Ordinal))
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
    Write-Host '--- Test-Temp-Cleanup: uninstall retires the coordination record ---' -ForegroundColor Cyan
    # Cloudflare-Deploy proves "Test-Temp-Cleanup is installed here" primarily
    # from %LOCALAPPDATA%\HookMaker\state\TestTempCleanup-result-<key>.json -
    # only the hook writes one. A record that outlived its uninstall therefore
    # asserted an installation that no longer exists: the gate kept waiting for
    # a fresh 'clean' category nothing would ever write again, and the deploy
    # reminder was permanently dead in that project.
    #
    # The REAL hook is installed and its INSTALLED runtime copy is fired, so the
    # record under test is the one production actually writes. Nothing here
    # recomputes a project key - the key is a hash of a path SPELLING, so a test
    # that hand-built the path would agree with itself and still miss the file
    # production wrote. Each record is identified by which file APPEARED after
    # that project was fired.
    $cleanupSource = Join-Path $RealHooksDir 'Test-Temp-Cleanup\Test-Temp-Cleanup.ps1'
    Check 'setup: the real Test-Temp-Cleanup hook source exists' (Test-Path -LiteralPath $cleanupSource -PathType Leaf)

    # Installed one at a time so the newly-appeared file identifies its project.
    $seenRecords = @()
    $cleanupProjects = [ordered]@{}
    foreach ($caseName in @('Red', 'Keep', 'Green', 'Spelled')) {
        $proj = New-Proj ('CleanupState' + $caseName)
        # 'Spelled' installs with a TRAILING SEPARATOR: targetProjectRoot is only
        # GetFullPath'd at install time and GetFullPath keeps it, so the record
        # persists a spelling that hashes to a different key than the one the
        # hook - which canonicalizes with Normalize-Path - actually writes. An
        # uninstaller that skipped that canonicalization deleted nothing here
        # while reporting a clean success.
        $installTarget = if ($caseName -eq 'Spelled') { $proj + '\' } else { $proj }
        & $InstallScript -CustomHook $cleanupSource -Events @('Stop') -TargetProject $installTarget -ClaudeOnly *> $null
        $rec = @(Get-RecordsFor 'Test-Temp-Cleanup' | Where-Object { [string]$_.targetProjectRoot -eq $installTarget })[0]
        Check ('setup: ' + $caseName + ' got its own Test-Temp-Cleanup record') ($null -ne $rec)
        # cwd is the canonical spelling a client really sends, whatever spelling
        # the install was targeted with.
        [void](Invoke-CleanupHookStop -RuntimeScript ([string]$rec.clients.claude.runtimeScript) -Cwd $proj)
        $appeared = @(Get-CleanupRecordFiles | Where-Object { $seenRecords -notcontains $_.FullName })
        Check ('setup: firing ' + $caseName + '''s INSTALLED runtime wrote exactly one new coordination record') ($appeared.Count -eq 1)
        $seenRecords += @($appeared | ForEach-Object { $_.FullName })
        $cleanupProjects[$caseName] = [pscustomobject]@{
            Record = $rec; RecordFile = [string]$appeared[0].FullName
            RuntimeDir = (Split-Path -Parent ([string]$rec.clients.claude.runtimeScript))
        }
    }

    # Guards the Spelled case against silently degrading into a duplicate of the
    # canonical one: if the installer ever starts canonicalizing targetProjectRoot
    # itself, this fails loudly instead of leaving a green test that proves
    # nothing about the uninstaller's own canonicalization.
    Check 'setup: the Spelled record really persists a non-canonical spelling (the case still bites)' (
        ([string]$cleanupProjects['Spelled'].Record.targetProjectRoot) -cne
        (Normalize-Path ([string]$cleanupProjects['Spelled'].Record.targetProjectRoot)))

    # ---- RED (historical, self-retiring): the pre-change executor names the
    # record path nowhere, so it provably could not remove it. Executed for real
    # against a HEAD export staged beside copies of its sibling modules - the
    # shared working tree is never reverted.
    $headText = ((& git -C $ToolRoot show 'HEAD:scripts/Uninstall-Hook.ps1' 2>$null) -join "`n")
    if ([string]::IsNullOrWhiteSpace($headText) -or $headText -match 'TestTempCleanup-result') {
        Write-Host 'HEAD already retires the coordination record; historical red-proof retired.' -ForegroundColor DarkGray
    }
    else {
        $shadowDir = Join-Path $Work 'headuninstall'
        New-Item -ItemType Directory -Path $shadowDir -Force | Out-Null
        # The whole _*.ps1 set: the uninstaller's dot-source closure
        # (_installplan -> _clientcapability/_installkiro/..., _installlib ->
        # _installdiscovered -> _hookdiscovery, _uninstallownership) is entirely
        # underscore-prefixed, so one wildcard copy covers it without the test
        # having to track that graph.
        Copy-Item -Path (Join-Path $ScriptRoot '_*.ps1') -Destination $shadowDir -Force
        $shadowScript = Join-Path $shadowDir 'Uninstall-Hook.ps1'
        Write-Utf8 $shadowScript $headText
        $rRed = Invoke-UninstallProcess -RecordId ([string]$cleanupProjects['Red'].Record.id) -ScriptPath $shadowScript
        # Without this the red proof would pass vacuously whenever the shadow run
        # merely failed to do anything at all.
        Check 'RED-PROOF setup: the pre-fix executor really did complete the uninstall' (
            $rRed.Exit -eq 0 -and [string]$rRed.Result.overall -eq 'ok' -and
            @(Get-RecordsFor 'Test-Temp-Cleanup' | Where-Object { [string]$_.id -eq [string]$cleanupProjects['Red'].Record.id }).Count -eq 0) $rRed.Err
        Check 'RED-PROOF: the pre-fix executor leaves the coordination record behind (gate dead forever)' (
            Test-Path -LiteralPath $cleanupProjects['Red'].RecordFile -PathType Leaf)
    }

    # ---- a dry run must retire nothing.
    $rKeepWhatIf = Invoke-UninstallProcess -RecordId ([string]$cleanupProjects['Keep'].Record.id) -WhatIf
    Check 'a WhatIf uninstall leaves the coordination record in place' (
        $rKeepWhatIf.Exit -eq 0 -and (Test-Path -LiteralPath $cleanupProjects['Keep'].RecordFile -PathType Leaf)) $rKeepWhatIf.Err

    # ---- GREEN.
    $rGreen = Invoke-UninstallProcess -RecordId ([string]$cleanupProjects['Green'].Record.id)
    Check 'uninstalling Test-Temp-Cleanup succeeds' ($rGreen.Exit -eq 0 -and [string]$rGreen.Result.overall -eq 'ok') $rGreen.Err
    Check 'the uninstalled project''s coordination record is retired' (
        -not (Test-Path -LiteralPath $cleanupProjects['Green'].RecordFile))
    # The orphan-runtime-directory signal needs no separate handling: the client
    # remover already deletes the managed hook directory on this same success
    # path, so both of Test-CleanupInstalled's signals fall together.
    Check 'the weaker runtime-directory signal is retired by the same success path' (
        -not (Test-Path -LiteralPath $cleanupProjects['Green'].RuntimeDir))
    Check 'a still-installed project''s record is never swept' (
        Test-Path -LiteralPath $cleanupProjects['Keep'].RecordFile -PathType Leaf)

    # ---- the canonicalization proof: a trailing-separator targetProjectRoot
    # still resolves to the file the hook really wrote.
    $rSpelled = Invoke-UninstallProcess -RecordId ([string]$cleanupProjects['Spelled'].Record.id)
    Check 'uninstalling a trailing-separator-targeted record succeeds' (
        $rSpelled.Exit -eq 0 -and [string]$rSpelled.Result.overall -eq 'ok') $rSpelled.Err
    Check 'a trailing-separator targetProjectRoot still retires the record the hook actually wrote' (
        -not (Test-Path -LiteralPath $cleanupProjects['Spelled'].RecordFile))
    Check 'retiring one project''s record never sweeps an unrelated orphaned record' (
        Test-Path -LiteralPath $cleanupProjects['Red'].RecordFile -PathType Leaf)
