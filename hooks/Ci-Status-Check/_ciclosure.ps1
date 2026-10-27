# A reviewed baseline is immutable input evidence, never an execution result.
# Inventory includes every path except the explicitly reviewed prose documents.
. (Join-Path $PSScriptRoot '_docssnippets.ps1')
function Get-DocsClosureCandidates {
    param($Policy)
    if(-not$Policy.PSObject.Properties['candidatePages']){return [pscustomobject]@{Items=@($Policy.candidates);Paged=$false}}
    if($Policy.schema-ne3-or$Policy.PSObject.Properties['candidates']){return $null}
    if($Policy.candidatePages-isnot[Array]){return $null}
    $pages=@($Policy.candidatePages)
    if($pages.Count-lt1-or$pages.Count-gt16){return $null}
    $items=New-Object Collections.Generic.List[object]
    foreach($page in $pages){
        if($page.candidates-isnot[Array]){return $null}
        $rows=@($page.candidates)
        if($rows.Count-lt1-or$rows.Count-gt100){return $null}
        $bytes=[long]0
        foreach($row in $rows){
            if($row.bytes-isnot[int]-and$row.bytes-isnot[long]){return $null}
            if($row.bytes-lt0-or$row.bytes-gt1048576-$bytes){return $null}
            $bytes+=$row.bytes;$items.Add($row)
        }
    }
    return [pscustomobject]@{Items=$items.ToArray();Paged=$true}
}
function Get-CiClosureInventory {
    param([string]$ProjectRoot,[string]$Sha,[string[]]$Documents,$Policy=$null)
    $key=''
    if($null-ne$Policy-and(Get-Variable DocsInventoryCache -Scope Script -ErrorAction SilentlyContinue)-and
        (Get-Variable DocsEvidenceScope -Scope Script -ErrorAction SilentlyContinue)-and$script:DocsEvidenceScope-ne''-and$Sha-cmatch'^[a-f0-9]{40}$'-and[IO.Directory]::Exists($ProjectRoot)){
        $physical=Get-RepositoryPhysicalRoot $ProjectRoot
        $rootIdentity=$physical+'|'+[IO.Directory]::GetCreationTimeUtc($physical).Ticks+'|'+[IO.File]::GetCreationTimeUtc((Join-Path $physical '.git')).Ticks
        $key=Get-RepositoryIdentityHash ((@($script:DocsEvidenceScope,$rootIdentity,$Sha,($Documents|ConvertTo-Json -Compress),($Policy|ConvertTo-Json -Depth 100 -Compress)))-join'|')
        if($script:DocsInventoryCache.ContainsKey($key)){return $script:DocsInventoryCache[$key]}
    }
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
    $inventory=[pscustomobject]@{Fingerprint=Get-RepositoryIdentityHash ($ordered-join"`n");Count=$ordered.Count;Entries=$entries}
    # Parsing an immutable tree twice adds no evidence; only successful bounded
    # inventories in this invocation/review scope are reusable, never verdicts.
    if($key-ne''){
        $size=[Text.Encoding]::UTF8.GetByteCount(($rows-join"`n"))
        if($script:DocsInventoryCache.Count-lt32-and$script:DocsInventoryBytes+$size-le4194304){
            $script:DocsInventoryCache[$key]=$inventory;$script:DocsInventoryBytes+=$size
        }
    }
    return $inventory
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
        if($Policy.schema-notin@(2,3)-or$Policy.repository-ine$RepoSlug-or$Policy.verdict-cne'non-semantic'-or
            $Policy.PSObject.Properties['results']-or[string]::IsNullOrWhiteSpace([string]$Policy.rationale)){return $false}
        $candidateReview=Get-DocsClosureCandidates $Policy
        if($null-eq$candidateReview){return $false}
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
        $baseline=Get-CiClosureInventory $ProjectRoot $Policy.baseline.sha $documents $Policy
        $current=Get-CiClosureInventory $ProjectRoot $Sha $documents $Policy
        $prior=Get-CiClosureInventory $ProjectRoot $Policy.ancestor.sha $documents $Policy
        if($null-eq$baseline-or$null-eq$current-or$null-eq$prior-or$Policy.inventory.sha256-cnotmatch'^[a-f0-9]{64}$'-or
            $baseline.Fingerprint-cne$Policy.inventory.sha256-or$baseline.Count-ne$Policy.inventory.count-or
            $current.Fingerprint-cne$baseline.Fingerprint-or$prior.Fingerprint-cne$baseline.Fingerprint){return $false}
        foreach($document in $documents){
            foreach($binding in @(@{Sha=$Policy.baseline.sha;Inventory=$baseline},@{Sha=$Sha;Inventory=$current},@{Sha=$Policy.ancestor.sha;Inventory=$prior})){
                if(-not(Test-DocsClosureDocumentIdentity $binding.Inventory $binding.Sha $Sha $Policy $document)-or
                    -not(Test-DocsClosureDocument $ProjectRoot $binding.Sha $document $Policy)){return $false}
            }
        }
        $reviews=@($candidateReview.Items)
        # Explicit schema3 review binds identities without reading source bodies;
        # automatic inspection and older review contracts keep their original caps.
        $limit=if($candidateReview.Paged){1600}elseif($Policy.schema-eq3){256}else{100}
        $byteLimit=if($Policy.schema-eq3){16777216}else{1048576}
        if($reviews.Count-ne$Candidates.Count-or$reviews.Count-gt$limit){return $false}
        $actualPaths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($candidate in $Candidates){if($candidate.Path-isnot[string]-or-not$actualPaths.Add($candidate.Path)){return $false}}
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $reviewBytes=[long]0
        foreach($review in $reviews){
            if($review.path-isnot[string]-or-not$seen.Add($review.path)-or-not$current.Entries.ContainsKey($review.path)-or
                -not$baseline.Entries.ContainsKey($review.path)-or$review.blob-cne$baseline.Entries[$review.path].Blob-or$review.bytes-ne$baseline.Entries[$review.path].Bytes-or
                ($paths.Contains($review.path)-and$review.role-cne'prose-reference')-or
                [string]::IsNullOrWhiteSpace([string]$review.rationale)-or
                $review.role-cnotin@('output-only','process-stream','socket-stream','fixed-unrelated-input','opaque-reference','prose-reference','hygiene-only','packaging-identity')){return $false}
            $entry=if($candidateReview.Paged){$baseline.Entries[$review.path]}else{$current.Entries[$review.path]}
            if($entry.Bytes-gt$byteLimit-$reviewBytes){return $false}
            $reviewBytes+=$entry.Bytes
            if($reviewBytes-gt$byteLimit-or-not$actualPaths.Contains($review.path)){return $false}
        }
        return $true
    } catch {return $false}
}
