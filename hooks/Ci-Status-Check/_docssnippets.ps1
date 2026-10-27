# A reviewed document may change prose, never the protected executable surface.
# This is deliberately not a Markdown parser: unsupported constructs stay unknown.
function Get-DocsProtectedProjection {
    param([string[]]$Lines)
    $text=$Lines-join"`n"
    if([Text.Encoding]::UTF8.GetByteCount($text)-gt262144){return $null}
    $parts=New-Object Collections.Generic.List[string]
    $fence=''
    foreach($line in $Lines){
        if($fence-ne''){
            if($line-ceq$fence){$parts.Add('fence:'+$line);$fence='';continue}
            if($line-match'```|~~~'){return $null}
            $parts.Add('code:'+$line);continue
        }
        if($line-cmatch'^(```|~~~)[A-Za-z0-9_+-]*$'){
            $fence=$Matches[1];$parts.Add('fence:'+$line);continue
        }
        if($line-match'```|~~~|^(?: {4}|\t)|[<>]|\{\{|\{%|(?i)\b(include|doctest|mdx|import|export|require)\b'){return $null}
        if($line.Contains('`')){
            if($line-notmatch'^[^`]*(?:`[^`]+`[^`]*)+$'){return $null}
            $parts.Add('inline:'+$line);continue
        }
        # Links, headings, lists, escapes and other markup cannot evolve as prose.
        if($line-eq''-or$line-match'^\s|^[-+*]|^[0-9]+[.)]\s|[^\p{L}\p{N} .,;:!?()\-/\x27\x22]'){$parts.Add('markup:'+$line)}
    }
    if($fence-ne''){return $null}
    return [pscustomobject]@{Sha256=Get-RepositoryIdentityHash ($parts.ToArray()-join"`n")}
}
function Test-DocsClosureDocumentIdentity {
    param($Inventory,[string]$Sha,[string]$CurrentSha,$Policy,[string]$Path)
    if(-not$Inventory.Entries.ContainsKey($Path)-or$Inventory.Entries[$Path].Mode-cne'100644'){return $false}
    if(-not$Policy.PSObject.Properties['candidatePages']){return $true}
    $contracts=@($Policy.documentContracts|Where-Object{$_.path-ceq$Path})
    if($contracts.Count-ne1){return $false}
    $contract=$contracts[0]
    if($contract.beforeBlob-isnot[string]-or$contract.afterBlob-isnot[string]-or
        $contract.beforeBlob-cnotmatch'^[a-f0-9]{40}$'-or$contract.afterBlob-cnotmatch'^[a-f0-9]{40}$'){return $false}
    $blob=$Inventory.Entries[$Path].Blob
    if(($Sha-ceq$Policy.baseline.sha-or$Sha-ceq$Policy.ancestor.sha)-and$blob-cne$contract.beforeBlob){return $false}
    if($Sha-ceq$CurrentSha-and$blob-cne$contract.afterBlob){return $false}
    return @($contract.beforeBlob,$contract.afterBlob)-ccontains$blob
}
function Test-DocsClosureDocument {
    param([string]$ProjectRoot,[string]$Sha,[string]$Path,$Policy)
    if($Policy.schema-ne3){return Test-CiClosureProse $ProjectRoot $Sha $Path}
    $contracts=@($Policy.documentContracts)
    if($contracts.Count-ne@($Policy.documents).Count){return $false}
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($contract in $contracts){
        if($contract.path-isnot[string]-or-not$seen.Add($contract.path)-or@($Policy.documents)-cnotcontains$contract.path-or
            $contract.sha256-isnot[string]-or$contract.sha256-cnotmatch'^[a-f0-9]{64}$'){return $false}
    }
    $binding=@($contracts|Where-Object{$_.path-ceq$Path})
    if($binding.Count-ne1){return $false}
    $lines=@(Invoke-DocsGitQuery @('-C',$ProjectRoot,'show',($Sha+':'+$Path)) -PreserveEmptyLines)
    if($LASTEXITCODE-ne0){return $false}
    $projection=Get-DocsProtectedProjection $lines
    return $null-ne$projection-and$projection.Sha256-ceq$binding[0].sha256
}
