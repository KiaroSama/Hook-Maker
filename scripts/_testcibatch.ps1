# Package-private transport seam; the parent suite owns the guarded process.
# One shim/workspace, no network, no arbitrary sleeps, bounded child barriers.
function Invoke-CiApiBatchRegression {
    param([string]$HooksRoot,[switch]$SmokeOnly)
    $package = Join-Path $HooksRoot 'Ci-Status-Check'
    if (-not (Test-Path -LiteralPath (Join-Path $package '_cibatch.ps1'))) {
        Check 'CI API batch transport exists' $false
        return
    }
    . (Join-Path $HooksRoot '_processlib.ps1')
    . (Join-Path $HooksRoot '_processtree.ps1')
    . (Join-Path $package '_ghbudget.ps1')
    . (Join-Path $package '_cibatch.ps1')
    $work = New-TestWorkspace 'ci-api-batch'
    $savedPath = $env:PATH; $savedFixture = $env:HM_CI_BATCH_FIXTURE; $savedReady=$env:HM_CI_BATCH_READY
    $env:HM_CI_BATCH_READY='Local\HmCiBatchReady'+[guid]::NewGuid().ToString('N')
    $ready=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,$env:HM_CI_BATCH_READY)
    $savedHookDeadline = Get-Variable HookDeadlineUtc -Scope Script -ErrorAction SilentlyContinue
    $script:HookDeadlineUtc = [DateTime]::MaxValue
    $shim = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
$root = $env:HM_CI_BATCH_FIXTURE
if ($Rest.Count -ne 2 -or $Rest[0] -ne 'api') { exit 91 }
$id = [int](($Rest[1] -split '\?')[0] -split '/')[-1]
$utf8 = New-Object Text.UTF8Encoding($false,$true)
$identity = [string]$PID + '|' + (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
[IO.File]::WriteAllText((Join-Path $root ('start-' + $PID)), ([string]$id + '|' + $identity + '|' + [DateTime]::UtcNow.Ticks), $utf8)
[Console]::OutputEncoding = $utf8
if ($id -ge 100) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-ChildItem -LiteralPath $root -Filter 'start-*').Count -lt 4) {
        if ($timer.ElapsedMilliseconds -ge 5000) { exit 92 }
        [Threading.Thread]::Yield() | Out-Null
    }
}
switch ($id) {
    2 { [Console]::Error.Write('diagnostic'); [Console]::Out.Write('{"ok":true}'); exit 0 }
    3 { [Console]::Out.Write('{"ok":true}'); exit 1 }
    4 { [Console]::Out.Write('{"ok":true} trailing'); exit 0 }
    5 { $s=[Console]::OpenStandardOutput(); $s.Write([byte[]]@(123,34,120,34,58,34,255,34,125),0,9); $s.Flush(); exit 0 }
    6 { [Console]::Out.Write('"' + ('x' * 1048576) + '"'); exit 0 }
    7 { [Console]::Error.Write('x' * 1048576); [Console]::Out.Write('{}'); exit 0 }
    8 { [Console]::Out.Write('"' + ('x' * 999998) + '"'); exit 0 }
    9 { $wait=New-Object Threading.ManualResetEvent($false); try { [void]$wait.WaitOne(10000) } finally { $wait.Dispose() }; exit 0 }
    10 { [Console]::Out.Write('{/*comment*/"ok":true}'); exit 0 }
    11 { [Console]::Out.Write('{"ok":true,}'); exit 0 }
    12 { [Console]::Out.Write('null'); exit 0 }
    13 { [Console]::Out.Write('[]'); exit 0 }
    14 { [Console]::Out.Write('{"value":"' + [string][char]0x062a + '"}'); exit 0 }
    16 { $s=[Console]::OpenStandardError(); $s.WriteByte(255); $s.Flush(); [Console]::Out.Write('{}'); exit 0 }
    15 {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments='-NoLogo -NoProfile -File "'+(Join-Path $root 'holder.ps1')+'"'
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $child=[Diagnostics.Process]::Start($info)
        $ready=[Threading.EventWaitHandle]::OpenExisting($env:HM_CI_BATCH_READY)
        try { if (-not $ready.WaitOne(5000)) { exit 93 } } finally { $ready.Dispose(); $child.Dispose() }
        [Console]::Out.Write('{}'); exit 0
    }
}
[Console]::Out.Write('{"ok":true}')
'@
    $holder=@'
$utf8=New-Object Text.UTF8Encoding($false,$true)
[IO.File]::WriteAllText((Join-Path $env:HM_CI_BATCH_FIXTURE ('start-'+$PID)),('15|'+$PID+'|'+(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks),$utf8)
$ready=[Threading.EventWaitHandle]::OpenExisting($env:HM_CI_BATCH_READY)
try { [void]$ready.Set(); $wait=New-Object Threading.ManualResetEvent($false); try { [void]$wait.WaitOne(15000) } finally { $wait.Dispose() } } finally { $ready.Dispose() }
'@
    try {
        [IO.File]::WriteAllText((Join-Path $work 'holder.ps1'),$holder,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $work 'gh.ps1'), $shim, (New-Object Text.UTF8Encoding($false)))
        $env:PATH = $work + [IO.Path]::PathSeparator + $savedPath; $env:HM_CI_BATCH_FIXTURE = $work
        Initialize-CiApiBatch
        Initialize-GhBudget 40
        $base = 'repos/owner/repo/actions/runs/'
        $scope = 'physical-root|owner/repo|sha|policy'
        $batch = Invoke-CiApiBatch -Endpoints @(($base+'1'),($base+'2'),($base+'13'),($base+'14')) -ScopeKey $scope
        Check 'CI batch returns only parsed endpoint values including empty arrays and UTF8' ($null -ne $batch -and $batch.Count -eq 4 -and $batch[$base+'1'].ok -and $batch[$base+'13'].Count -eq 0 -and $batch[$base+'14'].value -eq [string][char]0x062a)
        $before = @(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count
        $batch[$base+'1'].ok = $false
        $again = Read-CiBatchApi -Endpoint ($base+'1') -ScopeKey $scope
        Check 'CI positive cache is invocation-local immutable wire data' ($again.ok -and @(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count -eq $before)
        $null = Read-CiBatchApi -Endpoint ($base+'1') -ScopeKey ($scope+'-changed')
        Check 'CI API scope identity prevents cache reuse' (@(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count -eq ($before+1))
        if($SmokeOnly){return}
        foreach ($id in @(3,4,5,6,7,10,11,12,16)) {
            Initialize-CiApiBatch; Initialize-GhBudget 40
            $failed = Invoke-CiApiBatch -Endpoints @(($base+'1'),($base+$id)) -ScopeKey $scope
            Check ('CI batch rejects incomplete/invalid response '+$id) ($null -eq $failed)
        }
        Initialize-CiApiBatch; Initialize-GhBudget 40
        $null = Read-CiBatchApi -Endpoint ($base+'3') -ScopeKey $scope
        $before = @(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count
        $null = Read-CiBatchApi -Endpoint ($base+'3') -ScopeKey $scope
        Check 'CI failed responses are never cached' (@(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count -eq ($before+1))
        Check 'CI failed batch never seeds successful response cache' ($script:CiApiBatchState.Cache.Count -eq 0)
        Initialize-CiApiBatch; Initialize-GhBudget 40
        $null=Invoke-CiApiBatch -Endpoints @(($base+'1'),($base+'1')) -ScopeKey $scope
        Check 'CI duplicate endpoints spend one unique request' ($script:CiApiBatchState.Seen.Count -eq 1)
        Initialize-CiApiBatch
        Check 'CI initialization resets prior invocation state' ($script:CiApiBatchState.Seen.Count -eq 0 -and $script:CiApiBatchState.Bytes -eq 0 -and $script:CiApiBatchState.Cache.Count -eq 0)
        Initialize-GhBudget 40
        $many = @(1..33 | ForEach-Object { $base + $_ })
        $before = @(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count
        Check 'CI 33 endpoint request refuses before starting a process' ($null -eq (Invoke-CiApiBatch -Endpoints $many -ScopeKey $scope))
        Check 'CI overlarge batch starts no child' (@(Get-ChildItem -LiteralPath $work -Filter 'start-*').Count -eq $before)
        foreach ($bad in @('https://api.github.com/repos/o/r/actions/runs','repos/o/r/issues','repos/o/r/actions/runs/1/cancel','repos/o/r/branches/../issues','repos/o/r/branches/%2e%2e','repos/o/r/actions/runs?hostname=evil')) {
            Check ('CI endpoint allowlist '+$bad) ($null -eq (Invoke-CiApiBatch -Endpoints @($bad) -ScopeKey $scope))
        }
        Initialize-CiApiBatch; Initialize-GhBudget 40
        foreach ($i in 1..4) { $large=Read-CiBatchApi -Endpoint ($base+'8') -ScopeKey ($scope+$i); Check ('CI aggregate allows bounded response '+$i) ($null -ne $large) }
        Check 'CI aggregate 4 MiB budget spans calls and scope changes' ($null -eq (Read-CiBatchApi -Endpoint ($base+'8') -ScopeKey ($scope+'5')))
        Initialize-CiApiBatch; Initialize-GhBudget 40
        $countBefore = $script:CiApiBatchState.Seen.Count
        foreach ($i in 1..32) { [void]$script:CiApiBatchState.Seen.Add($base+$i) }
        Check 'CI retry/second call cannot evade unique endpoint bound' ($null -eq (Read-CiBatchApi -Endpoint ($base+'33') -ScopeKey $scope))
        Check 'CI fixture began with no endpoint ownership' ($countBefore -eq 0)
        Initialize-CiApiBatch; Initialize-GhBudget 40
        $starts = @(Get-ChildItem -LiteralPath $work -Filter 'start-*')
        foreach ($file in $starts) { Remove-Item -LiteralPath $file.FullName -Force }
        $parallel = Invoke-CiApiBatch -Endpoints @(100..103 | ForEach-Object { $base + $_ }) -ScopeKey $scope
        Check 'CI four live requests reach barrier and drain' ($null -ne $parallel -and $parallel.Count -eq 4 -and $script:CiApiBatchState.PeakLive -eq 4)
        Initialize-CiApiBatch; Initialize-GhBudget 40
        $script:GhDeadlineUtc = [DateTime]::UtcNow.AddSeconds(3)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Check 'CI shared deadline failure never returns partial evidence' ($null -eq (Invoke-CiApiBatch -Endpoints @($base+'9') -ScopeKey $scope))
        Check 'CI deadline includes bounded cleanup' ($timer.ElapsedMilliseconds -lt 4000)
        Initialize-CiApiBatch; Initialize-GhBudget 40
        $script:GhDeadlineUtc=[DateTime]::UtcNow.AddSeconds(6)
        $timer.Restart()
        $inherited=Read-CiBatchApi -Endpoint ($base+'15') -ScopeKey $scope
        Check 'CI exited-root inherited pipes fail as whole response' ($null -eq $inherited -and $ready.WaitOne(0))
        Check 'CI inherited pipe cleanup stays inside original deadline' ($timer.ElapsedMilliseconds -lt 7000)
        $survivors = 0
        foreach ($file in @(Get-ChildItem -LiteralPath $work -Filter 'start-*')) {
            $parts = [IO.File]::ReadAllText($file.FullName,(New-Object Text.UTF8Encoding($false,$true))) -split '\|'
            if (-not (Test-ProcessGone -ProcessId ([int]$parts[1]) -ExpectedCreated ([DateTime]::new([long]$parts[2],[DateTimeKind]::Utc)))) { $survivors++ }
        }
        Check 'CI batch leaves no identified direct roots alive' ($survivors -eq 0)
    }
    finally {
        # Even a failed assertion cannot leave a deliberately blocked holder.
        foreach ($file in @(Get-ChildItem -LiteralPath $work -Filter 'start-*')) {
            $parts=[IO.File]::ReadAllText($file.FullName,(New-Object Text.UTF8Encoding($false,$true))) -split '\|'
            $birth=[DateTime]::new([long]$parts[2],[DateTimeKind]::Utc)
            if (-not (Test-ProcessGone -ProcessId ([int]$parts[1]) -ExpectedCreated $birth)) { $null=Stop-ProcessTree -ProcessId ([int]$parts[1]) -RootCreated $birth -TimeoutMilliseconds 2000 }
        }
        $ready.Dispose(); $env:HM_CI_BATCH_READY=$savedReady
        $env:PATH = $savedPath; $env:HM_CI_BATCH_FIXTURE = $savedFixture
        if ($null -ne $savedHookDeadline) { $script:HookDeadlineUtc = $savedHookDeadline.Value } else { Remove-Variable HookDeadlineUtc -Scope Script -ErrorAction SilentlyContinue }
        Initialize-CiApiBatch
        Remove-TestWorkspace $work
    }
}
