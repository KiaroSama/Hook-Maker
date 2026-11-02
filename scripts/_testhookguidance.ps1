# Literal budgets detect policy-dump regressions, not tokenizer/billing savings.
# Includes every shipped package and shared guidance; executable/data strings make
# this a conservative ceiling, not a count of what one event emits. Never truncate.
$guidanceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
$guidanceBudgets = @{
    'Ai-Memory-Check'=1900; 'Ai-Memory-Load'=2450; 'Cbm-Read-Check'=3600; 'Cbm-Update-Check'=1300
    'Ci-Status-Check'=46000; 'Cloudflare-Deploy'=8800; 'Cross-Project-.ai-Knowledge-Sync'=14200
    'Dependabot-Check'=3000; 'Dependency-Version-Check'=14400; 'Docs-Freshness-Check'=8100
    'Feature-Request-Check'=2900; 'Git-Sync-Check'=13200; 'Github-Baseline-Check'=9400
    'Graph-Read-Check'=3000; 'Graph-Update-Check'=3450; 'Ignore-Rules-Check'=4300
    'Install-Location-Check'=11600; 'Large-File-Check'=4950; 'Mcp-Usage-Check'=5250
    'Rules-Check'=10700; 'Secrets-Check'=11000; 'Session-Summary-Check'=11100
    'Skills-Check'=36300; 'Speckit-Check'=4550; 'Synapse-Rules-Check'=3900
    'Test-Completion-Check'=58500; 'Test-Plan-Check'=10300; 'Test-Run-Guard'=23600
    'Test-Temp-Cleanup'=12000; 'Utf8-Encoding-Check'=15000
}
. (Join-Path $guidanceRoot '_hooklib.ps1')
$packages = @(Get-ChildItem -LiteralPath $guidanceRoot -Directory | Where-Object { $_.Name -notlike 'ZZZ-*' })
Check 'every shipped hook has a reviewed literal-text budget' (
    @($packages | Where-Object { -not $guidanceBudgets.ContainsKey($_.Name) }).Count -eq 0 -and
    @($guidanceBudgets.Keys | Where-Object { $_ -notin $packages.Name }).Count -eq 0)
foreach ($package in $packages) {
    $chars = 0; $parseCount = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $package.FullName -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        $parseCount += @($errors).Count
        foreach ($node in $ast.FindAll({param($n)
            $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)) { $chars += $node.Value.Length }
    }
    Check ('concise literal budget: ' + $package.Name) (
        $parseCount -eq 0 -and $guidanceBudgets.ContainsKey($package.Name) -and $chars -le $guidanceBudgets[$package.Name]) $chars
}
# Pure shared reminders: no provider call or additional subprocess required.
$research = Get-ResearchWorkflowReminder -Skills
Check 'research routing retains identity, native distinction and uncertainty within budget' (
    $research.Length -lt 900 -and $research -match 'provider/source/component kind/supported client' -and
    $research -match 'Native /deep-research differs' -and $research -match 'never simulated/substituted' -and
    $research -match 'partial is UNKNOWN' -and $research -match 'Hook executes nothing') $research
# Long dynamic facts must survive output unchanged, not merely fit authored budgets.
$longFact = ('scope-' + ('x' * 4096) + '-UNKNOWN')
foreach ($guidanceClient in @('claude', 'codex')) {
    $writer = New-Object IO.StringWriter
    $previous = [Console]::Out
    try {
        [Console]::SetOut($writer)
        $null = Write-HookResult -EventName 'Stop' -Kind 'advisory' -Message $longFact -Client $guidanceClient
    }
    finally { [Console]::SetOut($previous) }
    $wire = $writer.ToString() | ConvertFrom-Json
    Check ('passive output preserves complete dynamic facts and UNKNOWN: ' + $guidanceClient) (
        $wire.systemMessage -ceq $longFact -and $null -eq $wire.PSObject.Properties['decision'] -and
        $null -eq $wire.PSObject.Properties['hookSpecificOutput'])
}
