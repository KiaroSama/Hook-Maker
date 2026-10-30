# Audit reports pairing, not execution SUCCESS. Existing isolated completion harness.
function Invoke-AuditIndexRegression {
    param([string]$Root,[string]$Work)
    & {
        param($Root,$Work)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_identity.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_evidence.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_audit.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_diagnostic.ps1')
        $script:stateDir=Join-Path $Work 'audit-index';$script:projectKey='fixture'
        [void][IO.Directory]::CreateDirectory($script:stateDir)
        foreach($i in 0..19) {
            $doc=[ordered]@{runId=('run-'+$i);commandFingerprint=('command-'+$i);projectFingerprint='state';runIdControlled=$true;observedUtc='2026-01-01T00:00:00Z';startedUtc='2026-01-01T00:00:00Z';endedUtc='2026-01-01T00:00:01Z';overall='ok';terminated=$false;leakedProcessIds=@()}
            foreach($kind in @('observed','result')) {
                [IO.File]::WriteAllText((Join-Path $script:stateDir ('TestRunGuard-'+$kind+'-fixture-'+$i+'.json')),($doc|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
            }
        }
        $reader=(Get-Command Get-Field).ScriptBlock;$script:AuditRunReads=0
        function Get-Field {param($Object,[string]$Name) if($Name-eq'runId'){$script:AuditRunReads++}; & $reader $Object $Name}
        $path=Join-Path $Work 'indexed-audit.json'
        Export-CompletionEvidenceAudit $path ([pscustomobject]@{ProjectKey='fixture';State='available';RepositoryStateFingerprint='state'})
        $report=Read-JsonFile $path
        Check 'audit avoids repeated whole-result run lookups' ($script:AuditRunReads-le200) ([string]$script:AuditRunReads)
        Check 'indexed audit retains complete hashes and truthful paired rows' ($report.originals.Count-eq40-and$report.observations.Count-eq20-and@($report.observations|Where-Object{$_.pairStatus-ne'PAIRED'-or$_.verdict-ne'UNKNOWN'}).Count-eq0-and$report.gateWaived-eq$false)
        $refused=$false;try{Export-CompletionEvidenceAudit $path ([pscustomobject]@{})}catch{$refused=$true}
        Check 'audit never overwrites an existing report' $refused
        $script:AuditMutationPath=Join-Path $script:stateDir 'TestRunGuard-observed-fixture-0.json'
        $script:AuditMutationDone=$false
        $hashReader=(Get-Command Get-AuditBytesHash).ScriptBlock
        function Get-AuditBytesHash {
            param([byte[]]$Bytes)
            $hash=& $hashReader $Bytes
            if(-not$script:AuditMutationDone) {
                $script:AuditMutationDone=$true
                [IO.File]::AppendAllText($script:AuditMutationPath,' ',[Text.UTF8Encoding]::new($false))
            }
            return $hash
        }
        $changedPath=Join-Path $Work 'changed-audit.json';$refused=$false
        try{Export-CompletionEvidenceAudit $changedPath ([pscustomobject]@{})}catch{$refused=$_.Exception.Message-match'changed concurrently'}
        Check 'concurrent raw-byte change refuses audit publication' ($refused-and-not[IO.File]::Exists($changedPath))
    } $Root $Work
}
function Invoke-AuditAssignmentRegression {
    param([switch]$Codex,[string]$HostExe='pwsh')
    $c=New-IsolatedHookCopy;$p=New-GitRepo ('AuditAssignment-'+$Codex)
    Write-SelectionPair $c $p assigned-good exact-command
    Write-SelectionPair $c $p assigned-failed failed-command -Overall failed
    Write-ObservedRecord -Copy $c -Root $p -RunId unknown-old -CommandFingerprint absent-command -Fingerprint ''
    Write-ObservedRecord -Copy $c -Root $p -RunId uncontrolled -CommandFingerprint one-result -RunIdControlled:$false
    Write-SelectionPair $c $p controlled one-result
    Write-ObservedRecord -Copy $c -Root $p -RunId malformed-active-old -CommandFingerprint recovery-command -AgeMinutes 10
    Write-SelectionPair $c $p malformed-active-new recovery-command
    Write-Utf8 (Get-RunStateFile $c $p active malformed-active-old) '{broken'
    $paths=@(Get-ChildItem (Get-StateDir $c) -Filter 'TestRunGuard-*.json' -File)
    $hashes=@{};foreach($file in $paths){$hashes[$file.FullName]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash}
    $reportPath=Join-Path $Work ('assignment-audit-'+$Codex+'.json')
    $savedLocal=$env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA=$c.LocalAppData
        $out=Invoke-QuietCommand -FilePath $HostExe -ArgumentList @('-NoProfile','-File',$c.Script,'-AuditEvidence','-ProjectRoot',$p,'-AuditPath',$reportPath) -TimeoutSeconds 30
        $exitCode=$LASTEXITCODE
    }finally{$env:LOCALAPPDATA=$savedLocal}
    $report=Read-JsonFile $reportPath
    Check 'read-only assignment audit creates report' ($exitCode-eq0-and$null-ne$report) ($out-join' ')
    if($null-eq$report){return}
    $good=@($report.observations|Where-Object runId -eq assigned-good)
    Check 'assigned clean pair has proven pair status without false matching failure' ($good.Count-eq1-and(Get-Field $good[0] 'pairStatus')-eq'PAIRED'-and$good[0].failedField-eq''-and$good[0].candidateOverall-eq'ok')
    $negative=@($report.observations|Where-Object runId -eq assigned-failed)
    Check 'assigned negative remains historical UNKNOWN with truthful pairing' ($negative.Count-eq1-and(Get-Field $negative[0] 'pairStatus')-eq'PAIRED'-and$negative[0].verdict-eq'UNKNOWN'-and$negative[0].candidateOverall-eq'failed')
    $controlled=@($report.observations|Where-Object runId -eq controlled)
    $uncontrolled=@($report.observations|Where-Object runId -eq uncontrolled)
    Check 'audit honors controlled-first one-to-one receipt assignment' ($controlled.Count-eq1-and$controlled[0].pairStatus-eq'PAIRED'-and$uncontrolled.Count-eq1-and$uncontrolled[0].pairStatus-eq'UNPAIRED')
    $malformed=@($report.observations|Where-Object runId -eq malformed-active-old)
    Check 'malformed active evidence cannot certify historical supersession' ($malformed.Count-eq1-and$malformed[0].verdict-eq'UNKNOWN')
    $unchanged=$true;foreach($file in $paths){if((Get-FileHash $file.FullName -Algorithm SHA256).Hash-ne$hashes[$file.FullName]){$unchanged=$false}}
    Check 'assignment report never grants SUCCESS or changes original bytes' ($unchanged-and$report.gateWaived-eq$false-and@($report.observations|Where-Object verdict -eq SUCCESS).Count-eq0)
}
