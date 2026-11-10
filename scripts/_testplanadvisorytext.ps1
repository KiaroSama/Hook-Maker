# Public advisory contract; reuse one capture per client, no extra policy-only subprocess.
# Dot-sourced by Test-TestPlanCheck.ps1 with its isolated harness.
$hcAdv = New-IsolatedHookCopy
$projAdv = New-GitRepo 'AdvisoryText'
$rAdv = Fire -HookPath $hcAdv.Script -Cwd $projAdv -EventName 'SessionStart' -LocalAppData $hcAdv.LocalAppData
$msgAdv = Get-Message $rAdv.Out
Check 'SessionStart emits advisory without a blocking decision' ($rAdv.Exit -eq 0 -and $msgAdv -match 'TEST PLAN CHECK' -and $rAdv.Out -notmatch '"decision"') ($rAdv.Out + '|' + $rAdv.Err)
# Bounds/waits/resources/ownership/cleanup/discovery/CPU/timings/optimization,
# edit-light/final CI/private CI/local exceptions and Windows/shared Rust now live
# behind these mandatory full-owner pointers, not inline in this reminder.
# This checks routing, NOT execution or the contents of privately deployed rules.
$policyFacts = @(
    @('test and environment owners before EVERY run', 'BEFORE EVERY run, global-test-rules.md/global-environment-rules.md FULL'),
    @('read-only advisory authority', 'Hook runs/edits/installs nothing')
)
foreach ($fact in $policyFacts) {
    $missing = @($fact | Select-Object -Skip 1 | Where-Object { -not $msgAdv.Contains($_) })
    Check ('policy route: ' + $fact[0]) ($missing.Count -eq 0) ($missing -join '; ')
}
Check 'full-owner load precedes execution boundary' (
    $msgAdv.IndexOf('BEFORE EVERY run') -ge 0 -and
    $msgAdv.IndexOf('Hook runs/edits/installs nothing') -gt $msgAdv.IndexOf('BEFORE EVERY run')) $msgAdv
Check 'ordinary policy stays concise without truncation' ($msgAdv.Length -lt 1600 -and $msgAdv -notmatch 'truncated') $msgAdv.Length
$hcAdvCl = New-IsolatedHookCopy
$projAdvCl = New-GitRepo 'AdvisoryTextClaude'
$rAdvCl = Fire -HookPath $hcAdvCl.Script -Cwd $projAdvCl -EventName 'UserPromptSubmit' -Prompt $TestRelatedPrompt -LocalAppData $hcAdvCl.LocalAppData -ClaudeProjectDir $projAdvCl
$msgAdvCl = Get-Message $rAdvCl.Out
foreach ($fact in $policyFacts) {
    $missing = @($fact | Select-Object -Skip 1 | Where-Object { -not $msgAdvCl.Contains($_) })
    Check ('Claude prompt preserves policy route: ' + $fact[0]) ($missing.Count -eq 0) ($missing -join '; ')
}
Check 'both clients retain off-Stop context without systemMessage/block' (
    $rAdv.Out -match 'hookSpecificOutput' -and $rAdvCl.Out -match 'hookSpecificOutput' -and
    $rAdv.Out -notmatch 'systemMessage|"decision"' -and $rAdvCl.Out -notmatch 'systemMessage|"decision"') ($rAdv.Err + $rAdvCl.Err)
