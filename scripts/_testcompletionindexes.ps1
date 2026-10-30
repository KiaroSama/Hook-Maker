# Deterministic candidate visits, not machine-dependent timing thresholds.
function Invoke-CompletionPruningRegression {
    param([string]$Root)
    & {
        param($Root)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_identity.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_evidence.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_recovery.ps1')
        $script:recoveryAssociations = New-Object Collections.Specialized.OrderedDictionary
        $script:recoveryAssociations['pinned'] = [pscustomobject]@{negativeRunId='RUN-0';recoveryRunId='RUN-1';negativeReceipts=@([pscustomobject]@{runId='RUN-2'},[pscustomobject]@{runId='run-3'})}
        $script:pendingNotes = New-Object Collections.Specialized.OrderedDictionary
        $script:LedgerWriteFailed = ''; $script:statePath = 'unused'
        $stateFingerprint = 'current'; $projectKey = 'pathkey'; $preserveOriginals = $false
        $script:PruneVisits = 0
        $supersede = (Get-Command Test-ResultSuperseded).ScriptBlock
        function Test-ResultSuperseded { param($NegDoc,$NegTime,$AllResults) $script:PruneVisits += @($AllResults).Count; & $supersede $NegDoc $NegTime $AllResults }
        function Test-IncidentResolved { param($Key) return $false }
        function Read-JsonFile { param($Path) return [pscustomobject]@{pendingNotes=@()} }
        function Get-Item { param($LiteralPath,[switch]$Force) return [pscustomobject]@{LastWriteTimeUtc=[datetime]::UtcNow.AddDays(-10)} }
        $resultEntries = @(foreach ($i in 0..15) {
            [pscustomobject]@{Path=('result-'+$i);Doc=[pscustomobject]@{runId=('run-'+$i);commandFingerprint=('command-'+$i);projectFingerprint='old';overall='failed';terminated=$false;leakedProcessIds=@();recordedUtc='2026-01-01T00:00:00Z'}}
        })
        $observedEntries = @()
        . (Join-Path $Root 'hooks/Test-Completion-Check/_pruning.ps1')
        Check 'pruning visits only same-command candidates' ($script:PruneVisits-le16) ([string]$script:PruneVisits)
        Check 'retention index preserves singular ignore-case and grouped exact-case pins' (($resultEntries.Path-join',')-ceq'result-0,result-1,result-3') ($resultEntries.Path-join',')
    } $Root
}
function Invoke-CompletionIndexRegression {
    param([string]$Root)
    & {
        param($Root)
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_identity.ps1')
        . (Join-Path $Root 'hooks/Test-Completion-Check/_evidence.ps1')
        $matcher = (Get-Command Test-ResultMatchesObserved).ScriptBlock
        $script:MatchVisits = 0
        function Test-ResultMatchesObserved {
            param($Result,$Observed,$CurrentStateFingerprint)
            $script:MatchVisits++
            & $matcher $Result $Observed $CurrentStateFingerprint
        }
        $results = @(foreach ($i in 0..19) {
            [pscustomobject]@{ Path=('result-'+$i); Doc=[pscustomobject]@{
                runId=('run-'+$i); commandFingerprint=('command-'+$i); projectFingerprint='state'
                startedUtc='2026-01-01T00:00:00Z'; endedUtc='2026-01-01T00:00:01Z'
            } }
        })
        $observed = @(foreach ($i in 0..19) {
            [pscustomobject]@{ Path=('observed-'+$i); Doc=[pscustomobject]@{
                runId=('RUN-'+$i); runIdControlled=($i%2-eq0); commandFingerprint=('COMMAND-'+$i)
                projectFingerprint='state'; observedUtc='2026-01-01T00:00:00Z'
            } }
        })
        $assignment = Get-ObservedResultAssignment $observed $results 'state'
        Check 'assignment visits only matching identity buckets' ($script:MatchVisits-le20) ([string]$script:MatchVisits)
        Check 'indexed assignment preserves all controlled and uncontrolled pairs' ($assignment.Map.Count-eq20-and$assignment.AssignedPaths.Count-eq20)
        $foreign = Get-ObservedResultAssignment $observed $results 'foreign'
        Check 'indexed buckets cannot bypass current-state matcher' ($foreign.Map.Count-eq0)
        $sameResults = @($results[0],$results[0],$results[1])
        $sameResults[1] = [pscustomobject]@{Path='second';Doc=$results[0].Doc}
        $sameObserved = @($observed[0],$observed[0],$observed[0])
        $sameObserved[1] = [pscustomobject]@{Path='uncontrolled';Doc=[pscustomobject]@{runId='other';runIdControlled=$false;commandFingerprint='command-0';projectFingerprint='state';observedUtc='2026-01-01T00:00:00Z'}}
        $sameObserved[2] = [pscustomobject]@{Path='uncontrolled2';Doc=$sameObserved[1].Doc}
        $actual = Get-ObservedResultAssignment $sameObserved $sameResults 'state'
        $controlled = @($actual.SortedObserved | Where-Object { $_.Doc.runIdControlled })[0]
        $chosen = @($actual.Map.Values | ForEach-Object { $_.Path } | Sort-Object)
        Check 'controlled-first assignment retains sorted first result and unique ownership' ($controlled.Path-ceq'observed-0'-and$actual.Map.Count-eq2-and($chosen-join',')-ceq'result-0,second')
        $empty = Get-ObservedResultAssignment @() @() ''
        Check 'empty assignment retains empty map' ($empty.Map.Count-eq0-and$empty.AssignedPaths.Count-eq0)
    } $Root
}
