# Public advisory contract; reuse one capture per client, no extra policy-only subprocess.
# Dot-sourced by Test-TestPlanCheck.ps1 with its isolated harness.
$hcAdv = New-IsolatedHookCopy
$projAdv = New-GitRepo 'AdvisoryText'
$rAdv = Fire -HookPath $hcAdv.Script -Cwd $projAdv -EventName 'SessionStart' -LocalAppData $hcAdv.LocalAppData
$msgAdv = Get-Message $rAdv.Out
Check 'SessionStart emits advisory without a blocking decision' ($rAdv.Exit -eq 0 -and $msgAdv -match 'TEST PLAN CHECK' -and $rAdv.Out -notmatch '"decision"') ($rAdv.Out + '|' + $rAdv.Err)
$policyFacts = @(
    @('wall and idle bounds', 'bounded WALL timeout AND an idle/no-progress timeout', 'A run with no bound is a defect'),
    @('signal-based waits', 'No long blind sleeps', 'readiness check, or bounded polling'),
    @('shared resource budget', 'shared worker ceiling for explicit/auto counts', 'cores/free memory/children/other work', 'OS/cleanup headroom', 'HOOKMAKER_MAX_TEST_WORKERS'),
    @('owned tree and teardown', 'Terminate the whole owned process tree', 'clean temp/state in finally', 'failed run'),
    @('discovery and CI coverage', 'Discover suites instead of hardcoding', 'mapped to a CI bucket'),
    @('CPU is not a hang', 'High CPU alone never means hung', 'wall/idle/memory bound'),
    @('measured timing', 'record before/after timing', '"feels faster" is not evidence'),
    @('light implementation loop', 'writing -> LIGHT type/lint/compile/import/exact-path smoke or one seam'),
    @('one final heavy pass', 'ALL edits finished -> one HEAVY suite/matrix/integration pass', 'Collect/fix ALL failures together, rerun whole pass', 'No suite per file'),
    @('optimization before evidence', 'Optimization before any run, including checks/benchmarks/guarded evidence', 'cheapest valid tier', 'one level/behavior', 'parameterized variants/shared setup'),
    @('existing tests and validity', 'Optimize new/changed/unreviewed existing tests', 'preserve validity', 'Record suite/date/before-after timing in .ai/TESTING_NOTES.md', 'reuse unchanged reviewed work'),
    @('bounded lifetime owner', 'OWNED, BOUNDED, WATCHED, SWEPT', 'recorded PID/start time + bounded reaper', 'Wall/idle expiry or interrupted wait -> kill/verify whole owned tree, never success'),
    @('survivor sweep', 'No turn end with owned runs alive', 'After subagent/final: sweep', 'Windows PID+start, exclude own shell/other projects', 'report survivors and cleanup'),
    @('manual private CI first', 'CI first (private repos too): one manual final exact-SHA batch after ALL edits', 'push starts no run by design', 'Add missing suite mapping', 'never duplicate CI locally'),
    @('local fallback evidence', 'next-edit-dependent light check', 'local-only requirement', 'live-proven billing/quota/runner/workflow/no-repo block recorded in .ai/TESTING_NOTES.md', 'queue/privacy is not fallback'),
    @('Windows and shared Rust', 'pwsh7; 5.1 only documented compatibility need', 'G:\Program Files\Rust', 'CARGO_HOME/RUSTUP_HOME/version/target', 'no project compiler duplicate', 'Advice installs nothing or changes PATH/env')
)
foreach ($fact in $policyFacts) {
    $missing = @($fact | Select-Object -Skip 1 | Where-Object { -not $msgAdv.Contains($_) })
    Check ('policy facts: ' + $fact[0]) ($missing.Count -eq 0) ($missing -join '; ')
}
$labels = @('- When optimising', '- Cadence:', '- Optimization before any run', '- No orphaned test process', '- CI first')
$previous = -1
foreach ($label in $labels) {
    $at = $msgAdv.IndexOf($label)
    Check ('policy order: ' + $label) ($at -gt $previous) $at
    $previous = $at
}
Check 'ordinary policy stays concise without truncation' ($msgAdv.Length -lt 4200 -and $msgAdv -notmatch 'truncated') $msgAdv.Length
$hcAdvCl = New-IsolatedHookCopy
$projAdvCl = New-GitRepo 'AdvisoryTextClaude'
$rAdvCl = Fire -HookPath $hcAdvCl.Script -Cwd $projAdvCl -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hcAdvCl.LocalAppData -ClaudeProjectDir $projAdvCl
$msgAdvCl = Get-Message $rAdvCl.Out
foreach ($fact in $policyFacts) {
    $missing = @($fact | Select-Object -Skip 1 | Where-Object { -not $msgAdvCl.Contains($_) })
    Check ('Claude prompt preserves policy facts: ' + $fact[0]) ($missing.Count -eq 0) ($missing -join '; ')
}
Check 'both clients retain off-Stop context without systemMessage/block' (
    $rAdv.Out -match 'hookSpecificOutput' -and $rAdvCl.Out -match 'hookSpecificOutput' -and
    $rAdv.Out -notmatch 'systemMessage|"decision"' -and $rAdvCl.Out -notmatch 'systemMessage|"decision"') ($rAdv.Err + $rAdvCl.Err)
