# A self-hosted runner left running after its run finished (plan 046 item i;
# global-github-automation-rules.md -> Self-Hosted Runners: stopped as soon as
# its run has finished, never left running idle, and only by its own identity).
#
# THIS project's runner only: on Windows the processes whose executable lives
# under <project>\.ci-runner-win\ (a Runner.* name lookup, only when that folder
# exists); in WSL a read-only `pgrep -f /srv/ci/runners/<slug>/`, and only when a
# distro is ALREADY running - a stopped distro holds no live runner, and this
# hook never starts one. The hook reports; the agent stops the runner.

function Get-RunnerRepositorySlugForRoot {
    param([string]$ProjectRoot)
    $leaf = Split-Path -Leaf ([string]$ProjectRoot).TrimEnd('\', '/')
    return ([regex]::Replace($leaf.ToLowerInvariant(), '[^a-z0-9._-]+', '-')).Trim('-')
}

# Checked=$false means the question could not be answered (never an all-clear).
# IDLE is the finding: a Runner.Worker exists only while a job runs, so a runner
# that has one is busy (another branch, a PR, a re-run) and is never flagged -
# telling the agent to stop it would kill a live job.
function Get-LiveProjectRunner {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $none = [pscustomobject]@{ Checked = $false; Pids = @(); Stop = '' }
    $idleNone = [pscustomobject]@{ Checked = $true; Pids = @(); Stop = '' }
    $folder = Join-Path $ProjectRoot '.ci-runner-win'
    if ([IO.Directory]::Exists($folder)) {
        $prefix = $folder.TrimEnd('\') + '\'
        # The runner's own binaries are all named Runner.*, so a name lookup finds
        # them without WMI (a cold WMI enumeration can outlast any sane timeout).
        try {
            $procs = @(Get-Process -Name 'Runner.*' -ErrorAction SilentlyContinue |
                Where-Object { $exe = [string]$_.Path; $exe -ne '' -and $exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        }
        catch { return $none }
        if (@($procs | Where-Object { [string]$_.ProcessName -like 'Runner.Worker*' }).Count -gt 0) { return $idleNone }
        $pattern = [Management.Automation.WildcardPattern]::Escape($prefix).Replace("'", "''") + '*'
        return [pscustomobject]@{ Checked = $true; Pids = @($procs | ForEach-Object { [int]$_.Id } | Sort-Object)
            Stop = ('Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like ''' + $pattern + ''' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }') }
    }
    if (-not (Test-ManualSelfHostedRepo -ProjectRoot $ProjectRoot)) { return $none }
    $saved = $env:WSL_UTF8
    try {
        $env:WSL_UTF8 = '1'
        $running = @(Invoke-QuietCommand -FilePath 'wsl.exe' -ArgumentList @('--list', '--running', '--quiet') -TimeoutSeconds 5 |
            ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() } | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' })
        # wsl.exe answers non-zero when no distribution is running at all.
        if ($running.Count -eq 0) { return $idleNone }
        $path = '/srv/ci/runners/' + (Get-RunnerRepositorySlugForRoot -ProjectRoot $ProjectRoot) + '/'
        $found = New-Object System.Collections.Generic.List[int]
        $stopDistro = ''
        # Only distributions ALREADY running are asked, each by name: `-e` alone
        # targets the default distribution and would boot it if it is stopped.
        foreach ($distro in $running) {
            $busy = @(Invoke-QuietCommand -FilePath 'wsl.exe' -ArgumentList @('-d', $distro, '-e', 'pgrep', '-f', ($path + '.*Runner.Worker')) -TimeoutSeconds 5 |
                Where-Object { ([string]$_).Trim() -match '^\d+$' })
            if ($LASTEXITCODE -gt 1) { return $none }
            if ($busy.Count -gt 0) { return $idleNone }
            $pids = @(Invoke-QuietCommand -FilePath 'wsl.exe' -ArgumentList @('-d', $distro, '-e', 'pgrep', '-f', $path) -TimeoutSeconds 5 |
                ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^\d+$' })
            if ($LASTEXITCODE -gt 1) { return $none }
            if ($pids.Count -gt 0) { foreach ($id in $pids) { [void]$found.Add([int]$id) }; $stopDistro = $distro }
        }
        if ($found.Count -eq 0) { return $idleNone }
        return [pscustomobject]@{ Checked = $true; Pids = @($found.ToArray() | Sort-Object)
            Stop = ('wsl.exe -d ' + $stopDistro + ' -e pkill -f ''' + $path + '''') }
    }
    catch { return $none }
    finally { $env:WSL_UTF8 = $saved }
}

# The sentence a block carries, or '' when nothing of this project's runner is
# alive (or it could not be checked, which is never reported as clean or dirty).
function Get-RunnerLeftRunningText {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $live = Get-LiveProjectRunner -ProjectRoot $ProjectRoot
    if (-not $live.Checked -or @($live.Pids).Count -eq 0) { return '' }
    return ('This project''s CI runner is still running (pid ' + (@($live.Pids) -join ', ') + ') although its run has finished. Stop it now, before any other work: ' +
        $live.Stop + ' - then confirm it exited. Rule: global-github-automation-rules.md -> Self-Hosted Runners (stopped as soon as its run has finished, never left running idle).')
}

# Once the exact-SHA run has reached a terminal state: one block per unchanged
# (commit, runner pids) - a runner stopped and started again blocks again.
function Invoke-RunnerLeftRunningGate {
    param([string]$ProjectRoot, [string]$Sha, [string]$StateDir, $HookInput, [string]$EventName)
    $text = Get-RunnerLeftRunningText -ProjectRoot $ProjectRoot
    if ($text -eq '') { return }
    $fingerprint = Get-ShortHash ($Sha + '|' + $text)
    $path = Join-Path $StateDir ('CiStatusCheck-Runner-' + (Get-ShortHash $ProjectRoot.ToLowerInvariant()) + '.txt')
    try { if ([IO.File]::Exists($path) -and ([IO.File]::ReadAllText($path)).Trim() -eq $fingerprint) { return } } catch { }
    try { [void][IO.Directory]::CreateDirectory($StateDir); [IO.File]::WriteAllText($path, $fingerprint) } catch { }
    $emit = Write-StopBlockResult -HookInput $HookInput -HookName 'Ci-Status-Check' -EventName $EventName -Reason ('CI CHECK: ' + $text)
    exit $emit.ExitCode
}
