# Test-ContextHooks section: terminating an OWNED process tree.
#
# The walk is tested against synthetic snapshots rather than by building real
# process trees: a recycled process id and an eight-deep tree are both trivial
# to describe and close to impossible to stage reliably, and the walk is pure
# given its input. One real child-and-grandchild case covers the wiring.
#
# What used to be here instead: a recursion with a fresh process query at every
# level, no depth bound, no identity check, no deadline, and no return value.

    # =====================================================================
    Write-Host '--- process tree: the walk only follows processes that can BE descendants ---' -ForegroundColor Cyan
    . (Join-Path (Split-Path -Parent $HookLib) '_processtree.ps1')
    $ptBase = [DateTime]'2026-09-20T10:00:00Z'
    function New-PtNode {
        param([int]$Id, [int]$Parent, [double]$MinutesAfterBase)
        return [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; CreationDate = $ptBase.AddMinutes($MinutesAfterBase) }
    }

    # 100 -> 101 -> 102, all started after the root.
    $ptTree = @((New-PtNode 100 1 0), (New-PtNode 101 100 1), (New-PtNode 102 101 2), (New-PtNode 900 1 1))
    $ptWalk = Get-OwnedDescendantId -RootId 100 -RootCreated $ptBase -Snapshot $ptTree
    Check 'the walk finds the child and the grandchild' (
        (@($ptWalk.Ids) -contains 101) -and (@($ptWalk.Ids) -contains 102)) (@($ptWalk.Ids) -join ',')
    Check 'and nothing that is not under the root' (@($ptWalk.Ids) -notcontains 900) (@($ptWalk.Ids) -join ',')
    Check 'a complete walk is not reported as truncated' (-not $ptWalk.Truncated) ([string]$ptWalk.Truncated)

    # THE identity case. Process ids are recycled, and this runs after the run
    # has already gone wrong - exactly when a recorded id is most likely to have
    # been reused. A process that started BEFORE the root cannot be its child.
    $ptRecycled = @((New-PtNode 200 1 10), (New-PtNode 201 200 -5))
    $ptWalk2 = Get-OwnedDescendantId -RootId 200 -RootCreated ($ptBase.AddMinutes(10)) -Snapshot $ptRecycled
    Check 'a child that PREDATES its parent is a recycled id, not a descendant' (
        @($ptWalk2.Ids).Count -eq 0) (@($ptWalk2.Ids) -join ',')

    # A recycled id can also make the parent map cyclic. The visited set is what
    # stops that being an infinite walk instead of a wrong answer.
    $ptCycle = @((New-PtNode 300 301 0), (New-PtNode 301 300 1))
    $ptWalk3 = Get-OwnedDescendantId -RootId 300 -RootCreated $ptBase -Snapshot $ptCycle
    Check 'a cycle in the parent map terminates instead of looping' (
        @($ptWalk3.Ids).Count -le 1) (@($ptWalk3.Ids) -join ',')

    # Deeper than the depth bound: stop at the bound and SAY so, rather than
    # claiming a complete walk.
    $ptDeep = New-Object System.Collections.Generic.List[object]
    [void]$ptDeep.Add((New-PtNode 400 1 0))
    for ($i = 1; $i -le 20; $i++) { [void]$ptDeep.Add((New-PtNode (400 + $i) (399 + $i) $i)) }
    $ptWalk4 = Get-OwnedDescendantId -RootId 400 -RootCreated $ptBase -Snapshot @($ptDeep.ToArray())
    Check 'a tree deeper than the bound is truncated, not silently partial' $ptWalk4.Truncated ([string]$ptWalk4.Truncated)
    Check 'and it stops at the depth bound' (@($ptWalk4.Ids).Count -le 8) ([string]@($ptWalk4.Ids).Count)

    # =====================================================================
    Write-Host '--- process tree: cleanup is bounded and reports what it did ---' -ForegroundColor Cyan
    # One real tree, to prove the wiring: a child that spawns a grandchild, both
    # bounded so a failure here cannot outlive the suite.
    $ptExe = (Get-Process -Id $PID).Path
    $ptChild = Start-Process -FilePath $ptExe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-Command',
        "Start-Process -FilePath '$ptExe' -WindowStyle Hidden -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 45'; Start-Sleep -Seconds 45")
    # Wait on the grandchild EXISTING, not on the clock.
    $ptDeadline = [DateTime]::UtcNow.AddSeconds(15)
    $ptGrand = @()
    while ([DateTime]::UtcNow -lt $ptDeadline) {
        $ptGrand = @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $ptChild.Id) -ErrorAction SilentlyContinue)
        if ($ptGrand.Count -gt 0) { break }
        Start-Sleep -Milliseconds 100
    }
    Check 'the fixture actually produced a grandchild to clean up' ($ptGrand.Count -gt 0) ([string]$ptGrand.Count)
    $ptGrandId = if ($ptGrand.Count -gt 0) { [int]$ptGrand[0].ProcessId } else { 0 }

    $ptVerdict = Stop-ProcessTree -ProcessId $ptChild.Id -TimeoutMilliseconds 8000
    Check 'cleanup reports the tree as cleared' $ptVerdict.Cleared (
        'Cleared=' + $ptVerdict.Cleared + ' Survivors=' + (@($ptVerdict.Survivors) -join ',') + ' Truncated=' + $ptVerdict.Truncated)
    Check 'cleanup stays inside its deadline' (-not $ptVerdict.DeadlineHit -and $ptVerdict.ElapsedMs -le 8000) ([string]$ptVerdict.ElapsedMs)
    Check 'the child is really gone, not merely asked to leave' (
        $null -eq (Get-Process -Id $ptChild.Id -ErrorAction SilentlyContinue)) ([string]$ptChild.Id)
    Check 'the GRANDCHILD is gone too - the whole point of walking the tree' (
        $ptGrandId -eq 0 -or $null -eq (Get-Process -Id $ptGrandId -ErrorAction SilentlyContinue)) ([string]$ptGrandId)

    # Never terminate the process doing the terminating.
    $ptSelf = Stop-ProcessTree -ProcessId $PID -TimeoutMilliseconds 2000
    Check 'cleanup never kills its own process' (
        $null -ne (Get-Process -Id $PID -ErrorAction SilentlyContinue)) ([string]$ptSelf.Cleared)

    # An id that is already gone is nothing to do, not a failure.
    $ptGoneVerdict = Stop-ProcessTree -ProcessId $ptChild.Id -TimeoutMilliseconds 2000
    Check 'an already-dead process is cleared, not reported as a survivor' (
        @($ptGoneVerdict.Survivors).Count -eq 0) (@($ptGoneVerdict.Survivors) -join ',')
