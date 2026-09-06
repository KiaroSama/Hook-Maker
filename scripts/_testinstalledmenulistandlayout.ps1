# Test-InstalledHooksMenu.ps1 scenario block: the uninstall list/confirmation
# identity, the fixed menu numbering, and the hook-status root-folder prompt.
#
# These three themes share ONE fixture-scoped try/finally, which is why they are
# a single block: separating them would mean duplicating the fixture lifecycle.
#
# Part 1 - the Uninstall Installed Hooks row (its index is read off the live
# render, never pinned - see Get-RenderedIndex below): proves the list and
# confirmation screens in Setup-SyncGroupInstalledHooks.ps1 render the FULL
# install identity that Get-InstalledHookSnapshot already collects - hook type,
# exact target path, per-client event names and the exact persisted
# sourceScript in the list; record id, settings path, runtime script and
# native-Git ownership status in the confirmation screen - and that declining
# the final confirmation mutates nothing (the record survives in the registry).
#
# Part 2 - the fixed menu layout itself: item 1 is "Select all", item 2 the
# sync group, then the shipped hooks contiguously, then the five management
# rows, then the custom hooks. On the current hook set that renders as shipped
# 3..29 (the three test-health hooks at 23/24/25, Utf8-Encoding-Check at 26,
# Synapse-Rules-Check at 27, Session-Summary-Check at 28 and Cloudflare-Deploy
# last at 29), then 30 Update, 31 Get hook status, 32 Uninstall, 33 Reset sync
# groups, 34 Fix a renamed/moved project, and the custom hooks from 35. Those
# row numbers stay PINNED in the assertions on purpose - they are the order
# contract, and deriving them there would leave nothing protecting it. Every
# number this block TYPES at the wizard is read off the live render instead:
# hand-renumbering the scripted answers is what let this file drift twice.
# Also proves that adding a custom hook shifts NONE of the management rows,
# that each management action must be selected alone, and that item 1
# ("Select all") expands to the sync group plus every hook while excluding
# all five management indices.
#
# Part 3 - the Get hook status prompt flow (Setup-SyncGroupHookStatus.ps1),
# entered by the derived row index: which root
# folder inputs are accepted (quoted paths with spaces, a project root, a
# .claude\hooks\Hook-Maker direct subtree), that an invalid path re-prompts
# instead of scanning, that the global question defaults to No on a bare Enter,
# that 0 at the global question returns to the root prompt, and that cancelling
# writes nothing to the install registry.
#
# Dot-sourced by Test-InstalledHooksMenu.ps1 INTO its scope - it relies on that
# suite's harness (Check, $script:Pass/$script:Fail), helpers, fixtures and
# workspace. NOT a standalone suite: run scripts\Test-InstalledHooksMenu.ps1.

    Write-Host '--- the uninstall row lists the full install identity and the confirmation screen repeats it ---' -ForegroundColor Cyan

    # ZZZ-Regtest-* throwaway fixture, no internal lower->upper case transition
    # (Get-HookFriendlyName hyphenates PascalCase boundaries; this name already
    # uses hyphens so its rendered label matches the name verbatim).
    $fxName = 'ZZZ-Menusuite-Fixture'
    $fxScript = New-FixtureHook $fxName
    try {
        $proj = New-Proj 'Menu22Proj'
        $cfg = Join-Path $Work 'cfg.json'; New-Config $cfg

        # ---- one render, up front: every number typed below comes from it ----
        # The hook list is built from the hooks\ directory, so it renders the
        # same before and after the fixture is installed - rendering here lets
        # Part 1 type a DERIVED row index instead of a hand-maintained literal,
        # and lets Part 2 reuse this capture instead of spawning a second
        # wizard. Renders the hook list and leaves without selecting anything.
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

        # The one index a row is allowed to have, or -1 when the row is missing
        # or ambiguous - which the assertion just below turns into a loud
        # failure instead of a nonsense answer typed at the wizard.
        function Get-RenderedIndex {
            param($Rows, [string]$Pattern)
            if ($null -eq $Rows) { return -1 }
            $hit = @(@($Rows.Keys) | Sort-Object | Where-Object { [string]$Rows[$_] -match $Pattern })
            if ($hit.Count -ne 1) { return -1 }
            return [int]$hit[0]
        }
        # Read off $rawRows, not the filtered view: what is TYPED has to match
        # what the wizard rendered. (The two agree for these rows anyway - a
        # foreign fixture lands in the custom block, after all five of them.)
        $updateIndex = Get-RenderedIndex $rawRows '^Update installed hooks \| \[manage\]'
        $statusIndex = Get-RenderedIndex $rawRows '^Get hook status \| \[manage\]'
        $uninstallIndex = Get-RenderedIndex $rawRows '^Uninstall installed hooks \| \[manage\]'
        $resetIndex = Get-RenderedIndex $rawRows '^Reset sync groups \| \[manage\]'
        $relocateIndex = Get-RenderedIndex $rawRows '^Fix a renamed or moved project \| \[manage\]'
        # The custom block is read off the FILTERED view, because that is the
        # view the immunity assertions compare against.
        $customStartIndex = Get-RenderedIndex $rows ('^' + [regex]::Escape($fxName))
        $derived = @{ update = $updateIndex; status = $statusIndex; uninstall = $uninstallIndex
            reset = $resetIndex; relocate = $relocateIndex; customStart = $customStartIndex }
        Check 'menu: each management row and the custom block resolve to exactly one index' (
            @(@($derived.Keys) | Where-Object { $derived[$_] -lt 1 }).Count -eq 0) (
            (@($derived.Keys) | Sort-Object | ForEach-Object { $_ + '=' + $derived[$_] }) -join ' ')

        # Claude + Codex, multi-event (2 events), project-scoped.
        & $InstallScript -CustomHook $fxScript -Events @('SessionStart', 'Stop') -TargetProject $proj *> $null
        $rec = Get-RecordForScope $fxName $proj
        Check 'setup: the fixture installed a project-scoped record' ($null -ne $rec)
        Check 'setup: the record has both clients' ((@(Get-InstalledClientNames -Record $rec) | Sort-Object) -join ',' -eq 'claude,codex')

        $claudeSettings = [string]$rec.clients.claude.settingsPath
        $claudeRuntimeScript = [string]$rec.clients.claude.runtimeScript
        $codexSettings = [string]$rec.clients.codex.settingsPath
        $codexRuntimeScript = [string]$rec.clients.codex.runtimeScript

        # main menu 1 -> submenu 1 -> the Uninstall row (index derived above) ->
        # scope menu 2 (every installed hook) -> select row 1 (the fixture
        # record) -> decline the confirmation -> exit the main menu.
        $r = Invoke-Wizard -Config $cfg -Answers @('1', '1', [string]$uninstallIndex, '2', '1', 'n', '0') -WorkingDirectory $proj
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
        # numbers move whenever a hook ships, and this line had gone stale
        # against the assertions below it twice. The assertions are the
        # specification; this line only says what shape they check.
        Write-Host '--- hook list layout: shipped block, then the 5 management rows, then custom ---' -ForegroundColor Cyan

        # $menu / $rawRows / $rows were captured before the install above; the
        # hook list does not depend on what is installed, so this is the same
        # render, asserted here rather than re-spawned.

        if ($null -ne $rows) {
            $indices = @($rows.Keys)
            Check 'menu: item 1 is "Select all hooks"' ([string]$rows[1] -match '^Select all hooks') ([string]$rows[1])
            Check 'menu: item 2 is the sync group' ([string]$rows[2] -match '^Create or update a sync group') ([string]$rows[2])

            # The shipped hooks occupy 3 .. (first management row - 1) with no
            # gap and no management row anywhere inside. The end of the range
            # is derived so a new hook does not make this assertion lie; the
            # per-row identity checks below stay pinned and carry the order.
            $shippedRange = @(3..($updateIndex - 1))
            $missing = @($shippedRange | Where-Object { -not $rows.Contains($_) })
            Check ('menu: rows 3..' + ($updateIndex - 1) + ' all exist (the ' + ($updateIndex - 3) + ' shipped hooks)') ($missing.Count -eq 0) ('missing: ' + ($missing -join ','))
            $strayManagement = @($shippedRange | Where-Object { $rows.Contains($_) -and [string]$rows[$_] -match '\[manage\]' })
            Check ('menu: no management row appears inside the shipped range 3..' + ($updateIndex - 1)) ($strayManagement.Count -eq 0) ('stray: ' + ($strayManagement -join ','))

            # The order contract, PINNED: the three test-health hooks (24.txt)
            # sit at 23/24/25 IN THAT ORDER, then Utf8-Encoding-Check at 26
            # (30.md), then Synapse-Rules-Check, Session-Summary-Check and
            # Cloudflare-Deploy, which stays the last individual entry. These
            # numbers are literal on purpose - derive them and nothing is left
            # protecting the order.
            Check 'menu: 23 is Test-Plan-Check' ([string]$rows[23] -match '^Test-Plan-Check \| \[pre-task\] \|') ([string]$rows[23])
            Check 'menu: 24 is Test-Run-Guard' ([string]$rows[24] -match '^Test-Run-Guard \| \[pre\+post-task\] \|') ([string]$rows[24])
            Check 'menu: 25 is Test-Completion-Check' ([string]$rows[25] -match '^Test-Completion-Check \| \[post-task\] \|') ([string]$rows[25])
            Check 'menu: 26 is Utf8-Encoding-Check' ([string]$rows[26] -match '^Utf8-Encoding-Check \| \[pre\+post-task\] \|') ([string]$rows[26])
            Check 'menu: 27 is Synapse-Rules-Check (directly before Cloudflare-Deploy)' ([string]$rows[27] -match '^Synapse-Rules-Check \| \[pre\+post-task\] \|') ([string]$rows[27])
            Check 'menu: 28 is Session-Summary-Check (directly before Cloudflare-Deploy)' ([string]$rows[28] -match '^Session-Summary-Check \| \[post-task\] \|') ([string]$rows[28])
            Check 'menu: 29 is Cloudflare-Deploy (still the last individual entry)' ([string]$rows[29] -match '^Cloudflare-Deploy \| \[post-task\] \|') ([string]$rows[29])

            Check 'menu: 30 is Update installed hooks' ([string]$rows[30] -match '^Update installed hooks \| \[manage\] \|') ([string]$rows[30])
            # The exact contract wording for the two rows the task pins. The
            # status row gained '; skips dependency caches' when it started pruning
            # node_modules/.next/... - the row states what the scan DOES, and a
            # scan that no longer walks those trees must say so rather than let
            # the reader assume full coverage.
            Check 'menu: 31 renders EXACTLY the contract row' ([string]$rows[31] -eq 'Get hook status | [manage] | scan a path for installed hooks (skips dependency caches) and track results') ([string]$rows[31])
            Check 'menu: 32 renders EXACTLY the contract row' ([string]$rows[32] -eq 'Uninstall installed hooks | [manage] | list and remove installed hooks; never deletes hook sources') ([string]$rows[32])

            # The fixture is the only custom hook, so the custom block starts at
            # 35 - i.e. adding a custom hook did NOT shift 3-34 at all.
            Check 'menu: custom hooks start at 35' ([string]$rows[35] -match 'ZZZ-Menusuite-Fixture') ([string]$rows[35])
            Check 'menu: adding a custom hook did not shift the management rows' (([string]$rows[30] -match 'Update') -and ([string]$rows[31] -match 'Get hook status') -and ([string]$rows[32] -match 'Uninstall')) (($indices | Sort-Object) -join ',')
            Check 'menu: adding a custom hook did not shift the three new shipped rows' (([string]$rows[23] -match 'Test-Plan-Check') -and ([string]$rows[24] -match 'Test-Run-Guard') -and ([string]$rows[25] -match 'Test-Completion-Check')) (($indices | Sort-Object) -join ',')
            # The Tip line is what tells a user which numbers are actions, so it
            # has to agree with the rows actually rendered above it - compare it
            # against those rows rather than against a second hand-kept literal.
            Check 'menu: the Tip line names all five management indices' ($menu.Out -match ([string]$updateIndex + '/' + $statusIndex + '/' + $uninstallIndex + '/' + $resetIndex + '/' + $relocateIndex + ' are management actions')) $menu.Out

            # Every row added since the budget was introduced - the three
            # test-health hooks, Utf8-Encoding-Check, Synapse-Rules-Check and
            # Session-Summary-Check, all of whose descriptions were deliberately
            # kept short - must render on ONE line, within the budget the older
            # shipped rows already respect (the longest pre-existing row is the
            # yardstick - no new row may be the one that starts wrapping).
            # Located BY NAME: pinning their numbers here is what went stale.
            $newRowNames = @('Test-Plan-Check', 'Test-Run-Guard', 'Test-Completion-Check',
                'Utf8-Encoding-Check', 'Synapse-Rules-Check', 'Session-Summary-Check')
            $newRowNumbers = @($newRowNames | ForEach-Object { Get-RenderedIndex $rows ('^' + [regex]::Escape($_) + ' \|') })
            Check 'menu: every short-by-design row was located by name' (
                @($newRowNumbers | Where-Object { $_ -lt 1 }).Count -eq 0) (($newRowNames -join ',') + ' -> ' + ($newRowNumbers -join ','))
            $existingRowLengths = @(@($rows.Keys) |
                Where-Object { $_ -ge 3 -and $_ -le ($updateIndex - 1) -and $newRowNumbers -notcontains $_ } |
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
            # "Unchanged" means against the render taken before the probe, not
            # against a literal that has to be edited every time a hook ships.
            Check 'immunity: the hook total is unchanged' (
                (@($probeRows.Keys).Count - 7) -eq (@($rows.Keys).Count - 7)) ('total hooks: ' + (@($probeRows.Keys).Count - 7) + ' vs ' + (@($rows.Keys).Count - 7))
            Check ('immunity: the custom block still starts at ' + $customStartIndex + ' with this suite''s own fixture') (
                [string]$probeRows[$customStartIndex] -match 'ZZZ-Menusuite-Fixture') ([string]$probeRows[$customStartIndex])
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
        # Each covers a different SHAPE of the rule "a management row is an
        # action, never part of a selection", and each is built from the derived
        # indices so it stays illegal instead of quietly turning into a legal
        # hook-only pick the next time a hook ships:
        #   a hook + a management row      | a range running off the end of the
        #   shipped block into two of them | "select all" + a management row |
        #   two management rows together.
        $illegal = @(
            ('3,' + $updateIndex),
            ([string]($updateIndex - 1) + '-' + $statusIndex),
            ('1,' + $statusIndex),
            ([string]$updateIndex + ',' + $uninstallIndex))
        $reject = Invoke-Wizard -Config $cfg -Answers (@('1', '1') + $illegal + @('0', '0', 'exit')) -WorkingDirectory $proj
        Check 'mix: the rejection run exits 0' ($reject.Exit -eq 0) $reject.Err
        $rejectionCount = ([regex]::Matches($reject.Out, [regex]::Escape('on its own - it cannot be combined'))).Count
        Check ('mix: all four illegal selections were rejected (' + ($illegal -join ' / ') + ')') ($rejectionCount -eq 4) ('rejections seen: ' + $rejectionCount)
        Check 'mix: the rejection names all five management indices' ($reject.Out -match ('Select ' + $updateIndex + ' \(update\), ' + $statusIndex + ' \(status\), ' + $uninstallIndex + ' \(uninstall\), ' + $resetIndex + ' \(reset sync groups\) or ' + $relocateIndex + ' \(fix a renamed project\)')) $reject.Out
        # None of the management screens may have been entered. The
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
        if ($null -ne $rows) { $totalHooks = @($rows.Keys).Count - 7 }  # minus items 1, 2 and the 5 management rows
        $all = Invoke-Wizard -Config $cfg -Answers @('1', '1', '1', '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'select-all: the run exits 0' ($all.Exit -eq 0) $all.Err
        # Cross-checked against the real hooks\ directory rather than a literal:
        # every hook folder except the sync engine (which is menu item 2, not a
        # hook) and every ZZZ-* fixture, plus this suite's own fixture as the
        # one custom hook. A shipped hook that never reached the menu, or a menu
        # row with no hook behind it, fails here.
        $shippedOnDisk = @(Get-ChildItem -LiteralPath $RealHooksDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' -and $_.Name -notlike 'ZZZ-*' }).Count
        Check ('select-all: every shipped hook on disk (' + $shippedOnDisk + ') + this suite''s 1 custom hook were counted from the menu') ($totalHooks -eq ($shippedOnDisk + 1)) ('total hooks: ' + $totalHooks)
        # The wizard counts what it will actually install, foreign fixtures
        # included, so the number it PRINTS is the unfiltered one.
        Check 'select-all: item 1 expanded to the sync group plus every hook' ($all.Out -match ('Running the sync group first, then installing ' + ($totalHooks + $foreignRowCount) + ' more hook\(s\)')) $all.Out
        Check 'select-all: item 1 never entered a management screen' (($all.Out -cnotmatch 'Get Hook Status') -and ($all.Out -cnotmatch 'Uninstall Installed Hooks') -and ($all.Out -cnotmatch 'Update Previously Installed Hooks')) $all.Out

        # ================================================================
        # Part 3 - the Get hook status prompt flow, entered by $statusIndex
        # ================================================================
        Write-Host ''
        Write-Host '--- Get hook status root-folder prompt: what is accepted, and what re-prompts ---' -ForegroundColor Cyan

        # The registry is a directory of per-record files: its "bytes" are the
        # concatenation of every record, and its "last write" the newest of them.
        $registryPath = Get-InstallRegistryDirectory -ToolRoot $ToolRoot
        $registryBefore = Get-InstallRegistryRawText -ToolRoot $ToolRoot
        $registryWriteBefore = $null
        if (Test-Path -LiteralPath $registryPath -PathType Container) {
            $registryWriteBefore = @(Get-InstallRecordFiles -ToolRoot $ToolRoot |
                Sort-Object -Property LastWriteTimeUtc -Descending |
                ForEach-Object { $_.LastWriteTimeUtc })[0]
        }

        $globalQuestion = "Also inspect the current user's global Claude, Codex and Kiro hook locations\?"

        # -- a missing path re-prompts instead of scanning -------------------
        $missingPath = Join-Path $Work 'no-such-folder-here'
        $bad = Invoke-Wizard -Config $cfg -Answers @('1', '1', [string]$statusIndex, $missingPath, '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the invalid-path run exits 0' ($bad.Exit -eq 0) $bad.Err
        Check 'status: a missing folder is rejected with the exact path' ($bad.Out -match [regex]::Escape('Folder not found: ' + $missingPath)) $bad.Out
        Check 'status: the root prompt was shown again after the rejection' (([regex]::Matches($bad.Out, 'Root folder to scan')).Count -ge 2) $bad.Out
        Check 'status: an invalid path never reached the global question' ($bad.Out -notmatch $globalQuestion) $bad.Out
        Check 'status: an invalid path never started a scan' ($bad.Out -notmatch 'Roots to scan:') $bad.Out

        # -- a quoted path containing spaces is accepted ---------------------
        $spaceDir = New-Proj 'Status Root With Spaces'
        $quoted = Invoke-Wizard -Config $cfg -Answers @('1', '1', [string]$statusIndex, ('"' + $spaceDir + '"'), '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the quoted-path run exits 0' ($quoted.Exit -eq 0) $quoted.Err
        Check 'status: a quoted path containing spaces is accepted' ($quoted.Out -match $globalQuestion) $quoted.Out
        # 0 at the global question goes BACK to the root prompt: that is the
        # second render of the root prompt in this run, and nothing was scanned.
        Check 'status: 0 at the global question returns to the root prompt' (([regex]::Matches($quoted.Out, 'Root folder to scan')).Count -eq 2) $quoted.Out
        Check 'status: cancelling never started a scan' ($quoted.Out -notmatch 'Roots to scan:') $quoted.Out

        # -- a plain project root is accepted --------------------------------
        $projRoot = Invoke-Wizard -Config $cfg -Answers @('1', '1', [string]$statusIndex, $proj, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the project-root run exits 0' ($projRoot.Exit -eq 0) $projRoot.Err
        Check 'status: a project root is accepted' ($projRoot.Out -match $globalQuestion) $projRoot.Out

        # -- a .claude\hooks\Hook-Maker direct subtree is accepted ------------
        # The scan must not demand the exact project root: pointing it at a
        # directory well inside the project has to work too.
        $subtree = Join-Path $proj '.claude\hooks\Hook-Maker'
        New-Item -ItemType Directory -Path $subtree -Force | Out-Null
        $sub = Invoke-Wizard -Config $cfg -Answers @('1', '1', [string]$statusIndex, $subtree, '0', '0', '0', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the .claude\hooks\Hook-Maker run exits 0' ($sub.Exit -eq 0) $sub.Err
        Check 'status: a .claude\hooks\Hook-Maker direct subtree is accepted' ($sub.Out -match $globalQuestion) $sub.Out

        # -- cancelling wrote nothing to the registry -------------------------
        # Asserted here, while every run above cancelled before the scan. The
        # default-No scenario below deliberately runs LAST, because it is the
        # only one that proceeds far enough to hand off to the scanner.
        $registryAfter = Get-InstallRegistryRawText -ToolRoot $ToolRoot
        $registryWriteAfter = $null
        if (Test-Path -LiteralPath $registryPath -PathType Container) {
            $registryWriteAfter = @(Get-InstallRecordFiles -ToolRoot $ToolRoot |
                Sort-Object -Property LastWriteTimeUtc -Descending |
                ForEach-Object { $_.LastWriteTimeUtc })[0]
        }
        $sameBytes = [string]::Equals($registryBefore, $registryAfter, [System.StringComparison]::Ordinal)
        Check 'status: cancelling the scan left the install registry byte-identical' $sameBytes
        Check 'status: cancelling the scan did not rewrite the install registry file' ($registryWriteBefore -eq $registryWriteAfter) ([string]$registryWriteBefore + ' -> ' + [string]$registryWriteAfter)

        # -- the global question defaults to No on a bare Enter ---------------
        # Enter answers No, so the roots screen must say the global locations
        # are excluded and must list only the chosen root.
        $defaultNo = Invoke-Wizard -Config $cfg -Answers @('1', '1', [string]$statusIndex, $proj, '', '0', 'exit') -WorkingDirectory $proj
        Check 'status: the default-No run exits 0' ($defaultNo.Exit -eq 0) $defaultNo.Err
        Check 'status: Enter at the global question means No' ($defaultNo.Out -match [regex]::Escape('Global Claude/Codex/Kiro locations are NOT included in this scan.')) $defaultNo.Out
        Check 'status: the canonical root is shown before the scan starts' ($defaultNo.Out -match [regex]::Escape($proj)) $defaultNo.Out
        Check 'status: the roots screen states reparse points are not followed' ($defaultNo.Out -match 'Reparse points .* are not followed') $defaultNo.Out
    }
    finally {
        Remove-FixtureHook $fxName
    }
