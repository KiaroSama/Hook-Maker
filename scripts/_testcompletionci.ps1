# Test-TestCompletionCheck.ps1 scenario block: a green CI result for THIS commit
# clears a run that completed but FAILED - and nothing else does.
#
# Its own file because _testcompletionledger.ps1 is near the size ceiling, and
# because this is one question with one set of near-misses. Dot-sourced by
# Test-TestCompletionCheck.ps1 into the caller's scope (uses its harness).
#
# The contradiction it removes: one hook told the agent not to run locally a
# suite CI runs, and this one then refused to let the work finish until a clean
# run existed locally. Measured cost in one real task: 345s + 310s of duplicate
# local running, after CI was already green on the pushed commit.

    # =====================================================================
    Write-Host '--- CI1: a green CI result for this exact commit clears a FAILED run ---' -ForegroundColor Cyan

    $script:ciSlug = 'acme/widget'
    function Initialize-CiRepo {
        param([string]$Name)
        $root = New-GitRepo $Name
        # Test-CiClearedFailure needs a resolvable GitHub remote to derive the
        # same state key Ci-Status-Check writes under. No network is involved.
        $null = & git -C $root remote add origin ('https://github.com/' + $script:ciSlug + '.git') 2>&1
        return $root
    }
    function Get-CiHead {
        param([string]$Root)
        return ([string](& git -C $Root rev-parse HEAD)).Trim()
    }
    function Write-CiRecord {
        param(
            [object]$Copy, [string]$Root, [string]$Sha, [string]$Outcome = 'verified',
            [string]$Evidence = 'ci-green', [double]$AgeMinutes = 0, [switch]$LegacyThreeLine
        )
        $key = Get-ShortHash ($Root.ToLowerInvariant() + '|' + $script:ciSlug.ToLowerInvariant())
        $path = Join-Path (Get-StateDir $Copy) ('CiStatusCheck-' + $key + '.txt')
        $when = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes).ToString('o')
        $lines = if ($LegacyThreeLine) { @($Sha, $Outcome, $when) } else { @($Sha, $Outcome, $when, $Evidence) }
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllLines($path, $lines)
        return $path
    }
    # One failed run, one CI record, one verdict. Everything below is this shape.
    function Invoke-CiCase {
        param([string]$Name, [hashtable]$Record = $null, [switch]$Dirty, [string]$Overall = 'failed', [int]$ExitCode = 1)
        $c = New-IsolatedHookCopy
        $p = Initialize-CiRepo $Name
        $k = Get-ProjectKey $p
        Write-GuardedResult -Copy $c -Root $p -Overall $Overall -ExitCode $ExitCode -RunId ($Name + '-' + $k) -CommandFingerprint ('cmd' + $Name + $k) -AgeMinutes 30
        if ($null -ne $Record) {
            $recArgs = @{ Copy = $c; Root = $p } + $Record
            if (-not $recArgs.ContainsKey('Sha')) { $recArgs['Sha'] = (Get-CiHead $p) }
            $null = Write-CiRecord @recArgs
        }
        if ($Dirty) { Write-Utf8 (Join-Path $p 'uncommitted.txt') 'an edit CI has never seen' }
        $r = Fire -Copy $c -Cwd $p
        return [pscustomobject]@{ Out = [string]$r.Out; Blocked = ([string]$r.Out -match '"decision":"block"'); Root = $p; Copy = $c }
    }

    # The whole point: green CI, current commit, clean tree, newer than the failure.
    $ciOk = Invoke-CiCase -Name 'ciclear' -Record @{ Evidence = 'ci-green' }
    Check 'CI1: a green CI result for the current commit does not block' (-not $ciOk.Blocked) $ciOk.Out
    $ciHead = Get-CiHead $ciOk.Root
    Check 'CI1: and the notice names the commit it accepted, so the claim is checkable' (
        $ciOk.Out -match [regex]::Escape($ciHead.Substring(0, 7))) $ciOk.Out
    Check 'CI1: no durable note is demanded for a failure CI cleared' (
        $ciOk.Out -notmatch 'durable note') $ciOk.Out

    # =====================================================================
    Write-Host '--- CI2: every near-miss still blocks ---' -ForegroundColor Cyan
    $ciRed = Invoke-CiCase -Name 'cired' -Record @{ Outcome = 'failed'; Evidence = '' }
    Check 'CI2: a RED CI result still blocks' $ciRed.Blocked $ciRed.Out
    $ciPending = Invoke-CiCase -Name 'cipending' -Record @{ Outcome = 'pending'; Evidence = '' }
    Check 'CI2: a PENDING CI result still blocks' $ciPending.Blocked $ciPending.Out
    $ciNone = Invoke-CiCase -Name 'cinone'
    Check 'CI2: NO CI record at all still blocks - absence of evidence is not evidence' $ciNone.Blocked $ciNone.Out
    $ciOther = Invoke-CiCase -Name 'ciother' -Record @{ Sha = ('0' * 40); Evidence = 'ci-green' }
    Check 'CI2: a green result for a DIFFERENT commit still blocks' $ciOther.Blocked $ciOther.Out
    $ciDirty = Invoke-CiCase -Name 'cidirty' -Record @{ Evidence = 'ci-green' } -Dirty
    Check 'CI2: a dirty working tree still blocks' $ciDirty.Blocked $ciDirty.Out
    Check 'CI2: and the refusal says the tree has uncommitted changes' (
        $ciDirty.Out -match 'uncommitted changes') $ciDirty.Out
    # Evidence must be NEWER than what it excuses. The failure above ended 30
    # minutes ago, so a record observed 90 minutes ago never saw it.
    $ciStale = Invoke-CiCase -Name 'cistale' -Record @{ Evidence = 'ci-green'; AgeMinutes = 90 }
    Check 'CI2: a green result recorded BEFORE the failure ended still blocks' $ciStale.Blocked $ciStale.Out

    # The trap: Ci-Status-Check writes outcome 'verified' both for an observed
    # all-success AND for a project that has no CI to observe. Reading the two as
    # the same would silently disable this gate everywhere without workflows.
    $ciNoCi = Invoke-CiCase -Name 'cinoci' -Record @{ Evidence = 'no-ci' }
    Check 'CI2: "no CI configured" is NOT a green result and clears nothing' $ciNoCi.Blocked $ciNoCi.Out
    # An older Ci-Status-Check runtime writes three lines. Fails closed.
    $ciLegacy = Invoke-CiCase -Name 'cilegacy' -Record @{ LegacyThreeLine = $true }
    Check 'CI2: a pre-change three-line record clears nothing' $ciLegacy.Blocked $ciLegacy.Out

    # =====================================================================
    Write-Host '--- CI3: a hang is still a hang, whatever CI says ---' -ForegroundColor Cyan
    $ciTerm = Invoke-CiCase -Name 'citerm' -Record @{ Evidence = 'ci-green' } -Overall 'terminated' -ExitCode 124
    Check 'CI3: a TERMINATED run blocks even with a green CI result' $ciTerm.Blocked $ciTerm.Out
    Check 'CI3: and it still demands its durable note' (
        $ciTerm.Out -match 'Test incident:') $ciTerm.Out

    # =====================================================================
    Write-Host '--- CI4: the record itself, and what age does not change ---' -ForegroundColor Cyan
    # Age alone must not invalidate a green result: the commit has not moved, so
    # nothing about what CI saw has changed. Without this, adding a time-to-live
    # later would quietly undo the whole feature and nothing would notice.
    $ciOld = Invoke-CiCase -Name 'ciold' -Record @{ Evidence = 'ci-green'; AgeMinutes = 20 }
    Check 'CI4: an OLD green result for the current commit still clears' (-not $ciOld.Blocked) $ciOld.Out

    # A newer non-green observation overwrites the green one and wins.
    $cN = New-IsolatedHookCopy
    $pN = Initialize-CiRepo 'cinewer'
    $kN = Get-ProjectKey $pN
    Write-GuardedResult -Copy $cN -Root $pN -Overall 'failed' -ExitCode 1 -RunId ('cinewer-' + $kN) -CommandFingerprint ('cmdnewer' + $kN) -AgeMinutes 30
    $null = Write-CiRecord -Copy $cN -Root $pN -Sha (Get-CiHead $pN) -Evidence 'ci-green' -AgeMinutes 10
    $recPath = Write-CiRecord -Copy $cN -Root $pN -Sha (Get-CiHead $pN) -Outcome 'failed' -Evidence ''
    $rN = Fire -Copy $cN -Cwd $pN
    Check 'CI4: a newer non-green observation overrides the older green one' (
        [string]$rN.Out -match '"decision":"block"') $rN.Out

    # The record carries a commit, an outcome, a timestamp and one evidence word -
    # nothing else. Argued in the plan as non-secret by construction; this is what
    # makes the argument load-bearing rather than a claim.
    $recLines = @([System.IO.File]::ReadAllLines($recPath))
    Check 'CI4: the observation is exactly four lines, no other repository content' (
        $recLines.Count -eq 4 -and $recLines[0] -match '^[0-9a-f]{40}$' -and $recLines[1] -eq 'failed') (
        ($recLines -join ' | '))
