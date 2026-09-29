# Test-TestTempCleanup.ps1 scenario block: the batched git-state table answers
# EXACTLY what the per-path Get-GitCandidateState answers, for every state and
# path shape, across batches, and never guesses when git is unavailable. A
# wrong 'untracked' is a deletable tracked file, so equivalence is the contract.
#
# Dot-sourced by Test-TestTempCleanup.ps1 into the caller's scope (uses Check,
# $Work) - not a standalone suite.

    Write-Host '--- batched git state equals the per-path answer ---' -ForegroundColor Cyan
    $cleanupHookDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Test-Temp-Cleanup'
    . (Join-Path $cleanupHookDir '_gitstate.ps1')
    $entryAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $cleanupHookDir 'Test-Temp-Cleanup.ps1'), [ref]$null, [ref]$null)
    $perPathFn = $entryAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GitCandidateState' }, $true)
    . ([scriptblock]::Create($perPathFn.Extent.Text))

    $gsRepo = Join-Path $Work 'gitstate-repo'
    New-Item -ItemType Directory -Path $gsRepo -Force | Out-Null
    & git -C $gsRepo init -q
    & git -C $gsRepo config user.email 't@t'; & git -C $gsRepo config user.name 't'; & git -C $gsRepo config core.autocrlf false
    [System.IO.File]::WriteAllText((Join-Path $gsRepo '.gitignore'), "*.log`n!keep.log`nignored-dir/`n")
    foreach ($f in @('tracked.txt', 'staged.txt', 'untracked.txt', 'x.log', 'keep.log', 'Tracked Space.txt')) { [System.IO.File]::WriteAllText((Join-Path $gsRepo $f), 'v1') }
    foreach ($d in @('tracked-dir', 'untracked-dir', 'ignored-dir')) { New-Item -ItemType Directory -Path (Join-Path $gsRepo $d) -Force | Out-Null; [System.IO.File]::WriteAllText((Join-Path $gsRepo ($d + '\inner.txt')), 'v1') }
    & git -C $gsRepo add .gitignore tracked.txt staged.txt 'Tracked Space.txt' tracked-dir/inner.txt
    & git -C $gsRepo commit -q -m seed
    [System.IO.File]::WriteAllText((Join-Path $gsRepo 'staged.txt'), 'v2')
    & git -C $gsRepo add staged.txt
    $gsPaths = @('tracked.txt', 'staged.txt', 'untracked.txt', 'x.log', 'keep.log', 'Tracked Space.txt', 'tracked-dir', 'untracked-dir', 'ignored-dir')
    $gsTable = Get-GitCandidateStateTable -Root $gsRepo -RelPaths $gsPaths -GitAvailable $true
    $gsMismatch = @()
    foreach ($p in $gsPaths) {
        $single = Get-GitCandidateState -Root $gsRepo -RelPath $p -GitAvailable $true
        if ($gsTable[$p] -ne $single) { $gsMismatch += ($p + ': table=' + $gsTable[$p] + ' per-path=' + $single) }
    }
    Check 'every state (tracked, staged, untracked, ignored, negated, dirs, spaces) matches the per-path answer' ($gsMismatch.Count -eq 0) ($gsMismatch -join ' | ')
    # A case-only variant of a tracked file: the per-path pathspec is case-sensitive
    # and would call it untracked (deletable); the table is the safer of the two.
    $caseTable = Get-GitCandidateStateTable -Root $gsRepo -RelPaths @('TRACKED.TXT') -GitAvailable $true
    Check 'a case-only variant of a tracked file is never classified untracked' ($caseTable['TRACKED.TXT'] -eq 'tracked') ([string]$caseTable['TRACKED.TXT'])
    Check 'the fixture really covers all four resolved states' (
        $gsTable['tracked.txt'] -eq 'tracked' -and $gsTable['staged.txt'] -eq 'staged' -and $gsTable['untracked.txt'] -eq 'untracked' -and
        $gsTable['x.log'] -eq 'ignored' -and $gsTable['keep.log'] -eq 'untracked' -and $gsTable['tracked-dir'] -eq 'tracked') (($gsTable.Keys | ForEach-Object { $_ + '=' + $gsTable[$_] }) -join ', ')

    # Enough long names to force more than one command-line batch.
    $longDir = Join-Path $gsRepo 'many'
    New-Item -ItemType Directory -Path $longDir -Force | Out-Null
    $longPaths = @()
    foreach ($i in 1..300) {
        $name = ('residue-' + $i.ToString('000') + '-' + ('x' * 40) + '.tmp')
        [System.IO.File]::WriteAllText((Join-Path $longDir $name), 'r')
        $longPaths += ('many\' + $name)
    }
    $longTable = Get-GitCandidateStateTable -Root $gsRepo -RelPaths $longPaths -GitAvailable $true
    Check 'batched: 300 long untracked paths (several batches) are all untracked' (@($longPaths | Where-Object { $longTable[$_] -ne 'untracked' }).Count -eq 0) (
        @($longPaths | Where-Object { $longTable[$_] -ne 'untracked' } | Select-Object -First 3) -join ', ')
    $noGit = Get-GitCandidateStateTable -Root $gsRepo -RelPaths $gsPaths -GitAvailable $false
    Check 'git unavailable: every entry is unknown, never guessed' (@($gsPaths | Where-Object { $noGit[$_] -ne 'unknown' }).Count -eq 0)
