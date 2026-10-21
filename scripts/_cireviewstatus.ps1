# Input review status is separate from managed payload currency: updating code
# cannot renew a source review and must not create a permanent reinstall loop.
function Get-CiReviewEnrollmentStatus {
    param($Record,[string]$ToolRoot)
    if($Record.friendlyName-cne'Ci-Status-Check'){return @()}
    foreach($client in @(Get-InstalledClientNames $Record)){
        $state='missing';$detail='Use Set-CiWorkloadReview.ps1 after independent source review.'
        try{
            $sub=Get-ClientSubrecord $Record $client
            $path=Join-Path (Split-Path -Parent $sub.runtimeScript) '_ci-policy.json'
            if(Test-Path -LiteralPath $path){
                $item=Get-Item -LiteralPath $path -Force
                if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$item.Length-gt65536){throw 'Invalid review file'}
                $policy=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
                $state='legacy-review';$detail='Existing owner review retained; validity is checked by the runtime.'
                if($policy.PSObject.Properties['enrollment']){
                    $valid=& {
                        param($Root,$Tool,$Policy)
                        $Enrollment=$Policy.enrollment
                        . (Join-Path $Tool 'hooks/Ci-Status-Check/_cienrollment.ps1')
                        $deadline=[DateTime]::UtcNow.AddSeconds(5)
                        $access=Get-RepositoryAccessSnapshot $Root
                        if($access.State-cne'available'){return $false}
                        function Invoke-DocsGit {
                            param([string[]]$Arguments)
                            $left=[int][Math]::Floor(($deadline-[DateTime]::UtcNow).TotalMilliseconds)
                            if($left-lt1){$global:LASTEXITCODE=124;return @()}
                            if($access.GitEnvironment.Count-gt0-and-not(Test-RepositoryRootApproval (Get-RepositoryApprovalIdentity $Root))){$global:LASTEXITCODE=1;return @()}
                            $result=Invoke-QuietCommand git $Arguments -CaptureOutput -Environment $access.GitEnvironment -TimeoutMilliseconds $left
                            if($null-eq$result){$global:LASTEXITCODE=124;return @()}
                            $global:LASTEXITCODE=$result.ExitCode
                            return @($result.Output-split'\r?\n'|Where-Object{$_-ne''})
                        }
                        (Test-CiEnrollmentBinding $Enrollment $Root $Enrollment.repository $Enrollment.commit $Enrollment.branch)-and
                            $Enrollment.reviewFingerprint-ceq(Get-CiReviewedInputFingerprint $Policy)
                    } $Record.targetProjectRoot $ToolRoot $policy
                    $state=if($valid){'context-current'}else{'review-required'}
                    $detail=if($valid){'Enrolled context matches; live CI proof remains separate.'}else{'Source/root/remote/ref changed or unavailable; review again using Set-CiWorkloadReview.ps1. Updating payload cannot renew review.'}
                }
            }
        }catch{$state='review-required';$detail='Unreadable or invalid review; preserve it and review using Set-CiWorkloadReview.ps1.'}
        [pscustomobject]@{Client=$client;Status=$state;Detail=$detail}
    }
}
