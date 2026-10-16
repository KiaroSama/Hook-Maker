# Compiled reader fault controls share one process and tiny exact raw frames.
Initialize-Utf8BatchReader
$oid='a'*40
$cases=@(
    @{Header=($oid+' missing');Body=[byte[]]@();End=[byte[]]@();Reason='missing-object'},
    @{Header=($oid+' tree 0');Body=[byte[]]@();End=[byte[]]@(10);Reason='malformed-header'},
    @{Header=($oid+' blob 5');Body=[byte[]]@(97);End=[byte[]]@(10);Reason='short-body'},
    @{Header=($oid+' blob 1');Body=[byte[]]@(97);End=[byte[]]@(13);Reason='missing-delimiter'}
)
foreach($case in $cases){
    $bytes=[Text.Encoding]::ASCII.GetBytes($case.Header+"`n")+$case.Body+$case.End
    $stream=[IO.MemoryStream]::new([byte[]]$bytes,$false);$reason=''
    try{$reader=[HookMakerUtf8.BatchReader]::new($stream,[DateTime]::UtcNow.AddSeconds(2));$null=$reader.Frame($oid,8MB)}
    catch{$reason=$_.Exception.ToString()}finally{$stream.Dispose()}
    Check ('compiled batch exact diagnostic '+$case.Reason) ($reason.Contains($case.Reason))
}
# Read-ahead must survive across a large invalid body, binary and final valid frame.
$body=[Text.Encoding]::ASCII.GetBytes('a'*(1MB+7))+[byte[]]@(0xC3)
$bytes=[Text.Encoding]::ASCII.GetBytes($oid+' blob '+$body.Length+"`n")+$body+[byte[]]@(10)+
    [Text.Encoding]::ASCII.GetBytes($oid+" blob 4`n")+[byte[]]@(0,0,97,98,10)+[Text.Encoding]::ASCII.GetBytes($oid+" blob 1`na`n")
$stream=[IO.MemoryStream]::new([byte[]]$bytes,$false)
try{
    $reader=[HookMakerUtf8.BatchReader]::new($stream,[DateTime]::UtcNow.AddSeconds(3))
    $first=$reader.Frame($oid,8MB);$second=$reader.Frame($oid,8MB);$third=$reader.Frame($oid,8MB)
    Check 'compiled read-ahead drains late invalid and binary frames before next valid text' ($first.Class-eq'invalid'-and$second.Class-eq'binary'-and$third.Class-eq'utf8')
}finally{$stream.Dispose()}
