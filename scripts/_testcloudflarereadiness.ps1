# A corrupt fixture index makes `git status` fail while HEAD/upstream remain valid.
$fingerprintProbe = Join-Path $Work 'fingerprint-probe.ps1'
Write-Utf8 $fingerprintProbe (@'
. '__LIBRARY__'
$inputRecord = Read-HookInput
'FINGERPRINT=' + (Get-RepoStateFingerprint -ProjectRoot ([string](Get-Field $inputRecord 'cwd')))
'@.Replace('__LIBRARY__', $HookLib.Replace("'", "''")))
function Get-FixtureFingerprint {
    param([string]$Root, [string]$HostName)
    $savedHook = $Hook
    try {
        $Hook = $fingerprintProbe
        return Fire -Cwd $Root -Exe $HostName
    }
    finally { $Hook = $savedHook }
}
foreach ($hostName in @('pwsh', 'powershell.exe')) {
    Write-Host ('--- failed status is not release-ready: ' + $hostName + ' ---') -ForegroundColor Cyan
    $hostTag = if ($hostName -eq 'pwsh') { 'ps7' } else { 'ps5' }
    $failedStatusRepo = New-ReadyWorkersRepo ('StatusFailure-' + $hostTag)
    $cleanFingerprint = Get-FixtureFingerprint -Root $failedStatusRepo -HostName $hostName
    Check ($hostName + ': clean fixture has a usable coordination fingerprint') (
        $cleanFingerprint.Exit -eq 0 -and $cleanFingerprint.Out -match '^FINGERPRINT=[a-f0-9]+$') ($cleanFingerprint.Out + $cleanFingerprint.Err)
    [System.IO.File]::WriteAllBytes((Join-Path $failedStatusRepo '.git\index'), [byte[]]@(1, 2, 3))
    $null = Invoke-QuietCommand -FilePath git -ArgumentList @('-C', $failedStatusRepo, 'status', '--porcelain')
    Check ($hostName + ': fixture status fails with a real Git error') ($LASTEXITCODE -eq 128)
    $failedFingerprint = Get-FixtureFingerprint -Root $failedStatusRepo -HostName $hostName
    Check ($hostName + ': failed status yields UNKNOWN rather than a clean fingerprint') (
        $failedFingerprint.Exit -eq 0 -and $failedFingerprint.Out -eq 'FINGERPRINT=') ($failedFingerprint.Out + $failedFingerprint.Err)
    $r = Fire -Cwd $failedStatusRepo -Exe $hostName
    Check ($hostName + ': failed status cannot open the release-readiness gate') ($r.Exit -eq 0 -and $r.Out -eq '') ($r.Out + $r.Err)
}
