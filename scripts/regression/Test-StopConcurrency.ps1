param([string]$Mode = '', [string]$Root = '', [int]$Index = 0, [string]$ResultPath = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'hooks\_hooklib.ps1')
$utf8 = New-Object Text.UTF8Encoding($false)

# Worker processes execute only in-process state helpers and never spawn a
# descendant. Both their readiness wait and the parent's ownership are bounded.
if ($Mode -ne '') {
    try {
        $payload = [IO.File]::ReadAllText((Join-Path $Root 'input.json')) | ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $Root ($Index.ToString() + '.ready')), 'ready', $utf8)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path $Root 'release'))) {
            if ($clock.Elapsed.TotalSeconds -gt 20) { throw 'worker barrier deadline exceeded' }
            Start-Sleep -Milliseconds 10
        }
        if ($Mode -eq 'boundary') {
            Register-UserTaskBoundary -HookInput $payload
            $value = Get-CurrentUserTaskIdentity $payload
        }
        elseif ($Mode -eq 'receipt') {
            $value = Register-TaskContinuation -HookInput $payload -Reason ('repair-' + $Index) -AddHeader $false
        }
        elseif ($Mode -eq 'claim') {
            $value = Set-StopBlockMarker -HookInput $payload -HookName ('Parallel-Gate-' + $Index) -FindingFingerprint ('finding-' + $Index)
        }
        else { throw 'unknown worker mode' }
        [IO.File]::WriteAllText((Join-Path $Root ($Index.ToString() + '.result.json')), ($value | ConvertTo-Json -Depth 8), $utf8)
        exit 0
    }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('hookmaker-concurrency space-' + [guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA; $savedClient = $env:HOOKMAKER_CLIENT; $savedBudget = $env:HOOKMAKER_STOP_CORRECTION_BUDGET
$cases = New-Object System.Collections.Generic.List[object]
function Check-Case {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    [void]$cases.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    $level = if ($Passed) { 'INFO' } else { 'ERROR' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' ' + $Detail)
}
function New-Payload {
    param([string]$Project, [string]$Session, [string]$Turn, [string]$Prompt)
    return [pscustomobject]@{ cwd = $Project; session_id = $Session; turn_id = $Turn; prompt = $Prompt; hook_event_name = 'UserPromptSubmit'; stop_hook_active = $false }
}
function Invoke-Workers {
    param([string]$Scenario, $Payload)
    $dir = Join-Path $work $Scenario
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'input.json'), ($Payload | ConvertTo-Json -Depth 5), $utf8)
    $children = New-Object System.Collections.Generic.List[object]
    $count = 6
    try {
        $exe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -le 5) { 'powershell.exe' } else { 'pwsh.exe' })
        foreach ($n in 1..$count) {
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $exe
            $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode ' + $Scenario + ' -Root "' + $dir + '" -Index ' + $n
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            [void]$children.Add([pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() })
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (@(Get-ChildItem -LiteralPath $dir -Filter '*.ready' -File).Count -lt $count) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'parent readiness deadline exceeded' }
            foreach ($child in $children) { if ($child.Process.HasExited) { throw ('worker exited before barrier: ' + $child.Err.Result) } }
            Start-Sleep -Milliseconds 10
        }
        [IO.File]::WriteAllText((Join-Path $dir 'release'), 'release', $utf8)
        foreach ($child in $children) {
            $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $child.Process.WaitForExit($remaining)) { throw 'parent worker deadline exceeded' }
            if (-not $child.Out.Wait(2000) -or -not $child.Err.Wait(2000)) { throw 'worker stream drain deadline exceeded' }
            if ($child.Process.ExitCode -ne 0) { throw ('worker failure: ' + $child.Err.Result) }
        }
        $values = @()
        foreach ($n in 1..$count) { $values += ([IO.File]::ReadAllText((Join-Path $dir ($n.ToString() + '.result.json'))) | ConvertFrom-Json) }
        return $values
    }
    finally {
        foreach ($child in $children) {
            if (-not $child.Process.HasExited) { $child.Process.Kill(); [void]$child.Process.WaitForExit(5000) }
            $child.Process.Dispose()
        }
    }
}
function Capture-Wire {
    param([scriptblock]$Action)
    $saved = [Console]::Out; $writer = New-Object IO.StringWriter
    try { [Console]::SetOut($writer); $null = & $Action; return $writer.ToString() }
    finally { [Console]::SetOut($saved); $writer.Dispose() }
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    $env:LOCALAPPDATA = $work; $env:HOOKMAKER_CLIENT = 'codex'; $env:HOOKMAKER_STOP_CORRECTION_BUDGET = '6'
    $payload = New-Payload $work 'parallel' 'turn-1' 'first request'
    $values = @(Invoke-Workers 'boundary' $payload)
    Check-Case 'six simultaneous dispatch handlers publish exactly one task identity' (@($values | Select-Object -ExpandProperty TaskId -Unique).Count -eq 1 -and @($values | Where-Object Degraded).Count -eq 0)
    $task = (Get-CurrentUserTaskIdentity $payload).TaskId
    $payload.hook_event_name = 'Stop'
    $values = @(Invoke-Workers 'receipt' $payload)
    $record = Read-TaskIdentityRecord -Path (Get-TaskScope $payload).Path
    Check-Case 'six concurrent receipt mutations all succeed without lost updates' (@($values | Where-Object { -not $_.Ok }).Count -eq 0 -and @($record.blockFingerprints).Count -eq 6)
    Check-Case 'receipt mutations retain their original task' ($record.taskId -ceq $task)
    foreach ($n in 1..5) { $null = Set-StopBlockMarker -HookInput $payload -HookName ('Seed-' + $n) -FindingFingerprint ('seed-' + $n) }
    $payload.stop_hook_active = $true
    $values = @(Invoke-Workers 'claim' $payload)
    Check-Case 'six simultaneous contenders at budget-minus-one admit exactly one' (@($values | Where-Object Admitted).Count -eq 1)
    $ledger = Read-StopLedger -Path (Get-StopLedgerPath $work)
    $key = (Get-StopLedgerKeys $payload 'probe').ChainKey
    Check-Case 'concurrent counter never exceeds its configured budget' ($ledger.chains.$key.blocks -eq 6)

    $unknownRoot = Join-Path $work 'unknown'; [void][IO.Directory]::CreateDirectory($unknownRoot)
    $transcript = Join-Path $unknownRoot 'history.jsonl'
    $unknown = [pscustomobject]@{ cwd = $unknownRoot; session_id = 'unknown'; hook_event_name = 'Stop'; stop_hook_active = $false; transcript_path = $transcript }
    $admitted = 0
    foreach ($n in 1..30) {
        [IO.File]::AppendAllText($transcript, ('changed-' + $n + "`n"), $utf8)
        if ((Set-StopBlockMarker $unknown 'Same-Gate' -FindingFingerprint 'unchanged').Admitted) { $admitted++ }
    }
    Check-Case 'thirty transcript mutations cannot refund an unidentified task budget' ($admitted -eq 1)

    $p = New-Payload $work 'receipt-test' 'real-1' 'do the work'
    Register-UserTaskBoundary $p; $id = (Get-CurrentUserTaskIdentity $p).TaskId
    $receipt = Register-TaskContinuation -HookInput $p -Reason ('LONG REPAIR ' + ('x' * 12000))
    $p.turn_id = 'synthetic-1'; $p.prompt = $receipt.Text.Substring(0, 100) + ' [spilled preview]'
    Register-UserTaskBoundary $p
    Check-Case 'a truncated correction retains the originating task through its opaque receipt' ((Get-CurrentUserTaskIdentity $p).TaskId -ceq $id)
    Register-UserTaskBoundary $p
    Check-Case 'duplicate synthetic dispatch is idempotent after consuming its receipt' ((Get-CurrentUserTaskIdentity $p).TaskId -ceq $id)
    $p.turn_id = 'real-2'
    Register-UserTaskBoundary $p
    Check-Case 'a consumed receipt cannot permanently swallow a new user turn' ((Get-CurrentUserTaskIdentity $p).TaskId -cne $id)
    Check-Case 'meaningful internal prompt whitespace is preserved' ((Get-TaskPromptFingerprint "code 'a b'") -cne (Get-TaskPromptFingerprint "code 'a  b'"))

    $env:HOOKMAKER_CLIENT = 'claude'
    $p = New-Payload $work 'phase-test' '' 'repeat this request'
    Register-UserTaskBoundary $p; $id = (Get-CurrentUserTaskIdentity $p).TaskId
    $p.hook_event_name = 'Stop'; Register-UserTaskBoundary $p
    $p.hook_event_name = 'UserPromptSubmit'; Register-UserTaskBoundary $p
    Check-Case 'the same Claude prompt after a completed turn begins a new task' ((Get-CurrentUserTaskIdentity $p).TaskId -cne $id)
    $wire = Capture-Wire { Write-HookResult -EventName Stop -Kind advisory -Message 'non-actionable information' }
    $json = $wire | ConvertFrom-Json
    Check-Case 'Claude Stop advisory is visible but cannot start a new model turn' ($null -ne $json.PSObject.Properties['systemMessage'] -and $null -eq $json.PSObject.Properties['hookSpecificOutput'] -and $null -eq $json.PSObject.Properties['decision'])
    $wire = Capture-Wire { Write-StopBlockResult -HookInput $p -HookName 'empty' -EventName Stop -Reason '' }
    Check-Case 'an empty finding emits no block or spurious JSON' ([string]::IsNullOrWhiteSpace($wire))
    Set-TaskSummaryPublished $p
    $p.prompt = 'next task'; Register-UserTaskBoundary $p
    Check-Case 'a new task does not inherit the previous summary-published flag' (-not (Test-TaskSummaryAlreadyPublished $p))
}
catch { Check-Case 'suite completed without an infrastructure or product exception' $false $_.Exception.Message }
finally {
    $env:LOCALAPPDATA = $savedLocal; $env:HOOKMAKER_CLIENT = $savedClient; $env:HOOKMAKER_STOP_CORRECTION_BUDGET = $savedBudget
    if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    Check-Case 'all owned test files were removed' (-not [IO.Directory]::Exists($work))
}
$failed = @($cases.ToArray() | Where-Object { -not $_.passed }).Count
$report = [ordered]@{ schema = 1; hostVersion = $PSVersionTable.PSVersion.ToString(); workers = 6; cases = $cases.ToArray(); failed = $failed }
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    [IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 8), $utf8)
}
Write-Host ('Cases: ' + $cases.Count + '; failed: ' + $failed)
if ($failed -gt 0) { exit 1 }
exit 0
