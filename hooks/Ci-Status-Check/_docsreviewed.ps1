# Exact reviewed input closure, never a CI result or a filename-based waiver.
function Test-DocsReviewedInputScope {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string[]]$Files,[object[]]$Candidates)
    if([string]::IsNullOrWhiteSpace($RepoSlug)){return $false}
    $path='.hookmaker-docs-policy.json'
    $raw=@(Invoke-DocsGitQuery @('-C',$ProjectRoot,'show',($Sha+':'+$path)))-join"`n"
    if($LASTEXITCODE-ne0-or[Text.Encoding]::UTF8.GetByteCount($raw)-gt65536){return $false}
    try {
        $policy=$raw|ConvertFrom-Json -ErrorAction Stop
        if($policy.schema-ne1-or$policy.repository-ine$RepoSlug-or$policy.PSObject.Properties['results']-or
            $policy.verdict-cne'non-semantic'-or[string]::IsNullOrWhiteSpace([string]$policy.rationale)-or
            $policy.treeFingerprint-cnotmatch'^[a-f0-9]{64}$'){return $false}
        $tree=@(Invoke-DocsGitQuery @('-C',$ProjectRoot,'ls-tree','-r',$Sha))
        if($LASTEXITCODE-ne0){return $false}
        $bound=@($tree|Where-Object{$_-cnotmatch"`t\.hookmaker-docs-policy\.json$"})-join"`n"
        if((Get-RepositoryIdentityHash $bound)-cne$policy.treeFingerprint){return $false}
        $entries=@{}
        foreach($line in $tree){
            if($line-cmatch'^[0-7]{6} blob ([a-f0-9]{40}|[a-f0-9]{64})\t(.+)$'){$entries[$Matches[2]]=$Matches[1]}
        }
        $documents=@($policy.documents)
        if($documents.Count-ne$Files.Count-or$documents.Count-eq0){return $false}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($document in $documents){
            if($document.path-isnot[string]-or-not$seen.Add($document.path)-or$Files-cnotcontains$document.path-or
                -not$entries.ContainsKey($document.path)-or$document.blob-cne$entries[$document.path]){return $false}
        }
        $reviews=@($policy.candidates)
        if($reviews.Count-ne$Candidates.Count-or$reviews.Count-gt100){return $false}
        $seen.Clear()
        foreach($review in $reviews){
            if($review.path-isnot[string]-or-not$seen.Add($review.path)-or
                -not$entries.ContainsKey($review.path)-or$review.blob-cne$entries[$review.path]-or
                [string]::IsNullOrWhiteSpace([string]$review.rationale)-or
                $review.role-cnotin@('output-only','process-stream','socket-stream','fixed-unrelated-input','opaque-reference','prose-reference','hygiene-only','packaging-identity')){return $false}
            $actual=@($Candidates|Where-Object{$_.Path-ceq$review.path})
            if($actual.Count-ne1-or$actual[0].Bytes-ne$review.bytes){return $false}
        }
        return $true
    }catch{return $false}
}
