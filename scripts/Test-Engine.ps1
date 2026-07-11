# Smoke test for the cross-project sync engine.
# Self-contained: builds throwaway fixtures under the temp directory, drives the
# engine through stdin exactly like a real hook, asserts behavior, cleans up.
# Guards the collection edge cases that caused past crashes (single vs many
# extensions, empty vs populated sources) plus the core review/ack lifecycle.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-Engine.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$Engine = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks\CrossProjectSyncHook.ps1'
if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) {
    Write-Host "Engine not found at: $Engine" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        $script:Pass++
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
    }
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Project {
    param([string]$Name)
    $root = Join-Path $Work $Name
    New-Item -ItemType Directory -Path (Join-Path $root '.ai') -Force | Out-Null
    return $root
}

function New-Endpoint {
    param([string]$Name, [string]$Root)
    return [ordered]@{ name = $Name; root = $Root; directory = '.ai'; aliases = @() }
}

function New-Route {
    param([string]$Id, $Source, $Destination)
    return [ordered]@{ id = $Id; enabled = $true; source = $Source; destination = $Destination }
}

function Write-Config {
    param([string]$Path, $Routes, $Extensions)
    $cfg = [ordered]@{
        version  = 2
        defaults = [ordered]@{
            events            = @('SessionStart', 'UserPromptSubmit')
            initialSyncMode   = 'review'
            maxFileBytes      = 2097152
            includeExtensions = $Extensions
            excludePatterns   = @('.cross-project-sync/*', '*/.cross-project-sync/*')
        }
        profiles = @(
            [ordered]@{ id = 'grp'; name = 'Test group'; enabled = $true; routes = $Routes }
        )
    }
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

# Deliver the hook payload through a real stdin file handle rather than a
# PowerShell pipe: piping a string from a Windows PowerShell 5.1 parent into a
# child process yields empty stdin, and a real host (Claude/Codex) hands the
# hook a genuine stdin stream anyway. This keeps the test host-independent.
function Fire {
    param([string]$Cwd, [string]$Config, [string]$Exe = 'pwsh', [string]$EventName = 'SessionStart', [string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = [guid]::NewGuid().ToString() }
    $payload = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName; source = 'startup' } | ConvertTo-Json -Compress

    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))

    if ($Exe -eq 'pwsh') {
        $file = 'pwsh'
        $argLine = '-NoLogo -NoProfile -File "' + $Engine + '" -ConfigPath "' + $Config + '"'
    }
    else {
        $file = 'powershell.exe'
        $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Engine + '" -ConfigPath "' + $Config + '"'
    }
    $proc = Start-Process -FilePath $file -ArgumentList $argLine -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -Wait -NoNewWindow -PassThru
    $out = if (Test-Path -LiteralPath $outFile) { [System.IO.File]::ReadAllText($outFile) } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out.Trim() }
}

try {
    # --- Fixtures: A <-> B mesh, plus an unrelated project X ---------------
    $A = New-Project 'ProjA'
    $B = New-Project 'ProjB'
    $X = New-Project 'ProjX'
    Set-Content -LiteralPath (Join-Path $A '.ai\LESSON.md') "# Lesson`nvalidate signatures" -Encoding utf8

    $routesAB = @(
        (New-Route 'a-to-b' (New-Endpoint 'A' $A) (New-Endpoint 'B' $B)),
        (New-Route 'b-to-a' (New-Endpoint 'B' $B) (New-Endpoint 'A' $A))
    )

    # --- Scenario 1: single-element includeExtensions must not crash -------
    $cfg1 = Join-Path $Work 'cfg-single.json'
    Write-Config -Path $cfg1 -Routes $routesAB -Extensions @('.md')
    $r1 = Fire -Cwd $B -Config $cfg1
    Check 'single-extension config: exit 0 (no crash)' ($r1.Exit -eq 0)
    Check 'single-extension config: review emitted' ($r1.Out -match 'REVIEW REQUIRED')
    $valid = $false
    try { $null = $r1.Out | ConvertFrom-Json; $valid = $true } catch { $valid = $false }
    Check 'output is valid JSON hook payload' $valid

    # --- Scenario 2: many extensions still work (fresh state) --------------
    $cfg2 = Join-Path $Work 'cfg-many.json'
    Write-Config -Path $cfg2 -Routes $routesAB -Extensions @('.md', '.txt', '.json', '.ps1')
    $r2 = Fire -Cwd $B -Config $cfg2
    Check 'many-extension config: review emitted' ($r2.Out -match 'REVIEW REQUIRED')

    # --- Scenario 3: staged package on disk (from scenario 1) --------------
    $inboxRoot = Join-Path $B '.ai\.cross-project-sync\inbox'
    $staged = @(Get-ChildItem -LiteralPath $inboxRoot -Recurse -File -ErrorAction SilentlyContinue)
    Check 'manifest.json staged' (@($staged | Where-Object Name -eq 'manifest.json').Count -ge 1)
    Check 'source LESSON.md staged' (@($staged | Where-Object Name -eq 'LESSON.md').Count -ge 1)

    # --- Scenario 4: same session is silent --------------------------------
    $null = Fire -Cwd $B -Config $cfg1 -SessionId 'fixed'          # first notify in this session
    $rSame = Fire -Cwd $B -Config $cfg1 -SessionId 'fixed'         # same session again
    Check 'same session: second fire is silent' ([string]::IsNullOrWhiteSpace($rSame.Out))

    # --- Scenario 5: acknowledge clears the pending review -----------------
    $ack = & pwsh -NoLogo -NoProfile -File $Engine -Acknowledge -ProjectRoot $B -Profile 'grp' -Route 'a-to-b' -ConfigPath $cfg1 2>&1
    Check 'acknowledge: succeeds' ($LASTEXITCODE -eq 0 -and (($ack | Out-String) -match 'acknowledged'))
    $stagedAfter = @(Get-ChildItem -LiteralPath $inboxRoot -Recurse -File -ErrorAction SilentlyContinue)
    Check 'acknowledge: inbox cleaned' ($stagedAfter.Count -eq 0)
    $rAfterAck = Fire -Cwd $B -Config $cfg1
    Check 'after acknowledge: silent (no changes)' ([string]::IsNullOrWhiteSpace($rAfterAck.Out))

    # --- Scenario 6: a real change is re-detected --------------------------
    Add-Content -LiteralPath (Join-Path $A '.ai\LESSON.md') 'rotate tokens quarterly'
    Set-Content -LiteralPath (Join-Path $A '.ai\COMMANDS.md') 'npm test' -Encoding utf8
    $r6 = Fire -Cwd $B -Config $cfg1 -EventName 'UserPromptSubmit'
    Check 'change re-detected after ack' ($r6.Out -match 'REVIEW REQUIRED')
    $manifest = Get-ChildItem -LiteralPath $inboxRoot -Recurse -Filter 'manifest.json' | Select-Object -First 1
    $m = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
    Check 'manifest lists added COMMANDS.md' (@($m.added) -contains 'COMMANDS.md')
    Check 'manifest lists modified LESSON.md' (@($m.modified) -contains 'LESSON.md')

    # --- Scenario 7: unrelated project is ignored --------------------------
    Set-Content -LiteralPath (Join-Path $X '.ai\NOTE.md') 'X is in no route' -Encoding utf8
    $rX = Fire -Cwd $X -Config $cfg1
    Check 'unrelated project: no output' ([string]::IsNullOrWhiteSpace($rX.Out))
    Check 'unrelated project: no sync state created' (-not (Test-Path -LiteralPath (Join-Path $X '.ai\.cross-project-sync')))

    # --- Scenario 8: empty source is a silent baseline, no empty package ---
    $C0 = New-Project 'EmptySource'
    $D0 = New-Project 'Dest'
    $cfgEmpty = Join-Path $Work 'cfg-empty.json'
    Write-Config -Path $cfgEmpty -Routes @((New-Route 'c-to-d' (New-Endpoint 'C' $C0) (New-Endpoint 'D' $D0))) -Extensions @('.md')
    $rEmpty = Fire -Cwd $D0 -Config $cfgEmpty
    Check 'empty source: silent (no empty review package)' ([string]::IsNullOrWhiteSpace($rEmpty.Out))
    Check 'empty source: no inbox package created' (-not (Test-Path -LiteralPath (Join-Path $D0 '.ai\.cross-project-sync\inbox')))

    # --- Scenario 9: engine runs under Windows PowerShell 5.1 --------------
    if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        $r9 = Fire -Cwd $B -Config $cfg2 -Exe 'powershell.exe'
        Check 'runs under powershell.exe (5.1)' ($r9.Exit -eq 0 -and $r9.Out -match 'REVIEW REQUIRED')
    }
    else {
        Write-Host '[SKIP] powershell.exe not available' -ForegroundColor Yellow
    }
}
finally {
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        [System.IO.Directory]::Delete($Work, $true)
    }
}

Write-Host ''
$resultColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ('Result: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed') -ForegroundColor $resultColor
exit $script:Fail
