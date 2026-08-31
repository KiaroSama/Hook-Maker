# Offline test suite for Get-HookStatus.ps1's PARSERS: what evidence it extracts
# from a Claude/Codex settings file and from a native Git hooks directory, and
# what it refuses to claim.
#
# Traversal is covered by Test-HookStatusScan.ps1; everything here uses a small
# fixture tree and asserts on the emitted scan-result document.
#
# Covers: both Claude settings filenames and Codex hooks.json; Hook Maker-created
# and third-party handlers; targets inside and outside standard hook roots;
# several events collapsing into ONE runtime record; two clients collapsing into
# one record only on proven identity; two same-named hooks at DIFFERENT paths
# staying separate; all three command-field spellings; fields that DISAGREE;
# unparseable shell commands; malformed settings JSON; unrelated valid JSON;
# handlers with matchers; a registration whose target is missing; unreferenced
# helper files. Native: normal .git\hooks; a .git FILE with gitdir:; a custom
# core.hooksPath; the canonical Hook Maker wrapper; an external pre-push; a
# pre-commit; a custom hook filename; *.sample ignored; referenced stage scripts;
# a tampered native file; the git-unavailable fallback.
#
# And the load-bearing one: a fixture command whose ONLY effect would be creating
# a sentinel file - asserted to never appear, proving nothing discovered is run.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-HookStatusDiscovery.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$Scanner = Join-Path $ScriptRoot 'Get-HookStatus.ps1'
if (-not (Test-Path -LiteralPath $Scanner -PathType Leaf)) {
    Write-Host "Required script not found: $Scanner" -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 800
. (Join-Path $ScriptRoot '_testlib.ps1')
# The canonical wrapper generator, so the fixture wrapper is byte-identical to
# what the installer would really write (and a tampered one provably is not).
. (Join-Path $ToolRoot 'hooks\_hooklib.ps1')
. (Join-Path $ScriptRoot '_installplan.ps1')
# Same reason for Kiro: the managed fixture documents below are built by the
# REAL writer, so "the scanner recognises what the installer wrote" is what the
# assertions actually prove - not what this suite guessed the format is.
. (Join-Path $ScriptRoot '_installkiro.ps1')

$WorkToken = [guid]::NewGuid().ToString('N').Substring(0, 8)
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-statusdisc-' + $WorkToken)
# A SIBLING of $Work, never inside it: $Work is the tree these tests scan, and
# the scanner refuses to write its result document into a scanned root.
$Artifacts = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-statusdisc-art-' + $WorkToken)
New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $Artifacts -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedStateDir = $env:HOOKMAKER_STATE_DIR
$env:HOOKMAKER_STATE_DIR = Join-Path $Work 'state'

function New-Dir { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path }
function Write-JsonFixture { param([string]$Path, $Value) Write-Utf8 -Path $Path -Content ($Value | ConvertTo-Json -Depth 30) }

# Runs the scanner in a FRESH process, exactly as the UI layer will.
function Invoke-Scan {
    param([string]$Root, [switch]$IncludeGlobal, [switch]$Persist, [int]$MaxDepth = 0, [hashtable]$Environment)
    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    # Harness artifacts live OUTSIDE $Work, because $Work is what gets scanned.
    # The scanner now refuses a -ResultPath inside any scan root - writing into
    # the tree under inspection would both contaminate it and let the scan
    # observe its own output. Keeping stdout/stderr capture out too means the
    # fixture directory contains only what a test deliberately put there.
    if (-not (Test-Path -LiteralPath $Artifacts)) {
        New-Item -ItemType Directory -Path $Artifacts -Force | Out-Null
    }
    $resultPath = Join-Path $Artifacts ("result-$token.json")
    $outFile = Join-Path $Artifacts ("out-$token.txt")
    $errFile = Join-Path $Artifacts ("err-$token.txt")
    $argLine = '-NoLogo -NoProfile -File "' + $Scanner + '" -ScanRoot "' + $Root + '" -ToolRoot "' + $ToolRoot +
        '" -ResultPath "' + $resultPath + '"'
    if (-not $Persist) { $argLine += ' -NoPersist' }
    if ($IncludeGlobal) { $argLine += ' -IncludeGlobal' }
    if ($MaxDepth -gt 0) { $argLine += ' -MaxDepth ' + $MaxDepth }
    $startArgs = @{
        FilePath = (Get-Process -Id $PID).Path; ArgumentList = $argLine
        RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
        Wait = $true; NoNewWindow = $true; PassThru = $true; WorkingDirectory = $Work
    }
    $environmentToUse = @{ HOOKMAKER_STATE_DIR = $env:HOOKMAKER_STATE_DIR }
    if ($null -ne $Environment) { foreach ($k in $Environment.Keys) { $environmentToUse[$k] = $Environment[$k] } }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) { $startArgs.Environment = $environmentToUse }
    $process = Start-Process @startArgs
    $document = $null
    if (Test-Path -LiteralPath $resultPath) {
        $document = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    }
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = ([System.IO.File]::ReadAllText($errFile)).Trim() }
    return [pscustomobject]@{ Exit = $process.ExitCode; Result = $document; Err = $err; ResultPath = $resultPath }
}

# Finds the record whose evidence mentions the given path fragment.
function Get-FindingByTarget {
    param($Result, [string]$Fragment)
    return @(@($Result.findings) | Where-Object {
        $matched = $false
        foreach ($client in @($_.clients)) {
            foreach ($target in @($client.parsedTargets)) { if ([string]$target -like ('*' + $Fragment + '*')) { $matched = $true } }
        }
        $matched
    })
}
function Get-NativeFinding {
    param($Result, [string]$HookName, [string]$RepoFragment = '')
    return @(@($Result.findings) | Where-Object {
        $null -ne $_.nativeGit -and [string]$_.nativeGit.hookName -eq $HookName -and
        ($RepoFragment -eq '' -or [string]$_.nativeGit.repositoryRoot -like ('*' + $RepoFragment + '*'))
    })
}

# One handler group, ready to drop into a hooks object.
function New-Group { param($Handlers, [string]$Matcher = $null)
    if ($null -eq $Matcher) { return @{ hooks = @($Handlers) } }
    return @{ matcher = $Matcher; hooks = @($Handlers) }
}

try {
    # =====================================================================
    # Fixture A - Claude settings.local.json, the parser workhorse
    # =====================================================================
    $projA = New-Dir (Join-Path $Work 'ProjA')
    $runtimeRoot = New-Dir (Join-Path $projA '.claude\hooks\Hook-Maker')
    $hmHookDir = New-Dir (Join-Path $runtimeRoot 'ZZZ-Status-Managed')
    $hmScript = Join-Path $hmHookDir 'ZZZ-Status-Managed.ps1'
    Write-Utf8 -Path $hmScript -Content '# managed runtime (never executed by the scanner)'
    # An unreferenced helper sitting next to it: present on disk, named by no
    # registration - it must never be invented as a hook.
    Write-Utf8 -Path (Join-Path $hmHookDir '_helper.ps1') -Content '# unreferenced helper'

    # Third-party hook OUTSIDE any standard hook root.
    $thirdParty = New-Dir (Join-Path $projA 'tools')
    $thirdPartyScript = Join-Path $thirdParty 'lint.js'
    Write-Utf8 -Path $thirdPartyScript -Content '// third-party hook'

    # Two hooks that SHARE a basename at different paths - must stay separate.
    $twinA = Join-Path (New-Dir (Join-Path $projA 'a')) 'same-name.ps1'
    $twinB = Join-Path (New-Dir (Join-Path $projA 'b')) 'same-name.ps1'
    Write-Utf8 -Path $twinA -Content '# twin a'
    Write-Utf8 -Path $twinB -Content '# twin b'

    # The proof-of-no-execution fixture: if the scanner ever ran a discovered
    # command, this sentinel would exist afterwards.
    $sentinel = Join-Path $Work 'SENTINEL-EXECUTED.txt'
    $sentinelCommand = 'powershell.exe -NoProfile -Command "Set-Content -LiteralPath ''' + $sentinel + ''' -Value pwned"'

    $claudeSettings = Join-Path $projA '.claude\settings.local.json'
    Write-JsonFixture -Path $claudeSettings -Value @{
        hooks = [ordered]@{
            # Same managed runtime registered on THREE events -> one record.
            SessionStart     = @(New-Group @(@{ type = 'command'; command = ('pwsh -NoProfile -File "' + $hmScript + '"') }))
            UserPromptSubmit = @(New-Group @(@{ type = 'command'; command = ('pwsh -NoProfile -File "' + $hmScript + '"') }))
            Stop             = @(New-Group @(@{ type = 'command'; command = ('pwsh -NoProfile -File "' + $hmScript + '"') }))
            # Third-party, outside any standard hook root, WITH a matcher.
            PreToolUse       = @(New-Group @(@{ type = 'command'; command = ('node "' + $thirdPartyScript + '"') }) 'Edit|Write')
            # All three command-field spellings, agreeing.
            PostToolUse      = @(New-Group @(@{
                type = 'command'
                command = ('pwsh -File "' + $twinA + '"')
                commandWindows = ('powershell.exe -File "' + $twinA + '"')
                command_windows = ('powershell.exe -File "' + $twinA + '"')
            }))
            # Same basename, DIFFERENT path.
            PreCompact       = @(New-Group @(@{ type = 'command'; command = ('pwsh -File "' + $twinB + '"') }))
            # Fields that DISAGREE.
            Notification     = @(New-Group @(@{
                type = 'command'
                command = ('pwsh -File "' + $twinA + '"')
                commandWindows = ('powershell.exe -File "' + $twinB + '"')
            }))
            # Unparseable: a piped shell command with no single target.
            SubagentStop     = @(New-Group @(@{ type = 'command'; command = 'cat foo | grep bar && echo done' }))
            # Registration whose target does not exist.
            SessionEnd       = @(New-Group @(@{ type = 'command'; command = ('pwsh -File "' + (Join-Path $projA 'gone\missing.ps1') + '"') }))
            # Never executed - only fingerprinted.
            PreCompactExtra  = @(New-Group @(@{ type = 'command'; command = $sentinelCommand }))
        }
    }

    # A Codex registration in the SAME project pointing at the SAME managed
    # runtime -> must merge with the Claude record on proven identity.
    Write-JsonFixture -Path (Join-Path $projA '.codex\hooks.json') -Value @{
        hooks = [ordered]@{
            SessionStart = @(New-Group @(@{
                type = 'command'
                command = ('pwsh -NoProfile -File "' + $hmScript + '"')
                commandWindows = ('powershell.exe -NoProfile -File "' + $hmScript + '"')
            }))
        }
    }

    # Fixture B - the OTHER Claude filename (settings.json) in a second project.
    $projB = New-Dir (Join-Path $Work 'ProjB')
    $bScript = Join-Path (New-Dir (Join-Path $projB 'scripts')) 'b-hook.ps1'
    Write-Utf8 -Path $bScript -Content '# project b hook'
    Write-JsonFixture -Path (Join-Path $projB '.claude\settings.json') -Value @{
        hooks = @{ SessionStart = @(New-Group @(@{ type = 'command'; command = ('pwsh -File "' + $bScript + '"') })) }
    }

    # Fixture C - malformed settings JSON, and an unrelated valid JSON file at a
    # candidate name.
    $projC = New-Dir (Join-Path $Work 'ProjC')
    Write-Utf8 -Path (Join-Path $projC '.claude\settings.local.json') -Content '{ "hooks": { "Stop": [ '
    Write-JsonFixture -Path (Join-Path $projC '.codex\hooks.json') -Value @{ unrelated = @{ some = 'config' }; version = 4 }

    Write-Host '--- Claude / Codex registration parsing ---' -ForegroundColor Cyan
    $scan = Invoke-Scan -Root $Work
    Check 'the scan exits 0' ($scan.Exit -eq 0) $scan.Err
    Check 'a result document was written' ($null -ne $scan.Result) $scan.Err
    $result = $scan.Result

    Check 'both Claude settings filenames are parsed (settings.local.json)' (
        @(Get-FindingByTarget -Result $result -Fragment 'ZZZ-Status-Managed.ps1').Count -ge 1)
    Check 'settings.json is parsed too' (
        @(Get-FindingByTarget -Result $result -Fragment 'b-hook.ps1').Count -eq 1)

    $managed = @(Get-FindingByTarget -Result $result -Fragment 'ZZZ-Status-Managed.ps1')
    Check 'multiple events on one runtime collapse into exactly ONE record' ($managed.Count -eq 1) (
        ($managed | ForEach-Object { $_.id }) -join ',')
    if ($managed.Count -eq 1) {
        $claudeEvidence = @(@($managed[0].clients) | Where-Object { $_.client -eq 'claude' })
        Check 'that record carries all three Claude events' (
            @($claudeEvidence).Count -eq 1 -and @($claudeEvidence[0].events).Count -eq 3) (
            (@($claudeEvidence[0].events)) -join ',')
        Check 'Claude and Codex merge into ONE record on proven identity' (
            @($managed[0].clients).Count -eq 2)
        Check 'the merged record is recognized as Hook Maker managed' ([string]$managed[0].managedBy -eq 'hookMaker')
        Check 'a Hook Maker record is fully removable' ([string]$managed[0].removalPolicy -eq 'full')
        # The uninstaller auto-deletes ONLY on kind 'entrypoint' plus
        # classification 'registeredRuntime'; both literals are a contract.
        Check 'a real entrypoint is emitted as kind=entrypoint/registeredRuntime' (
            @(@($managed[0].runtimeArtifacts) | Where-Object {
                [string]$_.kind -eq 'entrypoint' -and [string]$_.classification -eq 'registeredRuntime' -and
                [string]$_.deleteEligibility -eq 'eligible' }).Count -eq 1) (
            ($managed[0].runtimeArtifacts | ConvertTo-Json -Depth 4))
    }

    $thirdPartyFinding = @(Get-FindingByTarget -Result $result -Fragment 'lint.js')
    Check 'a third-party hook outside any standard hook root is discovered' ($thirdPartyFinding.Count -eq 1)
    if ($thirdPartyFinding.Count -eq 1) {
        Check 'the third-party hook is classified external, not hookMaker' ([string]$thirdPartyFinding[0].managedBy -eq 'external')
        Check 'a handler with a matcher records a matcher fingerprint' (
            @(@($thirdPartyFinding[0].clients)[0].matcherFingerprints).Count -eq 1)
        Check 'the matcher fingerprint is a 64-hex digest' (
            [string]@(@($thirdPartyFinding[0].clients)[0].matcherFingerprints)[0] -match '^[0-9a-f]{64}$')
    }

    $twinAFinding = @(@($result.findings) | Where-Object {
        @(@($_.clients) | Where-Object { @($_.parsedTargets) -contains $twinA }).Count -gt 0 -and
        [string]$_.status -ne 'ambiguous' })
    $twinBFinding = @(@($result.findings) | Where-Object {
        @(@($_.clients) | Where-Object { @($_.parsedTargets) -contains $twinB }).Count -gt 0 -and
        [string]$_.status -ne 'ambiguous' })
    Check 'two same-named hooks at DIFFERENT paths stay separate records' (
        $twinAFinding.Count -eq 1 -and $twinBFinding.Count -eq 1 -and $twinAFinding[0].id -ne $twinBFinding[0].id) (
        'a=' + $twinAFinding.Count + ' b=' + $twinBFinding.Count)
    if ($twinAFinding.Count -eq 1) {
        Check 'all three command field spellings are recorded' (
            @(@($twinAFinding[0].clients)[0].commandFieldNames).Count -eq 3) (
            (@(@($twinAFinding[0].clients)[0].commandFieldNames)) -join ',')
    }

    $disagree = @(@($result.findings) | Where-Object { [string]$_.status -eq 'ambiguous' })
    Check 'command fields that DISAGREE produce an ambiguous record' ($disagree.Count -ge 1)
    if ($disagree.Count -ge 1) {
        Check 'a disagreeing record reports registrationStatus fieldsDisagree' (
            [string]@($disagree[0].clients)[0].registrationStatus -eq 'fieldsDisagree')
        Check 'a disagreeing record is never automatically removable' ([string]$disagree[0].removalPolicy -eq 'unavailable')
        Check 'a disagreeing record is flagged for manual repair' ($disagree[0].needsManualRepair -eq $true)
    }

    $unparsed = @(@($result.findings) | Where-Object { [string]$_.status -eq 'registrationOnly' })
    Check 'an unparseable shell command is still reported as an installed hook' ($unparsed.Count -ge 1)
    if ($unparsed.Count -ge 1) {
        Check 'an unparseable registration is registration-only removable' (
            @(@($unparsed | Where-Object { [string]$_.removalPolicy -eq 'registrationOnly' })).Count -ge 1)
    }

    $missing = @(Get-FindingByTarget -Result $result -Fragment 'gone\missing.ps1')
    Check 'a registration whose target is missing is reported as missingTarget' (
        $missing.Count -eq 1 -and [string]$missing[0].status -eq 'missingTarget') (
        $(if ($missing.Count -eq 1) { [string]$missing[0].status } else { 'count=' + $missing.Count }))
    if ($missing.Count -eq 1) {
        Check 'a missing target is never delete-eligible' (
            @(@($missing[0].runtimeArtifacts) | Where-Object { [string]$_.deleteEligibility -eq 'eligible' }).Count -eq 0)
        Check 'a missing target is registration-only removable' ([string]$missing[0].removalPolicy -eq 'registrationOnly')
    }

    Check 'malformed settings JSON is a reportable warning, not a crash' (
        @(@($result.warnings) | Where-Object { $_ -like '*not valid JSON*' }).Count -eq 1) (
        (@($result.warnings)) -join ' | ')
    Check 'malformed settings JSON does not fail the scan' ([string]$result.overall -ne 'failed')
    Check 'an unrelated but valid JSON file produces no findings and no warning' (
        @(@($result.warnings) | Where-Object { $_ -like '*ProjC*' -and $_ -notlike '*not valid JSON*' }).Count -eq 0)

    Check 'an unreferenced helper file is never invented as a hook' (
        @(Get-FindingByTarget -Result $result -Fragment '_helper.ps1').Count -eq 0)

    Write-Host '--- nothing discovered is ever executed ---' -ForegroundColor Cyan
    Check 'the sentinel-writing command is discovered as a registration' (
        @(@($result.findings) | Where-Object {
            @(@($_.clients) | Where-Object { @($_.events) -contains 'PreCompactExtra' }).Count -gt 0 }).Count -eq 1)
    Check 'NO discovered command was executed (sentinel file absent)' (
        -not (Test-Path -LiteralPath $sentinel)) $sentinel

    # =====================================================================
    # Native Git discovery
    # =====================================================================
    Write-Host '--- native Git hook discovery ---' -ForegroundColor Cyan
    $gitWork = New-Dir (Join-Path $Work 'GitFixtures')

    # 1. A normal .git\hooks directory.
    $repo1 = New-Dir (Join-Path $gitWork 'Repo1')
    $repo1Hooks = New-Dir (Join-Path $repo1 '.git\hooks')
    Write-Utf8 -Path (Join-Path $repo1 '.git\config') -Content "[core]`n`trepositoryformatversion = 0`n"
    # The canonical Hook Maker wrapper, generated by the real generator so it is
    # byte-identical to a genuine install.
    $stageScript = Join-Path (New-Dir (Join-Path $repo1 'stages')) 'Ignore-Rules-Check.ps1'
    Write-Utf8 -Path $stageScript -Content '# managed pre-push stage'
    Write-Utf8 -Path (Join-Path $repo1Hooks 'pre-push') -Content (New-PrePushWrapperBody -ManagedScripts @($stageScript))
    Write-Utf8 -Path (Join-Path $repo1Hooks 'pre-commit') -Content "#!/bin/sh`necho external pre-commit`n"
    Write-Utf8 -Path (Join-Path $repo1Hooks 'my-custom-hook') -Content "#!/bin/sh`necho custom`n"
    Write-Utf8 -Path (Join-Path $repo1Hooks 'pre-rebase.sample') -Content "#!/bin/sh`nexit 0`n"

    # 2. A .git FILE with gitdir: (worktree / submodule shape).
    $repo2 = New-Dir (Join-Path $gitWork 'Repo2')
    $repo2GitDir = New-Dir (Join-Path $gitWork 'Repo2GitDir')
    New-Dir (Join-Path $repo2GitDir 'hooks') | Out-Null
    Write-Utf8 -Path (Join-Path $repo2 '.git') -Content ('gitdir: ' + $repo2GitDir)
    Write-Utf8 -Path (Join-Path $repo2GitDir 'hooks\pre-push') -Content "#!/bin/sh`necho worktree pre-push`n"

    # 3. A custom core.hooksPath.
    $repo3 = New-Dir (Join-Path $gitWork 'Repo3')
    New-Dir (Join-Path $repo3 '.git') | Out-Null
    $customHooks = New-Dir (Join-Path $repo3 'githooks')
    Write-Utf8 -Path (Join-Path $repo3 '.git\config') -Content "[core]`n`thooksPath = githooks`n"
    Write-Utf8 -Path (Join-Path $customHooks 'pre-push') -Content "#!/bin/sh`necho custom hooks path`n"

    # 4. A TAMPERED Hook Maker wrapper: carries the marker but is not what the
    #    canonical generator produces.
    $repo4 = New-Dir (Join-Path $gitWork 'Repo4')
    $repo4Hooks = New-Dir (Join-Path $repo4 '.git\hooks')
    $tampered = (New-PrePushWrapperBody -ManagedScripts @($stageScript)) + "`nrm -rf /`n"
    Write-Utf8 -Path (Join-Path $repo4Hooks 'pre-push') -Content $tampered

    $gitScan = Invoke-Scan -Root $gitWork
    Check 'the native scan exits 0' ($gitScan.Exit -eq 0) $gitScan.Err
    $gitResult = $gitScan.Result
    Check 'four git repositories are discovered' ([int]$gitResult.counts.gitRepositories -eq 4) (
        [string]$gitResult.counts.gitRepositories)

    $wrapper = @(Get-NativeFinding -Result $gitResult -HookName 'pre-push' -RepoFragment 'Repo1')
    Check 'the canonical Hook Maker wrapper is classified hookMakerWrapper' (
        $wrapper.Count -eq 1 -and [string]$wrapper[0].nativeGit.classification -eq 'hookMakerWrapper') (
        $(if ($wrapper.Count -eq 1) { [string]$wrapper[0].nativeGit.classification } else { 'count=' + $wrapper.Count }))
    if ($wrapper.Count -eq 1) {
        Check 'its managed stages are PROVEN, not guessed' (
            @($wrapper[0].nativeGit.managedStages).Count -eq 1 -and
            [string]@($wrapper[0].nativeGit.managedStages)[0] -eq $stageScript) (
            (@($wrapper[0].nativeGit.managedStages)) -join ',')
        Check 'the referenced stage script appears as a runtime artifact' (
            @(@($wrapper[0].runtimeArtifacts) | Where-Object { [string]$_.kind -eq 'nativeStage' }).Count -eq 1)
        Check 'a stage script is NEVER kind=entrypoint (it must not be auto-deleted)' (
            @(@($wrapper[0].runtimeArtifacts) | Where-Object {
                [string]$_.kind -eq 'nativeStage' -and [string]$_.deleteEligibility -eq 'preserve' }).Count -eq 1)
        Check 'the wrapper file itself is the entrypoint artifact' (
            @(@($wrapper[0].runtimeArtifacts) | Where-Object {
                [string]$_.kind -eq 'entrypoint' -and [string]$_.classification -eq 'registeredRuntime' }).Count -eq 1) (
            ($wrapper[0].runtimeArtifacts | ConvertTo-Json -Depth 4))
        Check 'a managed wrapper is removable as a native file only' (
            [string]$wrapper[0].removalPolicy -eq 'nativeFileOnly')
        Check 'the wrapper file is hashed' ([string]$wrapper[0].nativeGit.hookHash -match '^[0-9a-f]{64}$')
        Check 'the wrapper size and modified time are recorded' (
            [int64]$wrapper[0].nativeGit.hookSize -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$wrapper[0].nativeGit.hookModifiedUtc))
    }

    Check 'an external pre-commit is discovered too (not just pre-push)' (
        @(Get-NativeFinding -Result $gitResult -HookName 'pre-commit' -RepoFragment 'Repo1').Count -eq 1)
    Check 'a custom hook FILENAME is discovered' (
        @(Get-NativeFinding -Result $gitResult -HookName 'my-custom-hook').Count -eq 1)
    Check '*.sample files are ignored' (
        @(@($gitResult.findings) | Where-Object { $null -ne $_.nativeGit -and [string]$_.nativeGit.hookName -like '*.sample' }).Count -eq 0)
    $external = @(Get-NativeFinding -Result $gitResult -HookName 'pre-commit' -RepoFragment 'Repo1')
    if ($external.Count -eq 1) {
        Check 'an external native hook is classified externalNativeHook' (
            [string]$external[0].nativeGit.classification -eq 'externalNativeHook')
        Check 'an external native hook is never automatically removable' (
            [string]$external[0].removalPolicy -eq 'unavailable')
    }

    Check 'a .git FILE with gitdir: is followed to its real hooks directory' (
        @(Get-NativeFinding -Result $gitResult -HookName 'pre-push' -RepoFragment 'Repo2').Count -eq 1)
    Check 'a custom core.hooksPath is honored' (
        @(Get-NativeFinding -Result $gitResult -HookName 'pre-push' -RepoFragment 'Repo3').Count -eq 1)

    $tamperedFinding = @(Get-NativeFinding -Result $gitResult -HookName 'pre-push' -RepoFragment 'Repo4')
    Check 'a tampered marked wrapper is ambiguous, never claimed as ours' (
        $tamperedFinding.Count -eq 1 -and [string]$tamperedFinding[0].nativeGit.classification -eq 'ambiguous') (
        $(if ($tamperedFinding.Count -eq 1) { [string]$tamperedFinding[0].nativeGit.classification } else { 'count=' + $tamperedFinding.Count }))
    if ($tamperedFinding.Count -eq 1) {
        Check 'a tampered wrapper reports no proven stages' (@($tamperedFinding[0].nativeGit.managedStages).Count -eq 0)
        Check 'a tampered wrapper is flagged for manual repair' ($tamperedFinding[0].needsManualRepair -eq $true)
        Check 'a tampered wrapper is never automatically removable' ([string]$tamperedFinding[0].removalPolicy -eq 'unavailable')
    }

    # git-unavailable fallback: PATH is emptied for the child, so core.hooksPath
    # must be recovered from the repository config file instead.
    $noGitScan = Invoke-Scan -Root $gitWork -Environment @{ PATH = (Split-Path -Parent (Get-Process -Id $PID).Path) }
    Check 'the scan still exits 0 when git is unavailable' ($noGitScan.Exit -eq 0) $noGitScan.Err
    Check 'core.hooksPath is still honored without git (config-file fallback)' (
        @(Get-NativeFinding -Result $noGitScan.Result -HookName 'pre-push' -RepoFragment 'Repo3').Count -eq 1)
    Check 'the managed wrapper is still classified correctly without git' (
        @(@(Get-NativeFinding -Result $noGitScan.Result -HookName 'pre-push' -RepoFragment 'Repo1') |
            Where-Object { [string]$_.nativeGit.classification -eq 'hookMakerWrapper' }).Count -eq 1)

    # =====================================================================
    # Kiro: a perHookFile client (one JSON document per installation under
    # .kiro\hooks, no shared settings file anywhere)
    # =====================================================================
    Write-Host '--- Kiro per-hook-file registrations ---' -ForegroundColor Cyan

    function Get-FindingBySettingsFragment {
        param($Result, [string]$Fragment)
        return @(@($Result.findings) | Where-Object {
                @(@($_.clients) | Where-Object { [string]$_.settingsPath -like ('*' + $Fragment + '*') }).Count -gt 0
            })
    }

    $kiroWork = New-Dir (Join-Path $Work 'KiroWork')
    $kiroProj = New-Dir (Join-Path $kiroWork 'ProjK')

    # 1. A real managed installation, written by the real writer.
    $kiroManagedId = 'zzz-kiro-managed-01'
    $kiroRuntime = Join-Path $kiroProj '.kiro\hook-runtime\Hook-Maker\ZZZ-Kiro-Managed\ZZZ-Kiro-Managed.ps1'
    Write-Utf8 -Path $kiroRuntime -Content '# ZZZ-Kiro-Managed runtime'
    $kiroDocument = New-KiroHookDocument -FriendlyName 'ZZZ-Kiro-Managed' `
        -Command ('pwsh -NoProfile -File "' + $kiroRuntime + '"') `
        -Triggers @('SessionStart', 'PreToolUse') -TimeoutSeconds 30 -ManagedId $kiroManagedId
    # ...plus a foreign entry hand-added to OUR document, which the writer is
    # required to preserve and the scanner must therefore never claim.
    $kiroForeignInOurs = Join-Path $kiroProj 'tools\ZZZ-Kiro-Foreign-In-Ours.ps1'
    Write-Utf8 -Path $kiroForeignInOurs -Content '# hand-added by the user'
    $kiroMixed = [pscustomobject][ordered]@{
        version = 'v1'
        hooks   = @(@($kiroDocument.hooks) + @([pscustomobject][ordered]@{
                    name        = 'team-extra-check'
                    description = 'hand written by the team'
                    trigger     = 'PostToolUse'
                    action      = [pscustomobject][ordered]@{ type = 'command'; command = ('pwsh -File "' + $kiroForeignInOurs + '"') }
                    timeout     = 30
                    enabled     = $true
                }))
    }
    $kiroManagedPath = Get-KiroRegistrationPath -Scope 'project' -FriendlyName 'ZZZ-Kiro-Managed' `
        -StableId $kiroManagedId -TargetProjectRoot $kiroProj
    Write-Utf8 -Path $kiroManagedPath -Content (ConvertTo-KiroHookJson -Document $kiroMixed)

    # 2. A hand-written third-party hook in the same directory.
    $kiroTeamTarget = Join-Path $kiroProj 'tools\ZZZ-Kiro-Team.ps1'
    Write-Utf8 -Path $kiroTeamTarget -Content '# team hook'
    Write-JsonFixture -Path (Join-Path $kiroProj '.kiro\hooks\team-lint.json') -Value @{
        version = 'v1'
        hooks   = @(@{ name = 'team-lint'; trigger = 'PostToolUse'
                action  = @{ type = 'command'; command = ('pwsh -File "' + $kiroTeamTarget + '"') } })
    }

    # 3. A document NAMED like ours that carries no ownership identity at all.
    #    The filename is a hint; only the entries are evidence.
    $kiroImpostorTarget = Join-Path $kiroProj 'tools\ZZZ-Kiro-Impostor.ps1'
    Write-Utf8 -Path $kiroImpostorTarget -Content '# impostor'
    Write-JsonFixture -Path (Join-Path $kiroProj '.kiro\hooks\hookmaker-impostor-abcdef123456.json') -Value @{
        version = 'v1'
        hooks   = @(@{ name = 'looks-official'; description = 'hand written'; trigger = 'Stop'
                action  = @{ type = 'command'; command = ('pwsh -File "' + $kiroImpostorTarget + '"') } })
    }

    # 4. An 'agent' action: no subprocess, so no command and no target exists.
    Write-JsonFixture -Path (Join-Path $kiroProj '.kiro\hooks\agent-prompt.json') -Value @{
        version = 'v1'
        hooks   = @(@{ name = 'ask-the-model'; trigger = 'UserPromptSubmit'
                action  = @{ type = 'agent'; prompt = 'review the diff' } })
    }

    # 5. A Kiro command whose ONLY effect would be creating a sentinel file.
    $kiroSentinel = Join-Path $Work 'SENTINEL-KIRO-EXECUTED.txt'
    Write-JsonFixture -Path (Join-Path $kiroProj '.kiro\hooks\zzz-sentinel.json') -Value @{
        version = 'v1'
        hooks   = @(@{ name = 'sentinel'; trigger = 'SessionStart'
                action  = @{ type = 'command'
                    command = ('powershell.exe -NoProfile -Command "Set-Content -LiteralPath ''' + $kiroSentinel + ''' -Value pwned"') } })
    }

    # 6. A Claude registration in the SAME project, so "Kiro was added" and
    #    "Claude still behaves exactly as before" are proven side by side.
    $kiroSideClaude = Join-Path $kiroProj 'tools\ZZZ-Kiro-Side-Claude.ps1'
    Write-Utf8 -Path $kiroSideClaude -Content '# claude beside kiro'
    Write-JsonFixture -Path (Join-Path $kiroProj '.claude\settings.local.json') -Value @{
        hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = ('pwsh -File "' + $kiroSideClaude + '"') }) }) }
    }

    $kiroResult = (Invoke-Scan -Root $kiroWork).Result
    Check 'a scan of a Kiro project reports complete coverage with no warnings' (
        [string]$kiroResult.overall -eq 'ok') ((@($kiroResult.warnings)) -join ' || ')
    Check 'NO discovered Kiro command was executed (sentinel file absent)' (
        -not (Test-Path -LiteralPath $kiroSentinel)) $kiroSentinel

    $kiroManaged = @(Get-FindingByTarget -Result $kiroResult -Fragment 'ZZZ-Kiro-Managed.ps1')
    Check 'a managed Kiro installation is discovered' ($kiroManaged.Count -eq 1) (
        'count=' + $kiroManaged.Count + ' | ' + ((@($kiroResult.findings) | ForEach-Object { [string]$_.friendlyName }) -join ','))
    if ($kiroManaged.Count -eq 1) {
        Check 'a Kiro-only record is typed KiroRegistration' (
            [string]$kiroManaged[0].hookType -eq 'KiroRegistration') ([string]$kiroManaged[0].hookType)
        Check 'its client evidence is the kiro client' (
            @($kiroManaged[0].clients).Count -eq 1 -and [string]@($kiroManaged[0].clients)[0].client -eq 'kiro') (
            ($kiroManaged[0].clients | ConvertTo-Json -Depth 4))
        # THE project-root regression: <proj>\.kiro\hooks\x.json used to resolve
        # to <proj>\.kiro, i.e. the client directory named as the project.
        Check 'the project root is the parent of .kiro, NOT .kiro itself' (
            [string]$kiroManaged[0].targetProjectRoot -eq $kiroProj) (
            'got ' + [string]$kiroManaged[0].targetProjectRoot + ' expected ' + $kiroProj)
        Check 'a project-scoped Kiro record is scoped project' ([string]$kiroManaged[0].scope -eq 'project')
        Check 'ownership is PROVEN from the entry identity, not the filename' (
            [string]$kiroManaged[0].managedBy -eq 'hookMaker') ([string]$kiroManaged[0].managedBy)
        Check 'both triggers of one document collapse into ONE record' (
            (@(@($kiroManaged[0].clients)[0].events | Sort-Object) -join ',') -eq 'PreToolUse,SessionStart') (
            (@(@($kiroManaged[0].clients)[0].events) -join ','))
        Check 'the registration points at the proven runtime script' (
            [string]@($kiroManaged[0].clients)[0].registrationStatus -eq 'parsed')
        Check 'the registration document itself is recorded as the settings path' (
            [string]@($kiroManaged[0].clients)[0].settingsPath -eq $kiroManagedPath) (
            [string]@($kiroManaged[0].clients)[0].settingsPath)
        Check 'the real Kiro command field name travels with the evidence' (
            (@(@($kiroManaged[0].clients)[0].commandFieldNames) -join ',') -eq 'action.command') (
            (@(@($kiroManaged[0].clients)[0].commandFieldNames) -join ','))
        Check 'no raw Kiro command string is persisted in the finding' (
            ($kiroManaged[0] | ConvertTo-Json -Depth 8) -notlike '*-NoProfile -File*')
        # A per-hook-file registration cannot be pruned out of a shared settings
        # document, so nothing about it may be advertised as removable.
        Check 'a Kiro record is never offered for automatic removal' (
            [string]$kiroManaged[0].removalPolicy -eq 'unavailable') ([string]$kiroManaged[0].removalPolicy)
        Check 'and its runtime artifact is preserved, never delete-eligible' (
            @(@($kiroManaged[0].runtimeArtifacts) | Where-Object { [string]$_.deleteEligibility -ne 'preserve' }).Count -eq 0) (
            ($kiroManaged[0].runtimeArtifacts | ConvertTo-Json -Depth 4))
    }

    $kiroForeignEntry = @(Get-FindingByTarget -Result $kiroResult -Fragment 'ZZZ-Kiro-Foreign-In-Ours.ps1')
    Check 'a foreign entry inside a document we DO own is reported' ($kiroForeignEntry.Count -eq 1) (
        'count=' + $kiroForeignEntry.Count)
    if ($kiroForeignEntry.Count -eq 1) {
        Check 'and it is never claimed as ours' (
            [string]$kiroForeignEntry[0].managedBy -eq 'external') ([string]$kiroForeignEntry[0].managedBy)
    }

    $kiroTeam = @(Get-FindingByTarget -Result $kiroResult -Fragment 'ZZZ-Kiro-Team.ps1')
    Check 'a hand-written third-party Kiro hook is still discovered' ($kiroTeam.Count -eq 1) (
        'count=' + $kiroTeam.Count)
    if ($kiroTeam.Count -eq 1) {
        Check 'a hand-written third-party Kiro hook is external, never ours' (
            [string]$kiroTeam[0].managedBy -eq 'external') ([string]$kiroTeam[0].managedBy)
        Check 'and it is never offered for automatic removal either' (
            [string]$kiroTeam[0].removalPolicy -eq 'unavailable')
    }

    $kiroImpostor = @(Get-FindingByTarget -Result $kiroResult -Fragment 'ZZZ-Kiro-Impostor.ps1')
    Check 'a document merely NAMED hookmaker-*.json is discovered' ($kiroImpostor.Count -eq 1) (
        'count=' + $kiroImpostor.Count)
    if ($kiroImpostor.Count -eq 1) {
        Check 'a hookmaker-NAMED document with no entry identity is NOT claimed as ours' (
            [string]$kiroImpostor[0].managedBy -ne 'hookMaker') ([string]$kiroImpostor[0].managedBy)
        Check 'and its ownership is reported as honestly unknown' (
            [string]$kiroImpostor[0].managedBy -eq 'unknown') ([string]$kiroImpostor[0].managedBy)
    }

    $kiroAgent = @(Get-FindingBySettingsFragment -Result $kiroResult -Fragment 'agent-prompt.json')
    Check 'an agent-action Kiro hook is discovered' ($kiroAgent.Count -eq 1) ('count=' + $kiroAgent.Count)
    if ($kiroAgent.Count -eq 1) {
        Check 'an agent action spawns no process, so no target is ever claimed' (
            @(@($kiroAgent[0].clients)[0].parsedTargets).Count -eq 0 -and
            [string]@($kiroAgent[0].clients)[0].registrationStatus -eq 'unparsedCommand') (
            ($kiroAgent[0].clients | ConvertTo-Json -Depth 4))
        Check 'an agent action is honestly unknown ownership, not external' (
            [string]$kiroAgent[0].managedBy -eq 'unknown') ([string]$kiroAgent[0].managedBy)
    }

    # The regression guard that matters most for this change: adding a client
    # must not move ANY Claude/Codex answer.
    $kiroSideClaudeFinding = @(Get-FindingByTarget -Result $kiroResult -Fragment 'ZZZ-Kiro-Side-Claude.ps1')
    Check 'a Claude registration beside Kiro is still discovered' ($kiroSideClaudeFinding.Count -eq 1)
    if ($kiroSideClaudeFinding.Count -eq 1) {
        Check 'and it is still typed ClaudeRegistration' (
            [string]$kiroSideClaudeFinding[0].hookType -eq 'ClaudeRegistration')
        Check 'and its project root is unchanged by the new root derivation' (
            [string]$kiroSideClaudeFinding[0].targetProjectRoot -eq $kiroProj) (
            [string]$kiroSideClaudeFinding[0].targetProjectRoot)
        Check 'and it keeps its full removal policy' (
            [string]$kiroSideClaudeFinding[0].removalPolicy -eq 'full') (
            [string]$kiroSideClaudeFinding[0].removalPolicy)
        Check 'and its runtime artifact is still delete-eligible' (
            @(@($kiroSideClaudeFinding[0].runtimeArtifacts) |
                Where-Object { [string]$_.deleteEligibility -eq 'eligible' }).Count -eq 1) (
            ($kiroSideClaudeFinding[0].runtimeArtifacts | ConvertTo-Json -Depth 4))
    }

    Write-Host '--- Kiro documents this scanner refuses to interpret ---' -ForegroundColor Cyan
    # Separate root: these produce warnings, and the clean-coverage assertion
    # above must stay meaningful.
    $kiroOdd = New-Dir (Join-Path $Work 'KiroOdd')
    $kiroOddProj = New-Dir (Join-Path $kiroOdd 'ProjOdd')
    # Legacy 0.x shape: version "1" with when/then, not v1 with a hooks array.
    Write-JsonFixture -Path (Join-Path $kiroOddProj '.kiro\hooks\hookmaker-legacy-000000000000.json') -Value @{
        version = '1'
        when    = @{ type = 'fileEdited'; patterns = @('*.ts') }
        then    = @{ type = 'askAgent'; prompt = 'review' }
    }
    Write-Utf8 -Path (Join-Path $kiroOddProj '.kiro\hooks\broken.json') -Content '{ "version": "v1", "hooks": [ '
    $kiroOddResult = (Invoke-Scan -Root $kiroOdd).Result
    Check 'a legacy (non-v1) Kiro document produces NO record' (
        @(Get-FindingBySettingsFragment -Result $kiroOddResult -Fragment 'hookmaker-legacy').Count -eq 0) (
        ($kiroOddResult.findings | ConvertTo-Json -Depth 4))
    Check 'and the legacy document is reported as skipped, not silently ignored' (
        @(@($kiroOddResult.warnings) | Where-Object { $_ -like '*hookmaker-legacy*' }).Count -eq 1) (
        (@($kiroOddResult.warnings)) -join ' || ')
    Check 'malformed Kiro JSON is a finding, never a crash' (
        [string]$kiroOddResult.overall -ne 'failed' -and
        @(@($kiroOddResult.warnings) | Where-Object { $_ -like '*broken.json*' }).Count -eq 1) (
        (@($kiroOddResult.warnings)) -join ' || ')

    Write-Host '--- stable ids and rescan semantics ---' -ForegroundColor Cyan
    # Scanned twice over a subtree that has not changed between the two runs
    # (the whole workspace has - the git fixtures were created in between).
    $firstScanOfA = Invoke-Scan -Root $projA
    $rescan = Invoke-Scan -Root $projA
    $firstIds = @(@($firstScanOfA.Result.findings) | ForEach-Object { [string]$_.id } | Sort-Object)
    $secondIds = @(@($rescan.Result.findings) | ForEach-Object { [string]$_.id } | Sort-Object)
    Check 'the unchanged subtree yields findings to compare' ($firstIds.Count -gt 0)
    Check 'an unchanged tree rescans to the SAME ids' (($firstIds -join ',') -eq ($secondIds -join ',')) (
        ($firstIds -join ',') + ' vs ' + ($secondIds -join ','))
    Check 'every id has the disc- prefix and a 32-hex body' (
        @(@($firstIds) | Where-Object { $_ -notmatch '^disc-[0-9a-f]{32}$' }).Count -eq 0) ($firstIds -join ',')
    Check 'no raw command string is persisted in any finding' (
        ([System.IO.File]::ReadAllText($scan.ResultPath)) -notlike '*Set-Content -LiteralPath*')
}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace @($Work, $Artifacts))) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
