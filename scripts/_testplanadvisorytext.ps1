# In-process timing seam exercises the real source block with counted reads.
function Invoke-TestPlanTimingRegression {
    param([string]$SourcePath, [string]$FixtureRoot)
    $timingDir=Join-Path $FixtureRoot 'timing-key-selection';[void][IO.Directory]::CreateDirectory($timingDir)
    $cwd=$FixtureRoot;$stateDir=$timingDir
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$parseErrors)
    $keyFunction=$ast.Find({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Get-RunnerProjectKey'},$true)
    $timingBlock=$ast.Find({param($n) $n-is[Management.Automation.Language.TryStatementAst]-and$n.Extent.Text-match'^try\s*\{\s*\$myTimingKeys'},$true)
    if($null-eq$keyFunction-or$null-eq$timingBlock){throw 'Timing source seam missing'}
    . ([scriptblock]::Create($keyFunction.Extent.Text))
    $key=Get-RunnerProjectKey $cwd;$samples=@(1..5|ForEach-Object{@{outcome='ok'}})
    $doc=@{projectKey=$key;samples=$samples}|ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $stateDir ('TestTiming-'+$key+'-a.json')),$doc,[Text.UTF8Encoding]::new($false))
    # Both filename selection AND stored key must agree; neither is authority alone.
    [IO.File]::WriteAllText((Join-Path $stateDir ('TestTiming-'+('0'*12)+'-b.json')),$doc,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $stateDir ('TestTiming-'+$key+'-c.json')),($doc.Replace($key,('0'*12))),[Text.UTF8Encoding]::new($false))
    $reads=New-Object 'Collections.Generic.List[string]'
    function Read-JsonFile {param([string]$Path) [void]$reads.Add($Path);return ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json)}
    function Get-Field {param($Object,[string]$Name) return $Object.$Name}
    $script:TimingMinBaseline=5;$lines=New-Object 'Collections.Generic.List[string]'
    . ([scriptblock]::Create($timingBlock.Extent.Text))
    Check 'timing selector never opens foreign filenames or rereads duplicate project keys' ($reads.Count-eq2) $reads.Count
    Check 'timing selector still rejects mismatched stored projectKey' (($lines-join' ')-match'Local timing baselines: 1 commands') ($lines-join' ')
}

Invoke-TestPlanTimingRegression -SourcePath $Hook -FixtureRoot $Work

# Public advisory contract; reuse one capture per client, no extra policy-only subprocess.
# Dot-sourced by Test-TestPlanCheck.ps1 with its isolated harness.
$hcAdv = New-IsolatedHookCopy
$projAdv = New-GitRepo 'AdvisoryText'
$rAdv = Fire -HookPath $hcAdv.Script -Cwd $projAdv -EventName 'SessionStart' -LocalAppData $hcAdv.LocalAppData
$msgAdv = Get-Message $rAdv.Out
Check 'SessionStart emits advisory without a blocking decision' ($rAdv.Exit -eq 0 -and $msgAdv -match 'Test-Plan-Check: advisory test health' -and $rAdv.Out -notmatch '"decision"') ($rAdv.Out + '|' + $rAdv.Err)
# Bounds/waits/resources/ownership/cleanup/discovery/CPU/timings/optimization,
# edit-light/final CI/private CI/local exceptions and Windows/shared Rust now live
# behind these mandatory full-owner pointers, not inline in this reminder.
# This checks routing, NOT execution or the contents of privately deployed rules.
$policyFacts = @(
    @('test and environment owners before EVERY run', 'read global-test-rules.md FULL'),
    @('read-only advisory authority', 'Hook runs/edits nothing')
)
foreach ($fact in $policyFacts) {
    $missing = @($fact | Select-Object -Skip 1 | Where-Object { -not $msgAdv.Contains($_) })
    Check ('policy route: ' + $fact[0]) ($missing.Count -eq 0) ($missing -join '; ')
}
Check 'full-owner load precedes execution boundary' (
    $msgAdv.IndexOf('read global-test-rules.md FULL') -ge 0 -and
    $msgAdv.IndexOf('Hook runs/edits nothing') -gt $msgAdv.IndexOf('read global-test-rules.md FULL')) $msgAdv
Check 'ordinary policy stays concise without truncation' ($msgAdv.Length -lt 3000 -and $msgAdv -notmatch 'truncated') $msgAdv.Length
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
