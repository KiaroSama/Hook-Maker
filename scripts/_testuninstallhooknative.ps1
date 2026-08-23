# Dot-sourced scenario block of Test-UninstallHook.ps1: the native Git
# pre-push chain, failure injection and strict record identity - full removal
# restores the preserved user hook byte-for-byte; a remaining foreign stage
# regenerates the wrapper; a tampered / marker-less / partially-removed
# wrapper is manualRepair with zero mutation; blocked Claude/Codex/registry
# writes produce no false success and no silent deletion; and every corrupted
# persisted identity field (runtimeScript, settingsPath, scope paths,
# non-string types) is refused while a genuine record still uninstalls
# cleanly.
# Defines $ignoreHook (the shipped fixture source), which the later ownership
# block also relies on - keep this file dot-sourced first.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-UninstallHook.ps1 instead.

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
    Write-Host '--- native Git: a wrapper file present but missing the marker is manualRepair - ownership unknown, never silent success ---' -ForegroundColor Cyan
    $noMarkerRepo = Join-Path $Work 'nomarker-repo'
    New-Item -ItemType Directory -Path $noMarkerRepo -Force | Out-Null
    Push-Location $noMarkerRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $noMarkerRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $noMarkerRepo *> $null
    $recNoMarker = Get-RecordForScope 'Ignore-Rules-Check' $noMarkerRepo
    $noMarkerWrapperPath = [string]$recNoMarker.nativeGit.wrapperPath
    $noMarkerRuntimeRoot = [string]$recNoMarker.nativeGit.runtimeRoot
    Check 'setup: the native chain is tracked as managed (no-marker case)' ($null -ne $recNoMarker.nativeGit -and $recNoMarker.nativeGit.managed -eq $true)

    # Replace the wrapper outright with a plain file carrying NO Hook Maker
    # marker - simulates a user or another tool having replaced it, where
    # ownership of whatever now sits at this path is genuinely unknown.
    Write-Utf8 $noMarkerWrapperPath "#!/bin/sh`necho a completely different pre-push hook, not ours`n"
    $noMarkerWrapperBytesBefore = Get-BytesOrEmpty $noMarkerWrapperPath
    $noMarkerClaudeSettingsBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.settingsPath)
    $noMarkerCodexSettingsBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.settingsPath)
    $noMarkerClaudeRuntimeBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.runtimeScript)
    $noMarkerCodexRuntimeBefore = Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.runtimeScript)

    $rNoMarker = Invoke-UninstallProcess -RecordId $recNoMarker.id
    Check 'a marker-less wrapper does not crash the uninstaller' ($rNoMarker.Exit -eq 0) $rNoMarker.Err
    Check 'a marker-less wrapper is reported as manualRepair overall' ([string]$rNoMarker.Result.overall -eq 'manualRepair') ($rNoMarker.Result | ConvertTo-Json -Depth 5)
    Check 'a marker-less wrapper is reported manualRepair for nativeGit with the precise reason' ((@($rNoMarker.Result.components | Where-Object { $_.component -eq 'nativeGit' }))[0].reason -eq 'wrapperReplacedOrOwnershipUnknown')
    Check 'the marker-less wrapper is preserved byte-for-byte (never overwritten)' (Test-BytesEqual (Get-BytesOrEmpty $noMarkerWrapperPath) $noMarkerWrapperBytesBefore)
    Check 'the managed native runtime directory still exists (never swept away)' (Test-Path -LiteralPath (Join-Path $noMarkerRuntimeRoot 'Ignore-Rules-Check'))
    Check 'the managed native companion directory still exists (never swept away)' (Test-Path -LiteralPath (Join-Path $noMarkerRuntimeRoot 'Secrets-Check'))
    Check 'the registry record is retained, not removed' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $noMarkerRepo }).Count -eq 1)
    Check 'claude is never even attempted once nativeGit is ambiguous' ((Get-ComponentStatus $rNoMarker.Result 'claude') -eq '')
    Check 'codex is never even attempted once nativeGit is ambiguous' ((Get-ComponentStatus $rNoMarker.Result 'codex') -eq '')
    Check 'Claude settings are byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.settingsPath)) $noMarkerClaudeSettingsBefore)
    Check 'Codex settings are byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.settingsPath)) $noMarkerCodexSettingsBefore)
    Check 'Claude runtime copy is byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.claude.runtimeScript)) $noMarkerClaudeRuntimeBefore)
    Check 'Codex runtime copy is byte-for-byte unchanged (proves nothing else was mutated)' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recNoMarker.clients.codex.runtimeScript)) $noMarkerCodexRuntimeBefore)

    # =========================================================================
    Write-Host '--- native Git: wrapper missing but owned native runtime remains -> retained as manual repair, never silently abandoned ---' -ForegroundColor Cyan
    $missingArtifactsRepo = Join-Path $Work 'missing-wrapper-artifacts-repo'
    New-Item -ItemType Directory -Path $missingArtifactsRepo -Force | Out-Null
    Push-Location $missingArtifactsRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $missingArtifactsRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $missingArtifactsRepo -ClaudeOnly *> $null
    $recMissingArtifacts = Get-RecordForScope 'Ignore-Rules-Check' $missingArtifactsRepo
    $maWrapperPath = [string]$recMissingArtifacts.nativeGit.wrapperPath
    $maRuntimeRoot = [string]$recMissingArtifacts.nativeGit.runtimeRoot
    Check 'setup: the native chain is tracked as managed (missing-wrapper-artifacts case)' ($null -ne $recMissingArtifacts.nativeGit -and $recMissingArtifacts.nativeGit.managed -eq $true)

    # Simulate the wrapper having been removed by hand while the managed
    # runtime directories are still sitting on disk (e.g. a crash between the
    # two deletes, or a user only deleting the wrapper).
    Remove-Item -LiteralPath $maWrapperPath -Force
    $maClaudeRuntimeBefore = Get-BytesOrEmpty ([string]$recMissingArtifacts.clients.claude.runtimeScript)

    $rMissingArtifacts = Invoke-UninstallProcess -RecordId $recMissingArtifacts.id
    Check 'a missing wrapper with owned artifacts remaining does not crash the uninstaller' ($rMissingArtifacts.Exit -eq 0) $rMissingArtifacts.Err
    Check 'a missing wrapper with owned artifacts remaining is reported as manualRepair overall' ([string]$rMissingArtifacts.Result.overall -eq 'manualRepair') ($rMissingArtifacts.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with owned artifacts remaining is reported manualRepair for nativeGit' ((Get-ComponentStatus $rMissingArtifacts.Result 'nativeGit') -eq 'manualRepair')
    Check 'the owned native runtime directory is left in place, not silently abandoned' (Test-Path -LiteralPath (Join-Path $maRuntimeRoot 'Ignore-Rules-Check'))
    Check 'the owned native companion directory is left in place too' (Test-Path -LiteralPath (Join-Path $maRuntimeRoot 'Secrets-Check'))
    Check 'the record is retained, not removed' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $missingArtifactsRepo }).Count -eq 1)
    Check 'claude is never even attempted once nativeGit needs manual repair' ((Get-ComponentStatus $rMissingArtifacts.Result 'claude') -eq '')
    Check 'the claude runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty ([string]$recMissingArtifacts.clients.claude.runtimeScript)) $maClaudeRuntimeBefore)

    # =========================================================================
    Write-Host '--- native Git: wrapper missing AND no owned native artifacts remain -> true idempotent success ---' -ForegroundColor Cyan
    $missingCleanRepo = Join-Path $Work 'missing-wrapper-clean-repo'
    New-Item -ItemType Directory -Path $missingCleanRepo -Force | Out-Null
    Push-Location $missingCleanRepo
    try { & git init --quiet -b main 2>$null | Out-Null } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $missingCleanRepo '.git\hooks') -Force | Out-Null

    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $missingCleanRepo -ClaudeOnly *> $null
    $recMissingClean = Get-RecordForScope 'Ignore-Rules-Check' $missingCleanRepo
    $mcWrapperPath = [string]$recMissingClean.nativeGit.wrapperPath
    $mcRuntimeRoot = [string]$recMissingClean.nativeGit.runtimeRoot
    Check 'setup: the native chain is tracked as managed (missing-wrapper-clean case)' ($null -ne $recMissingClean.nativeGit -and $recMissingClean.nativeGit.managed -eq $true)

    # A fully hand-cleaned-up native side: the wrapper AND every managed
    # runtime directory are already gone before the uninstaller ever runs.
    Remove-Item -LiteralPath $mcWrapperPath -Force
    Remove-Item -LiteralPath $mcRuntimeRoot -Recurse -Force

    $rMissingClean = Invoke-UninstallProcess -RecordId $recMissingClean.id
    Check 'a missing wrapper with no owned artifacts remaining does not crash the uninstaller' ($rMissingClean.Exit -eq 0) $rMissingClean.Err
    Check 'a missing wrapper with no owned artifacts remaining reports overall ok' ([string]$rMissingClean.Result.overall -eq 'ok') ($rMissingClean.Result | ConvertTo-Json -Depth 5)
    Check 'a missing wrapper with no owned artifacts remaining reports nativeGit ok (alreadyRemoved)' ((Get-ComponentStatus $rMissingClean.Result 'nativeGit') -eq 'ok')
    Check 'the record is fully removed (true idempotent success)' (@(Get-RecordsFor 'Ignore-Rules-Check' | Where-Object { $_.targetProjectRoot -eq $missingCleanRepo }).Count -eq 0)

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
        # The uninstall removes this record by DELETING its own file, so that
        # is the handle to hold: blocking a single document proved nothing once
        # the registry became a directory of per-record files.
        $registryPath = Get-InstallRecordPath -ToolRoot $ToolRoot -Id ([string]$recRegistryFail.id)

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

    # =========================================================================
    # Strict identity validation: the persisted registry record is the source
    # of truth. Every fixture below either (a) proves a GENUINE installer-
    # written record still passes every new invariant and uninstalls cleanly,
    # or (b) corrupts exactly one persisted invariant and proves NOTHING is
    # deleted, the record is retained, and the precise reason is manualRepair/
    # failed - never a silent guess.
    # =========================================================================

    Write-Host '--- CRITICAL: a genuine installer-written record still passes every new invariant and uninstalls cleanly (both clients) ---' -ForegroundColor Cyan
    $fxPositive = New-FixtureHook 'ZZZ-Uninst-Positive'
    try {
        $projPositive = New-Proj 'PositiveControlProj'
        & $InstallScript -CustomHook $fxPositive -Events @('Stop') -TargetProject $projPositive *> $null
        $recPositive = Get-RecordForScope 'ZZZ-Uninst-Positive' $projPositive
        Check 'positive control: install produced a both-client record' ($null -ne $recPositive -and (@(Get-InstalledClientNames -Record $recPositive) | Sort-Object) -join ',' -eq 'claude,codex')

        $rPositive = Invoke-UninstallProcess -RecordId $recPositive.id
        Check 'positive control: a real installer-written record exits 0' ($rPositive.Exit -eq 0) $rPositive.Err
        Check 'positive control: reports overall ok (the new invariants accept a genuine record)' ([string]$rPositive.Result.overall -eq 'ok') ($rPositive.Result | ConvertTo-Json -Depth 5)
        Check 'positive control: claude reported ok, not manualRepair' ((Get-ComponentStatus $rPositive.Result 'claude') -eq 'ok')
        Check 'positive control: codex reported ok, not manualRepair' ((Get-ComponentStatus $rPositive.Result 'codex') -eq 'ok')
        Check 'positive control: the record is fully removed' (@(Get-RecordsFor 'ZZZ-Uninst-Positive').Count -eq 0)
        Check 'positive control: the claude runtime copy is gone' (-not (Test-Path -LiteralPath ([string]$recPositive.clients.claude.runtimeScript)))
        Check 'positive control: the codex runtime copy is gone' (-not (Test-Path -LiteralPath ([string]$recPositive.clients.codex.runtimeScript)))
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Positive' }

    # =========================================================================
    Write-Host '--- identity: correct friendly name but a runtimeScript whose own directory no longer matches it is refused ---' -ForegroundColor Cyan
    $fxWrongScript = New-FixtureHook 'ZZZ-Uninst-Wrongscript'
    try {
        $projWrongScript = New-Proj 'WrongScriptProj'
        & $InstallScript -CustomHook $fxWrongScript -Events @('Stop') -TargetProject $projWrongScript -ClaudeOnly *> $null
        $recWrongScript = Get-RecordForScope 'ZZZ-Uninst-Wrongscript' $projWrongScript
        $origSettingsPath = [string]$recWrongScript.clients.claude.settingsPath
        $origRuntimeScript = [string]$recWrongScript.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

        # Still lives under the real runtimeRoot, and its own command is kept
        # consistent with it (so the registry-level "command targets
        # runtimeScript" check does not itself block this record) - but its
        # directory name no longer matches the record's friendlyName. That
        # inconsistency is internal to the record itself and is never trusted
        # to compute a delete target, regardless of what the command says.
        $decoyScript = Join-Path ([string]$recWrongScript.clients.claude.runtimeRoot) 'Some-Other-Name\Some-Other-Name.ps1'
        $recWrongScript.clients.claude.runtimeScript = $decoyScript
        $recWrongScript.clients.claude.command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $decoyScript + '"'
        Save-MutatedRecord -Record $recWrongScript

        $r = Invoke-UninstallProcess -RecordId $recWrongScript.id
        Check 'wrong runtimeScript does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'wrong runtimeScript is reported manualRepair overall' ([string]$r.Result.overall -eq 'manualRepair') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'wrong runtimeScript names a precise, non-empty reason' (-not [string]::IsNullOrWhiteSpace((Get-AnyRefusalReason $r.Result))) ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the original settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Wrongscript').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Wrongscript' }

    # =========================================================================
    Write-Host '--- identity: a runtimeScript with the correct basename living under a FOREIGN runtime root is refused ---' -ForegroundColor Cyan
    $fxForeignRoot = New-FixtureHook 'ZZZ-Uninst-Foreignroot'
    try {
        $projForeignA = New-Proj 'ForeignRootProjA'
        $projForeignB = New-Proj 'ForeignRootProjB'
        & $InstallScript -CustomHook $fxForeignRoot -Events @('Stop') -TargetProject $projForeignA -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fxForeignRoot -Events @('Stop') -TargetProject $projForeignB -ClaudeOnly *> $null
        $recForeignA = Get-RecordForScope 'ZZZ-Uninst-Foreignroot' $projForeignA
        $recForeignB = Get-RecordForScope 'ZZZ-Uninst-Foreignroot' $projForeignB

        $origSettingsPath = [string]$recForeignA.clients.claude.settingsPath
        $origRuntimeScript = [string]$recForeignA.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript
        $foreignRuntimeScript = [string]$recForeignB.clients.claude.runtimeScript
        $foreignBytesBefore = Get-BytesOrEmpty $foreignRuntimeScript

        # Same basename SHAPE (Hook-Maker\ZZZ-Uninst-Foreignroot\ZZZ-Uninst-Foreignroot.ps1)
        # but this is project B's own copy, entirely outside project A's runtimeRoot.
        $recForeignA.clients.claude.runtimeScript = $foreignRuntimeScript
        Save-MutatedRecord -Record $recForeignA

        $r = Invoke-UninstallProcess -RecordId $recForeignA.id
        Check 'foreign runtime root does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        # Caught either by Uninstall-Hook.ps1's own per-client containment
        # check or by the registry's own record-level validation gate - either
        # way the overall outcome must be manualRepair/failed, never a false
        # success, and nothing may be deleted.
        Check 'foreign runtime root is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the original project A settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original project A runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'project B''s real runtime script is NEVER touched' (Test-BytesEqual (Get-BytesOrEmpty $foreignRuntimeScript) $foreignBytesBefore)
        Check 'project A''s record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Foreignroot' | Where-Object { $_.targetProjectRoot -eq $projForeignA }).Count -eq 1)

        $rCleanupB = Invoke-UninstallProcess -RecordId $recForeignB.id
        Check 'cleanup: project B''s own untouched record still uninstalls cleanly' ($rCleanupB.Exit -eq 0 -and [string]$rCleanupB.Result.overall -eq 'ok') $rCleanupB.Err
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Foreignroot' }

    # =========================================================================
    Write-Host '--- identity: a runtimeScript pointing at a completely unrelated path is refused ---' -ForegroundColor Cyan
    $fxOutside = New-FixtureHook 'ZZZ-Uninst-Outsideroot'
    try {
        $projOutside = New-Proj 'OutsideRootProj'
        & $InstallScript -CustomHook $fxOutside -Events @('Stop') -TargetProject $projOutside -ClaudeOnly *> $null
        $recOutside = Get-RecordForScope 'ZZZ-Uninst-Outsideroot' $projOutside
        $origSettingsPath = [string]$recOutside.clients.claude.settingsPath
        $origRuntimeScript = [string]$recOutside.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

        $unrelatedFile = Join-Path $Work 'totally-unrelated-file.ps1'
        Write-Utf8 $unrelatedFile "exit 0`n"
        $recOutside.clients.claude.runtimeScript = $unrelatedFile
        Save-MutatedRecord -Record $recOutside

        $r = Invoke-UninstallProcess -RecordId $recOutside.id
        Check 'runtimeScript outside runtimeRoot does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'runtimeScript outside runtimeRoot is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the unrelated file itself is never touched' (Test-Path -LiteralPath $unrelatedFile)
        Check 'the original settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Outsideroot').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Outsideroot' }

    # =========================================================================
    Write-Host '--- identity: a runtimeScript directly under runtimeRoot (no hook subfolder) is refused ---' -ForegroundColor Cyan
    $fxRootEqual = New-FixtureHook 'ZZZ-Uninst-Rootequal'
    try {
        $projRootEqual = New-Proj 'RootEqualProj'
        & $InstallScript -CustomHook $fxRootEqual -Events @('Stop') -TargetProject $projRootEqual -ClaudeOnly *> $null
        $recRootEqual = Get-RecordForScope 'ZZZ-Uninst-Rootequal' $projRootEqual
        $origSettingsPath = [string]$recRootEqual.clients.claude.settingsPath
        $origRuntimeScript = [string]$recRootEqual.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript
        $runtimeRootForRootEqual = [string]$recRootEqual.clients.claude.runtimeRoot

        $rootEqualScript = Join-Path $runtimeRootForRootEqual 'ZZZ-Uninst-Rootequal.ps1'
        $recRootEqual.clients.claude.runtimeScript = $rootEqualScript
        Save-MutatedRecord -Record $recRootEqual

        $r = Invoke-UninstallProcess -RecordId $recRootEqual.id
        Check 'runtimeScript directly under runtimeRoot does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'runtimeScript directly under runtimeRoot is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the whole runtimeRoot directory survives (never treated as one hook''s own directory)' (Test-Path -LiteralPath $runtimeRootForRootEqual -PathType Container)
        Check 'the original settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the original runtime script is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Rootequal').Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Rootequal' }

    # =========================================================================
    Write-Host '--- identity: a project record whose Claude settingsPath does not match the canonical project path is refused ---' -ForegroundColor Cyan
    $fxWrongClaudeSettings = New-FixtureHook 'ZZZ-Uninst-Wrongclaudesettings'
    try {
        $projWrongClaudeSettings = New-Proj 'WrongClaudeSettingsProj'
        & $InstallScript -CustomHook $fxWrongClaudeSettings -Events @('Stop') -TargetProject $projWrongClaudeSettings *> $null
        $recWCS = Get-RecordForScope 'ZZZ-Uninst-Wrongclaudesettings' $projWrongClaudeSettings
        $origClaudeSettingsPath = [string]$recWCS.clients.claude.settingsPath
        $origClaudeRuntimeScript = [string]$recWCS.clients.claude.runtimeScript
        $claudeSettingsBefore = Get-BytesOrEmpty $origClaudeSettingsPath
        $claudeRuntimeBefore = Get-BytesOrEmpty $origClaudeRuntimeScript

        # A plausible but WRONG project settings path (settings.json instead of
        # the machine-specific settings.local.json Install-Hook.ps1 actually writes).
        $wrongPath = Join-Path $projWrongClaudeSettings '.claude\settings.json'
        Write-Utf8 $wrongPath '{"hooks":{}}'
        $recWCS.clients.claude.settingsPath = $wrongPath
        Save-MutatedRecord -Record $recWCS

        $r = Invoke-UninstallProcess -RecordId $recWCS.id
        Check 'wrong Claude settingsPath does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'wrong Claude settingsPath is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        # A malformed record is refused BEFORE either client is even attempted
        # (this is a whole-record validity gate, not a per-client one) - codex
        # is therefore never touched either, not "independently succeeded".
        Check 'codex is never even attempted for a record that fails validation' ((Get-ComponentStatus $r.Result 'codex') -ne 'ok')
        Check 'the real Claude settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origClaudeSettingsPath) $claudeSettingsBefore)
        Check 'the Claude runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origClaudeRuntimeScript) $claudeRuntimeBefore)
        Check 'the decoy settings.json is untouched too' ((Get-Content -LiteralPath $wrongPath -Raw) -eq '{"hooks":{}}')
        $retainedWCS = @(Get-Registry).installs | Where-Object { $_.id -eq $recWCS.id } | Select-Object -First 1
        Check 'the retained record still lists claude' ($null -ne $retainedWCS.clients.claude)
        Check 'the retained record still lists codex too (nothing was ever attempted, so nothing was dropped)' ($null -ne $retainedWCS.clients.codex)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Wrongclaudesettings' }

    # =========================================================================
    Write-Host '--- identity: a project record whose Codex settingsPath does not match the canonical project path is refused ---' -ForegroundColor Cyan
    $fxWrongCodexSettings = New-FixtureHook 'ZZZ-Uninst-Wrongcodexsettings'
    try {
        $projWrongCodexSettings = New-Proj 'WrongCodexSettingsProj'
        & $InstallScript -CustomHook $fxWrongCodexSettings -Events @('Stop') -TargetProject $projWrongCodexSettings *> $null
        $recWKS = Get-RecordForScope 'ZZZ-Uninst-Wrongcodexsettings' $projWrongCodexSettings
        $origCodexSettingsPath = [string]$recWKS.clients.codex.settingsPath
        $origCodexRuntimeScript = [string]$recWKS.clients.codex.runtimeScript
        $codexSettingsBefore = Get-BytesOrEmpty $origCodexSettingsPath
        $codexRuntimeBefore = Get-BytesOrEmpty $origCodexRuntimeScript

        $wrongPath = Join-Path $projWrongCodexSettings '.codex\hooks-wrong.json'
        Write-Utf8 $wrongPath '{"hooks":{}}'
        $recWKS.clients.codex.settingsPath = $wrongPath
        Save-MutatedRecord -Record $recWKS

        $r = Invoke-UninstallProcess -RecordId $recWKS.id
        Check 'wrong Codex settingsPath does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'wrong Codex settingsPath is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        # Whole-record validity gate: claude is never even attempted either.
        Check 'claude is never even attempted for a record that fails validation' ((Get-ComponentStatus $r.Result 'claude') -ne 'ok')
        Check 'the real Codex hooks file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origCodexSettingsPath) $codexSettingsBefore)
        Check 'the Codex runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origCodexRuntimeScript) $codexRuntimeBefore)
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Wrongcodexsettings' }

    # =========================================================================
    Write-Host '--- identity: a GLOBAL-scope record whose settingsPath does not match the canonical global path is refused ---' -ForegroundColor Cyan
    $fxGlobalForeign = New-FixtureHook 'ZZZ-Uninst-Globalforeign'
    try {
        $fakeHome = Join-Path $Work 'fakehome-globalforeign'
        New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
        $rInstall = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $fxGlobalForeign, '-Events', 'Stop', '-ClaudeOnly') -FakeHome $fakeHome
        Check 'setup: global-scope install exits 0' ($rInstall.Exit -eq 0) $rInstall.Err
        $recGlobal = @(Get-RecordsFor 'ZZZ-Uninst-Globalforeign' | Where-Object { $_.scope -eq 'global' })[0]
        Check 'setup: global-scope record has an empty targetProjectRoot' ($null -ne $recGlobal -and [string]::IsNullOrWhiteSpace([string]$recGlobal.targetProjectRoot))

        $origSettingsPath = [string]$recGlobal.clients.claude.settingsPath
        $origRuntimeScript = [string]$recGlobal.clients.claude.runtimeScript
        $settingsBefore = Get-BytesOrEmpty $origSettingsPath
        $runtimeBefore = Get-BytesOrEmpty $origRuntimeScript

        # A foreign settings path: a DIFFERENT fake home entirely, never the
        # canonical <fakeHome>\.claude\settings.json Install-Hook.ps1 itself wrote.
        $otherFakeHome = Join-Path $Work 'fakehome-globalforeign-other'
        $foreignPath = Join-Path $otherFakeHome '.claude\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $foreignPath) -Force | Out-Null
        Write-Utf8 $foreignPath '{"hooks":{}}'
        $recGlobal.clients.claude.settingsPath = $foreignPath
        Save-MutatedRecord -Record $recGlobal

        $r = Invoke-UninstallProcess -RecordId $recGlobal.id -FakeHome $fakeHome
        Check 'global foreign settingsPath does not crash the uninstaller' ($r.Exit -eq 0) $r.Err
        Check 'global foreign settingsPath is reported manualRepair/failed overall, never ok' ([string]$r.Result.overall -ne 'ok') ($r.Result | ConvertTo-Json -Depth 5)
        Check 'the real global (fake home) settings file is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origSettingsPath) $settingsBefore)
        Check 'the real global runtime copy is untouched' (Test-BytesEqual (Get-BytesOrEmpty $origRuntimeScript) $runtimeBefore)
        Check 'the foreign settings file is untouched' ((Get-Content -LiteralPath $foreignPath -Raw) -eq '{"hooks":{}}')
        Check 'the record is retained' (@(Get-RecordsFor 'ZZZ-Uninst-Globalforeign').Count -eq 1)

        # Repair the path back and clean up so this doesn't leak a permanently-
        # broken global record for the rest of the isolated test run.
        $recGlobal.clients.claude.settingsPath = $origSettingsPath
        Save-MutatedRecord -Record $recGlobal
        $rCleanup = Invoke-UninstallProcess -RecordId $recGlobal.id -FakeHome $fakeHome
        Check 'cleanup: repairing settingsPath back allows a clean uninstall' ($rCleanup.Exit -eq 0 -and [string]$rCleanup.Result.overall -eq 'ok') $rCleanup.Err
    }
    finally { Remove-FixtureHook 'ZZZ-Uninst-Globalforeign' }
