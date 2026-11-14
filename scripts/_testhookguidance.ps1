# R035 immutable 28be7d1 output-construction baseline: 289 groups / 132315 chars.
# Each full authored message preserves facts and actions; no truncation/token claim.
$guidanceRoot=Join-Path (Split-Path -Parent $PSScriptRoot) hooks
. (Join-Path $PSScriptRoot _guidanceinventory.ps1)
$guidanceBudgets=@{
    '_hooklib.ps1'=316
    '_manualworkflow.ps1'=135
    '_replylanguage.ps1'=130
    '_scope.ps1'=2927
    '_stoplib.ps1'=280
    'Ai-Memory-Check'=853
    'Ai-Memory-Load'=723
    'Cbm-Read-Check'=1482
    'Cbm-Update-Check'=295
    'Ci-Status-Check'=3912
    'Cloudflare-Deploy'=1475
    'Cross-Project-.ai-Knowledge-Sync'=1165
    'Dependabot-Check'=728
    'Dependency-Version-Check'=2990
    'Docs-Freshness-Check'=1079
    'Feature-Request-Check'=908
    'Git-Sync-Check'=3103
    'Github-Baseline-Check'=2323
    'Graph-Read-Check'=1288
    'Graph-Update-Check'=1140
    'Ignore-Rules-Check'=408
    'Install-Location-Check'=720
    'Large-File-Check'=1285
    'Mcp-Usage-Check'=1470
    'Rules-Check'=3551
    'Secrets-Check'=1111
    'Session-Summary-Check'=1646
    'Skills-Check'=6662
    'Speckit-Check'=1433
    'Synapse-Rules-Check'=1546
    'Test-Completion-Check'=7691
    'Test-Plan-Check'=3168
    'Test-Run-Guard'=4222
    'Test-Temp-Cleanup'=1499
    'Utf8-Encoding-Check'=2563
}
$guidanceInventory=@(Get-HookGuidanceInventory $guidanceRoot)
$authoredCharacters=($guidanceInventory|Measure-Object Characters -Sum).Sum
Check '035 authored guidance <=66157 of baseline132315' ($authoredCharacters-le66157) $authoredCharacters
$packages=@(Get-ChildItem $guidanceRoot -Directory|Where-Object{$_.Name-notlike'ZZZ-*'})
foreach($package in $packages){Check ('035 guidance covers '+$package.Name) (@($guidanceInventory|Where-Object{$_.Path.StartsWith($package.Name+'/',[StringComparison]::Ordinal)}).Count-gt0)}
foreach($name in $guidanceBudgets.Keys){
    $groups=@($guidanceInventory|Where-Object{($_.Path-split'/')[0]-ceq$name})
    $characters=($groups|Measure-Object Characters -Sum).Sum
    Check ('035 per-package half baseline: '+$name) ($null-ne$characters-and$characters-le$guidanceBudgets[$name]) $characters
}
. (Join-Path $guidanceRoot _hooklib.ps1)
# Pure adapter callers preserve complete dynamic facts, independent of authored caps.
$longFact='scope-'+('x'*4096)+'-UNKNOWN'
foreach($client in @('claude','codex')){
    $capture=New-Object IO.StringWriter;$previous=[Console]::Out
    try{[Console]::SetOut($capture);$null=Write-HookResult -EventName Stop -Kind advisory -Message $longFact -Client $client}finally{[Console]::SetOut($previous)}
    $wire=$capture.ToString()|ConvertFrom-Json
    Check ('035 dynamic facts untruncated '+$client) ($wire.systemMessage-ceq$longFact-and$null-eq$wire.PSObject.Properties['decision'])
}