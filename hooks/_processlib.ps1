# The bounded process runner every hook uses: ConvertTo-Win32ArgumentString and
# Invoke-QuietCommand, moved verbatim out of _hooklib.ps1 (over the size ceiling)
# as ONE responsibility. REQUIRED, not optional: _hooklib.ps1 dot-sources it
# unconditionally, because a helper every hook calls cannot be allowed to be
# missing (why the banner-cut split of PR #21 was reverted). Terminating an owned
# tree lives in _processtree.ps1, loaded by _hooklib.ps1 as before.

# Runs an external command (git, gh, ...) whose stderr must NEVER become a
# terminating error, even when the command exits non-zero. Windows PowerShell
# 5.1 promotes ANY stderr line from a native command into a NativeCommandError
# under $ErrorActionPreference='Stop' - and, verified empirically, `2>$null`,
# `2>&1 | Out-Null`, and `*>$null` all fail to prevent that promotion under 5.1
# (pwsh 7 is unaffected, which is why this only shows up against the real
# Claude client). Only relaxing $ErrorActionPreference around the call works.
# Returns stdout lines (redirecting stderr away); $LASTEXITCODE is left intact
# for the caller exactly as a raw `&` call would leave it.
# Runs a child process quietly and, above all, BOUNDED.
#
# This is the only place a hook starts a process, and it carries every network
# call in the hook set (gh api, gh run list, npm outdated, pip list
# --outdated, go list -u -m all). Without a deadline a single stalled request
# held the whole Stop hostage for its timeout and left the child running after
# the client gave up on the hook - the exact "terminate owned child process
# trees, leave no orphaned workers" case in global-hook-rules.md.
#
# TimeoutSeconds is a CEILING, not an expected duration: a local git call
# returns in milliseconds. On expiry the whole process TREE is killed (a
# `gh` that spawned a helper leaves nothing behind), and the caller gets $null
# with a non-zero $LASTEXITCODE - which every caller already treats as "no
# answer", so a timeout degrades to silence rather than to a wrong claim.
# Build a Win32 command line the way CommandLineToArgvW parses it back.
#
# Only Windows PowerShell 5.1 needs this - pwsh 7 has
# ProcessStartInfo.ArgumentList and does it itself. Joining arguments with
# spaces is NOT equivalent: a repo path like
#   G:\Program Files\Portable\Scripts\Hook Maker
# would arrive as four separate arguments, which is exactly the situation
# every hook here runs in.
#
# The backslash rule is the non-obvious half: a run of backslashes is
# literal UNLESS it meets a quote, where each one must be doubled. So a
# trailing separator becomes "C:\dir\\" - doubling only the
# run that collides with the closing quote.
function ConvertTo-Win32ArgumentString {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList)
    $quote = [char]34
    $slash = [char]92
    $sb = New-Object System.Text.StringBuilder
    foreach ($argument in @($ArgumentList)) {
        $text = [string]$argument
        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
        # No space, tab or quote means no quoting needed - but an EMPTY
        # argument still needs quotes or it vanishes from the command line.
        if ($text.Length -gt 0 -and -not ($text.Contains(' ') -or $text.Contains([char]9) -or $text.Contains($quote))) {
            [void]$sb.Append($text)
            continue
        }
        [void]$sb.Append($quote)
        $pending = 0
        foreach ($ch in $text.ToCharArray()) {
            if ($ch -eq $slash) { $pending++; continue }
            if ($ch -eq $quote) {
                [void]$sb.Append([string]$slash * ($pending * 2 + 1))
                $pending = 0
            }
            elseif ($pending -gt 0) {
                [void]$sb.Append([string]$slash * $pending)
                $pending = 0
            }
            [void]$sb.Append($ch)
        }
        # Trailing backslashes meet the closing quote, so they double.
        if ($pending -gt 0) { [void]$sb.Append([string]$slash * ($pending * 2)) }
        [void]$sb.Append($quote)
    }
    return $sb.ToString()
}

function Invoke-QuietCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [int]$TimeoutSeconds = 20,
        [switch]$CaptureOutput,
        [hashtable]$Environment = @{}
    )
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $process = $null
    $commandTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $timeoutMs = [int]([Math]::Max(1, $TimeoutSeconds) * 1000)
        # Resolve the command the way `&` did before this function was made
        # bounded. Process.Start needs a real executable IMAGE: it cannot run
        # a .ps1 or .cmd, while `&` resolved both through PATH + PATHEXT. A
        # `gh.ps1` shim on PATH is exactly the shape the test suites use, and
        # a user wrapping git/gh would have hit the same wall in production.
        $targetPath = $FilePath
        $targetArgs = @($ArgumentList); $cmdLine = $null
        try {
            $resolved = @(Get-Command -Name $FilePath -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandType -eq 'Application' -or $_.CommandType -eq 'ExternalScript' })
            if ($resolved.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$resolved[0].Source)) {
                $targetPath = [string]$resolved[0].Source
                $extension = [System.IO.Path]::GetExtension($targetPath).ToLowerInvariant()
                if ($extension -eq '.ps1') {
                    # Run it on the SAME host this hook is running on, so a 5.1
                    # hook does not silently get pwsh semantics or vice versa.
                    $targetArgs = @('-NoLogo', '-NoProfile', '-File', $targetPath) + $targetArgs
                    $targetPath = [string](Get-Process -Id $PID).Path
                }
                elseif ($extension -eq '.cmd' -or $extension -eq '.bat') {
                    $cmdLine = '/s /c "' + (ConvertTo-Win32ArgumentString -ArgumentList (@($targetPath) + $targetArgs)) + '"' # /s + outer quotes: a quoted path AND a quoted argument otherwise lose their first and last quote
                    $targetPath = (Join-Path $env:SystemRoot 'System32\cmd.exe')
                }
            }
        }
        catch { }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $targetPath
        # Inherit the CALLER's directory. Push-Location moves PowerShell's
        # provider location but NOT [Environment]::CurrentDirectory, which is
        # what ProcessStartInfo inherits - so without this a caller that did
        # Push-Location <module dir> to scope a `go list` or `npm outdated`
        # silently ran the child in the wrong directory and got the wrong
        # answer. Invoking through `&` never had this gap.
        try {
            $callerDir = (Get-Location -PSProvider FileSystem -ErrorAction SilentlyContinue)
            if ($null -ne $callerDir -and -not [string]::IsNullOrWhiteSpace([string]$callerDir.ProviderPath)) {
                $info.WorkingDirectory = [string]$callerDir.ProviderPath
            }
        }
        catch { }
        # ArgumentList (not a joined string) so a path with spaces survives -
        # but ONLY pwsh 7 has it. ProcessStartInfo.ArgumentList arrived in
        # .NET Core; on .NET Framework 4.x, which is what Windows PowerShell
        # 5.1 runs on, the property does not exist. Measured, not assumed:
        # $info.PSObject.Properties.Name -contains 'ArgumentList' is False on
        # 5.1 and True on pwsh 7. Under StrictMode the 5.1 call threw inside
        # this function's own try, which returned $null - so every git/gh
        # call a hook made on 5.1 failed SILENTLY and read as "no answer".
        # An earlier revision of this comment asserted the property existed
        # on both hosts. It does not, and that claim is what hid the bug.
        if ($null -ne $cmdLine) { $info.Arguments = $cmdLine } elseif ($info.PSObject.Properties.Name -contains 'ArgumentList') {
            foreach ($argument in @($targetArgs)) { [void]$info.ArgumentList.Add([string]$argument) }
        }
        else {
            $info.Arguments = ConvertTo-Win32ArgumentString -ArgumentList @($targetArgs)
        }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        if ($CaptureOutput) {
            $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false,$true)
            $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false,$true)
        }
        # No window, no inherited stdin: a child that decides to prompt would
        # otherwise wait for input nobody is there to give.
        $info.RedirectStandardInput = $true
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = [string]$Environment[$key] }
        $process = [System.Diagnostics.Process]::Start($info)
        if ($null -eq $process) { $global:LASTEXITCODE = 1; return $null }
        $ownedProcessCreated = $process.StartTime.ToUniversalTime()
        $process.StandardInput.Close()
        # Read stdout asynchronously BEFORE waiting: a child that fills the pipe
        # buffer while we block on WaitForExit deadlocks with us forever.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remainingMs = [int][Math]::Max(0, $timeoutMs - $commandTimer.ElapsedMilliseconds)
        if (-not $process.WaitForExit($remainingMs)) {
            try { $null = Stop-ProcessTree -ProcessId $process.Id -RootCreated $ownedProcessCreated } catch { }
            $global:LASTEXITCODE = 124
            return $null
        }
        # A descendant can retain either pipe after the direct child exits.
        # Keep the process handle until cleanup (so its PID cannot be reused)
        # and spend only the remaining command budget waiting for both EOFs.
        $remainingMs = [int][Math]::Max(0, $timeoutMs - $commandTimer.ElapsedMilliseconds)
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $remainingMs)) {
            try { $null = Stop-ProcessTree -ProcessId $process.Id -RootCreated $ownedProcessCreated } catch { }
            $global:LASTEXITCODE = 124
            return $null
        }
        $output = ''
        try { $output = $stdoutTask.GetAwaiter().GetResult() } catch { $output = '' }
        $errorOutput = ''
        try { $errorOutput = $stderrTask.GetAwaiter().GetResult() } catch { }
        $global:LASTEXITCODE = $process.ExitCode
        if ($CaptureOutput) { return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; ErrorOutput = $errorOutput } }
        if ([string]::IsNullOrEmpty($output)) { return @() }
        return ($output -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    catch {
        $global:LASTEXITCODE = 1
        return $null
    }
    finally {
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
        $ErrorActionPreference = $savedPreference
    }
}
