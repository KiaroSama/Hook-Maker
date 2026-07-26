# Dot-sourced scenario block of Test-HookStatusScan.ps1: what the scan
# refuses BEFORE it starts - a -ResultPath inside the scanned root (directly
# or nested) is refused with nothing scanned, nothing written and the
# registry untouched, while an outside result path still scans normally; a
# scan root that IS a reparse point is refused outright (a scan that did not
# run, not a partial one) while CHILD reparse points keep their skip-and-
# record behavior; and the real per-user .claude/.codex directories are
# proven untouched by any of it.
# NOT a standalone suite: dot-sourced into the entry suite's scope. Run
# scripts\Test-HookStatusScan.ps1 instead.

    # =====================================================================
    # What the scan refuses BEFORE it starts
    # =====================================================================
    Write-Host '--- a result path inside the scanned root is refused ---' -ForegroundColor Cyan
    # The guarantee is "this scan never writes anything inside the folder it
    # scans", so the only correct outcome is a hard refusal: nothing scanned,
    # no document inside the root, non-zero exit, registry untouched.

    # Error text is compared with all whitespace removed: a redirected stderr
    # error record may wrap at the console width, which would otherwise break a
    # plain substring match on a long path.
    function Test-ErrNames { param([string]$Err, [string]$Needle)
        return (($Err -replace '\s', '') -like ('*' + ($Needle -replace '\s', '') + '*')) }

    $refuseRoot = New-Dir (Join-Path $Work 'RefuseRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $refuseRoot 'Proj')) -HookName 'ZZZ-Refuse' | Out-Null
    $registryBeforeRefusals = [System.IO.File]::ReadAllBytes($RegistryPath)
    # Real per-user config must be untouched by anything below - note the
    # workspace itself lives under the real profile, which is exactly the shape
    # that has caused scope bugs here before.
    $realUserConfigs = @('.claude', '.codex') | ForEach-Object { Join-Path $HOME $_ }
    $realConfigBefore = @($realUserConfigs | ForEach-Object {
        [string]$_ + '|' + $(if (Test-Path -LiteralPath $_) { [System.IO.Directory]::GetLastWriteTimeUtc($_).ToString('o') } else { 'absent' }) })

    $insideResult = Join-Path $refuseRoot 'scan-result.json'
    $insideScanRefusal = Invoke-Scan -Root $refuseRoot -ResultPath $insideResult -Persist
    Check 'a result path directly inside the scan root is refused with a non-zero exit' (
        $insideScanRefusal.Exit -ne 0) ('exit=' + [string]$insideScanRefusal.Exit)
    Check 'and no result document is created inside the scanned root' (
        -not (Test-Path -LiteralPath $insideResult))
    Check 'and the refusal names both the result path and the root it is inside' (
        (Test-ErrNames -Err $insideScanRefusal.Err -Needle $insideResult) -and
        (Test-ErrNames -Err $insideScanRefusal.Err -Needle $refuseRoot)) $insideScanRefusal.Err
    Check 'and nothing was scanned or persisted' (
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$registryBeforeRefusals, [byte[]][System.IO.File]::ReadAllBytes($RegistryPath)))
    Check 'and nothing at all was written inside the scanned root' (
        @(Get-ChildItem -LiteralPath $refuseRoot -Recurse -Force -Filter '*.json' |
            Where-Object { $_.FullName -notlike '*\.claude\*' }).Count -eq 0) (
        (@(Get-ChildItem -LiteralPath $refuseRoot -Recurse -Force -Filter '*.json') | ForEach-Object { $_.FullName }) -join ',')

    # A nested destination is the same violation: containment, not parentage, is
    # what the guarantee is about.
    $nestedResult = Join-Path (New-Dir (Join-Path $refuseRoot 'a\b\c')) 'deep-result.json'
    $nestedRefusal = Invoke-Scan -Root $refuseRoot -ResultPath $nestedResult -Persist
    Check 'a result path in a NESTED subdirectory of the scan root is refused too' (
        $nestedRefusal.Exit -ne 0 -and -not (Test-Path -LiteralPath $nestedResult)) (
        'exit=' + [string]$nestedRefusal.Exit)

    # Over-rejection guard: the normal case must be entirely unaffected.
    $outsideResult = Join-Path (New-Dir (Join-Path $Work 'OutsideResults')) 'result.json'
    $outsideScan = Invoke-Scan -Root $refuseRoot -ResultPath $outsideResult
    Check 'a result path OUTSIDE the scan root still scans normally' (
        $outsideScan.Exit -eq 0 -and [string]$outsideScan.Result.overall -eq 'ok') (
        'exit=' + [string]$outsideScan.Exit + ' ' + $outsideScan.Err)
    Check 'and it still finds the hook and writes its document where it was told' (
        (Test-Path -LiteralPath $outsideResult) -and (Test-FoundTarget -Result $outsideScan.Result -Fragment 'ZZZ-Refuse.ps1'))

    Write-Host '--- a scan root that IS a reparse point is refused, never followed ---' -ForegroundColor Cyan
    # A junction root could point anywhere; following it would silently scan a
    # tree the caller never named. Child junctions keep their own behavior
    # (skipped and recorded) - proven by the regression guard below.
    $linkTarget = New-Dir (Join-Path $Work 'LinkTarget')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $linkTarget 'Proj')) -HookName 'ZZZ-Behind-Junction' | Out-Null
    $rootJunction = Join-Path $Work 'RootJunction'
    $rootJunctionCreated = $false
    if ($IsWindows) {
        & cmd.exe /c ('mklink /J "' + $rootJunction + '" "' + $linkTarget + '"') *> $null
        $rootJunctionCreated = (Test-Path -LiteralPath $rootJunction)
        if ($rootJunctionCreated) { [void]$script:Junctions.Add($rootJunction) }
    }
    if ($rootJunctionCreated) {
        $junctionRootScan = Invoke-Scan -Root $rootJunction -Persist
        Check 'a reparse-point scan root exits non-zero' ($junctionRootScan.Exit -ne 0) (
            'exit=' + [string]$junctionRootScan.Exit)
        Check 'and the refusal names the offending root' (
            Test-ErrNames -Err $junctionRootScan.Err -Needle $rootJunction) $junctionRootScan.Err
        Check 'and nothing behind the junction was scanned' (
            -not (Test-FoundTarget -Result $junctionRootScan.Result -Fragment 'ZZZ-Behind-Junction.ps1')) (
            $(if ($null -ne $junctionRootScan.Result) { [string]$junctionRootScan.Result.overall } else { 'no document' }))
        Check 'a refused root is a scan that did not run, not a partial one' (
            $null -ne $junctionRootScan.Result -and [string]$junctionRootScan.Result.overall -eq 'failed' -and
            @($junctionRootScan.Result.coverage.skippedReparse).Count -eq 0) (
            $(if ($null -ne $junctionRootScan.Result) { ($junctionRootScan.Result.coverage | ConvertTo-Json -Depth 4) } else { 'no document' }))
        Check 'and a refused root persists nothing' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$registryBeforeRefusals, [byte[]][System.IO.File]::ReadAllBytes($RegistryPath)))
        # The physical target is still a perfectly ordinary root.
        $physicalScan = Invoke-Scan -Root $linkTarget
        Check 'the physical directory the junction points at still scans normally' (
            $physicalScan.Exit -eq 0 -and (Test-FoundTarget -Result $physicalScan.Result -Fragment 'ZZZ-Behind-Junction.ps1')) (
            'exit=' + [string]$physicalScan.Exit + ' ' + $physicalScan.Err)

        # Regression guard: refusing the ROOT must not have turned child reparse
        # points into failures - they are still skipped, recorded, and survivable.
        $childLinkRoot = New-Dir (Join-Path $Work 'ChildLinkRoot')
        New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $childLinkRoot 'real')) -HookName 'ZZZ-Beside-Child-Link' | Out-Null
        $childJunction = Join-Path $childLinkRoot 'child-link'
        & cmd.exe /c ('mklink /J "' + $childJunction + '" "' + $linkTarget + '"') *> $null
        if (Test-Path -LiteralPath $childJunction) {
            [void]$script:Junctions.Add($childJunction)
            $childLinkScan = Invoke-Scan -Root $childLinkRoot
            Check 'a CHILD reparse point is still skipped and recorded, not refused' (
                $childLinkScan.Exit -eq 0 -and
                @(@($childLinkScan.Result.coverage.skippedReparse) | Where-Object { $_ -like '*child-link*' }).Count -eq 1) (
                'exit=' + [string]$childLinkScan.Exit + ' skipped=' + ((@($childLinkScan.Result.coverage.skippedReparse)) -join ','))
            Check 'and the hook beside the child junction is still found' (
                Test-FoundTarget -Result $childLinkScan.Result -Fragment 'ZZZ-Beside-Child-Link.ps1')
            Check 'and what lives only behind the child junction is not reported' (
                -not (Test-FoundTarget -Result $childLinkScan.Result -Fragment 'ZZZ-Behind-Junction.ps1'))
        }
        else {
            Write-Host '[SKIP] child junction could not be created; child-reparse regression guard skipped' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '[SKIP] a junction root could not be created on this platform/account; reparse-root assertions skipped' -ForegroundColor Yellow
    }

    $realConfigAfter = @($realUserConfigs | ForEach-Object {
        [string]$_ + '|' + $(if (Test-Path -LiteralPath $_) { [System.IO.Directory]::GetLastWriteTimeUtc($_).ToString('o') } else { 'absent' }) })
    Check 'the real per-user .claude/.codex directories were never touched' (
        ($realConfigBefore -join ';') -eq ($realConfigAfter -join ';')) (
        ($realConfigBefore -join ';') + ' vs ' + ($realConfigAfter -join ';'))
