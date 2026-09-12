# Runtime regressions for test-risk classification and incomplete file coverage.
param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 900
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-testplanscanner'
$hookRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$hookCopy = Join-Path $Work 'hook'
New-Item -ItemType Directory -Path $hookCopy -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $hookRoot 'Test-Plan-Check\Test-Plan-Check.ps1') -Destination $hookCopy
Copy-Item -LiteralPath (Join-Path $hookRoot '_hooklib.ps1') -Destination $Work

function Invoke-Scanner {
    param([string]$Project, [string]$Config = '')
    Write-Utf8 (Join-Path $hookCopy '.env') ("TEST_PLAN_ALWAYS_REPORT=1`nTEST_PLAN_MAX_SCAN_SECONDS=10`n" + $Config)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $hookCopy 'Test-Plan-Check.ps1') + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    $info.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Work 'local'
    $info.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = ''
    $info.EnvironmentVariables['HOOKMAKER_CLIENT'] = 'codex'
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write((@{cwd=$Project; session_id='scanner-regression'; hook_event_name='SessionStart'} | ConvertTo-Json -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { throw 'Test-plan scanner exceeded its 30-second process bound.' }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { throw 'Test-plan scanner output did not close.' }
        $output = $stdout.Result
        if ($process.ExitCode -ne 0 -or $stderr.Result -ne '') { throw ('Test-plan scanner failed: ' + $stderr.Result) }
        $document = $output | ConvertFrom-Json
        return [string]$document.hookSpecificOutput.additionalContext
    }
    finally {
        if (-not $process.HasExited) {
            & taskkill.exe /PID $process.Id /T /F *> $null
            if (-not $process.WaitForExit(5000)) { throw 'Test-plan scanner child survived cleanup.' }
        }
        $process.Dispose()
    }
}

function New-ScannerProject {
    param([string]$Name, [string]$Text)
    $project = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    Write-Utf8 (Join-Path $project 'Test-Sample.ps1') $Text
    return $project
}

try {
    $literalProject = New-ScannerProject 'quoted-inputs' @'
$warning = 'WaitForExit() with no timeout'
$input = 'Start-Sleep -Seconds 300'
Check 'reject a long sleep' ($result -match 'Start-Sleep -Seconds 300')
$example = @"
Start-Sleep -Seconds 400
`$process.WaitForExit()
"@
# Start-Sleep -Seconds 500
'@
    $message = Invoke-Scanner $literalProject
    Check 'quoted strings, here-strings and comments are not executable risks' ($message -notmatch 'Test-Sample.ps1:\d+ - ') $message

    $selfProject = Join-Path $Work 'detector-source'
    New-Item -ItemType Directory -Path $selfProject -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $hookCopy 'Test-Plan-Check.ps1') -Destination $selfProject
    $message = Invoke-Scanner $selfProject
    Check 'the detector does not report its own diagnostic strings as waits' ($message -notmatch 'Test-Plan-Check.ps1:\d+ - ') $message

    $spawnProject = New-ScannerProject 'direct-spawn' 'Start-Process pwsh -PassThru'
    $message = Invoke-Scanner $spawnProject
    Check 'an unbounded direct process launch is reported' ($message -match 'Test-Sample.ps1:1 - starts a child process') $message

    $realProject = New-ScannerProject 'real-statements' @'
Start-Sleep -Seconds 60
$process.WaitForExit()
& 'Start-Sleep' -Seconds '90'
"value: $(Start-Sleep -Seconds 120)"
Start-Sleep -Seconds 60.5
'@
    $message = Invoke-Scanner $realProject
    Check 'a real sleep retains its source line' ($message -match 'Test-Sample.ps1:1 - blind sleep of 60s') $message
    Check 'a real unbounded method call retains its source line' ($message -match 'Test-Sample.ps1:2 - WaitForExit\(\)') $message
    Check 'a quoted command invocation is still executable' ($message -match 'Test-Sample.ps1:3 - blind sleep of 90s') $message
    Check 'an executable string interpolation is still inspected' ($message -match 'Test-Sample.ps1:4 - blind sleep of 120s') $message
    Check 'a decimal-duration sleep remains visible to the scanner' ($message -match 'Test-Sample.ps1:5 - blind sleep of 60s') $message

    $sentinelProject = New-ScannerProject 'bounded-child' @'
$deadline = [DateTime]::UtcNow.AddSeconds(10)
Start-Process pwsh -ArgumentList '-Command', 'Start-Sleep -Seconds 300' -PassThru
'@
    $message = Invoke-Scanner $sentinelProject
    Check 'a bounded child command string is not a direct sleep' ($message -notmatch 'Test-Sample.ps1:\d+ - ') $message

    $largeProject = New-ScannerProject 'oversized' ('# ' + ('x' * 2048))
    $message = Invoke-Scanner $largeProject "TEST_PLAN_MAX_FILE_KB=1`n"
    Check 'a file skipped by the byte limit makes coverage partial' ($message -match 'PARTIAL' -and $message -match '(?i)(size|larger|oversize|byte|KB)') $message

    $invalidProject = New-ScannerProject 'invalid-syntax' 'if ('
    $message = Invoke-Scanner $invalidProject
    Check 'unparseable PowerShell never claims complete coverage' ($message -match 'PARTIAL' -and $message -match 'could not be parsed') $message

    $lockedProject = New-ScannerProject 'locked' 'Start-Sleep -Seconds 60'
    $held = [System.IO.File]::Open((Join-Path $lockedProject 'Test-Sample.ps1'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $message = Invoke-Scanner $lockedProject
        Check 'a failed file read makes coverage partial' ($message -match 'PARTIAL' -and $message -match 'could not be read') $message
    }
    finally { $held.Dispose() }
    $message = Invoke-Scanner $lockedProject
    Check 'a readable file clears partial coverage and reports the real risk' ($message -notmatch 'PARTIAL' -and $message -match 'blind sleep of 60s') $message
}
finally {
    if (-not $KeepArtifacts -and -not (Remove-TestWorkspace $Work)) { $script:Fail++ }
}
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail)
exit $script:Fail
