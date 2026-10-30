# Historical accounting reads an existing pin; it never writes a recovery.
function Invoke-RecoveredObservationRegression {
    param([string]$Root,[string]$Work)
    & {
        param($Root,$Work)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_identity.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_recovery.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_evidence.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_runclassify.ps1')
        $script:recoveryAssociations=New-Object Collections.Specialized.OrderedDictionary
        $script:resolvedIncidents=New-Object 'Collections.Generic.List[string]'
        function Test-IncidentResolved { param($Key) return $script:resolvedIncidents.Contains($Key) }
        $obsPairs=New-Object 'Collections.Generic.List[object]';$stateFingerprint='current'
        $path=Join-Path $Work 'recovered-original.json'
        $doc=[pscustomobject]@{runId='original';commandFingerprint='complete-command';projectFingerprint='';overall='failed';exitCode=1;terminated=$false;leakedProcessIds=@();endedUtc='2026-01-01T00:00:01Z'}
        [IO.File]::WriteAllText($path,($doc|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        $hash=(Read-RecoveryReceipt $path).Sha256
        $key=Get-ResultIncidentKey $doc $path
        [void]$script:resolvedIncidents.Add($key)
        $script:recoveryAssociations[$key]=[pscustomobject]@{negativeRunId='original';negativeReceiptSha256=$hash;recoveryRunId='verified-later'}
        $observed=[pscustomobject]@{runId='original';commandFingerprint='complete-command';runIdControlled=$true;observedUtc='2026-01-01T00:00:00Z'}
        $run=[pscustomobject]@{ResultEntry=$null;SameCmdEntry=[pscustomobject]@{Doc=$doc;Path=$path};Observed=$observed}
        Check 'exact controlled legacy observation honors existing audited recovery' (Test-RunNegativeAccounted $run @())
        foreach($case in @('run','command','uncontrolled','pin','note-only','empty-pins','missing','changed')) {
            $observed.runId='original';$observed.commandFingerprint='complete-command';$observed.runIdControlled=$true
            $run.SameCmdEntry=[pscustomobject]@{Doc=$doc;Path=$path}
            $script:recoveryAssociations[$key]=[pscustomobject]@{negativeRunId='original';negativeReceiptSha256=$hash;recoveryRunId='verified-later'}
            switch($case) {
                run {$observed.runId='other'}
                command {$observed.commandFingerprint='other'}
                uncontrolled {$observed.runIdControlled=$false}
                pin {$script:recoveryAssociations[$key].negativeReceiptSha256='0'*64}
                note-only {$script:recoveryAssociations.Clear()}
                empty-pins {$script:recoveryAssociations[$key]=[pscustomobject]@{negativeReceipts=@()}}
                missing {$run.SameCmdEntry=$null}
                changed {[IO.File]::AppendAllText($path,' ',[Text.UTF8Encoding]::new($false))}
            }
            Check ('recovered observation rejects '+$case) (-not(Test-RunNegativeAccounted $run @()))
        }
        Check 'recovered observation never manufactures matched result or new resolution' ($null-eq$run.ResultEntry-and$script:resolvedIncidents.Count-eq1-and$script:recoveryAssociations.Count-eq1)
    } $Root $Work
}
