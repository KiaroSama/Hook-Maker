# Test-Wizard.ps1 scenario block: PROMPT ROBUSTNESS - an unwritable project
# .ai directory reported without crashing (with rollback of an earlier
# project's just-created directory and a pre-existing one left untouched),
# hierarchical <parent>-<slot> prompt numbering across invalid/duplicate/
# overlapping/undo answers, back navigation from a child slot, sync-group
# and hook selections sharing their paths, and a malformed profile route
# that must not crash Show-Profiles under StrictMode.
#
# Dot-sourced by Test-Wizard.ps1 into the caller's scope (uses its harness,
# helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- an unwritable project .ai directory must not crash the wizard ---' -ForegroundColor Cyan
    # Real regression: a project whose .ai directory cannot be created
    # (permission denied / read-only location) raised a terminating
    # UnauthorizedAccessException that propagated out of Invoke-CreateGroup ->
    # Invoke-InstallExistingHook -> the main menu -> run.ps1, killing the whole
    # wizard and ejecting the user. It must instead report the failure, change
    # nothing, and return to the hook list. The denial is created with a real
    # ACL (icacls "add subdirectory" deny), matching the reported failure.
    $cfgAcl = Join-Path $Work 'cfg-acl.json'; New-Config $cfgAcl
    $aclOk = New-Proj 'AclOkProj'
    $aclBlocked = New-Proj 'AclBlockedProj'
    # A third project whose .ai already existed BEFORE this run (with real
    # content) - it must survive untouched regardless of the later failure.
    $aclPreExisting = New-Proj 'AclPreExistingProj'
    $aclPreExistingAi = Join-Path $aclPreExisting '.ai'
    New-Item -ItemType Directory -Path $aclPreExistingAi -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $aclPreExistingAi 'memory.md'), 'pre-existing content', (New-Object System.Text.UTF8Encoding $false))
    $aclUser = $env:USERNAME
    $aclApplied = $false
    try {
        & icacls $aclBlocked /deny "${aclUser}:(AD)" *> $null
        $aclApplied = ($LASTEXITCODE -eq 0)
        if ($aclApplied) {
            # Confirm the denial actually reproduces the reported exception.
            $aclRepro = $false
            try { New-Item -ItemType Directory -Path (Join-Path $aclBlocked '.ai') -Force -ErrorAction Stop | Out-Null }
            catch { $aclRepro = ($_.Exception -is [System.UnauthorizedAccessException]) }
            Check 'ACL fixture reproduces the reported UnauthorizedAccessException' $aclRepro

            # Order matters: aclOk (succeeds first), aclPreExisting (already
            # has .ai, untouched), aclBlocked (fails last) - proves a LATER
            # project's failure rolls back an EARLIER project's already-
            # created empty .ai directory from the SAME run.
            $rAcl = Invoke-Wizard -Config $cfgAcl -Answers @('1', '1', '2', $aclOk, $aclPreExisting, $aclBlocked, 'done', '1', '', '0', 'exit')
            Check 'an unwritable .ai directory does NOT crash the wizard (exit 0, no fatal)' ($rAcl.Exit -eq 0 -and $rAcl.Err -notmatch 'UnauthorizedAccessException') ($rAcl.Err)
            Check 'the failing project path is reported' ($rAcl.Out -match 'Could not create 1 knowledge' -and $rAcl.Out -match 'AclBlockedProj') $rAcl.Out
            Check 'it states nothing was changed' ($rAcl.Out -match 'Nothing was changed') $rAcl.Out
            Check 'the wizard returns to the hook list instead of exiting' ((([regex]::Matches($rAcl.Out, 'Available hooks')).Count) -ge 2) $rAcl.Out
            $profAcl = @((Get-Content $cfgAcl -Raw | ConvertFrom-Json).profiles)
            Check 'no sync profile is written when a .ai directory could not be created' ($profAcl.Count -eq 0)
            # Regression: a LATER project's failure must not leave an EARLIER
            # project's just-created empty .ai directory behind while the
            # wizard claims "nothing was changed".
            Check 'an earlier project''s just-created .ai directory is rolled back (not left behind)' (-not (Test-Path -LiteralPath (Join-Path $aclOk '.ai')))
            # A pre-existing .ai directory (present before this run) must never
            # be touched, rolled back, or have its content altered.
            Check 'a pre-existing .ai directory is never touched by the rollback' ((Test-Path -LiteralPath $aclPreExistingAi -PathType Container) -and (Test-Path -LiteralPath (Join-Path $aclPreExistingAi 'memory.md')))
            Check 'a pre-existing .ai directory''s content is unmodified' ([System.IO.File]::ReadAllText((Join-Path $aclPreExistingAi 'memory.md')) -eq 'pre-existing content')
        }
        else {
            Write-Host '[SKIP] icacls deny could not be applied; skipping the unwritable-.ai regression' -ForegroundColor Yellow
        }
    }
    finally {
        if ($aclApplied) { & icacls $aclBlocked /remove:d "$aclUser" *> $null }
    }

    # =====================================================================
    Write-Host '--- repeated project prompts + confirmation back navigation ---' -ForegroundColor Cyan
    $cfgBack = Join-Path $Work 'cfg-back.json'; New-Config $cfgBack
    $backA = New-Proj 'BackA'; $backB = New-Proj 'BackB'
    # Configure two hooks with shared targets, back from confirmation, then
    # enter done immediately: existing targets must still be present.
    $rBack = Invoke-Wizard -Config $cfgBack -Answers @('1', '1', '3,4', '1', '1', $backA, $backB, 'done', '0', 'done', 'exit')
    # Repeated child prompts inside ONE parent question use hierarchical
    # "<parent>-<slot>" numbering (e.g. "12-1.", "12-2.") - they must NOT each
    # steal a fresh top-level integer (the confirmed bug this replaces).
    $nestedPromptMatches = @([regex]::Matches($rBack.Out, '(?m)^(\d+)-(\d+)\. Project root path'))
    Check 'repeated project prompts use hierarchical <parent>-<slot> numbering, not fresh top-level integers' (
        $nestedPromptMatches.Count -ge 2 -and
        $nestedPromptMatches[0].Groups[1].Value -eq $nestedPromptMatches[1].Groups[1].Value -and
        $nestedPromptMatches[0].Groups[2].Value -eq '1' -and $nestedPromptMatches[1].Groups[2].Value -eq '2')
    Check 'no repeated project prompt appears as a bare top-level integer' (-not ($rBack.Out -match '(?m)^\d+\. Project root path'))
    Check 'confirmation back returns to project entry instead of the hook list' (([regex]::Matches($rBack.Out, 'Add Projects')).Count -eq 2 -and ([regex]::Matches($rBack.Out, 'Available hooks')).Count -eq 1)
    Check 'confirmation back preserves the existing project list' (([regex]::Matches($rBack.Out, 'projects: BackA, BackB')).Count -eq 4)

    # =====================================================================
    Write-Host '--- hierarchical numbering: invalid/duplicate/overlap/undo retain the correct slot ---' -ForegroundColor Cyan
    $cfgSlots = Join-Path $Work 'cfg-slots.json'; New-Config $cfgSlots
    $slotA = New-Proj 'Slot A With Spaces'
    $slotB = New-Proj 'SlotB'
    $missingPath = Join-Path $Work 'does-not-exist-anywhere'
    $overlapChild = Join-Path $slotA 'nested'
    New-Item -ItemType Directory -Path $overlapChild -Force | Out-Null
    $rSlots = Invoke-Wizard -Config $cfgSlots -Answers @(
        '1', '1', '3', '1', '1',
        $slotA,             # slot 1 accepted
        $missingPath,       # invalid (missing dir) -> re-shows slot 2
        $slotA,              # duplicate -> re-shows slot 2
        $overlapChild,       # overlaps slotA -> re-shows slot 2
        $slotB,             # slot 2 accepted
        'undo',             # removes slotB -> back to slot 2
        $slotB,             # slot 2 accepted again
        'done', 'y', 'exit'
    )
    $slotMatches = @([regex]::Matches($rSlots.Out, '(?m)^(\d+)-(\d+)\. Project root path'))
    $slotNumbers = @($slotMatches | ForEach-Object { [int]$_.Groups[2].Value })
    Check 'invalid/duplicate/overlap all re-display the SAME child slot (2) instead of advancing' (
        $slotNumbers.Count -ge 6 -and
        $slotNumbers[0] -eq 1 -and $slotNumbers[1] -eq 2 -and $slotNumbers[2] -eq 2 -and $slotNumbers[3] -eq 2 -and $slotNumbers[4] -eq 2)
    # slotNumbers[5] is "3" - the prompt shown BEFORE the 'undo' answer is read
    # (childNumber had already advanced past the just-accepted slotB). The
    # prompt shown AFTER undo processes (slotNumbers[6]) is what proves the
    # slot stepped back to 2 instead of continuing at 3.
    Check 'undo steps the slot counter back (re-shows slot 2, not 3)' ($slotNumbers.Count -ge 7 -and $slotNumbers[6] -eq 2) ($slotNumbers -join ',')
    Check 'a project path containing spaces is accepted' ($rSlots.Out -match [regex]::Escape('Slot A With Spaces'))
    Check 'the missing directory is rejected without being added' ($rSlots.Out -match 'Directory not found')
    Check 'the duplicate path is rejected without being added' ($rSlots.Out -match 'Already added')
    Check 'the overlapping nested path is rejected without being added' ($rSlots.Out -match 'Path overlaps an already added project')

    # =====================================================================
    Write-Host '--- hierarchical numbering: back=0 and subsequent top-level numbering stay correct ---' -ForegroundColor Cyan
    $cfgAfter = Join-Path $Work 'cfg-after-nested.json'; New-Config $cfgAfter
    $afterA = New-Proj 'AfterA'; $afterB = New-Proj 'AfterB'
    $rAfter = Invoke-Wizard -Config $cfgAfter -Answers @('1', '1', '3', '1', '1', '0', '1', $afterA, $afterB, 'done', 'y', 'exit')
    Check 'back=0 from the first child slot returns to the correct parent stage (client select)' (([regex]::Matches($rAfter.Out, 'Select the client')).Count -eq 2)
    $afterConfirmMatches = @([regex]::Matches($rAfter.Out, '(?m)^(\d+)\. Start now\?'))
    Check 'genuine top-level numbering after the nested collection is unaffected (still a plain integer, not <n>-<n>)' ($afterConfirmMatches.Count -ge 1)

    # =====================================================================
    Write-Host '--- multi-select: sync group (1) combined with a hook shares the paths ---' -ForegroundColor Cyan
    $cfg5 = Join-Path $Work 'cfg5.json'; New-Config $cfg5
    $c = New-Proj 'ComboC'; $d = New-Proj 'ComboD'
    # main 1 -> sub 1 -> "2,3" (sync group + Ai-Memory-Check) ->
    #   [sync group wizard: C, D, done, client Both, confirm] ->
    #   [single-hook config: recommended events, client Both, PATHS REUSED, confirm] -> exit
    # The hook is NOT prompted for a path - it reuses the sync group's C,D.
    $r2 = Invoke-Wizard -Config $cfg5 -Answers @('1', '1', '2,3', $c, $d, 'done', '1', '', '1', '1', '', '0')
    Check 'exit 0' ($r2.Exit -eq 0) $r2.Err
    Check 'no stderr' ($r2.Err -eq '')
    Check 'runs the sync group first, then the hook, without repeating the menu' ($r2.Out -match 'Running the sync group first')
    Check 'the single hook reuses the sync-group paths (no separate target prompt)' ($r2.Out -match 'Reusing the same 2 project path')
    Check 'completion message counts both' ($r2.Out -match 'Sync group \+ 1 hook\(s\) installed')
    $prof5 = @((Get-Content $cfg5 -Raw | ConvertFrom-Json).profiles)
    Check 'sync group profile was applied' ($prof5.Count -eq 1 -and @($prof5[0].routes).Count -eq 2)
    Check 'the hook installed into BOTH shared sync-group projects' ((Test-Path (Join-Path $c '.claude\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1')) -and (Test-Path (Join-Path $d '.claude\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1')))
    Check 'the sync engine also installed into those same shared projects' ((Test-Path (Join-Path $c '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync')) -and (Test-Path (Join-Path $d '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync')))

    Write-Host '--- multi-select: sync group alone still works (unchanged) ---' -ForegroundColor Cyan
    $cfg6 = Join-Path $Work 'cfg6.json'; New-Config $cfg6
    $f = New-Proj 'SoloF'; $g = New-Proj 'SoloG'
    $r3 = Invoke-Wizard -Config $cfg6 -Answers @('1', '1', '2', $f, $g, 'done', '1', '', '0')
    Check 'exit 0' ($r3.Exit -eq 0)
    Check 'no stderr' ($r3.Err -eq '')
    # NOTE: -match is case-INSENSITIVE by default, and the main menu's own
    # static description text is "(sync group + hooks\ folder)" - a plain
    # 'Sync group \+' pattern collides with that. Anchor on "N hook(s)
    # installed" (the actual completion-message shape) to target only the
    # combined-install summary, never the menu label.
    Check 'sync-group-only completion message (no "+ N hooks installed")' ($r3.Out -match 'Restart the Claude/Codex clients' -and $r3.Out -notmatch 'Sync group \+ \d+ hook')

    # =====================================================================
    Write-Host '--- a malformed profile route must not crash the wizard (Show-Profiles / StrictMode) ---' -ForegroundColor Cyan
    # Real regression: Show-Profiles read $route.source.root / $route.destination.root
    # UNGUARDED whenever '.name' was absent. Under Set-StrictMode -Version 2.0, a
    # route whose source/destination has neither 'name' nor 'root' (or is a bare
    # string) throws a property-not-found error that propagates past the main
    # menu loop into the top-level catch, exiting the whole wizard session.
    $cfgMalformed = Join-Path $Work 'cfg-malformed.json'
    @'
{"version":2,"defaults":{"events":["SessionStart","UserPromptSubmit"]},"profiles":[{"id":"malformed-profile","name":"Malformed","enabled":true,"routes":[{"source":{"root":"C:\\Malformed\\Src"},"destination":{}},{"source":"bare-string-source","destination":{"name":"NormalDest"}}]}]}
'@ | Set-Content -LiteralPath $cfgMalformed -Encoding utf8
    # main menu '2' (Show configured profiles) then '0' (exit) - if Show-Profiles
    # throws, '0' is never read and the process exits 1 from the outer catch
    # instead of the normal '0' -> break menu path.
    $rMalformed = Invoke-Wizard -Config $cfgMalformed -Answers @('2', '0')
    Check 'a malformed route does not crash the wizard (exit 0, no fatal error)' (
        $rMalformed.Exit -eq 0 -and $rMalformed.Out -notmatch 'Fatal error') (
        'exit=' + [string]$rMalformed.Exit + ' err=' + $rMalformed.Err)
    Check 'no stderr' ($rMalformed.Err -eq '')
    Check 'the malformed profile is still listed' ($rMalformed.Out -match 'Malformed') $rMalformed.Out
    Check 'a source with only "root" (no "name") still renders its root' ($rMalformed.Out -match 'C:\\Malformed\\Src') $rMalformed.Out
    Check 'the wizard returns to the main menu instead of exiting' ((([regex]::Matches($rMalformed.Out, 'Main menu:')).Count) -ge 2) $rMalformed.Out

    # =====================================================================
    Write-Host '--- client menu: exactly four entries, All by default, invalid answers re-prompt ---' -ForegroundColor Cyan
    # The menu offers Claude / Codex / Kiro / All clients in that order and nothing
    # else. Kiro is ONE entry covering both its surfaces: the IDE and the CLI share
    # a registrationKind and a runtimeRelativeRoot, so a separate "Kiro IDE" /
    # "Kiro CLI" pair would offer a distinction the installer cannot act on.
    # Answers: hook 3 (Ai-Memory-Check) -> recommended events -> an out-of-range
    # client number, then a non-numeric one, then back out with 0.
    $cfgClient = Join-Path $Work 'cfg-client-menu.json'; New-Config $cfgClient
    $rClient = Invoke-Wizard -Config $cfgClient -Answers @('1', '1', '3', '1', '9', 'kiro', '0', '0', 'exit')
    Check 'exit 0 (client menu navigation)' ($rClient.Exit -eq 0) $rClient.Err
    Check 'no stderr' ($rClient.Err -eq '')
    # The number and the label are painted separately, so ANSI escapes sit between
    # them - hence [^\r\n]* rather than a literal space.
    Check 'the client menu lists exactly Claude, Codex, Kiro, All clients in that order' (
        $rClient.Out -match 'Client:[\s\S]*?1\.[^\r\n]*Claude[\s\S]*?2\.[^\r\n]*Codex[\s\S]*?3\.[^\r\n]*Kiro[\s\S]*?4\.[^\r\n]*All clients') $rClient.Out
    Check 'no menu line offers a separate Kiro IDE / Kiro CLI option, and nothing follows "4. All clients"' (
        $rClient.Out -notmatch 'Kiro IDE' -and $rClient.Out -notmatch 'Kiro CLI' -and
        $rClient.Out -notmatch '4\.[^\r\n]*All clients[^\r\n]*\r?\n[^\r\n]*5\.') $rClient.Out
    Check 'the client prompt shows 4 (All clients) as the Enter default' ($rClient.Out -match 'Select the client[^\r\n]*\[4\]') $rClient.Out
    # An out-of-range number and a non-numeric answer must EACH re-prompt rather
    # than being accepted: three menu renders for the three answers given
    # (9, kiro, 0) and one error line for each of the two rejected ones.
    Check 'an out-of-range and a non-numeric client answer each re-prompt instead of being accepted' (
        (([regex]::Matches($rClient.Out, 'Select the client')).Count -eq 3) -and
        (([regex]::Matches($rClient.Out, 'Enter a number between 1 and 4, or 0\.')).Count -eq 2)) $rClient.Out
    Check 'back=0 from the client menu returns to the event selection' (([regex]::Matches($rClient.Out, 'Select events')).Count -eq 2) $rClient.Out

    # =====================================================================
    Write-Host '--- client menu: a bare Enter selects All clients and flags Kiro up front ---' -ForegroundColor Cyan
    # Kiro installs for real, so the note must describe Kiro's ACTUAL, permanent
    # limitations (5 of the 12 logical events; Stop can never hard-block) and must
    # not claim the registration is unimplemented - it has been wired up since
    # e914f5d, and the assertions here used to pin that stale claim in place. The
    # selection must still not be quietly narrowed to make an install succeed.
    # Declined at the confirmation, so nothing is written either way.
    $cfgAllClients = Join-Path $Work 'cfg-client-all.json'; New-Config $cfgAllClients
    $allClientsProj = New-Proj 'AllClientsProj'
    $rAllClients = Invoke-Wizard -Config $cfgAllClients -Answers @('1', '1', '3', '1', '', $allClientsProj, 'done', 'n', 'exit')
    Check 'exit 0 (bare Enter on the client menu)' ($rAllClients.Exit -eq 0) $rAllClients.Err
    Check 'a bare Enter on the client menu resolves to All, not to a single client' (
        $rAllClients.Out -match 'client:[^\r\n]*All' -and $rAllClients.Out -notmatch 'client:[^\r\n]*(Claude|Codex|Kiro)') $rAllClients.Out
    # The five names are spelled out rather than re-derived from the capability
    # table: a test that computes its expectation from the same source as the
    # code cannot catch that source being wrong.
    Check 'a Kiro-inclusive selection names the events Kiro really supports, and never claims it is unimplemented' (
        $rAllClients.Out -match 'Kiro supports only these events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop\.' -and
        $rAllClients.Out -notmatch 'not implemented') $rAllClients.Out
    Check 'the Kiro note states the permanent Stop limitation instead of a build-state one' (
        $rAllClients.Out -match 'Kiro cannot hard-block at Stop') $rAllClients.Out
    # The -ge 0 is load-bearing: IndexOf returns -1 for an ABSENT note, and -1 is
    # less than every real offset, so an ordering-only check silently passes when
    # the note it is ordering does not exist at all.
    $kiroNoteAt = $rAllClients.Out.IndexOf('Kiro supports only these events')
    Check 'the Kiro note is pre-flight (before the confirmation) and declining installs nothing' (
        $kiroNoteAt -ge 0 -and $kiroNoteAt -lt $rAllClients.Out.IndexOf('Start now?') -and
        -not (Test-Path -LiteralPath (Join-Path $allClientsProj '.claude'))) $rAllClients.Out

    # =====================================================================
    Write-Host '--- client menu: All clients really installs Claude + Codex despite Kiro ---' -ForegroundColor Cyan
    # Regression guard. The client menu has no Claude+Codex entry, so "All clients"
    # is the ONLY single pick that reaches two clients in one pass. When Kiro's
    # registration was unimplemented and that condition THREW, it took "All
    # clients" down with it - leaving no way to install for two clients at all.
    # Kiro now installs for real, so this asserts the same property from the
    # other side: all three clients land in one pass.
    $cfgKiroOk = Join-Path $Work 'cfg-client-all-install.json'; New-Config $cfgKiroOk
    $kiroOkProj = New-Proj 'AllClientsInstallProj'
    $rKiroOk = Invoke-Wizard -Config $cfgKiroOk -Answers @('1', '1', '3', '1', '4', $kiroOkProj, 'done', '', '0')
    Check 'selecting All clients does NOT abort on the unimplemented Kiro (exit 0, no stderr)' (
        $rKiroOk.Exit -eq 0 -and $rKiroOk.Err -eq '') ('exit=' + [string]$rKiroOk.Exit + ' err=' + $rKiroOk.Err)
    Check 'All clients installed the hook for Claude' (
        (Test-Path -LiteralPath (Join-Path $kiroOkProj '.claude\settings.local.json')) -and
        (Test-Path -LiteralPath (Join-Path $kiroOkProj '.claude\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1')))
    Check 'All clients installed the same hook for Codex in the SAME pass' (
        (Test-Path -LiteralPath (Join-Path $kiroOkProj '.codex\hooks.json')) -and
        (Test-Path -LiteralPath (Join-Path $kiroOkProj '.codex\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1')))
    # Kiro must land in the SAME pass, as a real registration plus a runtime -
    # the whole point of the change that made "All clients" survive it. The
    # launcher is asserted separately because it is planned, not written
    # afterwards; an unplanned launcher is the "unexpected managed file" that
    # made the updater reinstall Kiro forever.
    Check 'All clients installed the same hook for Kiro in the SAME pass' (
        @(Get-ChildItem -LiteralPath (Join-Path $kiroOkProj '.kiro\hooks') -Filter 'hookmaker-*.json' -File -ErrorAction SilentlyContinue).Count -eq 1 -and
        (Test-Path -LiteralPath (Join-Path $kiroOkProj '.kiro\hook-runtime\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1'))) $rKiroOk.Out
    Check 'the Kiro launcher is produced by the install plan, not written beside it' (
        Test-Path -LiteralPath (Join-Path $kiroOkProj '.kiro\hook-runtime\Hook-Maker\Ai-Memory-Check\kiro-launch.ps1')) $rKiroOk.Out
