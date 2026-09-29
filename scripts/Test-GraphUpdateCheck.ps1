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
# The production marker-path helper, so the stand-down fixture uses the real naming.
$HookLib = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\_hooklib.ps1'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
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
    $proc = Start-BoundedProcess @startArgs
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
    # stop_hook_active means "a Stop gate blocked and the agent is coming
    # back" - NOT "YOU blocked". Thirteen gates share the one flag, so a gate
    # standing down on it alone went silent for somebody else's block, and
    # the next Stop ran with the secret-leak, UTF-8 and CI gates all muted.
    # Each gate now stands down only on its OWN re-entry.
    $r3 = Fire -Cwd $guard -StopHookActive
    Check 'stop_hook_active ALONE does not silence it (another gate blocked, not this one)' ($r3.Exit -eq 0 -and $r3.Out -ne '') $r3.Out
    # A separate project has no cooldown stamp: only the real ledger claim
    # below can suppress it. The environment assignment is code, never text
    # expanded on the left-hand side of a nested PowerShell command.
    $ownedGuard = New-GitRepo 'OwnedGuard'
    New-StaleGraph $ownedGuard | Out-Null
    Write-Utf8 (Join-Path $ownedGuard 'src.ps1') 'function Owned {}'
    Add-Commit $ownedGuard 'add Owned'
    $savedMarkerLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $FakeLocalAppData
        . $HookLib
        $claim = Set-StopBlockMarker -HookInput ([pscustomobject]@{
            session_id = 't'; cwd = $ownedGuard; hook_event_name = 'Stop'
        }) -HookName 'Graph-Update-Check'
        Check 'the production helper actually admitted the isolated graph claim' $claim.Admitted $claim.Reason
        $ledgerPath = Get-StopLedgerPath -ProjectRoot $ownedGuard
        Check 'the graph claim is persisted inside the owned test state directory' (
            (Test-PathInside -Candidate $ledgerPath -Parent $FakeLocalAppData) -and
            [IO.File]::Exists($ledgerPath)) $ledgerPath
    }
    finally { $env:LOCALAPPDATA = $savedMarkerLocal }
    $r4 = Fire -Cwd $ownedGuard -StopHookActive
    Check 'own re-entry is silent without a cooldown stamp and without stderr' (
        $r4.Exit -eq 0 -and $r4.Out -eq '' -and $r4.Err -eq '') ($r4.Out + $r4.Err)

    # =====================================================================
    # graphify-markdown.md: the git-ignored Markdown folders are part of the
    # graph, so an edit there makes it stale even though Git shows nothing.
    Write-Host '--- Markdown work: git-ignored folders count, dependency folders do not ---' -ForegroundColor Cyan
    function New-MarkdownRepo {
        param([string]$Name)
        $repo = New-GitRepo $Name
        Write-Utf8 (Join-Path $repo '.gitignore') "/.ai/`n/node_modules/`n/graphify-out/`n"
        Write-Utf8 (Join-Path $repo 'src.ps1') 'function Md {}'
        Add-Commit $repo 'init'
        $graph = New-StaleGraph $repo
        (Get-Item -LiteralPath $graph).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
        return $repo
    }
    $mdRepo = New-MarkdownRepo 'MdStale'
    New-Item -ItemType Directory -Path (Join-Path $mdRepo '.ai') -Force | Out-Null
    $mdFile = Join-Path $mdRepo '.ai\x.md'
    Write-Utf8 $mdFile '# note'
    (Get-Item -LiteralPath $mdFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(20)
    $r = Fire -Cwd $mdRepo
    Check 'an edit in a git-ignored .ai/ newer than the graph blocks once' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block names the Markdown folders and the local update' (
        $r.Out -match 'Markdown the graph covers beyond Git' -and $r.Out -match 'graphify update \.' -and $r.Out -match 'never an external model backend') $r.Out
    $r = Fire -Cwd $mdRepo
    Check 'the same Markdown state does not block twice' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $depRepo = New-MarkdownRepo 'MdDependency'
    New-Item -ItemType Directory -Path (Join-Path $depRepo 'node_modules\pkg') -Force | Out-Null
    $depFile = Join-Path $depRepo 'node_modules\pkg\README.md'
    Write-Utf8 $depFile '# dependency'
    (Get-Item -LiteralPath $depFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(20)
    $r = Fire -Cwd $depRepo
    Check 'a Markdown edit only inside node_modules stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    $capRoot = New-Proj 'MdCap'
    New-Item -ItemType Directory -Path (Join-Path $capRoot 'plans') -Force | Out-Null
    foreach ($i in 1..5) { Write-Utf8 (Join-Path $capRoot ('plans\p' + $i + '.md')) '# p' }
    . (Join-Path (Split-Path -Parent $Hook) '_markdownwork.ps1')
    $capped = Get-MarkdownWorkTime -ProjectRoot $capRoot -MaxFiles 2
    $whole = Get-MarkdownWorkTime -ProjectRoot $capRoot
    Check 'a file-cap hit is reported as Partial, never as a complete scan' ($capped.Partial -and -not $whole.Partial -and $whole.Files -eq 5) (
        'capped=' + $capped.Partial + ' whole=' + $whole.Partial + '/' + $whole.Files)

    Write-Host '--- Graph-Read-Check: a graph built without the Markdown folders ---' -ForegroundColor Cyan
    $readHook = Join-Path (Split-Path -Parent (Split-Path -Parent $Hook)) 'Graph-Read-Check\Graph-Read-Check.ps1'
    function Invoke-ReadCheck {
        param([string]$Cwd, [string]$Session)
        $in = Join-Path $Work ('read-in-' + $Session + '.json'); $out = Join-Path $Work ('read-out-' + $Session + '.txt')
        [System.IO.File]::WriteAllText($in, (@{ session_id = $Session; cwd = $Cwd; hook_event_name = 'SessionStart' } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
        $startArgs = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = ('-NoLogo -NoProfile -File "' + $readHook + '"'); RedirectStandardInput = $in; RedirectStandardOutput = $out; Wait = $true; NoNewWindow = $true; PassThru = $true }
        if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) { $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData } }
        $null = Start-BoundedProcess @startArgs
        return $(if (Test-Path -LiteralPath $out) { [System.IO.File]::ReadAllText($out) } else { '' })
    }
    $readRepo = New-MarkdownRepo 'MdRead'
    New-Item -ItemType Directory -Path (Join-Path $readRepo '.ai') -Force | Out-Null
    Write-Utf8 (Join-Path $readRepo '.ai\memory.md') '# memory'
    $out = Invoke-ReadCheck -Cwd $readRepo -Session 'md-read-1'
    Check 'read-check: a graph without .graphify_build.json gets the one-time set-up line' ($out -match 'built without the git-ignored Markdown folders' -and $out -match 'graphify-markdown\.md') $out
    Write-Utf8 (Join-Path $readRepo 'graphify-out\.graphify_build.json') '{"gitignore": false}'
    $out = Invoke-ReadCheck -Cwd $readRepo -Session 'md-read-2'
    Check 'read-check: {"gitignore": false} removes the line' ($out -match 'GRAPH READ CHECK' -and $out -notmatch 'built without the git-ignored') $out
    $plainRepo = New-GitRepo 'MdNone'
    Write-Utf8 (Join-Path $plainRepo 'a.ps1') 'function A {}'; Add-Commit $plainRepo 'init'
    New-StaleGraph $plainRepo | Out-Null
    $out = Invoke-ReadCheck -Cwd $plainRepo -Session 'md-read-3'
    Check 'read-check: a project without Markdown folders never gets the line' ($out -match 'GRAPH READ CHECK' -and $out -notmatch 'built without the git-ignored') $out

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
