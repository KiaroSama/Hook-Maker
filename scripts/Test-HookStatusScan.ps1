# Offline test suite for Get-HookStatus.ps1's TRAVERSAL and PERSISTENCE: how the
# walk reaches hooks, what it refuses to follow, what it survives, and what it
# writes.
#
# Parsing is covered by Test-HookStatusDiscovery.ps1; everything here is about
# getting to the evidence and recording it safely.
#
# Covers: an arbitrary ancestor root finds nested hooks; a direct runtime subtree
# finds the NEAREST related settings by bounded upward lookup; a deeply nested
# tree; access-denied isolated to one directory; a disappearing directory
# isolated; a reparse/junction loop never followed; canonical duplicate paths
# deduplicated; NO default depth cap (and -MaxDepth proving the knob is the only
# thing that caps it); and a full-drive-shaped fixture - hundreds of unrelated
# folders, nested projects, a permission hole, Claude/Codex/Git hooks at
# different depths - scanned from its root with no depth hint.
#
# Persistence: -NoPersist writes nothing; a successful scan persists and updates
# in place on rescan; a failed scan leaves the registry byte-identical; managed
# records are never touched; partial coverage persists but never claims
# completeness.
#
# NEVER scans a real drive or a real user home - temp fixtures only.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-HookStatusScan.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$Scanner = Join-Path $ScriptRoot 'Get-HookStatus.ps1'
if (-not (Test-Path -LiteralPath $Scanner -PathType Leaf)) {
    Write-Host "Required script not found: $Scanner" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 800
. (Join-Path $ScriptRoot '_testlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-statusscan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedStateDir = $env:HOOKMAKER_STATE_DIR
$StateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $StateDir
$RegistryPath = Join-Path $StateDir 'install-registry.json'

# Tracked so cleanup can always undo them, even on an early failure.
$script:DeniedDirectories = New-Object System.Collections.Generic.List[string]
$script:Junctions = New-Object System.Collections.Generic.List[string]

function New-Dir { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path }
function Write-Utf8 {
    param([string]$Path, [string]$Content)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

# One Claude registration pointing at a real script inside the given project.
function New-ClaudeHook {
    param([string]$ProjectRoot, [string]$HookName, [string]$SettingsLeaf = 'settings.local.json')
    $target = Join-Path (New-Dir (Join-Path $ProjectRoot 'hookscripts')) ($HookName + '.ps1')
    Write-Utf8 -Path $target -Content ('# ' + $HookName)
    $settings = Join-Path $ProjectRoot ('.claude\' + $SettingsLeaf)
    Write-Utf8 -Path $settings -Content (@{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $target + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    return $target
}
function New-CodexHook {
    param([string]$ProjectRoot, [string]$HookName)
    $target = Join-Path (New-Dir (Join-Path $ProjectRoot 'hookscripts')) ($HookName + '.ps1')
    Write-Utf8 -Path $target -Content ('# ' + $HookName)
    Write-Utf8 -Path (Join-Path $ProjectRoot '.codex\hooks.json') -Content (@{
        hooks = @{ Stop = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $target + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    return $target
}
function New-GitHookRepo {
    param([string]$RepositoryRoot, [string]$HookName = 'pre-push')
    Write-Utf8 -Path (Join-Path $RepositoryRoot ('.git\hooks\' + $HookName)) -Content "#!/bin/sh`necho hook`n"
    return $RepositoryRoot
}

function Invoke-Scan {
    param([string]$Root, [switch]$IncludeGlobal, [switch]$Persist, [int]$MaxDepth = 0, [switch]$Async, [hashtable]$Environment)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $resultPath = Join-Path $Work ("result-$token.json")
    $outFile = Join-Path $Work ("out-$token.txt")
    $errFile = Join-Path $Work ("err-$token.txt")
    $argLine = '-NoLogo -NoProfile -File "' + $Scanner + '" -ScanRoot "' + $Root + '" -ToolRoot "' + $ToolRoot +
        '" -ResultPath "' + $resultPath + '"'
    if (-not $Persist) { $argLine += ' -NoPersist' }
    if ($IncludeGlobal) { $argLine += ' -IncludeGlobal' }
    if ($MaxDepth -gt 0) { $argLine += ' -MaxDepth ' + $MaxDepth }
    $startArgs = @{
        FilePath = (Get-Process -Id $PID).Path; ArgumentList = $argLine
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        NoNewWindow = $true; PassThru = $true; WorkingDirectory = $Work
    }
    if (-not $Async) { $startArgs.Wait = $true }
    $environmentToUse = @{ HOOKMAKER_STATE_DIR = $env:HOOKMAKER_STATE_DIR }
    if ($null -ne $Environment) { foreach ($k in $Environment.Keys) { $environmentToUse[$k] = $Environment[$k] } }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) { $startArgs.Environment = $environmentToUse }
    $process = Start-Process @startArgs
    if ($Async) { return [pscustomobject]@{ Process = $process; ResultPath = $resultPath; ErrFile = $errFile } }
    $document = $null
    if (Test-Path -LiteralPath $resultPath) { $document = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    return [pscustomobject]@{ Exit = $process.ExitCode; Result = $document; Err = $err; ResultPath = $resultPath }
}

function Test-FoundTarget {
    param($Result, [string]$Fragment)
    if ($null -eq $Result) { return $false }
    foreach ($finding in @($Result.findings)) {
        foreach ($client in @($finding.clients)) {
            foreach ($target in @($client.parsedTargets)) { if ([string]$target -like ('*' + $Fragment + '*')) { return $true } }
        }
        if ($null -ne $finding.nativeGit -and [string]$finding.nativeGit.hookPath -like ('*' + $Fragment + '*')) { return $true }
    }
    return $false
}

function Deny-Directory {
    param([string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    try { & icacls $Path /deny ($identity + ':(OI)(CI)(RX)') *> $null } catch { return $false }
    [void]$script:DeniedDirectories.Add($Path)
    try { [void][System.IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator().MoveNext(); return $false }
    catch { return $true }
}

try {
    # =====================================================================
    # Traversal
    # =====================================================================
    Write-Host '--- an arbitrary ancestor root finds nested hooks ---' -ForegroundColor Cyan
    $ancestor = New-Dir (Join-Path $Work 'Ancestor')
    $nested = New-Dir (Join-Path $ancestor 'team\group\projects\WebApp')
    New-ClaudeHook -ProjectRoot $nested -HookName 'ZZZ-Nested-Claude' | Out-Null
    New-CodexHook -ProjectRoot (New-Dir (Join-Path $ancestor 'team\other\ApiApp')) -HookName 'ZZZ-Nested-Codex' | Out-Null
    New-GitHookRepo -RepositoryRoot (New-Dir (Join-Path $ancestor 'team\group\projects\WebApp')) | Out-Null

    $scan = Invoke-Scan -Root $ancestor
    Check 'a scan from an arbitrary ancestor exits 0' ($scan.Exit -eq 0) $scan.Err
    Check 'a deeply nested Claude hook is found from the ancestor' (Test-FoundTarget -Result $scan.Result -Fragment 'ZZZ-Nested-Claude.ps1')
    Check 'a deeply nested Codex hook is found from the ancestor' (Test-FoundTarget -Result $scan.Result -Fragment 'ZZZ-Nested-Codex.ps1')
    Check 'a nested native git hook is found from the ancestor' (Test-FoundTarget -Result $scan.Result -Fragment 'pre-push')
    Check 'a complete scan reports complete coverage' ($scan.Result.coverage.complete -eq $true) (
        (@($scan.Result.coverage.inaccessible) + @($scan.Result.coverage.skippedReparse)) -join ',')

    Write-Host '--- a direct runtime subtree finds the nearest related settings ---' -ForegroundColor Cyan
    $direct = New-Dir (Join-Path $Work 'DirectProject')
    $directRuntime = New-Dir (Join-Path $direct '.claude\hooks\Hook-Maker\ZZZ-Direct')
    $directScript = Join-Path $directRuntime 'ZZZ-Direct.ps1'
    Write-Utf8 -Path $directScript -Content '# direct runtime'
    Write-Utf8 -Path (Join-Path $direct '.claude\settings.local.json') -Content (@{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $directScript + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    New-GitHookRepo -RepositoryRoot $direct -HookName 'pre-commit' | Out-Null

    # -ScanRoot IS the runtime folder: only an upward lookup can find the
    # registration that names it.
    $directScan = Invoke-Scan -Root (Join-Path $direct '.claude\hooks\Hook-Maker')
    Check 'scanning a runtime subtree exits 0' ($directScan.Exit -eq 0) $directScan.Err
    Check 'scanning ...\.claude\hooks\Hook-Maker still finds its Claude registration' (
        Test-FoundTarget -Result $directScan.Result -Fragment 'ZZZ-Direct.ps1') (
        ($directScan.Result | ConvertTo-Json -Depth 6))
    Check 'the upward lookup also reaches the enclosing git repository' (
        [int]$directScan.Result.counts.gitRepositories -eq 1) ([string]$directScan.Result.counts.gitRepositories)
    Check 'the upward lookup does not wander outside into sibling projects' (
        -not (Test-FoundTarget -Result $directScan.Result -Fragment 'ZZZ-Nested-Claude.ps1'))
    Check 'the registration found upward is recorded exactly once' (
        @(@($directScan.Result.findings) | Where-Object { @($_.clients).Count -gt 0 }).Count -eq 1)

    Write-Host '--- no default depth cap ---' -ForegroundColor Cyan
    $deepRoot = New-Dir (Join-Path $Work 'DeepTree')
    $deep = $deepRoot
    for ($i = 1; $i -le 30; $i++) { $deep = New-Dir (Join-Path $deep ('level' + $i)) }
    New-ClaudeHook -ProjectRoot $deep -HookName 'ZZZ-Deep-30' | Out-Null

    $deepScan = Invoke-Scan -Root $deepRoot
    Check 'a 30-level deep hook is found with NO depth hint' (
        Test-FoundTarget -Result $deepScan.Result -Fragment 'ZZZ-Deep-30.ps1') (
        'directories=' + [string]$deepScan.Result.counts.directories)
    $cappedScan = Invoke-Scan -Root $deepRoot -MaxDepth 3
    Check '-MaxDepth 3 does NOT reach the 30-level hook (the cap is opt-in only)' (
        -not (Test-FoundTarget -Result $cappedScan.Result -Fragment 'ZZZ-Deep-30.ps1'))
    Check 'a depth-capped scan never claims complete coverage' ($cappedScan.Result.coverage.complete -eq $false)
    Check 'a depth-capped scan reports partial' ([string]$cappedScan.Result.overall -eq 'partial')

    Write-Host '--- an unreadable directory is isolated, never fatal ---' -ForegroundColor Cyan
    $permRoot = New-Dir (Join-Path $Work 'PermRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $permRoot 'before')) -HookName 'ZZZ-Before-Denied' | Out-Null
    $denied = New-Dir (Join-Path $permRoot 'denied-subtree')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $denied 'hidden')) -HookName 'ZZZ-Inside-Denied' | Out-Null
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $permRoot 'zafter')) -HookName 'ZZZ-After-Denied' | Out-Null
    $enforced = Deny-Directory -Path $denied

    $permScan = Invoke-Scan -Root $permRoot
    Check 'a scan containing an unreadable directory still exits 0' ($permScan.Exit -eq 0) $permScan.Err
    Check 'hooks before the unreadable directory are still found' (Test-FoundTarget -Result $permScan.Result -Fragment 'ZZZ-Before-Denied.ps1')
    Check 'hooks after the unreadable directory are still found' (Test-FoundTarget -Result $permScan.Result -Fragment 'ZZZ-After-Denied.ps1')
    if ($enforced) {
        Check 'the unreadable directory is recorded in coverage.inaccessible' (
            @(@($permScan.Result.coverage.inaccessible) | Where-Object { $_ -like '*denied-subtree*' }).Count -ge 1) (
            (@($permScan.Result.coverage.inaccessible)) -join ',')
        Check 'a scan with an unreadable directory never claims complete coverage' ($permScan.Result.coverage.complete -eq $false)
        Check 'a scan with an unreadable directory reports partial' ([string]$permScan.Result.overall -eq 'partial')
    }
    else {
        Write-Host '[SKIP] deny ACL was not enforceable for this account; inaccessible-path assertions skipped' -ForegroundColor Yellow
    }

    Write-Host '--- a directory that disappears mid-scan is isolated ---' -ForegroundColor Cyan
    # A genuine race: a large tree is scanned while a subtree is deleted under
    # it. Whether or not the race lands, the invariant asserted is the same one
    # the deterministic access-denied fixture above proves - a directory the
    # walk cannot read must never abort the run.
    $raceRoot = New-Dir (Join-Path $Work 'RaceRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $raceRoot 'keep')) -HookName 'ZZZ-Race-Keep' | Out-Null
    $doomed = New-Dir (Join-Path $raceRoot 'zdoomed')
    for ($i = 0; $i -lt 60; $i++) { New-Dir (Join-Path $doomed ('filler' + $i + '\a\b\c')) | Out-Null }
    $async = Invoke-Scan -Root $raceRoot -Async
    Remove-Item -LiteralPath $doomed -Recurse -Force -ErrorAction SilentlyContinue
    $async.Process.WaitForExit()
    $raceResult = $null
    if (Test-Path -LiteralPath $async.ResultPath) { $raceResult = [System.IO.File]::ReadAllText($async.ResultPath) | ConvertFrom-Json }
    Check 'a directory vanishing mid-scan does not fail the run' ($async.Process.ExitCode -eq 0) (
        $(if (Test-Path -LiteralPath $async.ErrFile) { [System.IO.File]::ReadAllText($async.ErrFile) } else { '' }))
    Check 'the surviving hook is still reported after a mid-scan deletion' (Test-FoundTarget -Result $raceResult -Fragment 'ZZZ-Race-Keep.ps1')

    Write-Host '--- reparse points are never followed ---' -ForegroundColor Cyan
    $loopRoot = New-Dir (Join-Path $Work 'LoopRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $loopRoot 'real')) -HookName 'ZZZ-Loop-Real' | Out-Null
    $junction = Join-Path $loopRoot 'loop-back'
    $junctionCreated = $false
    if ($IsWindows) {
        # A junction pointing at its own ancestor: following it is an infinite
        # tree. Directory junctions do not require elevation.
        & cmd.exe /c ('mklink /J "' + $junction + '" "' + $loopRoot + '"') *> $null
        $junctionCreated = (Test-Path -LiteralPath $junction)
        if ($junctionCreated) { [void]$script:Junctions.Add($junction) }
    }
    if ($junctionCreated) {
        $loopScan = Invoke-Scan -Root $loopRoot
        Check 'a junction loop does not hang or fail the scan' ($loopScan.Exit -eq 0) $loopScan.Err
        Check 'the junction is recorded as skipped, not traversed' (
            @(@($loopScan.Result.coverage.skippedReparse) | Where-Object { $_ -like '*loop-back*' }).Count -eq 1) (
            (@($loopScan.Result.coverage.skippedReparse)) -join ',')
        Check 'the real hook beside the junction is still found' (Test-FoundTarget -Result $loopScan.Result -Fragment 'ZZZ-Loop-Real.ps1')
        Check 'a scan that skipped a reparse point never claims complete coverage' ($loopScan.Result.coverage.complete -eq $false)
        Check 'the hook is reported exactly once, not once per loop iteration' (
            @(@($loopScan.Result.findings) | Where-Object { @($_.clients).Count -gt 0 }).Count -eq 1)
    }
    else {
        Write-Host '[SKIP] junction could not be created on this platform/account' -ForegroundColor Yellow
    }

    Write-Host '--- canonical duplicate paths are deduplicated ---' -ForegroundColor Cyan
    $dupRoot = New-Dir (Join-Path $Work 'DupRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $dupRoot 'Proj')) -HookName 'ZZZ-Dup' | Out-Null
    $straight = Invoke-Scan -Root $dupRoot
    # Same directory, spelled with a redundant .\ segment, a trailing separator,
    # a walk back up through .., and different casing.
    $noisy = Invoke-Scan -Root ((Join-Path $dupRoot '.\Proj\..\') + '\')
    Check 'a noisily-spelled root canonicalizes to the same scan' (
        @($straight.Result.findings).Count -eq @($noisy.Result.findings).Count -and @($noisy.Result.findings).Count -eq 1) (
        'straight=' + @($straight.Result.findings).Count + ' noisy=' + @($noisy.Result.findings).Count)
    Check 'a canonicalized rescan produces the same record id' (
        [string]@($straight.Result.findings)[0].id -eq [string]@($noisy.Result.findings)[0].id)
    $upperScan = Invoke-Scan -Root $dupRoot.ToUpperInvariant()
    Check 'an upper-cased root produces the same record id (case-insensitive keys)' (
        [string]@($upperScan.Result.findings)[0].id -eq [string]@($straight.Result.findings)[0].id)

    Write-Host '--- a full-drive-shaped fixture ---' -ForegroundColor Cyan
    # Hundreds of unrelated folders, nested projects, a permission hole and
    # hooks planted at four different depths - scanned from the root with no
    # depth hint, exactly as a real drive scan would be.
    $drive = New-Dir (Join-Path $Work 'FakeDrive')
    foreach ($top in @('Program Files', 'Users', 'Windows', 'Dev', 'Temp')) {
        $topDir = New-Dir (Join-Path $drive $top)
        for ($i = 0; $i -lt 12; $i++) {
            $branch = New-Dir (Join-Path $topDir ('pkg' + $i + '\src\lib\internal'))
            Write-Utf8 -Path (Join-Path $branch 'readme.txt') -Content 'unrelated'
            Write-Utf8 -Path (Join-Path $branch 'data.json') -Content '{"unrelated":true}'
        }
    }
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $drive 'Dev\Shallow')) -HookName 'ZZZ-Drive-Depth2' | Out-Null
    New-CodexHook -ProjectRoot (New-Dir (Join-Path $drive 'Users\me\code\Mid')) -HookName 'ZZZ-Drive-Depth4' | Out-Null
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $drive 'Program Files\a\b\c\d\e\Deep')) -HookName 'ZZZ-Drive-Depth7' -SettingsLeaf 'settings.json' | Out-Null
    New-GitHookRepo -RepositoryRoot (New-Dir (Join-Path $drive 'Windows\x\y\Repo')) -HookName 'pre-push' | Out-Null
    # A nested project INSIDE another project.
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $drive 'Dev\Shallow\vendor\Inner')) -HookName 'ZZZ-Drive-Nested' | Out-Null
    $driveDenied = New-Dir (Join-Path $drive 'Windows\System32-ish')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $driveDenied 'unreachable')) -HookName 'ZZZ-Drive-Unreachable' | Out-Null
    $driveEnforced = Deny-Directory -Path $driveDenied

    $driveScan = Invoke-Scan -Root $drive
    Check 'the drive-shaped scan exits 0' ($driveScan.Exit -eq 0) $driveScan.Err
    Check 'it inspected a realistic number of directories' ([int]$driveScan.Result.counts.directories -gt 200) (
        [string]$driveScan.Result.counts.directories)
    foreach ($expected in @('ZZZ-Drive-Depth2.ps1', 'ZZZ-Drive-Depth4.ps1', 'ZZZ-Drive-Depth7.ps1', 'ZZZ-Drive-Nested.ps1')) {
        Check ('every reachable hook is found with no depth hint: ' + $expected) (
            Test-FoundTarget -Result $driveScan.Result -Fragment $expected)
    }
    Check 'the nested git repository is found too' ([int]$driveScan.Result.counts.gitRepositories -ge 1)
    Check 'a nested project inside another project is a SEPARATE record' (
        @(@($driveScan.Result.findings) | Where-Object { @($_.clients).Count -gt 0 }).Count -ge 4) (
        [string]@($driveScan.Result.findings).Count)
    if ($driveEnforced) {
        Check 'a hook behind a permission hole is honestly not reported' (
            -not (Test-FoundTarget -Result $driveScan.Result -Fragment 'ZZZ-Drive-Unreachable.ps1'))
        Check 'and the drive scan is reported as partial, not complete' (
            $driveScan.Result.coverage.complete -eq $false -and [string]$driveScan.Result.overall -eq 'partial')
    }

    # =====================================================================
    # Persistence
    # =====================================================================
    Write-Host '--- persistence ---' -ForegroundColor Cyan
    New-Dir $StateDir | Out-Null
    # A pre-existing MANAGED record: a scan must never modify or drop it.
    $managedRegistry = @{
        version = 3
        installs = @(@{
            id = 'zzz-managed-fixture'; friendlyName = 'ZZZ Managed Fixture'; schema = 2
            recordType = 'managed'; origin = 'hookMaker'; hookType = 'CustomHook'; scope = 'project'
            targetProjectRoot = $Work; sourceScript = 'x.ps1'; sourceDir = $Work
            clients = @{}; createdUtc = '2020-01-01T00:00:00.0000000Z'
        })
    }
    Write-Utf8 -Path $RegistryPath -Content ($managedRegistry | ConvertTo-Json -Depth 20)
    $beforeBytes = [System.IO.File]::ReadAllBytes($RegistryPath)

    $noPersistScan = Invoke-Scan -Root $ancestor
    Check '-NoPersist leaves the registry byte-identical' (
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$beforeBytes, [byte[]][System.IO.File]::ReadAllBytes($RegistryPath)))
    Check '-NoPersist still reports findings' (@($noPersistScan.Result.findings).Count -gt 0)
    Check '-NoPersist reports no records added' ([int]$noPersistScan.Result.recordsAdded -eq 0)

    $failScan = Invoke-Scan -Root (Join-Path $Work 'no-such-directory-at-all') -Persist
    Check 'a failed scan exits non-zero' ($failScan.Exit -ne 0)
    Check 'a failed scan writes a result document with overall=failed' (
        $null -ne $failScan.Result -and [string]$failScan.Result.overall -eq 'failed') (
        $(if ($null -ne $failScan.Result) { [string]$failScan.Result.overall } else { 'no document' }))
    Check 'a failed scan leaves the registry byte-identical' (
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$beforeBytes, [byte[]][System.IO.File]::ReadAllBytes($RegistryPath)))

    $persistScan = Invoke-Scan -Root $ancestor -Persist
    Check 'a successful scan exits 0' ($persistScan.Exit -eq 0) $persistScan.Err
    Check 'a successful scan reports records added' ([int]$persistScan.Result.recordsAdded -gt 0) (
        [string]$persistScan.Result.recordsAdded)
    $registry = [System.IO.File]::ReadAllText($RegistryPath) | ConvertFrom-Json
    $discovered = @(@($registry.installs) | Where-Object { $null -ne $_.PSObject.Properties['recordType'] -and [string]$_.recordType -eq 'discovered' })
    Check 'discovered records land in the registry' ($discovered.Count -eq @($persistScan.Result.findings).Count) (
        'registry=' + $discovered.Count + ' findings=' + @($persistScan.Result.findings).Count)
    $managedAfter = @(@($registry.installs) | Where-Object { [string]$_.id -eq 'zzz-managed-fixture' })
    # createdUtc is compared as an INSTANT, not as text: Read-InstallRegistryState
    # parses JSON with ConvertFrom-Json, which turns an ISO timestamp into a
    # [DateTime], so every registry writer in this project re-serializes it in
    # .NET's round-trip form. The instant is preserved; only the spelling changes.
    Check 'the pre-existing managed record survives untouched' (
        $managedAfter.Count -eq 1 -and
        [string]$managedAfter[0].friendlyName -eq 'ZZZ Managed Fixture' -and
        [string]$managedAfter[0].recordType -eq 'managed' -and
        [string]$managedAfter[0].sourceScript -eq 'x.ps1' -and
        ([datetime]$managedAfter[0].createdUtc).ToUniversalTime() -eq ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime()) (
        $(if ($managedAfter.Count -eq 1) { ($managedAfter[0] | ConvertTo-Json -Depth 4) } else { 'count=' + $managedAfter.Count }))
    Check 'every discovered record carries origin=statusScan' (
        @(@($discovered) | Where-Object { [string]$_.origin -ne 'statusScan' }).Count -eq 0)
    Check 'no discovered record stores a raw command string' (
        ([System.IO.File]::ReadAllText($RegistryPath)) -notlike '*pwsh -File*')

    $firstSeen = [string]@($discovered)[0].firstSeenUtc
    Start-Sleep -Milliseconds 20
    $rescan = Invoke-Scan -Root $ancestor -Persist
    $registry2 = [System.IO.File]::ReadAllText($RegistryPath) | ConvertFrom-Json
    $discovered2 = @(@($registry2.installs) | Where-Object { $null -ne $_.PSObject.Properties['recordType'] -and [string]$_.recordType -eq 'discovered' })
    Check 'a rescan updates in place instead of duplicating' ($discovered2.Count -eq $discovered.Count) (
        'first=' + $discovered.Count + ' second=' + $discovered2.Count)
    Check 'a rescan reports updates, not additions' (
        [int]$rescan.Result.recordsAdded -eq 0 -and [int]$rescan.Result.recordsUpdated -gt 0) (
        'added=' + [string]$rescan.Result.recordsAdded + ' updated=' + [string]$rescan.Result.recordsUpdated)
    $matching = @(@($discovered2) | Where-Object { [string]$_.id -eq [string]@($discovered)[0].id })
    Check 'firstSeenUtc is set once and never overwritten' (
        $matching.Count -eq 1 -and [string]$matching[0].firstSeenUtc -eq $firstSeen) (
        $(if ($matching.Count -eq 1) { [string]$matching[0].firstSeenUtc + ' vs ' + $firstSeen } else { 'count=' + $matching.Count }))
    Check 'lastSeenUtc is refreshed by the rescan' (
        $matching.Count -eq 1 -and [string]$matching[0].lastSeenUtc -ne $firstSeen)

    # A record whose evidence lives under an inaccessible subtree must NOT be
    # demoted to notSeen by a later partial scan.
    if ($enforced) {
        Invoke-Scan -Root $permRoot -Persist | Out-Null
        $permRegistry = [System.IO.File]::ReadAllText($RegistryPath) | ConvertFrom-Json
        $notSeen = @(@($permRegistry.installs) | Where-Object {
            $null -ne $_.PSObject.Properties['status'] -and [string]$_.status -eq 'notSeen' })
        Check 'a partial scan never marks a record under an inaccessible subtree as notSeen' (
            @(@($notSeen) | Where-Object { [string]$_.friendlyName -like '*Inside-Denied*' }).Count -eq 0)
        Check 'a partial scan still persists what it verified' (
            @(@($permRegistry.installs) | Where-Object {
                $null -ne $_.PSObject.Properties['friendlyName'] -and [string]$_.friendlyName -like '*Before-Denied*' }).Count -eq 1)
    }

    # A record from an earlier scan of the SAME roots that is genuinely gone is
    # the only case that may be demoted.
    $gone = New-Dir (Join-Path $Work 'GoneRoot')
    New-ClaudeHook -ProjectRoot (New-Dir (Join-Path $gone 'Proj')) -HookName 'ZZZ-Will-Vanish' | Out-Null
    Invoke-Scan -Root $gone -Persist | Out-Null
    Remove-Item -LiteralPath (Join-Path $gone 'Proj\.claude') -Recurse -Force
    Invoke-Scan -Root $gone -Persist | Out-Null
    $goneRegistry = [System.IO.File]::ReadAllText($RegistryPath) | ConvertFrom-Json
    $vanished = @(@($goneRegistry.installs) | Where-Object {
        $null -ne $_.PSObject.Properties['friendlyName'] -and [string]$_.friendlyName -like '*Will-Vanish*' })
    Check 'a covered record that is genuinely gone is demoted to notSeen' (
        $vanished.Count -eq 1 -and [string]$vanished[0].status -eq 'notSeen') (
        $(if ($vanished.Count -eq 1) { [string]$vanished[0].status } else { 'count=' + $vanished.Count }))

    Write-Host '--- -IncludeGlobal ---' -ForegroundColor Cyan
    # A fake user home, so no real Claude/Codex settings are ever touched.
    $fakeHome = New-Dir (Join-Path $Work 'FakeHome')
    $globalTarget = Join-Path (New-Dir (Join-Path $fakeHome 'globalhooks')) 'ZZZ-Global.ps1'
    Write-Utf8 -Path $globalTarget -Content '# global hook'
    Write-Utf8 -Path (Join-Path $fakeHome '.claude\settings.json') -Content (@{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $globalTarget + '"') }) }) }
    } | ConvertTo-Json -Depth 20)
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $globalEnv = @{ USERPROFILE = $fakeHome; HOME = $fakeHome; HOMEDRIVE = ''; HOMEPATH = '' }
        $withoutGlobal = Invoke-Scan -Root $ancestor -Environment $globalEnv
        Check 'without -IncludeGlobal the global settings file is not read' (
            -not (Test-FoundTarget -Result $withoutGlobal.Result -Fragment 'ZZZ-Global.ps1'))
        $withGlobal = Invoke-Scan -Root $ancestor -IncludeGlobal -Environment $globalEnv
        Check '-IncludeGlobal reads the canonical current-user settings file' (
            Test-FoundTarget -Result $withGlobal.Result -Fragment 'ZZZ-Global.ps1') (
            (@($withGlobal.Result.scanRoots)) -join ',')
        Check 'the global finding is scoped global, not project' (
            @(@($withGlobal.Result.findings) | Where-Object {
                [string]$_.scope -eq 'global' -and [string]$_.friendlyName -like '*ZZZ-Global*' }).Count -eq 1)
        # The same home, but INSIDE the scanned root: the global root must not be
        # added a second time.
        $insideHome = New-Dir (Join-Path $ancestor 'InsideHome')
        Write-Utf8 -Path (Join-Path $insideHome '.claude\settings.json') -Content (@{
            hooks = @{ Stop = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $globalTarget + '"') }) }) }
        } | ConvertTo-Json -Depth 20)
        $insideScan = Invoke-Scan -Root $ancestor -IncludeGlobal -Environment @{ USERPROFILE = $insideHome; HOME = $insideHome; HOMEDRIVE = ''; HOMEPATH = '' }
        Check 'a global root already inside the scan root is not scanned twice' (
            @($insideScan.Result.scanRoots).Count -eq 1) ((@($insideScan.Result.scanRoots)) -join ',')
        Check 'and its settings file is still reported exactly once' (
            @(@($insideScan.Result.findings) | Where-Object {
                @(@($_.clients) | Where-Object { [string]$_.settingsPath -like '*InsideHome*' }).Count -gt 0 }).Count -eq 1)

        Write-Host '--- declining -IncludeGlobal is honored on EVERY code path ---' -ForegroundColor Cyan
        # Regression: the direct-subtree lookup used to reach the canonical
        # global settings files even when the user had just declined them,
        # because only the scan-root list was gated. A declined global scan must
        # mean no global settings file is opened at all - while the genuine
        # direct-subtree feature keeps working for the PROJECT.
        $homeProject = New-Dir (Join-Path $fakeHome 'projects\App')
        $homeProjectTarget = Join-Path (New-Dir (Join-Path $homeProject 'hookscripts')) 'ZZZ-HomeProject.ps1'
        Write-Utf8 -Path $homeProjectTarget -Content '# project inside the home directory'
        Write-Utf8 -Path (Join-Path $homeProject '.claude\settings.local.json') -Content (@{
            hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $homeProjectTarget + '"') }) }) }
        } | ConvertTo-Json -Depth 20)
        $homeRuntime = New-Dir (Join-Path $homeProject '.claude\hooks\Hook-Maker\ZZZ-HomeProject')

        $subtreeNoGlobal = Invoke-Scan -Root $homeRuntime -Environment $globalEnv
        Check 'a subtree scan under the home still finds its PROJECT registration' (
            Test-FoundTarget -Result $subtreeNoGlobal.Result -Fragment 'ZZZ-HomeProject.ps1') (
            ($subtreeNoGlobal.Result | ConvertTo-Json -Depth 6))
        Check 'without -IncludeGlobal a subtree scan never reads the global settings file' (
            -not (Test-FoundTarget -Result $subtreeNoGlobal.Result -Fragment 'ZZZ-Global.ps1'))
        Check 'and it reports no global-scoped finding at all' (
            @(@($subtreeNoGlobal.Result.findings) | Where-Object { [string]$_.scope -eq 'global' }).Count -eq 0)

        $subtreeWithGlobal = Invoke-Scan -Root $homeRuntime -IncludeGlobal -Environment $globalEnv
        Check 'with -IncludeGlobal the same subtree scan DOES read the global settings file' (
            Test-FoundTarget -Result $subtreeWithGlobal.Result -Fragment 'ZZZ-Global.ps1')

        # The home directory itself as the scan root: the downward walk would
        # otherwise open the global file on its way past.
        $homeRootScan = Invoke-Scan -Root $fakeHome -Environment $globalEnv
        Check 'scanning the home directory without -IncludeGlobal skips the global settings file' (
            -not (Test-FoundTarget -Result $homeRootScan.Result -Fragment 'ZZZ-Global.ps1')) (
            ((@($homeRootScan.Result.findings) | ForEach-Object { [string]$_.friendlyName }) -join ','))
        Check 'but a project inside the home directory is still discovered' (
            Test-FoundTarget -Result $homeRootScan.Result -Fragment 'ZZZ-HomeProject.ps1')
    }
    else {
        Write-Host '[SKIP] Start-Process -Environment unavailable; -IncludeGlobal assertions skipped' -ForegroundColor Yellow
    }
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedStateDir
    # Undo permission and reparse fixtures FIRST, or the workspace cannot be
    # removed and the next run inherits the mess.
    foreach ($path in $script:DeniedDirectories) {
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            & icacls $path /remove:d $identity *> $null
            & icacls $path /grant ($identity + ':(OI)(CI)F') *> $null
        }
        catch { }
    }
    foreach ($path in $script:Junctions) {
        # Delete the LINK, never its contents.
        try { [System.IO.Directory]::Delete($path) } catch { }
    }
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { } }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
        if (Test-Path -LiteralPath $Work) {
            Write-Host ('WARNING: workspace could not be fully removed: ' + $Work) -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
