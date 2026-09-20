# Shared evidence assertions and owned-process runner for the September review suites.
# This file is a harness, not a test suite and never executes repository hooks on load.
function Check-Contract {
    param([string]$Name, [scriptblock]$Test, [bool]$FailsOnBaseline = $false)
    $detail = ''; $passed = $false; $threw = $false
    try { $passed = [bool](& $Test) } catch { $threw = $true; $detail = $_.Exception.Message }
    $expected = -not ($Baseline -and $FailsOnBaseline)
    # A historical failure must be an observed contract violation, never an
    # unrelated exception in the assertion or its fixture.
    $matched = -not $threw -and $passed -eq $expected
    [void]$cases.Add([pscustomobject]@{ name=$Name; passed=$passed; expectedPass=$expected; matched=$matched; assertionThrew=$threw; detail=$detail })
    $level = if ($matched) { 'INFO' } else { 'ERROR' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' actual=' + $passed + ' expected=' + $expected + ' ' + $detail)
}
function Put-ReviewText {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Assistant-Record {
    param($Content)
    return ([pscustomobject]@{ type='assistant'; message=[pscustomobject]@{ content=$Content } } | ConvertTo-Json -Depth 8 -Compress)
}
function Invoke-ReviewHook {
    param([string]$ScriptPath, $Payload, [string]$Client = 'codex')
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = (Get-Process -Id $PID).Path
    $process.StartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.EnvironmentVariables['HOOKMAKER_CLIENT'] = $Client
    $process.StartInfo.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = $(if ($Client -eq 'claude') { $work } else { '' })
    $started = $false
    try {
        [void]$process.Start(); $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine(($Payload | ConvertTo-Json -Depth 8 -Compress)); $process.StandardInput.Close()
        if (-not $process.WaitForExit(20000)) { throw 'hook process deadline exceeded' }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { throw 'hook pipe drain deadline exceeded' }
        $wire = [pscustomobject]@{ Exit=$process.ExitCode; Out=$stdout.Result.Trim(); Err=$stderr.Result.Trim() }
        # These are test-owned fixture responses, never arbitrary user input.
        # Keep bounded traces independently of the verdict so an absent result
        # or host-specific failure is diagnosable instead of retried into green.
        if (-not [string]::IsNullOrWhiteSpace($env:REVIEW_EVIDENCE)) {
            [void][IO.Directory]::CreateDirectory($env:REVIEW_EVIDENCE)
            $trace = [ordered]@{ timestampUtc=[DateTime]::UtcNow.ToString('o'); hostVersion=$PSVersionTable.PSVersion.ToString(); script=(Split-Path -Leaf $ScriptPath); client=$Client; event=[string]$Payload.hook_event_name; exit=$wire.Exit; stdout=$wire.Out.Substring(0,[Math]::Min(16384,$wire.Out.Length)); stderr=$wire.Err.Substring(0,[Math]::Min(8192,$wire.Err.Length)); truncated=($wire.Out.Length -gt 16384 -or $wire.Err.Length -gt 8192) }
            [IO.File]::AppendAllText((Join-Path $env:REVIEW_EVIDENCE 'hook-traces.jsonl'), (($trace | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
        }
        return $wire
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); if (-not $process.WaitForExit(5000)) { throw 'hook cleanup not proven' } }
        $process.Dispose()
    }
}
