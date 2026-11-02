# Persisted-stage unit controls plus public moved-project lifecycle regression.
function Invoke-CompanionAbsenceRegression {
    param([string]$Root,[string]$Work)
    & {
        . (Join-Path $Root 'hooks/_hooklib.ps1')
        . (Join-Path $Root 'scripts/_installplan.ps1')
        . (Join-Path $Root 'scripts/_uninstallresidue.ps1')
        . (Join-Path $Root 'scripts/_uninstallnative.ps1')
        $FriendlyName='Utf8-Encoding-Check';$Complete=$false;$WhatIf=$false
        $old=Join-Path $Work 'absent old project'
        $nativeRoot=Join-Path $old '.git/hooks/Hook-Maker'
        $stage=Join-Path $nativeRoot 'Utf8-Encoding-Check/Utf8-Encoding-Check.ps1'
        $wrapper=Join-Path $old '.git/hooks/pre-push'
        $record=[pscustomobject]@{targetProjectRoot=$old}
        $owner=[pscustomobject]@{friendlyName='Ignore-Rules-Check';targetProjectRoot=$old;nativeGit=[pscustomobject]@{managed=$true;wrapperPath=$wrapper;runtimeRoot=$nativeRoot;expectedStages=@($stage);companions=@('Utf8-Encoding-Check')}}
        $registry=[pscustomobject]@{installs=@($owner)}
        function Set-ComponentResult {param($Component,$Status,$ReasonCode,$Message) $script:AbsenceResult=[pscustomobject]@{status=$Status;reason=$ReasonCode}}
        $RecordTargetProjectRoot=$old;$ToolRoot=$Root
        function Read-InstallRegistryState {param($ToolRoot) return [pscustomobject]@{State='ok';Registry=$registry}}
        function Invoke-WithResourceLock {param($ResourcePath,$Action) throw 'Absent-root removal must not create a resource-lock parent.'}
        Remove-CompanionChainStage
        if($script:AbsenceResult.status-cne'ok'-or$script:AbsenceResult.reason-cne'alreadyRemoved'-or(Test-Path -LiteralPath $old)){throw 'Absent owned companion must be idempotent without recreating the root.'}
        $registry.installs=@($owner,$owner)
        $refused=$false
        try { Remove-CompanionChainStage } catch { $refused=$_.Exception.Message -match 'Multiple native companion owners' }
        if(-not $refused -or (Test-Path -LiteralPath $old)){throw 'Ambiguous owners must refuse without recreating the root.'}
        $registry.installs=@($owner)
        $owner.nativeGit.expectedStages=@($stage,$stage)
        Remove-CompanionChainStage
        if($script:AbsenceResult.status-cne'manualRepair'){throw 'Duplicate persisted stages must remain unproven.'}
        $owner.nativeGit.expectedStages=@($stage)
        $owner.nativeGit.wrapperPath=Join-Path $Work 'foreign/pre-push'
        Remove-CompanionChainStageCore
        if($script:AbsenceResult.status-cne'manualRepair'){throw 'Foreign wrapper cannot authorize missing-root retirement.'}
        $owner.nativeGit.wrapperPath=$wrapper
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $stage))
        [IO.File]::WriteAllText($stage,'fixture',[Text.UTF8Encoding]::new($false))
        Remove-CompanionChainStageCore
        if($script:AbsenceResult.status-cne'manualRepair'-or-not[IO.File]::Exists($stage)){throw 'Missing wrapper cannot abandon surviving stage.'}
        [IO.File]::Delete($stage)
        [IO.Directory]::Delete((Split-Path -Parent $stage))
        $owner.nativeGit.expectedStages=@((Join-Path $Work 'foreign/Utf8-Encoding-Check/Utf8-Encoding-Check.ps1'))
        Remove-CompanionChainStageCore
        if($script:AbsenceResult.status-cne'manualRepair'){throw 'Foreign persisted stage cannot authorize absence.'}
        Write-Output 'Companion absence: 6 controls passed.'
    }
}

# Runs in the existing isolated Test-UninstallHook harness on both hosts.
function Invoke-MovedCompanionRegression {
    $oldProject = New-Proj 'Companion old project'
    & git -C $oldProject init --quiet -b main
    if ($LASTEXITCODE -ne 0) { throw 'Moved companion fixture initialization failed.' }
    $ignoreSource = Join-Path $RealHooksDir 'Ignore-Rules-Check/Ignore-Rules-Check.ps1'
    $utf8Source = Join-Path $RealHooksDir 'Utf8-Encoding-Check/Utf8-Encoding-Check.ps1'
    & $InstallScript -CustomHook $ignoreSource -Events @('Stop') -TargetProject $oldProject *> $null
    & $InstallScript -CustomHook $utf8Source -Events @('Stop') -TargetProject $oldProject *> $null
    $oldUtf8 = Get-RecordForScope 'Utf8-Encoding-Check' $oldProject
    $newProject = Join-Path $Work 'Companion moved project'
    [IO.Directory]::Move($oldProject, $newProject)
    & $InstallScript -CustomHook $ignoreSource -Events @('Stop') -TargetProject $newProject *> $null
    & $InstallScript -CustomHook $utf8Source -Events @('Stop') -TargetProject $newProject *> $null
    $newUtf8 = Get-RecordForScope 'Utf8-Encoding-Check' $newProject
    $newOwner = Get-RecordForScope 'Ignore-Rules-Check' $newProject
    $protected = @([string]$newOwner.nativeGit.wrapperPath) + @($newOwner.nativeGit.expectedStages)
    foreach ($client in @('claude', 'codex')) {
        $sub = Get-ClientSubrecord $newUtf8 $client
        $protected += @([string]$sub.settingsPath, [string]$sub.runtimeScript)
    }
    $before = @{}
    foreach ($path in $protected) { $before[$path] = [IO.File]::ReadAllBytes($path) }
    $removed = Invoke-UninstallProcess -RecordId $oldUtf8.id
    Check 'moved companion public uninstall retires only the obsolete record' (
        [string]$removed.Result.overall -eq 'ok' -and -not (Test-Path -LiteralPath $oldProject) -and
        (Get-ComponentReason $removed.Result 'chainStage') -eq 'alreadyRemoved' -and
        @((Get-Registry).installs | Where-Object { $_.id -eq $oldUtf8.id }).Count -eq 0) ($removed.Result | ConvertTo-Json -Depth 5)
    $changed = @($protected | Where-Object {
        -not [IO.File]::Exists($_) -or -not (Test-BytesEqual ([IO.File]::ReadAllBytes($_)) $before[$_])
    })
    Check 'moved companion preserves replacement wrapper, stages and both clients byte-for-byte' ($changed.Count -eq 0) ($changed -join '; ')
    Check 'replacement tracking remains independently owned' (
        @((Get-Registry).installs | Where-Object { $_.id -eq $newUtf8.id }).Count -eq 1 -and
        @((Get-Registry).installs | Where-Object { $_.id -eq $newOwner.id }).Count -eq 1)
}
