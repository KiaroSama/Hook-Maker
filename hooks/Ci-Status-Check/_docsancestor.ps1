# Every ancestor uses the same complete positive workload evidence as final CI.
function Invoke-DocsGit {
    param([string[]]$Arguments)
    $remaining = Get-GhRemainingSeconds
    if ($remaining -lt 1) { $global:LASTEXITCODE = 124; return @() }
    return (Invoke-QuietCommand -FilePath git -ArgumentList $Arguments -TimeoutSeconds ([Math]::Min(5, $remaining)))
}
function Read-DocsCiApi {
    param([string]$Endpoint)
    $raw = @(Invoke-GhBounded -ArgumentList @('api', $Endpoint)) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function Test-DocsAncestorGreen {
    param([string]$ProjectRoot, [string]$RepoSlug, [string]$Sha, [string]$Branch)
    if ($Sha -notmatch '^[a-f0-9]{40}$' -or (Get-GhRemainingSeconds) -lt 1) { return $false }
    if ($null -eq (Get-Command Get-CiRunSnapshot -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot '_ciworkload.ps1')
    }
    $snapshot = Get-CiRunSnapshot -ProjectRoot $ProjectRoot -RepoSlug $RepoSlug -Sha $Sha -Branch $Branch
    if ($null -eq $snapshot) { return $false }
    $script:DocsAncestorAbsent = ($snapshot.Runs.Count -eq 0 -and $snapshot.FailedRuns.Count -eq 0 -and
        $snapshot.PendingRuns.Count -eq 0 -and $snapshot.InfraRuns.Count -eq 0 -and $snapshot.BillingRuns.Count -eq 0)
    return $snapshot.AllSuccess
}
