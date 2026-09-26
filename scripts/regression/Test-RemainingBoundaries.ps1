param([string]$SourceRoot = '', [string]$ResultPath = '', [switch]$Baseline)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($SourceRoot -eq '') { $SourceRoot = $repo }
. (Join-Path $repo 'scripts\_testlib.ps1')
. (Join-Path $SourceRoot 'hooks\_processtree.ps1')
. (Join-Path $SourceRoot 'scripts\_installruntimepayload.ps1')
$work = New-TestWorkspace -Prefix 'hookmaker-remaining-boundaries'
$cases = New-Object 'System.Collections.Generic.List[object]'
$fixtureProcesses = New-Object 'System.Collections.Generic.List[object]'
function Check-Boundary {
    param([string]$Name, [scriptblock]$Assertion, [bool]$OldFails = $false)
    $passed = $false; $errorText = ''
    try { $passed = [bool](& $Assertion) } catch { $errorText = $_.Exception.Message }
    $expected = -not ($Baseline -and $OldFails)
    $unexpected = ($passed -ne $expected -or $errorText -ne '')
    [void]$cases.Add([pscustomobject]@{ name=$Name; passed=$passed; expected=$expected; unexpected=$unexpected; error=$errorText })
    $level = if ($unexpected) { 'ERROR' } else { 'INFO' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' passed=' + $passed + ' ' + $errorText)
}
$baseTime = [datetime]'2026-09-20T10:00:00Z'
function New-Node {
    param([int]$Id, [int]$Parent, $Minute)
    return [pscustomobject]@{ ProcessId=$Id; ParentProcessId=$Parent; CreationDate=$(if ($null -eq $Minute) { $null } else { $baseTime.AddMinutes($Minute) }) }
}
try {
    Check-Boundary 'C01 normal child and grandchild are retained' {
        $v = Get-OwnedDescendantId 100 $baseTime @((New-Node 100 1 0),(New-Node 101 100 1),(New-Node 102 101 2))
        (@($v.Ids) -join ',') -ceq '101,102' -and -not $v.Truncated
    }
    Check-Boundary 'C02 grandchild older than its DIRECT parent is excluded' {
        $v = Get-OwnedDescendantId 100 $baseTime @((New-Node 100 1 0),(New-Node 101 100 10),(New-Node 102 101 5))
        (@($v.Ids) -join ',') -ceq '101'
    } $true
    Check-Boundary 'C03 missing descendant identity is partial, not kill authority' {
        $v = Get-OwnedDescendantId 100 $baseTime @((New-Node 100 1 0),(New-Node 101 100 $null))
        @($v.Ids).Count -eq 0 -and $v.Truncated
    } $true
    Check-Boundary 'C04 an exact-depth leaf is complete, not false truncation' {
        $nodes = @((New-Node 100 1 0)); foreach ($n in 1..8) { $nodes += New-Node (100+$n) (99+$n) $n }
        $v = Get-OwnedDescendantId 100 $baseTime $nodes
        @($v.Ids).Count -eq 8 -and -not $v.Truncated
    } $true
    Check-Boundary 'C05 mismatched root identity cannot authorize a new tree' {
        $v = Get-OwnedDescendantId 100 $baseTime @((New-Node 100 1 10),(New-Node 101 100 11))
        @($v.Ids).Count -eq 0 -and $v.Truncated
    } $true
    Check-Boundary 'C06 access denied is not evidence that a process is gone' {
        & {
            function Get-Process { param($Id,$ErrorAction) throw [UnauthorizedAccessException]::new('test-owned metadata denial') }
            -not (Test-ProcessGone 999)
        }
    } $true
    Check-Boundary 'C07 self-root cleanup never enumerates or acts on child processes' {
        & {
            $script:cleanupQueries = 0
            function Get-ProcessSnapshot { param($TimeoutSeconds) $script:cleanupQueries++; return $null }
            $v = Stop-ProcessTree -ProcessId $PID -TimeoutMilliseconds 1000
            $script:cleanupQueries -eq 0 -and -not $v.Cleared
        }
    } $true
    Check-Boundary 'C08 a genuinely absent PID is recognized as absent' { Test-ProcessGone -ProcessId 2147483646 }
    Check-Boundary 'C09 a cycle is bounded and never contains its own root' {
        $v = Get-OwnedDescendantId 100 $baseTime @((New-Node 100 101 0),(New-Node 101 100 1))
        @($v.Ids).Count -eq 1 -and @($v.Ids) -notcontains 100
    }
    Check-Boundary 'C10 deeper-than-bound graph explicitly reports partial coverage' {
        $nodes = @((New-Node 100 1 0)); foreach ($n in 1..20) { $nodes += New-Node (100+$n) (99+$n) $n }
        $v = Get-OwnedDescendantId 100 $baseTime $nodes
        $v.Truncated -and @($v.Ids).Count -le 8
    }

    # Only these two test-owned, self-expiring processes can be targeted by the
    # deliberately stale snapshot. Never borrow a real user's process identity.
    $exe = (Get-Process -Id $PID).Path
    $rootChild = Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 45') -PassThru -WindowStyle Hidden
    [void]$fixtureProcesses.Add($rootChild)
    $otherChild = Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 45') -PassThru -WindowStyle Hidden
    [void]$fixtureProcesses.Add($otherChild)
    $null = $rootChild.Handle; $null = $otherChild.Handle
    $rootStart = $rootChild.StartTime.ToUniversalTime()
    $script:staleProcessSnapshot = @(
        [pscustomobject]@{ProcessId=$rootChild.Id;ParentProcessId=$PID;CreationDate=$rootStart},
        [pscustomobject]@{ProcessId=$otherChild.Id;ParentProcessId=$rootChild.Id;CreationDate=$otherChild.StartTime.ToUniversalTime().AddMinutes(2)}
    )
    $v = & {
        function Get-ProcessSnapshot { param($TimeoutSeconds) return $script:staleProcessSnapshot }
        Stop-ProcessTree -ProcessId $rootChild.Id -TimeoutMilliseconds 5000
    }
    Check-Boundary 'C11 a changed PID identity between snapshot and kill is preserved' { -not $otherChild.HasExited } $true
    Check-Boundary 'C12 the actually owned root was terminated' { $rootChild.WaitForExit(1000) }

    # The process query itself being unavailable is a REAL outcome, not an error:
    # cleanup falls back to the one process it can address directly and reports
    # partial coverage. It must never read as a cleared tree, and it must never
    # fall back to matching by process name, which cannot tell ours from anyone's.
    $snapshotless = Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 45') -PassThru -WindowStyle Hidden
    [void]$fixtureProcesses.Add($snapshotless)
    $null = $snapshotless.Handle
    $vNoSnap = & {
        function Get-ProcessSnapshot { param($TimeoutSeconds) return $null }
        Stop-ProcessTree -ProcessId $snapshotless.Id -TimeoutMilliseconds 5000
    }
    Check-Boundary 'C13 an unavailable process query still terminates the owned root' { $snapshotless.WaitForExit(1000) }
    Check-Boundary 'C14 and reports partial coverage rather than a cleared tree' {
        $vNoSnap.Truncated -and -not $vNoSnap.Cleared
    }

    # Exercise the actual payload producer with an isolated complete checkout,
    # observing whether it contributes any artifact before refusing damage.
    $tool = Join-Path $work 'tool'; [void][IO.Directory]::CreateDirectory((Join-Path $tool 'hooks'))
    [void][IO.Directory]::CreateDirectory((Join-Path $tool 'scripts'))
    $leaves = @('_hooklib.ps1','_stoplib.ps1','_evidencelib.ps1','_taskidentity.ps1','_processtree.ps1','_deliverylib.ps1','_scope.ps1')
    # The shared set grew with the gate receipts; a baseline subject predates them.
    if ([IO.File]::Exists((Join-Path $SourceRoot 'hooks/_gatereceipts.ps1'))) { $leaves += '_gatereceipts.ps1' }
    if ([IO.File]::Exists((Join-Path $SourceRoot 'hooks/_replylanguage.ps1'))) { $leaves += '_replylanguage.ps1' }
    foreach ($leaf in $leaves) { Copy-Item -LiteralPath (Join-Path $SourceRoot ('hooks/'+$leaf)) -Destination (Join-Path $tool ('hooks/'+$leaf)) }
    function New-PlanArtifact { param($RelativePath,$Kind,$SourcePath) return [pscustomobject]@{Path=$RelativePath;Source=$SourcePath} }
    function Add-Artifact { param($Artifact) [void]$script:payload.Add($Artifact) }
    $script:payload = New-Object 'System.Collections.Generic.List[object]'
    Add-SharedRuntimeLibraryArtifacts -ToolRoot $tool -FriendlyName 'Fixture'
    Check-Boundary 'I01 a complete source set still produces the exact shared library set' {
        $script:payload.Count -eq $leaves.Count -and (@($script:payload | ForEach-Object { [IO.Path]::GetFileName($_.Path) } | Sort-Object) -join '|') -ceq (@($leaves|Sort-Object) -join '|')
    }
    foreach ($leaf in $leaves) {
        $path = Join-Path $tool ('hooks/'+$leaf); $bytes = [IO.File]::ReadAllBytes($path)
        foreach ($damage in @('missing','empty')) {
            if ($damage -eq 'missing') { [IO.File]::Delete($path) } else { [IO.File]::WriteAllBytes($path,[byte[]]@()) }
            $script:payload.Clear(); $caught = ''
            try { Add-SharedRuntimeLibraryArtifacts -ToolRoot $tool -FriendlyName 'Fixture' } catch { $caught=$_.Exception.Message }
            # The old delivery-specific guard refused a missing file only after
            # contributing the preceding artifacts, so its transaction also fails.
            Check-Boundary ('I02 '+$damage+' '+$leaf+' rejects before producing partial artifacts') {
                $caught -match [regex]::Escape($leaf) -and $script:payload.Count -eq 0
            } $true
            [IO.File]::WriteAllBytes($path,$bytes)
        }
    }
    $script:payload.Clear(); $caught = ''
    try { Add-CompanionRuntimeArtifacts -ToolRoot $tool -FriendlyName 'Test-Run-Guard' } catch { $caught=$_.Exception.Message }
    Check-Boundary 'I03 missing guarded runner is rejected, not silently omitted' { $caught -match 'Run-Tests-Guarded.ps1' -and $script:payload.Count -eq 0 } $true
    # The runner was split into three siblings it refuses to start without, so a
    # PARTIAL set must be rejected exactly like a missing entry point. Staging only
    # the entry file proves that: an installer that shipped it alone would make
    # every guarded run in that project an immediate refusal.
    [IO.File]::WriteAllText((Join-Path $tool 'scripts/Run-Tests-Guarded.ps1'),'# test fixture')
    $script:payload.Clear(); $caught = ''
    try { Add-CompanionRuntimeArtifacts -ToolRoot $tool -FriendlyName 'Test-Run-Guard' } catch { $caught=$_.Exception.Message }
    Check-Boundary 'I03b a partial guarded-runner set is rejected too' { $caught -match '_guarded' -and $script:payload.Count -eq 0 } $true
    foreach ($leaf in @('_guardedtiming.ps1','_guardedstate.ps1','_guardedprocess.ps1')) {
        [IO.File]::WriteAllText((Join-Path $tool ('scripts/' + $leaf)),'# test fixture')
    }
    $script:payload.Clear()
    Add-CompanionRuntimeArtifacts -ToolRoot $tool -FriendlyName 'Test-Run-Guard'
    $companionNames = New-Object System.Collections.Generic.List[string]
    foreach ($artifact in $script:payload.ToArray()) { [void]$companionNames.Add([string]$artifact.Path) }
    $companionPaths = @($companionNames.ToArray() | Sort-Object)
    Check-Boundary 'I04 the complete guarded-runner set retains its exact destinations' {
        ($companionPaths -join ',') -ceq 'Test-Run-Guard/scripts/_guardedprocess.ps1,Test-Run-Guard/scripts/_guardedstate.ps1,Test-Run-Guard/scripts/_guardedtiming.ps1,Test-Run-Guard/scripts/Run-Tests-Guarded.ps1'
    } $true
}
catch {
    $message=$_.Exception.Message + ' ' + $_.ScriptStackTrace
    Check-Boundary 'HARNESS completes without exceptions' { throw $message }
}
finally {
    foreach ($p in $fixtureProcesses) {
        try { if (-not $p.HasExited) { $p.Kill() }; $gone=$p.WaitForExit(5000) } catch { $gone=$false }
        Check-Boundary 'CLEANUP test-owned process terminated' { $gone }
        $p.Dispose()
    }
    $cleaned = Remove-TestWorkspace -Path $work
    Check-Boundary 'CLEANUP project-owned workspace removed' { $cleaned }
}
$failed=@($cases | Where-Object { -not $_.passed }).Count
$unexpected=@($cases | Where-Object unexpected).Count
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    $doc=[ordered]@{hostVersion=$PSVersionTable.PSVersion.ToString();baseline=[bool]$Baseline;cases=@($cases.ToArray());failed=$failed;unexpected=$unexpected}
    [IO.File]::WriteAllText($ResultPath,($doc|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
}
Write-Host ('Cases='+$cases.Count+' failed='+$failed+' unexpected='+$unexpected)
if ($unexpected -gt 0) { exit 1 }
exit 0
