# Test-CiStatusCheck.ps1 shared harness: the two stdin-driven process runners
# that invoke the hook - the normal Fire and the -ReportExternalBlocker variant.
# Dot-sourced by Test-CiStatusCheck.ps1 into the caller's scope (uses its
# $CiHook / $Work / mock state) - not a standalone suite.
#
# They live here because the suite reached the 800-line ceiling and a file at
# the ceiling takes no new code; the bounded waits below are that new code.

function Fire {
    # $RawStdin is intentionally UNTYPED: a [string] param coerces a $null
    # default to '', which would make the "$null -eq $payload" guard below false
    # and send empty stdin. Keep it untyped so an omitted RawStdin stays $null.
    # $Client controls the child's CLAUDE_PROJECT_DIR, the signal hooks use to
    # tell Claude Code from Codex. Start-Process -Environment MERGES with the
    # inherited environment, so a CLAUDE_PROJECT_DIR set in the parent (running
    # the suite from inside Claude Code) would otherwise leak in and make
    # client-dependent assertions pass locally but differ in CI. Always set it
    # explicitly: 'claude' -> a path, anything else -> empty (Codex).
    param([string]$HookPath, [string]$Cwd, [string]$EventName = 'SessionStart', $Extra = $null, $RawStdin = $null, [string]$Exe = '', [string]$Client = 'codex')
    $payload = $RawStdin
    if ($null -eq $payload) {
        $obj = @{ session_id = 't'; cwd = $Cwd; hook_event_name = $EventName }
        if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
        $payload = $obj | ConvertTo-Json    # multi-line JSON on purpose
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $file = (Get-Process -Id $PID).Path
        $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '"'
    }
    else {
        $file = 'powershell.exe'
        $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $HookPath + '"'
    }
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $claudeProjectDir = if ($Client -eq 'claude') { $Cwd } else { '' }
        $startArgs.Environment = @{ PATH = $env:PATH; GH_MOCK_DIR = $env:GH_MOCK_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; CLAUDE_PROJECT_DIR = $claudeProjectDir }
    }
    $proc = Start-Process @startArgs
    # Bounded: -Wait has no ceiling. A hook that blocks on stdin or deadlocks
    # would otherwise hang this suite until the bucket's blunt per-suite limit
    # killed it, which reports a timed-out SUITE instead of this child.
    if (-not $proc.WaitForExit(180000)) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        throw ('the hook child (pid ' + $proc.Id + ') did not exit within 180s and was terminated')
    }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    if ($err -ne '' -and $env:HOOKMAKER_TEST_DEBUG -eq '1') {
        Write-Host ('  [stderr] ' + $err.Split("`n")[0]) -ForegroundColor DarkYellow
    }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

function FireExternalBlocker {
    param([string]$Cwd, [string]$Classification = '', [string]$Reason = '', [string]$Exe = '', [string]$HookPath = $CiHook, [string]$Client = 'codex')
    $argLine = '-NoLogo -NoProfile -File "' + $HookPath + '" -ReportExternalBlocker'
    if ($Classification -ne '') { $argLine += ' -Classification ' + $Classification }
    if ($Reason -ne '') { $argLine += ' -Reason "' + $Reason + '"' }
    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $file = (Get-Process -Id $PID).Path
    }
    else {
        $file = 'powershell.exe'
        $argLine = $argLine.Replace('-NoLogo -NoProfile -File', '-NoLogo -NoProfile -ExecutionPolicy Bypass -File')
    }
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; WorkingDirectory = $Cwd
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $claudeProjectDir = if ($Client -eq 'claude') { $Cwd } else { '' }
        $startArgs.Environment = @{ PATH = $env:PATH; GH_MOCK_DIR = $env:GH_MOCK_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; CLAUDE_PROJECT_DIR = $claudeProjectDir }
    }
    $proc = Start-Process @startArgs
    # Bounded: -Wait has no ceiling. A hook that blocks on stdin or deadlocks
    # would otherwise hang this suite until the bucket's blunt per-suite limit
    # killed it, which reports a timed-out SUITE instead of this child.
    if (-not $proc.WaitForExit(180000)) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        throw ('the hook child (pid ' + $proc.Id + ') did not exit within 180s and was terminated')
    }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = ([System.IO.File]::ReadAllText($outFile)).Trim() }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}
