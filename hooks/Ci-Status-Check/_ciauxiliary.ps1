# Narrow GitHub-managed CodeQL configuration skips, never project-workload proof.
# All data comes from the invocation's existing bounded REST transport/collections.
function Get-CiAuxiliarySkippedChecks {
    param($Runs,$Checks,[string]$RepoSlug,[string]$Sha,$ValidatedCheckIds)
    $allowed=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenSuites=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $prefix='https://api.github.com/repos/'+$RepoSlug+'/check-runs/'
    foreach($run in @($Runs)) {
        if((Get-Field $run 'path')-cne'dynamic/github-code-scanning/codeql'-or(Get-Field $run 'event')-cne'dynamic'-or
            (Get-Field $run 'status')-cne'completed'-or(Get-Field $run 'conclusion')-cne'success'){continue}
        $suite=[string](Get-Field $run 'check_suite_id')
        if($suite-cnotmatch'^[1-9][0-9]*$'){continue}
        $suiteChecks=@($Checks|Where-Object{[string](Get-Field (Get-Field $_ 'check_suite') 'id')-ceq$suite})
        # Unknown auxiliary runs cause no jobs fetch. Only a candidate skip merits it.
        if(@($suiteChecks|Where-Object{(Get-Field $_ 'conclusion')-ceq'skipped'}).Count-eq0){continue}
        if(-not$seenSuites.Add($suite)){return $null}
        if((Get-Field $run 'head_sha')-cne$Sha-or
            (Get-Field (Get-Field $run 'repository') 'full_name')-ine$RepoSlug-or
            (Get-Field (Get-Field $run 'head_repository') 'full_name')-ine$RepoSlug){return $null}
        $runId=[string](Get-Field $run 'id');$attempt=[string](Get-Field $run 'run_attempt')
        if($runId-cnotmatch'^[1-9][0-9]*$'-or$attempt-cnotmatch'^[1-9][0-9]*$'){return $null}
        $jobsDoc=Read-CiWorkloadCollection -Endpoint ('repos/'+$RepoSlug+'/actions/runs/'+$runId+'/attempts/'+$attempt+'/jobs?per_page=100') -Field jobs
        if($null-eq$jobsDoc){return $null}
        $jobs=@($jobsDoc.jobs)
        if($jobs.Count-lt2-or$jobs.Count-ne$suiteChecks.Count){return $null}
        $jobNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $checkIds=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $analysisCount=0;$configurationCount=0
        foreach($job in $jobs) {
            $name=[string](Get-Field $job 'name')
            if(-not$jobNames.Add($name)-or[string](Get-Field $job 'run_id')-cne$runId-or
                [string](Get-Field $job 'run_attempt')-cne$attempt-or(Get-Field $job 'head_sha')-cne$Sha-or
                (Get-Field $job 'status')-cne'completed'){return $null}
            $url=[string](Get-Field $job 'check_run_url')
            if(-not$url.StartsWith($prefix,[StringComparison]::Ordinal)-or$url.Substring($prefix.Length)-cnotmatch'^[1-9][0-9]*$'){return $null}
            $id=$url.Substring($prefix.Length)
            if(-not$checkIds.Add($id)-or$ValidatedCheckIds.Contains($id)){return $null}
            $matched=@($suiteChecks|Where-Object{[string](Get-Field $_ 'id')-ceq$id})
            if($matched.Count-ne1){return $null}
            $check=$matched[0];$app=Get-Field $check 'app'
            if((Get-Field $check 'url')-cne$url-or(Get-Field $check 'name')-cne$name-or
                (Get-Field $check 'head_sha')-cne$Sha-or(Get-Field $check 'status')-cne'completed'-or
                (Get-Field $check 'conclusion')-cne(Get-Field $job 'conclusion')-or
                (Get-Field $app 'slug')-cne'github-actions'-or
                (Get-Field (Get-Field $app 'owner') 'login')-cne'github'){return $null}
            $end=ConvertTo-CiUtcTime (Get-Field $job 'completed_at')
            if($null-eq$end-or$end-gt[DateTimeOffset]::UtcNow){return $null}
            # Preserve an explicit empty array: Get-Field pipelines it as no output.
            $steps=$null
            if($null-ne$job.PSObject.Properties['steps']){$steps=$job.PSObject.Properties['steps'].Value}
            if($name-ceq'Adjust Configuration') {
                $start=ConvertTo-CiUtcTime (Get-Field $job 'started_at')
                if((Get-Field $job 'conclusion')-cne'skipped'-or$steps-isnot[Array]-or$steps.Count-ne0-or
                    $null-eq$start-or$start-gt[DateTimeOffset]::UtcNow){return $null}
                # GitHub can report this no-execution job ending before it starts.
                # Neither timestamp is used for workload freshness or provenance.
                $configurationCount++
                [void]$allowed.Add($id)
            }
            elseif($name-cmatch'^Analyze \([A-Za-z0-9_+., /-]+\)$') {
                if((Get-Field $job 'conclusion')-cne'success'-or$steps-isnot[Array]-or$steps.Count-eq0){return $null}
                $numbers=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                foreach($step in $steps) {
                    if([string](Get-Field $step 'number')-cnotmatch'^[1-9][0-9]*$'-or-not$numbers.Add([string]$step.number)-or
                        (Get-Field $step 'status')-cne'completed'-or(Get-Field $step 'conclusion')-cnotin@('success','skipped')){return $null}
                }
                $analysis=@($steps|Where-Object{(Get-Field $_ 'name')-ceq'Perform CodeQL Analysis'})
                if($analysis.Count-ne1-or(Get-Field $analysis[0] 'conclusion')-cne'success'){return $null}
                $analysisEnd=ConvertTo-CiUtcTime (Get-Field $analysis[0] 'completed_at')
                if($null-eq$analysisEnd-or$analysisEnd-gt$end){return $null}
                $analysisCount++
            }
            else{return $null}
        }
        if($configurationCount-ne1-or$analysisCount-lt1){return $null}
        foreach($id in $checkIds){[void]$ValidatedCheckIds.Add($id)}
    }
    return ,$allowed
}
