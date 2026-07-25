# Test-TestRunGuard.ps1 scenario block: the POLICY GUIDANCE the deny text
# carries (E-04 deep-debug/test-policy bounds, the conditional UTF-8 output
# note), the hook's static safety (E-13), irrelevant events, proof that the
# real user settings are never touched, and the Windows PowerShell 5.1 host.
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- E-04: the deny text states the deep-debug/test-policy bounds (guidance only) ---' -ForegroundColor Cyan
    $hcDd = New-IsolatedHookCopy
    $rDd = Fire -HookPath $hcDd.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/' -LocalAppData $hcDd.LocalAppData
    $msgDd = Get-Message $rDd.Out
    Check 'the deny still denies (guard behavior unchanged by the guidance line)' ($rDd.Out -match '"permissionDecision":"deny"') $rDd.Out
    Check 'the deny names the deep-debug bounds the replacement enforces' (
        $msgDd -match 'Deep-debug/test-policy bounds' -and $msgDd -match 'outer wall \+ idle' -and
        $msgDd -match 'shared worker ceiling' -and $msgDd -match 'process-tree cleanup' -and
        $msgDd -match 'exit-code propagation' -and $msgDd -match 'no ad hoc sleeps') $msgDd
    Check 'the deny tells the model to use only a documented native timeout flag, never a guessed one' (
        $msgDd -match 'documents its OWN native timeout flag' -and $msgDd -match 'never a guessed one') $msgDd
    Check 'a command with no file redirect gets NO UTF-8 output note' ($msgDd -notmatch 'WRITES textual output') $msgDd

    # =====================================================================
    Write-Host '--- E-04: UTF-8 output advice only when the command VISIBLY writes a text file ---' -ForegroundColor Cyan
    $hcU1 = New-IsolatedHookCopy
    $rU1 = Fire -HookPath $hcU1.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/ > results.txt' -LocalAppData $hcU1.LocalAppData
    $msgU1 = Get-Message $rU1.Out
    Check 'a "> file" redirect on a recognised test command adds the UTF-8 output note' (
        $msgU1 -match 'WRITES textual output' -and $msgU1 -match '-Encoding utf8' -and $msgU1 -match 'PYTHONUTF8=1') $msgU1
    Check 'the note names ONLY official syntax and forbids invented flags' (
        $msgU1 -match 'OFFICIAL syntax' -and $msgU1 -match 'Never invent an encoding flag' -and
        $msgU1 -notmatch '--encoding') $msgU1
    Check 'the note defers file validation to Utf8-Encoding-Check' ($msgU1 -match 'Utf8-Encoding-Check validates the files') $msgU1
    $hcU2 = New-IsolatedHookCopy
    $rU2 = Fire -HookPath $hcU2.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/ > $null' -LocalAppData $hcU2.LocalAppData
    Check 'a redirect to $null is NOT "maintained textual output" (no UTF-8 note)' ((Get-Message $rU2.Out) -notmatch 'WRITES textual output') (Get-Message $rU2.Out)
    $hcU3 = New-IsolatedHookCopy
    $rU3 = Fire -HookPath $hcU3.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q | tee out.log' -LocalAppData $hcU3.LocalAppData
    Check 'a tee into a file also gets the UTF-8 output note' ((Get-Message $rU3.Out) -match 'WRITES textual output') (Get-Message $rU3.Out)
    # The E-04 additions must not create a NEW recognition path: an unrelated
    # command that merely redirects stays totally silent.
    $hcU4 = New-IsolatedHookCopy
    $rU4 = Fire -HookPath $hcU4.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'git status --porcelain > status.txt' -LocalAppData $hcU4.LocalAppData
    Check 'an unrelated command with a redirect is still totally silent' ($rU4.Exit -eq 0 -and $rU4.Out -eq '' -and $rU4.Err -eq '') ($rU4.Out + '|' + $rU4.Err)

    # =====================================================================
    Write-Host '--- E-13: static safety - the hook never executes commands, codewords, or skills ---' -ForegroundColor Cyan
    $trgText = [System.IO.File]::ReadAllText($Hook)
    Check 'source has no execution primitive in statement position (Start-Process/Invoke-Expression/iex)' (
        $trgText -notmatch '(?im)^\s*(Start-Process|Invoke-Expression|iex)\b') $trgText.Substring(0, 200)
    Check 'source never applies the call operator to data (no "& $var" execution path)' ($trgText -notmatch '&\s+\$') $trgText.Substring(0, 200)
    Check 'source references no slash command in statement position' ($trgText -notmatch '(?im)^\s*/(goal|ponytail)') $trgText.Substring(0, 200)

    # =====================================================================
    Write-Host '--- irrelevant events are ignored ---' -ForegroundColor Cyan
    foreach ($otherEvent in @('Stop', 'SessionStart', 'UserPromptSubmit')) {
        $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName $otherEvent -Command 'pytest -q' -LocalAppData $hc.LocalAppData
        Check ('silent on the unrelated event ' + $otherEvent) ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }

    # =====================================================================
    Write-Host '--- real settings and real state are never touched ---' -ForegroundColor Cyan
    $realClaude = Join-Path $env:USERPROFILE '.claude\settings.json'
    $beforeBytes = if (Test-Path -LiteralPath $realClaude -PathType Leaf) { [System.IO.File]::ReadAllBytes($realClaude) } else { $null }
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hc.LocalAppData
    $afterBytes = if (Test-Path -LiteralPath $realClaude -PathType Leaf) { [System.IO.File]::ReadAllBytes($realClaude) } else { $null }
    $sameBytes = if ($null -eq $beforeBytes -and $null -eq $afterBytes) { $true }
    elseif ($null -eq $beforeBytes -or $null -eq $afterBytes) { $false }
    else { [System.Linq.Enumerable]::SequenceEqual([byte[]]$beforeBytes, [byte[]]$afterBytes) }
    Check 'the real ~\.claude\settings.json is byte-identical' $sameBytes

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $hc51 = New-IsolatedHookCopy
    $r = Fire -HookPath $hc51.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'git status' -LocalAppData $hc51.LocalAppData -Exe 'powershell.exe'
    Check '5.1: an unrelated command is silent and error-free' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + '|' + $r.Err)
    $r = Fire -HookPath $hc51.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/' -LocalAppData $hc51.LocalAppData -Exe 'powershell.exe'
    $replacement = Get-Replacement (Get-Message $r.Out)
    Check '5.1: a raw test command is blocked with a valid -ArgumentsJson replacement' ($r.Err -eq '' -and $replacement -match '-ArgumentsJson') ($replacement + '|' + $r.Err)
    # Write-ObservedRecord swallows its own errors by design, so a 5.1-only
    # breakage would otherwise be invisible. Prove the record really lands.
    $observed51 = Get-ObservedRecord $hc51.LocalAppData
    Check '5.1: the coordination handoff record is written and parseable' (
        $null -ne $observed51 -and $observed51.Document.guarded -eq $false -and
        $null -ne (ConvertTo-UtcTimeLikeConsumer $observed51.Document.observedUtc))
    $null = New-ResultDocument -LocalAppData $hc51.LocalAppData -ProjectRoot $Proj -Fields @{
        overall = 'terminated'; exitCode = 124; terminated = $true; terminateReason = 'wallTimeout'
        terminateDetail = 'exceeded the 1800s wall ceiling'; lastProgress = 'suite 2 of 9'
    }
    $r = Fire -HookPath $hc51.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hc51.LocalAppData -Exe 'powershell.exe'
    Check '5.1: PostToolUse reports the termination cleanly' ($r.Exit -eq 0 -and $r.Err -eq '' -and (Get-Message $r.Out) -match 'wallTimeout') ($r.Out + '|' + $r.Err)
