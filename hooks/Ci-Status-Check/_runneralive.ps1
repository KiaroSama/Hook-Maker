# A self-hosted runner left running after its run finished (plan 046 item i;
# global-github-automation-rules.md -> Self-Hosted Runners: stopped as soon as
# its run has finished, never left running idle, and only by its own identity).
#
# THIS project's runner only: on Windows the processes whose executable lives
# under <project>\.ci-runner-win\ (one bounded CIM query, only when that folder
# exists); in WSL a read-only `pgrep -f /srv/ci/runners/<slug>/`, and only when a
# distro is ALREADY running - a stopped distro holds no live runner, and this
# hook never starts one. The hook reports; the agent stops the runner.

function Get-RunnerRepositorySlugForRoot {
    param([string]$ProjectRoot)
    $leaf = Split-Path -Leaf ([string]$ProjectRoot).TrimEnd('\', '/')
    return ([regex]::Replace($leaf.ToLowerInvariant(), '[^a-z0-9._-]+', '-')).Trim('-')
}

# Checked=$false means the question could not be answered (never an all-clear).
function Get-LiveProjectRunner {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $none = [pscustomobject]@{ Checked = $false; Pids = @(); Stop = '' }
    $folder = Join-Path $ProjectRoot '.ci-runner-win'
    if ([IO.Directory]::Exists($folder)) {
        $prefix = $folder.TrimEnd('\') + '\'
        try {
            $procs = @(Get-CimInstance -ClassName Win32_Process -Property @('ProcessId', 'ExecutablePath') -OperationTimeoutSec 5 -ErrorAction Stop |
                Where-Object { $exe = [string]$_.ExecutablePath; $exe -ne '' -and $exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        }
        catch { return $none }
        return [pscustomobject]@{ Checked = $true; Pids = @($procs | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
            Stop = ('Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like ''' + $prefix + '*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }') }
    }
    if (-not (Test-ManualSelfHostedRepo -ProjectRoot $ProjectRoot)) { return $none }
    $saved = $env:WSL_UTF8
    try {
        $env:WSL_UTF8 = '1'
        $running = @(Invoke-QuietCommand -FilePath 'wsl.exe' -ArgumentList @('--list', '--running', '--quiet') -TimeoutSeconds 5 |
            ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() } | Where-Object { $_ -ne '' })
        if ($LASTEXITCODE -ne 0) {
            # wsl.exe answers non-zero when no distribution is running at all.
            if ($running.Count -eq 0) { return [pscustomobject]@{ Checked = $true; Pids = @(); Stop = '' } }
            return $none
        }
        if ($running.Count -eq 0) { return [pscustomobject]@{ Checked = $true; Pids = @(); Stop = '' } }
        $path = '/srv/ci/runners/' + (Get-RunnerRepositorySlugForRoot -ProjectRoot $ProjectRoot) + '/'
        $found = @(Invoke-QuietCommand -FilePath 'wsl.exe' -ArgumentList @('-e', 'pgrep', '-f', $path) -TimeoutSeconds 5 |
            ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^\d+$' })
        if ($LASTEXITCODE -gt 1) { return $none }
        return [pscustomobject]@{ Checked = $true; Pids = @($found | ForEach-Object { [int]$_ } | Sort-Object); Stop = ('wsl.exe -e pkill -f ''' + $path + '''') }
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
