# Test-TestRunGuard.ps1 scenario block: PreToolUse RECOGNITION and the
# replacement it emits - real test commands recognised, the false-positive
# guard (total silence on ordinary work), the guarded replacement proven
# executable end to end, the HOOKMAKER_MAX_TEST_WORKERS ceiling reaching a
# real child, no double-wrapping, the blind-wait deny set, metacharacter
# survival, the hook's static safety, advisory mode, and .env handling.
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- conservative recognition: real test commands ARE recognised ---' -ForegroundColor Cyan
    $hc = New-IsolatedHookCopy
    $recognised = @(
        'pytest -q tests/',
        'python -m pytest tests/unit',
        'npm test',
        'npm run test:unit',
        'cargo test --all',
        'go test ./...',
        'dotnet test MySolution.sln',
        'npx --no-install vitest run',
        'pwsh -NoProfile -File .\scripts\Run-Tests.ps1',
        'pwsh -NoProfile -File .\scripts\Test-RulesCheck.ps1'
    )
    foreach ($command in $recognised) {
        $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command $command -LocalAppData $hc.LocalAppData
        $message = Get-Message $r.Out
        Check ('recognised as a test command: ' + $command) ($message -match 'TEST RUN GUARD') ($r.Out + '|' + $r.Err)
    }

    # =====================================================================
    Write-Host '--- FALSE-POSITIVE GUARD: unrelated commands are TOTALLY silent ---' -ForegroundColor Cyan
    $unrelated = @(
        'git commit -m "add a test for the parser"',
        'git status --porcelain',
        'npm run build',
        'npm install --no-audit',
        'cargo build --release',
        'go vet ./...',
        'dotnet build',
        'Copy-Item .\tests\fixtures\sample.json .\out\sample.json',
        'cat src/testdata/latest-test-results.txt',
        'ls ./test',
        'docker build -t app:latest .',
        'gh pr list --limit 5',
        'python .\tools\generate-test-fixtures.py',
        'code .\scripts\Test-RulesCheck.ps1',
        'echo pytest'
    )
    foreach ($command in $unrelated) {
        $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command $command -LocalAppData $hc.LocalAppData
        Check ('total silence on: ' + $command) ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + '|' + $r.Err)
    }

    # =====================================================================
    Write-Host '--- a recognised RAW command is blocked with a VALID guarded replacement ---' -ForegroundColor Cyan
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q tests/' -LocalAppData $hc.LocalAppData
    $message = Get-Message $r.Out
    Check 'output is exactly one parseable JSON document' (Test-IsSingleJson $r.Out) $r.Out
    Check 'Claude shape denies via permissionDecision' ($r.Out -match '"permissionDecision":"deny"') $r.Out
    $replacement = Get-Replacement $message
    Check 'a replacement invocation is returned' ($replacement -ne '') $message
    Check 'the replacement uses -ArgumentsJson, NEVER -Arguments' ($replacement -match '-ArgumentsJson' -and $replacement -notmatch '-Arguments\s') $replacement
    Check 'the replacement goes through Run-Tests-Guarded.ps1' ($replacement -match 'Run-Tests-Guarded\.ps1') $replacement
    Check 'the replacement carries the wall and idle ceilings' ($replacement -match '-TimeoutSeconds 1800' -and $replacement -match '-IdleTimeoutSeconds 300') $replacement
    Check 'the replacement carries a -ResultPath the PostToolUse side can read' ($replacement -match '-ResultPath') $replacement
    Check 'the ArgumentsJson is a JSON ARRAY of the original arguments' ($replacement -match '\[\\?"-q\\?",\\?"tests/\\?"\]' -or $replacement -match '\["-q","tests/"\]') $replacement

    # The replacement is not merely plausible - the hook's OWN emitted text is
    # executed verbatim and must work. Bounded: the child exits immediately and
    # every ceiling stays in seconds.
    Write-Host '--- the hook''s own replacement text is executable end-to-end ---' -ForegroundColor Cyan
    $hcProbe = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_WALL_TIMEOUT_SECONDS = '60'; TEST_GUARD_IDLE_TIMEOUT_SECONDS = '30'; TEST_GUARD_HEARTBEAT_SECONDS = '1' }
    $probeSuite = Join-Path $Proj 'scripts\Test-Probe.ps1'
    Write-Utf8 $probeSuite "param([string]`$Tag)`nWrite-Host ('probe ran with tag=' + `$Tag)`nexit 7`n"
    $probeCommand = 'pwsh -NoProfile -File "' + $probeSuite + '" -Tag "a b|c&d"'
    $r = Fire -HookPath $hcProbe.Script -Cwd $Proj -EventName 'PreToolUse' -Command $probeCommand -LocalAppData $hcProbe.LocalAppData
    $probeReplacement = Get-Replacement (Get-Message $r.Out)
    Check 'the probe command is recognised and a replacement returned' ($probeReplacement -match '-ArgumentsJson') $probeReplacement
    $probeRunner = Join-Path $Work 'run-replacement.ps1'
    Write-Utf8 $probeRunner ($probeReplacement + "`nexit `$LASTEXITCODE`n")
    # The worker ceiling rides along on this same run - the child inherits the
    # variable, so no second process is needed. A ceiling of 1 is used because
    # it clamps on ANY machine: the natural budget is max(2, ...) >= 2, so
    # min(budget, 1) is 1 on a 2-core runner and a 32-core workstation alike.
    # Asserting against a larger ceiling would pass vacuously wherever the
    # natural budget already sat below it.
    $previousWorkerCeiling = $env:HOOKMAKER_MAX_TEST_WORKERS
    $env:HOOKMAKER_MAX_TEST_WORKERS = '1'
    try {
        $runnerProc = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru `
            -ArgumentList @('-NoLogo', '-NoProfile', '-File', $probeRunner)
    }
    finally {
        $env:HOOKMAKER_MAX_TEST_WORKERS = $previousWorkerCeiling
    }
    Check 'the emitted replacement runs and propagates the child exit code (7)' ($runnerProc.ExitCode -eq 7) ([string]$runnerProc.ExitCode)
    $probeResult = Join-Path $hcProbe.LocalAppData 'HookMaker\state'
    $probeResultFile = @(Get-ChildItem -LiteralPath $probeResult -Filter 'TestRunGuard-result-*.json' -ErrorAction SilentlyContinue)
    Check 'the replacement wrote its result document to the hook-declared -ResultPath' ($probeResultFile.Count -eq 1)
    Check 'the result filename is PER-RUN (key + runId), so concurrent runs never collide' (
        $probeResultFile.Count -eq 1 -and $probeResultFile[0].Name -match '^TestRunGuard-result-[a-z0-9]+-[a-z0-9]+\.json$') $(if ($probeResultFile.Count -eq 1) { $probeResultFile[0].Name } else { 'none' })
    $probeDoc = Get-Content -LiteralPath $probeResultFile[0].FullName -Raw | ConvertFrom-Json
    Check 'the result document records the failure, not a pass' ($probeDoc.overall -eq 'failed' -and $probeDoc.exitCode -eq 7) $probeDoc.overall
    Check 'the metacharacter argument survived as ONE argument, unevaluated' ($probeDoc.lastProgress -match 'tag=a b\|c&d') $probeDoc.lastProgress
    Check 'the result document records no argument VALUES' (($probeDoc | ConvertTo-Json -Depth 6) -notmatch '-Tag') ([string]$probeDoc.argumentCount)
    Check 'HOOKMAKER_MAX_TEST_WORKERS clamps the reported worker budget' ($probeDoc.workerBudget -eq 1) ([string]$probeDoc.workerBudget)

    # ... and the very next PostToolUse consumes exactly that document.
    $r = Fire -HookPath $hcProbe.Script -Cwd $Proj -EventName 'PostToolUse' -Command $probeCommand -LocalAppData $hcProbe.LocalAppData
    Check 'PostToolUse reads the real document the replacement produced' ((Get-Message $r.Out) -match 'exit code 7') $r.Out

    # =====================================================================
    # HM-05: the resolved worker ceiling is ENFORCED end-to-end, not just advised.
    # =====================================================================
    Write-Host '--- the worker ceiling rides the replacement AND reaches a real child ---' -ForegroundColor Cyan

    # Unit: TEST_GUARD_MAX_WORKERS is handed to the runner as -MaxWorkers; 0 omits it.
    $hcCap = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_MAX_WORKERS = '3' }
    $rCap = Fire -HookPath $hcCap.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcCap.LocalAppData
    $capRepl = Get-Replacement (Get-Message $rCap.Out)
    Check 'TEST_GUARD_MAX_WORKERS is passed to the runner as -MaxWorkers' ($capRepl -match '-MaxWorkers 3') $capRepl
    $rNoCap = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hc.LocalAppData
    $noCapRepl = Get-Replacement (Get-Message $rNoCap.Out)
    Check 'no cap => no -MaxWorkers flag (0 is omitted, never a guessed default)' ($noCapRepl -notmatch '-MaxWorkers') $noCapRepl

    # Integration: with the cap set and NO ambient HOOKMAKER_MAX_TEST_WORKERS, the
    # runner both REPORTS the ceiling and EXPORTS it into the child that actually
    # runs. The child prints the value it inherited, so a value of 1 can only have
    # arrived via -MaxWorkers -> Get-GuardedWorkerBudget -> the child's environment.
    $hcExport = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_MAX_WORKERS = '1'; TEST_GUARD_WALL_TIMEOUT_SECONDS = '60'; TEST_GUARD_IDLE_TIMEOUT_SECONDS = '30'; TEST_GUARD_HEARTBEAT_SECONDS = '1' }
    $workerSuite = Join-Path $Proj 'scripts\Test-WorkerProbe.ps1'
    Write-Utf8 $workerSuite "Write-Host ('WORKERS=' + `$env:HOOKMAKER_MAX_TEST_WORKERS)`nexit 0`n"
    $workerCommand = 'pwsh -NoProfile -File "' + $workerSuite + '"'
    $rExp = Fire -HookPath $hcExport.Script -Cwd $Proj -EventName 'PreToolUse' -Command $workerCommand -LocalAppData $hcExport.LocalAppData
    $expRepl = Get-Replacement (Get-Message $rExp.Out)
    Check 'the export replacement carries -MaxWorkers 1' ($expRepl -match '-MaxWorkers 1') $expRepl
    $expRunner = Join-Path $Work 'run-export.ps1'
    Write-Utf8 $expRunner ($expRepl + "`nexit `$LASTEXITCODE`n")
    $prevAmbient = $env:HOOKMAKER_MAX_TEST_WORKERS
    $env:HOOKMAKER_MAX_TEST_WORKERS = ''         # prove the value can ONLY come from -MaxWorkers
    try {
        $expProc = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru `
            -ArgumentList @('-NoLogo', '-NoProfile', '-File', $expRunner)
    }
    finally {
        $env:HOOKMAKER_MAX_TEST_WORKERS = $prevAmbient
    }
    Check 'the export replacement ran and propagated the child exit code (0)' ($expProc.ExitCode -eq 0) ([string]$expProc.ExitCode)
    $expFile = @(Get-ChildItem -LiteralPath (Join-Path $hcExport.LocalAppData 'HookMaker\state') -Filter 'TestRunGuard-result-*.json' -ErrorAction SilentlyContinue)
    Check 'the export run wrote its result document' ($expFile.Count -eq 1)
    $expDoc = Get-Content -LiteralPath $expFile[0].FullName -Raw | ConvertFrom-Json
    Check 'the runner resolved the ceiling from -MaxWorkers alone (workerBudget=1)' ($expDoc.workerBudget -eq 1) ([string]$expDoc.workerBudget)
    Check 'the exported ceiling reached the real child (child saw HOOKMAKER_MAX_TEST_WORKERS=1)' ($expDoc.lastProgress -match 'WORKERS=1') $expDoc.lastProgress

    # =====================================================================
    Write-Host '--- an already-guarded command passes untouched (no double wrap) ---' -ForegroundColor Cyan
    $guardedCommand = 'pwsh -NoProfile -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -ArgumentsJson ''["-File",".\scripts\Run-Tests.ps1"]'' -TimeoutSeconds 900'
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command $guardedCommand -LocalAppData $hc.LocalAppData
    Check 'an already-guarded invocation is silent, never re-wrapped' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pwsh -File scripts\Run-Tests-Guarded.ps1 -FilePath pytest -ArgumentsJson ''["-q"]''' -LocalAppData $hc.LocalAppData
    Check 'a guarded invocation whose payload is pytest is still not re-wrapped' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    # HM-06: DIRECT ad hoc blind waits are denied with an EXACT safe pattern; short,
    # bounded, GNU-timeout-bounded and nested-string waits are left alone.
    # =====================================================================
    Write-Host '--- direct blind waits are denied; short/bounded/nested waits are not ---' -ForegroundColor Cyan
    function Test-BlindWait {
        param([string]$Label, [string]$Command, [bool]$ExpectDeny)
        $rb = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command $Command -LocalAppData $hc.LocalAppData
        $denied = ($rb.Out -match '"permissionDecision":"deny"')
        if ($ExpectDeny) {
            Check ('DENIED: ' + $Label) ($denied) $rb.Out
            # The message is an EXACT safe pattern (a deadline-bounded readiness
            # check), not a generic warning.
            $msg = Get-Message $rb.Out
            Check ('  ...with a deadline-bounded readiness pattern: ' + $Label) ($msg -match 'AddSeconds' -and $msg -match 'while ') $rb.Out
        }
        else {
            Check ('ALLOWED (not a blind wait): ' + $Label) ((-not $denied) -and $rb.Exit -eq 0) $rb.Out
        }
    }
    # Denied - the four forms the contract names.
    Test-BlindWait -Label 'Start-Sleep -Seconds 300'        -Command 'Start-Sleep -Seconds 300'                  -ExpectDeny $true
    Test-BlindWait -Label 'Start-Sleep 240 (positional)'    -Command 'Start-Sleep 240'                           -ExpectDeny $true
    Test-BlindWait -Label 'sleep 300 (shell)'               -Command 'sleep 300'                                 -ExpectDeny $true
    Test-BlindWait -Label 'sleep 5m (suffix -> 300s)'       -Command 'sleep 5m'                                  -ExpectDeny $true
    Test-BlindWait -Label 'timeout /t 200 (Windows delay)'  -Command 'timeout /t 200'                            -ExpectDeny $true
    Test-BlindWait -Label 'always-true poll loop, no break' -Command 'while ($true) { Start-Sleep -Seconds 1 }'  -ExpectDeny $true
    # Allowed - short, bounded, GNU-bounded, nested, or shows a deadline.
    Test-BlindWait -Label 'Start-Sleep -Seconds 5 (short)'     -Command 'Start-Sleep -Seconds 5'                                                                              -ExpectDeny $false
    Test-BlindWait -Label 'Start-Sleep -Milliseconds 200'      -Command 'Start-Sleep -Milliseconds 200'                                                                       -ExpectDeny $false
    Test-BlindWait -Label 'sleep 2 (short backoff)'            -Command 'sleep 2'                                                                                             -ExpectDeny $false
    Test-BlindWait -Label 'GNU timeout 300 bounds a command'   -Command 'timeout 300 node server.js'                                                                          -ExpectDeny $false
    Test-BlindWait -Label 'nested shell string is NOT parsed'  -Command 'bash -c "sleep 300"'                                                                                 -ExpectDeny $false
    Test-BlindWait -Label 'deadline-bounded poll loop'         -Command '$d=[DateTime]::UtcNow.AddSeconds(30); while ([DateTime]::UtcNow -lt $d) { Start-Sleep -Milliseconds 200 }' -ExpectDeny $false
    Test-BlindWait -Label 'always-true loop WITH a break'      -Command 'while ($true) { if ($ready) { break }; Start-Sleep -Seconds 1 }'                                      -ExpectDeny $false

    # HM-06 follow-up: PYTHON literal long sleeps. The tokenizer hands the quoted
    # payload over as ONE token, so the hook may regex-match it without parsing a
    # shell - but ONLY inside a segment whose program is python/python3/py.
    Test-BlindWait -Label 'python -c "time.sleep(300)"'                -Command 'python -c "time.sleep(300)"'               -ExpectDeny $true
    Test-BlindWait -Label 'python3 -c "import time; time.sleep(600)"' -Command 'python3 -c "import time; time.sleep(600)"' -ExpectDeny $true
    Test-BlindWait -Label 'py -c "time.sleep(120)"'                   -Command 'py -c "time.sleep(120)"'                   -ExpectDeny $true
    Test-BlindWait -Label 'python -c "time.sleep(1)" (below ceiling)' -Command 'python -c "time.sleep(1)"'                 -ExpectDeny $false
    Test-BlindWait -Label 'grep "time.sleep(300)" (non-python)'       -Command 'grep "time.sleep(300)" app.py'             -ExpectDeny $false
    Test-BlindWait -Label 'python script.py (no literal sleep)'       -Command 'python script.py'                          -ExpectDeny $false
    Test-BlindWait -Label 'echo time.sleep(300) (non-python)'         -Command 'echo time.sleep(300)'                      -ExpectDeny $false

    # Advisory mode reports the finding but does not block.
    $hcBlindAdv = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_ADVISORY_ONLY = '1' }
    $rAdv = Fire -HookPath $hcBlindAdv.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'Start-Sleep -Seconds 300' -LocalAppData $hcBlindAdv.LocalAppData
    Check 'advisory mode reports the blind wait but never denies' ($rAdv.Out -notmatch '"permissionDecision":"deny"' -and (Get-Message $rAdv.Out) -match 'blind wait') $rAdv.Out
    # 0 disables the check entirely.
    $hcBlindOff = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_MAX_BLIND_SLEEP_SECONDS = '0' }
    $rOff = Fire -HookPath $hcBlindOff.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'Start-Sleep -Seconds 300' -LocalAppData $hcBlindOff.LocalAppData
    Check 'TEST_GUARD_MAX_BLIND_SLEEP_SECONDS=0 disables the check (a long sleep is allowed)' ($rOff.Out -notmatch '"permissionDecision":"deny"' -and $rOff.Exit -eq 0) $rOff.Out
    # A real test command is unaffected - the blind-wait pass never swallows it.
    $rStillTest = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hc.LocalAppData
    Check 'a real test command still gets its guarded-runner replacement (blind-wait pass did not swallow it)' ((Get-Message $rStillTest.Out) -match 'Run-Tests-Guarded') $rStillTest.Out

    # =====================================================================
    Write-Host '--- metacharacters and spaces survive into the replacement, unevaluated ---' -ForegroundColor Cyan
    $marker = Join-Path $Work 'SHOULD-NOT-EXIST.txt'
    $nasty = 'pytest -k "slow and not flaky" --junitxml "C:\out dir\r&d.xml" ; echo pwned > "' + $marker + '"'
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command $nasty -LocalAppData $hc.LocalAppData
    $message = Get-Message $r.Out
    $replacement = Get-Replacement $message
    Check 'the quoted multi-word argument survives whole' ($replacement -match 'slow and not flaky') $replacement
    Check 'the ampersand path argument survives whole' ($replacement -match 'r&d\.xml') $replacement
    Check 'the trailing shell segment is NOT folded into the test arguments' ($replacement -notmatch 'pwned') $replacement
    Check 'the hook executed nothing - the injected side effect never happened' (-not (Test-Path -LiteralPath $marker))

    # =====================================================================
    Write-Host '--- static safety: the hook never evaluates or spawns anything ---' -ForegroundColor Cyan
    # Comment lines are stripped first: the header deliberately says the words
    # "Invoke-Expression" and "shell" in prose.
    # The WHOLE hook package, not just the entry point. These are the hook's
    # execution-safety assertions (no Invoke-Expression, no Start-Process, no
    # script blocks, no call-operator on a variable); reading one file would
    # quietly stop covering everything a companion module contains, so a split
    # could weaken them to nothing while every assertion still reported green.
    $hookCode = (@(Get-ChildItem -LiteralPath (Split-Path -Parent $Hook) -File -Filter '*.ps1' | Sort-Object Name |
            ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) }) |
        Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
    Check 'no Invoke-Expression' ($hookCode -notmatch 'Invoke-Expression')
    Check 'no iex alias' ($hookCode -notmatch '(^|[^\w-])iex([^\w-]|$)')
    Check 'no Start-Process' ($hookCode -notmatch 'Start-Process')
    Check 'no Invoke-Command / Invoke-Item' ($hookCode -notmatch 'Invoke-Command' -and $hookCode -notmatch 'Invoke-Item')
    Check 'no ScriptBlock creation' ($hookCode -notmatch 'ScriptBlock')
    Check 'no call operator on a variable' ($hookCode -notmatch '&\s*\$')
    Check 'the replacement is built with -ArgumentsJson, never -Arguments' ($hookCode -match "'-ArgumentsJson " -and $hookCode -notmatch "'-Arguments ")

    # =====================================================================
    Write-Host '--- TEST_GUARD_ADVISORY_ONLY=1 advises instead of blocking ---' -ForegroundColor Cyan
    $hcAdvisory = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_ADVISORY_ONLY = '1' }
    $r = Fire -HookPath $hcAdvisory.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcAdvisory.LocalAppData
    $message = Get-Message $r.Out
    Check 'advisory mode never denies' ($r.Out -notmatch '"permissionDecision":"deny"' -and $r.Exit -eq 0) $r.Out
    Check 'advisory mode still reports the finding and the replacement' ($message -match 'ADVISORY ONLY' -and $message -match 'Run-Tests-Guarded\.ps1') $message
    Check 'advisory output is one parseable JSON document' (Test-IsSingleJson $r.Out) $r.Out

    # =====================================================================
    Write-Host '--- .env overrides reach the replacement; invalid values fall back once ---' -ForegroundColor Cyan
    $hcEnv = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_WALL_TIMEOUT_SECONDS = '600'; TEST_GUARD_IDLE_TIMEOUT_SECONDS = '45'; TEST_GUARD_MAX_MEMORY_MB = '4096' }
    $r = Fire -HookPath $hcEnv.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcEnv.LocalAppData
    $replacement = Get-Replacement (Get-Message $r.Out)
    Check 'valid .env values are carried into the replacement' ($replacement -match '-TimeoutSeconds 600' -and $replacement -match '-IdleTimeoutSeconds 45' -and $replacement -match '-MaxMemoryMB 4096') $replacement

    $hcBad = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_WALL_TIMEOUT_SECONDS = 'forever'; TEST_GUARD_ADVISORY_ONLY = 'maybe' }
    $r1 = Fire -HookPath $hcBad.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcBad.LocalAppData
    $message1 = Get-Message $r1.Out
    Check 'an invalid value is reported by KEY and falls back to the default' ($message1 -match 'TEST_GUARD_WALL_TIMEOUT_SECONDS' -and $message1 -match 'using the default 1800') $message1
    Check 'an invalid value never leaks the offending value' ($message1 -notmatch 'forever' -and $message1 -notmatch 'maybe') $message1
    Check 'an invalid value does not disable the gate (it still denies)' ($r1.Out -match '"permissionDecision":"deny"') $r1.Out
    $r2 = Fire -HookPath $hcBad.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcBad.LocalAppData
    Check 'the config complaint is reported ONCE, not on every event' ((Get-Message $r2.Out) -notmatch 'TEST_GUARD_WALL_TIMEOUT_SECONDS') $r2.Out
    $rUnrelated = Fire -HookPath $hcBad.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'git status' -LocalAppData $hcBad.LocalAppData
    Check 'a malformed .env never turns the hook into an unconditional blocker' ($rUnrelated.Exit -eq 0 -and $rUnrelated.Out -eq '') $rUnrelated.Out

    # =====================================================================
    Write-Host '--- TEST_GUARD_NEVER_GUARD and TEST_GUARD_EXTRA_TEST_COMMANDS ---' -ForegroundColor Cyan
    $hcNever = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_NEVER_GUARD = 'pytest --collect-only' }
    $r = Fire -HookPath $hcNever.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest --collect-only -q' -LocalAppData $hcNever.LocalAppData
    Check 'TEST_GUARD_NEVER_GUARD wins over recognition' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $hcExtra = New-IsolatedHookCopy -EnvOverrides @{ TEST_GUARD_EXTRA_TEST_COMMANDS = 'bazel test' }
    $r = Fire -HookPath $hcExtra.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'bazel test //...' -LocalAppData $hcExtra.LocalAppData
    Check 'TEST_GUARD_EXTRA_TEST_COMMANDS extends recognition' ((Get-Message $r.Out) -match 'TEST RUN GUARD') $r.Out
    $r = Fire -HookPath $hcExtra.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'bazel build //...' -LocalAppData $hcExtra.LocalAppData
    Check 'the extras do not widen recognition beyond the declared fragment' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out


    # =====================================================================
    # A shell REDIRECTION must not survive into the argument list.
    #
    # '|' was a recognised separator but '2>&1' was not, so
    #   python -m pytest tests/x.py -q 2>&1 | tail -3
    # emitted ["-m","pytest","tests/x.py","-q","2>&1"] and the replacement this
    # hook prints died with `file or directory not found: 2>&1`. Every redirection
    # form leaked the same way, operand included. The guarded runner captures both
    # streams itself, so a redirection has nothing to express here.
    Write-Host '--- redirections never reach the replacement command ---' -ForegroundColor Cyan
    $hcRedir = New-IsolatedHookCopy
    foreach ($redirCase in @(
            @{ Cmd = 'pytest -q --no-header 2>&1 | tail -3'; Expect = '["-q","--no-header"]' },
            @{ Cmd = 'pytest -q > out.txt'; Expect = '["-q"]' },
            @{ Cmd = 'pytest -q 2> err.txt'; Expect = '["-q"]' },
            @{ Cmd = 'pytest -q >> log.txt'; Expect = '["-q"]' })) {
        $rRedir = Fire -HookPath $hcRedir.Script -Cwd $Proj -EventName 'PreToolUse' -Command ([string]$redirCase.Cmd) -LocalAppData $hcRedir.LocalAppData
        $redirReplacement = Get-Replacement (Get-Message $rRedir.Out)
        $redirJson = ''
        if ($redirReplacement -match "-ArgumentsJson\s+'([^']*)'") { $redirJson = $Matches[1] }
        Check ('no redirection token survives: ' + [string]$redirCase.Cmd) (
            $redirJson -eq [string]$redirCase.Expect) ('got ' + $redirJson + ' want ' + [string]$redirCase.Expect)
    }
    # A redirection CHARACTER inside a quoted argument is data, not an operator -
    # the tokenizer already swallowed the quoted run, so it must survive intact.
    $rRedirQuoted = Fire -HookPath $hcRedir.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -k "a>b" -q' -LocalAppData $hcRedir.LocalAppData
    $redirQuotedReplacement = Get-Replacement (Get-Message $rRedirQuoted.Out)
    Check 'a redirection character inside a QUOTED argument is preserved' (
        $redirQuotedReplacement -match 'a>b') $redirQuotedReplacement
