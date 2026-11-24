param([string]$ResultPath = '', [switch]$SurvivorOnly)
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

    Use-Registry 'survivor'
    Save-InstallRegistry -ToolRoot $repo -Registry $original
    $survivorPath = Get-InstallRecordPath -ToolRoot $repo -Id 'bbb'
    $rawSurvivor = '{ "id": "bbb", "friendlyName": "Original B", "schema": 2, "createdUtc": "2026-09-25T21:15:05.0000000Z", "note": "keep exact formatting" }' + "`r`n"
    [IO.File]::WriteAllText($survivorPath, $rawSurvivor, (New-Object Text.UTF8Encoding($true)))
    $beforeDigest = (Get-FileHash -LiteralPath $survivorPath -Algorithm SHA256).Hash
    $state = Read-InstallRegistryState -ToolRoot $repo -NoCache
    $state.Registry.installs = @($state.Registry.installs | Where-Object id -ne 'aaa')
    Save-InstallRegistry -ToolRoot $repo -Registry $state.Registry
    Check-Storage 'removing another record preserves surviving ISO timestamp, formatting and BOM bytes' ((Get-FileHash -LiteralPath $survivorPath -Algorithm SHA256).Hash -ceq $beforeDigest)
    $state = Read-InstallRegistryState -ToolRoot $repo -NoCache
    Check-Storage 'survivor-preserving generation activates with the exact retained digest' ($state.State -eq 'ok' -and @($state.Registry.installs).Count -eq 1 -and (Get-InstallRegistryGenerationState $repo).Complete)
    $state.Registry.installs[0].friendlyName = 'Changed B'
    Save-InstallRegistry -ToolRoot $repo -Registry $state.Registry
    $state = Read-InstallRegistryState -ToolRoot $repo -NoCache
    Check-Storage 'a genuinely changed surviving record is persisted rather than mistaken for formatting drift' ($state.State -eq 'ok' -and $state.Registry.installs[0].friendlyName -ceq 'Changed B' -and (Get-FileHash -LiteralPath $survivorPath -Algorithm SHA256).Hash -cne $beforeDigest)

    if (-not $SurvivorOnly) {
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

        . (Join-Path $repo 'hooks\Cross-Project-.ai-Knowledge-Sync\_syncpaths.ps1')
        $fileAncestor = Join-Path $work 'not-a-directory'
        [IO.File]::WriteAllText($fileAncestor, 'file')
        Check-Storage 'a file masquerading as a state directory is rejected' (-not (Test-SyncPathChain -Root $work -Path (Join-Path $fileAncestor 'route.json') -Leaf -AllowMissing))
        $outside = Join-Path (Split-Path -Parent $work) 'outside.md'
        Check-Storage 'a state path cannot escape the configured root' (-not (Test-SyncPathChain -Root $work -Path $outside -Leaf -AllowMissing))

        $caseParent = Join-Path $work 'case-sibling-parent'
        [void][IO.Directory]::CreateDirectory($caseParent)
        $null = & fsutil.exe file setCaseSensitiveInfo $caseParent enable 2>&1
        $caseSensitive = $LASTEXITCODE -eq 0
        $project = Join-Path $caseParent 'Project'
        $sibling = Join-Path $caseParent 'project'
        [void][IO.Directory]::CreateDirectory($project)
        if ($caseSensitive) {
            [void][IO.Directory]::CreateDirectory($sibling)
            [IO.File]::WriteAllText((Join-Path $sibling 'sibling.md'), 'distinct sibling')
            Check-Storage 'NTFS fixture has distinct case-sensitive siblings' (-not [IO.File]::Exists((Join-Path $project 'sibling.md')))
        }
        else { Write-Host 'NTFS case sensitivity unavailable; checking path spelling on the ordinary directory.' }
        Check-Storage 'reject path tails with a different case' (-not (Test-SyncPathChain -Root $project -Path (Join-Path $sibling 'sibling.md') -Leaf -AllowMissing))
        $driveAlias = [string]$project[0]
        $driveAlias = $(if ($driveAlias -ceq $driveAlias.ToUpperInvariant()) { $driveAlias.ToLowerInvariant() } else { $driveAlias.ToUpperInvariant() }) + $project.Substring(1)
        Check-Storage 'accept the same path with a different drive letter case' (Test-SyncPathChain -Root $project -Path (Join-Path $driveAlias 'inside.md') -Leaf -AllowMissing)
    }
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
