# Test-TestRunGuard.ps1 scenario block: PostToolUse REPORTING and RUNNER
# DISCOVERY - terminated/leaked/failed results surfaced, a clean result kept
# silent, missing/stale evidence never claimed as success, the Codex output
# shape, argv-array commands, the advise-instead-of-block downgrade when no
# runner is locatable, and Find-GuardedRunner's managed-wins precedence.
#
# Defines New-ResultDocument, used again by the later scenario blocks.
#
# Dot-sourced by Test-TestRunGuard.ps1 into the caller's scope (uses its
# harness, helpers and workspace) - not a standalone suite.

    # =====================================================================
    Write-Host '--- PostToolUse: a TERMINATED result names the reason and the last progress ---' -ForegroundColor Cyan
    function New-ResultDocument {
        param([string]$LocalAppData, [string]$ProjectRoot, [hashtable]$Fields)
        # Same key the hook derives: SHA-256 prefix of the lowercased project root.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $key = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 10) }
        finally { $sha.Dispose() }
        $dir = Join-Path $LocalAppData 'HookMaker\state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # A synthetic result must carry the run identity of the observation it
        # stands in for, or the hook's identity gate correctly rejects it as
        # belonging to a different run. Copy runId/commandFingerprint/
        # projectFingerprint from the PER-RUN observed record when one exists.
        $runId = ''; $cmdFp = ''; $projFp = ''
        $obsFiles = @(Get-ChildItem -LiteralPath $dir -Filter ('TestRunGuard-observed-' + $key + '-*.json') -File -ErrorAction SilentlyContinue)
        if ($obsFiles.Count -ge 1) {
            try {
                $obs = Get-Content -LiteralPath $obsFiles[0].FullName -Raw | ConvertFrom-Json
                $runId = [string]$obs.runId
                $cmdFp = [string]$obs.commandFingerprint
                $projFp = if ($obs.PSObject.Properties['projectFingerprint']) { [string]$obs.projectFingerprint } else { [string]$obs.fingerprint }
            }
            catch { }
        }
        $nowIso = [DateTime]::UtcNow.ToString('o')
        $document = [ordered]@{
            schema = 2; overall = 'ok'; exitCode = 0; terminated = $false; terminateReason = ''
            terminateDetail = ''; elapsedSeconds = 12.5; leakedProcessIds = @(); lastProgress = ''
            peakMemoryMB = 210.5; peakTreeSize = 4
            runId = $runId; commandFingerprint = $cmdFp; projectFingerprint = $projFp
            startedUtc = $nowIso; endedUtc = $nowIso
        }
        foreach ($key2 in $Fields.Keys) { $document[$key2] = $Fields[$key2] }
        # PER-RUN result filename by the FINAL runId (after any -Fields override).
        $path = Join-Path $dir ('TestRunGuard-result-' + $key + '-' + (Get-SafeRunId ([string]$document['runId'])) + '.json')
        Write-Utf8 $path (($document | ConvertTo-Json -Depth 6))
        return $path
    }

    $hcPost = New-IsolatedHookCopy
    $null = New-ResultDocument -LocalAppData $hcPost.LocalAppData -ProjectRoot $Proj -Fields @{
        overall = 'terminated'; exitCode = 124; terminated = $true; terminateReason = 'idleTimeout'
        terminateDetail = 'produced no output or state change for 300s'
        lastProgress = 'RUNNING suite Test-RulesCheck.ps1 (7/22)'
    }
    $r = Fire -HookPath $hcPost.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcPost.LocalAppData
    $message = Get-Message $r.Out
    Check 'PostToolUse output is one parseable JSON document' (Test-IsSingleJson $r.Out) $r.Out
    Check 'the finding names the terminate reason' ($message -match 'TERMINATED' -and $message -match 'idleTimeout') $message
    Check 'the finding carries lastProgress - where it was when it died' ($message -match 'Test-RulesCheck\.ps1 \(7/22\)') $message
    Check 'the finding refuses to call a termination a test failure' ($message -match 'not a test failure') $message
    Check 'PostToolUse never blocks' ($r.Exit -eq 0 -and $r.Out -notmatch '"permissionDecision":"deny"' -and $r.Out -notmatch '"decision"') $r.Out
    $rRepeat = Fire -HookPath $hcPost.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcPost.LocalAppData
    Check 'the SAME unchanged result is not reported twice' ($rRepeat.Exit -eq 0 -and $rRepeat.Out -eq '') $rRepeat.Out

    # =====================================================================
    Write-Host '--- PostToolUse: leaked processes and non-zero exits are surfaced ---' -ForegroundColor Cyan
    $hcLeak = New-IsolatedHookCopy
    $null = New-ResultDocument -LocalAppData $hcLeak.LocalAppData -ProjectRoot $Proj -Fields @{
        overall = 'terminated'; exitCode = 124; terminated = $true; terminateReason = 'wallTimeout'
        terminateDetail = 'exceeded the 1800s wall ceiling'; lastProgress = 'still collecting'
        leakedProcessIds = @(4242, 4243)
    }
    $r = Fire -HookPath $hcLeak.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'npm test' -LocalAppData $hcLeak.LocalAppData
    $message = Get-Message $r.Out
    Check 'a process leak is reported with the actual ids' ($message -match 'PROCESS LEAK' -and $message -match '4242, 4243') $message
    Check 'the wall-timeout reason is named' ($message -match 'wallTimeout') $message

    $hcFail = New-IsolatedHookCopy
    $null = New-ResultDocument -LocalAppData $hcFail.LocalAppData -ProjectRoot $Proj -Fields @{
        overall = 'failed'; exitCode = 3; lastProgress = 'Passed: 40  Failed: 3'
    }
    $r = Fire -HookPath $hcFail.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcFail.LocalAppData
    $message = Get-Message $r.Out
    Check 'a non-zero exit code is surfaced as a non-pass' ($message -match 'exit code 3' -and $message -match 'did NOT pass') $message

    # =====================================================================
    Write-Host '--- PostToolUse: a clean result is silent; unrelated commands are silent ---' -ForegroundColor Cyan
    $hcClean = New-IsolatedHookCopy
    $null = New-ResultDocument -LocalAppData $hcClean.LocalAppData -ProjectRoot $Proj -Fields @{ overall = 'ok'; exitCode = 0; lastProgress = 'Passed: 43  Failed: 0' }
    $r = Fire -HookPath $hcClean.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcClean.LocalAppData
    Check 'a clean guarded result produces total silence' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $hcClean.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'git status' -LocalAppData $hcClean.LocalAppData
    Check 'PostToolUse is silent for an unrelated command even with a result present' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- PostToolUse: MISSING or STALE evidence never claims success ---' -ForegroundColor Cyan
    $hcMissing = New-IsolatedHookCopy
    $r = Fire -HookPath $hcMissing.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcMissing.LocalAppData
    $message = Get-Message $r.Out
    Check 'a missing result document is reported as NO evidence' ($message -match 'NO evidence' -and $message -match 'do not report it as passing') $message
    Check 'the missing-evidence finding never claims a pass' ($message -notmatch 'passed\b' -or $message -match 'do not report it as passing') $message

    $hcStale = New-IsolatedHookCopy
    $stalePath = New-ResultDocument -LocalAppData $hcStale.LocalAppData -ProjectRoot $Proj -Fields @{ overall = 'ok'; exitCode = 0 }
    (Get-Item -LiteralPath $stalePath).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-6)
    $r = Fire -HookPath $hcStale.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcStale.LocalAppData
    $message = Get-Message $r.Out
    Check 'a STALE ok result is not accepted as evidence for this run' ($message -match 'stale' -and $message -match 'NO evidence') $message

    # =====================================================================
    Write-Host '--- Codex shape (no CLAUDE_PROJECT_DIR) ---' -ForegroundColor Cyan
    $hcCodex = New-IsolatedHookCopy
    $r = Fire -HookPath $hcCodex.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcCodex.LocalAppData -NoClaudeProjectDir
    Check 'Codex block uses systemMessage, never hookSpecificOutput' ($r.Out -match '"systemMessage"' -and $r.Out -notmatch 'hookSpecificOutput') $r.Out
    Check 'Codex output is one parseable JSON document' (Test-IsSingleJson $r.Out) $r.Out
    Check 'Codex block exits 2 and feeds the reason back on stderr' ($r.Exit -eq 2 -and $r.Err -match 'TEST RUN GUARD') ([string]$r.Exit + '|' + $r.Err)
    $r = Fire -HookPath $hcCodex.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'git status' -LocalAppData $hcCodex.LocalAppData -NoClaudeProjectDir
    Check 'Codex is equally silent on unrelated commands' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + '|' + $r.Err)

    $hcCodexPost = New-IsolatedHookCopy
    $null = New-ResultDocument -LocalAppData $hcCodexPost.LocalAppData -ProjectRoot $Proj -Fields @{
        overall = 'terminated'; exitCode = 124; terminated = $true; terminateReason = 'memoryLimit'
        terminateDetail = 'owned process tree reached 4096MB'; lastProgress = 'suite 3 of 9'
    }
    $r = Fire -HookPath $hcCodexPost.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcCodexPost.LocalAppData -NoClaudeProjectDir
    Check 'Codex PostToolUse uses systemMessage and exits 0' ($r.Exit -eq 0 -and $r.Out -match '"systemMessage"' -and $r.Out -match 'memoryLimit') $r.Out

    # =====================================================================
    Write-Host '--- an argv ARRAY command (Codex-style exec) is understood without parsing ---' -ForegroundColor Cyan
    $hcArray = New-IsolatedHookCopy
    $r = Fire -HookPath $hcArray.Script -Cwd $Proj -EventName 'PreToolUse' -CommandArray @('pytest', '-k', 'slow and not flaky') -LocalAppData $hcArray.LocalAppData
    $replacement = Get-Replacement (Get-Message $r.Out)
    Check 'an argv array is recognised' ($replacement -match 'Run-Tests-Guarded\.ps1') $replacement
    Check 'an argv array element with spaces stays one argument' ($replacement -match 'slow and not flaky') $replacement
    $r = Fire -HookPath $hcArray.Script -Cwd $Proj -EventName 'PreToolUse' -CommandArray @('git', 'log', '--oneline') -LocalAppData $hcArray.LocalAppData
    Check 'an unrelated argv array is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- the runner is missing: advise, never block with a command that does not exist ---' -ForegroundColor Cyan
    $bare = Join-Path $Work 'BareProject'
    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    $hcBare = New-IsolatedHookCopy
    $r = Fire -HookPath $hcBare.Script -Cwd $bare -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcBare.LocalAppData
    $message = Get-Message $r.Out
    Check 'with no locatable runner the gate downgrades to advice' ($r.Exit -eq 0 -and $r.Out -notmatch '"permissionDecision":"deny"') $r.Out
    Check 'the advice still states the requirement' ($message -match 'could not be located' -and $message -match 'wall timeout') $message

    # Review-1: the runner SHIPS beside the installed hook (installer plants it at
    # <hookdir>\scripts\Run-Tests-Guarded.ps1 - Find-GuardedRunner's candidate[0]).
    # So in a project that has NO scripts\Run-Tests-Guarded.ps1 of its own, the
    # gate must still BLOCK with a real replacement, not downgrade to advice.
    Write-Host '--- the runner ships beside the hook: a bare project still gets a real block (Review-1) ---' -ForegroundColor Cyan
    $shipDir = Join-Path $Work ('hookship-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $shipDir 'scripts') -Force | Out-Null
    Copy-Item $Hook (Join-Path $shipDir 'Test-Run-Guard.ps1')
    Copy-Item $HookLib (Join-Path (Split-Path -Parent $shipDir) '_hooklib.ps1') -Force
    Copy-Item $Runner (Join-Path $shipDir 'scripts\Run-Tests-Guarded.ps1')   # <- shipped by the installer
    $shipFakeLocal = Join-Path $shipDir '_fakelocal'; New-Item -ItemType Directory -Path $shipFakeLocal -Force | Out-Null
    $bare2 = Join-Path $Work 'BareProject2'; New-Item -ItemType Directory -Path $bare2 -Force | Out-Null
    $r = Fire -HookPath (Join-Path $shipDir 'Test-Run-Guard.ps1') -Cwd $bare2 -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $shipFakeLocal
    $shipMsg = Get-Message $r.Out
    $shipRepl = Get-Replacement $shipMsg
    Check 'a hook with the runner shipped beside it BLOCKS a raw command in a bare project' (
        $r.Out -match '"permissionDecision":"deny"' -and $shipRepl -match '-ArgumentsJson') $r.Out
    Check 'the shipped-beside runner is the one referenced in the replacement' (
        $shipRepl -match 'scripts.Run-Tests-Guarded\.ps1') $shipRepl

    # =====================================================================
    Write-Host '--- Find-GuardedRunner: MANAGED (shipped-beside) wins over a project runner; contract marker required (Defect 2) ---' -ForegroundColor Cyan
    # Pulls the -File "<runner>" path out of the replacement's runner invocation.
    function Get-RunnerPath {
        param([string]$Message)
        foreach ($line in ($Message -split "`n")) {
            if ($line -match '-File\s+"([^"]+Run-Tests-Guarded\.ps1)"') { return $Matches[1] }
        }
        return ''
    }
    # A hook with the MANAGED runner shipped beside it (carries the contract marker).
    $mgDir = Join-Path $Work ('managed-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $mgDir 'scripts') -Force | Out-Null
    Copy-Item $Hook (Join-Path $mgDir 'Test-Run-Guard.ps1')
    Copy-Item $HookLib (Join-Path (Split-Path -Parent $mgDir) '_hooklib.ps1') -Force
    Copy-Item $Runner (Join-Path $mgDir 'scripts\Run-Tests-Guarded.ps1')     # managed - has the marker
    $mgHook = Join-Path $mgDir 'Test-Run-Guard.ps1'
    $mgLocal = Join-Path $mgDir '_fakelocal'; New-Item -ItemType Directory -Path $mgLocal -Force | Out-Null
    $mgRunner = Join-Path $mgDir 'scripts\Run-Tests-Guarded.ps1'

    # A project that ALSO ships a scripts\Run-Tests-Guarded.ps1 - but WITHOUT the marker.
    $projNoMarker = Join-Path $Work ('projnomarker-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $projNoMarker 'scripts') -Force | Out-Null
    Write-Utf8 (Join-Path $projNoMarker 'scripts\Run-Tests-Guarded.ps1') "param()`nWrite-Host 'not the real guarded runner'`n"
    $r = Fire -HookPath $mgHook -Cwd $projNoMarker -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $mgLocal
    $runnerUsed = Get-RunnerPath (Get-Message $r.Out)
    Check 'the MANAGED shipped-beside runner is used, not the project runner' ($runnerUsed -eq $mgRunner) $runnerUsed
    Check 'the marker-less project runner is never referenced' ($runnerUsed -notmatch [regex]::Escape($projNoMarker)) $runnerUsed

    # A project runner that DOES carry the marker still loses to the managed one.
    $projWithMarker = Join-Path $Work ('projmarker-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $projWithMarker 'scripts') -Force | Out-Null
    Copy-Item $Runner (Join-Path $projWithMarker 'scripts\Run-Tests-Guarded.ps1')     # marker present
    $r = Fire -HookPath $mgHook -Cwd $projWithMarker -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $mgLocal
    $runnerUsed = Get-RunnerPath (Get-Message $r.Out)
    Check 'even a marker-carrying project runner loses to the managed shipped-beside runner' ($runnerUsed -eq $mgRunner) $runnerUsed

    # (c) A project runner WITHOUT the marker and NO managed runner anywhere on the
    # walk -> the imposter is skipped -> the gate downgrades to advice, never a
    # block whose replacement would point at an unrelated script.
    $isoNoMgr = New-IsolatedHookCopy
    $projOnlyBad = Join-Path $Work ('projonlybad-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $projOnlyBad 'scripts') -Force | Out-Null
    Write-Utf8 (Join-Path $projOnlyBad 'scripts\Run-Tests-Guarded.ps1') "param()`nWrite-Host 'imposter runner'`n"
    $r = Fire -HookPath $isoNoMgr.Script -Cwd $projOnlyBad -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $isoNoMgr.LocalAppData
    $msg = Get-Message $r.Out
    Check 'a candidate without the contract marker is NOT returned -> the gate advises instead of blocking' (
        $r.Out -notmatch '"permissionDecision":"deny"' -and $msg -match 'could not be located') $msg

