# Gitleaks must execute green on every push: a skipped scan is a workflow defect, never green.
function Test-IsGitleaksCheck {
    param([string]$Name)
    return ([string]$Name -match '(?i)gitleaks')
}

# Returns concise defect strings for a Gitleaks workflow that can skip push runs, else @().
function Get-GitleaksWorkflowSkipDefects {
    param([string]$ProjectRoot)
    $defects = New-Object Collections.Generic.List[string]
    $dir = Join-Path $ProjectRoot '.github\workflows'
    if (-not [IO.Directory]::Exists($dir)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { ($_.Name -match '(?i)gitleaks') -and ($_.Extension -in @('.yml', '.yaml')) })) {
        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $file.FullName -TotalCount 600 -ErrorAction Stop) } catch { continue }
        $label = '.github/workflows/' + $file.Name
        $inJobs = $false; $inPush = $false; $jobIf = $false; $pathFilter = $false
        $jobKeyIndent = -1; $jobPropIndent = -1
        foreach ($raw in $lines) {
            $line = [string]$raw
            if (($line -match '^\s*#') -or ($line -match '^\s*$')) { continue }
            $indent = $line.Length - $line.TrimStart().Length
            if ($indent -eq 0) { $inJobs = ($line -match '^jobs\s*:'); $inPush = $false; $jobKeyIndent = -1; $jobPropIndent = -1; continue }
            if ($inJobs) {
                if ($jobKeyIndent -lt 0) { $jobKeyIndent = $indent }
                elseif ($indent -gt $jobKeyIndent -and $jobPropIndent -lt 0) { $jobPropIndent = $indent }
                if ($indent -eq $jobPropIndent -and ($line -match '^\s+if\s*:')) { $jobIf = $true }
            }
            if ($indent -le 2) { $inPush = ($line -match '^\s+push\s*:') }
            elseif ($inPush -and ($line -match '^\s+(paths|paths-ignore)\s*:')) { $pathFilter = $true }
            if ($line -match '^\s*push\s*:\s*\{.*paths') { $pathFilter = $true }
        }
        if ($jobIf) { $defects.Add($label + ' job-level if: can skip the push scan (Gitleaks secret scan (push) must run green, never skipped); remove it') }
        if ($pathFilter) { $defects.Add($label + ' push paths:/paths-ignore: filter can skip the push scan (must run green, never skipped); remove it') }
    }
    return @($defects.ToArray())
}
