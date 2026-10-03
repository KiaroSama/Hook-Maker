# Docs carryover owns stricter, COMPLETE remote evidence than the general status
# display. Every call shares the existing hook/GitHub deadline; truncation is unknown.
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
    $runsDoc = Read-DocsCiApi ('repos/' + $RepoSlug + '/actions/runs?head_sha=' + $Sha + '&per_page=50')
    if ($null -eq $runsDoc -or $null -eq (Get-Field $runsDoc 'total_count') -or $null -eq $runsDoc.PSObject.Properties['workflow_runs']) { return $false }
    $runs = @((Get-Field $runsDoc 'workflow_runs') | Where-Object { $null -ne $_ })
    if ($runs.Count -eq 0 -and (Get-Field $runsDoc 'total_count') -eq 0) { $script:DocsAncestorAbsent = $true; return $false }
    if ($runs.Count -eq 0 -or $runs.Count -gt 50 -or $runs.Count -ne (Get-Field $runsDoc 'total_count')) { return $false }
    foreach ($run in $runs) {
        if ([string](Get-Field $run 'head_sha') -cne $Sha -or
            [string](Get-Field (Get-Field $run 'head_repository') 'full_name') -ine $RepoSlug -or
            [string](Get-Field $run 'status') -cne 'completed' -or [string](Get-Field $run 'conclusion') -cne 'success') { return $false }
    }
    # Every branch-applicable push workflow must be represented. Unknown YAML or
    # a workflow filtered out of this ancestor is conservative: no carryover.
    $workflows = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'ls-tree', '-r', '--name-only', $Sha, '--', '.github/workflows'))
    if ($LASTEXITCODE -ne 0 -or $workflows.Count -gt 50) { return $false }
    $expected = 0
    foreach ($path in $workflows) {
        if ($path -notmatch '\.ya?ml$') { continue }
        $text = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'show', ($Sha + ':' + $path))) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $false }
        $filter = Get-WorkflowPushFilter -Text $text
        if ($null -eq $filter) { continue }
        if (-not $filter.Certain -or @(@($filter.Branches) + @($filter.BranchesIgnore) | Where-Object { $_ -match '[?+\[\]]' }).Count -gt 0) { return $false }
        if (@($filter.Branches).Count -gt 0 -and -not (Test-FilterMatch $Branch $filter.Branches)) { continue }
        if (@($filter.BranchesIgnore).Count -gt 0 -and (Test-FilterMatch $Branch $filter.BranchesIgnore)) { continue }
        $expected++
        if (@($runs | Where-Object { [string](Get-Field $_ 'path') -ceq $path -and [string](Get-Field $_ 'event') -ceq 'push' }).Count -eq 0) { return $false }
    }
    if ($expected -eq 0) { return $false }
    $checksDoc = Read-DocsCiApi ('repos/' + $RepoSlug + '/commits/' + $Sha + '/check-runs?filter=latest&per_page=100')
    if ($null -eq $checksDoc -or $null -eq (Get-Field $checksDoc 'total_count') -or $null -eq $checksDoc.PSObject.Properties['check_runs']) { return $false }
    $checks = @((Get-Field $checksDoc 'check_runs') | Where-Object { $null -ne $_ })
    if ($checks.Count -eq 0 -or $checks.Count -gt 100 -or $checks.Count -ne (Get-Field $checksDoc 'total_count')) { return $false }
    foreach ($check in $checks) {
        if ([string](Get-Field $check 'head_sha') -cne $Sha -or [string](Get-Field $check 'status') -cne 'completed' -or
            [string](Get-Field $check 'conclusion') -cne 'success') { return $false }
    }
    $statusDoc = Read-DocsCiApi ('repos/' + $RepoSlug + '/commits/' + $Sha + '/status?per_page=100')
    if ($null -eq $statusDoc -or [string](Get-Field $statusDoc 'sha') -cne $Sha -or
        $null -eq (Get-Field $statusDoc 'total_count') -or $null -eq $statusDoc.PSObject.Properties['statuses']) { return $false }
    $statuses = @((Get-Field $statusDoc 'statuses') | Where-Object { $null -ne $_ })
    if ($statuses.Count -gt 100 -or $statuses.Count -ne (Get-Field $statusDoc 'total_count')) { return $false }
    if (@($statuses | Where-Object { [string](Get-Field $_ 'state') -cne 'success' }).Count -gt 0) { return $false }
    if ($statuses.Count -gt 0 -and [string](Get-Field $statusDoc 'state') -cne 'success') { return $false }
    return $true
}
