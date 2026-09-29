# Test-Wizard.ps1 scenario block: the sync-group and custom-hook install loops
# read the installer's STRUCTURED result. Both used to print "+ hook installed
# in" for every target whatever the installer reported. A state directory that
# is a FILE makes the real installer land the hook but fail registry tracking,
# which it reports as overall=partial without throwing - the exact case.
#
# Dot-sourced by Test-Wizard.ps1 into the caller's scope (uses its harness).

    Write-Host '--- install loops: a partial install is never reported as installed ---' -ForegroundColor Cyan
    $brokenState = Join-Path $Work 'state-is-a-file'
    [System.IO.File]::WriteAllText($brokenState, 'x')

    $cfgRes = Join-Path $Work 'cfg-install-result.json'; New-Config $cfgRes
    $resA = New-Proj 'ResultA'; $resB = New-Proj 'ResultB'
    $rGroup = Invoke-Wizard -Config $cfgRes -StateDir $brokenState -Answers @('1', '1', '2', $resA, $resB, 'done', '1', '', '0')
    Check 'sync group: a partial install prints no "+ hook installed in" line' (
        $rGroup.Exit -eq 0 -and $rGroup.Out -notmatch '\+ hook installed in') $rGroup.Out
    Check 'sync group: each partial target is named as NOT installed' (
        $rGroup.Out -match 'x NOT installed in ResultA' -and $rGroup.Out -match 'x NOT installed in ResultB') $rGroup.Out
    Check 'sync group: the failures are summarised' ($rGroup.Out -match '2 install\(s\) did NOT succeed') $rGroup.Out

    $resHook = 'ZZZ-InstallResult'
    $resHookFolder = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks') $resHook
    $resC = New-Proj 'ResultC'; $resD = New-Proj 'ResultD'
    try {
        $rCustom = Invoke-Wizard -Config $cfgRes -StateDir $brokenState -Answers @('1', '2', $resHook, '5', 'y', '', $resC, 'done', 'y', '0', '0')
        Check 'custom hook: a partial install prints no "+ hook installed in" line' (
            $rCustom.Exit -eq 0 -and $rCustom.Out -notmatch '\+ hook installed in') $rCustom.Out
        Check 'custom hook: the completion line reports the failure instead of success' (
            $rCustom.Out -match 'x NOT installed in ResultC' -and $rCustom.Out -match 'installed in 0 of 1 project\(s\); 1 did NOT succeed' -and
            $rCustom.Out -notmatch ($resHook + '\.ps1 installed for:')) $rCustom.Out
        # Control: the same flow with a working state directory still succeeds,
        # so the assertions above cannot pass on a flow that never installs.
        Remove-Item -LiteralPath $resHookFolder -Recurse -Force -ErrorAction SilentlyContinue
        $rCustomOk = Invoke-Wizard -Config $cfgRes -Answers @('1', '2', $resHook, '5', 'y', '', $resD, 'done', 'y', '0', '0')
        Check 'custom hook control: a clean install still prints the success line' (
            $rCustomOk.Out -match '\+ hook installed in ResultD' -and $rCustomOk.Out -match ($resHook + '\.ps1 installed for:')) $rCustomOk.Out
    }
    finally {
        Remove-Item -LiteralPath $resHookFolder -Recurse -Force -ErrorAction SilentlyContinue
        Check 'the ZZZ-InstallResult fixture was removed from the real hooks directory' (-not (Test-Path -LiteralPath $resHookFolder)) $resHookFolder
    }
