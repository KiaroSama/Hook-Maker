# Complete reviewed identities exercise the real validator; only Git is external.
function Invoke-DocsClosureExtendedRegression {
    param([string]$HooksRoot,[switch]$SmokeOnly)
    . (Join-Path $HooksRoot '_hooklib.ps1')
    . (Join-Path $HooksRoot 'Ci-Status-Check/_ciclosure.ps1')
    $base='a'*40;$ancestor='b'*40;$final='c'*40;$tree='d'*40;$blob='e'*40
    $document='reports/VALIDATION.md'
    $code=@('```powershell','Write-Output 42','```','Use `pwsh` for this example.')
    $rows=@(0..154|ForEach-Object{"100644 blob $blob 42`tscripts/reader-$_.py"})
    [string[]]$parts=@(0..154|ForEach-Object{"100644|$blob|42|scripts/reader-$_.py"})
    [Array]::Sort($parts,[StringComparer]::Ordinal)
    $reviews=@(0..154|ForEach-Object{@{path="scripts/reader-$_.py";blob=$blob;bytes=42;role='output-only';rationale='Reviewed fixed output, no document input'}})
    # Literal projection is independent of the implementation under test.
    $projection=@('fence:```powershell','code:Write-Output 42','fence:```','inline:Use `pwsh` for this example.')-join"`n"
    $policy=[ordered]@{schema=3;repository='owner/repo';verdict='non-semantic';rationale='Synthetic complete reader closure';baseline=@{sha=$base;tree=$tree};ancestor=@{sha=$ancestor;tree=$tree};sourceBranches=@('native');destinationBranches=@('main');documents=@($document);documentContracts=@(@{path=$document;sha256=Get-RepositoryIdentityHash $projection});inventory=@{count=155;sha256=Get-RepositoryIdentityHash ($parts-join"`n")};candidates=$reviews}
    $inputs=@($reviews|ForEach-Object{[pscustomobject]@{Path=$_.path}})
    function Invoke-DocsGit {param($Arguments);$global:LASTEXITCODE=0;return $tree}
    function Invoke-DocsGitQuery {
        param($Arguments,[switch]$PreserveEmptyLines)
        $global:LASTEXITCODE=0
        if($Arguments-contains'show'){
            $object=([string]$Arguments[-1]).Split(':')[0]
            if($script:ExtendedCase-eq'ambiguous'){return @('~~~python','print(42)')}
            if($script:ExtendedCase-eq'include'){return '{{include report}}'}
            if($script:ExtendedCase-eq'snippet'-and$object-ceq$final){return @('```powershell','Write-Output 43','```')}
            if($script:ExtendedCase-eq'blank'-and$object-ceq$final){return @('```powershell','Write-Output 42','','```','Use `pwsh` for this example.')}
            if($script:ExtendedCase-eq'inline'-and$object-ceq$final){return @('```powershell','Write-Output 42','```','Use `bash` for this example.')}
            if($script:ExtendedCase-eq'block-context'-and$object-ceq$final){return @(('Ordinary prose '+$object),'')+$code}
            return @('Ordinary prose '+$object)+$code
        }
        if($script:ExtendedCase-eq'transitive'){return $rows+@("100644 blob $blob 3`tother/input.py","100644 blob $blob 20`t$document")}
        if($script:ExtendedCase-eq'mode'){return @($rows|ForEach-Object{$_-replace'^100644','100755'})+"100644 blob $blob 20`t$document"}
        return $rows+"100644 blob $blob 20`t$document"
    }
    $cases=if($SmokeOnly){@('complete')}else{@('complete','omitted','extra','duplicate','blob','bytes','role','transitive','mode','snippet','blank','block-context','inline','include','ambiguous','contract','branch','legacy','limit','size','results','contracts-duplicate')}
    foreach($case in $cases){
        $script:ExtendedCase=$case
        $copy=$policy|ConvertTo-Json -Depth 12|ConvertFrom-Json
        $actual=$inputs
        switch($case){
            omitted {$copy.candidates=@($copy.candidates|Select-Object -Skip 1)}
            extra {$actual=$inputs+@([pscustomobject]@{Path='extra.py'})}
            duplicate {$copy.candidates[1].path=$copy.candidates[0].path}
            blob {$copy.candidates[0].blob='0'*40}
            bytes {$copy.candidates[0].bytes=43}
            role {$copy.candidates[0].role='semantic-read'}
            contract {$copy.documentContracts[0].sha256='0'*64}
            branch {$copy.destinationBranches=@('other')}
            legacy {$copy.schema=2}
            limit {$copy.candidates=@($copy.candidates)*2;$actual=@($inputs)*2}
            size {$copy.candidates[0].bytes=16777217}
            results {$copy|Add-Member results success}
            contracts-duplicate {$copy.documentContracts+=@($copy.documentContracts[0])}
        }
        $ok=Test-CiReviewedClosure fixture owner/repo $final $copy @($document) $actual main $ancestor
        Check ('complete reviewed docs '+$case) ($ok-eq($case-eq'complete'))
    }
}
