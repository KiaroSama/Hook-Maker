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
    $r = Fire -Cwd $proj4 -HookPath $GraphHook -EventName 'SubagentStop'
    Check 'SubagentStop -> silent (not a registered event)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check: UserPromptSubmit only when the prompt needs codebase structure ---' -ForegroundColor Cyan
    $irrelevantStdin = @{ session_id = 'g-irrelevant'; cwd = $proj4; hook_event_name = 'UserPromptSubmit'; prompt = 'fix a typo in the README' } | ConvertTo-Json
    $r = Fire -Cwd $proj4 -HookPath $GraphHook -RawStdin $irrelevantStdin
    Check 'a docs-only/trivial prompt stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $relevantStdin1 = @{ session_id = 'g-relevant'; cwd = $proj4; hook_event_name = 'UserPromptSubmit'; prompt = 'refactor the module and check what calls this function across the codebase' } | ConvertTo-Json
    $r = Fire -Cwd $proj4 -HookPath $GraphHook -RawStdin $relevantStdin1
    Check 'a structure/refactor/call-path prompt emits the reminder' ($r.Out -like '*GRAPH READ CHECK*') $r.Out
    $relevantStdin2 = @{ session_id = 'g-relevant'; cwd = $proj4; hook_event_name = 'UserPromptSubmit'; prompt = 'now also check the architecture impact further' } | ConvertTo-Json
    $r2 = Fire -Cwd $proj4 -HookPath $GraphHook -RawStdin $relevantStdin2
    Check 'the SAME session does not repeat the reminder on the next relevant prompt' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $relevantStdin3 = @{ session_id = 'g-relevant-2'; cwd = $proj4; hook_event_name = 'UserPromptSubmit'; prompt = 'where is this used across modules' } | ConvertTo-Json
    $r3 = Fire -Cwd $proj4 -HookPath $GraphHook -RawStdin $relevantStdin3
    Check 'a NEW session with a relevant prompt reminds again' ($r3.Out -like '*GRAPH READ CHECK*') $r3.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check: relevant PERSIAN prompt (graph exists) ---' -ForegroundColor Cyan
    # Persian terms are built from code points so this file stays pure ASCII and
    # is read identically by pwsh 7 and Windows PowerShell 5.1 (no BOM reliance).
    $faArch = -join ([char[]](0x645, 0x639, 0x645, 0x627, 0x631, 0x6cc))   # architecture
    $faDep = -join ([char[]](0x648, 0x627, 0x628, 0x633, 0x62a, 0x6af, 0x6cc)) # dependency
    $pGraphFa = New-Proj 'GraphPersian'
    New-Item -ItemType Directory -Path (Join-Path $pGraphFa 'graphify-out') -Force | Out-Null
    Write-Utf8 (Join-Path $pGraphFa 'graphify-out\graph.json') '{}'
    $faStdin1 = @{ session_id = 'g-fa1'; cwd = $pGraphFa; hook_event_name = 'UserPromptSubmit'; prompt = ('please review the ' + $faArch + ' of this project') } | ConvertTo-Json
    $r = Fire -Cwd $pGraphFa -HookPath $GraphHook -RawStdin $faStdin1
    Check 'relevant Persian (architecture) -> scoped-query reminder' ($r.Out -like '*GRAPH READ CHECK*' -and $r.Out -like '*graphify query*') $r.Out
    $faStdin2 = @{ session_id = 'g-fa2'; cwd = $pGraphFa; hook_event_name = 'UserPromptSubmit'; prompt = ('this ' + $faDep + ' needs checking') } | ConvertTo-Json
    $r = Fire -Cwd $pGraphFa -HookPath $GraphHook -RawStdin $faStdin2
    Check 'relevant Persian (dependency) -> scoped-query reminder' ($r.Out -like '*GRAPH READ CHECK*' -and $r.Out -like '*graphify query*') $r.Out
    # A dedicated English relevant case with a fresh project (the graph-exists path).
    $pGraphEn = New-Proj 'GraphEnglish'
    New-Item -ItemType Directory -Path (Join-Path $pGraphEn 'graphify-out') -Force | Out-Null
    Write-Utf8 (Join-Path $pGraphEn 'graphify-out\graph.json') '{}'
    $enStdin = @{ session_id = 'g-en1'; cwd = $pGraphEn; hook_event_name = 'UserPromptSubmit'; prompt = 'map the call path and module dependencies' } | ConvertTo-Json
    $r = Fire -Cwd $pGraphEn -HookPath $GraphHook -RawStdin $enStdin
    Check 'relevant English -> scoped-query reminder' ($r.Out -like '*this project has a graphify knowledge graph*' -and $r.Out -like '*graphify query*') $r.Out

    # =====================================================================
    Write-Host '--- Graph-Read-Check: missing graph + graphify AVAILABLE -> create-then-query, never runs graphify ---' -ForegroundColor Cyan
    # A fake graphify.cmd on PATH makes Get-Command resolve it WITHOUT running
    # it. It writes a sentinel IF executed; the sentinel must never appear.
    $fakeToolDir = Join-Path $Work 'faketool'
    New-Item -ItemType Directory -Path $fakeToolDir -Force | Out-Null
    $sentinel = Join-Path $Work 'graphify-was-run.txt'
    Write-Utf8 (Join-Path $fakeToolDir 'graphify.cmd') ("@echo off`r`necho ran> `"" + $sentinel + "`"`r`n")
    $pMiss = New-Proj 'MissGraphAvail'   # deliberately no graphify-out
    $savedPath = $env:PATH
    $env:PATH = $fakeToolDir + [System.IO.Path]::PathSeparator + $savedPath
    try {
        $missStdin = @{ session_id = 'm-1'; cwd = $pMiss; hook_event_name = 'UserPromptSubmit'; prompt = 'refactor the architecture and check module dependencies across the codebase' } | ConvertTo-Json
        $r = Fire -Cwd $pMiss -HookPath $GraphHook -RawStdin $missStdin
        Check 'missing graph + relevant -> create-then-query guidance' ($r.Out -like '*GRAPH READ CHECK*' -and $r.Out -like '*create the graph*' -and $r.Out -like '*graphify query*') $r.Out
        Check 'hook did NOT execute graphify (no sentinel)' (-not (Test-Path -LiteralPath $sentinel))
        # Missing graph + trivial/docs prompt -> total silence (new session).
        $trivialStdin = @{ session_id = 'm-triv'; cwd = $pMiss; hook_event_name = 'UserPromptSubmit'; prompt = 'fix a typo in the changelog wording' } | ConvertTo-Json
        $r = Fire -Cwd $pMiss -HookPath $GraphHook -RawStdin $trivialStdin
        Check 'missing graph + trivial/docs prompt -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    }
    finally { $env:PATH = $savedPath }

    # =====================================================================
    Write-Host '--- Graph-Read-Check: missing graph + graphify UNAVAILABLE -> one fallback advisory, no loop ---' -ForegroundColor Cyan
    $pMiss2 = New-Proj 'MissGraphUnavail'   # no graphify-out
    $savedPath = $env:PATH
    $env:PATH = (Join-Path $env:SystemRoot 'System32')   # a sane PATH with no graphify
    try {
        $u1 = @{ session_id = 'u-1'; cwd = $pMiss2; hook_event_name = 'UserPromptSubmit'; prompt = 'trace the call path and impact of this entry point' } | ConvertTo-Json
        $r = Fire -Cwd $pMiss2 -HookPath $GraphHook -RawStdin $u1
        Check 'missing graph + graphify unavailable -> bounded fallback advisory' ($r.Out -like '*GRAPH READ CHECK*' -and $r.Out -like '*fall back*' -and $r.Out -like '*not found on PATH*') $r.Out
        # Same session + same (no-graph) state -> deduped, never loops.
        $r2 = Fire -Cwd $pMiss2 -HookPath $GraphHook -RawStdin $u1
        Check 'unavailable fallback does not repeat in the same session/state' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    }
    finally { $env:PATH = $savedPath }

    # =====================================================================
    Write-Host '--- Graph-Read-Check: fingerprint by session + graph version, existence change re-enables ---' -ForegroundColor Cyan
    $pFp = New-Proj 'GraphFingerprint'
    $fpGraph = Join-Path $pFp 'graphify-out\graph.json'
    New-Item -ItemType Directory -Path (Join-Path $pFp 'graphify-out') -Force | Out-Null
    Write-Utf8 $fpGraph '{}'
    $fpStdin = @{ session_id = 'fp-1'; cwd = $pFp; hook_event_name = 'UserPromptSubmit'; prompt = 'refactor the module structure' } | ConvertTo-Json
    $r = Fire -Cwd $pFp -HookPath $GraphHook -RawStdin $fpStdin
    Check 'first relevant prompt in session -> reminder' ($r.Out -like '*GRAPH READ CHECK*') $r.Out
    $r2 = Fire -Cwd $pFp -HookPath $GraphHook -RawStdin $fpStdin
    Check 'same session + unchanged graph -> silent (fingerprint dedup)' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    # Regenerate the graph (new version): its LastWriteTime changes the token.
    $gi = Get-Item -LiteralPath $fpGraph -Force
    $gi.LastWriteTimeUtc = $gi.LastWriteTimeUtc.AddMinutes(5)
    $r3 = Fire -Cwd $pFp -HookPath $GraphHook -RawStdin $fpStdin
    Check 'a graph version change re-enables the reminder in the same session' ($r3.Out -like '*GRAPH READ CHECK*') $r3.Out

    # Existence change (no graph -> graph appears): create-guidance, then read.
    $pEx = New-Proj 'GraphExistenceChange'   # starts with no graphify-out
    $savedPath = $env:PATH
    $env:PATH = $fakeToolDir + [System.IO.Path]::PathSeparator + (Join-Path $env:SystemRoot 'System32')
    try {
        $exStdin = @{ session_id = 'ex-1'; cwd = $pEx; hook_event_name = 'UserPromptSubmit'; prompt = 'what is the impact across modules and entry points' } | ConvertTo-Json
        $r = Fire -Cwd $pEx -HookPath $GraphHook -RawStdin $exStdin
        Check 'no graph yet -> create/fallback guidance (not the read note)' ($r.Out -like '*no graphify knowledge graph exists*' -and $r.Out -notlike '*this project has a graphify knowledge graph*') $r.Out
        # The graph now appears; the same session must switch to the READ note.
        New-Item -ItemType Directory -Path (Join-Path $pEx 'graphify-out') -Force | Out-Null
        Write-Utf8 (Join-Path $pEx 'graphify-out\graph.json') '{}'
        $r2 = Fire -Cwd $pEx -HookPath $GraphHook -RawStdin $exStdin
        Check 'graph now exists -> read reminder re-enabled (existence change)' ($r2.Out -like '*this project has a graphify knowledge graph*' -and $r2.Out -like '*graphify query*') $r2.Out
    }
    finally { $env:PATH = $savedPath }

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
