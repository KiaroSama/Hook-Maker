# Explicit expectations are input review, not saved execution results. Any changed
# workflow/source blob invalidates them before a successful run is considered.
function Test-CiReviewedTreeBinding {
    param([string]$ProjectRoot,[string]$Sha,$Policy)
    try{
        if($Policy.schema-ne3-or$Policy.PSObject.Properties['results']-or$Policy.objectFormat-cnotin@('sha1','sha256')){return $false}
        $length=if($Policy.objectFormat-ceq'sha1'){40}else{64}
        if($Sha-cnotmatch('^[a-f0-9]{'+$length+'}$')-or$Policy.tree-cnotmatch('^[a-f0-9]{'+$length+'}$')){return $false}
        $format=@(Invoke-DocsGit @('-C',$ProjectRoot,'rev-parse','--show-object-format=storage'))
        if($LASTEXITCODE-ne0-or$format.Count-ne1-or$format[0]-cne$Policy.objectFormat){return $false}
        $tree=@(Invoke-DocsGit @('-C',$ProjectRoot,'rev-parse','--verify','--end-of-options',($Sha+'^{tree}')))
        if($LASTEXITCODE-ne0-or$tree.Count-ne1-or$tree[0]-cne$Policy.tree){return $false}
        # A tree binds tracked bytes, not branch context or external inputs.
        # Require a review record for each dimension; text alone is not proof.
        foreach($dimension in @('conditions','checkout','scripts','envInputs','permissionsSecrets','artifactsCache','concurrency','dependencies')){
            $property=$Policy.contextReview.PSObject.Properties[$dimension]
            if($null-eq$property-or$property.Value-isnot[string]-or[string]::IsNullOrWhiteSpace($property.Value)-or$property.Value.Length-gt4096){return $false}
        }
        return $true
    }catch{return $false}
}
function Get-CiReviewedExpectation {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string]$Branch)
    $path='.hookmaker-ci-policy.json'
    $runtimeReview=Join-Path $PSScriptRoot '_ci-policy.json'
    if([IO.File]::Exists($runtimeReview)){
        $file=Get-Item -LiteralPath $runtimeReview -Force
        if(($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$file.Length-gt65536){return $null}
        $raw=[IO.File]::ReadAllText($runtimeReview,(New-Object Text.UTF8Encoding($false,$true)))
    }else{
        $raw=@(Invoke-DocsGit -Arguments @('-C',$ProjectRoot,'show',($Sha+':'+$path)))-join"`n"
        if($LASTEXITCODE-ne0){return $null}
    }
    if($raw.Length-gt65536){return $null}
    try {
        $policy=$raw|ConvertFrom-Json -ErrorAction Stop
        if($policy.schema-notin@(1,2,3)-or$policy.repository-ine$RepoSlug-or$policy.PSObject.Properties['results']-or
            [string]::IsNullOrWhiteSpace([string]$policy.rationale)){return $null}
        if($policy.schema-eq3-and(-not[IO.File]::Exists($runtimeReview)-or-not(Test-CiReviewedTreeBinding $ProjectRoot $Sha $policy))){return $null}
        $closure=@($policy.sources)
        if($closure.Count-eq0-or$closure.Count-gt100){return $null}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $sourceParts=New-Object Collections.Generic.List[string]
        foreach($source in $closure){
            if($source.path-isnot[string]-or$source.path-cnotmatch'^[A-Za-z0-9_. /-]+$'-or$source.path-match'(^|/)\.\.?(/|$)'-or
                $source.path.StartsWith('/')-or$source.blob-cnotmatch'^(?:[a-f0-9]{40}|[a-f0-9]{64})$'-or-not$seen.Add([string]$source.path)){return $null}
        }
        # Schema2 independently validates the COMPLETE inventory below. Selecting
        # its reviewed source blobs must not first enumerate an unrelated tree.
        $treeArgs=@('-C',$ProjectRoot,'ls-tree','-r',$Sha)
        if($policy.schema-in@(2,3)){$treeArgs+=@('--')+@($closure|ForEach-Object{':(literal)'+$_.path})}
        $sourceTree=@(Invoke-DocsGit -Arguments $treeArgs)
        if($LASTEXITCODE-ne0-or($sourceTree-join"`n").Length-gt1048576){return $null}
        $blobs=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        $modes=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach($row in $sourceTree){
            if($row-cnotmatch'^([0-7]{6}) blob ([a-f0-9]{40}|[a-f0-9]{64})\t(.+)$'){
                if($policy.schema-eq1){continue}
                return $null
            }
            $mode=$Matches[1];$blob=$Matches[2];$sourcePath=$Matches[3]
            if($blobs.ContainsKey($sourcePath)){return $null}
            $blobs.Add($sourcePath,$blob);$modes.Add($sourcePath,$mode)
        }
        if($policy.schema-in@(2,3)-and$blobs.Count-ne$closure.Count){return $null}
        foreach($source in $closure){
            if(-not$blobs.ContainsKey([string]$source.path)-or$blobs[[string]$source.path]-cne$source.blob){return $null}
            if($policy.schema-eq3-and($source.mode-cnotin@('100644','100755')-or$modes[[string]$source.path]-cne$source.mode)){return $null}
            $sourceParts.Add($source.path+'|'+$source.blob)
        }
        $workflowPaths=@(Invoke-DocsGit -Arguments @('-C',$ProjectRoot,'ls-tree','-r','--name-only',$Sha,'--','.github/workflows'))
        if($LASTEXITCODE-ne0-or$workflowPaths.Count-gt50){return $null}
        foreach($workflowPath in $workflowPaths){if(-not$seen.Contains([string]$workflowPath)){return $null}}
        if($policy.schema-eq2){
            if(-not(Get-Command Test-CiReviewedClosure -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot '_ciclosure.ps1')}
            $closure=$policy.closure
            $inputs=@($closure.candidates|ForEach-Object{[pscustomobject]@{Path=$_.path;Bytes=$_.bytes}})
            if(-not(Test-CiReviewedClosure $ProjectRoot $RepoSlug $Sha $closure @($closure.documents) $inputs $Branch)){return $null}
        }elseif($policy.schema-eq1){
            if($policy.treeFingerprint-cnotmatch'^[a-f0-9]{64}$'){return $null}
            $bound=@($sourceTree|Where-Object{$_-cnotmatch"`t\.hookmaker-ci-policy\.json$"})-join"`n"
            if((Get-RepositoryIdentityHash $bound)-cne$policy.treeFingerprint){return $null}
        }
        $workflows=@($policy.workflows)
        if($workflows.Count-eq0-or$workflows.Count-gt50){return $null}
        $keys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($workflow in $workflows){
            if(-not$seen.Contains([string]$workflow.path)-or$workflow.path-cnotmatch'^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$'-or
                [string]$workflow.id-cnotmatch'^[1-9][0-9]*$'-or$workflow.event-cnotin@('workflow_dispatch','push','pull_request')-or
                -not$keys.Add([string]$workflow.path+'|'+$workflow.event)){return $null}
            if($policy.schema-eq2-and(@($policy.closure.sourceBranches)-cnotcontains$workflow.branch-or@($policy.closure.destinationBranches)-cnotcontains$Branch)){return $null}
            if($workflow.branch-cne$Branch){
                if($workflow.branchEquivalent-isnot[bool]-or-not$workflow.branchEquivalent-or
                    [string]::IsNullOrWhiteSpace([string]$workflow.branchRationale)-or
                    @($workflow.equivalentTo|Where-Object{$_-is[string]-and$_-ceq$Branch}).Count-ne1){return $null}
            }
            $jobs=@($workflow.jobs)
            if($jobs.Count-eq0-or$jobs.Count-gt100){return $null}
            $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $requiredCount=0
            foreach($job in $jobs){
                if($job.name-isnot[string]-or[string]::IsNullOrWhiteSpace($job.name)-or-not$names.Add($job.name)){return $null}
                # Inapplicability is reviewed source input, not an observed-success
                # allowlist. Missing/null steps must not masquerade as an empty array.
                $disposition=$job.PSObject.Properties['disposition']
                if($null-ne$disposition){
                    if($disposition.Value-isnot[string]-or$disposition.Value-cne'skipped'-or$job.rationale-isnot[string]-or
                        [string]::IsNullOrWhiteSpace($job.rationale)-or$job.rationale.Length-gt4096-or
                        $job.steps-isnot[Array]-or$job.steps.Count-ne0){return $null}
                    continue
                }
                if(@($job.steps).Count-eq0-or@($job.steps).Count-gt100){return $null}
                $stepNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                foreach($step in @($job.steps)){if($step-isnot[string]-or[string]::IsNullOrWhiteSpace($step)-or-not$stepNames.Add($step)){return $null}}
                $requiredCount++
            }
            if($requiredCount-eq0){return $null}
        }
        [string[]]$ordered=$sourceParts.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
        return [pscustomobject]@{SourceFingerprint=Get-RepositoryIdentityHash (($ordered-join"`n")+'|'+$raw);Workflows=$workflows}
    }catch{return $null}
}
