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
    Check 'no .specify/ -> init then constitution' ($r.Out -match 'speckit-init -> speckit-constitution') $r.Out
    Check 'and it is advisory, never a block' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision"') $r.Out

    $infra = New-SpeckitProject -Name 'infra' -WithInfrastructure -WithConstitution
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $infra; session_id = 'r2'; prompt = 'add an export feature' }
    Check 'infrastructure but no feature -> the full chain from specify' (
        $r.Out -match 'without feature spec: full chain from speckit-specify') $r.Out

    $open = New-SpeckitProject -Name 'open' -WithInfrastructure -WithConstitution -Feature '001-x' -TasksBody "- [ ] T001 a`r`n- [x] T002 b`r`n- [ ] T003 c"
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'r3'; prompt = 'add an export feature' }
    Check 'an unfinished feature is named, with its exact open count' (
        $r.Out -match 'specs/001-x' -and $r.Out -match '2 unchecked') $r.Out

    $done = New-SpeckitProject -Name 'done' -WithInfrastructure -WithConstitution -Feature '002-y' -TasksBody '- [x] T001 done'
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $done; session_id = 'r4'; prompt = 'add an export feature' }
    Check 'a finished feature routes resumed work to converge' (
        $r.Out -match 'specs/002-y' -and $r.Out -match 'tasks checked' -and $r.Out -match 'speckit-converge') $r.Out

    # UNREADABLE IS NOT ABSENT. A feature whose tasks.md is missing must not be
    # reported as finished - that would send the agent to start something new
    # on top of work whose state nobody checked.
    $blind = New-SpeckitProject -Name 'blind' -WithInfrastructure -WithConstitution -Feature '003-z'
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $blind; session_id = 'r5'; prompt = 'add an export feature' }
    Check 'a feature whose task list cannot be read is UNKNOWN, never "finished"' (
        $r.Out -match 'UNKNOWN' -and $r.Out -notmatch 'tasks checked') $r.Out

    # =====================================================================
    Write-Host '--- silence is the default ---' -ForegroundColor Cyan

    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'r3'; prompt = 'add an export feature' }
    Check 'the same project in the same session says nothing a second time' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 's-other'; prompt = 'add an export feature' }
    Check 'but a different session gets the message' ($r.Out -match 'Speckit-Check: advisory') $r.Out

    # The state CHANGING is what un-suppresses it: initialising a project
    # mid-session must not be silenced by the "no .specify/ yet" note.
    New-Item -ItemType Directory -Path (Join-Path $bare '.specify\memory') -Force | Out-Null
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $bare; session_id = 'r1'; prompt = 'add an export feature' }
    Check 'initialising the project mid-session re-arms the follow-up route' (
        $r.Out -match 'Speckit-Check: advisory' -and $r.Out -notmatch 'No \.specify/:') $r.Out

    # =====================================================================
    Write-Host '--- mid-task intake (order 55, step 3) ---' -ForegroundColor Cyan

    # A NEW request while a feature is open, with nothing on disk changed: the
    # earlier fingerprint had no request in it, so this was silenced - exactly
    # the case the intake line exists for.
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'r3'; prompt = 'also fix the login bug in the api' }
    Check 'a NEW request mid-task is surfaced although task counts and timestamps are unchanged' (
        $r.Out -match 'Speckit-Check: advisory') $r.Out
    # Dated IDs/acceptance/order/artifacts/phases/gates live behind full owner.
    Check 'intake requires full Spec Kit owner before project-change/delta dependents' (
        $r.Out -match 'global-spec-kit-rules.md/global-project-lifecycle-rules.md') $r.Out
    Check 'only dependent work waits' ($r.Out -match 'ask unknowns') $r.Out
    Check 'intake retains ownership without implicit cross-project repair' (
        $r.Out -match 'Newest folder != owner' -and $r.Out -match 'other-project needs consent/handoff') $r.Out
    Check 'the old "finish existing tasks before starting anything else" is gone' (
        $r.Out -notmatch 'before starting something else') $r.Out

    # The pointer wins over recency: folder write time is not ownership.
    $ptr = New-SpeckitProject -Name 'pointer' -WithInfrastructure -WithConstitution -Feature '001-active' -TasksBody '- [ ] T001 open'
    $newerDir = Join-Path $ptr 'specs\002-unrelated'
    New-Item -ItemType Directory -Path $newerDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $newerDir 'spec.md'), "# spec`n")
    [System.IO.File]::WriteAllText((Join-Path $newerDir 'tasks.md'), '- [x] T001 done')
    (Get-Item -LiteralPath (Join-Path $newerDir 'tasks.md')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
    [System.IO.File]::WriteAllText((Join-Path $ptr '.specify\feature.json'), '{"feature_directory":"specs/001-active"}')
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $ptr; session_id = 'p1'; prompt = 'add an export feature' }
    Check 'the active-feature pointer wins over a newer unrelated folder' (
        $r.Out -match 'Active feature \(\.specify/feature\.json\): specs/001-active' -and $r.Out -notmatch '002-unrelated') $r.Out
    # A pointer to something that is not a spec-bearing folder under specs\
    # falls back to recency rather than routing to nowhere.
    [System.IO.File]::WriteAllText((Join-Path $ptr '.specify\feature.json'), '{"feature_directory":"specs/999-missing"}')
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $ptr; session_id = 'p2'; prompt = 'add an export feature' }
    Check 'a dangling pointer falls back to the newest feature, labelled as such' (
        $r.Out -match 'no active-feature pointer' -and $r.Out -match 'specs/002-unrelated') $r.Out

    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = $open; session_id = 'q1'; prompt = 'what does this project do?' }
    Check 'a question-shaped prompt is silent' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'UserPromptSubmit'; cwd = (Join-Path $Work 'no-such-dir'); session_id = 'q2'; prompt = 'add a feature' }
    Check 'a cwd that is not a directory is silent' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $open; session_id = 'q3' }
    Check 'Stop without a transcript is silent (no evidence is not a violation)' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'SubagentStop'; cwd = $open; session_id = 'q3b' }
    Check 'SubagentStop is not owned - a subagent works under its parent chain' ($r.Out.Trim() -eq '') $r.Out

    # =====================================================================
    Write-Host '--- Stop gate: multi-file change without the chain (spec 036) ---' -ForegroundColor Cyan
    function New-GateTranscript {
        param([string]$Name, [string]$Root, [string]$Prompt, [string[]]$Writes, [string[]]$Skills = @())
        $entries = New-Object System.Collections.Generic.List[string]
        [void]$entries.Add((@{ type = 'user'; message = @{ role = 'user'; content = $Prompt } } | ConvertTo-Json -Depth 8 -Compress))
        foreach ($s in $Skills) { [void]$entries.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Skill'; input = @{ skill = $s } }) } } | ConvertTo-Json -Depth 8 -Compress)) }
        foreach ($w in $Writes) { [void]$entries.Add((@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Edit'; input = @{ file_path = (Join-Path $Root $w) } }) } } | ConvertTo-Json -Depth 8 -Compress)) }
        $path = Join-Path $Work ($Name + '.jsonl')
        [System.IO.File]::WriteAllText($path, (($entries.ToArray() -join "`n") + "`n"))
        return $path
    }
    $gateRoot = New-SpeckitProject -Name 'StopGate' -WithInfrastructure -WithConstitution
    $three = @('src\a.ps1', 'src\b.ps1', 'docs\c.md')
    $t = New-GateTranscript 'gate-3' $gateRoot 'add an export feature to the app' $three
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g1'; transcript_path = $t }
    Check 'a change request + 3 edited files + no chain -> blocked once' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'SPECKIT CHECK' -and $r.Out -match 'edited 3 files') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g1'; transcript_path = $t }
    Check 'the same unchanged request set is not refused twice' ($r.Out -notmatch '"decision"\s*:\s*"block"') $r.Out
    $t = New-GateTranscript 'gate-2' $gateRoot 'add an export feature to the app' @('src\a.ps1', 'src\b.ps1')
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g2'; transcript_path = $t }
    Check '1-2 edited files is a small task - silent' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'gate-q' $gateRoot 'what does this project do?' $three
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g3'; transcript_path = $t }
    Check 'a question-only session is silent regardless of edits' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'gate-skill' $gateRoot 'add an export feature to the app' $three @('spec-kit:speckit-specify')
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g4'; transcript_path = $t }
    Check 'a speckit-* Skill call clears the gate' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'gate-specs' $gateRoot 'add an export feature to the app' ($three + @('specs\001-x\tasks.md'))
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g5'; transcript_path = $t }
    Check 'a write under specs/ clears the gate' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'gate-private' $gateRoot 'add an export feature to the app' @('src\a.ps1', '.ai\memory.md', '.claude\x.md', 'plans\p.md')
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g6'; transcript_path = $t }
    Check '.ai/.claude/plans writes are not counted as edited files' ($r.Out.Trim() -eq '') $r.Out
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g7'; transcript_path = (Join-Path $Work 'missing.jsonl') }
    Check 'an unreadable transcript is silent' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'gate-own' $gateRoot 'SPECKIT CHECK: request "add an export feature" edited 3 files' $three
    $r = Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $gateRoot; session_id = 'g8'; transcript_path = $t }
    Check 'its own banner never arms the gate' ($r.Out.Trim() -eq '') $r.Out
    # =====================================================================
    Write-Host '--- Stop gate: Spec Kit CHAIN/EXEMPT classification (spec 041) ---' -ForegroundColor Cyan
    $classRoot = New-SpeckitProject -Name 'ClassGate' -WithInfrastructure -WithConstitution
    $closingOk = "Done.`nSpec Kit: EXEMPT (small) - one wording fix"
    function Invoke-Class { param([string]$Sid, [string]$Transcript, [string]$Closing, [string]$HookPath = $Hook)
        $saved = $script:Hook; $script:Hook = $HookPath
        try { return (Invoke-SpeckitHook @{ hook_event_name = 'Stop'; cwd = $classRoot; session_id = $Sid; transcript_path = $Transcript; last_assistant_message = $Closing }) }
        finally { $script:Hook = $saved } }
    $t = New-GateTranscript 'class-one' $classRoot 'fix the typo in the readme' @('README.md')
    $r = Invoke-Class 'c1' $t 'Fixed the typo.'
    Check 'an edited turn with no Spec Kit line -> blocked once' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'no Spec Kit line') $r.Out
    $r = Invoke-Class 'c1' $t 'Fixed the typo.'
    Check 'the same missing line is not refused twice in one turn' ($r.Out -notmatch '"decision"\s*:\s*"block"') $r.Out
    $r = Invoke-Class 'c2' $t $closingOk
    Check 'EXEMPT (small) with one ordinary file passes' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'class-two' $classRoot 'fix the typo in the readme' @('README.md', 'docs\x.md')
    $r = Invoke-Class 'c3' $t $closingOk
    Check 'EXEMPT small with 2 edited files -> reclassify' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'Reclassify as CHAIN' -and $r.Out -match '2 project files') $r.Out
    $t = New-GateTranscript 'class-ci' $classRoot 'fix the typo in the readme' @('.github\workflows\ci.yml')
    $r = Invoke-Class 'c4' $t $closingOk
    Check 'EXEMPT small touching a CI workflow -> reclassify' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'ci\.yml') $r.Out
    $t = New-GateTranscript 'class-lock' $classRoot 'fix the typo in the readme' @('Cargo.lock')
    $r = Invoke-Class 'c5' $t $closingOk
    Check 'EXEMPT small touching a lockfile -> reclassify' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'Cargo\.lock') $r.Out
    $t = New-GateTranscript 'class-q' $classRoot 'what does this do?' @('src\a.ps1')
    $r = Invoke-Class 'c6' $t "Spec Kit: EXEMPT (question)"
    Check 'EXEMPT (question) after a project edit -> reclassify' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'a question turn') $r.Out
    $t = New-GateTranscript 'class-chain' $classRoot 'add an export feature' @('src\a.ps1')
    $r = Invoke-Class 'c7' $t "Spec Kit: CHAIN (specify -> implement)"
    Check 'CHAIN without speckit evidence -> blocked' ($r.Out -match '"decision"\s*:\s*"block"' -and $r.Out -match 'no speckit-\* step') $r.Out
    $t = New-GateTranscript 'class-chain-ok' $classRoot 'add an export feature' @('src\a.ps1') @('speckit-implement')
    $r = Invoke-Class 'c8' $t "Spec Kit: CHAIN (implement)"
    Check 'CHAIN with speckit-implement before governed edits passes silently' ($r.Out.Trim() -eq '') $r.Out
    # Order 107 step 5d: governed edit before speckit-implement in a CHAIN task gets one advisory (not a block).
    $orderEntries = @(
        (@{ type = 'user'; message = @{ role = 'user'; content = 'add an export feature' } } | ConvertTo-Json -Depth 8 -Compress),
        (@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Edit'; input = @{ file_path = (Join-Path $classRoot 'src\early.ps1') } }) } } | ConvertTo-Json -Depth 8 -Compress),
        (@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'Skill'; input = @{ skill = 'speckit-implement' } }) } } | ConvertTo-Json -Depth 8 -Compress)
    )
    $tOrder = Join-Path $Work 'class-chain-order.jsonl'
    [System.IO.File]::WriteAllText($tOrder, (($orderEntries -join "`n") + "`n"))
    $r = Invoke-Class 'c8b' $tOrder "Spec Kit: CHAIN (specify -> implement)"
    Check '107 5d: CHAIN edit before speckit-implement -> one advisory, not a block' (
        $r.Out -notmatch '"decision"\s*:\s*"block"' -and $r.Out -match 'src/early\.ps1 edited before speckit-implement') $r.Out
    $r = Invoke-Class 'c8b' $tOrder "Spec Kit: CHAIN (specify -> implement)"
    Check '107 5d: the same pre-implement advisory is not repeated in one turn' ($r.Out.Trim() -eq '') $r.Out
    $tNoImpl = New-GateTranscript 'class-chain-noimpl' $classRoot 'add an export feature' @('src\a.ps1') @('speckit-specify')
    $r = Invoke-Class 'c8c' $tNoImpl "Spec Kit: CHAIN (specify)"
    Check '107 5d: CHAIN edit with speckit-specify only (no speckit-implement) -> one advisory' (
        $r.Out -notmatch '"decision"\s*:\s*"block"' -and $r.Out -match 'edited before speckit-implement') $r.Out
    $t = New-GateTranscript 'class-none' $classRoot 'what does this do?' @()
    $r = Invoke-Class 'c9' $t 'It routes hooks.'
    Check 'a turn without project edits has no classification duty' ($r.Out.Trim() -eq '') $r.Out
    $t = New-GateTranscript 'class-sub' $classRoot 'fix the typo' @('README.md')
    $r = Invoke-SpeckitHook @{ hook_event_name = 'SubagentStop'; cwd = $classRoot; session_id = 'c10'; transcript_path = $t; last_assistant_message = 'x' }
    Check 'SubagentStop is never refused by the classification gate' ($r.Out.Trim() -eq '') $r.Out
    foreach ($mode in @('advisory', 'off')) {
        $dir = Join-Path $Work ('speckit-' + $mode)
        New-Item -ItemType Directory -Path (Join-Path $dir 'Speckit-Check') -Force | Out-Null
        Copy-Item (Join-Path (Split-Path -Parent $Hook) '*.ps1') (Join-Path $dir 'Speckit-Check')
        Copy-TestRuntimeLibraries -SourceHookLib (Join-Path $HooksRoot '_hooklib.ps1') -Destination (Join-Path $dir '_hooklib.ps1')
        [IO.File]::WriteAllText((Join-Path $dir 'Speckit-Check\.env'), "HOOK_ENFORCEMENT=$mode`r`n")
        $t = New-GateTranscript ('class-' + $mode) $classRoot 'fix the typo in the readme' @('README.md')
        $r = Invoke-Class ('c-' + $mode) $t 'Fixed.' (Join-Path $dir 'Speckit-Check\Speckit-Check.ps1')
        if ($mode -eq 'advisory') { Check 'HOOK_ENFORCEMENT=advisory reports without a block' ($r.Out -match 'Spec Kit line' -and $r.Out -notmatch '"decision"') $r.Out }
        else { Check 'HOOK_ENFORCEMENT=off is silent' ($r.Out.Trim() -eq '') $r.Out }
    }

    $r = Invoke-SpeckitHook @{ hook_event_name = 'SessionStart'; cwd = $open; session_id = 'q4' }
    Check 'SessionStart needs no prompt and still routes' ($r.Out -match 'Speckit-Check: advisory') $r.Out

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

    Write-Host '--- monthly Spec Kit refresh advisory (files only) ---' -ForegroundColor Cyan
    $refreshText = 'Refresh: `specify integration status` -> `specify integration upgrade <key>` EACH installed -> `specify extension update`; date .ai/COMMANDS.md.'
    function New-RefreshProject {
        param([string]$Name, [AllowNull()][object]$RecordedDaysAgo)
        $root = New-SpeckitProject -Name $Name -WithInfrastructure -WithConstitution
        if ($null -ne $RecordedDaysAgo) {
            New-Item -ItemType Directory -Path (Join-Path $root '.ai') -Force | Out-Null
            $date = [DateTime]::UtcNow.Date.AddDays(-[int]$RecordedDaysAgo).ToString('yyyy-MM-dd')
            [System.IO.File]::WriteAllText((Join-Path $root '.ai\COMMANDS.md'), ("# Commands`n- " + $date + " Spec Kit refresh: specify 0.9, upgrade ok`n"))
        }
        return $root
    }
    function Get-RefreshOut { param([string]$Cwd) (Invoke-SpeckitHook -Payload @{ hook_event_name = 'SessionStart'; cwd = $Cwd; session_id = 'refresh' }).Out }
    $rfNone = New-RefreshProject -Name 'RefreshNone' -RecordedDaysAgo $null
    $out = Get-RefreshOut $rfNone
    $context = ''
    try { $context = [string](($out | ConvertFrom-Json).hookSpecificOutput.additionalContext) } catch { }
    Check 'no recorded refresh -> the fixed refresh text, verbatim' ($context.Contains($refreshText)) $out
    $out = Get-RefreshOut $rfNone
    Check 'the same recorded state is advised once per project' (-not $out.Contains('Refresh: `specify integration status`')) $out
    $out = Get-RefreshOut (New-RefreshProject -Name 'Refresh31' -RecordedDaysAgo 31)
    Check 'a refresh recorded 31 days ago -> advised' ($out -match 'Refresh: `specify integration status`') $out
    $out = Get-RefreshOut (New-RefreshProject -Name 'Refresh5' -RecordedDaysAgo 5)
    Check 'a refresh recorded 5 days ago -> not advised, route still given' ($out -notmatch 'Refresh: `specify integration status`' -and $out -match 'Speckit-Check: advisory') $out
    $out = Get-RefreshOut (New-SpeckitProject -Name 'RefreshNoSpecify')
    Check 'a folder without .specify/ never gets the refresh text' ($out -notmatch 'Refresh: `specify integration status`') $out
    $speckitSource = [System.IO.File]::ReadAllText($Hook)
    Check 'the hook never runs specify (no invocation in its source)' (
        $speckitSource -notmatch '(?im)^[^#\r\n]*(&\s*[''"]?specify\b|FilePath\s+[''"]?specify\b|Start-Process[^\r\n]*specify\b)') ''
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
