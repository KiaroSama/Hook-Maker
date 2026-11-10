# Selection diagnostics use controlled codes, never runtime exception contents.
param([switch]$RunRegression)
function Invoke-CiReviewDiagnosticRegression {
    param([string]$ToolRoot)
    & {
        . (Join-Path $ToolRoot 'scripts/_ciworkloadreview.ps1')
        function Get-InstallRecordById { param($ToolRoot,$Id) return $script:DiagnosticRecord }
        function Test-InstallRecordValid { param($Record) return [pscustomobject]@{Ok=($script:DiagnosticCase-cne'record-invalid')} }
        function Normalize-Path { param($Path) return $Path }
        function Get-InstallIntegrity { param($Record,$ToolRoot) return $script:DiagnosticIntegrity }
        $script:DiagnosticRecord=$null
        $cases=@(
            @{Code='record-missing';Record=$null;Detail=''},
            @{Code='record-invalid';Record=$true;Detail=''},
            @{Code='identity-changed';Record=$true;Detail=''},
            @{Code='client-missing';Record=$true;Detail=''},
            @{Code='source-stale';Record=$true;Detail='source changed: private-value'},
            @{Code='registration-stale';Record=$true;Detail='registration drifted (private-value)'},
            @{Code='payload-stale';Record=$true;Detail='installed file modified: private-value'}
        )
        foreach($directCode in @('record-invalid','identity-changed','runtime-busy','policy-mismatch')){
            $caught=$null;try{Stop-CiReview $directCode}catch{$caught=$_}
            $message=Get-CiReviewFailureMessage $caught validation $ToolRoot '0123456789' claude
            Check ('typed refusal remains actionable '+$directCode) ($message.Contains('['+$directCode+']')-and$message.Contains('preserved')-and$message-notmatch'private-value') $message
        }
        foreach($case in $cases){
            $script:DiagnosticCase=$case.Code
            $script:DiagnosticRecord=if($null-eq$case.Record){$null}else{[pscustomobject]@{scope='project';friendlyName='Ci-Status-Check';toolRoot=$ToolRoot;sourceScript=Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'}}
            $script:DiagnosticIntegrity=[pscustomobject]@{Components=@([pscustomobject]@{Name='claude';Status='update';Detail=$case.Detail})}
            if($case.Code-ceq'identity-changed'){$script:DiagnosticRecord.scope='global'}
            if($case.Code-ceq'client-missing'){$script:DiagnosticIntegrity.Components=@()}
            $caught=$null
            try{$null=Get-CiReviewSelection $ToolRoot '0123456789' claude}catch{$caught=$_}
            $code=if($null-ne$caught){[string]$caught.Exception.Data['HookMakerReviewCode']}else{''}
            Check ('selection stable cause '+$case.Code) ($code-ceq$case.Code) $code
            $formatter=Get-Command Get-CiReviewFailureMessage -ErrorAction SilentlyContinue
            $message=if($null-ne$formatter){Get-CiReviewFailureMessage $caught selection $ToolRoot '0123456789' claude}else{''}
            Check ('selection sanitized repair '+$case.Code) ($message-match[regex]::Escape($case.Code)-and$message-notmatch'private-value'-and$message-match'0123456789'-and$message-match'claude'-and$message-match'preserved') $message
        }
    }
}
if($RunRegression){
    Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop'
    . (Join-Path $PSScriptRoot '_testlib.ps1')
    $script:Pass=0;$script:Fail=0
    Invoke-CiReviewDiagnosticRegression (Split-Path -Parent $PSScriptRoot)
    Write-Output "Passed: $script:Pass Failed: $script:Fail"
    exit $script:Fail
}
