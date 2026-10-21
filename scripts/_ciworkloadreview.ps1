# Management-only review publication. Never reads run outcomes or writes CI state.
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
    if($null-eq$record-or-not(Test-InstallRecordValid $record).Ok-or$record.scope-cne'project'-or$record.friendlyName-cne'Ci-Status-Check'-or
        (Normalize-Path $record.toolRoot)-ine(Normalize-Path $ToolRoot)-or(Normalize-Path $record.sourceScript)-ine(Normalize-Path (Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'))){throw 'Select an existing project Ci-Status-Check record owned by this tool.'}
    $integrity=Get-InstallIntegrity $record $ToolRoot
    $component=@($integrity.Components|Where-Object{$_.Name-ceq$Client})
    if($component.Count-ne1-or$component[0].Status-cne'current'){throw 'Update or repair the selected managed payload/registration before enrolling input review.'}
    $sub=Get-ClientSubrecord $record $Client
    if($null-eq$sub-or-not$sub.installed){throw 'Selected client is not installed.'}
    $directory=Split-Path -Parent ([string]$sub.runtimeScript)
    $null=Get-RepositoryPhysicalRoot $directory
    $metadata=Join-Path $directory '.hookmaker-runtime.json'
    $raw=Read-CiReviewBytes $metadata
    $owner=[Text.UTF8Encoding]::new($false,$true).GetString($raw).TrimStart([char]0xfeff)|ConvertFrom-Json
    if($owner.recordId-cne$RecordId-or$owner.client-cne$Client-or$owner.friendlyName-cne'Ci-Status-Check'){throw 'Runtime ownership metadata differs from selected record.'}
    return [pscustomobject]@{Record=$record;Client=$Client;Directory=$directory;PolicyPath=Join-Path $directory '_ci-policy.json';MetadataHash=Get-CiReviewBytesHash $raw}
}
function Save-CiReviewRecovery {
    param([string]$ToolRoot,[string]$RecordId,[string]$Client,[byte[]]$Submitted,[AllowNull()][byte[]]$Previous)
    $root=Join-Path (Get-InstallStateDirectory $ToolRoot) 'ci-review-recovery'
    $parent=Get-InstallStateDirectory $ToolRoot
    $null=Get-RepositoryPhysicalRoot $parent
    [void][IO.Directory]::CreateDirectory($root)
    $null=Get-RepositoryPhysicalRoot $root
    $directory=Join-Path $root ($RecordId+'-'+$Client+'-'+[guid]::NewGuid().ToString('N'))
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
        if(-not$held){throw 'Selected runtime is busy; no review changed.'}
        $previous=Read-CiReviewBytes $Selection.PolicyPath -Optional
        if((Get-CiReviewBytesHash $previous)-cne$ExpectedPolicyHash){throw 'Review preimage changed; inspect the current policy before applying again.'}
        $null=& $Revalidate
        $recovery=Save-CiReviewRecovery $ToolRoot $Selection.Record.id $Selection.Client $Submitted $previous
        $encoded=[Text.UTF8Encoding]::new($false,$true).GetBytes($Json)
        if($encoded.Length-gt65536){throw 'Enrolled review exceeds 64 KiB.'}
        $temp=Join-Path $Selection.Directory ('.ci-review-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $stream=[IO.File]::Open($temp,'CreateNew','Write','None')
        try{$stream.Write($encoded,0,$encoded.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        $null=& $Revalidate
        if((Get-CiReviewBytesHash (Read-CiReviewBytes $Selection.PolicyPath -Optional))-cne$ExpectedPolicyHash){throw 'Concurrent review modification detected; original preserved.'}
        if($null-eq$previous){[IO.File]::Move($temp,$Selection.PolicyPath)}else{[IO.File]::Replace($temp,$Selection.PolicyPath,[NullString]::Value)}
        $temp=''
        if((Get-CiReviewBytesHash (Read-CiReviewBytes $Selection.PolicyPath))-cne(Get-CiReviewBytesHash $encoded)){throw 'Published review could not be verified; retain recovery data.'}
        return [pscustomobject]@{status='enrolled';policyHash=Get-CiReviewBytesHash $encoded;recoveryPath=$recovery}
    }finally{if($temp-ne''-and[IO.File]::Exists($temp)){[IO.File]::Delete($temp)};if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
