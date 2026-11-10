# Explicit reviewed evidence, not provider verification or CI success.
function Get-DeploymentConfigurationPath {
    param([string]$Root)
    foreach($name in @('wrangler.toml','wrangler.jsonc','wrangler.json')){
        $path=Join-Path $Root $name
        if(Test-Path -LiteralPath $path -PathType Leaf){return $path}
    }
    return ''
}
function Read-DeploymentEvidence {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer-or$item.Length-gt65536){throw 'Evidence must be a regular file <=64 KiB.'}
    $probe=$item
    while($null-ne$probe){
        if($probe.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Evidence path contains a link.'}
        $probe=if($probe-is[IO.DirectoryInfo]){$probe.Parent}else{$probe.Directory}
    }
    $stream=[IO.File]::Open($item.FullName,'Open','Read','Read')
    try {
        if($stream.Length-gt65536){throw 'Evidence exceeds 64 KiB.'}
        $bytes=New-Object byte[] ([int]$stream.Length)
        $offset=0
        while($offset-lt$bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read-le0){throw 'Evidence read incomplete.'};$offset+=$read}
        if($stream.ReadByte()-ne-1){throw 'Evidence changed while reading.'}
    }finally{$stream.Dispose()}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    return [pscustomobject]@{Document=($text|ConvertFrom-Json);Hash=$digest;Path=$item.FullName}
}
function Get-DeploymentAckPath {
    param([string]$Root,[string]$Client,[string]$Commit,[string]$StateDirectory)
    if($Client-cnotin@('claude','codex')-or$Commit-cnotmatch'^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){throw 'Exact client and full commit SHA required.'}
    $key=Get-RepositoryIdentityHash ((Normalize-Path $Root).ToLowerInvariant())
    return Join-Path $StateDirectory ('CloudflareDeploy-ack-'+$key+'-'+$Client+'-'+$Commit+'.json')
}
function Get-DeploymentCooldownPath {
    param([string]$Root,[string]$Client,[string]$Commit,[string]$ConfigPath,[string]$StateDirectory)
    $identity=[IO.Path]::GetFileNameWithoutExtension((Get-DeploymentAckPath $Root $Client $Commit $StateDirectory))
    $configHash=Read-DeploymentEvidenceConfig $ConfigPath
    return Join-Path $StateDirectory ($identity.Replace('CloudflareDeploy-ack-','CloudflareDeploy-cooldown-')+'-'+$configHash+'.txt')
}
function Test-DeploymentEvidenceDocument {
    param($Document,[string]$Root,[string]$Client,[string]$Commit)
    try {
        if($null-eq$Document-or($Document.schema-isnot[int]-and$Document.schema-isnot[long])-or$Document.schema-ne1-or$Document.client-cne$Client-or$Document.commit-cne$Commit-or
            -not[string]::Equals((Normalize-Path $Document.projectRoot),(Normalize-Path $Root),[StringComparison]::OrdinalIgnoreCase)-or
            $Document.result-cnotin@('deployed','no-ship')-or[string]::IsNullOrWhiteSpace($Document.reason)){return $false}
        $allowed=@('schema','projectRoot','client','commit','result','reason','environment','service','version','postcheck','verifiedUtc')
        foreach($property in $Document.PSObject.Properties){
            if($property.Name-cnotin$allowed){return $false}
            if($property.Name-cne'schema'-and($property.Value-isnot[string]-and$property.Value-isnot[datetime])){return $false}
            if(([string]$property.Value).Length-gt2048){return $false}
        }
        if($Document.result-ceq'deployed'){
            foreach($field in @('environment','service','version','postcheck')){
                if([string]::IsNullOrWhiteSpace([string](Get-Field $Document $field))){return $false}
            }
            $rawTime=Get-Field $Document 'verifiedUtc'
            $time=[DateTime]::MinValue
            if($rawTime-is[datetime]){$time=$rawTime.ToUniversalTime()}
            elseif([string]$rawTime-match'(Z|[+-]\d{2}:?\d{2})$'){
                if(-not[DateTime]::TryParse([string]$rawTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$time)){return $false}
                $time=$time.ToUniversalTime()
            }else{return $false}
            if($time-gt[DateTime]::UtcNow.AddSeconds(2)){return $false}
        }
        return $true
    }catch{return $false}
}
function Read-DeploymentEvidenceConfig {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer-or$item.Length-gt1048576){throw 'Deployment configuration unavailable or oversized.'}
    $probe=$item
    while($null-ne$probe){
        if($probe.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Deployment configuration path contains a link.'}
        $probe=if($probe-is[IO.DirectoryInfo]){$probe.Parent}else{$probe.Directory}
    }
    $stream=[IO.File]::Open($item.FullName,'Open','Read','Read')
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        if($stream.Length-gt1048576){throw 'Deployment configuration exceeds 1 MiB.'}
        return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    }finally{$hash.Dispose();$stream.Dispose()}
}
function Initialize-DeploymentStateDirectory {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $missing=New-Object 'Collections.Generic.Stack[string]'
    $ancestor=$full
    while(-not[IO.Directory]::Exists($ancestor)){
        if([IO.File]::Exists($ancestor)){throw 'State directory path contains a file.'}
        $missing.Push($ancestor)
        $parent=[IO.Directory]::GetParent($ancestor)
        if($null-eq$parent){throw 'State directory has no existing parent.'}
        $ancestor=$parent.FullName
    }
    $null=Get-RepositoryPhysicalRoot $ancestor
    while($missing.Count){
        $next=$missing.Pop()
        $null=Get-RepositoryPhysicalRoot ([IO.Directory]::GetParent($next).FullName)
        [void][IO.Directory]::CreateDirectory($next)
        $null=Get-RepositoryPhysicalRoot $next
    }
    return Get-RepositoryPhysicalRoot $full
}
function Save-DeploymentAcknowledgment {
    param([string]$Root,[string]$Client,[string]$Commit,[string]$ConfigPath,[string]$StateDirectory,[string]$EvidencePath,[scriptblock]$Revalidate)
    $null=Get-RepositoryPhysicalRoot $Root
    $evidence=Read-DeploymentEvidence $EvidencePath
    if(-not(Test-DeploymentEvidenceDocument $evidence.Document $Root $Client $Commit)){throw 'Evidence: project/client/SHA/postcheck mismatch.'}
    $config=Read-DeploymentEvidenceConfig $ConfigPath
    $destination=Get-DeploymentAckPath $Root $Client $Commit $StateDirectory
    $null=Initialize-DeploymentStateDirectory $StateDirectory
    $record=[ordered]@{schema=1;projectRoot=Normalize-Path $Root;client=$Client;commit=$Commit;configHash=$config;result=$evidence.Document.result;evidencePath=$evidence.Path;evidenceHash=$evidence.Hash}
    $json=$record|ConvertTo-Json -Compress
    if($null-ne$Revalidate){$null=& $Revalidate}
    if((Read-DeploymentEvidence $EvidencePath).Hash-cne$evidence.Hash-or(Read-DeploymentEvidenceConfig $ConfigPath)-cne$config){throw 'Evidence changed; nothing recorded.'}
    if(Test-Path -LiteralPath $destination){
        $prior=Read-DeploymentEvidence $destination
        if(($prior.Document|ConvertTo-Json -Compress)-cne$json){throw 'Different acknowledgment exists; original retained.'}
        return $destination
    }
    $temporary=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $created=$false
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream=[IO.File]::Open($temporary,'CreateNew','Write','None');$created=$true
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if($null-ne$Revalidate){$null=& $Revalidate}
        if((Read-DeploymentEvidence $EvidencePath).Hash-cne$evidence.Hash-or(Read-DeploymentEvidenceConfig $ConfigPath)-cne$config){throw 'Evidence changed before publication.'}
        [IO.File]::Move($temporary,$destination)
    }finally{if($created-and[IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    return $destination
}
function Invoke-DeploymentAcknowledgment {
    param([string]$Root,[string]$Client,[string]$Commit,[string]$EvidencePath,[switch]$ReviewConfirmed)
    $log=$null;$stream=$null
    try {
        $state=Join-Path $env:LOCALAPPDATA 'HookMaker/state'
        try {
            $logDir=Join-Path $state 'logs'
            $null=Initialize-DeploymentStateDirectory $logDir
            $logPath=Join-Path $logDir ('CloudflareDeploymentAck_'+[DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss')+'_UTC_'+[guid]::NewGuid().ToString('N')+'.log')
            $stream=[IO.File]::Open($logPath,'CreateNew','Write','Read')
            $log=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false));$log.AutoFlush=$true
            $log.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [INFO] [ACK] Review requested; no provider action.')
        }catch{
            if($null-ne$log){try{$log.Dispose()}catch{};$log=$null}
            elseif($null-ne$stream){try{$stream.Dispose()}catch{}}
            [Console]::Error.WriteLine('Acknowledgment file logging unavailable; no file log claimed.')
        }
        if(-not$ReviewConfirmed){throw 'Independent evidence review required.'}
        $Root=Get-RepositoryPhysicalRoot $Root
        $identity=Get-RepositoryApprovalIdentity $Root
        $expected=(Get-RepositoryIdentityHash ($Commit+'|')).Substring(0,10)
        $revalidate={
            $fresh=Get-RepositoryAccessSnapshot $Root
            $currentIdentity=Get-RepositoryApprovalIdentity $Root
            if($fresh.State-cne'available'-or$fresh.Fingerprint-cne$expected-or$currentIdentity.Identity-cne$identity.Identity-or
                -not[string]::Equals($fresh.RepositoryRoot,$Root,[StringComparison]::OrdinalIgnoreCase)){throw 'Exact clean current repository/SHA required.'}
            $head=Invoke-QuietCommand git @('-C',$Root,'rev-parse','HEAD') -CaptureOutput -Environment $fresh.GitEnvironment -TimeoutSeconds 5
            if($null-eq$head-or$head.ExitCode-ne0-or$head.Output.Trim()-cne$Commit){throw 'Exact current SHA required.'}
        }
        $null=& $revalidate
        $config=Get-DeploymentConfigurationPath $Root
        if($config-eq''){throw 'Deployment configuration missing.'}
        $null=Save-DeploymentAcknowledgment $Root $Client $Commit $config $state $EvidencePath $revalidate
        if($null-ne$log){try{$log.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [INFO] [ACK] Reviewed decision recorded; exit=0; no provider or CI verification.')}catch{[Console]::Error.WriteLine('Acknowledgment recorded; diagnostic file write failed.')}}
        [Console]::Out.WriteLine('Reviewed deployment decision acknowledged; no deploy, provider verification or CI result performed.')
        return 0
    }catch{
        if($null-ne$log){try{$log.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [ERROR] [ACK] Validation/publication refused; originals retained; exit=1.')}catch{[Console]::Error.WriteLine('Acknowledgment diagnostic file write failed.')}}
        [Console]::Error.WriteLine('Acknowledgment refused: verify clean SHA/client, bounded reviewed evidence. Originals retained.')
        return 1
    }finally{if($null-ne$log){try{$log.Dispose()}catch{[Console]::Error.WriteLine('Acknowledgment diagnostic file close failed.')}}}
}
function Test-DeploymentAcknowledgment {
    param([string]$Root,[string]$Client,[string]$Commit,[string]$ConfigPath,[string]$StateDirectory)
    try {
        $record=(Read-DeploymentEvidence (Get-DeploymentAckPath $Root $Client $Commit $StateDirectory)).Document
        $fields=@('schema','projectRoot','client','commit','configHash','result','evidencePath','evidenceHash')
        if(@($record.PSObject.Properties).Count-ne$fields.Count){return $false}
        foreach($field in $fields){if($null-eq$record.PSObject.Properties[$field]){return $false}}
        if(($record.schema-isnot[int]-and$record.schema-isnot[long])-or$record.schema-ne1-or$record.client-cne$Client-or$record.commit-cne$Commit-or
            -not[string]::Equals((Normalize-Path $record.projectRoot),(Normalize-Path $Root),[StringComparison]::OrdinalIgnoreCase)-or
            $record.configHash-cne(Read-DeploymentEvidenceConfig $ConfigPath)){return $false}
        $evidence=Read-DeploymentEvidence $record.evidencePath
        return ($record.evidenceHash-ceq$evidence.Hash-and$record.result-ceq$evidence.Document.result-and(Test-DeploymentEvidenceDocument $evidence.Document $Root $Client $Commit))
    }catch{return $false}
}
