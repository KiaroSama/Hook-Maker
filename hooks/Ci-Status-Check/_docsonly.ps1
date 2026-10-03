# Skip-marked prose-only chains may reuse independently verified ancestor CI.
# Local cache is optional: pending reports overwrite it. This module coordinates
# bounded exact remote evidence, conservative input policy and serialized once
# publication. Outcome is docs-only-carryover, NEVER ci-green for documentation;
# Test-Completion-Check remains unchanged. Owning policy: GitHub rules Section8.
#
# Anything else keeps today's behaviour: no skip marker, a file that is not
# documentation, a parent that was not verified green, or a branch whose
# protection requires status checks (a skipped commit would leave them pending).

foreach ($module in @('_docsancestor.ps1', '_docsinputs.ps1')) { . (Join-Path $PSScriptRoot $module) }

$script:DocsOnlySkipMarkers = @('[skip ci]', '[ci skip]', '[no ci]', '[skip actions]', '[actions skip]')

function Test-CommitHasSkipMarker {
    param([string]$Message)
    $lower = ([string]$Message).ToLowerInvariant()
    foreach ($marker in $script:DocsOnlySkipMarkers) { if ($lower.Contains($marker)) { return $true } }
    return ($Message -match '(?im)^skip-checks:\s*true\s*$')
}

# Tracked public documentation only: Markdown, plus a .txt that is plainly prose
# (under docs/, or a README/CHANGELOG/NOTICE/AUTHORS/CONTRIBUTING file). A .txt
# elsewhere is usually build or dependency input (requirements.txt, CMakeLists.txt),
# and nothing under .github or a test, fixture or example path ever counts.
function Test-DocumentationOnlyPath {
    param([string]$Path)
    $p = ([string]$Path).Replace('\', '/').ToLowerInvariant()
    if ($p.StartsWith('.github/') -or $p -match '(^|/)(tests?|fixtures?|examples?|samples?|testdata)(/|$)' -or $p -match '\.example\.') { return $false }
    if ($p.EndsWith('.md')) { return $true }
    if (-not $p.EndsWith('.txt')) { return $false }
    $leaf = $p.Substring($p.LastIndexOf('/') + 1)
    return ($p.StartsWith('docs/') -or $leaf -match '^(readme|changelog|changes|history|notice|authors|contributing)([._-].*)?\.txt$')
}

# The last SHA observed green: this commit's own record when it says
# ci-green, or the parent a previous docs-only carry-over named.
function Get-VerifiedGreenBase {
    param([string]$StatePath)
    try {
        if (-not [IO.File]::Exists($StatePath)) { return '' }
        $lines = @([IO.File]::ReadAllLines($StatePath))
        if ($lines.Count -lt 4 -or $lines[1].Trim() -cne 'verified') { return '' }
        if ($lines[3].Trim() -ceq 'ci-green') { return $lines[0].Trim() }
        if ($lines[3].Trim() -ceq 'docs-only-carryover' -and $lines.Count -ge 5) { return $lines[4].Trim() }
    }
    catch { }
    return ''
}

# $null (today's behaviour) or @{ Parent; Files } when the carry-over applies.
function Get-DocsOnlyCarryover {
    param([string]$ProjectRoot, [string]$Sha, [string]$Branch, [string]$RepoSlug, [string]$StatePath)
    $message = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'log', '-1', '--format=%B', $Sha)) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not (Test-CommitHasSkipMarker -Message $message)) { return $null }
    # The pending record overwrites the old green cache; never make local history
    # a prerequisite. Walk at most eight first-parent edges, rejecting EVERY edge
    # so code later reverted to the same tree cannot masquerade as docs-only.
    $chain = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'rev-list', '--first-parent', '--max-count=9', $Sha))
    if ($LASTEXITCODE -ne 0 -or $chain.Count -lt 2 -or $chain[0] -cne $Sha) { return $null }
    $cached = Get-VerifiedGreenBase -StatePath $StatePath
    $files = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $candidates = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $chain.Count - 1; $i++) {
        $parents = ([string](Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'rev-list', '--parents', '-n', '1', $chain[$i]))).Split(' ')
        if ($LASTEXITCODE -ne 0 -or $parents.Count -ne 2 -or $parents[1] -cne $chain[$i + 1]) { break }
        $delta = @(Invoke-DocsGit -Arguments @('-C', $ProjectRoot, 'diff', '--name-only', '--no-renames', $chain[$i + 1], $chain[$i]))
        if ($LASTEXITCODE -ne 0 -or $delta.Count -eq 0 -or @($delta | Where-Object { -not (Test-DocumentationOnlyPath $_) }).Count -gt 0) { break }
        foreach ($path in $delta) { [void]$files.Add([string]$path) }
        $candidates.Add([string]$chain[$i + 1])
        if ([string]$chain[$i + 1] -ceq $cached) { break }
    }
    if ($candidates.Count -eq 0 -or (Test-DocsHaveSemanticConsumers $ProjectRoot $Sha @($files))) { return $null }
    if (-not (Test-NoRequiredStatusChecks -RepoSlug $RepoSlug -Branch $Branch)) { return $null }
    $ordered = @($candidates.ToArray())
    # Nearest first: an older cached success cannot conceal a newer failed run.
    foreach ($base in $ordered) {
        if ((Get-GhRemainingSeconds) -lt 1) { break }
        $script:DocsAncestorAbsent = $false
        if (Test-DocsAncestorGreen $ProjectRoot $RepoSlug $base $Branch) {
            return [pscustomobject]@{ Parent = $base; Files = @($files | Sort-Object) }
        }
        if (-not $script:DocsAncestorAbsent) { return $null }
    }
    return $null
}

function Test-NoRequiredStatusChecks {
    param([string]$RepoSlug, [string]$Branch)
    $encoded = [uri]::EscapeDataString($Branch)
    try {
        $branchDoc = (@(Invoke-GhBounded -ArgumentList @('api', ('repos/' + $RepoSlug + '/branches/' + $encoded))) -join "`n") | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $null -eq $branchDoc -or [string](Get-Field $branchDoc 'name') -cne $Branch -or
            (Get-Field $branchDoc 'protected') -isnot [bool]) { return $false }
        if ([bool](Get-Field $branchDoc 'protected')) {
            if ($null -eq (Get-Field $branchDoc 'protection') -or $null -eq (Get-Field (Get-Field $branchDoc 'protection') 'required_status_checks')) { return $false }
            $checks = Get-Field (Get-Field $branchDoc 'protection') 'required_status_checks'
            if ($null -ne $checks) {
                if ($null -eq $checks.PSObject.Properties['contexts'] -or $null -eq $checks.PSObject.Properties['enforcement_level']) { return $false }
                $level = [string](Get-Field $checks 'enforcement_level')
                if (@(Get-Field $checks 'contexts' | Where-Object { $null -ne $_ }).Count -gt 0 -or
                    @(Get-Field $checks 'checks' | Where-Object { $null -ne $_ }).Count -gt 0 -or $level -ne 'off') { return $false }
            }
        }
        $rawRules = @(Invoke-GhBounded -ArgumentList @('api', ('repos/' + $RepoSlug + '/rules/branches/' + $encoded + '?per_page=100'))) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $rawRules.TrimStart().StartsWith('[')) { return $false }
        $rules = @($rawRules | ConvertFrom-Json | ForEach-Object { $_ })
        if ($rules.Count -ge 100) { return $false }
        foreach ($rule in $rules) {
            $type = [string](Get-Field $rule 'type')
            if ($type -eq '' -or $type -in @('required_status_checks', 'workflows')) { return $false }
        }
        return $true
    }
    catch { return $false }
}

# Writes the carry-over record and exits with the note, or returns quietly.
function Invoke-DocsOnlyCarryover {
    param([string]$ProjectRoot, [string]$Sha, [string]$Branch, [string]$RepoSlug, [string]$StatePath, [string]$EventName)
    $carry = Get-DocsOnlyCarryover -ProjectRoot $ProjectRoot -Sha $Sha -Branch $Branch -RepoSlug $RepoSlug -StatePath $StatePath
    if ($null -eq $carry) { return }
    if (-not (Write-CiStateAtomic -Path $StatePath -Lines @($Sha, 'verified', [DateTime]::UtcNow.ToString('o'), 'docs-only-carryover', $carry.Parent))) {
        # A concurrent winner already published the SAME complete carryover.
        $lines = @(); try { $lines = @([IO.File]::ReadAllLines($StatePath, [Text.Encoding]::UTF8)) } catch { }
        if ($lines.Count -ge 5 -and $lines[0] -ceq $Sha -and $lines[3] -ceq 'docs-only-carryover' -and $lines[4] -ceq $carry.Parent) { exit 0 }
        return
    }
    $shown = @($carry.Files | Select-Object -First 5)
    $more = if ($carry.Files.Count -gt $shown.Count) { ', ...' } else { '' }
    exit (Write-HookResult -EventName $EventName -Kind 'advisory' -Message ('CI CHECK: tests verified green on ' + $carry.Parent +
        '; ' + $Sha.Substring(0, [Math]::Min(7, $Sha.Length)) + ' changes documentation only (' + $carry.Files.Count + ' file(s): ' + ($shown -join ', ') + $more +
        ') and carries a skip marker, so no run was started. Report the tests as passed on that parent - this commit is not a new green result.')).ExitCode
}
