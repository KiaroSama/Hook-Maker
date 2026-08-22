# Dot-sourced scenario block of Test-HookStatusScan.ps1: TRAVERSAL - an
# arbitrary ancestor root finds nested Claude/Codex/Kiro/git hooks; a direct
# runtime subtree (.claude and .kiro shapes) finds the NEAREST related
# settings by bounded upward lookup; Kiro per-hook-file registration
# directories are recognised by position (and a plain 'hooks' directory is
# not); NO default depth cap (-MaxDepth is the only thing that caps it);
# access-denied and a directory vanishing mid-scan are isolated, never fatal;
# reparse points - including a '.git' junction - are never followed; noisily
# spelled roots canonicalize to the same scan; and a full-drive-shaped
# fixture is scanned from its root with no depth hint.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Later blocks reuse the fixture trees built
# here ($ancestor, $permRoot/$enforced). Run scripts\Test-HookStatusScan.ps1
# instead.

    # =====================================================================
    # Traversal
    # =====================================================================
    Write-Host '--- an arbitrary ancestor root finds nested hooks ---' -ForegroundColor Cyan
    $ancestor = New-Dir (Join-Path $Work 'Ancestor')
    $nested = New-Dir (Join-Path $ancestor 'team\group\projects\WebApp')
    New-ClaudeHook -ProjectRoot $nested -HookName 'ZZZ-Nested-Claude' | Out-Null
    New-CodexHook -ProjectRoot (New-Dir (Join-Path $ancestor 'team\other\ApiApp')) -HookName 'ZZZ-Nested-Codex' | Out-Null
    New-GitHookRepo -RepositoryRoot (New-Dir (Join-Path $ancestor 'team\group\projects\WebApp')) | Out-Null

    $scan = Invoke-Scan -Root $ancestor
    Check 'a scan from an arbitrary ancestor exits 0' ($scan.Exit -eq 0) $scan.Err
    Check 'a deeply nested Claude hook is found from the ancestor' (Test-FoundTarget -Result $scan.Result -Fragment 'ZZZ-Nested-Claude.ps1')
    Check 'a deeply nested Codex hook is found from the ancestor' (Test-FoundTarget -Result $scan.Result -Fragment 'ZZZ-Nested-Codex.ps1')
    Check 'a nested native git hook is found from the ancestor' (Test-FoundTarget -Result $scan.Result -Fragment 'pre-push')
    Check 'a complete scan reports complete coverage' ($scan.Result.coverage.complete -eq $true) (
        (@($scan.Result.coverage.inaccessible) + @($scan.Result.coverage.skippedReparse)) -join ',')

    Write-Host '--- a direct runtime subtree finds the nearest related settings ---' -ForegroundColor Cyan
    $direct = New-Dir (Join-Path $Work 'DirectProject')
    $directRuntime = New-Dir (Join-Path $direct '.claude\hooks\Hook-Maker\ZZZ-Direct')
    $directScript = Join-Path $directRuntime 'ZZZ-Direct.ps1'
    Write-Utf8 -Path $directScript -Content '# direct runtime'
    Write-Utf8 -Path (Join-Path $direct '.claude\settings.local.json') -Content (@{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $directScript + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    New-GitHookRepo -RepositoryRoot $direct -HookName 'pre-commit' | Out-Null

    # -ScanRoot IS the runtime folder: only an upward lookup can find the
    # registration that names it.
    $directScan = Invoke-Scan -Root (Join-Path $direct '.claude\hooks\Hook-Maker')
    Check 'scanning a runtime subtree exits 0' ($directScan.Exit -eq 0) $directScan.Err
    Check 'scanning ...\.claude\hooks\Hook-Maker still finds its Claude registration' (
        Test-FoundTarget -Result $directScan.Result -Fragment 'ZZZ-Direct.ps1') (
        ($directScan.Result | ConvertTo-Json -Depth 6))
    Check 'the upward lookup also reaches the enclosing git repository' (
        [int]$directScan.Result.counts.gitRepositories -eq 1) ([string]$directScan.Result.counts.gitRepositories)
    Check 'the upward lookup does not wander outside into sibling projects' (
        -not (Test-FoundTarget -Result $directScan.Result -Fragment 'ZZZ-Nested-Claude.ps1'))
    Check 'the registration found upward is recorded exactly once' (
        @(@($directScan.Result.findings) | Where-Object { @($_.clients).Count -gt 0 }).Count -eq 1)

    Write-Host '--- a Kiro runtime subtree resolves its enclosing project context ---' -ForegroundColor Cyan
    # Kiro's runtime root is .kiro\hook-runtime\Hook-Maker (deliberately NOT
    # .kiro\hooks, which is Kiro's own config-discovery root). A scan aimed at
    # that tree must resolve the enclosing project exactly as the .claude case
    # above does; before .kiro became an upward marker it resolved NOTHING, so
    # the enclosing registration and git repository were both invisible.
    $kiroProj = New-Dir (Join-Path $Work 'KiroRuntimeProject')
    $kiroRuntimeScript = Join-Path $kiroProj '.kiro\hook-runtime\Hook-Maker\ZZZ-Kiro\ZZZ-Kiro.ps1'
    Write-Utf8 -Path $kiroRuntimeScript -Content '# kiro runtime'
    New-ClaudeHook -ProjectRoot $kiroProj -HookName 'ZZZ-Kiro-Enclosing' | Out-Null
    New-GitHookRepo -RepositoryRoot $kiroProj -HookName 'pre-commit' | Out-Null
    # ...and the Kiro registration that names that runtime. It lives in a
    # DIFFERENT directory from the runtime (.kiro\hooks vs .kiro\hook-runtime),
    # so only the upward hop can connect the two.
    New-KiroHook -ProjectRoot $kiroProj -HookName 'ZZZ-Kiro-Upward' -TargetScript $kiroRuntimeScript | Out-Null

    $kiroScan = Invoke-Scan -Root (Join-Path $kiroProj '.kiro\hook-runtime\Hook-Maker')
    Check 'scanning a .kiro runtime subtree exits 0' ($kiroScan.Exit -eq 0) $kiroScan.Err
    Check 'scanning ...\.kiro\hook-runtime\Hook-Maker finds the enclosing registration' (
        Test-FoundTarget -Result $kiroScan.Result -Fragment 'ZZZ-Kiro-Enclosing.ps1') (
        ($kiroScan.Result | ConvertTo-Json -Depth 6))
    Check 'the .kiro upward lookup also reads the enclosing .kiro\hooks registrations' (
        @(@($kiroScan.Result.findings) | Where-Object {
                @(@($_.clients) | Where-Object { [string]$_.client -eq 'kiro' }).Count -gt 0 }).Count -eq 1) (
        ($kiroScan.Result.findings | ConvertTo-Json -Depth 6))
    Check 'the .kiro upward lookup also reaches the enclosing git repository' (
        [int]$kiroScan.Result.counts.gitRepositories -eq 1) ([string]$kiroScan.Result.counts.gitRepositories)
    Check 'the .kiro upward lookup does not wander into sibling projects' (
        -not (Test-FoundTarget -Result $kiroScan.Result -Fragment 'ZZZ-Nested-Claude.ps1'))

    Write-Host '--- Kiro per-hook-file registrations are reached by the walk ---' -ForegroundColor Cyan
    # Kiro registers one JSON document per installation under .kiro\hooks
    # instead of a shared settings file, so the walk has to recognise the
    # DIRECTORY by position and open every *.json in it - and an unreadable one
    # has to degrade into partial coverage exactly like any other directory.
    $kiroWalkRoot = New-Dir (Join-Path $Work 'KiroWalkRoot')
    $kiroDeep = New-Dir (Join-Path $kiroWalkRoot 'org\team\Service')
    New-KiroHook -ProjectRoot $kiroDeep -HookName 'ZZZ-Kiro-Deep' | Out-Null
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $kiroWalkRoot 'org\other\Web')) -HookName 'ZZZ-Kiro-Sibling-Claude' | Out-Null
    # A directory called 'hooks' that is NOT under .kiro must never be treated
    # as a registration directory.
    Write-Utf8 -Path (Join-Path $kiroWalkRoot 'org\team\Service\hooks\decoy.json') -Content (@{
            version = 'v1'
            hooks   = @(@{ name = 'decoy'; trigger = 'Stop'; action = @{ type = 'command'; command = 'pwsh -File "C:\ZZZ-Kiro-Decoy.ps1"' } })
        } | ConvertTo-Json -Depth 20)

    $kiroWalkScan = Invoke-Scan -Root $kiroWalkRoot
    Check 'a nested Kiro registration is found from an arbitrary ancestor' (
        Test-FoundTarget -Result $kiroWalkScan.Result -Fragment 'ZZZ-Kiro-Deep.ps1') (
        ($kiroWalkScan.Result.findings | ConvertTo-Json -Depth 6))
    Check 'a sibling Claude project beside it is still found' (
        Test-FoundTarget -Result $kiroWalkScan.Result -Fragment 'ZZZ-Kiro-Sibling-Claude.ps1')
    Check 'a plain "hooks" directory outside .kiro is NOT read as a Kiro registration' (
        -not (Test-FoundTarget -Result $kiroWalkScan.Result -Fragment 'ZZZ-Kiro-Decoy.ps1')) (
        ($kiroWalkScan.Result.findings | ConvertTo-Json -Depth 6))

    $kiroDeniedProj = New-Dir (Join-Path $kiroWalkRoot 'org\team\Locked')
    New-KiroHook -ProjectRoot $kiroDeniedProj -HookName 'ZZZ-Kiro-Locked' | Out-Null
    $kiroDeniedEnforced = Deny-Directory -Path (Join-Path $kiroDeniedProj '.kiro\hooks')
    if ($kiroDeniedEnforced) {
        $kiroDeniedScan = Invoke-Scan -Root $kiroWalkRoot
        Check 'an unreadable .kiro\hooks directory does not fail the scan' (
            $kiroDeniedScan.Exit -eq 0) $kiroDeniedScan.Err
        Check 'an unreadable .kiro\hooks directory is recorded in coverage.inaccessible' (
            @(@($kiroDeniedScan.Result.coverage.inaccessible) | Where-Object { $_ -like '*Locked*' }).Count -ge 1) (
            (@($kiroDeniedScan.Result.coverage.inaccessible)) -join ',')
        Check 'and the scan reports partial coverage, never a false all-clear' (
            $kiroDeniedScan.Result.coverage.complete -eq $false -and
            [string]$kiroDeniedScan.Result.overall -eq 'partial') (
            'complete=' + [string]$kiroDeniedScan.Result.coverage.complete + ' overall=' + [string]$kiroDeniedScan.Result.overall)
        Check 'and the readable Kiro registration beside it is still reported' (
            Test-FoundTarget -Result $kiroDeniedScan.Result -Fragment 'ZZZ-Kiro-Deep.ps1')
    }
    else {
        Write-Host '[SKIP] deny ACL was not enforceable for this account; Kiro partial-coverage assertions skipped' -ForegroundColor Yellow
    }

    Write-Host '--- no default depth cap ---' -ForegroundColor Cyan
    $deepRoot = New-Dir (Join-Path $Work 'DeepTree')
    $deep = $deepRoot
    for ($i = 1; $i -le 30; $i++) { $deep = New-Dir (Join-Path $deep ('level' + $i)) }
    New-ClaudeHook -ProjectRoot $deep -HookName 'ZZZ-Deep-30' | Out-Null

    $deepScan = Invoke-Scan -Root $deepRoot
    Check 'a 30-level deep hook is found with NO depth hint' (
        Test-FoundTarget -Result $deepScan.Result -Fragment 'ZZZ-Deep-30.ps1') (
        'directories=' + [string]$deepScan.Result.counts.directories)
    $cappedScan = Invoke-Scan -Root $deepRoot -MaxDepth 3
    Check '-MaxDepth 3 does NOT reach the 30-level hook (the cap is opt-in only)' (
        -not (Test-FoundTarget -Result $cappedScan.Result -Fragment 'ZZZ-Deep-30.ps1'))
    Check 'a depth-capped scan never claims complete coverage' ($cappedScan.Result.coverage.complete -eq $false)
    Check 'a depth-capped scan reports partial' ([string]$cappedScan.Result.overall -eq 'partial')

    Write-Host '--- an unreadable directory is isolated, never fatal ---' -ForegroundColor Cyan
    $permRoot = New-Dir (Join-Path $Work 'PermRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $permRoot 'before')) -HookName 'ZZZ-Before-Denied' | Out-Null
    $denied = New-Dir (Join-Path $permRoot 'denied-subtree')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $denied 'hidden')) -HookName 'ZZZ-Inside-Denied' | Out-Null
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $permRoot 'zafter')) -HookName 'ZZZ-After-Denied' | Out-Null
    $enforced = Deny-Directory -Path $denied

    $permScan = Invoke-Scan -Root $permRoot
    Check 'a scan containing an unreadable directory still exits 0' ($permScan.Exit -eq 0) $permScan.Err
    Check 'hooks before the unreadable directory are still found' (Test-FoundTarget -Result $permScan.Result -Fragment 'ZZZ-Before-Denied.ps1')
    Check 'hooks after the unreadable directory are still found' (Test-FoundTarget -Result $permScan.Result -Fragment 'ZZZ-After-Denied.ps1')
    if ($enforced) {
        Check 'the unreadable directory is recorded in coverage.inaccessible' (
            @(@($permScan.Result.coverage.inaccessible) | Where-Object { $_ -like '*denied-subtree*' }).Count -ge 1) (
            (@($permScan.Result.coverage.inaccessible)) -join ',')
        Check 'a scan with an unreadable directory never claims complete coverage' ($permScan.Result.coverage.complete -eq $false)
        Check 'a scan with an unreadable directory reports partial' ([string]$permScan.Result.overall -eq 'partial')
    }
    else {
        Write-Host '[SKIP] deny ACL was not enforceable for this account; inaccessible-path assertions skipped' -ForegroundColor Yellow
    }

    Write-Host '--- a directory that disappears mid-scan is isolated ---' -ForegroundColor Cyan
    # A genuine race: a large tree is scanned while a subtree is deleted under
    # it. Whether or not the race lands, the invariant asserted is the same one
    # the deterministic access-denied fixture above proves - a directory the
    # walk cannot read must never abort the run.
    $raceRoot = New-Dir (Join-Path $Work 'RaceRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $raceRoot 'keep')) -HookName 'ZZZ-Race-Keep' | Out-Null
    $doomed = New-Dir (Join-Path $raceRoot 'zdoomed')
    for ($i = 0; $i -lt 60; $i++) { New-Dir (Join-Path $doomed ('filler' + $i + '\a\b\c')) | Out-Null }
    $async = Invoke-Scan -Root $raceRoot -Async
    Remove-Item -LiteralPath $doomed -Recurse -Force -ErrorAction SilentlyContinue
    $async.Process.WaitForExit()
    $raceResult = $null
    if (Test-Path -LiteralPath $async.ResultPath) { $raceResult = [System.IO.File]::ReadAllText($async.ResultPath) | ConvertFrom-Json }
    Check 'a directory vanishing mid-scan does not fail the run' ($async.Process.ExitCode -eq 0) (
        $(if (Test-Path -LiteralPath $async.ErrFile) { [System.IO.File]::ReadAllText($async.ErrFile) } else { '' }))
    Check 'the surviving hook is still reported after a mid-scan deletion' (Test-FoundTarget -Result $raceResult -Fragment 'ZZZ-Race-Keep.ps1')

    Write-Host '--- reparse points are never followed ---' -ForegroundColor Cyan
    $loopRoot = New-Dir (Join-Path $Work 'LoopRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $loopRoot 'real')) -HookName 'ZZZ-Loop-Real' | Out-Null
    $junction = Join-Path $loopRoot 'loop-back'
    $junctionCreated = $false
    if ($IsWindows) {
        # A junction pointing at its own ancestor: following it is an infinite
        # tree. Directory junctions do not require elevation.
        & cmd.exe /c ('mklink /J "' + $junction + '" "' + $loopRoot + '"') *> $null
        $junctionCreated = (Test-Path -LiteralPath $junction)
        if ($junctionCreated) { [void]$script:Junctions.Add($junction) }
    }
    if ($junctionCreated) {
        $loopScan = Invoke-Scan -Root $loopRoot
        Check 'a junction loop does not hang or fail the scan' ($loopScan.Exit -eq 0) $loopScan.Err
        Check 'the junction is recorded as skipped, not traversed' (
            @(@($loopScan.Result.coverage.skippedReparse) | Where-Object { $_ -like '*loop-back*' }).Count -eq 1) (
            (@($loopScan.Result.coverage.skippedReparse)) -join ',')
        Check 'the real hook beside the junction is still found' (Test-FoundTarget -Result $loopScan.Result -Fragment 'ZZZ-Loop-Real.ps1')
        Check 'a scan that skipped a reparse point never claims complete coverage' ($loopScan.Result.coverage.complete -eq $false)
        Check 'the hook is reported exactly once, not once per loop iteration' (
            @(@($loopScan.Result.findings) | Where-Object { @($_.clients).Count -gt 0 }).Count -eq 1)
    }
    else {
        Write-Host '[SKIP] junction could not be created on this platform/account' -ForegroundColor Yellow
    }

    Write-Host '--- a ''.git'' JUNCTION is skipped, never dispatched to git handling ---' -ForegroundColor Cyan
    # '.git' is dispatched to Read-GitRepository by NAME; if the reparse guard
    # did not also cover that name, a '.git' directory junction would be
    # followed straight through to whatever it points at (core.hooksPath /
    # hooks read via an explicit path), reading outside the scan root entirely.
    $dotGitJunctionRoot = New-Dir (Join-Path $Work 'DotGitJunctionRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $dotGitJunctionRoot 'Proj')) -HookName 'ZZZ-Beside-DotGit-Junction' | Out-Null
    $externalGitTarget = New-Dir (Join-Path $Work 'ExternalGitTarget')
    Write-Utf8 -Path (Join-Path $externalGitTarget 'hooks\pre-push') -Content "#!/bin/sh`necho outside`n"
    $dotGitJunction = Join-Path $dotGitJunctionRoot '.git'
    $dotGitJunctionCreated = $false
    if ($IsWindows) {
        & cmd.exe /c ('mklink /J "' + $dotGitJunction + '" "' + $externalGitTarget + '"') *> $null
        $dotGitJunctionCreated = (Test-Path -LiteralPath $dotGitJunction)
        if ($dotGitJunctionCreated) { [void]$script:Junctions.Add($dotGitJunction) }
    }
    if ($dotGitJunctionCreated) {
        $dotGitJunctionScan = Invoke-Scan -Root $dotGitJunctionRoot
        Check 'a .git junction does not hang or fail the scan' ($dotGitJunctionScan.Exit -eq 0) $dotGitJunctionScan.Err
        Check 'the .git junction is recorded as skipped, not dispatched to Read-GitRepository' (
            @(@($dotGitJunctionScan.Result.coverage.skippedReparse) | Where-Object { $_ -like '*\.git' }).Count -eq 1) (
            (@($dotGitJunctionScan.Result.coverage.skippedReparse)) -join ',')
        Check 'nothing behind the .git junction was read (no native hook record produced)' (
            -not (Test-FoundTarget -Result $dotGitJunctionScan.Result -Fragment 'pre-push'))
        Check 'the ordinary hook beside the .git junction is still found' (
            Test-FoundTarget -Result $dotGitJunctionScan.Result -Fragment 'ZZZ-Beside-DotGit-Junction.ps1')
    }
    else {
        Write-Host '[SKIP] .git junction could not be created on this platform/account' -ForegroundColor Yellow
    }

    Write-Host '--- canonical duplicate paths are deduplicated ---' -ForegroundColor Cyan
    $dupRoot = New-Dir (Join-Path $Work 'DupRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $dupRoot 'Proj')) -HookName 'ZZZ-Dup' | Out-Null
    $straight = Invoke-Scan -Root $dupRoot
    # Same directory, spelled with a redundant .\ segment, a trailing separator,
    # a walk back up through .., and different casing.
    $noisy = Invoke-Scan -Root ((Join-Path $dupRoot '.\Proj\..\') + '\')
    Check 'a noisily-spelled root canonicalizes to the same scan' (
        @($straight.Result.findings).Count -eq @($noisy.Result.findings).Count -and @($noisy.Result.findings).Count -eq 1) (
        'straight=' + @($straight.Result.findings).Count + ' noisy=' + @($noisy.Result.findings).Count)
    Check 'a canonicalized rescan produces the same record id' (
        [string]@($straight.Result.findings)[0].id -eq [string]@($noisy.Result.findings)[0].id)
    $upperScan = Invoke-Scan -Root $dupRoot.ToUpperInvariant()
    Check 'an upper-cased root produces the same record id (case-insensitive keys)' (
        [string]@($upperScan.Result.findings)[0].id -eq [string]@($straight.Result.findings)[0].id)

    Write-Host '--- a full-drive-shaped fixture ---' -ForegroundColor Cyan
    # Hundreds of unrelated folders, nested projects, a permission hole and
    # hooks planted at four different depths - scanned from the root with no
    # depth hint, exactly as a real drive scan would be.
    $drive = New-Dir (Join-Path $Work 'FakeDrive')
    foreach ($top in @('Program Files', 'Users', 'Windows', 'Dev', 'Temp')) {
        $topDir = New-Dir (Join-Path $drive $top)
        for ($i = 0; $i -lt 12; $i++) {
            $branch = New-Dir (Join-Path $topDir ('pkg' + $i + '\src\lib\internal'))
            Write-Utf8 -Path (Join-Path $branch 'readme.txt') -Content 'unrelated'
            Write-Utf8 -Path (Join-Path $branch 'data.json') -Content '{"unrelated":true}'
        }
    }
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $drive 'Dev\Shallow')) -HookName 'ZZZ-Drive-Depth2' | Out-Null
    New-CodexHook -ProjectRoot (New-Dir (Join-Path $drive 'Users\me\code\Mid')) -HookName 'ZZZ-Drive-Depth4' | Out-Null
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $drive 'Program Files\a\b\c\d\e\Deep')) -HookName 'ZZZ-Drive-Depth7' -SettingsLeaf 'settings.json' | Out-Null
    New-GitHookRepo -RepositoryRoot (New-Dir (Join-Path $drive 'Windows\x\y\Repo')) -HookName 'pre-push' | Out-Null
    # A nested project INSIDE another project.
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $drive 'Dev\Shallow\vendor\Inner')) -HookName 'ZZZ-Drive-Nested' | Out-Null
    $driveDenied = New-Dir (Join-Path $drive 'Windows\System32-ish')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $driveDenied 'unreachable')) -HookName 'ZZZ-Drive-Unreachable' | Out-Null
    $driveEnforced = Deny-Directory -Path $driveDenied

    $driveScan = Invoke-Scan -Root $drive
    Check 'the drive-shaped scan exits 0' ($driveScan.Exit -eq 0) $driveScan.Err
    Check 'it inspected a realistic number of directories' ([int]$driveScan.Result.counts.directories -gt 200) (
        [string]$driveScan.Result.counts.directories)
    foreach ($expected in @('ZZZ-Drive-Depth2.ps1', 'ZZZ-Drive-Depth4.ps1', 'ZZZ-Drive-Depth7.ps1', 'ZZZ-Drive-Nested.ps1')) {
        Check ('every reachable hook is found with no depth hint: ' + $expected) (
            Test-FoundTarget -Result $driveScan.Result -Fragment $expected)
    }
    Check 'the nested git repository is found too' ([int]$driveScan.Result.counts.gitRepositories -ge 1)
    Check 'a nested project inside another project is a SEPARATE record' (
        @(@($driveScan.Result.findings) | Where-Object { @($_.clients).Count -gt 0 }).Count -ge 4) (
        [string]@($driveScan.Result.findings).Count)
    if ($driveEnforced) {
        Check 'a hook behind a permission hole is honestly not reported' (
            -not (Test-FoundTarget -Result $driveScan.Result -Fragment 'ZZZ-Drive-Unreachable.ps1'))
        Check 'and the drive scan is reported as partial, not complete' (
            $driveScan.Result.coverage.complete -eq $false -and [string]$driveScan.Result.overall -eq 'partial')
    }

# =====================================================================
Write-Host '--- dependency/build caches are pruned by name, and only those ---' -ForegroundColor Cyan
# A real 22,254-directory scan came back PARTIAL because 10 of its 14 skipped
# reparse points were npm/pnpm package junctions inside node_modules and .next.
# Those trees cannot hold a registration, so walking them bought nothing and
# cost a permanent "coverage incomplete". Pruning them dropped that scan to
# 7,838 directories and 4 skips - and the 4 that remain are real .claude/.codex
# junctions, so it is still honestly partial.
$pruneRoot = New-Dir (Join-Path $Work 'PruneRoot')
# Inside pruned caches: must NOT be discovered.
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot 'app\node_modules\some-pkg')) -HookName 'ZZZ-Pruned-NodeModules' | Out-Null
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot 'app\.next\cached')) -HookName 'ZZZ-Pruned-Next' | Out-Null
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot 'py\.venv\Lib')) -HookName 'ZZZ-Pruned-Venv' | Out-Null
# The same tree under a name the prune list does NOT know. Only the PEP 405
# marker identifies it, which is the whole point: a project may call its
# virtualenv anything, and the real case that exposed this was 'spotdl-env'.
$oddVenv = New-Dir (Join-Path $pruneRoot 'py\spotdl-env')
[System.IO.File]::WriteAllText((Join-Path $oddVenv 'pyvenv.cfg'), 'home = C:\Python312', (New-Object System.Text.UTF8Encoding $false))
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $oddVenv 'Lib')) -HookName 'ZZZ-Pruned-OddVenv' | Out-Null
# Reference collections: third-party skills/MCP material that holds other
# people's .claude and .codex directories - findings for hooks nobody
# installed here.
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot '.OTHERS\steering')) -HookName 'ZZZ-Pruned-Others' | Out-Null
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot '.SKILLS\somepack')) -HookName 'ZZZ-Pruned-Skills' | Out-Null
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot '.MCPs\server')) -HookName 'ZZZ-Pruned-Mcps' | Out-Null
# NOT pruned: a project can legitimately live under a directory called build or
# dist, so those names are deliberately absent from the prune list. This is the
# assertion that stops someone "tidying up" by adding them.
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot 'build\realproject')) -HookName 'ZZZ-Kept-Build' | Out-Null
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot 'dist\realproject')) -HookName 'ZZZ-Kept-Dist' | Out-Null
New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $pruneRoot 'normal')) -HookName 'ZZZ-Kept-Normal' | Out-Null

$pruneScan = Invoke-Scan -Root $pruneRoot
Check 'the pruning scan exits 0' ($pruneScan.Exit -eq 0) $pruneScan.Err
foreach ($hidden in @('ZZZ-Pruned-NodeModules.ps1', 'ZZZ-Pruned-Next.ps1', 'ZZZ-Pruned-Venv.ps1',
        'ZZZ-Pruned-OddVenv.ps1',
        'ZZZ-Pruned-Others.ps1', 'ZZZ-Pruned-Skills.ps1', 'ZZZ-Pruned-Mcps.ps1')) {
    Check ('a hook inside a pruned cache is NOT reported: ' + $hidden) (
        -not (Test-FoundTarget -Result $pruneScan.Result -Fragment $hidden))
}
foreach ($kept in @('ZZZ-Kept-Build.ps1', 'ZZZ-Kept-Dist.ps1', 'ZZZ-Kept-Normal.ps1')) {
    Check ('a hook under a NON-pruned directory is still found: ' + $kept) (
        Test-FoundTarget -Result $pruneScan.Result -Fragment $kept)
}
Check 'the pruning is REPORTED, never silent' (
    [int]$pruneScan.Result.coverage.prunedDirectories -ge 3) (
    [string]$pruneScan.Result.coverage.prunedDirectories)
$prunedNames = @($pruneScan.Result.coverage.prunedNames)
Check 'the report names which caches were excluded' (
    ($prunedNames -contains 'node_modules') -and ($prunedNames -contains '.next') -and ($prunedNames -contains '.venv')) (
    $prunedNames -join ',')
# Reported under the MARKER, never under the directory's own name: one stable
# entry however many oddly named virtualenvs a machine happens to hold.
Check 'a marker-detected virtualenv is reported under the marker name' (
    ($prunedNames -contains 'pyvenv.cfg') -and -not ($prunedNames -contains 'spotdl-env')) (
    $prunedNames -join ',')
# Pruning is scoping, not a coverage gap: with nothing unreadable and no
# reparse point, a pruned scan must still be able to report complete.
Check 'pruning alone does NOT make coverage incomplete' (
    $pruneScan.Result.coverage.complete -eq $true -and [string]$pruneScan.Result.overall -eq 'ok') (
    'overall=' + [string]$pruneScan.Result.overall + ' complete=' + [string]$pruneScan.Result.coverage.complete)
