# Offline test suite for Test-Temp-Cleanup - new hook, no prior coverage.
# Focused on the explicit safety requirements, not an exhaustive per-ecosystem
# matrix: SessionStart baseline is silent; a safe candidate created after
# baseline gets deleted and verified; tracked/staged/linked/hard-excluded
# paths are preserved; review-only artifacts are preserved by default;
# missing-baseline fallback is conservative; path/byte limits are respected;
# a locked candidate blocks once and does not loop; Claude/Codex output
# shapes; the hook never runs git clean/reset or a global cache-clean command.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-TestTempCleanup.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HooksRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$Hook = Join-Path $HooksRoot 'Test-Temp-Cleanup\Test-Temp-Cleanup.ps1'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-cleanuptest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }
function New-GitRepo {
    param([string]$Name)
    $p = New-Proj $Name
    & git -C $p init -q -b main
    & git -C $p config user.email 't@t'
    & git -C $p config user.name 't'
    return $p
}
function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A
    & git -C $Repo commit -q -m $Message
}

# Per-test isolated LOCALAPPDATA so baseline/result/failure state files never
# collide across test cases or with the real machine state.
function New-IsolatedHookCopy {
    param([hashtable]$EnvOverrides = @{})
    $dir = Join-Path $Work ('hookcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item $Hook (Join-Path $dir 'Test-Temp-Cleanup.ps1')
    Copy-Item $HookLib (Join-Path $Work '_hooklib.ps1') -Force
    if ($EnvOverrides.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($key in $EnvOverrides.Keys) { [void]$lines.Add($key + '=' + $EnvOverrides[$key]) }
        Write-Utf8 (Join-Path $dir '.env') (($lines.ToArray() -join "`r`n") + "`r`n")
    }
    $fakeLocal = Join-Path $dir '_fakelocal'
    New-Item -ItemType Directory -Path $fakeLocal -Force | Out-Null
    return [pscustomobject]@{ Script = (Join-Path $dir 'Test-Temp-Cleanup.ps1'); LocalAppData = $fakeLocal }
}

function Fire {
    param([string]$HookPath, [string]$Cwd, [string]$EventName, [string]$SessionId = 'sess1', [string]$LocalAppData, [switch]$StopHookActive, [switch]$NoClaudeProjectDir, [string]$Exe = 'pwsh')
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
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
        # -Environment MERGES with the inherited environment rather than
        # replacing it (see LESSON.md) - an ambient CLAUDE_PROJECT_DIR from
        # this very test-runner session would otherwise leak into a "Codex"
        # case. Explicitly clear it to '' rather than omitting the key.
        $env = @{ PATH = $env:PATH; LOCALAPPDATA = $LocalAppData }
        $env['CLAUDE_PROJECT_DIR'] = if ($NoClaudeProjectDir) { '' } else { $Cwd }
        $startArgs.Environment = $env
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

try {
    # =====================================================================
    Write-Host '--- SessionStart baseline is always silent ---' -ForegroundColor Cyan
    $hc1 = New-IsolatedHookCopy
    $proj1 = New-GitRepo 'Baseline'
    Add-Commit $proj1 'init'
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'SessionStart' -LocalAppData $hc1.LocalAppData
    Check 'SessionStart is silent even with nothing present' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    New-Item -ItemType Directory -Path (Join-Path $proj1 '.pytest_cache') -Force | Out-Null
    Write-Utf8 (Join-Path $proj1 '.pytest_cache\x.txt') 'cache'
    $r = Fire -HookPath $hc1.Script -Cwd $proj1 -EventName 'SessionStart' -LocalAppData $hc1.LocalAppData
    Check 'SessionStart stays silent even when candidates are already present' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $baselineFile = @(Get-ChildItem -LiteralPath (Join-Path $hc1.LocalAppData 'HookMaker\state') -Filter 'TestTempCleanup-baseline-*.json' -ErrorAction SilentlyContinue)
    Check 'a baseline state file was written' ($baselineFile.Count -eq 1)

    # =====================================================================
    Write-Host '--- a safe candidate created after baseline is deleted and verified ---' -ForegroundColor Cyan
    $hc2 = New-IsolatedHookCopy
    $proj2 = New-GitRepo 'SafeDelete'
    Add-Commit $proj2 'init'
    Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'SessionStart' -LocalAppData $hc2.LocalAppData | Out-Null
    $cachePath = Join-Path $proj2 '.pytest_cache'
    New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
    Write-Utf8 (Join-Path $cachePath 'x.txt') 'cache'
    $r = Fire -HookPath $hc2.Script -Cwd $proj2 -EventName 'Stop' -LocalAppData $hc2.LocalAppData
    Check 'Stop reports safe cleanup succeeded' ($r.Out -match 'TEST TEMP CLEANUP' -and $r.Out -match 'removed safe project-local test cache') $r.Out
    Check 'the safe candidate is actually gone (rescan-verified)' (-not (Test-Path -LiteralPath $cachePath))
    Check 'output uses hookSpecificOutput.additionalContext (Claude shape), never decision:block' ($r.Out -match '"additionalContext"' -and $r.Out -notmatch '"decision"') $r.Out

    # =====================================================================
    Write-Host '--- tracked/committed candidates are never deleted ---' -ForegroundColor Cyan
    $hc3 = New-IsolatedHookCopy
    $proj3 = New-GitRepo 'TrackedPreserved'
    $trackedCache = Join-Path $proj3 '.pytest_cache'
    New-Item -ItemType Directory -Path $trackedCache -Force | Out-Null
    Write-Utf8 (Join-Path $trackedCache 'x.txt') 'cache'
    Add-Commit $proj3 'init with tracked cache'
    Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'SessionStart' -LocalAppData $hc3.LocalAppData | Out-Null
    $r = Fire -HookPath $hc3.Script -Cwd $proj3 -EventName 'Stop' -LocalAppData $hc3.LocalAppData
    Check 'a tracked cache directory is preserved, never deleted' (Test-Path -LiteralPath $trackedCache)

    # =====================================================================
    Write-Host '--- reparse points (junctions) are never followed or deleted ---' -ForegroundColor Cyan
    $hc4 = New-IsolatedHookCopy
    $proj4 = New-GitRepo 'JunctionPreserved'
    Add-Commit $proj4 'init'
    Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'SessionStart' -LocalAppData $hc4.LocalAppData | Out-Null
    $realOutside = Join-Path $Work 'OutsideRealCache'
    New-Item -ItemType Directory -Path $realOutside -Force | Out-Null
    Write-Utf8 (Join-Path $realOutside 'guard.txt') 'do-not-delete'
    $junctionPath = Join-Path $proj4 '.pytest_cache'
    $junctionOk = $false
    try { & cmd /c mklink /J "$junctionPath" "$realOutside" *> $null; $junctionOk = (Test-Path -LiteralPath $junctionPath) } catch { }
    if ($junctionOk) {
        $r = Fire -HookPath $hc4.Script -Cwd $proj4 -EventName 'Stop' -LocalAppData $hc4.LocalAppData
        Check 'a junction named like a safe cache is left alone' (Test-Path -LiteralPath $junctionPath)
        Check 'the real directory the junction points to is untouched' (Test-Path -LiteralPath (Join-Path $realOutside 'guard.txt'))
    }
    else {
        Write-Host '  (skipped: could not create a test junction on this host)' -ForegroundColor DarkYellow
    }

    # =====================================================================
    Write-Host '--- hard-protected roots (node_modules, .git, ...) are never descended into ---' -ForegroundColor Cyan
    $hc5 = New-IsolatedHookCopy
    $proj5 = New-GitRepo 'HardProtected'
    Add-Commit $proj5 'init'
    Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'SessionStart' -LocalAppData $hc5.LocalAppData | Out-Null
    $nested = Join-Path $proj5 'node_modules\.pytest_cache'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Write-Utf8 (Join-Path $nested 'x.txt') 'cache'
    $r = Fire -HookPath $hc5.Script -Cwd $proj5 -EventName 'Stop' -LocalAppData $hc5.LocalAppData
    Check 'a cache dir nested inside node_modules is never discovered or deleted' (Test-Path -LiteralPath $nested)

    # =====================================================================
    Write-Host '--- review-only artifacts are preserved by default ---' -ForegroundColor Cyan
    $hc6 = New-IsolatedHookCopy
    $proj6 = New-GitRepo 'ReviewOnly'
    Add-Commit $proj6 'init'
    Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'SessionStart' -LocalAppData $hc6.LocalAppData | Out-Null
    $coverageDir = Join-Path $proj6 'coverage'
    New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
    Write-Utf8 (Join-Path $coverageDir 'lcov.info') 'data'
    $r = Fire -HookPath $hc6.Script -Cwd $proj6 -EventName 'Stop' -LocalAppData $hc6.LocalAppData
    Check 'coverage/ is preserved, not deleted, by default' (Test-Path -LiteralPath $coverageDir)
    Check 'the report says preserved' ($r.Out -match 'preserved') $r.Out

    # =====================================================================
    Write-Host '--- DELETE_REVIEW_ARTIFACTS=true is an explicit opt-in ---' -ForegroundColor Cyan
    $hc7 = New-IsolatedHookCopy -EnvOverrides @{ DELETE_REVIEW_ARTIFACTS = 'true' }
    $proj7 = New-GitRepo 'ReviewOptIn'
    Add-Commit $proj7 'init'
    Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'SessionStart' -LocalAppData $hc7.LocalAppData | Out-Null
    $coverageDir7 = Join-Path $proj7 'coverage'
    New-Item -ItemType Directory -Path $coverageDir7 -Force | Out-Null
    Write-Utf8 (Join-Path $coverageDir7 'lcov.info') 'data'
    Fire -HookPath $hc7.Script -Cwd $proj7 -EventName 'Stop' -LocalAppData $hc7.LocalAppData | Out-Null
    Check 'with the explicit opt-in, review artifacts can be deleted' (-not (Test-Path -LiteralPath $coverageDir7))

    # =====================================================================
    Write-Host '--- missing baseline: conservative fallback only ---' -ForegroundColor Cyan
    $hc8 = New-IsolatedHookCopy
    $proj8 = New-GitRepo 'MissingBaseline'
    Add-Commit $proj8 'init'
    $pyCache8 = Join-Path $proj8 '.pytest_cache'
    New-Item -ItemType Directory -Path $pyCache8 -Force | Out-Null
    Write-Utf8 (Join-Path $pyCache8 'x.txt') 'cache'
    $testTmp8 = Join-Path $proj8 '.test-tmp'
    New-Item -ItemType Directory -Path $testTmp8 -Force | Out-Null
    Write-Utf8 (Join-Path $testTmp8 'x.txt') 'temp'
    # No SessionStart fired -> no baseline for this session at all.
    $r = Fire -HookPath $hc8.Script -Cwd $proj8 -EventName 'Stop' -LocalAppData $hc8.LocalAppData
    Check 'without a baseline, the smallest always-disposable cache is still removed' (-not (Test-Path -LiteralPath $pyCache8))
    Check 'without a baseline, a broader candidate is conservatively preserved' (Test-Path -LiteralPath $testTmp8)
    Check 'the report is honest about not being fully verified' ($r.Out -match 'NOT fully verified') $r.Out

    # =====================================================================
    Write-Host '--- MAX_DELETE_PATHS limit stops deletion and reports incomplete ---' -ForegroundColor Cyan
    $hc9 = New-IsolatedHookCopy -EnvOverrides @{ MAX_DELETE_PATHS = '1' }
    $proj9 = New-GitRepo 'LimitTest'
    Add-Commit $proj9 'init'
    Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'SessionStart' -LocalAppData $hc9.LocalAppData | Out-Null
    foreach ($n in @('.pytest_cache', '.mypy_cache')) {
        $p = Join-Path $proj9 $n
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Write-Utf8 (Join-Path $p 'x.txt') 'cache'
    }
    $r = Fire -HookPath $hc9.Script -Cwd $proj9 -EventName 'Stop' -LocalAppData $hc9.LocalAppData
    $remaining = @(@('.pytest_cache', '.mypy_cache') | Where-Object { Test-Path -LiteralPath (Join-Path $proj9 $_) })
    Check 'MAX_DELETE_PATHS=1 leaves exactly one candidate behind' ($remaining.Count -eq 1)
    Check 'the report says the cleanup is incomplete' ($r.Out -match 'INCOMPLETE') $r.Out

    # =====================================================================
    Write-Host '--- a locked candidate blocks once and does not loop ---' -ForegroundColor Cyan
    $hc10 = New-IsolatedHookCopy
    $proj10 = New-GitRepo 'LockedFail'
    Add-Commit $proj10 'init'
    Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'SessionStart' -LocalAppData $hc10.LocalAppData | Out-Null
    $lockedCache = Join-Path $proj10 '.pytest_cache'
    New-Item -ItemType Directory -Path $lockedCache -Force | Out-Null
    $lockedFile = Join-Path $lockedCache 'locked.txt'
    Write-Utf8 $lockedFile 'held'
    $stream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $r1 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
        Check 'a locked safe candidate blocks with a clear reason' ($r1.Out -match '"decision":"block"' -and $r1.Out -match 'could not remove') $r1.Out
        Check 'the failure message never touches tracked/user data claims' ($r1.Out -match 'tracked/user data was not touched') $r1.Out
        $r2 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
        Check 'the SAME unchanged failure does not block again (no loop)' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    }
    finally {
        $stream.Close()
        $stream.Dispose()
    }
    $r3 = Fire -HookPath $hc10.Script -Cwd $proj10 -EventName 'Stop' -LocalAppData $hc10.LocalAppData
    Check 'once the lock clears, cleanup succeeds on a later Stop' (-not (Test-Path -LiteralPath $lockedCache))

    # =====================================================================
    Write-Host '--- Codex output shape (no CLAUDE_PROJECT_DIR) ---' -ForegroundColor Cyan
    $hc11 = New-IsolatedHookCopy
    $proj11 = New-GitRepo 'CodexShape'
    Add-Commit $proj11 'init'
    Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'SessionStart' -LocalAppData $hc11.LocalAppData -NoClaudeProjectDir | Out-Null
    $cache11 = Join-Path $proj11 '.pytest_cache'
    New-Item -ItemType Directory -Path $cache11 -Force | Out-Null
    Write-Utf8 (Join-Path $cache11 'x.txt') 'cache'
    $r = Fire -HookPath $hc11.Script -Cwd $proj11 -EventName 'Stop' -LocalAppData $hc11.LocalAppData -NoClaudeProjectDir
    Check 'Codex shape uses systemMessage, never hookSpecificOutput/decision' ($r.Out -match '"systemMessage"' -and $r.Out -notmatch 'hookSpecificOutput' -and $r.Out -notmatch '"decision"') $r.Out

    # =====================================================================
    Write-Host '--- stop_hook_active and SubagentStop-off guards ---' -ForegroundColor Cyan
    $hc12 = New-IsolatedHookCopy
    $proj12 = New-GitRepo 'GuardChecks'
    Add-Commit $proj12 'init'
    Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'SessionStart' -LocalAppData $hc12.LocalAppData | Out-Null
    $cache12 = Join-Path $proj12 '.pytest_cache'
    New-Item -ItemType Directory -Path $cache12 -Force | Out-Null
    Write-Utf8 (Join-Path $cache12 'x.txt') 'cache'
    $rGuard = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData -StopHookActive
    Check 'stop_hook_active short-circuits before any scan/deletion' ($rGuard.Exit -eq 0 -and $rGuard.Out -eq '' -and (Test-Path -LiteralPath $cache12))
    $rSub = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'SubagentStop' -LocalAppData $hc12.LocalAppData
    Check 'SubagentStop is silent by default (ENABLE_SUBAGENT_STOP=false)' ($rSub.Exit -eq 0 -and $rSub.Out -eq '' -and (Test-Path -LiteralPath $cache12))

    # =====================================================================
    Write-Host '--- static safety: never git clean/reset or a global cache-clean command ---' -ForegroundColor Cyan
    # Strip comment-only lines first: the header deliberately documents "never
    # runs git clean/reset" in prose, which would otherwise false-positive.
    $hookCode = (([System.IO.File]::ReadAllLines($Hook)) | Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
    Check 'the hook never invokes git clean' ($hookCode -notmatch 'git.{0,10}clean')
    Check 'the hook never invokes git reset' ($hookCode -notmatch 'git.{0,10}reset')
    Check 'the hook never invokes npm/yarn/pip cache-clean commands' ($hookCode -notmatch 'cache clean' -and $hookCode -notmatch 'cache purge')
    $hookText = [System.IO.File]::ReadAllText($Hook)
    Check 'the hook never touches .git/.ai/.claude/.codex as candidates (hard-pruned)' ($hookText -match "'\.git', '\.ai', '\.claude', '\.codex'")

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $hc13 = New-IsolatedHookCopy
    $proj13 = New-GitRepo 'Ps5'
    Add-Commit $proj13 'init'
    $r = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'SessionStart' -LocalAppData $hc13.LocalAppData -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 SessionStart runs cleanly' ($r.Exit -eq 0 -and $r.Out -eq '' -and $r.Err -eq '') $r.Err
    $cache13 = Join-Path $proj13 '.pytest_cache'
    New-Item -ItemType Directory -Path $cache13 -Force | Out-Null
    Write-Utf8 (Join-Path $cache13 'x.txt') 'cache'
    $r = Fire -HookPath $hc13.Script -Cwd $proj13 -EventName 'Stop' -LocalAppData $hc13.LocalAppData -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 Stop cleans up and reports cleanly' ($r.Exit -eq 0 -and $r.Out -match 'TEST TEMP CLEANUP' -and $r.Err -eq '') $r.Err
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
