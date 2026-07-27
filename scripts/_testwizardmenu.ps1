# Test-Wizard.ps1 scenario block: MENU STRUCTURE and SYNC GROUPS - the merged
# main menu, the hook listing (order, timing tags, descriptions, management
# rows), sync-group creation, the transitive merge contract (widening,
# disabled-route preservation, idempotency, larger-group id tie-break, a real
# install with an untouched anchor), back navigation, a real single-hook
# install with Claude-only targeting, per-hook recommended events, a real
# both-client sync-group install, and multi-select install.
#
# Dot-sourced by Test-Wizard.ps1 into the caller's scope (uses its harness,
# helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- menu structure + listing + sync-group create (-NoInstall) ---' -ForegroundColor Cyan
    $cfg1 = Join-Path $Work 'cfg1.json'; New-Config $cfg1
    $a = New-Proj 'A1'; $b = New-Proj 'B1'
    # main 1 -> sub 1 (install existing) -> item 2 (sync group) -> A,B,done -> client Both -> start
    $r = Invoke-Wizard -Config $cfg1 -NoInstall -Answers @('1', '1', '2', $a, $b, 'done', '1', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'main menu merged (Create or install a hook)' ($r.Out -match '1\. Create or install a hook')
    Check 'no separate top-level sync-group option' ($r.Out -notmatch '1\. Create or update a sync group\s*\r?\n\s*2\. Show')
    Check 'select-all is list item 1 (hint ends at the 3-N bound, no management-action tail)' ($r.Out -match '(?m)^  1\. Select all hooks \| \[all\] \| run the sync group \(2\) and install every hook below \(3-24\)\s*$')
    Check 'sync group is list item 2' ($r.Out -match '2\. Create or update a sync group')
    Check 'context hook menu names match their whole-.ai scope' ($r.Out -match 'Ai-Context-Check' -and $r.Out -match 'Ai-Context-Load')
    Check 'old memory-only menu names are hidden' ($r.Out -notmatch 'Ai-Memory-(Check|Load)')
    # The engine is reachable ONLY through item 2's hardcoded description line
    # (checked by "menu parts are pipe-separated" below), NOT by its own
    # hyphenated name as a separate list item: installed as a generic custom
    # hook (no -Profile, no config copy) it can never find its routing config
    # once copied into a project and silently does nothing.
    Check 'engine is NOT a separate numbered list entry' ($r.Out -notmatch '\d+\.\s+Cross-Project')
    Check 'listing shows timing tags' ($r.Out -match '\[post-task\]' -and $r.Out -match '\[pre-task\]')
    Check 'Docs-Freshness-Check (When=both) renders the [pre+post-task] timing tag' ($r.Out -match 'Docs-Freshness-Check[\s\S]*?\[pre\+post-task\]')
    # Regression: Ignore-Rules-Check's metadata used to say When='pre+post', a
    # value Get-HookTimingTag's switch never recognized (only pre/post/both),
    # so it silently rendered NO tag at all; Skills-Check's real recommended
    # events (SessionStart,UserPromptSubmit,Stop) were marked pre-only despite
    # including Stop. Both are normalized to 'both' now - verify every single
    # shipped hook renders exactly one recognized, non-blank timing tag, and
    # that these two specific hooks render the correct pre+post tag.
    Check 'Ignore-Rules-Check renders a recognized (non-blank) timing tag' ($r.Out -match 'Ignore-Rules-Check[\s\S]*?\[(pre|post|pre\+post)-task\]') $r.Out
    Check 'Ignore-Rules-Check renders the [pre+post-task] tag (real events: SessionStart,Stop)' ($r.Out -match 'Ignore-Rules-Check[\s\S]*?\[pre\+post-task\]') $r.Out
    Check 'Skills-Check renders the [pre+post-task] tag (real events include Stop)' ($r.Out -match 'Skills-Check[\s\S]*?\[pre\+post-task\]') $r.Out
    $allShippedHookCount = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
    $preTagCount = @([regex]::Matches($r.Out, '\[pre-task\]')).Count
    $postTagCount = @([regex]::Matches($r.Out, '\[post-task\]')).Count
    $bothTagCount = @([regex]::Matches($r.Out, '\[pre\+post-task\]')).Count
    # +1 accounts for the sync engine's own hardcoded, correctly-accurate
    # "Create or update a sync group | [pre-task] | ..." line (item 2) - it is
    # not one of the $script:HookMeta-driven hook-list entries counted by
    # $allShippedHookCount, but this single render of the hook list still
    # shows it exactly once alongside the real per-hook entries.
    Check 'every shipped hook renders exactly one valid, non-empty timing tag' (($preTagCount + $postTagCount + $bothTagCount) -eq ($allShippedHookCount + 1)) ('pre=' + $preTagCount + ' post=' + $postTagCount + ' both=' + $bothTagCount + ' expected=' + ($allShippedHookCount + 1))
    Check 'listing shows short descriptions' ($r.Out -match 'relevant \.ai context files' -and $r.Out -match 'checks global \+ project rules')
    Check 'menu parts are pipe-separated' ($r.Out -match 'Create or update a sync group \| \[pre-task\] \| cross-project \.ai knowledge sync')
    $menuOrder = @(
        '1\. Select all hooks', '2\. Create or update a sync group', '3\. Ai-Context-Check',
        '4\. Ai-Context-Load', '5\. Ci-Status-Check', '6\. Dependabot-Check',
        '7\. Github-Baseline-Check', '8\. Git-Sync-Check', '9\. Docs-Freshness-Check',
        '10\. Graph-Read-Check', '11\. Graph-Update-Check', '12\. Large-File-Check',
        '13\. Mcp-Usage-Check', '14\. Rules-Check', '15\. Skills-Check',
        '16\. Secrets-Check', '17\. Ignore-Rules-Check', '18\. Dependency-Version-Check',
        '19\. Test-Temp-Cleanup', '20\. Test-Plan-Check', '21\. Test-Run-Guard',
        '22\. Test-Completion-Check', '23\. Utf8-Encoding-Check', '24\. Cloudflare-Deploy'
    ) -join '[\s\S]*'
    Check 'hooks follow the requested menu order (Select all -> sync group -> hooks -> test-health at 20/21/22 -> Utf8-Encoding-Check at 23 -> Cloudflare-Deploy last at 24)' ($r.Out -match $menuOrder)
    # The three test-health hooks (24.txt) render one line each, with the tag
    # their canonical When value demands - a value Get-HookTimingTag does not
    # recognize silently renders NO tag at all.
    Check 'Test-Plan-Check renders the [pre-task] tag' ($r.Out -match '(?m)^  20\. Test-Plan-Check \| \[pre-task\] \| \S') $r.Out
    Check 'Test-Run-Guard renders the [pre+post-task] tag' ($r.Out -match '(?m)^  21\. Test-Run-Guard \| \[pre\+post-task\] \| \S') $r.Out
    Check 'Test-Completion-Check renders the [post-task] tag' ($r.Out -match '(?m)^  22\. Test-Completion-Check \| \[post-task\] \| \S') $r.Out
    Check 'the three management rows follow the shipped block at 25/26/27' (
        ($r.Out -match '(?m)^  25\. Update installed hooks \| \[manage\] \|') -and
        ($r.Out -match '(?m)^  26\. Get hook status \| \[manage\] \|') -and
        ($r.Out -match '(?m)^  27\. Uninstall installed hooks \| \[manage\] \|')) $r.Out
    Check '_hooklib excluded from listing' ($r.Out -notmatch '_hooklib')
    Check 'full back suffix on sub-prompts' ($r.Out -match 'back=0' -and $r.Out -match 'quit=exit')
    Check 'main-menu suffix is quit-only' ($r.Out -match 'Select an option.*\{quit=exit\}')
    Check 'config validated' ($r.Out -match 'configuration validated')
    Check 'install skipped (-NoInstall)' ($r.Out -match 'hook install skipped')
    $prof1 = @((Get-Content $cfg1 -Raw | ConvertFrom-Json).profiles)
    Check 'one full-mesh profile written' ($prof1.Count -eq 1 -and $prof1[0].id -match '^sync-group-[0-9a-f]{10}$' -and @($prof1[0].routes).Count -eq 2)

    # =====================================================================
    Write-Host '--- transitive sync-group merge (linking a new project widens the whole mesh) ---' -ForegroundColor Cyan
    $cfgMerge = Join-Path $Work 'cfg-merge.json'; New-Config $cfgMerge
    $mA = New-Proj 'MergeA'; $mB = New-Proj 'MergeB'; $mC = New-Proj 'MergeC'; $mD = New-Proj 'MergeD'
    # Group 1: A,B,C -> one full mesh of 3 (6 directed routes). -NoInstall so only
    # the config profile is written (no real Install-Hook).
    $rG1 = Invoke-Wizard -Config $cfgMerge -NoInstall -Answers @('1', '1', '2', $mA, $mB, $mC, 'done', '1', '', '0')
    Check 'merge: group 1 (A,B,C) created' ($rG1.Exit -eq 0) $rG1.Err
    $profG1 = @((Get-Content $cfgMerge -Raw | ConvertFrom-Json).profiles)
    Check 'merge: group 1 is one full mesh of 3 (6 routes)' ($profG1.Count -eq 1 -and @($profG1[0].routes).Count -eq 6)
    $g1Id = $profG1[0].id

    # Disable one route directly in group 1's config BEFORE the merge - the
    # widening must never silently re-enable a route the user explicitly
    # turned off (point 6 of the merge contract).
    $cfgObjDisable = Get-Content $cfgMerge -Raw | ConvertFrom-Json
    $routeToDisable = @($cfgObjDisable.profiles[0].routes | Where-Object { $_.source.name -eq 'MergeA' -and $_.destination.name -eq 'MergeB' })[0]
    Check 'merge setup: found MergeA->MergeB route to disable' ($null -ne $routeToDisable)
    $routeToDisable.enabled = $false
    ($cfgObjDisable | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $cfgMerge -Encoding utf8

    # Group 2: link D to C. C already belongs to group 1, so the two must MERGE
    # into ONE full mesh of A,B,C,D (12 routes), reusing group 1's id.
    $rG2 = Invoke-Wizard -Config $cfgMerge -NoInstall -Answers @('1', '1', '2', $mC, $mD, 'done', 'y', '1', '', '0')
    Check 'merge: group 2 (C,D) applied' ($rG2.Exit -eq 0) $rG2.Err
    Check 'merge: the summary announces the merge with the existing group' ($rG2.Out -match 'Merges with 1 existing sync group')
    $profM = @((Get-Content $cfgMerge -Raw | ConvertFrom-Json).profiles)
    Check 'merge: still exactly one profile after the merge' ($profM.Count -eq 1) ('profiles=' + $profM.Count)
    Check 'merge: the merged mesh covers all 4 projects (12 directed routes)' (@($profM[0].routes).Count -eq 12)
    Check 'merge: the merged profile reuses the larger group''s id' ($profM[0].id -eq $g1Id)
    $routeNames = @($profM[0].routes | ForEach-Object { $_.source.name + '->' + $_.destination.name })
    Check 'merge: D now meshes with A (a link group 2 never named directly)' (($routeNames -contains 'MergeD->MergeA') -and ($routeNames -contains 'MergeA->MergeD'))
    Check 'merge: D now meshes with B (transitive through C)' (($routeNames -contains 'MergeD->MergeB') -and ($routeNames -contains 'MergeB->MergeD'))

    # Point 4 (full contract): all 12 directed routes of the 4-project full
    # mesh exist, EACH EXACTLY ONCE - not just "count is 12" (a duplicate-plus-
    # missing mix could also satisfy a bare count) and not just the two sampled
    # pairs above. A naive non-transitive union of {A,B,C} and {C,D} would top
    # out at 8 routes (6 + 2, D only ever meeting C) and would fail this.
    $expectedPairs = @()
    foreach ($sourceName in @('MergeA', 'MergeB', 'MergeC', 'MergeD')) {
        foreach ($destName in @('MergeA', 'MergeB', 'MergeC', 'MergeD')) {
            if ($sourceName -ne $destName) { $expectedPairs += ($sourceName + '->' + $destName) }
        }
    }
    $missingPairs = @($expectedPairs | Where-Object { $routeNames -notcontains $_ })
    $dupRouteIds = @($profM[0].routes | Group-Object -Property id | Where-Object { $_.Count -gt 1 })
    Check 'merge: all 12 directed routes of the full mesh are present' ($missingPairs.Count -eq 0) ('missing=' + ($missingPairs -join ','))
    Check 'merge: no route id is duplicated' ($dupRouteIds.Count -eq 0) ('dup ids=' + (($dupRouteIds | ForEach-Object { $_.Name }) -join ','))
    Check 'merge: exactly 12 routes total (no extras beyond the full mesh)' ($routeNames.Count -eq 12)

    # The expansion PROMPT and its default. Every merge scenario above answers
    # 'y' because each is asserting the merge itself; this one answers the way
    # a user pressing Enter does. The wizard must offer the choice, name the
    # group it would pull in, and default to NOT pulling it in.
    $cfgAsk = Join-Path $Work 'cfg-ask.json'; New-Config $cfgAsk
    $aA = New-Proj 'AskA'; $aB = New-Proj 'AskB'; $aC = New-Proj 'AskC'; $aD = New-Proj 'AskD'
    $null = Invoke-Wizard -Config $cfgAsk -NoInstall -Answers @('1', '1', '2', $aA, $aB, $aC, 'done', '1', '', '0')
    # Entering only C and D: A and B would be dragged in, so the question fires.
    $rAsk = Invoke-Wizard -Config $cfgAsk -NoInstall -Answers @('1', '1', '2', $aC, $aD, 'done', '', '1', '', '0')
    Check 'expansion prompt: the wizard asks before widening the mesh' (
        $rAsk.Out -match 'already belong to other sync group') $rAsk.Out
    Check 'expansion prompt: it names the projects a yes would ADD' (
        $rAsk.Out -match 'would be ADDED to this mesh') $rAsk.Out
    $askProfiles = @((Get-Content $cfgAsk -Raw | ConvertFrom-Json).profiles)
    # Enter = no: the entered pair meshes on its own and the existing group is
    # left exactly as it was, so BOTH profiles survive.
    Check 'expansion prompt: pressing Enter declines, leaving both groups intact' (
        $askProfiles.Count -eq 2) ('profiles=' + $askProfiles.Count)
    $askRouteCounts = @($askProfiles | ForEach-Object { @($_.routes).Count } | Sort-Object)
    Check 'expansion prompt: declining yields 6 + 2 routes, never a 12-route merge' (
        ($askRouteCounts -join ',') -eq '2,6') ($askRouteCounts -join ',')

    # Point 6: the route disabled before the merge stays disabled; a route
    # that was never touched (the reverse direction) stays enabled; a brand
    # new transitive route defaults to enabled.
    $routeAtoB = @($profM[0].routes | Where-Object { $_.source.name -eq 'MergeA' -and $_.destination.name -eq 'MergeB' })[0]
    Check 'merge: the route explicitly disabled before the merge (MergeA->MergeB) stays disabled' ($routeAtoB.enabled -eq $false)
    $routeBtoA = @($profM[0].routes | Where-Object { $_.source.name -eq 'MergeB' -and $_.destination.name -eq 'MergeA' })[0]
    Check 'merge: the reverse direction (MergeB->MergeA), never disabled, stays enabled' ($routeBtoA.enabled -eq $true)
    $routeAtoD = @($profM[0].routes | Where-Object { $_.source.name -eq 'MergeA' -and $_.destination.name -eq 'MergeD' })[0]
    Check 'merge: a brand new transitive route (MergeA->MergeD) defaults to enabled' ($routeAtoD.enabled -eq $true)

    # Point 9: re-running the exact same merge-triggering answers again must be
    # a pure no-op - no duplicate profile, no route churn, no re-enabling the
    # disabled route, same retained id.
    $rG2Again = Invoke-Wizard -Config $cfgMerge -NoInstall -Answers @('1', '1', '2', $mC, $mD, 'done', 'y', '1', '', '0')
    Check 'merge: re-running the same merge exits 0' ($rG2Again.Exit -eq 0) $rG2Again.Err
    $profMAgain = @((Get-Content $cfgMerge -Raw | ConvertFrom-Json).profiles)
    Check 'merge: idempotent re-run keeps exactly one profile' ($profMAgain.Count -eq 1) ('profiles=' + $profMAgain.Count)
    Check 'merge: idempotent re-run keeps exactly 12 routes (no duplicates, none dropped)' (@($profMAgain[0].routes).Count -eq 12)
    Check 'merge: idempotent re-run keeps the same profile id' ($profMAgain[0].id -eq $profM[0].id)
    $dupRouteIdsAgain = @($profMAgain[0].routes | Group-Object -Property id | Where-Object { $_.Count -gt 1 })
    Check 'merge: idempotent re-run introduces no duplicate route ids' ($dupRouteIdsAgain.Count -eq 0)
    $routeAtoBAgain = @($profMAgain[0].routes | Where-Object { $_.source.name -eq 'MergeA' -and $_.destination.name -eq 'MergeB' })[0]
    Check 'merge: idempotent re-run does not silently re-enable the disabled route' ($routeAtoBAgain.enabled -eq $false)

    # =====================================================================
    Write-Host '--- transitive merge: the id of the LARGER of two simultaneously-absorbed groups wins ---' -ForegroundColor Cyan
    # The block above only ever absorbs ONE existing profile per merge step,
    # so it cannot distinguish "keep the larger absorbed profile's id" from
    # "keep whichever profile happens to be the only one absorbed". This test
    # creates TWO separate, non-overlapping groups - a 2-member group created
    # FIRST (chronologically earlier) and a 3-member group created SECOND -
    # then links one member of each in a single new entry. Both groups
    # intersect the new union and are absorbed together; the merge must keep
    # the LARGER group's id even though it is neither the first created nor
    # the first entry in the config's profiles array.
    $cfgTie = Join-Path $Work 'cfg-tie.json'; New-Config $cfgTie
    $tA = New-Proj 'TieA'; $tB = New-Proj 'TieB'
    $tX = New-Proj 'TieX'; $tY = New-Proj 'TieY'; $tZ = New-Proj 'TieZ'
    $rTie1 = Invoke-Wizard -Config $cfgTie -NoInstall -Answers @('1', '1', '2', $tA, $tB, 'done', '1', '', '0')
    Check 'tie-break: smaller group (TieA,TieB) created first' ($rTie1.Exit -eq 0) $rTie1.Err
    $idSmall = ((@((Get-Content $cfgTie -Raw | ConvertFrom-Json).profiles))[0]).id
    $rTie2 = Invoke-Wizard -Config $cfgTie -NoInstall -Answers @('1', '1', '2', $tX, $tY, $tZ, 'done', '1', '', '0')
    Check 'tie-break: larger group (TieX,TieY,TieZ) created second' ($rTie2.Exit -eq 0) $rTie2.Err
    $profsTieBefore = @((Get-Content $cfgTie -Raw | ConvertFrom-Json).profiles)
    Check 'tie-break: two independent (non-overlapping) profiles exist before the link' ($profsTieBefore.Count -eq 2)
    $idLarge = (@($profsTieBefore | Where-Object { $_.id -ne $idSmall }))[0].id
    # Link TieB (member of the smaller group) with TieX (member of the larger
    # group) in one new entry - both existing groups intersect this union and
    # must be absorbed TOGETHER into a single 5-project full mesh.
    $rTie3 = Invoke-Wizard -Config $cfgTie -NoInstall -Answers @('1', '1', '2', $tB, $tX, 'done', 'y', '1', '', '0')
    Check 'tie-break: linking one member of each group exits 0' ($rTie3.Exit -eq 0) $rTie3.Err
    Check 'tie-break: the summary announces absorbing BOTH existing groups' ($rTie3.Out -match 'Merges with 2 existing sync group')
    $profsTieAfter = @((Get-Content $cfgTie -Raw | ConvertFrom-Json).profiles)
    Check 'tie-break: exactly one profile remains after absorbing both' ($profsTieAfter.Count -eq 1) ('profiles=' + $profsTieAfter.Count)
    Check 'tie-break: the merged mesh covers all 5 projects (20 directed routes)' (@($profsTieAfter[0].routes).Count -eq 20) ('routes=' + @($profsTieAfter[0].routes).Count)
    Check 'tie-break: the LARGER absorbed group''s id is retained' ($profsTieAfter[0].id -eq $idLarge) ('got=' + $profsTieAfter[0].id + ' expectedLarge=' + $idLarge + ' expectedSmall(wrong)=' + $idSmall)
    Check 'tie-break: the smaller (chronologically first) group''s id is NOT retained' ($profsTieAfter[0].id -ne $idSmall)

    # =====================================================================
    Write-Host '--- transitive merge + a REAL install: anchor keeps working, only new members installed ---' -ForegroundColor Cyan
    # Points 7-8 of the merge contract need REAL installs (the -NoInstall
    # blocks above only prove the config side). RmA anchors group {RmA,RmB}
    # with a real engine install; group {RmB,RmC} then merges RmC in
    # transitively. RmA/RmB are anchor members and must NOT be touched again -
    # RmC (new) must be installed. Then RmA's OWN already-registered engine
    # copy (unchanged command, same -Profile id) is fired pointed at the LIVE
    # shared config - the file Setup-SyncGroupBuilder.ps1's own comment
    # describes ("the engine ... reads the live config at run time") - and
    # must resolve the newly-linked RmC as a source, something a non-
    # transitive (naive union) merge could never produce since RmC was never
    # named when RmA's own group was created.
    $cfgReal = Join-Path $Work 'cfg-merge-real.json'; New-Config $cfgReal
    $rmA = New-Proj 'RealAnchorA'; $rmB = New-Proj 'RealAnchorB'; $rmC = New-Proj 'RealAnchorC'
    $rReal1 = Invoke-Wizard -Config $cfgReal -Answers @('1', '1', '2', $rmA, $rmB, 'done', '1', '', '0')
    Check 'real-merge: group (RealAnchorA,RealAnchorB) created with a real install' ($rReal1.Exit -eq 0) $rReal1.Err
    $rmASettings = Join-Path $rmA '.claude\settings.local.json'
    Check 'real-merge: RealAnchorA got a real engine install' (Test-Path $rmASettings)
    $rmAEngineSnapshot = Join-Path $rmA '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\sync-hooks.json'
    $rmASettingsHashBefore = (Get-FileHash -LiteralPath $rmASettings -Algorithm SHA256).Hash
    $rmAEngineWriteBefore = (Get-Item -LiteralPath $rmAEngineSnapshot).LastWriteTimeUtc
    $anchorProfId = ((@((Get-Content $cfgReal -Raw | ConvertFrom-Json).profiles))[0]).id

    $rReal2 = Invoke-Wizard -Config $cfgReal -Answers @('1', '1', '2', $rmB, $rmC, 'done', 'y', '1', '', '0')
    Check 'real-merge: group (RealAnchorB,RealAnchorC) merges into the existing group with a real install' ($rReal2.Exit -eq 0) $rReal2.Err
    Check 'real-merge: the summary announces the merge' ($rReal2.Out -match 'Merges with 1 existing sync group')
    $profsReal = @((Get-Content $cfgReal -Raw | ConvertFrom-Json).profiles)
    Check 'real-merge: exactly one profile, full mesh of 3 (6 routes)' ($profsReal.Count -eq 1 -and @($profsReal[0].routes).Count -eq 6)
    Check 'real-merge: the merged profile keeps the anchor''s original id' ($profsReal[0].id -eq $anchorProfId)

    # Point 8: the anchor (RealAnchorA) must not be touched by the second run.
    $rmASettingsHashAfter = (Get-FileHash -LiteralPath $rmASettings -Algorithm SHA256).Hash
    Check 'real-merge (point 8): anchor''s settings.local.json is byte-identical (not re-registered)' ($rmASettingsHashBefore -eq $rmASettingsHashAfter)
    $rmAEngineWriteAfter = (Get-Item -LiteralPath $rmAEngineSnapshot).LastWriteTimeUtc
    Check 'real-merge (point 8): anchor''s local engine runtime copy was not rewritten' ($rmAEngineWriteBefore -eq $rmAEngineWriteAfter)
    # RealAnchorC (new member, never an anchor member) must have gotten a fresh install.
    Check 'real-merge (point 8): the new member RealAnchorC got a fresh engine install' (Test-Path (Join-Path $rmC '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'))

    # Point 7: fire RealAnchorA's OWN already-installed engine SCRIPT (same
    # file, untouched -Profile id) pointed at the LIVE shared config path and
    # prove it resolves RealAnchorC - a member RealAnchorA's group never had
    # until the SECOND, transitive merge widened the shared config.
    $rmCAi = Join-Path $rmC '.ai'
    if (-not (Test-Path $rmCAi)) { New-Item -ItemType Directory -Path $rmCAi -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $rmCAi 'memory.md'), 'regression probe content from RealAnchorC', (New-Object System.Text.UTF8Encoding $false))
    $rmAEngineScript = Join-Path $rmA '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'
    $inFire = Join-Path $Work 'fire-anchor.json'; $outFire = "$inFire.out"; $errFire = "$inFire.err"
    [System.IO.File]::WriteAllText($inFire, (@{ session_id = 'wiztest-anchor'; cwd = $rmA; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
    $fireHost = (Get-Process -Id $PID).Path
    $pFire = Start-Process $fireHost -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "' + $rmAEngineScript + '" -ConfigPath "' + $cfgReal + '" -Profile "' + $anchorProfId + '"') -RedirectStandardInput $inFire -RedirectStandardOutput $outFire -RedirectStandardError $errFire -Wait -NoNewWindow -PassThru
    $fireOut = ''; if (Test-Path $outFire) { $fireOut = [System.IO.File]::ReadAllText($outFire) }
    $fireErr = ''; if (Test-Path $errFire) { $fireErr = ([System.IO.File]::ReadAllText($errFire)).Trim() }
    Check 'real-merge (point 7): anchor''s installed engine runs cleanly against the live merged config' ($pFire.ExitCode -eq 0 -and $fireErr -eq '') $fireErr
    Check 'real-merge (point 7): anchor resolves the transitively-linked RealAnchorC through the live config (a naive non-transitive union would never link them)' ($fireOut -match 'RealAnchorC') $fireOut

    # =====================================================================
    Write-Host '--- back navigation returns exactly one menu level ---' -ForegroundColor Cyan
    $cfgNav = Join-Path $Work 'cfg-nav.json'; New-Config $cfgNav
    $rNav = Invoke-Wizard -Config $cfgNav -Answers @(
        '1', '1', '2', '0', # sync-group project entry -> hook list
        '0',                # hook list -> create/install menu
        '2', '0',           # create-hook first prompt -> create/install menu
        '3', '0',           # config-install hook list -> create/install menu
        '0',                # create/install menu -> main menu
        'exit'
    )
    Check 'sync-group project back returns to the hook list' (([regex]::Matches($rNav.Out, 'Tip: use lists and ranges')).Count -eq 2)
    Check 'sub-flow back always returns to the create/install menu' (([regex]::Matches($rNav.Out, 'Create or Install a Hook')).Count -eq 4)
    Check 'create/install back returns to the main menu' (([regex]::Matches($rNav.Out, 'Main menu:')).Count -eq 2)

    # =====================================================================
    Write-Host '--- install a real hook (list offset + Claude-only targeting) ---' -ForegroundColor Cyan
    $cfg2 = Join-Path $Work 'cfg2.json'; New-Config $cfg2
    $t = New-Proj 'T2'
    # main 1 -> sub 1 (install existing) -> item 3 (displayed as Ai-Context-Check,
    # internally Ai-Memory-Check, whose recommended events are 'Stop' - so
    # choice 1 in the single-hook event menu is now that recommendation; choice
    # 3 is the explicit "Session Start" alone this test actually wants) ->
    # events Session Start (explicit, not the recommendation) -> client Claude
    # (menu item 1 since the client menu became Claude/Codex/Kiro/All) -> target
    # -> done -> start
    $r = Invoke-Wizard -Config $cfg2 -Answers @('1', '1', '3', '3', '1', $t, 'done', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'event menu separates camel-case labels' ($r.Out -match 'Session Start \+ User Prompt Submit' -and $r.Out -match 'User Prompt Submit' -and $r.Out -match 'Pre Tool Use, Post Tool Use, Stop')
    $claude2 = Join-Path $t '.claude\settings.local.json'
    Check 'claude settings written' (Test-Path $claude2)
    $j2 = ''; if (Test-Path $claude2) { $j2 = [System.IO.File]::ReadAllText($claude2) }
    Check 'item 3 installed the FIRST real hook (Ai-Memory-Check)' ($j2 -match 'Ai-Memory-Check\.ps1')
    Check 'explicit choice 3 (Session Start alone) registered only SessionStart, not the Stop recommendation' (@(Get-RegisteredEvents $claude2 'Ai-Memory-Check') -join ',' -eq 'SessionStart')
    Check 'did not install a neighbor hook' ($j2 -notmatch 'Ci-Status-Check')
    Check 'Claude-only leaves codex untouched' (-not (Test-Path (Join-Path $t '.codex\hooks.json')) -and -not (Test-Path (Join-Path $t '.codex')))
    # Self-contained install: the command points at a runtime copy INSIDE the
    # project, named with the friendly hyphenated hook name.
    Check 'command points at the project-local copy' ($j2 -like '*hooks\\Hook-Maker\\Ai-Memory-Check\\Ai-Memory-Check.ps1*')
    Check 'command does not reference the tool folder' ($j2 -notlike '*Hook Maker*')
    Check 'runtime copy of the hook exists' (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\Ai-Memory-Check\Ai-Memory-Check.ps1'))
    Check 'each hook gets its own PRIVATE _hooklib copy' (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\Ai-Memory-Check\_hooklib.ps1'))
    Check 'no shared library is left at the runtime root' (-not (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\_hooklib.ps1')))
    Check 'runtime copy has no .env.example' (-not (Test-Path (Join-Path $t '.claude\hooks\Hook-Maker\Ai-Memory-Check\.env.example')))

    # =====================================================================
    Write-Host '--- single-hook install now defaults to THAT hook''s recommended events (regression) ---' -ForegroundColor Cyan
    # Before the fix, a single-hook pick always opened the generic 4-choice
    # event menu (default SessionStart+UserPromptSubmit on a bare Enter),
    # regardless of what the hook actually needed - a Stop-only hook like
    # Cloudflare-Deploy or a SessionStart+Stop hook like Docs-Freshness-Check
    # could silently be installed on the wrong events by just pressing Enter.
    $shippedHookCountForEventsTest = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Cross-Project-.ai-Knowledge-Sync' }).Count
    $cfgRecStop = Join-Path $Work 'cfg-rec-stop.json'; New-Config $cfgRecStop
    $recStopProj = New-Proj 'RecommendedStopOnly'
    # main 1 -> sub 1 -> last individual entry (Cloudflare-Deploy, Stop-only) ->
    # events: blank Enter (choice 1 = recommended) -> client Both -> target -> done -> start
    $rRecStop = Invoke-Wizard -Config $cfgRecStop -Answers @('1', '1', ($shippedHookCountForEventsTest + 2).ToString(), '', '1', $recStopProj, 'done', '', '0')
    Check 'exit 0 (recommended-events single-hook install, Stop-only)' ($rRecStop.Exit -eq 0) $rRecStop.Err
    Check 'the recommended-events choice names the actual events' ($rRecStop.Out -match "This hook's recommended events.*\(Stop\)")
    $recStopClaude = Join-Path $recStopProj '.claude\settings.local.json'
    Check 'Cloudflare-Deploy installed' (Test-Path $recStopClaude)
    Check 'a bare Enter on the recommended-events choice registers exactly Stop, not SessionStart+UserPromptSubmit' (@(Get-RegisteredEvents $recStopClaude 'Cloudflare-Deploy') -join ',' -eq 'Stop')

    $cfgRecBoth = Join-Path $Work 'cfg-rec-both.json'; New-Config $cfgRecBoth
    $recBothProj = New-Proj 'RecommendedSessionStartStop'
    # item 9 = Docs-Freshness-Check (recommended events: SessionStart,Stop).
    $rRecBoth = Invoke-Wizard -Config $cfgRecBoth -Answers @('1', '1', '9', '', '1', $recBothProj, 'done', '', '0')
    Check 'exit 0 (recommended-events single-hook install, SessionStart+Stop)' ($rRecBoth.Exit -eq 0) $rRecBoth.Err
    Check 'the recommended-events choice names both actual events' ($rRecBoth.Out -match 'This hook''s recommended events.*\(SessionStart, Stop\)')
    $recBothClaude = Join-Path $recBothProj '.claude\settings.local.json'
    Check 'Docs-Freshness-Check installed' (Test-Path $recBothClaude)
    Check 'a bare Enter on the recommended-events choice registers exactly SessionStart+Stop' (@(@(Get-RegisteredEvents $recBothClaude 'Docs-Freshness-Check') | Sort-Object) -join ',' -eq 'SessionStart,Stop')

    # =====================================================================
    Write-Host '--- sync group with a real install (both clients) ---' -ForegroundColor Cyan
    $cfg3 = Join-Path $Work 'cfg3.json'; New-Config $cfg3
    $a3 = New-Proj 'A3'; $b3 = New-Proj 'B3'
    # Client answer '4' = "All clients". The menu has no Claude+Codex entry, so
    # All is how one pass reaches both, and Claude + Codex install exactly as the
    # legacy 'Both' did. Hence the codex assertions below. (Kiro installs too;
    # Test-KiroIntegration.ps1 owns proving that, so it is not re-asserted here.)
    $r = Invoke-Wizard -Config $cfg3 -Answers @('1', '1', '2', $a3, $b3, 'done', '4', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    $profId3 = (@((Get-Content $cfg3 -Raw | ConvertFrom-Json).profiles)[0]).id
    foreach ($proj in @($a3, $b3)) {
        $name = Split-Path -Leaf $proj
        Check "$name got claude settings" (Test-Path (Join-Path $proj '.claude\settings.local.json'))
        Check "$name got codex hooks" (Test-Path (Join-Path $proj '.codex\hooks.json'))
        $cl = Join-Path $proj '.claude\settings.local.json'
        $jc = ''; if (Test-Path $cl) { $jc = [System.IO.File]::ReadAllText($cl) }
        Check "$name command points at engine + this profile" ($jc -match 'Cross-Project-\.ai-Knowledge-Sync\.ps1' -and $jc -match [regex]::Escape($profId3))
        # Self-contained: engine + lib + routing config copied into BOTH clients,
        # the engine folder/script under the friendly name.
        $eng = 'hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\Cross-Project-.ai-Knowledge-Sync.ps1'
        $engCfg = 'hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\sync-hooks.json'
        $engProjects = 'hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\SYNC-PROJECTS.txt'
        Check "$name command uses the local engine copy" ($jc -like ('*' + $eng.Replace('\', '\\') + '*') -and $jc -notlike '*Hook Maker*')
        Check "$name claude runtime copy complete" ((Test-Path (Join-Path $proj (Join-Path '.claude' $eng))) -and (Test-Path (Join-Path $proj '.claude\hooks\Hook-Maker\Cross-Project-.ai-Knowledge-Sync\_hooklib.ps1')) -and (Test-Path (Join-Path $proj (Join-Path '.claude' $engCfg))))
        Check "$name codex runtime copy complete" ((Test-Path (Join-Path $proj (Join-Path '.codex' $eng))) -and (Test-Path (Join-Path $proj (Join-Path '.codex' $engCfg))))
        foreach ($clientDir in @('.claude', '.codex')) {
            $projectList = Join-Path $proj (Join-Path $clientDir $engProjects)
            $projectListText = ''; if (Test-Path $projectList) { $projectListText = [System.IO.File]::ReadAllText($projectList) }
            Check "$name $clientDir runtime lists the sync projects" ((Test-Path $projectList) -and $projectListText.Contains($a3) -and $projectListText.Contains($b3))
        }
        # The copied engine must actually RUN from inside the project with the
        # copied config: fire it once via stdin and require a clean exit.
        $localEngine = Join-Path $proj (Join-Path '.claude' $eng)
        $localCfg = Join-Path $proj (Join-Path '.claude' $engCfg)
        $inE = Join-Path $Work ('eng-' + $name + '.json'); $outE = "$inE.out"; $errE = "$inE.err"
        [System.IO.File]::WriteAllText($inE, (@{ session_id = 'wiztest'; cwd = $proj; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
        $engineHost = (Get-Process -Id $PID).Path
        $pe = Start-Process $engineHost -ArgumentList ('-NoLogo -NoProfile -NonInteractive -File "' + $localEngine + '" -ConfigPath "' + $localCfg + '" -Profile "' + $profId3 + '"') -RedirectStandardInput $inE -RedirectStandardOutput $outE -RedirectStandardError $errE -Wait -NoNewWindow -PassThru
        $errText = ''; if (Test-Path $errE) { $errText = ([System.IO.File]::ReadAllText($errE)).Trim() }
        Check "$name local engine copy runs cleanly" ($pe.ExitCode -eq 0 -and $errText -eq '')
    }

    # =====================================================================
    Write-Host '--- multi-select install (range + list, recommended events) ---' -ForegroundColor Cyan
    $cfg4 = Join-Path $Work 'cfg4.json'; New-Config $cfg4
    $m = New-Proj 'Multi'
    # main 1 -> sub 1 -> "3-8,16,24" (eight advisory hooks incl. Cloudflare-Deploy,
    #        still the LAST individual entry (Docs-Freshness-Check inserted at 9
    #        shifted Secrets-Check 15->16, the three test-health hooks at
    #        20/21/22 and Utf8-Encoding-Check at 23 shifted Cloudflare-Deploy
    #        to 24); the engine is excluded from this list entirely, see the
    #        guard test below)
    #        -> mode 1 (recommended events per hook) -> client 4 = All clients
    #        (reaches Claude + Codex in one pass; Kiro installs alongside them
    #        and is asserted in Test-KiroIntegration.ps1, not here)
    #        -> target -> done -> start -> exit
    $r = Invoke-Wizard -Config $cfg4 -Answers @('1', '1', '3-8,16,24', '1', '4', $m, 'done', '', '0')
    Check 'exit 0' ($r.Exit -eq 0)
    Check 'no stderr' ($r.Err -eq '')
    Check 'selection accepts a range combined with a single item' ($r.Out -notmatch 'Enter number\(s\)')
    Check 'multi-hook header has a blank line before its options' ($r.Out -match 'Configuring 8 hooks:[^\r\n]*\r?\n\r?\n\s*1\.')
    # The wizard is split across Setup-SyncGroup*.ps1 siblings, so read them ALL
    # rather than only the entry script: this particular renderer now lives in
    # Setup-SyncGroupInstallFlows.ps1. Reading the whole set keeps the assertion
    # exactly as strict while surviving any further responsibility split.
    $setupSource = ((Get-ChildItem -LiteralPath (Split-Path -Parent $Setup) -Filter 'Setup-SyncGroup*.ps1' -File |
                Sort-Object Name | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n")
    Check 'multi-hook header label uses a different color from hook names' ($setupSource -match "Get-Painted \('Configuring '.*\`$C\.Input.*Get-Painted \`$selectedNames \`$C\.White")
    $installedFolders = @(Get-ChildItem -LiteralPath (Join-Path $m '.claude\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'eight distinct hooks installed in one pass' ($installedFolders.Count -eq 8)
    Check 'each installed under its own friendly folder' ($installedFolders -notcontains 'Cross-Project-.ai-Knowledge-Sync' -and (@($installedFolders | Where-Object { $_ -match '-' }).Count -eq 8))
    $codexFolders = @(Get-ChildItem -LiteralPath (Join-Path $m '.codex\hooks\Hook-Maker') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Check 'batch honored client=All (codex got all eight too)' ($codexFolders.Count -eq 8)
    $expectedEvents = [ordered]@{
        'Ai-Memory-Check'       = 'Stop'
        'Ai-Memory-Load'        = 'SessionStart,UserPromptSubmit'
        'Ci-Status-Check'       = 'Stop'
        'Dependabot-Check'      = 'SessionStart'
        'Github-Baseline-Check' = 'SessionStart'
        'Git-Sync-Check'        = 'SessionStart,Stop,SubagentStop'
        'Cloudflare-Deploy'     = 'Stop'
        'Secrets-Check'         = 'SessionStart,Stop'
    }
    $recommendedEventsApplied = $true
    foreach ($entry in $expectedEvents.GetEnumerator()) {
        $expected = @($entry.Value.Split(',') | Sort-Object) -join ','
        $claudeEvents = @(Get-RegisteredEvents (Join-Path $m '.claude\settings.local.json') $entry.Key | Sort-Object) -join ','
        $codexEvents = @(Get-RegisteredEvents (Join-Path $m '.codex\hooks.json') $entry.Key | Sort-Object) -join ','
        if ($claudeEvents -ne $expected -or $codexEvents -ne $expected) { $recommendedEventsApplied = $false }
    }
    Check 'batch applies each hook recommended events in both clients' $recommendedEventsApplied
    Check 'summary lists all eight (8 event lines)' (([regex]::Matches($r.Out, 'events:')).Count -ge 8)

