# Tiny offline traversal fixture shared by the baseline suite and its focused mode.
function Invoke-AdvisoryScopeRegression {
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot '_scope.ps1')
    $root = Join-Path $Work 'advisory-scope'
    $utf8 = [Text.UTF8Encoding]::new($false)
    foreach ($name in @('package.json', 'plans/archive/Cargo.toml', 'specs/sample/package.json', '.specify/package.json', 'src/plans/package.json', 'node_modules/pkg/package.json')) {
        $path = Join-Path $root $name
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, '{}', $utf8)
    }
    if (-not (Get-Command Get-AdvisoryProjectFiles -ErrorAction SilentlyContinue)) {
        Check 'advisory discovery provides bounded project-only traversal' $false
        return
    }
    $result = Get-AdvisoryProjectFiles -ProjectRoot $root -ExcludedDirs (Get-HookExcludedDirs)
    $relative = @($result.Files | ForEach-Object { $_.Substring($root.Length + 1).Replace('\', '/') } | Sort-Object)
    Check 'root scratch manifests omitted, nested production manifests retained' ($result.Complete -and ($relative -join '|') -ceq 'package.json|src/plans/package.json') ($relative -join '|')
    foreach ($case in @(
        @{Args = @{MaxEntries = 1}; Reason = 'entryLimit'},
        @{Args = @{MaxDirectories = 1}; Reason = 'directoryLimit'},
        @{Args = @{MaxDepth = 0}; Reason = 'depthLimit'},
        @{Args = @{TimeoutMilliseconds = 0}; Reason = 'timeLimit'}
    )) {
        $arguments = $case.Args
        $limited = Get-AdvisoryProjectFiles -ProjectRoot $root -ExcludedDirs (Get-HookExcludedDirs) @arguments
        Check ('advisory discovery explicitly reports ' + $case.Reason) (-not $limited.Complete -and $limited.Reasons -contains $case.Reason)
    }
    & {
        function Get-HookRemainingSeconds { return 0 }
        $expired = Get-AdvisoryProjectFiles -ProjectRoot $root
        Check 'advisory traversal honors exhausted registered deadline' (-not $expired.Complete -and $expired.Reasons -contains 'timeLimit' -and $expired.Files.Count -eq 0)
    }
    $missing = Get-AdvisoryProjectFiles -ProjectRoot (Join-Path $root 'missing')
    Check 'unreadable discovery is unknown, never a clean empty result' (-not $missing.Complete -and $missing.Reasons -contains 'readError')
}

function Invoke-AdvisoryBaselineRegression {
    $utf8 = [Text.UTF8Encoding]::new($false)
    foreach ($hostName in @('pwsh', 'powershell.exe')) {
        if ($hostName -eq 'powershell.exe' -and -not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) { continue }
        $repo = New-GitRepo ('advisory-root-scope-' + $hostName)
        foreach ($name in @('plans/research/Cargo.toml', 'specs/sample/build.gradle', '.specify/package.json', 'src/plans/package.json')) {
            $path = Join-Path $repo $name
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [IO.File]::WriteAllText($path, '{}', $utf8)
        }
        $result = Fire -HookPath $BaselineHook -Cwd (Join-Path $repo 'src') -Exe $(if ($hostName -eq 'powershell.exe') { $hostName } else { '' })
        Check ('actual baseline retains nested production, excludes root research: ' + $hostName) (
            $result.Exit -eq 0 -and $result.Err -eq '' -and $result.Out -match 'npm at /src/plans' -and
            $result.Out -notmatch 'cargo at|gradle at|npm at /\.specify|cargo detected|discovery is partial') $result.Out
    }
}
