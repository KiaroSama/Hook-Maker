# Pure receipt trust boundary: external observations are fixtures, never real state.
function Invoke-CiProvenanceRegression {
    param([string]$HooksRoot)
    $helper=Join-Path $HooksRoot '_ciprovenance.ps1'
    if(Test-Path -LiteralPath $helper){. $helper}
    $now=[DateTimeOffset]::UtcNow
    $sha='a'*40
    $receipt=[ordered]@{
        schema=1; repository='owner/repo'; sha=$sha; outcome='ci-green'
        observedUtc=$now.ToString('o'); completedUtc=$now.AddMinutes(-1).ToString('o')
        workloadFingerprint=('b'*64); sourceFingerprint=('c'*64)
        runs=@(@{id=7;attempt=2;workflowId=9;path='.github/workflows/ci.yml';event='workflow_dispatch';branch='main';completedUtc=$now.AddMinutes(-1).ToString('o')})
    }
    foreach($case in @('valid','legacy','wrong-repo','wrong-sha','wrong-schema','future','stale','old-execution','docs','missing-workload','missing-runs','duplicate-run')) {
        $copy=($receipt|ConvertTo-Json -Depth 8 -Compress)|ConvertFrom-Json
        switch($case){
            'wrong-repo'{$copy.repository='other/repo'}
            'wrong-sha'{$copy.sha='d'*40}
            'wrong-schema'{$copy.schema=0}
            'future'{$copy.observedUtc=$now.AddMinutes(2).ToString('o')}
            'stale'{$copy.observedUtc=$now.AddMinutes(-61).ToString('o')}
            'old-execution'{$copy.completedUtc=$now.AddHours(-2).ToString('o');$copy.runs[0].completedUtc=$copy.completedUtc}
            'docs'{$copy.outcome='docs-only-carryover'}
            'missing-workload'{$copy.workloadFingerprint=''}
            'missing-runs'{$copy.runs=@()}
            'duplicate-run'{$copy.runs=@($copy.runs[0],$copy.runs[0])}
        }
        $observedText=if($copy.observedUtc-is[DateTime]){$copy.observedUtc.ToUniversalTime().ToString('o')}else{[string]$copy.observedUtc}
        $lines=@($sha,'verified',$observedText,'ci-green',($copy|ConvertTo-Json -Depth 8 -Compress))
        if($case-eq'legacy'){$lines=$lines[0..3]}
        $accepted=$false
        try{$accepted=$null-ne(Read-CiProvenance -Lines $lines -Repository 'owner/repo' -Sha $sha -FailureEndedUtc $now.AddMinutes(-30).UtcDateTime)}catch{}
        Check ('CI provenance '+$case) ($accepted-eq($case-eq'valid'))
    }
    $carry=[ordered]@{schema=1;repository='owner/repo';sha=$sha;parent=('d'*40);outcome='docs-only-carryover';observedUtc=$now.ToString('o');sourceFingerprint=('c'*64)}
    foreach($case in @('valid','legacy','wrong-repo','wrong-sha','wrong-schema','future','stale','wrong-source')){
        $copy=($carry|ConvertTo-Json)|ConvertFrom-Json
        switch($case){
            'wrong-repo'{$copy.repository='other/repo'}
            'wrong-sha'{$copy.sha='e'*40}
            'wrong-schema'{$copy.schema=0}
            'future'{$copy.observedUtc=$now.AddMinutes(2).ToString('o')}
            'stale'{$copy.observedUtc=$now.AddMinutes(-2).ToString('o')}
            'wrong-source'{$copy.sourceFingerprint=''}
        }
        $observed=if($copy.observedUtc-is[DateTime]){$copy.observedUtc.ToUniversalTime().ToString('o')}else{[string]$copy.observedUtc}
        $lines=@($sha,'verified',$observed,'docs-only-carryover',('d'*40),($copy|ConvertTo-Json -Compress))
        if($case-eq'legacy'){$lines=$lines[0..4]}
        $accepted=$null-ne(Read-CiCarryover -Lines $lines -Repository owner/repo -Sha $sha)
        Check ('carryover provenance '+$case) ($accepted-eq($case-eq'valid'))
        Check ('carryover never clears failed tests '+$case) ($null-eq(Read-CiProvenance -Lines $lines -Repository owner/repo -Sha $sha -FailureEndedUtc $now.AddMinutes(-30)))
        if($case-eq'stale'){Check 'stale notice identity is only deduplication after fresh revalidation' ($null-ne(Read-CiCarryover -Lines $lines -Repository owner/repo -Sha $sha -NoticeIdentityOnly))}
    }
}
