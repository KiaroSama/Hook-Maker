param([string]$ResultPath = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path ([IO.Path]::GetTempPath()) ('hookmaker-task-regression-' + [guid]::NewGuid().ToString('N'))
$savedLocal = $env:LOCALAPPDATA
$savedClient = $env:HOOKMAKER_CLIENT
$results = New-Object System.Collections.Generic.List[object]
function Assert-Case {
    param([string]$Name, [scriptblock]$Test)
    $ok = $false; $detail = ''
    try { $ok = [bool](& $Test) } catch { $detail = $_.Exception.Message }
    [void]$results.Add([pscustomobject]@{ name = $Name; passed = $ok; detail = $detail })
    $level = if ($ok) { 'INFO' } else { 'ERROR' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' ' + $detail)
}
function New-TaskInput {
    param([string]$Session, [string]$Prompt, [string]$Turn)
    return [pscustomobject]@{ hook_event_name = 'UserPromptSubmit'; cwd = $work; session_id = $Session; prompt = $Prompt; turn_id = $Turn }
}
try {
    [void](New-Item -ItemType Directory -Path $work)
    $env:LOCALAPPDATA = $work
    $env:HOOKMAKER_CLIENT = 'codex'
    . (Join-Path $repo 'hooks\_hooklib.ps1')
    $a = New-TaskInput 'session-a' 'Inspect the parser' 'turn-a1'
    Register-UserTaskBoundary $a
    $a1 = Get-CurrentUserTaskIdentity $a
    Assert-Case 'fresh task has a non-degraded identity' { -not $a1.Degraded -and $a1.TaskId -ne '' }
    Register-UserTaskBoundary $a
    Assert-Case 'duplicate prompt dispatch preserves task identity' { (Get-CurrentUserTaskIdentity $a).TaskId -eq $a1.TaskId }
    $b = New-TaskInput 'session-b' 'Inspect a different parser' 'turn-b1'
    Register-UserTaskBoundary $b
    Assert-Case 'another session cannot evict the active task' { $v = Get-CurrentUserTaskIdentity $a; -not $v.Degraded -and $v.TaskId -eq $a1.TaskId }
    Register-UserTaskBoundary $a
    $beforeRepeat = (Get-CurrentUserTaskIdentity $a).TaskId
    $repeat = New-TaskInput 'session-a' 'Inspect the parser' 'turn-a2'
    Register-UserTaskBoundary $repeat
    Assert-Case 'identical text in a new user turn starts a new task' { (Get-CurrentUserTaskIdentity $repeat).TaskId -ne $beforeRepeat }
    $beforeClient = (Get-CurrentUserTaskIdentity $repeat).TaskId
    $env:HOOKMAKER_CLIENT = 'claude'
    $c = New-TaskInput 'session-a' 'Claude task in the same project' 'claude-1'
    Register-UserTaskBoundary $c
    $env:HOOKMAKER_CLIENT = 'codex'
    Assert-Case 'another client cannot replace the Codex task' { (Get-CurrentUserTaskIdentity $repeat).TaskId -eq $beforeClient }
    $missingSession = New-TaskInput '' 'No provenance' 'unknown'
    Assert-Case 'missing session never adopts another session identity' { (Get-CurrentUserTaskIdentity $missingSession).Degraded }

    # Exercise the actual write transaction, not a translated model.
    $ledgerPath = Join-Path $work 'corrupt-ledger.json'
    [IO.File]::WriteAllText($ledgerPath, '{ invalid json')
    $before = [IO.File]::ReadAllText($ledgerPath)
    $v = Invoke-StopLedgerUpdate -Path $ledgerPath -Mutate { param($doc) $true }
    Assert-Case 'transaction refuses corrupt persisted state without overwriting it' { -not $v.Ok -and [IO.File]::ReadAllText($ledgerPath) -ceq $before }
    [IO.File]::WriteAllText($ledgerPath, '{"version":999,"entries":{},"chains":{},"unresolved":{}}')
    $before = [IO.File]::ReadAllText($ledgerPath)
    $v = Invoke-StopLedgerUpdate -Path $ledgerPath -Mutate { param($doc) $true }
    Assert-Case 'transaction refuses future state while holding its lock' { -not $v.Ok -and [IO.File]::ReadAllText($ledgerPath) -ceq $before }
}
finally {
    $env:LOCALAPPDATA = $savedLocal
    $env:HOOKMAKER_CLIENT = $savedClient
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$failed = @($results.ToArray() | Where-Object { -not $_.passed }).Count
$report = [ordered]@{ schema = 1; hostVersion = $PSVersionTable.PSVersion.ToString(); cases = $results.ToArray(); failed = $failed }
if ($ResultPath -ne '') {
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $ResultPath) -Force)
    [IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
Write-Host ('Cases: ' + $results.Count + '; failed: ' + $failed)
if ($failed -gt 0) { exit 1 }
exit 0
