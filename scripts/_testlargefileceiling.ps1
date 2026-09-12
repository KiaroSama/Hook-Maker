# Test-LargeFileCheck section: the ONE Stop gate - a source file that THIS TASK
# pushed past the hard ceiling (at or under it in the SessionStart baseline, over
# it now). Covers: the block and its exact recovery text; a file already over the
# ceiling at baseline staying advisory; the once-per-fingerprint bound and the
# fact that changed state is still evaluated (and that the advisory cooldown
# never swallows the gate); no baseline and partial coverage never blocking; and
# the baseline holding metadata only - relative path and line count, no content.
#
# Dot-sourced from Test-LargeFileCheck.ps1 INSIDE its try block, so it runs in
# that scope and uses that harness directly: $Work, Fire, Check, New-Proj,
# New-SourceFile, New-IsolatedHookCopy, Get-Advisory, Write-Utf8 and the
# counters. It is not a standalone suite, and the underscore prefix keeps it out
# of the runner's Test-*.ps1 glob, so it needs no ci.yml bucket of its own.
#
# It is a separate file because Test-LargeFileCheck.ps1 already sits at the
# write-time ceiling this very hook enforces: at ~700 lines a file is closed to
# new code, so the new cases went to a file named for what they cover - not
# appended past the number, and not a thin wrapper.

    # Get-Advisory deliberately refuses to read a block document (accepting one as
    # "the message" once masked a real defect), so the gate's own text is read
    # here - and only from a real decision:block.
    function Get-BlockReason {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
        $doc = $null
        try { $doc = $Text | ConvertFrom-Json } catch { return '' }
        if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['decision']) { return '' }
        if ([string]$doc.decision -ne 'block') { return '' }
        return [string]$doc.reason
    }

    # $msg1 is the SessionStart guidance the entry file already captured: the
    # wording the hard-ceiling rule retired must be gone from it, not merely
    # joined by the new wording.
    Check 'C0. the retired review-signal/overage/appending framing is gone' (
        $msg1 -notmatch '(?i)review signal' -and $msg1 -notmatch '(?i)overage' -and
        $msg1 -notmatch '(?i)appending is correct') $msg1

    # =====================================================================
    Write-Host '--- The Stop GATE: a file this task pushed past the ceiling ---' -ForegroundColor Cyan
    $hcC1 = New-IsolatedHookCopy
    $projC1 = New-Proj 'CeilingGrown'
    New-SourceFile (Join-Path $projC1 'src\grows.py') 790
    Write-Utf8 (Join-Path $projC1 'src\marker.py') 'CONTENT-MUST-NEVER-REACH-STATE'
    $rBase = Fire -HookPath $hcC1.Script -Cwd $projC1 -EventName 'SessionStart' -LocalAppData $hcC1.LocalAppData
    Check 'C1a. SessionStart still emits the guidance (and now also takes a baseline)' (
        $rBase.Exit -eq 0 -and $rBase.Err -eq '' -and (Get-Advisory $rBase.Out) -match '(?i)HARD CEILING') ($rBase.Out + $rBase.Err)
    $baselineFiles = @(Get-ChildItem -LiteralPath (Join-Path $hcC1.LocalAppData 'HookMaker\state') -Filter 'LargeFileCheckBaseline-*.json' -ErrorAction SilentlyContinue)
    Check 'C1b. exactly one baseline file, in the isolated state dir - never in the project' (
        $baselineFiles.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $projC1 'HookMaker'))) ("$($baselineFiles.Count)")
    $baselinePathC1 = if ($baselineFiles.Count -eq 1) { $baselineFiles[0].FullName } else { '' }
    $baselineText = if ($baselinePathC1 -ne '') { [System.IO.File]::ReadAllText($baselinePathC1) } else { '' }
    $baselineRows = @()
    if ($baselineText -ne '') { $baselineRows = @(($baselineText | ConvertFrom-Json).baseline.files) }
    $rowProps = @($baselineRows | ForEach-Object { (@($_.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object) -join ',' } | Sort-Object -Unique)
    Check 'C1c. the baseline stores METADATA ONLY: relative path + line count, nothing else' (
        $baselineRows.Count -ge 2 -and $rowProps.Count -eq 1 -and $rowProps[0] -eq 'l,p') ("$rowProps")
    Check 'C1d. no file content reaches the state file' (
        $baselineText -ne '' -and $baselineText -notmatch 'CONTENT-MUST-NEVER-REACH-STATE') $baselineText
    Check 'C1e. the baseline recorded the pre-task line count of the file that will grow' (
        @($baselineRows | Where-Object { $_.p -eq 'src\grows.py' -and [int]$_.l -eq 790 }).Count -eq 1) $baselineText

    # The task grows it past the ceiling.
    New-SourceFile (Join-Path $projC1 'src\grows.py') 900
    $rBlock = Fire -HookPath $hcC1.Script -Cwd $projC1 -EventName 'Stop' -LocalAppData $hcC1.LocalAppData
    $reasonC1 = Get-BlockReason $rBlock.Out
    Check 'C2a. a file grown from <=800 to >800 during the task BLOCKS (real decision:block)' (
        $reasonC1 -ne '' -and $rBlock.Exit -eq 0 -and $rBlock.Err -eq '') ($rBlock.Out + $rBlock.Err)
    Check 'C2b. the block names the file, both counts and the ceiling' (
        $reasonC1 -match 'src\\grows\.py \(900 lines now, 790 at session start\)' -and
        $reasonC1 -match '800-line hard ceiling') $reasonC1
    Check 'C2c. the block carries the EXACT recovery, and says what clears it' (
        $reasonC1 -match 'move the code added to src\\grows\.py into a new responsibility-named file; do not create a wrapper\.' -and
        $reasonC1 -match 'clears as soon as each file above is back at or under 800 lines') $reasonC1
    Check 'C2d. the recovery forbids ducking the number with a wrapper/forwarding file' (
        $reasonC1 -match '(?i)never a thin wrapper, forwarding file, or fragment created to duck the number') $reasonC1

    # =====================================================================
    Write-Host '--- The gate blocks ONCE per fingerprint, and changed state is re-evaluated ---' -ForegroundColor Cyan
    $rRepeat = Fire -HookPath $hcC1.Script -Cwd $projC1 -EventName 'Stop' -LocalAppData $hcC1.LocalAppData
    Check 'C3a. the same unchanged state does NOT block twice' (
        (Get-BlockReason $rRepeat.Out) -eq '' -and $rRepeat.Out -notmatch '"decision"') $rRepeat.Out
    $afterBlockText = if ($baselinePathC1 -ne '') { [System.IO.File]::ReadAllText($baselinePathC1) } else { '' }
    $afterBlockDoc = $null
    if ($afterBlockText -ne '') { $afterBlockDoc = $afterBlockText | ConvertFrom-Json }
    Check 'C3b. the bound is the recorded fingerprint, and the baseline survives it' (
        $null -ne $afterBlockDoc -and [string]$afterBlockDoc.lastBlockFingerprint -ne '' -and
        @($afterBlockDoc.baseline.files).Count -ge 2) $afterBlockText
    # The repeat above emitted the ordinary oversized-file advisory, so the
    # per-project cooldown is now running. The gate must not depend on it.
    New-SourceFile (Join-Path $projC1 'src\grows.py') 950
    $rChanged = Fire -HookPath $hcC1.Script -Cwd $projC1 -EventName 'Stop' -LocalAppData $hcC1.LocalAppData
    Check 'C3c. changed state blocks again - and the advisory cooldown never swallows the gate' (
        (Get-BlockReason $rChanged.Out) -match 'src\\grows\.py \(950 lines now, 790 at session start\)') $rChanged.Out

    # =====================================================================
    Write-Host '--- A file already over the ceiling at baseline stays ADVISORY ---' -ForegroundColor Cyan
    $hcC2 = New-IsolatedHookCopy
    $projC2 = New-Proj 'CeilingPreExisting'
    New-SourceFile (Join-Path $projC2 'legacy\old.cs') 1200
    $null = Fire -HookPath $hcC2.Script -Cwd $projC2 -EventName 'SessionStart' -LocalAppData $hcC2.LocalAppData
    # It even grows further during the task: it was over the ceiling before the
    # task started, so this hook still never blocks on it.
    New-SourceFile (Join-Path $projC2 'legacy\old.cs') 1400
    $rC2 = Fire -HookPath $hcC2.Script -Cwd $projC2 -EventName 'Stop' -LocalAppData $hcC2.LocalAppData
    Check 'C4a. a file already over the ceiling at baseline NEVER blocks' (
        $rC2.Out -notmatch '"decision"' -and $rC2.Exit -eq 0) $rC2.Out
    Check 'C4b. it stays the non-blocking advisory it has always been' (
        (Get-Advisory $rC2.Out) -match 'old\.cs \(1400 lines\)' -and
        (Get-Advisory $rC2.Out) -match '(?i)this is advisory and nothing here blocks') $rC2.Out

    # =====================================================================
    Write-Host '--- Unknown never blocks: no baseline, and partial coverage ---' -ForegroundColor Cyan
    $hcC3 = New-IsolatedHookCopy
    $projC3 = New-Proj 'CeilingNoBaseline'
    New-SourceFile (Join-Path $projC3 'src\fresh.py') 900
    $rC3 = Fire -HookPath $hcC3.Script -Cwd $projC3 -EventName 'Stop' -LocalAppData $hcC3.LocalAppData
    Check 'C5. with no SessionStart baseline the gate stays silent and the advisory remains' (
        $rC3.Out -notmatch '"decision"' -and (Get-Advisory $rC3.Out) -match 'fresh\.py \(900 lines\)') $rC3.Out

    # MAX_FILES=1 makes both walks partial, whichever file the enumeration reaches
    # first, so the gate has incomplete coverage on at least one side.
    $hcC4 = New-IsolatedHookCopy -EnvContent "MAX_FILES=1`n"
    $projC4 = New-Proj 'CeilingPartial'
    New-SourceFile (Join-Path $projC4 'src\a_grows.py') 700
    New-SourceFile (Join-Path $projC4 'src\b_other.py') 100
    $null = Fire -HookPath $hcC4.Script -Cwd $projC4 -EventName 'SessionStart' -LocalAppData $hcC4.LocalAppData
    New-SourceFile (Join-Path $projC4 'src\a_grows.py') 900
    $rC4 = Fire -HookPath $hcC4.Script -Cwd $projC4 -EventName 'Stop' -LocalAppData $hcC4.LocalAppData
    Check 'C6. partial coverage never blocks (a ceiling-cut walk is not proof)' (
        $rC4.Out -notmatch '"decision"' -and $rC4.Exit -eq 0) $rC4.Out
