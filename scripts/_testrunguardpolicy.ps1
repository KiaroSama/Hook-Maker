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
    # Optimization/cadence/CI/private/local exceptions/native bounds/waits now
    # live behind one mandatory full owner before runs. These assertions prove
    # the pointer and inline owner lifetime, not private rule contents or execution.
    Check 'the deny requires complete test policy before any run' (
        $msgDd -match 'BEFORE runs: global-test-rules\.md FULL') $msgDd
    Check 'the deny keeps guarded lifetime and forbids background wrappers' (
        $msgDd -match 'Guard owns lifetime; no background wrapper') $msgDd
    # The cadence text is GUIDANCE on the note: it never reaches the command.
    $replDd = Get-Replacement $msgDd
    Check 'the cadence line rides the note, never the replacement command' (
        $replDd -match 'Run-Tests-Guarded\.ps1' -and $replDd -notmatch 'Cadence' -and
        $replDd -notmatch 'CI first') $replDd
    Check 'a command with no file redirect gets NO UTF-8 output note' ($msgDd -notmatch 'Text:') $msgDd

    # =====================================================================
    Write-Host '--- E-04: UTF-8 output advice only when the command VISIBLY writes a text file ---' -ForegroundColor Cyan
    $hcU1 = New-IsolatedHookCopy
    $rU1 = Fire -HookPath $hcU1.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/ > results.txt' -LocalAppData $hcU1.LocalAppData
    $msgU1 = Get-Message $rU1.Out
    Check 'a "> file" redirect on a recognised test command adds the UTF-8 output note' (
        $msgU1 -match 'Text:' -and $msgU1 -match '-Encoding utf8' -and $msgU1 -match 'PYTHONUTF8=1') $msgU1
    Check 'the note names ONLY official syntax and forbids invented flags' (
        $msgU1 -match 'UTF-8' -and $msgU1 -match 'Documented flags only' -and
        $msgU1 -notmatch '--encoding') $msgU1
    Check 'the note defers file validation to Utf8-Encoding-Check' ($msgU1 -match 'Utf8-Encoding-Check validates') $msgU1
    $hcU2 = New-IsolatedHookCopy
    $rU2 = Fire -HookPath $hcU2.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/ > $null' -LocalAppData $hcU2.LocalAppData
    Check 'a redirect to $null is NOT "maintained textual output" (no UTF-8 note)' ((Get-Message $rU2.Out) -notmatch 'Text:') (Get-Message $rU2.Out)
    $hcU3 = New-IsolatedHookCopy
    $rU3 = Fire -HookPath $hcU3.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q | tee out.log' -LocalAppData $hcU3.LocalAppData
    Check 'a tee into a file also gets the UTF-8 output note' ((Get-Message $rU3.Out) -match 'Text:') (Get-Message $rU3.Out)
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
    # The SHAPE of that JSON, not merely its presence. This assertion existed and
    # passed all along while the emitted command was unusable on this host: the
    # old `, @($Arguments) | ConvertTo-Json` is host-dependent, and 5.1 wraps the
    # comma-built array in a PSObject, emitting {"value":[...],"Count":N}. The
    # runner then rejects the hook's OWN suggestion with "must be a JSON ARRAY",
    # so on a 5.1-hosted install (the default registration) the replacement could
    # never work for any argument count. Reported from real use.
    $json51 = ''
    if ($replacement -match "-ArgumentsJson\s+'([^']*)'") { $json51 = $Matches[1] }
    Check '5.1: the emitted -ArgumentsJson is a JSON ARRAY, not a PSObject wrapper' (
        $json51 -ne '' -and $json51.TrimStart().StartsWith('[')) ('json=' + $json51)
    Check '5.1: it carries no value/Count wrapper properties' (
        $json51 -notmatch '"value"\s*:' -and $json51 -notmatch '"Count"\s*:') ('json=' + $json51)
    $roundTrip51 = @()
    try { $roundTrip51 = @($json51 | ConvertFrom-Json) } catch { }
    Check '5.1: it round-trips to the ORIGINAL arguments, in order' (
        (@($roundTrip51) -join '|') -eq '-q|tests/') ((@($roundTrip51) -join '|') + ' from ' + $json51)
    # A SINGLE argument is the case the unary comma existed to protect; prove the
    # replacement keeps it an array on this host too.
    #
    # Its OWN isolated hook copy on purpose: every PreToolUse firing writes an
    # observed record, and Get-ObservedRecord below deliberately returns $null
    # when it finds more than one. Probing on $hc51 would break that assertion -
    # and it would look like a product regression rather than test pollution.
    $hcOne51 = New-IsolatedHookCopy
    $rOne51 = Fire -HookPath $hcOne51.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest' -LocalAppData $hcOne51.LocalAppData -Exe 'powershell.exe'
    $oneReplacement51 = Get-Replacement (Get-Message $rOne51.Out)
    $oneJson51 = ''
    if ($oneReplacement51 -match "-ArgumentsJson\s+'([^']*)'") { $oneJson51 = $Matches[1] }
    Check '5.1: a single-argument command still emits a JSON ARRAY' (
        $oneJson51.TrimStart().StartsWith('[') -and $oneJson51 -notmatch '"value"\s*:') ('json=' + $oneJson51)
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

    # =====================================================================
    Write-Host '--- V45: the deny ends with the LANGUAGE line when the session records Persian ---' -ForegroundColor Cyan
    # Its own parent directory, so the full shared library set (which the other
    # isolated copies deliberately lack) cannot change their behaviour.
    $rlRoot = Join-Path $Work 'rl-deny'
    $rlDir = Join-Path $rlRoot 'Test-Run-Guard'
    New-Item -ItemType Directory -Path $rlDir -Force | Out-Null
    Copy-HookPackage -Destination $rlDir
    Copy-TestRuntimeLibraries -SourceHookLib $HookLib -Destination (Join-Path $rlRoot '_hooklib.ps1')
    $rlLocal = Join-Path $rlRoot '_fakelocal'
    $rlState = Join-Path $rlLocal 'HookMaker\state'
    New-Item -ItemType Directory -Path $rlState -Force | Out-Null
    $rlKey = & { . $HookLib; Get-ShortHash 'sess1' }
    [System.IO.File]::WriteAllText((Join-Path $rlState ('ReplyLanguage-' + $rlKey + '.txt')), 'persian')
    $rRl = Fire -HookPath (Join-Path $rlDir 'Test-Run-Guard.ps1') -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/' -LocalAppData $rlLocal
    $msgRl = Get-Message $rRl.Out
    Check 'RL-D1 the deny still denies and its text ends with the LANGUAGE line' (
        $rRl.Out -match '"permissionDecision":"deny"' -and
        $msgRl.TrimEnd().EndsWith('Output is untranslated.') -and
        $msgRl -match 'LANGUAGE: replies/progress Persian') $msgRl
    [System.IO.File]::Delete((Join-Path $rlState ('ReplyLanguage-' + $rlKey + '.txt')))
    $rRl = Fire -HookPath (Join-Path $rlDir 'Test-Run-Guard.ps1') -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/' -LocalAppData $rlLocal
    Check 'RL-D2 with no recorded language the deny carries no LANGUAGE line' (
        $rRl.Out -match '"permissionDecision":"deny"' -and (Get-Message $rRl.Out) -notmatch 'LANGUAGE:') $rRl.Out

