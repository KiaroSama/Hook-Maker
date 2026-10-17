# Deterministic clock at the acquisition boundary; Git access/state guards stay real.
function Invoke-RepositoryDeadlineRegression {
    param([string]$Root)
    . (Join-Path $Root 'hooks/_hooklib.ps1')
    $work=New-TestWorkspace -Prefix 'hookmaker-repository-deadline'
    $originalQuery=(Get-Command Invoke-QuietCommand).ScriptBlock
    $originalSnapshot=(Get-Command Get-RepositoryAccessSnapshot).ScriptBlock
    try {
        $repo=Join-Path $work 'bounded root';[void][IO.Directory]::CreateDirectory($repo)
        [void][IO.Directory]::CreateDirectory((Join-Path $repo '.git'))
        $script:AcquisitionClock=[pscustomobject]@{Elapsed=[TimeSpan]::Zero}
        $script:AcquisitionCalls=0;$script:AcquisitionBudgets=@()
        # Substitute only the monotonic clock; no sleeps or host-speed assumptions.
        $text=$originalSnapshot.ToString().Replace('[Diagnostics.Stopwatch]::StartNew()','$script:AcquisitionClock')
        Set-Item Function:Get-RepositoryAccessSnapshot -Value ([scriptblock]::Create($text))
        function Invoke-QuietCommand {
            param($FilePath,$ArgumentList,$TimeoutSeconds,$TimeoutMilliseconds,[switch]$CaptureOutput,$Environment)
            $script:AcquisitionCalls++
            $script:AcquisitionBudgets+=@{Seconds=$TimeoutSeconds;Milliseconds=$TimeoutMilliseconds}
            $cost=if($script:AcquisitionCalls-eq1){1800}else{700}
            if($TimeoutMilliseconds-lt$cost){return [pscustomobject]@{ExitCode=124;Output='';ErrorOutput=''}}
            $script:AcquisitionClock.Elapsed=[TimeSpan]::FromMilliseconds(1800+($script:AcquisitionCalls-1)*700)
            $output=if($ArgumentList-contains'--show-toplevel'){
                if($ArgumentList-contains'HEAD'){$repo+"`nabc123"}else{$repo}
            }elseif($ArgumentList-contains'HEAD'){'abc123'}else{'?? a.txt'}
            return [pscustomobject]@{ExitCode=0;Output=$output;ErrorOutput=''}
        }
        $snapshot=Get-RepositoryAccessSnapshot $repo
        Check 'root and first HEAD share one launch within unchanged total deadline' ($snapshot.State-eq'available'-and$script:AcquisitionCalls-eq4-and$script:AcquisitionBudgets[3].Milliseconds-gt0-and$script:AcquisitionBudgets[3].Milliseconds-le1400)
        foreach($bad in @('root-only','extra','blank-head','wrong-root','changed-head')) {
            $script:AcquisitionClock.Elapsed=[TimeSpan]::Zero
            function Invoke-QuietCommand {
                param($FilePath,$ArgumentList,$TimeoutSeconds,$TimeoutMilliseconds,[switch]$CaptureOutput,$Environment)
                $output=if($ArgumentList-contains'--show-toplevel'){
                    switch($bad){
                        'root-only'{$repo}
                        'extra'{$repo+"`nabc123`nextra"}
                        'blank-head'{$repo+"`n "}
                        'wrong-root'{$work+"`nabc123"}
                        default{$repo+"`nabc123"}
                    }
                }elseif($ArgumentList-contains'HEAD'){if($bad-eq'changed-head'){'different'}else{'abc123'}}else{'?? a.txt'}
                return [pscustomobject]@{ExitCode=0;Output=$output;ErrorOutput=''}
            }
            $refused=Get-RepositoryAccessSnapshot $repo
            $expected=if($bad-eq'wrong-root'){'repositoryRootMismatch'}elseif($bad-eq'changed-head'){'repositoryChanged'}else{'gitFailed'}
            Check ('combined root/HEAD refuses '+$bad) ($refused.State-eq'unavailable'-and$refused.Fingerprint-eq''-and$refused.Diagnosis-eq$expected)
        }
        $oid='a'*40
        foreach($case in @('clean','detached','unknown-header','dirty','dirty-changed','became-dirty','changed-head','missing-oid','duplicate-oid','malformed-oid','initial-oid','v2-timeout')) {
            $script:AcquisitionClock.Elapsed=[TimeSpan]::Zero
            $script:AcquisitionCalls=0;$script:AcquisitionBudgets=@()
            function Invoke-QuietCommand {
                param($FilePath,$ArgumentList,$TimeoutSeconds,$TimeoutMilliseconds,[switch]$CaptureOutput,$Environment)
                $script:AcquisitionCalls++
                $script:AcquisitionBudgets+=@{Milliseconds=$TimeoutMilliseconds}
                # Three launches fit; a redundant fourth clean launch cannot.
                $cost=if($case-in@('dirty','dirty-changed')){700}else{1100}
                if($TimeoutMilliseconds-lt$cost){return [pscustomobject]@{ExitCode=124;Output='';ErrorOutput=''}}
                $script:AcquisitionClock.Elapsed+=[TimeSpan]::FromMilliseconds($cost)
                $output=if($ArgumentList-contains'--show-toplevel'){$repo+"`n"+$oid}
                elseif($ArgumentList-contains'HEAD'){$oid}
                elseif($ArgumentList-contains'--porcelain=v2'){
                    if($case-eq'v2-timeout'){return [pscustomobject]@{ExitCode=124;Output='';ErrorOutput=''}}
                    $headers=@(('# branch.oid '+$oid),'# branch.head main')
                    switch($case){
                        'detached'{$headers[1]='# branch.head (detached)'}
                        'unknown-header'{$headers+='# future.header value'}
                        'became-dirty'{$headers+='? new file.txt'}
                        'changed-head'{$headers[0]='# branch.oid '+('b'*40)}
                        'missing-oid'{$headers=@('# branch.head main')}
                        'duplicate-oid'{$headers+='# branch.oid '+$oid}
                        'malformed-oid'{$headers[0]='# branch.oid invalid'}
                        'initial-oid'{$headers[0]='# branch.oid (initial)'}
                    }
                    $headers-join"`n"
                }elseif($case-in@('dirty','dirty-changed')){
                    if($case-eq'dirty-changed'-and$script:AcquisitionCalls-eq4){'?? after.txt'}else{'?? a.txt'}
                }else{''}
                return [pscustomobject]@{ExitCode=0;Output=$output;ErrorOutput=''}
            }
            $current=Get-RepositoryAccessSnapshot $repo
            if($case-in@('clean','detached','unknown-header')){
                $legacy=(Get-RepositoryIdentityHash ($oid+'|')).Substring(0,10)
                Check ('clean acquisition retains legacy fingerprint with three launches: '+$case) ($current.State-eq'available'-and$current.Fingerprint-ceq$legacy-and$script:AcquisitionCalls-eq3-and$script:AcquisitionBudgets[2].Milliseconds-le1800)
            }elseif($case-eq'dirty'){
                $legacy=(Get-RepositoryIdentityHash ($oid+'|?? a.txt')).Substring(0,10)
                Check 'dirty acquisition retains four-launch legacy preimage without v2 path conversion' ($current.State-eq'available'-and$current.Fingerprint-ceq$legacy-and$script:AcquisitionCalls-eq4)
            }else{
                $diagnosis=if($case-eq'v2-timeout'){'gitTimedOut'}elseif($case-in@('dirty-changed','became-dirty','changed-head')){'repositoryChanged'}else{'gitFailed'}
                Check ('clean optimization refuses '+$case) ($current.State-eq'unavailable'-and$current.Fingerprint-eq''-and$current.Diagnosis-ceq$diagnosis)
            }
        }
        $script:AcquisitionClock.Elapsed=[TimeSpan]::FromMilliseconds(4000);$script:AcquisitionCalls=0
        $expired=Get-RepositoryAccessSnapshot $repo
        Check 'exhausted overall deadline launches no Git child' ($expired.State-eq'unavailable'-and$expired.Diagnosis-eq'gitTimedOut'-and$script:AcquisitionCalls-eq0)
        $script:AcquisitionClock.Elapsed=[TimeSpan]::Zero
        function Invoke-QuietCommand {
            param($FilePath,$ArgumentList,$TimeoutSeconds,$TimeoutMilliseconds,[switch]$CaptureOutput,$Environment)
            $global:LASTEXITCODE=124;return $null
        }
        $timeout=Get-RepositoryAccessSnapshot $repo
        Check 'process-boundary timeout is diagnosed as timeout not missing execution' ($timeout.State-eq'unavailable'-and$timeout.Diagnosis-eq'gitTimedOut')
        Set-Item Function:Invoke-QuietCommand -Value $originalQuery
        $version=Invoke-QuietCommand -FilePath git -ArgumentList @('--version') -CaptureOutput -TimeoutMilliseconds 5000
        Check 'real process accepts explicit millisecond budget and drains UTF8 output' ($null-ne$version-and$version.ExitCode-eq0-and$version.Output-match'^git version')
        $invalid=$false;try{Invoke-QuietCommand -FilePath git -ArgumentList @('--version') -TimeoutMilliseconds 0}catch{$invalid=$true}
        Check 'nonpositive millisecond budget rejected before startup' $invalid
        $stalled=Invoke-QuietCommand -FilePath pwsh -ArgumentList @('-NoProfile','-Command','[Threading.Thread]::Sleep(30000)') -CaptureOutput -TimeoutMilliseconds 250
        Check 'real process returns timeout outcome for subsecond budget' ($null-eq$stalled-and$LASTEXITCODE-eq124)
    }
    finally {
        Set-Item Function:Invoke-QuietCommand -Value $originalQuery
        Set-Item Function:Get-RepositoryAccessSnapshot -Value $originalSnapshot
        if(-not(Remove-TestWorkspace $work)){$script:Fail++}
    }
}
