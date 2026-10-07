# Audit reports pairing, not execution SUCCESS. Existing isolated completion harness.
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
