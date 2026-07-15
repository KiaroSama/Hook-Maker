# Offline smoke test for the Ai-Memory-Check hook (post-task, Stop): the
# git-based staleness trigger (project work newer than .ai/memory.md), the
# stop_hook_active loop guard, the cooldown, and the enhancement that
# enumerates the ACTUAL specialized .ai/*.md files present in the block
# reason - not a generic example list - so "update whichever deserves it"
# has real names to weigh. Uses real throwaway git repos, no network.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-AiMemoryCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Hook = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\Ai-Memory-Check\Ai-Memory-Check.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Required script not found: $Hook" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-aimemchk-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$FakeAppData = Join-Path $Work 'appdata'
New-Item -ItemType Directory -Path $Work, $FakeAppData -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$SavedLocalAppData = $env:LOCALAPPDATA

function Fire {
    # $RawStdin intentionally UNTYPED: [string] coerces $null to '' (see LESSON.md).
    param([string]$Cwd, [string]$EventName = 'Stop', $RawStdin = $null, [bool]$StopHookActive = $false, [string]$Exe = 'pwsh')
    $payload = $RawStdin
    if ($null -eq $payload) {
        $obj = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName }
        if ($StopHookActive) { $obj['stop_hook_active'] = $true }
        $payload = $obj | ConvertTo-Json
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') {
        $file = 'pwsh'; $argLine = '-NoLogo -NoProfile -File "' + $Hook + '"'
    }
    else {
        $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"'
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

function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

function New-GitProj {
    param([string]$Name)
    $repo = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q -b main
    & git -C $repo config user.email 't@t'
    & git -C $repo config user.name 't'
    return $repo
}
function Add-Commit {
    param([string]$Repo, [string]$Message = 'c')
    & git -C $Repo add -A 2>$null | Out-Null
    & git -C $Repo commit -q -m $Message 2>$null | Out-Null
}

try {
    # =====================================================================
    Write-Host '--- input handling ---' -ForegroundColor Cyan
    $plain = New-GitProj 'Plain'
    Add-Commit $plain 'seed'
    $r = Fire -Cwd $plain -RawStdin ''
    Check 'empty stdin -> silent exit 0' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $plain -StopHookActive $true
    Check 'stop_hook_active -> silent (loop guard)' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $plain
    Check 'no .ai/ directory -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- .ai exists, memory.md missing entirely -> flags it ---' -ForegroundColor Cyan
    $proj1 = New-GitProj 'MissingMemory'
    New-Item -ItemType Directory -Path (Join-Path $proj1 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj1 'code.txt') 'work'
    Add-Commit $proj1 'work commit'
    $r = Fire -Cwd $proj1
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'blocks with a reason' ($null -ne $parsed -and [string]$parsed.decision -eq 'block')
    Check 'reason names memory.md as missing' ($null -ne $parsed -and [string]$parsed.reason -like '*memory.md*missing*')

    # =====================================================================
    Write-Host '--- stale memory.md vs newer project work -> flags it, lists real .ai files ---' -ForegroundColor Cyan
    $proj2 = New-GitProj 'StaleMemory'
    New-Item -ItemType Directory -Path (Join-Path $proj2 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj2 '.ai\memory.md') '# Memory'
    Write-Utf8 (Join-Path $proj2 '.ai\LESSON.md') 'a lesson'
    Write-Utf8 (Join-Path $proj2 '.ai\REFERENCE.md') 'a reference'
    Add-Commit $proj2 'seed .ai'
    Start-Sleep -Milliseconds 200
    Write-Utf8 (Join-Path $proj2 'app.ps1') 'newer real work'
    Add-Commit $proj2 'real work, newer than memory.md'
    (Get-Item (Join-Path $proj2 '.ai\memory.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $r = Fire -Cwd $proj2
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'blocks: memory.md older than latest work' ($null -ne $parsed -and [string]$parsed.reason -like '*older than the latest project changes*')
    Check 'reason lists the ACTUAL specialized files present (not a generic example)' ($null -ne $parsed -and [string]$parsed.reason -like '*Other files currently in .ai/*LESSON.md*REFERENCE.md*')
    # Immediate re-fire must respect the cooldown (default 30 min) - silent.
    $r2 = Fire -Cwd $proj2
    Check 'respects cooldown on immediate re-check' ($r2.Exit -eq 0 -and $r2.Out -eq '')

    # =====================================================================
    Write-Host '--- .ai has no specialized files yet -> says so explicitly ---' -ForegroundColor Cyan
    $proj3 = New-GitProj 'OnlyMemory'
    New-Item -ItemType Directory -Path (Join-Path $proj3 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj3 '.ai\memory.md') '# Memory'
    Add-Commit $proj3 'seed'
    Start-Sleep -Milliseconds 200
    Write-Utf8 (Join-Path $proj3 'app.ps1') 'work'
    Add-Commit $proj3 'newer work'
    (Get-Item (Join-Path $proj3 '.ai\memory.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $r = Fire -Cwd $proj3
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check 'explicitly says no specialized files exist yet' ($null -ne $parsed -and [string]$parsed.reason -like '*no specialized files yet*')

    # =====================================================================
    Write-Host '--- memory.md already fresh -> silent ---' -ForegroundColor Cyan
    $proj4 = New-GitProj 'Fresh'
    New-Item -ItemType Directory -Path (Join-Path $proj4 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj4 'app.ps1') 'work'
    Add-Commit $proj4 'work'
    Write-Utf8 (Join-Path $proj4 '.ai\memory.md') '# Memory, written after the work commit'
    $r = Fire -Cwd $proj4
    Check 'fresh memory.md -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 host ---' -ForegroundColor Cyan
    $proj5 = New-GitProj 'Host51'
    New-Item -ItemType Directory -Path (Join-Path $proj5 '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $proj5 '.ai\memory.md') '# Memory'
    Add-Commit $proj5 'seed'
    Start-Sleep -Milliseconds 200
    Write-Utf8 (Join-Path $proj5 'app.ps1') 'work'
    Add-Commit $proj5 'newer work'
    (Get-Item (Join-Path $proj5 '.ai\memory.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $r = Fire -Cwd $proj5 -Exe 'powershell.exe'
    $parsed = $null
    try { $parsed = $r.Out | ConvertFrom-Json } catch { }
    Check '5.1 host: blocks cleanly, no crash' ($r.Exit -eq 0 -and $r.Err -eq '' -and $null -ne $parsed -and [string]$parsed.decision -eq 'block') $r.Out
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
