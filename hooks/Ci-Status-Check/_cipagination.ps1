# Count-bearing REST collections only. All pages share the existing transport
# budget; a short/duplicate/changing page never becomes a successful subset.
function Read-CiWorkloadCollection {
    param([string]$Endpoint,[ValidateSet('workflow_runs','jobs','check_runs','statuses')][string]$Field,[string]$IdentityField='id',[string]$Sha='')
    try {
        if(-not(Test-CiBatchEndpoint $Endpoint)-or$Endpoint-match'(?:\?|&)page='-or$Endpoint-cnotmatch'(?:\?|&)per_page=(50|100)(?:&|$)'){return $null}
        $size=[int]$Matches[1]
        $first=$null;$total=-1;$bytes=[long]0
        $rows=New-Object 'Collections.Generic.List[object]'
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        for($page=1;$page-le32;$page++){
            $url=if($page-eq1){$Endpoint}else{$Endpoint+'&page='+$page}
            $doc=Read-CiWorkloadApi $url
            if($null-eq$doc-or$null-eq$doc.PSObject.Properties['total_count']-or$null-eq$doc.PSObject.Properties[$Field]){return $null}
            $count=$doc.total_count
            if(($count-isnot[int]-and$count-isnot[long])-or$count-lt0-or$count-gt32*$size){return $null}
            if($page-eq1){$total=[int]$count;$first=$doc}elseif($count-ne$total){return $null}
            if($Sha-ne''-and(Get-Field $doc 'sha')-cne$Sha){return $null}
            $items=$doc.PSObject.Properties[$Field].Value
            if($items-isnot[Array]){return $null}
            if($items.Count-ne[Math]::Min($size,$total-$rows.Count)){return $null}
            $pageBytes=[Text.Encoding]::UTF8.GetByteCount(($doc|ConvertTo-Json -Depth 40 -Compress))
            $bytes+=$pageBytes
            if($pageBytes-gt1048576-or$bytes-gt4194304){return $null}
            foreach($item in $items){
                if($null-eq$item){return $null}
                $key=[string](Get-Field $item $IdentityField)
                if([string]::IsNullOrWhiteSpace($key)-or($IdentityField-ceq'id'-and$key-cnotmatch'^[1-9][0-9]*$')-or-not$seen.Add($key)){return $null}
                $rows.Add($item)
            }
            if($rows.Count-eq$total){$first.$Field=$rows.ToArray();return $first}
        }
        return $null
    }catch{return $null}
}
