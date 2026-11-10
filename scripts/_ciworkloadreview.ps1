# Management-only review publication. Never reads run outcomes or writes CI state.
function Stop-CiReview {
    param([string]$Code)
    $errorObject=New-Object InvalidOperationException('CI input review refused.')
    $errorObject.Data['HookMakerReviewCode']=$Code
    throw $errorObject
}
function Get-CiReviewFailureMessage {
    param($Failure,[string]$Phase,[string]$ToolRoot,[string]$RecordId,[string]$Client)
    # Only our allowlist is printable; exception text can contain private paths/data.
    $code=[string]$Failure.Exception.Data['HookMakerReviewCode']
    $advice=switch($code){
        'record-missing' {'Refresh installation status; select an existing record.'}
        'record-invalid' {'Record invalid; inspect ownership before repair.'}
        'identity-changed' {'Ownership changed; reconcile selected record/runtime, never overwrite.'}
        'source-stale' {'Source generation changed; wait for frozen source, preview selected repair.'}
        'payload-stale' {'Managed payload stale; preview repair, preserve independent edits.'}
        'registration-stale' {'Registration differs; inspect saved binding, preview selected repair.'}
        'client-missing' {'Selected client is not installed; no other client was selected.'}
        'runtime-busy' {'Runtime busy; wait for its owner, do not reinstall concurrently.'}
        'policy-mismatch' {'Policy preimage changed; inspect current review, no automatic hash refresh.'}
        default {$code='validation-unverified';'Verify exact source/context, workflow access and reviewed policy.'}
    }
    $repair=''
    if($code-in@('source-stale','payload-stale','registration-stale')){
        $scriptPath=(Join-Path $ToolRoot 'scripts/Repair-Hook.ps1').Replace("'","''")
        $repair=" Preview: pwsh -NoProfile -File '$scriptPath' -RecordId $RecordId -Client $Client. Apply only after review with -Apply."
    }
    return ('CI workload review refused at '+$Phase+' ['+$code+']; record='+$RecordId+'; client='+$Client+'. '+$advice+$repair+' Original review/recovery preserved; no CI result stored.')
}
function Read-CiReviewBytes {
    param([string]$Path,[switch]$Optional)
    if(-not(Test-Path -LiteralPath $Path)){if($Optional){return $null};throw 'Review file is missing.'}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$item.Length-gt65536){throw 'Review must be a regular file no larger than 64 KiB.'}
    $probe=$item.Directory
    while($null-ne$probe){if($probe.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Review path contains a link.'};$probe=$probe.Parent}
    $bytes=[IO.File]::ReadAllBytes($Path)
    $null=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    return ,$bytes
}
function Get-CiReviewBytesHash {
    param([AllowNull()][byte[]]$Bytes)
    if($null-eq$Bytes){return 'absent'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Get-CiReviewSelection {
    param([string]$ToolRoot,[string]$RecordId,[string]$Client)
    $record=Get-InstallRecordById -ToolRoot $ToolRoot -Id $RecordId
    if($null-eq$record){Stop-CiReview record-missing}
    if(-not(Test-InstallRecordValid $record).Ok){Stop-CiReview record-invalid}
    if($record.scope-cne'project'-or$record.friendlyName-cne'Ci-Status-Check'-or
        (Normalize-Path $record.toolRoot)-ine(Normalize-Path $ToolRoot)-or(Normalize-Path $record.sourceScript)-ine(Normalize-Path (Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'))){Stop-CiReview identity-changed}
    $integrity=Get-InstallIntegrity $record $ToolRoot
    if($null-eq$integrity.PSObject.Properties['Components']){Stop-CiReview record-invalid}
    $component=@($integrity.Components|Where-Object{$_.Name-ceq$Client})
    if($component.Count-ne1){Stop-CiReview client-missing}
    if($component[0].Status-cne'current'){
        $detail=[string]$component[0].Detail
        $code=if($detail-match'^source (changed|file)'){'source-stale'}elseif($detail-match'registration'){'registration-stale'}elseif($detail-match'ownership'){'identity-changed'}else{'payload-stale'}
        Stop-CiReview $code
    }
    $sub=Get-ClientSubrecord $record $Client
    if($null-eq$sub-or-not$sub.installed){Stop-CiReview client-missing}
    $directory=Split-Path -Parent ([string]$sub.runtimeScript)
    $null=Get-RepositoryPhysicalRoot $directory
    $metadata=Join-Path $directory '.hookmaker-runtime.json'
    $raw=Read-CiReviewBytes $metadata
    $owner=[Text.UTF8Encoding]::new($false,$true).GetString($raw).TrimStart([char]0xfeff)|ConvertFrom-Json
    if($owner.recordId-cne$RecordId-or$owner.client-cne$Client-or$owner.friendlyName-cne'Ci-Status-Check'){Stop-CiReview identity-changed}
    return [pscustomobject]@{Record=$record;Client=$Client;Directory=$directory;PolicyPath=Join-Path $directory '_ci-policy.json';MetadataHash=Get-CiReviewBytesHash $raw}
}
function Save-CiReviewRecovery {
    param([string]$ToolRoot,[string]$RecordId,[string]$Client,[byte[]]$Submitted,[AllowNull()][byte[]]$Previous,[ValidateSet('_ci-policy.json','_docs-policy.json')][string]$PolicyName='_ci-policy.json')
    $root=Join-Path (Get-InstallStateDirectory $ToolRoot) 'ci-review-recovery'
    $parent=Get-InstallStateDirectory $ToolRoot
    $null=Get-RepositoryPhysicalRoot $parent
    [void][IO.Directory]::CreateDirectory($root)
    $null=Get-RepositoryPhysicalRoot $root
    $kind=if($PolicyName-ceq'_docs-policy.json'){'-docs'}else{''}
    $directory=Join-Path $root ($RecordId+'-'+$Client+$kind+'-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    foreach($item in @(@('submitted.json',$Submitted),@('previous.json',$Previous))){
        if($null-eq$item[1]){continue}
        $path=Join-Path $directory $item[0]
        $stream=[IO.File]::Open($path,'CreateNew','Write','None')
        try{$stream.Write($item[1],0,$item[1].Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if((Get-CiReviewBytesHash (Read-CiReviewBytes $path))-cne(Get-CiReviewBytesHash $item[1])){throw 'Review recovery copy verification failed.'}
    }
    return $directory
}
function Publish-CiWorkloadReview {
    param([string]$ToolRoot,$Selection,[byte[]]$Submitted,[string]$Json,[string]$ExpectedPolicyHash,[scriptblock]$Revalidate)
    $mutex=New-ManagedRuntimeMutex $Selection.Directory
    $held=$false;$temp=''
    try{
        try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not$held){Stop-CiReview runtime-busy}
        $previous=Read-CiReviewBytes $Selection.PolicyPath -Optional
        if((Get-CiReviewBytesHash $previous)-cne$ExpectedPolicyHash){Stop-CiReview policy-mismatch}
        $null=& $Revalidate
        $recovery=Save-CiReviewRecovery $ToolRoot $Selection.Record.id $Selection.Client $Submitted $previous
        $encoded=[Text.UTF8Encoding]::new($false,$true).GetBytes($Json)
        if($encoded.Length-gt65536){throw 'Enrolled review exceeds 64 KiB.'}
        $temp=Join-Path (Split-Path -Parent $Selection.Directory) ('.ci-review-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $stream=[IO.File]::Open($temp,'CreateNew','Write','None')
        try{$stream.Write($encoded,0,$encoded.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        $null=& $Revalidate
        if((Get-CiReviewBytesHash (Read-CiReviewBytes $Selection.PolicyPath -Optional))-cne$ExpectedPolicyHash){Stop-CiReview policy-mismatch}
        if($null-eq$previous){[IO.File]::Move($temp,$Selection.PolicyPath)}else{[IO.File]::Replace($temp,$Selection.PolicyPath,[NullString]::Value)}
        $temp=''
        if((Get-CiReviewBytesHash (Read-CiReviewBytes $Selection.PolicyPath))-cne(Get-CiReviewBytesHash $encoded)){throw 'Published review could not be verified; retain recovery data.'}
        return [pscustomobject]@{status='enrolled';policyHash=Get-CiReviewBytesHash $encoded;recoveryPath=$recovery}
    }finally{if($temp-ne''-and[IO.File]::Exists($temp)){[IO.File]::Delete($temp)};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
