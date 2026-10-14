# Cross-host repository-state seam: real Git bytes, dirty paths, real guarded child.
function Invoke-RepositoryFingerprintRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    $work=New-TestWorkspace -Prefix 'hookmaker-repository-fingerprint'
    try {
        $repo=Join-Path $work 'dirty root'; [void][IO.Directory]::CreateDirectory($repo)
        $git=Invoke-QuietCommand -FilePath git -ArgumentList @('-C',$repo,'init','-q','-b','main') -CaptureOutput -TimeoutSeconds 5
        if($git.ExitCode-ne0){throw 'Fingerprint fixture Git init failed.'}
        foreach($pair in @(@('user.email','t@t'),@('user.name','t'),@('core.quotepath','false'))) {
            $git=Invoke-QuietCommand -FilePath git -ArgumentList @('-C',$repo,'config',$pair[0],$pair[1]) -CaptureOutput -TimeoutSeconds 5
            if($git.ExitCode-ne0){throw 'Fingerprint fixture Git config failed.'}
        }
        Write-Utf8 (Join-Path $repo 'readme.txt') 'original'
        $git=Invoke-QuietCommand -FilePath git -ArgumentList @('-C',$repo,'add','.') -CaptureOutput -TimeoutSeconds 5
        if($git.ExitCode-ne0){throw 'Fingerprint fixture Git add failed.'}
        $git=Invoke-QuietCommand -FilePath git -ArgumentList @('-C',$repo,'commit','-q','-m','initial') -CaptureOutput -TimeoutSeconds 5
        if($git.ExitCode-ne0){throw 'Fingerprint fixture Git commit failed.'}
        # Worked ordinal ordering, not a second call to the production sorter.
        $names=@('-a.txt','Z.txt','_a.txt','a-b.txt','ab.txt','z-a.txt',([string][char]0x03A9+'.txt'))
        foreach($name in $names){Write-Utf8 (Join-Path $repo $name) 'dirty'}
        $head=Invoke-QuietCommand -FilePath git -ArgumentList @('-C',$repo,'rev-parse','HEAD') -CaptureOutput -TimeoutSeconds 5
        if($head.ExitCode-ne0){throw 'Fingerprint fixture HEAD unavailable.'}
        $preimage=$head.Output.Trim()+'|'+(($names|ForEach-Object{'?? '+$_})-join'|')
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$expected=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($preimage)))).Replace('-','').ToLowerInvariant().Substring(0,10)}
        finally {$sha.Dispose()}
        $scripts=Join-Path $work 'companion/scripts'
        [void][IO.Directory]::CreateDirectory($scripts)
        Copy-GuardedRunner -RepoRoot $Root -DestinationScriptsDir $scripts
        $probe=Join-Path $work 'snapshot.ps1'
        $probeText=@'
param([string]$Library,[string]$Repository,[string]$Culture,[string]$OutputPath)
$ErrorActionPreference='Stop'
[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($Culture)
. (Join-Path $Library '_processlib.ps1')
. (Join-Path $Library '_repositoryaccess.ps1')
$snapshot=Get-RepositoryAccessSnapshot $Repository
[IO.File]::WriteAllText($OutputPath,($snapshot|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
'@
        Write-Utf8 $probe $probeText
        $producer=''
        foreach($case in @(@('powershell.exe','en-US',(Join-Path $Root 'hooks')),@('pwsh','en-US',$scripts),@('pwsh','tr-TR',$scripts))) {
            $out=Join-Path $work ($case[0]+'-'+$case[1]+'.json')
            $result=Invoke-QuietCommand -FilePath $case[0] -ArgumentList @('-NoProfile','-File',$probe,'-Library',$case[2],'-Repository',$repo,'-Culture',$case[1],'-OutputPath',$out) -CaptureOutput -TimeoutSeconds 12
            $snapshot=Read-JsonFile $out
            $valid=$result.ExitCode-eq0-and$null-ne$snapshot-and$snapshot.State-eq'available'
            Check ($case[0]+'/'+$case[1]+': dirty snapshot matches worked ordinal preimage') ($valid-and$snapshot.Fingerprint-ceq$expected) ($result.Output+$result.ErrorOutput)
            if($case[0]-eq'powershell.exe'-and$valid){$producer=[string]$snapshot.Fingerprint}
        }
        $child=Join-Path $work 'child.ps1';$capture=Join-Path $work 'child-capture.txt';$receipt=Join-Path $work 'receipt.json'
        Write-Utf8 $child "param([string]`$Capture);[IO.File]::WriteAllText(`$Capture,'actual-child',[Text.UTF8Encoding]::new(`$false))"
        $arguments=ConvertTo-Json -InputObject @('-NoProfile','-File',$child,'-Capture',$capture) -Compress
        $result=Invoke-QuietCommand -FilePath pwsh -ArgumentList @('-NoProfile','-File',(Join-Path $scripts 'Run-Tests-Guarded.ps1'),'-WorkingDirectory',$repo,'-FilePath','pwsh','-ArgumentsJson',$arguments,'-ProjectFingerprint',$producer,'-ResultPath',$receipt,'-Quiet','-TimeoutSeconds','20','-IdleTimeoutSeconds','10','-MaxWorkers','1') -CaptureOutput -TimeoutSeconds 30
        $doc=Read-JsonFile $receipt
        Check 'PS5.1 dirty producer binds pwsh companion actual child and receipt' ($result.ExitCode-eq0-and$null-ne$doc-and$doc.overall-eq'ok'-and$doc.projectFingerprint-ceq$expected-and[IO.File]::Exists($capture)-and[IO.File]::ReadAllText($capture,[Text.Encoding]::UTF8)-ceq'actual-child'-and@($doc.leakedProcessIds).Count-eq0) ($result.Output+$result.ErrorOutput)
    }
    finally {if(-not(Remove-TestWorkspace $work)){$script:Fail++}}
}
