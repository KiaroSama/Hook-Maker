# Offline test suite for Graph-Update-Check - had NO dedicated coverage before
# this suite (only implicitly touched by Test-Wizard's generic install flow).
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-GraphUpdateCheck.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Graph-Update-Check\Graph-Update-Check.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-graphtest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray
$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

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

function Fire {
    param([string]$Cwd, [switch]$StopHookActive, [string]$Exe = 'pwsh')
    $obj = @{ session_id = 't'; cwd = $Cwd; hook_event_name = 'Stop' }
    if ($StopHookActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ($Exe -eq 'pwsh') { $file = (Get-Process -Id $PID).Path; $argLine = '-NoLogo -NoProfile -File "' + $Hook + '"' }
    else { $file = 'powershell.exe'; $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Hook + '"' }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData }
    }
    $proc = Start-Process @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

# A graph.json whose LastWriteTimeUtc is safely in the past relative to the
# repo's latest commit (staleness is computed from that gap, see
# Get-LatestWorkTimeUtc / the >2-minute margin in the hook itself).
function New-StaleGraph {
    param([string]$Repo)
    $graphDir = Join-Path $Repo 'graphify-out'
    New-Item -ItemType Directory -Path $graphDir -Force | Out-Null
    $graphPath = Join-Path $graphDir 'graph.json'
    Write-Utf8 $graphPath '{}'
    (Get-Item -LiteralPath $graphPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
    return $graphPath
}

try {
    # =====================================================================
    Write-Host '--- no graph -> silent ---' -ForegroundColor Cyan
    $noGraph = New-GitRepo 'NoGraph'
    Add-Commit $noGraph 'init'
    $r = Fire -Cwd $noGraph
    Check 'no graphify-out/graph.json -> silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- stale graph triggers the decision reminder ---' -ForegroundColor Cyan
    $stale = New-GitRepo 'Stale'
    New-StaleGraph $stale | Out-Null
    Write-Utf8 (Join-Path $stale 'src.ps1') 'function Foo {}'
    Add-Commit $stale 'add Foo'
    $r = Fire -Cwd $stale
    Check 'a stale graph produces a Stop reminder' ($r.Out -match '"decision":"block"' -and $r.Out -match 'GRAPH UPDATE CHECK') $r.Out
    Check 'the reminder uses structural/relationship criteria, not file count' (
        $r.Out -match 'based on STRUCTURAL impact, not the number of files changed') $r.Out
    Check 'the OLD blanket "one-file fixes" exclusion wording is gone' ($r.Out -notmatch 'one-file fixes')
    Check 'a one-file structural change (export/import/call/inheritance) is described as update-worthy' (
        $r.Out -match 'a single-file change can still be graph-relevant' -and
        $r.Out -match 'changed export, import, call, or inheritance relationship') $r.Out
    Check 'a one-file internal literal/comment-only change is described as potentially not update-worthy' (
        $r.Out -match 'prose/comments/formatting only, a literal or config value change') $r.Out
    Check 'a multi-file docs-only change is explicitly excluded too (criteria are structural, not per-file)' (
        $r.Out -match 'a multi-file change can be graph-irrelevant') $r.Out
    Check 'AST-only/no-API-cost wording remains accurate' ($r.Out -match 'graphify update \.' -and $r.Out -match 'AST-only, no API cost') $r.Out
    Check 'updating remains advisory (agent decides, hook never runs graphify itself)' (
        $r.Out -match 'Decide for yourself' -and $r.Out -notmatch 'graphify update \.\s*$')
    $hookText = [System.IO.File]::ReadAllText($Hook)
    Check 'the hook script never invokes graphify itself' ($hookText -notmatch "FilePath\s+graphify" -and $hookText -notmatch "'graphify'")

    # =====================================================================
    Write-Host '--- an up-to-date graph stays silent ---' -ForegroundColor Cyan
    $fresh = New-GitRepo 'Fresh'
    Write-Utf8 (Join-Path $fresh 'src.ps1') 'function Foo {}'
    Add-Commit $fresh 'add Foo'
    New-StaleGraph $fresh | Out-Null
    (Get-Item -LiteralPath (Join-Path $fresh 'graphify-out\graph.json')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
    $r = Fire -Cwd $fresh
    Check 'a graph newer than the latest work stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- cooldown and stop_hook_active remain intact ---' -ForegroundColor Cyan
    $r2 = Fire -Cwd $stale
    Check 'repeated Stop within the cooldown window stays silent' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $guard = New-GitRepo 'Guard'
    New-StaleGraph $guard | Out-Null
    Write-Utf8 (Join-Path $guard 'src.ps1') 'function Bar {}'
    Add-Commit $guard 'add Bar'
    $r3 = Fire -Cwd $guard -StopHookActive
    Check 'stop_hook_active short-circuits before any graph/git inspection' ($r3.Exit -eq 0 -and $r3.Out -eq '')

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $ps5 = New-GitRepo 'Ps5'
    New-StaleGraph $ps5 | Out-Null
    Write-Utf8 (Join-Path $ps5 'src.ps1') 'function Baz {}'
    Add-Commit $ps5 'add Baz'
    $r4 = Fire -Cwd $ps5 -Exe 'powershell.exe'
    Check 'Windows PowerShell 5.1 emits the reminder cleanly' ($r4.Exit -eq 0 -and $r4.Out -match 'GRAPH UPDATE CHECK' -and $r4.Out -match 'STRUCTURAL impact') $r4.Err
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
