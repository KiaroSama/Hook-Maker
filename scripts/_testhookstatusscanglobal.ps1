# Dot-sourced scenario block of Test-HookStatusScan.ps1: -IncludeGlobal -
# the canonical current-user settings are read only when asked (proven with a
# fake home, never the real one); the global finding is scoped global; a
# global root already inside the scan root is not scanned twice; and
# declining -IncludeGlobal is honored on EVERY code path (the downward walk
# over the home, the direct-subtree upward lookup, and Kiro's global
# registration DIRECTORY shape).
# NOT a standalone suite: dot-sourced into the entry suite's scope; rescans
# the $ancestor fixture built by the traversal block. Run
# scripts\Test-HookStatusScan.ps1 instead.

    Write-Host '--- -IncludeGlobal ---' -ForegroundColor Cyan
    # A fake user home, so no real Claude/Codex settings are ever touched.
    $fakeHome = New-Dir (Join-Path $Work 'FakeHome')
    $globalTarget = Join-Path (New-Dir (Join-Path $fakeHome 'globalhooks')) 'ZZZ-Global.ps1'
    Write-Utf8 -Path $globalTarget -Content '# global hook'
    Write-Utf8 -Path (Join-Path $fakeHome '.claude\settings.json') -Content (@{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $globalTarget + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $globalEnv = @{ USERPROFILE = $fakeHome; HOME = $fakeHome; HOMEDRIVE = ''; HOMEPATH = '' }
        $withoutGlobal = Invoke-Scan -Root $ancestor -Environment $globalEnv
        Check 'without -IncludeGlobal the global settings file is not read' (
            -not (Test-FoundTarget -Result $withoutGlobal.Result -Fragment 'ZZZ-Global.ps1'))
        $withGlobal = Invoke-Scan -Root $ancestor -IncludeGlobal -Environment $globalEnv
        Check '-IncludeGlobal reads the canonical current-user settings file' (
            Test-FoundTarget -Result $withGlobal.Result -Fragment 'ZZZ-Global.ps1') (
            (@($withGlobal.Result.scanRoots)) -join ',')
        Check 'the global finding is scoped global, not project' (
            @(@($withGlobal.Result.findings) | Where-Object {
                [string]$_.scope -eq 'global' -and [string]$_.friendlyName -like '*ZZZ-Global*' }).Count -eq 1)
        # The same home, but INSIDE the scanned root: the global root must not be
        # added a second time.
        $insideHome = New-Dir (Join-Path $ancestor 'InsideHome')
        Write-Utf8 -Path (Join-Path $insideHome '.claude\settings.json') -Content (@{
            hooks = @{ Stop = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $globalTarget + '"') }) }) }
        } | ConvertTo-Json -Depth 20)
        $insideScan = Invoke-Scan -Root $ancestor -IncludeGlobal -Environment @{ USERPROFILE = $insideHome; HOME = $insideHome; HOMEDRIVE = ''; HOMEPATH = '' }
        Check 'a global root already inside the scan root is not scanned twice' (
            @($insideScan.Result.scanRoots).Count -eq 1) ((@($insideScan.Result.scanRoots)) -join ',')
        Check 'and its settings file is still reported exactly once' (
            @(@($insideScan.Result.findings) | Where-Object {
                @(@($_.clients) | Where-Object { [string]$_.settingsPath -like '*InsideHome*' }).Count -gt 0 }).Count -eq 1)

        Write-Host '--- declining -IncludeGlobal is honored on EVERY code path ---' -ForegroundColor Cyan
        # Regression: the direct-subtree lookup used to reach the canonical
        # global settings files even when the user had just declined them,
        # because only the scan-root list was gated. A declined global scan must
        # mean no global settings file is opened at all - while the genuine
        # direct-subtree feature keeps working for the PROJECT.
        $homeProject = New-Dir (Join-Path $fakeHome 'projects\App')
        $homeProjectTarget = Join-Path (New-Dir (Join-Path $homeProject 'hookscripts')) 'ZZZ-HomeProject.ps1'
        Write-Utf8 -Path $homeProjectTarget -Content '# project inside the home directory'
        Write-Utf8 -Path (Join-Path $homeProject '.claude\settings.local.json') -Content (@{
            hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $homeProjectTarget + '"') }) }) }
        } | ConvertTo-Json -Depth 20)
        $homeRuntime = New-Dir (Join-Path $homeProject '.claude\hooks\Hook-Maker\ZZZ-HomeProject')

        $subtreeNoGlobal = Invoke-Scan -Root $homeRuntime -Environment $globalEnv
        Check 'a subtree scan under the home still finds its PROJECT registration' (
            Test-FoundTarget -Result $subtreeNoGlobal.Result -Fragment 'ZZZ-HomeProject.ps1') (
            ($subtreeNoGlobal.Result | ConvertTo-Json -Depth 6))
        Check 'without -IncludeGlobal a subtree scan never reads the global settings file' (
            -not (Test-FoundTarget -Result $subtreeNoGlobal.Result -Fragment 'ZZZ-Global.ps1'))
        Check 'and it reports no global-scoped finding at all' (
            @(@($subtreeNoGlobal.Result.findings) | Where-Object { [string]$_.scope -eq 'global' }).Count -eq 0)

        $subtreeWithGlobal = Invoke-Scan -Root $homeRuntime -IncludeGlobal -Environment $globalEnv
        Check 'with -IncludeGlobal the same subtree scan DOES read the global settings file' (
            Test-FoundTarget -Result $subtreeWithGlobal.Result -Fragment 'ZZZ-Global.ps1')

        # The home directory itself as the scan root: the downward walk would
        # otherwise open the global file on its way past.
        $homeRootScan = Invoke-Scan -Root $fakeHome -Environment $globalEnv
        Check 'scanning the home directory without -IncludeGlobal skips the global settings file' (
            -not (Test-FoundTarget -Result $homeRootScan.Result -Fragment 'ZZZ-Global.ps1')) (
            ((@($homeRootScan.Result.findings) | ForEach-Object { [string]$_.friendlyName }) -join ','))
        Check 'but a project inside the home directory is still discovered' (
            Test-FoundTarget -Result $homeRootScan.Result -Fragment 'ZZZ-HomeProject.ps1')

        # The same gate for the OTHER client shape. Kiro's global location is a
        # DIRECTORY (~\.kiro\hooks), not a settings file, so it needs its own
        # proof that declining -IncludeGlobal is honored - this is exactly the
        # code path that leaked once already for Claude.
        New-KiroHook -ProjectRoot $fakeHome -HookName 'ZZZ-KiroHome' | Out-Null
        $kiroHomeNoGlobal = Invoke-Scan -Root $fakeHome -Environment $globalEnv
        Check 'without -IncludeGlobal the global .kiro\hooks directory is not read' (
            -not (Test-FoundTarget -Result $kiroHomeNoGlobal.Result -Fragment 'ZZZ-KiroHome.ps1')) (
            ((@($kiroHomeNoGlobal.Result.findings) | ForEach-Object { [string]$_.friendlyName }) -join ','))
        $kiroHomeWithGlobal = Invoke-Scan -Root $fakeHome -IncludeGlobal -Environment $globalEnv
        Check 'with -IncludeGlobal the global .kiro\hooks directory IS read' (
            Test-FoundTarget -Result $kiroHomeWithGlobal.Result -Fragment 'ZZZ-KiroHome.ps1') (
            ((@($kiroHomeWithGlobal.Result.findings) | ForEach-Object { [string]$_.friendlyName }) -join ','))
        Check 'and the global Kiro finding is scoped global, not project' (
            @(@($kiroHomeWithGlobal.Result.findings) | Where-Object {
                    [string]$_.scope -eq 'global' -and [string]$_.friendlyName -like '*ZZZ-KiroHome*' }).Count -eq 1) (
            ((@($kiroHomeWithGlobal.Result.findings) | ForEach-Object {
                    [string]$_.friendlyName + '=' + [string]$_.scope }) -join ','))
    }
    else {
        Write-Host '[SKIP] Start-Process -Environment unavailable; -IncludeGlobal assertions skipped' -ForegroundColor Yellow
    }
