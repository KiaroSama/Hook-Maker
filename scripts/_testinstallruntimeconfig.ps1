# Runtime configuration survives both a failed replacement and a later retry.
# Loaded by _testinstallregistrysafety.ps1; needs _testlib, _installplan and
# _installlib. Uses a real file handle to deny copying without denying deletion.

Write-Host '--- runtime replacement preserves configuration on copy failure ---' -ForegroundColor Cyan
$runtimeConfigWork = New-TestWorkspace -Prefix 'hookmaker-runtime-config'
try {
    $runtimeConfigRoot = Join-Path $runtimeConfigWork 'runtime with spaces'
    $runtimeConfigName = 'Config-Recovery'
    $runtimeConfigScript = Join-Path $runtimeConfigRoot 'Config-Recovery\Config-Recovery.ps1'
    $runtimeConfigPath = Join-Path $runtimeConfigRoot 'Config-Recovery\.env'
    $runtimeConfigOldBody = "exit 0 # original`r`n"
    $runtimeConfigNewBody = "exit 0 # replacement`r`n"
    $runtimeConfigText = 'LOCAL_LABEL=caf' + [char]0xE9 + "`r`nMAX_FILES=7`r`n"
    $runtimeConfigOldPlan = @(New-PlanArtifact -RelativePath 'Config-Recovery/Config-Recovery.ps1' -Kind 'Generated' -GeneratedContent $runtimeConfigOldBody)
    $runtimeConfigNewPlan = @(New-PlanArtifact -RelativePath 'Config-Recovery/Config-Recovery.ps1' -Kind 'Generated' -GeneratedContent $runtimeConfigNewBody)
    Install-PlannedRuntime -Plan $runtimeConfigOldPlan -RuntimeRoot $runtimeConfigRoot -FriendlyName $runtimeConfigName | Out-Null
    Write-Utf8 -Path $runtimeConfigPath -Content $runtimeConfigText
    $runtimeConfigBytes = [System.IO.File]::ReadAllBytes($runtimeConfigPath)

    # FileShare.Delete allows the original buggy swap and cleanup to complete,
    # while denying the READ required to carry the user's configuration across.
    $runtimeConfigHandle = [System.IO.File]::Open($runtimeConfigPath, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Delete)
    $runtimeConfigError = ''
    try {
        try { Install-PlannedRuntime -Plan $runtimeConfigNewPlan -RuntimeRoot $runtimeConfigRoot -FriendlyName $runtimeConfigName | Out-Null }
        catch { $runtimeConfigError = $_.Exception.Message }
    }
    finally { $runtimeConfigHandle.Dispose() }

    Check 'a configuration copy failure is reported' (-not [string]::IsNullOrWhiteSpace($runtimeConfigError))
    Check 'a configuration copy failure keeps the original runtime' (
        [System.IO.File]::ReadAllText($runtimeConfigScript, [System.Text.Encoding]::UTF8) -ceq $runtimeConfigOldBody)
    $runtimeConfigPresent = Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf
    Check 'a configuration copy failure keeps the original configuration' $runtimeConfigPresent
    $runtimeConfigUnchanged = $false
    if ($runtimeConfigPresent) {
        $runtimeConfigUnchanged = [System.Linq.Enumerable]::SequenceEqual([byte[]]$runtimeConfigBytes,
            [byte[]][System.IO.File]::ReadAllBytes($runtimeConfigPath))
    }
    Check 'a configuration copy failure keeps the exact UTF-8 bytes' $runtimeConfigUnchanged
    Check 'a configuration copy failure removes disposable staging' (
        @(Get-ChildItem -LiteralPath $runtimeConfigRoot -Directory -Force | Where-Object { $_.Name -like '.hookmaker-*' }).Count -eq 0)

    # Re-seed independently so a failure above does not prevent the retry checks.
    Write-Utf8 -Path $runtimeConfigPath -Content $runtimeConfigText
    Install-PlannedRuntime -Plan $runtimeConfigNewPlan -RuntimeRoot $runtimeConfigRoot -FriendlyName $runtimeConfigName | Out-Null
    Check 'an unlocked retry installs the replacement runtime' (
        [System.IO.File]::ReadAllText($runtimeConfigScript, [System.Text.Encoding]::UTF8) -ceq $runtimeConfigNewBody)
    Check 'an unlocked retry preserves exact configuration bytes' (
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$runtimeConfigBytes,
            [byte[]][System.IO.File]::ReadAllBytes($runtimeConfigPath)))
    Check 'an unlocked retry removes the previous runtime and staging' (
        @(Get-ChildItem -LiteralPath $runtimeConfigRoot -Directory -Force | Where-Object { $_.Name -like '.hookmaker-*' }).Count -eq 0)
}
finally {
    if (-not (Remove-TestWorkspace $runtimeConfigWork)) { $script:Fail++ }
}
