# Ownership regressions: deterministic PID reuse without recycling a real PID.
# Dot-sourced by Test-TestRunGuard; native child/sentinel coverage runs only in CI.
function Invoke-GuardedOwnershipRegression {
    param([string]$RepoRoot)
    & {
        param($root)
        . (Join-Path $root 'scripts/_guardedprocess.ps1')
        . (Join-Path $root 'hooks/_processtree.ps1')
        $birth = [DateTime]::Parse('2026-10-03T00:00:00Z').ToUniversalTime()
        $roster = @(
            [pscustomobject]@{ ProcessId=120; ParentProcessId=99; CreationDate=$birth },
            [pscustomobject]@{ ProcessId=121; ParentProcessId=120; CreationDate=$birth.AddSeconds(10) },
            [pscustomobject]@{ ProcessId=122; ParentProcessId=121; CreationDate=$birth.AddSeconds(5) },
            [pscustomobject]@{ ProcessId=123; ParentProcessId=122; CreationDate=$birth.AddSeconds(20) },
            [pscustomobject]@{ ProcessId=124; ParentProcessId=121; CreationDate=$birth.AddSeconds(11) })
        $fixture = @{ Queries=0; Kills=(New-Object 'System.Collections.Generic.List[int]'); Live=@{} }
        $missingQuery = $false; $unknownJob = $false; $jobIds = @()
        foreach ($row in $roster) {
            $p = [pscustomobject]@{ Id=[int]$row.ProcessId; StartTime=$row.CreationDate; HasExited=$false; Handle=[IntPtr]::Zero; WorkingSet64=100MB; CPU=1 }
            $p | Add-Member ScriptMethod Kill { [void]$fixture.Kills.Add($this.Id); $this.HasExited=$true }
            $p | Add-Member ScriptMethod Dispose { }
            $fixture.Live[$p.Id]=$p
        }
        function Get-CimInstance { $fixture.Queries++; return $roster }
        function Get-ProcessSnapshot { if ($missingQuery) { return $null }; $fixture.Queries++; return $roster }
        function Get-Process { param($Id) return $fixture.Live[[int]$Id] }
        function taskkill.exe { throw 'PPID taskkill fallback was invoked' }
        function Get-JobOwnedProcessIds { param($JobHandle) return [pscustomobject]@{ Available=(-not $unknownJob); Ids=$jobIds } }
        function Read-OwnedTree {
            param([IntPtr]$Job=[IntPtr]::Zero)
            $splat=@{ RootId=120 }
            $params=(Get-Command Get-OwnedProcessTree).Parameters
            if ($params.ContainsKey('JobHandle')) { $splat.JobHandle=$Job }
            if ($params.ContainsKey('RootCreated')) { $splat.RootCreated=$birth }
            $value=Get-OwnedProcessTree @splat
            if ($null -ne $value -and $null -ne $value.PSObject.Properties['Ids']) { return $value }
            return [pscustomobject]@{ Ids=@($value); Identities=@() }
        }
        $tree=Read-OwnedTree
        Check 'ownership: a stale direct-parent edge excludes its entire foreign subtree' (($tree.Ids -join ',') -eq '120,121,124') ($tree.Ids -join ',')
        $fixture.Live[120].StartTime=$birth.AddSeconds(30)
        $roster[0].CreationDate=$fixture.Live[120].StartTime
        $rejected=$false
        try { $tree=Read-OwnedTree; $rejected=($tree.Ids.Count -eq 0) } catch { $rejected=$true }
        Check 'ownership: a recycled root never authorizes foreign descendants' $rejected
        $fixture.Live[120].StartTime=$birth; $roster[0].CreationDate=$birth
        $missingQuery=$true; $unknown=$false
        try { $null=Read-OwnedTree } catch { $unknown=$true }
        Check 'ownership: an unavailable snapshot is unknown, not a clean root-only sample' $unknown
        $missingQuery=$false
        $job=[IntPtr]::Zero
        $sentinelHandle=[Diagnostics.Process]::GetCurrentProcess()
        try {
            if (-not (Initialize-JobObjectType)) { throw 'Job type unavailable' }
            $job=[HookMaker.JobNative]::CreateKillOnClose()
            if ($job -eq [IntPtr]::Zero) { throw 'Empty test job unavailable' }
            $before=$fixture.Queries; $tree=Read-OwnedTree -Job $job
            $sample=Get-TreeResourceSample -ProcessIds $tree.Ids
            Check 'ownership: an empty Job cannot count the foreign PPID roster' ($tree.Ids.Count -eq 0 -and $sample.MemoryMB -eq 0 -and $fixture.Queries -eq $before) ('ids='+($tree.Ids -join ','))
            $jobIds=@(120)
            $fixture.Live[120].Handle=$sentinelHandle.Handle
            $sampleArgs=@{ ProcessIds=@(120) }
            if ((Get-Command Get-TreeResourceSample).Parameters.ContainsKey('JobHandle')) { $sampleArgs.JobHandle=$job }
            $sample=Get-TreeResourceSample @sampleArgs
            Check 'ownership: a listed PID recycled before sampling cannot count foreign resources' ($sample.Alive -eq 0 -and $sample.MemoryMB -eq 0 -and $sample.CpuSeconds -eq 0)
            $jobIds=@(); $before=$fixture.Queries
            $stopArgs=@{ RootId=120; JobHandle=$job }
            if ((Get-Command Stop-OwnedProcessTree).Parameters.ContainsKey('RootCreated')) { $stopArgs.RootCreated=$birth }
            $stopError=''
            try { $survivors=@(Stop-OwnedProcessTree @stopArgs) } catch { $stopError=$_.Exception.Message; $survivors=@(-1) }
            Check 'ownership: Job cleanup never traverses or kills the foreign PPID roster' ($stopError -eq '' -and $survivors.Count -eq 0 -and $fixture.Kills.Count -eq 0 -and $fixture.Queries -eq $before) $stopError
            $unknownJob=$true; $before=$fixture.Queries; $unknown=$false
            try { $null=Read-OwnedTree -Job $job } catch { $unknown=$true }
            Check 'ownership: failed Job query refuses accounting without PPID fallback' ($unknown -and $fixture.Queries -eq $before)
            $unknown=$false
            try { $null=Stop-OwnedProcessTree @stopArgs } catch { $unknown=$true }
            Check 'ownership: failed Job cleanup query remains unproven without PPID fallback' ($unknown -and $fixture.Queries -eq $before -and $fixture.Kills.Count -eq 0)
        }
        finally { if ($job -ne [IntPtr]::Zero) { [void][HookMaker.JobNative]::Close($job) }; $sentinelHandle.Dispose() }
        foreach ($p in $fixture.Live.Values) { $p.HasExited=$false }
        $tree=Read-OwnedTree
        $fixture.Live[121].StartTime=$birth.AddSeconds(40)
        $sampleArgs=@{ ProcessIds=$tree.Ids }
        if ((Get-Command Get-TreeResourceSample).Parameters.ContainsKey('Identities')) { $sampleArgs.Identities=$tree.Identities }
        $sample=Get-TreeResourceSample @sampleArgs
        Check 'ownership: no-Job sampling rejects a changed birth after enumeration' ($sample.Alive -eq 2 -and $sample.MemoryMB -eq 200) ('alive='+$sample.Alive)
        $fixture.Live[121].StartTime=$birth.AddSeconds(10)
        $stopArgs=@{ RootId=120 }
        if ((Get-Command Stop-OwnedProcessTree).Parameters.ContainsKey('RootCreated')) { $stopArgs.RootCreated=$birth }
        $fixture.Kills.Clear(); $stopError=''
        try { $survivors=@(Stop-OwnedProcessTree @stopArgs) } catch { $stopError=$_.Exception.Message; $survivors=@(-1) }
        Check 'ownership: no-Job cleanup kills identified children first and excludes stale descendants' ($stopError -eq '' -and ($fixture.Kills -join ',') -eq '124,121,120' -and $survivors.Count -eq 0) ('kills='+($fixture.Kills -join ',')+' survivors='+($survivors -join ',')+' error='+$stopError)
    } $RepoRoot
}

Invoke-GuardedOwnershipRegression -RepoRoot $RepoRoot
