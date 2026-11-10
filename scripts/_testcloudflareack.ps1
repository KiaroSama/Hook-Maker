# Pure acknowledgment seam; real local files, no deployment or network.
param([switch]$RunRegression)
function Invoke-CloudflareAcknowledgmentRegression {
    param([string]$ToolRoot,[string]$Work)
    $helper=Join-Path $ToolRoot 'hooks/Cloudflare-Deploy/_acknowledgment.ps1'
    if(-not(Test-Path -LiteralPath $helper)){Check 'explicit deployment acknowledgment is available' $false;return}
    . $helper
    $root=Join-Path $Work 'ack-project';[void][IO.Directory]::CreateDirectory($root)
    $state=Join-Path $Work 'ack-state';[void][IO.Directory]::CreateDirectory($state)
    $config=Join-Path $root 'wrangler.toml';[IO.File]::WriteAllText($config,'name="fixture"',[Text.UTF8Encoding]::new($false))
    $sha='a'*40
    $evidence=Join-Path $Work 'deployment-evidence.json'
    $doc=[ordered]@{schema=1;projectRoot=$root;client='claude';commit=$sha;result='deployed';reason='Independently reviewed deployment and health evidence';environment='production';service='fixture';version='fixture-version';postcheck='Exact version routes and health independently verified';verifiedUtc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($evidence,($doc|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $ackPath=Save-DeploymentAcknowledgment $root claude $sha $config $state $evidence
    $originalAck=[IO.File]::ReadAllBytes($ackPath)
    $samePath=Save-DeploymentAcknowledgment $root claude $sha $config $state $evidence
    Check 'identical acknowledgment is idempotent' ($samePath-ceq$ackPath-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($ackPath))-ceq[Convert]::ToBase64String($originalAck))
    Check 'reviewed exact source acknowledgment matches' (Test-DeploymentAcknowledgment $root claude $sha $config $state)
    $badAck=[Text.Encoding]::UTF8.GetString($originalAck)|ConvertFrom-Json
    $badAck.schema='1'
    try{
        [IO.File]::WriteAllText($ackPath,($badAck|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        Check 'tampered acknowledgment schema never suppresses reminder' (-not(Test-DeploymentAcknowledgment $root claude $sha $config $state))
    }finally{[IO.File]::WriteAllBytes($ackPath,$originalAck)}
    $revalidated=$false
    try{$null=Save-DeploymentAcknowledgment $root claude $sha $config $state $evidence {throw 'Changed repository fixture'}}catch{$revalidated=$true}
    Check 'idempotent acknowledgment still revalidates current repository' $revalidated
    $evidenceBytes=[IO.File]::ReadAllBytes($evidence)
    $reviewEvidencePath=$evidence
    $changedDuringReview=$false
    try{
        $null=Save-DeploymentAcknowledgment $root claude $sha $config $state $evidence {
            [IO.File]::AppendAllText($reviewEvidencePath,' ',[Text.Encoding]::UTF8)
        }
    }catch{$changedDuringReview=$true}finally{[IO.File]::WriteAllBytes($evidence,$evidenceBytes)}
    Check 'idempotent acknowledgment refuses evidence changed during revalidation' $changedDuringReview
    $invalidState=Join-Path $Work 'invalid-client-state'
    $invalidClient=$false
    try{$null=Save-DeploymentAcknowledgment $root unknown $sha $config $invalidState $evidence}catch{$invalidClient=$true}
    Check 'invalid client never creates state directory' ($invalidClient-and-not[IO.Directory]::Exists($invalidState))
    $badSchema=$doc|ConvertTo-Json|ConvertFrom-Json
    $badSchema.schema='1'
    Check 'evidence schema requires an integer' (-not(Test-DeploymentEvidenceDocument $badSchema $root claude $sha))
    $linkTarget=Join-Path $Work 'ack-link-target';[void][IO.Directory]::CreateDirectory($linkTarget)
    $link=Join-Path $Work 'ack-link'
    $null=New-Item -ItemType Junction -Path $link -Target $linkTarget
    try{
        $linkedState=Join-Path $link 'new-state'
        $linkRefused=$false
        try{$null=Save-DeploymentAcknowledgment $root claude $sha $config $linkedState $evidence}catch{$linkRefused=$true}
        Check 'linked state refuses before creating a directory outside its boundary' ($linkRefused-and-not[IO.Directory]::Exists((Join-Path $linkTarget 'new-state')))
    }finally{[IO.Directory]::Delete($link)}
    Check 'new source never inherits acknowledgment' (-not(Test-DeploymentAcknowledgment $root claude ('b'*40) $config $state))
    Check 'other client never inherits acknowledgment' (-not(Test-DeploymentAcknowledgment $root codex $sha $config $state))
    $cooldown=Get-Command Get-DeploymentCooldownPath -ErrorAction SilentlyContinue
    $separate=$false
    if($null-ne$cooldown){
        $first=Get-DeploymentCooldownPath $root claude $sha $config $state
        $separate=$first-cne(Get-DeploymentCooldownPath $root claude ('b'*40) $config $state)-and$first-cne(Get-DeploymentCooldownPath $root codex $sha $config $state)
    }
    Check 'reminder cooldown binds exact source and client' $separate
    $rootKey=Get-RepositoryIdentityHash ((Normalize-Path $root).ToLowerInvariant())
    Check 'cooldown carries attributable project identity for complete removal' ([IO.Path]::GetFileName($first)-cmatch('^CloudflareDeploy-cooldown-'+$rootKey+'-claude-'+$sha+'-[a-f0-9]{64}\.txt$'))
    [IO.File]::AppendAllText($evidence,' ',[Text.Encoding]::UTF8)
    Check 'tampered evidence cannot suppress reminder' (-not(Test-DeploymentAcknowledgment $root claude $sha $config $state))
    $conflict=$false;try{$null=Save-DeploymentAcknowledgment $root claude $sha $config $state $evidence}catch{$conflict=$true}
    Check 'conflicting acknowledgment preserves original bytes' ($conflict-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($ackPath))-ceq[Convert]::ToBase64String($originalAck))
    $doc.client='codex';$doc.result='no-ship';$doc.Remove('version');$doc.Remove('postcheck')
    [IO.File]::WriteAllText($evidence,($doc|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $null=Save-DeploymentAcknowledgment $root codex $sha $config $state $evidence
    Check 'explicit no-ship requires no provider evidence' (Test-DeploymentAcknowledgment $root codex $sha $config $state)
    foreach($case in @('unknown','future','missing-postcheck','wrong-root')){
        $invalid=$doc|ConvertTo-Json|ConvertFrom-Json
        $invalid.result='deployed';$invalid|Add-Member version 'fixture';$invalid|Add-Member postcheck 'reviewed'
        switch($case){
            unknown {$invalid.result='unknown'}
            future {$invalid.verifiedUtc=[DateTime]::UtcNow.AddDays(1).ToString('o')}
            missing-postcheck {$invalid.PSObject.Properties.Remove('postcheck')}
            wrong-root {$invalid.projectRoot=Join-Path $root 'foreign'}
        }
        Check ('invalid deployment evidence refuses '+$case) (-not(Test-DeploymentEvidenceDocument $invalid $root codex $sha))
    }
    [IO.File]::AppendAllText($config,'# changed',[Text.Encoding]::UTF8)
    Check 'changed deployment configuration invalidates acknowledgment' (-not(Test-DeploymentAcknowledgment $root codex $sha $config $state))
}
# Reuse the existing real Git/bounded hook harness; all state stays in its fixture.
function Invoke-CloudflareAcknowledgmentCliRegression {
    param([string]$HookPath,[string]$Work)
    foreach($hostName in @('pwsh','powershell.exe')){
        $tag=if($hostName-eq'pwsh'){'ps7'}else{'ps5'}
        $root=New-ReadyWorkersRepo ('AckCli-'+$tag+' space')
        $sha=([string](& git -C $root rev-parse HEAD)).Trim()
        $evidence=Join-Path $Work ('ack-cli-'+$tag+'.json')
        $doc=[ordered]@{schema=1;projectRoot=$root;client='claude';commit=$sha;result='deployed';reason='Reviewed inert fixture evidence';environment='staging';service='fixture';version='fixture-v1';postcheck='Fixture health and version reviewed';verifiedUtc=[DateTime]::UtcNow.ToString('o')}
        Write-Utf8 $evidence ($doc|ConvertTo-Json)
        $out=Join-Path $Work ('ack-cli-'+$tag+'.out');$err=Join-Path $Work ('ack-cli-'+$tag+'.err')
        $arguments=@('-NoProfile','-NonInteractive','-File',$HookPath,'-Acknowledge','-ProjectRoot',$root,'-Client','claude','-Commit',$sha,'-EvidencePath',$evidence,'-ReviewConfirmed')
        $savedLocal=$env:LOCALAPPDATA
        $savedClient=$env:HOOKMAKER_CLIENT
        $savedClaudeProject=$env:CLAUDE_PROJECT_DIR
        try{
            Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
            $env:LOCALAPPDATA=$FakeLocalAppData;$env:HOOKMAKER_CLIENT='unknown'
            $unknown=Fire -Cwd $root -SessionId ('ack-unknown-'+$tag) -Exe $hostName
            Check ($tag+': unknown client stays silent without an acknowledgment or cooldown') ($unknown.Exit-eq0-and$unknown.Out-eq''-and$unknown.Err-eq'') ($unknown.Out+$unknown.Err)
            $env:HOOKMAKER_CLIENT='claude'
            $result=Start-BoundedProcess -FilePath $hostName -ArgumentList $arguments -TimeoutMs 30000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ($tag+': actual acknowledgment CLI accepts reviewed exact source') ($result.ExitCode-eq0) ([IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)+[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8))
            $repeat=Fire -Cwd $root -SessionId ('ack-repeat-'+$tag) -Exe $hostName
            Check ($tag+': acknowledged source stays silent in another session') ($repeat.Exit-eq0-and$repeat.Out-eq''-and$repeat.Err-eq'') ($repeat.Out+$repeat.Err)
            [IO.File]::AppendAllText($evidence,' ',[Text.Encoding]::UTF8)
            $tamper=Fire -Cwd $root -SessionId ('ack-tampered-'+$tag) -Exe $hostName
            Check ($tag+': changed evidence restores reminder') ($tamper.Out-match'CLOUDFLARE DEPLOY CHECK') ($tamper.Out+$tamper.Err)
            Write-Utf8 (Join-Path $root 'source.txt') 'next source'
            Add-Commit $root 'next';$null=& git -C $root push -q
            $next=Fire -Cwd $root -SessionId ('ack-new-sha-'+$tag) -Exe $hostName
            Check ($tag+': new SHA bypasses previous SHA cooldown') ($next.Out-match'CLOUDFLARE DEPLOY CHECK') ($next.Out+$next.Err)
            $wrong=Start-BoundedProcess -FilePath $hostName -ArgumentList $arguments -TimeoutMs 30000 -RedirectStandardOutput $out -RedirectStandardError $err
            Check ($tag+': acknowledgment refuses old SHA without deployment') ($wrong.ExitCode-ne0)
            $nextSha=([string](& git -C $root rev-parse HEAD)).Trim()
            $doc.commit=$nextSha;$doc.client='codex';$doc.result='no-ship';$doc.Remove('version');$doc.Remove('postcheck')
            Write-Utf8 $evidence ($doc|ConvertTo-Json)
            $noShip=@('-NoProfile','-NonInteractive','-File',$HookPath,'-Acknowledge','-ProjectRoot',$root,'-Client','codex','-Commit',$nextSha,'-EvidencePath',$evidence,'-ReviewConfirmed')
            $recorded=Start-BoundedProcess -FilePath $hostName -ArgumentList $noShip -TimeoutMs 30000 -RedirectStandardOutput $out -RedirectStandardError $err
            $env:HOOKMAKER_CLIENT='codex'
            $silent=Fire -Cwd $root -SessionId ('no-ship-'+$tag) -Exe $hostName
            Check ($tag+': explicit no-ship CLI suppresses only its client') ($recorded.ExitCode-eq0-and$silent.Out-eq''-and$silent.Err-eq'') ($silent.Out+$silent.Err)
            $logs=@(Get-ChildItem (Join-Path $FakeLocalAppData 'HookMaker/state/logs') -Filter 'CloudflareDeploymentAck_*.log' -File)
            Check ($tag+': acknowledgment diagnostics are retained without evidence bodies') ($logs.Count-ge3-and@($logs|Where-Object{[IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8)-match'Fixture health|fixture-v1'}).Count-eq0)
        }finally{$env:LOCALAPPDATA=$savedLocal;$env:HOOKMAKER_CLIENT=$savedClient;$env:CLAUDE_PROJECT_DIR=$savedClaudeProject}
    }
}
if($RunRegression){
    Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '../hooks/_hooklib.ps1')
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0;$work=New-TestWorkspace -Prefix 'deployment-ack-seam'
    try{Invoke-CloudflareAcknowledgmentRegression (Split-Path -Parent $PSScriptRoot) $work}
    finally{if(-not(Remove-TestWorkspace $work)){$script:Fail++}}
    Write-Output "Passed: $script:Pass Failed: $script:Fail";exit $script:Fail
}
