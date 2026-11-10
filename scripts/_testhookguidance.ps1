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
. (Join-Path $guidanceRoot '_scope.ps1')
$packages = @(Get-ChildItem -LiteralPath $guidanceRoot -Directory | Where-Object { $_.Name -notlike 'ZZZ-*' })
Check 'every shipped hook has a reviewed literal-text budget' (
    @($packages | Where-Object { -not $guidanceBudgets.ContainsKey($_.Name) }).Count -eq 0 -and
    @($guidanceBudgets.Keys | Where-Object { $_ -notin $packages.Name }).Count -eq 0)
foreach ($package in $packages) {
    $chars = 0; $parseCount = 0
    # The acknowledgment feature was added after these package ceilings. Keep
    # its implementation budget separate rather than charging new schema/API
    # names as growth of the old reminder. Its prose STILL counts below in the
    # unchanged fixed authored inventory, and its behavior has dedicated tests.
    $acknowledgmentChars = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $package.FullName -Filter '*.ps1' -File -Recurse)) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        $parseCount += @($errors).Count
        foreach ($node in $ast.FindAll({param($n)
            $n -is [Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)) {
            if ($package.Name -ceq 'Cloudflare-Deploy' -and $file.Name -ceq '_acknowledgment.ps1') { $acknowledgmentChars += $node.Value.Length }
            else { $chars += $node.Value.Length }
        }
    }
    if ($package.Name -ceq 'Cloudflare-Deploy') {
        Check 'acknowledgment implementation has its own bounded literal budget' ($acknowledgmentChars -gt 0 -and $acknowledgmentChars -le 4600) $acknowledgmentChars
    }
    Check ('concise literal budget: ' + $package.Name) (
        $parseCount -eq 0 -and $guidanceBudgets.ContainsKey($package.Name) -and $chars -le $guidanceBudgets[$package.Name]) $chars
}
# Immutable 0ab5b09b409cc0355df620f1cb98d180701886e6 output-construction
# baseline: 291 groups / 116720 characters. No length threshold, subtraction of
# changing non-prose text, tokenizer claim or truncation. This is source text;
# semantic assertions and real event contracts remain separately required.
. (Join-Path $PSScriptRoot '_guidanceinventory.ps1')
$guidanceInventory = @(Get-HookGuidanceInventory -HooksRoot $guidanceRoot)
$authoredCharacters = ($guidanceInventory | Measure-Object Characters -Sum).Sum
Check 'fixed output-construction inventory stays below half baseline' (
    $authoredCharacters * 2 -le 116720) ($authoredCharacters.ToString() + ' / 116720')
foreach ($package in $packages) {
    Check ('fixed inventory covers package: ' + $package.Name) (
        @($guidanceInventory | Where-Object { $_.Path.StartsWith($package.Name + '/', [StringComparison]::Ordinal) }).Count -gt 0)
}
# Pure shared reminders: no provider call or additional subprocess required.
$research = Get-ResearchWorkflowReminder -Skills
# Provider/kind/client/exposure/resources/typed-only now route through the exact
# catalogue job and FULL owners before selection; native/unknown/authority stay inline.
Check 'research routing requires complete owners before selection and preserves native/unknown boundary' (
    $research.Length -lt 900 -and $research -match 'BEFORE selection' -and
    $research -match 'global-research-workflows.md/global-connected-skill-contracts.md/exact catalogue job FULL' -and
    $research -match 'Native /deep-research distinct' -and $research -match 'partial UNKNOWN' -and
    $research -match 'no simulation/action/spend') $research
# Immutable baseline function outputs at 0ab5b09: Skills=809, workflow=793.
# Exercise the real adapters, not JSON length (escaping differs by client).
foreach ($sample in @(@{Skills=$true; Baseline=809}, @{Skills=$false; Baseline=793})) {
    $reminder = Get-ResearchWorkflowReminder -Skills:$sample.Skills
    foreach ($sampleClient in @('claude','codex')) {
        $capture = New-Object IO.StringWriter
        $savedOutput = [Console]::Out
        try {
            [Console]::SetOut($capture)
            $null = Write-HookResult -EventName 'UserPromptSubmit' -Kind 'context' -Message $reminder -Client $sampleClient
        }
        finally { [Console]::SetOut($savedOutput) }
        $emitted = $capture.ToString() | ConvertFrom-Json
        Check ('representative emitted reminder <=half baseline: ' + $sampleClient + '/skills=' + $sample.Skills) (
            $emitted.hookSpecificOutput.additionalContext -ceq $reminder -and
            $emitted.hookSpecificOutput.hookEventName -ceq 'UserPromptSubmit' -and
            $reminder.Length * 2 -le $sample.Baseline -and
            $null -eq $emitted.PSObject.Properties['decision'] -and
            $null -eq $emitted.PSObject.Properties['systemMessage']) ($reminder.Length.ToString() + ' / ' + $sample.Baseline)
    }
}
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
