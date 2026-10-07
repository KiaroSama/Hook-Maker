param([Parameter(Mandatory=$true)][string]$ProjectRoot,[switch]$Approve,[switch]$Revoke,[switch]$Status,[switch]$OwnerConfirmed)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'hooks/_repositorytrust.ps1')
$writer=$null;$exitCode=0
try {
    $logDir=Join-Path $root 'logs';[void][IO.Directory]::CreateDirectory($logDir)
    $name='Set-RepositoryTrust_'+[DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss')+'_UTC.log'
    $path=Join-Path $logDir $name
    if([IO.File]::Exists($path)){$path=Join-Path $logDir ($name.Replace('.log','_'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.log'))}
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $writer=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding $false));$writer.AutoFlush=$true
    $writer.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [INFO] [TRUST] Started runtime='+$PSVersionTable.PSVersion+' pid='+$PID)
} catch {[Console]::Error.WriteLine('Repository trust logging unavailable; proceeding with console diagnostics only.')}
try {
    if(@(@($Approve,$Revoke,$Status)|Where-Object{$_}).Count-ne1){throw 'Choose exactly one of -Approve, -Revoke or -Status.'}
    $identity=Get-RepositoryApprovalIdentity $ProjectRoot
    if($Status){$state=if(Test-RepositoryRootApproval $identity){'approved'}else{'not-approved'}}
    else {Set-RepositoryRootApproval -ProjectRoot $ProjectRoot -Approve:$Approve -Revoke:$Revoke -OwnerConfirmed:$OwnerConfirmed;$state=if($Approve){'approved'}else{'revoked'}}
    $message='Repository approval '+$state+'; exact root='+$identity.Root+'. Global Git configuration and repository contents unchanged.'
    if($writer){$writer.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [INFO] [TRUST] '+$message)}
    [Console]::Out.WriteLine($message)
} catch {
    $exitCode=3;$message=$_.Exception.Message
    if($writer){$writer.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [ERROR] [TRUST] '+$message)}
    [Console]::Error.WriteLine($message)
} finally {
    if($writer){$writer.WriteLine('['+[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' UTC] [INFO] [TRUST] Finished exitCode='+$exitCode);$writer.Dispose()}
}
exit $exitCode
