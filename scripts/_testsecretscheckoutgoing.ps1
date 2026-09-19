# Test-SecretsCheck.ps1 scenario block: git-boundary LEAK SCANS and the
# outgoing-commit PUSH GATE - staged/index-only detection, pre-push ref-update
# handling (new branch, deletion, force-push, multi-ref, spaced/nested paths,
# dash-prefixed values), the real end-to-end native pre-push chain, removed
# .env*/secrets.md history, and fail-closed incomplete scans.
#
# Dot-sourced by Test-SecretsCheck.ps1 into the caller's scope (uses its
# harness, helpers, and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- git: staged/index-only leak detection (confirmed gap) ---' -ForegroundColor Cyan

    # Leak only in the WORKING TREE (a dirty, unstaged edit adds the value).
    $projLeakWt = New-GitProj 'LeakWorktreeOnly'
    Write-Utf8 (Join-Path $projLeakWt '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projLeakWt '.env') "WT_ONLY_SECRET=wtonlyvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projLeakWt 'notes.txt') "clean`r`n"
    Add-Commit $projLeakWt 'seed clean'
    Write-Utf8 (Join-Path $projLeakWt 'notes.txt') "leaked: wtonlyvalue1234567890`r`n"
    $r = Fire -Cwd $projLeakWt
    Check 'leak only in working tree (unstaged) is detected' ($r.Out -like '*WT_ONLY_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
    Check 'worktree-only leak: value never printed' ($r.Out -notlike '*wtonlyvalue1234567890*') $r.Out

    # Leak only in the INDEX (staged, then the working copy is cleaned WITHOUT
    # staging that cleanup) - the confirmed gap: a working-tree-only `git grep`
    # misses this; the index scan (`git grep --cached`) must catch it.
    $projLeakIdx = New-GitProj 'LeakIndexOnly'
    Write-Utf8 (Join-Path $projLeakIdx '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projLeakIdx '.env') "IDX_ONLY_SECRET=idxonlyvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projLeakIdx 'notes.txt') "clean`r`n"
    Add-Commit $projLeakIdx 'seed clean'
    Write-Utf8 (Join-Path $projLeakIdx 'notes.txt') "leaked: idxonlyvalue1234567890`r`n"
    & git -C $projLeakIdx add notes.txt 2>$null | Out-Null
    Write-Utf8 (Join-Path $projLeakIdx 'notes.txt') "clean again (worktree only)`r`n"
    $r = Fire -Cwd $projLeakIdx
    Check 'leak only in the git index (staged) is detected' ($r.Out -like '*IDX_ONLY_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
    Check 'index-only leak: value never printed' ($r.Out -notlike '*idxonlyvalue1234567890*') $r.Out

    # Same leak present in BOTH the working tree and the index - reported once.
    $projLeakBoth = New-GitProj 'LeakBoth'
    Write-Utf8 (Join-Path $projLeakBoth '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projLeakBoth '.env') "BOTH_SECRET=bothvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projLeakBoth 'notes.txt') "leaked: bothvalue1234567890`r`n"
    & git -C $projLeakBoth add notes.txt 2>$null | Out-Null
    $r = Fire -Cwd $projLeakBoth
    Check 'leak in both working tree and index is reported exactly once (deduped)' (@($r.Out -split "`n" | Where-Object { $_ -like '*BOTH_SECRET*notes.txt*' }).Count -eq 1) $r.Out

    # Cleaned AND re-staged - true negative, must NOT be flagged.
    $projClean = New-GitProj 'LeakCleanedRestaged'
    Write-Utf8 (Join-Path $projClean '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projClean '.env') "CLEANED_SECRET=cleanedvalue1234567890`r`n"
    Write-Utf8 (Join-Path $projClean 'notes.txt') "clean`r`n"
    Add-Commit $projClean 'seed clean'
    Write-Utf8 (Join-Path $projClean 'notes.txt') "leaked: cleanedvalue1234567890`r`n"
    & git -C $projClean add notes.txt 2>$null | Out-Null
    Write-Utf8 (Join-Path $projClean 'notes.txt') "clean again`r`n"
    & git -C $projClean add notes.txt 2>$null | Out-Null
    $r = Fire -Cwd $projClean
    Check 'cleaned and re-staged file is NOT flagged as a leak' ($r.Out -notlike '*CLEANED_SECRET*appears in a git-tracked file*') $r.Out

    # Nested file path.
    $projNested = New-GitProj 'LeakNestedPath'
    Write-Utf8 (Join-Path $projNested '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projNested '.env') "NESTED_LEAK_TOKEN=nestedvalue1234567890`r`n"
    New-Item -ItemType Directory -Path (Join-Path $projNested 'src\deep\dir') -Force | Out-Null
    Write-Utf8 (Join-Path $projNested 'src\deep\dir\config.txt') "leaked: nestedvalue1234567890`r`n"
    Add-Commit $projNested 'nested leak'
    $r = Fire -Cwd $projNested
    Check 'nested tracked file leak is detected with relative path' ($r.Out -match 'src[/\\]deep[/\\]dir[/\\]config\.txt') $r.Out

    # Path containing spaces (project root and file name both).
    $projSpace = New-GitProj 'Leak With Space'
    Write-Utf8 (Join-Path $projSpace '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $projSpace '.env') "SPACE_LEAK_TOKEN=spacevalue1234567890`r`n"
    Write-Utf8 (Join-Path $projSpace 'my notes.txt') "leaked: spacevalue1234567890`r`n"
    Add-Commit $projSpace 'space leak'
    $r = Fire -Cwd $projSpace
    Check 'tracked file leak is detected when project/file paths contain spaces' ($r.Out -like '*SPACE_LEAK_TOKEN*appears in a git-tracked file*my notes.txt*') $r.Out
    Check 'no secret value ever appears in output or stderr (leak regression block)' (
        $r.Out -notlike '*spacevalue1234567890*' -and $r.Err -notlike '*spacevalue1234567890*'
    ) ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- outgoing-commit scan: the actual push-safety boundary (confirmed gap) ---' -ForegroundColor Cyan

    # Baseline sanity: a secret committed and pushed with no cleanup at all
    # must still be caught (the simplest outgoing case).
    $outBasic = New-PushableRepo 'OutgoingBasic'
    Write-Utf8 (Join-Path $outBasic '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outBasic 'baseline'
    Push-Repo $outBasic
    Write-Utf8 (Join-Path $outBasic '.env') "BASIC_OUTGOING_SECRET=basicoutgoingvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outBasic 'leak.txt') "leak: basicoutgoingvalue1234567890`r`n"
    Add-Commit $outBasic 'introduce a leak, never cleaned'
    $rBasic = FireGitPrePush -Cwd $outBasic -StdinText (Get-RefUpdateLine -Repo $outBasic)
    Check 'basic outgoing leak (no cleanup) is detected' ($rBasic.Exit -eq 1 -and $rBasic.Err -match 'BASIC_OUTGOING_SECRET' -and $rBasic.Err -match 'outgoing commit') $rBasic.Err

    # Secret in an OLDER outgoing commit, with a later cleanup commit also in
    # the same outgoing range - both worktree AND index are clean, only
    # history still carries it (the confirmed gap: neither `git grep` nor
    # `git grep --cached` sees this; also covers "introduced and removed
    # entirely within the outgoing range", since neither commit was ever
    # previously pushed).
    $outOlder = New-PushableRepo 'OutgoingOlderPlusCleanup'
    Write-Utf8 (Join-Path $outOlder '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outOlder 'baseline'
    Push-Repo $outOlder
    Write-Utf8 (Join-Path $outOlder '.env') "OLDER_COMMIT_SECRET=oldercommitvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outOlder 'leaked.txt') "leak: oldercommitvalue1234567890`r`n"
    Add-Commit $outOlder 'introduce leak (older outgoing commit)'
    Write-Utf8 (Join-Path $outOlder 'leaked.txt') "cleaned`r`n"
    Add-Commit $outOlder 'cleanup commit (also outgoing, tree now clean)'
    Check 'worktree and index are already clean before the push check' (@(& git -C $outOlder status --porcelain).Count -eq 0)
    $rOlder = FireGitPrePush -Cwd $outOlder -StdinText (Get-RefUpdateLine -Repo $outOlder)
    Check 'secret in an older outgoing commit is detected despite a clean later cleanup commit' ($rOlder.Exit -eq 1 -and $rOlder.Err -match 'OLDER_COMMIT_SECRET' -and $rOlder.Err -match 'outgoing commit') $rOlder.Err
    Check 'older-outgoing-commit leak: value never printed' ($rOlder.Err -notlike '*oldercommitvalue1234567890*') $rOlder.Err

    # A clean outgoing range must stay silent (no false blocker).
    $outClean = New-PushableRepo 'OutgoingCleanRange'
    Write-Utf8 (Join-Path $outClean '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outClean 'baseline'
    Push-Repo $outClean
    Write-Utf8 (Join-Path $outClean '.env') "CLEANRANGE_TOKEN=cleanrangevalue1234567890`r`n"
    Write-Utf8 (Join-Path $outClean 'notes.txt') "nothing secret in this outgoing range`r`n"
    Add-Commit $outClean 'unrelated, clean change'
    $rClean = FireGitPrePush -Cwd $outClean -StdinText (Get-RefUpdateLine -Repo $outClean)
    Check 'clean outgoing range never blocks' ($rClean.Exit -eq 0) $rClean.Err

    # New branch push: remote sha is all-zero. Scoped to commits not already
    # on any remote-tracking ref, so the already-pushed baseline is not rescanned.
    $outNewBranch = New-PushableRepo 'OutgoingNewBranch'
    Write-Utf8 (Join-Path $outNewBranch '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outNewBranch 'baseline'
    Push-Repo $outNewBranch
    & git -C $outNewBranch checkout -q -b feature
    Write-Utf8 (Join-Path $outNewBranch '.env') "NEWBRANCH_SECRET=newbranchvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outNewBranch 'feature.txt') "leak: newbranchvalue1234567890`r`n"
    Add-Commit $outNewBranch 'feature work with a leak'
    $stdinNewBranch = Get-RefUpdateLine -Repo $outNewBranch -Branch 'feature' -RemoteSha ('0' * 40)
    $rNewBranch = FireGitPrePush -Cwd $outNewBranch -StdinText $stdinNewBranch
    Check 'new branch push (remote sha all-zero) detects a leak in its only commit' ($rNewBranch.Exit -eq 1 -and $rNewBranch.Err -match 'NEWBRANCH_SECRET') $rNewBranch.Err

    # Deletion push: local sha is all-zero - nothing is being pushed for that
    # ref, so it contributes no commits to scan and must never crash.
    $outDelete = New-PushableRepo 'OutgoingDeletion'
    Write-Utf8 (Join-Path $outDelete '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outDelete 'baseline'
    Push-Repo $outDelete
    $deleteStdin = 'refs/heads/gone ' + ('0' * 40) + ' refs/heads/gone ' + ((& git -C $outDelete rev-parse HEAD | Out-String).Trim()) + "`n"
    $rDelete = FireGitPrePush -Cwd $outDelete -StdinText $deleteStdin
    Check 'deletion push (local sha all-zero) does not crash and scans nothing for that ref' ($rDelete.Exit -eq 0) $rDelete.Err

    # Force-push/non-fast-forward: the range is exactly the NEW divergent
    # commit(s), regardless of ancestry. A replaced commit that is no longer
    # reachable from local must not be rescanned (proves cleaned/replaced
    # history that is not part of the pushed result creates no false blocker)...
    $outForceClean = New-PushableRepo 'OutgoingForceCleanDivergence'
    Write-Utf8 (Join-Path $outForceClean '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outForceClean 'baseline'
    Write-Utf8 (Join-Path $outForceClean '.env') "FORCE_REPLACED_SECRET=forcereplacedvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outForceClean 'old.txt') "leak: forcereplacedvalue1234567890`r`n"
    Add-Commit $outForceClean 'commit A (has a leak, gets replaced)'
    Push-Repo $outForceClean
    $shaA = ((& git -C $outForceClean rev-parse HEAD) | Out-String).Trim()
    & git -C $outForceClean reset -q --hard HEAD~1
    Write-Utf8 (Join-Path $outForceClean 'new.txt') "unrelated, no secret`r`n"
    Add-Commit $outForceClean 'commit B (diverged, clean)'
    $rForceClean = FireGitPrePush -Cwd $outForceClean -StdinText (Get-RefUpdateLine -Repo $outForceClean -RemoteSha $shaA)
    Check 'force-push: the replaced (no longer reachable) commit is not rescanned' ($rForceClean.Exit -eq 0) $rForceClean.Err
    # ...but a leak IN the new divergent commit is still caught.
    $outForceLeak = New-PushableRepo 'OutgoingForceLeakDivergence'
    Write-Utf8 (Join-Path $outForceLeak '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outForceLeak 'baseline'
    Write-Utf8 (Join-Path $outForceLeak 'a.txt') "commit A content`r`n"
    Add-Commit $outForceLeak 'commit A (pushed, no secret yet)'
    Push-Repo $outForceLeak
    $shaA2 = ((& git -C $outForceLeak rev-parse HEAD) | Out-String).Trim()
    & git -C $outForceLeak reset -q --hard HEAD~1
    Write-Utf8 (Join-Path $outForceLeak '.env') "FORCE_LEAK_SECRET=forceleakvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outForceLeak 'c.txt') "leak: forceleakvalue1234567890`r`n"
    Add-Commit $outForceLeak 'commit C (diverged, has a leak)'
    $rForceLeak = FireGitPrePush -Cwd $outForceLeak -StdinText (Get-RefUpdateLine -Repo $outForceLeak -RemoteSha $shaA2)
    Check 'force-push/non-fast-forward: a leak in the new divergent commit is still detected' ($rForceLeak.Exit -eq 1 -and $rForceLeak.Err -match 'FORCE_LEAK_SECRET') $rForceLeak.Err

    # Multiple ref-update lines in ONE invocation (e.g. `git push --all`):
    # both refs' outgoing commits are scanned and their leaks reported.
    $outMulti = New-PushableRepo 'OutgoingMultiRef'
    Write-Utf8 (Join-Path $outMulti '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outMulti 'baseline'
    Push-Repo $outMulti
    Write-Utf8 (Join-Path $outMulti '.env') "MULTIREF_SECRET_A=multirefvalueA1234567890`r`nMULTIREF_SECRET_B=multirefvalueB1234567890`r`n"
    & git -C $outMulti checkout -q -b branchA
    Write-Utf8 (Join-Path $outMulti 'a.txt') "leak: multirefvalueA1234567890`r`n"
    Add-Commit $outMulti 'branchA leak'
    $stdinBranchA = Get-RefUpdateLine -Repo $outMulti -Branch 'branchA' -RemoteSha ('0' * 40)
    & git -C $outMulti checkout -q main
    & git -C $outMulti checkout -q -b branchB
    Write-Utf8 (Join-Path $outMulti 'b.txt') "leak: multirefvalueB1234567890`r`n"
    Add-Commit $outMulti 'branchB leak'
    $stdinBranchB = Get-RefUpdateLine -Repo $outMulti -Branch 'branchB' -RemoteSha ('0' * 40)
    $rMulti = FireGitPrePush -Cwd $outMulti -StdinText ($stdinBranchA + $stdinBranchB)
    Check 'multiple ref-update lines in one invocation: both leaks are detected' ($rMulti.Exit -eq 1 -and $rMulti.Err -match 'MULTIREF_SECRET_A' -and $rMulti.Err -match 'MULTIREF_SECRET_B') $rMulti.Err

    # Nested path with spaces, inside an outgoing commit.
    $outNested = New-PushableRepo 'OutgoingNestedSpace'
    Write-Utf8 (Join-Path $outNested '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outNested 'baseline'
    Push-Repo $outNested
    Write-Utf8 (Join-Path $outNested '.env') "NESTED_SPACE_SECRET=nestedspacevalue1234567890`r`n"
    New-Item -ItemType Directory -Path (Join-Path $outNested 'deep dir\sub folder') -Force | Out-Null
    Write-Utf8 (Join-Path $outNested 'deep dir\sub folder\my notes.txt') "leak: nestedspacevalue1234567890`r`n"
    Add-Commit $outNested 'nested leak with spaces'
    $rNested = FireGitPrePush -Cwd $outNested -StdinText (Get-RefUpdateLine -Repo $outNested)
    Check 'nested path with spaces in an outgoing commit is detected' ($rNested.Exit -eq 1 -and $rNested.Err -match 'NESTED_SPACE_SECRET' -and $rNested.Err -match [regex]::Escape('deep dir/sub folder/my notes.txt')) $rNested.Err
    Check 'nested/spaced outgoing leak: value never printed' ($rNested.Err -notlike '*nestedspacevalue1234567890*') $rNested.Err

    # Secret VALUE starting with '-' (a PEM header, a Django-style key, ...):
    # `git grep -F <value> <shas>` would parse a dash-leading pattern as an
    # unknown option and error out; the outgoing scan must still detect it as
    # a real leak, not fail closed with an "unscannable history" message
    # (regression test for the git-grep argument-injection fix).
    $outDash = New-PushableRepo 'OutgoingDashPrefixedValue'
    Write-Utf8 (Join-Path $outDash '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outDash 'baseline'
    Push-Repo $outDash
    Write-Utf8 (Join-Path $outDash '.env') "DASH_PREFIX_SECRET=-dashprefixvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outDash 'leak.txt') "leak: -dashprefixvalue1234567890`r`n"
    Add-Commit $outDash 'introduce a dash-prefixed secret value leak'
    $rDash = FireGitPrePush -Cwd $outDash -StdinText (Get-RefUpdateLine -Repo $outDash)
    Check 'dash-prefixed secret value in an outgoing commit is detected as a leak' ($rDash.Exit -eq 1 -and $rDash.Err -match 'DASH_PREFIX_SECRET' -and $rDash.Err -match 'outgoing commit') $rDash.Err
    Check 'dash-prefixed leak is NOT reported as an unscannable/incomplete outgoing scan' ($rDash.Err -notmatch 'could not be fully scanned') $rDash.Err
    Check 'dash-prefixed outgoing leak: value never printed' ($rDash.Err -notlike '*dashprefixvalue1234567890*') $rDash.Err

    # Negative control: the same shape WITHOUT the leading '-' must also be
    # detected, proving the checks above are not trivially true regardless of
    # the dash.
    $outNoDash = New-PushableRepo 'OutgoingNoDashControl'
    Write-Utf8 (Join-Path $outNoDash '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $outNoDash 'baseline'
    Push-Repo $outNoDash
    Write-Utf8 (Join-Path $outNoDash '.env') "NODASH_CONTROL_SECRET=nodashcontrolvalue1234567890`r`n"
    Write-Utf8 (Join-Path $outNoDash 'leak.txt') "leak: nodashcontrolvalue1234567890`r`n"
    Add-Commit $outNoDash 'introduce a non-dash-prefixed secret value leak'
    $rNoDash = FireGitPrePush -Cwd $outNoDash -StdinText (Get-RefUpdateLine -Repo $outNoDash)
    Check 'non-dash-prefixed secret value in an outgoing commit is still detected (negative control)' ($rNoDash.Exit -eq 1 -and $rNoDash.Err -match 'NODASH_CONTROL_SECRET' -and $rNoDash.Err -match 'outgoing commit') $rNoDash.Err

    # =====================================================================
    Write-Host '--- outgoing-commit scan: real end-to-end git push (native pre-push chain) ---' -ForegroundColor Cyan
    $e2e = New-PushableRepo 'OutgoingRealPush'
    # Written in Ignore-Rules-Check's INSERTION order, not alphabetically: each `!`
    # negation must follow the broader `/.env.*` it un-ignores. A sorted list here
    # would be a genuinely broken ruleset (dead negations), so Ignore-Rules-Check
    # would repair it and block first - and this test would stop exercising the
    # Secrets-Check outgoing-commit path it exists to prove.
    # This fixture's whole point is a repository that ALREADY carries the full
    # required set, so the pre-push chain reaches Secrets-Check with nothing for
    # Ignore-Rules-Check to add. It must therefore track the set in
    # Ignore-Rules-Check.ps1 exactly - it went four patterns short on 2026-09-19
    # and the chain stopped short of the assertion below.
    $e2eIgnore = @(
        '/.ai/', '/.specify/', '/specs/', '/secrets.md', '/explain-AI.md', '/reference.md',
        '/CLAUDE.md', '/AGENTS.md',
        '/.agents/', '/.claude/', '/.kiro/', '/.codex/', '/.cursor/', '/.cline/', '/graphify-out/',
        '/.codebase-memory/', '/plans/',
        '.ignoreme', '**/.ignoreme', '/.env', '/.env.*', '!/.env.example', '!/.env.sample',
        '!/.env.template', '!/.env.dist'
    ) -join "`r`n"
    Write-Utf8 (Join-Path $e2e '.gitignore') ($e2eIgnore + "`r`n")
    Add-Commit $e2e 'baseline with the full required ignore ruleset'
    Push-Repo $e2e
    $ignoreHook = Join-Path (Split-Path -Parent (Split-Path -Parent $Hook)) 'Ignore-Rules-Check\Ignore-Rules-Check.ps1'
    & $InstallScript -CustomHook $ignoreHook -Events @('Stop') -TargetProject $e2e -CodexOnly *> $null
    Write-Utf8 (Join-Path $e2e '.env') "E2E_REALPUSH_SECRET=e2erealpushvalue1234567890`r`n"
    Write-Utf8 (Join-Path $e2e 'leak.txt') "leak: e2erealpushvalue1234567890`r`n"
    Add-Commit $e2e 'introduce a real leak commit'
    Write-Utf8 (Join-Path $e2e 'leak.txt') "cleaned`r`n"
    Add-Commit $e2e 'clean it up in a later commit (still outgoing)'
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pushOutput = (& git -C $e2e push origin main 2>&1 | Out-String)
    $pushExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEap
    Check 'real end-to-end git push is rejected by the native pre-push chain' ($pushExit -ne 0 -and $pushOutput -match 'SECRETS CHECK' -and $pushOutput -match 'outgoing commit') $pushOutput
    Check 'real end-to-end push: the secret value never appears in git''s output' ($pushOutput -notlike '*e2erealpushvalue1234567890*') $pushOutput

    # =====================================================================
    Write-Host '--- outgoing history: committed .env*/secrets.md later removed is still blocked (item 1) ---' -ForegroundColor Cyan

    # An outgoing commit adds a real .env with a secret, a later outgoing
    # commit untracks it - the current-file scan excludes .env, but the
    # outgoing-history scan must NOT, so the leak is caught.
    $envHist = New-PushableRepo 'OutgoingEnvHistory'
    Write-Utf8 (Join-Path $envHist '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $envHist 'baseline'
    Push-Repo $envHist
    Write-Utf8 (Join-Path $envHist '.env') "ENVHIST_SECRET=envhistvalue1234567890`r`n"
    & git -C $envHist add -f .env 2>$null | Out-Null
    Add-Commit $envHist 'oops commit .env'
    & git -C $envHist rm -q --cached .env 2>$null | Out-Null
    Write-Utf8 (Join-Path $envHist '.env') "ENVHIST_SECRET=envhistvalue1234567890`r`n"
    Add-Commit $envHist 'untrack .env (local copy kept, ignored)'
    $rEnvHist = FireGitPrePush -Cwd $envHist -StdinText (Get-RefUpdateLine -Repo $envHist)
    Check 'outgoing commit adds .env then removes it: push blocked' ($rEnvHist.Exit -eq 1 -and $rEnvHist.Err -match 'ENVHIST_SECRET' -and $rEnvHist.Err -match 'outgoing commit') $rEnvHist.Err
    Check 'outgoing .env-history leak: value never printed' ($rEnvHist.Err -notlike '*envhistvalue1234567890*') $rEnvHist.Err

    # Nested .env.local, later removed.
    $envNestedHist = New-PushableRepo 'OutgoingEnvNestedHistory'
    Write-Utf8 (Join-Path $envNestedHist '.gitignore') "**/.env*`nsecrets.md`n"
    Add-Commit $envNestedHist 'baseline'
    Push-Repo $envNestedHist
    New-Item -ItemType Directory -Path (Join-Path $envNestedHist 'apps\api') -Force | Out-Null
    Write-Utf8 (Join-Path $envNestedHist 'apps\api\.env.local') "NESTED_ENVHIST_SECRET=nestedenvhistvalue1234567890`r`n"
    & git -C $envNestedHist add -f apps/api/.env.local 2>$null | Out-Null
    Add-Commit $envNestedHist 'oops commit nested .env.local'
    & git -C $envNestedHist rm -q --cached apps/api/.env.local 2>$null | Out-Null
    Write-Utf8 (Join-Path $envNestedHist 'apps\api\.env.local') "NESTED_ENVHIST_SECRET=nestedenvhistvalue1234567890`r`n"
    Add-Commit $envNestedHist 'untrack nested .env.local'
    $rNestedHist = FireGitPrePush -Cwd $envNestedHist -StdinText (Get-RefUpdateLine -Repo $envNestedHist)
    Check 'outgoing commit adds nested .env.local then removes it: push blocked' ($rNestedHist.Exit -eq 1 -and $rNestedHist.Err -match 'NESTED_ENVHIST_SECRET' -and $rNestedHist.Err -match 'apps[/\\]api[/\\]\.env\.local') $rNestedHist.Err

    # secrets.md committed then removed.
    $secHist = New-PushableRepo 'OutgoingSecretsMdHistory'
    Write-Utf8 (Join-Path $secHist '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $secHist '.env') "SECMD_SECRET=secmdvalue1234567890`r`n"
    Add-Commit $secHist 'baseline'
    Push-Repo $secHist
    Write-Utf8 (Join-Path $secHist 'secrets.md') "# Secrets`n`n## SECMD_SECRET`n- Value: secmdvalue1234567890`n"
    & git -C $secHist add -f secrets.md 2>$null | Out-Null
    Add-Commit $secHist 'oops commit secrets.md'
    & git -C $secHist rm -q --cached secrets.md 2>$null | Out-Null
    Write-Utf8 (Join-Path $secHist 'secrets.md') "# Secrets`n`n## SECMD_SECRET`n- Value: secmdvalue1234567890`n"
    Add-Commit $secHist 'untrack secrets.md'
    $rSecHist = FireGitPrePush -Cwd $secHist -StdinText (Get-RefUpdateLine -Repo $secHist)
    Check 'outgoing commit adds secrets.md then removes it: push blocked' ($rSecHist.Exit -eq 1 -and $rSecHist.Err -match 'SECMD_SECRET' -and $rSecHist.Err -match 'secrets\.md') $rSecHist.Err
    Check 'outgoing secrets.md-history leak: value never printed' ($rSecHist.Err -notlike '*secmdvalue1234567890*') $rSecHist.Err

    # A current, ignored, local-only .env (never committed) must NOT be
    # reported as an outgoing-history leak - the outgoing range is clean.
    $envLocalOnly = New-PushableRepo 'OutgoingEnvLocalOnly'
    Write-Utf8 (Join-Path $envLocalOnly '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $envLocalOnly 'readme.txt') 'nothing secret'
    Add-Commit $envLocalOnly 'baseline'
    Push-Repo $envLocalOnly
    Write-Utf8 (Join-Path $envLocalOnly '.env') "LOCALONLY_SECRET=localonlyvalue1234567890`r`n"
    Write-Utf8 (Join-Path $envLocalOnly 'notes.txt') 'a clean outgoing change'
    Add-Commit $envLocalOnly 'clean outgoing commit'
    $rLocalOnly = FireGitPrePush -Cwd $envLocalOnly -StdinText (Get-RefUpdateLine -Repo $envLocalOnly)
    Check 'a current ignored local-only .env is NOT a false outgoing-history leak' ($rLocalOnly.Exit -eq 0) $rLocalOnly.Err

    # =====================================================================
    Write-Host '--- outgoing history: incomplete scans fail closed (item 2) ---' -ForegroundColor Cyan

    # >500 outgoing commits with a secret BEYOND the former 500 cutoff must
    # still be blocked (no security-skipping cap). Build the leak first (oldest
    # outgoing commit), then pile 520 trivial commits on top.
    $bigLeak = New-PushableRepo 'OutgoingBigRangeLeak'
    Write-Utf8 (Join-Path $bigLeak '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $bigLeak 'baseline'
    Push-Repo $bigLeak
    Write-Utf8 (Join-Path $bigLeak '.env') "BIGRANGE_SECRET=bigrangevalue1234567890`r`n"
    Write-Utf8 (Join-Path $bigLeak 'deep-leak.txt') "leak: bigrangevalue1234567890`r`n"
    Add-Commit $bigLeak 'the leak, at the very bottom of a 520-deep outgoing range'
    # Empty filler keeps the outgoing range >500 (exercising the uncapped,
    # batched rev-list/grep path) without a file write + `git add` + tree diff
    # per commit. deep-leak.txt from the bottom commit persists in every later
    # tree, so the batched grep still finds it and detection is unchanged.
    for ($n = 1; $n -le 520; $n++) { & git -C $bigLeak commit --allow-empty -q -m "trivial $n" 2>$null | Out-Null }
    $rBigLeak = FireGitPrePush -Cwd $bigLeak -StdinText (Get-RefUpdateLine -Repo $bigLeak)
    Check '>500 outgoing commits with a leak beyond the former cutoff is still blocked' ($rBigLeak.Exit -eq 1 -and $rBigLeak.Err -match 'BIGRANGE_SECRET') $rBigLeak.Err

    # >500 clean outgoing commits must still be allowed (no false block, no
    # duplicate findings from batching).
    $bigClean = New-PushableRepo 'OutgoingBigRangeClean'
    Write-Utf8 (Join-Path $bigClean '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $bigClean '.env') "BIGCLEAN_SECRET=bigcleanvalue1234567890`r`n"
    Add-Commit $bigClean 'baseline'
    Push-Repo $bigClean
    # Empty filler: a >500-commit clean outgoing range still exercises the
    # batched rev-list/grep (no false block, no duplicate findings) without the
    # per-commit file write + `git add` + tree diff.
    for ($n = 1; $n -le 520; $n++) { & git -C $bigClean commit --allow-empty -q -m "trivial $n" 2>$null | Out-Null }
    $rBigClean = FireGitPrePush -Cwd $bigClean -StdinText (Get-RefUpdateLine -Repo $bigClean)
    Check '>500 clean outgoing commits are allowed (no false block)' ($rBigClean.Exit -eq 0) $rBigClean.Err

    # An unresolvable remote SHA (not present locally) must fail closed - block
    # with a safe incomplete-scan message, never treated as clean.
    $unresolvable = New-PushableRepo 'OutgoingUnresolvableRemote'
    Write-Utf8 (Join-Path $unresolvable '.gitignore') ".env`nsecrets.md`n"
    Add-Commit $unresolvable 'baseline'
    Push-Repo $unresolvable
    Write-Utf8 (Join-Path $unresolvable 'notes.txt') 'clean'
    Add-Commit $unresolvable 'clean change'
    $fakeRemote = 'deadbeef' + ('0' * 32)
    $rUnresolvable = FireGitPrePush -Cwd $unresolvable -StdinText (Get-RefUpdateLine -Repo $unresolvable -RemoteSha $fakeRemote)
    Check 'unresolvable remote SHA fails closed (blocked with incomplete-scan message)' ($rUnresolvable.Exit -eq 1 -and $rUnresolvable.Err -match 'could not be fully scanned' -and $rUnresolvable.Err -match 'not resolvable locally') $rUnresolvable.Err
    Check 'incomplete-scan block never prints a secret value' ($rUnresolvable.Err -notlike '*bigrangevalue*' -and $rUnresolvable.Err -notlike '*bigcleanvalue*') $rUnresolvable.Err
