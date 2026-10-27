# Complete reviewed identities exercise the real validator; only Git is external.
param([switch]$RunRegression)
function Invoke-DocsClosureExtendedRegression {
    param([string]$HooksRoot,[switch]$SmokeOnly,[switch]$PagedOnly)
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
        $resultRows=$rows
        if($script:ExtendedCase-in@('page-byte-max','page-byte-over')){$resultRows=@($rows|ForEach-Object{if($_-ceq"100644 blob $blob 42`tscripts/reader-0.py"){"100644 blob $blob $script:ExtendedFirstBytes`tscripts/reader-0.py"}else{$_}})}
        $docBlob=if($script:ExtendedCase-eq'unknown-document'-and$Arguments[-1]-ceq$final){'0'*40}else{$blob}
        return $resultRows+"100644 blob $docBlob 20`t$document"
    }
    $pageCases=@('paged','page-mixed','page-empty','page-count','page-entry-count','page-duplicate','page-missing','page-extra','page-blob','page-role','page-before','page-after','page-pair-missing','page-pair-duplicate','page-repo','page-branch','page-legacy','page-results','page-byte-max','page-byte-over','page-byte-negative','page-byte-string','page-sixteen','page-snippet','page-unknown-document','page-tree')
    $cases=if($PagedOnly){@('paged')}elseif($SmokeOnly){@('complete')}else{@('complete','omitted','extra','duplicate','blob','bytes','role','transitive','mode','snippet','blank','block-context','inline','include','ambiguous','contract','branch','legacy','limit','size','results','contracts-duplicate')+$pageCases}
    foreach($case in $cases){
        $script:ExtendedCase=$case
        $copy=$policy|ConvertTo-Json -Depth 12|ConvertFrom-Json
        $actual=$inputs
        if($case-in$pageCases){
            $copy|Add-Member candidatePages @([pscustomobject]@{candidates=@($copy.candidates|Select-Object -First 100)},[pscustomobject]@{candidates=@($copy.candidates|Select-Object -Skip 100)})
            $copy.PSObject.Properties.Remove('candidates')
            $copy.documentContracts[0]|Add-Member beforeBlob $blob
            $copy.documentContracts[0]|Add-Member afterBlob $blob
        }
        if($case-in@('page-byte-max','page-byte-over')){
            $firstBytes=if($case-eq'page-byte-max'){1044418}else{1044419}
            $copy.candidatePages[0].candidates[0].bytes=$firstBytes
            $script:ExtendedFirstBytes=$firstBytes
            [string[]]$sized=@($parts|ForEach-Object{if($_-ceq"100644|$blob|42|scripts/reader-0.py"){"100644|$blob|$firstBytes|scripts/reader-0.py"}else{$_}})
            [Array]::Sort($sized,[StringComparer]::Ordinal)
            $copy.inventory.sha256=Get-RepositoryIdentityHash ($sized-join"`n")
        }
        switch($case){
            page-mixed {$copy|Add-Member candidates @()}
            page-empty {$copy.candidatePages=@()}
            page-count {$copy.candidatePages=@($copy.candidatePages[0])*17}
            page-entry-count {$copy.candidatePages[0].candidates+=@($copy.candidatePages[1].candidates[0]);$copy.candidatePages[1].candidates=@($copy.candidatePages[1].candidates|Select-Object -Skip 1)}
            page-duplicate {$copy.candidatePages[1].candidates[0].path=$copy.candidatePages[0].candidates[0].path}
            page-missing {$copy.candidatePages[1].candidates=@($copy.candidatePages[1].candidates|Select-Object -Skip 1)}
            page-extra {$actual=$inputs+@([pscustomobject]@{Path='extra.py'})}
            page-blob {$copy.candidatePages[0].candidates[0].blob='0'*40}
            page-role {$copy.candidatePages[0].candidates[0].role='semantic-read'}
            page-before {$copy.documentContracts[0].beforeBlob='0'*40}
            page-after {$copy.documentContracts[0].afterBlob='0'*40}
            page-pair-missing {$copy.documentContracts[0].PSObject.Properties.Remove('afterBlob')}
            page-pair-duplicate {$copy.documentContracts+=@($copy.documentContracts[0])}
            page-repo {$copy.repository='other/repo'}
            page-branch {$copy.destinationBranches=@('other')}
            page-legacy {$copy.schema=2}
            page-results {$copy|Add-Member results success}
            page-byte-negative {$copy.candidatePages[0].candidates[0].bytes=-1}
            page-byte-string {$copy.candidatePages[0].candidates[0].bytes='42'}
            page-sixteen {$copy.candidatePages=@(0..15|ForEach-Object{[pscustomobject]@{candidates=@($reviews|Select-Object -Skip ($_*10) -First 10)}})}
            page-snippet {$script:ExtendedCase='snippet'}
            page-unknown-document {$script:ExtendedCase='unknown-document'}
            page-tree {$copy.inventory.sha256='0'*64}
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
        Check ('complete reviewed docs '+$case) ($ok-eq($case-in@('complete','paged','page-byte-max','page-sixteen')))
    }
}
if($RunRegression){
    Set-StrictMode -Version 2.0
    $ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0
    $hooks=Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
    Invoke-DocsClosureExtendedRegression $hooks
    & {param($Root,$Helper);. $Helper;Invoke-CiQueryRegression $Root} $hooks (Join-Path $PSScriptRoot '_testciquery.ps1')
    Write-Output "Passed: $script:Pass Failed: $script:Fail"
    exit $script:Fail
}
