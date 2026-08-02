# Test-InstalledHooksMenu.ps1 scenario block: the uninstall list/confirmation
# identity, the fixed menu numbering, and the hook-status root-folder prompt.
#
# These three themes share ONE fixture-scoped try/finally, which is why they are
# a single block: separating them would mean duplicating the fixture lifecycle.
#
# Part 1 - menu 27 (Uninstall Installed Hooks): proves the list and
# confirmation screens in Setup-SyncGroupInstalledHooks.ps1 render the FULL
# install identity that Get-InstalledHookSnapshot already collects - hook type,
# exact target path, per-client event names and the exact persisted
# sourceScript in the list; record id, settings path, runtime script and
# native-Git ownership status in the confirmation screen - and that declining
# the final confirmation mutates nothing (the record survives in the registry).
#
# Part 2 - the fixed menu numbering itself: shipped hooks occupy exactly 3..24
# (the three test-health hooks at 20/21/22, Utf8-Encoding-Check at 23, and
# Cloudflare-Deploy last at 24), 25 is Update, 26 is Get hook status, 27 is
# Uninstall, Reset sync groups, custom hooks start at 29, adding a custom hook shifts NONE of the
# three management rows, each management action must be selected alone, and
# item 1 ("Select all") expands to the sync group plus every hook while
# excluding all three management indices.
#
# Part 3 - the menu 26 prompt flow (Setup-SyncGroupHookStatus.ps1): which root
# folder inputs are accepted (quoted paths with spaces, a project root, a
# .claude\hooks\Hook-Maker direct subtree), that an invalid path re-prompts
# instead of scanning, that the global question defaults to No on a bare Enter,
# that 0 at the global question returns to the root prompt, and that cancelling
# writes nothing to the install registry.
#
# Dot-sourced by Test-InstalledHooksMenu.ps1 INTO its scope - it relies on that
# suite's harness (Check, $script:Pass/$script:Fail), helpers, fixtures and
# workspace. NOT a standalone suite: run scripts\Test-InstalledHooksMenu.ps1.

    Write-Host '--- menu 26 lists the full install identity and the confirmation screen repeats it ---' -ForegroundColor Cyan

    # ZZZ-Regtest-* throwaway fixture, no internal lower->upper case transition
    # (Get-HookFriendlyName hyphenates PascalCase boundaries; this name already
    # uses hyphens so its rendered label matches the name verbatim).
    $fxName = 'ZZZ-Menusuite-Fixture'
    $fxScript = New-FixtureHook $fxName
    try {
        $proj = New-Proj 'Menu22Proj'
        $cfg = Join-Path $Work 'cfg.json'; New-Config $cfg

        # Claude + Codex, multi-event (2 events), project-scoped.
        & $InstallScript -CustomHook $fxScript -Events @('SessionStart', 'Stop') -TargetProject $proj *> $null
        $rec = Get-RecordForScope $fxName $proj
        Check 'setup: the fixture installed a project-scoped record' ($null -ne $rec)
        Check 'setup: the record has both clients' ((@(Get-InstalledClientNames -Record $rec) | Sort-Object) -join ',' -eq 'claude,codex')

        $claudeSettings = [string]$rec.clients.claude.settingsPath
        $claudeRuntimeScript = [string]$rec.clients.claude.runtimeScript
        $codexSettings = [string]$rec.clients.codex.settingsPath
        $codexRuntimeScript = [string]$rec.clients.codex.runtimeScript

        # main menu 1 -> submenu 1 -> hook list 27 (Uninstall) -> scope menu 2
        # (every installed hook) -> select row 1 (the fixture record) -> decline
        # the confirmation -> exit the main menu.
        $r = Invoke-Wizard -Config $cfg -Answers @('1', '1', '27', '2', '1', 'n', '0') -WorkingDirectory $proj
        Check 'the wizard run exits 0' ($r.Exit -eq 0) $r.Err

        # ---- list screen: everything Get-InstalledHookSnapshot collects ----
        Check 'list: the friendly hook name appears' ($r.Out -match [regex]::Escape('ZZZ-Menusuite-Fixture')) $r.Out
        Check 'list: the hook type (CustomHook) appears' ($r.Out -match 'CustomHook') $r.Out
        Check 'list: the exact target project root appears' ($r.Out -match [regex]::Escape($proj)) $r.Out
        Check 'list: Claude''s events appear' ($r.Out -match 'Claude \[SessionStart, Stop\]') $r.Out
        Check 'list: Codex''s events appear' ($r.Out -match 'Codex \[SessionStart, Stop\]') $r.Out
        Check 'list: the exact persisted sourceScript appears' ($r.Out -match [regex]::Escape($fxScript)) $r.Out

        # ---- confirmation screen: record id, settings path, runtime script, native-git status ----
        Check 'confirm: the record id appears' ($r.Out -match [regex]::Escape($rec.id)) $r.Out
        Check 'confirm: the Claude settings path appears' ($r.Out -match [regex]::Escape($claudeSettings)) $r.Out
        Check 'confirm: the Codex settings path appears' ($r.Out -match [regex]::Escape($codexSettings)) $r.Out
        Check 'confirm: the Claude runtime script path appears' ($r.Out -match [regex]::Escape($claudeRuntimeScript)) $r.Out
        Check 'confirm: the Codex runtime script path appears' ($r.Out -match [regex]::Escape($codexRuntimeScript)) $r.Out
        Check 'confirm: native-Git ownership status appears (this install does not own it)' ($r.Out -match 'native Git:\s*no') $r.Out

        # ---- decline was honored: no mutation at all ----
        Check 'decline: the wizard reported "Canceled"' ($r.Out -match 'Canceled\. Nothing was changed\.') $r.Out
        $recAfter = Get-RecordForScope $fxName $proj
        Check 'decline: the record still exists in the registry' ($null -ne $recAfter -and [string]$recAfter.id -eq [string]$rec.id)
        Check 'decline: the Claude settings file is untouched' (Test-Path -LiteralPath $claudeSettings)
        Check 'decline: the Claude runtime script is untouched' (Test-Path -LiteralPath $claudeRuntimeScript)

        Write-Host ''
        Write-Host '--- sample rendered list block for this install ---' -ForegroundColor DarkGray
        # The fixture also appears earlier as a plain installable custom hook in
        # "Available hooks:" - the row we want is the one inside "Installed
        # hooks:", so anchor the search there rather than on the first match.
        $installedHeaderAt = $r.Out.IndexOf('Installed hooks:')
        $sampleStart = if ($installedHeaderAt -ge 0) { $r.Out.IndexOf('ZZZ-Menusuite-Fixture', $installedHeaderAt) } else { -1 }
        if ($sampleStart -ge 0) {
            $sampleEnd = $r.Out.IndexOf("`n`n", $sampleStart)
            if ($sampleEnd -lt 0) { $sampleEnd = [Math]::Min($r.Out.Length, $sampleStart + 600) }
            Write-Host $r.Out.Substring($sampleStart, $sampleEnd - $sampleStart)
        }

        # ================================================================
        # Part 2 - the fixed menu numbering
        # ================================================================
        Write-Host ''
        # Banner deliberately states the LAYOUT, not a rendering: the concrete
        # numbers depend on how many shipped hooks exist and this line had gone
        # stale against the assertions below it, which compute from the real
        # count. The assertions are the specification.
        Write-Host '--- hook list layout: shipped block, then the 3 management rows, then custom ---' -ForegroundColor Cyan

        # Render the hook list and leave without selecting anything.
        $menu = Invoke-Wizard -Config $cfg -Answers @('1', '1', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'menu: the render-only run exits 0' ($menu.Exit -eq 0) $menu.Err
        # Foreign ZZZ-* fixtures are removed before ANY count or index below is
        # taken - see Remove-ForeignFixtureRows. $foreignRowCount is what the
        # WIZARD still sees (it installs those hooks too), needed wherever an
        # assertion compares against a number the wizard itself rendered.
        $rawRows = Get-HookListRows $menu.Out
        $rows = Remove-ForeignFixtureRows $rawRows
        Check 'menu: the hook list block was rendered' ($null -ne $rows) $menu.Out
        $foreignRowCount = 0
        if ($null -ne $rawRows) { $foreignRowCount = @($rawRows.Keys).Count - @($rows.Keys).Count }

        if ($null -ne $rows) {
            $indices = @($rows.Keys)
            Check 'menu: item 1 is "Select all hooks"' ([string]$rows[1] -match '^Select all hooks') ([string]$rows[1])
            Check 'menu: item 2 is the sync group' ([string]$rows[2] -match '^Create or update a sync group') ([string]$rows[2])

            # The 22 shipped hooks occupy exactly 3..24 - no gap, and no
            # management row anywhere inside that range.
            $shippedRange = @(3..24)
            $missing = @($shippedRange | Where-Object { -not $rows.Contains($_) })
            Check 'menu: rows 3..24 all exist (the 22 shipped hooks)' ($missing.Count -eq 0) ('missing: ' + ($missing -join ','))
            $strayManagement = @($shippedRange | Where-Object { $rows.Contains($_) -and [string]$rows[$_] -match '\[manage\]' })
            Check 'menu: no management row appears inside the shipped range 3..24' ($strayManagement.Count -eq 0) ('stray: ' + ($strayManagement -join ','))

            # The three test-health hooks (24.txt) sit at 20/21/22 IN THAT
            # ORDER, then Utf8-Encoding-Check at 23 (30.md), then
            # Cloudflare-Deploy, which stays the last individual entry.
            Check 'menu: 20 is Test-Plan-Check' ([string]$rows[20] -match '^Test-Plan-Check \| \[pre-task\] \|') ([string]$rows[20])
            Check 'menu: 21 is Test-Run-Guard' ([string]$rows[21] -match '^Test-Run-Guard \| \[pre\+post-task\] \|') ([string]$rows[21])
            Check 'menu: 22 is Test-Completion-Check' ([string]$rows[22] -match '^Test-Completion-Check \| \[post-task\] \|') ([string]$rows[22])
            Check 'menu: 23 is Utf8-Encoding-Check' ([string]$rows[23] -match '^Utf8-Encoding-Check \| \[pre\+post-task\] \|') ([string]$rows[23])
            Check 'menu: 24 is Cloudflare-Deploy (still the last individual entry)' ([string]$rows[24] -match '^Cloudflare-Deploy \| \[post-task\] \|') ([string]$rows[24])

            Check 'menu: 25 is Update installed hooks' ([string]$rows[25] -match '^Update installed hooks \| \[manage\] \|') ([string]$rows[25])
            # The exact contract wording for the two rows the task pins. Row 26
            # gained '; skips dependency caches' when the scan started pruning
            # node_modules/.next/... - the row states what the scan DOES, and a
            # scan that no longer walks those trees must say so rather than let
            # the reader assume full coverage.
            Check 'menu: 26 renders EXACTLY the contract row' ([string]$rows[26] -eq 'Get hook status | [manage] | scan a path for installed hooks (skips dependency caches) and track results') ([string]$rows[26])
            Check 'menu: 27 renders EXACTLY the contract row' ([string]$rows[27] -eq 'Uninstall installed hooks | [manage] | list and remove installed hooks; never deletes hook sources') ([string]$rows[27])

            # The fixture is the only custom hook, so the custom block starts at
            # 28 - i.e. adding a custom hook did NOT shift 20-27 at all.
            Check 'menu: custom hooks start at 29' ([string]$rows[29] -match 'ZZZ-Menusuite-Fixture') ([string]$rows[29])
            Check 'menu: adding a custom hook did not shift the management rows' (([string]$rows[25] -match 'Update') -and ([string]$rows[26] -match 'Get hook status') -and ([string]$rows[27] -match 'Uninstall')) (($indices | Sort-Object) -join ',')
            Check 'menu: adding a custom hook did not shift the three new shipped rows' (([string]$rows[20] -match 'Test-Plan-Check') -and ([string]$rows[21] -match 'Test-Run-Guard') -and ([string]$rows[22] -match 'Test-Completion-Check')) (($indices | Sort-Object) -join ',')
            Check 'menu: the Tip line names all four management indices' ($menu.Out -match '25/26/27/28 are management actions') $menu.Out

            # Each newly inserted row (the three test-health hooks and
            # Utf8-Encoding-Check) must render on ONE line, within the budget
            # the existing shipped rows already respect (the longest
            # pre-existing row is the yardstick - no new row may be the one that
            # starts wrapping).
            $newRowNumbers = @(20, 21, 22, 23)
            $existingRowLengths = @(@($rows.Keys) |
                Where-Object { $_ -ge 3 -and $_ -le 24 -and $newRowNumbers -notcontains $_ } |
                ForEach-Object { ('  ' + $_ + '. ' + [string]$rows[$_]).Length })
            $rowBudget = (@($existingRowLengths | Sort-Object -Descending)[0])
            foreach ($n in $newRowNumbers) {
                $rendered = '  ' + $n + '. ' + [string]$rows[$n]
                Check ('menu: row ' + $n + ' renders on exactly one line within the existing budget (' + $rowBudget + ')') (
                    $rendered -notmatch "[`r`n]" -and $rendered.Length -le $rowBudget) ($rendered.Length.ToString() + ': ' + $rendered)
            }
        }

        Write-Host ''
        Write-Host '--- a foreign ZZZ-* fixture in the real hooks\ dir moves nothing this suite reads ---' -ForegroundColor Cyan

        # The failure this pins happened for real: a leftover hooks\ZZZ-* from
        # another suite's aborted run is a custom hook to the wizard, so it took
        # an index inside the custom block and pushed this suite's own fixture
        # down one, breaking the counts above. Create one deliberately, render
        # the SAME menu again, and require the filtered view to be identical
        # row for row.
        $probeName = 'ZZZ-Menu-Immunity-Probe'  # sorts BEFORE ZZZ-Menusuite-Fixture, so it really does shift it
        $beforeSignature = Get-RowSignature $rows
        [void](New-FixtureHook $probeName)
        try {
            $probe = Invoke-Wizard -Config $cfg -Answers @('1', '1', '0', '0', 'exit') -WorkingDirectory $proj
            Check 'immunity: the probe render run exits 0' ($probe.Exit -eq 0) $probe.Err
            $probeRaw = Get-HookListRows $probe.Out
            # The probe must actually be IN the rendered menu, otherwise the
            # equality below would prove nothing at all.
            Check 'immunity: the foreign fixture really did render as one extra row' (
                $null -ne $probeRaw -and $null -ne $rawRows -and
                @($probeRaw.Keys).Count -eq (@($rawRows.Keys).Count + 1) -and
                @(@($probeRaw.Values) | Where-Object { $_ -match [regex]::Escape($probeName) }).Count -eq 1) (Get-RowSignature $probeRaw)
            $probeRows = Remove-ForeignFixtureRows $probeRaw
            Check 'immunity: every row this suite reads is unchanged' (
                (Get-RowSignature $probeRows) -eq $beforeSignature) ((Get-RowSignature $probeRows) + "`n--- expected ---`n" + $beforeSignature)
            Check 'immunity: the hook total is unchanged' (
                (@($probeRows.Keys).Count - 6) -eq 23) ('total hooks: ' + (@($probeRows.Keys).Count - 6))
            Check 'immunity: the custom block still starts at 29 with this suite''s own fixture' (
                [string]$probeRows[29] -match 'ZZZ-Menusuite-Fixture') ([string]$probeRows[29])
            Check 'immunity: the foreign fixture is absent from the filtered view' (
                @(@($probeRows.Values) | Where-Object { $_ -match [regex]::Escape($probeName) }).Count -eq 0) (Get-RowSignature $probeRows)
        }
        finally {
            # A leaked hooks\ZZZ-* corrupts the NEXT run of this suite and of
            # Test-Wizard, so the removal is mandatory, not best-effort.
            Remove-FixtureHook $probeName
        }
        Check 'immunity: the foreign fixture was removed from the real hooks directory' (
            -not (Test-Path -LiteralPath (Join-Path $RealHooksDir $probeName))) $probeName

        Write-Host ''
        Write-Host '--- each management action must be selected alone ---' -ForegroundColor Cyan

        # Four illegal mixtures, one after another; each must be rejected and
        # re-render the menu rather than performing half of what was typed.
        $reject = Invoke-Wizard -Config $cfg -Answers @('1', '1', '3,26', '25-27', '1,27', '26,28', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'mix: the rejection run exits 0' ($reject.Exit -eq 0) $reject.Err
        $rejectionCount = ([regex]::Matches($reject.Out, [regex]::Escape('on its own - it cannot be combined'))).Count
        Check 'mix: all four illegal selections were rejected (3,26 / 25-27 / 1,27 / 26,28)' ($rejectionCount -eq 4) ('rejections seen: ' + $rejectionCount)
        Check 'mix: the rejection names all four management indices' ($reject.Out -match 'Select 25 \(update\), 26 \(status\), 27 \(uninstall\) or 28 \(reset sync groups\)') $reject.Out
        # None of the three management screens may have been entered. The
        # comparison is CASE-SENSITIVE on purpose: the phase headers ("Get Hook
        # Status") differ from the menu rows ("Get hook status") only by case,
        # and PowerShell's -notmatch is case-insensitive, so -cnotmatch is what
        # actually distinguishes "the screen opened" from "the row was listed".
        Check 'mix: no management screen was entered by an illegal mixture' (($reject.Out -cnotmatch 'Get Hook Status') -and ($reject.Out -cnotmatch 'Uninstall Installed Hooks') -and ($reject.Out -cnotmatch 'Update Previously Installed Hooks')) $reject.Out

        Write-Host ''
        Write-Host '--- item 1 expands to the sync group + every hook, never a management action ---' -ForegroundColor Cyan

        # Item 1 rebuilds the selection as: the sync group, then every shipped
        # and custom hook. The wizard announces the remaining count right before
        # it hands off to the sync-group flow, which is exactly the expansion.
        $totalHooks = 0
        if ($null -ne $rows) { $totalHooks = @($rows.Keys).Count - 6 }  # minus items 1, 2 and the 4 management rows
        $all = Invoke-Wizard -Config $cfg -Answers @('1', '1', '1', '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'select-all: the run exits 0' ($all.Exit -eq 0) $all.Err
        Check 'select-all: 22 shipped + 1 custom hook were counted from the menu' ($totalHooks -eq 23) ('total hooks: ' + $totalHooks)
        # The wizard counts what it will actually install, foreign fixtures
        # included, so the number it PRINTS is the unfiltered one.
        Check 'select-all: item 1 expanded to the sync group plus every hook' ($all.Out -match ('Running the sync group first, then installing ' + ($totalHooks + $foreignRowCount) + ' more hook\(s\)')) $all.Out
        Check 'select-all: item 1 never entered a management screen' (($all.Out -cnotmatch 'Get Hook Status') -and ($all.Out -cnotmatch 'Uninstall Installed Hooks') -and ($all.Out -cnotmatch 'Update Previously Installed Hooks')) $all.Out

        # ================================================================
        # Part 3 - the menu 25 (Get hook status) prompt flow
        # ================================================================
        Write-Host ''
        Write-Host '--- menu 25 root-folder prompt: what is accepted, and what re-prompts ---' -ForegroundColor Cyan

        $registryPath = Join-Path $IsolatedStateDir 'install-registry.json'
        $registryBefore = if (Test-Path -LiteralPath $registryPath) { [System.IO.File]::ReadAllBytes($registryPath) } else { $null }
        $registryWriteBefore = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).LastWriteTimeUtc } else { $null }

        $globalQuestion = "Also inspect the current user's global Claude, Codex and Kiro hook locations\?"

        # -- a missing path re-prompts instead of scanning -------------------
        $missingPath = Join-Path $Work 'no-such-folder-here'
        $bad = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $missingPath, '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the invalid-path run exits 0' ($bad.Exit -eq 0) $bad.Err
        Check 'status: a missing folder is rejected with the exact path' ($bad.Out -match [regex]::Escape('Folder not found: ' + $missingPath)) $bad.Out
        Check 'status: the root prompt was shown again after the rejection' (([regex]::Matches($bad.Out, 'Root folder to scan')).Count -ge 2) $bad.Out
        Check 'status: an invalid path never reached the global question' ($bad.Out -notmatch $globalQuestion) $bad.Out
        Check 'status: an invalid path never started a scan' ($bad.Out -notmatch 'Roots to scan:') $bad.Out

        # -- a quoted path containing spaces is accepted ---------------------
        $spaceDir = New-Proj 'Status Root With Spaces'
        $quoted = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', ('"' + $spaceDir + '"'), '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the quoted-path run exits 0' ($quoted.Exit -eq 0) $quoted.Err
        Check 'status: a quoted path containing spaces is accepted' ($quoted.Out -match $globalQuestion) $quoted.Out
        # 0 at the global question goes BACK to the root prompt: that is the
        # second render of the root prompt in this run, and nothing was scanned.
        Check 'status: 0 at the global question returns to the root prompt' (([regex]::Matches($quoted.Out, 'Root folder to scan')).Count -eq 2) $quoted.Out
        Check 'status: cancelling never started a scan' ($quoted.Out -notmatch 'Roots to scan:') $quoted.Out

        # -- a plain project root is accepted --------------------------------
        $projRoot = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $proj, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the project-root run exits 0' ($projRoot.Exit -eq 0) $projRoot.Err
        Check 'status: a project root is accepted' ($projRoot.Out -match $globalQuestion) $projRoot.Out

        # -- a .claude\hooks\Hook-Maker direct subtree is accepted ------------
        # The scan must not demand the exact project root: pointing it at a
        # directory well inside the project has to work too.
        $subtree = Join-Path $proj '.claude\hooks\Hook-Maker'
        New-Item -ItemType Directory -Path $subtree -Force | Out-Null
        $sub = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $subtree, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the .claude\hooks\Hook-Maker run exits 0' ($sub.Exit -eq 0) $sub.Err
        Check 'status: a .claude\hooks\Hook-Maker direct subtree is accepted' ($sub.Out -match $globalQuestion) $sub.Out

        # -- cancelling wrote nothing to the registry -------------------------
        # Asserted here, while every run above cancelled before the scan. The
        # default-No scenario below deliberately runs LAST, because it is the
        # only one that proceeds far enough to hand off to the scanner.
        $registryAfter = if (Test-Path -LiteralPath $registryPath) { [System.IO.File]::ReadAllBytes($registryPath) } else { $null }
        $registryWriteAfter = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).LastWriteTimeUtc } else { $null }
        $sameBytes = ($null -eq $registryBefore -and $null -eq $registryAfter) -or
                     ($null -ne $registryBefore -and $null -ne $registryAfter -and
                      [Convert]::ToBase64String($registryBefore) -eq [Convert]::ToBase64String($registryAfter))
        Check 'status: cancelling the scan left the install registry byte-identical' $sameBytes
        Check 'status: cancelling the scan did not rewrite the install registry file' ($registryWriteBefore -eq $registryWriteAfter) ([string]$registryWriteBefore + ' -> ' + [string]$registryWriteAfter)

        # -- the global question defaults to No on a bare Enter ---------------
        # Enter answers No, so the roots screen must say the global locations
        # are excluded and must list only the chosen root.
        $defaultNo = Invoke-Wizard -Config $cfg -Answers @('1', '1', '26', $proj, '', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the default-No run exits 0' ($defaultNo.Exit -eq 0) $defaultNo.Err
        Check 'status: Enter at the global question means No' ($defaultNo.Out -match [regex]::Escape('Global Claude/Codex/Kiro locations are NOT included in this scan.')) $defaultNo.Out
        Check 'status: the canonical root is shown before the scan starts' ($defaultNo.Out -match [regex]::Escape($proj)) $defaultNo.Out
        Check 'status: the roots screen states reparse points are not followed' ($defaultNo.Out -match 'Reparse points .* are not followed') $defaultNo.Out
    }
    finally {
        Remove-FixtureHook $fxName
    }
