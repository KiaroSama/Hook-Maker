# An expected-negative child remains failed, but only in the test's own store.
function Invoke-TestStateIsolationRegression {
    param([string]$RepoRoot, [string]$Workspace)
    $root = Join-Path $Workspace 'state-isolation'
    [void][IO.Directory]::CreateDirectory($root)
    $wrapper = Join-Path $root 'isolation.ps1'
    $code = @'
param([string]$Repo, [string]$CaseRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo 'hooks/_hooklib.ps1')
. (Join-Path $Repo 'scripts/_testlib.ps1')
$outerLocal = Join-Path $CaseRoot 'outer-local'
$outerState = Join-Path $CaseRoot 'outer-state'
$env:LOCALAPPDATA = $outerLocal
$env:HOOKMAKER_STATE_DIR = $outerState
$token = $null; $failure = ''
try {
    $token = Enter-TestStateIsolation -Workspace $CaseRoot
    & (Join-Path $Repo 'scripts/Run-Tests-Guarded.ps1') -FilePath pwsh -Arguments @('-NoProfile','-Command','exit 7') -ProjectFingerprint isolated-fixture -WorkingDirectory $CaseRoot -ResultPath (Join-Path $CaseRoot 'result.json') -TimeoutSeconds 15 -IdleTimeoutSeconds 5 -MaxWorkers 1 -HeartbeatSeconds 1 -Quiet
    $childExit = $LASTEXITCODE
    $isolatedState = $env:HOOKMAKER_STATE_DIR
    throw 'Controlled fixture failure'
}
catch { $failure = $_.Exception.Message }
finally { if ($null -ne $token) { Exit-TestStateIsolation -Token $token } }
$restored = ($env:LOCALAPPDATA -ceq $outerLocal -and $env:HOOKMAKER_STATE_DIR -ceq $outerState)
Remove-Item Env:HOOKMAKER_STATE_DIR -ErrorAction SilentlyContinue
$emptyToken = Enter-TestStateIsolation -Workspace $CaseRoot
Exit-TestStateIsolation -Token $emptyToken
$absentRestored = $null -eq [Environment]::GetEnvironmentVariable('HOOKMAKER_STATE_DIR')
$receipt = Read-JsonFile (Join-Path $CaseRoot 'result.json')
$report = [ordered]@{
    failure = $failure; restored = ($restored -and $absentRestored)
    childExit = $(if ($null -ne $receipt) { $receipt.exitCode } else { -1 })
    overall = $(if ($null -ne $receipt) { $receipt.overall } else { '' })
    commandFingerprint = $(if ($null -ne $receipt) { $receipt.commandFingerprint } else { '' })
    stderrBytes = $(if ($null -ne $receipt) { $receipt.stderrBytes } else { -1 })
    isolatedCount = $(if ($null -ne $token) { @(Get-ChildItem -LiteralPath $isolatedState -Filter 'TestRunGuard-result-*.json' -File).Count } else { 0 })
    outerCount = @(@($outerLocal, $outerState) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'TestRunGuard-*.json' -Recurse -File }).Count
}
[IO.File]::WriteAllText((Join-Path $CaseRoot 'report.json'), ($report | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
'@
    Write-Utf8 $wrapper $code
    foreach ($hostName in @('pwsh','powershell.exe')) {
        $caseRoot = Join-Path $root $hostName
        [void][IO.Directory]::CreateDirectory($caseRoot)
        $out = Invoke-QuietCommand -FilePath $hostName -ArgumentList @('-NoLogo','-NoProfile','-File',$wrapper,$RepoRoot,$caseRoot) -TimeoutSeconds 30 -CaptureOutput
        if ($null -ne $out -and $out.ExitCode -ne 0) { Write-Output $out.ErrorOutput }
        $report = Read-JsonFile (Join-Path $caseRoot 'report.json')
        Check ($hostName + ': expected-negative receipt is isolated and remains failed') ($null -ne $report -and $report.childExit -eq 7 -and $report.overall -eq 'failed' -and $report.isolatedCount -eq 1 -and $report.outerCount -eq 0) (($out -join ' ') + ($report | ConvertTo-Json -Compress))
        Check ($hostName + ': controlled failure restores caller environment') ($null -ne $report -and $report.restored -and $report.failure -eq 'Controlled fixture failure') (($out -join ' ') + ($report | ConvertTo-Json -Compress))
    }
}
