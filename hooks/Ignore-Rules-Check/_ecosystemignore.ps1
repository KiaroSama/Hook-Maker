# Per-ecosystem .gitignore blocks and tracked lockfiles (steering V89-V91, spec 041).
#
# The universal minimum is enforced by the hook itself. This file adds the
# ecosystem layer from global-ignore-rules.md: a block per toolchain the project
# ACTUALLY uses (manifest-gated, never speculative), and the rule that
# application lockfiles stay tracked.
#
# REPORT ONLY by default (user decision, 2026-11-17): an ecosystem line is a
# convention, not a leak, so it never blocks and is written only with
# ECOSYSTEM_PATTERNS=write. Writing only ever APPENDS missing lines under one
# header; existing lines are never deleted or reordered.

$script:EcosystemIgnoreLists = [ordered]@{
    'Rust'        = @('/target/', '**/target/', '/debug/', '**/*.rs.bk', '*.pdb', '**/mutants.out*/', 'rustc-ice-*.txt', '/.cargo/*', '!/.cargo/config.toml', '**/.cargo/credentials*', '/vendor/', '*.profraw', '*.profdata', 'lcov.info', 'tarpaulin-report.*', 'cobertura.xml', 'flamegraph.svg', 'perf.data', 'perf.data.old', '/criterion/')
    'Python'      = @('__pycache__/', '*.py[cod]', '*.so', '.venv/', 'venv/', 'build/', 'dist/', '*.egg-info/', '.eggs/', '.pytest_cache/', '.mypy_cache/', '.ruff_cache/', '.tox/', '.nox/', '.coverage', '.coverage.*', 'htmlcov/', 'coverage.xml', '.hypothesis/', '.ipynb_checkpoints/', '__pypackages__/')
    'Node'        = @('node_modules/', 'dist/', 'build/', 'out/', '.next/', '.nuxt/', '.output/', '.svelte-kit/', '.turbo/', '.vercel/', '.wrangler/', 'coverage/', '.nyc_output/', '*.tsbuildinfo', '.eslintcache', '.cache/', '.parcel-cache/', 'npm-debug.log*', 'yarn-debug.log*', 'yarn-error.log*', '.pnpm-store/', '.yarn/*', '!.yarn/patches', '!.yarn/plugins', '!.yarn/releases')
    '.NET'        = @('[Bb]in/', '[Oo]bj/', '.vs/', '*.user', '*.suo', '*.rsuser', '[Tt]est[Rr]esult*/', '*.trx', 'artifacts/', '*.nupkg', '*.snupkg', '.nuget/packages/')
    'C/C++'       = @('build/', '[Bb]uild-*/', 'cmake-build-*/', 'CMakeFiles/', 'CMakeCache.txt', 'cmake_install.cmake', 'compile_commands.json', '*.o', '*.obj', '*.a', '*.lib', '*.so', '*.dylib', '*.dll', '*.exe', '*.pdb', '*.ilk', '*.pch', '*.gch', 'vcpkg_installed/', '.cache/')
    'Go'          = @('*.exe', '*.test', '*.out', 'coverage.*', '*.coverprofile', '/bin/', '/dist/')
    'Java/Kotlin' = @('*.class', '*.jar', '*.war', '*.ear', 'target/', 'build/', '.gradle/', 'out/', '.kotlin/', 'hs_err_pid*', 'replay_pid*', '*.iml', '!gradle/wrapper/gradle-wrapper.jar')
    'Swift'       = @('.build/', '.swiftpm/', 'DerivedData/', 'xcuserdata/', '*.xcuserstate', '*.hmap', '*.ipa', '*.dSYM', '*.dSYM.zip', 'Carthage/Build/', 'fastlane/report.xml', 'fastlane/test_output/')
    'Dart'        = @('.dart_tool/', 'build/', '.flutter-plugins', '.flutter-plugins-dependencies', '.packages', 'doc/api/')
}
$script:EcosystemManifests = [ordered]@{
    'Rust' = @('Cargo.toml'); 'Python' = @('pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile')
    'Node' = @('package.json'); '.NET' = @('*.sln', '*.csproj', '*.fsproj', 'Directory.Build.props'); 'C/C++' = @('CMakeLists.txt', 'meson.build')
    'Go' = @('go.mod'); 'Java/Kotlin' = @('pom.xml', 'build.gradle', 'build.gradle.kts', 'settings.gradle.kts'); 'Swift' = @('Package.swift'); 'Dart' = @('pubspec.yaml')
}
$script:TrackedLockfiles = @('Cargo.lock', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'poetry.lock', 'uv.lock', 'go.sum', 'pubspec.lock', 'Package.resolved', 'packages.lock.json')

# `/target/`, `target/` and `**/target/` read the same to a human reviewer; the
# report is about a missing CONVENTION, so an equivalent spelling counts.
function ConvertTo-EcosystemKey { param([string]$Line) return ($Line.Trim() -replace '^(\*\*/|/)+', '').ToLowerInvariant() }

# Ecosystems whose manifest sits at the root (or, for .NET, one folder down).
function Get-ProjectEcosystems {
    param([Parameter(Mandatory = $true)][string]$Cwd)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:EcosystemManifests.Keys) {
        foreach ($pattern in $script:EcosystemManifests[$name]) {
            $hit = @(Get-ChildItem -LiteralPath $Cwd -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($hit.Count -eq 0 -and $name -eq '.NET' -and $pattern -like '*proj') {
                $hit = @(Get-ChildItem -LiteralPath $Cwd -Directory -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter $pattern -File -ErrorAction SilentlyContinue } | Select-Object -First 1)
            }
            if ($hit.Count -gt 0) { [void]$found.Add($name); break }
        }
    }
    return @($found)
}

# Returns @{ Missing = [ordered] ecosystem -> lines; Lockfiles = notes; Written = count }.
function Get-EcosystemIgnoreFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Cwd, [string[]]$ExistingLines = @(), [string[]]$TrackedFiles = @(),
        [ValidateSet('report', 'write')][string]$Mode = 'report'
    )
    $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in $ExistingLines) { if ($line.Trim() -ne '' -and -not $line.Trim().StartsWith('#')) { [void]$have.Add((ConvertTo-EcosystemKey $line)) } }
    $missing = [ordered]@{}
    $append = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(Get-ProjectEcosystems -Cwd $Cwd)) {
        $lack = @($script:EcosystemIgnoreLists[$name] | Where-Object { -not $have.Contains((ConvertTo-EcosystemKey $_)) })
        if ($lack.Count -eq 0) { continue }
        $missing[$name] = $lack
        [void]$append.Add('# ' + $name)
        foreach ($item in $lack) { [void]$append.Add($item); [void]$have.Add((ConvertTo-EcosystemKey $item)) }
    }
    $written = 0
    if ($Mode -eq 'write' -and $missing.Count -gt 0) {
        $path = Join-Path $Cwd '.gitignore'
        $text = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) } else { '' }
        $prefix = $text.TrimEnd(); if ($prefix -ne '') { $prefix += "`n`n" }
        [IO.File]::WriteAllText($path, $prefix + '# Hook Maker: ecosystem ignores (ECOSYSTEM_PATTERNS=write)' + "`n" + ($append -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        $written = ($append | Where-Object { -not $_.StartsWith('# ') }).Count
    }
    # Lockfiles: present on disk but untracked, or matched by an ignore rule.
    $present = @($script:TrackedLockfiles | Where-Object { [IO.File]::Exists((Join-Path $Cwd $_)) })
    $notes = New-Object System.Collections.Generic.List[string]
    if ($present.Count -gt 0) {
        $ignored = @()
        $probe = Invoke-QuietCommand -FilePath git -ArgumentList (@('-C', $Cwd, 'check-ignore', '--no-index', '--') + $present) -CaptureOutput
        if ($null -ne $probe -and $probe.ExitCode -in @(0, 1)) { $ignored = @(([string]$probe.Output) -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        foreach ($lock in $present) {
            if ($ignored -contains $lock) { [void]$notes.Add($lock + ' ignored') }
            elseif ($TrackedFiles -notcontains $lock) { [void]$notes.Add($lock + ' untracked') }
        }
    }
    return [pscustomobject]@{ Missing = $missing; Lockfiles = @($notes); Written = $written }
}

# One advisory line, or '' (nothing new). Said once per finding set per project.
function Get-EcosystemIgnoreLine {
    param([Parameter(Mandatory = $true)]$Finding, [Parameter(Mandatory = $true)][string]$Cwd)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Finding.Missing.Keys) {
        $lack = @($Finding.Missing[$name])
        $shown = ($lack | Select-Object -First 4) -join ' '
        if ($lack.Count -gt 4) { $shown += ' +' + ($lack.Count - 4) }
        [void]$parts.Add($name + ': ' + $shown)
    }
    $line = ''
    if ($parts.Count -gt 0) {
        $verb = if ($Finding.Written -gt 0) { 'Appended ecosystem ignores' } else { 'Ecosystem ignores missing (ECOSYSTEM_PATTERNS=write appends)' }
        $line = $verb + ' - ' + ($parts -join '; ')
    }
    if (@($Finding.Lockfiles).Count -gt 0) {
        if ($line -ne '') { $line += "`n" }
        $line += 'Lockfiles must stay tracked: ' + (@($Finding.Lockfiles) -join ', ')
    }
    if ($line -eq '') { return '' }
    $state = Join-Path $env:LOCALAPPDATA ('HookMaker\state\IgnoreRulesCheck-eco-' + (Get-ShortHash $Cwd.ToLowerInvariant()) + '.txt')
    $fp = Get-ShortHash $line
    try { if ([IO.File]::Exists($state) -and ([IO.File]::ReadAllText($state)).Trim() -eq $fp) { return '' } } catch { }
    try { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $state)); [IO.File]::WriteAllText($state, $fp) } catch { }
    return $line
}
