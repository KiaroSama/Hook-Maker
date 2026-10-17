# Exact review contract validation only; synthetic roles never certify real source.
function Invoke-DocsReviewedRegression {
    param([string]$HooksRoot)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_docsreviewed.ps1')
    $sha='a'*40;$blob='b'*40;$docBlob='c'*40
    $tree=@("100644 blob $blob`tscripts/output.py","100644 blob $docBlob`treports/VALIDATION.md")
    $policy=[ordered]@{schema=1;repository='owner/repo';verdict='non-semantic';rationale='Synthetic complete closure only';treeFingerprint=Get-RepositoryIdentityHash ($tree-join"`n");documents=@(@{path='reports/VALIDATION.md';blob=$docBlob});candidates=@(@{path='scripts/output.py';blob=$blob;bytes=42;role='output-only';rationale='Synthetic write-only output operation'})}
    function Invoke-DocsGitQuery {
        param($Arguments)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){return $script:InputPolicyJson}
        return $tree
    }
    foreach($case in @('exact','wrong-repo','wrong-tree','wrong-document','wrong-blob','missing-candidate','wrong-bytes','semantic-role','empty-rationale','results')){
        $copy=($policy|ConvertTo-Json -Depth 8)|ConvertFrom-Json
        switch($case){
            'wrong-repo'{$copy.repository='other/repo'}
            'wrong-tree'{$copy.treeFingerprint='d'*64}
            'wrong-document'{$copy.documents[0].blob='d'*40}
            'wrong-blob'{$copy.candidates[0].blob='d'*40}
            'missing-candidate'{$copy.candidates=@()}
            'wrong-bytes'{$copy.candidates[0].bytes=41}
            'semantic-role'{$copy.candidates[0].role='semantic-read'}
            'empty-rationale'{$copy.candidates[0].rationale=''}
            'results'{$copy|Add-Member results 'success'}
        }
        $script:InputPolicyJson=$copy|ConvertTo-Json -Depth 8 -Compress
        $safe=Test-DocsReviewedInputScope -ProjectRoot fixture -RepoSlug owner/repo -Sha $sha -Files @('reports/VALIDATION.md') -Candidates @([pscustomobject]@{Path='scripts/output.py';Bytes=42})
        Check ('reviewed input closure '+$case) ($safe-eq($case-eq'exact'))
    }
}
