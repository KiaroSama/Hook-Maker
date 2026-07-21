# Offline test suite for Test-Plan-Check - the BEFORE stage of the three-stage
# test-health architecture. New hook, no prior coverage.
#
# Covers the explicit contract, not an exhaustive keyword matrix:
# relevance gating (a test-related prompt advises, an ordinary prompt is
# silent); the fingerprint + cooldown (an unchanged repeat is suppressed, a
# CHANGED state reports immediately); BOTH client output shapes (Claude
# hookSpecificOutput.additionalContext, Codex systemMessage); SessionStart and
# UserPromptSubmit; pointable findings (minute-scale sleep, unbounded wait);
# a malformed .env falling back to the default with a message instead of
# crashing; output being a single valid JSON document; and the two hard
# guarantees - the hook NEVER writes into the project and NEVER runs a test
# (proved by comparing bytes, not Test-Path).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestPlanCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Test-Plan-Check\Test-Plan-Check.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$EnvExample = Join-Path $HooksRoot 'Test-Plan-Check\.env.example'
foreach ($required in @($Hook, $HookLib, $EnvExample)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-testplantest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# [System.IO.Path]::GetTempPath() sits UNDER the real user profile on Windows,
# so a fixture here is nested inside $HOME. Nothing below may reach real
# ~\.claude / ~\.codex state: every child gets a FAKE LOCALAPPDATA, and the
# client-detection env var is cleared for this process so Start-Process
# -Environment (which MERGES, not replaces) cannot leak it into a child.
$SavedClaudeProjectDir = $env:CLAUDE_PROJECT_DIR
$env:CLAUDE_PROJECT_DIR = ''

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}
function New-GitRepo {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    & git -C $p config core.autocrlf false
    & git -C $p add -A 2>$null | Out-Null
    & git -C $p commit -q -m init 2>$null | Out-Null
    return $p
}

# Per-test isolated hook copy + fake LOCALAPPDATA so cooldown state never collides.
function New-IsolatedHookCopy {
    param([string]$EnvContent = $null)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Test-Plan-Check.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($null -ne $EnvContent) { Write-Utf8 (Join-Path $dir '.env') $EnvContent }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Plan-Check.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param(
        [string]$HookPath, [string]$Cwd, [string]$EventName, [string]$Prompt = '',
        [string]$SessionId = 'sess1', [string]$LocalAppData,
        [switch]$ClaudeInputShape, [string]$ClaudeProjectDir = '',
        [switch]$StopHookActive, [string]$Exe = 'pwsh'
    )
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($Prompt -ne '') { $obj['prompt'] = $Prompt }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    # Claude Code echoes a hookSpecificOutput envelope on the event it sends.
    if ($ClaudeInputShape) { $obj['hookSpecificOutput'] = @{ hookEventName = $EventName } }
    $payload = $obj | ConvertTo-Json -Depth 5
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData; CLAUDE_PROJECT_DIR = $ClaudeProjectDir }
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Parses the advisory (never regexes it) and returns the model/user-visible text.
function Get-Message {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    try { $doc = $Text | ConvertFrom-Json } catch { return '' }
    if ($null -ne $doc.PSObject.Properties['hookSpecificOutput'] -and $null -ne $doc.hookSpecificOutput) {
        return [string]$doc.hookSpecificOutput.additionalContext
    }
    if ($null -ne $doc.PSObject.Properties['systemMessage']) { return [string]$doc.systemMessage }
    return ''
}

# Byte-level snapshot of an entire tree: relative path + length + SHA-256.
# Proving "untouched" by Test-Path would pass even if content were rewritten.
function Get-TreeSignature {
    param([string]$Root)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $parts = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object {
                $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($_.FullName))).Replace('-', '')
                $_.FullName.Substring($Root.Length) + '|' + $_.Length + '|' + $hash
            })
        return ($parts -join "`n")
    }
    finally { $sha.Dispose() }
}

$TestRelatedPrompt = 'The pytest suite hangs forever - can we add a wall timeout to the runner?'
$UnrelatedPrompt = 'Rename the customer invoice column in the billing summary and update the label.'

try {
    # =====================================================================
    Write-Host '--- SessionStart advises, as one valid JSON document, in the Codex shape ---' -ForegroundColor Cyan
    $hc1 = New-IsolatedHookCopy
    $proj1 = New-GitRepo 'Basic'
    Write-Utf8 (Join-Path $proj1 'scripts\Test-Thing.ps1') "# bounded suite`n`$timeout = 30`n"
    & git -C $proj1 add -A 2>$null | Out-Null
    & git -C $proj1 commit -q -m t 2>$null | Out-Null
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'SessionStart' -LocalAppData $hc1.LocalAppData
    Check 'SessionStart exits 0 with no stderr' ($r.Exit -eq 0 -and $r.Err -eq '') ($r.Err)
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { $parsed = $null }
    Check 'output is a single valid JSON document' ($null -ne $parsed -and (@($r.Out -split "`n" | Where-Object { $_.Trim() -ne '' })).Count -eq 1) $r.Out
    Check 'Codex client (no hookSpecificOutput in input, no CLAUDE_PROJECT_DIR) gets systemMessage' (
        $null -ne $parsed -and $null -ne $parsed.PSObject.Properties['systemMessage'] -and
        $null -eq $parsed.PSObject.Properties['hookSpecificOutput']) $r.Out
    $msg1 = Get-Message $r.Out
    Check 'the advisory surfaces the bounded wall/idle timeout policy point' ($msg1 -match '(?i)wall timeout' -and $msg1 -match '(?i)idle') $msg1
    Check 'the advisory surfaces resource-aware parallelism and process cleanup' ($msg1 -match '(?i)cores-2' -and $msg1 -match '(?i)process tree') $msg1
    # The policy block itself mentions blind sleeps, so absence is asserted on
    # the findings SECTION, which only appears when something real was seen.
    Check 'a bounded test file produces no invented finding' ($msg1 -notmatch '(?i)Observed in this project') $msg1
    Check 'a small, fully-scanned project is NOT marked partial' ($msg1 -notmatch '(?i)PARTIAL') $msg1

    # =====================================================================
    Write-Host '--- Claude output shape, detected both documented ways ---' -ForegroundColor Cyan
    $hc2 = New-IsolatedHookCopy
    $proj2 = New-GitRepo 'ClaudeShape'
    $r = Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'SessionStart' -LocalAppData $hc2.LocalAppData -ClaudeInputShape
    $parsed2 = $null
    try { $parsed2 = $r.Out | ConvertFrom-Json } catch { $parsed2 = $null }
    Check 'hookSpecificOutput in the INPUT selects the Claude shape' (
        $null -ne $parsed2 -and $null -ne $parsed2.PSObject.Properties['hookSpecificOutput'] -and
        -not [string]::IsNullOrWhiteSpace([string]$parsed2.hookSpecificOutput.additionalContext) -and
        [string]$parsed2.hookSpecificOutput.hookEventName -eq 'SessionStart') $r.Out
    Check 'the Claude shape never emits decision:block (this hook may never block)' ($r.Out -notmatch '(?i)"decision"') $r.Out

    $hc3 = New-IsolatedHookCopy
    $proj3 = New-GitRepo 'ClaudeEnv'
    $r = Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc3.LocalAppData -ClaudeProjectDir $proj3
    $parsed3 = $null
    try { $parsed3 = $r.Out | ConvertFrom-Json } catch { $parsed3 = $null }
    Check 'CLAUDE_PROJECT_DIR alone also selects the Claude shape, with the right event name' (
        $null -ne $parsed3 -and $null -ne $parsed3.PSObject.Properties['hookSpecificOutput'] -and
        [string]$parsed3.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit') $r.Out

    # =====================================================================
    Write-Host '--- relevance gate: test-related advises, ordinary prompt is silent ---' -ForegroundColor Cyan
    $hc4 = New-IsolatedHookCopy
    $proj4 = New-GitRepo 'Relevance'
    $rRelated = Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc4.LocalAppData
    Check 'a clearly test-related prompt produces advice' ((Get-Message $rRelated.Out) -match '(?i)TEST PLAN CHECK') $rRelated.Out

    $hc5 = New-IsolatedHookCopy
    $proj5 = New-GitRepo 'Irrelevance'
    $rUnrelated = Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'UserPromptSubmit' -Prompt $UnrelatedPrompt -LocalAppData $hc5.LocalAppData
    Check 'an unrelated prompt produces NOTHING' ($rUnrelated.Exit -eq 0 -and $rUnrelated.Out -eq '' -and $rUnrelated.Err -eq '') ($rUnrelated.Out + $rUnrelated.Err)
    $stateAfterSilence = @(Get-ChildItem -LiteralPath (Join-Path $hc5.LocalAppData 'HookMaker\state') -Filter 'TestPlanCheck-*.json' -ErrorAction SilentlyContinue)
    Check 'a silent irrelevant prompt does not even write cooldown state' ($stateAfterSilence.Count -eq 0)

    # =====================================================================
    Write-Host '--- project-specific extra keywords widen the gate ---' -ForegroundColor Cyan
    $hc6 = New-IsolatedHookCopy -EnvContent "TEST_PLAN_EXTRA_KEYWORDS=quokka`n"
    $proj6 = New-GitRepo 'ExtraKeywords'
    $rNoKeyword = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'UserPromptSubmit' -Prompt 'Please rename the invoice column.' -LocalAppData $hc6.LocalAppData
    Check 'without the keyword the prompt stays silent' ($rNoKeyword.Out -eq '') $rNoKeyword.Out
    $rKeyword = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'UserPromptSubmit' -Prompt 'Please rerun the quokka checks for me.' -LocalAppData $hc6.LocalAppData
    Check 'a configured extra keyword makes the prompt relevant' ((Get-Message $rKeyword.Out) -match '(?i)TEST PLAN CHECK') $rKeyword.Out

    # =====================================================================
    Write-Host '--- fingerprint + cooldown: unchanged repeats suppressed, a change reports at once ---' -ForegroundColor Cyan
    $hc7 = New-IsolatedHookCopy
    $proj7 = New-GitRepo 'Cooldown'
    Write-Utf8 (Join-Path $proj7 'tests\test_api.py') "def test_ok():`n    assert True`n"
    & git -C $proj7 add -A 2>$null | Out-Null
    & git -C $proj7 commit -q -m t 2>$null | Out-Null
    $rFirst = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc7.LocalAppData
    Check 'the first relevant prompt reports' ((Get-Message $rFirst.Out) -ne '') $rFirst.Out
    $rRepeat = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc7.LocalAppData
    Check 'an unchanged repeat inside the cooldown is silent' ($rRepeat.Exit -eq 0 -and $rRepeat.Out -eq '') $rRepeat.Out
    $rOtherEvent = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'SessionStart' -LocalAppData $hc7.LocalAppData
    Check 'the cooldown spans events - an unchanged SessionStart is silent too' ($rOtherEvent.Out -eq '') $rOtherEvent.Out
    # Regression guard: the timestamp must round-trip as UTC ticks. Stored as an
    # ISO string, ConvertFrom-Json rehydrates it as a LOCAL-kind [DateTime] and
    # the cooldown silently expires by the local UTC offset.
    $stateJson = Get-Content -LiteralPath (Get-ChildItem -LiteralPath (Join-Path $hc7.LocalAppData 'HookMaker\state') -Filter 'TestPlanCheck-*.json')[0].FullName -Raw | ConvertFrom-Json
    $ticks = [int64]0
    Check 'cooldown state stores a parseable UTC tick count (no ISO round-trip trap)' (
        $null -ne $stateJson.PSObject.Properties['reportedUtcTicks'] -and
        [int64]::TryParse([string]$stateJson.reportedUtcTicks, [ref]$ticks) -and $ticks -gt 0)
    Write-Utf8 (Join-Path $proj7 'tests\test_api.py') "import time`ndef test_ok():`n    time.sleep(300)`n    assert True`n"
    $rChanged = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc7.LocalAppData
    Check 'a CHANGED project state reports immediately, ignoring the cooldown' ((Get-Message $rChanged.Out) -ne '') $rChanged.Out
    Check 'the new minute-scale sleep is reported with a real file:line' ((Get-Message $rChanged.Out) -match 'test_api\.py:3 - blind sleep of 300s') (Get-Message $rChanged.Out)

    # =====================================================================
    Write-Host '--- TEST_PLAN_ALWAYS_REPORT=1 overrides the cooldown ---' -ForegroundColor Cyan
    $hcAlways = New-IsolatedHookCopy -EnvContent "TEST_PLAN_ALWAYS_REPORT=1`n"
    $projAlways = New-GitRepo 'AlwaysReport'
    $null = Fire -HookPath $hcAlways.Script -Cwd $projAlways -EventName 'SessionStart' -LocalAppData $hcAlways.LocalAppData
    $rAgain = Fire -HookPath $hcAlways.Script -Cwd $projAlways -EventName 'SessionStart' -LocalAppData $hcAlways.LocalAppData
    Check 'ALWAYS_REPORT=1 reports again on an unchanged project' ((Get-Message $rAgain.Out) -match '(?i)TEST PLAN CHECK') $rAgain.Out

    # =====================================================================
    Write-Host '--- an unbounded wait is reported; findings always point at a line ---' -ForegroundColor Cyan
    $hc8 = New-IsolatedHookCopy
    $proj8 = New-GitRepo 'UnboundedWait'
    Write-Utf8 (Join-Path $proj8 'scripts\Test-Runner.ps1') "`$p = Start-Process pwsh -PassThru`n`$p.WaitForExit()`n"
    & git -C $proj8 add -A 2>$null | Out-Null
    & git -C $proj8 commit -q -m t 2>$null | Out-Null
    $r = Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'SessionStart' -LocalAppData $hc8.LocalAppData
    $msg8 = Get-Message $r.Out
    Check 'WaitForExit() with no timeout is reported at its line' ($msg8 -match 'Test-Runner\.ps1:2 - WaitForExit\(\) with no timeout') $msg8
    Check 'the finding uses a project-relative path, never the absolute fixture path' ($msg8 -notlike ('*' + $proj8 + '*')) $msg8

    # =====================================================================
    Write-Host '--- a malformed .env falls back to the default, says so, and never crashes ---' -ForegroundColor Cyan
    $hc9 = New-IsolatedHookCopy -EnvContent "TEST_PLAN_COOLDOWN_MINUTES=not-a-number`nTEST_PLAN_ALWAYS_REPORT=maybe`n"
    $proj9 = New-GitRepo 'BadEnv'
    $r = Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'SessionStart' -LocalAppData $hc9.LocalAppData
    $msg9 = Get-Message $r.Out
    Check 'a malformed .env does not crash the hook' ($r.Exit -eq 0 -and $r.Err -eq '') ($r.Err)
    Check 'the invalid cooldown is reported in plain text and the default 120 is used' (
        $msg9 -match 'TEST_PLAN_COOLDOWN_MINUTES is not an integer' -and $msg9 -match '120 minutes pass') $msg9
    Check 'the invalid ALWAYS_REPORT flag is reported too' ($msg9 -match 'TEST_PLAN_ALWAYS_REPORT must be 0 or 1') $msg9

    # =====================================================================
    Write-Host '--- the hook NEVER writes to the project and NEVER runs a test ---' -ForegroundColor Cyan
    $hc10 = New-IsolatedHookCopy
    $proj10 = New-GitRepo 'NeverTouches'
    # If this file were ever executed rather than read, it would drop a marker.
    Write-Utf8 (Join-Path $proj10 'scripts\Test-Sideeffect.ps1') @'
Start-Sleep -Seconds 600
New-Item -ItemType File -Path (Join-Path $PSScriptRoot 'EXECUTED-MARKER.txt') -Force | Out-Null
'@
    & git -C $proj10 add -A 2>$null | Out-Null
    & git -C $proj10 commit -q -m t 2>$null | Out-Null
    $before = Get-TreeSignature $proj10
    $r = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc10.LocalAppData
    $after = Get-TreeSignature $proj10
    Check 'the whole project tree is byte-for-byte identical after the hook ran' ($before -eq $after)
    Check 'no execution marker exists - the hook read the test file, it did not run it' (-not (Test-Path -LiteralPath (Join-Path $proj10 'scripts\EXECUTED-MARKER.txt')))
    Check 'it still DETECTED the 600s sleep by reading' ((Get-Message $r.Out) -match 'Test-Sideeffect\.ps1:1 - blind sleep of 600s') (Get-Message $r.Out)
    Check 'the hook created no client settings inside the project' (
        -not (Test-Path -LiteralPath (Join-Path $proj10 '.claude')) -and -not (Test-Path -LiteralPath (Join-Path $proj10 '.codex')))
    $stateFiles = @(Get-ChildItem -LiteralPath (Join-Path $hc10.LocalAppData 'HookMaker\state') -Filter 'TestPlanCheck-*.json' -ErrorAction SilentlyContinue)
    Check 'its only state lives under the isolated LOCALAPPDATA, exactly one file' ($stateFiles.Count -eq 1)

    # =====================================================================
    Write-Host '--- a non-git project is handled (no fingerprint source) ---' -ForegroundColor Cyan
    $hc11 = New-IsolatedHookCopy
    $proj11 = New-Proj 'NoGit'
    Write-Utf8 (Join-Path $proj11 'tests\test_slow.py') "import time`ntime.sleep(120)`n"
    $r = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'SessionStart' -LocalAppData $hc11.LocalAppData
    Check 'a non-git project still reports its findings without error' (
        $r.Exit -eq 0 -and $r.Err -eq '' -and (Get-Message $r.Out) -match 'test_slow\.py:2 - blind sleep of 120s') ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $hc12 = New-IsolatedHookCopy
    $proj12 = New-GitRepo 'Host51'
    Write-Utf8 (Join-Path $proj12 'scripts\Test-Slow.ps1') "Start-Sleep -Seconds 180`n"
    & git -C $proj12 add -A 2>$null | Out-Null
    & git -C $proj12 commit -q -m t 2>$null | Out-Null
    $r = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hc12.LocalAppData -Exe 'powershell.exe'
    Check '5.1 host: relevance gate, scan and advisory all work' (
        $r.Exit -eq 0 -and (Get-Message $r.Out) -match 'Test-Slow\.ps1:1 - blind sleep of 180s') ($r.Out + $r.Err)
    $r = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'UserPromptSubmit' -Prompt $UnrelatedPrompt -LocalAppData $hc12.LocalAppData -Exe 'powershell.exe'
    Check '5.1 host: an unrelated prompt is still silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- unsupported events and replayed Stop input stay silent ---' -ForegroundColor Cyan
    $hc13 = New-IsolatedHookCopy
    $proj13 = New-GitRepo 'OtherEvents'
    $r = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'PreToolUse' -LocalAppData $hc13.LocalAppData
    Check 'an event this hook does not own is silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'SessionStart' -StopHookActive -LocalAppData $hc13.LocalAppData
    Check 'stop_hook_active is honoured first (recursion guard)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- an excluded tree (node_modules) is pruned before descent, never scanned ---' -ForegroundColor Cyan
    $hcExcl = New-IsolatedHookCopy
    $projExcl = New-GitRepo 'Excluded'
    # A risky pattern buried in an excluded tree must NOT be reported...
    Write-Utf8 (Join-Path $projExcl 'node_modules\pkg\tests\test_dep.py') "import time`ntime.sleep(500)`n"
    # ...while a real top-level test file still is.
    Write-Utf8 (Join-Path $projExcl 'tests\test_app.py') "import time`ntime.sleep(200)`n"
    & git -C $projExcl add -A 2>$null | Out-Null
    & git -C $projExcl commit -q -m t 2>$null | Out-Null
    $rExcl = Fire -HookPath $hcExcl.Script -Cwd $projExcl -EventName 'SessionStart' -LocalAppData $hcExcl.LocalAppData
    $msgExcl = Get-Message $rExcl.Out
    Check 'the real top-level test file IS reported' ($msgExcl -match 'test_app\.py:2 - blind sleep of 200s') $msgExcl
    Check 'the node_modules test file is NOT reported (tree pruned, never descended)' ($msgExcl -notmatch 'test_dep\.py') $msgExcl
    Check 'pruning a large excluded tree is not treated as partial coverage' ($msgExcl -notmatch '(?i)PARTIAL') $msgExcl

    # =====================================================================
    Write-Host '--- a reparse point (junction) is never followed ---' -ForegroundColor Cyan
    $hcRp = New-IsolatedHookCopy
    $projRp = New-GitRepo 'Reparse'
    # Real test content OUTSIDE the repo, reachable only via a junction inside it.
    $rpTarget = Join-Path $Work ('rp-target-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $rpTarget 'tests') -Force | Out-Null
    Write-Utf8 (Join-Path $rpTarget 'tests\test_linked.py') "import time`ntime.sleep(400)`n"
    # A normal in-repo finding proves the scan otherwise works.
    Write-Utf8 (Join-Path $projRp 'tests\test_local.py') "import time`ntime.sleep(150)`n"
    & git -C $projRp add -A 2>$null | Out-Null
    & git -C $projRp commit -q -m t 2>$null | Out-Null
    $rpLink = Join-Path $projRp 'linked'
    $madeJunction = $false
    try { New-Item -ItemType Junction -Path $rpLink -Target $rpTarget -ErrorAction Stop | Out-Null; $madeJunction = $true } catch { }
    if (-not $madeJunction) {
        try { & cmd /c mklink /J "$rpLink" "$rpTarget" 2>$null | Out-Null } catch { }
        $madeJunction = (Test-Path -LiteralPath $rpLink) -and
            ((((Get-Item -LiteralPath $rpLink -Force).Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    if ($madeJunction) {
        $rRp = Fire -HookPath $hcRp.Script -Cwd $projRp -EventName 'SessionStart' -LocalAppData $hcRp.LocalAppData
        $msgRp = Get-Message $rRp.Out
        Check 'the in-repo test file IS reported (scan otherwise works)' ($msgRp -match 'test_local\.py:2 - blind sleep of 150s') $msgRp
        Check 'content behind the junction is NOT reported (reparse point not followed)' ($msgRp -notmatch 'test_linked\.py') $msgRp
    }
    else {
        Write-Host '[SKIP] junction could not be created in this harness - reparse-skip assertion skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- a MAX_DIRS ceiling stops the walk and reports partial coverage ---' -ForegroundColor Cyan
    $hcDir = New-IsolatedHookCopy -EnvContent "TEST_PLAN_MAX_DIRS=1`n"
    $projDir = New-GitRepo 'DirCeiling'
    # The only finding lives one level down; with MAX_DIRS=1 the root is visited
    # but its subdirectory is never descended.
    Write-Utf8 (Join-Path $projDir 'sub\tests\test_deep.py') "import time`ntime.sleep(300)`n"
    & git -C $projDir add -A 2>$null | Out-Null
    & git -C $projDir commit -q -m t 2>$null | Out-Null
    $rDir = Fire -HookPath $hcDir.Script -Cwd $projDir -EventName 'SessionStart' -LocalAppData $hcDir.LocalAppData
    $msgDir = Get-Message $rDir.Out
    Check 'the directory ceiling makes the scan report PARTIAL coverage' ($msgDir -match '(?i)PARTIAL') $msgDir
    Check 'a finding below the ceiling depth is not scanned (walk pruned by the ceiling)' ($msgDir -notmatch 'test_deep\.py') $msgDir
    Check 'MAX_DIRS=1 is a valid value (no config warning)' ($msgDir -notmatch 'TEST_PLAN_MAX_DIRS is not') $msgDir

    # =====================================================================
    Write-Host '--- a MAX_FINDINGS ceiling stops the scan and reports partial coverage ---' -ForegroundColor Cyan
    $hcFind = New-IsolatedHookCopy -EnvContent "TEST_PLAN_MAX_FINDINGS=1`n"
    $projFind = New-GitRepo 'FindCeiling'
    # Three minute-scale sleeps; only the first may be emitted before the cap trips.
    Write-Utf8 (Join-Path $projFind 'tests\test_many.py') "import time`ntime.sleep(120)`ntime.sleep(180)`ntime.sleep(240)`n"
    & git -C $projFind add -A 2>$null | Out-Null
    & git -C $projFind commit -q -m t 2>$null | Out-Null
    $rFind = Fire -HookPath $hcFind.Script -Cwd $projFind -EventName 'SessionStart' -LocalAppData $hcFind.LocalAppData
    $msgFind = Get-Message $rFind.Out
    Check 'the findings ceiling makes the scan report PARTIAL coverage' ($msgFind -match '(?i)PARTIAL') $msgFind
    $observedCount = @([regex]::Matches($msgFind, 'blind sleep of')).Count
    Check 'only the capped number of findings (1) is emitted' ($observedCount -eq 1) ("count=$observedCount :: " + $msgFind)
}
finally {
    $env:CLAUDE_PROJECT_DIR = $SavedClaudeProjectDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
