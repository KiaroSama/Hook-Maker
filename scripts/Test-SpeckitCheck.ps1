# Offline suite for Speckit-Check and the shared prompt scope in _scope.ps1.
#
# Everything runs against FABRICATED project directories: the hook only ever
# looks at .specify\, .specify\memory\constitution.md and specs\<name>\, so no
# Spec Kit installation is needed - and must never be, or the suite would
# depend on whether the developer happens to have initialised this repo.
#
# The four fixtures are built ONCE and reused. Each routing branch is a
# different fixture rather than a mutated one, so the cases are order
# independent and can be read in isolation.
#
# Exit code is the number of failed assertions (0 = all passed).

[CmdletBinding()]
param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$HooksRoot = Join-Path $ToolRoot 'hooks'
$Hook = Join-Path $HooksRoot 'Speckit-Check\Speckit-Check.ps1'
$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $ScriptRoot '_testlib.ps1')
. (Join-Path $HooksRoot '_hooklib.ps1')
. (Join-Path $HooksRoot '_scope.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-speckit'
$savedSuiteEnvironment = @{}
foreach ($key in @('LOCALAPPDATA', 'HOOKMAKER_CLIENT', 'CLAUDE_PROJECT_DIR')) {
    $savedSuiteEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
$env:LOCALAPPDATA = Join-Path $Work 'suite-state'
$env:CLAUDE_PROJECT_DIR = ''

function Invoke-SpeckitHook {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Payload,
        [string]$Client = 'claude'
    )
    $json = ($Payload | ConvertTo-Json -Depth 8 -Compress)
    $previous = $env:HOOKMAKER_CLIENT
    $env:HOOKMAKER_CLIENT = $Client
    try {
        $hostExe = (Get-Process -Id $PID).Path
        $out = ($json | & $hostExe -NoProfile -File $Hook 2>&1) -join "`n"
        return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    }
    finally { $env:HOOKMAKER_CLIENT = $previous }
}

function New-SpeckitProject {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$WithInfrastructure,
        [switch]$WithConstitution,
        [AllowEmptyString()][string]$Feature = '',
        # [object], NOT [string]: PowerShell coerces $null to '' when binding a
        # [string] parameter, so a "no tasks.md at all" fixture would silently get
        # an EMPTY one - which reads as a finished feature, the opposite case.
        [AllowNull()][object]$TasksBody = $null
    )
    $root = Join-Path $Work $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if ($WithInfrastructure) {
        New-Item -ItemType Directory -Path (Join-Path $root '.specify\memory') -Force | Out-Null
        if ($WithConstitution) {
            [System.IO.File]::WriteAllText((Join-Path $root '.specify\memory\constitution.md'), "# c`n")
        }
    }
    if ($Feature -ne '') {
        $dir = Join-Path $root ('specs\' + $Feature)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'spec.md'), "# spec`n")
        if ($null -ne $TasksBody) { [System.IO.File]::WriteAllText((Join-Path $dir 'tasks.md'), $TasksBody) }
    }
    return $root
}

try {
    # =====================================================================
    Write-Host '--- the shared prompt scope answers for work, not for chat ---' -ForegroundColor Cyan

    # ARM 1: a feature request. Already answered by Test-FeatureRequestPrompt.
    Check 'a feature request is project-changing work' (
        Test-ProjectChangingPrompt -Prompt 'add a --json option to the export command') ''
    # ARM 2: a structural request, answered by _hooklib's classifier.
    Check 'a structural request is project-changing work' (
        Test-ProjectChangingPrompt -Prompt 'refactor the module boundaries here') ''
    # ARM 3 IS THE LOAD-BEARING ONE. Test-FeatureRequestPrompt SUBTRACTS the
    # defect case on purpose, so without this arm the hook is silent on exactly
    # the case the 2026-09-19 rules added to the spec-driven route.
    Check 'a bug report is project-changing work (the arm the feature classifier subtracts)' (
        Test-ProjectChangingPrompt -Prompt 'fix the crash in the storage layer') ''
    Check 'and the feature classifier alone would have rejected it, which is why the arm exists' (
        -not (Test-FeatureRequestPrompt -Prompt 'fix the crash in the storage layer')) ''
    Check 'a plain question is not project-changing work' (
        -not (Test-ProjectChangingPrompt -Prompt 'what does this project do?')) ''
    Check 'an empty prompt is not project-changing work' (
        -not (Test-ProjectChangingPrompt -Prompt '')) ''
    Check 'moving the classifier did not change its answers' (
        (Test-FeatureRequestPrompt -Prompt 'add a new dashboard page') -and
        -not (Test-FeatureRequestPrompt -Prompt 'fix the typo in the readme')) ''

    # =====================================================================
    Write-Host '--- the route names what is actually on disk ---' -ForegroundColor Cyan

    $bare = New-SpeckitProject -Name 'bare'
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $bare; session_id = 'r1'; prompt = 'add an export feature' }
    Check 'no .specify/ -> init then constitution' ($r.Out -match 'speckit-init, then speckit-constitution') $r.Out
    Check 'and it is advisory, never a block' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision"') $r.Out

    $infra = New-SpeckitProject -Name 'infra' -WithInfrastructure -WithConstitution
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $infra; session_id = 'r2'; prompt = 'add an export feature' }
    Check 'infrastructure but no feature -> the full chain from specify' (
        $r.Out -match 'no feature carries a spec yet') $r.Out

    $open = New-SpeckitProject -Name 'open' -WithInfrastructure -WithConstitution -Feature '001-x' -TasksBody "- [ ] T001 a`r`n- [x] T002 b`r`n- [ ] T003 c"
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'r3'; prompt = 'add an export feature' }
    Check 'an unfinished feature is named, with its exact open count' (
        $r.Out -match 'specs/001-x' -and $r.Out -match '2 unchecked item') $r.Out

    $done = New-SpeckitProject -Name 'done' -WithInfrastructure -WithConstitution -Feature '002-y' -TasksBody '- [x] T001 done'
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $done; session_id = 'r4'; prompt = 'add an export feature' }
    Check 'a finished feature routes resumed work to converge' (
        $r.Out -match 'specs/002-y' -and $r.Out -match 'no unchecked items' -and $r.Out -match 'speckit-converge') $r.Out

    # UNREADABLE IS NOT ABSENT. A feature whose tasks.md is missing must not be
    # reported as finished - that would send the agent to start something new
    # on top of work whose state nobody checked.
    $blind = New-SpeckitProject -Name 'blind' -WithInfrastructure -WithConstitution -Feature '003-z'
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $blind; session_id = 'r5'; prompt = 'add an export feature' }
    Check 'a feature whose task list cannot be read is UNKNOWN, never "finished"' (
        $r.Out -match 'UNKNOWN' -and $r.Out -notmatch 'no unchecked items') $r.Out

    # =====================================================================
    Write-Host '--- silence is the default ---' -ForegroundColor Cyan

    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'r3'; prompt = 'add an export feature' }
    Check 'the same project in the same session says nothing a second time' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 's-other'; prompt = 'add an export feature' }
    Check 'but a different session gets the message' ($r.Out -match 'SPECKIT CHECK') $r.Out

    # The state CHANGING is what un-suppresses it: initialising a project
    # mid-session must not be silenced by the "no .specify/ yet" note.
    New-Item -ItemType Directory -Path (Join-Path $bare '.specify\memory') -Force | Out-Null
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $bare; session_id = 'r1'; prompt = 'add an export feature' }
    Check 'initialising the project mid-session re-arms the follow-up route' (
        $r.Out -match 'SPECKIT CHECK' -and $r.Out -notmatch 'No \.specify/ here yet') $r.Out

    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'q1'; prompt = 'what does this project do?' }
    Check 'a question-shaped prompt is silent' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = (Join-Path $Work 'no-such-dir'); session_id = 'q2'; prompt = 'add a feature' }
    Check 'a cwd that is not a directory is silent' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $open; session_id = 'q3' }
    Check 'it ignores events it does not own - it has nothing to say at Stop' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'SessionStart'; cwd = $open; session_id = 'q4' }
    Check 'SessionStart needs no prompt and still routes' ($r.Out -match 'SPECKIT CHECK') $r.Out

    # =====================================================================
    Write-Host '--- both client wire shapes ---' -ForegroundColor Cyan

    $r = Invoke-SpeckitHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $done; session_id = 'w1'; prompt = 'add an export feature' } -Client 'claude'
    Check 'claude gets hookSpecificOutput.additionalContext with the event name' (
        $r.Out -match '"hookSpecificOutput"' -and $r.Out -match '"hookEventName":"UserPromptSubmit"' -and
        $r.Out -match '"additionalContext"') $r.Out
    Check 'and never a decision on an advisory' ($r.Out -notmatch '"decision"') $r.Out
    # CODEX SHARES THE ENVELOPE HERE, on purpose. The systemMessage divergence
    # is Stop-scoped; on every other event Codex honours additionalContext and
    # the adapter keeps the event name Claude's shape carries. Asserting a
    # "bare additionalContext" here would pin an expectation the adapter
    # deliberately does not hold.
    $r = Invoke-SpeckitHook -Payload @{ hook_event_name = 'UserPromptSubmit'; cwd = $done; session_id = 'w2'; prompt = 'add an export feature' } -Client 'codex'
    Check 'codex gets the same hookSpecificOutput envelope on UserPromptSubmit' (
        $r.Out -match '"hookSpecificOutput"' -and $r.Out -match '"hookEventName":"UserPromptSubmit"' -and
        $r.Out -match '"additionalContext"') $r.Out
    Check 'and neither client ever gets systemMessage here - that divergence is Stop-only' (
        $r.Out -notmatch '"systemMessage"') $r.Out
    Check 'and never a decision either' ($r.Out -notmatch '"decision"') $r.Out

    # =====================================================================
    Write-Host '--- the shared directory scope keeps every hook its coverage ---' -ForegroundColor Cyan

    foreach ($ci in @('.ci-runner', '.ci-runner-win', '.ci-work', '.ci-cache')) {
        Check ('the shared base excludes the project-owned CI directory ' + $ci) (
            @($script:HookMakerExcludedDirs) -contains $ci) $ci
    }
    Check 'the shared base excludes the regenerated code index' (
        @($script:HookMakerExcludedDirs) -contains '.codebase-memory') ''
    # THE TRAP THE BASE EXISTS TO AVOID. Merging the five hooks' arrays would
    # have added 'logs' here, and a secret scan that stops reading logs\ has
    # lost exactly the coverage a leak guard is for.
    Check 'the shared base does NOT exclude logs (the secret scan must keep reading it)' (
        @($script:HookMakerExcludedDirs) -notcontains 'logs') ''
    Check 'the shared base does NOT exclude coverage or .cross-project-sync either' (
        @($script:HookMakerExcludedDirs) -notcontains 'coverage' -and
        @($script:HookMakerExcludedDirs) -notcontains '.cross-project-sync') ''

    # THE INVARIANT THAT MATTERS, asserted per hook rather than as a list: after
    # the shared base landed, each of the five tree-walking hooks must still
    # exclude everything it excluded BEFORE. A list assertion would have passed
    # on the day the five copies drifted apart; this one compares the recorded
    # historical set against what the hook now composes.
    #
    # The "before" sets are pinned literals on purpose - they are the state the
    # five files were measured in on 2026-09-19, and reading them back out of
    # the current sources would make the test agree with whatever it finds.
    $historical = @{
        'Dependency-Version-Check' = @{
            Extra  = @('logs', '.cross-project-sync')
            Before = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync')
        }
        'Github-Baseline-Check'    = @{
            Extra  = @('logs', '.cross-project-sync', '.github')
            Before = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync', '.github')
        }
        'Large-File-Check'         = @{
            Extra  = @('logs', '.cross-project-sync')
            Before = @('.git', 'node_modules', '.ai', 'graphify-out', 'logs', 'dist', 'build', 'out', 'target', 'vendor', '__pycache__', '.venv', 'venv', '.claude', '.codex', 'bin', 'obj', '.cross-project-sync')
        }
        'Secrets-Check'            = @{
            Extra  = @('vendors', 'coverage', '.cache', 'cache', 'env', '.agents')
            Before = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj', '.ci-runner')
        }
        'Test-Plan-Check'          = @{
            Extra  = @('vendors', 'coverage', '.cache', 'cache', 'env', '.agents', '.tox', 'site-packages')
            Before = @('.git', 'node_modules', 'vendor', 'vendors', 'dist', 'build', 'out', 'target', 'coverage', '.cache', 'cache', '__pycache__', '.venv', 'venv', 'env', '.ai', 'graphify-out', '.claude', '.codex', '.agents', 'bin', 'obj', '.ci-runner', '.tox', 'site-packages')
        }
    }
    foreach ($hookName in @($historical.Keys | Sort-Object)) {
        $spec = $historical[$hookName]
        $effective = @(Get-HookExcludedDirs -Extra @($spec.Extra))
        $lost = @(@($spec.Before) | Where-Object { $effective -notcontains $_ })
        Check ($hookName + ' still excludes everything it excluded before the shared base') (
            $lost.Count -eq 0) ('lost: ' + ($lost -join ','))
        foreach ($ci in @('.ci-runner', '.ci-runner-win', '.ci-work', '.ci-cache')) {
            Check ($hookName + ' now excludes ' + $ci) ($effective -contains $ci) ''
        }
        # The source must actually COMPOSE the base rather than keep a private
        # copy - otherwise this whole block asserts about a list nothing reads.
        $hookSource = [System.IO.File]::ReadAllText((Join-Path $HooksRoot (Join-Path $hookName ($hookName + '.ps1'))))
        Check ($hookName + ' composes the shared base instead of a private list') (
            $hookSource -match 'Get-HookExcludedDirs -Extra' -and
            $hookSource -notmatch '\$excludedDirs = @\(''\.git''') ''
    }
    $merged = @(Get-HookExcludedDirs -Extra @('logs', '.git', 'logs'))
    Check 'a hook adds its extras beside the base, de-duplicated' (
        (@($merged | Where-Object { $_ -eq 'logs' }).Count -eq 1) -and
        (@($merged | Where-Object { $_ -eq '.git' }).Count -eq 1) -and
        ($merged.Count -eq $script:HookMakerExcludedDirs.Count + 1)) ($merged -join ',')
}
finally {
    foreach ($key in $savedSuiteEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedSuiteEnvironment[$key]) }
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
    else { Write-Host ('Artifacts kept: ' + $Work) -ForegroundColor DarkGray }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
