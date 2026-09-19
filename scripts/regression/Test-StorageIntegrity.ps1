param([string]$ResultPath = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'scripts\_testlib.ps1')
$work = New-TestWorkspace -Prefix 'hookmaker-storage'
$savedState = $env:HOOKMAKER_STATE_DIR
$savedLocal = $env:LOCALAPPDATA
$cases = New-Object System.Collections.Generic.List[object]
function Check-Storage {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    [void]$cases.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    $level = if ($Passed) { 'INFO' } else { 'ERROR' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' ' + $Detail)
}
function Use-Registry {
    param([string]$Name)
    $env:HOOKMAKER_STATE_DIR = Join-Path $work $Name
    [void][IO.Directory]::CreateDirectory($env:HOOKMAKER_STATE_DIR)
}
try {
    [void][IO.Directory]::CreateDirectory($work)
    $env:LOCALAPPDATA = $work
    . (Join-Path $repo 'hooks\_hooklib.ps1')
    . (Join-Path $repo 'scripts\_installplan.ps1')
    . (Join-Path $repo 'scripts\_installlib.ps1')
    $a = [pscustomobject][ordered]@{ id = 'aaa'; friendlyName = 'Original A'; schema = 2 }
    $b = [pscustomobject][ordered]@{ id = 'bbb'; friendlyName = 'Original B'; schema = 2 }
    $original = [pscustomobject]@{ version = 3; installs = @($a, $b) }

    Use-Registry 'mixed'
    Save-InstallRegistry -ToolRoot $repo -Registry $original
    $newA = [pscustomobject][ordered]@{ id = 'aaa'; friendlyName = 'Changed A'; schema = 2 }
    $newB = [pscustomobject][ordered]@{ id = 'bbb'; friendlyName = 'Changed B'; schema = 2 }
    $intended = Test-InstallRegistrySnapshot -Registry ([pscustomobject]@{ version = 3; installs = @($newA, $newB) })
    $null = Start-InstallRegistryGeneration -ToolRoot $repo -ExpectedFileNames $intended.FileNames -ExpectedRecords $intended.Expected
    Write-JsonFileAtomic -Value $newA -Path (Get-InstallRecordPath -ToolRoot $repo -Id 'aaa')
    Check-Storage 'a half-rewritten generation is not committed' (-not (Get-InstallRegistryGenerationState -ToolRoot $repo).Complete)
    $recovery = Repair-InterruptedInstallRegistryGeneration -ToolRoot $repo
    $recovered = Read-InstallRegistryState -ToolRoot $repo -NoCache
    $names = if ($recovered.State -eq 'ok') { @($recovered.Registry.installs | ForEach-Object { $_.friendlyName } | Sort-Object) -join '|' } else { '' }
    Check-Storage 'recovery restores the previous complete generation, never a new/old mixture' ($recovery.Ok -and $names -ceq 'Original A|Original B') $names

    Use-Registry 'deletion'
    Save-InstallRegistry -ToolRoot $repo -Registry $original
    $null = Start-InstallRegistryGeneration -ToolRoot $repo -ExpectedFileNames @() -ExpectedRecords @()
    Remove-Item -LiteralPath (Get-InstallRecordPath -ToolRoot $repo -Id 'aaa') -Force
    Check-Storage 'an unfinished delete-all transaction cannot commit merely because its expected set is empty' (-not (Get-InstallRegistryGenerationState -ToolRoot $repo).Complete)
    $recovery = Repair-InterruptedInstallRegistryGeneration -ToolRoot $repo
    $restored = Read-InstallRegistryState -ToolRoot $repo -NoCache
    Check-Storage 'recovery restores records deleted by an interrupted batch' ($recovery.Ok -and $restored.State -eq 'ok' -and @($restored.Registry.installs).Count -eq 2)

    Use-Registry 'future'
    Save-InstallRegistry -ToolRoot $repo -Registry $original
    $null = Start-InstallRegistryGeneration -ToolRoot $repo -ExpectedFileNames @('missing.json')
    $meta = Join-Path (Get-InstallRegistryDirectory -ToolRoot $repo) '_meta.json'
    Write-JsonFileAtomic -Path $meta -Value ([pscustomobject]@{ version = 99 })
    $before = [IO.File]::ReadAllText($meta)
    $recovery = Repair-InterruptedInstallRegistryGeneration -ToolRoot $repo
    Check-Storage 'recovery cannot downgrade an incomplete future-schema registry' (-not $recovery.Ok -and [IO.File]::ReadAllText($meta) -ceq $before)

    . (Join-Path $repo 'hooks\Cross-Project-.ai-Knowledge-Sync\_packageguard.ps1')
    $package = Join-Path $work 'review-package'
    [void][IO.Directory]::CreateDirectory((Join-Path $package 'files'))
    [IO.File]::WriteAllText((Join-Path $package 'files\lesson.md'), 'original reviewed content')
    $fingerprint = 'a' * 64
    Write-JsonFileAtomic -Path (Join-Path $package 'manifest.json') -Value ([pscustomobject]@{ version = 2; sourceContentFingerprint = $fingerprint; added = @('lesson.md'); modified = @(); deleted = @() })
    [IO.File]::WriteAllText((Join-Path $package 'files\lesson.md'), 'changed after review')
    Check-Storage 'a matching self-declared manifest fingerprint does not prove staged bytes intact' (-not (Test-PackageGenerationIntact -PackageRoot $package -Fingerprint $fingerprint))
    Remove-Item -LiteralPath (Join-Path $package 'files\lesson.md') -Force
    Check-Storage 'a missing staged file prevents acknowledgement' (-not (Test-PackageGenerationIntact -PackageRoot $package -Fingerprint $fingerprint))
    $fileAncestor = Join-Path $work 'not-a-directory'
    [IO.File]::WriteAllText($fileAncestor, 'file')
    Check-Storage 'a file masquerading as a staging directory is rejected' (-not (Test-OwnedStagingChain -TrustedRoot $work -OwnedRoot $fileAncestor -Target (Join-Path $fileAncestor 'package')))
    $outside = Join-Path $work 'outside.md'
    [IO.File]::WriteAllText($outside, 'outside')
    $digest = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash.ToLowerInvariant()
    Check-Storage 'a staged-file record cannot hash a path outside its files root' (-not (Test-StagedFilesVerified -FilesRoot (Join-Path $package 'files') -Records @([pscustomobject]@{ path = '../../outside.md'; sha256 = $digest })))
}
catch { Check-Storage 'suite completed without an unexpected exception' $false $_.Exception.Message }
finally {
    $env:HOOKMAKER_STATE_DIR = $savedState; $env:LOCALAPPDATA = $savedLocal
    if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    Check-Storage 'all owned test files were removed' (-not [IO.Directory]::Exists($work))
}
$failed = @($cases.ToArray() | Where-Object { -not $_.passed }).Count
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    $report = [ordered]@{ schema = 1; hostVersion = $PSVersionTable.PSVersion.ToString(); cases = $cases.ToArray(); failed = $failed }
    [IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
Write-Host ('Cases: ' + $cases.Count + '; failed: ' + $failed)
if ($failed -gt 0) { exit 1 }
exit 0
