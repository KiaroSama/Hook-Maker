# A reviewed baseline is immutable input evidence, never an execution result.
# Inventory includes every path except the explicitly reviewed prose documents.
function Get-CiClosureInventory {
    param([string]$ProjectRoot,[string]$Sha,[string[]]$Documents)
    $rows=@(Invoke-DocsGitQuery @('-C',$ProjectRoot,'ls-tree','-r','-l',$Sha))
    if($LASTEXITCODE-ne0-or$rows.Count-eq0){return $null}
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $parts=New-Object Collections.Generic.List[string]
    $entries=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($row in $rows){
        if($row-cnotmatch'^(100644|100755) blob ([a-f0-9]{40}|[a-f0-9]{64})\s+([0-9]+)\t([^\x00-\x1f]+)$'){return $null}
        $mode=$Matches[1];$blob=$Matches[2];$bytes=[long]$Matches[3];$path=$Matches[4]
        if($path.StartsWith('/')-or$path.Contains('\')-or$path-match'(^|/)\.\.?(/|$)'-or-not$seen.Add($path)){return $null}
        $entries.Add($path,[pscustomobject]@{Mode=$mode;Blob=$blob;Bytes=$bytes})
        if($Documents-cnotcontains$path){$parts.Add($mode+'|'+$blob+'|'+$bytes.ToString([Globalization.CultureInfo]::InvariantCulture)+'|'+$path)}
    }
    [string[]]$ordered=$parts.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
    return [pscustomobject]@{Fingerprint=Get-RepositoryIdentityHash ($ordered-join"`n");Count=$ordered.Count;Entries=$entries}
}
function Test-CiClosureProse {
    param([string]$ProjectRoot,[string]$Sha,[string]$Path)
    $lines=@(Invoke-DocsGitQuery @('-C',$ProjectRoot,'show',($Sha+':'+$Path)))
    if($LASTEXITCODE-ne0){return $false}
    $text=$lines-join"`n"
    # Conservative subset: no fenced/indented executable blocks, directives,
    # templating, raw HTML or includes. Unsupported markup is not prose proof.
    return [Text.Encoding]::UTF8.GetByteCount($text)-le262144-and
        $text-cnotmatch'```|~~~|(?m)^(?: {4}|\t)|[<>]|\{\{|\{%|(?i)\b(include|doctest|mdx|import|export|require)\b'
}
function Test-DocsReviewedAncestorBinding {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,[string]$Ancestor,[string]$Branch)
    $review=Get-Variable DocsReviewedClosure -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if($null-eq$review){return $true}
    $snapshot=Get-Variable DocsAncestorSnapshot -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if($null-eq$snapshot-or$null-eq$snapshot.Provenance){return $false}
    if(@($snapshot.Provenance.runs|Where-Object{@($review.sourceBranches)-cnotcontains$_.branch}).Count){return $false}
    return $review.repository-ieq$RepoSlug-and$review.ancestor.sha-ceq$Ancestor-and@($review.destinationBranches)-ccontains$Branch
}
function Test-CiReviewedClosure {
    param([string]$ProjectRoot,[string]$RepoSlug,[string]$Sha,$Policy,[string[]]$Files,[object[]]$Candidates,[string]$Branch,[string]$Ancestor='')
    try {
        if($Policy.schema-ne2-or$Policy.repository-ine$RepoSlug-or$Policy.verdict-cne'non-semantic'-or
            $Policy.PSObject.Properties['results']-or[string]::IsNullOrWhiteSpace([string]$Policy.rationale)){return $false}
        foreach($binding in @($Policy.baseline,$Policy.ancestor)){
            if($binding.sha-cnotmatch'^[a-f0-9]{40}$'-or$binding.tree-cnotmatch'^[a-f0-9]{40}$'){return $false}
            $tree=(@(Invoke-DocsGit @('-C',$ProjectRoot,'rev-parse',($binding.sha+'^{tree}')))-join'').Trim()
            if($LASTEXITCODE-ne0-or$tree-cne$binding.tree){return $false}
        }
        if($Ancestor-ne''-and$Ancestor-cne$Policy.ancestor.sha){return $false}
        $sources=@($Policy.sourceBranches);$destinations=@($Policy.destinationBranches)
        foreach($property in @('sourceBranches','destinationBranches')){
            $list=@($Policy.$property)
            if($list.Count-eq0-or$list.Count-gt32-or@($list|Where-Object{$_-isnot[string]-or$_-cnotmatch'^[A-Za-z0-9_./-]+$'}).Count-or@($list|Select-Object -Unique).Count-ne$list.Count){return $false}
        }
        if($destinations-cnotcontains$Branch){return $false}
        $maintenance=@(Get-Field $Policy 'maintenanceWorkflows'|Where-Object{$null-ne$_})
        if(@($maintenance|Where-Object{$_-isnot[string]-or$_-cnotmatch'^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$'}).Count-or$maintenance.Count-gt50){return $false}
        $documents=@($Policy.documents)
        if($documents.Count-eq0-or$documents.Count-gt16-or$Files.Count-eq0){return $false}
        $paths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($document in $documents){
            if($document-isnot[string]-or$document-cnotmatch'^[A-Za-z0-9_./-]+\.(md|txt)$'-or$document-match'(^|/)\.\.?(/|$)'-or-not$paths.Add($document)){return $false}
        }
        foreach($file in $Files){if(-not$paths.Contains($file)){return $false}}
        $baseline=Get-CiClosureInventory $ProjectRoot $Policy.baseline.sha $documents
        $current=Get-CiClosureInventory $ProjectRoot $Sha $documents
        $prior=Get-CiClosureInventory $ProjectRoot $Policy.ancestor.sha $documents
        if($null-eq$baseline-or$null-eq$current-or$null-eq$prior-or$Policy.inventory.sha256-cnotmatch'^[a-f0-9]{64}$'-or
            $baseline.Fingerprint-cne$Policy.inventory.sha256-or$baseline.Count-ne$Policy.inventory.count-or
            $current.Fingerprint-cne$baseline.Fingerprint-or$prior.Fingerprint-cne$baseline.Fingerprint){return $false}
        foreach($document in $documents){
            foreach($inventory in @($baseline,$current,$prior)){
                if(-not$inventory.Entries.ContainsKey($document)-or$inventory.Entries[$document].Mode-cne'100644'){return $false}
            }
            foreach($object in @($Policy.baseline.sha,$Sha,$Policy.ancestor.sha)){
                if(-not(Test-CiClosureProse $ProjectRoot $object $document)){return $false}
            }
        }
        $reviews=@($Policy.candidates)
        if($reviews.Count-ne$Candidates.Count-or$reviews.Count-gt100){return $false}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $reviewBytes=[long]0
        foreach($review in $reviews){
            if($review.path-isnot[string]-or-not$seen.Add($review.path)-or-not$current.Entries.ContainsKey($review.path)-or
                -not$baseline.Entries.ContainsKey($review.path)-or$review.blob-cne$baseline.Entries[$review.path].Blob-or$review.bytes-ne$baseline.Entries[$review.path].Bytes-or
                ($paths.Contains($review.path)-and$review.role-cne'prose-reference')-or
                [string]::IsNullOrWhiteSpace([string]$review.rationale)-or
                $review.role-cnotin@('output-only','process-stream','socket-stream','fixed-unrelated-input','opaque-reference','prose-reference','hygiene-only','packaging-identity')){return $false}
            $reviewBytes+=$current.Entries[$review.path].Bytes
            if($reviewBytes-gt1048576){return $false}
            $actual=@($Candidates|Where-Object{$_.Path-ceq$review.path})
            if($actual.Count-ne1){return $false}
        }
        return $true
    } catch {return $false}
}
