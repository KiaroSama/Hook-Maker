# Every ancestor uses the same complete positive workload evidence as final CI.
. (Join-Path $PSScriptRoot '_docsquery.ps1')
function Invoke-DocsGit {
    param([string[]]$Arguments)
    $key=Get-DocsImmutableQueryKey $Arguments
    if($key-ne''-and$script:DocsEvidenceCache.ContainsKey($key)){$global:LASTEXITCODE=0;return $script:DocsEvidenceCache[$key]}
    $remaining = Get-GhRemainingSeconds
    if ($remaining -lt 1) { $global:LASTEXITCODE = 124; return @() }
    $lines=@(Invoke-QuietCommand -FilePath git -ArgumentList $Arguments -TimeoutSeconds ([Math]::Min(5, $remaining)))
    Save-DocsImmutableQuery -Key $key -Lines $lines
    return $lines
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
    $script:DocsAncestorSnapshot=$snapshot
    $review=Get-Variable DocsReviewedClosure -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $maintenanceOnly=$snapshot.Runs.Count-eq0
    if($null-ne$review-and$snapshot.Runs.Count-gt0){
        $maintenanceOnly=@($snapshot.Runs|Where-Object{@(Get-Field $review 'maintenanceWorkflows')-cnotcontains$_.path}).Count-eq0
    }
    $script:DocsAncestorAbsent = ($maintenanceOnly -and $snapshot.ChecksComplete -and $snapshot.CommitChecksSafe -and
        $snapshot.FailedRuns.Count -eq 0 -and $snapshot.PendingRuns.Count -eq 0 -and $snapshot.InfraRuns.Count -eq 0 -and $snapshot.BillingRuns.Count -eq 0)
    return $snapshot.AllSuccess
}
