# Complete synthetic inventory; no real target policy or success record.
function Invoke-CiClosureRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciclosure.ps1')
    $base='a'*40;$ancestor='b'*40;$final='c'*40;$tree='d'*40;$blob='e'*40;$doc='f'*40
    $policy=[ordered]@{schema=2;repository='owner/repo';verdict='non-semantic';rationale='Synthetic reviewed operation closure';baseline=@{sha=$base;tree=$tree};ancestor=@{sha=$ancestor;tree=$tree};sourceBranches=@('native');destinationBranches=@('main');documents=@('reports/VALIDATION.md');inventory=@{count=1;sha256=Get-RepositoryIdentityHash ('100644|'+$blob+'|42|scripts/output.py')};candidates=@(@{path='scripts/output.py';blob=$blob;bytes=42;role='output-only';rationale='Write-only synthetic operation'})}
    function Invoke-DocsGit {param($Arguments);$global:LASTEXITCODE=0;return $tree}
    function Invoke-DocsGitQuery {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){
            if($script:ClosureCase-eq'include'){return '{{include report}}'}
            return 'Later ordinary prose'
        }
        $mode=if($script:ClosureCase-eq'mode'){'100755'}else{'100644'}
        $currentBlob=if($script:ClosureCase-eq'changed'){'0'*40}else{$blob}
        if($script:ClosureCase-ne'deleted'){"$mode blob $currentBlob 42`tscripts/output.py"}
        if($script:ClosureCase-eq'new'){"100644 blob $blob 1`tnew-reader.py"}
        "100644 blob $doc 21`treports/VALIDATION.md"
    }
    foreach($case in @('prose','changed','new','deleted','mode','include','wrong-branch','wrong-count','missing-candidate','wrong-role','results')){
        $script:ClosureCase=$case
        $copy=$policy|ConvertTo-Json -Depth 10|ConvertFrom-Json
        $branch=if($case-eq'wrong-branch'){'other'}else{'main'}
        if($case-eq'wrong-count'){$copy.inventory.count=2}
        if($case-eq'missing-candidate'){$copy.candidates=@()}
        if($case-eq'wrong-role'){$copy.candidates[0].role='semantic-read'}
        if($case-eq'results'){$copy|Add-Member results success}
        $ok=Test-CiReviewedClosure fixture owner/repo $final $copy @('reports/VALIDATION.md') @([pscustomobject]@{Path='scripts/output.py';Bytes=42}) $branch $ancestor
        Check ('reviewed invariance '+$case) ($ok-eq($case-eq'prose'))
    }
    $script:DocsReviewedClosure=$policy|ConvertTo-Json -Depth 10|ConvertFrom-Json
    $script:DocsAncestorSnapshot=[pscustomobject]@{Provenance=[pscustomobject]@{runs=@([pscustomobject]@{branch='main'})}}
    Check 'reviewed docs source branch constrains actual ancestor workload' (-not(Test-DocsReviewedAncestorBinding fixture owner/repo $final $ancestor main))
    $script:DocsAncestorSnapshot.Provenance.runs[0].branch='native'
    Check 'reviewed docs accepts only explicit source and destination branches' (Test-DocsReviewedAncestorBinding fixture owner/repo $final $ancestor main)
}
