# _hooklib section: the READ side of the bounded rolling test-timing history.
#
# Dot-sourced by _hooklib.ps1, so it runs in that scope and its $script:Timing*
# settings land where they always did. The WRITE side lives in the guarded
# runner (scripts/_guardedtiming.ps1) and is deliberately a separate copy: the
# runner does not load _hooklib at all, so the sample shape and the
# TestTiming-* path have to stay byte-compatible ACROSS the two by agreement
# rather than by sharing code. Change one and change the other.

# ---- HM-07: bounded rolling test-timing history (READ side) -----------------
# Samples live ONLY in local Hook-Maker state (%LOCALAPPDATA%\HookMaker\state),
# one file per (canonical project key + command/suite fingerprint), never in the
# project. Each sample is sanitized: runId, elapsed seconds, outcome, UTC, the
# effective worker ceiling and an optional safe suite label - never an argument,
# path, prompt, secret, user name or token. The standalone guarded runner WRITES
# them (Run-Tests-Guarded.ps1); these helpers READ them so Test-Plan-Check can
# surface a baseline and Test-Completion-Check can report a meaningful regression.
# The WRITER mirrors TimingMaxSamples exactly - keep the two in lockstep.
$script:TimingMaxSamples = 30
$script:TimingMinBaseline = 5        # this many COMPARABLE ok runs before judging
$script:TimingRelFactor = 1.5        # >= 50% slower than the median, AND ...
$script:TimingAbsSeconds = 30        # ... >= 30s slower in absolute terms

function Get-TimingHistoryPath {
    param([string]$StateDir, [string]$ProjectKey, [string]$CommandFingerprint)
    return (Join-Path $StateDir ('TestTiming-' + $ProjectKey + '-' + $CommandFingerprint + '.json'))
}

# The ok-only, worker-comparable elapsed samples. A run taken with a DIFFERENT
# worker ceiling is not comparable (more workers => faster), so a worker-count
# change yields too few comparable samples rather than a false regression.
function Get-ComparableOkSeconds {
    param($History, [int]$WorkerCeiling, [string]$ExcludeRunId = '')
    $out = New-Object System.Collections.Generic.List[double]
    if ($null -eq $History -or -not $History.PSObject.Properties['samples']) { return $out }
    foreach ($s in @($History.samples)) {
        if ($null -eq $s) { continue }
        # The run being judged has already been recorded by the runner, so exclude
        # it: a run must be compared against PRIOR history, never against itself.
        if ($ExcludeRunId -ne '' -and ([string](Get-Field $s 'runId')) -eq $ExcludeRunId) { continue }
        if (([string](Get-Field $s 'outcome')) -ne 'ok') { continue }
        $wc = -1; [void][int]::TryParse([string](Get-Field $s 'workerCeiling'), [ref]$wc)
        if ($wc -ne $WorkerCeiling) { continue }
        $sec = 0.0
        if ([double]::TryParse([string](Get-Field $s 'elapsedSeconds'), [ref]$sec) -and $sec -ge 0) { [void]$out.Add($sec) }
    }
    return $out
}

function Get-Median {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    $n = $v.Count
    if ($n -eq 0) { return 0.0 }
    if ($n % 2 -eq 1) { return [double]$v[($n - 1) / 2] }
    return ([double]$v[$n / 2 - 1] + [double]$v[$n / 2]) / 2.0
}

# A meaningful regression needs enough comparable ok history AND this run being
# both >= TimingRelFactor x and >= TimingAbsSeconds slower than the ROBUST median
# (so one earlier outlier neither redefines the baseline nor gets flagged). It is
# advisory by design - the caller decides how to surface it.
function Test-TimingRegression {
    param($History, [int]$WorkerCeiling, [double]$ElapsedSeconds, [string]$ExcludeRunId = '')
    # @() around the call: returning a List[double] unrolls to a bare double when it
    # holds one element, so re-wrap to a stable array before Count/Get-Median.
    $ok = @(Get-ComparableOkSeconds -History $History -WorkerCeiling $WorkerCeiling -ExcludeRunId $ExcludeRunId)
    $median = Get-Median -Values $ok
    $isReg = $false
    if ($ok.Count -ge $script:TimingMinBaseline -and $median -gt 0) {
        if ($ElapsedSeconds -ge ($median * $script:TimingRelFactor) -and ($ElapsedSeconds - $median) -ge $script:TimingAbsSeconds) { $isReg = $true }
    }
    return [pscustomobject]@{
        IsRegression   = $isReg
        Median         = [Math]::Round($median, 1)
        Samples        = $ok.Count
        ElapsedSeconds = [Math]::Round($ElapsedSeconds, 1)
        MinBaseline    = $script:TimingMinBaseline
    }
}

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
        [int]$TimeoutSeconds = 20
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
        $targetArgs = @($ArgumentList)
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
                    $targetArgs = @('/c', $targetPath) + $targetArgs
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
        if ($info.PSObject.Properties.Name -contains 'ArgumentList') {
            foreach ($argument in @($targetArgs)) { [void]$info.ArgumentList.Add([string]$argument) }
        }
        else {
            $info.Arguments = ConvertTo-Win32ArgumentString -ArgumentList @($targetArgs)
        }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # No window, no inherited stdin: a child that decides to prompt would
        # otherwise wait for input nobody is there to give.
        $info.RedirectStandardInput = $true
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
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
        try { [void]$stderrTask.GetAwaiter().GetResult() } catch { }
        $global:LASTEXITCODE = $process.ExitCode
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

# Kill a process AND everything it started. A `gh` that spawned a helper, or a
# package manager that shelled out, leaves the real work running if only the
# parent is killed.
function Get-GitHubRepository {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return $null }

    $remoteNames = @(Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'remote') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $valid = @{}
    foreach ($remoteName in $remoteNames) {
        $url = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'remote', 'get-url', [string]$remoteName))
        if ($LASTEXITCODE -ne 0) { continue }
        if ($url -match '^(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$') {
            $valid[[string]$remoteName] = ($Matches[1] + '/' + $Matches[2])
        }
    }
    if ($valid.Count -eq 0) { return $null }

    $branchName = ''
    $branchRaw = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', 'HEAD'))
    if ($LASTEXITCODE -eq 0 -and $branchRaw -ne '' -and $branchRaw -ne 'HEAD') { $branchName = $branchRaw }

    $branchRemote = ''
    if ($branchName -ne '') {
        $configuredRemote = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'config', '--get', ('branch.' + $branchName + '.remote')))
        if ($LASTEXITCODE -eq 0) { $branchRemote = $configuredRemote }
    }

    $selected = ''
    if ($branchRemote -ne '' -and $valid.ContainsKey($branchRemote)) { $selected = $branchRemote }
    if ($selected -eq '' -and $valid.ContainsKey('origin')) { $selected = 'origin' }
    if ($selected -eq '' -and $valid.Count -eq 1) { $selected = [string]@($valid.Keys)[0] }
    if ($selected -eq '') { return $null }

    # TrackingRef is the remote-tracking ref a caller may safely diff HEAD
    # against to decide "is HEAD pushed to the repository just selected". It is
    # populated ONLY when it is guaranteed to belong to $selected:
    # - the branch's own configured upstream, but only when that upstream's
    #   remote IS $selected (so @{upstream} cannot silently point at a
    #   different, possibly non-GitHub, remote than the repository resolved
    #   above); or
    # - a same-named remote-tracking branch under $selected, when the branch
    #   upstream doesn't match (or isn't configured at all).
    # Left empty when neither can be trusted - callers must then degrade
    # without claiming a pushed/verified state.
    $trackingRef = ''
    if ($branchName -ne '') {
        if ($branchRemote -eq $selected) {
            $upstreamRef = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', '@{upstream}'))
            if ($LASTEXITCODE -eq 0 -and $upstreamRef -ne '') { $trackingRef = $upstreamRef }
        }
        if ($trackingRef -eq '') {
            $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--verify', '--quiet', ('refs/remotes/' + $selected + '/' + $branchName))
            if ($LASTEXITCODE -eq 0) { $trackingRef = $selected + '/' + $branchName }
        }
    }

    return [pscustomobject]@{ Remote = $selected; Repository = [string]$valid[$selected]; Branch = $branchName; TrackingRef = $trackingRef }
}

# Deterministic per-project state fingerprint (HEAD sha + sorted status lines,
# hashed - never raw paths/content). Used to bind one hook's Stop-time result
# to the EXACT repository state another hook observes on a later Stop, so
# lifecycle hooks that fire concurrently on the same event (registration order
# is display-only, never execution order) can hand off state safely without
# racing: a consumer only trusts a producer's recorded state when this
# fingerprint still matches what the consumer observes right now.
function Get-RepoStateFingerprint {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') { return '' }
    $head = [string](Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', 'HEAD'))
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) { return '' }
    $status = @((Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain')) | Where-Object { $_ } | Sort-Object)
    if ($LASTEXITCODE -ne 0) { return '' }
    return Get-ShortHash ($head + '|' + ($status -join '|'))
}

function Get-LatestWorkTimeUtc {
    param([string]$ProjectRoot)
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return $null
    }
    $inside = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($LASTEXITCODE -ne 0 -or [string]$inside -ne 'true') {
        return $null
    }
    $latest = [DateTime]::MinValue
    $commitUnix = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'log', '-1', '--format=%ct')
    if ($LASTEXITCODE -eq 0 -and $commitUnix) {
        $latest = [DateTimeOffset]::FromUnixTimeSeconds([int64]([string]$commitUnix)).UtcDateTime
    }
    # -z, NOT plain --porcelain. With core.quotepath at its default git
    # OCTAL-ESCAPES any non-ASCII path in the human-readable form, so a modified
    # Persian or CJK filename arrived as "\331\276..." - a path that does not
    # exist, whose timestamp was therefore silently missed and the project looked
    # untouched since its last commit. Reproduced 2026-09-12: the hook reported the
    # commit time while a Persian file edited 2 s earlier sat on disk. -z emits the
    # real path bytes, NUL-separated and never quoted, so nothing needs unescaping.
    $status = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $ProjectRoot, 'status', '--porcelain', '-z')
    if ($LASTEXITCODE -eq 0) {
        # The helper drops empty lines, so rejoin before splitting on the real
        # separator; -z output carries no newlines of its own.
        $records = @((([string]::Join("`n", @($status))) -split [char]0) | Where-Object { $_ -ne '' })
        for ($recordIndex = 0; $recordIndex -lt $records.Count; $recordIndex++) {
            $lineText = [string]$records[$recordIndex]
            if ($lineText.Length -lt 4) { continue }
            # Under -z a rename/copy is TWO records: 'XY <new>' then '<old>'. Only
            # the destination exists on disk, so consume and discard the original
            # rather than testing a path that was moved away.
            $code = $lineText.Substring(0, 2)
            $relative = $lineText.Substring(3)
            if ($code.Contains('R') -or $code.Contains('C')) { $recordIndex++ }
            if ($relative -like '.ai/*' -or $relative -like 'graphify-out/*' -or $relative -like 'logs/*') { continue }
            try {
                $full = Join-Path $ProjectRoot ($relative.Replace('/', '\'))
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $modified = (Get-Item -LiteralPath $full -Force).LastWriteTimeUtc
                    if ($modified -gt $latest) { $latest = $modified }
                }
            }
            catch { }
        }
    }
    if ($latest -eq [DateTime]::MinValue) {
        return $null
    }
    return $latest
}
