# Test suite for scripts\Update-Fleet.ps1 - the non-interactive fleet updater.
#
# WHAT IT PINS, against the REAL installer and an isolated registry
# (HOOKMAKER_STATE_DIR in the throwaway workspace, the same isolation the
# registry-safety suite uses):
#   * a dry run reports the counts and changes nothing - not a project file,
#     not a registry record;
#   * -OnlyProject limits the run to one project;
#   * a -Marker absent from an otherwise current runtime makes it stale, and a
#     present one does not;
#   * -Apply after a source edit updates exactly the stale registrations, an
#     interrupted -Apply resumes by running again (the killed run's work is
#     not redone), and a further -Apply is a no-op;
#   * a project folder that is gone is reported unreachable, never failed;
#   * -Compare finds one deliberately altered installed file.
#
# Fixture: two standalone hook sources in the workspace (outside any hooks
# root, so only the script and the shared runtime library are installed), three
# throwaway projects, Claude client only. Nothing outside the workspace is
# written; the real registry and the real projects are never read or touched.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-UpdateFleet.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$Fleet = Join-Path $ScriptRoot 'Update-Fleet.ps1'

. (Join-Path $ScriptRoot '_testlib.ps1')

$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++; Write-Host ('[PASS] ' + $Name) -ForegroundColor Green }
    else {
        $script:Fail++
        Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('       ' + $Detail) -ForegroundColor DarkGray }
    }
}

$Work = New-TestWorkspace -Prefix 'hookmaker-updatefleet'
$PwshPath = (Get-Process -Id $PID).Path
$SafeCwd = Join-Path $Work 'safe-cwd'
New-Item -ItemType Directory -Path $SafeCwd -Force | Out-Null
$savedStateDir = $env:HOOKMAKER_STATE_DIR
$savedLogDir = $env:HOOKMAKER_LOG_DIR
$env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'
$env:HOOKMAKER_LOG_DIR = Join-Path $Work 'logs'
$script:RunIndex = 0
$interrupted = $null

function Invoke-Fleet {
    param([string[]]$Arguments = @())
    $script:RunIndex++
    $log = Join-Path $Work ('fleet-' + $script:RunIndex + '.log')
    $out = Join-Path $Work ('fleet-' + $script:RunIndex + '.out')
    $err = Join-Path $Work ('fleet-' + $script:RunIndex + '.err')
    $proc = Start-BoundedProcess -FilePath $PwshPath -WorkingDirectory $SafeCwd `
        -ArgumentList (@('-NoLogo', '-NoProfile', '-File', $Fleet, '-LogPath', $log) + $Arguments) `
        -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 300000
    $read = { param($p) if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { '' } }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = (& $read $out); Err = (& $read $err); Log = (& $read $log) }
}

# 'COUNTS current=4 stale=0 ...' -> hashtable.
function Get-Counts {
    param([string]$Text)
    $counts = @{}
    $line = @($Text -split "`r?`n" | Where-Object { $_ -like 'COUNTS *' }) | Select-Object -Last 1
    if ($null -eq $line) { return $counts }
    foreach ($pair in ($line.Substring(7) -split ' ')) {
        $parts = $pair -split '=', 2
        if ($parts.Count -eq 2) { $counts[$parts[0]] = [int]$parts[1] }
    }
    return $counts
}

function Test-Counts {
    param([hashtable]$Counts, [hashtable]$Expected)
    foreach ($key in $Expected.Keys) {
        if (-not $Counts.ContainsKey($key) -or $Counts[$key] -ne $Expected[$key]) { return $false }
    }
    return $true
}

function Format-Counts { param([hashtable]$Counts) return ((@($Counts.Keys | Sort-Object | ForEach-Object { $_ + '=' + $Counts[$_] })) -join ' ') }

# Every file's path, size, write time and hash, minus the lock files a reader
# legitimately rewrites.
function Get-TreeSnapshot {
    param([string[]]$Roots)
    $lines = foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            Where-Object { $_.Name -notlike '*.lock' -and $_.Name -notlike '*.hookmaker-lock' } |
            ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }
    return ((@($lines) | Sort-Object) -join "`n")
}

function Get-UpdatedLabels {
    param([string]$Log)
    return @([regex]::Matches($Log, '\] updated \| ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
}

try {
    # ---- fixture ---------------------------------------------------------------
    $sourceDir = Join-Path $Work 'sources'
    $alpha = Join-Path $sourceDir 'Fleet-Alpha.ps1'
    $beta = Join-Path $sourceDir 'Fleet-Beta.ps1'
    Write-Utf8 -Path $alpha -Content "exit 0`n"
    Write-Utf8 -Path $beta -Content "exit 0`n"
    $p1 = Join-Path $Work 'fleet one'
    $p2 = Join-Path $Work 'fleet-two'
    $p3 = Join-Path $Work 'fleet-gone'
    foreach ($p in @($p1, $p2, $p3)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    foreach ($pair in @(@($alpha, $p1), @($alpha, $p2), @($beta, $p1), @($beta, $p2), @($beta, $p3))) {
        & $InstallScript -CustomHook $pair[0] -Events @('Stop') -TargetProject $pair[1] -Clients @('claude') *> $null
    }
    $alphaRuntime = Join-Path $p1 '.claude\hooks\Hook-Maker\Fleet-Alpha\Fleet-Alpha.ps1'
    Check 'fixture: the real installer placed the runtimes' ((Test-Path -LiteralPath $alphaRuntime) -and
        (Test-Path -LiteralPath (Join-Path $p3 '.claude\hooks\Hook-Maker\Fleet-Beta\Fleet-Beta.ps1')))
    Remove-Item -LiteralPath $p3 -Recurse -Force
    $watched = @($p1, $p2, $env:HOOKMAKER_STATE_DIR)

    # ---- dry run: counts, nothing changed --------------------------------------
    $before = Get-TreeSnapshot $watched
    $run = Invoke-Fleet @()
    $counts = Get-Counts $run.Out
    Check 'dry run (the default) reports every registration current and the gone project unreachable' (
        $run.Exit -eq 0 -and (Test-Counts $counts @{ current = 4; stale = 0; 'pending-migration' = 0; unreachable = 1; skipped = 0 })) (
        (Format-Counts $counts) + ' exit=' + $run.Exit + ' ' + $run.Err)
    Check 'dry run changed no project file and no registry record' ((Get-TreeSnapshot $watched) -ceq $before)
    Check 'the log carries one line per registration' (
        ([regex]::Matches($run.Log, '\] ok \| ')).Count -eq 4 -and ([regex]::Matches($run.Log, '\] unreachable \| ')).Count -eq 1) $run.Log

    $run = Invoke-Fleet @('-OnlyProject', 'fleet one')
    $counts = Get-Counts $run.Out
    Check '-OnlyProject limits the run to that project' ($run.Exit -eq 0 -and (Test-Counts $counts @{ current = 2; unreachable = 0 })) (Format-Counts $counts)
    $run = Invoke-Fleet @('-OnlyProject', 'no-such-project')
    Check '-OnlyProject that matches nothing exits 1' ($run.Exit -eq 1) $run.Out

    # ---- markers ---------------------------------------------------------------
    $run = Invoke-Fleet @('-Marker', '_hooklib.ps1')
    Check 'a marker present in every runtime keeps them current' ((Get-Counts $run.Out)['current'] -eq 4) $run.Out
    $run = Invoke-Fleet @('-Marker', ('_hooklib.ps1:NO-SUCH-TEXT-' + [guid]::NewGuid().ToString('N')))
    $counts = Get-Counts $run.Out
    Check 'a marker pattern absent from an otherwise current runtime makes it stale' (
        $run.Exit -eq 0 -and (Test-Counts $counts @{ current = 0; stale = 4 }) -and $run.Out.Contains('marker missing')) (Format-Counts $counts)
    Check 'a marker dry run still changed nothing' ((Get-TreeSnapshot $watched) -ceq $before)

    # ---- source edit -> stale -> interrupted apply -> resume -> no-op ------------
    Write-Utf8 -Path $alpha -Content "# fleet v2`nexit 0`n"
    $before = Get-TreeSnapshot $watched
    $run = Invoke-Fleet @('-WhatIf')
    $counts = Get-Counts $run.Out
    Check 'after a source edit exactly the two registrations of that hook are stale' (
        $run.Exit -eq 0 -and (Test-Counts $counts @{ current = 2; stale = 2 })) (Format-Counts $counts)
    Check '-WhatIf changed nothing' ((Get-TreeSnapshot $watched) -ceq $before)

    $killLog = Join-Path $Work 'fleet-interrupted.log'
    $interrupted = Start-Process -FilePath $PwshPath -WorkingDirectory $SafeCwd -NoNewWindow -PassThru `
        -ArgumentList (ConvertTo-ProcessArgumentString @('-NoLogo', '-NoProfile', '-File', $Fleet, '-Apply', '-LogPath', $killLog)) `
        -RedirectStandardOutput (Join-Path $Work 'fleet-interrupted.out') -RedirectStandardError (Join-Path $Work 'fleet-interrupted.err')
    $deadline = [DateTime]::UtcNow.AddSeconds(240)
    $firstUpdated = @()
    while ([DateTime]::UtcNow -lt $deadline -and -not $interrupted.HasExited) {
        if (Test-Path -LiteralPath $killLog) {
            $firstUpdated = @(Get-UpdatedLabels ([System.IO.File]::ReadAllText($killLog)))
            if ($firstUpdated.Count -gt 0) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $interrupted.HasExited) { Stop-Process -Id $interrupted.Id -Force -ErrorAction SilentlyContinue }
    [void]$interrupted.WaitForExit(30000)
    if ($firstUpdated.Count -eq 0 -and (Test-Path -LiteralPath $killLog)) { $firstUpdated = @(Get-UpdatedLabels ([System.IO.File]::ReadAllText($killLog))) }
    Check 'the interrupted run updated one registration before it was killed' ($firstUpdated.Count -ge 1) ([string]($firstUpdated -join ','))

    $run = Invoke-Fleet @('-Apply')
    $resumed = @(Get-UpdatedLabels $run.Log)
    $counts = Get-Counts $run.Out
    Check 'the resumed -Apply succeeds with the gone project unreachable, not failed' ($run.Exit -eq 0 -and $counts['unreachable'] -eq 1) (
        'exit=' + $run.Exit + ' ' + $run.Out + ' ' + $run.Err)
    Check 'the resumed run does not redo what the killed run finished' (
        $firstUpdated.Count -ge 1 -and @($resumed | Where-Object { $firstUpdated -contains $_ }).Count -eq 0) (
        'killed: ' + ($firstUpdated -join ',') + ' resumed: ' + ($resumed -join ','))
    Check 'only the edited hook was ever updated' (@(@($firstUpdated) + @($resumed) | Where-Object { $_ -notlike '*/Fleet-Alpha/*' }).Count -eq 0) (
        (@($firstUpdated) + @($resumed)) -join ',')
    Check 'the edited source reached the runtime' ([System.IO.File]::ReadAllText($alphaRuntime).Contains('fleet v2'))

    $run = Invoke-Fleet @('-Apply')
    $counts = Get-Counts $run.Out
    Check 'a second -Apply is a no-op' (
        $run.Exit -eq 0 -and @(Get-UpdatedLabels $run.Log).Count -eq 0 -and (Test-Counts $counts @{ current = 4; stale = 0 })) (
        (Format-Counts $counts) + ' ' + $run.Out)

    # ---- compare ---------------------------------------------------------------
    $run = Invoke-Fleet @('-Compare')
    Check '-Compare alone on a clean fleet finds nothing and exits 0' (
        $run.Exit -eq 0 -and $run.Out -match 'COMPARE .*registrations=4 .*missing=0 different=0 errors=0 unreachable=1' -and
        -not $run.Out.Contains('COUNTS ')) $run.Out
    $altered = Join-Path $p2 '.claude\hooks\Hook-Maker\Fleet-Alpha\Fleet-Alpha.ps1'
    [System.IO.File]::AppendAllText($altered, "# edited in place`n")
    $run = Invoke-Fleet @('-Compare')
    Check '-Compare finds the one altered installed file and names its project' (
        $run.Exit -eq 1 -and $run.Out -match 'COMPARE .*missing=0 different=1 ' -and $run.Out.Contains($p2)) $run.Out
}
finally {
    if ($null -ne $interrupted -and -not $interrupted.HasExited) { Stop-Process -Id $interrupted.Id -Force -ErrorAction SilentlyContinue }
    $env:HOOKMAKER_STATE_DIR = $savedStateDir
    $env:HOOKMAKER_LOG_DIR = $savedLogDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace -Path @($Work))) { $script:Fail++ ; Write-Host '[FAIL] workspace cleanup left files behind' -ForegroundColor Red }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
