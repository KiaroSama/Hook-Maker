# Test-Wizard.ps1 block: wizard log retention and the log-directory redirect.
#
# Initialize-Log keeps only the newest $LogRetentionCount "Setup-SyncGroup_*.log"
# files (5,000+ had accumulated in six weeks, nearly all from these suites) and
# honours HOOKMAKER_LOG_DIR so the suites' own runs land in $Work, never in the
# real logs/. Dot-sourced into Test-Wizard.ps1's scope (uses $Work, Invoke-Wizard,
# New-Config, Check, $RealLogDir, $RealWizardLogCount) - not a standalone suite.

Write-Host ''
Write-Host '--- log retention and the HOOKMAKER_LOG_DIR redirect ---' -ForegroundColor Cyan
$logDir = $env:HOOKMAKER_LOG_DIR
Check 'redirect: this suite runs with HOOKMAKER_LOG_DIR inside its workspace' ($logDir -like ($Work + '*')) $logDir
$loggedHere = @(Get-ChildItem -LiteralPath $logDir -File -Filter 'Setup-SyncGroup_*.log' -ErrorAction SilentlyContinue).Count
Check 'redirect: the earlier wizard runs of this suite logged there' ($loggedHere -gt 0) ('count=' + $loggedHere)

# 205 stale logs whose names sort before any real one (the name carries the UTC stamp).
for ($i = 0; $i -lt 205; $i++) {
    $stale = Join-Path $logDir ('Setup-SyncGroup_2000-01-01_00-00-00_UTC_' + $i + '.log')
    [System.IO.File]::WriteAllText($stale, 'stale', (New-Object System.Text.UTF8Encoding $false))
}
$retentionConfig = Join-Path $Work 'retention.json'
New-Config $retentionConfig
$null = Invoke-Wizard -Answers @('exit') -Config $retentionConfig -NoInstall
$remaining = @(Get-ChildItem -LiteralPath $logDir -File -Filter 'Setup-SyncGroup_*.log' | Sort-Object Name)
$newestName = ''
$newestText = ''
if ($remaining.Count -gt 0) {
    $newestName = $remaining[$remaining.Count - 1].Name
    $newestText = [System.IO.File]::ReadAllText($remaining[$remaining.Count - 1].FullName)
}
Check 'retention: exactly 200 wizard logs remain after a run' ($remaining.Count -eq 200) ('count=' + $remaining.Count)
Check 'retention: the newest log is this run, not a stale fixture' ($newestName -ne '' -and $newestName -notmatch '_2000-01-01_') $newestName
Check 'retention: the oldest names went first' (-not (Test-Path -LiteralPath (Join-Path $logDir 'Setup-SyncGroup_2000-01-01_00-00-00_UTC_0.log')))
Check 'retention: the prune is recorded in the run''s own log' ($newestText -match 'Pruned \d+ log file') $newestText.Substring(0, [Math]::Min(300, $newestText.Length))
$realNow = @(Get-ChildItem -LiteralPath $RealLogDir -File -Filter 'Setup-SyncGroup_*.log' -ErrorAction SilentlyContinue).Count
Check 'redirect: the real logs/ gained no wizard log during this suite' ($realNow -eq $RealWizardLogCount) ('before=' + $RealWizardLogCount + ' now=' + $realNow)
