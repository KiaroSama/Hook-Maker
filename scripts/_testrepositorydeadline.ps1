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
            $script:AcquisitionClock.Elapsed=[TimeSpan]::FromMilliseconds($script:AcquisitionCalls*800)
            $output=if($ArgumentList-contains'--show-toplevel'){$repo}elseif($ArgumentList-contains'HEAD'){'abc123'}else{'?? a.txt'}
            return [pscustomobject]@{ExitCode=0;Output=$output;ErrorOutput=''}
        }
        $snapshot=Get-RepositoryAccessSnapshot $repo
        Check 'fractional final-read budget is usable without extending total deadline' ($snapshot.State-eq'available'-and$script:AcquisitionCalls-eq5-and$script:AcquisitionBudgets[4].Milliseconds-gt0-and$script:AcquisitionBudgets[4].Milliseconds-le1400)
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
