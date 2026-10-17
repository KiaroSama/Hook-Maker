# Compiled reader fault controls share one process and tiny exact raw frames.
Initialize-Utf8BatchReader
$oid='a'*40
# One dedicated worker, not one thread-pool operation per pipe buffer/window.
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '_testutf8syncstream.cs'),[Text.Encoding]::UTF8))
$ids=[string[]]@(1..65|ForEach-Object{$_.ToString('x40')})
$wire=($ids|ForEach-Object{$_+" blob 1`na`n"})-join''
$source=[Utf8SyncStream]::new([Text.Encoding]::ASCII.GetBytes($wire))
$sink=[Utf8SyncStream]::new();$worker=$null;$schedulingPassed=$false;$schedulingError=''
try {
    $worker=[HookMakerUtf8.BatchWorker]::new($sink,$source,$ids,8MB,[DateTime]::UtcNow.AddSeconds(3))
    $schedulingPassed=$worker.Work.Wait(3000)
    if($schedulingPassed){
        $schedulingPassed=$worker.Failure-eq''-and$worker.Results.Count-eq65-and
            @($worker.Results.Values|Where-Object{$_.Failed-or$_.Class-ne'utf8'}).Count-eq0-and
            [Text.Encoding]::ASCII.GetString($sink.ToArray())-ceq(($ids-join"`n")+"`n")-and
            $sink.MaximumWrite-le2080-and$sink.FlushCount-eq3-and
            $source.AsyncCalls-eq0-and$sink.AsyncCalls-eq0-and
            $source.WorkerThread-eq$sink.WorkerThread-and$source.WorkerThread-ne[Threading.Thread]::CurrentThread.ManagedThreadId-and
            -not$source.UsedThreadPool-and-not$sink.UsedThreadPool
    }
}catch{$schedulingError=$_.Exception.Message}
finally{
    $stopped=$null-eq$worker-or$worker.Stop(2000)
    $schedulingPassed=$schedulingPassed-and$stopped
    if($stopped){$source.Dispose();$sink.Dispose()}
}
Check 'whole batch uses one dedicated synchronous worker with exact bounded request windows' $schedulingPassed $schedulingError
Check 'pending synchronous pipe acknowledges cancellation while writer remains open' ([Utf8SyncStream]::CheckPendingPipeCancellation([HookMakerUtf8.BatchWorker]))
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
