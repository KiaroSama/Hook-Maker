# Offline test suite for Large-File-Check - the two-stage, advisory-only
# oversized-source detector.
#
# Covers the 27.txt contract: the pre-task preventive guidance (design correctly
# from the start, uses the effective threshold, cohesion-first / anti-wrapper, AI
# owns the decision); the Stop scan (strict greater-than so 800 is silent and 801
# is reported but never forced to split, largest-first ordering + remaining count,
# cooldown, stop_hook_active recursion guard, excluded trees, reparse points not
# followed, >3 MB files skipped, honest PARTIAL wording when the scan ceiling is
# reached); the advisory-only -GitPrePush contract (exit 0, no block, no
# unreachable branch); config validation and same-threshold consistency; single
# valid JSON output; and PowerShell 5.1 parity.
#
# Fixtures are byte-isolated per test (own hook copy + fake LOCALAPPDATA), so
# cooldown state never collides and nothing touches real client state.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-LargeFileCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Large-File-Check\Large-File-Check.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$EnvExample = Join-Path $HooksRoot 'Large-File-Check\.env.example'
foreach ($required in @($Hook, $HookLib, $EnvExample)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-largefiletest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

# Nothing below may reach real ~\.claude / ~\.codex state: every child gets a
# FAKE LOCALAPPDATA, and CLAUDE_PROJECT_DIR is cleared so a merged child env
# cannot leak it.
$SavedClaudeProjectDir = $env:CLAUDE_PROJECT_DIR
$env:CLAUDE_PROJECT_DIR = ''

# Real HookMaker state dir - snapshot so we can prove the suite left no residue.
$RealStateDir = Join-Path $env:LOCALAPPDATA 'HookMaker\state'
$RealStateBefore = @(Get-ChildItem -LiteralPath $RealStateDir -Filter 'LargeFileCheck-*.txt' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}
# A source file with EXACTLY $LineCount lines (ReadLines yields $LineCount entries).
function New-SourceFile {
    param([string]$Path, [int]$LineCount, [int]$Width = 4)
    $line = 'x' * $Width
    Write-Utf8 $Path (@(1..$LineCount | ForEach-Object { $line }) -join "`n")
}

function New-IsolatedHookCopy {
    param([string]$EnvContent = $null)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Large-File-Check.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($null -ne $EnvContent) { Write-Utf8 (Join-Path $dir '.env') $EnvContent }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Large-File-Check.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param(
        [string]$HookPath, [string]$Cwd, [string]$EventName = 'Stop',
        [string]$LocalAppData, [switch]$StopHookActive, [switch]$GitPrePush,
        [string]$Exe = 'pwsh', [string]$ClaudeProjectDir = '', [int]$TripTimeAfterFiles = 0
    )
    $obj = @{ cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json -Depth 5
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    $switchArg = if ($GitPrePush) { ' -GitPrePush' } else { '' }
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"' + $switchArg }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"' + $switchArg }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        # Default: CLAUDE_PROJECT_DIR empty -> the hook takes the Codex route
        # (systemMessage). A caller passing -ClaudeProjectDir forces the Claude
        # route (hookSpecificOutput) to prove the client-aware advisory shape.
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData; CLAUDE_PROJECT_DIR = $ClaudeProjectDir }
        # TEST-ONLY seam: forces the hook's in-file-loop wall-time check to trip
        # after N source files, so a mid-directory time stop is deterministic.
        if ($TripTimeAfterFiles -gt 0) { $startArgs.Environment['LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES'] = [string]$TripTimeAfterFiles }
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# Returns the model/user-visible advisory text from either NON-BLOCKING shape:
# Claude's hookSpecificOutput.additionalContext or Codex's systemMessage. It
# deliberately does NOT read decision:block's `reason` - accepting that masked
# the fact that the offender path used to (wrongly) block instead of advise, so
# a block would be silently treated as "the message". Offender/partial tests now
# assert the advisory shape here AND separately assert no decision:block.
function Get-Advisory {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    try { $doc = $Text | ConvertFrom-Json } catch { return '' }
    if ($null -ne $doc.PSObject.Properties['hookSpecificOutput'] -and $null -ne $doc.hookSpecificOutput) {
        return [string]$doc.hookSpecificOutput.additionalContext
    }
    if ($null -ne $doc.PSObject.Properties['systemMessage']) { return [string]$doc.systemMessage }
    return ''
}

# Byte-level tree snapshot: proves the hook never wrote into the project.
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

try {
    # =====================================================================
    Write-Host '--- Pre-task (SessionStart): full preventive policy, one valid JSON document ---' -ForegroundColor Cyan
    $hc1 = New-IsolatedHookCopy
    $proj1 = New-Proj 'PreTask'
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'SessionStart' -LocalAppData $hc1.LocalAppData
    Check '1. SessionStart exits 0 with no stderr' ($r.Exit -eq 0 -and $r.Err -eq '') $r.Err
    $parsed1 = $null
    try { $parsed1 = $r.Out | ConvertFrom-Json } catch { $parsed1 = $null }
    Check '28a. pre-task output is a single valid JSON document' (
        $null -ne $parsed1 -and (@($r.Out -split "`n" | Where-Object { $_.Trim() -ne '' }).Count -eq 1)) $r.Out
    Check '28b. pre-task uses the Claude hookSpecificOutput shape with the event name' (
        $null -ne $parsed1 -and $null -ne $parsed1.PSObject.Properties['hookSpecificOutput'] -and
        [string]$parsed1.hookSpecificOutput.hookEventName -eq 'SessionStart') $r.Out
    $msg1 = Get-Advisory $r.Out
    Check '1. SessionStart carries "design correctly from the start" guidance' ($msg1 -match '(?i)design correctly from the start') $msg1
    Check '2. it says not to postpone decomposition until the file is large' ($msg1 -match '(?i)postpone decomposition') $msg1
    Check '4. default threshold 800 appears in the guidance' ($msg1 -match '\b800\b') $msg1
    Check '6a. cohesion-first guidance remains' ($msg1 -match '(?i)cohesion') $msg1
    Check '6b. anti-wrapper guidance remains' ($msg1 -match '(?i)wrappers') $msg1
    Check '7. it states architectural judgment is the AI agent''s, not the hook''s' (
        $msg1 -match '(?i)architectural' -and $msg1 -match '(?i)AI agent') $msg1

    # =====================================================================
    Write-Host '--- Pre-task uses the CONFIGURED threshold; invalid falls back to 800 ---' -ForegroundColor Cyan
    $hc2 = New-IsolatedHookCopy -EnvContent "LINE_THRESHOLD=1200`n"
    $proj2 = New-Proj 'ConfiguredThreshold'
    $r = Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'SessionStart' -LocalAppData $hc2.LocalAppData
    $msg2 = Get-Advisory $r.Out
    Check '3. a configured threshold (1200) is used in the pre-task guidance' ($msg2 -match '\b1200\b') $msg2
    Check '3b. the default 800 is NOT shown when 1200 is configured' ($msg2 -notmatch '\b800\b') $msg2

    $hc3 = New-IsolatedHookCopy -EnvContent "LINE_THRESHOLD=not-a-number`n"
    $proj3 = New-Proj 'InvalidThreshold'
    $r = Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'SessionStart' -LocalAppData $hc3.LocalAppData
    $msg3 = Get-Advisory $r.Out
    Check '5a. an invalid threshold falls back to 800 in the guidance' ($msg3 -match '\b800\b') $msg3
    Check '5b. the raw invalid value is never surfaced' ($msg3 -notmatch 'not-a-number') $msg3

    # =====================================================================
    Write-Host '--- UserPromptSubmit emits the shorter reminder (still uses the threshold) ---' -ForegroundColor Cyan
    $hc4 = New-IsolatedHookCopy
    $proj4 = New-Proj 'PromptReminder'
    $r = Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'UserPromptSubmit' -LocalAppData $hc4.LocalAppData
    $parsed4 = $null
    try { $parsed4 = $r.Out | ConvertFrom-Json } catch { $parsed4 = $null }
    $msg4 = Get-Advisory $r.Out
    Check 'G1. UserPromptSubmit produces guidance with the right event name' (
        $null -ne $parsed4 -and [string]$parsed4.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit') $r.Out
    Check 'G2. the prompt reminder is SHORTER than the full SessionStart policy' ($msg4.Length -lt $msg1.Length) ("prompt=$($msg4.Length) session=$($msg1.Length)")
    Check 'G3. the prompt reminder still quotes the effective threshold (800)' ($msg4 -match '\b800\b') $msg4

    # =====================================================================
    Write-Host '--- Stop scan: strict greater-than (800 silent, 801 reported, never mandated) ---' -ForegroundColor Cyan
    $hc5 = New-IsolatedHookCopy
    $proj5 = New-Proj 'Exactly800'
    New-SourceFile (Join-Path $proj5 'src\a.py') 800
    $r = Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'Stop' -LocalAppData $hc5.LocalAppData
    Check '8. exactly 800 lines is silent (strict greater-than)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $hc6 = New-IsolatedHookCopy
    $proj6 = New-Proj 'Lines801'
    New-SourceFile (Join-Path $proj6 'src\a.py') 801
    $r = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'Stop' -LocalAppData $hc6.LocalAppData
    $msg6 = Get-Advisory $r.Out
    Check '9. 801 lines is reported' ($msg6 -match 'a\.py \(801 lines\)') $msg6
    Check '10. 801 does not mandate a split' ($msg6 -match '(?i)No split is mandatory' -and $msg6 -match '(?i)REVIEW SIGNAL') $msg6
    Check '10b. the report defers the decision to the AI (cohesion outranks line count)' ($msg6 -match '(?i)Cohesion outranks raw line count') $msg6

    $hc7 = New-IsolatedHookCopy
    $proj7 = New-Proj 'ClearlyLarger'
    New-SourceFile (Join-Path $proj7 'src\big.js') 1500
    $r = Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'Stop' -LocalAppData $hc7.LocalAppData
    Check '11. a clearly larger file (1500) is reported' ((Get-Advisory $r.Out) -match 'big\.js \(1500 lines\)') $r.Out

    # =====================================================================
    Write-Host '--- Stop scan: pre-existing and newly-created oversized files both reported ---' -ForegroundColor Cyan
    $hc8 = New-IsolatedHookCopy
    $proj8 = New-Proj 'PreExisting'
    # The scan is filesystem-based, so it reports any oversized file regardless of
    # when it appeared - a file present before the task is treated the same.
    New-SourceFile (Join-Path $proj8 'legacy\old.cs') 1200
    $r = Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'Stop' -LocalAppData $hc8.LocalAppData
    Check '12. an oversized file existing before the task is still reported' ((Get-Advisory $r.Out) -match 'old\.cs \(1200 lines\)') $r.Out

    $hc9 = New-IsolatedHookCopy
    $proj9 = New-Proj 'NewlyCreated'
    New-SourceFile (Join-Path $proj9 'feature\new.ts') 950
    $r = Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'Stop' -LocalAppData $hc9.LocalAppData
    Check '13. a newly created oversized file is reported' ((Get-Advisory $r.Out) -match 'new\.ts \(950 lines\)') $r.Out

    # =====================================================================
    Write-Host '--- Stop scan: many offenders sorted largest-first with a correct remaining count ---' -ForegroundColor Cyan
    $hc10 = New-IsolatedHookCopy
    $proj10 = New-Proj 'ManyOffenders'
    $sizes = @{ 'f1' = 900; 'f2' = 1600; 'f3' = 1100; 'f4' = 2000; 'f5' = 810; 'f6' = 1300; 'f7' = 1000 }
    foreach ($k in $sizes.Keys) { New-SourceFile (Join-Path $proj10 ('src\' + $k + '.py')) $sizes[$k] }
    $r = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    $msg10 = Get-Advisory $r.Out
    Check '14a. all 7 offenders are counted' ($msg10 -match '7 source file\(s\) exceed 800 lines') $msg10
    Check '14b. the largest (f4, 2000) is listed first' ($msg10 -match ':\s*src[\\/]f4\.py \(2000 lines\)') $msg10
    # Top 5 shown largest-first: 2000,1600,1300,1100,1000 then "and 2 more".
    $order = ([regex]::Matches($msg10, '\((\d+) lines\)') | ForEach-Object { [int]$_.Groups[1].Value })
    $topFive = @($order | Select-Object -First 5)
    $sortedDesc = @($topFive | Sort-Object -Descending)
    Check '14c. the top five are in descending order' ("$topFive" -eq "$sortedDesc" -and $topFive[0] -eq 2000 -and $topFive[4] -eq 1000) "$topFive"
    Check '14d. the remaining count is exactly "and 2 more"' ($msg10 -match 'and 2 more') $msg10

    # =====================================================================
    Write-Host '--- Stop scan: cooldown suppresses an unchanged repeat ---' -ForegroundColor Cyan
    $hc11 = New-IsolatedHookCopy
    $proj11 = New-Proj 'Cooldown'
    New-SourceFile (Join-Path $proj11 'src\a.py') 900
    $rFirst = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'Stop' -LocalAppData $hc11.LocalAppData
    Check '15a. the first Stop reports' ((Get-Advisory $rFirst.Out) -ne '') $rFirst.Out
    $rRepeat = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'Stop' -LocalAppData $hc11.LocalAppData
    Check '15b. an unchanged repeat inside the cooldown is silent' ($rRepeat.Exit -eq 0 -and $rRepeat.Out -eq '') $rRepeat.Out

    # =====================================================================
    Write-Host '--- Stop scan: stop_hook_active recursion guard, and total silence with no offender ---' -ForegroundColor Cyan
    $hc12 = New-IsolatedHookCopy
    $proj12 = New-Proj 'Recursion'
    New-SourceFile (Join-Path $proj12 'src\a.py') 1500
    $r = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData -StopHookActive
    Check '16. stop_hook_active prevents the scan (recursion guard)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $hc13 = New-IsolatedHookCopy
    $proj13 = New-Proj 'NoOffender'
    New-SourceFile (Join-Path $proj13 'src\a.py') 200
    New-SourceFile (Join-Path $proj13 'src\b.py') 799
    $r = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'Stop' -LocalAppData $hc13.LocalAppData
    Check '17. no offender means total silence' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ($r.Out + $r.Err)

    # =====================================================================
    Write-Host '--- Stop scan: excluded trees pruned, >3 MB files skipped ---' -ForegroundColor Cyan
    $hc14 = New-IsolatedHookCopy
    $proj14 = New-Proj 'Excluded'
    New-SourceFile (Join-Path $proj14 'node_modules\pkg\huge.js') 5000
    New-SourceFile (Join-Path $proj14 '.git\hooks\big.py') 5000
    New-SourceFile (Join-Path $proj14 'src\app.py') 900
    $r = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'Stop' -LocalAppData $hc14.LocalAppData
    $msg14 = Get-Advisory $r.Out
    Check '18a. the real top-level file IS reported' ($msg14 -match 'app\.py \(900 lines\)') $msg14
    Check '18b. an excluded node_modules file is NOT reported' ($msg14 -notmatch 'huge\.js') $msg14
    Check '18c. an excluded .git file is NOT reported' ($msg14 -notmatch 'big\.py') $msg14

    $hc15 = New-IsolatedHookCopy
    $proj15 = New-Proj 'BigBinary'
    # >3 MB with >800 lines: skipped as binary/generated even though line count qualifies.
    New-SourceFile (Join-Path $proj15 'src\generated.js') 900 4000
    New-SourceFile (Join-Path $proj15 'src\ok.py') 850
    $bigLen = (Get-Item -LiteralPath (Join-Path $proj15 'src\generated.js')).Length
    $r = Fire -HookPath $hc15.Script -Cwd $proj15 -EventName 'Stop' -LocalAppData $hc15.LocalAppData
    $msg15 = Get-Advisory $r.Out
    Check '20a. the >3 MB fixture really is over 3 MB' ($bigLen -gt 3MB) "$bigLen"
    Check '20b. the >3 MB file is skipped' ($msg15 -notmatch 'generated\.js') $msg15
    Check '20c. a normal offender alongside it is still reported' ($msg15 -match 'ok\.py \(850 lines\)') $msg15

    # =====================================================================
    Write-Host '--- Stop scan: a reparse point (junction) is never followed ---' -ForegroundColor Cyan
    $hc16 = New-IsolatedHookCopy
    $proj16 = New-Proj 'Reparse'
    $rpTarget = Join-Path $Work ('rp-target-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-SourceFile (Join-Path $rpTarget 'src\linked.py') 1400
    New-SourceFile (Join-Path $proj16 'src\local.py') 1300
    $rpLink = Join-Path $proj16 'linked'
    $madeJunction = $false
    try { New-Item -ItemType Junction -Path $rpLink -Target $rpTarget -ErrorAction Stop | Out-Null; $madeJunction = $true } catch { }
    if (-not $madeJunction) {
        try { & cmd /c mklink /J "$rpLink" "$rpTarget" 2>$null | Out-Null } catch { }
        $madeJunction = (Test-Path -LiteralPath $rpLink) -and
            ((((Get-Item -LiteralPath $rpLink -Force).Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    if ($madeJunction) {
        $r = Fire -HookPath $hc16.Script -Cwd $proj16 -EventName 'Stop' -LocalAppData $hc16.LocalAppData
        $msg16 = Get-Advisory $r.Out
        Check '19a. the in-repo file IS reported (scan otherwise works)' ($msg16 -match 'local\.py \(1300 lines\)') $msg16
        Check '19b. content behind the junction is NOT reported (reparse point not followed)' ($msg16 -notmatch 'linked\.py') $msg16
    }
    else {
        Write-Host '[SKIP] junction could not be created in this harness - reparse-skip assertion skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- Stop scan: a scan ceiling is reported as PARTIAL, not full coverage ---' -ForegroundColor Cyan
    $hc17 = New-IsolatedHookCopy -EnvContent "MAX_FILES=1`n"
    $proj17 = New-Proj 'PartialCeiling'
    New-SourceFile (Join-Path $proj17 'top.py') 900
    New-SourceFile (Join-Path $proj17 'sub\deep.py') 1000
    $r = Fire -HookPath $hc17.Script -Cwd $proj17 -EventName 'Stop' -LocalAppData $hc17.LocalAppData
    $msg17 = Get-Advisory $r.Out
    Check '21a. reaching the scan ceiling reports PARTIAL coverage' ($msg17 -match '(?i)PARTIAL scan') $msg17
    Check '21b. a normal small scan is NOT marked partial (case 9 report was clean)' ($msg6 -notmatch '(?i)PARTIAL') $msg6
    # R1: a ceiling-only partial must name the FILE ceiling in the OFFENDER report -
    # not a read failure, and not the directory/time limit that were not hit.
    Check '21c. the ceiling-only offender report names the FILE ceiling, not a read failure or a dir/time limit' (
        $msg17 -match '(?i)scan ceiling of 1 files was reached' -and
        $msg17 -notmatch '(?i)could not be read' -and $msg17 -notmatch '(?i)directory ceiling' -and $msg17 -notmatch '(?i)time limit') $msg17

    # =====================================================================
    Write-Host '--- Stop scan: MAX_FILES is a real per-file ceiling (one flat dir over the limit) ---' -ForegroundColor Cyan
    # D1/D3: a single directory holding MORE source files than MAX_FILES. The scan
    # must stop AT the ceiling (not walk the whole directory), and coverage must
    # read PARTIAL even though the stack ends empty (flag-driven, not stack-driven).
    $hcD1 = New-IsolatedHookCopy -EnvContent "MAX_FILES=3`n"
    $projD1 = New-Proj 'FlatCeiling'
    1..10 | ForEach-Object { New-SourceFile (Join-Path $projD1 ('src\f{0:00}.py' -f $_)) 900 }
    $rD1 = Fire -HookPath $hcD1.Script -Cwd $projD1 -EventName 'Stop' -LocalAppData $hcD1.LocalAppData
    $msgD1 = Get-Advisory $rD1.Out
    Check 'D1. MAX_FILES is a real per-file ceiling: 3 offenders reported, not all 10 scanned' (
        $msgD1 -match '\b3 source file\(s\) exceed 800 lines' -and $msgD1 -notmatch '\b10 source file') $msgD1
    Check 'D3. partial coverage is flag-driven: PARTIAL wording appears though the stack ended empty' ($msgD1 -match '(?i)PARTIAL scan') $msgD1

    # =====================================================================
    Write-Host '--- Stop scan: a PARTIAL scan with NO offender is not a false silence ---' -ForegroundColor Cyan
    # D2: the ceiling fills on a non-offending root file, so the oversized file
    # behind it is never seen. The hook must advise incomplete coverage - not a
    # decision:block, and not silence.
    $hcD2 = New-IsolatedHookCopy -EnvContent "MAX_FILES=1`n"
    $projD2 = New-Proj 'PartialNoOffender'
    New-SourceFile (Join-Path $projD2 'top.py') 200
    New-SourceFile (Join-Path $projD2 'sub\deep.py') 1500
    $rD2 = Fire -HookPath $hcD2.Script -Cwd $projD2 -EventName 'Stop' -LocalAppData $hcD2.LocalAppData
    $msgD2 = Get-Advisory $rD2.Out
    Check 'D2a. a partial no-offender scan is NOT silent (advisory emitted, exit 0)' (
        $rD2.Exit -eq 0 -and $rD2.Out -ne '' -and $rD2.Err -eq '') ("exit=$($rD2.Exit) out=[$($rD2.Out)] err=[$($rD2.Err)]")
    Check 'D2b. the advisory states coverage was INCOMPLETE and is NOT a decision:block' (
        $msgD2 -match '(?i)coverage was INCOMPLETE' -and $rD2.Out -notmatch '"decision"') $rD2.Out
    Check 'D2c. the unscanned oversized file is NOT falsely claimed as seen' ($msgD2 -notmatch 'deep\.py') $msgD2

    # =====================================================================
    Write-Host '--- Stop scan: a reparse-point ROOT is refused, never walked ---' -ForegroundColor Cyan
    # D4: cwd itself is a junction. The per-child reparse guard does not cover the
    # root, so the root must be refused before any descent.
    $hcD4 = New-IsolatedHookCopy
    $rpRootTarget = Join-Path $Work ('rp-root-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-SourceFile (Join-Path $rpRootTarget 'src\linked.py') 1400
    $rpRootLink = Join-Path $Work ('rootlink-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $madeRootJunction = $false
    try { New-Item -ItemType Junction -Path $rpRootLink -Target $rpRootTarget -ErrorAction Stop | Out-Null; $madeRootJunction = $true } catch { }
    if (-not $madeRootJunction) {
        try { & cmd /c mklink /J "$rpRootLink" "$rpRootTarget" 2>$null | Out-Null } catch { }
        $madeRootJunction = (Test-Path -LiteralPath $rpRootLink) -and
            ((((Get-Item -LiteralPath $rpRootLink -Force).Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    if ($madeRootJunction) {
        $rD4 = Fire -HookPath $hcD4.Script -Cwd $rpRootLink -EventName 'Stop' -LocalAppData $hcD4.LocalAppData
        Check 'D4. a reparse-point root is refused (silent exit 0, target not walked)' (
            $rD4.Exit -eq 0 -and $rD4.Out -eq '' -and $rD4.Err -eq '') ("exit=$($rD4.Exit) out=[$($rD4.Out)] err=[$($rD4.Err)]")
    }
    else {
        Write-Host '[SKIP] root junction could not be created in this harness - reparse-root assertion skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- Stop offender report is a CLIENT-AWARE, NON-BLOCKING advisory (never decision:block) ---' -ForegroundColor Cyan
    # The hook is advisory by contract - the AI owns the split. On Codex a Stop
    # decision:block coerces a new prompt (an infinite loop), so the offender
    # report must be a client-aware advisory, never a block.
    $hcCodex = New-IsolatedHookCopy
    $projCodex = New-Proj 'OffenderCodexShape'
    New-SourceFile (Join-Path $projCodex 'src\a.py') 900
    $rCodex = Fire -HookPath $hcCodex.Script -Cwd $projCodex -EventName 'Stop' -LocalAppData $hcCodex.LocalAppData
    $parsedCodex = $null
    try { $parsedCodex = $rCodex.Out | ConvertFrom-Json } catch { $parsedCodex = $null }
    Check 'S1a. offender report on CODEX (no CLAUDE_PROJECT_DIR) uses systemMessage, not hookSpecificOutput' (
        $null -ne $parsedCodex -and $null -ne $parsedCodex.PSObject.Properties['systemMessage'] -and
        $null -eq $parsedCodex.PSObject.Properties['hookSpecificOutput'] -and
        ([string]$parsedCodex.systemMessage) -match 'a\.py \(900 lines\)') $rCodex.Out
    Check 'S1b. the CODEX offender report is NOT a decision:block' ($rCodex.Out -notmatch '"decision"') $rCodex.Out

    $hcClaude = New-IsolatedHookCopy
    $projClaude = New-Proj 'OffenderClaudeShape'
    New-SourceFile (Join-Path $projClaude 'src\a.py') 900
    $rClaude = Fire -HookPath $hcClaude.Script -Cwd $projClaude -EventName 'Stop' -LocalAppData $hcClaude.LocalAppData -ClaudeProjectDir $projClaude
    $parsedClaude = $null
    try { $parsedClaude = $rClaude.Out | ConvertFrom-Json } catch { $parsedClaude = $null }
    Check 'S2a. offender report on CLAUDE uses hookSpecificOutput.additionalContext with the event name' (
        $null -ne $parsedClaude -and $null -ne $parsedClaude.PSObject.Properties['hookSpecificOutput'] -and
        [string]$parsedClaude.hookSpecificOutput.hookEventName -eq 'Stop' -and
        ([string]$parsedClaude.hookSpecificOutput.additionalContext) -match 'a\.py \(900 lines\)') $rClaude.Out
    Check 'S2b. the CLAUDE offender report is NOT a decision:block' ($rClaude.Out -notmatch '"decision"') $rClaude.Out

    # =====================================================================
    Write-Host '--- Partial no-offender advisory is client-aware in BOTH shapes (never a block) ---' -ForegroundColor Cyan
    $hcPartX = New-IsolatedHookCopy -EnvContent "MAX_FILES=1`n"
    $projPartX = New-Proj 'PartialAdvisoryCodex'
    New-SourceFile (Join-Path $projPartX 'top.py') 200
    New-SourceFile (Join-Path $projPartX 'sub\deep.py') 1500
    $rPartX = Fire -HookPath $hcPartX.Script -Cwd $projPartX -EventName 'Stop' -LocalAppData $hcPartX.LocalAppData
    $parsedPartX = $null
    try { $parsedPartX = $rPartX.Out | ConvertFrom-Json } catch { $parsedPartX = $null }
    Check 'S3. partial no-offender advisory on CODEX uses systemMessage and is not a block' (
        $null -ne $parsedPartX -and $null -ne $parsedPartX.PSObject.Properties['systemMessage'] -and
        ([string]$parsedPartX.systemMessage) -match '(?i)coverage was INCOMPLETE' -and
        $rPartX.Out -notmatch '"decision"') $rPartX.Out

    $hcPartC = New-IsolatedHookCopy -EnvContent "MAX_FILES=1`n"
    $projPartC = New-Proj 'PartialAdvisoryClaude'
    New-SourceFile (Join-Path $projPartC 'top.py') 200
    New-SourceFile (Join-Path $projPartC 'sub\deep.py') 1500
    $rPartC = Fire -HookPath $hcPartC.Script -Cwd $projPartC -EventName 'Stop' -LocalAppData $hcPartC.LocalAppData -ClaudeProjectDir $projPartC
    $parsedPartC = $null
    try { $parsedPartC = $rPartC.Out | ConvertFrom-Json } catch { $parsedPartC = $null }
    Check 'S4. partial no-offender advisory on CLAUDE uses hookSpecificOutput and is not a block' (
        $null -ne $parsedPartC -and $null -ne $parsedPartC.PSObject.Properties['hookSpecificOutput'] -and
        ([string]$parsedPartC.hookSpecificOutput.additionalContext) -match '(?i)coverage was INCOMPLETE' -and
        $rPartC.Out -notmatch '"decision"') $rPartC.Out

    # =====================================================================
    Write-Host '--- Stop scan: an UNREADABLE file makes a no-offender scan INCOMPLETE, not a silent all-clear ---' -ForegroundColor Cyan
    # A per-file read failure must not abort the directory and produce a false
    # all-clear. The parent holds an exclusive (FileShare.None) lock so the child
    # hook cannot read the file; ReadLines throws, $scanIncomplete is set, and the
    # no-offender path emits the client-aware INCOMPLETE advisory (not a block).
    $hcRead = New-IsolatedHookCopy
    $projRead = New-Proj 'UnreadableFile'
    $lockedPath = Join-Path $projRead 'src\locked.py'
    New-SourceFile $lockedPath 200
    $lockStream = $null
    $locked = $false
    try {
        $lockStream = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $locked = $true
    }
    catch { $locked = $false }
    if ($locked) {
        try {
            $rRead = Fire -HookPath $hcRead.Script -Cwd $projRead -EventName 'Stop' -LocalAppData $hcRead.LocalAppData
        }
        finally { $lockStream.Dispose() }
        $msgRead = Get-Advisory $rRead.Out
        Check 'R1. an unreadable file yields an advisory (exit 0, non-empty, no stderr) - not a silent all-clear' (
            $rRead.Exit -eq 0 -and $rRead.Out -ne '' -and $rRead.Err -eq '') ("exit=$($rRead.Exit) out=[$($rRead.Out)] err=[$($rRead.Err)]")
        Check 'R2. the advisory states coverage was INCOMPLETE and names a read failure (not only a ceiling)' (
            $msgRead -match '(?i)coverage was INCOMPLETE' -and $msgRead -match '(?i)could not be read') $msgRead
        Check 'R3. the incomplete-coverage advisory is NOT a decision:block' ($rRead.Out -notmatch '"decision"') $rRead.Out
    }
    else {
        Write-Host '[SKIP] could not lock a file exclusively in this harness - read-failure assertion skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- R1: a read-failure-only partial WITH an offender names the read failure, not a ceiling ---' -ForegroundColor Cyan
    # An offender is readable and reported; a sibling file is exclusively locked so
    # its ReadLines throws -> $scanIncomplete with NO ceiling hit. The OFFENDER
    # report's partial-cause must name the read failure, never assume a scan ceiling.
    $hcR1 = New-IsolatedHookCopy
    $projR1 = New-Proj 'ReadFailWithOffender'
    New-SourceFile (Join-Path $projR1 'src\big.py') 900
    $lockedR1 = Join-Path $projR1 'src\locked.py'
    New-SourceFile $lockedR1 200
    $lockStreamR1 = $null
    $lockedOk = $false
    try {
        $lockStreamR1 = [System.IO.File]::Open($lockedR1, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $lockedOk = $true
    }
    catch { $lockedOk = $false }
    if ($lockedOk) {
        try {
            $rR1 = Fire -HookPath $hcR1.Script -Cwd $projR1 -EventName 'Stop' -LocalAppData $hcR1.LocalAppData
        }
        finally { $lockStreamR1.Dispose() }
        $msgR1 = Get-Advisory $rR1.Out
        Check 'R1a. the readable offender is still reported' ($msgR1 -match 'big\.py \(900 lines\)') $msgR1
        Check 'R1b. the offender report marks PARTIAL and names the READ FAILURE cause' (
            $msgR1 -match '(?i)PARTIAL scan' -and $msgR1 -match '(?i)could not be read') $msgR1
        Check 'R1c. it does NOT falsely claim a scan ceiling / directory / time limit was hit' (
            $msgR1 -notmatch '(?i)scan ceiling' -and $msgR1 -notmatch '(?i)directory ceiling' -and $msgR1 -notmatch '(?i)time limit') $msgR1
    }
    else {
        Write-Host '[SKIP] could not lock a file exclusively in this harness - R1 read-failure-with-offender assertions skipped' -ForegroundColor Yellow
    }

    # =====================================================================
    Write-Host '--- R2: MAX_DIRECTORIES is a real traversal ceiling; the report names "directories" ---' -ForegroundColor Cyan
    # With MAX_DIRECTORIES=1 only the root directory is traversed: its offender is
    # found, but a subdirectory (and the oversized file inside it) is never entered.
    # Coverage is PARTIAL and the offender report must name the DIRECTORY ceiling.
    $hcR2 = New-IsolatedHookCopy -EnvContent "MAX_DIRECTORIES=1`n"
    $projR2 = New-Proj 'DirCeiling'
    New-SourceFile (Join-Path $projR2 'big.py') 900
    New-SourceFile (Join-Path $projR2 'sub\deep.py') 1500
    $rR2 = Fire -HookPath $hcR2.Script -Cwd $projR2 -EventName 'Stop' -LocalAppData $hcR2.LocalAppData
    $msgR2 = Get-Advisory $rR2.Out
    Check 'R2a. the root offender IS reported (root directory was traversed)' ($msgR2 -match 'big\.py \(900 lines\)') $msgR2
    Check 'R2b. the file behind the directory ceiling is NOT reached' ($msgR2 -notmatch 'deep\.py') $msgR2
    Check 'R2c. coverage is PARTIAL and the cause names the DIRECTORY ceiling (not files/time/read failure)' (
        $msgR2 -match '(?i)PARTIAL scan' -and $msgR2 -match '(?i)directory ceiling of 1 directories was reached' -and
        $msgR2 -notmatch '(?i)source-file scan ceiling' -and $msgR2 -notmatch '(?i)time limit' -and $msgR2 -notmatch '(?i)could not be read') $msgR2

    # =====================================================================
    Write-Host '--- R2: MAX_DIRECTORIES / MAX_SCAN_SECONDS validate and fall back safely ---' -ForegroundColor Cyan
    # A time trigger is not deterministically forceable in a fast fixture, so assert
    # the config is HONOURED/VALIDATED: invalid or out-of-range values fall back to
    # the defaults (4000 dirs, 5 s), so a tiny project still scans fully - no crash,
    # no false PARTIAL - and the offender is reported normally.
    $hcR2v = New-IsolatedHookCopy -EnvContent "MAX_DIRECTORIES=not-a-number`nMAX_SCAN_SECONDS=99999`n"
    $projR2v = New-Proj 'CeilingFallback'
    New-SourceFile (Join-Path $projR2v 'src\a.py') 801
    New-SourceFile (Join-Path $projR2v 'sub\deep.py') 1500
    $rR2v = Fire -HookPath $hcR2v.Script -Cwd $projR2v -EventName 'Stop' -LocalAppData $hcR2v.LocalAppData
    $msgR2v = Get-Advisory $rR2v.Out
    Check 'R2d. invalid MAX_DIRECTORIES / out-of-range MAX_SCAN_SECONDS do not crash the hook' ($rR2v.Exit -eq 0 -and $rR2v.Err -eq '') $rR2v.Err
    Check 'R2e. they fall back to defaults: a tiny project scans fully, offenders reported, NOT partial' (
        $msgR2v -match 'a\.py \(801 lines\)' -and $msgR2v -match 'deep\.py \(1500 lines\)' -and $msgR2v -notmatch '(?i)PARTIAL') $msgR2v

    # A valid MAX_SCAN_SECONDS is honoured (large enough not to trip on a tiny scan).
    $hcR2s = New-IsolatedHookCopy -EnvContent "MAX_SCAN_SECONDS=60`n"
    $projR2s = New-Proj 'ScanSecondsHonoured'
    New-SourceFile (Join-Path $projR2s 'src\a.py') 900
    $rR2s = Fire -HookPath $hcR2s.Script -Cwd $projR2s -EventName 'Stop' -LocalAppData $hcR2s.LocalAppData
    $msgR2s = Get-Advisory $rR2s.Out
    Check 'R2f. a valid MAX_SCAN_SECONDS is honoured: normal scan completes, offender reported, NOT partial' (
        $msgR2s -match 'a\.py \(900 lines\)' -and $msgR2s -notmatch '(?i)PARTIAL') $msgR2s

    # =====================================================================
    Write-Host '--- Stop scan: MAX_SCAN_SECONDS is a real MID-DIRECTORY time ceiling (deterministic seam) ---' -ForegroundColor Cyan
    # T1: ONE directory holding 10 oversized source files. The between-directories
    # time check cannot catch an overrun inside a single big directory; the in-file-
    # loop check can. A TEST-ONLY seam (LARGEFILECHECK_TEST_TRIP_TIME_AFTER_FILES=2)
    # forces that in-file-loop check to trip after 2 source files WITHOUT depending
    # on real wall-clock timing, proving the scan halts IN THE MIDDLE of the
    # directory (2 of 10 scanned) and names the TIME limit as the partial cause -
    # not files/dirs/read-failure. The seam is inert unless the env var is set.
    $hcT1 = New-IsolatedHookCopy
    $projT1 = New-Proj 'TimeCeilingMidDir'
    1..10 | ForEach-Object { New-SourceFile (Join-Path $projT1 ('src\t{0:00}.py' -f $_)) 900 }
    $rT1 = Fire -HookPath $hcT1.Script -Cwd $projT1 -EventName 'Stop' -LocalAppData $hcT1.LocalAppData -TripTimeAfterFiles 2
    $msgT1 = Get-Advisory $rT1.Out
    Check 'T1a. the scan stops MID-directory: only 2 of the 10 source files are scanned before the time trip' (
        $msgT1 -match '\b2 source file\(s\) exceed 800 lines' -and $msgT1 -notmatch '\b10 source file') $msgT1
    Check 'T1b. coverage is PARTIAL and the cause names the TIME limit (not files/dirs/read failure)' (
        $msgT1 -match '(?i)PARTIAL scan' -and $msgT1 -match '(?i)scan time limit of 5 seconds was reached' -and
        $msgT1 -notmatch '(?i)source-file scan ceiling' -and $msgT1 -notmatch '(?i)directory ceiling' -and
        $msgT1 -notmatch '(?i)could not be read') $msgT1
    Check 'T1c. the mid-directory time report is a client-aware advisory, never a decision:block' (
        $rT1.Out -notmatch '"decision"' -and $rT1.Exit -eq 0 -and $rT1.Err -eq '') ("exit=$($rT1.Exit) out=[$($rT1.Out)] err=[$($rT1.Err)]")

    # =====================================================================
    Write-Host '--- Stop scan: the MAX_FILES ceiling counts SOURCE files - a trailing non-source file is not PARTIAL ---' -ForegroundColor Cyan
    # Extension is checked before the ceiling: with MAX_FILES=2 and exactly two
    # source files plus a trailing non-source file, both source files are scanned
    # and NO false PARTIAL is declared for the skipped non-source file.
    $hcExt = New-IsolatedHookCopy -EnvContent "MAX_FILES=2`n"
    $projExt = New-Proj 'CeilingCountsSource'
    New-SourceFile (Join-Path $projExt 'a.py') 801
    New-SourceFile (Join-Path $projExt 'b.py') 801
    New-SourceFile (Join-Path $projExt 'zzz.md') 900
    $rExt = Fire -HookPath $hcExt.Script -Cwd $projExt -EventName 'Stop' -LocalAppData $hcExt.LocalAppData
    $msgExt = Get-Advisory $rExt.Out
    Check 'X1a. both source files are reported (ceiling counts only in-scope source files)' (
        $msgExt -match '2 source file\(s\) exceed 800 lines' -and $msgExt -match 'a\.py \(801 lines\)' -and $msgExt -match 'b\.py \(801 lines\)') $msgExt
    Check 'X1b. a remaining non-source file does NOT trigger a false PARTIAL warning' ($msgExt -notmatch '(?i)PARTIAL') $msgExt

    # =====================================================================
    Write-Host '--- GitPrePush is advisory-only: exit 0, no block, no unreachable branch ---' -ForegroundColor Cyan
    $hc18 = New-IsolatedHookCopy
    $proj18 = New-Proj 'GitPrePush'
    New-SourceFile (Join-Path $proj18 'src\a.py') 5000
    $r = Fire -HookPath $hc18.Script -Cwd $proj18 -GitPrePush -LocalAppData $hc18.LocalAppData
    Check '22/23. -GitPrePush exits 0 with no output and no stderr (never blocks push)' (
        $r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') ("exit=$($r.Exit) out=[$($r.Out)] err=[$($r.Err)]")
    $hookSource = [System.IO.File]::ReadAllText($Hook)
    Check '24a. the hook never exits non-zero (no blocking branch remains)' ($hookSource -notmatch '(?m)exit\s+1\b') $hookSource
    Check '24b. no unreachable GitPrePush stderr-block branch remains' ($hookSource -notmatch 'Error\]::WriteLine') $hookSource
    Check '24c. exactly one GitPrePush contract line (advisory exit 0)' ($hookSource -match 'if \(\$GitPrePush\) \{ exit 0 \}') $hookSource

    # =====================================================================
    Write-Host '--- Config validation: EXTENSIONS/COOLDOWN honoured; same threshold pre-task and Stop ---' -ForegroundColor Cyan
    $hc19 = New-IsolatedHookCopy -EnvContent "EXTENSIONS=.py`n"
    $proj19 = New-Proj 'Extensions'
    New-SourceFile (Join-Path $proj19 'src\keep.py') 900
    New-SourceFile (Join-Path $proj19 'src\skip.ps1') 900
    $r = Fire -HookPath $hc19.Script -Cwd $proj19 -EventName 'Stop' -LocalAppData $hc19.LocalAppData
    $msg19 = Get-Advisory $r.Out
    Check '25a. a configured EXTENSIONS list scans only those extensions (.py)' ($msg19 -match 'keep\.py \(900 lines\)') $msg19
    Check '25b. a non-listed extension (.ps1) is not scanned' ($msg19 -notmatch 'skip\.ps1') $msg19

    $hc20 = New-IsolatedHookCopy -EnvContent "LINE_THRESHOLD=1000`n"
    $proj20 = New-Proj 'SameThreshold'
    New-SourceFile (Join-Path $proj20 'src\just_over.py') 1001
    New-SourceFile (Join-Path $proj20 'src\at_limit.py') 1000
    $rPre = Fire -HookPath $hc20.Script -Cwd $proj20 -EventName 'SessionStart' -LocalAppData $hc20.LocalAppData
    $rStop = Fire -HookPath $hc20.Script -Cwd $proj20 -EventName 'Stop' -LocalAppData $hc20.LocalAppData
    $msgPre = Get-Advisory $rPre.Out
    $msgStop = Get-Advisory $rStop.Out
    Check '27a. pre-task guidance uses the configured 1000 threshold' ($msgPre -match '\b1000\b') $msgPre
    Check '27b. Stop uses the same 1000 threshold (1001 reported, 1000 not)' (
        $msgStop -match 'exceed 1000 lines' -and $msgStop -match 'just_over\.py \(1001 lines\)' -and $msgStop -notmatch 'at_limit\.py') $msgStop

    $hc21 = New-IsolatedHookCopy -EnvContent "LINE_THRESHOLD=abc`nCOOLDOWN_MINUTES=xyz`nMAX_FILES=nan`nEXTENSIONS=`n"
    $proj21 = New-Proj 'MalformedConfig'
    New-SourceFile (Join-Path $proj21 'src\a.py') 801
    $r = Fire -HookPath $hc21.Script -Cwd $proj21 -EventName 'Stop' -LocalAppData $hc21.LocalAppData
    $msg21 = Get-Advisory $r.Out
    Check '26a. malformed config does not crash the hook' ($r.Exit -eq 0 -and $r.Err -eq '') $r.Err
    Check '26b. malformed config falls back to the 800 default (801 still reported)' (
        $msg21 -match 'exceed 800 lines' -and $msg21 -match 'a\.py \(801 lines\)') $msg21

    # =====================================================================
    Write-Host '--- The hook never writes into the project; state stays isolated ---' -ForegroundColor Cyan
    $hc22 = New-IsolatedHookCopy
    $proj22 = New-Proj 'NeverTouches'
    New-SourceFile (Join-Path $proj22 'src\a.py') 1200
    $before = Get-TreeSignature $proj22
    $r = Fire -HookPath $hc22.Script -Cwd $proj22 -EventName 'Stop' -LocalAppData $hc22.LocalAppData
    $after = Get-TreeSignature $proj22
    Check '32a. the project tree is byte-for-byte identical after the hook ran' ($before -eq $after)
    Check '32b. the hook created no client settings inside the project' (
        -not (Test-Path -LiteralPath (Join-Path $proj22 '.claude')) -and -not (Test-Path -LiteralPath (Join-Path $proj22 '.codex')))
    $stateFiles = @(Get-ChildItem -LiteralPath (Join-Path $hc22.LocalAppData 'HookMaker\state') -Filter 'LargeFileCheck-*.txt' -ErrorAction SilentlyContinue)
    Check '32c. its only state lives under the isolated LOCALAPPDATA, exactly one file' ($stateFiles.Count -eq 1)

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 parity ---' -ForegroundColor Cyan
    $hc23 = New-IsolatedHookCopy
    $proj23 = New-Proj 'Host51'
    New-SourceFile (Join-Path $proj23 'src\a.py') 1100
    $rPre = Fire -HookPath $hc23.Script -Cwd $proj23 -EventName 'SessionStart' -LocalAppData $hc23.LocalAppData -Exe 'powershell.exe'
    Check '30a. 5.1 host: pre-task guidance works' (
        $rPre.Exit -eq 0 -and (Get-Advisory $rPre.Out) -match '(?i)design correctly from the start') ($rPre.Out + $rPre.Err)
    $rStop = Fire -HookPath $hc23.Script -Cwd $proj23 -EventName 'Stop' -LocalAppData $hc23.LocalAppData -Exe 'powershell.exe'
    Check '30b. 5.1 host: Stop scan reports the oversized file' (
        $rStop.Exit -eq 0 -and (Get-Advisory $rStop.Out) -match 'a\.py \(1100 lines\)') ($rStop.Out + $rStop.Err)

    # =====================================================================
    Write-Host '--- No residue in the REAL HookMaker state dir ---' -ForegroundColor Cyan
    $RealStateAfter = @(Get-ChildItem -LiteralPath $RealStateDir -Filter 'LargeFileCheck-*.txt' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    Check '31/32d. the suite wrote no state into the real LOCALAPPDATA (isolation held)' (
        (@($RealStateAfter | Where-Object { $RealStateBefore -notcontains $_ }).Count) -eq 0) ("$RealStateAfter")
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
