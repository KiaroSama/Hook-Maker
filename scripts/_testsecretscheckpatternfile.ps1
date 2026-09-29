# Test-SecretsCheck.ps1 scenario block: secret VALUES never go on a git command
# line. The leak scans hand them to `git grep -f` through a per-scan pattern
# file under the user's local state, removed after the scan; command lines are
# visible to every process of the user and land in process-creation audit logs.
#
# Dot-sourced by Test-SecretsCheck.ps1 into the caller's scope (uses its Fire,
# Check, New-GitProj, Add-Commit, New-ConfiguredHookCopy, $Hook, $FakeAppData).

    Write-Host '--- secret values reach git grep through a pattern file, never argv ---' -ForegroundColor Cyan
    $hookLines = @([System.IO.File]::ReadAllLines($Hook))
    $inFallback = $false; $argvValueLines = @()
    foreach ($line in $hookLines) {
        if ($line -match "Get-Command -Name 'Invoke-GitGrepWithValue'") { $inFallback = $true; continue }
        if ($inFallback) { if ($line -match '^\}') { $inFallback = $false }; continue }
        if ($line -match 'Invoke-QuietCommand' -and $line -match '\$[Vv]alue\b') { $argvValueLines += $line.Trim() }
    }
    Check 'source: outside the fallback no Invoke-QuietCommand call carries a secret value' ($argvValueLines.Count -eq 0) ($argvValueLines -join ' || ')

    # A value that starts with '-' is the case the old '-e' disambiguation existed for.
    $dashProj = New-GitProj 'PatternFileDash'
    Write-Utf8 (Join-Path $dashProj '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $dashProj '.env') "DASH_SECRET=-Abcdefghij1234567890zz`r`n"
    Write-Utf8 (Join-Path $dashProj 'notes.txt') "pasted: -Abcdefghij1234567890zz by mistake`r`n"
    Add-Commit $dashProj 'seed'
    $patternState = Join-Path $FakeAppData 'HookMaker\state'
    $r = Fire -Cwd $dashProj
    Check 'a leaked value starting with - is still found through the pattern file' ($r.Out -like '*DASH_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
    Check 'the dash-value report never contains the raw value' ($r.Out -notlike '*Abcdefghij1234567890zz*') $r.Out
    $residue = @(Get-ChildItem -LiteralPath $patternState -Filter 'SecretsCheck-pattern-*' -File -ErrorAction SilentlyContinue)
    Check 'no pattern file is left behind after the scan' ($residue.Count -eq 0) (($residue | ForEach-Object { $_.Name }) -join ', ')

    # An installed runtime copied before the sibling existed keeps detecting.
    $fallbackHook = New-ConfiguredHookCopy -EnvOverrides @{}
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $fallbackHook) '_patternfile.ps1') -Force
    $fallbackProj = New-GitProj 'PatternFileFallback'
    Write-Utf8 (Join-Path $fallbackProj '.gitignore') ".env`nsecrets.md`n"
    Write-Utf8 (Join-Path $fallbackProj '.env') "DASH_SECRET=-Abcdefghij1234567890zz`r`n"
    Write-Utf8 (Join-Path $fallbackProj 'notes.txt') "pasted: -Abcdefghij1234567890zz by mistake`r`n"
    Add-Commit $fallbackProj 'seed'
    $r = Fire -Cwd $fallbackProj -HookPath $fallbackHook
    Check 'fallback: without _patternfile.ps1 the leak is still detected' ($r.Out -like '*DASH_SECRET*appears in a git-tracked file*notes.txt*') $r.Out
