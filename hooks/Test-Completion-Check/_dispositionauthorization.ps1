# Exact user text approves immutable request bytes, never an assistant's boolean.
# Local client provenance is not cryptographic human identity.
function Get-DispositionAuthorization {
    param([string]$Path,[string]$RecordId,[string]$RequestHash,[string]$Root,[DateTime]$Created)
    if($RecordId-cnotmatch'^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$'){throw 'Disposition requires the exact user message UUID.'}
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'A regular client transcript is required.'}
    $stream=[IO.File]::Open($item.FullName,'Open','Read',([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
    try{
        $size=[int][Math]::Min(1048576,$stream.Length);$offset=$stream.Length-$size
        [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
        $bytes=New-Object byte[] $size;$read=0
        while($read-lt$size){$n=$stream.Read($bytes,$read,$size-$read);if($n-eq0){break};$read+=$n}
    }finally{$stream.Dispose()}
    $start=0
    if($offset-gt0){while($start-lt$read-and$bytes[$start]-ne10){$start++};$start++}
    $found=@();$utf8=New-Object Text.UTF8Encoding($false,$true)
    for($end=$start;$end-lt$read;$end++){
        if($bytes[$end]-ne10){continue}
        if($end-gt$start){
            try{$record=$utf8.GetString($bytes,$start,$end-$start).TrimStart([char]0xFEFF)|ConvertFrom-Json -ErrorAction Stop}catch{$record=$null}
            if($null-ne$record-and[string](Get-Field $record 'uuid')-ceq$RecordId){$found+=,$record}
        }
        $start=$end+1
    }
    if($found.Count-ne1){throw 'Exact authorization record is missing, duplicated or outside the bounded transcript tail.'}
    $r=$found[0];$m=Get-Field $r 'message';$at=ConvertTo-UtcTime (Get-Field $r 'timestamp')
    if([string](Get-Field $r 'type')-cne'user'-or[string](Get-Field $m 'role')-cne'user'-or
        (Get-Field $r 'isMeta')-eq$true-or(Get-Field $m 'isMeta')-eq$true-or
        $null-ne(Get-Field $r 'sourceToolAssistantUUID')-or$null-ne(Get-Field $r 'toolUseResult')-or
        $null-ne(Get-Field $r 'source')-or[string]::IsNullOrWhiteSpace([string](Get-Field $r 'sessionId'))-or
        -not[string]::Equals((Normalize-Path ([string](Get-Field $r 'cwd'))),(Normalize-Path $Root),[StringComparison]::OrdinalIgnoreCase)-or
        $null-eq$at-or$at-lt$Created-or$at-lt[DateTime]::UtcNow.AddHours(-1)-or$at-gt[DateTime]::UtcNow.AddSeconds(2)){throw 'Disposition authorization is not a fresh exact-project human record.'}
    $content=Get-Field $m 'content';$text=''
    if($content-is[string]){$text=$content}else{
        $parts=@($content)
        if($parts.Count-ne1-or[string](Get-Field $parts[0] 'type')-cne'text'-or$null-ne(Get-Field $parts[0] 'annotations')){throw 'Disposition authorization must be plain explicit user text.'}
        $text=[string](Get-Field $parts[0] 'text')
    }
    if($text.TrimEnd([char[]]@("`r","`n"))-cne('::test-disposition '+$RequestHash)){throw 'Human authorization does not name these exact request bytes.'}
    return [pscustomobject]@{recordId=$RecordId;sessionId=[string]$r.sessionId;authorizedUtc=$at.ToString('o');requestSha256=$RequestHash}
}
