# Offline test suite for Test-Run-Guard - new hook, no prior coverage.
#
# The centre of gravity is the FALSE-POSITIVE GUARD: a gate that blocks a
# command it merely suspects is worse than no gate at all, so most of the
# assertions here prove total silence on ordinary work (git, builds, file
# copies, paths that merely contain the word "test").
#
# Also covered: a recognised raw command is denied and the returned replacement
# is a VALID guarded invocation using -ArgumentsJson (asserted by actually
# running the real runner with it); an already-guarded command is never
# double-wrapped; spaces and shell metacharacters survive into the replacement
# without being evaluated; the hook starts no process at all;
# TEST_GUARD_ADVISORY_ONLY=1 advises instead of blocking; PostToolUse names the
# terminate reason and last progress, stays silent on a clean result, and never
# claims success on a missing/stale one; invalid .env values fall back once;
# both Claude and Codex shapes emit exactly one parseable JSON document.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestRunGuard.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HooksRoot = Join-Path $RepoRoot 'hooks'
$Hook = Join-Path $HooksRoot 'Test-Run-Guard\Test-Run-Guard.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$Runner = Join-Path $RepoRoot 'scripts\Run-Tests-Guarded.ps1'
foreach ($required in @($Hook, $HookLib, $Runner)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-runguardtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# Per-case isolated hook copy + fake LOCALAPPDATA, so result/report/config state
# never collides across cases or with the real machine state.
function New-IsolatedHookCopy {
    param([hashtable]$EnvOverrides = @{})
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Test-Run-Guard.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Run-Guard.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param(
        [string]$HookPath, [string]$Cwd, [string]$EventName, [string]$Command,
        [string[]]$CommandArray, [string]$LocalAppData, [switch]$NoClaudeProjectDir, [string]$Exe = 'pwsh'
    )
    $toolInput = @{ description = 'x' }
    if ($PSBoundParameters.ContainsKey('CommandArray')) { $toolInput['command'] = @($CommandArray) }
    else { $toolInput['command'] = $Command }
    $obj = @{ session_id = 'sess1'; cwd = $Cwd; hook_event_name = $EventName; tool_name = 'Bash'; tool_input = $toolInput }
    $payload = $obj | ConvertTo-Json -Depth 6
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    Write-Utf8 $inFile $payload
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $startArgs = @{
        FilePath               = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait                   = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # -Environment MERGES with the inherited environment, so an ambient
        # CLAUDE_PROJECT_DIR from this very runner would leak into a "Codex"
        # case. Set it explicitly to '' rather than omitting the key.
        $childEnv = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData }
        $childEnv['CLAUDE_PROJECT_DIR'] = if ($NoClaudeProjectDir) { '' } else { $Cwd }
        $startArgs.Environment = $childEnv
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# The model-visible text, whichever client shape carried it.
function Get-Message {
    param([string]$Out)
    if ([string]::IsNullOrWhiteSpace($Out)) { return '' }
    try { $parsed = $Out | ConvertFrom-Json } catch { return '' }
    foreach ($path in @('permissionDecisionReason', 'additionalContext')) {
        if ($null -ne $parsed.PSObject.Properties['hookSpecificOutput'] -and
            $null -ne $parsed.hookSpecificOutput.PSObject.Properties[$path]) {
            return [string]$parsed.hookSpecificOutput.$path
        }
    }
    if ($null -ne $parsed.PSObject.Properties['systemMessage']) { return [string]$parsed.systemMessage }
    return ''
}

function Test-IsSingleJson {
    param([string]$Out)
    if ([string]::IsNullOrWhiteSpace($Out)) { return $false }
    try { $null = $Out | ConvertFrom-Json; return $true } catch { return $false }
}

# Pulls the recommended invocation out of the finding: the line starting 'pwsh'.
function Get-Replacement {
    param([string]$Message)
    foreach ($line in ($Message -split "`n")) {
        if ($line.Trim().StartsWith('pwsh ')) { return $line.Trim() }
    }
    return ''
}

$Proj = Join-Path $Work 'Project'
New-Item -ItemType Directory -Path $Proj -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Proj 'scripts') -Force | Out-Null
Copy-Item $Runner (Join-Path $Proj 'scripts\Run-Tests-Guarded.ps1')

try {
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
    $probeDoc = Get-Content -LiteralPath $probeResultFile[0].FullName -Raw | ConvertFrom-Json
    Check 'the result document records the failure, not a pass' ($probeDoc.overall -eq 'failed' -and $probeDoc.exitCode -eq 7) $probeDoc.overall
    Check 'the metacharacter argument survived as ONE argument, unevaluated' ($probeDoc.lastProgress -match 'tag=a b\|c&d') $probeDoc.lastProgress
    Check 'the result document records no argument VALUES' (($probeDoc | ConvertTo-Json -Depth 6) -notmatch '-Tag') ([string]$probeDoc.argumentCount)
    Check 'HOOKMAKER_MAX_TEST_WORKERS clamps the reported worker budget' ($probeDoc.workerBudget -eq 1) ([string]$probeDoc.workerBudget)

    # ... and the very next PostToolUse consumes exactly that document.
    $r = Fire -HookPath $hcProbe.Script -Cwd $Proj -EventName 'PostToolUse' -Command $probeCommand -LocalAppData $hcProbe.LocalAppData
    Check 'PostToolUse reads the real document the replacement produced' ((Get-Message $r.Out) -match 'exit code 7') $r.Out

    # =====================================================================
    Write-Host '--- an already-guarded command passes untouched (no double wrap) ---' -ForegroundColor Cyan
    $guardedCommand = 'pwsh -NoProfile -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pwsh -ArgumentsJson ''["-File",".\scripts\Run-Tests.ps1"]'' -TimeoutSeconds 900'
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command $guardedCommand -LocalAppData $hc.LocalAppData
    Check 'an already-guarded invocation is silent, never re-wrapped' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $hc.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pwsh -File scripts\Run-Tests-Guarded.ps1 -FilePath pytest -ArgumentsJson ''["-q"]''' -LocalAppData $hc.LocalAppData
    Check 'a guarded invocation whose payload is pytest is still not re-wrapped' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

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
    $hookCode = (([System.IO.File]::ReadAllLines($Hook)) | Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
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
    Write-Host '--- PostToolUse: a TERMINATED result names the reason and the last progress ---' -ForegroundColor Cyan
    function New-ResultDocument {
        param([string]$LocalAppData, [string]$ProjectRoot, [hashtable]$Fields)
        # Same key the hook derives: SHA-256 prefix of the lowercased project root.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $key = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 10) }
        finally { $sha.Dispose() }
        $dir = Join-Path $LocalAppData 'HookMaker\state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir ('TestRunGuard-result-' + $key + '.json')
        # A synthetic result must carry the run identity of the observation it
        # stands in for, or the hook's identity gate correctly rejects it as
        # belonging to a different run. Copy runId/commandFingerprint/
        # projectFingerprint from the observed record when one exists.
        $runId = ''; $cmdFp = ''; $projFp = ''
        $observedPath = Join-Path $dir ('TestRunGuard-observed-' + $key + '.json')
        if (Test-Path -LiteralPath $observedPath -PathType Leaf) {
            try {
                $obs = Get-Content -LiteralPath $observedPath -Raw | ConvertFrom-Json
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
    Write-Host '--- coordination handoff: the observed record Test-Completion-Check reads ---' -ForegroundColor Cyan
    function Get-ObservedRecord {
        param([string]$LocalAppData)
        $files = @(Get-ChildItem -LiteralPath (Join-Path $LocalAppData 'HookMaker\state') -Filter 'TestRunGuard-observed-*.json' -ErrorAction SilentlyContinue)
        if ($files.Count -ne 1) { return $null }
        return [pscustomobject]@{ File = $files[0]; Document = (Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json) }
    }
    # The consumer's own key derivation, so a divergence fails here.
    $expectedKey = & {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Proj.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant().Substring(0, 10) }
        finally { $sha.Dispose() }
    }

    $hcObs = New-IsolatedHookCopy
    $r = Fire -HookPath $hcObs.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcObs.LocalAppData
    $observed = Get-ObservedRecord $hcObs.LocalAppData
    Check 'a blocked RAW test command writes an observed record' ($null -ne $observed)
    Check 'the observed file name matches what the consumer reads' ($observed.File.Name -eq ('TestRunGuard-observed-' + $expectedKey + '.json')) $observed.File.Name
    Check 'the observed record carries observedUtc, fingerprint and guarded' (
        $null -ne $observed.Document.PSObject.Properties['observedUtc'] -and
        $null -ne $observed.Document.PSObject.Properties['fingerprint'] -and
        $null -ne $observed.Document.PSObject.Properties['guarded']) ($observed.Document | ConvertTo-Json -Compress)
    Check 'a blocked raw command is recorded as NOT guarded' ($observed.Document.guarded -eq $false) ([string]$observed.Document.guarded)
    Check 'the fingerprint is non-empty' (-not [string]::IsNullOrWhiteSpace([string]$observed.Document.fingerprint)) ([string]$observed.Document.fingerprint)

    # TIMESTAMP CONTRACT. Replays the consumer's ConvertTo-UtcTime verbatim: an
    # 'o' string arrives from ConvertFrom-Json already Kind=Utc and is returned
    # untouched. Ticks would not parse at all. Drift must be seconds, not the
    # 210 minutes a double offset subtraction produced.
    function ConvertTo-UtcTimeLikeConsumer {
        param($Value)
        if ($null -eq $Value) { return $null }
        $parsed = [DateTime]::MinValue
        if ($Value -is [DateTime]) { $parsed = $Value }
        else {
            $text = [string]$Value
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            if (-not [DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $null }
        }
        if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { return $parsed }
        if ($parsed.Kind -eq [System.DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
        return [DateTime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    }
    $observedTime = ConvertTo-UtcTimeLikeConsumer $observed.Document.observedUtc
    Check 'the consumer can parse observedUtc at all (ticks could not)' ($null -ne $observedTime)
    $driftMinutes = [Math]::Abs(([DateTime]::UtcNow - $observedTime).TotalMinutes)
    Check 'the timestamp round-trips with no timezone drift (< 2 minutes, not 210)' ($driftMinutes -lt 2) ([string]$driftMinutes)

    $hcObsGuarded = New-IsolatedHookCopy
    $r = Fire -HookPath $hcObsGuarded.Script -Cwd $Proj -EventName 'PreToolUse' `
        -Command 'pwsh -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pytest -ArgumentsJson ''["-q"]''' -LocalAppData $hcObsGuarded.LocalAppData
    $observedGuarded = Get-ObservedRecord $hcObsGuarded.LocalAppData
    Check 'an ALREADY-GUARDED command still writes an observed record' ($null -ne $observedGuarded)
    Check 'it is recorded as guarded=true' ($observedGuarded.Document.guarded -eq $true) ([string]$observedGuarded.Document.guarded)
    Check 'writing the observed record stays silent (it is a handoff, not a finding)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $hcObsNone = New-IsolatedHookCopy
    $null = Fire -HookPath $hcObsNone.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'git status' -LocalAppData $hcObsNone.LocalAppData
    Check 'an unrelated command writes NO observed record' ($null -eq (Get-ObservedRecord $hcObsNone.LocalAppData))

    # The fingerprint must equal what the consumer computes for the same state,
    # or condition 5 silently never matches.
    $gitProj = Join-Path $Work 'GitProject'
    New-Item -ItemType Directory -Path $gitProj -Force | Out-Null
    & git -C $gitProj init -q -b main
    & git -C $gitProj config user.email 't@t'
    & git -C $gitProj config user.name 't'
    Write-Utf8 (Join-Path $gitProj 'a.txt') 'a'
    & git -C $gitProj add -A
    & git -C $gitProj commit -q -m 'init'
    $hcFp = New-IsolatedHookCopy
    $null = Fire -HookPath $hcFp.Script -Cwd $gitProj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcFp.LocalAppData
    $observedFp = Get-ObservedRecord $hcFp.LocalAppData
    . (Join-Path $HooksRoot '_hooklib.ps1')
    $consumerFingerprint = [string](Get-RepoStateFingerprint -ProjectRoot $gitProj)
    Check 'in a git repo the fingerprint equals Get-RepoStateFingerprint, as the consumer computes it' (
        $null -ne $observedFp -and [string]$observedFp.Document.fingerprint -eq $consumerFingerprint) (
        ([string]$observedFp.Document.fingerprint) + ' vs ' + $consumerFingerprint)

    # =====================================================================
    Write-Host '--- direct PowerShell test-script execution is recognised (scope D) ---' -ForegroundColor Cyan
    $hcD = New-IsolatedHookCopy
    foreach ($cmd in @('.\scripts\Test-Wizard.ps1', './scripts/Run-Tests.ps1', 'C:\repo\scripts\Test-RulesCheck.ps1 -KeepArtifacts', '& ".\scripts\Test-RulesCheck.ps1"')) {
        $r = Fire -HookPath $hcD.Script -Cwd $Proj -EventName 'PreToolUse' -Command $cmd -LocalAppData $hcD.LocalAppData
        $repl = Get-Replacement (Get-Message $r.Out)
        Check ('direct form is guarded: ' + $cmd) ((Get-Message $r.Out) -match 'TEST RUN GUARD' -and $repl -match 'Run-Tests-Guarded') $r.Out
    }
    $r = Fire -HookPath $hcD.Script -Cwd $Proj -EventName 'PreToolUse' -Command '.\scripts\Test-Wizard.ps1 -KeepArtifacts' -LocalAppData $hcD.LocalAppData
    $repl = Get-Replacement (Get-Message $r.Out)
    Check 'the direct-script replacement runs it via pwsh -File with the original args intact' (
        $repl -match '-FilePath "pwsh"' -and $repl -match 'Test-Wizard\.ps1' -and $repl -match 'KeepArtifacts') $repl
    foreach ($cmd in @('generate-test-fixtures.ps1', 'contest.ps1', '.\testdata\seed.ps1', 'pwsh -Command "Test-Thing"', 'echo test')) {
        $r = Fire -HookPath $hcD.Script -Cwd $Proj -EventName 'PreToolUse' -Command $cmd -LocalAppData $hcD.LocalAppData
        Check ('a non-test path stays silent: ' + $cmd) ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }

    # =====================================================================
    Write-Host '--- run-identity contract is carried into the observed record + replacement (scope A) ---' -ForegroundColor Cyan
    $hcId = New-IsolatedHookCopy
    $r = Fire -HookPath $hcId.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcId.LocalAppData
    $obsId = Get-ObservedRecord $hcId.LocalAppData
    Check 'the observed record is schema 2 with a runId, a command fingerprint, and runIdControlled' (
        $null -ne $obsId -and $obsId.Document.schema -eq 2 -and
        -not [string]::IsNullOrWhiteSpace([string]$obsId.Document.runId) -and
        -not [string]::IsNullOrWhiteSpace([string]$obsId.Document.commandFingerprint) -and
        $obsId.Document.runIdControlled -eq $true) ($obsId.Document | ConvertTo-Json -Compress)
    $replId = Get-Replacement (Get-Message $r.Out)
    Check 'the replacement injects -RunId and -ProjectFingerprint as data' ($replId -match '-RunId ' -and $replId -match '-ProjectFingerprint ') $replId
    Check 'the injected runId equals the observed runId' ($replId -match ('-RunId ' + [regex]::Escape([string]$obsId.Document.runId))) $replId
    # A guarded replacement PRESERVES the injected runId instead of minting a
    # fresh one that could never match the runner's result.
    $injRun = [string]$obsId.Document.runId
    $injFp = [string]$obsId.Document.projectFingerprint
    $null = Fire -HookPath $hcId.Script -Cwd $Proj -EventName 'PreToolUse' `
        -Command ('pwsh -File .\scripts\Run-Tests-Guarded.ps1 -FilePath pytest -ArgumentsJson ''["-q"]'' -RunId ' + $injRun + ' -ProjectFingerprint ' + $injFp) -LocalAppData $hcId.LocalAppData
    $obsId2 = Get-ObservedRecord $hcId.LocalAppData
    Check 'a guarded replacement preserves the injected runId (does not mint a fresh one)' (
        $null -ne $obsId2 -and $obsId2.Document.runId -eq $injRun -and $obsId2.Document.guarded -eq $true) ([string]$obsId2.Document.runId)

    # PostToolUse rejects a result whose identity does not match the observation.
    $hcMis = New-IsolatedHookCopy
    $null = Fire -HookPath $hcMis.Script -Cwd $Proj -EventName 'PreToolUse' -Command 'pytest -q' -LocalAppData $hcMis.LocalAppData
    $null = New-ResultDocument -LocalAppData $hcMis.LocalAppData -ProjectRoot $Proj -Fields @{ overall = 'ok'; runId = 'a-totally-different-run' }
    $r = Fire -HookPath $hcMis.Script -Cwd $Proj -EventName 'PostToolUse' -Command 'pytest -q' -LocalAppData $hcMis.LocalAppData
    Check 'PostToolUse rejects a result from a DIFFERENT run as not-evidence' ((Get-Message $r.Out) -match 'DIFFERENT run') $r.Out

    # =====================================================================
    Write-Host '--- runner: orphan descendants after a clean exit are a leak (scope B) ---' -ForegroundColor Cyan
    $orphanSuite = Join-Path $Work 'orphan-suite.ps1'
    Write-Utf8 $orphanSuite "`$c = Start-Process -FilePath 'ping.exe' -ArgumentList '-n','60','127.0.0.1' -PassThru -WindowStyle Hidden`nSet-Content -LiteralPath `$env:ORPHAN_PIDFILE -Value `$c.Id`nStart-Sleep -Milliseconds 300`nexit 0`n"
    $orphanPidFile = Join-Path $Work 'orphan-pid.txt'
    $orphanResult = Join-Path $Work 'orphan-result.json'
    # A wrapper script invokes the runner with the -Arguments ARRAY (built in
    # PowerShell), so no JSON/embedded-quote survives Start-Process arg mangling.
    $orphanWrapper = Join-Path $Work 'run-orphan.ps1'
    Write-Utf8 $orphanWrapper (
        "& '$Runner' -FilePath 'pwsh' -Arguments @('-NoProfile','-File','$orphanSuite') " +
        "-TimeoutSeconds 60 -IdleTimeoutSeconds 30 -HeartbeatSeconds 1 -ResultPath '$orphanResult' -Quiet`nexit `$LASTEXITCODE`n")
    $prevOrphanEnv = $env:ORPHAN_PIDFILE
    $env:ORPHAN_PIDFILE = $orphanPidFile
    try {
        $rp = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru -ArgumentList @(
            '-NoLogo', '-NoProfile', '-File', $orphanWrapper)
    }
    finally { $env:ORPHAN_PIDFILE = $prevOrphanEnv }
    $orphanDoc = $null
    try { $orphanDoc = Get-Content -LiteralPath $orphanResult -Raw | ConvertFrom-Json } catch { }
    Check 'the runner records the orphan as a leak and does not call the run ok' (
        $null -ne $orphanDoc -and $orphanDoc.overall -ne 'ok' -and @($orphanDoc.leakedProcessIds).Count -gt 0) (
        $(if ($null -ne $orphanDoc) { [string]$orphanDoc.overall + ' leaked=' + (@($orphanDoc.leakedProcessIds) -join ',') } else { 'no result' }))
    $orphanChild = ''
    try { $orphanChild = (Get-Content -LiteralPath $orphanPidFile -Raw).Trim() } catch { }
    $orphanAlive = $false
    if ($orphanChild -ne '') { try { $null = Get-Process -Id $orphanChild -ErrorAction Stop; $orphanAlive = $true } catch { } }
    Check 'the orphan child is actually gone after the run (terminated, not leaked forever)' (-not $orphanAlive) ('child ' + $orphanChild + ' alive=' + $orphanAlive)

    # =====================================================================
    Write-Host '--- runner: a silent CPU-busy run survives the no-progress limit (scope F) ---' -ForegroundColor Cyan
    $busySuite = Join-Path $Work 'busy-suite.ps1'
    Write-Utf8 $busySuite "`$sw=[System.Diagnostics.Stopwatch]::StartNew();`$x=0.0`nwhile(`$sw.Elapsed.TotalSeconds -lt 6){ for(`$i=0;`$i -lt 200000;`$i++){ `$x=[math]::Sqrt(`$i)+`$x } }`nexit 0`n"
    $busyResult = Join-Path $Work 'busy-result.json'
    $busyWrapper = Join-Path $Work 'run-busy.ps1'
    Write-Utf8 $busyWrapper (
        "& '$Runner' -FilePath 'pwsh' -Arguments @('-NoProfile','-File','$busySuite') " +
        "-TimeoutSeconds 30 -IdleTimeoutSeconds 2 -HeartbeatSeconds 1 -ResultPath '$busyResult' -Quiet`nexit `$LASTEXITCODE`n")
    $rp = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -NoNewWindow -PassThru -ArgumentList @(
        '-NoLogo', '-NoProfile', '-File', $busyWrapper)
    $busyDoc = $null
    try { $busyDoc = Get-Content -LiteralPath $busyResult -Raw | ConvertFrom-Json } catch { }
    Check 'a silent CPU-busy run is NOT killed by the 2s no-progress limit (CPU is progress)' (
        $null -ne $busyDoc -and $busyDoc.terminated -eq $false -and $busyDoc.overall -eq 'ok') (
        $(if ($null -ne $busyDoc) { [string]$busyDoc.overall + ' terminated=' + [string]$busyDoc.terminated + ' reason=' + [string]$busyDoc.terminateReason } else { 'no result' }))

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
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
