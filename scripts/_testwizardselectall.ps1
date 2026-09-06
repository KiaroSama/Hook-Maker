# Test-Wizard.ps1 scenario block: SELECT ALL and INSTALLER IDEMPOTENCY - the
# aggregate menu item 1 (sync group + every hook, shared paths, no double
# install, cancel semantics, client scoping, first/last individual entries,
# idempotent reinstall), the byte-for-byte planned-content checks for the
# menu-affected hooks, the three test-health hooks with their canonical
# events/timeouts and the guarded runner shipped beside Test-Run-Guard, and
# the synthetic-hook fixture proving the set is discovered dynamically.
#
# Defines $RealHooksDir and $hookCount, used by the scenarios that follow it
# in this file.
#
# Dot-sourced by Test-Wizard.ps1 into the caller's scope (uses its harness,
# helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- Select all hooks (aggregate menu item 1 = sync group + every hook) ---' -ForegroundColor Cyan
    $RealHooksDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
    # TWO different numbers, and conflating them is what let a sibling suite's
    # ZZZ-* fixture (or an aborted run's leftover) break this block:
    #   $hookCount        every hook Select All will configure - shipped AND
    #                     custom, so a ZZZ-* fixture belongs in it.
    #   $shippedHookCount MENU-INDEX arithmetic only. Custom hooks render AFTER
    #                     the three management rows, so a shipped index is
    #                     shipped+N and must never count a ZZZ-* fixture -
    #                     otherwise +2 selects "Update installed hooks" and the
    #                     scripted answers march on into the wrong flow.
    $hookCount = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
    $shippedHookCount = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' -and $_.Name -notlike 'ZZZ-*' }).Count
    $syncX = New-Proj 'SelectAllSyncX'; $syncY = New-Proj 'SelectAllSyncY'

    $cfgAll = Join-Path $Work 'cfg-all.json'; New-Config $cfgAll
    # Select-all expands to the sync group + every hook. Path-sharing: the paths
    # entered for the sync group (syncX, syncY) are REUSED as the install targets
    # for every hook, so the hook phase is NOT re-prompted for a path.
    # main 1 -> sub 1 -> "1" (select all) ->
    #   [sync group: syncX, syncY, done, client Both, confirm] ->
    #   [hooks: mode 1, client Both, confirm]   (no target re-prompt)
    $rAll = Invoke-Wizard -Config $cfgAll -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '1', '', '0')
    Check 'exit 0' ($rAll.Exit -eq 0) $rAll.Err
    Check 'no stderr' ($rAll.Err -eq '')
    Check 'select-all alone (no "2" typed) still runs the sync group' ($rAll.Out -match 'Running the sync group first')
    Check 'select-all reuses the sync-group paths for the hooks (no second path prompt)' ($rAll.Out -match 'Reusing the same 2 project path')
    Check 'the sync group''s project entry is the ONLY "Add Projects" phase' ((@([regex]::Matches($rAll.Out, 'Add Projects'))).Count -eq 1)
    Check ('select-all configures every discovered hook (' + $hookCount + ')') ($rAll.Out -match ('Configuring ' + $hookCount + ' hooks:'))
    Check 'completion summary reports both the sync group and the resolved hook count' ($rAll.Out -match ('Sync group \+ ' + $hookCount + ' hook\(s\) installed'))
    # syncX is now BOTH a sync-group target (gets the engine) AND a hook target
    # (gets every shipped hook), because the paths are shared.
    $allFolders = @(Get-ChildItem -LiteralPath (Join-Path $syncX '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $shippedFolders = @($allFolders | Where-Object { $_ -ne 'Cross-Project-.ai-Knowledge-Sync' })
    Check 'select-all installs every shipped hook exactly once into the shared target' ($shippedFolders.Count -eq $hookCount -and @($shippedFolders | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0)
    Check 'select-all never installs the sync engine as a PLAIN hook (the engine folder is there only as a sync-group target)' ($shippedFolders -notcontains 'Cross-Project-.ai-Knowledge-Sync')
    Check 'select-all includes Cloudflare-Deploy (the last individual entry)' ($shippedFolders -contains 'Cloudflare-Deploy')
    Check 'the shipped hooks also went into the SECOND shared target' (Test-Path (Join-Path $syncY '.claude\hooks\Hook-Maker\Cloudflare-Deploy'))
    $profAll = @((Get-Content $cfgAll -Raw | ConvertFrom-Json).profiles)
    Check 'select-all applies the sync-group profile exactly once' ($profAll.Count -eq 1 -and @($profAll[0].routes).Count -eq 2)
    Check 'sync group installed its engine at the sync-group targets' (
        (Test-Path (Join-Path $syncX '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1')) -and
        (Test-Path (Join-Path $syncY '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1')))

    # Combining "1" (select all) with an explicit individual pick must not
    # install anything twice, and the sync group still runs exactly once.
    $cfgAllCombo = Join-Path $Work 'cfg-all-combo.json'; New-Config $cfgAllCombo
    $rCombo = Invoke-Wizard -Config $cfgAllCombo -Answers @('1', '1', '1,5', $syncX, $syncY, 'done', '1', '', '1', '1', '', '0')
    Check 'select-all + explicit pick still runs the sync group exactly once' ((@([regex]::Matches($rCombo.Out, 'Running the sync group first'))).Count -eq 1)
    Check 'select-all combined with an explicit pick still configures each hook exactly once' ($rCombo.Out -match ('Configuring ' + $hookCount + ' hooks:'))

    # Combining "1" with "2" (the sync group's own item) must not run the
    # sync group twice either.
    $cfgAllWith2 = Join-Path $Work 'cfg-all-with2.json'; New-Config $cfgAllWith2
    $rWith2 = Invoke-Wizard -Config $cfgAllWith2 -Answers @('1', '1', '1,2', $syncX, $syncY, 'done', '1', '', '1', '1', '', '0')
    Check 'select-all + explicit "2" still runs the sync group exactly once (no duplicate)' ((@([regex]::Matches($rWith2.Out, 'Running the sync group first'))).Count -eq 1)
    Check '"1,2" still configures every hook exactly once' ($rWith2.Out -match ('Configuring ' + $hookCount + ' hooks:'))

    # Canceling the sync-group confirmation must not install any individual
    # hook and must not claim success.
    $cfgCancel = Join-Path $Work 'cfg-all-cancel.json'; New-Config $cfgCancel
    $cancelProj = New-Proj 'SelectAllCancel'
    $rCancel = Invoke-Wizard -Config $cfgCancel -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', 'n', '0')
    Check 'exit 0 (sync-group stage canceled)' ($rCancel.Exit -eq 0)
    Check 'canceling the sync-group stage reports Canceled, not success' ($rCancel.Out -match 'Canceled\. Nothing was changed\.' -and $rCancel.Out -notmatch 'hook\(s\) installed')
    Check 'canceling the sync-group stage installs no individual hook' (-not (Test-Path (Join-Path $cancelProj '.claude')))

    # Client scoping applies through the shared-path sync+hook flow. It is the same
    # code for 1 hook or all 21, so this uses a small "2,3" (sync group + one hook)
    # selection with one client and a FRESH project - installing every shipped hook just
    # to check a client flag would be unnecessarily heavy (a reused project would
    # also already carry an earlier Both-client install).
    $cfgAllClaude = Join-Path $Work 'cfg-all-claude.json'; New-Config $cfgAllClaude
    $caX = New-Proj 'SelAllClaudeX'; $caY = New-Proj 'SelAllClaudeY'
    # Client answer is menu item 1 = Claude (twice: once for the sync group, once
    # for the hook phase). The '1' between them is the events MODE, not a client.
    $null = Invoke-Wizard -Config $cfgAllClaude -Answers @('1', '1', '2,3', $caX, $caY, 'done', '1', '', '1', '1', '', '0')
    Check 'a shared-path sync+hook install honors Claude-only client scoping' ((Test-Path (Join-Path $caX '.claude\settings.local.json')) -and -not (Test-Path (Join-Path $caX '.codex')))

    $cfgAllCodex = Join-Path $Work 'cfg-all-codex.json'; New-Config $cfgAllCodex
    $coX = New-Proj 'SelAllCodexX'; $coY = New-Proj 'SelAllCodexY'
    # Client answer is menu item 2 = Codex (sync group, then hook phase).
    $null = Invoke-Wizard -Config $cfgAllCodex -Answers @('1', '1', '2,3', $coX, $coY, 'done', '2', '', '1', '2', '', '0')
    Check 'a shared-path sync+hook install honors Codex-only client scoping' ((Test-Path (Join-Path $coX '.codex\hooks.json')) -and -not (Test-Path (Join-Path $coX '.claude')))

    # Selecting the second-to-last individual entry installs Session-Summary-Check
    # (menu item 28, immediately before Cloudflare-Deploy). The point of the
    # assertion is the BOUNDARY - the entry just before the last one - so it
    # follows whichever hook currently sits there, not a pinned name.
    $cfgPenult = Join-Path $Work 'cfg-penult.json'; New-Config $cfgPenult
    $penultProj = New-Proj 'PenultEntryProj'
    # Answers after the hook item are events '2', then client '1' (= Claude).
    $rPenult = Invoke-Wizard -Config $cfgPenult -Answers @('1', '1', ($shippedHookCount + 1).ToString(), '2', '1', $penultProj, 'done', '', '0')
    Check 'selecting the second-to-last individual entry installs Session-Summary-Check' (Test-Path (Join-Path $penultProj '.claude\hooks\Hook-Maker\Session-Summary-Check\Session-Summary-Check.ps1'))
    Check 'did not install the neighboring Cloudflare-Deploy hook instead' (-not (Test-Path (Join-Path $penultProj '.claude\hooks\Hook-Maker\Cloudflare-Deploy')))

    # Selecting the LAST individual entry (a single-hook pick, no aggregate)
    # installs Cloudflare-Deploy specifically and does NOT run the sync group.
    $cfgLast = Join-Path $Work 'cfg-last.json'; New-Config $cfgLast
    $lastProj = New-Proj 'LastEntryProj'
    # Answers after the hook item are events '2', then client '1' (= Claude).
    $rLast = Invoke-Wizard -Config $cfgLast -Answers @('1', '1', ($shippedHookCount + 2).ToString(), '2', '1', $lastProj, 'done', '', '0')
    Check 'selecting the last individual entry installs Cloudflare-Deploy' (Test-Path (Join-Path $lastProj '.claude\hooks\Hook-Maker\Cloudflare-Deploy\Cloudflare-Deploy.ps1'))
    Check 'selecting a single individual entry does not run the sync group' ($rLast.Out -notmatch 'Running the sync group first')

    # Reinstalling via Select All stays idempotent: same set, no duplicate
    # registrations, nothing previously installed goes missing, sync-group
    # profile is updated in place rather than duplicated.
    # Path-sharing: the reinstall reuses syncX/syncY too - no separate hooks target
    # is prompted, so the hooks land in the SAME shared projects as the first pass.
    $rAllAgain = Invoke-Wizard -Config $cfgAll -Answers @('1', '1', '1', $syncX, $syncY, 'done', '1', '', '1', '1', '', '0')
    Check 'exit 0 (select-all reinstall)' ($rAllAgain.Exit -eq 0) $rAllAgain.Err
    $allFoldersAgain = @(Get-ChildItem -LiteralPath (Join-Path $syncX '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'reinstall via select-all stays idempotent (same folder set as the first pass)' ($allFoldersAgain.Count -eq $allFolders.Count)
    Check 'reinstall preserves every previously-installed hook (none dropped or duplicated)' (((@($allFolders | Sort-Object)) -join ',') -eq ((@($allFoldersAgain | Sort-Object)) -join ','))
    $profAllAgain = @((Get-Content $cfgAll -Raw | ConvertFrom-Json).profiles)
    Check 'reinstall does not duplicate the sync-group profile' ($profAllAgain.Count -eq 1 -and $profAllAgain[0].id -eq $profAll[0].id)
    # Parse the JSON (rather than raw-text/regex match it) so JSON's own
    # backslash-escaping ("\\") can never be mistaken for a missing/duplicate
    # entry: count actual handler entries whose (decoded) command references
    # Ai-Memory-Check's runtime copy.
    $claudeSettingsAllObj = Get-Content -LiteralPath (Join-Path $syncX '.claude\settings.local.json') -Raw | ConvertFrom-Json
    $aiMemHandlerCount = 0
    foreach ($eventProp in $claudeSettingsAllObj.hooks.PSObject.Properties) {
        foreach ($group in @($eventProp.Value)) {
            foreach ($handler in @($group.hooks)) {
                if ([string]$handler.command -like '*Ai-Memory-Check\Ai-Memory-Check.ps1*') { $aiMemHandlerCount++ }
            }
        }
    }
    Check 'reinstall does not duplicate a hook''s registration' ($aiMemHandlerCount -eq 1)

    # =====================================================================
    Write-Host '--- installer/idempotency check: Docs-Freshness-Check (new menu item 9) ---' -ForegroundColor Cyan
    # Selected together with its neighbor (13) so this goes through the
    # multi-hook "recommended events per hook" mode (a single-item selection
    # instead takes the fixed 4-choice event menu, which has no "recommended"
    # option - see Read-HookConfig/Read-EventSelection).
    $cfgDocs = Join-Path $Work 'cfg-docs.json'; New-Config $cfgDocs
    $docsProj = New-Proj 'DocsFreshnessProj'
    $rDocs = Invoke-Wizard -Config $cfgDocs -Answers @('1', '1', '12,13', '1', '1', $docsProj, 'done', '', '0')
    Check 'exit 0 (installing Docs-Freshness-Check)' ($rDocs.Exit -eq 0)
    Check 'Docs-Freshness-Check installed at its own friendly folder' (Test-Path (Join-Path $docsProj '.claude\hooks\Hook-Maker\Docs-Freshness-Check\Docs-Freshness-Check.ps1'))
    $docsEvents = @(Get-RegisteredEvents (Join-Path $docsProj '.claude\settings.local.json') 'Docs-Freshness-Check' | Sort-Object) -join ','
    Check 'Docs-Freshness-Check gets its recommended SessionStart,Stop events' ($docsEvents -eq 'SessionStart,Stop') $docsEvents
    $docsSourceHash = Get-PlanArtifactExpectedHash -Artifact (New-PlanArtifact -RelativePath 'expected' -Kind 'Generated' -GeneratedContent (Get-PrivateLibraryScriptContent -SourceScriptPath (Join-Path $RealHooksDir 'Docs-Freshness-Check\Docs-Freshness-Check.ps1')))
    $docsInstalledHash = (Get-FileHash -LiteralPath (Join-Path $docsProj '.claude\hooks\Hook-Maker\Docs-Freshness-Check\Docs-Freshness-Check.ps1') -Algorithm SHA256).Hash
    Check 'the installed Docs-Freshness-Check copy matches its planned content byte-for-byte' ($docsSourceHash -eq $docsInstalledHash)
    $rDocsAgain = Invoke-Wizard -Config $cfgDocs -Answers @('1', '1', '9,10', '1', '1', $docsProj, 'done', '', '0')
    Check 'exit 0 (reinstalling Docs-Freshness-Check)' ($rDocsAgain.Exit -eq 0)
    $docsFoldersAgain = @(Get-ChildItem -LiteralPath (Join-Path $docsProj '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'reinstall keeps exactly one Docs-Freshness-Check folder (no duplicate)' (@($docsFoldersAgain | Where-Object { $_ -eq 'Docs-Freshness-Check' }).Count -eq 1)

    # =====================================================================
    Write-Host '--- installer/idempotency check: the two menu-affected hooks (22, 28) ---' -ForegroundColor Cyan
    # Test-Temp-Cleanup is at 22 (three hooks were inserted above it at 9-11);
    # Cloudflare-Deploy stays the last entry, i.e. $shippedHookCount + 2, which
    # is why it is computed rather than written.
    $cfgAffected = Join-Path $Work 'cfg-affected.json'; New-Config $cfgAffected
    $affectedProj = New-Proj 'AffectedHooksProj'
    $affectedSelection = '22,' + ($shippedHookCount + 2).ToString()
    $rAffected = Invoke-Wizard -Config $cfgAffected -Answers @('1', '1', $affectedSelection, '1', '1', $affectedProj, 'done', '', '0')
    Check 'exit 0 (installing Test-Temp-Cleanup + Cloudflare-Deploy together)' ($rAffected.Exit -eq 0)
    Check 'both affected hooks installed' (
        (Test-Path (Join-Path $affectedProj '.claude\hooks\Hook-Maker\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1')) -and
        (Test-Path (Join-Path $affectedProj '.claude\hooks\Hook-Maker\Cloudflare-Deploy\Cloudflare-Deploy.ps1')))
    $cleanupEvents = @(Get-RegisteredEvents (Join-Path $affectedProj '.claude\settings.local.json') 'Test-Temp-Cleanup' | Sort-Object) -join ','
    Check 'Test-Temp-Cleanup gets its recommended SessionStart,Stop events' ($cleanupEvents -eq 'SessionStart,Stop') $cleanupEvents
    $cfDeployEvents = @(Get-RegisteredEvents (Join-Path $affectedProj '.claude\settings.local.json') 'Cloudflare-Deploy' | Sort-Object) -join ','
    Check 'Cloudflare-Deploy still gets its recommended Stop event' ($cfDeployEvents -eq 'Stop') $cfDeployEvents
    $cleanupSourceHash = Get-PlanArtifactExpectedHash -Artifact (New-PlanArtifact -RelativePath 'expected' -Kind 'Generated' -GeneratedContent (Get-PrivateLibraryScriptContent -SourceScriptPath (Join-Path $RealHooksDir 'Test-Temp-Cleanup\Test-Temp-Cleanup.ps1')))
    $cleanupInstalledHash = (Get-FileHash -LiteralPath (Join-Path $affectedProj '.claude\hooks\Hook-Maker\Test-Temp-Cleanup\Test-Temp-Cleanup.ps1') -Algorithm SHA256).Hash
    Check 'the installed Test-Temp-Cleanup copy matches its planned content byte-for-byte' ($cleanupSourceHash -eq $cleanupInstalledHash)

    # Reinstalling the same pair is idempotent: no duplicate registrations,
    # no duplicate runtime folders.
    $rAffectedAgain = Invoke-Wizard -Config $cfgAffected -Answers @('1', '1', $affectedSelection, '1', '1', $affectedProj, 'done', '', '0')
    Check 'exit 0 (reinstalling the same pair)' ($rAffectedAgain.Exit -eq 0)
    $affectedFolders = @(Get-ChildItem -LiteralPath (Join-Path $affectedProj '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $affectedFoldersJoined = (@($affectedFolders | Sort-Object)) -join ','
    Check 'reinstall keeps exactly these two folders (no duplicates, none dropped)' ($affectedFoldersJoined -eq 'Cloudflare-Deploy,Test-Temp-Cleanup')
    $affectedSettingsObj = Get-Content -LiteralPath (Join-Path $affectedProj '.claude\settings.local.json') -Raw | ConvertFrom-Json
    $cleanupHandlerCount = 0
    foreach ($eventProp in $affectedSettingsObj.hooks.PSObject.Properties) {
        foreach ($group in @($eventProp.Value)) {
            foreach ($handler in @($group.hooks)) {
                if ([string]$handler.command -like '*Test-Temp-Cleanup\Test-Temp-Cleanup.ps1*') { $cleanupHandlerCount++ }
            }
        }
    }
    Check 'reinstall does not duplicate Test-Temp-Cleanup''s registration (one per configured event)' ($cleanupHandlerCount -eq 2)
    # Test-Temp-Cleanup declares no Timeout in $script:HookMeta, so its
    # registration must stay on the historical default of 60 - the per-hook
    # timeout feature may not change a single hook that did not ask for one.
    $cleanupTimeouts = @(Get-RegisteredTimeouts (Join-Path $affectedProj '.claude\settings.local.json') 'Test-Temp-Cleanup')
    Check 'a hook without a metadata Timeout still registers the historical default 60' (
        $cleanupTimeouts.Count -eq 2 -and @($cleanupTimeouts | Where-Object { $_ -ne '60' }).Count -eq 0) ($cleanupTimeouts -join ',')

    # =====================================================================
    Write-Host '--- the three test-health hooks: canonical events + per-hook timeout (24.txt) ---' -ForegroundColor Cyan
    # 20,21,22 selected together so the batch takes the "recommended events per
    # hook" path - which resolves each hook's events through
    # Get-HookRecommendedEvents, i.e. straight out of $script:HookMeta (none of
    # the three ships a .env.example, so a generic default would be the
    # regression this pins).
    $cfgHealth = Join-Path $Work 'cfg-health.json'; New-Config $cfgHealth
    $healthProj = New-Proj 'TestHealthHooksProj'
    # mode '1' (recommended events per hook), then client '4' = All clients - the
    # only single pick that reaches Claude AND Codex, which the per-client
    # assertions below require. The kiro component is recorded failed and dropped.
    $rHealth = Invoke-Wizard -Config $cfgHealth -Answers @('1', '1', '23-25', '1', '4', $healthProj, 'done', '', '0')
    Check 'exit 0 (installing the three test-health hooks)' ($rHealth.Exit -eq 0) $rHealth.Err
    Check 'no stderr (installing the three test-health hooks)' ($rHealth.Err -eq '')
    $healthClaude = Join-Path $healthProj '.claude\settings.local.json'
    $healthCodex = Join-Path $healthProj '.codex\hooks.json'
    # name -> canonical events + canonical timeout, exactly as $script:HookMeta declares them.
    $healthExpected = [ordered]@{
        'Test-Plan-Check'       = @{ Events = 'SessionStart,UserPromptSubmit'; Timeout = '15' }
        'Test-Run-Guard'        = @{ Events = 'PostToolUse,PreToolUse';        Timeout = '10' }
        'Test-Completion-Check' = @{ Events = 'Stop,SubagentStop';             Timeout = '20' }
    }
    foreach ($entry in $healthExpected.GetEnumerator()) {
        $hookName = $entry.Key
        Check ($hookName + ' installed at its own friendly folder') (Test-Path (Join-Path $healthProj ('.claude\hooks\Hook-Maker\' + $hookName + '\' + $hookName + '.ps1')))
        foreach ($settings in @($healthClaude, $healthCodex)) {
            $client = if ($settings -eq $healthClaude) { 'claude' } else { 'codex' }
            $events = @(Get-RegisteredEvents $settings $hookName | Sort-Object) -join ','
            Check ($hookName + ' registers its canonical metadata events in ' + $client) ($events -eq $entry.Value.Events) $events
            $timeouts = @(Get-RegisteredTimeouts $settings $hookName)
            Check ($hookName + ' registers its canonical metadata timeout in ' + $client) (
                $timeouts.Count -eq 2 -and @($timeouts | Where-Object { $_ -ne $entry.Value.Timeout }).Count -eq 0) ($timeouts -join ',')
        }
    }
    # HM-06 install integrity: the during-stage is useless without its bounded
    # runner, so a REAL install must land Run-Tests-Guarded.ps1 beside
    # Test-Run-Guard in the target - and ONLY there. Proven physically, not just in
    # the plan. Combined with the per-client event checks above, this is "all three
    # hooks AND the guarded runner present for the correct clients/events".
    $trgRunnerClaude = Join-Path $healthProj '.claude\hooks\Hook-Maker\Test-Run-Guard\scripts\Run-Tests-Guarded.ps1'
    Check 'HM-06: the guarded runner is installed beside Test-Run-Guard (Claude runtime)' (Test-Path -LiteralPath $trgRunnerClaude -PathType Leaf) $trgRunnerClaude
    $installedRunners = @(Get-ChildItem -LiteralPath $healthProj -Recurse -Filter 'Run-Tests-Guarded.ps1' -File -ErrorAction SilentlyContinue)
    Check 'HM-06: every installed guarded runner rides inside a Test-Run-Guard runtime (never the other two test hooks)' (
        $installedRunners.Count -ge 1 -and @($installedRunners | Where-Object { $_.FullName -notmatch '[\\/]Test-Run-Guard[\\/]' }).Count -eq 0) (($installedRunners | ForEach-Object { $_.FullName }) -join ' ; ')

    # Future-proof: a synthetic, unknown hook folder must be picked up by
    # Select All with NO code change - proves the set is derived dynamically
    # from Get-HookEntries, never a hard-coded count. Created/removed inside
    # its own try/finally so the real hooks\ directory is never left dirty.
    $syntheticName = 'ZZZ-Synthetic-Test-Hook'
    $syntheticDir = Join-Path $RealHooksDir $syntheticName
    # Baseline taken HERE, not at the top of the file: this assertion is about the
    # delta one fixture makes, and many wizard runs (and any sibling suite) sit
    # between the two points. Comparing against the stale opening count turns
    # someone else's throwaway hook into a failure of ours.
    $preSyntheticHookCount = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
    try {
        New-Item -ItemType Directory -Path $syntheticDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $syntheticDir ($syntheticName + '.ps1')) -Value 'exit 0' -Encoding utf8
        $newHookCount = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
        Check 'synthetic fixture increases the discovered hook count by exactly one' ($newHookCount -eq $preSyntheticHookCount + 1) ('before=' + $preSyntheticHookCount + ' after=' + $newHookCount)

        $cfgFuture = Join-Path $Work 'cfg-future.json'; New-Config $cfgFuture
        $fX = New-Proj 'SelAllFutureX'; $fY = New-Proj 'SelAllFutureY'
        $rFuture = Invoke-Wizard -Config $cfgFuture -Answers @('1', '1', '1', $fX, $fY, 'done', '1', '', '1', '1', '', '0')
        Check 'exit 0 (with synthetic hook present)' ($rFuture.Exit -eq 0) $rFuture.Err
        Check 'select-all dynamically picks up the new hook count - no hard-coded 16' ($rFuture.Out -match ('Configuring ' + $newHookCount + ' hooks:'))
        $futureFolders = @(Get-ChildItem -LiteralPath (Join-Path $fX '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        Check 'select-all includes the synthetic hook without any code change' ($futureFolders -contains $syntheticName)
    }
    finally {
        if (Test-Path -LiteralPath $syntheticDir) {
            Get-ChildItem -LiteralPath $syntheticDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $syntheticDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Check 'synthetic fixture directory was cleaned up' (-not (Test-Path -LiteralPath $syntheticDir))
    }

