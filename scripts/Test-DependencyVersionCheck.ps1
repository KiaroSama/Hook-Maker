# Offline test suite for Dependency-Version-Check.
#
# npm and pip are replaced by PATH shims (npm.ps1 / pip.ps1, same convention as the `gh` shim in
# Test-CiStatusCheck.ps1) that serve canned JSON and a controllable exit code from
# $env:DEPVER_MOCK_DIR, plus record every invocation (directory + args) so cache/cooldown
# behavior can be asserted deterministically. No live npm/PyPI registry calls happen in this
# suite. GitHub Actions, runtime-pin, and Docker base-image checks are fully static (no
# command/network dependency) and are exercised directly with real fixture files.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-DependencyVersionCheck.ps1 [-KeepArtifacts]

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks\Dependency-Version-Check\Dependency-Version-Check.ps1'
if (-not (Test-Path -LiteralPath $Hook -PathType Leaf)) {
    Write-Host "Hook not found: $Hook" -ForegroundColor Red
    exit 1
}
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 400
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-depvertest'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$FakeLocalAppData = Join-Path $Work '_fakelocal'
New-Item -ItemType Directory -Path $FakeLocalAppData -Force | Out-Null
$ProjsRoot = Join-Path $Work '_projs'
New-Item -ItemType Directory -Path $ProjsRoot -Force | Out-Null

# ---- npm/pip shims: same PATH-override convention as the `gh` shim in Test-CiStatusCheck.ps1 ----
$ShimDir = Join-Path $Work 'shim'
$MockDir = Join-Path $Work 'mock'
New-Item -ItemType Directory -Path $ShimDir, $MockDir -Force | Out-Null
$npmMock = @'
$mockDir = $env:DEPVER_MOCK_DIR
if (-not $mockDir) { exit 1 }
Add-Content -LiteralPath (Join-Path $mockDir 'npm_calls.txt') -Value ((Get-Location).Path + '|' + ($args -join ' '))
$exitFile = Join-Path $mockDir 'npm_exit.txt'
$code = 1
if (Test-Path $exitFile) { $code = [int]((Get-Content $exitFile -Raw).Trim()) }
$jsonFile = Join-Path $mockDir 'npm_outdated.json'
if (Test-Path $jsonFile) { Write-Output (Get-Content $jsonFile -Raw) }
exit $code
'@
$pipMock = @'
$mockDir = $env:DEPVER_MOCK_DIR
if (-not $mockDir) { exit 1 }
Add-Content -LiteralPath (Join-Path $mockDir 'pip_calls.txt') -Value ((Get-Location).Path + '|' + ($args -join ' '))
$exitFile = Join-Path $mockDir 'pip_exit.txt'
$code = 0
if (Test-Path $exitFile) { $code = [int]((Get-Content $exitFile -Raw).Trim()) }
$jsonFile = Join-Path $mockDir 'pip_outdated.json'
if (Test-Path $jsonFile) { Write-Output (Get-Content $jsonFile -Raw) }
exit $code
'@
$goMock = @'
$mockDir = $env:DEPVER_MOCK_DIR
if (-not $mockDir) { exit 1 }
Add-Content -LiteralPath (Join-Path $mockDir 'go_calls.txt') -Value ((Get-Location).Path + '|' + ($args -join ' '))
$exitFile = Join-Path $mockDir 'go_exit.txt'
$code = 0
if (Test-Path $exitFile) { $code = [int]((Get-Content $exitFile -Raw).Trim()) }
$outFile = Join-Path $mockDir 'go_list.txt'
if (Test-Path $outFile) { Get-Content $outFile }
exit $code
'@
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'npm.ps1'), $npmMock)
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'pip.ps1'), $pipMock)
[System.IO.File]::WriteAllText((Join-Path $ShimDir 'go.ps1'), $goMock)
# Start-Process -Environment does NOT replace PATH wholesale for the child - it MERGES the
# given value into the process's inherited PATH (confirmed: passing an independent variable
# through -Environment leaves the parent's real npm/pip directories reachable regardless). The
# only reliable way to control what a child resolves `npm`/`pip` to is to mutate THIS process's
# own $env:PATH before Start-Process, exactly like the established `gh` shim convention in
# Test-CiStatusCheck.ps1 - so PATH is rewritten in place here (and restored in `finally`) instead
# of being threaded through as a separate value.
$OriginalPath = $env:PATH
$pathWithoutRealTools = @($OriginalPath -split ';' | Where-Object {
    $_ -ne '' -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'npm.cmd') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'npm.exe') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'npm.ps1') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'pip.exe') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $_ 'go.exe') -PathType Leaf)
})
$MockedPath = (@($ShimDir) + $pathWithoutRealTools) -join ';'
$env:PATH = $MockedPath

function Set-Mock {
    param([int]$NpmExit = 1, [string]$NpmJson = '{}', [int]$PipExit = 0, [string]$PipJson = '[]')
    # Only overwrite the fixture files this function manages - NOT a blanket wildcard clear,
    # which would also wipe npm_calls.txt/pip_calls.txt (the invocation-count log lives in this
    # same directory) and break any test that calls Set-Mock more than once while tracking calls
    # across it (e.g. a cache-invalidation test with an updated fixture mid-test).
    Set-Content (Join-Path $MockDir 'npm_exit.txt') $NpmExit
    Set-Content (Join-Path $MockDir 'npm_outdated.json') $NpmJson -Encoding utf8
    Set-Content (Join-Path $MockDir 'pip_exit.txt') $PipExit
    Set-Content (Join-Path $MockDir 'pip_outdated.json') $PipJson -Encoding utf8
}
function Get-NpmCallCount {
    $f = Join-Path $MockDir 'npm_calls.txt'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    return @(Get-Content -LiteralPath $f | Where-Object { $_ }).Count
}
function Reset-CallLog {
    Remove-Item (Join-Path $MockDir 'npm_calls.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $MockDir 'pip_calls.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $MockDir 'go_calls.txt') -Force -ErrorAction SilentlyContinue
}
function Set-GoMock {
    param([int]$GoExit = 0, [string]$GoOutput = '')
    Set-Content (Join-Path $MockDir 'go_exit.txt') $GoExit
    Set-Content (Join-Path $MockDir 'go_list.txt') $GoOutput -Encoding utf8
}

function New-Proj {
    param([string]$Name)
    $p = Join-Path $ProjsRoot $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Fire {
    param([string]$Cwd, [string]$EventName = 'SessionStart', [string]$Prompt = '', [string]$SessionId = 't', [string]$Exe = '', [switch]$StopActive, [string]$HookPath = '')
    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }
    if ($EventName -eq 'UserPromptSubmit') { $obj['prompt'] = $Prompt }
    if ($StopActive) { $obj['stop_hook_active'] = $true }
    $payload = $obj | ConvertTo-Json
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $inFile = Join-Path $Work ('in-' + $token + '.json')
    $outFile = Join-Path $Work ('out-' + $token + '.txt')
    $errFile = Join-Path $Work ('err-' + $token + '.txt')
    [System.IO.File]::WriteAllText($inFile, $payload, (New-Object System.Text.UTF8Encoding $false))
    $file = if ([string]::IsNullOrWhiteSpace($Exe)) { (Get-Process -Id $PID).Path } else { $Exe }
    $target = if ([string]::IsNullOrWhiteSpace($HookPath)) { $Hook } else { $HookPath }
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $target + '"'
    $startArgs = @{
        FilePath = $file; ArgumentList = $argLine; RedirectStandardInput = $inFile
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
        $startArgs.Environment = @{ PATH = $env:PATH; LOCALAPPDATA = $FakeLocalAppData; DEPVER_MOCK_DIR = $MockDir }
    }
    $proc = Start-BoundedProcess @startArgs
    $out = if (Test-Path -LiteralPath $outFile) { ([System.IO.File]::ReadAllText($outFile)).Trim() } else { '' }
    $err = if (Test-Path -LiteralPath $errFile) { ([System.IO.File]::ReadAllText($errFile)).Trim() } else { '' }
    return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out; Err = $err }
}

try {
    # =====================================================================
    Write-Host '--- no detected ecosystem stays silent ---' -ForegroundColor Cyan
    $empty = New-Proj 'Empty'
    Set-Mock
    $r = Fire -Cwd $empty
    Check 'a project with nothing this hook understands stays silent' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out

    # =====================================================================
    Write-Host '--- npm: outdated patch/minor/major classification ---' -ForegroundColor Cyan
    $npmProj = New-Proj 'NpmProj'
    Write-Utf8 (Join-Path $npmProj 'package.json') '{"name":"fixture","version":"1.0.0","dependencies":{"pkg-patch":"1.0.0","pkg-minor":"1.0.0","pkg-major":"1.0.0"}}'
    $npmJson = '{"pkg-patch":{"current":"1.0.0","latest":"1.0.1"},"pkg-minor":{"current":"1.0.0","latest":"1.1.0"},"pkg-major":{"current":"1.0.0","latest":"2.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson $npmJson
    $r = Fire -Cwd $npmProj
    Check 'npm outdated exit 1 (packages found) is treated as success, not a failure' ($r.Out -match 'pkg-patch' -and $r.Out -notmatch 'Incomplete') $r.Out
    Check 'a patch update is classified [patch]' ($r.Out -match 'pkg-patch 1\.0\.0 -> 1\.0\.1 \[patch\]') $r.Out
    Check 'a minor update is classified [minor]' ($r.Out -match 'pkg-minor 1\.0\.0 -> 1\.1\.0 \[minor\]') $r.Out
    Check 'a major update is classified [major]' ($r.Out -match 'pkg-major 1\.0\.0 -> 2\.0\.0 \[major\]') $r.Out
    Check 'output never contains a blocking decision (advisory only)' ($r.Out -notmatch '"decision"') $r.Out
    Check 'output includes incremental-update guidance' ($r.Out -match 'small verified batches') $r.Out
    Check 'output includes safety/release-note review guidance' ($r.Out -match 'release notes') $r.Out
    Check 'no automatic file modification occurs (package.json unchanged)' (
        ([System.IO.File]::ReadAllText((Join-Path $npmProj 'package.json'))) -eq '{"name":"fixture","version":"1.0.0","dependencies":{"pkg-patch":"1.0.0","pkg-minor":"1.0.0","pkg-major":"1.0.0"}}')

    # =====================================================================
    Write-Host '--- npm: prerelease is never the default recommendation ---' -ForegroundColor Cyan
    $preProj = New-Proj 'PreProj'
    Write-Utf8 (Join-Path $preProj 'package.json') '{"name":"fixture","dependencies":{"pkg-pre":"1.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson '{"pkg-pre":{"current":"1.0.0","latest":"2.0.0-beta.1"}}'
    $r = Fire -Cwd $preProj
    Check 'a prerelease latest version is classified [prerelease], not silently recommended' ($r.Out -match 'pkg-pre 1\.0\.0 -> 2\.0\.0-beta\.1 \[prerelease\]') $r.Out
    Check 'the report tells the agent never to default to a prerelease' ($r.Out -match 'never a prerelease/beta/RC/nightly') $r.Out

    # =====================================================================
    Write-Host '--- npm: real command failure vs "outdated found" exit code ---' -ForegroundColor Cyan
    $failProj = New-Proj 'FailProj'
    Write-Utf8 (Join-Path $failProj 'package.json') '{"name":"fixture","dependencies":{"x":"1.0.0"}}'
    Set-Mock -NpmExit 2 -NpmJson ''
    $r = Fire -Cwd $failProj
    Check 'a genuine npm command failure (exit > 1) is reported as incomplete, not silently skipped' ($r.Out -match 'Incomplete' -and $r.Out -match 'npm') $r.Out
    Check 'an incomplete check never claims dependencies are current' ($r.Out -notmatch 'up to date' -and $r.Out -notmatch 'all current')

    # =====================================================================
    Write-Host '--- pip: Python outdated packages ---' -ForegroundColor Cyan
    $pipProj = New-Proj 'PipProj'
    Write-Utf8 (Join-Path $pipProj 'requirements.txt') 'requests==2.0.0'
    # The hook queries THIS PROJECT's interpreter, never `pip` on PATH, so the
    # fixture needs a venv of its own. A .cmd that prints the same mock file the
    # old PATH shim used keeps Set-Mock the single place the payload is defined.
    $pipVenv = Join-Path $pipProj '.venv\Scripts'
    New-Item -ItemType Directory -Path $pipVenv -Force | Out-Null
    Write-Utf8 (Join-Path $pipVenv 'python.cmd') ('@echo off' + [Environment]::NewLine + 'type ' + [char]34 + (Join-Path $MockDir 'pip_outdated.json') + [char]34 + [Environment]::NewLine)
    # boto3 is outdated IN THE ENVIRONMENT but is not declared by this project -
    # the exact shape that made a real report list anyio, boto3, click, Faker and
    # huggingface_hub as this project's findings once the environment inherited
    # system site-packages. It must be inspected and then left out.
    Set-Mock -PipExit 0 -PipJson '[{"name":"requests","version":"2.0.0","latest_version":"2.5.0","latest_filetype":"wheel"},{"name":"boto3","version":"1.0.0","latest_version":"1.9.0","latest_filetype":"wheel"}]'
    $r = Fire -Cwd $pipProj
    Check 'pip outdated packages are reported' ($r.Out -match 'pip: requests 2\.0\.0 -> 2\.5\.0') $r.Out
    Check 'an outdated package this project does not declare is NOT reported' ($r.Out -notmatch 'boto3') $r.Out

    # =====================================================================
    Write-Host '--- go: go.mod detected, `go list -u -m all` runs in the module dir without crashing ---' -ForegroundColor Cyan
    # Regression: Invoke-QuietCommand has no -WorkingDirectory parameter, so the
    # previous `-WorkingDirectory $dir` argument threw a ParameterBindingException
    # and aborted the whole hook whenever a go.mod was present and `go` was on PATH.
    $goProj = New-Proj 'GoProj'
    Write-Utf8 (Join-Path $goProj 'go.mod') "module example.com/fixture`n`ngo 1.21`n"
    Set-GoMock -GoExit 0 -GoOutput "example.com/fixture`nexample.com/dep v1.0.0 [v1.2.0]`n"
    Remove-Item (Join-Path $MockDir 'go_calls.txt') -Force -ErrorAction SilentlyContinue
    $r = Fire -Cwd $goProj
    Check 'go.mod with go on PATH does not crash the hook' ($r.Exit -eq 0 -and $r.Err -eq '') ($r.Out + ' | err=' + $r.Err)
    Check 'the go module update is reported and classified' ($r.Out -match 'example\.com/dep v1\.0\.0 -> v1\.2\.0 \[minor\]') $r.Out
    $goCallLog = Join-Path $MockDir 'go_calls.txt'
    Check 'the go call log was written (the shim actually ran)' (Test-Path -LiteralPath $goCallLog)
    if (Test-Path -LiteralPath $goCallLog) {
        $goCallLine = ([System.IO.File]::ReadAllText($goCallLog)).Trim()
        $goProjFull = (Get-Item -LiteralPath $goProj).FullName
        Check 'the go call ran with the module directory as its working directory (Push-Location, not the removed -WorkingDirectory)' (
            $goCallLine -like ($goProjFull + '|*')) $goCallLine
    }

    # =====================================================================
    Write-Host '--- GitHub Actions: clearly old major version flagged ---' -ForegroundColor Cyan
    $ghProj = New-Proj 'GhActionsProj'
    Write-Utf8 (Join-Path $ghProj '.github\workflows\ci.yml') "on:`n  push:`njobs:`n  test:`n    steps:`n      - uses: actions/checkout@v2`n      - run: echo hi"
    Set-Mock
    $r = Fire -Cwd $ghProj
    Check 'a clearly old major GitHub Action version is flagged' ($r.Out -match 'actions/checkout@v2 is a clearly old major version') $r.Out
    $ghCurrentProj = New-Proj 'GhActionsCurrentProj'
    Write-Utf8 (Join-Path $ghCurrentProj '.github\workflows\ci.yml') "on:`n  push:`njobs:`n  test:`n    steps:`n      - uses: actions/checkout@v4`n      - run: echo hi"
    $r = Fire -Cwd $ghCurrentProj
    Check 'an at-or-above-minimum action version is never flagged (never asserts it IS the latest)' ($r.Out -notmatch 'actions/checkout')

    # =====================================================================
    Write-Host '--- runtime pin: EOL Node/Python version reported ---' -ForegroundColor Cyan
    $nvmProj = New-Proj 'NvmProj'
    Write-Utf8 (Join-Path $nvmProj '.nvmrc') '14'
    $r = Fire -Cwd $nvmProj
    Check 'an EOL Node major version pin is reported' ($r.Out -match 'runtime pin \.nvmrc: Node 14 is a known end-of-life major version \[EOL\]') $r.Out
    $currentNvmProj = New-Proj 'CurrentNvmProj'
    Write-Utf8 (Join-Path $currentNvmProj '.nvmrc') '22'
    $r = Fire -Cwd $currentNvmProj
    Check 'a current Node major version pin is not flagged' ($r.Out -notmatch 'end-of-life')
    $pyVerProj = New-Proj 'PyVerProj'
    Write-Utf8 (Join-Path $pyVerProj '.python-version') '3.7'
    $r = Fire -Cwd $pyVerProj
    Check 'an EOL Python version pin is reported' ($r.Out -match 'runtime pin \.python-version: Python 3\.7 is a known end-of-life version \[EOL\]') $r.Out

    # =====================================================================
    Write-Host '--- Docker base image: floating tag and EOL tag ---' -ForegroundColor Cyan
    $dockerFloatProj = New-Proj 'DockerFloatProj'
    Write-Utf8 (Join-Path $dockerFloatProj 'Dockerfile') "FROM node:latest`nCMD [`"node`"]"
    $r = Fire -Cwd $dockerFloatProj
    Check 'a floating :latest base image tag is flagged as non-reproducible' ($r.Out -match 'node:latest uses a floating/untagged') $r.Out
    $dockerEolProj = New-Proj 'DockerEolProj'
    Write-Utf8 (Join-Path $dockerEolProj 'Dockerfile') "FROM ubuntu:18.04`nCMD [`"true`"]"
    $r = Fire -Cwd $dockerEolProj
    Check 'a known EOL base image tag is flagged' ($r.Out -match 'ubuntu:18\.04 is a known end-of-life base image tag \[EOL\]') $r.Out
    $dockerCurrentProj = New-Proj 'DockerCurrentProj'
    Write-Utf8 (Join-Path $dockerCurrentProj 'Dockerfile') "FROM node:22-slim`nCMD [`"node`"]"
    $r = Fire -Cwd $dockerCurrentProj
    Check 'a pinned, non-EOL base image tag is not flagged' ($r.Out -notmatch 'node:22-slim')

    # =====================================================================
    Write-Host '--- ecosystems without a real integration report incomplete, never "current" ---' -ForegroundColor Cyan
    $cargoProj = New-Proj 'CargoProj'
    Write-Utf8 (Join-Path $cargoProj 'Cargo.toml') "[package]`nname = `"fixture`""
    $r = Fire -Cwd $cargoProj
    Check 'cargo is detected and reported incomplete with the correct crate requirement noted' ($r.Out -match 'cargo detected' -and $r.Out -match 'cargo-outdated crate') $r.Out
    Check 'an incomplete-only report never claims a clean/current result' ($r.Out -notmatch 'up to date')

    # =====================================================================
    Write-Host '--- UserPromptSubmit: new-dependency guidance + cached findings ---' -ForegroundColor Cyan
    $promptProj = New-Proj 'PromptProj'
    Write-Utf8 (Join-Path $promptProj 'package.json') '{"name":"fixture","dependencies":{"pkg-x":"1.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson '{"pkg-x":{"current":"1.0.0","latest":"2.0.0"}}'
    $rSession = Fire -Cwd $promptProj -EventName 'SessionStart'
    Check 'SessionStart caches findings for this project' ($rSession.Out -match 'pkg-x') $rSession.Out
    $rPromptPlain = Fire -Cwd $promptProj -EventName 'UserPromptSubmit' -Prompt 'fix a typo in the README'
    Check 'an unrelated prompt still surfaces cached findings but no new-dependency guidance' ($rPromptPlain.Out -match 'pkg-x' -and $rPromptPlain.Out -notmatch 'Before selecting a version for a new/updated dependency') $rPromptPlain.Out
    $rPromptNew = Fire -Cwd $promptProj -EventName 'UserPromptSubmit' -Prompt 'please add a new dependency for HTTP requests'
    Check 'a new-dependency prompt injects "prefer latest stable compatible" guidance' ($rPromptNew.Out -match 'Before selecting a version for a new/updated dependency') $rPromptNew.Out
    Check 'new-dependency guidance also warns against a floating tag / non-deterministic pin' ($rPromptNew.Out -match 'floating tag')
    $rPromptScratch = Fire -Cwd $promptProj -EventName 'UserPromptSubmit' -Prompt 'create a new project from scratch using a modern web framework'
    Check '"from scratch" project prompts also trigger the guidance' ($rPromptScratch.Out -match 'prefer the latest STABLE') $rPromptScratch.Out

    # =====================================================================
    Write-Host '--- caching: unchanged fingerprint suppresses a repeat scan; a manifest edit invalidates it ---' -ForegroundColor Cyan
    Reset-CallLog
    $cacheProj = New-Proj 'CacheProj'
    Write-Utf8 (Join-Path $cacheProj 'package.json') '{"name":"fixture","dependencies":{"pkg-c":"1.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson '{"pkg-c":{"current":"1.0.0","latest":"1.0.1"}}'
    $r1 = Fire -Cwd $cacheProj
    Check 'first scan runs npm and reports the finding' ($r1.Out -match 'pkg-c' -and (Get-NpmCallCount) -eq 1) ('calls=' + (Get-NpmCallCount))
    $r2 = Fire -Cwd $cacheProj
    # Compare parsed additionalContext, not the raw JSON string: a plain @{} hashtable's key
    # ORDER is not guaranteed stable across separate process invocations (confirmed: two
    # back-to-back runs of the same hook produced {"additionalContext":...,"hookEventName":...}
    # in one process and the reverse order in the next) - only the DECODED content is a
    # meaningful equality check here, the JSON key order is never semantically significant.
    $ctx1 = ($r1.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext
    $ctx2 = ($r2.Out | ConvertFrom-Json).hookSpecificOutput.additionalContext
    Check 'a second scan with an unchanged fingerprint reuses the cache (no new npm invocation)' ((Get-NpmCallCount) -eq 1 -and $ctx2 -eq $ctx1) ('calls=' + (Get-NpmCallCount))
    Write-Utf8 (Join-Path $cacheProj 'package.json') '{"name":"fixture","dependencies":{"pkg-c":"1.0.0","pkg-d":"1.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson '{"pkg-c":{"current":"1.0.0","latest":"1.0.1"},"pkg-d":{"current":"1.0.0","latest":"2.0.0"}}'
    $r3 = Fire -Cwd $cacheProj
    Check 'editing the manifest invalidates the cache and triggers a fresh scan' ((Get-NpmCallCount) -eq 2 -and $r3.Out -match 'pkg-d') ('calls=' + (Get-NpmCallCount))

    # =====================================================================
    Write-Host '--- state file never stores secret-like content, only fingerprint + report ---' -ForegroundColor Cyan
    $stateFiles = @(Get-ChildItem -LiteralPath $FakeLocalAppData -Recurse -Filter 'DependencyVersionCheck-*.txt' -ErrorAction SilentlyContinue)
    Check 'a cache state file was written' ($stateFiles.Count -gt 0)
    if ($stateFiles.Count -gt 0) {
        $stateText = [System.IO.File]::ReadAllText($stateFiles[0].FullName)
        Check 'the state file does not embed a full manifest/package.json body' ($stateText -notmatch '"dependencies"')
    }

    # =====================================================================
    Write-Host '--- Windows PowerShell 5.1 ---' -ForegroundColor Cyan
    $ps5Proj = New-Proj 'Ps5Proj'
    Write-Utf8 (Join-Path $ps5Proj 'package.json') '{"name":"fixture","dependencies":{"pkg-5":"1.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson '{"pkg-5":{"current":"1.0.0","latest":"1.1.0"}}'
    $r = Fire -Cwd $ps5Proj -Exe 'powershell.exe'
    # Windows PowerShell 5.1's ConvertTo-Json escapes ">" as ">" (confirmed: pwsh 7 leaves it
    # literal) - match either encoding rather than assuming a literal "->".
    Check 'Windows PowerShell 5.1 runs cleanly and classifies the update' ($r.Exit -eq 0 -and $r.Out -match 'pkg-5 1\.0\.0 -(>|\\u003e) 1\.1\.0 \[minor\]') $r.Err

    # =====================================================================
    Write-Host '--- output contract: every finding needs a stated DECISION ---' -ForegroundColor Cyan
    # The scan was never the weak half - an ignorable report was. These assert
    # the response contract, which is what the report now carries.
    $contractProj = New-Proj 'ContractProj'
    Write-Utf8 (Join-Path $contractProj 'package.json') '{"name":"fixture","dependencies":{"pkg-old":"1.0.0"}}'
    Set-Mock -NpmExit 1 -NpmJson '{"pkg-old":{"current":"1.0.0","latest":"3.0.0"}}'
    $rc = Fire -Cwd $contractProj -SessionId 'contract-1'
    Check 'the report demands a decision per finding, not agreement' ($rc.Out -match 'needs a DECISION, not agreement') $rc.Out
    Check 'update / keep / defer are all named as legitimate answers' (
        $rc.Out -match 'update \(then update the lockfile' -and $rc.Out -match 'keep \(' -and $rc.Out -match 'defer \(') $rc.Out
    Check 'silence is explicitly NOT an answer' ($rc.Out -match 'silence is not') $rc.Out
    Check 'EOL / clearly-old-major needs a stated reason to leave in place' ($rc.Out -match 'explicit stated reason to leave in place') $rc.Out
    Check 'the report names the exact closing line to write' ($rc.Out -match 'Dependency decisions:') $rc.Out
    Check 'the report still disclaims any authority to upgrade or block' (
        $rc.Out -match 'never runs an upgrade and never blocks completion' -and $rc.Out -notmatch '"decision"') $rc.Out

    # =====================================================================
    Write-Host '--- Stop/SubagentStop: replays unanswered findings, never scans, never blocks ---' -ForegroundColor Cyan
    Reset-CallLog
    $r = Fire -Cwd $contractProj -EventName 'Stop' -SessionId 'contract-1'
    Check 'the closing half replays the still-unanswered finding' ($r.Out -match 'pkg-old' -and $r.Out -match 'still on the table') $r.Out
    Check 'the closing half asks for the decision line' ($r.Out -match 'Dependency decisions:') $r.Out
    Check 'an unanswered finding is named an UNREVIEWED RISK, not an accepted one' ($r.Out -match 'UNREVIEWED RISK') $r.Out
    Check 'the closing half never blocks (advisory shape only)' ($r.Out -notmatch '"decision"') $r.Out
    Check 'the closing half separates out the EOL/major class' ($r.Out -match 'end-of-life or a clearly old major') $r.Out
    Check 'the closing half runs NO scan (no npm invocation at Stop)' ((Get-NpmCallCount) -eq 0) ('npm calls=' + (Get-NpmCallCount))
    $r2 = Fire -Cwd $contractProj -EventName 'Stop' -SessionId 'contract-1'
    Check 'an unchanged report does not repeat on the next Stop of the same session' ($r2.Exit -eq 0 -and $r2.Out -eq '') $r2.Out
    $r3 = Fire -Cwd $contractProj -EventName 'Stop' -SessionId 'contract-2'
    Check 'a NEW session replays it again' ($r3.Out -match 'pkg-old') $r3.Out
    $r4 = Fire -Cwd $contractProj -EventName 'SubagentStop' -SessionId 'contract-3'
    Check 'SubagentStop replays it too' ($r4.Out -match 'pkg-old') $r4.Out
    $r5 = Fire -Cwd $contractProj -EventName 'Stop' -SessionId 'contract-4' -StopActive
    Check 'stop_hook_active short-circuits the closing half' ($r5.Exit -eq 0 -and $r5.Out -eq '') $r5.Out
    # A project with nothing cached has nothing to replay.
    $quietProj = New-Proj 'QuietStopProj'
    Write-Utf8 (Join-Path $quietProj 'Cargo.toml') "[package]`nname = `"fixture`""
    $r6 = Fire -Cwd $quietProj -EventName 'Stop' -SessionId 'quiet-1'
    Check 'a project with no cached findings stays silent at Stop' ($r6.Exit -eq 0 -and $r6.Out -eq '') $r6.Out
    # An incomplete-only report is not replayed: there is nothing at the end of a
    # task to DECIDE about a check that could not run.
    $null = Fire -Cwd $quietProj -SessionId 'quiet-2'
    $r7 = Fire -Cwd $quietProj -EventName 'Stop' -SessionId 'quiet-3'
    Check 'an incomplete-only report is not replayed at Stop' ($r7.Exit -eq 0 -and $r7.Out -eq '') $r7.Out

    # =====================================================================
    Write-Host '--- CLOSING_REMINDER=0 keeps the hook pre-task only ---' -ForegroundColor Cyan
    $offDir = Join-Path $Work 'depcopy-off'
    New-Item -ItemType Directory -Path $offDir -Force | Out-Null
    Copy-Item $Hook (Join-Path $offDir 'Dependency-Version-Check.ps1')
    Copy-Item (Join-Path (Split-Path -Parent $Hook) '..\_hooklib.ps1') (Join-Path $Work '_hooklib.ps1') -Force
    Write-Utf8 (Join-Path $offDir '.env') "CLOSING_REMINDER=0`r`n"
    $offHook = Join-Path $offDir 'Dependency-Version-Check.ps1'
    $r = Fire -Cwd $contractProj -EventName 'Stop' -SessionId 'off-1' -HookPath $offHook
    Check 'CLOSING_REMINDER=0 silences the closing half' ($r.Exit -eq 0 -and $r.Out -eq '') $r.Out
    $r = Fire -Cwd $contractProj -EventName 'UserPromptSubmit' -Prompt 'add a new dependency' -SessionId 'off-2' -HookPath $offHook
    Check 'CLOSING_REMINDER=0 leaves the pre-task halves working' ($r.Out -match 'latest STABLE') $r.Out

    # =====================================================================
    Write-Host '--- shipped .env.example registers the correct events ---' -ForegroundColor Cyan
    $envExample = Join-Path (Split-Path -Parent $Hook) '.env.example'
    $envText = if (Test-Path -LiteralPath $envExample -PathType Leaf) { [System.IO.File]::ReadAllText($envExample) } else { '' }
    # Anchored: a substring match would still pass if a stale pre-task-only line
    # were left behind, or if extra events were appended unnoticed.
    Check 'the shipped .env.example registers the pre-task AND closing events' (
        $envText -match '(?m)^EVENTS=SessionStart,UserPromptSubmit,Stop,SubagentStop\s*$') $envText
    Check 'the shipped .env.example documents CLOSING_REMINDER' ($envText -match '(?m)^CLOSING_REMINDER=1\s*$') $envText

    # =====================================================================
    Write-Host '--- pip is scoped to the PROJECT, never the machine-wide Python ---' -ForegroundColor Cyan
    # Reported from a real machine: the hook listed anyio, boto3, click, Faker,
    # huggingface_hub and importlib_metadata - none of them dependencies of the
    # project it was reporting on - because Get-Command pip resolves the
    # GLOBAL interpreter. Worse than noise: it called cryptography outdated at
    # 50.0.0 while the project's own venv already had 50.0.1, so the one
    # actionable-looking finding was backwards.
    #
    # The resolver is extracted from the shipped source and exercised directly:
    # a stub interpreter cannot be a real .exe, and asserting the resolver is
    # what actually decides which environment gets queried.
    $scopeSrc = [System.IO.File]::ReadAllText($Hook)
    $scopeFn = [regex]::Match($scopeSrc, '(?s)function Get-ProjectPythonExecutable \{.*?\n\}')
    Check 'the hook resolves a PROJECT interpreter rather than PATH pip' ($scopeFn.Success) 'Get-ProjectPythonExecutable not found'
    Check 'the hook never falls back to bare pip/pip3 on PATH' ($scopeSrc -notmatch 'Get-Command pip3? -ErrorAction SilentlyContinue') 'a PATH pip fallback is still present'
    if ($scopeFn.Success) {
        Invoke-Expression $scopeFn.Value
        $scopeWork = Join-Path $Work 'pipscope'
        $withEnv = Join-Path $scopeWork 'withenv'
        $noEnv = Join-Path $scopeWork 'noenv'
        New-Item -ItemType Directory -Path (Join-Path $withEnv '.venv\Scripts'), $noEnv -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $withEnv '.venv\Scripts\python.exe') -Value 'stub' -Encoding ascii

        $resolved = Get-ProjectPythonExecutable -ProjectRoot $withEnv
        Check 'it resolves the project venv interpreter' (
            $null -ne $resolved -and ([string]$resolved).StartsWith($withEnv, [System.StringComparison]::OrdinalIgnoreCase)) ([string]$resolved)

        # The whole point: no environment of its own means NO answer, not the
        # machine's answer.
        Check 'a project with no venv resolves to nothing (no global fallback)' (
            $null -eq (Get-ProjectPythonExecutable -ProjectRoot $noEnv)) ([string](Get-ProjectPythonExecutable -ProjectRoot $noEnv))

        # AN EXPLICITLY CONFIGURED SHARED BASE. A project with no venv of its
        # own may deliberately run on a shared interpreter; refusing to look at
        # it made this hook permanently silent for those projects. It counts
        # only because the project named it and the path verifies - which is
        # exactly what `pip` off PATH never is.
        $sharedBase = Join-Path $scopeWork 'shared-python.exe'
        Set-Content -LiteralPath $sharedBase -Value 'stub' -Encoding ascii
        $script:config = @{ PYTHON_EXECUTABLE = $sharedBase }
        try {
            Check 'a configured shared interpreter is used when the project has no venv' (
                (Get-ProjectPythonExecutable -ProjectRoot $noEnv) -eq (
                    [System.IO.Path]::GetFullPath($sharedBase))) ([string](Get-ProjectPythonExecutable -ProjectRoot $noEnv))
            $script:config = @{ PYTHON_EXECUTABLE = (Join-Path $scopeWork 'does-not-exist.exe') }
            Check 'a configured interpreter that does not verify resolves to nothing, never to PATH' (
                $null -eq (Get-ProjectPythonExecutable -ProjectRoot $noEnv)) ([string](Get-ProjectPythonExecutable -ProjectRoot $noEnv))
            # The project's OWN venv still wins over the configured base.
            $script:config = @{ PYTHON_EXECUTABLE = $sharedBase }
            Check 'the project venv still wins over a configured shared base' (
                ([string](Get-ProjectPythonExecutable -ProjectRoot $withEnv)).StartsWith($withEnv, [System.StringComparison]::OrdinalIgnoreCase)) ([string](Get-ProjectPythonExecutable -ProjectRoot $withEnv))
        }
        finally { $script:config = @{} }

        # ---- the declared dependency SET -------------------------------------
        # With inherited system site-packages, `pip list --outdated` reports the
        # machine. Findings are restricted to what the project declares plus its
        # transitive closure, and an undeterminable scope reports nothing.
        . (Join-Path (Split-Path -Parent $Hook) '_pythonscope.ps1')
        $declProj = Join-Path $scopeWork 'declared'
        New-Item -ItemType Directory -Path $declProj -Force | Out-Null
        Write-Utf8 (Join-Path $declProj 'requirements.txt') (
            '# a comment' + [Environment]::NewLine +
            '-r other.txt' + [Environment]::NewLine +
            'Flask_SQLAlchemy>=3.0' + [Environment]::NewLine +
            'requests[security]==2.0.0 ; python_version > "3.8"' + [Environment]::NewLine)
        Write-Utf8 (Join-Path $declProj 'pyproject.toml') (
            '[project]' + [Environment]::NewLine +
            'dependencies = ["httpx>=0.27", "rich"]' + [Environment]::NewLine)
        $declared = Get-DeclaredPythonPackages -ProjectRoot $declProj
        $declaredNames = @($declared.Names)
        Check 'requirement names are normalised (PEP 503) and extras/markers stripped' (
            $declaredNames -contains 'flask-sqlalchemy' -and $declaredNames -contains 'requests') ($declaredNames -join ',')
        Check 'option lines and comments declare nothing' (
            -not ($declaredNames -contains 'r') -and -not ($declaredNames -contains 'a')) ($declaredNames -join ',')
        Check 'pyproject dependencies are part of the declared set' (
            $declaredNames -contains 'httpx' -and $declaredNames -contains 'rich') ($declaredNames -join ',')
        $emptyProj = Join-Path $scopeWork 'nodecl'
        New-Item -ItemType Directory -Path $emptyProj -Force | Out-Null
        Check 'a project that declares nothing yields an empty scope, never everything' (
            @((Get-DeclaredPythonPackages -ProjectRoot $emptyProj).Names).Count -eq 0) ''

        # A shell with SOME OTHER project's venv active must not leak into this
        # project's report.
        $previousVirtualEnv = $env:VIRTUAL_ENV
        $env:VIRTUAL_ENV = (Join-Path $withEnv '.venv')
        try {
            Check 'another project''s active VIRTUAL_ENV does not leak in' (
                $null -eq (Get-ProjectPythonExecutable -ProjectRoot $noEnv)) ([string](Get-ProjectPythonExecutable -ProjectRoot $noEnv))
        }
        finally {
            if ($null -eq $previousVirtualEnv) { Remove-Item Env:\VIRTUAL_ENV -ErrorAction SilentlyContinue }
            else { $env:VIRTUAL_ENV = $previousVirtualEnv }
        }
    }
}
finally {
    $env:PATH = $OriginalPath
    if ($KeepArtifacts) {
        Write-Host ("Artifacts kept at: $Work") -ForegroundColor DarkGray
    }
    else {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
