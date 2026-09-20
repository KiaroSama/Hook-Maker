# Test-TestTempCleanup.ps1 scenario block: the CANDIDATE SIZE WALK and its four
# bounds - it never descends through a junction, and it stops on entries, on
# time (a monotonic clock) and on depth - plus the rule that a measurement cut
# short by any of them is reported as ">=N" and never compared or stored as an
# exact size.
#
# One family, one file: these cases share the production-inert time seam and the
# deep/wide fixtures they build, and nothing else in the suite uses either.
#
# Dot-sourced by Test-TestTempCleanup.ps1 into the caller's scope (uses its
# harness, helpers, and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- the candidate SIZE walk never descends through a junction ---' -ForegroundColor Cyan
    # The junction case above covers a candidate that IS a link (measured not at
    # all). This covers a link INSIDE a candidate, which was unguarded:
    # Get-CandidateSize walked with [System.IO.Directory]::EnumerateFiles(...,
    # AllDirectories), and that FOLLOWS reparse points - so the size probe
    # descended through the link and measured a tree OUTSIDE the project, the one
    # thing this hook promises never to do. The reported size is the observable
    # proof: it must count only the bytes physically inside the candidate.
    $hc4b = New-IsolatedHookCopy
    $proj4b = New-GitRepo 'JunctionSizeWalk'
    Add-Commit $proj4b 'init'
    Fire -HookPath $hc4b.Script -Cwd $proj4b -EventName 'SessionStart' -LocalAppData $hc4b.LocalAppData | Out-Null
    # The junction target lives under %TEMP%, outside the project, and is padded
    # so that following the link cannot coincidentally produce the correct size.
    $outsideTarget = New-Dir (Join-Path $Work 'OutsideSizeTarget')
    Write-Utf8 (Join-Path $outsideTarget 'big.txt') ('x' * 4096)
    $sizeCache = New-Dir (Join-Path $proj4b '.pytest_cache')
    Write-Utf8 (Join-Path $sizeCache 'inner.txt') 'inner'
    $sizeLink = Join-Path $sizeCache 'linked'
    $sizeLinkOk = $false
    try { & cmd /c mklink /J "$sizeLink" "$outsideTarget" *> $null; $sizeLinkOk = (Test-Path -LiteralPath $sizeLink) } catch { }
    if (-not $sizeLinkOk) {
        Write-Host '  (skipped: this host cannot create a directory junction, so the follow-the-link size regression cannot be exercised)' -ForegroundColor DarkYellow
    }
    else {
        try {
            Check 'the junction really resolves to the outside tree before measuring' (
                Test-Path -LiteralPath (Join-Path $sizeLink 'big.txt'))
            $rSize = Fire -HookPath $hc4b.Script -Cwd $proj4b -EventName 'Stop' -LocalAppData $hc4b.LocalAppData
            # inner.txt is 5 bytes; big.txt behind the junction is 4096. A walk
            # that followed the link would report 4101.
            Check 'the reported size counts ONLY the bytes physically inside the project' (
                $rSize.Out -match ((Get-CandidateLinePattern '.pytest_cache' 'likely-disposable' 'untracked') +
                    ' \| link=none \| size=5 \|')) $rSize.Out
            Check '... so the tree behind the junction is never measured into it' (
                $rSize.Out -notmatch 'size=4101') $rSize.Out
            Check 'the junction target is untouched by the measurement' (
                ([System.IO.File]::ReadAllText((Join-Path $outsideTarget 'big.txt'))).Length -eq 4096)
        }
        finally {
            # Remove the LINK only. Directory.Delete on a junction unlinks it and
            # never touches the target - unlike a recursive delete through it.
            try { [System.IO.Directory]::Delete($sizeLink, $false) } catch { }
        }
        Check 'the junction fixture is unlinked and its target survived' (
            (-not (Test-Path -LiteralPath $sizeLink)) -and (Test-Path -LiteralPath (Join-Path $outsideTarget 'big.txt')))
    }

    # =====================================================================
    Write-Host '--- the size walk is bounded by ENTRIES, not by files alone ---' -ForegroundColor Cyan
    # Second half of the same defect: the ceiling counted FILES, so a tree made
    # of directories never tripped it and the walk ran to completion however
    # large it was - then reported a confident exact size for a measurement that
    # had had no bound at all. Past the ceiling the value must be a lower bound
    # ('>=N'), never a confident number.
    $hc4c = New-IsolatedHookCopy
    $proj4c = New-GitRepo 'SizeWalkBound'
    Add-Commit $proj4c 'init'
    Fire -HookPath $hc4c.Script -Cwd $proj4c -EventName 'SessionStart' -LocalAppData $hc4c.LocalAppData | Out-Null
    $wideCache = New-Dir (Join-Path $proj4c '.pytest_cache')
    # One entry past the 2000-entry ceiling, all directories, so a file-only cap
    # cannot see them at all.
    for ($i = 0; $i -lt 2001; $i++) { [void][System.IO.Directory]::CreateDirectory((Join-Path $wideCache ('d' + $i.ToString('0000')))) }
    $rBound = Fire -HookPath $hc4c.Script -Cwd $proj4c -EventName 'Stop' -LocalAppData $hc4c.LocalAppData
    Check 'a directory-only tree past the ceiling reports a BOUNDED size, never a confident one' (
        $rBound.Out -match '\.pytest_cache \| class=likely-disposable' -and $rBound.Out -match '\| size=>=') $rBound.Out
    Check 'the whole 2001-directory tree still exists (measuring mutates nothing)' (
        @(Get-ChildItem -LiteralPath $wideCache -Directory).Count -eq 2001)

    # =====================================================================
    Write-Host '--- the size walk is bounded by TIME, measured on a monotonic clock ---' -ForegroundColor Cyan
    # The seconds ceiling shipped with no red proof behind it, and it was
    # measured against [DateTime]::UtcNow - a WALL clock. An NTP correction or a
    # manual clock change landing between the two reads can move that deadline in
    # either direction, collapsing the budget to nothing or extending it
    # arbitrarily; a Stopwatch measures elapsed time from a tick source that
    # cannot be stepped. It is now read through a production-inert environment
    # seam that can only TIGHTEN the ceiling, which is what makes the bound
    # testable at all: a real five-second walk cannot be forced deterministically.
    # At a zero-second budget the first entry trips it, so the reported value must
    # be a lower bound rather than the exact number the unbounded walk produces.
    $hc4d = New-IsolatedHookCopy
    $proj4d = New-GitRepo 'SizeWalkTimeBound'
    Add-Commit $proj4d 'init'
    Fire -HookPath $hc4d.Script -Cwd $proj4d -EventName 'SessionStart' -LocalAppData $hc4d.LocalAppData | Out-Null
    # New-Cache writes a single x.txt of 'cache-content' - exactly 13 bytes.
    $timeCache = New-Cache $proj4d '.pytest_cache'
    $rTime = Fire -HookPath $hc4d.Script -Cwd $proj4d -EventName 'Stop' -LocalAppData $hc4d.LocalAppData -SizeWalkSeconds '0'
    Check 'a zero-second budget trips the TIME ceiling and reports a lower bound' (
        $rTime.Out -match '\.pytest_cache \| class=likely-disposable' -and $rTime.Out -match '\| size=>=0 \|') $rTime.Out
    Check '... so the exact size an unbounded walk would have produced is never claimed' (
        $rTime.Out -notmatch '\| size=13 \|') $rTime.Out
    Check 'the candidate is untouched by the bounded measurement' (
        [System.IO.File]::ReadAllText((Join-Path $timeCache 'x.txt')) -eq 'cache-content')

    # =====================================================================
    Write-Host '--- the size walk is bounded by DEPTH, like the candidate scan ---' -ForegroundColor Cyan
    # Get-CleanupScan has enforced a MaxDepth from the start; this walk had no
    # depth bound at all, so a deep real tree was bounded only by the entry and
    # time ceilings - and a narrow deep tree stays far under both while
    # descending arbitrarily. Depth is a COVERAGE limit here, not a stop
    # condition: what lies below it goes unmeasured (so the total is a lower
    # bound) while everything shallower is still measured honestly.
    $hc4e = New-IsolatedHookCopy
    $proj4e = New-GitRepo 'SizeWalkDepthBound'
    Add-Commit $proj4e 'init'
    Fire -HookPath $hc4e.Script -Cwd $proj4e -EventName 'SessionStart' -LocalAppData $hc4e.LocalAppData | Out-Null
    $deepCache = New-Dir (Join-Path $proj4e '.pytest_cache')
    Write-Utf8 (Join-Path $deepCache 'top.txt') 'abc'
    $deepChain = $deepCache
    for ($i = 1; $i -le 9; $i++) { $deepChain = New-Dir (Join-Path $deepChain ('d' + $i)) }
    Write-Utf8 (Join-Path $deepChain 'deep.txt') 'deepest'
    Check 'the deep fixture really is nine directories below the candidate' (
        Test-Path -LiteralPath (Join-Path $deepCache 'd1\d2\d3\d4\d5\d6\d7\d8\d9\deep.txt'))
    # 10 entries in total, so neither the 2000-entry nor the 5-second ceiling can
    # be what trips here - only the depth bound can.
    $rDepth = Fire -HookPath $hc4e.Script -Cwd $proj4e -EventName 'Stop' -LocalAppData $hc4e.LocalAppData
    Check 'past the depth ceiling the size is a lower bound of what was reachable' (
        $rDepth.Out -match '\.pytest_cache \| class=likely-disposable' -and $rDepth.Out -match '\| size=>=3 \|') $rDepth.Out
    Check '... and the unmeasured file below the ceiling is never counted into it' (
        $rDepth.Out -notmatch '\| size=10 \|') $rDepth.Out
    Check 'the whole deep tree still exists and its content is untouched' (
        [System.IO.File]::ReadAllText((Join-Path $deepChain 'deep.txt')) -eq 'deepest')

    # =====================================================================
    Write-Host '--- a >=N measurement is never compared or stored as an exact size ---' -ForegroundColor Cyan
    # The bounded flag was written into the baseline and then dropped on the way
    # back out: the Stop comparison rebuilt only { sizeBytes, modifiedUtc }, so
    # two LOWER BOUNDS that happened to land on the same number satisfied exactly
    # the equality an exact size would - and the candidate was then reported
    # during-session=unchanged, a claim a partial walk cannot support. The cache
    # exists BEFORE the baseline here, so it is the same candidate on both sides,
    # and both walks are bounded by the same zero-second budget.
    $hc4f = New-IsolatedHookCopy
    $proj4f = New-GitRepo 'BoundedNotExact'
    Write-Utf8 (Join-Path $proj4f 'src.txt') 'code'
    Add-Commit $proj4f 'init'
    New-Cache $proj4f '.pytest_cache' | Out-Null
    Fire -HookPath $hc4f.Script -Cwd $proj4f -EventName 'SessionStart' -LocalAppData $hc4f.LocalAppData -SizeWalkSeconds '0' | Out-Null
    $rExact = Fire -HookPath $hc4f.Script -Cwd $proj4f -EventName 'Stop' -LocalAppData $hc4f.LocalAppData -SizeWalkSeconds '0'
    Check 'a bounded baseline compared with a bounded rescan is NEVER reported as unchanged' (
        $rExact.Out -notmatch 'during-session=unchanged') $rExact.Out
    Check '... it is during-session=unknown, this field''s existing vocabulary for "cannot tell"' (
        $rExact.Out -match '\.pytest_cache \| class=likely-disposable \| type=test-cache-dir \| at-session-start=yes \| during-session=unknown') $rExact.Out

    # The control - and the proof of a THIRD defect, found by this very case
    # going red: with no seam the same shape measures exactly, so the comparison
    # must read 'unchanged'. It did not, because the baseline's timestamp comes
    # back from ConvertFrom-Json in a HOST-DIVERGENT shape - a [string] on
    # Windows PowerShell 5.1, a [DateTime] on pwsh 7, where [string] then yields
    # the culture's short form and can never equal the round-trip 'o' text the
    # live side produces. Every pre-existing candidate was therefore reported
    # during-session=modified on pwsh 7 alone, which also masked the bounded-size
    # rule above by never letting the comparison be reached.
    $hc4g = New-IsolatedHookCopy
    $proj4g = New-GitRepo 'ExactStillUnchanged'
    Write-Utf8 (Join-Path $proj4g 'src.txt') 'code'
    Add-Commit $proj4g 'init'
    New-Cache $proj4g '.pytest_cache' | Out-Null
    Fire -HookPath $hc4g.Script -Cwd $proj4g -EventName 'SessionStart' -LocalAppData $hc4g.LocalAppData | Out-Null
    $rUnchanged = Fire -HookPath $hc4g.Script -Cwd $proj4g -EventName 'Stop' -LocalAppData $hc4g.LocalAppData
    Check 'an EXACT baseline vs an EXACT rescan of the same bytes still reads unchanged' (
        $rUnchanged.Out -match 'at-session-start=yes \| during-session=unchanged') $rUnchanged.Out

    # The same shape on the other host, because a divergence is exactly what this
    # was: 5.1 kept the timestamp as a string and was always right, pwsh 7 coerced
    # it and was always wrong. One host answering correctly is what let this
    # survive - both must now answer identically or the divergence is back.
    $hc4h = New-IsolatedHookCopy
    $proj4h = New-GitRepo 'ExactStillUnchangedPs5'
    Write-Utf8 (Join-Path $proj4h 'src.txt') 'code'
    Add-Commit $proj4h 'init'
    New-Cache $proj4h '.pytest_cache' | Out-Null
    Fire -HookPath $hc4h.Script -Cwd $proj4h -EventName 'SessionStart' -LocalAppData $hc4h.LocalAppData -Exe 'powershell.exe' | Out-Null
    $rUnchanged51 = Fire -HookPath $hc4h.Script -Cwd $proj4h -EventName 'Stop' -LocalAppData $hc4h.LocalAppData -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 answers that identical comparison identically (no host divergence)' (
        $rUnchanged51.Out -match 'at-session-start=yes \| during-session=unchanged') $rUnchanged51.Out

