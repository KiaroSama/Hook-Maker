# One invocation cache seam: immutable object reads only; never identity or approval.
function Invoke-CiQueryRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot 'Ci-Status-Check/_docsquery.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_docsancestor.ps1')
    $script:QueryChildren=0
    function Get-GhRemainingSeconds { return 30 }
    function Invoke-QuietCommand {
        param($FilePath,$ArgumentList,$TimeoutSeconds)
        $script:QueryChildren++;$global:LASTEXITCODE=0
        return 'object content'
    }
    $sha='a'*40
    $init=Get-Command Initialize-DocsEvidenceCache -ErrorAction SilentlyContinue
    if($init){Initialize-DocsEvidenceCache -ScopeKey 'fixture|owner/repo|sha|policy'}
    $null=Invoke-DocsGit @('-C','fixture','show',($sha+':README.md'))
    $null=Invoke-DocsGit @('-C','fixture','show',($sha+':README.md'))
    Check 'immutable object read launches one Git child per invocation' ($script:QueryChildren-eq1)
    $before=$script:QueryChildren
    $null=Invoke-DocsGit @('-C','fixture','rev-parse','HEAD')
    $null=Invoke-DocsGit @('-C','fixture','rev-parse','HEAD')
    Check 'mutable HEAD is never memoized' (($script:QueryChildren-$before)-eq2)
    if($init){Initialize-DocsEvidenceCache -ScopeKey 'fixture|owner/repo|sha|policy'}
    $before=$script:QueryChildren
    $null=Invoke-DocsGit @('-C','fixture','show',($sha+':README.md'))
    Check 'new invocation discards immutable discovery cache' (($script:QueryChildren-$before)-eq1)
    Initialize-DocsEvidenceCache -ScopeKey 'failed-query'
    function Invoke-QuietCommand {param($FilePath,$ArgumentList,$TimeoutSeconds);$script:QueryChildren++;$global:LASTEXITCODE=1;return @()}
    $before=$script:QueryChildren
    $null=Invoke-DocsGit @('-C','fixture','show',($sha+':README.md'))
    $null=Invoke-DocsGit @('-C','fixture','show',($sha+':README.md'))
    Check 'failed immutable discovery is never memoized' (($script:QueryChildren-$before)-eq2)
}
