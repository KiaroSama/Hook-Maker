# Offline test suite for hooks\_budgetlib.ps1 - the hook deadline derived from
# the timeout the installer registered (`timeoutSeconds` in the runtime's
# .hookmaker-runtime.json). A child process that outlived that timeout was killed
# with the hook by the client, and the hook then reported nothing at all.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-HookBudgetLib.ps1
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_testlib.ps1')
$HooksRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
. (Join-Path $HooksRoot '_hooklib.ps1')
. (Join-Path $HooksRoot '_budgetlib.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else { $script:Fail++; Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red; if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray } }
}

$Work = New-TestWorkspace -Prefix 'hookmaker-budgetlib'
[void](New-Item -ItemType Directory -Path $Work -Force)
try {
    function New-RuntimeDir {
        param([string]$Name, $Json)
        $dir = Join-Path $Work $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        if ($null -ne $Json) { [System.IO.File]::WriteAllText((Join-Path $dir '.hookmaker-runtime.json'), $Json, (New-Object System.Text.UTF8Encoding $false)) }
        return $dir
    }
    function Get-DeadlineSeconds { return ($script:HookDeadlineUtc - [DateTime]::UtcNow).TotalSeconds }

    Write-Host '--- the deadline follows the registered timeout ---' -ForegroundColor Cyan
    Initialize-HookDeadline -RuntimeDirectory (New-RuntimeDir 'thirty' '{"schemaVersion":1,"timeoutSeconds":30}')
    $left = Get-DeadlineSeconds
    Check 'timeoutSeconds = 30 gives a deadline about 25 s away (5 s margin)' ($left -gt 23 -and $left -le 25) ('{0:N1}' -f $left)
    Initialize-HookDeadline -RuntimeDirectory (New-RuntimeDir 'missing' $null)
    $left = Get-DeadlineSeconds
    Check 'no metadata falls back to the installer default (60 - 5)' ($left -gt 53 -and $left -le 55) ('{0:N1}' -f $left)
    foreach ($bad in @(2, 9999)) {
        Initialize-HookDeadline -RuntimeDirectory (New-RuntimeDir ('bad' + $bad) ('{"timeoutSeconds":' + $bad + '}'))
        $left = Get-DeadlineSeconds
        Check ('an out-of-range value (' + $bad + ') falls back to 60') ($left -gt 53 -and $left -le 55) ('{0:N1}' -f $left)
    }
    Initialize-HookDeadline -RuntimeDirectory (New-RuntimeDir 'garbage' 'not json')
    Check 'an unreadable metadata file falls back to 60' ((Get-DeadlineSeconds) -gt 53) ''

    Write-Host '--- children are bounded by the time left ---' -ForegroundColor Cyan
    $pwshPath = (Get-Process -Id $PID).Path
    $script:HookDeadlineUtc = [DateTime]::UtcNow.AddSeconds(30)
    $null = Invoke-BoundedCommand -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'exit 0') -TimeoutSeconds 20
    Check 'with time left a bounded child runs and reports its exit code' ($LASTEXITCODE -eq 0) ([string]$LASTEXITCODE)
    $script:HookDeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
    # A process start alone costs far more than the bound below, so an instant
    # return with 124 proves nothing was started.
    $instant = [System.Diagnostics.Stopwatch]::StartNew()
    $out = @(Invoke-BoundedCommand -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 20)
    $code = $LASTEXITCODE
    $instant.Stop()
    Check 'past the deadline no process starts: empty output, exit 124, instant' ($out.Count -eq 0 -and $code -eq 124 -and $instant.Elapsed.TotalMilliseconds -lt 300) ('exit=' + $code + ' ms=' + [int]$instant.Elapsed.TotalMilliseconds)
    $script:HookDeadlineUtc = [DateTime]::UtcNow.AddSeconds(2)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-BoundedCommand -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 20
    $watch.Stop()
    Check 'a slow child is cut at the deadline, not at its own 20 s' ($watch.Elapsed.TotalSeconds -lt 10 -and $LASTEXITCODE -eq 124) ('{0:N1} s, exit {1}' -f $watch.Elapsed.TotalSeconds, $LASTEXITCODE)
}
finally {
    if (-not $KeepArtifacts) { if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++ } }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
