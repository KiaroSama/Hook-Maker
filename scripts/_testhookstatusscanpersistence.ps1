# Dot-sourced scenario block of Test-HookStatusScan.ps1: PERSISTENCE -
# -NoPersist leaves the registry byte-identical; a failed scan writes a
# result document but persists nothing; a successful scan adds discovered
# records (origin=statusScan, no raw command strings) and a rescan updates in
# place without duplicating; firstSeenUtc is set once; a pre-existing managed
# record is never touched; a partial scan never demotes records under an
# inaccessible subtree, while a covered record that is genuinely gone IS
# demoted to notSeen; a Kiro installation persists without ever corrupting
# the registry.
# NOT a standalone suite: dot-sourced into the entry suite's scope; reuses
# the $ancestor and $permRoot/$enforced fixtures built by the traversal
# block. Run scripts\Test-HookStatusScan.ps1 instead.

    # =====================================================================
    # Persistence
    # =====================================================================
    Write-Host '--- persistence ---' -ForegroundColor Cyan
    New-Dir $StateDir | Out-Null
    # A pre-existing MANAGED record: a scan must never modify or drop it.
    $managedRegistry = @{
        version = 3
        installs = @(@{
            id = 'zzz-managed-fixture'; friendlyName = 'ZZZ Managed Fixture'; schema = 2
            recordType = 'managed'; origin = 'hookMaker'; hookType = 'CustomHook'; scope = 'project'
            targetProjectRoot = $Work; sourceScript = 'x.ps1'; sourceDir = $Work
            clients = @{}; createdUtc = '2020-01-01T00:00:00.0000000Z'
        })
    }
    # Written THROUGH the library: the registry is a directory of per-record
    # files, so a hand-written single document is a file nothing consults.
    # Round-tripped through JSON first so the fixture is the SHAPE the registry
    # really stores - PSCustomObject records, not hashtables. Save-InstallRegistry
    # reads each record's id to name its file and refuses a record it cannot
    # identify, which a hashtable literal would trip.
    Save-InstallRegistry -ToolRoot $ToolRoot -Registry ($managedRegistry | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    # Storage-shape agnostic: the registry is a directory of per-record files.
    $beforeText = Get-InstallRegistryRawText -ToolRoot $ToolRoot

    $noPersistScan = Invoke-Scan -Root $ancestor
    Check '-NoPersist leaves the registry byte-identical' (
        [string]::Equals($beforeText, (Get-InstallRegistryRawText -ToolRoot $ToolRoot), [System.StringComparison]::Ordinal))
    Check '-NoPersist still reports findings' (@($noPersistScan.Result.findings).Count -gt 0)
    Check '-NoPersist reports no records added' ([int]$noPersistScan.Result.recordsAdded -eq 0)

    $failScan = Invoke-Scan -Root (Join-Path $Work 'no-such-directory-at-all') -Persist
    Check 'a failed scan exits non-zero' ($failScan.Exit -ne 0)
    Check 'a failed scan writes a result document with overall=failed' (
        $null -ne $failScan.Result -and [string]$failScan.Result.overall -eq 'failed') (
        $(if ($null -ne $failScan.Result) { [string]$failScan.Result.overall } else { 'no document' }))
    Check 'a failed scan leaves the registry byte-identical' (
        [string]::Equals($beforeText, (Get-InstallRegistryRawText -ToolRoot $ToolRoot), [System.StringComparison]::Ordinal))

    $persistScan = Invoke-Scan -Root $ancestor -Persist
    Check 'a successful scan exits 0' ($persistScan.Exit -eq 0) $persistScan.Err
    Check 'a successful scan reports records added' ([int]$persistScan.Result.recordsAdded -gt 0) (
        [string]$persistScan.Result.recordsAdded)
    $registry = Read-InstallRegistry -ToolRoot $ToolRoot
    $discovered = @(@($registry.installs) | Where-Object { $null -ne $_.PSObject.Properties['recordType'] -and [string]$_.recordType -eq 'discovered' })
    Check 'discovered records land in the registry' ($discovered.Count -eq @($persistScan.Result.findings).Count) (
        'registry=' + $discovered.Count + ' findings=' + @($persistScan.Result.findings).Count)
    $managedAfter = @(@($registry.installs) | Where-Object { [string]$_.id -eq 'zzz-managed-fixture' })
    # createdUtc is compared as an INSTANT, not as text: Read-InstallRegistryState
    # parses JSON with ConvertFrom-Json, which turns an ISO timestamp into a
    # [DateTime], so every registry writer in this project re-serializes it in
    # .NET's round-trip form. The instant is preserved; only the spelling changes.
    Check 'the pre-existing managed record survives untouched' (
        $managedAfter.Count -eq 1 -and
        [string]$managedAfter[0].friendlyName -eq 'ZZZ Managed Fixture' -and
        [string]$managedAfter[0].recordType -eq 'managed' -and
        [string]$managedAfter[0].sourceScript -eq 'x.ps1' -and
        ([datetime]$managedAfter[0].createdUtc).ToUniversalTime() -eq ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime()) (
        $(if ($managedAfter.Count -eq 1) { ($managedAfter[0] | ConvertTo-Json -Depth 4) } else { 'count=' + $managedAfter.Count }))
    Check 'every discovered record carries origin=statusScan' (
        @(@($discovered) | Where-Object { [string]$_.origin -ne 'statusScan' }).Count -eq 0)
    Check 'no discovered record stores a raw command string' (
        (Get-InstallRegistryRawText -ToolRoot $ToolRoot) -notlike '*pwsh -File*')

    $firstSeen = [string]@($discovered)[0].firstSeenUtc
    Start-Sleep -Milliseconds 20
    $rescan = Invoke-Scan -Root $ancestor -Persist
    $registry2 = Read-InstallRegistry -ToolRoot $ToolRoot
    $discovered2 = @(@($registry2.installs) | Where-Object { $null -ne $_.PSObject.Properties['recordType'] -and [string]$_.recordType -eq 'discovered' })
    Check 'a rescan updates in place instead of duplicating' ($discovered2.Count -eq $discovered.Count) (
        'first=' + $discovered.Count + ' second=' + $discovered2.Count)
    Check 'a rescan reports updates, not additions' (
        [int]$rescan.Result.recordsAdded -eq 0 -and [int]$rescan.Result.recordsUpdated -gt 0) (
        'added=' + [string]$rescan.Result.recordsAdded + ' updated=' + [string]$rescan.Result.recordsUpdated)
    $matching = @(@($discovered2) | Where-Object { [string]$_.id -eq [string]@($discovered)[0].id })
    Check 'firstSeenUtc is set once and never overwritten' (
        $matching.Count -eq 1 -and [string]$matching[0].firstSeenUtc -eq $firstSeen) (
        $(if ($matching.Count -eq 1) { [string]$matching[0].firstSeenUtc + ' vs ' + $firstSeen } else { 'count=' + $matching.Count }))
    Check 'lastSeenUtc is refreshed by the rescan' (
        $matching.Count -eq 1 -and [string]$matching[0].lastSeenUtc -ne $firstSeen)

    # A record whose evidence lives under an inaccessible subtree must NOT be
    # demoted to notSeen by a later partial scan.
    if ($enforced) {
        Invoke-Scan -Root $permRoot -Persist | Out-Null
        $permRegistry = Read-InstallRegistry -ToolRoot $ToolRoot
        $notSeen = @(@($permRegistry.installs) | Where-Object {
            $null -ne $_.PSObject.Properties['status'] -and [string]$_.status -eq 'notSeen' })
        Check 'a partial scan never marks a record under an inaccessible subtree as notSeen' (
            @(@($notSeen) | Where-Object { [string]$_.friendlyName -like '*Inside-Denied*' }).Count -eq 0)
        Check 'a partial scan still persists what it verified' (
            @(@($permRegistry.installs) | Where-Object {
                $null -ne $_.PSObject.Properties['friendlyName'] -and [string]$_.friendlyName -like '*Before-Denied*' }).Count -eq 1)
    }

    # A record from an earlier scan of the SAME roots that is genuinely gone is
    # the only case that may be demoted.
    $gone = New-Dir (Join-Path $Work 'GoneRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $gone 'Proj')) -HookName 'ZZZ-Will-Vanish' | Out-Null
    Invoke-Scan -Root $gone -Persist | Out-Null
    Remove-Item -LiteralPath (Join-Path $gone 'Proj\.claude') -Recurse -Force
    Invoke-Scan -Root $gone -Persist | Out-Null
    $goneRegistry = Read-InstallRegistry -ToolRoot $ToolRoot
    $vanished = @(@($goneRegistry.installs) | Where-Object {
        $null -ne $_.PSObject.Properties['friendlyName'] -and [string]$_.friendlyName -like '*Will-Vanish*' })
    Check 'a covered record that is genuinely gone is demoted to notSeen' (
        $vanished.Count -eq 1 -and [string]$vanished[0].status -eq 'notSeen') (
        $(if ($vanished.Count -eq 1) { [string]$vanished[0].status } else { 'count=' + $vanished.Count }))

    # A persisting scan over a Kiro installation must survive whatever the
    # registry layer decides about it: the record is either stored or reported
    # as not stored, but the scan never crashes, never corrupts the registry,
    # and never loses a managed record.
    $kiroPersistRoot = New-Dir (Join-Path $Work 'KiroPersistRoot')
    New-KiroHook -ProjectRoot (New-Dir (Join-Path $kiroPersistRoot 'Proj')) -HookName 'ZZZ-Kiro-Persist' | Out-Null
    $kiroPersistScan = Invoke-Scan -Root $kiroPersistRoot -Persist
    Check 'a persisting scan over a Kiro installation exits 0' ($kiroPersistScan.Exit -eq 0) $kiroPersistScan.Err
    Check 'and the Kiro installation is reported in the scan result' (
        Test-FoundTarget -Result $kiroPersistScan.Result -Fragment 'ZZZ-Kiro-Persist.ps1') (
        ($kiroPersistScan.Result.findings | ConvertTo-Json -Depth 6))
    $kiroRegistry = $null
    try { $kiroRegistry = Read-InstallRegistry -ToolRoot $ToolRoot } catch { $kiroRegistry = $null }
    Check 'and the registry is still readable afterwards' ($null -ne $kiroRegistry)
    Check 'and the pre-existing managed record still survives' (
        $null -ne $kiroRegistry -and
        @(@($kiroRegistry.installs) | Where-Object { [string]$_.id -eq 'zzz-managed-fixture' }).Count -eq 1)
