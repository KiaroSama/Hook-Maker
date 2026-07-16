# Offline smoke test for the two new pre-task context hooks:
# - Ai-Memory-Load: injects .ai/memory.md content, content-fingerprinted so an
#   unchanged file stays silent and a real edit re-surfaces it.
# - Graph-Read-Check: reminds to prefer graphify queries when graphify-out/
#   graph.json exists; silent otherwise. No state (cheap static reminder).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-AiMemoryLoad.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$MemoryHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Ai-Memory-Load\Ai-Memory-Load.ps1'
$GraphHook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Graph-Read-Check\Graph-Read-Check.ps1'
foreach ($required in @($MemoryHook, $GraphHook)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 300
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-aimemtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$FakeAppData = Join-Path $Work 'appdata'
New-Item -ItemType Directory -Path $Work, $FakeAppData -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$SavedLocalAppData = $env:LOCALAPPDATA

function Fire {
    # $RawStdin intentionally UNTYPED: [string] coerces $null to '' (see LESSON.md).
    param([string]$Cwd, [string]$EventName = 'SessionStart', $RawStdin = $null, [string]$HookPath = $MemoryHook, [string]$Exe = 'pwsh')
    $payload = $RawStdin
    if ($null -eq $payload) {
        $payload = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName } | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') {
        $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $env:LOCALAPPDATA = $FakeAppData
    try {
        $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -NoNewWindow -PassThru
    }
    finally {
        $env:LOCALAPPDATA = $SavedLocalAppData
    }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    if ($err -ne '' -and $env:HOOKMAKER_TEST_DEBUG -eq '1') {
        Write-Host ('  [stderr] ' + $err.Split("`n")[0]) -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

function New-ConfiguredHookCopy {
    param([string]$SourceHook, [string]$FileName, [hashtable]$EnvOverrides)
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $SourceHook (Join-Path $dir $FileName)
    Copy-Item (Join-Path (Split-Path -Parent $SourceHook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
    Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    return (Join-Path $dir $FileName)
}

try {
    # =====================================================================
    Write-Host '--- Ai-Memory-Load: input handling ---' -ForegroundColor Cyan
    $plain = New-Proj 'Plain'
    $r = Fire -Cwd $plain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $plain -EventName 'Stop'
    Check 'Stop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $plain
    Check 'no .ai/memory.md -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    Check 'no state written' (-not (Test-Path (Join-Path $FakeAppData 'HookMaker\state')) -or @(Get-ChildItem (Join-Path $FakeAppData 'HookMaker\state') -Filter 'AiMemoryLoad-*' -ErrorAction SilentlyContinue).Count -eq 0)

    # =====================================================================
    Write-Host '--- Ai-Memory-Load: injects content, then dedupes, then re-fires on change ---' -ForegroundColor Cyan
    $proj1 = New-Proj 'WithMemory'
    New-Item -ItemType Directory -Path (Join-Path $proj1 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj1 '.ai\memory.md') "# Project Memory`n`nUNIQUE_MARKER_ONE`n"
    $r1 = Fire -Cwd $proj1
    Check 'first run injects memory.md content' ($r1.Out -like '*AI MEMORY LOADED*' -and $r1.Out -like '*UNIQUE_MARKER_ONE*') $r1.Out
    $r2 = Fire -Cwd $proj1
    Check 'unchanged content -> silent (fingerprint dedup)' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    Write-Utf8 (Join-Path $proj1 '.ai\memory.md') "# Project Memory`n`nUNIQUE_MARKER_TWO`n"
    $r3 = Fire -Cwd $proj1
    Check 'changed content re-fires with the new text' ($r3.Out -like '*UNIQUE_MARKER_TWO*' -and $r3.Out -notlike '*UNIQUE_MARKER_ONE*') $r3.Out
    $r4 = Fire -Cwd $proj1
    Check 'stable again -> silent' ($r4.Exit -eq 0 -and $r4.Out -eq '') $r4.Out
    $r5 = Fire -Cwd $proj1 -EventName 'UserPromptSubmit'
    Check 'still stable on UserPromptSubmit -> silent' ($r5.Exit -eq 0 -and $r5.Out -eq '') $r5.Out

    # =====================================================================
    Write-Host '--- Ai-Memory-Load: lists the REST of .ai/, not just memory.md ---' -ForegroundColor Cyan
    $proj1b = New-Proj 'WholeAiFolder'
    New-Item -ItemType Directory -Path (Join-Path $proj1b '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj1b '.ai\memory.md') "# Memory`n`nROUTER_TEXT`n"
    Write-Utf8 (Join-Path $proj1b '.ai\LESSON.md') 'lesson content'
    Write-Utf8 (Join-Path $proj1b '.ai\REFERENCE.md') 'reference content'
    $rb1 = Fire -Cwd $proj1b
    Check 'lists other .ai files by name' ($rb1.Out -like '*LESSON.md*' -and $rb1.Out -like '*REFERENCE.md*') $rb1.Out
    Check 'does not inject their CONTENT, only names' ($rb1.Out -notlike '*lesson content*' -and $rb1.Out -notlike '*reference content*') $rb1.Out
    $rb2 = Fire -Cwd $proj1b
    Check 'unchanged file set + content -> silent' ($rb2.Exit -eq 0 -and $rb2.Out -eq '') $rb2.Out
    # A NEW specialized file appearing (memory.md itself untouched) must still
    # re-surface the note - the file-set is part of the fingerprint too.
    Write-Utf8 (Join-Path $proj1b '.ai\DECISIONS.md') 'decisions content'
    $rb3 = Fire -Cwd $proj1b
    Check 'a new .ai file (memory.md unchanged) still re-fires' ($rb3.Out -like '*DECISIONS.md*') $rb3.Out
    $rb4 = Fire -Cwd $proj1b
    Check 'stable again after the new file is acknowledged' ($rb4.Exit -eq 0 -and $rb4.Out -eq '') $rb4.Out

    # =====================================================================
    Write-Host '--- Ai-Memory-Load: truncation ---' -ForegroundColor Cyan
    $proj2 = New-Proj 'BigMemory'
    New-Item -ItemType Directory -Path (Join-Path $proj2 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj2 '.ai\memory.md') ('X' * 500)
    $smallCapHook = New-ConfiguredHookCopy -SourceHook $MemoryHook -FileName 'Ai-Memory-Load.ps1' -EnvOverrides @{ MAX_CHARS = '50' }
    $r = Fire -Cwd $proj2 -HookPath $smallCapHook
    Check 'oversized memory.md is truncated with a note' ($r.Out -like '*truncated at 50 chars*') $r.Out

    # =====================================================================
    Write-Host '--- Ai-Memory-Load: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $proj3 = New-Proj 'Host51'
    New-Item -ItemType Directory -Path (Join-Path $proj3 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj3 '.ai\memory.md') "# Memory`n`nHOST51_MARKER`n"
    $r = Fire -Cwd $proj3 -Exe 'powershell.exe'
    Check '5.1 host: injects content cleanly' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*HOST51_MARKER*') $r.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check: input handling + silent without a graph ---' -ForegroundColor Cyan
    $gplain = New-Proj 'GraphPlain'
    $r = Fire -Cwd $gplain -HookPath $GraphHook -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $gplain -HookPath $GraphHook -EventName 'Stop'
    Check 'Stop event -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $gplain -HookPath $GraphHook
    Check 'no graphify-out/graph.json -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check: reminds when a graph exists ---' -ForegroundColor Cyan
    $proj4 = New-Proj 'WithGraph'
    New-Item -ItemType Directory -Path (Join-Path $proj4 'graphify-out') -Force | Out-Null
    Write-Utf8 (Join-Path $proj4 'graphify-out\graph.json') '{}'
    $r = Fire -Cwd $proj4 -HookPath $GraphHook
    Check 'graph exists -> emits the reminder' ($r.Out -like '*GRAPH READ CHECK*' -and $r.Out -like '*graphify query*') $r.Out
    $r2 = Fire -Cwd $proj4 -HookPath $GraphHook
    Check 'fires again next session (cheap static reminder, no state needed)' ($r2.Out -like '*GRAPH READ CHECK*') $r2.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check: Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $r = Fire -Cwd $proj4 -HookPath $GraphHook -Exe 'powershell.exe'
    Check '5.1 host: emits cleanly' ($r.Exit -eq 0 -and $r.Err -eq '' -and $r.Out -like '*GRAPH READ CHECK*') $r.Out
}
finally {
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
