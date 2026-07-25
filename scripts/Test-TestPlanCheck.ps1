# Offline test suite for Test-Plan-Check - the BEFORE stage of the three-stage
# test-health architecture. New hook, no prior coverage.
#
# Covers the explicit contract, not an exhaustive keyword matrix:
# relevance gating (a test-related prompt advises, an ordinary prompt is
# silent); the fingerprint + cooldown (an unchanged repeat is suppressed, a
# CHANGED state reports immediately); the client output shapes this hook's two
# events can produce (Claude AND Codex both take
# hookSpecificOutput.additionalContext off Stop - Codex's systemMessage is
# Stop-scoped and must never appear here - while Kiro takes plain stdout);
# SessionStart and
# UserPromptSubmit; pointable findings (minute-scale sleep, unbounded wait);
# a malformed .env falling back to the default with a message instead of
# crashing; output being a single valid JSON document; the HM-04 per-entry
# time stop (including extension-NON-matching files); the HM-07 runner-keyed
# (12-char) timing-baseline advisory; and the two hard guarantees - the hook
# NEVER writes into the project and NEVER runs a test (proved by comparing
# bytes, not Test-Path).
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
        [switch]$StopHookActive, [string]$Exe = 'pwsh', [hashtable]$ExtraEnv = @{}
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
        $envTable = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData; CLAUDE_PROJECT_DIR = $ClaudeProjectDir }
        foreach ($k in $ExtraEnv.Keys) { $envTable[$k] = [string]$ExtraEnv[$k] }
        $startArgs.Environment = $envTable
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
    Write-Host '--- SessionStart advises, as one valid JSON document, in the Codex OFF-Stop shape ---' -ForegroundColor Cyan
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
    # THE CODEX x OFF-STOP PAIR. Codex documents `systemMessage` for Stop/
    # SubagentStop ONLY; on every other event it honours additionalContext, and
    # SessionStart is every-other-event. This hook never runs on Stop at all, so
    # `systemMessage` must never appear in ANY of its output. Leaving this pair
    # unasserted is exactly how the wrong shape shipped.
    Check 'Codex OFF Stop (no CLAUDE_PROJECT_DIR) gets hookSpecificOutput.additionalContext, never systemMessage' (
        $null -ne $parsed -and $null -eq $parsed.PSObject.Properties['systemMessage'] -and
        $null -ne $parsed.PSObject.Properties['hookSpecificOutput'] -and
        [string]$parsed.hookSpecificOutput.hookEventName -eq 'SessionStart' -and
        -not [string]::IsNullOrWhiteSpace([string]$parsed.hookSpecificOutput.additionalContext)) $r.Out
    $msg1 = Get-Message $r.Out
    Check 'the advisory surfaces the bounded wall/idle timeout policy point' ($msg1 -match '(?i)wall timeout' -and $msg1 -match '(?i)idle') $msg1
    Check 'the advisory surfaces resource-aware parallelism and process cleanup' ($msg1 -match '(?i)cores-2' -and $msg1 -match '(?i)process tree') $msg1
    # The policy block itself mentions blind sleeps, so absence is asserted on
    # the findings SECTION, which only appears when something real was seen.
    Check 'a bounded test file produces no invented finding' ($msg1 -notmatch '(?i)Observed in this project') $msg1
    Check 'a small, fully-scanned project is NOT marked partial' ($msg1 -notmatch '(?i)PARTIAL') $msg1

    # =====================================================================
    Write-Host '--- client detection comes from Get-HookClientId, not from the INPUT envelope ---' -ForegroundColor Cyan
    # `hookSpecificOutput` echoed in the INPUT event is NOT a documented client
    # signal and Get-HookClientId does not implement it; with no
    # CLAUDE_PROJECT_DIR this is still Codex, which off Stop is the same
    # additionalContext shape - so the envelope must change NOTHING here.
    $hc2 = New-IsolatedHookCopy
    $proj2 = New-GitRepo 'ClaudeShape'
    $r = Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'SessionStart' -LocalAppData $hc2.LocalAppData -ClaudeInputShape
    $parsed2 = $null
    try { $parsed2 = $r.Out | ConvertFrom-Json } catch { $parsed2 = $null }
    Check 'an INPUT hookSpecificOutput is not a client signal: still the off-Stop additionalContext shape' (
        $null -ne $parsed2 -and $null -ne $parsed2.PSObject.Properties['hookSpecificOutput'] -and
        $null -eq $parsed2.PSObject.Properties['systemMessage'] -and
        -not [string]::IsNullOrWhiteSpace([string]$parsed2.hookSpecificOutput.additionalContext) -and
        [string]$parsed2.hookSpecificOutput.hookEventName -eq 'SessionStart') $r.Out
    Check 'the advisory never emits decision:block (this hook may never block)' ($r.Out -notmatch '(?i)"decision"') $r.Out

    # The one client whose shape is observably different on this hook's events:
    # Kiro takes PLAIN stdout on SessionStart/UserPromptSubmit, never JSON. It is
    # reachable only through Get-HookClientId, so this fails outright if the hook
    # ever goes back to deciding the client for itself.
    $hcKiro = New-IsolatedHookCopy
    $rKiro = Fire -HookPath $hcKiro.Script -Cwd $proj2 -EventName 'SessionStart' -LocalAppData $hcKiro.LocalAppData -ExtraEnv @{ HOOKMAKER_CLIENT = 'kiro' }
    $parsedKiro = $null
    try { $parsedKiro = $rKiro.Out | ConvertFrom-Json } catch { $parsedKiro = $null }
    Check 'HOOKMAKER_CLIENT=kiro selects plain stdout, not either JSON envelope' (
        $rKiro.Exit -eq 0 -and $rKiro.Err -eq '' -and $null -eq $parsedKiro -and
        $rKiro.Out -match '(?i)TEST PLAN CHECK' -and $rKiro.Out -notmatch '(?i)hookSpecificOutput' -and
        $rKiro.Out -notmatch '(?i)systemMessage') ($rKiro.Out + $rKiro.Err)

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

    # =====================================================================
    Write-Host '--- one huge single directory trips the TIME ceiling MID-ENUMERATION (HM-04) ---' -ForegroundColor Cyan
    # Pre-fix, the wall-time ceiling was checked only BETWEEN directories, so one
    # directory holding a huge number of non-test (yet extension-matching) files ran
    # to the end during enumeration and overran TEST_PLAN_MAX_SCAN_SECONDS. The fix
    # enumerates lazily and checks the deadline for EVERY enumerated entry, before
    # the extension match. The test seam forces a deterministic mid-enumeration trip
    # so the assertion never depends on real wall-clock timing.
    $projTrip = New-Proj 'TimeTrip'
    # Many extension-matching NON-test files that sort BEFORE the one test file, so a
    # mid-enumeration TIME stop is reached before the test file is ever enumerated.
    # The test file (sorts last) carries the only finding.
    for ($fi = 1; $fi -le 12; $fi++) {
        Write-Utf8 (Join-Path $projTrip ('bulk\f{0:00}.ps1' -f $fi)) ('$x = ' + $fi + "`n")
    }
    Write-Utf8 (Join-Path $projTrip 'bulk\zz_test_slow.ps1') "Start-Sleep -Seconds 300`n"
    # Seam ON: trip after 5 enumerated ENTRIES (the `bulk` dir counts as one, then
    # f01..f04) -> the walk stops inside `bulk` long before reaching zz_test_slow,
    # so its finding is absent and the cause is TIME.
    $hcTrip = New-IsolatedHookCopy
    $rTrip = Fire -HookPath $hcTrip.Script -Cwd $projTrip -EventName 'SessionStart' -LocalAppData $hcTrip.LocalAppData -ExtraEnv @{ TESTPLANCHECK_TEST_TRIP_TIME_AFTER_FILES = '5' }
    $msgTrip = Get-Message $rTrip.Out
    Check 'a mid-enumeration TIME stop marks the scan PARTIAL' ($msgTrip -match '(?i)PARTIAL') $msgTrip
    Check 'the partial cause NAMES time, not files/dirs/read-failure' (
        $msgTrip -match 'scan time limit' -and $msgTrip -notmatch 'directory ceiling' -and
        $msgTrip -notmatch 'candidate-file ceiling' -and $msgTrip -notmatch 'could not be read') $msgTrip
    Check 'the finding behind the trip point is absent (enumeration really stopped early)' ($msgTrip -notmatch 'zz_test_slow') $msgTrip

    # NEGATIVE CONTROL: same fixture, NO seam -> the real Stopwatch never trips on a
    # handful of tiny files, so the scan completes, the finding IS found, and nothing
    # is marked partial. Proves the PARTIAL above is the mid-enumeration time stop,
    # not the fixture itself.
    $hcFull = New-IsolatedHookCopy
    $rFull = Fire -HookPath $hcFull.Script -Cwd $projTrip -EventName 'SessionStart' -LocalAppData $hcFull.LocalAppData
    $msgFull = Get-Message $rFull.Out
    Check 'without the seam the same fixture scans fully (not partial)' ($msgFull -notmatch '(?i)PARTIAL') $msgFull
    Check 'without the seam the test-file finding IS reported' ($msgFull -match 'zz_test_slow\.ps1:1 - blind sleep of 300s') $msgFull

    # =====================================================================
    Write-Host '--- extension-NON-matching files also pay the per-entry time check (HM-04) ---' -ForegroundColor Cyan
    # Pre-fix, the in-loop time check sat BEHIND the cheap extension match, so a
    # huge directory of extension-NON-matching files never paid a single time
    # check during enumeration. This fixture contains ONLY non-matching files;
    # the seam trips mid-enumeration, so the scan must still go PARTIAL with the
    # TIME cause - proving the deadline is paid per enumerated entry, not per
    # extension-matching file.
    $projNm = New-Proj 'NonMatchTrip'
    for ($fi = 1; $fi -le 8; $fi++) {
        Write-Utf8 (Join-Path $projNm ('data\d{0:00}.txt' -f $fi)) ('row ' + $fi + "`n")
    }
    $hcNm = New-IsolatedHookCopy
    $rNm = Fire -HookPath $hcNm.Script -Cwd $projNm -EventName 'SessionStart' -LocalAppData $hcNm.LocalAppData -ExtraEnv @{ TESTPLANCHECK_TEST_TRIP_TIME_AFTER_FILES = '3' }
    $msgNm = Get-Message $rNm.Out
    Check 'a non-matching-only directory still trips the TIME stop -> PARTIAL' ($rNm.Exit -eq 0 -and $rNm.Err -eq '' -and $msgNm -match '(?i)PARTIAL') ($msgNm + $rNm.Err)
    Check 'the partial cause NAMES time, not files/dirs/read-failure' (
        $msgNm -match 'scan time limit' -and $msgNm -notmatch 'directory ceiling' -and
        $msgNm -notmatch 'candidate-file ceiling' -and $msgNm -notmatch 'could not be read') $msgNm
    # Negative control: without the seam the same all-non-matching fixture scans
    # fully - the per-entry check itself must not invent a partial result.
    $hcNmCtl = New-IsolatedHookCopy
    $rNmCtl = Fire -HookPath $hcNmCtl.Script -Cwd $projNm -EventName 'SessionStart' -LocalAppData $hcNmCtl.LocalAppData
    Check 'without the seam the non-matching fixture scans fully (not partial)' ((Get-Message $rNmCtl.Out) -notmatch '(?i)PARTIAL') (Get-Message $rNmCtl.Out)

    # =====================================================================
    Write-Host '--- a reparse-point (junction) scan ROOT is refused and marked partial (HM-04) ---' -ForegroundColor Cyan
    # Real test content in a normal directory, reachable as a scan ROOT only via a
    # junction. The root reparse check must refuse the junction root (push nothing)
    # so no finding comes from behind it, and mark the scan partial naming the root.
    $rootTgt = Join-Path $Work ('rproot-tgt-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $rootTgt 'tests') -Force | Out-Null
    Write-Utf8 (Join-Path $rootTgt 'tests\test_root.py') "import time`ntime.sleep(300)`n"
    # Control: scanning the target directory DIRECTLY finds the finding (it is real).
    $hcCtl = New-IsolatedHookCopy
    $rCtl = Fire -HookPath $hcCtl.Script -Cwd $rootTgt -EventName 'SessionStart' -LocalAppData $hcCtl.LocalAppData
    Check 'control: scanning the target directly DOES find the finding' ((Get-Message $rCtl.Out) -match 'test_root\.py:2 - blind sleep of 300s') (Get-Message $rCtl.Out)
    # Now a junction whose cwd IS the reparse point.
    $rootJct = Join-Path $Work ('rproot-jct-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $madeRootJct = $false
    try { New-Item -ItemType Junction -Path $rootJct -Target $rootTgt -ErrorAction Stop | Out-Null; $madeRootJct = $true } catch { }
    if (-not $madeRootJct) {
        try { & cmd /c mklink /J "$rootJct" "$rootTgt" 2>$null | Out-Null } catch { }
        $madeRootJct = (Test-Path -LiteralPath $rootJct) -and
            ((((Get-Item -LiteralPath $rootJct -Force).Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    if ($madeRootJct) {
        $hcJct = New-IsolatedHookCopy
        $rJct = Fire -HookPath $hcJct.Script -Cwd $rootJct -EventName 'SessionStart' -LocalAppData $hcJct.LocalAppData
        $msgJct = Get-Message $rJct.Out
        Check 'a junction scan ROOT is refused -> the scan is PARTIAL naming the root' (
            $msgJct -match '(?i)PARTIAL' -and $msgJct -match '(?i)scan root is a junction') $msgJct
        Check 'the finding behind the junction root is absent (root not followed)' ($msgJct -notmatch 'test_root\.py') $msgJct
    }
    else {
        Write-Host '[SKIP] root junction could not be created in this harness - reparse-root assertion skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- a runner-stored timing baseline surfaces in the advisory (HM-07) ---' -ForegroundColor Cyan
    # The guarded runner stores TestTiming-<projectKey>-<cmdFp>.json with a 12-char
    # projectKey (Run-Tests-Guarded.ps1 Get-ProjectKey: SHA-256 of the lowercased
    # cwd, Substring(0,12)). Pre-fix the hook matched with the 10-char Get-ShortHash,
    # so a 10-char candidate never equalled the stored 12-char key and the baseline
    # line NEVER surfaced. The fixture below is keyed EXACTLY like the runner; the
    # fixed hook must surface it. TEST_PLAN_ALWAYS_REPORT=1 bypasses the cooldown.
    $hcTm = New-IsolatedHookCopy -EnvContent "TEST_PLAN_ALWAYS_REPORT=1`n"
    $projTm = New-GitRepo 'TimingBaseline'
    $tmSha = [System.Security.Cryptography.SHA256]::Create()
    try { $tmKey12 = ([System.BitConverter]::ToString($tmSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($projTm.ToLowerInvariant()))) -replace '-', '').ToLowerInvariant().Substring(0, 12) }
    finally { $tmSha.Dispose() }
    $tmStateDir = Join-Path $hcTm.LocalAppData 'HookMaker\state'
    New-Item -ItemType Directory -Path $tmStateDir -Force | Out-Null
    # >= 5 'ok' samples (the TimingMinBaseline the hook requires), runner field shape.
    $tmSamples = @(1..5 | ForEach-Object {
            [pscustomobject]@{ runId = ('r' + $_); elapsedSeconds = 12.3; outcome = 'ok'; utc = '2026-01-01T00:00:00.0000000Z'; workerCeiling = 4; suiteLabel = '' }
        })
    $tmDoc = [pscustomobject]@{ version = 1; projectKey = $tmKey12; commandFingerprint = ('ab' * 16); samples = $tmSamples }
    Write-Utf8 (Join-Path $tmStateDir ('TestTiming-' + $tmKey12 + '-' + ('ab' * 16) + '.json')) ($tmDoc | ConvertTo-Json -Depth 6)
    $rTm = Fire -HookPath $hcTm.Script -Cwd $projTm -EventName 'SessionStart' -LocalAppData $hcTm.LocalAppData
    $msgTm = Get-Message $rTm.Out
    Check 'the 12-char runner projectKey matches and the baseline line appears' (
        $rTm.Exit -eq 0 -and $rTm.Err -eq '' -and $msgTm -match 'prior test-timing baseline exists for 1 recorded command') ($msgTm + $rTm.Err)
    # Control: a timing file for a DIFFERENT project (different 12-char key) must
    # NOT be counted - the match is by stored key, not by file presence.
    $hcTmOther = New-IsolatedHookCopy -EnvContent "TEST_PLAN_ALWAYS_REPORT=1`n"
    $tmOtherState = Join-Path $hcTmOther.LocalAppData 'HookMaker\state'
    New-Item -ItemType Directory -Path $tmOtherState -Force | Out-Null
    $tmOtherDoc = [pscustomobject]@{ version = 1; projectKey = ('0' * 12); commandFingerprint = ('cd' * 16); samples = $tmSamples }
    Write-Utf8 (Join-Path $tmOtherState ('TestTiming-' + ('0' * 12) + '-' + ('cd' * 16) + '.json')) ($tmOtherDoc | ConvertTo-Json -Depth 6)
    $rTmOther = Fire -HookPath $hcTmOther.Script -Cwd $projTm -EventName 'SessionStart' -LocalAppData $hcTmOther.LocalAppData
    Check 'a foreign-project timing file is NOT counted as this project''s baseline' ((Get-Message $rTmOther.Out) -notmatch 'prior test-timing baseline') (Get-Message $rTmOther.Out)

    # =====================================================================
    Write-Host '--- E-03: standalone ::deep-debug extends the advisory; prose never does ---' -ForegroundColor Cyan
    $hcDd = New-IsolatedHookCopy
    $projDd = New-GitRepo 'DeepDebug'
    # Prose "deep debug" with NO other test keyword: total silence (the codeword
    # never activates from prose, and nothing else makes the prompt relevant).
    $rProse = Fire -HookPath $hcDd.Script -Cwd $projDd -EventName 'UserPromptSubmit' -Prompt 'let us deep debug the login flow now' -LocalAppData $hcDd.LocalAppData
    Check 'prose "deep debug" (no test keyword) stays totally silent' ($rProse.Exit -eq 0 -and $rProse.Out -eq '') $rProse.Out
    # Prose "deep debug" WITH a test keyword: the NORMAL advisory, no dd section.
    $rProseTest = Fire -HookPath $hcDd.Script -Cwd $projDd -EventName 'UserPromptSubmit' -Prompt 'deep debug this flaky test suite please' -LocalAppData $hcDd.LocalAppData
    $msgProse = Get-Message $rProseTest.Out
    Check 'prose "deep debug" + test keyword -> plain advisory WITHOUT the dd section' (
        $msgProse -match '(?i)TEST PLAN CHECK' -and $msgProse -notmatch '::deep-debug detected') $msgProse
    # A STANDALONE ::deep-debug token alone (no other keyword) passes the gate
    # and the advisory carries the deep-debug plan requirements.
    $hcDd2 = New-IsolatedHookCopy
    $projDd2 = New-GitRepo 'DeepDebugToken'
    $rDd = Fire -HookPath $hcDd2.Script -Cwd $projDd2 -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $hcDd2.LocalAppData
    $msgDd = Get-Message $rDd.Out
    Check 'standalone ::deep-debug alone is relevant and advises' ($msgDd -match '(?i)TEST PLAN CHECK' -and $msgDd -match '::deep-debug detected') $msgDd
    Check 'dd: persistent regression test/fixture + original failing/edge paths' (
        $msgDd -match 'PERSISTENT regression test' -and $msgDd -match 'original failing path' -and $msgDd -match 'failure/edge paths') $msgDd
    Check 'dd: bounded per-test/suite/command/idle/CI time + documented native timeout + outer guarded limit' (
        $msgDd -match 'per-test, per-suite, whole-command, idle/no-progress and CI-job time' -and
        $msgDd -match 'DOCUMENTED native timeout' -and $msgDd -match 'never a guessed flag' -and $msgDd -match 'outer guarded-runner limit') $msgDd
    Check 'dd: no blind sleep/unbounded polling/interactive wait/hidden retry + ONE shared worker ceiling' (
        $msgDd -match 'No blind sleeps, unbounded polling, interactive waits' -and $msgDd -match 'hidden retries' -and
        $msgDd -match 'ONE shared resource-aware worker ceiling') $msgDd
    Check 'dd: child-process/temp cleanup + property tests only for real invariants + security findings need confirmation' (
        $msgDd -match 'Terminate owned child processes and clean temporary resources' -and
        $msgDd -match 'REAL invariant' -and $msgDd -match 'security-tool finding needs confirmation') $msgDd
    Check 'dd: Ponytail simplifications get targeted tests, never a second broad loop' (
        $msgDd -match 'Ponytail simplifications get TARGETED tests only' -and $msgDd -match 'never a second broad debug/audit loop') $msgDd
    Check 'dd: new/modified test text is UTF-8 unless documented exception; new Test-*.ps1 CI-mapped' (
        $msgDd -match 'UTF-8 unless a documented technical exception applies' -and $msgDd -match 'permanently mapped to CI') $msgDd
    Check 'dd: the UTF-8 line defers file validation to Utf8-Encoding-Check (no second scanner here)' (
        $msgDd -match 'Utf8-Encoding-Check validates the files' -and $msgDd -match 'does not rescan') $msgDd
    # Same fingerprint gate: an unchanged repeat of the SAME dd prompt is silent.
    $rDdRepeat = Fire -HookPath $hcDd2.Script -Cwd $projDd2 -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $hcDd2.LocalAppData
    Check 'dd anti-loop: an unchanged ::deep-debug repeat inside the cooldown is silent' ($rDdRepeat.Exit -eq 0 -and $rDdRepeat.Out -eq '') $rDdRepeat.Out
    # Normal behavior unchanged AFTER dd: a later plain test prompt re-reports
    # the plain advisory (state changed: dd flag left the fingerprint) with no
    # dd section - the dd path never leaks into ordinary work.
    $rPlainAfter = Fire -HookPath $hcDd2.Script -Cwd $projDd2 -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hcDd2.LocalAppData
    $msgPlainAfter = Get-Message $rPlainAfter.Out
    Check 'a later plain test prompt reports the NORMAL advisory without dd lines' (
        $msgPlainAfter -match '(?i)TEST PLAN CHECK' -and $msgPlainAfter -notmatch '::deep-debug detected') $msgPlainAfter
    # Client shapes: the dd advisory rides the same client-aware envelope.
    $hcDdClaude = New-IsolatedHookCopy
    $projDdCl = New-GitRepo 'DeepDebugClaude'
    $rDdCl = Fire -HookPath $hcDdClaude.Script -Cwd $projDdCl -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $hcDdClaude.LocalAppData -ClaudeProjectDir $projDdCl
    $parsedDdCl = $null
    try { $parsedDdCl = $rDdCl.Out | ConvertFrom-Json } catch { $parsedDdCl = $null }
    Check 'dd advisory uses the Claude shape (hookSpecificOutput.additionalContext) for Claude' (
        $null -ne $parsedDdCl -and $null -ne $parsedDdCl.PSObject.Properties['hookSpecificOutput'] -and
        ([string]$parsedDdCl.hookSpecificOutput.additionalContext) -match '::deep-debug detected' -and
        $rDdCl.Out -notmatch '"decision"') $rDdCl.Out
    $hcDdCodex = New-IsolatedHookCopy
    $projDdCx = New-GitRepo 'DeepDebugCodex'
    $rDdCx = Fire -HookPath $hcDdCodex.Script -Cwd $projDdCx -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $hcDdCodex.LocalAppData
    $parsedDdCx = $null
    try { $parsedDdCx = $rDdCx.Out | ConvertFrom-Json } catch { $parsedDdCx = $null }
    # THE CODEX x OFF-STOP PAIR again, on the other event this hook owns.
    Check 'dd advisory uses the Codex OFF-Stop shape (additionalContext, never systemMessage)' (
        $null -ne $parsedDdCx -and $null -eq $parsedDdCx.PSObject.Properties['systemMessage'] -and
        $null -ne $parsedDdCx.PSObject.Properties['hookSpecificOutput'] -and
        [string]$parsedDdCx.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit' -and
        ([string]$parsedDdCx.hookSpecificOutput.additionalContext) -match '::deep-debug detected') $rDdCx.Out

    # =====================================================================
    Write-Host '--- E-13: static safety - the hook only DESCRIBES commands, it never executes them ---' -ForegroundColor Cyan
    # 'Start-Process' appears in the source only inside DETECTION regex/string
    # literals, so the assertion targets STATEMENT position (start of a line),
    # where an actual invocation would have to sit.
    $tpcText = [System.IO.File]::ReadAllText($Hook)
    Check 'source has no execution primitive in statement position (Start-Process/Invoke-Expression/iex)' (
        $tpcText -notmatch '(?im)^\s*(Start-Process|Invoke-Expression|iex)\b') $tpcText.Substring(0, 200)
    Check 'source never applies the call operator to data (no "& $var" execution path)' ($tpcText -notmatch '&\s+\$') $tpcText.Substring(0, 200)
    Check 'source references ::deep-debug only as a match pattern/advisory text (no slash-command execution)' (
        $tpcText -match '::deep-debug' -and $tpcText -notmatch '(?im)^\s*/(goal|ponytail)') $tpcText.Substring(0, 200)

    # =====================================================================
    Write-Host '--- E-13 RED-PROOF: the pre-fix hook has no ::deep-debug path (HEAD copy, retire-guarded) ---' -ForegroundColor Cyan
    # Reconstructed via read-only `git show HEAD:` (never a tree mutation). FIX
    # MARKER retire guard: once the dd advisory is committed, HEAD contains
    # '::deep-debug' and this historical proof retires (byte/extent equality is
    # never used - git show emits LF while working files are CRLF).
    $tpcRepoRoot = Split-Path -Parent $ScriptRoot
    $tpcPreText = ((& git -C $tpcRepoRoot show 'HEAD:hooks/Test-Plan-Check/Test-Plan-Check.ps1') -join "`n")
    if ($tpcPreText -match '::deep-debug') {
        Write-Host 'HEAD already contains the ::deep-debug advisory; historical red-proof retired.' -ForegroundColor DarkGray
    }
    else {
        $tpcPreDir = Join-Path $Work '_prefix-tpc'
        New-Item -ItemType Directory -Path $tpcPreDir -Force | Out-Null
        $tpcPreHook = Join-Path $tpcPreDir 'Test-Plan-Check.ps1'
        [System.IO.File]::WriteAllText($tpcPreHook, $tpcPreText, (New-Object System.Text.UTF8Encoding $false))
        Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force   # '..\_hooklib.ps1' resolves to $Work
        $tpcPreLocal = Join-Path $tpcPreDir '_fakelocal'
        New-Item -ItemType Directory -Path $tpcPreLocal -Force | Out-Null
        $projRed = New-GitRepo 'DeepDebugRed'
        $rRed = Fire -HookPath $tpcPreHook -Cwd $projRed -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $tpcPreLocal
        Check 'RED-PROOF: the PRE-FIX hook is totally silent for a standalone ::deep-debug prompt' ($rRed.Exit -eq 0 -and $rRed.Out -eq '') $rRed.Out
    }

    # =====================================================================
    Write-Host '--- E-13: installed-runtime parity + stale runtime repaired by the update flow ---' -ForegroundColor Cyan
    # Real install into a temp project (registry isolated via HOOKMAKER_STATE_DIR),
    # then: (a) the runtime copy emits IDENTICAL dd guidance to the source hook;
    # (b) a tampered/stale runtime is repaired back to current source by re-running
    # the installer - the same repair path Update installed hooks drives (the
    # pattern Test-RulesCheck/Test-InstallRegistry use).
    $tpcInstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
    $savedHmStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = Join-Path $Work 'hmstate'
    try {
        $tgtProj = New-Proj 'InstallTarget'
        & $tpcInstallScript -CustomHook $Hook -Events @('SessionStart', 'UserPromptSubmit') -TargetProject $tgtProj -ClaudeOnly *> $null
        $tpcRuntime = Join-Path $tgtProj '.claude\hooks\Hook-Maker\Test-Plan-Check\Test-Plan-Check.ps1'
        Check 'the installed runtime copy exists (self-contained install)' (Test-Path -LiteralPath $tpcRuntime -PathType Leaf)
        # The staged runtime is deliberately NOT byte-identical to source: the
        # installer normalizes the BOM and rewrites the shared-library dot-source
        # ('..\_hooklib.ps1' -> the private '_hooklib.ps1' beside the copy). So
        # identity is proven on the decoded text after applying exactly that
        # documented rewrite, and the repair proof below uses the runtime's own
        # canonical installed hash.
        $tpcExpectedRuntimeText = ([System.IO.File]::ReadAllText($Hook)).Replace('''..\_hooklib.ps1''', '''_hooklib.ps1''')
        Check 'the installed runtime matches source content (BOM + dot-source rewrite are the only differences)' (
            [System.IO.File]::ReadAllText($tpcRuntime) -eq $tpcExpectedRuntimeText)
        $canonHash = (Get-FileHash -LiteralPath $tpcRuntime -Algorithm SHA256).Hash
        # (a) parity: same dd prompt, fresh isolated state each, identical text.
        $parSrcLocal = Join-Path $Work '_par-src-local'; New-Item -ItemType Directory -Path $parSrcLocal -Force | Out-Null
        $parCopyLocal = Join-Path $Work '_par-copy-local'; New-Item -ItemType Directory -Path $parCopyLocal -Force | Out-Null
        $projPar = New-GitRepo 'ParityProj'
        $hcParity = New-IsolatedHookCopy
        $rParSrc = Fire -HookPath $hcParity.Script -Cwd $projPar -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $parSrcLocal
        $rParCopy = Fire -HookPath $tpcRuntime -Cwd $projPar -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $parCopyLocal
        $msgParSrc = Get-Message $rParSrc.Out
        $msgParCopy = Get-Message $rParCopy.Out
        Check 'installed runtime emits IDENTICAL ::deep-debug guidance to the source hook' (
            $msgParSrc -ne '' -and $msgParSrc -eq $msgParCopy) ('src=[' + $msgParSrc + '] copy=[' + $msgParCopy + ']')
        # (b) stale runtime -> update flow -> current again.
        Add-Content -LiteralPath $tpcRuntime -Value '# tampered stale runtime'
        Check 'the tampered runtime no longer matches the canonical installed content' ((Get-FileHash -LiteralPath $tpcRuntime -Algorithm SHA256).Hash -ne $canonHash)
        & $tpcInstallScript -CustomHook $Hook -Events @('SessionStart', 'UserPromptSubmit') -TargetProject $tgtProj -ClaudeOnly *> $null
        Check 'after the update flow the runtime matches current source again (canonical hash restored)' (
            (Get-FileHash -LiteralPath $tpcRuntime -Algorithm SHA256).Hash -eq $canonHash -and
            [System.IO.File]::ReadAllText($tpcRuntime) -eq $tpcExpectedRuntimeText)
        $parRepairLocal = Join-Path $Work '_par-repair-local'; New-Item -ItemType Directory -Path $parRepairLocal -Force | Out-Null
        $rParRepaired = Fire -HookPath $tpcRuntime -Cwd $projPar -EventName 'UserPromptSubmit' -Prompt '::deep-debug' -LocalAppData $parRepairLocal
        Check 'the repaired runtime emits the current ::deep-debug guidance' ((Get-Message $rParRepaired.Out) -match '::deep-debug detected') (Get-Message $rParRepaired.Out)
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedHmStateDir }
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
