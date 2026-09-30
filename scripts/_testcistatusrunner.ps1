# Test-CiStatusCheck.ps1 scenario block (plan 046 items i and k):
#   i - a runner of THIS project left running after its run finished blocks once
#       with its own stop command; a run still in progress never does; WSL is
#       read only when a distro is already running and is never started;
#   k - a skip-marked documentation-only commit on a verified-green parent gets
#       a note naming that parent, recorded as docs-only-carryover (never
#       ci-green); a code file, no marker, an unverified parent or a branch with
#       required checks keeps today's wait block.
# Dot-sourced by Test-CiStatusCheck.ps1 into the caller's scope (uses its harness,
# gh shim, Set-Mock, New-GitRepo and workspace) - not a standalone suite. The
# fake gh learns the branch-protection endpoint here and forgets it in finally.

function New-PushedCiRepo {
    param([string]$Name)
    $repo = New-GitRepo $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.github\workflows') -Force | Out-Null
    Set-Content (Join-Path $repo '.github\workflows\ci.yml') "on: [push]`njobs:`n  t:`n    runs-on: windows-latest`n    steps: []"
    & git -C $repo add . ; & git -C $repo commit -q -m 'ci'
    & git -C $repo update-ref refs/remotes/origin/main (Get-HeadSha $repo)
    return $repo
}
function Add-PushedCommit {
    param([string]$Repo, [hashtable]$Files, [string]$Message)
    foreach ($k in $Files.Keys) {
        $path = Join-Path $Repo $k
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content $path $Files[$k]
    }
    & git -C $Repo add . ; & git -C $Repo commit -q -m $Message
    & git -C $Repo update-ref refs/remotes/origin/main (Get-HeadSha $Repo)
    return (Get-HeadSha $Repo)
}
function Get-CiStateLines {
    param([string]$Sha)
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'HookMaker\state') -Filter 'CiStatusCheck-*.txt' -File -ErrorAction SilentlyContinue)) {
        $lines = @([System.IO.File]::ReadAllLines($file.FullName))
        if ($lines.Count -gt 0 -and $lines[0].Trim() -eq $Sha) { return $lines }
    }
    return @()
}
function Get-CiNote { param([string]$Out) try { return [string](($Out | ConvertFrom-Json).systemMessage) } catch { return '' } }

$ghShimPath = Join-Path $ShimDir 'gh.ps1'
$ghShimOriginal = [System.IO.File]::ReadAllText($ghShimPath)
$runnerSentinel = $null
try {
    [System.IO.File]::WriteAllText($ghShimPath, (@(
                'if ($args.Count -ge 2 -and $args[0] -eq ''api'' -and [string]$args[1] -match ''/rules/branches/'') {',
                '    $f = Join-Path $env:GH_MOCK_DIR ''rules.json''',
                '    if (Test-Path $f) { Write-Output (Get-Content $f -Raw) } else { Write-Output ''[]'' }; exit 0',
                '}',
                'if ($args.Count -ge 2 -and $args[0] -eq ''api'' -and [string]$args[1] -match ''^repos/[^/]+/[^/]+/branches/[^/]+$'') {',
                '    if (Test-Path (Join-Path $env:GH_MOCK_DIR ''branch_exit.txt'')) { Write-Output ''{"message":"Not Found","status":"404"}''; exit 1 }',
                '    $f = Join-Path $env:GH_MOCK_DIR ''branch.json''',
                '    if (Test-Path $f) { Write-Output (Get-Content $f -Raw) } else { Write-Output ''{"name":"main","protected":false}'' }; exit 0',
                '}') -join "`n") + "`n" + $ghShimOriginal)
    $green = '[{"databaseId":70,"name":"CI","workflowName":"CI","status":"completed","conclusion":"success"}]'

    # =====================================================================
    Write-Host '--- k: a skip-marked docs-only commit on a green parent is a note, never green ---' -ForegroundColor Cyan
    $dr = New-PushedCiRepo 'ci-docsonly'
    $parent = Get-HeadSha $dr
    Set-Mock -RunJson $green
    $null = Fire -HookPath $CiHook -Cwd $dr -EventName 'Stop'
    Check 'k fixture: the parent is recorded ci-green' ((@(Get-CiStateLines $parent) -join '|') -match '\|verified\|.*\|ci-green$') (@(Get-CiStateLines $parent) -join '|')
    $docSha = Add-PushedCommit -Repo $dr -Files @{ 'README.md' = 'docs v2'; 'docs\guide.md' = 'guide' } -Message 'docs: refresh the guide [skip ci]'
    Set-Mock -RunJson '[]'
    $r = Fire -HookPath $CiHook -Cwd $dr -EventName 'Stop'
    $note = Get-CiNote $r.Out
    Check 'k: the docs-only commit gets a note, not a block' ($r.Out -notmatch '"decision"' -and $note -match ('tests verified green on ' + $parent.Substring(0, 7)) -and
        $note -match 'documentation only \(2 file') $r.Out
    $state = @(Get-CiStateLines $docSha)
    Check 'k: recorded as docs-only-carryover naming the parent, never ci-green' (
        $state.Count -ge 5 -and $state[1] -eq 'verified' -and $state[3] -eq 'docs-only-carryover' -and $state[4] -eq $parent) ($state -join '|')
    $r = Fire -HookPath $CiHook -Cwd $dr -EventName 'Stop'
    Check 'k: the note is said once' ([string]::IsNullOrWhiteSpace($r.Out)) $r.Out
    $chainSha = Add-PushedCommit -Repo $dr -Files @{ 'CHANGELOG.md' = 'entry' } -Message 'docs: changelog [ci skip]'
    $r = Fire -HookPath $CiHook -Cwd $dr -EventName 'Stop'
    Check 'k: a second docs-only commit carries the same green parent' ((Get-CiNote $r.Out) -match ('green on ' + $parent.Substring(0, 7))) $r.Out

    foreach ($case in @(
            @{ Name = 'ci-docs-code'; Files = @{ 'README.md' = 'd'; 'tool.ps1' = 'x' }; Message = 'docs and code [skip ci]'; Why = 'a code file' },
            @{ Name = 'ci-docs-nomark'; Files = @{ 'README.md' = 'd' }; Message = 'docs: readme'; Why = 'no skip marker' },
            @{ Name = 'ci-docs-required'; Files = @{ 'README.md' = 'd' }; Message = 'docs: readme [skip ci]'; Why = 'required status checks' },
            @{ Name = 'ci-docs-ruleset'; Files = @{ 'README.md' = 'd' }; Message = 'docs: readme [skip ci]'; Why = 'a ruleset requiring checks' },
            @{ Name = 'ci-docs-unknown'; Files = @{ 'README.md' = 'd' }; Message = 'docs: readme [skip ci]'; Why = 'an unreadable protection answer (404)' },
            @{ Name = 'ci-docs-reqtxt'; Files = @{ 'requirements.txt' = 'x==1' }; Message = 'deps [skip ci]'; Why = 'a requirements.txt' })) {
        $repo = New-PushedCiRepo $case.Name
        Set-Mock -RunJson $green
        $null = Fire -HookPath $CiHook -Cwd $repo -EventName 'Stop'
        $null = Add-PushedCommit -Repo $repo -Files $case.Files -Message $case.Message
        Set-Mock -RunJson '[]'
        if ($case.Why -eq 'required status checks') { Set-Content (Join-Path $MockDir 'branch.json') '{"name":"main","protected":true,"protection":{"required_status_checks":{"enforcement_level":"everyone","contexts":["CI"]}}}' -Encoding utf8 }
        if ($case.Why -eq 'a ruleset requiring checks') { Set-Content (Join-Path $MockDir 'rules.json') '[{"type":"required_status_checks"}]' -Encoding utf8 }
        if ($case.Why -like 'an unreadable*') { Set-Content (Join-Path $MockDir 'branch_exit.txt') '1' }
        $r = Fire -HookPath $CiHook -Cwd $repo -EventName 'Stop'
        Check ('k: ' + $case.Why + ' keeps the wait block') ($r.Out -match '"decision"' -and $r.Out -match 'no runs are registered yet') $r.Out
    }
    $unverified = New-PushedCiRepo 'ci-docs-unverified'
    $null = Add-PushedCommit -Repo $unverified -Files @{ 'README.md' = 'd' } -Message 'docs: readme [skip ci]'
    Set-Mock -RunJson '[]'
    $r = Fire -HookPath $CiHook -Cwd $unverified -EventName 'Stop'
    Check 'k: an unverified parent keeps the wait block' ($r.Out -match '"decision"' -and $r.Out -match 'no runs are registered yet') $r.Out

    # =====================================================================
    Write-Host '--- i: this project''s runner left running after its run finished ---' -ForegroundColor Cyan
    $rr = New-PushedCiRepo 'ci-runner-left'
    $runnerBin = Join-Path $rr '.ci-runner-win\bin'
    New-Item -ItemType Directory -Path $runnerBin -Force | Out-Null
    $fakeListener = Join-Path $runnerBin 'Runner.Listener.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $fakeListener
    $runnerSentinel = Start-Process -FilePath $fakeListener -ArgumentList '-n 120 127.0.0.1' -WindowStyle Hidden -PassThru
    Set-Mock -RunJson '[{"databaseId":71,"name":"CI","workflowName":"CI","status":"in_progress","conclusion":null}]'
    $r = Fire -HookPath $CiHook -Cwd $rr -EventName 'Stop'
    Check 'i: a run still in progress never names the runner' ($r.Out -notmatch 'still running \(pid') $r.Out
    Set-Mock -RunJson $green
    $r = Fire -HookPath $CiHook -Cwd $rr -EventName 'Stop'
    Check 'i: finished run + live runner of this project -> one block with its own stop command' (
        $r.Out -match '"decision"' -and $r.Out -match ('still running \(pid ' + $runnerSentinel.Id) -and $r.Out -match '\.ci-runner-win') $r.Out
    $r = Fire -HookPath $CiHook -Cwd $rr -EventName 'Stop'
    Check 'i: the same runner and commit do not block twice' ($r.Out -notmatch 'still running') $r.Out
    # A Runner.Worker exists only while a job runs: a busy runner is never flagged.
    $fakeWorker = Join-Path $runnerBin 'Runner.Worker.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $fakeWorker
    $workerSentinel = Start-Process -FilePath $fakeWorker -ArgumentList '-n 120 127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        $rrBusy = Add-PushedCommit -Repo $rr -Files @{ 'more.txt' = 'x' } -Message 'more'
        Set-Mock -RunJson $green
        $r = Fire -HookPath $CiHook -Cwd $rr -EventName 'Stop'
        Check 'i: a runner busy with a job (Runner.Worker alive) is not told to stop' ($r.Out -notmatch 'still running') $r.Out
    }
    finally { try { $workerSentinel.Kill(); [void]$workerSentinel.WaitForExit(10000) } catch { } }
    Check 'i: the suite''s fake worker is gone' ($null -eq (Get-Process -Id $workerSentinel.Id -ErrorAction SilentlyContinue))
    try { $runnerSentinel.Kill(); [void]$runnerSentinel.WaitForExit(10000) } catch { }
    Check 'i: the suite''s fake runner is gone' ($null -eq (Get-Process -Id $runnerSentinel.Id -ErrorAction SilentlyContinue))
    $runnerSentinel = $null

    # WSL: read only when a distro already runs; a stopped WSL is never started.
    $wslCase = & {
        . (Join-Path (Split-Path -Parent $CiHook) '_runneralive.ps1')
        $calls = New-Object System.Collections.Generic.List[string]
        $script:WslRunning = $false; $script:WslBusy = $false
        function Test-ManualSelfHostedRepo { param($ProjectRoot) return $true }
        function Invoke-QuietCommand {
            param($FilePath, $ArgumentList, $TimeoutSeconds)
            [void]$calls.Add((@($ArgumentList) -join ' '))
            if ($ArgumentList[0] -eq '--list') { if ($script:WslRunning) { $global:LASTEXITCODE = 0; return @('Ubuntu') }; $global:LASTEXITCODE = 1; return @() }
            if ((@($ArgumentList) -join ' ') -match 'Runner\.Worker') { if ($script:WslBusy) { $global:LASTEXITCODE = 0; return @('555') }; $global:LASTEXITCODE = 1; return @() }
            $global:LASTEXITCODE = 0; return @('4321')
        }
        $stopped = Get-LiveProjectRunner -ProjectRoot (Join-Path $Work 'wsl proj')
        $stoppedPgrep = @($calls | Where-Object { $_ -like '*pgrep*' }).Count
        $script:WslRunning = $true
        $running = Get-LiveProjectRunner -ProjectRoot (Join-Path $Work 'wsl proj')
        $unnamed = @($calls | Where-Object { $_ -like '*pgrep*' -and $_ -notlike '-d Ubuntu -e pgrep*' }).Count
        $script:WslBusy = $true
        $busy = Get-LiveProjectRunner -ProjectRoot (Join-Path $Work 'wsl proj')
        [pscustomobject]@{ StoppedChecked = $stopped.Checked; StoppedPids = @($stopped.Pids).Count; StoppedPgrep = $stoppedPgrep
            RunningPids = @($running.Pids).Count; RunningStop = $running.Stop; Unnamed = $unnamed; BusyPids = @($busy.Pids).Count }
    }
    Check 'i: a stopped WSL is not probed further and holds no live runner' (
        $wslCase.StoppedChecked -and $wslCase.StoppedPids -eq 0 -and $wslCase.StoppedPgrep -eq 0) ($wslCase | ConvertTo-Json -Compress)
    Check 'i: a running WSL is read with pgrep for this project''s /srv/ci/runners/<slug>/ only' (
        $wslCase.RunningPids -eq 1 -and $wslCase.RunningStop -match "wsl.exe -d Ubuntu -e pkill -f '/srv/ci/runners/wsl-proj/'") ($wslCase | ConvertTo-Json -Compress)
    Check 'i: every WSL probe names a running distribution - the default one is never booted' ($wslCase.Unnamed -eq 0) ($wslCase | ConvertTo-Json -Compress)
    Check 'i: a WSL runner with a Runner.Worker is busy with a job and never flagged' ($wslCase.BusyPids -eq 0) ($wslCase | ConvertTo-Json -Compress)
}
finally {
    [System.IO.File]::WriteAllText($ghShimPath, $ghShimOriginal)
    if ($null -ne $runnerSentinel) { try { $runnerSentinel.Kill(); [void]$runnerSentinel.WaitForExit(10000) } catch { } }
}
