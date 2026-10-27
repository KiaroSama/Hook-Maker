# Input review status is separate from managed payload currency: updating code
# cannot renew a source review and must not create a permanent reinstall loop.
function Get-CiReviewEnrollmentStatus {
    param($Record,[string]$ToolRoot)
    if($Record.friendlyName-cne'Ci-Status-Check'){return @()}
    foreach($client in @(Get-InstalledClientNames $Record)){
        foreach($reviewName in @('_ci-policy.json','_docs-policy.json')){
        $state='missing';$detail=if($reviewName-ceq'_ci-policy.json'){'Use Set-CiWorkloadReview.ps1 after independent source review.'}else{'No documentation input review; automatic conservative analysis applies.'}
        try{
            $sub=Get-ClientSubrecord $Record $client
            $path=Join-Path (Split-Path -Parent $sub.runtimeScript) $reviewName
            if(Test-Path -LiteralPath $path){
                $item=Get-Item -LiteralPath $path -Force
                if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$item.Length-gt65536){throw 'Invalid review file'}
                $policy=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
                $state='legacy-review';$detail='Existing owner review retained; validity is checked by the runtime.'
                if($reviewName-ceq'_docs-policy.json'){
                    $valid=& {
                        param($Root,$Tool,$Policy)
                        . (Join-Path $Tool 'hooks/Ci-Status-Check/_ciclosure.ps1')
                        $deadline=[Diagnostics.Stopwatch]::StartNew()
                        $access=Get-RepositoryAccessSnapshot $Root
                        if($access.State-cne'available'){return $false}
                        function Invoke-DocsGit {
                            param([string[]]$Arguments)
                            $left=[int](5000-$deadline.ElapsedMilliseconds)
                            if($left-lt1){$global:LASTEXITCODE=124;return @()}
                            if($access.GitEnvironment.Count-gt0-and-not(Test-RepositoryRootApproval (Get-RepositoryApprovalIdentity $Root))){$global:LASTEXITCODE=1;return @()}
                            $result=Invoke-QuietCommand git $Arguments -CaptureOutput -Environment $access.GitEnvironment -TimeoutMilliseconds $left
                            if($null-eq$result-or[Text.Encoding]::UTF8.GetByteCount([string]$result.Output)-gt1048576){$global:LASTEXITCODE=124;return @()}
                            $global:LASTEXITCODE=$result.ExitCode
                            $text=[string]$result.Output
                            if($text.EndsWith("`n")){$text=$text.Substring(0,$text.Length-1).TrimEnd([char]"`r")}
                            return @($text-split'\r?\n')
                        }
                        function Invoke-DocsGitQuery {param($Arguments,[switch]$PreserveEmptyLines);Invoke-DocsGit $Arguments}
                        $identity=@(Invoke-DocsGit @('-C',$Root,'rev-parse','HEAD','--abbrev-ref','HEAD'))
                        if($LASTEXITCODE-ne0-or$identity.Count-ne2-or$Policy.schema-notin@(2,3)){return $false}
                        $review=Get-DocsClosureCandidates $Policy
                        if($null-eq$review){return $false}
                        $inputs=@($review.Items|ForEach-Object{[pscustomobject]@{Path=$_.path}})
                        return Test-CiReviewedClosure $Root $Policy.repository $identity[0] $Policy @($Policy.documents) $inputs $identity[1]
                    } $Record.targetProjectRoot $ToolRoot $policy
                    $state=if($valid){'review-bound'}else{'review-required'}
                    $detail=if($valid){'Documentation source/snippets match review; discovery and live CI proof remain runtime checks.'}else{'Documentation source/ref/snippets changed or could not be verified; inspect _docs-policy.json. Updating payload cannot renew review.'}
                }
                if($reviewName-ceq'_ci-policy.json'-and$policy.PSObject.Properties['enrollment']){
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
        }catch{$state='review-required';$detail=if($reviewName-ceq'_ci-policy.json'){'Unreadable or invalid review; preserve it and review using Set-CiWorkloadReview.ps1.'}else{'Unreadable or invalid documentation review; preserve owner input and inspect _docs-policy.json. Payload update cannot renew it.'}}
        if($reviewName-ceq'_ci-policy.json'-or$state-cne'missing'){
            [pscustomobject]@{Client=$client;Status=$state;Detail=$detail;Policy=$reviewName}
        }
        }
    }
}
