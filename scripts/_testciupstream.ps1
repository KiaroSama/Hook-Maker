# Current upstream mapping is mutable; use exact read-only external seam fixtures.
function Invoke-CiUpstreamRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciupstream.ps1')
    $sha='a'*40
    function Invoke-DocsGit {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'for-each-ref'){
            if($script:UpstreamCase-eq'missing'){return @()}
            if($script:UpstreamCase-eq'wrong-destination'){return "main|origin|refs/heads/other|origin/other|$sha"}
            if($script:UpstreamCase-eq'wrong-sha'){return ('main|origin|refs/heads/main|origin/main|'+('b'*40))}
            return "main|origin|refs/heads/main|origin/main|$sha"
        }
        if($script:UpstreamCase-eq'wrong-repo'){return 'https://github.com/other/repo.git'}
        return 'https://github.com/owner/repo.git'
    }
    foreach($case in @('exact','missing','wrong-destination','wrong-sha','wrong-repo')){
        $script:UpstreamCase=$case
        $destination=Get-CiCarryoverDestination fixture owner/repo $sha main
        Check ('carryover upstream '+$case) (($destination-ceq'main')-eq($case-eq'exact'))
    }
}
