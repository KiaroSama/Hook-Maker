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
    Initialize-DocsEvidenceCache -ScopeKey 'empty-lines'
    $queryArgs=@('-C','fixture','show',($sha+':README.md'))
    $key=Get-DocsImmutableQueryKey $queryArgs
    $script:DocsEvidenceCache[$key]=@('plain')
    $script:DocsEvidenceCache[$key+'|preserve-empty']=@('code','','end')
    $raw=@(Invoke-DocsGitQuery $queryArgs -PreserveEmptyLines)
    $plain=@(Invoke-DocsGitQuery $queryArgs)
    Check 'protected snippet cache retains empty lines separately from legacy text' ($raw.Count-eq3-and$raw[1]-ceq''-and$plain.Count-eq1-and$plain[0]-ceq'plain')
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciclosure.ps1')
    $script:InventoryReads=0;$script:InventoryFail=$false
    function Get-RepositoryPhysicalRoot {param($Path);[IO.Path]::GetFullPath($Path)}
    function Invoke-DocsGitQuery {
        param($Arguments)
        $script:InventoryReads++
        $global:LASTEXITCODE=if($script:InventoryFail){1}else{0}
        return @("100644 blob $('b'*40) 12`treader.ps1","100644 blob $('c'*40) 10`tREADME.md")
    }
    Initialize-DocsEvidenceCache 'parsed-inventory'
    $policy=[pscustomobject]@{schema=3;rationale='Reviewed immutable source'}
    $one=Get-CiClosureInventory $HooksRoot $sha @('README.md') $policy
    $two=Get-CiClosureInventory $HooksRoot $sha @('README.md') $policy
    Check 'validated immutable inventory parses once per invocation' ($script:InventoryReads-eq1-and$null-ne$one-and[object]::ReferenceEquals($one,$two))
    $policy.rationale='Changed review'
    $null=Get-CiClosureInventory $HooksRoot $sha @('README.md') $policy
    Check 'changed review invalidates parsed inventory' ($script:InventoryReads-eq2)
    $null=Get-CiClosureInventory $PSScriptRoot $sha @('README.md') $policy
    Check 'different root cannot reuse parsed inventory' ($script:InventoryReads-eq3)
    $null=Get-CiClosureInventory $HooksRoot ('d'*40) @('README.md') $policy
    Check 'different object cannot reuse parsed inventory' ($script:InventoryReads-eq4)
    $null=Get-CiClosureInventory $HooksRoot $sha @('OTHER.md') $policy
    Check 'different documents cannot reuse parsed inventory' ($script:InventoryReads-eq5)
    Initialize-DocsEvidenceCache 'parsed-inventory'
    $null=Get-CiClosureInventory $HooksRoot $sha @('README.md') $policy
    Check 'new invocation reparses immutable inventory' ($script:InventoryReads-eq6)
    Initialize-DocsEvidenceCache 'failed-inventory';$script:InventoryFail=$true
    $bad1=Get-CiClosureInventory $HooksRoot $sha @('README.md') $policy
    $bad2=Get-CiClosureInventory $HooksRoot $sha @('README.md') $policy
    Check 'failed inventory is never memoized' ($script:InventoryReads-eq8-and$null-eq$bad1-and$null-eq$bad2)
}
