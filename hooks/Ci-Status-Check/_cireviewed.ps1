# Explicit expectations are input review, not saved execution results. Any changed
# workflow/source blob invalidates them before a successful run is considered.
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
        if($policy.schema-notin@(1,2)-or$policy.repository-ine$RepoSlug-or$policy.PSObject.Properties['results']-or
            [string]::IsNullOrWhiteSpace([string]$policy.rationale)){return $null}
        $closure=@($policy.sources)
        if($closure.Count-eq0-or$closure.Count-gt100){return $null}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $sourceParts=New-Object Collections.Generic.List[string]
        $sourceTree=@(Invoke-DocsGit -Arguments @('-C',$ProjectRoot,'ls-tree','-r',$Sha))
        if($LASTEXITCODE-ne0-or($sourceTree-join"`n").Length-gt1048576){return $null}
        $blobs=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach($row in $sourceTree){if($row-cmatch'^[0-7]{6} blob ([a-f0-9]{40}|[a-f0-9]{64})\t(.+)$'){$blobs[$Matches[2]]=$Matches[1]}}
        foreach($source in $closure){
            if($source.path-cnotmatch'^[A-Za-z0-9_. /-]+$'-or$source.path-match'(^|/)\.\.(/|$)'-or
                $source.path.StartsWith('/')-or$source.blob-cnotmatch'^(?:[a-f0-9]{40}|[a-f0-9]{64})$'-or-not$seen.Add([string]$source.path)){return $null}
            if(-not$blobs.ContainsKey([string]$source.path)){return $null}
            $actual=$blobs[[string]$source.path]
            if($actual-cne$source.blob){return $null}
            $sourceParts.Add($source.path+'|'+$actual)
        }
        $workflowPaths=@(Invoke-DocsGit -Arguments @('-C',$ProjectRoot,'ls-tree','-r','--name-only',$Sha,'--','.github/workflows'))
        if($LASTEXITCODE-ne0-or$workflowPaths.Count-gt50){return $null}
        foreach($workflowPath in $workflowPaths){if(-not$seen.Contains([string]$workflowPath)){return $null}}
        if($policy.schema-eq2){
            if(-not(Get-Command Test-CiReviewedClosure -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot '_ciclosure.ps1')}
            $closure=$policy.closure
            $inputs=@($closure.candidates|ForEach-Object{[pscustomobject]@{Path=$_.path;Bytes=$_.bytes}})
            if(-not(Test-CiReviewedClosure $ProjectRoot $RepoSlug $Sha $closure @($closure.documents) $inputs $Branch)){return $null}
        }else{
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
            foreach($job in $jobs){
                if([string]::IsNullOrWhiteSpace([string]$job.name)-or-not$names.Add([string]$job.name)-or@($job.steps).Count-eq0-or@($job.steps).Count-gt100){return $null}
                foreach($step in @($job.steps)){if($step-isnot[string]-or[string]::IsNullOrWhiteSpace($step)){return $null}}
            }
        }
        [string[]]$ordered=$sourceParts.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
        return [pscustomobject]@{SourceFingerprint=Get-RepositoryIdentityHash (($ordered-join"`n")+'|'+$raw);Workflows=$workflows}
    }catch{return $null}
}
