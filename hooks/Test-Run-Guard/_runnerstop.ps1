# CI runner stops, read as DATA (global-github-automation-rules.md -> Self-Hosted
# Runners): every project has its own runner and it is stopped only by its own
# identity - the pid of the run.cmd/run.sh the agent started, or the processes
# whose executable lives under THIS project's runner folder. A stop by name or
# wildcard (taskkill /IM Runner.Listener.exe, Stop-Process -Name Runner*,
# pkill Runner.Listener, Stop-Service "actions.runner.*" - the wildcard of
# GitHub's own service example) also stops every other project's runner and the
# job it is running, so it is refused with the project-scoped stop. `wsl
# --shutdown` / `--terminate` stop every WSL runner too, but the user may want
# them for other reasons, so they are advised against, never refused.
#
# Nothing here executes or evaluates anything: segments come from the shared
# tokenizer, and a quoted or heredoc body that merely CONTAINS a runner name is
# data, never a program.

# Does this value name the runner processes by name or pattern (not by pid)?
function Test-RunnerImageToken {
    param([string]$Value)
    if (([string]$Value).Contains(',')) { return (@(([string]$Value).Split(',') | Where-Object { Test-RunnerImageToken $_ }).Count -gt 0) }
    $v = ([string]$Value).Trim().ToLowerInvariant()
    if ($v -eq '') { return $false }
    if ($v -match '^runner\.(listener|worker)(\.exe)?$') { return $true }
    # A pattern that can match either image: Runner*, Runner.*, Runner.L*.
    return ($v.StartsWith('runner') -and ($v.Contains('*') -or $v.Contains('?')))
}

# A service name that matches more than one runner service.
function Test-RunnerServiceWildcard {
    param([string]$Value)
    $v = ([string]$Value).Trim().ToLowerInvariant()
    return ($v.StartsWith('actions.runner') -and ($v.Contains('*') -or $v.Contains('?')))
}

# Drops the launch wrappers that do not change what runs: `sudo`, `wsl.exe -e`,
# `wsl.exe --`, `wsl -d <distro> --`/`-e`, and PowerShell's call operator.
function Get-RunnerSegmentProgramIndex {
    param([string[]]$Segment)
    $i = 0
    while ($i -lt $Segment.Count) {
        $name = Get-ProgramName $Segment[$i]
        if ($name -eq '&') { $i++; continue }
        if ($name -eq 'sudo') {
            $i++
            while ($i -lt $Segment.Count -and $Segment[$i].StartsWith('-')) { if ($Segment[$i] -in @('-u', '-g', '-C', '-h', '-p', '-U', '-D', '-R', '-T')) { $i += 2 } else { $i++ } }
            continue
        }
        if ($name -eq 'wsl') {
            $j = $i + 1
            while ($j -lt $Segment.Count -and $Segment[$j] -notin @('-e', '--exec', '--')) {
                if ($Segment[$j] -in @('-d', '--distribution', '-u', '--user', '--cd')) { $j += 2 } else { $j++ }
            }
            if ($j -ge $Segment.Count) { return $i }
            $i = $j + 1
            continue
        }
        return $i
    }
    return -1
}

function Get-RunnerRepositorySlug {
    param([string]$ProjectRoot)
    $leaf = Split-Path -Leaf ([string]$ProjectRoot).TrimEnd('\', '/')
    return ([regex]::Replace($leaf.ToLowerInvariant(), '[^a-z0-9._-]+', '-')).Trim('-')
}

function Get-RunnerStopReplacement {
    param([string]$ProjectRoot, [bool]$Wsl)
    $slug = Get-RunnerRepositorySlug -ProjectRoot $ProjectRoot
    if ($Wsl) {
        return 'Stop only this project''s runner: pkill -f ''/srv/ci/runners/' + $slug + '/'' (or kill the pid of the run.sh you started), then confirm it exited.'
    }
    $folder = [Management.Automation.WildcardPattern]::Escape((Join-Path $ProjectRoot '.ci-runner-win').TrimEnd('\') + '\').Replace("'", "''") + '*'
    return ('Stop only this project''s runner: Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like ''' + $folder +
        ''' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } (or taskkill /PID <pid of the run.cmd you started> /T), then confirm each exited.')
}

# $null, or @{ Deny; Message } for the first runner stop found in the command.
function Get-RunnerStopFinding {
    param([string[]]$Tokens, [string]$ProjectRoot)
    $segments = @(Split-CommandSegments -Tokens @($Tokens))
    $rule = ' Rule: global-github-automation-rules.md -> Self-Hosted Runners (one runner per project, stopped only by its own identity).'
    $lead = 'TEST RUN GUARD: this stops CI runners by name or wildcard, which also stops every other project''s runner and the job it is running. '
    $slug = Get-RunnerRepositorySlug -ProjectRoot $ProjectRoot
    for ($s = 0; $s -lt $segments.Count; $s++) {
        $segment = @($segments[$s])
        $start = Get-RunnerSegmentProgramIndex -Segment $segment
        if ($start -lt 0) { continue }
        $program = Get-ProgramName $segment[$start]
        $rest = @($segment | Select-Object -Skip ($start + 1))
        $viaWsl = ($start -gt 0 -and @($segment[0..($start - 1)] | Where-Object { (Get-ProgramName $_) -eq 'wsl' }).Count -gt 0)
        $byName = $false; $wsl = $viaWsl
        switch ($program) {
            'taskkill' {
                for ($k = 0; $k -lt $rest.Count - 1; $k++) {
                    if ($rest[$k] -in @('/im', '/IM', '-im', '-IM', '/Im', '/iM') -and (Test-RunnerImageToken $rest[$k + 1])) { $byName = $true }
                }
            }
            { $_ -in @('stop-process', 'spps', 'kill') } {
                for ($k = 0; $k -lt $rest.Count - 1; $k++) {
                    if ($rest[$k] -match '^-(n|na|nam|name|pr|pro|proc|proce|proces|process|processn|processna|processnam|processname)$' -and (Test-RunnerImageToken $rest[$k + 1])) { $byName = $true }
                }
            }
            { $_ -in @('get-process', 'gps') } {
                # Get-Process Runner* | Stop-Process: the pattern selects every runner.
                $named = @($rest | Where-Object { $_ -notmatch '^-' -and (Test-RunnerImageToken $_) }).Count -gt 0
                if ($named -and $s + 1 -lt $segments.Count) {
                    $next = @($segments[$s + 1])
                    if ($next.Count -gt 0 -and (Get-ProgramName $next[0]) -in @('stop-process', 'spps', 'kill')) { $byName = $true }
                }
            }
            { $_ -in @('pkill', 'killall') } {
                $wsl = $true
                $ownPath = '/srv/ci/runners/' + $slug + '/'
                foreach ($arg in $rest) {
                    if ($arg -match '^-') { continue }
                    $a = $arg.ToLowerInvariant()
                    if ($a.Contains($ownPath)) { continue }
                    if ($a.Contains('runner.listener') -or $a.Contains('runner.worker') -or $a -eq 'run.sh' -or $a.EndsWith('/run.sh') -or
                        $a.Contains('actions.runner') -or $a.Contains('/srv/ci/runners')) { $byName = $true }
                }
            }
            { $_ -in @('stop-service', 'restart-service', 'spsv') } {
                if (@($rest | Where-Object { Test-RunnerServiceWildcard $_ }).Count -gt 0) { $byName = $true }
            }
            { $_ -in @('get-service', 'gsv') } {
                if (@($rest | Where-Object { Test-RunnerServiceWildcard $_ }).Count -gt 0 -and $s + 1 -lt $segments.Count) {
                    $next = @($segments[$s + 1])
                    if ($next.Count -gt 0 -and (Get-ProgramName $next[0]) -in @('stop-service', 'restart-service', 'spsv')) { $byName = $true }
                }
            }
            { $_ -in @('sc', 'net') } {
                if ($rest.Count -ge 2 -and $rest[0].ToLowerInvariant() -eq 'stop' -and (Test-RunnerServiceWildcard $rest[1])) { $byName = $true }
            }
            'systemctl' {
                $wsl = $true
                if (@($rest | Where-Object { $_ -in @('stop', 'restart', 'kill') }).Count -gt 0 -and
                    @($rest | Where-Object { Test-RunnerServiceWildcard $_ }).Count -gt 0) { $byName = $true }
            }
            'wsl' {
                $flag = @($rest | Where-Object { $_ -in @('--shutdown', '--terminate', '-t') })
                if ($flag.Count -gt 0) {
                    return [pscustomobject]@{ Deny = $false; Message = ('TEST RUN GUARD: `wsl ' + $flag[0] +
                        '` stops every WSL CI runner too, and the job each one is running - another project''s included. If you only meant to stop this project''s runner: ' +
                        (Get-RunnerStopReplacement -ProjectRoot $ProjectRoot -Wsl $true) + $rule) }
                }
            }
        }
        if ($byName) {
            return [pscustomobject]@{ Deny = $true; Message = ($lead + (Get-RunnerStopReplacement -ProjectRoot $ProjectRoot -Wsl $wsl) + $rule) }
        }
    }
    return $null
}
