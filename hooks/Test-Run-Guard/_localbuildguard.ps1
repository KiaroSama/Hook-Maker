# Test-Run-Guard: local heavy/release build finding (steering V103). Data only: reads the
# already-tokenized command, never executes anything. Dot-sourced by Test-Run-Guard.ps1.
# GitHub Actions CI is the sole build route; lightweight checks are never matched.

function Test-LocalBuildBypass {
    param([string]$ProjectRoot)
    if ([string]$env:ALLOW_LOCAL_HEAVY_BUILD -eq '1') { return 'allow-env' }
    $dir = if ([string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) { '' } else { Join-Path $env:LOCALAPPDATA 'HookMaker\state' }
    if ($dir -eq '' -or -not [IO.Directory]::Exists($dir)) { return '' }
    # shortcut: the state file name hashes cwd+repo slug, so any fresh billing/quota record counts (<2 days), upgrade if slug is cheap to read.
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter 'CiStatusCheck-External-*.txt' -File -ErrorAction SilentlyContinue)) {
        if (((Get-Date) - $file.LastWriteTime).TotalDays -gt 2) { continue }
        try { $lines = @([IO.File]::ReadAllLines($file.FullName)) } catch { continue }
        if (($lines.Count -ge 3) -and (($lines[2] + ' ' + $(if ($lines.Count -ge 4) { $lines[3] } else { '' })) -match '(?i)billing|quota')) { return 'ci-billing-block' }
    }
    return ''
}

function Get-LocalHeavyBuildSegment {
    param([string[]]$Segment)
    $s = @($Segment)
    $envTokens = @($s | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' })
    $idx = -1
    for ($i = 0; $i -lt $s.Count; $i++) {
        if ($s[$i] -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
        $name = Get-ProgramName $s[$i]
        if ($name -in @('&', 'sudo', 'time', 'env', 'call')) { continue }
        $idx = $i; break
    }
    if ($idx -lt 0) { return '' }
    $prog = Get-ProgramName $s[$idx]
    $argv = @(@($s | Select-Object -Skip ($idx + 1)) | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $argText = ' ' + ($argv -join ' ') + ' '
    $summary = ($s | Select-Object -Skip $idx -First 6) -join ' '
    $sub = ''
    foreach ($a in $argv) { if (-not ($a.StartsWith('-') -or $a.StartsWith('+') -or $a.StartsWith('/'))) { $sub = $a; break } }
    $release = ($argText -match '\s(--release|-r)\s') -or ($argText -match '\s--profile[ =]release\s')
    if ($prog -eq 'cargo' -and (($sub -in @('build', 'b') -and $release) -or ($sub -eq 'zigbuild' -and $release))) { return $summary }
    if ($prog -eq 'cargo-zigbuild' -and $release) { return $summary }
    if ($prog -eq 'cross' -and $sub -eq 'build' -and $release) { return $summary }
    if ($prog -eq 'dotnet' -and $sub -eq 'publish' -and (($argText -match '\s(-c|--configuration)[ =]?release\s') -or ($argText -match '\s(-r|--runtime)\s'))) { return $summary }
    if ($prog -eq 'cmake' -and ($argText -match '\s--build\s') -and ($argText -match '\s--config[ =]release\s')) { return $summary }
    if ($prog -eq 'msbuild' -and ($argText -match '\s[/-]p:configuration=release\s')) { return $summary }
    if ($prog -eq 'go' -and $sub -eq 'build' -and (@($envTokens | Where-Object { $_ -match '^(?i)GOOS=' }).Count -gt 0) -and (@($envTokens | Where-Object { $_ -match '^(?i)GOARCH=' }).Count -gt 0)) {
        return (($envTokens + $summary) -join ' ')
    }
    return ''
}

function Get-LocalHeavyBuildFinding {
    param([string[]]$Tokens, [string]$ProjectRoot)
    $segment = New-Object Collections.Generic.List[string]
    $hit = ''
    foreach ($t in (@($Tokens) + @(';'))) {
        if ($t -in @(';', '&&', '||', '|', '&')) {
            if ($segment.Count -gt 0) { $hit = Get-LocalHeavyBuildSegment -Segment $segment.ToArray(); if ($hit -ne '') { break } }
            $segment.Clear()
        }
        else { [void]$segment.Add([string]$t) }
    }
    if ($hit -eq '') { return $null }
    if ((Test-LocalBuildBypass -ProjectRoot $ProjectRoot) -ne '') { return $null }
    return [pscustomobject]@{
        CommandSummary = $hit
        Reason = 'local heavy/release build: GitHub Actions CI is the sole build route unless the user approves a local build for this task or CI is confirmed billing/quota-blocked (ALLOW_LOCAL_HEAVY_BUILD=1). Compiled binaries live as ONE canonical copy in <project>/bin/<binary>.exe (POSIX <project>/bin/<binary>), zero duplicates, all paths/launchers/tests wired to bin/.'
    }
}
